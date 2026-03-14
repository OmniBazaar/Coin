# Security Audit Report: OmniValidatorRewards (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/OmniValidatorRewards.sol`
**SHA-256:** `57df06936712eb01689176eef04b2b5da45600b5362e7d2b882c969f1e0c63d6`
**Solidity Version:** 0.8.24
**Lines of Code:** 2,514
**Upgradeable:** Yes (UUPS with 48h timelock + ossification)
**Handles Funds:** Yes (block rewards distribution to validators -- 6.089B XOM pool)
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 4 (2026-02-28), V2/V3 Joint (2026-03-09), Round 6 (2026-03-10)
**Compilation:** Clean (no errors or warnings)
**Tests:** 82/82 passing
**Solhint:** 0 errors, 8 warnings (analyzed below)

---

## Executive Summary

OmniValidatorRewards is a UUPS-upgradeable contract that distributes pre-funded block rewards (6.089 billion XOM over 40 years) to validators based on a weighted participation model: 40% participation score, 30% staking amount, 30% activity (heartbeat + transaction processing). Epochs correspond to 2-second block intervals. The contract has undergone six prior audit rounds with all Critical, High, and Medium findings remediated.

This Round 7 audit confirms that all Round 6 findings (H-01 emission over-allocation, M-01 admin transfer revocation, M-02 retroactive heartbeat gaming) have been successfully fixed with on-chain rate limiting via `totalDistributed` / `TOTAL_VALIDATOR_POOL`, `adminTransferProposer` storage for atomic revocation, and `lastHeartbeatEpoch` for epoch-based heartbeat validation respectively.

This audit identified **zero Critical**, **one High** (permissionless Bootstrap registration creates a Sybil reward dilution vector), **two Medium** (redundant state storage wastes gas across every transaction recording; `_computeEpochWeights` exceeds function-max-lines linter threshold), **three Low**, and **four Informational** findings.

---

## Finding Summary

| Severity | Count | New | Previously Known |
|----------|-------|-----|-----------------|
| Critical | 0 | 0 | 0 |
| High | 1 | 0 | 1 (reconfirmed from V2/V3 audit H-02) |
| Medium | 2 | 2 | 0 |
| Low | 3 | 1 | 2 (carried forward) |
| Informational | 4 | 2 | 2 (carried forward) |

---

## Role Map

| Role | Granted To | Capabilities |
|------|-----------|--------------|
| `DEFAULT_ADMIN_ROLE` | Deployer (at init) | Pause/unpause, propose/apply contract references, propose/cancel upgrades, ossify, set minStakeForRewards, set stakeExempt, propose/cancel admin transfer, setBlockchainRoleAdmin, grant/revoke all roles |
| `BLOCKCHAIN_ROLE` | Deployer (at init) | Record transaction processing (`recordTransactionProcessing`, `recordMultipleTransactions`) |
| `PENALTY_ROLE` | Not granted at init | Set reward multiplier (penalties 1-100%) via `setRewardMultiplier` |
| `ROLE_MANAGER_ROLE` | Deployer (at init) | Set role multiplier (gateway bonus) via `setRoleMultiplier` |
| Permissionless | Any address | `processEpoch`, `processMultipleEpochs`, `submitHeartbeat` (if validator in OmniCore), `claimRewards` (if has balance), `acceptAdminTransfer` (if pending admin) |

---

## High Findings

### [H-01] Permissionless Bootstrap Registration Enables Sybil Reward Dilution (Reconfirmed)

**Severity:** High
**Category:** Access Control / Economic Security
**Location:** `_bootstrapRoleMultiplier()` (lines 2340-2354), `_computeEpochWeights()` (lines 2072-2201)
**First Identified:** V2/V3 Audit (2026-03-09) as H-02
**Status:** OPEN -- requires Bootstrap.sol or operational mitigation

**Description:**

Bootstrap.sol's `registerNode()` (line 249) and `registerGatewayNode()` (line 285) are **permissionless** -- any address can register as a node. The only access control is the `banned` mapping (admin-set). `registerGatewayNode()` validates that `publicIp`, `nodeId`, and `stakingPort` are non-empty, but does not verify their correctness or uniqueness.

OmniValidatorRewards derives its validator list from `omniCore.getActiveNodes()`, which in turn queries Bootstrap.sol. The `_bootstrapRoleMultiplier()` function automatically grants a 1.5x (15000 bps) multiplier to any address Bootstrap reports as an active gateway (type 0).

This creates a multi-layered Sybil attack:

1. Attacker registers N addresses in Bootstrap as gateway nodes (providing fabricated peer info).
2. Each passes `omniCore.isValidator()` (which delegates to Bootstrap).
3. Each submits heartbeats to become "active" in OmniValidatorRewards.
4. Each receives the 1.5x gateway bonus automatically via `_bootstrapRoleMultiplier()`.
5. Legitimate validators' reward share is diluted proportionally.

The `minStakeForRewards` check (line 2125) provides defense-in-depth **only if set to a non-zero value**. At deployment, it defaults to 0 (line 879). If the admin sets it before public launch, Sybil nodes without OmniCore stakes are filtered out. However, `stakeExempt` addresses bypass this check entirely.

**Impact:** Without `minStakeForRewards > 0`, an attacker can register unlimited Sybil gateways (limited only by Bootstrap's `MAX_NODES` of 1000) and drain a significant fraction of each epoch's rewards. Even with `minStakeForRewards` set, the 1.5x gateway bonus is granted without cross-verifying actual AVAX staking or infrastructure operation.

**Recommendation (unchanged from V2/V3 audit):**

1. **Immediate (operational):** Set `minStakeForRewards` to >= 1,000,000 XOM before public launch.
2. **Short-term:** Add admin approval or governance vote for Bootstrap node registration, or require a deposit/bond.
3. **Medium-term:** In `_bootstrapRoleMultiplier()`, cross-verify the gateway node has an active OmniCore stake above a gateway-specific threshold before granting the 1.5x bonus.
4. **Remove or limit** the `stakeExempt` mapping after seed validators are no longer needed.

**Mitigating Factors:**
- `MAX_VALIDATORS_PER_EPOCH` (200) caps the number of Sybil nodes that can earn rewards per epoch.
- OmniCore V3 interleaves gateway and computation nodes, preventing gateway-only monopolization.
- Admin can ban Sybil addresses in Bootstrap.sol.
- If `minStakeForRewards` is properly set, the attack requires genuine economic stake per node.

---

## Medium Findings

### [M-01] Redundant `_epochTxnCount` Mapping Wastes ~5,000 Gas Per Transaction Recording

**Severity:** Medium
**Category:** Gas Optimization
**Location:** `recordTransactionProcessing()` (lines 917-940), `recordMultipleTransactions()` (lines 950-980), `_epochTxnCount` (lines 441-442)
**First Identified:** Round 6 L-01 (upgraded to Medium due to cumulative gas impact)

**Description:**

Two separate mappings track identical per-validator per-epoch transaction counts with reversed key ordering:

```solidity
// Used for cap enforcement (Round 4 M-04)
mapping(uint256 => mapping(address => uint256)) private _epochTxnCount;

// Used for weight calculation
mapping(address => mapping(uint256 => uint256)) public transactionsProcessed;
```

In `recordTransactionProcessing()`:
```solidity
++_epochTxnCount[currentEpoch][validator];      // SSTORE #1
++transactionsProcessed[validator][currentEpoch]; // SSTORE #2 (same data)
```

Both mappings store the same value. The `_epochTxnCount` mapping was introduced in Round 4 (M-04) specifically for the per-epoch per-validator cap check, but could use the existing `transactionsProcessed` mapping for the same check by simply reversing the key order in the comparison.

At scale (200 validators, each recording transactions every epoch), this adds ~5,000 gas per call (one redundant cold/warm SSTORE). Over 40 years at 2-second epochs, this represents significant cumulative gas waste.

**Impact:** ~5,000 extra gas per `recordTransactionProcessing()` and `recordMultipleTransactions()` call. No correctness issue.

**Recommendation:**

Remove `_epochTxnCount` and use `transactionsProcessed` for the cap check:

```solidity
function recordTransactionProcessing(address validator) external onlyRole(BLOCKCHAIN_ROLE) {
    if (!omniCore.isValidator(validator)) revert NotValidator();
    uint256 currentEpoch = getCurrentEpoch();
    if (transactionsProcessed[validator][currentEpoch]
        >= MAX_TXN_PER_EPOCH_PER_VALIDATOR) {
        revert TxnCapExceeded();
    }
    ++transactionsProcessed[validator][currentEpoch];
    ++epochTotalTransactions[currentEpoch];
    emit TransactionProcessed(validator, currentEpoch, 1);
}
```

This saves one SSTORE per call and one storage slot header. The `>= MAX_TXN_PER_EPOCH_PER_VALIDATOR` check is equivalent to the existing `> MAX_TXN_PER_EPOCH_PER_VALIDATOR - 1` check.

---

### [M-02] `_computeEpochWeights` Exceeds Function Complexity and Length Thresholds

**Severity:** Medium
**Category:** Code Quality / Maintainability
**Location:** `_computeEpochWeights()` (lines 2072-2201)
**Solhint Warnings:** `function-max-lines` (128 lines, max 100), `code-complexity` (cyclomatic complexity 12, max 7)

**Description:**

`_computeEpochWeights()` is 128 lines with cyclomatic complexity of 12, exceeding the project's solhint thresholds (max 100 lines, max 7 complexity). The function handles:

1. Epoch-based heartbeat validation with timestamp fallback (lines 2098-2120)
2. Minimum stake enforcement with exemption check (lines 2125-2141)
3. Base weight calculation via `_calculateValidatorWeight()` (lines 2142-2145)
4. Penalty multiplier application with expiry check (lines 2147-2167)
5. Role multiplier derivation with Bootstrap fallback (lines 2173-2194)
6. Weight accumulation and active count tracking (lines 2195-2197)

While this complexity arose organically through multiple audit rounds (each adding a check), the function is now difficult to review and test in isolation.

Additionally, `_distributeRewards()` has cyclomatic complexity 10 (also exceeds the threshold of 7).

**Impact:** Increased risk of introducing bugs during future modifications. Harder to achieve complete test coverage of all code paths.

**Recommendation:**

Extract the inner loop body into a private function:

```solidity
function _computeValidatorEpochWeight(
    address validator,
    uint256 epoch,
    uint256 heartbeatEpochWindow,
    uint256 minStake
) internal view returns (uint256 weight, bool isActive) {
    // Heartbeat validation
    // Stake check
    // Base weight
    // Penalty multiplier
    // Role multiplier
}
```

This separates concerns and brings each function under the complexity threshold. The compiler will inline the private function if gas-optimal.

---

## Low Findings

### [L-01] `processEpoch()` Does Not Emit `ValidatorSetCapped` Event

**Severity:** Low
**Category:** Monitoring / Observability
**Location:** `processEpoch()` (lines 992-1048)

**Description:**

`processMultipleEpochs()` emits `ValidatorSetCapped` when `validators.length > MAX_VALIDATORS_PER_EPOCH` (lines 1104-1109), but `processEpoch()` does not. When the validator set exceeds 200 and epochs are processed one at a time, monitoring systems receive no warning that validators beyond index 200 are being excluded.

**Impact:** Off-chain monitoring is blind to validator set capping when single-epoch processing is used.

**Recommendation:** Add the same check and event emission in `processEpoch()` after fetching the validator list:

```solidity
address[] memory validators = omniCore.getActiveNodes();
if (validators.length > MAX_VALIDATORS_PER_EPOCH) {
    emit ValidatorSetCapped(validators.length, MAX_VALIDATORS_PER_EPOCH);
}
```

---

### [L-02] `setRewardMultiplier(validator, 100, reason)` Is Functionally Identical to `(validator, 0, reason)` But Takes a Different Code Path

**Severity:** Low
**Category:** Business Logic Edge Case
**Location:** `setRewardMultiplier()` (lines 1375-1403), `_computeEpochWeights()` (lines 2146-2167)
**Carried Forward:** Round 6 L-02

**Description:**

Setting `multiplier = 100` stores the value 100 and clears the penalty expiry (because `100 < 100` is false). In `_computeEpochWeights`, `mult = 100` triggers the non-zero branch, which applies `(baseWeight * 100) / 100 = baseWeight`. The result is identical to `mult = 0` (default/100%), but the code takes an unnecessary multiplication-division path.

More significantly, PENALTY_ROLE can use `multiplier = 100` to clear a penalty expiry timer without visibly "removing" the penalty, then re-apply a harsher penalty with a fresh 30-day timer.

**Impact:** Minor gas waste and a subtle mechanism for penalty timer manipulation by PENALTY_ROLE.

**Recommendation:** In `_computeEpochWeights`, treat `mult == 100` the same as `mult == 0`:

```solidity
if (mult != 0 && mult != 100) {
    // Apply penalty
}
```

Or document that `multiplier = 100` is the canonical "restore" value that also clears timers.

---

### [L-03] `PoolRunningLow` Event May Fire Repeatedly on Every Epoch After Threshold

**Severity:** Low
**Category:** Event Spam
**Location:** `_distributeRewards()` (lines 2041-2053)

**Description:**

Once `totalDistributed` crosses the 90% threshold of `TOTAL_VALIDATOR_POOL`, the `PoolRunningLow` event is emitted on **every** subsequent epoch. With 2-second epochs, this produces approximately 43,200 events per day (~1.3M events per month) until the pool is fully exhausted.

This may overwhelm off-chain event listeners, log storage, and monitoring dashboards.

**Impact:** Excessive event emission after the 90% threshold. No on-chain impact but may cause off-chain monitoring issues.

**Recommendation:** Add a boolean flag `poolLowAlerted` that is set on first emission and prevents subsequent emissions:

```solidity
bool public poolLowAlerted;

// In _distributeRewards:
if (percentBps < POOL_LOW_THRESHOLD_BPS && !poolLowAlerted) {
    poolLowAlerted = true;
    emit PoolRunningLow(newRemaining, totalDistributed, percentBps);
}
```

Alternatively, emit only when the pool crosses specific 1% thresholds (e.g., 9%, 8%, 7%...).

---

## Informational Findings

### [I-01] `submitHeartbeat()` Uses `msg.sender` While `claimRewards()` Uses `_msgSender()` (ERC-2771 Inconsistency)

**Severity:** Informational
**Category:** Consistency
**Location:** `submitHeartbeat()` (line 891), `claimRewards()` (line 1169)
**Carried Forward:** Round 6 I-02

**Description:**

`submitHeartbeat()` uses `msg.sender` directly, preventing heartbeat submission via meta-transactions. `claimRewards()` uses `_msgSender()`, allowing claims via the trusted forwarder. This means a validator behind NAT or without direct transaction capability can claim rewards but cannot prove liveness.

This is likely intentional (heartbeats prove on-chain liveness of the validator's key), but creates an asymmetry.

**Recommendation:** Document the design choice. If meta-transaction heartbeats are desired, `submitHeartbeat()` should use `_msgSender()` and validate that the resulting address is a validator.

---

### [I-02] `totalBlocksProduced` Counts All Processed Epochs Including Those With Zero Active Validators

**Severity:** Informational
**Category:** Accounting / Naming
**Location:** `processEpoch()` (line 1027), `processMultipleEpochs()` (line 1143)
**Carried Forward:** Round 6 I-03

**Description:**

`totalBlocksProduced` is incremented for every processed epoch regardless of whether any validator was active or any rewards were distributed. The variable name suggests it tracks reward-generating blocks, but it actually tracks total epochs processed.

The NatSpec at line 373 clarifies this is "for monitoring only" and "not used in reward calculation," which is correct.

**Impact:** Monitoring dashboards may show inflated "blocks produced" relative to reward-generating epochs.

**Recommendation:** Rename to `totalEpochsProcessed` for clarity, or only increment when `activeCount > 0`.

---

### [I-03] Solhint Warning: Non-Strict Inequality in `_computeEpochWeights` (Line 2104)

**Severity:** Informational
**Category:** Gas Optimization
**Location:** `_computeEpochWeights()` line 2104

**Description:**

Solhint flags `epoch <= hbEpoch + heartbeatEpochWindow` as a non-strict inequality (`gas-strict-inequalities`). Converting to `epoch < hbEpoch + heartbeatEpochWindow + 1` would satisfy the linter but reduce readability.

The current form is semantically clearer: "the epoch is within the heartbeat window." The gas difference is negligible (EQ + LT vs LT with incremented operand).

**Recommendation:** Suppress with an inline comment if the linter warning is undesirable:

```solidity
// solhint-disable-next-line gas-strict-inequalities
&& epoch <= hbEpoch + heartbeatEpochWindow;
```

Or accept the warning as a known trade-off for readability.

---

### [I-04] NatSpec `@title`, `@author`, `@notice` Tags on Contract Declaration Are Not Detected by Solhint

**Severity:** Informational
**Category:** Documentation / Linting
**Location:** Contract declaration (line 207), NatSpec block (lines 101-205)

**Description:**

Solhint reports three `use-natspec` warnings:
```
207:1  warning  Missing @title tag in contract 'OmniValidatorRewards'
207:1  warning  Missing @author tag in contract 'OmniValidatorRewards'
207:1  warning  Missing @notice tag in contract 'OmniValidatorRewards'
```

The contract **does** have `@title`, `@author`, and `@notice` tags (lines 102-105), but they are separated from the `contract` declaration by the `// solhint-disable max-states-count` comment on line 206. Solhint's NatSpec detection requires the documentation block to be immediately adjacent to the declaration.

**Recommendation:** Move the `solhint-disable` inside the contract body or place the NatSpec block after the disable directive:

```solidity
// solhint-disable max-states-count
/**
 * @title OmniValidatorRewards
 * @author OmniBazaar Team
 * @notice Trustless validator reward distribution for OmniBazaar
 * ...
 */
contract OmniValidatorRewards is ...
```

This satisfies both the `max-states-count` suppression and the `use-natspec` detection.

---

## Round 6 Fix Verification

| ID | Finding | Fix Applied | Verified |
|----|---------|-------------|----------|
| H-01 | Emission over-allocation (~154M deficit) | `TOTAL_VALIDATOR_POOL` constant (6.089B), `totalDistributed` accumulator, solvency guard in `_distributeRewards()`, `PoolRunningLow` + `EpochRewardCapped` events | **VERIFIED** (lines 345-346, 487, 1982-2013, 2038-2053) |
| M-01 | `acceptAdminTransfer` does not revoke old admin | `adminTransferProposer` stored in `proposeAdminTransfer()`, atomically revoked in `acceptAdminTransfer()` | **VERIFIED** (lines 474, 1556, 1574, 1585-1587) |
| M-02 | Offline validators earn retroactive rewards | `lastHeartbeatEpoch` mapping updated in `submitHeartbeat()`, epoch-based validation in `_computeEpochWeights()` with timestamp fallback for pre-upgrade validators | **VERIFIED** (lines 481, 900, 2095-2120) |

---

## Previous Audit Fix Verification (All Rounds)

### Round 4 Fixes (2026-02-28)

| Finding | Fix | Verified |
|---------|-----|----------|
| H-01: emergencyWithdraw XOM bypass | `_originalXomToken` stored at init, checked in `emergencyWithdraw` | **VERIFIED** (lines 430, 1352-1357) |
| M-01: roleMultiplier uncapped | `MAX_ROLE_MULTIPLIER = 15000` (1.5x cap) | **VERIFIED** (line 257) |
| M-02: Indefinite penalty suppression | `MAX_PENALTY_DURATION = 30 days`, auto-expiry via `_resetExpiredPenalties` | **VERIFIED** (lines 264, 1929-1951) |
| M-04: Per-epoch per-validator txn cap | `MAX_TXN_PER_EPOCH_PER_VALIDATOR = 1000` | **VERIFIED** (lines 270, 926-932) |
| M-05: claimRewards blocked during pause | `whenNotPaused` removed from `claimRewards` | **VERIFIED** (line 1165 -- no modifier) |
| L-02: Sub-base roleMultiplier rejected | `MultiplierBelowBase` error for values 1-9999 | **VERIFIED** (lines 1428-1432) |
| I-01: nonReentrant placed first | First modifier on `processEpoch` and `processMultipleEpochs` | **VERIFIED** (lines 996, 1089) |
| I-03: Single division for activity precision | `numerator / 10000` | **VERIFIED** (lines 2322-2327) |

### Round 3 Fixes (2026-02-26)

| Finding | Fix | Verified |
|---------|-----|----------|
| H-01: Upgrade timelock | `proposeUpgrade()` + `UPGRADE_DELAY` (48h) + `_authorizeUpgrade()` check | **VERIFIED** (lines 1294-1330, 1895-1920) |
| M-01: External calls wrapped in try/catch | All calls to `participation` and `omniCore` use try/catch | **VERIFIED** (lines 2225-2231, 2260-2266, 2343-2352) |
| M-02: totalOutstandingRewards solvency tracking | Accumulated on distribution, decremented on claim | **VERIFIED** (lines 2025, 1180) |

### V2 Changes (2026-03)

| Change | Implementation | Verified |
|--------|---------------|----------|
| Permissionless processEpoch | No `BLOCKCHAIN_ROLE` modifier | **VERIFIED** (lines 992-998) |
| Auto role multiplier from Bootstrap | `_bootstrapRoleMultiplier()` with try/catch | **VERIFIED** (lines 2340-2354) |
| Two-step admin transfer with 48h delay | `proposeAdminTransfer()` / `acceptAdminTransfer()` with `ADMIN_TRANSFER_DELAY` | **VERIFIED** (lines 1546-1604) |
| Admin transfer proposer tracked (R6 M-01 fix) | `adminTransferProposer` stored and used for atomic revocation | **VERIFIED** (lines 474, 1556, 1574-1587) |
| Minimum stake for rewards | `minStakeForRewards` with `stakeExempt` bypass | **VERIFIED** (lines 454, 2125-2141) |
| Epoch-based heartbeat (R6 M-02 fix) | `lastHeartbeatEpoch` in `submitHeartbeat()`, checked in `_computeEpochWeights()` | **VERIFIED** (lines 481, 900, 2098-2120) |
| Pool solvency cap (R6 H-01 fix) | `TOTAL_VALIDATOR_POOL`, `totalDistributed`, solvency guard in `_distributeRewards()` | **VERIFIED** (lines 345-346, 487, 1982-2053) |

---

## Business Logic Verification

### Block Reward Schedule

| Parameter | Spec (CLAUDE.md) | Contract | Status |
|-----------|------------------|----------|--------|
| Initial reward | 15.602 XOM/block | `INITIAL_BLOCK_REWARD = 15_602_000_000_000_000_000` (15.602e18) | **MATCHES** |
| Reduction interval | Every 6,311,520 blocks | `BLOCKS_PER_REDUCTION = 6_311_520` | **MATCHES** |
| Reduction amount | 1% per period | `REDUCTION_FACTOR = 99, REDUCTION_DENOMINATOR = 100` | **MATCHES** |
| Zero reward cutoff | After 631,152,000 blocks | `MAX_REDUCTIONS = 100` (100 x 6,311,520 = 631,152,000) | **MATCHES** |
| Total duration | ~40 years | 631,152,000 x 2s = 40.00 years | **MATCHES** |
| Total pool cap | 6.089 billion XOM | `TOTAL_VALIDATOR_POOL = 6_089_000_000 ether` | **MATCHES** |
| Block time | 2 seconds | `EPOCH_DURATION = 2` | **MATCHES** |

**Note on H-01 from Round 6:** The raw emission schedule produces ~6.243B XOM, but the `TOTAL_VALIDATOR_POOL` cap (6.089B) now acts as a hard ceiling. Once `totalDistributed` reaches 6.089B, epoch rewards are capped to zero via the solvency guard in `_distributeRewards()`. The emission schedule will effectively terminate early (around year ~38.3) rather than over-allocate. This is the correct behavior -- the pool runs dry gracefully rather than becoming insolvent.

### Solvency Guard Verification

The `_distributeRewards()` function (lines 1973-2054) implements a three-layer solvency check:

1. **Pool cap:** `poolRemaining = TOTAL_VALIDATOR_POOL - totalDistributed` (line 1985-1988)
2. **Contract balance:** `availableForRewards = contractBalance - totalOutstandingRewards` (lines 1990-1997)
3. **Minimum of both:** `maxDistributable = min(poolRemaining, availableForRewards)` (lines 2000-2002)
4. **Epoch reward capped:** `effectiveReward = min(epochReward, maxDistributable)` (lines 2004-2010)

This prevents both over-allocation beyond the 6.089B pool and distribution of tokens that are already owed to other validators (outstanding claims). **Verified correct.**

### Weight Calculation

| Component | Spec | Contract | Status |
|-----------|------|----------|--------|
| Participation score | 40% weight | `PARTICIPATION_WEIGHT = 40` | **MATCHES** |
| Staking amount | 30% weight | `STAKING_WEIGHT = 30` | **MATCHES** |
| Activity | 30% weight | `ACTIVITY_WEIGHT = 30` | **MATCHES** |
| Heartbeat sub-weight | 60% of activity | `HEARTBEAT_SUBWEIGHT = 60` | **MATCHES** |
| Tx processing sub-weight | 40% of activity | `TX_PROCESSING_SUBWEIGHT = 40` | **MATCHES** |

### Distribution Split

| Parameter | Spec (CLAUDE.md) | Contract | Status |
|-----------|------------------|----------|--------|
| Staking pool | Up to 50% | Not implemented | **ACCEPTED** |
| ODDAO | 10% | Not implemented | **ACCEPTED** |
| Block producer | Remainder | 100% to weighted validators | **ACCEPTED** |

**Note:** This contract implements the Proof of Participation reward model, where all block rewards go to validators weighted by participation. The staking pool and ODDAO receive funds through other mechanisms (marketplace fees via UnifiedFeeVault, DEX fees via DEXSettlement). This has been confirmed as intentional across multiple audit rounds.

### Staking Tier Scores (Spot-Check)

| Amount | Expected Score | Calculation | Status |
|--------|---------------|-------------|--------|
| 0 XOM | 0 | `(0 * 20) / 1M = 0` | **CORRECT** |
| 500K XOM | 10 | `(500K * 20) / 1M = 10` | **CORRECT** |
| 1M XOM | 20 | `20 + (0 * 20) / 9M = 20` | **CORRECT** |
| 5.5M XOM | 30 | `20 + (4.5M * 20) / 9M = 30` | **CORRECT** |
| 10M XOM | 40 | `40 + (0 * 20) / 90M = 40` | **CORRECT** |
| 55M XOM | 50 | `40 + (45M * 20) / 90M = 50` | **CORRECT** |
| 100M XOM | 60 | `60 + (0 * 20) / 900M = 60` | **CORRECT** |
| 1B XOM | 80 | `80 + (0 * 20) / 9B = 80` | **CORRECT** |
| 10B+ XOM | 100 | Cap | **CORRECT** |

### Epoch Management

| Check | Result |
|-------|--------|
| Sequential enforcement | `epoch != lastProcessedEpoch + 1` reverts `EpochNotSequential` | **CORRECT** |
| Future epoch prevention | `epoch > currentEpoch` reverts `FutureEpoch` | **CORRECT** |
| Batch cap | `MAX_BATCH_EPOCHS = 50` enforced | **CORRECT** |
| First epoch | `lastProcessedEpoch` starts at 0, first call requires epoch 1 | **CORRECT** |
| Zero reward after exhaustion | After `MAX_REDUCTIONS` (epoch 631,152,000+), reward is 0 | **CORRECT** |
| Pool exhaustion handling | Solvency guard caps reward to available balance | **CORRECT** |

---

## DeFi Exploit Analysis

### Can a validator claim rewards multiple times per epoch?

**No.** Rewards accumulate in `accumulatedRewards[caller]`. `claimRewards()` atomically zeroes the balance, transfers, and emits. The `nonReentrant` modifier prevents reentrancy. There is no per-epoch claim mechanism.

### Can a validator manipulate epoch boundaries?

**No.** Epoch numbers are deterministic: `(block.timestamp - genesisTimestamp) / EPOCH_DURATION`. `genesisTimestamp` is set once in `initialize()`. Block timestamp manipulation on Avalanche is bounded to ~1 second. Sequential enforcement prevents skipping/replaying.

### Flash-loan to inflate validator stake?

**Mitigated.** `_calculateStakingComponent` rejects stakes with `lockTime < block.timestamp + 1` (expired locks). A flash-staker needs a genuine OmniCore stake with future lock time. OmniCore enforces minimum lock durations.

### Can the pool be drained by claiming more than deposited?

**No.** Three protections:
1. `totalDistributed` tracks cumulative distribution, capped at `TOTAL_VALIDATOR_POOL` (6.089B).
2. `totalOutstandingRewards` tracks unclaimed obligations, subtracted from available balance.
3. `claimRewards()` checks `xomToken.balanceOf(address(this)) >= amount` before transfer.

### Can a validator front-run `processEpoch` with a heartbeat?

**Partially mitigated.** The Round 6 M-02 fix introduces `lastHeartbeatEpoch` to track the epoch at which a heartbeat was submitted. In `_computeEpochWeights`, a validator is only considered active for epochs within `heartbeatEpochWindow` (10 epochs = 20 seconds) of their last heartbeat epoch. A validator that was offline for 50 epochs cannot come back online and retroactively earn for all 50 epochs -- only the epochs within the window of their heartbeat.

**Remaining risk:** A validator can submit a heartbeat and immediately process the current epoch in the same block, guaranteeing a heartbeat score of 100 for that epoch. This is accepted behavior (the advantage is marginal -- 18% of total weight at most).

### Can `emergencyWithdraw` drain the XOM reward pool?

**No.** Both `address(xomToken)` and `_originalXomToken` are checked. The original XOM address is stored immutably at initialization and cannot be changed via `proposeContracts/applyContracts`. This prevents the bypass where admin swaps the `xomToken` reference, then withdraws the old token.

### Can admin transfer leave two admins in control?

**No (fixed in R6).** `acceptAdminTransfer()` reads `adminTransferProposer`, grants to `msg.sender`, then atomically revokes from the proposer. The `if (oldAdmin != address(0) && oldAdmin != msg.sender)` guard handles the edge case of self-transfer.

### Integer overflow risks?

**None.** Solidity 0.8.24 has built-in overflow protection. Maximum calculation: `epochReward * maxWeight = 15.602e18 * 150 = 2.34e21`, well within uint256 range. `TOTAL_VALIDATOR_POOL = 6.089e27` is also safely within range. All `unchecked` blocks contain only loop counter increments bounded by loop conditions.

### Can `totalDistributed` overflow?

**No.** `totalDistributed` is incremented by `epochDistributed` each epoch, which is at most `INITIAL_BLOCK_REWARD` (15.602e18). Even after 40 years of continuous distribution, `totalDistributed` reaches at most ~6.243e27, far from the uint256 maximum of ~1.16e77.

### Can `totalOutstandingRewards` underflow in `claimRewards()`?

**No.** `totalOutstandingRewards` is incremented by the exact amount added to each validator's `accumulatedRewards`. When claimed, `totalOutstandingRewards -= amount` where `amount = accumulatedRewards[caller]`. Since `accumulatedRewards[caller]` was added to `totalOutstandingRewards` when distributed, the subtraction cannot underflow (Solidity 0.8 reverts on underflow).

---

## Gas Analysis

| Function | Estimated Gas (200 validators) | Notes |
|----------|-------------------------------|-------|
| `processEpoch` (single) | ~2.5M gas | 200 external calls to participation + omniCore, plus Bootstrap lookups |
| `processMultipleEpochs(50)` | ~100M gas | 50 x 200 = 10,000 weight calculations; **may exceed Avalanche block gas limit** |
| `processMultipleEpochs(10)` | ~25M gas | Safer batch size for 200 validators |
| `claimRewards` | ~60K gas | Single SSTORE + SafeERC20 transfer |
| `submitHeartbeat` | ~50K gas | 2 SSTOREs (lastHeartbeat + lastHeartbeatEpoch) + event |
| `recordTransactionProcessing` | ~65K gas | 3 SSTOREs (redundant `_epochTxnCount`, see M-01) |
| `recordMultipleTransactions` | ~65K gas | 3 SSTOREs + arithmetic |
| `_distributeRewards` (200 validators) | ~1.5M gas | 200 SSTOREs + xomToken.balanceOf + solvency calculations |

**Note:** `processMultipleEpochs(50)` with 200 validators is very gas-intensive. On Avalanche C-Chain with an 8M gas limit per block, `processMultipleEpochs(3-4)` is a safer maximum for 200 validators. Consider reducing `MAX_BATCH_EPOCHS` or dynamically computing the safe batch size based on active validator count.

---

## Solhint Analysis

| Line | Warning | Assessment | Action |
|------|---------|------------|--------|
| 207:1 | Missing @title in contract | NatSpec block exists (lines 102-105) but separated from declaration by `solhint-disable` comment | See I-04 -- move disable inside contract body |
| 207:1 | Missing @author in contract | Same cause as above | See I-04 |
| 207:1 | Missing @notice in contract | Same cause as above | See I-04 |
| 1973:5 | code-complexity 10 > 7 | `_distributeRewards` has solvency guard + distribution loop | Accept -- complexity is justified by solvency requirements |
| 2072:5 | function-max-lines 128 > 100 | `_computeEpochWeights` accumulated checks across audit rounds | See M-02 -- extract helper function |
| 2072:5 | code-complexity 12 > 7 | Same function | See M-02 |
| 2104:20 | gas-strict-inequalities | `epoch <= hbEpoch + heartbeatEpochWindow` | See I-03 -- accept for readability |
| 2464:5 | ordering | `_msgSender()` internal view after `_stakingTierScore()` internal pure | Move ERC2771 overrides above pure functions |

---

## Security Properties Summary

| Property | Status | Details |
|----------|--------|---------|
| Reentrancy protection | PASS | `nonReentrant` on `processEpoch`, `processMultipleEpochs`, `claimRewards` |
| CEI pattern | PASS | `claimRewards` updates state before transfer |
| Access control | PASS | Role-based via OpenZeppelin AccessControl, 4 roles |
| Upgrade safety | PASS | UUPS with 48h timelock + ossification |
| Integer overflow | PASS | Solidity 0.8.24 built-in; all unchecked blocks bounded |
| Flash-stake protection | PASS | Lock expiry check in `_calculateStakingComponent` |
| Solvency tracking | PASS | `totalOutstandingRewards` + `totalDistributed` + pool cap |
| Pool exhaustion | PASS | `TOTAL_VALIDATOR_POOL` hard cap with graceful degradation |
| Emergency controls | PASS | Pause/unpause + emergencyWithdraw (non-XOM) |
| Epoch integrity | PASS | Sequential enforcement prevents double-processing |
| External call resilience | PASS | All external calls wrapped in try/catch |
| DoS protection | PASS | Validator cap (200) + batch cap (50) + txn cap (1000) |
| Admin transfer safety | PASS | Two-step with 48h delay + atomic revocation |
| Heartbeat gaming | PASS | Epoch-based validation prevents retroactive rewards |
| XOM withdrawal protection | PASS | Both current and original XOM addresses blocked |
| Trusted forwarder | PASS | Immutable, standard ERC-2771 pattern |
| Penalty decay | PASS | 30-day max duration with automatic expiry |
| Sybil prevention | PARTIAL | Requires `minStakeForRewards > 0` (operational) |

---

## Incomplete Code / Stubs / TODOs

**None found.** The contract contains no TODO comments, stub implementations, mock functions, or "in production" comments. All code paths are fully implemented.

---

## Recommendations Summary

| # | Severity | Finding | Recommendation | Effort |
|---|----------|---------|----------------|--------|
| H-01 | High | Permissionless Bootstrap registration enables Sybil reward dilution | Set `minStakeForRewards >= 1M XOM` before launch; add Bootstrap registration access control | Medium |
| M-01 | Medium | Redundant `_epochTxnCount` wastes ~5K gas/call | Remove `_epochTxnCount`, use `transactionsProcessed` for cap check | Low |
| M-02 | Medium | `_computeEpochWeights` exceeds complexity/length limits | Extract inner loop body into helper function | Low |
| L-01 | Low | `processEpoch` missing `ValidatorSetCapped` event | Add check and event emission after fetching validators | Low |
| L-02 | Low | `multiplier=100` takes unnecessary code path | Treat `mult == 100` as equivalent to `mult == 0` | Low |
| L-03 | Low | `PoolRunningLow` fires on every epoch after threshold | Add `poolLowAlerted` flag to emit once | Low |
| I-01 | Info | `msg.sender` vs `_msgSender()` inconsistency in heartbeat/claim | Document design choice | None |
| I-02 | Info | `totalBlocksProduced` counts empty epochs | Rename to `totalEpochsProcessed` | Low |
| I-03 | Info | Non-strict inequality gas warning | Add solhint-disable comment or accept | None |
| I-04 | Info | NatSpec not detected due to comment separation | Move `solhint-disable` inside contract body | Low |

---

## Deployment Checklist

Before mainnet deployment, ensure the following operational requirements are met:

1. [ ] `minStakeForRewards` set to >= 1,000,000 XOM (prevents Sybil attacks -- H-01)
2. [ ] `DEFAULT_ADMIN_ROLE` transferred to a TimelockController controlled by 3-of-5 multisig
3. [ ] `PENALTY_ROLE` granted to appropriate governance address
4. [ ] `BLOCKCHAIN_ROLE` granted to all validator node addresses or delegated via `setBlockchainRoleAdmin`
5. [ ] Bootstrap.sol admin access controls verified (registration requires approval or minimum stake)
6. [ ] Seed validator exemptions (`stakeExempt`) documented and planned for removal
7. [ ] `reinitializeV2()` called with correct Bootstrap.sol address during proxy upgrade
8. [ ] `processMultipleEpochs` batch size tested at expected validator count (gas limit check)
9. [ ] Off-chain monitoring configured for `PoolRunningLow`, `EpochRewardCapped`, `ValidatorSetCapped` events
10. [ ] OmniRewardManager has transferred exactly 6,089,000,000 XOM to this contract's proxy address

---

## Conclusion

OmniValidatorRewards has matured significantly over seven audit rounds. The contract now implements comprehensive solvency protection (pool cap + distribution tracking + balance checks), atomic admin transfers, epoch-based heartbeat validation, automatic role multiplier derivation from Bootstrap.sol, penalty decay, and the ossification mechanism for permanent upgrade lockdown.

All Critical, High, and Medium findings from Round 6 have been successfully remediated:
- **H-01 (emission over-allocation):** Hard-capped by `TOTAL_VALIDATOR_POOL` with graceful degradation.
- **M-01 (admin transfer):** Atomic revocation via `adminTransferProposer`.
- **M-02 (retroactive heartbeat):** Epoch-based validation with timestamp fallback for backward compatibility.

The remaining High finding (H-01 in this report) is a reconfirmation of the Sybil attack vector from the V2/V3 audit, which depends on Bootstrap.sol's permissionless registration and the operational requirement to set `minStakeForRewards > 0`. This is an architectural concern that spans multiple contracts and requires coordinated mitigation.

The two new Medium findings (redundant storage and function complexity) are code quality issues that do not affect correctness but should be addressed for long-term maintainability and gas efficiency.

**Overall Risk Rating: 4/10** (pre-ossification, with `minStakeForRewards` set), dropping to **2/10** after ossification.

This rating reflects: strong solvency protection, proper access control with timelocks, comprehensive external call resilience, epoch integrity enforcement, and the accumulated hardening from six prior audit rounds. The primary residual risks are the Bootstrap Sybil vector (operational mitigation available) and the inherent centralization risk of the admin key before ossification.

---

*Report generated: 2026-03-13 14:15 UTC*
*Auditor: Claude Code Audit Agent (Round 7 Pre-Mainnet)*
*Contract: OmniValidatorRewards.sol (2,514 lines, Solidity 0.8.24)*
*SHA-256: 57df06936712eb01689176eef04b2b5da45600b5362e7d2b882c969f1e0c63d6*
*Tests: 82/82 passing*
*Compilation: Clean (0 errors, 0 warnings)*
*Solhint: 0 errors, 8 warnings (all analyzed)*
