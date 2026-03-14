# StakingRewardPool.sol -- Adversarial Security Review (Round 8)

**Date:** 2026-03-14
**Reviewer:** Adversarial Agent A3
**Contract:** `Coin/contracts/StakingRewardPool.sol` (1,149 lines)
**Methodology:** Concrete exploit construction across 7 categories
**Prior Audits:** Round 1 (2026-02-20), Round 4 Attacker (2026-02-28), Round 6 (2026-03-10), Round 7 (2026-03-13)
**Cross-Referenced:** OmniCore.sol (stake/unlock), OmniCoin.sol (ERC20), OmniForwarder.sol (ERC-2771)

---

## Executive Summary

This adversarial review attempted to construct concrete, step-by-step exploit scenarios against StakingRewardPool.sol across seven pre-identified attack surfaces. The contract has been through seven prior audit rounds and is substantially hardened. After detailed analysis, I identify **one viable medium-severity exploit** (the `emergencyWithdraw` XOM-check bypass via `xomToken` reassignment, confirming Round 7 M-02 but with a newly identified single-role variant) and **one new low-severity finding** (cross-cycle `frozenRewards` carry-over allowing a staker to inflate rewards on a second staking cycle). The remaining five attack categories are properly defended. The `snapshotRewards` griefing vector is partially mitigated but has a remaining edge case worth documenting.

---

## Viable Exploits

| # | Attack Name | Severity | Attacker Profile | Confidence | Impact |
|---|-------------|----------|------------------|------------|--------|
| 1 | emergencyWithdraw XOM Drain via Single-Admin xomToken Swap | Medium | Compromised Admin (ADMIN_ROLE + DEFAULT_ADMIN_ROLE on same key) | HIGH | Complete pool drainage (all XOM) |
| 2 | Cross-Cycle frozenRewards Carry-Over Inflation | Low | Any staker | MEDIUM | Excess rewards on second staking cycle |
| 3 | snapshotRewards Griefing -- lastClaimTime Advancement | Low | Any external actor | MEDIUM | Reduced accrued rewards for target user |

---

### 1. emergencyWithdraw XOM Drain via Single-Admin xomToken Swap

**Severity:** Medium
**Confidence:** HIGH
**Attacker Profile:** Compromised admin keypair that holds both ADMIN_ROLE and DEFAULT_ADMIN_ROLE (common in early deployments, or a single multisig that holds both)

**Exploit Scenario:**

This extends Round 7 M-02 with a critical observation: in the `initialize()` function (lines 435-436), the deployer receives **both** `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE`. If role separation is not performed post-deployment (which is an operational step, not enforced by code), a single compromised key controls both roles needed for this attack.

Step-by-step:

1. **T+0h:** Attacker (holding both roles) calls `proposeContracts(currentOmniCore, fakeTokenAddress)` where `fakeTokenAddress` is any ERC20 that is not the real XOM. This emits `ContractsChangeProposed` but may go unnoticed if monitoring is not active.

2. **T+48h:** Attacker calls `executeContracts()`. The `xomToken` state variable now points to `fakeTokenAddress`. The real XOM tokens are still physically sitting in the contract. At this point:
   - `emergencyWithdraw` check `token == address(xomToken)` now compares against `fakeTokenAddress`
   - The real XOM address will pass the check (it is not equal to `fakeTokenAddress`)

3. **T+48h (same tx or next block):** Attacker calls `emergencyWithdraw(realXomAddress, poolBalance, attackerWallet)` using `DEFAULT_ADMIN_ROLE`. Since `realXomAddress != address(xomToken)` (xomToken is now the fake token), the `CannotWithdrawRewardToken` revert is bypassed.

4. **Result:** All real XOM drained from the pool. All stakers permanently lose their pending rewards.

**Code References:**
- `initialize()` lines 435-436: Both roles granted to single deployer
- `emergencyWithdraw()` line 824: `if (token == address(xomToken))` -- dynamic check against mutable state
- `executeContracts()` line 765: `xomToken = IERC20(pending.xomToken)` -- allows xomToken mutation
- `proposeContracts()` line 727: Only requires ADMIN_ROLE

**Existing Defenses:**
- 48-hour timelock on contract changes (provides detection window)
- `ContractsChangeProposed` event emitted (requires active monitoring)
- Requires role separation to have been performed post-deployment (operational, not code-enforced)

**Why This is Worse Than Round 7 Assessed:**

Round 7 M-02 stated this "requires both ADMIN_ROLE and DEFAULT_ADMIN_ROLE" as a mitigating factor. However, `initialize()` grants BOTH roles to `msg.sender`. Unless an explicit post-deployment step separates these roles (which is not enforced by the contract), a single key compromise enables the full attack. The 48h timelock is the only defense.

**Recommendation:**

Priority A (code fix): Store the XOM token address as an immutable that cannot be changed via `executeContracts()`:

```solidity
address private immutable _permanentXomToken;

constructor(address trustedForwarder_, address xomToken_)
    ERC2771ContextUpgradeable(trustedForwarder_)
{
    _permanentXomToken = xomToken_;
    _disableInitializers();
}

function emergencyWithdraw(address token, uint256 amount, address recipient)
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (recipient == address(0)) revert ZeroAddress();
    if (token == address(xomToken) || token == _permanentXomToken) {
        revert CannotWithdrawRewardToken();
    }
    IERC20(token).safeTransfer(recipient, amount);
    emit EmergencyWithdrawal(token, amount, recipient);
}
```

Priority B (operational): Enforce role separation in the deployment script immediately after `initialize()`. Transfer `DEFAULT_ADMIN_ROLE` to a separate multisig or timelock controller. Document this as a mandatory deployment step.

Priority C (monitoring): Deploy an on-chain monitor contract that automatically calls `pause()` if a `ContractsChangeProposed` event changes the `xomToken` address.

---

### 2. Cross-Cycle frozenRewards Carry-Over Inflation

**Severity:** Low
**Confidence:** MEDIUM
**Attacker Profile:** Any staker with patience (requires two full staking cycles)

**Exploit Scenario:**

The `frozenRewards` mapping and `lastClaimTime` mapping persist across staking cycles. When a user stakes, snapshots, unlocks, then stakes again, the `frozenRewards` from the first cycle carry into the second cycle's `earned()` calculation. This is by design for the unlock/claim workflow, but creates an edge case when combined with the partial-claim mechanism.

Step-by-step:

1. **Cycle 1:** User stakes 10M XOM at Tier 3 with 730-day duration (12% APR). After 730 days, accrued rewards = 10M * 0.12 * 2 = 2.4M XOM.

2. **Pre-Unlock:** User calls `snapshotRewards()`. Now `frozenRewards[user] = 2.4M XOM`.

3. **Claim Partial:** User calls `claimRewards()`. `earned()` returns `frozenRewards (2.4M) + accrued (0, since lastClaimTime was just set)` = 2.4M. But `MAX_CLAIM_PER_TX = 1M`, so only 1M is paid out. State after claim: `frozenRewards[user] = 1.4M`, `lastClaimTime[user] = now`.

4. **Unlock:** User calls `OmniCore.unlock()`. Stake becomes inactive. User still has `frozenRewards[user] = 1.4M`.

5. **Cycle 2:** User stakes again with the same 10M XOM. Now `earned()` returns `frozenRewards (1.4M) + _computeAccrued(new stake data)`. As time passes, the new accrual adds on top of the carried-over 1.4M.

6. **The Issue:** The `_computeAccrued` function uses `lastClaimTime` to determine the accrual start (line 970). Since `lastClaimTime` was set during the partial claim in Cycle 1, it may be **before** the new stake's `stakeStart` time. The code handles this at line 971-973:
   ```solidity
   if (accrualStart < stakeStart) {
       accrualStart = stakeStart;
   }
   ```
   This correctly clamps to the new stake start. So the new accrual is properly bounded. The user's `frozenRewards` carry-over is the designed behavior -- they earned those rewards legitimately.

**Reassessment:** Upon deeper analysis, this is NOT exploitable. The `accrualStart` clamping at line 971-973 prevents double-counting. The `frozenRewards` carry-over is intentional -- it represents legitimately earned but unclaimed rewards from the previous cycle. The partial claim correctly tracks the remainder.

**Revised Confidence:** LOW -- this is working as designed. The only concern is that `frozenRewards` could accumulate over many cycles if a user never fully claims, but the `MAX_CLAIM_PER_TX` ensures eventual drainage, and the rewards are legitimately earned.

**Status:** NOT EXPLOITABLE (investigated, properly handled)

---

### 3. snapshotRewards Griefing -- lastClaimTime Advancement

**Severity:** Low
**Confidence:** MEDIUM
**Attacker Profile:** Any external actor (snapshotRewards is callable by anyone)

**Exploit Scenario:**

`snapshotRewards(user)` is callable by anyone for any user (line 523, documented as "Callable by anyone for any user (intentional design)"). When called, it:
1. Computes accrued rewards since `lastClaimTime[user]`
2. Adds accrued to `frozenRewards[user]`
3. Sets `lastClaimTime[user] = block.timestamp` (line 541)
4. Caches stake data in `lastActiveStake[user]` (line 548)

The griefing vector: An attacker can call `snapshotRewards(targetUser)` repeatedly. Each call:
- Correctly freezes accrued rewards (no reward loss if stake is active)
- Advances `lastClaimTime` to `block.timestamp`
- Overwrites `lastActiveStake` with current stake data

Step-by-step:

1. User Alice has been staking for 6 months and has accrued significant rewards.
2. Attacker calls `snapshotRewards(alice)` every block.
3. Each call: accrued since last snapshot (a few seconds of rewards) gets frozen, lastClaimTime advances, lastActiveStake gets overwritten.

**Analysis:** This does NOT cause reward loss for Alice as long as her stake remains active. The frozen rewards accumulate correctly. However, it causes unnecessary gas consumption on Alice's behalf (she pays nothing, attacker pays gas) and, more importantly, it continuously **overwrites `lastActiveStake`** with current data.

The overwrite matters because `lastActiveStake` is intended to preserve historical stake data for post-unlock claims. If the attacker calls `snapshotRewards(alice)` right after Alice's lock period expires but before she unlocks, the snapshot correctly captures her full stake data. This is actually fine.

**The real edge case:** If an attacker calls `snapshotRewards(alice)` when `accrued > 0` (which it will be after even 1 second), it overwrites `lastActiveStake` with the current stake data. If Alice's stake data subsequently changes (e.g., she gets slashed by a governance action that modifies OmniCore state), the `lastActiveStake` would reflect the pre-modification state. But OmniCore does not support mid-stake modifications, so this edge case is currently impossible.

**Existing Defenses:**
- The `accrued > 0` guard (line 538) prevents overwriting when no rewards have accrued
- `frozenRewards` accumulates correctly, so no rewards are lost
- The griefing costs the attacker gas with no material benefit

**Impact:** Minimal. Gas cost to the attacker, no material loss to the target user. The continuous `lastActiveStake` overwrite is harmless given OmniCore's stake immutability.

**Status:** DEFENDED (griefing possible but non-impactful)

---

## Investigated but Defended

### 4. emergencyWithdraw XOM-Check Bypass via Token Balance Manipulation

**Attack Concept:** Manipulate the XOM token balance of the StakingRewardPool before the `emergencyWithdraw` check to make the pool appear empty, then withdraw through some other path.

**Analysis:** The `emergencyWithdraw` function (line 818-831) checks `if (token == address(xomToken))` -- this is an address comparison, not a balance check. There is no balance-dependent logic in `emergencyWithdraw` that could be manipulated. The check is purely "is this the XOM token address?" If yes, revert. If no, allow withdrawal.

The only way to drain XOM is:
1. Via `claimRewards()` -- requires a legitimate (or spoofed) `earned()` return value
2. Via `emergencyWithdraw()` with the xomToken swap trick (see Finding #1)
3. Via UUPS upgrade to malicious implementation

Directly manipulating the token balance before `emergencyWithdraw` does not bypass the address check.

**Status:** DEFENDED

---

### 5. Unlock/Snapshot Race -- Front-Running to Steal Rewards

**Attack Concept:** User A watches the mempool for User B's `unlock()` transaction. User A front-runs with `snapshotRewards(userB)` to freeze User B's rewards, then somehow claims them.

**Analysis:** This is actually a HELPFUL action, not an attack. `snapshotRewards` freezes rewards into `frozenRewards[userB]`, which can only be claimed by User B via `claimRewards()` (which uses `_msgSender()` to determine the caller/recipient). There is no path to redirect another user's frozen rewards.

The actual risk (confirmed in Round 7 M-01) is the OPPOSITE scenario: nobody calls `snapshotRewards(userB)` before `unlock()`, causing User B's accrued rewards to be lost. But this is a user-experience issue, not an exploit -- the "attacker" here is User B themselves, making a mistake.

**Status:** DEFENDED (front-running is benign or helpful)

---

### 6. Ossification Bypass

**Attack Concept:** After `ossify()` is called, find a path to still upgrade the contract.

**Analysis:**
- `ossify()` (line 898) sets `_ossified = true` permanently (no function to set it back to false)
- `_authorizeUpgrade()` (line 926) checks `if (_ossified) revert ContractIsOssified()`
- `_authorizeUpgrade` is `internal override` -- the UUPS upgrade path MUST go through this function
- There is no `selfdestruct` or `delegatecall` to an arbitrary address that could bypass this
- The only upgrade path is `upgradeToAndCall()` (inherited from UUPSUpgradeable) which calls `_authorizeUpgrade()`

**Remaining paths checked:**
1. `proposeContracts()` / `executeContracts()` -- changes `omniCore` and `xomToken` references but does NOT upgrade the implementation contract
2. `AccessControl.grantRole()` -- can grant new DEFAULT_ADMIN_ROLE holders, but they still cannot bypass `_ossified` check
3. Storage collision with `_ossified` -- the variable is at a deterministic slot in the contract's storage namespace. No other function writes to this slot. Checked: `_ossified` is a `bool private` at a specific slot, and the `__gap` array does not overlap.

**Status:** FULLY DEFENDED -- ossification is irreversible and cannot be bypassed through any code path.

---

### 7. Reward Calculation Overflow

**Attack Concept:** Find staking amounts + duration combinations that cause arithmetic overflow in the reward calculation.

**Analysis:** The reward formula (line 998-999):
```solidity
return (stakeData.amount * effectiveAPR * elapsed)
    / (SECONDS_PER_YEAR * BASIS_POINTS);
```

Worst-case inputs:
- `amount`: 16.6 billion XOM = 16,600,000,000 * 10^18 = ~1.66 * 10^28
- `effectiveAPR`: MAX_TOTAL_APR = 1200
- `elapsed`: 40 years = 40 * 365.25 * 86400 = ~1.262 * 10^9

Product: 1.66 * 10^28 * 1200 * 1.262 * 10^9 = ~2.51 * 10^40

`uint256` max: ~1.16 * 10^77

Safety margin: ~10^37. Even with theoretical maximum values far exceeding the token supply, there is no overflow risk. Solidity 0.8.24 built-in overflow checks would revert anyway if somehow triggered.

**Status:** FULLY DEFENDED -- enormous safety margin, built-in overflow protection.

---

### 8. Tier Boundary Gaming

**Attack Concept:** Stake exactly at a tier boundary (e.g., exactly 1,000,000 XOM) to get Tier 2 rewards, then unstake dust to drop below the threshold while keeping the higher tier.

**Analysis:**

OmniCore's `_validateStakingTier()` (line 1339-1355) enforces minimum thresholds:
- Tier 2 requires `amount >= 1_000_000 ether`
- The stake amount is immutable after staking (OmniCore stores it and does not allow partial withdrawal)
- `unlock()` returns the full `userStake.amount` -- there is no partial unstake

StakingRewardPool's `_clampTier()` (line 1071-1095) independently validates the declared tier against the staked amount, using the same thresholds. Even if OmniCore somehow returned an inflated tier, `_clampTier` would clamp it down.

OmniCore does allow staking at a LOWER tier than the amount qualifies for (e.g., staking 10M XOM but declaring Tier 1). `_validateStakingTier` only checks `amount >= tierMinimums[tier - 1]` -- it does not enforce that the user picks the highest tier their amount qualifies for. This is by design (documented in Round 7 I-01 as a frontend responsibility). A user choosing a lower tier only hurts themselves (lower APR), which is not an exploit.

**Status:** FULLY DEFENDED -- immutable stake amounts, dual tier validation, no partial unstake.

---

### 9. Front-Running Reward Distribution (depositToPool)

**Attack Concept:** Front-run a large `depositToPool()` call to stake just before the pool gets funded, then claim rewards from the new funds.

**Analysis:** `depositToPool()` adds XOM to the pool's balance but does not distribute it to anyone. Rewards are calculated purely based on time-based APR, not pool share. Whether the pool has 1 XOM or 1 billion XOM, the reward calculation is identical. The pool balance only matters at claim time (line 491: `if (poolBalance < reward)`).

Front-running `depositToPool()` provides zero advantage because:
1. Reward accrual is time-based, not share-based
2. `MIN_STAKE_AGE = 1 days` prevents claiming within 24 hours of staking
3. `duration == 0` check prevents uncommitted staking
4. Minimum useful duration is 30 days (OmniCore validation)

**Status:** FULLY DEFENDED -- rewards are time-based, not pool-share-based.

---

### 10. Reentrancy During Unstake (via XOM Token Callback)

**Attack Concept:** The XOM token transfer in `claimRewards()` triggers a callback that re-enters the contract.

**Analysis:**
- `claimRewards()` has the `nonReentrant` modifier (line 470)
- OmniCoin is a standard ERC20 (extends `ERC20`, `ERC20Pausable`, `ERC20Votes`) with no ERC777 hooks
- OmniCoin's `_update()` override (line 312-318) calls `super._update()` which is the standard ERC20 transfer -- no external calls or callbacks
- Even if OmniCoin had callbacks, `nonReentrant` would block re-entry
- The CEI pattern is followed: state updates (lines 498-500) happen before the transfer (line 504)

`snapshotRewards()` lacks `nonReentrant` but only makes a `view` call to `omniCore.getStake()` (no external state changes possible via a view call). Its state writes are to its own mappings only.

**Status:** FULLY DEFENDED -- nonReentrant + CEI + standard ERC20 (no callbacks).

---

## ERC-2771 Trusted Forwarder Analysis

**Attack Concept:** Abuse the trusted forwarder to impersonate another user when calling `claimRewards()` and redirect their rewards.

**Analysis:**

The OmniForwarder (line 36-43 of OmniForwarder.sol) is OpenZeppelin's `ERC2771Forwarder` which:
- Verifies EIP-712 signatures before forwarding
- Auto-increments nonces to prevent replay
- Checks deadlines on forwarded requests

For `claimRewards()`:
- `_msgSender()` returns the forwarder-extracted sender address (line 473)
- Rewards are transferred to `caller` (line 504) which is `_msgSender()`
- An attacker would need to forge a valid EIP-712 signature from the victim

The forwarder is immutable (set in constructor, `ERC2771ContextUpgradeable` stores it as an immutable). Even if the forwarder were compromised, the attacker could only call `claimRewards()` on behalf of the victim, which would send the victim's rewards to the **victim's address** (since `_msgSender()` extracts the signer from the forwarder's calldata, and the rewards go to that address). The attacker cannot redirect rewards to a different address.

**Status:** FULLY DEFENDED

---

## Summary of Findings

| # | Finding | Severity | Status | Action Required |
|---|---------|----------|--------|-----------------|
| 1 | emergencyWithdraw XOM drain via xomToken swap (single-admin variant) | Medium | CONFIRMED VIABLE | Fix with immutable XOM address in constructor |
| 2 | Cross-cycle frozenRewards carry-over | -- | NOT EXPLOITABLE | Working as designed |
| 3 | snapshotRewards griefing (lastClaimTime advancement) | -- | DEFENDED | Non-impactful gas cost to attacker |
| 4 | emergencyWithdraw balance manipulation | -- | DEFENDED | Address comparison, not balance-dependent |
| 5 | Unlock/snapshot race (front-running) | -- | DEFENDED | Front-running is benign |
| 6 | Ossification bypass | -- | FULLY DEFENDED | Irreversible, no code paths bypass it |
| 7 | Reward calculation overflow | -- | FULLY DEFENDED | 10^37 safety margin |
| 8 | Tier boundary gaming | -- | FULLY DEFENDED | Dual validation, immutable stakes |
| 9 | Front-running reward distribution | -- | FULLY DEFENDED | Time-based rewards, not share-based |
| 10 | Reentrancy during unstake | -- | FULLY DEFENDED | nonReentrant + CEI + standard ERC20 |
| 11 | ERC-2771 impersonation | -- | FULLY DEFENDED | Rewards go to signer, not relayer |

---

## Additional Observations

### Unlock/Snapshot Ordering (Architectural Risk -- Reconfirmed)

Round 7 M-01 identified that `unlock()` in OmniCore does not call `snapshotRewards()`. This remains the highest-risk architectural concern. I attempted to construct an exploit where an attacker **intentionally** causes another user to lose rewards by front-running their `unlock()` call. However, front-running with `snapshotRewards()` would actually SAVE the user's rewards, not lose them. The only scenario where rewards are lost is when the user themselves calls `unlock()` without prior snapshot -- which is a UX failure, not an adversarial exploit.

**Critically:** The `lastActiveStake` mapping is still WRITE-ONLY. It is populated by `snapshotRewards()` but never read by `earned()` or `_computeAccrued()`. This means that even if a snapshot was taken, the cached data serves no computational purpose in the current contract. The `frozenRewards` accumulation in `snapshotRewards()` is what actually preserves rewards. The `lastActiveStake` cache appears to be dead code from a design perspective.

### depositToPool Accounting Gap

`UnifiedFeeVault` transfers XOM directly to the StakingRewardPool (via `safeTransfer`), not through `depositToPool()`. This means `totalDeposited` only tracks explicit `depositToPool()` calls, not all inflows. The actual pool balance (`xomToken.balanceOf(address(this))`) may be significantly larger than `totalDeposited - totalDistributed`. This is documented and accepted, but monitoring systems should use `getPoolBalance()` rather than the counter arithmetic.

### Pending Proposal Single-Slot Limitation

Both `pendingContracts` and `pendingAPRChange` are single-instance. A new proposal silently overwrites the old one. An attacker with ADMIN_ROLE could theoretically:
1. Propose a benign contract change (monitored and approved by community)
2. Wait 47 hours
3. Overwrite with a malicious contract change (new 48h timer starts)
4. The community may have stopped watching after seeing the first proposal was benign

This is a social engineering attack against the monitoring infrastructure, not a code vulnerability. The 48h timer restarts on overwrite, and a new `ContractsChangeProposed` event is emitted. But the Round 7 L-03 finding (no cancellation event for the overwritten proposal) makes this slightly harder to detect via monitoring.

---

## Conclusion

StakingRewardPool.sol is well-hardened after seven audit rounds. The only actionable finding from this adversarial review is the single-admin variant of the `emergencyWithdraw` XOM-check bypass (Finding #1), which should be addressed by storing the XOM token address as an immutable. All other attack vectors are properly defended through a combination of:

- `nonReentrant` guards on fund-moving functions
- CEI pattern for state updates
- `_clampTier()` for independent tier validation
- `MAX_TOTAL_APR` cap on reward rates
- `MAX_CLAIM_PER_TX` cap on per-claim amounts
- `MIN_STAKE_AGE` against flash-stake attacks
- `duration == 0` rejection against uncommitted staking
- 24-48 hour timelocks on configuration changes
- Ossification for permanent immutability
- Standard ERC20 (no callback reentrancy surface)

The contract is suitable for mainnet deployment with the caveat that Finding #1 should either be fixed in code (immutable XOM address) or mitigated operationally (mandatory role separation + active monitoring).

---

*Generated by Adversarial Agent A3 (Claude Opus 4.6)*
*Methodology: Concrete exploit construction with step-by-step scenarios*
*Contract version: StakingRewardPool.sol as of 2026-03-14*
*Cross-referenced: OmniCore.sol, OmniCoin.sol, OmniForwarder.sol, MockOmniCoreStaking.sol*
