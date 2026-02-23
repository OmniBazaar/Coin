# Security Audit Report: OmniValidatorRewards

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniValidatorRewards.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 757
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (holds XOM for validator reward distribution)

## Executive Summary

OmniValidatorRewards is a UUPS-upgradeable contract that distributes XOM block rewards to validators based on a weighted score system (40% participation, 30% staking, 30% activity). It uses epoch-based processing at 2-second intervals with a 40-year emission schedule of ~6.089 billion XOM.

The audit found **2 Critical vulnerabilities**: (1) `processEpoch()` allows arbitrary epoch skipping, permanently destroying rewards for skipped epochs, and (2) `emergencyWithdraw()` combined with UUPS upgrade authority gives the admin two independent paths to drain all funds with no timelock or multi-sig. Additionally, a **High-severity flash-stake attack** allows inflating staking weight with zero lock commitment, and **setContracts()** allows instant redirection of all oracle dependencies to malicious contracts. All 4 independent audit agents confirmed the epoch-skipping vulnerability as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 5 |
| Medium | 7 |
| Low | 3 |
| Informational | 2 |

## Findings

### [C-01] Epoch Skipping Grief Attack — Permanent Reward Destruction

**Severity:** Critical
**Lines:** 362-420 (line 365)
**Agents:** All 4 (2A, 2B, 2C, 2D — unanimously confirmed)

**Description:**

`processEpoch(uint256 epoch)` requires only `epoch > lastProcessedEpoch` (line 365), not `epoch == lastProcessedEpoch + 1`. Any caller can skip arbitrary epochs. The function is permissionless — no access control. Skipped epochs' rewards are permanently lost because `lastProcessedEpoch` advances past them.

Furthermore, `totalBlocksProduced` increments by only 1 per call (line 416), desynchronizing the reward reduction schedule from wall-clock time.

**Proof of Concept:**
```
1. lastProcessedEpoch = 0, 1 day passes (43,200 two-second epochs)
2. Attacker calls processEpoch(43200)
3. Only epoch 43,200 is processed; epochs 1-43,199 are permanently skipped
4. Lost: 43,199 × 15.602 XOM = 673,990 XOM destroyed
5. Cost: gas for one transaction
```

**Impact:** Anyone can permanently destroy the validator reward program for the cost of gas. At 15.602 XOM/epoch, skipping 1 day destroys ~674K XOM.

**Recommendation:** Enforce sequential processing:
```solidity
if (epoch != lastProcessedEpoch + 1) revert EpochNotSequential();
```

---

### [C-02] Admin Has Two Independent Fund-Drain Paths Without Timelock

**Severity:** Critical
**Lines:** 737-744 (emergencyWithdraw), 754-756 (_authorizeUpgrade)
**Agents:** 2A, 2B, 2C, 2D (all confirmed independently)

**Description:**

**Path 1 — emergencyWithdraw:** Admin can call `emergencyWithdraw(xomToken, fullBalance, adminAddress)` to drain all XOM including accumulated validator rewards. No timelock, no multi-sig, no accounting check, and no event emission.

**Path 2 — UUPS Upgrade:** Admin can upgrade to a malicious implementation that drains all funds in its initializer. `_authorizeUpgrade` has an empty body beyond the role check.

The contract managing 6.089 billion XOM over 40 years has a single-key rug-pull vector. The deployer receives both `DEFAULT_ADMIN_ROLE` and `BLOCKCHAIN_ROLE` (line 269-270).

**Impact:** Complete loss of all validator reward funds via admin key compromise.

**Recommendation:**
1. Add timelock (48-72h) for withdrawals and upgrades
2. Restrict `emergencyWithdraw` to non-XOM tokens, or enforce `balance - totalOwed` cap
3. Transfer admin to multi-sig wallet
4. Add `PausableUpgradeable` for incident response

---

### [H-01] Flash-Stake Weight Inflation via Zero-Duration Staking

**Severity:** High
**Lines:** 550-577 (+ OmniCore 375-422)
**Agent:** 2D

**Description:**

`_calculateStakingComponent()` reads the current stake from OmniCore. OmniCore's `stake()` accepts `duration = 0` (lockTime = block.timestamp), and `unlock()` checks `block.timestamp < lockTime` — which is false immediately, allowing same-block unstake.

An attacker with a large XOM balance can: stake 10B XOM (duration=0) → process epoch (get max 30-point staking weight) → unlock → repeat every epoch. No capital lockup required.

**Impact:** Attacker achieves maximum staking weight while bearing zero lock-up risk, diluting honest validators' rewards.

**Recommendation:** In `_calculateStakingComponent`, require `stake.lockTime > block.timestamp`:
```solidity
if (stake.lockTime <= block.timestamp) return 0;
```

---

### [H-02] setContracts Enables Instant Oracle Manipulation

**Severity:** High
**Lines:** 715-729
**Agents:** All 4

**Description:**

Admin can replace `participation`, `omniCore`, and `xomToken` with malicious contracts that fabricate validator lists, inflate scores, and redirect transfers. No timelock, no multi-sig. Attack is instant and reversible (swap back to hide tracks).

**Impact:** Complete control over reward distribution — 100% of rewards redirected to attacker.

**Recommendation:** Add timelock or make oracle references immutable (changes only via UUPS upgrade).

---

### [H-03] Unbounded Validator Iteration — Gas DoS

**Severity:** High
**Lines:** 362-420, 427-482
**Agents:** 2A, 2B, 2D

**Description:**

`processEpoch()` iterates ALL validators 3 times (count, weights, distribute), each calling external contracts. `processMultipleEpochs()` calls `getActiveNodes()` inside the loop. With a large validator set, gas exceeds block limits, making epoch processing impossible.

**Impact:** If the validator set grows sufficiently, epoch processing halts permanently, freezing all reward distribution.

**Recommendation:** Single-pass iteration, cache `getActiveNodes()` outside loops, add `MAX_BATCH_SIZE` for `processMultipleEpochs`.

---

### [H-04] Removed Validators Forfeit Unclaimed Rewards

**Severity:** High
**Lines:** 492-493
**Agents:** 2B, 2C

**Description:**

`claimRewards()` requires `omniCore.isValidator(msg.sender)`. If a validator is deactivated (voluntarily or by admin via `setContracts`), their accumulated rewards are permanently inaccessible. No grace period, no admin-assisted claim.

**Impact:** Permanent loss of earned rewards for retired, migrated, or removed validators. Growing pool of locked XOM.

**Recommendation:** Remove the `isValidator` check from `claimRewards()` — rewards can only be accumulated for addresses that were validators during `processEpoch()`, so the check is redundant for security.

---

### [H-05] BLOCKCHAIN_ROLE Can Inflate Transaction Counts Without Limits

**Severity:** High
**Lines:** 340-351
**Agents:** 2C, 2B

**Description:**

`recordMultipleTransactions(validator, count)` has no cap on `count`. A compromised BLOCKCHAIN_ROLE holder can call with `type(uint256).max` to give one validator 100% of transaction-processing weight (12% of total reward weight).

**Impact:** Systematic reward skewing toward chosen validators.

**Recommendation:** Add per-call and per-epoch caps on `count`.

---

### [M-01] Missing Storage Gap (__gap) for UUPS Upgrades

**Severity:** Medium
**Lines:** 137-176
**Agent:** 2C

**Description:**

Every other UUPS contract in the codebase has a storage gap (OmniCore: `[49]`, PrivateOmniCoin: `[46]`, OmniPrivacyBridge: `[44]`, etc.). OmniValidatorRewards is the only one missing it. Future upgrades adding state variables could corrupt mapping storage slots.

**Recommendation:** Add `uint256[40] private __gap;` after the last state variable.

---

### [M-02] Block Count vs Time Desynchronization Inflates Emissions

**Severity:** Medium
**Lines:** 416, 623-624
**Agents:** 2B, 2D

**Description:**

`totalBlocksProduced` only increments by 1 per `processEpoch` call, but `getCurrentEpoch()` advances based on wall-clock time. If epochs are processed infrequently, the reduction schedule (based on `totalBlocksProduced`) is delayed, keeping rewards at the higher initial rate longer than intended.

**Recommendation:** Base reward reduction on epoch number (time-based) rather than `totalBlocksProduced`.

---

### [M-03] Batch Processing Uses Current State for Historical Epochs

**Severity:** Medium
**Lines:** 427-482
**Agents:** 2A, 2C, 2D

**Description:**

`processMultipleEpochs()` evaluates heartbeats and participation scores at current `block.timestamp`, not at the historical epoch's time. Validators who were active during past epochs but are currently offline receive nothing; newly-joined validators retroactively receive rewards for epochs they weren't part of.

**Recommendation:** Enforce small batch sizes (max 10-50 epochs) and document the limitation. Consider epoch-specific state snapshots.

---

### [M-04] Staking Score Step Function Creates Unfair Cliff Effects

**Severity:** Medium
**Lines:** 561-574
**Agent:** 2B

**Description:**

Staking score uses a step function: 1M XOM = 20, 10M = 40, 100M = 60, 1B = 80, 10B = 100. A validator staking 9.99M XOM gets the same score (20) as one staking 1M. But 10M gets double (40). This creates perverse incentives to cluster at exact tier boundaries.

**Recommendation:** Use continuous logarithmic scaling or linear interpolation between tiers.

---

### [M-05] Heartbeat Gaming — Full Score for Minimal Effort

**Severity:** Medium
**Lines:** 592, 309-312
**Agent:** 2B

**Description:**

Heartbeat score is binary: 100 or 0. A validator submitting heartbeats every 19 seconds (costing only gas) gets the same 100% score as one with continuous uptime. Heartbeats represent 18% of total reward weight but prove nothing about actual validation work.

**Recommendation:** Use time-weighted uptime tracking or require proof-of-work in heartbeats.

---

### [M-06] No Pause Mechanism

**Severity:** Medium
**Lines:** Entire contract
**Agent:** 2C

**Description:**

No `PausableUpgradeable` inheritance. During a security incident, admin can only drain funds or emergency upgrade — neither cleanly halts operations.

**Recommendation:** Add `PausableUpgradeable` with `whenNotPaused` on all public functions.

---

### [M-07] Front-Running Epoch Processing

**Severity:** Medium
**Lines:** 362
**Agent:** 2A

**Description:**

`processEpoch()` is permissionless. Attackers can front-run to process epochs before a validator's heartbeat lands, denying them rewards for that epoch. The 2-second epoch duration makes timing windows tight.

**Recommendation:** Restrict to `BLOCKCHAIN_ROLE` or add a minimum delay before epoch can be processed.

---

### [L-01] Block Reward Truncation at Period 100

**Severity:** Low
**Lines:** 623-639
**Agent:** 2D

**Description:**

`calculateBlockReward()` returns 0 after `MAX_REDUCTIONS = 100`. Mathematically, `15.602 × 0.99^100 = 5.71 XOM`, not 0. The NatSpec comment acknowledges "~5.6 XOM" but code returns 0.

**Recommendation:** Either continue the decay curve or update NatSpec to match code behavior.

---

### [L-02] No Solvency Check During Epoch Processing

**Severity:** Low
**Lines:** 401-411
**Agent:** 2B, 2D

**Description:**

`processEpoch()` accumulates rewards without checking contract XOM balance. If underfunded, `accumulatedRewards` becomes unbacked liability. Early claimers get paid; late claimers get `InsufficientBalance`.

**Recommendation:** Add balance check before distributing: `require(balance >= epochReward)`.

---

### [L-03] Missing Events in processMultipleEpochs

**Severity:** Low
**Lines:** 427-482
**Agent:** 2A

**Description:**

`processMultipleEpochs()` does not emit `EpochProcessed` or `RewardDistributed` events, unlike `processEpoch()`. Off-chain monitoring misses batch-processed data.

**Recommendation:** Add summary event or per-epoch events.

---

### [I-01] getActiveNodes Not Implemented in Production OmniCore

**Severity:** Informational
**Agent:** 2B

`OmniCore.sol` does not implement `getActiveNodes()`. Tests pass because `MockOmniCore` has it. Deployment blocker.

---

### [I-02] Rounding Dust Accumulation

**Severity:** Informational
**Agents:** 2A, 2B, 2D

Integer division truncation leaves at most `(validators.length - 1)` wei per epoch. Over 40 years: ~0.00000003 XOM. Negligible.

---

## Static Analysis Results

**Solhint:** No errors (OZ 5.x patterns)
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 2C: Access Control & Privilege Escalation (agent)
- Pass 2D: DeFi Exploit Pattern Analysis (agent)
- Pass 5: Triage & deduplication (manual — 46 raw findings → 19 unique)
- Pass 6: Report generation

## Conclusion

OmniValidatorRewards has **two critical vulnerabilities that must be fixed before any deployment**:

1. **Epoch skipping (C-01)** is a zero-cost grief attack that can permanently destroy millions of XOM in rewards. The fix is trivial: enforce `epoch == lastProcessedEpoch + 1`.

2. **Admin fund-drain paths (C-02)** provide single-key rug-pull capability. Requires timelock + multi-sig + Pausable.

The **flash-stake attack (H-01)** undermines the economic fairness of the reward system and should be fixed by requiring meaningful lock commitment. The **validator forfeit (H-04)** is a design flaw that punishes legitimate validator transitions.

The contract would benefit significantly from: adding `PausableUpgradeable`, enforcing a minimum stake duration for weight calculations, adding a storage gap, and restricting `processEpoch` to an authorized caller or removing the epoch parameter entirely.
