# Security Audit Report: OmniSybilGuard

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniSybilGuard.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 479
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (holds ETH for report stakes and reward pool)

## Executive Summary

OmniSybilGuard is a UUPS-upgradeable contract that implements Sybil resistance through community-driven reporting, device fingerprinting, and judge-arbitrated resolution. Users stake funds to report suspected Sybil accounts, judges resolve reports after a 72-hour challenge period, and valid reports earn a 5,000-unit reward while flagging the suspect. The contract uses OpenZeppelin's AccessControl, ReentrancyGuard, and UUPSUpgradeable.

The audit found **1 Critical vulnerability**: the contract uses native ETH (`msg.value`, `.call{value}`) for all stake and reward operations, but the OmniBazaar specification requires XOM (an ERC-20 token). On OmniCoin L1 (chain 131313), native gas tokens are NOT XOM — this makes the entire economic model incompatible with the documented design. Additionally, **3 High-severity issues** were found: report ID collision can permanently lock stakes, reward pool exhaustion blocks valid report resolution (deadlocking the system), and the missing UUPS storage gap. Both audit agents independently confirmed the report ID collision as a critical fix.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 5 |
| Informational | 2 |

## Findings

### [C-01] Currency Mismatch — Uses Native ETH Instead of XOM ERC-20 Tokens

**Severity:** Critical
**Lines:** 273-274, 332-342, 356-360, 475-478
**Agent:** Agent B

**Description:**

The contract accepts and distributes native ETH (`msg.value`, `.call{value}`) for all stake and reward operations. However, the OmniBazaar specification explicitly requires XOM (an ERC-20 token) as the staking and reward currency:
- Report stake: 1,000 XOM (spec) vs 1,000 native gas tokens (implementation)
- Report reward: 5,000 XOM (spec) vs 5,000 native gas tokens (implementation)

The constants are named with XOM semantics (`REPORT_STAKE = 1000 * 10**18`, `REPORT_REWARD = 5000 * 10**18`) and the NatSpec references "XOM", but the mechanism uses `msg.value` and `.call{value}`. On OmniCoin L1 (chain 131313), the native currency is NOT XOM — XOM is a separate ERC-20 token (`OmniCoin.sol`).

The test suite confirms the mismatch: `"Note: Contract constants are designed for XOM but we test with ETH"`.

**Impact:** The entire economic model is broken. The contract cannot fulfill its stated purpose on OmniCoin L1. Staking native gas tokens has a completely different economic proposition than staking XOM.

**Recommendation:** Refactor to use `IERC20(xomToken).transferFrom()` for stakes and `IERC20(xomToken).transfer()` for payouts:
```solidity
address public xomToken; // Set in initialize()

// In reportSybil():
IERC20(xomToken).transferFrom(msg.sender, address(this), REPORT_STAKE);

// In resolveReport() (valid):
IERC20(xomToken).transfer(report.reporter, report.stake + REPORT_REWARD);

// In resolveReport() (invalid):
IERC20(xomToken).transfer(report.suspect, report.stake);
```
Remove `payable` from `reportSybil()`. Remove the `receive()` function.

---

### [H-01] Report ID Collision — Permanent Stake Loss in Same Block

**Severity:** High
**Lines:** 277-279
**Agents:** Both

**Description:**

The `reportId` is computed as `keccak256(abi.encodePacked(suspect, msg.sender, block.timestamp))`. If the same reporter submits two reports against the same suspect in the same block (same `block.timestamp`), the `reportId` is identical. The second report silently overwrites the first in the `reports` mapping — the first reporter's stake is permanently locked because the overwritten report's `stake` field now holds only the second deposit. There is no check that `reports[reportId].timestamp == 0` before writing.

Additionally, `abi.encodePacked` with address types has known collision risks (though mitigated here by fixed-size types). The `ReportAlreadyPending` error is defined (line 189) but never used.

**Impact:** Permanent loss of staked funds for the first report when a collision occurs. The `totalReports` counter becomes inaccurate (incremented twice but only one report exists).

**Recommendation:** Either use a monotonically increasing counter as the report ID, or add existence check:
```solidity
if (reports[reportId].timestamp != 0) revert ReportAlreadyPending();
```
Also switch from `abi.encodePacked` to `abi.encode`.

---

### [H-02] Reward Pool Exhaustion Blocks Valid Report Resolution — System Deadlock

**Severity:** High
**Lines:** 332-333
**Agent:** Agent B

**Description:**

When a report is ruled valid, `resolveReport()` checks `if (rewardPool < REPORT_REWARD) revert InsufficientRewardPool()`. If the reward pool is exhausted, the entire function reverts, which means:

1. The suspect is never flagged (state changes revert)
2. The reporter's stake remains locked indefinitely
3. The judge cannot rule on any valid reports until someone funds the pool
4. There is no mechanism for the reporter to withdraw their stake if the pool is empty

An attacker could deliberately drain the pool by filing valid reports against their own Sybil accounts, then file one more report whose resolution is permanently blocked.

**Impact:** Complete system deadlock for valid reports. Reporter funds locked with no recovery. Confirmed Sybil accounts remain unflagged.

**Recommendation:** Separate flagging from reward payout. Flag the account and mark resolved regardless of pool balance. If the pool is insufficient, record owed rewards in a `pendingRewards` mapping for later claim:
```solidity
if (rewardPool >= REPORT_REWARD) {
    rewardPool -= REPORT_REWARD;
    totalPayout = report.stake + REPORT_REWARD;
} else {
    pendingRewards[report.reporter] += REPORT_REWARD;
    totalPayout = report.stake;
}
```

---

### [H-03] Missing Storage Gap for UUPS Upgrades

**Severity:** High
**Lines:** Storage section (53-108)
**Agents:** Both

**Description:**

The contract uses UUPS upgradeable pattern but does not include a `__gap` storage variable. Every other UUPS contract in the OmniBazaar codebase includes a storage gap. Without a gap, adding new state variables in a future upgrade risks storage slot collision.

**Impact:** Any future upgrade adding state variables will corrupt existing reports, flagged accounts, device registrations, and reward pool balance.

**Recommendation:** Add at the end of the storage section:
```solidity
/// @dev Reserved storage gap for future upgrades
uint256[43] private __gap;
```

---

### [M-01] No Duplicate Pending Report Prevention Per Suspect

**Severity:** Medium
**Lines:** 270-294
**Agents:** Both

**Description:**

Multiple reporters can submit independent reports against the same suspect simultaneously. The `ReportAlreadyPending` error exists (line 189) but is never used. If the first report is resolved as valid (flagging the account), subsequent reports against the already-flagged suspect are still unresolved and their stakes are locked. When resolved:
- If ruled valid: drain the reward pool again for an already-flagged account
- If ruled invalid: the honest reporter's stake goes to the (already-confirmed Sybil) suspect

**Impact:** A flagged Sybil account can receive reporter stakes as "compensation" when subsequent reports are ruled invalid.

**Recommendation:** Add at the top of `reportSybil()`:
```solidity
if (flaggedAccounts[suspect]) revert AccountAlreadyFlagged();
```

---

### [M-02] Payout Failure Permanently Blocks Report Resolution

**Severity:** Medium
**Lines:** 337-342
**Agents:** Both

**Description:**

If the `.call{value}` payout fails (recipient is a contract without `receive()`/`fallback()`), the entire `resolveReport()` transaction reverts. Since the transaction reverts entirely, `report.resolved` is not persisted, so the judge can retry. But if the recipient **always** reverts on ETH receipt, the report can never be resolved, permanently locking the reporter's stake.

**Impact:** A malicious reporter can deploy a contract that rejects ETH, stake through it, and if ruled invalid, the payout to the suspect succeeds (assuming the suspect is an EOA). But if the suspect is also a contract that rejects ETH, the report is permanently stuck.

**Recommendation:** Implement pull-based withdrawals:
```solidity
mapping(address => uint256) public pendingWithdrawals;

// In resolveReport(): credit instead of push
pendingWithdrawals[recipient] += amount;

// New function:
function withdraw() external nonReentrant {
    uint256 amount = pendingWithdrawals[msg.sender];
    pendingWithdrawals[msg.sender] = 0;
    (bool success,) = msg.sender.call{value: amount}("");
    if (!success) revert PayoutFailed();
}
```

---

### [M-03] Missing Zero-Address Check on `suspect` in reportSybil

**Severity:** Medium
**Lines:** 271
**Agents:** Both

**Description:**

There is no check that `suspect != address(0)`. A report against `address(0)` would succeed. When resolved as valid, the reporter receives stake + 5000 reward from the pool — effectively draining the reward pool for a meaningless flag. When resolved as invalid, the `.call{value}` to `address(0)` succeeds (sending funds to the burn address), permanently destroying the reporter's stake.

**Impact:** Reward pool drain vector (report address(0), get it validated, collect 5000 reward). Or accidental permanent loss of stake.

**Recommendation:** Add `if (suspect == address(0)) revert ZeroAddress();`

---

### [M-04] Judge Collusion Risk — Single Unilateral Authority

**Severity:** Medium
**Lines:** 310-346, 367-370
**Agent:** Agent B

**Description:**

A single `JUDGE_ROLE` holder has unilateral power to: resolve any report as valid/invalid, manually flag any account via `manualFlag()` without evidence or stake, and collude with a reporter to split the 5,000-unit reward. There is no multi-judge requirement, no appeal mechanism, and no on-chain way for the suspect to contest a ruling.

**Impact:** A compromised judge can flag innocent accounts, extract funds via colluding reporters, and cause economic harm.

**Recommendation:** Implement multi-judge voting (2-of-3 agreement). Add an on-chain appeal mechanism. Consider judge slashing for consistently reversed decisions.

---

### [M-05] Device Fingerprint Not Integrated with OmniRegistration

**Severity:** Medium
**Lines:** 227-251
**Agent:** Agent B

**Description:**

`registerDevice()` is the only on-chain device limit enforcement (MAX_USERS_PER_DEVICE = 2), but OmniRegistration does NOT call it. OmniRegistration's comments note device fingerprinting as "off-chain." A user can register through OmniRegistration without any device check. Additionally, device fingerprints are generated client-side (browser fingerprinting) and are trivially spoofable via VMs or browser configuration changes.

**Impact:** The "one bonus per computer" invariant is not enforced on-chain. The device limit is bypassable.

**Recommendation:** Integrate `registerDevice()` as a mandatory call within OmniRegistration's registration flow. Acknowledge that client-side fingerprinting must be supplemented with server-side checks.

---

### [L-01] Excess msg.value Beyond REPORT_STAKE Not Refunded

**Severity:** Low
**Lines:** 274, 286, 341
**Agents:** Both

**Description:**

The check is `msg.value < REPORT_STAKE`, accepting any amount >= REPORT_STAKE. The full `msg.value` is stored as `report.stake`. On valid resolution, the excess is returned with the reward. On invalid resolution, the excess goes to the suspect — the reporter loses more than the intended stake amount.

**Recommendation:** Enforce exact payment: `if (msg.value != REPORT_STAKE) revert IncorrectStake();`

---

### [L-02] `receive()` Unconditionally Adds ETH to Reward Pool

**Severity:** Low
**Lines:** 475-478
**Agents:** Both

**Description:**

The `receive()` function adds all incoming ETH to `rewardPool` unconditionally. Accidental ETH transfers become irrecoverable reward pool funds. No `emergencyWithdraw()` or admin withdrawal exists for accidentally sent funds.

**Recommendation:** Remove `receive()` or have it revert. Channel all funding through `fundRewardPool()`.

---

### [L-03] Missing Zero-Address Check on `user` in registerDevice

**Severity:** Low
**Lines:** 228
**Agent:** Agent A

**Description:**

The `user` parameter is not validated against `address(0)`. Registering `address(0)` wastes one of the MAX_USERS_PER_DEVICE slots.

**Recommendation:** Add `require(user != address(0), "zero address")`.

---

### [L-04] No Cooldown After Unflagging

**Severity:** Low
**Lines:** 377-381
**Agent:** Agent B

**Description:**

After `unflagAccount()` clears a flag, there is nothing preventing a judge from immediately calling `manualFlag()` or another reporter from filing a new report. No cooldown, no appeal record.

**Recommendation:** Add a `mapping(address => uint256) public unflaggedAt` and prevent new reports for a cooldown period (e.g., 30 days).

---

### [L-05] `unflagAccount()` Emits No Event

**Severity:** Low
**Lines:** 377-381
**Agent:** Agent B

**Description:**

Every other state-changing function emits an event, but `unflagAccount()` silently modifies state. Off-chain indexers cannot track when accounts are cleared.

**Recommendation:** Add and emit `event AccountUnflagged(address indexed account)`.

---

### [I-01] `REPORTER_ROLE` Name Is Misleading

**Severity:** Informational
**Agent:** Agent B

**Description:**

`REPORTER_ROLE` is used for validators who call `registerDevice()`, not for submitting sybil reports (which is permissionless). The name suggests report submission requires this role, which is incorrect.

**Recommendation:** Rename to `DEVICE_REGISTRAR_ROLE` or `VALIDATOR_ROLE`.

---

### [I-02] `fundRewardPool()` NatSpec Contradiction

**Severity:** Informational
**Agent:** Agent A

**Description:**

The NatSpec says `@dev Only callable by admin. Anyone can send funds via fundRewardPool.` — self-contradictory. The function has no `onlyRole` modifier, making it permissionless.

**Recommendation:** Clarify the NatSpec to match implementation.

---

## Static Analysis Results

**Solhint:** 0 errors, 19 warnings
- 3 global imports (style)
- 3 ordering issues (style)
- 2 struct packing (gas optimization)
- 7 not-rely-on-time (accepted — 72-hour challenge period is business requirement)
- 2 gas-strict-inequalities
- 2 other

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 22 raw findings -> 16 unique)
- Pass 6: Report generation

## Conclusion

OmniSybilGuard has **one Critical vulnerability that makes the contract fundamentally incompatible with OmniBazaar**:

1. **Currency mismatch (C-01)** — the contract uses native ETH for all stake/reward operations but the spec requires XOM (ERC-20). On OmniCoin L1, these are different currencies. The entire contract must be refactored to use `IERC20` operations.

2. **Report ID collision (H-01)** can permanently lock reporter stakes when two reports are submitted in the same block.

3. **Reward pool exhaustion deadlock (H-02)** blocks all valid report resolution, permanently locking reporter stakes and leaving confirmed Sybil accounts unflagged.

4. **Missing storage gap (H-03)** is a standard UUPS deployment hazard.

The contract requires a significant refactoring (ETH→XOM migration) before it can serve its intended purpose. The pull-based withdrawal pattern should be adopted simultaneously to resolve M-02. No tests exist for the collision scenario or reward pool exhaustion, which should be considered deployment blockers.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
