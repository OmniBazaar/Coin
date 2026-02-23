# Security Audit Report: StakingRewardPool

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/StakingRewardPool.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 533
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (XOM reward pool)

## Executive Summary

StakingRewardPool is a UUPS upgradeable contract that distributes XOM staking rewards based on time-elapsed APR calculations, reading stake data from an external OmniCore contract. The audit identified **0 Critical, 7 High, 7 Medium, 5 Low, and 4 Informational** findings. The most severe issues are: (1) `emergencyWithdraw()` can drain the entire XOM reward pool with no guard against withdrawing the reward token; (2) `setContracts()` can replace the OmniCore oracle with a malicious contract to fabricate stake data; (3) no upper bound on APR values allows admin to set astronomical rates; (4) a race condition between `snapshotRewards()` and `OmniCore.unlock()` causes permanent reward loss; (5) `_authorizeUpgrade` uses `ADMIN_ROLE` instead of `DEFAULT_ADMIN_ROLE`. The centralization risk is rated **8/10** -- a single compromised `ADMIN_ROLE` key can drain all funds via oracle replacement or malicious upgrade.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 7 |
| Medium | 7 |
| Low | 5 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 79 |
| Passed | 63 |
| Failed | 7 |
| Partial | 9 |
| **Compliance Score** | **80%** |

**Top 5 Failed Checks:**
1. SOL-CR-3: Admin can withdraw entire reward pool including user-owed rewards
2. SOL-CR-4: Admin can change critical protocol properties (APR, oracle address) immediately with no timelock
3. SOL-CR-7: No validation on APR setter functions (no upper bound)
4. SOL-Defi-Staking-3: `snapshotRewards()` callable by anyone for any user
5. SOL-AM-DOSA-2: No minimum claim threshold

## Static Analysis Summary

### Slither
Skipped -- full-project Slither analysis exceeds 10-minute timeout on this codebase.

### Aderyn
Skipped -- Aderyn v0.6.8 crashes with "Fatal compiler bug" against solc v0.8.33.

### Solhint
- **Errors:** 0
- **Warnings:** 3
  - `use-natspec`: Missing @title/@author/@notice on contract (suppressed by `solhint-disable` at line 68)

---

## High Findings

### [H-01] emergencyWithdraw Can Drain the Entire XOM Reward Pool
**Severity:** High
**Category:** SC01 Access Control
**VP Reference:** VP-57 (recoverERC20 Backdoor)
**Location:** `emergencyWithdraw()` (line 445-452)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-CR-3), Solodit (Zunami $500K)

**Description:**
The `emergencyWithdraw()` function allows `DEFAULT_ADMIN_ROLE` to withdraw any token in any amount to any address, including the XOM reward token itself. There is no check that `token != address(xomToken)`, no cap relative to obligations, and no event emitted. A compromised admin can drain the entire pool in a single transaction.

```solidity
function emergencyWithdraw(address token, uint256 amount, address recipient)
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (recipient == address(0)) revert ZeroAddress();
    IERC20(token).safeTransfer(recipient, amount); // Can drain XOM!
}
```

After draining, all `claimRewards()` calls revert with `PoolUnderfunded()`, permanently denying users their accrued rewards.

**Real-World Precedent:** Zunami Protocol (May 2025) -- $500K drained via admin `withdrawStuckToken()` with no token exclusion.

**Recommendation:**
```solidity
function emergencyWithdraw(address token, uint256 amount, address recipient)
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (recipient == address(0)) revert ZeroAddress();
    if (token == address(xomToken)) revert("cannot withdraw reward token");
    IERC20(token).safeTransfer(recipient, amount);
    emit EmergencyWithdrawal(token, amount, recipient);
}
```

---

### [H-02] setContracts Enables Complete Fund Drainage via Oracle Replacement
**Severity:** High
**Category:** SC03 Oracle Manipulation
**VP Reference:** VP-17 (Spot Price Manipulation)
**Location:** `setContracts()` (line 425-436)
**Sources:** Agent-A, Agent-C, Agent-D, Checklist (SOL-CR-4), Solodit (VERY HIGH precedent)

**Description:**
`ADMIN_ROLE` can instantly replace both `omniCore` and `xomToken` with arbitrary addresses. Replacing `omniCore` with a malicious contract that returns fabricated stake data (e.g., `amount = 1e30, tier = 5, active = true`) allows the attacker to call `claimRewards()` and drain the entire pool. No timelock, no multi-sig, no delay.

**Exploit Scenario:**
1. Attacker compromises `ADMIN_ROLE` key
2. Deploys malicious `IOmniCoreStaking` returning fake high-value stakes
3. Calls `setContracts(maliciousOmniCore, xomToken)`
4. Calls `claimRewards()` -- `earned()` returns massive amount from fake stake data
5. Pool drained in a single transaction

**Recommendation:**
Add a 48-hour timelock for contract reference changes, or make addresses immutable after initialization. At minimum, restrict to `DEFAULT_ADMIN_ROLE`.

---

### [H-03] No Upper Bound on APR Values
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-23 (Missing Amount Validation)
**Location:** `setTierAPR()` (line 395-402), `setDurationBonusAPR()` (line 410-417)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-CR-7), Solodit (Paladin Valkyrie)

**Description:**
Both APR setter functions accept any `uint256` value with no upper bound. Per OmniBazaar tokenomics, maximum combined APR is 12% (1200 basis points). An admin setting `tierAPR[1] = 1000000` (10,000%) would allow a staker with even 1 XOM to drain the pool rapidly.

```solidity
tierAPR[tier] = apr; // No cap check!
```

**Recommendation:**
```solidity
uint256 public constant MAX_TOTAL_APR = 1200; // 12% hard cap per tokenomics

function setTierAPR(uint256 tier, uint256 apr) external onlyRole(ADMIN_ROLE) {
    if (tier == 0 || tier > MAX_TIER) revert InvalidTier();
    if (apr > MAX_TOTAL_APR) revert InvalidAmount();
    tierAPR[tier] = apr;
    emit TierAPRUpdated(tier, apr);
}
```

---

### [H-04] Race Condition Between snapshotRewards and OmniCore.unlock Causes Permanent Reward Loss
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Front-Running / Transaction Ordering)
**Location:** `snapshotRewards()` (line 347), interaction with `OmniCore.unlock()`
**Sources:** Agent-A, Agent-C, Solodit (SOL-AM-FrA-2)

**Description:**
The contract design requires `snapshotRewards()` to be called BEFORE `OmniCore.unlock()` to preserve accrued rewards. After unlock, the stake becomes inactive (`active = false`), and `earned()` returns only `frozenRewards[user]` (0 if never snapshotted). All time-accrued rewards are permanently lost if the user forgets or fails to call `snapshotRewards()` first.

**Exploit Scenario:**
1. User stakes 1,000,000 XOM at 12% APR for 1 year
2. After 1 year, accrued rewards = 120,000 XOM
3. User calls `OmniCore.unlock()` directly without `snapshotRewards()`
4. Stake becomes inactive; `earned(user)` returns 0
5. 120,000 XOM in rewards permanently lost

**Recommendation:**
Have `OmniCore.unlock()` call `StakingRewardPool.snapshotRewards(msg.sender)` automatically before clearing the stake. Alternatively, add a `claimFrozenOnly()` function and modify `_computeAccrued()` to handle recently-deactivated stakes by caching the last-known stake data.

---

### [H-05] _authorizeUpgrade Uses ADMIN_ROLE Instead of DEFAULT_ADMIN_ROLE
**Severity:** High
**Category:** SC10 Upgrade Safety
**VP Reference:** VP-42 (Upgrade Safety)
**Location:** `_authorizeUpgrade()` (line 530-532)
**Sources:** Agent-A, Agent-C, Solodit (SOL-Basics-PU-4)

**Description:**
Contract upgrades are the most powerful operation -- they can replace all logic and drain all funds. The function uses `ADMIN_ROLE` (a secondary role) instead of `DEFAULT_ADMIN_ROLE` (the root role). Combined with H-06, if `ADMIN_ROLE` is held by a single EOA while `DEFAULT_ADMIN_ROLE` is transferred to a timelock, that EOA retains unilateral upgrade capability.

**Recommendation:**
```solidity
function _authorizeUpgrade(
    address newImplementation
) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
```

---

### [H-06] Admin Transfer Script Doesn't Transfer ADMIN_ROLE to Timelock
**Severity:** High
**Category:** Centralization Risk (Deployment)
**VP Reference:** VP-06 (Missing Access Control)
**Location:** `scripts/transfer-admin-to-timelock.js`
**Sources:** Agent-C, Solodit (HIGH precedent)

**Description:**
The admin transfer script only transfers `DEFAULT_ADMIN_ROLE` to the TimelockController. `ADMIN_ROLE` remains with the deployer EOA, giving that single key the ability to:
- Upgrade the contract to malicious code via `_authorizeUpgrade` (H-05)
- Replace the OmniCore oracle via `setContracts` (H-02)
- Set APR to extreme values via `setTierAPR` (H-03)

This completely undermines the purpose of the timelock.

**Recommendation:**
Update the admin transfer script to:
1. Grant `ADMIN_ROLE` to the timelock address
2. Revoke `ADMIN_ROLE` from the deployer
3. Verify both transfers completed

---

### [H-07] OmniCore Unvalidated Tier Allows Reward Rate Inflation
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_computeAccrued()` (line 485)
**Sources:** Agent-B

**Description:**
The reward calculation blindly trusts `stakeData.tier` from OmniCore:
```solidity
uint256 effectiveAPR = _getEffectiveAPR(stakeData.tier, stakeData.duration);
```

OmniCore's `stake()` function accepts arbitrary tier values without validating them against the staked amount. A user can stake 1 XOM with `tier = 5` and receive 9% APR instead of the correct 5% for Tier 1 (1-999K XOM range). A Sybil attack with thousands of addresses staking minimal amounts at maximum tier drains the pool at 1.8x the intended rate.

Per OmniBazaar tokenomics:
- Tier 1: 1 - 999,999 XOM = 5% APR
- Tier 5: 1,000,000,000+ XOM = 9% APR

**Recommendation:**
Add independent tier validation in StakingRewardPool:
```solidity
function _clampTier(uint256 amount, uint256 declaredTier) internal pure returns (uint256) {
    if (amount >= 1_000_000_000e18) return 5;
    if (amount >= 100_000_000e18) return 4;
    if (amount >= 10_000_000e18) return 3;
    if (amount >= 1_000_000e18) return 2;
    if (amount >= 1e18) return 1;
    return 0;
}
```

---

## Medium Findings

### [M-01] claimRewards Reverts Entirely if Pool Underfunded
**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Unexpected Revert)
**Location:** `claimRewards()` (line 326)
**Sources:** Agent-A, Checklist (partial), Solodit (Pashov Resolv L-08, CodeHawks RAAC)

**Description:**
If `poolBalance < reward`, the entire claim reverts. A user owed 1000 XOM cannot claim even if the pool has 999 XOM. Rewards continue accruing during underfunding, making the gap larger over time.

**Recommendation:**
Allow partial claims: `if (reward > poolBalance) reward = poolBalance;`

---

### [M-02] OmniCore Unavailability Blocks All Claims Including Frozen Rewards
**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Unexpected Revert)
**Location:** `earned()` (line 279)
**Sources:** Agent-A, Agent-D, Checklist (partial SOL-AM-DOSA-6), Solodit (VERY HIGH)

**Description:**
`earned()` calls `omniCore.getStake(user)` without try/catch. If OmniCore is paused, upgraded incorrectly, or self-destructed, all reward calculations revert. Users with `frozenRewards > 0` cannot claim even their already-frozen rewards.

**Recommendation:**
Wrap in try/catch and fall back to frozen-only:
```solidity
function earned(address user) public view returns (uint256) {
    uint256 frozen = frozenRewards[user];
    try omniCore.getStake(user) returns (IOmniCoreStaking.Stake memory stakeData) {
        if (!stakeData.active || stakeData.amount == 0) return frozen;
        return frozen + _computeAccrued(user, stakeData);
    } catch {
        return frozen;
    }
}
```

---

### [M-03] No Pause Mechanism
**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Missing Safety Feature)
**Location:** Contract-wide
**Sources:** Agent-B, Checklist (partial SOL-CR-2), Solodit (HIGH)

No way to halt operations during an emergency. The only response to a discovered vulnerability is a full UUPS upgrade, which requires deploying new code.

**Recommendation:** Import `PausableUpgradeable` and add `whenNotPaused` to `claimRewards()`, `snapshotRewards()`, and `depositToPool()`.

---

### [M-04] APR Change Front-Running via snapshotRewards
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Front-Running)
**Location:** `setTierAPR()` (line 395), `snapshotRewards()` (line 347)
**Sources:** Agent-D, Solodit (SOL-AM-FrA-2)

**Description:**
An attacker monitoring the mempool can front-run an admin's APR reduction by calling `snapshotRewards()` to lock in rewards at the higher rate before the change takes effect.

**Recommendation:** Implement a 24-48 hour timelock on APR changes. Alternatively, snapshot all active stakers before APR changes take effect.

---

### [M-05] Duration Tier Boundary Uses Range Instead of Exact Match
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_getDurationTier()` (line 518-523)
**Sources:** Agent-B

**Description:**
Per tokenomics, duration bonuses are for specific commitments (0, 1 month, 6 months, 2 years). The implementation uses range-based comparison, allowing `duration = 31 days` to get the +1% bonus intended for 30-day commitments. Users can game by locking for the minimum qualifying duration.

**Recommendation:** Validate exact durations in OmniCore, or document range-based behavior as intentional.

---

### [M-06] emergencyWithdraw Emits No Event
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `emergencyWithdraw()` (line 445-452)
**Sources:** Agent-C, Solodit (transparency pattern)

Emergency fund movements should always be logged for monitoring and forensic analysis. Without an event, off-chain monitoring cannot detect unauthorized withdrawals.

**Recommendation:** Add `emit EmergencyWithdrawal(token, amount, recipient);`

---

### [M-07] _computeAccrued Potential Underflow on Malformed Stake Data
**Severity:** Medium
**Category:** SC07 Arithmetic
**VP Reference:** VP-12 (Integer Underflow)
**Location:** `_computeAccrued()` (line 470)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D

**Description:**
`stakeStart = stakeData.lockTime - stakeData.duration` underflows (reverts) if `lockTime < duration`. This depends on OmniCore maintaining the invariant `lockTime = block.timestamp + duration`. If OmniCore is replaced via `setContracts()` with different semantics, affected users' rewards become permanently unclaimable.

**Recommendation:** Add: `if (stakeData.lockTime < stakeData.duration) return 0;`

---

## Low Findings

### [L-01] snapshotRewards Callable by Anyone for Any User
**Location:** `snapshotRewards()` (line 347)

The function has no access control. While mathematical analysis shows the total reward is invariant to repeated calls (frozen + accrued remains constant), it is unusual for a state-changing function to be fully permissionless. The design is intentional (allows OmniCore or helpers to snapshot before unlock) but should be explicitly documented.

---

### [L-02] Fee-on-Transfer Token Accounting Mismatch
**Location:** `depositToPool()` (line 376-383)

`totalDeposited += amount` assumes the full amount is received. If XOM were ever migrated to a fee-on-transfer variant, the counter would overcount. Use balance-before/after pattern for defensive coding.

---

### [L-03] Floating Pragma on Upgradeable Contract
**Location:** Line 2

`pragma solidity ^0.8.19` allows different compiler versions for proxy vs implementation. Lock to a specific version for deployment.

---

### [L-04] No Per-Claim Reward Cap
**Location:** `claimRewards()` (line 321)

No maximum per-claim limit. If APR is misconfigured (H-03) or OmniCore is replaced (H-02), a single claim can drain the entire pool. A per-claim cap would limit blast radius.

---

### [L-05] Missing Zero-Address Checks
**Location:** `snapshotRewards()` (line 347), `emergencyWithdraw()` (line 445)

`snapshotRewards(address(0))` and `emergencyWithdraw(address(0), ...)` are not validated. Both would fail at the EVM level but with opaque errors.

---

## Informational Findings

### [I-01] totalDeposited/totalDistributed Not Used On-Chain
**Location:** Lines 128-131

Both counters are updated on deposits and claims but never read by any on-chain logic. They exist for off-chain monitoring only, consuming extra SSTORE gas on every operation.

---

### [I-02] Excessive Event Parameter Indexing
**Location:** Events at lines 144-168

`RewardsClaimed`, `RewardsSnapshot`, and `PoolDeposit` index all three parameters including `amount` and `timestamp`, which are rarely filtered on. Only `user`/`depositor` should be indexed; `amount` and `timestamp` should be non-indexed data.

---

### [I-03] Storage Gap Documentation
**Location:** Line 134

The `uint256[44] private __gap` provides adequate headroom. Document the slot budget above `__gap`: "Reduce by N when adding N new state variables."

---

### [I-04] Missing Early Withdrawal Penalty Mechanism
**Location:** Contract-wide (absent feature)

Per OmniBazaar tokenomics, early withdrawal carries a "substantial penalty." Neither OmniCore nor StakingRewardPool implements this feature. Users who locked tokens simply cannot unlock early -- the feature described in the spec is entirely missing.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Zunami Protocol | 2025-05 | $500K | Admin `withdrawStuckToken()` with no token exclusion -- identical to H-01 |
| SafeMoon | 2023-03 | $8.9M | Unprotected function to drain funds -- similar to H-01 |
| Beanstalk | 2022-04 | $182M | Flash loan governance via current-balance dependency -- analogous to H-02 oracle trust |
| Spartan Protocol | 2021-05 | $30.5M | Pool share calculation logic flaw -- analogous to H-03 APR manipulation |
| Popsicle Finance | 2021-08 | $20M | Repeated reward claim via cross-function state sharing |
| GMX | 2025-07 | $41M | Share price manipulation of trading protocol |

## Solodit Similar Findings

- **SOL-AM-RP-1 (Rug Pull):** emergencyWithdraw drains pool -- matches Zunami Protocol incident
- **SOL-CR-4 (No Timelock):** setContracts/setTierAPR changes take effect immediately
- **SOL-AM-FrA-2 (Front-Running):** snapshotRewards/unlock race condition; APR change front-running
- **SOL-Basics-PU-4 (Upgrade Auth):** _authorizeUpgrade uses wrong role
- **SOL-AM-DOSA-6 (External DoS):** OmniCore unavailability blocks all claims
- **Pashov Resolv L-08:** Reward loss if transfer fails -- similar to M-01 underfunded revert
- **Cyfrin Paladin Valkyrie (CRITICAL):** Permissionless reward distribution manipulation

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `emergencyWithdraw()`, grant/revoke all roles | 9/10 |
| ADMIN_ROLE | `setTierAPR()`, `setDurationBonusAPR()`, `setContracts()`, `_authorizeUpgrade()` | 9/10 |
| Anyone | `claimRewards()`, `snapshotRewards()`, `depositToPool()`, `earned()` | 1/10 |

## Centralization Risk Assessment

**Centralization Rating: 8/10 (High -- single-key total fund loss)**

**Single-key maximum damage (ADMIN_ROLE):**
1. Replace OmniCore with malicious contract, claim fabricated rewards (drain pool)
2. Set APR to extreme value, claim inflated rewards (drain pool)
3. Upgrade contract to malicious implementation (steal all tokens)

**Single-key maximum damage (DEFAULT_ADMIN_ROLE):**
All of above plus:
4. Call `emergencyWithdraw()` to directly extract all XOM
5. Grant attacker `ADMIN_ROLE`, revoke legitimate holders

**Time to exploit:** Immediate -- no timelock in contract.

**Recommendation:** Transfer both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` to a TimelockController with minimum 48-hour delay. Use multi-sig for the timelock proposer.

## Remediation Priority

| Priority | ID | Finding | Effort |
|----------|----|---------|--------|
| 1 | H-01 | emergencyWithdraw can drain pool | Low (add token exclusion) |
| 2 | H-05 | _authorizeUpgrade wrong role | Low (change to DEFAULT_ADMIN_ROLE) |
| 3 | H-06 | Admin script missing ADMIN_ROLE transfer | Low (update script) |
| 4 | H-03 | No APR cap | Low (add constant + check) |
| 5 | H-02 | setContracts no timelock | Medium (add timelock pattern) |
| 6 | H-04 | snapshotRewards/unlock race | Medium (auto-snapshot in unlock) |
| 7 | H-07 | Unvalidated tier from OmniCore | Medium (add clampTier) |
| 8 | M-02 | OmniCore DoS blocks claims | Low (add try/catch) |
| 9 | M-01 | No partial claims | Low (cap to pool balance) |
| 10 | M-06 | No event on emergencyWithdraw | Low (add event) |
| 11 | M-03 | No pause mechanism | Low (import Pausable) |
| 12 | M-07 | Underflow on malformed data | Low (add safety check) |
| 13 | M-04 | APR change front-running | Medium (timelock) |
| 14 | M-05 | Duration tier range vs exact | Medium (design decision) |

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
