# Cross-System Flash Loan Attack Analysis

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Phase 2 -- Pre-Mainnet)
**Scope:** Adversarial cross-contract flash loan attack surface analysis
**Contracts Analyzed:** 11 (8 primary + 3 supplementary)
**Individual Audit Reports Referenced:** Round 6 audit reports for all 8 primary contracts

---

## Executive Summary

This report presents a systematic, adversarial analysis of flash loan attack vectors across the OmniBazaar smart contract protocol. The analysis examines 8 specific attack paths that chain multiple contracts together in a single atomic transaction to extract value, manipulate prices, or game reward calculations.

**Overall Assessment: The protocol has STRONG flash loan resistance.**

The OmniBazaar contract suite demonstrates defense-in-depth against flash loan attacks through multiple independent mechanisms:

1. **Time-based protections:** `MIN_STAKE_AGE` (24h) in StakingRewardPool, `VOTING_DELAY` (1 day) in OmniGovernance, vesting periods in LiquidityMining and OmniBonding
2. **Snapshot-based voting:** ERC20Votes checkpoints in OmniCoin, `getStakedAt()` in OmniCore
3. **Cumulative tracking:** Per-address purchase tracking in LiquidityBootstrappingPool
4. **Deterministic pricing:** Fixed prices in OmniBonding (not oracle-derived), signed order prices in DEXSettlement
5. **Capacity limits:** Daily bonding caps, MAX_OUT_RATIO in LBP, daily volume limits in DEXSettlement

However, **3 cross-contract attack paths present residual risk** that warrants remediation before mainnet:

| ID | Attack Path | Severity | Feasibility |
|----|------------|----------|-------------|
| ATK-01 | Flash Loan + LiquidityMining (no min stake duration) | **HIGH** | Medium |
| ATK-03 | Flash Loan + OmniSwapRouter + LBP Price Manipulation | **MEDIUM** | Low |
| ATK-05 | Flash Loan + OmniBonding Front-Running via OmniSwapRouter | **MEDIUM** | Medium |

All other attack paths are effectively mitigated by existing protections.

---

## Post-Audit Remediation Status (2026-03-10)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| ATK-01 | High | Flash loan + LiquidityMining reward extraction (no min stake duration) | **FIXED** -- Added MIN_STAKE_DURATION to LiquidityMining |
| ATK-03 | Medium | Flash loan + OmniSwapRouter + LBP price manipulation | **FIXED** -- OmniSwapRouter + LBP price manipulation mitigated |
| ATK-05 | Medium | Flash loan + OmniBonding front-running via OmniSwapRouter | **FIXED** -- OmniBonding cooldown after price changes |

---

## Contracts Analyzed

### Primary Contracts (Full Source Review)

| Contract | Location | Lines | Key Flash Loan Defenses |
|----------|----------|-------|------------------------|
| OmniCoin.sol | `contracts/OmniCoin.sol` | 293 | ERC20Votes checkpoints, no minting after genesis |
| OmniCore.sol | `contracts/OmniCore.sol` | 1,369 | Checkpoint-based `getStakedAt()`, tier validation |
| StakingRewardPool.sol | `contracts/StakingRewardPool.sol` | 1,095 | `MIN_STAKE_AGE = 1 days`, tier clamping |
| DEXSettlement.sol | `contracts/dex/DEXSettlement.sol` | 2,107 | EIP-712 dual signatures, commit-reveal, nonReentrant |
| OmniSwapRouter.sol | `contracts/dex/OmniSwapRouter.sol` | 692 | Slippage protection, deadline enforcement |
| LiquidityBootstrappingPool.sol | `contracts/liquidity/LiquidityBootstrappingPool.sol` | 911 | Cumulative purchase tracking, MAX_OUT_RATIO (30%) |
| LiquidityMining.sol | `contracts/liquidity/LiquidityMining.sol` | 1,192 | Vesting split (30% immediate / 70% vested 90 days) |
| OmniBonding.sol | `contracts/liquidity/OmniBonding.sol` | 1,172 | Daily capacity limits, vesting, fixed pricing |

### Supplementary Contracts (Governance & Rewards)

| Contract | Location | Lines | Relevance |
|----------|----------|-------|-----------|
| OmniGovernance.sol | `contracts/OmniGovernance.sol` | 1,091 | Attack vector 4 target |
| OmniRewardManager.sol | `contracts/OmniRewardManager.sol` | ~2,000 | Attack vector 8 target |
| OmniValidatorRewards.sol | `contracts/OmniValidatorRewards.sol` | ~2,000 | Attack vector 8 target |

---

## Attack Path Analysis

### ATK-01: Flash Loan + LiquidityMining Reward Extraction

**Severity: HIGH**
**Feasibility: Medium**
**Contracts Involved:** LiquidityMining.sol, OmniCoin.sol (as reward token), any external AMM LP token

#### Attack Description

An attacker exploits the absence of a minimum staking duration in LiquidityMining to capture a disproportionate share of accumulated rewards by briefly becoming the dominant staker.

#### Attack Steps

1. **Attacker monitors** LiquidityMining pools for pools where `pool.lastRewardTime` is stale (no interactions for a significant period) and `pool.totalStaked` is low.
2. **Attacker acquires** a large quantity of the pool's LP token (via own holdings, borrowing, or market purchase -- not a flash loan, as LP tokens must remain staked across blocks).
3. **Block N:** Attacker calls `LiquidityMining.stake(poolId, largeAmount)`.
   - `_updatePool()` (line 962-984) distributes accumulated rewards across existing stakers proportional to their share at the OLD `totalStaked`.
   - Attacker's stake is added to `totalStaked`.
   - Attacker now holds e.g. 99% of `totalStaked`.
4. **Block N+1** (2 seconds later on Avalanche): Attacker calls `LiquidityMining.withdraw(poolId, largeAmount)`.
   - `_updatePool()` distributes 2 seconds of rewards: `2 * rewardPerSecond * (attackerStake / totalStaked)`.
   - Attacker captures 99% of 2 seconds of rewards.
   - `_harvestRewards()` splits rewards: 30% immediate, 70% vested over 90 days.
5. **Attacker calls** `LiquidityMining.claim(poolId)` to collect the 30% immediate portion.
6. **Repeat** across multiple pools and blocks.

#### Functions Exploited

- `LiquidityMining.stake()` (line 478-514): No minimum duration check
- `LiquidityMining.withdraw()` (line 522-553): No minimum hold time validation
- `LiquidityMining._updatePool()` (line 962-984): Standard MasterChef accumulator
- `LiquidityMining._harvestRewards()` (line 987-1050): Immediate/vested split

#### Profitability Analysis

For a pool with `rewardPerSecond = 1e18` (1 XOM/s) and existing `totalStaked = 1000e18`:
- Attacker stakes `999000e18` LP tokens, capturing 99.9% of pool share
- Per 2-second block: `2 * 1e18 * 0.999 = 1.998e18` XOM (~2 XOM)
- Immediate claim (30%): ~0.6 XOM per block
- At $0.005/XOM: ~$0.003 per block
- **Not profitable at current reward rates** given gas costs

However, for pools with high `rewardPerSecond` (up to `MAX_REWARD_PER_SECOND = 1e24`) and low `totalStaked`:
- `rewardPerSecond = 1e22` (10,000 XOM/s), `totalStaked = 100e18`
- Per 2-second block with 99% share: `2 * 1e22 * 0.99 = 1.98e22` XOM (~19,800 XOM)
- Immediate: ~5,940 XOM (~$30 at $0.005/XOM)
- **Profitable if LP token acquisition cost < $30 per block**

#### Existing Protections

- **Vesting split:** Only 30% of rewards are immediately claimable (70% vests over 90 days) -- reduces immediate profitability by 70%.
- **No flash loan in same block:** LP tokens must remain staked until a separate `withdraw()` call, which must be in a different transaction (or at minimum the same block with `nonReentrant`, so no reentrancy). A flash loan requires repayment within the same transaction, making same-block stake/withdraw impossible.
- **`totalCommittedRewards` tracking:** Prevents owner from sweeping rewards owed to the attacker during the vesting period.

#### Why This Is Still HIGH Severity

Despite the 70% vesting mitigation, the attack remains viable because:
1. The attacker does NOT need a flash loan -- they can use their own capital or borrowed LP tokens with no lockup requirement.
2. The 30% immediate portion is sufficient for profit on high-reward pools.
3. The attack can be automated and repeated every 2 seconds.
4. The 70% vested portion still accrues to the attacker's benefit over 90 days.
5. The attack dilutes rewards for legitimate long-term stakers.

#### Recommended Fix

Add a minimum staking duration to LiquidityMining:

```solidity
uint256 public constant MIN_STAKE_DURATION = 1 hours;
mapping(uint256 => mapping(address => uint256)) public stakeTimestamp;

function stake(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
    // ... existing logic ...
    stakeTimestamp[poolId][caller] = block.timestamp;
    // ...
}

function withdraw(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
    if (block.timestamp < stakeTimestamp[poolId][_msgSender()] + MIN_STAKE_DURATION) {
        revert MinStakeDurationNotMet();
    }
    // ... existing logic ...
}
```

This matches the pattern already implemented in StakingRewardPool (`MIN_STAKE_AGE = 1 days`).

---

### ATK-02: Flash Loan + StakingRewardPool Reward Extraction

**Severity: LOW (Effectively Mitigated)**
**Feasibility: Not Feasible**
**Contracts Involved:** StakingRewardPool.sol, OmniCore.sol, OmniCoin.sol

#### Attack Description

An attacker attempts to flash-loan XOM, stake it in OmniCore, then claim staking rewards from StakingRewardPool, and repay the flash loan -- all in one transaction.

#### Attack Steps (Attempted)

1. Flash-loan large amount of XOM from an external lending protocol.
2. Call `OmniCore.stake()` to deposit XOM with a high tier for maximum APR.
3. Call `StakingRewardPool.claimReward()` to extract staking rewards.
4. Call `OmniCore.unlock()` to unstake XOM.
5. Repay flash loan.

#### Why This Attack Fails

**Protection 1 -- `MIN_STAKE_AGE` (24 hours):**
StakingRewardPool enforces a minimum stake age before any rewards accrue (line ~470):

```solidity
if (stakeStart + MIN_STAKE_AGE > block.timestamp) {
    return 0; // No rewards for stakes younger than 24 hours
}
```

A flash loan that stakes and claims in the same block would have `stakeStart == block.timestamp`, so `stakeStart + 86400 > block.timestamp` is always true. The reward calculation returns 0.

**Protection 2 -- OmniCore Duration Lock:**
`OmniCore.unlock()` checks `block.timestamp >= lockTime`. For `duration = 0`, `lockTime` is still the block timestamp. For any non-zero duration (30/180/730 days), the lock prevents same-block withdrawal.

Even with `duration = 0`, the attacker can unstake in the same block but StakingRewardPool returns 0 rewards due to `MIN_STAKE_AGE`.

**Protection 3 -- Tier Clamping:**
`StakingRewardPool._clampTier()` validates that the declared tier matches the staked amount. An attacker cannot claim Tier 5 (9% APR) with a Tier 1 stake.

#### Impact Assessment

Zero financial impact. The attack is completely blocked by `MIN_STAKE_AGE = 1 days`.

#### Residual Concern

The `duration = 0` option in OmniCore creates a 24-hour window where a non-flash-loan attacker can stake, wait exactly 24 hours, claim rewards, and unstake. The Round 6 StakingRewardPool audit identifies this as M-02 but the economic gain is minimal: `(amount * 1200 * 86400) / (31536000 * 10000)` = 0.033% of the staked amount for one day at max APR. This is comparable to typical lending protocol yields and is not economically attractive enough to constitute an exploit.

---

### ATK-03: Flash Loan + OmniSwapRouter Price Manipulation

**Severity: MEDIUM**
**Feasibility: Low**
**Contracts Involved:** OmniSwapRouter.sol, LiquidityBootstrappingPool.sol, any external AMM adapter

#### Attack Description

An attacker uses a flash loan to manipulate prices on external AMMs routed through OmniSwapRouter, then exploits the manipulated price to extract value from the LiquidityBootstrappingPool or other protocol contracts.

#### Attack Steps

1. **Flash-loan** large amount of counter-asset (e.g., USDC) from an external lending protocol.
2. **Manipulate price** on an external AMM (e.g., Uniswap V3 pool routed via OmniSwapRouter adapter):
   - Swap large amount of USDC for XOM on the AMM, driving XOM price up.
3. **Buy XOM from LBP** at the LBP's current (lower) spot price, which has not been affected by the AMM manipulation because LBP uses its own internal weighted math.
4. **Sell the LBP-acquired XOM** on the manipulated AMM at the inflated price.
5. **Reverse the AMM manipulation** by selling the remaining XOM.
6. **Repay flash loan** with profit.

#### Why This Attack Is Partially Mitigated

**Protection 1 -- LBP is Independent of External AMMs:**
The LBP computes its own spot price using Balancer weighted math based on its internal reserves and time-based weights. External AMM prices do not affect the LBP price. The attacker cannot inflate the LBP's output by manipulating an external pool.

**Protection 2 -- LBP Cumulative Purchase Tracking:**
`LiquidityBootstrappingPool.cumulativePurchases[caller]` tracks total spending per address. Even if the attacker uses the flash-loaned USDC to buy from the LBP, they are limited by `maxPurchaseAmount`.

**Protection 3 -- MAX_OUT_RATIO (30%):**
Each LBP swap can extract at most 30% of the XOM reserve. This limits the total XOM extractable per transaction.

**Protection 4 -- Unidirectional LBP:**
The LBP only supports counter-asset-to-XOM swaps. The attacker cannot sell XOM back to the LBP after step 4. They must sell on external markets.

#### Residual Risk

The attack vector is not against the LBP itself but against the **price relationship between the LBP and external markets**. If the LBP spot price is meaningfully below external market prices (which is the normal state during an LBP), an attacker can:

1. Flash-loan USDC
2. Buy XOM from LBP at below-market price (limited by maxPurchaseAmount and MAX_OUT_RATIO)
3. Sell XOM on external AMMs at market price
4. Repay flash loan

This is not a flash loan attack per se -- it is simple arbitrage that is **expected and desired** in an LBP context. The weight-shifting mechanism is designed to create a declining price curve that invites arbitrage.

However, the OmniSwapRouter introduces a cross-contract concern: if the router's adapter routes through the LBP itself (via a registered adapter), an attacker could construct a multi-hop path that combines external AMM manipulation with LBP purchases in a single atomic swap. The router does not verify price consistency across hops.

**OmniSwapRouter H-02 amplifies this risk:** The router trusts adapter-reported `amountOut` without balance verification. A malicious adapter could report inflated output while delivering fewer tokens, allowing the attacker to bypass the router's slippage check.

#### Recommended Fix

1. **Fix OmniSwapRouter H-01 and H-02** (from the Round 6 OmniSwapRouter audit): Reset adapter approvals after each hop, and add balance-before/after verification for output tokens.
2. **Ensure the LBP is NOT registered as an OmniSwapRouter adapter.** The LBP is a distribution mechanism, not a general-purpose liquidity source.
3. **Document that LBP arbitrage is expected behavior** and the maxPurchaseAmount/MAX_OUT_RATIO limits bound the extraction.

---

### ATK-04: Flash Loan + Governance Voting Power Manipulation

**Severity: LOW (Effectively Mitigated)**
**Feasibility: Not Feasible**
**Contracts Involved:** OmniGovernance.sol, OmniCoin.sol, OmniCore.sol

#### Attack Description

An attacker attempts to flash-loan XOM, delegate to themselves for voting power, and pass a malicious governance proposal in a single transaction.

#### Attack Steps (Attempted)

1. Flash-loan large amount of XOM.
2. Call `OmniCoin.delegate(self)` to gain voting power.
3. Call `OmniGovernance.propose()` to create a malicious proposal.
4. Call `OmniGovernance.castVote()` to vote for the proposal.
5. Force proposal execution.
6. Repay flash loan.

#### Why This Attack Fails Completely

**Protection 1 -- VOTING_DELAY (1 day):**
OmniGovernance has a `VOTING_DELAY = 1 days` (line 132). After `propose()`, the proposal enters `Pending` state for 1 full day before voting opens. The flash loan must be repaid within the same transaction (block), so the attacker cannot vote on their own proposal.

**Protection 2 -- ERC20Votes Checkpoint Snapshots:**
OmniCoin uses OpenZeppelin's ERC20Votes, which records voting power at discrete checkpoints. `OmniGovernance._castVote()` uses `getVotingPowerAt(voter, proposal.snapshotBlock)` (line 846-848), which queries the voting power at `snapshotBlock` -- the block when the proposal was created.

If the attacker flash-loans XOM and creates a proposal in the same block, the snapshot is taken at that block. However, `getVotingPowerAt()` calls `omniCoin.getPastVotes(account, blockNumber)`, and ERC20Votes records checkpoints at the *start* of the block, before any transactions in that block execute. The attacker's flash-loan delegation would create a checkpoint in the current block, but `getPastVotes()` for the current block may return the pre-delegation value depending on the OpenZeppelin version and block ordering semantics.

Even if the checkpoint is recorded in time, the VOTING_DELAY prevents voting until the next day, by which time the flash loan is long repaid and the delegation is gone.

**Protection 3 -- OmniCore Staking Snapshots:**
`OmniGovernance._getStakedAmountAt()` (line 988-1009) uses `OmniCore.getStakedAt()` with checkpoint-based lookups. The ATK-H02 fix explicitly removes the fallback to current staking amounts, returning 0 if historical data is unavailable. Flash-staking in OmniCore would not increase voting power for a past snapshot block.

**Protection 4 -- Multi-Phase Execution:**
Even if an attacker could somehow vote, governance proposals require: Active voting (5 days) -> Succeeded -> Queue in Timelock (48h for ROUTINE, 7 days for CRITICAL) -> Execute. This multi-day pipeline makes single-transaction attacks impossible.

**Protection 5 -- Quorum Requirement:**
4% of total supply (~664 billion XOM) must vote for quorum. This is an enormous amount that would be costly to borrow even for a multi-block attack.

#### Impact Assessment

Zero feasibility. The combination of VOTING_DELAY, checkpoint snapshots, and multi-phase execution makes this attack vector completely non-viable.

---

### ATK-05: Flash Loan + OmniBonding Arbitrage via Price Update Front-Running

**Severity: MEDIUM**
**Feasibility: Medium**
**Contracts Involved:** OmniBonding.sol, OmniSwapRouter.sol, OmniCoin.sol

#### Attack Description

An attacker monitors the mempool for `OmniBonding.setXomPrice()` transactions that increase the XOM price, then front-runs the price increase to bond at the old (lower) price and profit from the discount.

#### Attack Steps

1. **Monitor mempool** for `OmniBonding.setXomPrice(newPrice)` where `newPrice > fixedXomPrice`.
2. **Flash-loan** stablecoins (USDC) from an external lending protocol.
3. **Front-run** the `setXomPrice()` by submitting `OmniBonding.bond(asset, amount)` with higher gas priority.
4. Bond executes at old price with discount (e.g., 10% discount on $0.005 = $0.0045/XOM).
5. `setXomPrice()` executes, raising price to e.g., $0.0055.
6. **Problem:** The attacker's XOM is vesting (1-30 days), so cannot immediately sell.
7. **However:** The attacker can use the flash-loaned USDC for the bond, and the XOM vesting represents future value.

#### Why This Attack Is Partially Viable

**The flash loan component is limited:** The attacker must use the flash-loaned USDC to bond, but the XOM is vested over 1-30 days. The flash loan must be repaid in the same transaction, so the attacker cannot use the flash-loaned USDC for bonding (they need to repay it). Instead, they must use their own capital.

**BUT: The front-running component IS viable without a flash loan:**

1. Attacker uses own USDC (or borrows via a non-flash lending protocol).
2. Front-runs `setXomPrice()` to bond at old price.
3. Waits for vesting period.
4. Claims vested XOM.
5. Sells on market at the new (higher) price.

**Quantification (from OmniBonding audit M-02):**

With a 10% price increase and 10% bond discount:
- Old effective price: $0.005 * 0.90 = $0.0045/XOM
- New effective price: $0.0055 * 0.90 = $0.00495/XOM
- Attacker advantage: ~9.1% more XOM per dollar
- With $100,000 USDC: ~2,020,202 additional XOM (~$10,101 in value at new price)
- Limited by daily capacity: `dailyCapacity` per asset

**Cross-contract amplification via OmniSwapRouter:**

If the attacker can simultaneously manipulate the XOM spot price on external AMMs via OmniSwapRouter (lowering it temporarily), the price update by the OmniBonding owner might be a response to genuine price increases. The attacker could:

1. Suppress XOM price on AMMs (flash loan sell pressure).
2. Bond at the current low OmniBonding price.
3. Release the AMM sell pressure (repay flash loan).
4. XOM price recovers, and the attacker's vesting bonds become more valuable.

This is a more sophisticated attack combining mempool observation with flash-loan-based price suppression, but it requires the OmniBonding owner to react to AMM price movements when setting the fixed price.

#### Existing Protections

- **Vesting period (1-30 days):** Delays XOM receipt, introducing market risk.
- **Daily capacity limits:** Cap the amount bondable per asset per day.
- **PRICE_COOLDOWN (6 hours):** Limits price changes to 10% per 6 hours.
- **MAX_PRICE_CHANGE_BPS (10%):** Bounds any single price change.
- **Solvency check:** `XOM.balanceOf(address(this)) >= totalXomOutstanding + xomOwed` prevents bonding beyond available XOM.

#### Recommended Fix

The OmniBonding audit already recommends the operational mitigation:

1. **Pause bonding before price changes:** Owner calls `pause()`, then `setXomPrice()`, then `unpause()`. This eliminates the front-running window.
2. **Alternatively, add a bond cooldown after price changes:**

```solidity
uint256 public bondCooldownAfterPriceChange = 1 hours;

function bond(address asset, uint256 amount) external nonReentrant whenNotPaused {
    if (block.timestamp < lastPriceUpdateTime + bondCooldownAfterPriceChange) {
        revert BondCooldownActive();
    }
    // ... existing logic ...
}
```

---

### ATK-06: Cross-Contract Reentrancy Chain

**Severity: LOW (Effectively Mitigated)**
**Feasibility: Very Low**
**Contracts Involved:** DEXSettlement.sol, OmniSwapRouter.sol, LiquidityMining.sol, OmniBonding.sol

#### Attack Description

An attacker attempts to exploit reentrancy across multiple contracts in the protocol by using token transfer callbacks (ERC-777 hooks, ERC-1363 callbacks, or malicious token contracts) to re-enter other protocol contracts during a settlement or swap.

#### Attack Steps (Attempted)

1. Create a malicious ERC-777 token with `tokensReceived` hooks.
2. Register this token as a trading pair on DEXSettlement.
3. During `settleTrade()`, when the malicious token is transferred, the `tokensReceived` hook fires.
4. From within the hook, call into OmniSwapRouter, LiquidityMining, or OmniBonding to exploit stale state.

#### Why This Attack Fails

**Protection 1 -- ReentrancyGuard on All Contracts:**

| Contract | Protected Functions | Guard Type |
|----------|-------------------|------------|
| DEXSettlement | `settleTrade()`, `settleIntent()`, `lockIntentCollateral()`, `claimFees()` | `nonReentrant` |
| OmniSwapRouter | `swap()`, `rescueTokens()` | `nonReentrant` |
| LiquidityMining | `stake()`, `withdraw()`, `claim()`, `claimAll()`, `emergencyWithdraw()` | `nonReentrant` |
| OmniBonding | `bond()`, `claim()`, `claimAll()` | `nonReentrant` |
| StakingRewardPool | `claimReward()` | `nonReentrant` |
| LiquidityBootstrappingPool | `swap()` | `nonReentrant` |
| OmniCore | `stake()`, `unlock()` | `nonReentrant` |

Each contract has independent `ReentrancyGuard` instances. A callback from DEXSettlement can call OmniSwapRouter (different guard, would succeed), but the OmniSwapRouter call would complete normally -- there is no stale state to exploit because:

- DEXSettlement's `settleIntent()` follows CEI (state updated before transfers).
- DEXSettlement's `settleTrade()` has a CEI violation (H-01 in the DEXSettlement audit), but the state updates that occur after transfers (`filledOrders`, nonces, volume) are defensive -- reading stale values from another contract would see the order as "not filled yet" and nonces as "not used yet," but re-settlement would fail because `nonReentrant` prevents re-entering `settleTrade()`.

**Protection 2 -- Cross-Contract Read-Only Reentrancy:**

The DEXSettlement H-01 finding (CEI violation in `settleTrade()`) creates a read-only reentrancy window where external contracts querying `filledOrders`, `isNonceUsed()`, or `dailyVolumeUsed` would see stale values during token transfer callbacks. This could be exploited if another protocol contract (e.g., an oracle or rate limiter) reads these values for decision-making.

**Current cross-contract dependencies that could be affected:**

| Source Contract | View Function | Dependent Contract | Usage |
|----------------|--------------|-------------------|-------|
| DEXSettlement | `dailyVolumeUsed` | None | Not read by other contracts |
| DEXSettlement | `filledOrders[hash]` | None | Not read by other contracts |
| DEXSettlement | `totalTradingVolume` | None | Informational only |
| OmniCore | `stakes(address)` | OmniGovernance | Voting power |
| OmniCore | `getStakedAt()` | OmniGovernance | Snapshot voting |
| OmniCore | `stakes(address)` | StakingRewardPool | Reward calculation |

**No cross-contract read-only reentrancy is exploitable** in the current architecture because:
- DEXSettlement's stale view functions are not read by any other protocol contract during their state-changing functions.
- OmniCore's staking data is read by OmniGovernance, but governance voting uses snapshot blocks (historical data), not current state.
- StakingRewardPool reads OmniCore's staking data, but reward claims use `claimReward()` which is `nonReentrant` and cannot be called from a transfer callback of an unrelated settlement.

#### Impact Assessment

Effectively zero. The independent `nonReentrant` guards on all contracts, combined with the lack of cross-contract state dependencies during transfer callbacks, make cross-contract reentrancy non-exploitable in the current architecture.

#### Recommended Fix

Fix DEXSettlement H-01 (move state updates before `_executeAtomicSettlement()` in `settleTrade()`) as a defense-in-depth measure. This is not exploitable today but would become a risk if future contracts begin reading DEXSettlement view functions during their own state-changing operations.

---

### ATK-07: Flash Loan + Oracle Manipulation via OmniSwapRouter

**Severity: LOW (Effectively Mitigated)**
**Feasibility: Very Low**
**Contracts Involved:** OmniSwapRouter.sol, OmniBonding.sol, LiquidityBootstrappingPool.sol, DEXSettlement.sol

#### Attack Description

An attacker uses a flash loan to manipulate prices on AMMs routed through OmniSwapRouter, then exploits the manipulated price to extract value from protocol contracts that rely on market price feeds.

#### Analysis of Oracle Dependencies

**Critical finding: The OmniBazaar protocol uses almost NO on-chain price oracles.**

| Contract | Price Source | Oracle Type | Manipulable? |
|----------|------------|-------------|-------------|
| OmniBonding | `fixedXomPrice` (owner-set) | Manual | No (owner-controlled) |
| LiquidityBootstrappingPool | Internal weighted math | Algorithmic | No (self-contained reserves) |
| DEXSettlement | EIP-712 signed order prices | Off-chain signatures | No (pre-agreed prices) |
| OmniSwapRouter | `ISwapAdapter.getAmountOut()` | Per-adapter | Yes (adapter-dependent) |
| StakingRewardPool | Tier-based APR (no price) | None | N/A |
| LiquidityMining | `estimateAPR()` (view, off-chain prices) | External input | View-only, not exploitable |
| OmniValidatorRewards | Fixed emission schedule | None | N/A |

**The protocol's key design strength is the deliberate avoidance of on-chain price oracles.** OmniBonding uses a manually-set fixed price. DEXSettlement uses pre-signed order prices. The LBP uses its own internal reserves. None of these can be manipulated via flash loans on external AMMs.

#### OmniSwapRouter as the Single Oracle-Adjacent Component

The OmniSwapRouter's `getQuote()` function calls `ISwapAdapter.getAmountOut()` on registered adapters. If these adapters use spot prices from manipulable AMM pools, the quoted price can be inflated or deflated via flash loans. However:

1. `getQuote()` is a `view` function -- it does not change state.
2. `swap()` uses `minAmountOut` for slippage protection -- the user controls their acceptable output.
3. No other protocol contract calls `OmniSwapRouter.getQuote()` for price feeds.

**The only contract that COULD be affected is OmniBonding if the owner uses OmniSwapRouter quotes to determine `fixedXomPrice`.** But this is an off-chain operational decision, not an on-chain vulnerability.

#### Impact Assessment

Minimal. The protocol's architecture deliberately avoids on-chain price oracles for critical financial decisions. Flash loan oracle manipulation has no viable target in the current contract suite.

#### Recommendation

Document the "no on-chain oracle" design decision as a security feature. If future contracts introduce on-chain price oracles (e.g., TWAP oracles for OmniBonding price automation), ensure they use manipulation-resistant designs (multi-block TWAP with minimum observation window >= 30 minutes).

---

### ATK-08: Flash Loan + Reward Calculation Gaming

**Severity: LOW (Effectively Mitigated)**
**Feasibility: Not Feasible**
**Contracts Involved:** OmniRewardManager.sol, OmniValidatorRewards.sol, StakingRewardPool.sol, OmniCore.sol

#### Attack Description

An attacker attempts to game the reward calculation systems across multiple contracts to extract disproportionate rewards by temporarily inflating their staking position, validator status, or participation score.

#### Sub-Vector 8a: OmniRewardManager Welcome/Referral Bonus Gaming

**Attack:** Flash-loan XOM to meet some qualification threshold, then claim a welcome or referral bonus.

**Why it fails:**
- Welcome bonuses require off-chain verification (email, phone, social media follows) via signed attestations from validators.
- `OmniRewardManager.claimWelcomeBonus()` requires a valid validator signature with EIP-712 typehash `ClaimWelcomeBonus(address user,uint256 nonce,uint256 deadline)`.
- The validator signs the attestation off-chain after verifying KYC requirements. Flash-loaning XOM does not help because the qualification criteria are not staking-based.
- `MAX_DAILY_WELCOME_BONUSES = 1000` rate-limits Sybil attacks.
- Per-user tracking (`welcomeBonusClaimed[user]`) prevents double claims.
- Decreasing bonus schedule (higher bonuses for earlier users) is based on total claims count, not the claimant's balance.

**Impact:** Zero. Bonus qualification is KYC-based, not balance-based.

#### Sub-Vector 8b: OmniValidatorRewards Epoch Reward Inflation

**Attack:** Flash-loan XOM, stake to become a validator, process an epoch to claim validator rewards, unstake, and repay.

**Why it fails:**
- **Validator qualification requires `canBeValidator()` from OmniParticipation** -- which checks participation score (minimum 50 points), KYC level 4, and minimum stake of 1,000,000 XOM.
- Even if the attacker could meet the staking requirement via flash loan, the KYC and participation score requirements cannot be met in a single transaction.
- **Epoch processing is restricted to `BLOCKCHAIN_ROLE`** (M-07 fix): Only authorized validators can call `processEpoch()`. An attacker cannot self-process an epoch.
- **`processEpoch()` iterates active nodes from Bootstrap.sol:** The attacker would need to be registered as an active node, which requires being authorized by existing validators.
- **Heartbeat requirement:** `OmniValidatorRewards.recordHeartbeat()` must be called regularly to maintain activity score. A flash-loan attacker has no time to build heartbeat history.
- **Lock expiry check for flash-stake protection:** The validator rewards contract checks that the validator's stake lock has not expired within the current epoch.
- **Sequential epoch enforcement:** Epochs must be processed in order with no gaps. An attacker cannot skip to a favorable epoch.
- **Batch cap (50 epochs per call):** Limits the rewards claimable per transaction.

**Impact:** Zero. The multi-factor qualification (KYC, participation score, node registration, heartbeat history) makes flash-loan validator gaming impossible.

#### Sub-Vector 8c: StakingRewardPool APR Tier Exploitation

**Attack:** Flash-loan XOM, stake at Tier 5 (1B+ XOM, 9% APR) with duration Tier 3 (2 years, +3% bonus) for maximum 12% APR, claim rewards, unstake.

**Why it fails:**
- **`MIN_STAKE_AGE = 1 days`:** StakingRewardPool returns 0 rewards for any stake younger than 24 hours. Flash loans are repaid within the same block (2 seconds).
- **Duration lock enforcement:** `duration = 730 days` means the XOM is locked for 2 years. The attacker cannot unstake to repay the flash loan.
- **Even with `duration = 0`:** The 24-hour minimum stake age prevents same-transaction reward extraction.
- **Tier clamping (`_clampTier()`):** Validates the declared tier against the actual staked amount. The attacker must actually stake 1B+ XOM to claim Tier 5.

**Impact:** Zero. The `MIN_STAKE_AGE` completely blocks flash-loan reward extraction.

#### Sub-Vector 8d: Cross-Contract Reward Double-Counting

**Attack:** Use the same XOM tokens to earn rewards from both StakingRewardPool (staking rewards) and LiquidityMining (LP mining rewards) simultaneously.

**Analysis:**
- StakingRewardPool rewards are based on XOM staked in OmniCore.
- LiquidityMining rewards are based on LP tokens staked in LiquidityMining.
- These are different token types (XOM vs. LP tokens). The same XOM cannot be staked in OmniCore AND used as an LP token simultaneously.
- However, XOM staked in OmniCore can also participate in governance voting (OmniGovernance). This is intentional -- staking power confers voting power.
- XOM used in an AMM LP position earns LiquidityMining rewards. The user gives up direct XOM staking rewards but gains LP mining rewards. This is a normal DeFi trade-off.

**Impact:** No double-counting vulnerability exists. Different reward systems use different staking mechanisms with different token types.

---

## Mitigations Already Present

The following table summarizes the flash loan defenses already implemented across the contract suite:

| Defense Mechanism | Contract(s) | Protection Type | Effectiveness |
|-------------------|-------------|----------------|---------------|
| `MIN_STAKE_AGE = 1 days` | StakingRewardPool | Time-based | Blocks flash-stake reward extraction |
| `VOTING_DELAY = 1 days` | OmniGovernance | Time-based | Blocks flash-loan governance manipulation |
| ERC20Votes checkpoints | OmniCoin | Snapshot-based | Historical voting power, not current balance |
| `getStakedAt()` checkpoints | OmniCore | Snapshot-based | Historical staking data for governance |
| Cumulative purchase tracking | LiquidityBootstrappingPool | Per-address cap | Prevents splitting flash loans across txs |
| `MAX_OUT_RATIO = 30%` | LiquidityBootstrappingPool | Per-swap cap | Limits single-swap pool extraction |
| Unidirectional swaps | LiquidityBootstrappingPool | Design | No sell side for sandwich back-run |
| Vesting (1-30 days) | OmniBonding | Time-based | Delays XOM receipt, adds market risk |
| Daily capacity limits | OmniBonding | Per-day cap | Limits daily bonding volume |
| Fixed price (no oracle) | OmniBonding | Design | Not manipulable via flash loans |
| 70% vesting / 30% immediate | LiquidityMining | Partial delay | Reduces immediate extractable value |
| `PRICE_COOLDOWN = 6 hours` | OmniBonding | Time-based | Limits price change frequency |
| `MAX_PRICE_CHANGE_BPS = 10%` | OmniBonding | Rate limit | Bounds single price changes |
| EIP-712 signed prices | DEXSettlement | Pre-commitment | Prices signed off-chain, not oracle-based |
| Commit-reveal (optional) | DEXSettlement | MEV protection | Pre-commitment of order hashes |
| `nonReentrant` on all contracts | All 8 contracts | Reentrancy guard | Blocks direct reentrancy |
| SafeERC20 | All 8 contracts | Safe transfers | Prevents transfer-related reentrancy tricks |
| Fee-on-transfer detection | LBP, OmniSwapRouter, LiquidityMining, OmniBonding | Balance checks | Prevents accounting manipulation |
| KYC + participation score | OmniRewardManager, OmniValidatorRewards | Off-chain verification | Blocks Sybil reward gaming |
| `BLOCKCHAIN_ROLE` restriction | OmniValidatorRewards | Access control | Only authorized validators process epochs |
| Per-user welcome bonus tracking | OmniRewardManager | One-time caps | Prevents double-claiming |
| Daily bonus rate limiting | OmniRewardManager | Rate limit | Blocks mass Sybil bonus claims |
| Solvency tracking | OmniBonding (`totalXomOutstanding`), LiquidityMining (`totalCommittedRewards`) | Invariant | Prevents over-distribution |

---

## Recommended Fixes (Priority Order)

### Priority 1 -- MUST FIX Before Mainnet

| ID | Contract | Fix | Effort |
|----|----------|-----|--------|
| ATK-01 | LiquidityMining | Add `MIN_STAKE_DURATION = 1 hours` to prevent flash-stake reward extraction | Low (5 lines) |
| DEX-H01 | DEXSettlement | Move `filledOrders`, nonce, and volume state updates before `_executeAtomicSettlement()` in `settleTrade()` (CEI fix) | Low (reorder lines) |

### Priority 2 -- SHOULD FIX Before Public Launch

| ID | Contract | Fix | Effort |
|----|----------|-----|--------|
| ATK-05 | OmniBonding | Add bond cooldown after price changes (1 hour) OR enforce pause-before-price-change operationally | Low (3 lines) |
| SR-H01 | OmniSwapRouter | Reset adapter approvals to zero after each swap hop | Low (1 line per hop) |
| SR-H02 | OmniSwapRouter | Add balance-before/after verification for output tokens per hop | Medium (10 lines) |
| DEX-H02 | DEXSettlement | Fix cross-token rebate calculation in `settleIntent()` (compute rebate on same token as fee) | Low (2 lines) |

### Priority 3 -- Operational Recommendations

| ID | Action | Contracts Affected |
|----|--------|-------------------|
| OPS-01 | Deploy all owner-controlled contracts (OmniBonding, LBP, LiquidityMining) with Gnosis Safe multisig owners | All |
| OPS-02 | Document the "no on-chain oracle" design as a security feature | Architecture docs |
| OPS-03 | Monitor for LiquidityMining pool sniping (first staker in empty pools) | LiquidityMining |
| OPS-04 | Do NOT register LBP as an OmniSwapRouter adapter | OmniSwapRouter, LBP |
| OPS-05 | Use pause-then-price-change-then-unpause pattern for OmniBonding price updates | OmniBonding |

---

## Conclusion

The OmniBazaar smart contract protocol demonstrates a mature understanding of flash loan attack vectors and has implemented effective defenses across the contract suite. The key architectural decisions that provide systemic flash loan resistance are:

1. **Time-based minimum stake ages** (StakingRewardPool's 24-hour minimum) that are incompatible with same-block flash loans.
2. **Checkpoint-based governance snapshots** (ERC20Votes + OmniCore's `getStakedAt()`) that use historical data rather than current balances.
3. **Fixed pricing without on-chain oracles** (OmniBonding) that eliminates the most common DeFi flash loan attack surface.
4. **Pre-signed order prices** (DEXSettlement) that prevent flash-loan price manipulation of settlement amounts.
5. **Cumulative per-address tracking** (LBP) that prevents splitting flash-loaned amounts across transactions.

The single actionable finding is **ATK-01 (LiquidityMining flash-stake)**, which requires adding a minimum staking duration. This is a straightforward fix that follows the pattern already established by StakingRewardPool. The remaining findings (ATK-03 OmniSwapRouter adapter trust, ATK-05 OmniBonding front-running) have operational mitigations available and are lower severity.

**No critical cross-contract flash loan vulnerabilities exist in the current protocol.**

The protocol's ultra-lean blockchain design -- with most business logic handled off-chain by validators and only settlement/token transfers on-chain -- naturally limits the flash loan attack surface by reducing the amount of state that can be manipulated in a single atomic transaction.

---

*Generated by Claude Code Audit Agent -- Phase 2 Pre-Mainnet Cross-Contract Analysis*
*Contracts analyzed: OmniCoin.sol, OmniCore.sol, StakingRewardPool.sol, DEXSettlement.sol, OmniSwapRouter.sol, LiquidityBootstrappingPool.sol, LiquidityMining.sol, OmniBonding.sol + OmniGovernance.sol, OmniRewardManager.sol, OmniValidatorRewards.sol*
*Individual audit reports referenced: 8 Round 6 reports (2026-03-10)*
*Analysis date: 2026-03-10 01:18 UTC*
