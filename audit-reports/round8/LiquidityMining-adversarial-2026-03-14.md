# LiquidityMining.sol -- Adversarial Security Review (Round 8)

**Date:** 2026-03-14
**Reviewer:** Adversarial Agent A3
**Contract:** `Coin/contracts/liquidity/LiquidityMining.sol` (1,254 lines)
**Methodology:** Concrete exploit construction across 7 categories
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10), Round 7 (2026-03-13)
**Cross-Referenced:** OmniCoin.sol (ERC20 reward token), OmniCore.sol (protocol core), vulnerability-patterns.md (VP-01 through VP-58)

---

## Executive Summary

This adversarial review attempted to construct concrete, step-by-step exploit scenarios against LiquidityMining.sol across seven pre-identified attack surfaces. The contract has been through four prior audit rounds and is substantially hardened. After detailed line-by-line analysis, I identify **one viable medium-severity exploit** (emergency withdrawal as a flash-stake escape hatch bypassing `MIN_STAKE_DURATION`), **one low-severity finding** (totalCommittedRewards drift in the vesting append path combined with vesting period reduction creating a claimable surplus), and **one informational observation** (front-running window on `setRewardRate` is theoretical but unprofitable in practice). The remaining four attack categories are properly defended.

Notably, the Round 7 M-01 finding (re-staking resets `MIN_STAKE_DURATION` timer) has already been remediated in the current code at line 557: `if (user.amount == 0)` guards the timestamp update. The Round 7 report appears to have been written against an older revision.

---

## Viable Exploits

| # | Attack Name | Severity | Attacker Profile | Confidence | Impact |
|---|-------------|----------|------------------|------------|--------|
| 1 | emergencyWithdraw Bypasses MIN_STAKE_DURATION (Flash-Stake Escape Hatch) | Medium | Any user (flash-loan capable) | HIGH | Flash-stake reward extraction via emergency exit; 0.5% LP penalty but keeps 30% of accrued immediate rewards if pool has no vesting |
| 2 | totalCommittedRewards Conservative Drift + Vesting Period Reduction = Locked Dust | Low | Any staker (long-term, many harvests) | MEDIUM | Small amount of XOM permanently locked in contract; owner cannot withdraw it |
| 3 | setRewardRate Front-Running Window (Theoretical) | Informational | MEV searcher | LOW | Marginal excess reward capture; unprofitable in practice on Avalanche |

---

### 1. emergencyWithdraw Bypasses MIN_STAKE_DURATION (Flash-Stake Escape Hatch)

**Severity:** Medium
**Confidence:** HIGH
**Attacker Profile:** Any user, potentially using a flash loan for LP tokens
**VP Reference:** VP-52 (Flash Loan Governance Attack -- adapted pattern), VP-34 (Front-Running)

#### Background

The `MIN_STAKE_DURATION = 1 days` check was added in Round 6 H-01 to prevent flash-stake reward extraction. It is enforced in `withdraw()` at lines 596-602:

```solidity
if (block.timestamp < stakeTimestamp[poolId][caller] + MIN_STAKE_DURATION) {
    revert MinStakeDurationNotMet();
}
```

However, `emergencyWithdraw()` (line 736) has **no** `MIN_STAKE_DURATION` check. By design, it is available even when paused to ensure users can always recover LP tokens. The documentation states users "forfeit ALL pending and vesting rewards" in exchange.

#### The Problem

The forfeiture is not complete. The `emergencyWithdraw()` function does NOT call `_updatePool()` (as noted in the NatSpec at line 731: "Does not call _updatePool() -- the stale accumulator has no effect since all reward state is zeroed"). This means the pool's `accRewardPerShare` is NOT updated to include time since `lastRewardTime`. The user's reward state at the time of `emergencyWithdraw()` reflects only rewards accumulated up to the **last** `_updatePool()` call by any user.

However, this is only a partial defense. Consider the following exploit:

#### Step-by-Step Exploit Scenario

**Preconditions:**
- Pool 0 exists with `rewardPerSecond = R`, `immediateBps = 10000` (100% immediate, no vesting -- or any high immediateBps)
- Pool 0 has `totalStaked = T` (some existing stakers)
- Attacker can borrow `L` LP tokens via flash loan (or has their own)

**Step 1 -- Stake (Block N):**
Attacker calls `stake(0, L)`. This:
1. Calls `_updatePool(0)` -- updates `accRewardPerShare` to current timestamp
2. Since `user.amount == 0`, sets `stakeTimestamp[0][attacker] = block.timestamp`
3. Sets `user.amount = L`, `user.rewardDebt = (L * accRewardPerShare) / REWARD_PRECISION`

At this point, the attacker has zero pending rewards (debt equals accumulated).

**Step 2 -- Wait for another user interaction (any time later, same block possible):**
Any other user calling `stake()`, `withdraw()`, or `claim()` on pool 0 triggers `_updatePool(0)`, which advances `accRewardPerShare`. Alternatively, the attacker waits for 1+ seconds for time to elapse.

Actually, the attacker does NOT even need another user. They can call `claim(0)` themselves. `claim()` calls `_updatePool(0)` and then `_harvestRewards(0, caller)`. If any time has elapsed since the stake, this harvests rewards proportional to the attacker's share. Then `claim()` transfers the `pendingImmediate` to the attacker.

**Step 3 -- Claim (Block N+1 or later, at least 1 second elapsed):**
Attacker calls `claim(0)`. This:
1. `_updatePool(0)` advances `accRewardPerShare` by `elapsed * R / totalStaked`
2. `_harvestRewards()` calculates: `pending = (L * accRewardPerShare) / REWARD_PRECISION - rewardDebt`
3. With `immediateBps = 10000`: `immediateReward = pending`, `vestingReward = 0`
4. `user.pendingImmediate += immediateReward`
5. `totalCommittedRewards += immediateReward`
6. Attacker receives `immediateReward` XOM tokens

**Step 4 -- emergencyWithdraw (same block as Step 3):**
Attacker calls `emergencyWithdraw(0)`. This:
1. NO `MIN_STAKE_DURATION` check -- proceeds immediately
2. `forfeited = user.pendingImmediate + user.vestingTotal - user.vestingClaimed = 0 + 0 - 0 = 0` (already claimed in Step 3)
3. `fee = (L * emergencyWithdrawFeeBps) / BASIS_POINTS = L * 50 / 10000 = 0.5% of L`
4. Attacker receives `L - fee` LP tokens back
5. Fee (0.5% of LP) goes to protocolTreasury/stakingPool

**Step 5 -- Repay flash loan:**
Attacker repays `L` LP tokens. Net cost: `fee = 0.5% of L` in LP tokens. Net gain: `immediateReward` in XOM.

#### Profitability Analysis

For the attack to be profitable: `immediateReward > fee_in_XOM_terms`

With `immediateBps = 10000` (100% immediate):
- `immediateReward = elapsed * R * L / (T + L)` (for 1 second elapsed: `R * L / (T + L)`)
- `fee = 0.005 * L` in LP tokens

With default `immediateBps = 3000` (30% immediate):
- `immediateReward = 0.3 * elapsed * R * L / (T + L)`
- 70% goes to vesting, which is forfeited in `emergencyWithdraw`

The attack is most profitable when:
1. `immediateBps` is high (ideally 10000)
2. `R` (rewardPerSecond) is high relative to `T` (totalStaked)
3. `L` is very large (flash loan maximizes this)
4. `emergencyWithdrawFeeBps` is low (currently 50 = 0.5%)

**Concrete numbers example:**
- `R = 1e18` (1 XOM/second)
- `T = 1000e18` (1000 LP tokens staked)
- `L = 100000e18` (100K LP tokens, flash loaned)
- `immediateBps = 10000` (100% immediate)
- `elapsed = 2` seconds (1 block on Avalanche)

Reward: `2 * 1e18 * 100000e18 / (1000e18 + 100000e18) = 2 * 100000 / 101000 * 1e18 = ~1.98e18 XOM`
Fee: `100000e18 * 50 / 10000 = 500e18` LP tokens

If XOM and LP tokens are roughly equal value, the attacker loses 500 LP and gains ~2 XOM. This is unprofitable.

However, if the pool has been running with low stakers for a while and the attacker uses Step 2-3 to claim rewards accumulated over multiple seconds/blocks before anyone else interacts, OR if `rewardPerSecond` is very high, the economics shift.

**The real danger** is when `immediateBps = 10000` AND the attacker executes steps 1-4 across 2 blocks (not same block). The attacker performs: stake in block N, claim in block N+1 (capturing ~1 second of rewards as sole/major staker), and emergencyWithdraw in block N+1 (same tx as claim, or next tx in same block). The `MIN_STAKE_DURATION` that was designed to prevent this is completely bypassed.

#### Key Insight: `claim()` Followed by `emergencyWithdraw()` Nullifies Forfeiture

The critical observation is that `emergencyWithdraw()` forfeits `pendingImmediate + vestingTotal - vestingClaimed`. But if the attacker calls `claim()` first, `pendingImmediate` is zeroed, `vestingClaimed` catches up to the claimable vested portion, and the forfeiture is only the unvested portion. For 100% immediate pools, the forfeiture is zero after claiming.

#### Existing Defenses

- `emergencyWithdrawFeeBps = 50` (0.5% LP penalty) makes the attack unprofitable for small rewards
- Default `immediateBps = 3000` means 70% of rewards vest over 90 days, making forfeiture significant
- The attack requires the LP token to be available for flash loans
- Avalanche block times (~2s) limit the reward window per block

#### Why This is Viable Despite Defenses

If an admin creates a pool with `immediateBps = 10000` (a valid configuration), or even `immediateBps = 7000-10000`, the flash-stake-claim-emergencyWithdraw loop completely circumvents the `MIN_STAKE_DURATION` protection. The 0.5% LP fee is the only deterrent. For pools with high reward rates relative to staked value, this can be profitable.

#### Recommendation

**Priority A (code fix):** Add `MIN_STAKE_DURATION` enforcement to `emergencyWithdraw()`:

```solidity
function emergencyWithdraw(uint256 poolId) external nonReentrant {
    if (poolId >= pools.length) revert PoolNotFound();
    address caller = _msgSender();
    PoolInfo storage pool = pools[poolId];
    UserStake storage user = userStakes[poolId][caller];
    uint256 amount = user.amount;
    if (amount == 0) revert InsufficientStake();

    // Enforce MIN_STAKE_DURATION even for emergency withdrawals
    // to prevent flash-stake-claim-emergencyWithdraw loops
    if (block.timestamp < stakeTimestamp[poolId][caller] + MIN_STAKE_DURATION) {
        revert MinStakeDurationNotMet();
    }

    // ... rest of function
}
```

**Counterargument:** This may conflict with the design goal of "users can always recover LP tokens." However, the design goal was about paused-state recovery, not flash-stake protection. A compromise is to apply the check only when `!paused()`:

```solidity
if (!paused() && block.timestamp < stakeTimestamp[poolId][caller] + MIN_STAKE_DURATION) {
    revert MinStakeDurationNotMet();
}
```

This preserves emergency access when paused but prevents flash-stake exploitation during normal operation.

**Priority B (mitigation):** Ensure no pool is created with `immediateBps` close to 10000. The default 3000 provides natural protection since 70% of rewards are forfeited on emergency withdrawal. Consider a `MAX_IMMEDIATE_BPS` constant (e.g., 5000) enforced in `addPool()` and `setVestingParams()`.

---

### 2. totalCommittedRewards Conservative Drift + Vesting Period Reduction = Locked Dust

**Severity:** Low
**Confidence:** MEDIUM
**Attacker Profile:** Not an attack -- an accumulation of rounding errors over time
**VP Reference:** VP-13 (Precision Loss), VP-15 (Rounding Exploitation)

#### Analysis

The NatSpec at lines 171-181 documents that `totalCommittedRewards` may drift slightly above reality due to rounding in the vesting append path. Let me trace exactly how.

**Source of drift -- vesting append path (lines 1094-1108):**

When a harvest appends to an existing vesting schedule:
1. `instantlyVested = (vestingReward * alreadyElapsed) / pool.vestingPeriod` -- truncates DOWN
2. `pendingImmediate += instantlyVested` -- user gets slightly less instant vesting
3. `vestingTotal += vestingReward - instantlyVested` -- slightly more goes to vestingTotal
4. But `totalCommittedRewards += immediateReward + vestingReward` (line 1070) -- commits the full amount

The full `vestingReward` is committed, but `instantlyVested` is rounded down, so `vestingReward - instantlyVested` is rounded up. When `_calculateVested` later computes the claimable amount from `vestingTotal`, it performs `(vestingTotal * elapsed) / vestingPeriod`, which also truncates down. The net effect: a tiny surplus in `totalCommittedRewards` relative to what users can actually claim.

**Quantifying the drift:**

Each append operation introduces at most 1 wei of drift. With:
- 50 pools
- 1000 active stakers per pool
- Daily harvests for each staker
- 40-year contract lifetime

Maximum drift: `50 * 1000 * 365 * 40 = 730,000,000` append operations = ~730M wei = ~7.3e-10 XOM. This is negligible in value.

**Interaction with vesting period reduction:**

However, there is an additional edge case. If the admin calls `setVestingParams()` to REDUCE the vesting period for a pool, users with existing vesting schedules benefit: their `_calculateVested` returns more (shorter period means faster vesting). But `totalCommittedRewards` was calculated at the OLD vesting period. The old committed amount is still correct -- users were always entitled to the full `vestingTotal` -- just the timing changed.

Conversely, if the admin INCREASES the vesting period, `_calculateVested` returns less for the same elapsed time, and users must wait longer. The committed amount stays the same. This can create a situation where `totalCommittedRewards` is accurate but the timing of withdrawability shifts.

**Impact:** The drift is always in the safe (over-committing) direction. The locked dust is inaccessible to the owner via `withdrawRewards()` since that function only allows withdrawal of XOM above `totalCommittedRewards`. The dust is also inaccessible to users (they cannot claim more than their actual entitlement).

**Verdict:** Accepted risk. The drift is negligible and cannot be exploited.

#### Recommendation

No code change needed. The existing NatSpec documentation is accurate and sufficient. For operational monitoring, the `CommittedRewardsDrift` event provides observability if drift exceeds expectations.

---

### 3. setRewardRate Front-Running Window (Theoretical)

**Severity:** Informational
**Confidence:** LOW
**Attacker Profile:** MEV searcher monitoring owner transactions
**VP Reference:** VP-34 (Front-Running / Transaction Ordering Dependence)

#### Analysis

When the owner calls `setRewardRate(poolId, newRate)`:
1. `_updatePool(poolId)` settles pending rewards at the OLD rate
2. `pools[poolId].rewardPerSecond = newRewardPerSecond` applies the new rate

A front-running scenario:
1. Owner submits `setRewardRate(0, 2 * currentRate)` to mempool
2. MEV searcher sees the pending tx and front-runs with a large `stake(0, L)` tx
3. Owner's `setRewardRate` executes -- rate doubles
4. Searcher now earns rewards at the doubled rate with their large stake
5. After `MIN_STAKE_DURATION`, searcher withdraws

The reverse is also possible: if the owner is reducing the rate, a searcher might front-run with a `claim()` to collect rewards at the old (higher) rate before the reduction.

#### Why This is Not Viable in Practice

1. **MIN_STAKE_DURATION = 1 day:** The searcher must commit LP tokens for 24 hours minimum. During this time, other stakers can also adjust their positions, diluting the advantage.

2. **Avalanche C-Chain has limited MEV:** Avalanche's consensus model provides faster finality (~1-2s) and the mempool visibility window is much shorter than Ethereum. Avalanche does not have a public builder/searcher ecosystem comparable to Ethereum's.

3. **Owner can use private transactions:** The owner (presumably a multisig) can submit rate changes via a private RPC endpoint or directly to a validator, bypassing the public mempool.

4. **`MIN_UPDATE_INTERVAL` is declared but not enforced:** The constant `MIN_UPDATE_INTERVAL = 1 days` exists (line 119) but is never checked in `setRewardRate()`. If it were enforced, it would not help against front-running anyway -- the issue is about transaction ordering within the same block, not rate update frequency.

5. **The claim front-run scenario** (claiming at old rate before reduction) is a non-issue because `_updatePool()` is called INSIDE `setRewardRate()`, settling all pending rewards at the old rate before applying the new rate. A user calling `claim()` in the same block as the rate change gets the same settled amount regardless of transaction ordering.

#### Recommendation

No code change needed. The `MIN_UPDATE_INTERVAL` constant could be enforced for defense-in-depth, but the attack is unprofitable on Avalanche. Document that admin rate changes should use private transactions when possible.

---

## Investigated-but-Defended Categories

### 4. Emergency Withdrawal Penalty Manipulation

**Category:** Can the 0.5% penalty be avoided or minimized?
**Verdict:** DEFENDED (with caveat from Finding #1)

#### Analysis

The `emergencyWithdrawFeeBps` is set to 50 (0.5%) in the constructor and can be adjusted by the owner up to 1000 (10%) via `setEmergencyWithdrawFee()` (line 824). The fee calculation at line 767:

```solidity
uint256 fee = (amount * emergencyWithdrawFeeBps) / BASIS_POINTS;
```

**Can the fee be avoided?**

1. **Withdraw instead of emergencyWithdraw:** If the user has passed `MIN_STAKE_DURATION`, they can use `withdraw()` which has no fee. The emergency fee only applies to the no-questions-asked emergency path.

2. **Admin reduces fee to 0:** The owner can set `emergencyWithdrawFeeBps = 0`, which makes the fee zero. This is a feature, not a bug -- the admin controls this parameter. The max is capped at 1000 (10%) to protect users.

3. **Rounding to zero:** For very small stake amounts, `(amount * 50) / 10000` could round to zero. Specifically, for `amount < 200`, the fee rounds to 0. This means staking amounts less than 200 wei effectively have no emergency fee. However, such amounts are economically meaningless.

4. **Front-running admin fee increases:** If the admin increases the fee, a user could front-run with `emergencyWithdraw()` at the old (lower) fee. This is a standard admin-change front-running scenario and is mitigated by the owner using private transactions.

**Penalty manipulation via `claim()` + `emergencyWithdraw()` combination:** This is the finding from #1 above. The penalty is on LP tokens, but the rewards forfeiture can be minimized by claiming first.

#### Defense Assessment

The LP token penalty itself cannot be avoided (assuming `emergencyWithdrawFeeBps > 0` and `amount >= 200`). The reward forfeiture, however, can be minimized as described in Finding #1. The 70/20/10 fee split is correctly implemented.

---

### 5. Reward Calculation Overflow

**Category:** Can extreme amounts or durations overflow the reward math?
**Verdict:** DEFENDED
**VP Reference:** VP-12 (Integer Overflow/Underflow)

#### Analysis

Solidity 0.8.24 has built-in overflow protection. All arithmetic reverts on overflow. The question is whether any combination of inputs can trigger a revert that traps user funds.

**Critical multiplication paths:**

1. **`_updatePool` (line 1042):**
   ```solidity
   pool.accRewardPerShare += (reward * REWARD_PRECISION) / pool.totalStaked;
   ```
   - `reward = elapsed * pool.rewardPerSecond`
   - Max `elapsed`: ~40 years = ~1.26e9 seconds (if no one interacts)
   - Max `pool.rewardPerSecond`: `MAX_REWARD_PER_SECOND = 1e24`
   - Max `reward`: `1.26e9 * 1e24 = 1.26e33`
   - `reward * REWARD_PRECISION`: `1.26e33 * 1e18 = 1.26e51`
   - `uint256` max: `~1.16e77`
   - **No overflow.** The intermediate value `1.26e51` is well within `uint256` range.

2. **`_calculatePendingRewards` (line 1151):**
   ```solidity
   uint256 pending = (userStakeInfo.amount * accRewardPerShare) / REWARD_PRECISION - userStakeInfo.rewardDebt;
   ```
   - Max `userStakeInfo.amount`: Bounded by LP token total supply. Even `1e30` (extreme)
   - Max `accRewardPerShare`: After 40 years with min staking: `1.26e33 * 1e18 / 1 = 1.26e51` (1 wei staked)
   - `amount * accRewardPerShare`: `1e30 * 1.26e51 = 1.26e81` -- **EXCEEDS uint256 max!**

   However, this scenario requires exactly 1 wei to be staked for 40 years while `rewardPerSecond = 1e24`. This is extremely unrealistic. With even 1 full LP token staked (`1e18`), `accRewardPerShare` would be `1.26e51 / 1e18 = 1.26e33`, and `1e30 * 1.26e33 = 1.26e63`, which is safe.

   The realistic upper bound with `MAX_REWARD_PER_SECOND = 1e24`, `totalStaked >= 1e18`, and `amount <= 1e27` (1 billion LP tokens):
   - `accRewardPerShare` <= `1.26e33 * 1e18 / 1e18 = 1.26e33` (40 years, 1 LP staked)
   - Realistically, `accRewardPerShare` <= `1.26e33` (pool runs for 40 years with minimal stake)
   - `amount * accRewardPerShare` <= `1e27 * 1.26e33 = 1.26e60` -- safe

3. **`estimateAPR` (line 991):**
   ```solidity
   uint256 annualRewards = pool.rewardPerSecond * 365 days;
   ```
   - `1e24 * 31536000 = 3.15e31` -- safe

4. **`emergencyWithdraw` fee calculation (line 767):**
   ```solidity
   uint256 fee = (amount * emergencyWithdrawFeeBps) / BASIS_POINTS;
   ```
   - Max `amount * 1000 / 10000` -- safe for any uint256 amount under `type(uint256).max / 1000`

**Edge case: `accRewardPerShare` growing without bound:**

If `totalStaked` is very small (e.g., 1 wei) and `rewardPerSecond` is high, `accRewardPerShare` grows rapidly. Over time, this could cause overflow in `_calculatePendingRewards`. However:
- With 1 wei staked and `rewardPerSecond = 1e24`, after 40 years: `accRewardPerShare = 1.26e9 * 1e24 * 1e18 / 1 = 1.26e51`
- `1 * 1.26e51 / 1e18 = 1.26e33` pending rewards -- safe
- The overflow only occurs if a user with a very large stake enters a pool where `accRewardPerShare` is already enormous, which is self-correcting: their entry increases `totalStaked`, slowing further accumulation.

#### Defense Assessment

No overflow is possible under realistic conditions. The `MAX_REWARD_PER_SECOND` cap and Solidity 0.8.24's built-in overflow checks provide adequate protection. The theoretical overflow in `_calculatePendingRewards` requires a combination of extreme values (1 wei totalStaked for decades combined with massive new stakes) that is not achievable in practice.

---

### 6. Flash-Stake Protection

**Category:** Is `MIN_STAKE_DURATION` sufficient to prevent flash-loan staking?
**Verdict:** PARTIALLY DEFENDED (see Finding #1 for the gap)

#### Analysis

**Standard flash-stake via `withdraw()`:** Fully blocked. The `MIN_STAKE_DURATION = 1 days` check in `withdraw()` prevents flash-loan staking because the attacker cannot repay the loan within the same block (or even within 24 hours).

**Flash-stake via `emergencyWithdraw()`:** The gap identified in Finding #1. `emergencyWithdraw()` has no `MIN_STAKE_DURATION` check. An attacker can stake, wait 1 block, claim immediate rewards, and emergencyWithdraw, all within 2 blocks.

**Flash-stake via claim-only:** A subtler variant. An attacker stakes with their own LP tokens (not flash-loaned), claims rewards every block, but never withdraws. This is not a "flash-stake" per se -- it is standard staking behavior. The `MIN_STAKE_DURATION` is irrelevant here because the attacker never triggers `withdraw()`. However, the attacker IS earning rewards legitimately proportional to their stake and time, which is by design.

**Re-staking after full withdrawal:** If a user fully withdraws (user.amount becomes 0) and immediately re-stakes, `stakeTimestamp` is reset to `block.timestamp` (line 557-561: `if (user.amount == 0)`). This is correct behavior -- the user is starting a new staking position.

**Re-staking during active stake (Round 7 M-01):** The current code at line 557 checks `if (user.amount == 0)` before setting the timestamp. This means re-staking (adding more LP while already staked) does NOT reset the timer. This fix was already applied, contradicting the Round 7 audit report which appears to describe an older code version.

#### Defense Assessment

The `MIN_STAKE_DURATION` protection is effective against the primary flash-loan attack vector (`stake` + `withdraw`). The `emergencyWithdraw` bypass (Finding #1) is the only remaining gap.

---

### 7. Cross-Contract Interactions

**Category:** Can OmniCore or other contracts manipulate LiquidityMining state?
**Verdict:** DEFENDED

#### Analysis

**Contract isolation:** LiquidityMining has zero imports from project-specific contracts. Its only external dependencies are:
- `IERC20` / `SafeERC20` (OpenZeppelin) -- for LP token and XOM token interactions
- `ReentrancyGuard` (OpenZeppelin) -- reentrancy protection
- `Ownable2Step` / `Ownable` (OpenZeppelin) -- access control
- `Pausable` (OpenZeppelin) -- pause mechanism
- `ERC2771Context` / `Context` (OpenZeppelin) -- meta-transaction support

No other OmniBazaar contract holds a reference to LiquidityMining or can call its functions (other than standard user interactions).

**ERC-2771 trusted forwarder vector:** The trusted forwarder (set as immutable in constructor) can submit meta-transactions on behalf of users. If the forwarder is compromised, an attacker could:
1. Call `stake()` on behalf of a user (requires user's signed meta-tx, so not unilateral)
2. Call `emergencyWithdraw()` on behalf of a user (same)
3. Call `claim()` on behalf of a user (same)

The forwarder requires valid user signatures (EIP-712 or similar) to submit meta-transactions. A compromised forwarder cannot forge signatures. The worst case is a forwarder that replays or withholds transactions, which is a liveness issue, not a funds-at-risk issue. Users can always interact directly with LiquidityMining, bypassing the forwarder.

**LP token as attack vector (VP-05, VP-50):** If an LP token implements ERC-777 hooks or other callback mechanisms, the `safeTransferFrom` call in `stake()` could trigger a callback. However:
1. `stake()` is protected by `nonReentrant`
2. State updates (user.amount, pool.totalStaked) happen AFTER the token transfer (lines 564-569)
3. Wait -- this means the token transfer at line 552 happens BEFORE the state update at line 564. Could a callback in `safeTransferFrom` re-enter?

Let me trace the `stake()` function order:
1. `_updatePool(poolId)` -- updates pool accumulator
2. `_harvestRewards(poolId, caller)` -- harvests if existing stake
3. `pool.lpToken.safeTransferFrom(caller, address(this), amount)` -- EXTERNAL CALL
4. `user.amount += received` -- state update
5. `pool.totalStaked += received` -- state update

The external call at step 3 occurs BEFORE the state updates at steps 4-5. This appears to violate Checks-Effects-Interactions (CEI). However, the `nonReentrant` modifier prevents re-entry into any `nonReentrant`-protected function. Since all state-modifying functions (`stake`, `withdraw`, `claim`, `claimAll`, `emergencyWithdraw`) are `nonReentrant`, a callback from the LP token cannot re-enter any of them.

A read-only reentrancy (VP-04) is theoretically possible: during the callback at step 3, `pool.totalStaked` has not yet been updated with the new deposit. If another contract reads `pool.totalStaked` via `getPoolInfo()` during this window, it would see the stale value. However, LiquidityMining does not expose any view functions that other contracts depend on for pricing or collateral calculations. The stale read would only affect off-chain indexers, not on-chain security.

**OmniCore interaction:** OmniCore.sol does not reference LiquidityMining and has no mechanism to manipulate its state. The two contracts are completely independent.

#### Defense Assessment

Cross-contract attacks are not viable. The contract is well-isolated, all state-modifying functions have reentrancy protection, and the ERC-2771 forwarder cannot act unilaterally.

---

## Additional Observations

### Round 7 M-01 Status Discrepancy

The Round 7 audit report (dated 2026-03-13) identifies M-01 as "Re-Staking Resets MIN_STAKE_DURATION Timer" and shows the code as:

```solidity
// H-01 Round 6: record stake timestamp for MIN_STAKE_DURATION
stakeTimestamp[poolId][caller] = block.timestamp;
```

However, the current contract code (lines 555-561) already includes the fix:

```solidity
// M-01: Only set stake timestamp on first stake, not re-stakes.
// Re-staking should NOT reset the MIN_STAKE_DURATION timer.
if (user.amount == 0) {
    // H-01 Round 6: record stake timestamp for MIN_STAKE_DURATION
    stakeTimestamp[poolId][caller] = block.timestamp;
}
```

The code comment explicitly references M-01 as the reason for the guard. This fix was likely applied between the Round 7 audit snapshot and the current code. **Round 7 M-01 should be considered FIXED.**

### Unused MIN_UPDATE_INTERVAL Constant

The constant `MIN_UPDATE_INTERVAL = 1 days` (line 119) is declared but never referenced in any function. It was presumably intended to enforce a minimum interval between `setRewardRate()` calls, but this enforcement was never implemented. This is not a vulnerability (it would be a defense-in-depth measure), but it is dead code.

### emergencyWithdraw Does Not Reset stakeTimestamp

When `emergencyWithdraw()` zeroes out all user state (lines 770-776), it does NOT reset `stakeTimestamp[poolId][caller]`. This means if the user stakes again later, the `if (user.amount == 0)` check at line 557 is true, so `stakeTimestamp` IS reset. No functional impact, but the stale timestamp remains in storage until the user stakes again.

---

## Summary of Recommendations

| # | Finding | Severity | Recommendation | Effort |
|---|---------|----------|----------------|--------|
| 1 | emergencyWithdraw bypasses MIN_STAKE_DURATION | Medium | Add MIN_STAKE_DURATION check to emergencyWithdraw (with paused-state exception) | Low |
| 1b | High immediateBps amplifies flash-stake extraction | Medium | Consider MAX_IMMEDIATE_BPS cap or document operational policy | Low |
| 2 | totalCommittedRewards conservative drift | Low | Accept -- documented, negligible, safe direction | None |
| 3 | setRewardRate front-running window | Informational | Use private transactions for admin rate changes | Operational |
| -- | Round 7 M-01 (re-staking timer reset) | -- | Already FIXED in current code | None |
| -- | Unused MIN_UPDATE_INTERVAL constant | Informational | Remove dead code or implement enforcement | Trivial |

---

## Overall Assessment

LiquidityMining.sol is a well-hardened contract after four prior audit rounds. The single viable exploit (Finding #1: emergencyWithdraw as flash-stake escape hatch) requires specific conditions to be profitable (high `immediateBps`, high reward rate, available LP flash loans) and has natural mitigations (0.5% LP fee, 70% vesting forfeiture at default settings). The remaining findings are low/informational severity.

**Deployment readiness:** CONDITIONALLY APPROVED. Recommend applying the `MIN_STAKE_DURATION` check in `emergencyWithdraw()` before mainnet deployment. If that fix is not applied, ensure all pools use `immediateBps <= 5000` as an operational constraint and document the risk.

---

*Adversarial review conducted 2026-03-14*
*Analysis method: Manual line-by-line trace with concrete exploit construction*
*Cross-referenced: vulnerability-patterns.md (56 patterns), Round 7 audit findings, StakingRewardPool adversarial report*
