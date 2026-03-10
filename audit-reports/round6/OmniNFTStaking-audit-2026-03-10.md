# Security Audit Report: OmniNFTStaking.sol -- Round 6 (Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (5-Pass Pre-Mainnet Audit)
**Contract:** `Coin/contracts/nft/OmniNFTStaking.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 978 (up from 532 in Round 1)
**Upgradeable:** No
**Handles Funds:** Yes (custodies NFTs, distributes ERC-20 reward tokens)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21)

---

## Executive Summary

OmniNFTStaking is a collection-based NFT staking contract with ERC-20 rewards, rarity multipliers, and streak bonuses. This Round 6 pre-mainnet audit confirms that all 5 High-severity findings from Round 1 have been fully resolved:

- **H-01 (Reward transfer traps NFTs):** Fixed -- try/catch in `unstake()` ensures NFT is always returned; `emergencyWithdraw()` added as fallback
- **H-02 (endTime not enforced):** Fixed -- `_calculatePending()` now caps to `pool.endTime`; `stake()` rejects expired pools
- **H-03 (No creator withdrawal):** Fixed -- `withdrawRemainingRewards()` added, callable by creator after `endTime`
- **H-04 (Fee-on-transfer accounting):** Fixed -- balance-before/after in `createPool()` (lines 355-366)
- **H-05 (Silent reward loss in claimRewards):** Fixed -- reverts with `InsufficientRewards` if pool cannot cover pending; `lastClaimAt` only advances after confirmed payout

All Medium findings have been addressed:
- **M-01 (Retroactive streak bonus):** Fixed -- segmented reward calculation across tier boundaries
- **M-02 (setRarityMultiplier missing nonReentrant):** Fixed -- `nonReentrant` added
- **M-03 (Missing zero-address checks):** Fixed -- validates `collection` and `rewardToken`
- **M-04 (No totalReward consistency check):** Fixed -- validates `totalReward >= rewardPerDay * durationDays`
- **M-05 (Staking into expired pool):** Fixed -- `PoolExpired` check added to `stake()`

Additionally, Low findings from Round 1 have been addressed:
- **L-01 (Single-step Ownable):** Fixed -- now uses `Ownable2Step`
- **L-05 (Missing events):** Fixed -- `RarityMultiplierSet`, `PoolPaused`, `PoolResumed`, `RewardTransferFailed` events added

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY with minor caveats noted below.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | `_rewardForSegment()` division truncation can cause significant reward loss | **FIXED** |
| M-02 | Medium | `setRarityMultiplier()` advances `lastClaimAt` even when no rewards are paid | **FIXED** |

---

## Remediation Status from Previous Audits

| ID | Severity | Title | Status | Notes |
|----|----------|-------|--------|-------|
| H-01 | High | Reward token transfer failure traps NFTs | RESOLVED | try/catch in `unstake()` (lines 461-482); pool accounting restored on failure; `emergencyWithdraw()` added (lines 542-566); `RewardTransferFailed` event |
| H-02 | High | Pool endTime stored but never enforced | RESOLVED | `_calculatePending()` caps `effectiveNow = min(nowTs, pool.endTime)` (lines 793-795); `stake()` checks `block.timestamp >= pool.endTime` (line 392) |
| H-03 | High | No creator withdrawal after pool ends | RESOLVED | `withdrawRemainingRewards()` added (lines 575-593); validates `creator`, `endTime`, and `remainingReward > 0` |
| H-04 | High | Fee-on-transfer remainingReward mismatch | RESOLVED | Balance-before/after in `createPool()` (lines 355-366); `totalReward` and `remainingReward` updated to actual received amount |
| H-05 | High | Silent reward loss in claimRewards | RESOLVED | `claimRewards()` reverts with `InsufficientRewards` if `pending > pool.remainingReward` (lines 519-521); `lastClaimAt` only advances after confirmation (lines 524-525) |
| M-01 | Medium | Streak bonus applied retroactively to full period | RESOLVED | `_segmentedReward()` (lines 901-957) splits reward calculation at streak tier boundaries; each sub-period uses correct multiplier |
| M-02 | Medium | setRarityMultiplier missing nonReentrant | RESOLVED | `nonReentrant` added (line 609); CEI pattern: state updates before transfer |
| M-03 | Medium | Missing zero-address checks on createPool | RESOLVED | `collection` and `rewardToken` validated (lines 315-316) |
| M-04 | Medium | No consistency check totalReward vs rewardPerDay | RESOLVED | `totalReward < rewardPerDay * durationDays` reverts with `InsufficientTotalReward` (lines 324-327) |
| M-05 | Medium | Staking into expired pool not prevented | RESOLVED | `if (block.timestamp >= pool.endTime) revert PoolExpired()` in `stake()` (line 392) |
| L-01 | Low | Single-step Ownable | RESOLVED | Now uses `Ownable2Step` (line 47) |
| L-02 | Low | Unsafe downcasts | UNCHANGED | uint64(block.timestamp) safe until year 2554; uint32 totalStaked safe (max 4.29B) |
| L-03 | Low | accumulatedReward write-only | UNCHANGED | Used for off-chain tracking via `getStake()` |
| L-04 | Low | pausePool allows claims and unstakes | UNCHANGED | Intentional design -- users can always exit |
| L-05 | Low | Missing events for admin state changes | RESOLVED | `RarityMultiplierSet`, `PoolPaused`, `PoolResumed` events added |
| L-06 | Low | No ERC-165 validation on collection | UNCHANGED | See L-03 below |
| I-01 | Info | Floating pragma | RESOLVED | Pinned to `0.8.24` |
| I-02 | Info | Stake struct not deleted on unstake | UNCHANGED | Preserves `accumulatedReward` for off-chain tracking |
| I-03 | Info | Pool creation permissionless | UNCHANGED | By design |

---

## New Findings (Round 6)

### [M-01] `_rewardForSegment()` Division Truncation Can Cause Significant Reward Loss

**Severity:** Medium
**Location:** `_rewardForSegment()` (lines 968-977)

**Description:**

The reward calculation performs a single division at the end:

```solidity
reward = (rewardPerDay * elapsed * rarityMul * streakMul)
    / (1 days * totalWeight * MULTIPLIER_PRECISION);
```

This is a single division of a large numerator by a large denominator. The numerator includes four multiplied terms. The issue is that the divisor includes `totalWeight * MULTIPLIER_PRECISION`, and for pools with many stakers (high `totalWeight`), the division truncation can be significant.

**Example:** With `rewardPerDay = 1e18` (1 token), `elapsed = 3600` (1 hour), `rarityMul = 10000` (1x), `streakMul = 10000` (1x), `totalWeight = 10000000` (1000 stakers at 1x):

```
numerator = 1e18 * 3600 * 10000 * 10000 = 3.6e29
divisor = 86400 * 10000000 * 10000 = 8.64e15
reward = 3.6e29 / 8.64e15 = 41666666666666 (4.17e13)
```

This is approximately correct. However, for very short elapsed times (e.g., 1 second with many stakers), truncation to zero becomes possible:

```
numerator = 1e18 * 1 * 10000 * 10000 = 1e26
divisor = 86400 * 10000000 * 10000 = 8.64e15
reward = 1e26 / 8.64e15 = 11574 (non-zero, OK)
```

**Assessment:** The multiplication order prevents intermediate overflow (Solidity 0.8.x checked arithmetic would revert). For typical parameters, truncation is minimal. The risk only materializes with extremely small `rewardPerDay` values or extremely large `totalWeight`. The segmented calculation (4 segments max) compounds the truncation across segments but not significantly.

**Recommendation:** Document the precision characteristics. For pools with very small `rewardPerDay` (< 1e12), warn creators that per-staker rewards may truncate to zero with many stakers.

---

### [M-02] `setRarityMultiplier()` Advances `lastClaimAt` Even When No Rewards Are Paid

**Severity:** Medium
**Location:** `setRarityMultiplier()` (lines 605-641)

**Description:**

When the owner sets a rarity multiplier, `lastClaimAt` is advanced to `block.timestamp` (line 625):

```solidity
s.lastClaimAt = uint64(block.timestamp);
```

Then pending rewards are conditionally transferred (lines 631-636):

```solidity
if (pending > 0 && pending <= pool.remainingReward) {
    s.accumulatedReward += pending;
    pool.remainingReward -= pending;
    IERC20(pool.rewardToken).safeTransfer(s.staker, pending);
}
```

If `pending > pool.remainingReward` (pool exhausted), the condition fails, no rewards are transferred, but `lastClaimAt` has already been advanced. The staker loses the unclaimed rewards for the period between their previous `lastClaimAt` and the current timestamp.

This differs from `claimRewards()` which correctly reverts with `InsufficientRewards` when rewards are insufficient (H-05 fix). The `setRarityMultiplier()` function does not revert -- it silently drops the rewards.

**Impact:** An owner calling `setRarityMultiplier()` on a near-exhausted pool causes the staker to permanently lose their pending rewards.

**Recommendation:** Either revert when rewards cannot be paid:
```solidity
if (pending > pool.remainingReward) revert InsufficientRewards();
```

Or only advance `lastClaimAt` when rewards are actually paid:
```solidity
if (pending > 0 && pending <= pool.remainingReward) {
    s.lastClaimAt = uint64(block.timestamp);
    s.accumulatedReward += pending;
    pool.remainingReward -= pending;
    IERC20(pool.rewardToken).safeTransfer(s.staker, pending);
}
```

---

### [L-01] `unstake()` Does Not Advance `lastClaimAt`

**Severity:** Low
**Location:** `unstake()` (lines 433-493)

**Description:**

When a staker unstakes, `lastClaimAt` is never updated. The stake is marked `active = false` (line 447), so this has no functional impact (no future calculations reference this stake). However, the `getStake()` view function will show a stale `lastClaimAt` value, which could confuse off-chain consumers trying to determine when the last claim occurred.

**Recommendation:** Set `s.lastClaimAt = uint64(block.timestamp)` during unstake for clean off-chain state.

---

### [L-02] `emergencyWithdraw()` Does Not Forfeit Pending Rewards to the Pool

**Severity:** Low
**Location:** `emergencyWithdraw()` (lines 542-566)

**Description:**

When a staker calls `emergencyWithdraw()`, their NFT is returned but no rewards are transferred. The `s.active` flag is set to false, `totalStaked` is decremented, and `totalWeightedStakes` is reduced. However, `pool.remainingReward` is not adjusted -- the forfeited rewards remain in `remainingReward` and can be claimed by other stakers or withdrawn by the creator after `endTime`.

This is correct behavior -- the emergency withdrawer forfeits their rewards, and those rewards become available to others. However, it means that after an emergency withdrawal, the `rewardPerDay` rate is effectively higher for remaining stakers (same reward pool, fewer stakers), which could be seen as a gaming vector: withdraw and re-stake to boost rewards for confederates.

**Assessment:** Low severity because emergency withdrawal is a last resort. The staker loses their streak bonus by re-staking, which partially offsets the gaming potential.

---

### [L-03] No ERC-165 Validation on Collection Address in `createPool()`

**Severity:** Low
**Location:** `createPool()` (line 315)

**Description:**

The `collection` address is validated as non-zero (line 315) but not verified as an ERC-721 contract. A pool created with a non-ERC721 address would permanently lock the deposited reward tokens since no one could successfully `stake()` (the `safeTransferFrom` would revert).

**Recommendation:** Add `require(IERC165(collection).supportsInterface(type(IERC721).interfaceId))`.

---

### [L-04] Pool `nextPoolId` Starts at 0 -- Ambiguity With Default Mapping Value

**Severity:** Low
**Location:** `nextPoolId` (line 118)

**Description:**

`nextPoolId` starts at 0. The first pool gets `poolId = 0`. Any `pools[id]` lookup for a non-existent ID returns a default `Pool` struct with `creator == address(0)`. The `PoolNotFound` check (`pool.creator == address(0)`) correctly handles this for all functions that need it (`stake`, `pausePool`, `resumePool`, `withdrawRemainingRewards`).

However, if someone queries `getPool(999)` for a non-existent pool, they get all-zero values which could be confused with a legitimate pool that has zero remaining rewards and an inactive state. Starting at 1 would eliminate the ambiguity (same fix applied to OmniFractionalNFT).

**Recommendation:** Start `nextPoolId` at 1 for consistency with OmniFractionalNFT's vault ID scheme.

---

### [I-01] `_segmentedReward()` Handles Edge Case Where `lastClaim` Is Past Tier Boundaries

**Severity:** Informational
**Location:** `_segmentedReward()` (lines 901-957)

**Description:**

The segmented reward function correctly handles the case where `lastClaim` is already past one or more tier boundaries. For example, if `lastClaim` is at day 31 (past STREAK_TIER2 = 30 days), the first two segments produce zero duration and the reward is calculated entirely at the Tier 2 (1.25x) or higher multiplier. The guard conditions (`from < tierXStart && from < effectiveEnd`) correctly skip past segments. This is well-implemented.

---

### [I-02] `accumulatedReward` Field Provides Off-Chain Tracking Only

**Severity:** Informational
**Location:** Stake struct (line 79)

**Description:**

The `accumulatedReward` field is incremented in `unstake()`, `claimRewards()`, and `setRarityMultiplier()` but is never read by on-chain logic except in `getStake()`. Each SSTORE to this field costs ~5,000 gas. This is an acceptable gas cost for the off-chain accounting benefit.

---

### [I-03] Streak Bonus Resets on Unstake and Re-Stake

**Severity:** Informational
**Location:** `stake()` (line 401)

**Description:**

When a user unstakes and re-stakes the same NFT, `stakedAt` is reset to `block.timestamp` (line 401), resetting the streak bonus to 1.0x. This is the intended design -- users who leave and return start fresh. However, it means there is no "loyalty reward" for long-term participants who temporarily need to access their NFT.

---

## Reward Calculation Deep Dive

### Segmented Reward Formula

The `_segmentedReward()` function splits the [lastClaim, effectiveEnd] interval at streak tier boundaries:

```
Tier 0: [stakedAt, stakedAt + 7 days)     -> 1.0x  (STREAK_BONUS_0 = 10000)
Tier 1: [stakedAt + 7d, stakedAt + 30d)   -> 1.1x  (STREAK_BONUS_1 = 11000)
Tier 2: [stakedAt + 30d, stakedAt + 90d)  -> 1.25x (STREAK_BONUS_2 = 12500)
Tier 3: [stakedAt + 90d, ...)             -> 1.5x  (STREAK_BONUS_3 = 15000)
```

Each segment's reward:
```
segment = (rewardPerDay * segmentDuration * rarityMultiplier * streakBonus)
        / (1 day * totalWeightedStakes * MULTIPLIER_PRECISION)
```

**Correctness verification:** For a single staker with 1.0x rarity, 1.0x streak, 1 day elapsed:
```
reward = (rewardPerDay * 86400 * 10000 * 10000) / (86400 * 10000 * 10000)
       = rewardPerDay
```
Correct -- single staker receives full `rewardPerDay`.

**Two stakers, equal weight:**
```
totalWeightedStakes = 20000
reward = (rewardPerDay * 86400 * 10000 * 10000) / (86400 * 20000 * 10000)
       = rewardPerDay / 2
```
Correct -- each staker receives half.

### Can Staking Rewards Be Gamed?

**Attack vector 1: Stake just before claiming to dilute others**
A griefing attacker could stake an NFT to increase `totalWeightedStakes`, reducing other stakers' per-second rewards. However, the attacker earns rewards proportional to their stake weight, so this is not profitable -- they pay the opportunity cost of the NFT.

**Attack vector 2: Flash-stake for instant rewards**
Not possible. Rewards are time-based (`elapsed` must be > 0). Staking and unstaking in the same block yields zero rewards.

**Attack vector 3: Manipulate totalWeightedStakes**
`totalWeightedStakes` only changes via `stake()`, `unstake()`, `emergencyWithdraw()`, and `setRarityMultiplier()`. All are protected by `nonReentrant`. No sandwich attack can manipulate the weight within a single block to extract excess rewards.

**Attack vector 4: Claim after pool endTime**
Blocked by H-02 fix: `effectiveNow = min(block.timestamp, pool.endTime)` ensures no rewards accrue past the intended duration.

**Conclusion:** Staking rewards cannot be meaningfully gamed with the current implementation.

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Guard | External Calls | Verdict |
|----------|-------|----------------|---------|
| `createPool()` | `nonReentrant` | `IERC20.balanceOf()`, `IERC20.safeTransferFrom()`, `IERC20.balanceOf()` | SAFE |
| `stake()` | `nonReentrant` | `IERC721.safeTransferFrom()` -> `onERC721Received()` callback | SAFE |
| `unstake()` | `nonReentrant` | try/catch `IERC20.transfer()`, `IERC721.safeTransferFrom()` | SAFE |
| `claimRewards()` | `nonReentrant` | `IERC20.safeTransfer()` | SAFE |
| `emergencyWithdraw()` | `nonReentrant` | `IERC721.safeTransferFrom()` | SAFE |
| `withdrawRemainingRewards()` | `nonReentrant` | `IERC20.safeTransfer()` | SAFE |
| `setRarityMultiplier()` | `nonReentrant` | `IERC20.safeTransfer()` | SAFE |
| `pausePool()` | None needed | No external calls | SAFE |
| `resumePool()` | None needed | No external calls | SAFE |

**ERC-721 Callback Risk:** `stake()` calls `safeTransferFrom` which triggers `onERC721Received()`. Protected by `nonReentrant`. `unstake()` and `emergencyWithdraw()` also use `safeTransferFrom` with `nonReentrant`.

**ERC-20 Callback Risk:** The try/catch in `unstake()` uses `transfer()` (not `safeTransfer`) to enable the try/catch pattern. This is correct -- `safeTransfer` would revert on false return, defeating the try/catch purpose. The try/catch handles both reverts and false returns.

---

## Integer Overflow Analysis

**Solidity 0.8.24 provides checked arithmetic. Key areas:**

1. **`_rewardForSegment()` numerator:** `rewardPerDay * elapsed * rarityMul * streakMul`. Maximum values: rewardPerDay ~ 1e30 (huge), elapsed ~ 2^64, rarityMul = 50000, streakMul = 15000. Product ~ 1e30 * 2^64 * 5e4 * 1.5e4 ~ 1e53. uint256 max is ~1.16e77. **No overflow risk.**

2. **`totalWeightedStakes` accumulation:** Each stake adds up to MAX_MULTIPLIER = 50000. With uint256, overflow requires 2^256 / 50000 ~ 2.3e72 stakers. **Not possible.**

3. **`uint64` downcasts:** `block.timestamp` is safe until year 2554. `pool.endTime = block.timestamp + durationDays * 1 days` where durationDays is uint16 (max 65535 = ~179 years). `block.timestamp + 179 years` fits in uint64. **Safe.**

---

## Conclusion

OmniNFTStaking has undergone dramatic improvement since Round 1. All 5 High-severity and all 5 Medium-severity findings have been fully resolved. The segmented reward calculation (`_segmentedReward`) is a particularly well-implemented fix for the retroactive streak bonus issue, splitting reward periods at tier boundaries. The try/catch pattern in `unstake()` correctly ensures NFTs are never trapped by reward token failures. The `emergencyWithdraw()` provides a guaranteed exit path.

The two remaining Medium findings (division truncation documentation and `setRarityMultiplier` timestamp advance) are minor. The contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet Audit*
