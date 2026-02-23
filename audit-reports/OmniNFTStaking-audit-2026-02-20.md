# Security Audit Report: OmniNFTStaking

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/nft/OmniNFTStaking.sol`
**Solidity Version:** ^0.8.24
**Lines of Code:** 532
**Upgradeable:** No
**Handles Funds:** Yes (custodies NFTs, distributes ERC20 reward tokens)
**Deployed At:** Chain 131313

## Executive Summary

OmniNFTStaking is a collection-based NFT staking contract that allows pool creators to deposit ERC20 reward tokens, enabling NFT holders to stake their tokens and earn rewards proportional to rarity multipliers and streak bonuses. The audit found **1 high-severity issue** where reward token transfer failures permanently trap staked NFTs, **4 additional high-severity issues** covering pool endTime not being enforced, missing creator withdrawal mechanism, fee-on-transfer token incompatibility, and silent reward loss during claims. The contract has no `emergencyWithdraw` function, which compounds the NFT trapping risk into a potential permanent-loss scenario.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 5 |
| Medium | 5 |
| Low | 6 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 107 |
| Passed | 74 |
| Failed | 18 |
| Partial | 15 |
| **Compliance Score** | **68.2%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-AM-DOSA-1** (FAIL): No pull-based withdrawal pattern — reward transfer failure in `unstake()` traps NFTs
2. **SOL-Defi-Staking-2** (FAIL): Reward timing not enforced — `endTime` stored but never checked in `_calculatePending()`
3. **SOL-Token-FE-6** (FAIL): Fee-on-transfer tokens cause `remainingReward` accounting mismatch
4. **SOL-AM-RP-1** (FAIL): Admin rug-pull vector — `setRarityMultiplier()` transfers to staker without `nonReentrant`
5. **SOL-CR-3** (FAIL): No admin/creator withdrawal mechanism for unused rewards after pool ends

---

## High Findings

### [H-01] Reward Token Transfer Failure Permanently Traps Staked NFTs

**Severity:** High
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Revert)
**Location:** `unstake()` (lines 268-298)
**Sources:** Agent-C, Agent-D, Checklist (SOL-AM-DOSA-1), Solodit

**Description:**

In `unstake()`, the reward token transfer (line 287) and NFT return (line 291) are coupled in the same transaction. If the ERC20 `safeTransfer` reverts — which can happen with paused tokens (USDC, USDT), blocklisted addresses, or tokens with reverting callbacks — the entire transaction reverts, preventing the NFT from being returned to the staker. The contract has no `emergencyWithdraw()` function as a fallback, so the NFT is permanently trapped.

```solidity
// Lines 285-295: Coupled reward transfer + NFT return
if (pending > 0 && pending <= pool.remainingReward) {
    pool.remainingReward -= pending;
    IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);  // If this reverts...
}

// ...this never executes, NFT is trapped
IERC721(pool.collection).safeTransferFrom(
    address(this), msg.sender, tokenId
);
```

**Exploit Scenario:**

1. A pool creator creates a pool with USDC as the reward token.
2. Alice stakes her valuable NFT (e.g., worth 10 ETH).
3. Circle blocklists Alice's address (e.g., due to OFAC compliance).
4. Alice calls `unstake()` — the USDC transfer to Alice reverts.
5. The entire transaction reverts. Alice's NFT is permanently locked in the contract.
6. There is no `emergencyWithdraw()` to recover the NFT without reward transfer.

**Real-World Precedent:** Cyfrin Paladin Valkyrie v2.0 — CRITICAL finding: "Permissionless Reward Distribution Enabling Pool Lockup" with "complete pool denial of service with irreversible liquidity lockup." Multiple Code4rena/Sherlock findings document ERC20 blocklisting causing NFT custody DoS (reNFT, LayerEdge Staking).

**Recommendation:**

1. Wrap the reward transfer in a try/catch so NFT return is not blocked:

```solidity
if (pending > 0 && pending <= pool.remainingReward) {
    pool.remainingReward -= pending;
    try IERC20(pool.rewardToken).transfer(msg.sender, pending) returns (bool success) {
        if (!success) { /* log failed, rewards stay in contract */ }
    } catch { /* rewards stay in contract, NFT still returned */ }
}
```

2. Add an `emergencyWithdraw(uint256 poolId, uint256 tokenId)` function that returns the NFT without attempting any reward transfer.

---

### [H-02] Pool endTime Stored But Never Enforced — Rewards Accrue Indefinitely

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_calculatePending()` (lines 488-515)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Defi-Staking-2, SOL-Defi-Staking-3), Solodit

**Description:**

The `Pool` struct stores `endTime` (line 130), calculated as `block.timestamp + (durationDays * 1 days)` during `createPool()`. However, `_calculatePending()` never references `endTime` — it computes `elapsed = block.timestamp - s.lastClaimAt` without capping it at the pool's end time. This means rewards continue to accrue indefinitely past the intended pool duration, draining `remainingReward` at the configured `rewardPerDay` rate regardless of whether the pool was supposed to have ended.

```solidity
// Line 500: No endTime check — elapsed time is unbounded
uint256 elapsed = block.timestamp - s.lastClaimAt;
// Missing: uint256 effectiveEnd = block.timestamp < pool.endTime ? block.timestamp : pool.endTime;
// Missing: uint256 elapsed = effectiveEnd - s.lastClaimAt;
```

Additionally, `stake()` (line 235) only checks `pool.active` but not whether `block.timestamp >= pool.endTime`, allowing users to stake into expired pools.

**Real-World Precedent:** Sherlock/ZeroLend One H-8: "Liquidated positions will still accrue rewards after being liquidated" — identical pattern where a condition that should gate accrual is stored but not checked. Synthetix StakingRewards canonical pattern uses `lastTimeRewardApplicable = min(block.timestamp, periodFinish)` specifically to prevent this.

**Recommendation:**

```solidity
function _calculatePending(...) internal view returns (uint256 pending) {
    // ... existing checks ...
    uint256 effectiveEnd = block.timestamp < pool.endTime
        ? block.timestamp : pool.endTime;
    if (effectiveEnd <= s.lastClaimAt) return 0;
    uint256 elapsed = effectiveEnd - s.lastClaimAt;
    // ... rest of calculation ...
}
```

Also add `if (block.timestamp >= pool.endTime) revert PoolNotActive();` to `stake()`.

---

### [H-03] No Mechanism for Creator to Withdraw Unused Rewards After Pool Ends

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-57 (recoverERC20 Backdoor — missing legitimate variant)
**Location:** Contract-wide
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Solodit

**Description:**

Once a pool creator deposits reward tokens via `createPool()`, there is no function to recover `remainingReward` after the pool's `endTime` passes. If fewer stakers participate than expected, or if stakers unstake early, the excess reward tokens are permanently locked in the contract. There is also no `rescueTokens()` function for tokens accidentally sent to the contract.

This is compounded by H-02 (endTime not enforced) — without the endTime fix, rewards theoretically drain to zero given enough time. But with the endTime fix applied, any undistributed rewards after `endTime` become permanently trapped.

**Real-World Precedent:** Code4rena/Blend M-08: "Removing a pool from the reward zone leads to the loss of ungulped emissions." Cyfrin Paladin Valkyrie v2.0: "Reward Deposits Stuck Without Liquidity."

**Recommendation:**

```solidity
function withdrawRemainingRewards(uint256 poolId) external nonReentrant {
    Pool storage pool = pools[poolId];
    if (pool.creator != msg.sender) revert NotPoolCreator();
    if (block.timestamp < pool.endTime) revert PoolStillActive();
    uint256 amount = pool.remainingReward;
    if (amount == 0) revert ZeroAmount();
    pool.remainingReward = 0;
    IERC20(pool.rewardToken).safeTransfer(msg.sender, amount);
}
```

---

### [H-04] Fee-on-Transfer Tokens Cause remainingReward Accounting Mismatch

**Severity:** High
**Category:** SC05 Input Validation / Token Integration
**VP Reference:** VP-46 (Fee-on-Transfer)
**Location:** `createPool()` (lines 199, 208-212)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Token-FE-6), Solodit

**Description:**

`createPool()` sets `remainingReward = totalReward` (line 199) based on the function parameter, then calls `safeTransferFrom(msg.sender, address(this), totalReward)`. For fee-on-transfer (deflationary) tokens, the contract receives fewer tokens than `totalReward`. The internal accounting (`remainingReward`) exceeds the actual token balance, causing the last stakers to be unable to claim their rewards when the contract's actual balance runs out.

```solidity
// Line 199: Accounting uses parameter value
remainingReward: totalReward,  // e.g., 1000 tokens

// Line 208-212: Actual transfer — if 2% fee, only 980 tokens arrive
IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), totalReward);
```

**Real-World Precedent:** Code4rena/Virtuals Protocol: "Fee-induced reserve inconsistency in FRouter." Ethereum.org Token Integration Checklist explicitly warns about deflationary tokens.

**Recommendation:**

Measure actual received balance:

```solidity
uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(this));
IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), totalReward);
uint256 actualReceived = IERC20(rewardToken).balanceOf(address(this)) - balanceBefore;

pools[poolId].remainingReward = actualReceived;
pools[poolId].totalReward = actualReceived;
```

---

### [H-05] Silent Reward Loss in claimRewards() — Timestamp Advances Without Payout

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `claimRewards()` (lines 305-327)
**Sources:** Agent-B, Agent-D, Checklist (SOL-AM-DOSA-1), Solodit

**Description:**

In `claimRewards()`, `lastClaimAt` is advanced to `block.timestamp` (line 318) and `accumulatedReward` is incremented (line 319) **before** the conditional transfer check (line 321). While `_calculatePending()` caps `pending` to `pool.remainingReward`, a race condition exists: if `remainingReward` is reduced by another transaction (e.g., via `setRarityMultiplier()` which lacks `nonReentrant`) between the `_calculatePending()` call and the transfer, the condition `pending <= pool.remainingReward` may fail. When this happens, the staker receives zero tokens but their claim timestamp still advances, permanently losing those rewards.

Even without the race condition, when `pool.remainingReward` reaches exactly 0, the `_calculatePending()` returns 0, and subsequent claimers get nothing — but their accumulated time since last claim is lost because `lastClaimAt` was never updated to mark the boundary.

```solidity
// Lines 318-324: State advances regardless of payout
s.lastClaimAt = uint64(block.timestamp);   // Advances even if no payout
s.accumulatedReward += pending;             // Records phantom reward

if (pending <= pool.remainingReward) {      // May fail if remainingReward changed
    pool.remainingReward -= pending;
    IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);
}
// No revert or compensation when condition fails — rewards silently lost
```

**Real-World Precedent:** CodeHawks/RAAC: "Incorrect Reward Claim Logic in FeeCollector::claimRewards causes Denial of Service." Cyfrin Paladin Valkyrie v2.0 CRITICAL: reward calculation overflow causes "Reward tokens become permanently locked."

**Recommendation:**

Revert when rewards are insufficient instead of silently dropping them:

```solidity
if (pending > pool.remainingReward) {
    revert InsufficientRewards();
}
s.lastClaimAt = uint64(block.timestamp);
s.accumulatedReward += pending;
pool.remainingReward -= pending;
IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);
```

---

## Medium Findings

### [M-01] Streak Bonus Applied Retroactively to Full Unclaimed Period

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-15 (Precision Loss / Rounding Exploitation)
**Location:** `_calculatePending()` (lines 503, 508-510)
**Sources:** Agent-A, Agent-B, Checklist (PARTIAL)

**Description:**

The streak bonus is calculated based on `stakedAt` (line 503 → `_streakBonus(s.stakedAt)`) and applied multiplicatively to the entire elapsed period since `lastClaimAt`. This means:

- A staker who claims daily for 89 days earns at 1.0x-1.25x streak bonus (gradually increasing as they cross thresholds).
- A staker who waits and claims on day 90 earns the 1.5x bonus retroactively applied to all 90 days.

This creates an unfair incentive: the optimal strategy is to delay claiming until reaching the highest streak tier, then claim a lump sum with the maximum multiplier applied retroactively to the entire period.

**Recommendation:**

Track streak bonus changes by snapshotting the tier at each claim, or compute rewards in segments with the applicable multiplier for each time window.

---

### [M-02] setRarityMultiplier Missing nonReentrant Modifier

**Severity:** Medium
**Category:** SC08 Reentrancy
**VP Reference:** VP-01 (Classic Reentrancy)
**Location:** `setRarityMultiplier()` (lines 335-361)
**Sources:** Agent-A, Agent-C, Agent-D, Checklist (SOL-AM-RP-1), Solodit

**Description:**

`setRarityMultiplier()` performs a `safeTransfer` to `s.staker` (line 354) without the `nonReentrant` modifier. The state updates on lines 358-360 (`totalWeightedStakes` and `rarityMultiplier`) happen **after** the external call, violating the Checks-Effects-Interactions pattern. While the function is `onlyOwner` (limiting the attack surface), if `s.staker` is a contract, it could re-enter during the transfer callback.

A re-entrant call to `claimRewards()` or `unstake()` during the transfer would read stale `rarityMultiplier` and `totalWeightedStakes` values, potentially resulting in incorrect reward calculations.

```solidity
// Line 354: External call BEFORE state updates
IERC20(pool.rewardToken).safeTransfer(s.staker, pending);

// Lines 358-360: State updates AFTER external call (CEI violation)
totalWeightedStakes[poolId] = totalWeightedStakes[poolId] - s.rarityMultiplier + multiplier;
s.rarityMultiplier = multiplier;
```

**Recommendation:**

Add the `nonReentrant` modifier to `setRarityMultiplier()`. Also reorder to update state before the external call.

---

### [M-03] Missing Zero-Address Checks on createPool Parameters

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-22 (Zero-Address Check)
**Location:** `createPool()` (lines 175-222)
**Sources:** Agent-A, Agent-C, Agent-D, Checklist (SOL-Basics-Function-1), Solodit

**Description:**

`createPool()` does not validate that `collection` and `rewardToken` are non-zero addresses. Passing `address(0)` for `rewardToken` would cause the `safeTransferFrom` to revert, but the `nextPoolId` would already have been incremented (line 187), wasting a pool slot. Passing `address(0)` for `collection` would create a pool that no one can stake in (since `safeTransferFrom` on address(0) would fail in `stake()`), permanently locking the deposited reward tokens.

**Recommendation:**

```solidity
if (collection == address(0) || rewardToken == address(0)) revert InvalidAddress();
```

---

### [M-04] No Consistency Check Between totalReward and rewardPerDay * durationDays

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `createPool()` (lines 175-222)
**Sources:** Agent-B, Solodit

**Description:**

A pool creator can set inconsistent parameters. For example, `rewardPerDay = 1000 XOM`, `durationDays = 365`, but `totalReward = 100 XOM`. The pool appears to last 365 days but exhausts in ~2.4 hours. Conversely, `totalReward` could far exceed `rewardPerDay * durationDays`, leaving excess tokens permanently locked (compounded by H-03). While the `remainingReward` cap prevents over-distribution, the inconsistency misleads stakers about pool economics.

**Recommendation:**

Add a soft validation: `require(totalReward >= rewardPerDay * durationDays, "Underfunded pool")` or at minimum emit the computed `totalReward / rewardPerDay` effective duration in the event.

---

### [M-05] Staking Into Expired Pool Not Prevented

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `stake()` (lines 229-261)
**Sources:** Agent-B, Agent-C

**Description:**

The `stake()` function checks `pool.active` (line 235) but does not check whether `block.timestamp >= pool.endTime`. A user can stake into a pool whose intended duration has passed. Combined with H-02 (endTime not enforced in reward calculation), the staker would continue earning rewards from a pool that should have ended. Even with H-02 fixed, allowing staking after `endTime` is misleading — the user would stake their NFT into a pool with zero remaining reward period.

**Recommendation:**

Add `if (block.timestamp >= pool.endTime) revert PoolExpired();` to `stake()`.

---

## Low Findings

### [L-01] Single-Step Ownable Instead of Ownable2Step

**Severity:** Low
**VP Reference:** N/A (Architectural)
**Location:** Lines 11, 22, 161

The contract uses OpenZeppelin's `Ownable` with single-step ownership transfer. If the owner accidentally transfers to a wrong address, ownership is permanently lost, disabling `setRarityMultiplier()`, `pausePool()`, and `resumePool()`.

**Recommendation:** Use `Ownable2Step` which requires the new owner to accept the transfer.

---

### [L-02] Unsafe Downcasts Without Validation

**Severity:** Low
**VP Reference:** VP-14 (Unsafe Downcast)
**Location:** Lines 189-190, 200, 243-244, 250, 318, 348

Multiple unchecked downcasts to `uint64` and `uint32`:
- `uint64(block.timestamp)` — safe until year 2554, but will silently overflow
- `uint64(block.timestamp + durationDays * 1 days)` — could overflow for large `durationDays` (max uint16 = 65535 days = ~179 years, safe in practice)
- `uint32 totalStaked` — overflows at 4.29 billion NFTs (practically impossible per pool)

**Recommendation:** Use OpenZeppelin's `SafeCast` library for explicit overflow checks.

---

### [L-03] accumulatedReward Field Is Write-Only

**Severity:** Low
**VP Reference:** N/A (Dead Code)
**Location:** Lines 143, 281, 319, 349

The `accumulatedReward` field in the `Stake` struct is incremented in `unstake()`, `claimRewards()`, and `setRarityMultiplier()` but is never read by any internal logic. It's only exposed via the `getStake()` view function. While useful for off-chain tracking, the gas cost of storage writes (~5,000 gas per SSTORE) is wasted if no on-chain logic depends on it.

**Recommendation:** Document it as an off-chain accounting field, or remove if gas optimization is a priority.

---

### [L-04] pausePool Allows Claims and Unstakes

**Severity:** Low
**VP Reference:** N/A (Design Decision)
**Location:** `pausePool()` (lines 367-371), `claimRewards()` (line 310), `unstake()` (line 273)

`pausePool()` sets `pool.active = false`, but neither `claimRewards()` nor `unstake()` check `pool.active`. Only `stake()` checks it. This means pausing a pool only prevents new stakes — existing stakers can continue claiming and unstaking. This is likely intentional (users should always be able to exit) but is not documented.

**Recommendation:** Add NatSpec clarifying that pause only affects new stakes.

---

### [L-05] Missing Events for Admin State Changes

**Severity:** Low
**VP Reference:** N/A (Best Practice)
**Location:** `setRarityMultiplier()` (line 335), `pausePool()` (line 367), `resumePool()` (line 377)

Three owner-only state-changing functions lack events:
- `setRarityMultiplier()` — changes a staker's multiplier but emits no event
- `pausePool()` — disables new stakes but emits no event
- `resumePool()` — re-enables stakes but emits no event

Off-chain indexers and UIs cannot track these admin actions.

**Recommendation:** Add events: `RarityMultiplierSet(poolId, tokenId, oldMultiplier, newMultiplier)`, `PoolPaused(poolId)`, `PoolResumed(poolId)`.

---

### [L-06] No ERC-165 Validation on Collection Address

**Severity:** Low
**VP Reference:** VP-25 (Missing Validation)
**Location:** `createPool()` (line 175)

`createPool()` accepts any address as `collection` without verifying it implements `IERC721`. A pool created with a non-ERC721 address would permanently lock the deposited reward tokens since no one could successfully call `stake()` (the `safeTransferFrom` would revert).

**Recommendation:** Add `require(IERC165(collection).supportsInterface(type(IERC721).interfaceId))`.

---

## Informational Findings

### [I-01] Floating Pragma

**Severity:** Informational
**Location:** Line 2

The contract uses `pragma solidity ^0.8.24` (floating). For deployed contracts, a fixed pragma (e.g., `0.8.24`) is recommended to ensure consistent compilation behavior.

---

### [I-02] Stake Struct Not Deleted on Unstake

**Severity:** Informational
**Location:** `unstake()` (line 280)

When a user unstakes, the `Stake` struct remains in storage with `active = false`. Deleting the struct with `delete stakes[poolId][tokenId]` would provide a gas refund (~4,800 gas for each cleared slot). However, this would also clear `accumulatedReward` (used for off-chain tracking via `getStake()`).

---

### [I-03] Pool Creation Is Permissionless

**Severity:** Informational
**Location:** `createPool()` (line 175)

Anyone can create a staking pool for any NFT collection. While this is likely by design (community-driven pools), it means an attacker could create a phishing pool with a misleading `collection` address to trick users into staking NFTs into a pool controlled by a malicious `rewardToken` contract.

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Loss | Relevance |
|----------------|--------|------|-----------|
| Reward transfer DoS trapping user assets | Cyfrin Paladin Valkyrie v2.0 (2025) | Pool lockup | Exact match — `unstake()` couples reward transfer with NFT return |
| Liquidated positions accruing rewards past end | Sherlock/ZeroLend One (2025) | Reward over-distribution | Exact match — `endTime` not enforced in `_calculatePending()` |
| Fee-on-transfer reserve inconsistency | Code4rena/Virtuals Protocol (2025) | Accounting mismatch | Exact match — `remainingReward` set from parameter, not actual received |
| Removed pool losing ungulped emissions | Code4rena/Blend (2025) | Locked rewards | Direct — no creator withdrawal after pool ends |
| Reward claim advancing state without payout | CodeHawks/RAAC (2025) | Permanent reward loss | Direct — `lastClaimAt` advances regardless of transfer success |
| Missing emergency withdrawal in staking | Sherlock/LayerEdge (2025) | User asset lock | Direct — no `emergencyWithdraw()` fallback |

## Solodit Similar Findings

- **Sherlock/ZeroLend One H-8:** Positions accruing rewards past intended end — rated HIGH. Identical to H-02.
- **Cyfrin Paladin Valkyrie v2.0 (CRITICAL):** Permissionless reward distribution enabling pool lockup with irreversible liquidity lockup. Matches H-01 pattern.
- **Pashov Audit Group/Resolv L-08:** Users may lose rewards if reward token transfer fails. Same as H-01, rated Low there because no user assets were custodied.
- **Code4rena/Blend M-08:** Removing pool leads to loss of ungulped emissions. Same as H-03.
- **Code4rena/Virtuals Protocol:** Fee-induced reserve inconsistency. Same as H-04.
- **CodeHawks/RAAC:** Incorrect reward claim logic causes DoS. Same as H-05.
- **Sherlock/LayerEdge #168:** Missing emergency withdrawal methods in staking contract. Same as missing `emergencyWithdraw()` (part of H-01).

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**0 errors, 19 warnings:**
- 5x `not-rely-on-time`: Timestamp-dependent logic (acceptable for staking duration calculations)
- 4x `ordering`: Import and function ordering suggestions
- 4x `gas-custom-errors`: Already using custom errors (false positives on inherited code)
- 3x `max-line-length`: Lines exceeding 120 characters
- 2x `reason-string`: Custom errors used instead (no issue)
- 1x `no-empty-blocks`: Empty constructor body (intentional)

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Contract Owner (Ownable) | `setRarityMultiplier()`, `pausePool()`, `resumePool()` | 5/10 |
| Pool Creator | `createPool()` (deposits rewards, one-time) | 3/10 |
| Staker (msg.sender == stake.staker) | `stake()`, `unstake()`, `claimRewards()` | 2/10 |
| Any address | `createPool()` (permissionless), view functions | 2/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The contract owner can:
1. Set any staker's rarity multiplier to 0.1x (minimum), reducing their rewards by 100x
2. Pause pools indefinitely, preventing new stakes (but not claims/unstakes)
3. Transfer ownership to an incorrect address via single-step `Ownable`

The owner **cannot** drain user NFTs or reward tokens directly. The owner **cannot** prevent unstaking (since `unstake()` doesn't check `pool.active`).

**Centralization Risk Rating:** 5/10

**Recommendation:** Implement `Ownable2Step` and consider a timelock for `setRarityMultiplier()` to give stakers advance notice of multiplier changes. Consider making pool-specific admin functions callable by the pool creator rather than the global owner.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
