# Security Audit Report: LiquidityMining

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/liquidity/LiquidityMining.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 795
**Upgradeable:** No
**Handles Funds:** Yes (holds LP tokens and XOM reward tokens)

## Executive Summary

LiquidityMining is a MasterChef-style staking contract where users deposit LP tokens into pools to earn XOM rewards. Rewards are split between immediate (30% default) and vested (70% default, linearly over 90 days). The audit found **1 Critical vulnerability** — the vesting calculation hardcodes `DEFAULT_VESTING_PERIOD = 90 days` instead of using the pool-specific `vestingPeriod`, creating a direct contradiction with the harvest logic that uses the pool's configured period. Additionally, the **owner can drain all XOM** including rewards committed to users (High). The contract also has **fee-on-transfer token incompatibility**, **vesting schedule reset issues**, and **missing events** on admin functions. All 4 independent audit agents confirmed the Critical finding.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 2 |
| Medium | 5 |
| Low | 4 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 68 |
| Passed | 47 |
| Failed | 9 |
| Partial | 12 |
| **Compliance Score** | **69%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Basics-Math-1** (FAIL): `_calculateVested()` hardcodes 90-day period instead of pool-specific `vestingPeriod`
2. **SOL-Defi-Staking-2** (FAIL): Vesting schedule reset in `_harvestRewards()` overwrites unclaimed vested rewards
3. **SOL-AM-RP-1** (FAIL): `withdrawRewards()` allows owner to drain ALL XOM including user-committed rewards
4. **SOL-Defi-General-9** (FAIL): Fee-on-transfer LP tokens cause accounting inflation
5. **SOL-Basics-AL-9** (FAIL): `claimAll()` iterates unbounded `pools` array — DoS risk

---

## Critical Findings

### [C-01] _calculateVested() Hardcodes DEFAULT_VESTING_PERIOD, Ignoring Pool-Specific Configuration

**Severity:** Critical
**Category:** SC07 Arithmetic / SC02 Business Logic
**VP Reference:** VP-16 (Off-By-One / Logic Error)
**Location:** `_calculateVested()` (line 778), `_harvestRewards()` (line 709)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-Math-1, SOL-Basics-Function-4)

**Description:**

The contract allows per-pool vesting periods via `addPool()` (line 69) and `setVestingParams()` (line 286), storing `vestingPeriod` in the `PoolInfo` struct. However, `_calculateVested()` ignores this entirely and hardcodes `DEFAULT_VESTING_PERIOD = 90 days`:

```solidity
// Line 778 — ALWAYS uses 90 days regardless of pool configuration
uint256 vestingPeriod = DEFAULT_VESTING_PERIOD;
```

Meanwhile, `_harvestRewards()` uses the pool's actual `vestingPeriod` for vesting schedule reset decisions:

```solidity
// Line 709 — Uses pool.vestingPeriod for reset logic
if (userStakeInfo.vestingStart == 0 ||
    block.timestamp >= userStakeInfo.vestingStart + pool.vestingPeriod) {
```

This creates a direct contradiction:
- A pool with `vestingPeriod = 30 days`: Harvest resets the schedule after 30 days, but `_calculateVested()` calculates as if it's a 90-day vest — users can only claim 33% of vested rewards before the schedule resets, permanently losing the other 67%.
- A pool with `vestingPeriod = 180 days`: Harvest resets the schedule after 180 days, but `_calculateVested()` reports 100% vested after 90 days — users claim early.

The NatSpec at line 25 explicitly documents "70% of rewards vest linearly over 90 days (configurable)" but the implementation does not honor "configurable."

**Impact:** Direct financial loss. For any pool with a non-default vesting period, users either lose rewards (shorter periods) or receive them prematurely (longer periods). A pool owner could set `vestingPeriod = 1 day` expecting daily vesting, but users would need 90 days to fully vest, with the harvest function resetting their schedule daily and wiping unclaimed rewards.

**Real-World Precedent:** Zivoe (Sherlock 2024) — vesting reward logic inconsistencies causing locked/lost funds. Concur Finance (Code4rena 2022) — MasterChef reward calculation mismatches.

**Recommendation:**

Pass `poolId` to `_calculateVested()` and use the pool's configured vesting period:

```solidity
function _calculateVested(
    UserStake storage userStakeInfo,
    uint256 poolId
) internal view returns (uint256) {
    uint256 vestingPeriod = pools[poolId].vestingPeriod;
    if (vestingPeriod == 0) vestingPeriod = DEFAULT_VESTING_PERIOD;
    // ... rest of calculation using vestingPeriod
}
```

---

## High Findings

### [H-01] withdrawRewards() Allows Owner to Drain All XOM Including User-Committed Rewards

**Severity:** High
**Category:** SC01 Access Control / VP-57
**VP Reference:** VP-57 (recoverERC20 Backdoor)
**Location:** `withdrawRewards()` (lines 504-506)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-AM-RP-1, SOL-CR-3)

**Description:**

The `withdrawRewards()` function allows the owner to withdraw ANY amount of XOM from the contract without restriction:

```solidity
function withdrawRewards(uint256 amount) external onlyOwner {
    xom.safeTransfer(msg.sender, amount);
}
```

There is no check that `amount` is limited to excess/unallocated rewards versus XOM committed to users as pending immediate or vesting rewards. The owner can drain XOM that users have already earned but not yet claimed, causing their `claim()` and `claimAll()` calls to revert with insufficient balance.

**Real-World Precedent:** WardenPledge (Code4rena 2022) — owner bypasses ERC20 recovery restrictions to drain all rewards. Paladin (Code4rena 2022) — owner drains reserved reward tokens via recoverERC20.

**Recommendation:**

Track total committed rewards and restrict withdrawals:

```solidity
uint256 public totalCommittedRewards; // Updated in _harvestRewards and claim

function withdrawRewards(uint256 amount) external onlyOwner {
    uint256 available = xom.balanceOf(address(this)) - totalCommittedRewards;
    require(amount <= available, "Would impair pending claims");
    xom.safeTransfer(msg.sender, amount);
}
```

---

### [H-02] Vesting Schedule Reset Overwrites Unclaimed Vested Rewards

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-16 (Logic Error)
**Location:** `_harvestRewards()` (lines 706-717)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Defi-Staking-2)

**Description:**

When the vesting period has elapsed, `_harvestRewards()` fully resets the vesting schedule:

```solidity
// Lines 709-713 — Vesting period complete: full reset
if (block.timestamp >= userStakeInfo.vestingStart + pool.vestingPeriod) {
    userStakeInfo.vestingTotal = vestingReward;
    userStakeInfo.vestingClaimed = 0;
    userStakeInfo.vestingStart = block.timestamp;
}
```

This overwrites `vestingTotal` with only the new `vestingReward`. If the user had unclaimed vested rewards from the prior period (i.e., `vestingTotal - vestingClaimed > 0`), those rewards are silently lost.

When the vesting period has NOT yet elapsed:

```solidity
// Lines 714-717 — Vesting period ongoing: add to existing
else {
    userStakeInfo.vestingTotal += vestingReward;
}
```

New rewards are added to `vestingTotal` without adjusting `vestingStart`. This means newly added vested rewards inherit the old start time, allowing them to vest faster than intended.

**Recommendation:**

Before resetting, calculate and credit any unclaimed-but-vested rewards:

```solidity
uint256 alreadyVested = _calculateVested(userStakeInfo, poolId);
uint256 unclaimed = alreadyVested - userStakeInfo.vestingClaimed;
if (unclaimed > 0) {
    pendingImmediate += unclaimed; // Credit to immediate rewards
}
// Then reset schedule
userStakeInfo.vestingTotal = vestingReward;
userStakeInfo.vestingClaimed = 0;
userStakeInfo.vestingStart = block.timestamp;
```

---

## Medium Findings

### [M-01] Fee-on-Transfer LP Token Accounting Inflation

**Severity:** Medium
**Category:** SC05 Input Validation / SC02 Business Logic
**VP Reference:** VP-46 (Fee-on-Transfer Tokens)
**Location:** `stake()` (line 333)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Defi-AS-9, SOL-Defi-General-9)

**Description:**

In `stake()`, LP tokens are transferred via `safeTransferFrom` and the full `amount` is added to accounting without measuring actual received balance:

```solidity
pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
user.amount += amount;
pool.totalStaked += amount;
```

If the LP token applies a transfer fee, the contract receives fewer tokens than `amount`, but accounting records the full value. Over time, later withdrawers face insufficient balance.

**Real-World Precedent:** Inspex MasterChef (2022) — fee-on-transfer token accounting inflation in multiple SushiSwap forks. Concur Finance (Code4rena 2022) — improper handling of deposit fees in MasterChef.

**Recommendation:**

Measure actual received balance:

```solidity
uint256 balBefore = pool.lpToken.balanceOf(address(this));
pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
uint256 received = pool.lpToken.balanceOf(address(this)) - balBefore;
user.amount += received;
pool.totalStaked += received;
```

---

### [M-02] Emergency Withdrawal Fee Not Split 70/20/10

**Severity:** Medium
**Category:** SC02 Business Logic (Protocol Invariant)
**VP Reference:** N/A (Protocol Design)
**Location:** `emergencyWithdraw()` (lines 480-485)
**Sources:** Agent-B

**Description:**

OmniBazaar's standard fee distribution pattern is 70/20/10. The `emergencyWithdraw()` function sends 100% of the fee to the treasury address without splitting:

```solidity
uint256 fee = (user.amount * emergencyWithdrawFeeBps) / BASIS_POINTS;
pool.lpToken.safeTransfer(treasury, fee);
```

**Recommendation:** Either split the fee per protocol standards or document this as an intentional exception for emergency operations.

---

### [M-03] Unbounded Pool Array in claimAll() and addPool()

**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-29 (Unbounded Loop / Block Gas Limit)
**Location:** `claimAll()` (lines 420-453), `addPool()` (lines 237-241)
**Sources:** Agent-A, Agent-D, Checklist (SOL-Basics-AL-9)

**Description:**

`claimAll()` iterates over the entire `pools` array with no upper bound. `addPool()` also iterates the full array to check for duplicate LP tokens. If many pools are added, both functions could exceed the block gas limit.

**Recommendation:** Add a `MAX_POOLS` constant (e.g., 50) enforced in `addPool()`. Consider pagination for `claimAll()`.

---

### [M-04] Single-Step Ownership Transfer

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Access Control Design)
**Location:** Inherits `Ownable` (line 27)
**Sources:** Agent-B, Agent-C, Checklist (SOL-Basics-AC-4)

**Description:**

The contract uses OpenZeppelin's `Ownable` with single-step `transferOwnership()`. An accidental transfer to a wrong address permanently locks all admin functions.

**Recommendation:** Use `Ownable2Step` for two-step ownership transfer.

---

### [M-05] Admin Setter Functions Missing Events

**Severity:** Medium
**Category:** SC02 Business Logic (Monitoring)
**VP Reference:** N/A (Best Practice)
**Location:** `setVestingParams()` (line 286), `setPoolActive()` (line 303), `setEmergencyWithdrawFee()` (line 512), `setTreasury()` (line 521)
**Sources:** Agent-B, Agent-C, Checklist (SOL-CR-5, SOL-Basics-Event-1)

**Description:**

Multiple admin setter functions modify critical protocol parameters without emitting events. Off-chain monitoring tools and users cannot detect these changes.

**Recommendation:** Add events to all admin functions.

---

## Low Findings

### [L-01] No Minimum vestingPeriod Validation

**Severity:** Low
**Category:** SC05 Input Validation
**VP Reference:** VP-23 (Missing Amount Validation)
**Location:** `setVestingParams()` (lines 286-296), `addPool()` (line 69)
**Sources:** Agent-A, Checklist (SOL-Basics-Function-1, SOL-CR-7)

`setVestingParams()` allows `vestingPeriod = 0`. If C-01 is fixed to use pool-specific periods, a zero `vestingPeriod` would cause division-by-zero in `_calculateVested()`. Currently masked by the hardcoded period.

**Recommendation:** Require `vestingPeriod >= 1 days`.

---

### [L-02] No Admin Setter Rate Limits or Timelocks

**Severity:** Low
**Category:** SC01 Access Control (Centralization)
**VP Reference:** N/A
**Location:** All admin functions
**Sources:** Agent-C, Checklist (SOL-CR-4)

All admin functions execute immediately with no timelock. A compromised owner key could set all reward rates to 0, deactivate pools, or redirect the treasury instantly.

---

### [L-03] Flash-Stake Reward Manipulation

**Severity:** Low
**Category:** SC04 Flash Loan
**VP Reference:** VP-52 (Flash Loan Governance Attack pattern)
**Location:** `stake()` (line 313), `withdraw()` (line 350)
**Sources:** Agent-D, Checklist (SOL-Defi-General-8)

No minimum lock period between `stake()` and `withdraw()`. A flash loan could inflate `totalStaked` temporarily, manipulating per-share reward calculations for other users in the same block.

**Recommendation:** Add a minimum lock period (e.g., 1 block or 1 epoch).

---

### [L-04] Multiple Small Stakes Produce Different Vesting Outcomes

**Severity:** Low
**Category:** SC02 Business Logic
**VP Reference:** VP-16 (Logic Error)
**Location:** `_harvestRewards()` (lines 706-718)
**Sources:** Checklist (SOL-Heuristics-17)

Calling `stake()` multiple times with small amounts triggers `_harvestRewards()` each time, repeatedly resetting or extending the vesting schedule. This yields different vesting outcomes compared to a single large stake.

---

## Informational Findings

### [I-01] Floating Pragma

**Severity:** Informational
**Location:** Line 2

Uses `pragma solidity ^0.8.19;`. Pin to exact version for reproducible builds.

---

### [I-02] withdraw() Blocks During Pause but claim() Does Not

**Severity:** Informational
**Location:** `withdraw()` (line 353), `claim()` (line 388)

`withdraw()` has `whenNotPaused` but `claim()` does not. Users cannot withdraw LP tokens during a pause while rewards continue accruing to existing stakers.

---

### [I-03] emergencyWithdraw() Does Not Call _updatePool()

**Severity:** Informational
**Location:** `emergencyWithdraw()` (lines 459-490)

`emergencyWithdraw()` resets all user state without updating `accRewardPerShare`, meaning subsequent user interactions may use a stale accumulator.

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Relevance |
|----------------|--------|-----------
| MasterChef fee-on-transfer inflation | Inspex (2022), Concur Finance | Direct — M-01 matches pattern |
| Vesting schedule overwrite/loss | Zivoe (Sherlock 2024) | Direct — H-02 matches pattern |
| Owner drains reward tokens | WardenPledge, Paladin (Code4rena 2022) | Direct — H-01 matches pattern |
| Unbounded loops DoS | Multiple MasterChef forks | Direct — M-03 matches pattern |
| Flash-stake manipulation | SushiSwap MasterChef (known issue) | Low — L-03 matches pattern |

No DeFiHackLabs fund-loss incidents directly match this contract's MasterChef pattern at scale. The primary real-world risks are from the Critical vesting bug and the High owner drain capability.

## Solodit Similar Findings

- **Zivoe (Sherlock 2024):** Vesting reward distribution inconsistencies — locked/lost funds. Direct match to C-01 and H-02.
- **WardenPledge (Code4rena 2022):** Owner bypasses ERC20 recovery restrictions to drain all rewards — rated MEDIUM. Direct match to H-01.
- **Concur Finance (Code4rena 2022):** Wrong reward token calculation in MasterChef contract, improper deposit fee handling — rated HIGH. Direct match to C-01 and M-01.
- **Multiple MasterChef forks (Inspex 2022):** Fee-on-transfer token incompatibility causing accounting inflation — rated MEDIUM.
- **Paladin Valkyrie (Cyfrin 2025):** Parameter inconsistencies in reward distribution and vesting mechanisms.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33.

### Solhint
**0 errors, 26 warnings:**
- 1x `immutable-vars-naming`: `xom` not in UPPER_CASE
- 1x `ordering`: Struct after immutable declaration
- 10x `gas-indexed-events`: Event parameters not indexed
- 2x `gas-increment-by-one`: Use `++i` instead of `i++`
- 12x `gas-strict-inequalities`: Non-strict inequalities

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (Ownable) | `addPool()`, `setRewardRate()`, `setVestingParams()`, `setPoolActive()`, `depositRewards()`, `withdrawRewards()`, `setEmergencyWithdrawFee()`, `setTreasury()`, `pause()`, `unpause()` | 7/10 |
| Any user | `stake()`, `withdraw()`, `claim()`, `claimAll()`, `emergencyWithdraw()` | 1/10 |
| Any address | View functions: `pendingReward()`, `estimateAPR()`, `getPoolInfo()`, `getUserInfo()`, `poolCount()` | 0/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The owner can drain all XOM rewards via `withdrawRewards()` (H-01), set all reward rates to 0, deactivate all pools, change the treasury to their own address, and pause the contract indefinitely. Users' LP tokens are safe (cannot be withdrawn by owner), but all earned rewards can be stolen.

**Centralization Risk Rating:** 7/10

The owner has significant control over reward economics and can drain accumulated rewards. LP token principal is safe. The lack of timelocks, multi-sig requirements, or withdrawal caps on rewards makes this a medium-high centralization risk.

**Recommendation:** Deploy a multisig or timelock as the owner. Implement `Ownable2Step`. Add `totalCommittedRewards` tracking to prevent reward drainage. Consider adding a `MAX_EMERGENCY_FEE` cap and removing the ability to set arbitrary treasury addresses.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
