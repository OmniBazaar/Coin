# Security Audit Report: LiquidityMining (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/liquidity/LiquidityMining.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,057
**Upgradeable:** No
**Handles Funds:** Yes (holds LP tokens and XOM reward tokens)
**Previous Audits:** Round 1 (2026-02-21) -- 1 Critical, 2 High, 5 Medium, 4 Low, 3 Info

## Executive Summary

LiquidityMining is a MasterChef-style staking contract where users deposit LP tokens into configurable pools to earn XOM rewards. Rewards are split between immediate (30% default, configurable per pool in basis points) and vested (remainder, linearly vested over 90 days default, configurable per pool). The contract supports up to 50 pools, each with independent reward rates and vesting parameters.

**Round 3 re-audit finds that all Critical, High, and Medium-severity issues from Round 1 have been remediated.** The contract has grown from 795 to 1,057 lines with substantial improvements including: pool-specific vesting period in `_calculateVested` (C-01 fixed), `totalCommittedRewards` tracking to prevent owner fund drain (H-01 fixed), unclaimed vested rewards credited before schedule reset (H-02 fixed), fee-on-transfer balance-before/after pattern (M-01 fixed), 70/20/10 fee split on emergency withdrawal (M-02 fixed), MAX_POOLS = 50 cap (M-03 fixed), Ownable2Step inheritance (M-04 fixed), events on all admin functions (M-05 fixed), MIN_VESTING_PERIOD = 1 day validation (L-01 fixed), pinned pragma to 0.8.24 (I-01 fixed), and renounceOwnership disabled.

This round identifies **0 Critical, 0 High, 3 Medium, 4 Low, and 3 Informational** findings. The most significant remaining issue is a `totalCommittedRewards` accounting drift that can silently inflate over time due to the vesting schedule append logic, potentially locking excess XOM in the contract.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Informational | 3 |

## Round 1 Remediation Status

| Round 1 ID | Description | Status |
|------------|-------------|--------|
| C-01 | `_calculateVested()` hardcodes DEFAULT_VESTING_PERIOD | **FIXED** -- Now takes `poolId` parameter, uses `pools[poolId].vestingPeriod` with fallback to DEFAULT_VESTING_PERIOD (lines 1023-1036) |
| H-01 | `withdrawRewards()` allows owner to drain all XOM | **FIXED** -- `totalCommittedRewards` tracker added (line 123); `withdrawRewards()` restricts to excess above committed (lines 664-671) |
| H-02 | Vesting schedule reset overwrites unclaimed rewards | **FIXED** -- Unclaimed vested rewards credited to `pendingImmediate` before schedule reset (lines 946-952) |
| M-01 | Fee-on-transfer LP token accounting inflation | **FIXED** -- Balance-before/after pattern in `stake()` (lines 443-447) |
| M-02 | Emergency withdrawal fee not split 70/20/10 | **FIXED** -- Three-way split: 70% treasury, 20% validator, 10% staking pool (lines 634-644) |
| M-03 | Unbounded pool array in `claimAll()` / `addPool()` | **FIXED** -- `MAX_POOLS = 50` constant (line 89), enforced in `addPool()` (line 321) |
| M-04 | Single-step ownership transfer | **FIXED** -- Inherits `Ownable2Step` (line 28), `renounceOwnership()` disabled (line 878) |
| M-05 | Admin setter functions missing events | **FIXED** -- Events added: `VestingParamsUpdated`, `PoolActiveUpdated`, `EmergencyWithdrawFeeUpdated`, `TreasuryUpdated`, `ValidatorFeeRecipientUpdated`, `StakingPoolFeeRecipientUpdated` (lines 197-241) |
| L-01 | No minimum vestingPeriod validation | **FIXED** -- `MIN_VESTING_PERIOD = 1 days` (line 92), enforced in `setVestingParams()` (lines 390-394) |
| L-02 | No admin setter rate limits or timelocks | **NOT FIXED** -- See L-01 below (downgraded, acceptable for non-upgradeable contract with Ownable2Step) |
| L-03 | Flash-stake reward manipulation | **NOT FIXED** -- See L-02 below (same risk, mitigated by practical constraints) |
| L-04 | Multiple small stakes produce different vesting outcomes | **PARTIALLY FIXED** -- Unclaimed rewards now credited on reset (H-02 fix), but multiple-stake vesting asymmetry remains inherent to the design |
| I-01 | Floating pragma | **FIXED** -- Pinned to `0.8.24` (line 2) |
| I-02 | `withdraw()` blocks during pause but `claim()` does not | **NOT CHANGED** -- See I-01 below (intentional design: users can claim during pause but not add/remove LP) |
| I-03 | `emergencyWithdraw()` does not call `_updatePool()` | **NOT CHANGED** -- See I-02 below (acceptable: emergency path forfeits rewards, stale accumulator has no effect on user since all reward state is zeroed) |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 72 |
| Passed | 62 |
| Failed | 3 |
| Partial | 7 |
| **Compliance Score** | **86%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Defi-Staking-2** (PARTIAL): `totalCommittedRewards` can drift from actual obligations due to vesting append logic -- see M-01
2. **SOL-AM-RP-1** (PARTIAL): Owner can set `rewardPerSecond` to extreme values, inflating `totalCommittedRewards` beyond XOM balance, causing claim reverts -- see M-02
3. **SOL-Defi-General-8** (PARTIAL): No minimum lock between `stake()` and `withdraw()` -- see L-02
4. **SOL-CR-4** (FAIL): No timelocks on admin parameter changes -- see L-01
5. **SOL-Basics-Event-1** (FAIL): Indexed event parameters use all three slots for numeric values, limiting log filtering utility -- see I-03

---

## Medium Findings

### [M-01] totalCommittedRewards Accounting Drift Due to Vesting Append Logic

**Severity:** Medium
**Category:** SC02 Business Logic / SC07 Arithmetic
**VP Reference:** VP-15 (Rounding / Accounting Error)
**Location:** `_harvestRewards()` (lines 930-962), `emergencyWithdraw()` (lines 610-616)
**Sources:** Pass 1 (Logic), Pass 2 (Arithmetic), Pass 4 (Economic), Checklist (SOL-Defi-Staking-2)

**Description:**

The `totalCommittedRewards` tracker is incremented each time `_harvestRewards()` is called (line 934):

```solidity
totalCommittedRewards += immediateReward + vestingReward;
```

And decremented when rewards are claimed (lines 530, 586) or forfeited via emergency withdrawal (line 615).

However, when a completed vesting period's unclaimed rewards are credited to `pendingImmediate` (lines 946-951), the `totalCommittedRewards` is NOT decremented for those rewards and then re-incremented. These rewards were already counted when originally committed, and they are now being moved from the vesting bucket to the immediate bucket -- a neutral transfer. This part is correct.

The issue arises in the **append path** (line 960):

```solidity
} else {
    // Add to existing vesting (extends proportionally)
    userStakeInfo.vestingTotal += vestingReward;
}
```

When new vesting rewards are appended to an existing vesting schedule, `totalCommittedRewards` is incremented by the full `vestingReward`. But the `_calculateVested()` function computes vested amount proportionally:

```solidity
uint256 totalVested = (userStakeInfo.vestingTotal * elapsed) / vestingPeriod;
```

After appending, `vestingTotal` increases, making the already-elapsed portion appear to vest a larger absolute amount. When the user eventually claims via `claim()`, the `vestedAmount` returned by `_calculateVested()` may include a portion that was not separately committed via `totalCommittedRewards`. Conversely, new rewards inherit time already elapsed, meaning the user can claim them faster than intended, and the `totalCommittedRewards` may over-count the obligation if the user forfeits via `emergencyWithdraw()` before the new rewards would have vested under a clean schedule.

Over many harvest cycles with the append path, the cumulative drift between `totalCommittedRewards` and actual obligations can grow. In the worst case, `totalCommittedRewards` exceeds actual pending+vesting obligations, locking XOM in the contract that the owner cannot withdraw via `withdrawRewards()`.

**Impact:** `totalCommittedRewards` may overstate actual obligations, preventing the owner from recovering excess XOM. Users are not harmed -- they can always claim their full entitlement. The locked amount grows with the number of harvest-without-claim cycles.

**Real-World Precedent:** Zivoe (Sherlock 2024) -- vesting reward distribution inconsistencies causing accounting drift. Concur Finance (Code4rena 2022) -- accumulated reward accounting errors in MasterChef variants.

**Recommendation:**

Option A: Track committed rewards more granularly by separating immediate and vesting obligations:
```solidity
uint256 public totalCommittedImmediate;
uint256 public totalCommittedVesting;
```
Update `totalCommittedVesting` to reflect actual vesting obligations by decrementing the prior vestingTotal and re-adding the new total on schedule reset.

Option B: Add a recalibration function that the owner can call to recompute `totalCommittedRewards` by iterating all users/pools. This is gas-expensive but provides a correctness escape hatch.

Option C (simplest): On the append path, adjust for the time-weighted portion that becomes immediately vested due to elapsed time inheriting:
```solidity
} else {
    uint256 alreadyElapsed = block.timestamp - userStakeInfo.vestingStart;
    uint256 instantlyVested = (vestingReward * alreadyElapsed) / pool.vestingPeriod;
    userStakeInfo.pendingImmediate += instantlyVested;
    userStakeInfo.vestingTotal += vestingReward - instantlyVested;
    // totalCommittedRewards already incremented for full amount above
}
```

---

### [M-02] Unbounded rewardPerSecond Allows Inflating totalCommittedRewards Beyond XOM Balance

**Severity:** Medium
**Category:** SC05 Input Validation / SC01 Access Control (Centralization)
**VP Reference:** VP-23 (Missing Amount Validation), VP-57 (Admin parameter manipulation)
**Location:** `setRewardRate()` (lines 359-372), `addPool()` (lines 310-352)
**Sources:** Pass 1 (Logic), Pass 3 (Access Control), Checklist (SOL-AM-RP-1, SOL-CR-7)

**Description:**

Neither `setRewardRate()` nor `addPool()` validate `rewardPerSecond` against any upper bound. The owner can set an astronomically high reward rate that causes `_updatePool()` to produce enormous `accRewardPerShare` values. On the next `_harvestRewards()` call, `totalCommittedRewards` increases by the inflated reward amount.

Since `claim()` and `claimAll()` call `xom.safeTransfer()` for the total claimed amount, if `totalCommittedRewards` exceeds the contract's XOM balance, the transfer reverts. Users cannot claim their rewards even if some are legitimate.

The owner cannot directly steal funds this way (the H-01 fix protects `withdrawRewards()`), but an accidental or malicious extreme `rewardPerSecond` can permanently DoS all reward claims for a pool.

Additionally, `setRewardRate()` does not enforce `MIN_UPDATE_INTERVAL` (defined at line 86 as `1 days` but never checked). This constant appears to have been intended as a rate-limiting mechanism but is unused.

**Impact:** Owner misconfiguration or compromise can cause all claims to revert permanently. The `MIN_UPDATE_INTERVAL` constant is dead code.

**Recommendation:**

1. Enforce a maximum `rewardPerSecond` proportional to the contract's XOM balance:
```solidity
uint256 public constant MAX_REWARD_PER_SECOND = 1e24; // ~31.5B XOM/year
if (newRewardPerSecond > MAX_REWARD_PER_SECOND) revert InvalidParameters();
```

2. Either use `MIN_UPDATE_INTERVAL` for rate-limiting `setRewardRate()` calls, or remove the constant:
```solidity
mapping(uint256 => uint256) public lastRateUpdate;

function setRewardRate(uint256 poolId, uint256 newRewardPerSecond) external onlyOwner {
    if (block.timestamp - lastRateUpdate[poolId] < MIN_UPDATE_INTERVAL) revert InvalidParameters();
    // ...
    lastRateUpdate[poolId] = block.timestamp;
}
```

---

### [M-03] Deploy Script Constructor Argument Mismatch

**Severity:** Medium
**Category:** SC11 Deployment / Integration
**VP Reference:** N/A (Operational)
**Location:** `scripts/deploy-liquidity-infrastructure.ts` (lines 130-132)
**Sources:** Pass 5 (Integration)

**Description:**

The deployment script `deploy-liquidity-infrastructure.ts` deploys LiquidityMining with only 2 constructor arguments:

```typescript
const mining = await LiquidityMining.deploy(
    omniCoinAddress,           // XOM reward token
    treasuryAddress            // Treasury for fees
);
```

However, the current constructor requires 4 arguments:

```solidity
constructor(
    address _xom,
    address _treasury,
    address _validatorFeeRecipient,
    address _stakingPoolFeeRecipient
) Ownable(msg.sender) {
```

Deploying with this script will revert. The `validatorFeeRecipient` and `stakingPoolFeeRecipient` parameters (added as part of the M-02 fee split fix) are missing.

**Impact:** Deployment will fail if using the current deploy script. Not a vulnerability in the contract itself, but a deployment blocker.

**Recommendation:**

Update `deploy-liquidity-infrastructure.ts` to pass all 4 constructor arguments:
```typescript
const mining = await LiquidityMining.deploy(
    omniCoinAddress,           // XOM reward token
    treasuryAddress,           // Treasury for fees (70%)
    validatorAddress,          // Validator fee recipient (20%)
    stakingPoolAddress         // Staking pool fee recipient (10%)
);
```

---

## Low Findings

### [L-01] No Timelocks on Admin Parameter Changes

**Severity:** Low
**Category:** SC01 Access Control (Centralization)
**VP Reference:** VP-06 (Access Control Design)
**Location:** All admin functions: `setRewardRate()`, `setVestingParams()`, `setPoolActive()`, `setEmergencyWithdrawFee()`, `setTreasury()`, `setValidatorFeeRecipient()`, `setStakingPoolFeeRecipient()`
**Sources:** Pass 3 (Access Control), Checklist (SOL-CR-4)

**Description:**

All admin setter functions execute immediately with no timelock delay. While `Ownable2Step` protects against accidental ownership transfer, a compromised owner key can instantly:
- Set all reward rates to 0 (stopping reward accumulation)
- Deactivate all pools (preventing new stakes)
- Set emergency withdrawal fee to maximum 10%
- Redirect treasury, validator, and staking pool fee recipients to attacker addresses
- Change vesting parameters to disadvantage users mid-vesting

Users' staked LP tokens remain safe (only withdrawable by the staker), but reward economics can be arbitrarily manipulated. Downgraded from Round 1 because Ownable2Step makes key compromise harder and the contract is non-upgradeable.

**Recommendation:** Deploy the contract with a timelock controller (e.g., OpenZeppelin `TimelockController`) as the owner. This adds a delay between proposal and execution without modifying the contract.

---

### [L-02] Flash-Stake Reward Manipulation

**Severity:** Low
**Category:** SC04 Flash Loan / SC02 Business Logic
**VP Reference:** VP-52 (Flash Loan Attack Pattern)
**Location:** `stake()` (line 423), `withdraw()` (line 465)
**Sources:** Pass 2 (Arithmetic), Pass 4 (Economic), Checklist (SOL-Defi-General-8)

**Description:**

No minimum lock period exists between `stake()` and `withdraw()`. In a single transaction, a flash loan can:

1. Borrow LP tokens
2. `stake()` a large amount, inflating `pool.totalStaked`
3. Wait one block (or use same block if `block.timestamp` advances)
4. `withdraw()` the full amount

Because `_updatePool()` uses `block.timestamp - pool.lastRewardTime`, a same-block stake+withdraw earns 0 rewards (the elapsed time is 0). However, a next-block withdraw (2 seconds later on Avalanche) earns `rewardPerSecond * 2 * flashAmount / totalStaked`, diluting legitimate stakers' rewards for that interval.

The practical impact is low because:
- Flash loans for LP tokens are less common than for single tokens
- The reward dilution per block is small relative to long-term staking
- The attacker must repay the flash loan with interest

**Recommendation:** Add a minimum lock period:
```solidity
mapping(uint256 => mapping(address => uint256)) public lastStakeTime;

function withdraw(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
    if (block.timestamp - lastStakeTime[poolId][msg.sender] < MIN_LOCK_PERIOD) {
        revert TooEarly();
    }
    // ...
}
```

---

### [L-03] addPool() Allows immediateBps = 0 But Overrides to DEFAULT_IMMEDIATE_BPS

**Severity:** Low
**Category:** SC05 Input Validation
**VP Reference:** VP-16 (Logic Error)
**Location:** `addPool()` (lines 340-342)
**Sources:** Pass 1 (Logic)

**Description:**

In `addPool()`, if `immediateBps` is passed as 0, it is silently overridden to `DEFAULT_IMMEDIATE_BPS` (3000 = 30%):

```solidity
immediateBps: immediateBps > 0
    ? immediateBps
    : DEFAULT_IMMEDIATE_BPS,
```

This behavior contradicts the `setVestingParams()` function (line 396), which allows `immediateBps = 0` explicitly (100% vesting, no immediate rewards). An owner who wants a fully-vesting pool must call `addPool()` with any non-zero `immediateBps` and then immediately call `setVestingParams()` to set it to 0.

Similarly, `vestingPeriod = 0` in `addPool()` is overridden to `DEFAULT_VESTING_PERIOD`, but `setVestingParams()` allows `vestingPeriod = 0` (with the `MIN_VESTING_PERIOD` check only applying when `vestingPeriod > 0`). A pool with `vestingPeriod = 0` would mean no vesting (all rewards immediate, regardless of `immediateBps`), which is handled by the fallback in `_calculateVested()` (line 1036).

**Impact:** Low. Owner inconvenience -- requires two transactions to create a fully-vesting pool. No funds at risk.

**Recommendation:** Allow 0 as a valid value in `addPool()` or document the default override behavior:
```solidity
// If immediateBps is explicitly 0, honor it (100% vesting)
// Only use default when not specified (use a sentinel value or separate overload)
immediateBps: immediateBps, // Remove the ternary
```

---

### [L-04] emergencyWithdraw Forfeited Rewards Guarded By >= But Can Silently Under-Decrement

**Severity:** Low
**Category:** SC07 Arithmetic
**VP Reference:** VP-12 (Unchecked Arithmetic)
**Location:** `emergencyWithdraw()` (lines 610-616)
**Sources:** Pass 2 (Arithmetic)

**Description:**

```solidity
uint256 forfeited = user.pendingImmediate +
    user.vestingTotal -
    user.vestingClaimed;
if (forfeited > 0 && totalCommittedRewards >= forfeited) {
    totalCommittedRewards -= forfeited;
}
```

The `totalCommittedRewards >= forfeited` guard prevents underflow, which is correct. However, if `totalCommittedRewards < forfeited` (due to the accounting drift described in M-01, or due to rounding), the decrement is silently skipped entirely. This means `totalCommittedRewards` retains the forfeited amount as if it is still committed, further inflating the tracker and locking additional XOM in the contract.

A more correct approach would decrement `totalCommittedRewards` by `min(forfeited, totalCommittedRewards)` to partially correct the tracker rather than skipping entirely.

**Impact:** Low. Worsens the M-01 drift in edge cases where `totalCommittedRewards` is already under-tracking. Owner's excess XOM remains locked.

**Recommendation:**

```solidity
if (forfeited > 0) {
    uint256 decrement = forfeited > totalCommittedRewards
        ? totalCommittedRewards
        : forfeited;
    totalCommittedRewards -= decrement;
}
```

---

## Informational Findings

### [I-01] claim() Is Not Guarded by whenNotPaused

**Severity:** Informational
**Location:** `claim()` (line 503), `claimAll()` (line 547)

**Description:**

`stake()` and `withdraw()` are guarded by `whenNotPaused`, but `claim()` and `claimAll()` are not. This means users can continue claiming rewards during a pause, while new staking and unstaking are blocked. `emergencyWithdraw()` also lacks `whenNotPaused` but is explicitly designed for emergency situations.

This appears to be an intentional design choice: during a pause (e.g., due to a discovered exploit), users should be able to claim already-earned rewards and perform emergency withdrawals, but not modify their staking positions. This is a reasonable security pattern.

**Recommendation:** If this is intentional, add a NatSpec comment documenting the pause semantics. If unintentional, add `whenNotPaused` to `claim()` and `claimAll()`.

---

### [I-02] emergencyWithdraw() Does Not Call _updatePool()

**Severity:** Informational
**Location:** `emergencyWithdraw()` (lines 599-649)

**Description:**

`emergencyWithdraw()` resets all user state without first calling `_updatePool()`. This means `accRewardPerShare` is not updated for the time between the last pool update and the emergency withdrawal. Since the user's entire reward state is zeroed (lines 623-628) and they forfeit all rewards, the stale accumulator does not affect the withdrawing user.

However, the stale `pool.lastRewardTime` means the NEXT user who interacts with the pool (stake, withdraw, or claim) will trigger `_updatePool()`, which will compute rewards for the full elapsed period including the time before the emergency withdrawal. Since `pool.totalStaked` has already been decremented (line 631), the remaining stakers receive a slightly larger share of the rewards for that interval than they would have if the pool had been updated first. This is a minor wealth transfer from the emergency withdrawer (who forfeits) to remaining stakers.

**Impact:** Negligible. The emergency withdrawer has already forfeited all rewards. Remaining stakers receive a marginally larger share.

**Recommendation:** No change needed. Calling `_updatePool()` before the emergency withdrawal would be more precise but adds gas cost to an already-expensive emergency path. The current behavior slightly benefits remaining stakers.

---

### [I-03] Event Parameters Over-Use Indexed for Numeric Values

**Severity:** Informational
**Location:** Multiple events (lines 132-241)

**Description:**

Several events use all three `indexed` parameter slots on numeric values rather than addresses. For example:

```solidity
event PoolAdded(
    uint256 indexed poolId,
    address indexed lpToken,
    uint256 indexed rewardPerSecond,    // Numeric value as indexed
    string name                         // Not indexed, but queryable
);
```

Indexed numeric parameters are stored as topic hashes, making exact-value filtering possible but range queries impossible. The `name` parameter (a string) would benefit more from indexing for log filtering purposes. Similarly, `RewardsClaimed` indexes `immediateAmount` and `vestedAmount` rather than the `user` address (which IS indexed).

This is not a bug but reduces the utility of event logs for off-chain monitoring tools.

**Recommendation:** Consider restructuring event parameters to index addresses and identifiers rather than amounts:
```solidity
event PoolAdded(
    uint256 indexed poolId,
    address indexed lpToken,
    uint256 rewardPerSecond,         // Not indexed -- amounts are better unindexed
    string name
);
```

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Zivoe | 2024 | N/A (Sherlock) | Vesting reward distribution inconsistencies -- C-01/H-02 from Round 1 now FIXED |
| Concur Finance | 2022-01 | N/A (Code4rena) | MasterChef reward calculation mismatches -- C-01 from Round 1 now FIXED; M-01 accounting drift partially related |
| WardenPledge | 2022-10 | N/A (Code4rena) | Owner drains reserved reward tokens -- H-01 from Round 1 now FIXED |
| Penpie | 2024-09 | $27.3M | Reentrancy in reward harvesting -- mitigated by `nonReentrant` on all state-changing functions |
| SushiSwap MasterChef | Known Issue | N/A | Flash-stake reward dilution -- L-02, same risk accepted |
| Euler Finance | 2023-03 | $200M | Donation attack on share-based accounting -- not directly applicable (no share-based math) |
| Harvest Finance | 2020-10 | $34M | Flash loan LP manipulation -- L-02, flash-stake variant |

No confirmed critical exploit patterns match this contract's current implementation. The balance-before/after pattern, nonReentrant guards, Ownable2Step, and totalCommittedRewards tracking effectively mitigate the most common MasterChef attack vectors.

## Solodit Similar Findings

- [Zivoe (Sherlock 2024) -- Vesting reward inconsistencies](https://solodit.cyfrin.io/) -- Directly matched Round 1's C-01 and H-02. Both now fixed. Residual M-01 (accounting drift in append path) is a lower-severity variant.
- [Concur Finance (Code4rena 2022) -- Wrong reward token calculation](https://solodit.cyfrin.io/) -- Matched Round 1's C-01. Now fixed. M-01 is a subtler variant involving committed-reward tracking rather than core reward calculation.
- [MasterChef fee-on-transfer (Inspex 2022)](https://solodit.cyfrin.io/) -- Matched Round 1's M-01. Now fixed with balance-before/after pattern.
- [WardenPledge (Code4rena 2022) -- Owner bypasses recovery restrictions](https://solodit.cyfrin.io/) -- Matched Round 1's H-01. Now fixed with totalCommittedRewards tracking.
- [Paladin Valkyrie (Cyfrin 2025) -- Parameter inconsistencies in reward distribution](https://solodit.cyfrin.io/) -- Related to M-02 (unbounded rewardPerSecond) and L-03 (addPool default override inconsistency).

## Static Analysis Summary

### Slither
**Status:** Not run -- full-project compilation required; known build artifact issues with deleted contracts prevent single-file analysis. Recommend running after `npx hardhat clean && npx hardhat compile`.

### Aderyn
**Status:** Not run -- Aderyn v0.6.8 incompatible with solc v0.8.24 (known crash in AST ingestion).

### Solhint
**Status:** Passed (0 errors, 0 warnings)

The contract uses inline `solhint-disable-next-line` comments for intentional timestamp usage (`not-rely-on-time`), intentional gas patterns (`gas-strict-inequalities`), and the lowercase `xom` immutable (`immutable-vars-naming`). All suppressions are appropriate and documented.

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (Ownable2Step) | `addPool()`, `setRewardRate()`, `setVestingParams()`, `setPoolActive()`, `depositRewards()`, `withdrawRewards()`, `setEmergencyWithdrawFee()`, `setTreasury()`, `setValidatorFeeRecipient()`, `setStakingPoolFeeRecipient()`, `pause()`, `unpause()` | **5/10** |
| Any user | `stake()`, `withdraw()`, `claim()`, `claimAll()`, `emergencyWithdraw()` | **1/10** |
| Any address | View functions: `estimateAPR()`, `getPoolInfo()`, `getUserInfo()`, `poolCount()` | **0/10** |

## Centralization Risk Assessment

**Single-key maximum damage:** The owner can set all reward rates to 0 (stopping accumulation), deactivate all pools (blocking new stakes), redirect fee recipients to their own addresses, set emergency withdrawal fee to 10%, and pause the contract indefinitely. However, the owner **cannot**:
- Withdraw user-committed XOM rewards (protected by `totalCommittedRewards`)
- Withdraw user LP tokens (no admin withdrawal function for LP tokens)
- Upgrade the contract (non-upgradeable)
- Renounce ownership (disabled)

**Centralization Risk Rating: 5/10** (down from 7/10 in Round 1)

Improvements since Round 1:
- `Ownable2Step` prevents accidental ownership transfer
- `totalCommittedRewards` prevents owner from draining earned rewards
- `renounceOwnership()` disabled prevents lockout
- 70/20/10 fee split ensures fee distribution follows protocol standards
- Non-upgradeable contract eliminates UUPS/proxy upgrade risk

**Remaining risks:** All admin functions execute immediately (no timelock). Recommended deployment with TimelockController as owner.

---

## Comparison: Round 1 vs Round 3

| Metric | Round 1 (2026-02-21) | Round 3 (2026-02-26) |
|--------|----------------------|----------------------|
| Lines of Code | 795 | 1,057 |
| Solidity Version | ^0.8.19 | 0.8.24 (pinned) |
| Critical | 1 | **0** |
| High | 2 | **0** |
| Medium | 5 | **3** |
| Low | 4 | **4** |
| Informational | 3 | **3** |
| Ownership Model | Ownable (single-step) | **Ownable2Step** |
| renounceOwnership | Enabled | **Disabled** |
| Vesting Period Usage | Hardcoded 90 days | **Pool-specific** |
| Fee-on-Transfer | Vulnerable | **Balance-before/after** |
| Emergency Fee Split | 100% treasury | **70/20/10** |
| Committed Rewards Tracking | None | **totalCommittedRewards** |
| Pool Cap | None | **MAX_POOLS = 50** |
| Min Vesting Period | None | **MIN_VESTING_PERIOD = 1 day** |
| Admin Events | Partial | **Complete** |
| Fee Recipients | 1 (treasury only) | **3 (treasury + validator + staking pool)** |
| Compliance Score | 69% | **86%** |

**Assessment:** The contract has undergone substantial hardening since Round 1. All Critical and High vulnerabilities have been fully remediated. The remaining Medium findings are accounting precision issues (M-01), input validation gaps (M-02), and a deployment script mismatch (M-03) -- none represent direct fund-loss vectors. The contract is significantly more secure and approaching production readiness. The primary recommendation is to deploy with a TimelockController as the owner to address the L-01 centralization concern.

---

*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Static tools: Solhint (passed, 0 errors 0 warnings), Slither (not run -- build artifacts), Aderyn (not run -- compiler crash)*
