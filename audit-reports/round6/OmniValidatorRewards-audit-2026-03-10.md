# Security Audit Report: OmniValidatorRewards (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Round 6 Pre-Mainnet)
**Contract:** `Coin/contracts/OmniValidatorRewards.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 2,332
**Upgradeable:** Yes (UUPS with 48h timelock + ossification)
**Handles Funds:** Yes (block rewards distribution to validators)
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 4 (2026-02-28)

---

## Executive Summary

OmniValidatorRewards is a UUPS-upgradeable contract that distributes block rewards to validators based on a weighted participation model (40% participation score / 30% staking amount / 30% activity). Epochs correspond to 2-second block intervals. Rewards are accumulated per-validator and claimed via a pull-based mechanism.

This Round 6 audit found that all High and Medium findings from Round 4 have been addressed (H-01 emergencyWithdraw bypass, M-01 roleMultiplier cap, M-02 penalty decay, M-04 per-epoch txn cap, M-05 claim during pause). The V2 upgrade introduced permissionless epoch processing and auto-derived role multipliers from Bootstrap.sol, both of which are well-implemented.

However, this audit identified **one HIGH** finding (emission schedule over-allocation leading to eventual insolvency), **two MEDIUM** findings (incomplete admin transfer, heartbeat retroactive rewards gaming), **three LOW** findings, and **three INFORMATIONAL** observations.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | Emission schedule over-allocation | **FIXED** — on-chain rate limiting |
| M-01 | Medium | acceptAdminTransfer does not revoke old admin | **FIXED** |
| M-02 | Medium | Offline validators earn retroactive rewards | **FIXED** |

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Role Map

| Role | Granted To | Capabilities |
|------|-----------|--------------|
| `DEFAULT_ADMIN_ROLE` | Deployer (at init) | Pause/unpause, propose/apply contract references, propose/cancel upgrades, ossify, set minStakeForRewards, set stakeExempt, propose admin transfer, cancel admin transfer, grant/revoke all roles |
| `BLOCKCHAIN_ROLE` | Deployer (at init) | Record transaction processing (`recordTransactionProcessing`, `recordMultipleTransactions`) |
| `PENALTY_ROLE` | Not granted at init | Set reward multiplier (penalties 1-100%) via `setRewardMultiplier` |
| `ROLE_MANAGER_ROLE` | Deployer (at init) | Set role multiplier (gateway bonus) via `setRoleMultiplier` |
| Permissionless | Any address | `processEpoch`, `processMultipleEpochs`, `submitHeartbeat` (if validator), `claimRewards` (if has balance), `acceptAdminTransfer` (if pending admin) |

---

## High Findings

### [H-01] Emission Schedule Over-Allocation: Contract Will Become Insolvent

**Severity:** High
**Category:** Business Logic / Tokenomics
**Location:** `INITIAL_BLOCK_REWARD` constant (line 280), `calculateBlockRewardForEpoch()` (line 1769)

**Description:**

The contract's emission schedule distributes approximately **6.243 billion XOM** over 40 years, but the OmniRewardManager pre-funds the contract with only **6.089 billion XOM**. This creates a deficit of approximately **154 million XOM** (~2.53% over-allocation).

Mathematical verification:

```
Sum of (15.602 * 0.99^i * 6,311,520) for i = 0..99
= 15.602 * 6,311,520 * sum(0.99^i for i=0..99)
= 15.602 * 6,311,520 * 63.397
= 6,242,827,569 XOM

Pre-funded: 6,089,000,000 XOM
Deficit:      153,827,569 XOM
```

The correct initial reward for exactly 6.089B over 100 reduction periods is **15.2176 XOM/block**, not 15.602.

The contract will become insolvent at approximately **epoch 604,911,180** (~year 38.3 of the 40-year schedule). After that point, `claimRewards()` will revert with `InsufficientBalance` for late claimants, creating a bank-run scenario where validators race to claim before funds are exhausted.

Additionally, the spec requires a **3-way block reward split**: staking pool (up to 50%), ODDAO (10%), and block producer (remainder). This contract distributes **100%** of the epoch reward to validators. If the split is intended to happen within this contract, the implementation is missing. If the split happens externally before funding, then the 6.089B pre-fund should represent only the validator portion, which would require an even lower per-epoch reward.

**Impact:** Contract insolvency ~2 years before end of emission schedule. Validators who claim later lose their earned rewards. Creates perverse incentive to claim frequently rather than accumulate.

**Recommendation:**

Option A: Adjust `INITIAL_BLOCK_REWARD` to 15,217,556,000,000,000,000 (15.2176 XOM) to match the 6.089B budget exactly.

Option B: Add a solvency guard in `_distributeRewards()` that caps epoch rewards to the available balance:
```solidity
uint256 available = xomToken.balanceOf(address(this)) - totalOutstandingRewards;
if (epochReward > available) {
    epochReward = available;
}
```

Option C: If the 3-way split (50% staking / 10% ODDAO / 40% producer) should be implemented in this contract, reduce the distributed amount by the appropriate factor and transfer the staking/ODDAO portions to their respective contracts.

---

## Medium Findings

### [M-01] acceptAdminTransfer Does Not Revoke Old Admin Role

**Severity:** Medium
**Category:** Access Control
**Location:** `acceptAdminTransfer()` (lines 1484-1501)

**Description:**

When `acceptAdminTransfer()` is called, it grants `DEFAULT_ADMIN_ROLE` to the new admin (`msg.sender`) but does **not** revoke the role from the old admin. The code comment (lines 1496-1499) acknowledges this and states the old admin should "call revokeRole on themselves," but this relies on voluntary cooperation.

Furthermore, there is a variable naming bug on line 1491: `address oldAdmin = pendingAdmin` sets `oldAdmin` to the **new** admin's address (since `pendingAdmin` is the incoming admin, which equals `msg.sender`). The emitted event `AdminTransferAccepted(oldAdmin, msg.sender)` therefore logs the same address for both parameters, making the event useless for auditing who the **previous** admin was.

After a transfer, both old and new admin hold `DEFAULT_ADMIN_ROLE` simultaneously. The old admin retains full control: pause, upgrade proposals, contract reference changes, role grants, and so on.

**Impact:** Admin transfer does not actually transfer exclusive control. A compromised old admin retains full privileges indefinitely. The event log does not record who the old admin was.

**Recommendation:**

1. Store the proposer's address (the current admin) when `proposeAdminTransfer` is called.
2. In `acceptAdminTransfer`, revoke `DEFAULT_ADMIN_ROLE` from the stored proposer.
3. Fix the event to correctly log the old and new admin addresses.

```solidity
// In proposeAdminTransfer:
adminTransferProposer = msg.sender;

// In acceptAdminTransfer:
address oldAdmin = adminTransferProposer;
_revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
_grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
emit AdminTransferAccepted(oldAdmin, msg.sender);
```

---

### [M-02] Offline Validators Can Retroactively Earn Rewards via Stale Heartbeat State

**Severity:** Medium
**Category:** Business Logic / Gaming
**Location:** `processMultipleEpochs()` (lines 1020-1086), `_computeEpochWeights()` (line 1940)

**Description:**

`_computeEpochWeights()` checks `isValidatorActive()` against `block.timestamp`, not against the epoch's historical timestamp. When processing a backlog of unprocessed epochs, a validator that was offline during those epochs can:

1. Come online and call `submitHeartbeat()` to become active
2. Immediately call `processMultipleEpochs(50)` to process the backlog
3. Receive rewards for all 50 epochs as if they were active the entire time

The validator can repeat this pattern: go offline, let epochs accumulate (up to the batch cap), come back online briefly, process the batch, and collect rewards. This is strictly more profitable than staying online continuously, as the validator avoids infrastructure costs during offline periods.

While Round 3 acknowledged this as "accepted behavior" (M-03), the V2 change to **permissionless** epoch processing significantly amplifies the risk. Previously, only `BLOCKCHAIN_ROLE` could process epochs, providing an implicit governance check. Now any validator can call `processMultipleEpochs` immediately after submitting a heartbeat.

**Impact:** Validators can earn up to 50 epochs of unearned rewards per batch by strategically going offline and only coming online to process and claim.

**Recommendation:**

Record the epoch number at which each validator last submitted a heartbeat. In `_computeEpochWeights`, compare the epoch being processed against the validator's heartbeat epoch rather than current `block.timestamp`:

```solidity
mapping(address => uint256) public lastHeartbeatEpoch;

function submitHeartbeat() external whenNotPaused {
    // ...existing checks...
    lastHeartbeat[msg.sender] = block.timestamp;
    lastHeartbeatEpoch[msg.sender] = getCurrentEpoch();
}

// In _computeEpochWeights, replace isValidatorActive() with:
// epoch <= lastHeartbeatEpoch[validator] + (HEARTBEAT_TIMEOUT / EPOCH_DURATION)
```

---

## Low Findings

### [L-01] Redundant Transaction Count Storage Wastes Gas

**Severity:** Low
**Category:** Gas Optimization
**Location:** `recordTransactionProcessing()` (lines 852-875), `recordMultipleTransactions()` (lines 885-915)

**Description:**

Two separate mappings track the same per-validator per-epoch transaction count:
- `_epochTxnCount[epoch][validator]` (used for cap enforcement)
- `transactionsProcessed[validator][epoch]` (used for weight calculation)

Both store identical values with reversed key ordering. The `_epochTxnCount` mapping exists solely because Round 4 added the cap check, but it could have used the existing `transactionsProcessed` mapping instead.

**Impact:** ~5,000 extra gas per `recordTransactionProcessing` call (one redundant SSTORE).

**Recommendation:** Remove `_epochTxnCount` and use `transactionsProcessed` for the cap check:
```solidity
if (transactionsProcessed[validator][currentEpoch]
    >= MAX_TXN_PER_EPOCH_PER_VALIDATOR) {
    revert TxnCapExceeded();
}
```

---

### [L-02] setRewardMultiplier with multiplier=100 Is a No-Op That Clears Penalty Timer

**Severity:** Low
**Category:** Business Logic Edge Case
**Location:** `setRewardMultiplier()` (lines 1310-1338)

**Description:**

Setting `rewardMultiplier[validator] = 100` with `setRewardMultiplier(validator, 100, "reason")` has the following behavior:

1. The multiplier value 100 is stored (passes `multiplier > 100` check)
2. Since `multiplier != 0 && multiplier < 100` is **false** (100 is not < 100), the penalty expiry is **cleared**
3. In `_computeEpochWeights`, when `mult = 100`: `baseWeight = (baseWeight * 100) / 100 = baseWeight` (no change)

So `multiplier = 100` behaves identically to `multiplier = 0` (both give 100% rewards, neither has an expiry). However, `multiplier = 100` still causes `mult != 0` to be true in `_computeEpochWeights`, triggering the penalty expiry check code path (which finds no expiry and applies the 100% multiplication anyway).

More importantly, PENALTY_ROLE can set multiplier to 100 to clear a validator's penalty expiry timer without actually removing the penalty. If a validator had `multiplier = 50` with 25 days remaining on the 30-day timer, PENALTY_ROLE setting it to 100 clears the timer while ostensibly "restoring" the validator. But then setting it back to 50 restarts the 30-day clock.

**Impact:** Minor confusion and a subtle mechanism for PENALTY_ROLE to reset penalty timers.

**Recommendation:** Document that `multiplier = 100` is equivalent to "restore to full" and is the canonical way to clear a penalty. Alternatively, treat 100 the same as 0 in `_computeEpochWeights`.

---

### [L-03] Validator Cap Creates Deterministic Exclusion for Validators Beyond Index 200

**Severity:** Low
**Category:** Fairness / Denial of Service
**Location:** `_computeEpochWeights()` (line 1932-1934), `_resetExpiredPenalties()` (line 1843-1845)

**Description:**

Both `_computeEpochWeights` and `_resetExpiredPenalties` iterate at most `MAX_VALIDATORS_PER_EPOCH` (200) validators from the array returned by `omniCore.getActiveNodes()`. If the validator set exceeds 200, validators at indices 201+ receive zero weight (zero rewards) and their expired penalties are never cleaned up.

If `getActiveNodes()` returns validators in a deterministic order (e.g., registration order), the same validators are consistently excluded. This creates a permanent denial of rewards for late-registered validators when the network exceeds 200 participants.

The `ValidatorSetCapped` event is emitted (line 1039-1043 in `processMultipleEpochs`), but only in the batch function, not in `processEpoch`.

**Impact:** Validators beyond index 200 earn zero rewards. If ordering is deterministic, this permanently disadvantages late registrants.

**Recommendation:**
1. Ensure `OmniCore.getActiveNodes()` returns validators in a rotation or randomized order so that exclusion is distributed fairly.
2. Emit `ValidatorSetCapped` in `processEpoch` as well (currently only in `processMultipleEpochs`).
3. Consider increasing `MAX_VALIDATORS_PER_EPOCH` or implementing a rotation mechanism in this contract.

---

## Informational Findings

### [I-01] PENALTY_ROLE Not Granted at Initialization

**Severity:** Informational
**Category:** Access Control Setup
**Location:** `initialize()` (lines 766-800)

**Description:**

The `initialize()` function grants `DEFAULT_ADMIN_ROLE`, `BLOCKCHAIN_ROLE`, and `ROLE_MANAGER_ROLE` to the deployer, but does **not** grant `PENALTY_ROLE`. This means no address can call `setRewardMultiplier()` until the admin explicitly grants `PENALTY_ROLE` to an address.

This is likely intentional (penalties should not be needed during initial setup), but it means the penalty system is inoperative until post-deployment configuration.

**Recommendation:** Document this as expected behavior. Consider adding a deployment checklist that includes granting `PENALTY_ROLE`.

---

### [I-02] submitHeartbeat Uses msg.sender While claimRewards Uses _msgSender()

**Severity:** Informational
**Category:** Consistency
**Location:** `submitHeartbeat()` (line 830), `claimRewards()` (line 1104)

**Description:**

`submitHeartbeat()` uses `msg.sender` directly, preventing heartbeat submission via meta-transactions (ERC-2771). `claimRewards()` uses `_msgSender()`, allowing claims via the trusted forwarder. `recordTransactionProcessing()` also uses a direct `validator` parameter (not `msg.sender` at all).

This inconsistency is likely intentional (heartbeats prove liveness and should come from the validator directly), but it creates an asymmetry where a validator can claim rewards via meta-tx but cannot submit heartbeats via meta-tx. If the validator node is behind a NAT or cannot submit transactions directly, it can claim but not prove liveness.

**Recommendation:** Document the intentional design choice. If meta-tx heartbeats are desired in the future, add an overloaded `submitHeartbeatFor(address validator)` with appropriate authorization.

---

### [I-03] processEpoch Increments totalBlocksProduced Even When No Validators Are Active

**Severity:** Informational
**Category:** Accounting
**Location:** `processEpoch()` (lines 959-963)

**Description:**

When `activeCount == 0` in `processEpoch`, the function increments `totalBlocksProduced` and advances `lastProcessedEpoch`, but the epoch reward is effectively discarded (never distributed). The NatSpec states `totalBlocksProduced` is "for monitoring only," but its value will not accurately reflect blocks that generated actual rewards. It simply counts processed epochs regardless of reward distribution.

Similarly in `processMultipleEpochs` (line 1078), `totalBlocksProduced` is incremented for every epoch including those with zero active validators.

**Impact:** Monitoring dashboards may show inflated block counts relative to actual reward-generating blocks.

**Recommendation:** Either rename to `totalEpochsProcessed` for clarity, or only increment when `activeCount > 0`.

---

## Business Logic Verification

### Block Reward Schedule

| Parameter | Spec (CLAUDE.md) | Contract | Status |
|-----------|------------------|----------|--------|
| Initial reward | 15.602 XOM/block | `INITIAL_BLOCK_REWARD = 15_602_000_000_000_000_000` (15.602e18) | **MATCHES** |
| Reduction interval | Every 6,311,520 blocks | `BLOCKS_PER_REDUCTION = 6_311_520` | **MATCHES** |
| Reduction amount | 1% per period | `REDUCTION_FACTOR = 99, REDUCTION_DENOMINATOR = 100` | **MATCHES** |
| Zero reward cutoff | After 631,152,000 blocks | `MAX_REDUCTIONS = 100` (100 * 6,311,520 = 631,152,000) | **MATCHES** |
| Total duration | ~40 years | 631,152,000 * 2s = 40.00 years | **MATCHES** |
| Total emissions target | 6.089 billion XOM | Actual: ~6.243 billion XOM | **MISMATCH** (see H-01) |
| Block time | 2 seconds | `EPOCH_DURATION = 2` | **MATCHES** |

### Distribution Split

| Parameter | Spec (CLAUDE.md) | Contract | Status |
|-----------|------------------|----------|--------|
| Staking pool | Up to 50% | Not implemented | **MISSING** |
| ODDAO | 10% | Not implemented | **MISSING** |
| Block producer | Remainder | 100% to weighted validators | **DIFFERENT** |

**Note:** The contract distributes 100% of epoch rewards to validators based on weighted participation. The spec calls for a 3-way split. Either the split is handled externally (before funding) or the contract is missing this logic. See H-01 for details.

### Weight Calculation

| Component | Spec | Contract | Status |
|-----------|------|----------|--------|
| Participation score | 40% weight | `PARTICIPATION_WEIGHT = 40` | **MATCHES** |
| Staking amount | 30% weight | `STAKING_WEIGHT = 30` | **MATCHES** |
| Activity | 30% weight | `ACTIVITY_WEIGHT = 30` | **MATCHES** |
| Heartbeat sub-weight | 60% of activity | `HEARTBEAT_SUBWEIGHT = 60` | **MATCHES** |
| Tx processing sub-weight | 40% of activity | `TX_PROCESSING_SUBWEIGHT = 40` | **MATCHES** |

### Epoch Management

| Check | Result |
|-------|--------|
| Sequential enforcement | `epoch != lastProcessedEpoch + 1` reverts `EpochNotSequential` -- **CORRECT** |
| Future epoch prevention | `epoch > currentEpoch` reverts `FutureEpoch` -- **CORRECT** |
| Batch cap | `MAX_BATCH_EPOCHS = 50` enforced -- **CORRECT** |
| First epoch | `lastProcessedEpoch` starts at 0, first call requires epoch 1 -- **CORRECT** |
| Last epoch | After `MAX_REDUCTIONS` (epoch 631,152,000+), reward is 0 -- **CORRECT** |
| Partial epoch | Not applicable (epochs are discrete 2-second intervals) |

### Staking Tier Scores

| Amount | Expected Score | Contract Score | Status |
|--------|---------------|----------------|--------|
| 0 | 0 | 0 | **MATCHES** |
| 500K XOM | 10 | `(500K * 20) / 1M = 10` | **MATCHES** |
| 1M XOM | 20 | `20 + (0 * 20) / 9M = 20` | **MATCHES** |
| 5M XOM | ~28.9 | `20 + (4M * 20) / 9M = 28.89` | **MATCHES** |
| 10M XOM | 40 | `40 + (0 * 20) / 90M = 40` | **MATCHES** |
| 1B XOM | 80 | `80 + (0 * 20) / 9B = 80` | **MATCHES** |
| 10B+ XOM | 100 | `100` (cap) | **MATCHES** |

---

## DeFi Exploit Analysis

### Can a validator claim rewards multiple times per epoch?

**No.** Rewards are accumulated in `accumulatedRewards[caller]`. The `claimRewards()` function transfers the full accumulated balance and zeroes it atomically (CEI pattern). There is no per-epoch claiming; rewards accumulate across all processed epochs and are claimed in aggregate. The `nonReentrant` modifier prevents reentrancy-based double-claims.

### Can a validator manipulate epoch boundaries?

**No.** Epoch numbers are derived deterministically from `(block.timestamp - genesisTimestamp) / EPOCH_DURATION`. A validator cannot change `genesisTimestamp` (set once in `initialize()`) or manipulate `block.timestamp` beyond the validator timestamp tolerance (~1 second on Avalanche). The sequential enforcement (`epoch == lastProcessedEpoch + 1`) prevents skipping or replaying epochs.

### Flash-loan to inflate validator stake?

**Mitigated.** The `_calculateStakingComponent` function checks `stake.lockTime < block.timestamp + 1` (equivalent to `lockTime <= block.timestamp`), rejecting any stake whose lock has expired or expires in the current block. A flash-staker with zero or minimal lock duration would have their stake rejected. A same-block stake with `lockTime = block.timestamp + 1` would pass, but this requires a genuine OmniCore stake transaction (not a flash-loan) since OmniCore enforces staking lock durations.

### What happens if epoch processing is delayed?

**Partial vulnerability.** Epochs accumulate and can be batch-processed (up to 50 at a time). The core issue is that historical epochs are processed using current validator state (heartbeats, stakes, participation scores), not the state at the time of the epoch. This creates the gaming vector described in M-02. The maximum staleness window per batch is 100 seconds (50 epochs x 2s), which is documented as accepted.

### Can rewards be front-run?

**Not directly.** `processEpoch` distributes rewards to validators based on weight; it does not send tokens. Only `claimRewards()` transfers tokens, and it uses `_msgSender()` to identify the claimant. A front-runner cannot claim another validator's rewards. However, a validator can front-run `processEpoch` with a `submitHeartbeat` to appear active for an epoch where they were offline (see M-02).

### Integer overflow in large reward calculations?

**Not possible.** Solidity 0.8.24 provides built-in overflow protection. The maximum value in reward calculations is `epochReward * maxWeight = 15.602e18 * 150 = 2.34e21`, well within the uint256 range (~1.16e77). All `unchecked` blocks contain only loop counter increments bounded by loop conditions.

---

## Previous Audit Fix Verification

### Round 4 Fixes (2026-02-28)

| Finding | Fix | Verified |
|---------|-----|----------|
| H-01: emergencyWithdraw XOM bypass | `_originalXomToken` stored at init, checked in emergencyWithdraw | **VERIFIED** (lines 418, 1287-1291) |
| M-01: roleMultiplier uncapped | `MAX_ROLE_MULTIPLIER = 15000` (1.5x cap) | **VERIFIED** (line 257, 1358) |
| M-02: Indefinite penalty suppression | `MAX_PENALTY_DURATION = 30 days`, auto-expiry | **VERIFIED** (lines 264, 1321-1326) |
| M-03: Stale validator state in batch | Documented as accepted, bounded to 100s | **VERIFIED** (lines 998-1004) |
| M-04: Per-epoch per-validator txn cap | `MAX_TXN_PER_EPOCH_PER_VALIDATOR = 1000` | **VERIFIED** (lines 270, 861-867) |
| M-05: claimRewards blocked during pause | Removed `whenNotPaused` from `claimRewards` | **VERIFIED** (line 1100, no whenNotPaused modifier) |
| L-02: Sub-base roleMultiplier rejected | `MultiplierBelowBase` error for values 1-9999 | **VERIFIED** (lines 1363-1367) |
| I-01: nonReentrant placed first | `nonReentrant` is first modifier on `processEpoch` | **VERIFIED** (line 931) |
| I-03: Single division for activity | `numerator / 10000` instead of multiple divisions | **VERIFIED** (lines 2140-2145) |

### V2 Changes (2026-03)

| Change | Implementation | Assessment |
|--------|---------------|------------|
| Permissionless processEpoch | `BLOCKCHAIN_ROLE` removed from modifier | **VERIFIED** -- Sequential enforcement prevents double-processing |
| Auto role multiplier from Bootstrap | `_bootstrapRoleMultiplier()` with try/catch | **VERIFIED** -- Graceful fallback to 1.0x on failure |
| Two-step admin transfer | `proposeAdminTransfer` + `acceptAdminTransfer` with 48h delay | **PARTIAL** -- Does not revoke old admin (see M-01) |
| Minimum stake for rewards | `minStakeForRewards` with `stakeExempt` mapping | **VERIFIED** -- Prevents Sybil dilution |

---

## Gas Analysis

| Function | Estimated Gas (200 validators) | Notes |
|----------|-------------------------------|-------|
| `processEpoch` | ~2.5M gas | 200 external calls to participation + omniCore |
| `processMultipleEpochs(50)` | ~100M gas | 50 * 200 weight calculations; may exceed block gas limit |
| `claimRewards` | ~60K gas | Single SSTORE + SafeERC20 transfer |
| `submitHeartbeat` | ~45K gas | Single SSTORE + event |
| `recordTransactionProcessing` | ~65K gas | 3 SSTOREs (redundant, see L-01) |

**Note:** `processMultipleEpochs(50)` with 200 validators performs 10,000 external calls. On Avalanche with an 8M block gas limit, this may fail. Consider reducing `MAX_BATCH_EPOCHS` or `MAX_VALIDATORS_PER_EPOCH` if gas limits are hit in production.

---

## Security Properties Summary

| Property | Status |
|----------|--------|
| Reentrancy protection | All state-changing functions use `nonReentrant` |
| CEI pattern | `claimRewards` updates state before external transfer |
| Access control | Role-based via OpenZeppelin AccessControl |
| Upgrade safety | UUPS with 48h timelock + ossification |
| Integer overflow | Solidity 0.8.24 built-in protection |
| Flash-stake protection | Lock expiry check in `_calculateStakingComponent` |
| Solvency tracking | `totalOutstandingRewards` accumulator |
| Emergency controls | Pause/unpause + emergencyWithdraw (non-XOM only) |
| Epoch integrity | Sequential enforcement prevents double-processing |
| External call resilience | All external calls wrapped in try/catch |
| DoS protection | Validator cap (200) + batch cap (50) + txn cap (1000) |

---

## Recommendations Summary

| # | Severity | Finding | Recommendation |
|---|----------|---------|----------------|
| H-01 | High | Emission over-allocation (~154M XOM deficit) | Reduce `INITIAL_BLOCK_REWARD` to 15.2176e18, or add solvency guard in `_distributeRewards`, or implement 3-way split |
| M-01 | Medium | acceptAdminTransfer does not revoke old admin | Store proposer address and revoke their role atomically |
| M-02 | Medium | Offline validators earn retroactive rewards | Track heartbeat epoch and compare against processed epoch |
| L-01 | Low | Redundant transaction count storage | Remove `_epochTxnCount`, use `transactionsProcessed` |
| L-02 | Low | multiplier=100 edge case with penalty timer | Document or normalize to 0 |
| L-03 | Low | Deterministic validator exclusion at >200 | Rotate ordering or increase cap |
| I-01 | Info | PENALTY_ROLE not granted at init | Document as expected |
| I-02 | Info | msg.sender vs _msgSender inconsistency | Document design choice |
| I-03 | Info | totalBlocksProduced counts empty epochs | Rename or guard increment |

---

## Conclusion

OmniValidatorRewards V2 is a well-structured contract with comprehensive security measures accumulated over four prior audit rounds. The UUPS upgrade timelock, ossification mechanism, penalty expiry, per-epoch transaction caps, and external call resilience are all correctly implemented.

The critical finding (H-01) is the emission schedule math: the contract will distribute ~154M XOM more than its pre-funded balance, causing insolvency around year 38. This must be resolved before mainnet deployment by either adjusting the initial block reward constant, adding a solvency cap, or clarifying the relationship with the 3-way block reward split described in the specification.

The admin transfer (M-01) should be hardened to atomically revoke the old admin's role. The heartbeat gaming vector (M-02) should be considered in the context of the permissionless epoch processing change, which removed the governance check that previously mitigated this risk.

**Overall Risk Rating: 5/10** (pre-ossification), dropping to **3/10** after ossification and H-01 fix.

---

*Report generated: 2026-03-10 01:04 UTC*
*Auditor: Claude Code Audit Agent (Round 6 Pre-Mainnet)*
*Contract hash: OmniValidatorRewards.sol (2,332 lines, Solidity 0.8.24)*
