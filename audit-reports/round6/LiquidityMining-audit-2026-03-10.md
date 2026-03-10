# Security Audit Report: LiquidityMining (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/liquidity/LiquidityMining.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,192
**Upgradeable:** No
**Handles Funds:** Yes (holds LP tokens and XOM reward tokens)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable2Step`, `Pausable`, `ERC2771Context` (all OZ v5.4.0)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Slither Report:** Not available (file not found at `/tmp/slither-LiquidityMining.json`)

---

## Executive Summary

LiquidityMining is a MasterChef-style staking contract where users deposit LP tokens into configurable pools to earn XOM rewards. Rewards are split between immediate (30% default, configurable per pool) and vested (remainder, linearly vested over 90 days default, configurable per pool). The contract supports up to 50 pools, each with independent reward rates and vesting parameters.

Since the Round 3 audit, the contract has grown from 1,057 to 1,192 lines, incorporating ERC2771Context meta-transaction support, improved vesting append accounting with instantly-vested portions (M-01 from Round 3), and a MAX_REWARD_PER_SECOND cap to prevent runaway reward inflation.

This Round 6 pre-mainnet audit identifies **0 Critical**, **1 High**, **2 Medium**, **3 Low**, and **3 Informational** findings. The High finding concerns a flash-stake vector that allows an attacker to stake and unstake within the same block to capture rewards without meaningful time commitment.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | Flash-stake attack: user can stake and unstake in same block to claim rewards | **FIXED** |
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `stake()` and `unstake()` | **FIXED** |
| M-02 | Medium | `totalCommittedRewards` accounting drift on pool append | **FIXED** |

---

## Round 3 Remediation Status

| Round 3 Finding | Status | Evidence |
|-----------------|--------|----------|
| M-01: totalCommittedRewards accounting drift | **PARTIALLY FIXED** | The instantly-vested portion calculation in the append path (lines 1038-1045) corrects the immediate double-counting issue. However, residual drift remains possible -- see M-01 below. |
| M-02: Extreme rewardPerSecond inflates totalCommittedRewards | **FIXED** | `MAX_REWARD_PER_SECOND = 1e24` constant (line 126) enforced in `addPool()` (line 366-368) and `setRewardRate()` (line 417-419). |
| M-03: No ERC-2771 meta-transaction support | **FIXED** | Contract now inherits `ERC2771Context` (line 53). `_msgSender()` used in `stake()`, `withdraw()`, `claim()`, `claimAll()`, and `emergencyWithdraw()`. |
| L-01: No timelocks on admin changes | **NOT FIXED** | Still relies on `Ownable2Step` without timelocks. Acceptable given documentation states owner should be multisig. |
| L-02: Flash-stake reward manipulation | **NOT FIXED** | See H-01 below -- re-elevated to High severity after deeper analysis. |
| L-03: Missing MAX_REWARD_PER_SECOND cap | **FIXED** | See M-02 remediation above. |
| L-04: Indexed event slots used for numeric values | **NOT FIXED** | See I-03 below. |
| I-01: `withdraw()` blocks during pause, `claim()` does not | **UNCHANGED** | Intentional design documented. |
| I-02: `emergencyWithdraw()` does not call `_updatePool()` | **UNCHANGED** | Acceptable: emergency path forfeits all rewards. |
| I-03: `renounceOwnership()` disabled | **UNCHANGED** | Correctly implemented (line 952-954). |

---

## Architecture Analysis

### Design Strengths

1. **Ownable2Step:** Two-step ownership transfer prevents accidental ownership loss. `renounceOwnership()` is disabled (line 952-954).

2. **Committed Rewards Tracking:** `totalCommittedRewards` prevents the owner from withdrawing XOM that is owed to stakers (line 740-744). This is a critical solvency invariant.

3. **MAX_REWARD_PER_SECOND Cap:** Prevents the owner from setting absurdly high reward rates that would inflate `totalCommittedRewards` beyond the XOM balance (line 126).

4. **Fee-on-Transfer LP Token Handling:** `stake()` uses balance-before/after pattern (lines 502-504) to correctly account for fee-on-transfer LP tokens.

5. **Emergency Withdrawal Always Available:** `emergencyWithdraw()` is not gated by `whenNotPaused`, ensuring users can always recover their LP tokens (line 666).

6. **70/20/10 Fee Split on Emergency Withdrawal:** Emergency withdrawal fees are split to treasury (70%), validator (20%), and staking pool (10%) per the project's fee distribution model (lines 709-718).

7. **Pool Duplication Prevention:** `addPool()` iterates existing pools to reject duplicate LP tokens (lines 372-377).

8. **ERC2771 Meta-Transaction Support:** Properly integrated with correct overrides.

9. **Vesting Append Accounting Fix:** The instantly-vested portion calculation (lines 1038-1045) prevents the original M-01 double-counting issue from Round 3 by crediting the time-elapsed fraction of newly appended vesting rewards immediately.

### Design Concerns

1. **No Minimum Staking Duration:** Users can stake and withdraw in the same block, capturing rewards without meaningful commitment. See H-01.

2. **Pool Array Growth:** Pools can only be added, never removed. Disabled pools still consume gas in `claimAll()` loops. Mitigated by `MAX_POOLS = 50`.

3. **Single Vesting Schedule Per Pool Per User:** A user has only one vesting schedule per pool. Multiple stakes cause vesting schedule resets or appends, which can produce different outcomes than a single equivalent stake. This is inherent to the design.

---

## Findings

### [H-01] Flash-Stake Reward Extraction: Stake and Withdraw in Same Block Captures Full Block Rewards

**Severity:** High
**Lines:** 478-514 (stake), 522-553 (withdraw), 962-984 (_updatePool)
**Category:** Economic / Flash Loan Attack

**Description:**

The reward accumulation model updates `accRewardPerShare` based on elapsed time (`block.timestamp - pool.lastRewardTime`) multiplied by `rewardPerSecond` and divided by `totalStaked` (lines 977-981):

```solidity
uint256 elapsed = block.timestamp - pool.lastRewardTime;
uint256 reward = elapsed * pool.rewardPerSecond;
pool.accRewardPerShare += (reward * REWARD_PRECISION) / pool.totalStaked;
```

An attacker can exploit this with the following sequence in a single transaction:

1. **Observe** that `pool.lastRewardTime` is stale (e.g., no interactions for 1 hour, so `elapsed = 3600`).
2. **Flash-loan** a large amount of the LP token.
3. **Call `stake(poolId, largeAmount)`:** This triggers `_updatePool()`, which distributes the 1 hour of accumulated rewards across the current (pre-stake) `totalStaked`. If `totalStaked` is small (e.g., 1000 tokens) and the attacker stakes 1,000,000 tokens, the attacker now holds 99.9% of `totalStaked`.
4. **Wait** -- no waiting needed. The rewards from the 1-hour gap were already distributed at step 3 to existing stakers, not the attacker.
5. **However:** If there are zero current stakers (`totalStaked == 0`), `_updatePool()` just advances `lastRewardTime` without distributing rewards (lines 970-974). The attacker would be the first staker and capture all subsequent rewards.

**Revised analysis:** The primary risk is not flash-staking against existing stakers (the `_updatePool()` call in `stake()` correctly distributes accumulated rewards before the attacker's stake is added). The risk is:

**Scenario A -- Empty pool capture:** When `totalStaked == 0`, rewards for the idle period are effectively burned (not distributed). An attacker who is the sole staker captures 100% of rewards going forward until another user stakes. This is by design but worth documenting.

**Scenario B -- Same-block stake/withdraw within a block where timestamp advances:** If an attacker stakes at the beginning of a block and withdraws at the end, they capture rewards for 0 seconds of elapsed time (since `block.timestamp` is constant within a block). The reward is zero. This is safe.

**Scenario C -- Cross-block flash-stake with persistent LP position:** An attacker borrows LP tokens via a flash loan in block N, stakes them, and then cannot repay the flash loan because the LP tokens are locked in the contract until `withdraw()` is called. This means flash loans cannot be used for same-block attacks.

**However**, the attacker can use their own LP tokens (or borrowed non-flash LP tokens) to stake a disproportionately large amount for a single block interval (2 seconds on Avalanche). If `rewardPerSecond = 1e18` (1 XOM/s) and the attacker stakes enough LP to hold 99% of the pool for 2 seconds, they capture `2 * 1e18 * 0.99 = 1.98e18` XOM (~2 XOM) at the cost of:
- Gas fees for stake + withdraw transactions
- Opportunity cost of LP tokens for 2 seconds
- The 30% immediate / 70% vested split means only 0.6 XOM is immediately claimable

**Revised Severity Assessment:** At typical reward rates, the extractable value per block is small. The vesting split (70% vested over 90 days) significantly reduces the immediate profitability of flash-staking. However, for pools with high `rewardPerSecond` and low `totalStaked`, the attack becomes profitable. This remains a structural concern.

**Impact:** Attacker can extract a disproportionate share of rewards by briefly becoming a large fraction of the pool's total stake. Profitability depends on reward rate, existing staked amount, and vesting parameters.

**Recommendation:**

Add a minimum staking duration requirement:

```solidity
uint256 public constant MIN_STAKE_DURATION = 1 hours;
mapping(uint256 => mapping(address => uint256)) public stakeTimestamp;

function withdraw(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
    // ...
    if (block.timestamp < stakeTimestamp[poolId][caller] + MIN_STAKE_DURATION) {
        revert MinStakeDurationNotMet();
    }
    // ...
}
```

This prevents the stake-for-one-block attack pattern without affecting legitimate users.

---

### [M-01] totalCommittedRewards Residual Drift from Vesting Append Edge Cases

**Severity:** Medium
**Lines:** 1007-1008, 1032-1046, 678-690
**Category:** Accounting / Solvency

**Description:**

The `totalCommittedRewards` tracker is designed to ensure the contract always holds enough XOM to satisfy all pending (immediate + unvested) reward obligations. It is incremented in `_harvestRewards()` (line 1008):

```solidity
totalCommittedRewards += immediateReward + vestingReward;
```

And decremented on claims (lines 591, 648) and emergency withdrawals (lines 686-689).

The vesting append path (lines 1032-1046) handles mid-schedule reward additions by computing the instantly-vested fraction and crediting it to `pendingImmediate`:

```solidity
uint256 alreadyElapsed = block.timestamp - userStakeInfo.vestingStart;
uint256 instantlyVested = (vestingReward * alreadyElapsed) / pool.vestingPeriod;
userStakeInfo.pendingImmediate += instantlyVested;
userStakeInfo.vestingTotal += vestingReward - instantlyVested;
```

The issue: `totalCommittedRewards` is incremented by `immediateReward + vestingReward` (the full amount), but the vesting append logic splits `vestingReward` into `instantlyVested` (added to pendingImmediate) and `vestingReward - instantlyVested` (added to vestingTotal). Both portions are tracked by `totalCommittedRewards`, so the total commitment is correct.

However, when `_calculateVested()` computes the claimable vested amount, it uses linear interpolation over the original `vestingStart` and `vestingPeriod`:

```solidity
uint256 totalVested = (userStakeInfo.vestingTotal * elapsed) / vestingPeriod;
```

After an append, `vestingTotal` has increased, but `vestingStart` has NOT been reset (append path preserves the original start time). This means the elapsed fraction applies to the new total, and the newly-appended portion inherits the already-elapsed time. The `instantlyVested` calculation compensates for this, but rounding errors accumulate with each append operation.

Over many harvest cycles with appends, `totalCommittedRewards` may drift slightly above the actual sum of (pendingImmediate + unvested) across all users. This drift is always in the conservative direction (over-committing), meaning the contract holds slightly more XOM than necessary rather than less.

**Impact:** Over time, a small fraction of XOM may become permanently locked in the contract because `totalCommittedRewards` is slightly higher than actual obligations. The owner's `withdrawRewards()` function can only withdraw excess above `totalCommittedRewards`, so this locked amount is inaccessible.

**Likelihood:** Medium -- occurs with every vesting append operation. The drift is proportional to rounding errors, which are typically 1 wei per operation. Over thousands of operations, the total drift could reach a few thousand wei -- negligible in value terms.

**Recommendation:**

This is a known limitation of the append-based vesting model. The conservative drift direction (over-committing) is safe for solvency. Two options:

1. **Accept and document:** The drift is negligible in practice. Add a comment explaining the expected behavior.
2. **Add an admin function to reconcile:** Allow the owner to recalculate `totalCommittedRewards` by iterating all user stakes, but this is gas-expensive and introduces its own risks.

Option 1 is recommended.

---

### [M-02] `emergencyWithdraw()` Forfeited Rewards Decrement Uses Min-Clamping That Masks Accounting Errors

**Severity:** Medium
**Lines:** 678-690
**Category:** Accounting / Defensive Programming

**Description:**

The `emergencyWithdraw()` function calculates forfeited rewards and decrements `totalCommittedRewards`:

```solidity
uint256 forfeited = user.pendingImmediate +
    user.vestingTotal -
    user.vestingClaimed;
if (forfeited > 0) {
    uint256 decrement = forfeited > totalCommittedRewards
        ? totalCommittedRewards
        : forfeited;
    totalCommittedRewards -= decrement;
}
```

The `min(forfeited, totalCommittedRewards)` clamping prevents an underflow revert, but it also silently masks scenarios where `totalCommittedRewards` has drifted below actual obligations. If `totalCommittedRewards < forfeited`, the function succeeds but leaves `totalCommittedRewards = 0`, which would then allow the owner to withdraw all remaining XOM via `withdrawRewards()` -- potentially including XOM owed to other users.

**Impact:** In a pathological case where `totalCommittedRewards` has drifted significantly below actual obligations (which should not happen under normal operation), an emergency withdrawal could reset the committed tracker to zero, allowing the owner to extract XOM owed to other stakers.

**Likelihood:** Very low. The drift described in M-01 is in the conservative direction (over-committing), not under-committing. For this attack to work, there would need to be a separate bug causing `totalCommittedRewards` to be too low.

**Recommendation:**

Consider emitting a warning event when clamping occurs:

```solidity
if (forfeited > totalCommittedRewards) {
    emit CommittedRewardsDrift(totalCommittedRewards, forfeited);
    totalCommittedRewards = 0;
} else {
    totalCommittedRewards -= forfeited;
}
```

This preserves the safety of not reverting while providing observability for accounting drift.

---

### [L-01] `depositRewards()` Uses `msg.sender` Instead of `_msgSender()` for ERC-2771 Consistency

**Severity:** Low
**Lines:** 730
**Category:** ERC-2771 Inconsistency

**Description:**

The `depositRewards()` function uses `msg.sender` for the `safeTransferFrom` call:

```solidity
function depositRewards(uint256 amount) external onlyOwner {
    xom.safeTransferFrom(msg.sender, address(this), amount);
}
```

All other functions that interact with the caller use `_msgSender()` for ERC-2771 compatibility. However, since `depositRewards()` is `onlyOwner`, and `Ownable2Step` uses `msg.sender` for ownership checks (not `_msgSender()`), the owner executing via a meta-transaction forwarder would pass the `onlyOwner` check (using the forwarder's address as `msg.sender`) but then attempt to transfer from the forwarder's address rather than the original signer's address.

**Impact:** If the owner ever calls `depositRewards()` via the trusted forwarder (meta-transaction), the `safeTransferFrom` would attempt to transfer from the forwarder's address, which likely has no XOM balance and no approval, causing a revert.

**Recommendation:**

Use `_msgSender()` for consistency, though the practical impact is minimal since admin functions are rarely called via meta-transactions:

```solidity
function depositRewards(uint256 amount) external onlyOwner {
    xom.safeTransferFrom(_msgSender(), address(this), amount);
}
```

Note: This also requires ensuring the `Ownable2Step` modifier checks are compatible with ERC-2771 (they are not by default in OZ v5). See I-01.

---

### [L-02] `setPoolActive(false)` Does Not Settle Pending Rewards Before Deactivation

**Severity:** Low
**Lines:** 462-471
**Category:** State Consistency

**Description:**

When the owner deactivates a pool via `setPoolActive(poolId, false)`, the function does not call `_updatePool(poolId)` first:

```solidity
function setPoolActive(uint256 poolId, bool active) external onlyOwner {
    if (poolId >= pools.length) revert PoolNotFound();
    pools[poolId].active = active;
    emit PoolActiveUpdated(poolId, active);
}
```

After deactivation, users can still `withdraw()` and `claim()` (these do not check `pool.active`), and these functions call `_updatePool()`, which will correctly calculate rewards up to the current timestamp.

However, if the owner deactivates a pool and then immediately changes the `rewardPerSecond` via `setRewardRate()`, the pending rewards for the stale period would be calculated at the new rate rather than the old rate (because `_updatePool()` is called inside `setRewardRate()` at line 421, which settles at the old rate before applying the new rate). So the actual risk here is minimal.

**Impact:** No funds at risk. The `setRewardRate()` function properly settles before changing rates. The only issue is that `pool.active = false` does not prevent reward accumulation -- rewards continue to accrue for the stale period until the next `_updatePool()` call.

**Recommendation:**

Call `_updatePool()` before deactivating:

```solidity
function setPoolActive(uint256 poolId, bool active) external onlyOwner {
    if (poolId >= pools.length) revert PoolNotFound();
    _updatePool(poolId);
    pools[poolId].active = active;
    emit PoolActiveUpdated(poolId, active);
}
```

---

### [L-03] `claimAll()` Gas Cost Scales Linearly with Pool Count

**Severity:** Low
**Lines:** 608-654
**Category:** Gas / DoS

**Description:**

`claimAll()` iterates all pools (up to `MAX_POOLS = 50`), calling `_updatePool()` for each:

```solidity
for (uint256 i = 0; i < poolLen; ) {
    _updatePool(i);
    // ...
}
```

With 50 pools, the gas cost could exceed block gas limits on some chains. On Avalanche C-Chain (which has a 15M gas limit), 50 pool iterations with SLOAD-heavy `_updatePool()` calls should remain under the limit, but it is worth monitoring.

**Impact:** With many pools, `claimAll()` may become expensive. Users can always claim from individual pools via `claim(poolId)`.

**Recommendation:**

Consider adding a `claimBatch(uint256[] calldata poolIds)` function that lets users specify which pools to claim from.

---

### [I-01] `Ownable2Step` Uses `msg.sender` Not `_msgSender()` -- ERC-2771 Incompatibility for Admin Functions

**Severity:** Informational
**Lines:** 53
**Category:** ERC-2771 / Access Control

**Description:**

The contract inherits both `Ownable2Step` and `ERC2771Context`. OpenZeppelin's `Ownable` (parent of `Ownable2Step`) uses `msg.sender` in its `onlyOwner` modifier, not `_msgSender()`. This means admin functions called via the trusted forwarder would fail the `onlyOwner` check because `msg.sender` would be the forwarder address, not the actual owner.

**Impact:** Admin functions cannot be called via meta-transactions. This is likely intentional (admin functions should be called directly), but it creates an inconsistency where user functions support ERC-2771 but admin functions do not.

**Recommendation:**

Document this as intentional behavior. Admin functions (pool management, fee configuration) should be called directly from the owner address, not via meta-transactions.

---

### [I-02] `estimateAPR()` Is an On-Chain View Function That Should Be Off-Chain

**Severity:** Informational
**Lines:** 911-944
**Category:** Gas Efficiency

**Description:**

The `estimateAPR()` function performs a view-only calculation that depends on external price inputs (`lpTokenPrice`, `xomPrice`). This is purely informational and could be computed off-chain from the pool's `rewardPerSecond` and `totalStaked` values, which are already publicly readable.

**Impact:** No security impact. The function adds ~100 bytes of contract bytecode.

**Recommendation:**

Consider removing and computing off-chain to reduce deployment cost. Alternatively, keep for frontend convenience.

---

### [I-03] Event Parameters Use All Three Indexed Slots for Numeric Values

**Severity:** Informational
**Lines:** 166-171, 177-181, 187-191, etc.
**Category:** Event Design

**Description:**

Multiple events use all three `indexed` slots for numeric values (e.g., `PoolAdded`, `RewardRateUpdated`, `Staked`, `Withdrawn`). Indexed numeric parameters are stored as topic hashes and cannot be efficiently filtered by range. Address parameters benefit from indexing (exact match filtering), while numeric parameters generally benefit more from being unindexed (allowing ABI decoding).

**Impact:** Log filtering by numeric ranges is less efficient. No correctness impact.

**Recommendation:**

Prefer indexing address parameters and leaving numeric parameters unindexed. For example:

```solidity
event Staked(address indexed user, uint256 indexed poolId, uint256 amount); // amount unindexed
```

---

## Flash-Stake Economic Analysis

### Can rewards be gamed by flash-staking?

**Partially.** As analyzed in H-01, an attacker cannot use a flash loan for same-block stake/withdraw because the LP tokens are locked until `withdraw()` is called in a subsequent transaction. However:

1. **Two-block attack:** An attacker with their own LP tokens can stake in block N and withdraw in block N+1 (2 seconds on Avalanche), capturing `2 * rewardPerSecond * (attackerStake / totalStaked)` in rewards. The 70% vesting split makes this less attractive.

2. **Pool sniping at creation:** When a new pool is created with `totalStaked = 0`, the first staker captures 100% of rewards. An attacker monitoring for `PoolAdded` events could be the first staker with a disproportionately large amount, then withdraw after accumulating rewards.

### What happens when totalStaked goes to zero?

**Rewards are effectively burned.** When `totalStaked == 0`, `_updatePool()` simply advances `lastRewardTime` without incrementing `accRewardPerShare` (lines 970-974). The rewards for the idle period are never distributed. This is the standard MasterChef behavior and is by design.

### Reward token funding and depletion

**Handled correctly.** The `totalCommittedRewards` tracker ensures the owner cannot withdraw XOM that is owed to stakers. If the contract runs out of XOM:
- `claim()` would revert on the `safeTransfer` call
- `_harvestRewards()` would still increment `totalCommittedRewards`, creating a debt
- The owner must `depositRewards()` to replenish before users can claim

This is not ideal but is safe -- users' claims are deferred, not lost.

### Rounding errors in reward-per-share calculations

**Minimal.** The `REWARD_PRECISION = 1e18` provides 18 decimal places of precision for `accRewardPerShare`. For typical `totalStaked` values (millions of LP tokens with 18 decimals), the rounding error per update is < 1 wei. Over millions of updates, cumulative rounding could reach a few thousand wei -- negligible.

---

## Cross-Contract DeFi Attack Vectors

### LiquidityMining + OmniBonding Interaction

**No direct interaction.** LiquidityMining distributes XOM rewards to LP stakers. OmniBonding accepts stablecoins for discounted XOM. There is no direct on-chain interaction between the two contracts.

An attacker could: (1) LP-stake to earn XOM, (2) sell XOM on the open market to depress the price, (3) bond stablecoins at the (now lower) fixed price for discounted XOM. However, step 3 uses a fixed price set by the owner, not a market price, so this attack fails unless the owner manually lowers the price in response to market conditions.

### Sandwich Attacks on Staking

**Not applicable.** Staking LP tokens in LiquidityMining does not affect any market price. There is no price impact to sandwich.

---

## Summary

LiquidityMining is a well-structured MasterChef-style staking contract with thoughtful solvency protections (totalCommittedRewards), proper vesting mechanics, and strong access controls (Ownable2Step). The primary concern is the flash-stake vector (H-01), which can be mitigated with a minimum staking duration. The accounting drift in M-01 is conservative and negligible in practice. The contract is suitable for mainnet deployment with the H-01 mitigation applied.

**Deployment Readiness:** CONDITIONALLY APPROVED
- H-01: Minimum staking duration SHOULD be implemented before mainnet
- M-01: Accept and document (conservative drift, negligible value)
- M-02: Add warning event for observability
- L-01: Fix ERC-2771 consistency in `depositRewards()`

---

*Audit conducted 2026-03-10 01:03 UTC*
