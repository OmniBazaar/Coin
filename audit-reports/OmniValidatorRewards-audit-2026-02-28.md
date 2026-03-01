# Security Audit Report: OmniValidatorRewards

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniValidatorRewards.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,739
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (block rewards distribution to validators)

## Executive Summary

OmniValidatorRewards is a UUPS-upgradeable contract that distributes block rewards to validators based on a weighted participation model (40% uptime/30% staking/30% participation). The contract processes epochs sequentially, calculates per-validator weights, and distributes rewards via a pull-based claim mechanism. It includes a 48-hour timelock for contract reference changes and an ossification mechanism. One HIGH-severity finding was confirmed by all audit sources: the `emergencyWithdraw()` XOM guard can be bypassed via the `proposeContracts()` mechanism. Business logic verification confirmed the block reward schedule, weight calculations, and staking tier mappings all match the OmniBazaar specification.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 5 |
| Low | 3 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 119 |
| Passed | 99 |
| Failed | 5 |
| Partial | 15 |
| **Compliance Score** | **83%** |

Top 5 failed checks:
1. SOL-AM-RP-1: Admin can pull assets via emergencyWithdraw XOM guard bypass
2. SOL-Basics-PU-7: Constant values embedded in bytecode cannot be validated during upgrades
3. SOL-Basics-AC-4: Single-step admin role transfer (no two-step)
4. SOL-AM-DOSA-2: No minimum transaction amount in `recordTransactionProcessing()`
5. SOL-CR-2: `claimRewards()` blocked during pause with no emergency bypass

---

## High Findings

### [H-01] emergencyWithdraw() XOM Guard Bypass via Contract Reference Swap
**Severity:** High
**Category:** Access Control / Business Logic
**VP Reference:** VP-06 (Missing Access Control Safeguard)
**Location:** `emergencyWithdraw()` (line 1000), `proposeContracts()`/`applyContracts()` (lines 861-925)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin Checklist (SOL-AM-RP-1)

**Description:**
The `emergencyWithdraw()` function guards against draining XOM rewards by checking `if (token == address(xomToken)) revert CannotWithdrawXOM()`. However, the `proposeContracts()` function allows the admin to change the `xomToken` reference to a different address. After the 48-hour timelock, `applyContracts()` updates `xomToken` to the new address. At that point, calling `emergencyWithdraw(originalXOMAddress)` passes the guard because `originalXOMAddress != address(newXomToken)`.

**Exploit Scenario:**
1. Admin calls `proposeContracts(dummyToken, currentCore, currentParticipation)`
2. Wait 48 hours for timelock to expire
3. Admin calls `applyContracts()` — `xomToken` now points to dummy
4. Admin calls `emergencyWithdraw(originalXOM, adminAddress)` — passes the guard
5. All validator reward funds are drained

**Recommendation:**
Store the original XOM address as an immutable or maintain a separate `rewardToken` that cannot be changed:
```solidity
address private immutable _originalXomToken;

constructor() { _disableInitializers(); }

function initialize(...) public initializer {
    _originalXomToken = address(_xomToken);
    // ...
}

function emergencyWithdraw(address token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (token == address(xomToken) || token == _originalXomToken) revert CannotWithdrawXOM();
    // ...
}
```

---

## Medium Findings

### [M-01] ROLE_MANAGER Can Concentrate Rewards via roleMultiplier
**Severity:** Medium
**Category:** Access Control / Centralization
**VP Reference:** VP-06 (Access Control)
**Location:** `setRoleMultiplier()` (line 1053), `_computeEpochWeights()` (line 1464)
**Sources:** Agent-B, Agent-C, Cyfrin Checklist (SOL-CR-4)

**Description:**
The `ROLE_MANAGER` role can set `roleMultiplier` up to 20000 (2.0x) for any validator, immediately taking effect with no timelock. This doubles a validator's reward weight, concentrating rewards toward favored validators at the expense of others. Combined with the `PENALTY_ROLE` which can suppress competitor weights to 1/100, a colluding admin pair can redirect the majority of block rewards.

**Recommendation:**
Add a timelock for multiplier changes or cap the multiplier at 1.5x (15000 bps). Require multiplier changes to go through the existing `proposeContracts` timelock mechanism.

---

### [M-02] PENALTY_ROLE Can Suppress Validator Rewards Indefinitely
**Severity:** Medium
**Category:** Access Control / Centralization
**VP Reference:** VP-06 (Access Control)
**Location:** `setRewardMultiplier()` (line 1023)
**Sources:** Agent-B, Cyfrin Checklist (SOL-CR-4)

**Description:**
The `PENALTY_ROLE` can set a validator's `rewardMultiplier` to 1 (effectively 1/100 of normal rewards) with no time limit, cooldown, or appeal mechanism. While penalties are a legitimate governance function, indefinite penalty without decay or review creates centralization risk. A compromised `PENALTY_ROLE` key could permanently suppress honest validators.

**Recommendation:**
Implement penalty decay (auto-reset after N epochs) or require periodic renewal. Add a `MAX_PENALTY_DURATION` constant.

---

### [M-03] Stale Validator State During Batch Epoch Processing
**Severity:** Medium
**Category:** Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `processMultipleEpochs()` (line 749)
**Sources:** Agent-A, Cyfrin Checklist (PARTIAL SOL-AM-DOSA-6)

**Description:**
`processMultipleEpochs()` calls `omniCore.getActiveNodes()` once and uses the same validator list for up to 50 sequential epochs. If the validator set changed during this period (validators joined/left), intermediate epochs use stale validator data. The heartbeat and staking data is also fetched per-epoch via the same snapshot, which may not reflect reality at the actual epoch timestamp.

**Recommendation:**
Document this as accepted behavior for catch-up scenarios, or re-fetch the validator list every N epochs within the batch. The staleness window is bounded to 100 seconds (50 epochs × 2 seconds), which is generally acceptable.

---

### [M-04] BLOCKCHAIN_ROLE Can Inflate Transaction Counts
**Severity:** Medium
**Category:** Access Control
**VP Reference:** VP-06 (Access Control)
**Location:** `recordTransactionProcessing()` (line 629), `recordMultipleTransactions()` (line 652)
**Sources:** Agent-B, Cyfrin Checklist (SOL-AM-DOSA-2)

**Description:**
The `BLOCKCHAIN_ROLE` can call `recordTransactionProcessing()` and `recordMultipleTransactions()` with no minimum value or deduplication. A compromised `BLOCKCHAIN_ROLE` holder could inflate a specific validator's `transactionsProcessed` count, gaming the activity weight component (30% of total weight). There is no validation that the transactions being recorded are genuine.

**Recommendation:**
Add a maximum transactions-per-epoch cap per validator, or require transaction hashes for deduplication. This is mitigated by the trust model (BLOCKCHAIN_ROLE is held by the consensus system) but represents a single-key risk.

---

### [M-05] claimRewards() Blocked During Pause With No Emergency Bypass
**Severity:** Medium
**Category:** Business Logic / Centralization
**VP Reference:** VP-30 (DoS via Revert)
**Location:** `claimRewards()` (line 824)
**Sources:** Cyfrin Checklist (SOL-CR-2)

**Description:**
The `claimRewards()` function uses the `whenNotPaused` modifier. When the contract is paused (e.g., during an emergency), validators cannot claim earned rewards. If the admin key is lost while paused, or if the admin maliciously pauses indefinitely, validator funds are permanently locked. There is no emergency claim function that bypasses the pause.

**Recommendation:**
Either remove `whenNotPaused` from `claimRewards()` (rewards are already earned, claiming is a withdrawal) or add an `emergencyClaimRewards()` function with a separate guardian key.

---

## Low Findings

### [L-01] Rounding Dust Accumulation in Reward Distribution
**Severity:** Low
**VP Reference:** VP-15 (Rounding Direction)
**Location:** `_distributeRewards()` (line 1622)
**Sources:** Agent-A, Cyfrin Checklist (PARTIAL SOL-Basics-AL-12)

**Description:**
The formula `(epochReward * weights[i]) / totalWeight` truncates fractionally, causing the sum of individual rewards to be slightly less than `epochReward`. Over millions of epochs, this dust accumulates as a small deficit in `totalOutstandingRewards`. The impact is negligible in practice but theoretically causes a very slight underpayment to the last validator in each epoch.

---

### [L-02] roleMultiplier Values 1-10000 Are Silent No-Ops
**Severity:** Low
**VP Reference:** VP-22 (Input Validation)
**Location:** `setRoleMultiplier()` (line 1053), `_computeEpochWeights()` (line 1464)
**Sources:** Agent-B, Cyfrin Checklist (PARTIAL SOL-Basics-Function-5)

**Description:**
`setRoleMultiplier()` accepts values from 0 to 20000. Values 0 and 10000 both behave identically (1.0x multiplier). Values 1-9999 are accepted but effectively penalize validators (< 1.0x multiplier), which is counter to the stated purpose of providing role bonuses. The function should validate that values are either 0 (unset) or >= 10000.

---

### [L-03] getActiveNodes() Memory Allocation Not Capped
**Severity:** Low
**VP Reference:** VP-29 (Unbounded Loop)
**Location:** `processEpoch()` (line 700)
**Sources:** Agent-A, Cyfrin Checklist (PARTIAL SOL-Basics-AL-9)

**Description:**
`omniCore.getActiveNodes()` returns an unbounded array into memory. Although processing is capped at `MAX_VALIDATORS_PER_EPOCH` (200), the full memory allocation occurs before the cap is applied. If OmniCore returns thousands of addresses, the memory cost could be significant.

---

## Informational Findings

### [I-01] NonReentrant Modifier Not First in Modifier Chain
**Severity:** Informational
**Location:** `processEpoch()` (line 683), `processMultipleEpochs()` (line 754)
**Sources:** Cyfrin Checklist (PARTIAL SOL-Heuristics-4)

**Description:**
Best practice places `nonReentrant` before all other modifiers. The current order is `onlyRole(BLOCKCHAIN_ROLE) nonReentrant whenNotPaused`. While `onlyRole` makes no external calls, reordering to `nonReentrant` first is defensive.

---

### [I-02] Single-Step Admin Role Transfer
**Severity:** Informational
**Location:** Inherited from AccessControlUpgradeable
**Sources:** Cyfrin Checklist (SOL-Basics-AC-4)

**Description:**
`DEFAULT_ADMIN_ROLE` can be transferred in one step via `grantRole()`. A typo in the new admin address permanently loses admin access. Consider using `AccessControlDefaultAdminRulesUpgradeable` from OpenZeppelin v5.x for two-step admin transfer.

---

### [I-03] Division-Before-Multiplication in Activity Component
**Severity:** Informational
**Location:** `_calculateActivityComponent()` (lines 1583-1596)
**Sources:** Cyfrin Checklist (PARTIAL SOL-Basics-Math-4)

**Description:**
The computation `hScore * HEARTBEAT_SUBWEIGHT / 100` followed by `activityScore * ACTIVITY_WEIGHT / 100` applies two sequential truncating divisions. With values in the 0-100 range, this can lose up to 2-3 points of precision. Consider accumulating the full numerator before dividing.

---

## Business Logic Verification

| Component | Status | Notes |
|-----------|--------|-------|
| Block reward schedule | **MATCHES** | 15.602 XOM/block, 1% reduction per 6,311,520 blocks |
| Weight calculation | **MATCHES** | 40% uptime, 30% staking, 30% participation |
| Staking tier mapping | **MATCHES** | 5 tiers (1-999K through 1B+) |
| Duration bonus mapping | **MATCHES** | 4 tiers (0% to +3%) |
| Heartbeat timeout | **MATCHES** | 20-second timeout |
| MAX_VALIDATORS_PER_EPOCH | **MATCHES** | Capped at 200 |
| Epoch duration | **MATCHES** | 2-second blocks |
| Zero reward epoch | **MATCHES** | After 631,152,000 blocks (~40 years) |
| Ossification mechanism | **CORRECT** | Permanently freezes admin functions |
| 48-hour timelock | **CORRECT** | For contract reference changes |

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | pause, unpause, emergencyWithdraw, proposeContracts, applyContracts, cancelPendingContracts, proposeUpgrade, ossify | 7/10 |
| BLOCKCHAIN_ROLE | processEpoch, processMultipleEpochs, recordTransactionProcessing, recordMultipleTransactions | 5/10 |
| VALIDATOR_ROLE | submitHeartbeat | 2/10 |
| PENALTY_ROLE | setRewardMultiplier | 4/10 |
| ROLE_MANAGER_ROLE | setRoleMultiplier | 4/10 |

## Centralization Risk Assessment

**Pre-ossification:** 7/10 — Admin can change contract references (with 48h timelock), pause the contract, and withdraw non-XOM tokens. The emergencyWithdraw XOM bypass (H-01) elevates this to 7/10.

**Post-ossification:** 4/10 — Most admin functions are permanently disabled. PENALTY_ROLE and ROLE_MANAGER_ROLE remain active and can influence reward distribution.

**Single-key maximum damage:** Admin can drain all XOM rewards via H-01 bypass. Fix H-01 to reduce to "can pause indefinitely, blocking claims."

**Recommendation:** Fix H-01 immediately. Transfer DEFAULT_ADMIN_ROLE to a multi-sig. Consider requiring PENALTY_ROLE and ROLE_MANAGER_ROLE to be held by governance contract.

## Static Analysis Summary

### Slither
Slither full-project analysis timed out (>5 minutes). Findings filtered from prior run did not reveal additional issues beyond those caught by LLM agents.

### Aderyn
Aderyn crashed with internal error on import resolution (v0.6.8). Noted and continued with LLM analysis.

### Solhint
0 errors, 1 warning:
- Line 1610: Function ordering — internal function after internal view function

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
