# Security Audit Report: OmniNFTStaking.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 20:59 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/nft/OmniNFTStaking.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 991
**Upgradeable:** No
**Handles Funds:** Yes (custodies ERC-721 NFTs, distributes ERC-20 reward tokens)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21), Round 6 (2026-03-10)

---

## Executive Summary

OmniNFTStaking is a collection-based NFT staking contract where pool creators deposit ERC-20 reward tokens and users stake ERC-721 NFTs to earn rewards proportional to their rarity multiplier and staking streak duration. The contract supports permissionless pool creation, owner-controlled rarity multipliers, pausable pools, streak bonuses (1.0x to 1.5x across four time tiers), and emergency withdrawal.

This Round 7 audit is the final pre-mainnet review. All five High-severity findings from Round 1 and all Medium-severity findings from Rounds 1 and 6 have been confirmed as fully remediated. The contract demonstrates a mature security posture with correct Checks-Effects-Interactions (CEI) patterns, comprehensive reentrancy protection, and robust edge-case handling.

This audit identifies **zero Critical, zero High, one Medium, four Low, and four Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 4 |
| Informational | 4 |

**Overall Assessment: PRODUCTION READY** -- the single Medium finding is an operational consideration that does not affect fund safety.

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | Reward token cross-pool commingling allows creator of one pool to siphon another pool's rewards | NEW |
| L-01 | Low | No ERC-165 validation on collection address in `createPool()` | CARRIED (R6 L-03) |
| L-02 | Low | `unstake()` does not advance `lastClaimAt` for off-chain tracking | CARRIED (R6 L-01) |
| L-03 | Low | `nextPoolId` starts at 0 -- ambiguity with default mapping values | CARRIED (R6 L-04) |
| L-04 | Low | `pausePool`/`resumePool` lack pool-expiry check -- can pause/resume already-ended pools | NEW |
| I-01 | Info | `accumulatedReward` field is write-only from on-chain perspective | CARRIED |
| I-02 | Info | Stake struct not deleted on unstake (preserves historical data) | CARRIED |
| I-03 | Info | Pool creation is permissionless | CARRIED |
| I-04 | Info | `_streakBonus()` unused in reward path (replaced by `_segmentedReward`) | NEW |

---

## Remediation Status from All Prior Audits

| Prior Finding | Round | Severity | Status | Verification |
|---------------|-------|----------|--------|--------------|
| H-01: Reward transfer failure traps NFTs | R1 | High | **RESOLVED** | `unstake()` uses try/catch (lines 462-482) around `IERC20.transfer()`. On failure, pool accounting is restored (`remainingReward += pending`, `accumulatedReward -= pending`), `RewardTransferFailed` event emitted, and NFT is unconditionally returned via `safeTransferFrom` at line 486. `emergencyWithdraw()` (lines 542-566) provides a guaranteed no-reward exit path. |
| H-02: Pool endTime stored but never enforced | R1 | High | **RESOLVED** | `_calculatePending()` caps `effectiveNow = min(block.timestamp, pool.endTime)` at lines 798-800. `stake()` rejects expired pools at line 392: `if (block.timestamp >= pool.endTime) revert PoolExpired()`. |
| H-03: No creator withdrawal after pool ends | R1 | High | **RESOLVED** | `withdrawRemainingRewards()` (lines 575-593) validates creator identity, enforces `block.timestamp >= pool.endTime`, zeros `remainingReward` before transfer (CEI), and uses `safeTransfer`. |
| H-04: Fee-on-transfer remainingReward mismatch | R1 | High | **RESOLVED** | `createPool()` uses balance-before/after pattern (lines 355-366). `totalReward` and `remainingReward` are updated to the actual received amount. |
| H-05: Silent reward loss in claimRewards | R1 | High | **RESOLVED** | `claimRewards()` reverts with `InsufficientRewards` when `pending > pool.remainingReward` (lines 519-521). `lastClaimAt` only advances after confirmed payout (line 525). |
| M-01: Streak bonus applied retroactively | R1 | Medium | **RESOLVED** | `_segmentedReward()` (lines 906-962) splits reward calculation at streak tier boundaries. Each sub-period uses the correct multiplier. Verified: segments are computed from `lastClaim` to `effectiveEnd` with correct boundary timestamps relative to `stakedAt`. |
| M-02: `setRarityMultiplier` missing nonReentrant | R1 | Medium | **RESOLVED** | `nonReentrant` added at line 612. CEI pattern: state updates (lines 626-629) before transfer (line 640). |
| M-03: Missing zero-address checks on createPool | R1 | Medium | **RESOLVED** | `collection` and `rewardToken` validated at lines 315-316. |
| M-04: No totalReward vs rewardPerDay consistency | R1 | Medium | **RESOLVED** | `totalReward < rewardPerDay * durationDays` reverts with `InsufficientTotalReward` at lines 324-327. |
| M-05: Staking into expired pool not prevented | R1 | Medium | **RESOLVED** | `if (block.timestamp >= pool.endTime) revert PoolExpired()` in `stake()` at line 392. |
| R6 M-01: Division truncation in `_rewardForSegment` | R6 | Medium | **RESOLVED** | NatSpec precision documentation added at lines 966-974. Pool creators warned that `rewardPerDay` should be at least `1e12` for pools with more than 1000 stakers. |
| R6 M-02: `setRarityMultiplier` advances lastClaimAt even when no rewards paid | R6 | Medium | **RESOLVED** | `lastClaimAt` now only advances inside the `if (pending > 0 && pending <= pool.remainingReward)` block (lines 635-641). If rewards cannot be paid, the staker retains their pending reward period. |
| L-01: Single-step Ownable | R1 | Low | **RESOLVED** | Now uses `Ownable2Step` (line 47). |
| L-05: Missing events for admin state changes | R1 | Low | **RESOLVED** | `RarityMultiplierSet`, `PoolPaused`, `PoolResumed`, `RewardTransferFailed` events added. |

---

## New Findings (Round 7)

### [M-01] Reward Token Cross-Pool Commingling Allows Creator of One Pool to Siphon Another Pool's Rewards

**Severity:** Medium
**Location:** `createPool()` (lines 306-376), `withdrawRemainingRewards()` (lines 575-593)

**Description:**

All reward token deposits are held in the contract's single ERC-20 balance with no per-pool escrow. The accounting is based on `pool.remainingReward` decrements. If multiple pools use the same reward token, the contract's actual ERC-20 balance is the aggregate of all pools' `remainingReward` values.

The risk arises in this scenario:

1. Creator A creates Pool 1 with 10,000 XOM rewards for 100 days.
2. Creator B creates Pool 2 with 10,000 XOM rewards for 100 days.
3. Contract holds 20,000 XOM. Pool 1 `remainingReward = 10,000`. Pool 2 `remainingReward = 10,000`.
4. Pool 1 ends with 5,000 XOM undistributed. Creator A calls `withdrawRemainingRewards()` and receives 5,000 XOM. Contract balance: 15,000 XOM. Pool 2 `remainingReward = 10,000`. Solvent.
5. Now: if a fee-on-transfer token were used where the actual received amount is less than `remainingReward` due to an accounting edge (or if a reward token has a built-in burn on transfer), the contract could become insolvent -- Pool 2's `remainingReward` could exceed the contract's actual balance.

Under normal (non-fee-on-transfer) conditions, the balance-before/after pattern in `createPool()` (H-04 fix) correctly tracks received amounts, so `remainingReward` is accurate. The risk is limited to:
- Tokens that apply fees on `transfer()` but not `transferFrom()` (rare but possible)
- Tokens whose transfer behavior changes after pool creation (upgradeable ERC-20s)
- Deflationary tokens with continuous burn mechanics

**Impact:** In edge cases with unusual token mechanics, the last pool to withdraw could receive less than their `remainingReward`, causing a shortfall. Under standard ERC-20 tokens, this is not exploitable.

**Recommendation:** Document that pool creators should only use standard ERC-20 tokens. For defense in depth, consider capping `withdrawRemainingRewards()` to `min(pool.remainingReward, IERC20(pool.rewardToken).balanceOf(address(this)))`.

---

### [L-01] No ERC-165 Validation on Collection Address in `createPool()`

**Severity:** Low
**Location:** `createPool()` line 315

**Description:**

The `collection` address is validated as non-zero but not verified as an ERC-721 contract via `IERC165.supportsInterface()`. A pool created with a non-ERC721 address (e.g., an EOA or a non-ERC721 contract) would permanently lock the deposited reward tokens since no one could successfully call `stake()` -- the `safeTransferFrom` would revert.

The pool creator loses their deposited rewards. After `endTime`, they can recover them via `withdrawRemainingRewards()`, so funds are not permanently lost, only temporarily locked.

**Impact:** Pool creator inconvenience. No impact on other users.

**Recommendation:** Add ERC-165 check:
```solidity
if (!IERC165(collection).supportsInterface(type(IERC721).interfaceId)) {
    revert InvalidCollection();
}
```

---

### [L-02] `unstake()` Does Not Advance `lastClaimAt` for Off-Chain Tracking

**Severity:** Low
**Location:** `unstake()` (lines 433-493)

**Description:**

When a staker unstakes, `lastClaimAt` is never updated. Since the stake is marked `active = false` (line 447), no future on-chain calculations reference this stake. However, `getStake()` returns a stale `lastClaimAt`, which could confuse off-chain indexers or UIs trying to determine when the last claim occurred.

**Impact:** Off-chain data quality only. No on-chain impact.

**Recommendation:** Set `s.lastClaimAt = uint64(block.timestamp)` during unstake.

---

### [L-03] `nextPoolId` Starts at 0 -- Ambiguity With Default Mapping Values

**Severity:** Low
**Location:** `nextPoolId` (line 118)

**Description:**

The first pool gets `poolId = 0`. Any `pools[id]` lookup for a non-existent ID returns a default `Pool` struct with `creator == address(0)`. All functions that need to validate pool existence correctly check `pool.creator == address(0)`. However, `getPool(999)` returns all-zero values that could be confused with a legitimate empty pool by off-chain consumers.

**Impact:** Off-chain ambiguity only. On-chain logic is correct.

**Recommendation:** Start `nextPoolId` at 1 for consistency with OmniFractionalNFT's vault ID scheme.

---

### [L-04] `pausePool`/`resumePool` Lack Pool-Expiry Check

**Severity:** Low
**Location:** `pausePool()` (line 653), `resumePool()` (line 664)

**Description:**

The owner can pause or resume a pool that has already expired (`block.timestamp >= pool.endTime`). While this has no harmful effect (expired pools cannot accept new stakes due to the `PoolExpired` check in `stake()`), it creates misleading state: a pool can appear "active" in `getPool()` even though it is expired and cannot accept stakes.

**Impact:** Off-chain confusion only. No fund risk.

**Recommendation:** Add `if (block.timestamp >= pool.endTime) revert PoolExpired()` to both `pausePool` and `resumePool`.

---

### [I-01] `accumulatedReward` Field Is Write-Only From On-Chain Perspective

**Severity:** Informational

The `accumulatedReward` field in the `Stake` struct is incremented in `unstake()`, `claimRewards()`, and `setRarityMultiplier()` but is never read by any on-chain logic other than the `getStake()` view function. Each SSTORE costs approximately 5,000 gas. This is an acceptable cost for off-chain tracking and event-free historical reward totals.

---

### [I-02] Stake Struct Not Deleted on Unstake

**Severity:** Informational

When a user unstakes, the `Stake` struct is not deleted via `delete stakes[poolId][tokenId]`. Instead, `s.active` is set to `false`. This preserves `accumulatedReward`, `stakedAt`, and `staker` for off-chain historical queries. The trade-off is that the gas refund from SSTORE-to-zero is forfeited (~4,800 gas per non-zero slot that would otherwise be zeroed). With 6 non-zero fields, the forfeited refund is approximately 28,800 gas per unstake. This is an intentional design choice.

---

### [I-03] Pool Creation Is Permissionless

**Severity:** Informational

Any address can call `createPool()` to create a staking pool for any NFT collection. This is by design -- it allows collection creators to incentivize staking without requiring protocol governance approval. However, it also means:
- Spam pools can be created (though each requires a real reward token deposit, providing economic deterrent)
- Pools with misleading parameters (e.g., very low `rewardPerDay`, incompatible `collection` addresses) can exist

No remediation needed -- the permissionless design is intentional and the economic cost of deposits provides Sybil resistance.

---

### [I-04] `_streakBonus()` Function Is Unused in the Reward Calculation Path

**Severity:** Informational
**Location:** `_streakBonus()` (lines 826-838)

**Description:**

The `_streakBonus()` function is only called by the external view function `getStreakBonus()` (line 698). It is not used in the actual reward calculation path, which uses `_segmentedReward()` with hardcoded streak constants (`STREAK_BONUS_0` through `STREAK_BONUS_3`). This is correct -- `_segmentedReward()` needs to split at boundaries, not use a single bonus for the entire period. However, `_streakBonus()` computes the bonus based on `block.timestamp - stakedAt`, which may diverge from the segmented calculation's view at any given moment (the segmented calculation is based on [lastClaim, effectiveEnd], not the current timestamp).

The two functions are consistent for the purpose they serve: `getStreakBonus()` tells the user their current tier, while `_segmentedReward()` correctly applies per-segment bonuses for actual reward math.

No remediation needed.

---

## Reentrancy Analysis

**Status: FULLY PROTECTED**

| Function | Guard | External Calls | CEI Pattern | Verdict |
|----------|-------|----------------|-------------|---------|
| `createPool()` | `nonReentrant` | `IERC20.balanceOf()` (2x), `IERC20.safeTransferFrom()` | N/A (no state modified after transfer in a reenterable way) | SAFE |
| `stake()` | `nonReentrant` | `IERC721.safeTransferFrom()` (triggers `onERC721Received` callback) | State updated (lines 398-411) before NFT transfer (line 414) | SAFE |
| `unstake()` | `nonReentrant` | try/catch `IERC20.transfer()`, `IERC721.safeTransferFrom()` | State updated (lines 447-449) before transfers (lines 462, 486) | SAFE |
| `claimRewards()` | `nonReentrant` | `IERC20.safeTransfer()` | State updated (lines 525-527) before transfer (line 529) | SAFE |
| `emergencyWithdraw()` | `nonReentrant` | `IERC721.safeTransferFrom()` | State updated (lines 554-556) before transfer (line 559) | SAFE |
| `withdrawRemainingRewards()` | `nonReentrant` | `IERC20.safeTransfer()` | State updated (line 588) before transfer (line 590) | SAFE |
| `setRarityMultiplier()` | `nonReentrant` | `IERC20.safeTransfer()` | State updated (lines 626-629) before conditional transfer (line 640) | SAFE |
| `pausePool()` | None needed | No external calls | N/A | SAFE |
| `resumePool()` | None needed | No external calls | N/A | SAFE |

**ERC-721 Callback Risk:** `safeTransferFrom` triggers `onERC721Received()` on the recipient. In `stake()`, the recipient is `address(this)` which inherits `ERC721Holder` -- callback is a no-op. In `unstake()` and `emergencyWithdraw()`, the recipient is the staker, who could be a contract with a malicious `onERC721Received()`. The `nonReentrant` guard prevents re-entry.

**ERC-20 Callback Risk:** Standard ERC-20 tokens do not have transfer callbacks. However, ERC-777 tokens (backward-compatible with ERC-20) have `tokensReceived` hooks. The `nonReentrant` guard protects against this. The try/catch in `unstake()` correctly uses raw `transfer()` instead of `safeTransfer()` to capture both `false` returns and reverts.

---

## Access Control Analysis

**Status: CORRECTLY IMPLEMENTED**

| Role | Holder | Capabilities | Assessment |
|------|--------|-------------|------------|
| `owner` (Ownable2Step) | Deployer (initially) | `setRarityMultiplier()`, `pausePool()`, `resumePool()` | Two-step transfer prevents accidental ownership loss. Owner can set any staked NFT's rarity multiplier (0.1x-5.0x), and pause/resume any pool. Cannot withdraw pool funds, cannot unstake users' NFTs, cannot modify reward rates. |
| Pool creator | Any address | `createPool()`, `withdrawRemainingRewards()` | Creator can only withdraw their own pool's remaining rewards, and only after `endTime`. Cannot withdraw other creators' pool funds. |
| Staker | NFT owner | `stake()`, `unstake()`, `claimRewards()`, `emergencyWithdraw()` | Can only operate on their own stakes. Cannot claim other stakers' rewards. |

**Owner Powers Assessment:**

The owner has significant power through `setRarityMultiplier()`:
- Can increase a confederate staker's multiplier to 5.0x (MAX_MULTIPLIER), giving them 5x the reward share.
- Can decrease a victim staker's multiplier to 0.1x (MIN_MULTIPLIER), reducing their share by 10x.
- However, the owner cannot steal NFTs or prevent unstaking. Stakers can always exit via `unstake()` or `emergencyWithdraw()`.

This is an acceptable centralization trade-off for NFT rarity classification, which inherently requires an oracle or authority. The owner should ideally be a multi-sig or governance contract.

**Pause Power Assessment:**

The owner can `pausePool()` to prevent new stakes. Existing stakers can still `claimRewards()`, `unstake()`, and `emergencyWithdraw()`. This is correct -- pause should never trap user funds.

---

## NFT Staking/Unstaking Flow Analysis

**Staking Path:**
1. User calls `stake(poolId, tokenId)` with an NFT they own.
2. Validations: pool exists, pool is active, pool not expired, NFT not already staked in this pool.
3. Stake struct created with `staker = caller`, `stakedAt = now`, `lastClaimAt = now`, `rarityMultiplier = 10000` (1.0x).
4. `pool.totalStaked` incremented. `totalWeightedStakes[poolId]` incremented by multiplier.
5. NFT transferred from caller to contract via `safeTransferFrom`.
6. `Staked` event emitted.

**Unstaking Path:**
1. User calls `unstake(poolId, tokenId)`.
2. Validations: stake is active, caller is the staker.
3. Pending rewards calculated via `_calculatePending()`.
4. Effects: `s.active = false`, `pool.totalStaked--`, `totalWeightedStakes -= multiplier`.
5. Reward transfer attempted via try/catch. On success, `pool.remainingReward` decremented. On failure, accounting restored and `RewardTransferFailed` emitted.
6. NFT unconditionally returned to staker via `safeTransferFrom`.
7. `Unstaked` event emitted with the amount actually paid.

**Emergency Withdrawal Path:**
1. User calls `emergencyWithdraw(poolId, tokenId)`.
2. Validations: stake is active, caller is the staker.
3. Effects: `s.active = false`, `pool.totalStaked--`, `totalWeightedStakes -= multiplier`.
4. NFT returned to staker. No reward transfer attempted.
5. `EmergencyWithdraw` event emitted.

**Key Safety Properties:**
- NFTs are NEVER trapped. Both `unstake()` (via try/catch) and `emergencyWithdraw()` guarantee return.
- Double-unstake is prevented: `if (!s.active) revert StakeNotFound()`.
- Re-staking after unstake is supported. The old `Stake` struct has `active = false`; a new `Stake` is written to `stakes[poolId][tokenId]`, overwriting the old data.

---

## Reward Calculation Deep Dive

### Formula Verification

**`_rewardForSegment()`** (lines 981-990):
```
reward = (rewardPerDay * elapsed * rarityMul * streakMul)
       / (1 days * totalWeight * MULTIPLIER_PRECISION)
```

Where:
- `rewardPerDay`: total daily reward for the pool (not per staker)
- `elapsed`: seconds in this segment
- `rarityMul`: staker's rarity multiplier (in MULTIPLIER_PRECISION units)
- `streakMul`: streak bonus for this tier (in MULTIPLIER_PRECISION units)
- `totalWeight`: sum of all active stakers' rarity multipliers
- `MULTIPLIER_PRECISION`: 10000

**Dimensional analysis:**
- Numerator: `tokens * seconds * precision * precision` = `tokens * seconds * precision^2`
- Denominator: `seconds * precision * precision` = `seconds * precision^2` (because `totalWeight` is in precision units)
- Result: `tokens` -- dimensionally correct.

**Single staker, 1x rarity, 1x streak, 1 day:**
```
= (rewardPerDay * 86400 * 10000 * 10000) / (86400 * 10000 * 10000)
= rewardPerDay
```
Correct.

**Two stakers, equal weight, 1.25x streak, 1 day:**
```
Per staker = (rewardPerDay * 86400 * 10000 * 12500) / (86400 * 20000 * 10000)
           = rewardPerDay * 12500 / 20000
           = rewardPerDay * 0.625
Total both = rewardPerDay * 1.25
```
This means streak bonuses can cause total distributed rewards to exceed `rewardPerDay`. This is correct and expected -- streak bonuses are a multiplier on the staker's share, and the pool's `rewardPerDay` is a base rate. The `remainingReward` cap in `_calculatePending()` (line 816-818) ensures the pool never distributes more than its funded amount.

### Overflow Analysis

**Maximum numerator:** `rewardPerDay(max ~1e30) * elapsed(max ~5.68e15 for 180 years) * rarityMul(50000) * streakMul(15000)` = `~4.26e55`. This is well below `uint256` max (~1.16e77). No overflow risk.

**Truncation Analysis:** With `rewardPerDay = 1e18`, `elapsed = 1` (1 second), `rarityMul = 10000`, `streakMul = 10000`, `totalWeight = 10000`:
```
= 1e18 * 1 * 10000 * 10000 / (86400 * 10000 * 10000) = 1e26 / 8.64e9 = 1.157e16
```
Non-zero. Truncation only becomes an issue with `rewardPerDay < 1e2` and `totalWeight > 1e9` (100,000+ stakers at 1x). Documented in NatSpec at line 974.

---

## Edge Cases and Attack Vectors

### Flash-Stake Attack
**Not possible.** Staking and claiming in the same block yields `elapsed = 0`, producing zero rewards. The minimum exploitable interval is 1 second (1 block on Avalanche), which yields negligible rewards.

### Stake Weight Manipulation (Sandwich)
**Not possible.** `totalWeightedStakes` changes are protected by `nonReentrant`. An attacker cannot sandwich a victim's claim by staking/unstaking in the same transaction. Cross-block sandwiching (stake in block N, victim claims in block N+1, unstake in block N+2) would dilute the victim's rewards by increasing `totalWeight`, but the attacker would earn proportional rewards, making it unprofitable after gas costs.

### Re-Staking for Streak Reset Gaming
An attacker could emergency-withdraw their NFT (forfeiting pending rewards) and re-stake to reset their streak timer. Since streak bonuses are multiplicative, restarting at 1.0x from 1.5x is always disadvantageous. Re-staking is not a profitable strategy.

### Pool Fund Draining via Streak Bonuses
Streak bonuses can cause total payouts to exceed `rewardPerDay * durationDays` because each staker's reward is scaled by their streak bonus. A pool with `totalReward = rewardPerDay * durationDays` and all long-term stakers at 1.5x streak could theoretically drain rewards 50% faster. The `remainingReward` cap (line 816-818) prevents over-distribution. After `remainingReward` hits zero, stakers receive nothing (or the pool's `remainingReward` amount, whichever is less). Pool creators should account for streak bonuses when setting `totalReward`.

### ERC-2771 Meta-Transaction Considerations
The contract uses `ERC2771Context` for gasless transactions via a trusted forwarder. The `_msgSender()` override at line 849-856 correctly delegates to `ERC2771Context._msgSender()`. All user-facing functions (`stake`, `unstake`, `claimRewards`, `emergencyWithdraw`, `createPool`) use `_msgSender()` via `caller` local variable. The `Ownable2Step.owner()` check in `onlyOwner` also uses `_msgSender()` through the overridden `Context._msgSender()`.

**Risk:** The trusted forwarder is set in the constructor and cannot be changed. If the forwarder is compromised, an attacker could spoof `_msgSender()` for any function. This is an inherent risk of ERC-2771 and is mitigated by deploying a well-audited forwarder contract. The constructor accepts `address(0)` as the forwarder (as done in tests), which effectively disables meta-transactions.

### Unsafe `transfer()` in `unstake()` Try/Catch
The `unstake()` function uses raw `IERC20.transfer()` (line 462) instead of `SafeERC20.safeTransfer()` inside a try/catch block. This is intentional and correct:
- `safeTransfer()` reverts on `false` return, which would defeat the try/catch purpose
- The try/catch captures both `false` returns (handled in `if (success)` check at line 465) and reverts (handled in `catch` at line 475)
- Both failure paths correctly restore `pool.remainingReward` and `s.accumulatedReward`

However, there is a subtle consideration: `IERC20.transfer()` is expected to return `bool`. Some non-standard tokens (e.g., USDT on mainnet) do not return a value. In Solidity 0.8.x, calling `transfer()` on such a token via the `IERC20` interface would revert due to ABI decoding failure, which would be caught by the `catch` block. So this is safe.

---

## ERC-2771 Context Diamond Resolution

The contract inherits from both `Ownable2Step` (which inherits `Ownable`, which inherits `Context`) and `ERC2771Context` (which also inherits `Context`). This creates a diamond inheritance for `_msgSender()`, `_msgData()`, and `_contextSuffixLength()`.

The contract correctly resolves this by explicitly overriding all three functions (lines 849-888) and delegating to `ERC2771Context`. The `override(Context, ERC2771Context)` specifier is correct. This ensures that all calls to `_msgSender()` -- including those from `Ownable` modifiers like `onlyOwner` -- go through the ERC-2771 forwarder detection logic.

---

## Gas Considerations

| Operation | Estimated Gas | Notes |
|-----------|--------------|-------|
| `createPool()` | ~150,000 | Includes ERC-20 transferFrom + SSTORE for pool struct |
| `stake()` | ~130,000 | Includes ERC-721 safeTransferFrom + SSTORE for stake struct |
| `unstake()` | ~100,000 | Includes reward calculation + try/catch transfer + NFT return |
| `claimRewards()` | ~80,000 | Includes segmented reward calculation + ERC-20 transfer |
| `emergencyWithdraw()` | ~70,000 | No reward calculation, just NFT return |
| `setRarityMultiplier()` | ~90,000 | Includes reward calculation + conditional transfer |

No gas optimization issues identified. The contract uses custom errors (cheaper than require strings), events with indexed parameters, and efficient struct packing.

---

## Conclusion

OmniNFTStaking.sol has reached a mature and battle-tested state through seven rounds of auditing. All High-severity and Medium-severity findings from prior rounds have been fully remediated and verified. The contract demonstrates:

1. **Robust NFT safety:** NFTs are never trapped, even when reward tokens revert/pause. The try/catch pattern in `unstake()` and the `emergencyWithdraw()` fallback provide comprehensive exit paths.

2. **Accurate reward calculation:** The segmented reward function correctly applies streak bonuses per-segment, preventing retroactive application. The `remainingReward` cap prevents over-distribution.

3. **Strong reentrancy protection:** All state-changing functions use `nonReentrant`. CEI pattern is followed. ERC-721 callbacks and potential ERC-777 hooks are neutralized.

4. **Correct access control:** Two-step ownership via `Ownable2Step`. Owner powers are limited to rarity multipliers and pool pause/resume -- cannot steal NFTs or funds.

5. **ERC-2771 compatibility:** Meta-transaction support is correctly implemented with proper diamond resolution.

The single Medium finding (M-01: cross-pool token commingling) is an operational consideration for pools using non-standard tokens and does not affect standard ERC-20 usage. The contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Round 7 Pre-Mainnet Final Audit*
