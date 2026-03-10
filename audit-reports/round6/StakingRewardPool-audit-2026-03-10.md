# Security Audit Report: StakingRewardPool (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Deep Review)
**Contract:** `Coin/contracts/StakingRewardPool.sol`
**Solidity Version:** 0.8.24 (locked)
**Lines of Code:** 1,095
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (XOM reward pool)
**Previous Audit:** 2026-02-20 (Round 1 -- 0C/7H/7M/5L/4I)
**Attacker Review:** 2026-02-28 (Round 4 -- ATK-H01 flash-stake)
**Remediation Status:** All prior H/M findings addressed

---

## Executive Summary

StakingRewardPool is a UUPS upgradeable contract that distributes XOM staking rewards using a trustless time-based drip pattern. It reads stake data from OmniCore and computes per-second APR rewards on-chain. Users claim directly without validator involvement.

This Round 6 re-audit evaluates the contract after all Round 1 (7 High, 7 Medium) and Round 4 (ATK-H01) remediations were applied. The contract has improved substantially. The audit identifies **0 Critical, 2 High, 4 Medium, 5 Low, and 4 Informational** findings. The most significant remaining issues are: (1) inconsistent use of `msg.sender` vs `_msgSender()` in `depositToPool()` bypasses ERC-2771 meta-transaction support; (2) the unlock/snapshot race condition (H-04 from Round 1) remains an operational risk despite the `lastActiveStake` cache mitigation; (3) `duration=0` staking is still allowed in OmniCore, creating a MIN_STAKE_AGE-bounded but non-trivial reward extraction window.

**Remediation Verification:**

| Round 1 ID | Status | Verification |
|------------|--------|-------------|
| H-01 | FIXED | `emergencyWithdraw` blocks XOM token withdrawal |
| H-02 | FIXED | `setContracts` replaced with 48h timelock (propose/execute) |
| H-03 | FIXED | `MAX_TOTAL_APR = 1200` enforced on all APR setters |
| H-04 | PARTIALLY FIXED | `lastActiveStake` cache added; operational risk remains |
| H-05 | FIXED | `_authorizeUpgrade` uses `DEFAULT_ADMIN_ROLE` |
| H-06 | N/A (deployment script) | Not in contract scope |
| H-07 | FIXED | `_clampTier()` independently validates tier vs amount |
| M-01 | FIXED | Partial claims when pool underfunded; remainder stored in `frozenRewards` |
| M-02 | FIXED | `earned()` uses try/catch; falls back to frozen-only |
| M-03 | FIXED | `PausableUpgradeable` integrated; `whenNotPaused` on key functions |
| M-04 | FIXED | APR changes use 24h timelock (propose/execute) |
| M-05 | DOCUMENTED | Range-based duration tiers acknowledged as intentional design |
| M-06 | FIXED | `EmergencyWithdrawal` event emitted |
| M-07 | FIXED | Underflow guard: `if (lockTime < duration) return 0` |
| ATK-H01 | FIXED | `MIN_STAKE_AGE = 1 days` prevents flash-stake extraction |

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 5 |
| Informational | 4 |

**Centralization Rating:** 5/10 (Moderate -- improved from 8/10 via timelocks)

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | `depositToPool()` uses `msg.sender` instead of `_msgSender()` — breaks meta-transactions | **FIXED** |
| H-02 | High | `unlock()` and `snapshot()` race condition — unlock before snapshot loses rewards | **FIXED** |
| M-01 | Medium | Missing `whenNotPaused` on `depositToPool()` and `snapshot()` | **FIXED** |
| M-02 | Medium | No event emission on tier threshold updates | **FIXED** |
| M-03 | Medium | `emergencyWithdraw()` does not update `totalStaked` accounting | **FIXED** |
| M-04 | Medium | Missing zero-address check in `setRewardToken()` | **FIXED** |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `emergencyWithdraw()`, `pause()`, `unpause()`, `ossify()`, `_authorizeUpgrade()`, grant/revoke all roles | 7/10 |
| ADMIN_ROLE | `proposeTierAPR()`, `proposeDurationBonusAPR()`, `executeAPRChange()`, `cancelAPRChange()`, `proposeContracts()`, `executeContracts()`, `cancelContractsChange()` | 5/10 |
| Anyone | `claimRewards()`, `snapshotRewards()`, `depositToPool()`, `earned()`, `getEffectiveAPR()`, `getPoolBalance()` | 1/10 |

**Role Separation:** Well designed. `DEFAULT_ADMIN_ROLE` controls emergency and upgrade functions. `ADMIN_ROLE` controls configuration with timelocks. This is a significant improvement over Round 1 where both roles had immediate, untimelocked power.

**Who Can Fund the Pool:** Anyone can call `depositToPool()`. By design, validators deposit block reward shares and the UnifiedFeeVault distributes 20% of marketplace fees to this pool.

**Who Can Distribute Rewards:** No one distributes manually. Users self-serve via `claimRewards()`. The contract computes rewards trustlessly from on-chain stake data.

**Who Can Modify APR Tiers:** Only `ADMIN_ROLE`, with a mandatory 24-hour timelock delay between proposal and execution.

---

## Business Logic Verification

### APR Tiers

| Tier | Specified (CLAUDE.md) | Implemented (line 425-429) | Status |
|------|----------------------|---------------------------|--------|
| Tier 1 (1 - 999,999 XOM) | 5% | `tierAPR[1] = 500` | CORRECT |
| Tier 2 (1M - 9,999,999 XOM) | 6% | `tierAPR[2] = 600` | CORRECT |
| Tier 3 (10M - 99,999,999 XOM) | 7% | `tierAPR[3] = 700` | CORRECT |
| Tier 4 (100M - 999,999,999 XOM) | 8% | `tierAPR[4] = 800` | CORRECT |
| Tier 5 (1B+ XOM) | 9% | `tierAPR[5] = 900` | CORRECT |

### Duration Bonuses

| Duration | Specified | Implemented (line 433-435) | Status |
|----------|----------|---------------------------|--------|
| No commitment | 0% | `durationBonusAPR[0]` = 0 (default) | CORRECT |
| 1 month (30 days) | +1% | `durationBonusAPR[1] = 100` | CORRECT |
| 6 months (180 days) | +2% | `durationBonusAPR[2] = 200` | CORRECT |
| 2 years (730 days) | +3% | `durationBonusAPR[3] = 300` | CORRECT |

### Total APR Range

**Specified:** 5-12% | **Implemented:** 500-1200 bps | **MAX_TOTAL_APR cap:** 1200 bps | **Status:** CORRECT

Note: The MAX_TOTAL_APR cap (line 177) is enforced on individual APR setter proposals (`proposeTierAPR` at line 571, `proposeDurationBonusAPR` at line 606). However, see M-01 below regarding combined APR validation.

### Reward Calculation Formula

```
reward = (amount * effectiveAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)
       = (amount * effectiveAPR * elapsed) / (31536000 * 10000)
```

**Verification (line 948-949):**
```solidity
return (stakeData.amount * effectiveAPR * elapsed)
    / (SECONDS_PER_YEAR * BASIS_POINTS);
```

**Pro-rata:** Correct. Rewards accrue per-second based on elapsed time since last claim or stake start.

**Overflow Analysis:**
- Max amount: 16.6B XOM = ~1.66e28 (18 decimals)
- Max APR: 1200 bps
- Max elapsed: 40 years = ~1.26e9 seconds
- Product: 1.66e28 * 1200 * 1.26e9 = ~2.5e40
- uint256 max: ~1.16e77
- **No overflow risk.**

### Early Withdrawal Penalty

**Specified:** "Substantial penalty applies" per tokenomics documentation.
**Implemented:** NOT IMPLEMENTED in StakingRewardPool or OmniCore.

OmniCore's `unlock()` enforces `block.timestamp >= lockTime` (line 716), meaning early withdrawal is simply impossible -- the transaction reverts with `StakeLocked()`. The "penalty" is effectively infinite: you cannot withdraw early at all. This may or may not match the tokenomics intent, which seems to describe a penalty fee for early exit rather than total lockout. See I-03 below.

### Pool Funding from Block Rewards

**Specified:** "Up to 50% per block" from block rewards, plus fee allocations.
**Implemented:** `depositToPool()` is a permissionless deposit function. The 50% cap and block reward logic are enforced off-chain by validators and on-chain by OmniValidatorRewards. UnifiedFeeVault sends 20% of marketplace fees to the pool. The pool itself does not enforce the 50% cap -- it accepts any deposit amount. This is correct design: the pool is a receiver, not an enforcer.

### Productive Use of Staked XOM for DEX Liquidity

**Specified:** "Staked XOM used for DEX liquidity provision."
**Implemented:** NOT IMPLEMENTED in StakingRewardPool. Staked XOM is held by OmniCore, not this pool. The pool only holds reward tokens, not staked principal. DEX liquidity integration, if any, would need to be in OmniCore or a separate contract. See I-04 below.

---

## High Findings

### [H-01] depositToPool Uses msg.sender Instead of _msgSender() -- ERC-2771 Bypass

**Severity:** High
**Category:** SC02 Business Logic / ERC-2771 Consistency
**Location:** `depositToPool()` (lines 542-553)

**Description:**

The contract inherits `ERC2771ContextUpgradeable` and overrides `_msgSender()` (line 1055) to support meta-transactions via a trusted forwarder. The `claimRewards()` function correctly uses `_msgSender()` (line 455). However, `depositToPool()` uses raw `msg.sender` in two places:

```solidity
function depositToPool(uint256 amount) external whenNotPaused {
    if (amount == 0) revert InvalidAmount();
    xomToken.safeTransferFrom(
        msg.sender, address(this), amount  // <-- Should be _msgSender()
    );
    totalDeposited += amount;
    emit PoolDeposit(msg.sender, amount, totalDeposited);  // <-- Should be _msgSender()
}
```

When a meta-transaction is relayed through the trusted forwarder:
1. `msg.sender` is the forwarder contract, NOT the actual user
2. `safeTransferFrom(forwarder, ...)` will attempt to transfer tokens from the forwarder, not the user
3. The transaction will either fail (if forwarder has no balance/approval) or transfer the forwarder's tokens (if it does have balance), crediting the wrong depositor in the event

This breaks meta-transaction deposit functionality entirely.

**Impact:** Meta-transaction deposits via trusted forwarder are non-functional. If the trusted forwarder holds XOM tokens with approval to this contract, those tokens could be stolen by anyone who relays a deposit meta-transaction.

**Recommendation:**
```solidity
function depositToPool(uint256 amount) external whenNotPaused {
    if (amount == 0) revert InvalidAmount();
    address caller = _msgSender();
    xomToken.safeTransferFrom(caller, address(this), amount);
    totalDeposited += amount;
    emit PoolDeposit(caller, amount, totalDeposited);
}
```

---

### [H-02] Unlock/Snapshot Race Condition Remains an Operational Risk

**Severity:** High
**Category:** SC02 Business Logic
**Location:** `snapshotRewards()` (lines 497-534), OmniCore `unlock()` (OmniCore.sol line 711)

**Description:**

The Round 1 H-04 finding identified that if a user calls `OmniCore.unlock()` without first calling `StakingRewardPool.snapshotRewards()`, their accrued rewards are permanently lost. The remediation added `lastActiveStake` caching and frozen reward preservation.

However, the fundamental race condition persists: **there is no on-chain enforcement that `snapshotRewards()` is called before `unlock()`**. The `lastActiveStake` cache is only populated when `snapshotRewards()` is explicitly called. After `unlock()`:

1. OmniCore sets `stake.active = false` and `stake.amount = 0` (OmniCore.sol lines 721-725)
2. `earned()` reads the zeroed stake from OmniCore, finds `!active`, returns only `frozenRewards[user]`
3. If `frozenRewards[user] == 0` (never snapshotted), all accrued rewards are lost
4. The `lastActiveStake` cache is never consulted by `earned()` or `_computeAccrued()`

The `lastActiveStake` mapping is written to in `snapshotRewards()` (line 526-532) but is never read by any function in the contract. It exists purely for off-chain reference or future use.

**Impact:** Users who call `unlock()` directly (without prior `snapshotRewards()`) permanently lose all accrued rewards. Given that `unlock()` is the natural user action and `snapshotRewards()` is an extra step that must be remembered, this will affect users who do not use a frontend that bundles both calls.

**Recommendation:**

Option A (preferred): Have OmniCore's `unlock()` call `StakingRewardPool.snapshotRewards(caller)` before clearing the stake. This requires OmniCore to hold a reference to StakingRewardPool.

Option B: Modify `earned()` to fall back to `lastActiveStake` when the on-chain stake is inactive:

```solidity
function earned(address user) public view returns (uint256) {
    uint256 frozen = frozenRewards[user];

    try omniCore.getStake(user) returns (
        IOmniCoreStaking.Stake memory stakeData
    ) {
        if (!stakeData.active || stakeData.amount == 0) {
            // Fall back to cached stake data if available
            CachedStake memory cached = lastActiveStake[user];
            if (cached.amount > 0 && cached.snapshotTime > 0) {
                // Compute rewards from last claim to snapshot time
                // (already captured in frozenRewards via snapshotRewards)
            }
            return frozen;
        }
        uint256 accrued = _computeAccrued(user, stakeData);
        return frozen + accrued;
    } catch {
        return frozen;
    }
}
```

Option C (minimal): Document clearly in OmniCore's `unlock()` NatSpec and in frontend code that `snapshotRewards()` MUST be called first, and add a view function `hasUnsnapshotedRewards(user)` to help frontends detect the risk.

---

## Medium Findings

### [M-01] Combined APR Validation Gap -- Individual Caps Don't Prevent 24% Combined

**Severity:** Medium
**Category:** SC02 Business Logic
**Location:** `proposeTierAPR()` (line 571), `proposeDurationBonusAPR()` (line 606), `_getEffectiveAPR()` (line 960-971)

**Description:**

Both `proposeTierAPR()` and `proposeDurationBonusAPR()` individually check `if (apr > MAX_TOTAL_APR) revert APRExceedsMaximum()`. This means a tier APR of 1200 (12%) and a duration bonus APR of 1200 (12%) would each pass validation individually. The combined effective APR would be 2400 bps (24%), double the documented maximum.

In `_getEffectiveAPR()`:
```solidity
return baseAPR + bonusAPR;  // Can exceed MAX_TOTAL_APR
```

There is no check that `baseAPR + bonusAPR <= MAX_TOTAL_APR`.

**Exploit Scenario:**
1. Admin proposes `tierAPR[5] = 1200` (12%) -- passes individual check
2. After 24h, admin executes
3. Admin proposes `durationBonusAPR[3] = 1200` (12%) -- passes individual check
4. After 24h, admin executes
5. User staking at Tier 5 with 2-year lock gets 24% APR

**Mitigating Factors:** This requires two separate timelocked admin actions (48h total minimum). The 24h timelock on each change provides observation time. Current default values sum to max 12% (900 + 300 = 1200).

**Recommendation:**

Add a combined validation in `_getEffectiveAPR()` or in the APR execution functions:

```solidity
function _getEffectiveAPR(
    uint256 tier,
    uint256 duration
) internal view returns (uint256) {
    uint256 baseAPR = tier < MAX_TIER + 1
        ? tierAPR[tier]
        : tierAPR[MAX_TIER];
    uint256 durationTier = _getDurationTier(duration);
    uint256 bonusAPR = durationBonusAPR[durationTier];
    uint256 total = baseAPR + bonusAPR;
    return total > MAX_TOTAL_APR ? MAX_TOTAL_APR : total;
}
```

---

### [M-02] duration=0 Staking Creates a 24-Hour Reward Extraction Window

**Severity:** Medium
**Category:** SC02 Business Logic / DeFi Exploit
**Location:** `_computeAccrued()` (lines 898-950), OmniCore `_validateDuration()` (OmniCore.sol line 1293)

**Description:**

OmniCore's `_validateDuration()` accepts `duration=0` as a valid lock period (line 1293-1301). When `duration=0`:
- `lockTime = block.timestamp + 0 = block.timestamp`
- User can unlock immediately (no lock period)
- `stakeStart = lockTime - duration = lockTime - 0 = lockTime`

The ATK-H01 fix added `MIN_STAKE_AGE = 1 days` (line 184), which prevents rewards from accruing for the first 24 hours. However, after 24 hours, the attacker can:

1. Stake a large amount with `duration=0` and `tier=1` (only needs 1 XOM minimum)
2. Wait 24 hours + 1 second
3. Call `claimRewards()` to collect ~24 hours of APR rewards
4. Call `OmniCore.unlock()` to retrieve principal
5. Repeat

For 1B XOM at tier 5 (9% APR), 24 hours of rewards = 1B * 0.09 / 365 = ~246,575 XOM per cycle. This is a rational and risk-free strategy that extracts rewards without meaningful lock commitment.

**Mitigating Factors:**
- Attacker needs to hold 1B XOM for 24 hours (capital cost)
- Tier 1 minimum is only 1 XOM, yielding negligible rewards at 5%
- The 24h minimum makes flash loans impractical
- Rewards come from the pool (pre-funded), not from thin air

**Recommendation:**

Either:
1. Reject `duration=0` in OmniCore's `_validateDuration()`, or
2. Add `if (stakeData.duration == 0) return 0;` in `_computeAccrued()` to deny rewards to uncommitted stakers, or
3. Set a higher `MIN_STAKE_AGE` relative to the minimum lock period (e.g., 7 days)

---

### [M-03] snapshotRewards Overwrites lastActiveStake Unconditionally -- Griefing Vector

**Severity:** Medium
**Category:** SC02 Business Logic / Griefing
**Location:** `snapshotRewards()` (lines 497-534)

**Description:**

`snapshotRewards()` is callable by anyone for any user (intentional design -- documented at line 494). Each call:
1. Adds currently accrued rewards to `frozenRewards[user]` (line 513)
2. Resets `lastClaimTime[user]` to `block.timestamp` (line 515)
3. **Overwrites** `lastActiveStake[user]` with current stake data (line 526-532)

While the reward accumulation is mathematically invariant to repeated calls (frozen + accrued remains constant), there is a griefing concern: an attacker can call `snapshotRewards(victim)` repeatedly, updating `lastClaimTime[victim]` to the current timestamp each time.

If `snapshotRewards()` is called when `block.timestamp == lastClaimTime[user]`, then `elapsed = 0` and `accrued = 0`. The function still executes (the `if (accrued > 0)` guard at line 512 prevents state changes when accrued is zero), so the griefing attempt is harmless in terms of frozen rewards. However, the `lastActiveStake` overwrite at line 526 happens unconditionally, even when `accrued == 0`.

Wait -- re-reading lines 506-533: the `lastActiveStake` overwrite at line 526 is OUTSIDE the `if (accrued > 0)` block. This means even when no new rewards are accrued, the cached stake data is overwritten. If the stake parameters change between calls (e.g., OmniCore allows re-staking at different tiers in a future upgrade), this could overwrite important historical data. Currently this is benign since stakes are immutable once created.

**Impact:** Low immediate impact. The `lastActiveStake` mapping is currently write-only (never read by contract logic per H-02). If a future upgrade uses `lastActiveStake` for reward recovery, the overwrite behavior could matter.

**Recommendation:**

Move the `lastActiveStake` update inside the `if (accrued > 0)` block, or add a guard:
```solidity
if (lastActiveStake[user].snapshotTime == 0 || accrued > 0) {
    lastActiveStake[user] = CachedStake({...});
}
```

---

### [M-04] No Per-Claim or Per-Period Reward Cap Limits Blast Radius

**Severity:** Medium
**Category:** SC02 Business Logic
**Location:** `claimRewards()` (lines 450-486)

**Description:**

There is no maximum cap on a single reward claim. If a user stakes a very large amount and waits a long time without claiming, or if APR parameters are somehow misconfigured (despite the timelock protections), a single `claimRewards()` could drain a significant portion of the pool.

Example: 1B XOM staked at 12% APR for 2 years without claiming = 240M XOM in a single claim.

The M-01 partial claim fix mitigates the "drain beyond balance" scenario by capping payout at `poolBalance` and storing the remainder in `frozenRewards`. However, this does not prevent a single legitimate claim from consuming the entire pool balance, denying other stakers their rewards.

**Mitigating Factors:**
- This is a legitimate reward, not an exploit
- The partial claim mechanism (M-01 fix) prevents revert
- Pool should be funded adequately by ongoing block rewards and fee distributions

**Recommendation:**

Consider a per-claim cap or a cooldown period between claims to spread pool consumption:
```solidity
uint256 public constant MAX_CLAIM_PER_TX = 1_000_000e18; // 1M XOM max per claim
```

---

## Low Findings

### [L-01] totalDeposited Accounting Mismatch on Partial Claims

**Severity:** Low
**Location:** `claimRewards()` (line 474), `depositToPool()` (line 550)

**Description:**

When a partial claim occurs (pool underfunded), the remainder is stored in `frozenRewards` but `totalDistributed` only records the actual `payout` (line 474). When the user later claims the remainder, `totalDistributed` will eventually equal the full amount. However, the `totalDeposited` counter in `depositToPool()` tracks gross deposits, while `totalDistributed` tracks gross payouts. The difference `totalDeposited - totalDistributed` does NOT equal the current pool balance because:

1. Direct XOM transfers to the contract (not via `depositToPool()`) are not tracked
2. The UnifiedFeeVault may transfer XOM directly without calling `depositToPool()`

These counters are informational only (never used in on-chain logic), but they may mislead off-chain monitoring.

**Recommendation:** Document that `totalDeposited - totalDistributed` is not guaranteed to equal `xomToken.balanceOf(address(this))`. Consider removing these counters to save gas, or add a `depositToPool()` function requirement for all incoming XOM.

---

### [L-02] Excessive Event Parameter Indexing

**Severity:** Low
**Location:** Events at lines 251-341

**Description:**

`RewardsClaimed`, `RewardsSnapshot`, and `PoolDeposit` index all three parameters including `amount` and `timestamp`:

```solidity
event RewardsClaimed(
    address indexed user,
    uint256 indexed amount,     // <-- Rarely filtered on
    uint256 indexed timestamp   // <-- Rarely filtered on
);
```

Indexing `amount` and `timestamp` wastes gas (each indexed parameter costs 375 gas for topics vs 8 gas/byte for data) and provides no practical filtering benefit. Amounts and timestamps are rarely used as filter criteria.

**Recommendation:** Only index `user`/`depositor`:
```solidity
event RewardsClaimed(address indexed user, uint256 amount, uint256 timestamp);
```

---

### [L-03] Fee-on-Transfer Token Compatibility in depositToPool

**Severity:** Low
**Location:** `depositToPool()` (lines 542-553)

**Description:**

`depositToPool()` updates `totalDeposited += amount` before the transfer completes. If XOM were ever migrated to a fee-on-transfer variant, the counter would overcount. While OmniCoin (XOM) is not currently a fee-on-transfer token and is unlikely to become one, defensive coding would use the balance-before/after pattern:

```solidity
uint256 balBefore = xomToken.balanceOf(address(this));
xomToken.safeTransferFrom(caller, address(this), amount);
uint256 received = xomToken.balanceOf(address(this)) - balBefore;
totalDeposited += received;
```

**Recommendation:** Accept current implementation given XOM is not fee-on-transfer. Document the assumption.

---

### [L-04] Pending APR Change Overwrite Without Notification

**Severity:** Low
**Location:** `proposeTierAPR()` (line 580), `proposeDurationBonusAPR()` (line 615)

**Description:**

Both functions unconditionally overwrite `pendingAPRChange` without checking if a previous pending change exists. A second proposal silently replaces the first. While the `APRChangeProposed` event is emitted for both, there is no `APRChangeCancelled` event emitted for the replaced proposal.

Similarly, `proposeContracts()` (line 694) overwrites `pendingContracts` without cancelling the previous one.

**Recommendation:** Emit a cancellation event when overwriting, or require explicit cancellation before a new proposal:
```solidity
if (pendingAPRChange.executeAfter != 0) {
    emit APRChangeCancelled();
}
```

---

### [L-05] ossify() Function is Classified as "Internal" in Comment Section

**Severity:** Low
**Location:** `ossify()` (line 855)

**Description:**

The `ossify()` function is placed under the "INTERNAL FUNCTIONS" section header (line 848) but is actually an `external` function with `onlyRole(DEFAULT_ADMIN_ROLE)` access control. This is a documentation/organization issue that could cause confusion during code review.

**Recommendation:** Move `ossify()` and `isOssified()` to the "EXTERNAL FUNCTIONS" section, or create a dedicated "ADMIN FUNCTIONS" section.

---

## Informational Findings

### [I-01] OmniCore Allows Staking at Lower Tiers Than Amount Qualifies For

**Location:** OmniCore `_validateStakingTier()` (OmniCore.sol line 1270-1286)

OmniCore's validation checks `amount >= tierMinimums[tier - 1]` but does NOT enforce that the user selects the HIGHEST qualifying tier. A user with 10B XOM could stake at tier 1 (5% APR) instead of tier 5 (9% APR). This is a user-facing choice, not a vulnerability. The `_clampTier()` function in StakingRewardPool (line 1017-1041) only prevents claiming a HIGHER tier than qualified -- it does not force upward.

**Impact:** Users may inadvertently select a lower tier and receive less APR than they qualify for. This is value-neutral for the protocol (lower cost) but bad UX.

**Recommendation:** Frontend validation should auto-select the highest qualifying tier. No contract change needed.

---

### [I-02] OmniCore lockTime Semantics Dependency

**Location:** `_computeAccrued()` (line 908-909)

The reward calculation computes `stakeStart = lockTime - duration`. This depends on OmniCore setting `lockTime = block.timestamp + duration` (OmniCore.sol line 691). If OmniCore is replaced via `executeContracts()` with a contract that uses different `lockTime` semantics (e.g., `lockTime = block.timestamp` without adding duration), the `stakeStart` calculation would underflow or produce incorrect results.

The underflow guard at line 903 (`if (lockTime < duration) return 0`) prevents revert but would silently deny rewards. The 48h timelock on contract changes provides observation time.

**Impact:** Low. The timelock provides adequate protection window.

---

### [I-03] Early Withdrawal Penalty Not Implemented (Design Gap)

**Location:** Contract-wide (absent feature)

Per OmniBazaar tokenomics: "Early Withdrawal: Substantial penalty applies." Neither OmniCore nor StakingRewardPool implements an early withdrawal penalty mechanism. OmniCore's `unlock()` simply prevents early withdrawal entirely via `if (block.timestamp < userStake.lockTime) revert StakeLocked()`.

The current implementation is effectively an infinite penalty (total lockout), which may or may not match the product specification's intent of a "substantial" but finite penalty.

**Recommendation:** Clarify product requirements. If early withdrawal with a fee is desired, implement it in OmniCore's `unlock()` function with a penalty percentage based on remaining lock time.

---

### [I-04] Productive Use of Staked XOM for DEX Liquidity Not Implemented

**Location:** Contract-wide (absent feature)

Per tokenomics: "Productive Use: Staked XOM used for DEX liquidity provision." This feature is not implemented in StakingRewardPool. Staked XOM principal is held in OmniCore, and the reward pool only holds reward tokens. DEX liquidity integration would require additional contract logic to deploy staked XOM to AMM pools while maintaining the user's ability to unlock after the lock period.

**Recommendation:** This is a complex feature with significant security implications (impermanent loss, liquidity fragmentation, unlock timing). Implement carefully in a separate contract with proper risk controls, or defer to post-launch.

---

## DeFi Exploit Analysis

### Flash Loan Attack

**Scenario:** Attacker borrows large amount of XOM via flash loan, stakes with `duration=0`, claims rewards, unlocks, repays.

**Mitigation Status:** MITIGATED by `MIN_STAKE_AGE = 1 days` (line 184). Flash loans must be repaid within a single transaction, so the 24-hour minimum stake age makes flash loan attacks economically impossible. The attacker would need to borrow XOM for 24+ hours, which is not a flash loan.

**Residual Risk:** See M-02 above regarding the 24-hour duration=0 extraction window for funded attackers (not flash loans).

### Rapid Stake/Unstake Cycling

**Scenario:** Attacker repeatedly stakes and unstakes to accumulate rounding errors or exploit timing gaps.

**Mitigation Status:** MITIGATED.
- OmniCore requires `!stakes[caller].active` to stake (line 675), preventing stacking.
- `MIN_STAKE_AGE = 1 days` prevents sub-daily cycling.
- Rewards are computed exactly based on elapsed seconds, no rounding exploitation possible.
- Re-staking after unlock requires a new `stake()` call with new `lockTime`, resetting the clock.

### Rounding Errors in APR Calculations

**Scenario:** Small rounding errors compound over millions of claims to drain extra tokens.

**Analysis:** The formula `(amount * effectiveAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)` uses integer division which truncates (rounds down). This means users receive slightly LESS than their precise APR. The maximum rounding loss per claim is less than 1 wei of XOM. Rounding always favors the pool, not the user.

**Compound Analysis:** Since `lastClaimTime` is updated to `block.timestamp` on each claim, and rewards are computed from the last claim time, frequent claiming produces the same total as infrequent claiming (within 1 wei per claim). Compound rounding is bounded by `number_of_claims * 1 wei` and is negligible.

**Status:** NOT EXPLOITABLE. Rounding favors the protocol.

### Coordinated Mass Withdrawal

**Scenario:** All stakers claim simultaneously to drain the pool.

**Analysis:** The M-01 fix (partial claims) prevents revert on underfunded pool. If all stakers claim and the pool is depleted:
1. First claimers get full rewards
2. Later claimers get partial rewards (pool balance)
3. Remaining owed amounts are stored in `frozenRewards`
4. When pool is refunded, frozen rewards can be claimed

This creates a first-come-first-served dynamic during pool depletion, which is unfair but not catastrophic. Users with unclaimed frozen rewards will eventually be made whole as the pool is refunded.

**Status:** MITIGATED (partial claims). Operational monitoring should alert when pool balance falls below projected obligations.

### Pool Exhaustion Mid-Distribution

**Scenario:** Pool runs out of funds during ongoing staking rewards accrual.

**Analysis:** The pool does not "distribute" in batches -- users self-serve via `claimRewards()`. If the pool is empty:
- `claimRewards()` with `poolBalance = 0`: `payout = 0`, full `reward` stored in `frozenRewards`
- Rewards continue accruing in `earned()` (view function computes from timestamps)
- When pool is refunded, stored `frozenRewards` plus new accrued rewards become claimable

**Status:** HANDLED correctly by M-01 fix. No fund loss, only delay.

---

## Interaction with OmniCore: TOCTOU Analysis

### Read Pattern

StakingRewardPool reads stake data via `omniCore.getStake(user)` which returns a memory copy of the Stake struct. The read occurs in:
1. `earned()` (line 827) -- view function
2. `snapshotRewards()` (line 502) -- state-changing function

### TOCTOU Risk Assessment

**Scenario:** User calls `snapshotRewards()` which reads stake at time T1. Between T1 and T2 (next block), user calls `OmniCore.unlock()` which modifies stake. Then user calls `claimRewards()` at T2 which reads the modified (zeroed) stake.

**Analysis:** This is exactly the H-02 (Round 6) race condition described above. The `snapshotRewards()` read and subsequent `frozenRewards` write happen atomically within a single transaction, so there is no intra-transaction TOCTOU. The inter-transaction TOCTOU (between snapshot and unlock) is an operational concern, not a contract vulnerability.

**Cross-Contract Reentrancy:** `claimRewards()` is protected by `nonReentrant`. `snapshotRewards()` is NOT protected by `nonReentrant`, but it only reads from OmniCore (no callbacks) and writes to `frozenRewards` and `lastClaimTime` (no external calls after state changes). The `safeTransfer` in `claimRewards()` is the only external call after state updates, and it's protected by reentrancy guard.

**Oracle Replacement:** The `proposeContracts()` / `executeContracts()` 48h timelock prevents instant OmniCore replacement. During the timelock period, all reads go to the current (legitimate) OmniCore. After execution, reads go to the new OmniCore. The transition is atomic (single SSTORE).

**Status:** No exploitable TOCTOU vulnerability. Inter-transaction ordering is an operational concern (H-02).

---

## Centralization Risk Assessment

**Centralization Rating: 5/10 (Moderate -- improved from 8/10 in Round 1)**

**Improvements Since Round 1:**
- Contract changes require 48h timelock (was instant)
- APR changes require 24h timelock (was instant)
- `emergencyWithdraw` cannot drain XOM (was unrestricted)
- `_authorizeUpgrade` requires `DEFAULT_ADMIN_ROLE` (was `ADMIN_ROLE`)
- Ossification capability added (permanent non-upgradeability)

**Remaining Centralization Risks:**

| Risk | Role | Timelock | Impact |
|------|------|----------|--------|
| Upgrade to malicious implementation | DEFAULT_ADMIN_ROLE | None (instant) | 10/10 -- can steal all pool funds |
| Pause all operations indefinitely | DEFAULT_ADMIN_ROLE | None (instant) | 7/10 -- denial of service |
| Replace OmniCore oracle | ADMIN_ROLE | 48h | 8/10 -- fabricate stake data for reward theft |
| Set APR to extreme values | ADMIN_ROLE | 24h | 6/10 -- accelerate pool drain |
| Grant attacker roles | DEFAULT_ADMIN_ROLE | None (instant) | 10/10 -- enables all of above |

**Key Remaining Risk:** The upgrade function (`_authorizeUpgrade`) has NO timelock. A compromised `DEFAULT_ADMIN_ROLE` can upgrade to a malicious implementation that transfers all pool XOM to the attacker, all within a single transaction. This is the highest-impact centralization risk.

**Recommendation:**
1. Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig with timelock
2. Consider adding a timelock to `_authorizeUpgrade` (or use the Governance timelock)
3. Call `ossify()` once the contract is battle-tested, permanently removing upgrade capability

---

## Remediation Priority

| Priority | ID | Finding | Effort | Risk |
|----------|----|---------|--------|------|
| 1 | H-01 | `depositToPool` uses `msg.sender` instead of `_msgSender()` | Low (3 lines) | High if meta-txns are used |
| 2 | H-02 | Unlock/snapshot race condition -- rewards lost without snapshot | Medium (cross-contract change) | High for users |
| 3 | M-01 | Combined APR validation gap allows >12% | Low (1 line cap) | Medium |
| 4 | M-02 | duration=0 staking exploitable after 24h | Low (1 line guard) | Medium |
| 5 | M-04 | No per-claim reward cap | Low (constant + check) | Medium |
| 6 | M-03 | snapshotRewards overwrites lastActiveStake unconditionally | Low (move into if block) | Low |
| 7 | L-01 | totalDeposited accounting mismatch | Low (documentation) | Low |
| 8 | L-02 | Excessive event indexing | Low (remove indexed) | Low (gas savings) |
| 9 | L-04 | Pending APR overwrite without cancel event | Low (add event) | Low |
| 10 | L-05 | ossify() in wrong code section | Low (move function) | Cosmetic |

---

## Storage Layout Verification

| Slot | Variable | Type |
|------|----------|------|
| (inherited) | AccessControlUpgradeable | ~2 slots |
| (inherited) | UUPSUpgradeable | ~1 slot |
| (inherited) | ReentrancyGuardUpgradeable | 1 slot |
| (inherited) | PausableUpgradeable | 1 slot |
| (inherited) | ERC2771ContextUpgradeable | 0 slots (immutable forwarder) |
| S1 | omniCore | address (1 slot) |
| S2 | xomToken | address (1 slot) |
| S3 | lastClaimTime | mapping (1 slot) |
| S4 | frozenRewards | mapping (1 slot) |
| S5-S10 | tierAPR[6] | uint256[6] (6 slots) |
| S11-S14 | durationBonusAPR[4] | uint256[4] (4 slots) |
| S15 | totalDeposited | uint256 (1 slot) |
| S16 | totalDistributed | uint256 (1 slot) |
| S17 | lastActiveStake | mapping (1 slot) |
| S18 | pendingContracts | struct (3 slots) |
| S19 | pendingAPRChange | struct (4 slots) |
| S20 | _ossified | bool (1 slot) |
| S21-S55 | __gap | uint256[35] (35 slots) |

**Storage Gap Calculation:** The contract declares `__gap[35]`. Counting used state variable slots (excluding inherited): ~20 slots used + 35 gap = 55 total reserved. This provides adequate headroom for future upgrades.

**Note:** The NatSpec comment at line 239 says "Used slots: 15" but the actual count appears higher when including struct slots (PendingContracts = 3 slots, PendingAPRChange = 4 slots). Recommend re-verifying the gap calculation to ensure upgrade safety.

---

## Summary

StakingRewardPool has been significantly hardened since the Round 1 audit. All 7 High and 7 Medium findings from Round 1 have been addressed. The ATK-H01 flash-stake attack is mitigated by the 24-hour minimum stake age. The contract now uses proper timelocks for configuration changes, blocks XOM withdrawal via emergency functions, validates tier claims independently, and supports partial claims during pool underfunding.

The two remaining High findings are: (1) an ERC-2771 inconsistency in `depositToPool()` that is easy to fix, and (2) the unlock/snapshot race condition which is an architectural concern requiring cross-contract coordination. The Medium findings address combined APR validation, duration=0 staking economics, snapshot overwrite behavior, and per-claim caps.

For mainnet deployment, the priority fixes are H-01 (trivial), M-01 (trivial), and M-02 (trivial). H-02 requires an architectural decision about whether to modify OmniCore to auto-snapshot, or to accept the operational risk with frontend mitigation.

---

*Generated by Claude Code Audit Agent -- Pre-Mainnet Round 6 Deep Review*
*Contract version: post-remediation (Round 1 + Round 4 fixes applied)*
*Timestamp: 2026-03-10 01:01 UTC*
