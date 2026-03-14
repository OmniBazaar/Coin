# Cross-System Adversarial Review: Flash Loan Attacks

**Audit Round:** 7 (Cross-System)
**Date:** 2026-03-13
**Auditor:** Claude Opus 4.6
**Scope:** Cross-contract flash loan exploit chains across 10+ contracts
**Methodology:** Manual adversarial review with cross-contract attack path analysis (no automated tooling)

---

## Contracts Analyzed

| # | Contract | Path | Lines | Read Depth |
|---|----------|------|-------|------------|
| 1 | OmniCoin.sol | `contracts/OmniCoin.sol` | -- | Flash capability grep |
| 2 | DEXSettlement.sol | `contracts/dex/DEXSettlement.sol` | 2191 | Full |
| 3 | OmniSwapRouter.sol | `contracts/dex/OmniSwapRouter.sol` | 730 | Full |
| 4 | OmniBonding.sol | `contracts/liquidity/OmniBonding.sol` | 1204 | Full |
| 5 | LiquidityBootstrappingPool.sol | `contracts/liquidity/LiquidityBootstrappingPool.sol` | 946 | Full |
| 6 | LiquidityMining.sol | `contracts/liquidity/LiquidityMining.sol` | 1243 | Full |
| 7 | StakingRewardPool.sol | `contracts/StakingRewardPool.sol` | 1149 | Full |
| 8 | OmniGovernance.sol | `contracts/OmniGovernance.sol` | -- | Targeted (voting, staking) |
| 9 | RWAAMM.sol | `contracts/rwa/RWAAMM.sol` | 1221 | Full |
| 10 | OmniPriceOracle.sol | `contracts/oracle/OmniPriceOracle.sol` | 1538 | Full |
| 11 | RWAPool.sol | `contracts/rwa/RWAPool.sol` | -- | Targeted (flash swap) |
| 12 | OmniCore.sol | `contracts/OmniCore.sol` | -- | Targeted (stake/getStakedAt) |
| 13 | OmniValidatorRewards.sol | `contracts/OmniValidatorRewards.sol` | -- | Targeted (staking component) |

---

## Executive Summary

The OmniBazaar smart contract suite demonstrates **strong flash loan resilience** across all analyzed contracts. Previous audit rounds (particularly Round 6 and the ATK rounds) have already addressed the most critical flash loan vectors. The system's architecture -- where oracle prices are determined by multi-validator consensus rather than on-chain pool state, where governance uses checkpoint-based snapshot voting (including staked power via ATK-H02), and where staking/mining enforce minimum time commitments -- creates a defense-in-depth posture that makes flash loan attacks economically infeasible.

**Overall Flash Loan Risk: LOW**

No critical or high-severity flash loan vulnerabilities were identified. Two medium-severity observations, one low-severity item, and two informational items are documented below.

---

## 1. Flash Loan Sources Analysis

### 1.1 Internal Flash Loan Sources

**OmniCoin.sol (XOM Token)**
- **No ERC-3156 flash loan/flash mint functionality.** Confirmed via grep search: no `flashLoan`, `flashMint`, `IERC3156FlashLender`, or `IERC3156FlashBorrower` references exist.
- **No custom flash loan mechanism** of any kind.
- **Assessment:** The protocol does not provide any internal flash loan capability. This is a strong defensive posture.

**RWAPool.sol**
- Flash swaps were **explicitly disabled** (audit fix H-02, Round 6).
- The `FlashSwapsDisabled()` custom error is thrown if `data.length > 0` is passed to the swap function (line 389).
- **Rationale documented in code:** Flash swaps transfer tokens before callback, which is incompatible with RWA compliance checks.
- **Assessment:** Correctly disabled. No bypass path found.

**RWAAMM.sol**
- Factory pattern for creating RWAPool instances. Pools inherit the flash swap disabled status.
- No independent flash loan mechanism.
- **Assessment:** Clean.

### 1.2 External Flash Loan Sources (Attack Vectors)

An attacker can obtain temporary large positions from:

| Source | Max Available | Tokens | Cost |
|--------|--------------|--------|------|
| Aave V3 (Avalanche) | ~$2B+ TVL | USDC, USDT, WETH, WBTC, AVAX | 0.05% fee |
| dYdX | ~$500M+ | USDC, ETH, DAI | 0 fee (deprecated v3) |
| Balancer V2 | ~$1B+ | Most ERC-20 | 0% fee |
| Uniswap V3 Flash Swaps | Pool-dependent | Any pool pair | Swap fee |

**Critical Note:** While OmniCoin itself has no flash loans, any ERC-20 token used as a bond asset (OmniBonding), counter-asset (LBP), or LP token (LiquidityMining) can be flash-borrowed from external protocols. The XOM token itself may also be available on external DEXs once trading begins.

---

## 2. Price Manipulation Vectors

### 2.1 OmniPriceOracle Resilience Assessment

The OmniPriceOracle has **exemplary multi-layer protection**:

1. **Multi-validator consensus** -- Minimum 5 validators must submit prices, median is used
2. **Minimum 3 sources** per validator submission (Round 6 fix)
3. **Circuit breaker** -- 10% maximum single-round change (`MAX_PRICE_CHANGE_BPS = 1000`)
4. **Cumulative deviation** -- 20% maximum deviation from anchor per hour (`MAX_CUMULATIVE_DEVIATION_BPS = 2000`)
5. **TWAP** -- 1-hour rolling window smooths volatility
6. **Chainlink fallback** -- If median deviates >10% from Chainlink, oracle pauses
7. **Validator suspension** -- After 100 cumulative violations

**Assessment:** The oracle is extremely resistant to manipulation. An attacker would need to compromise 3+ of 5+ validators simultaneously OR manipulate the Chainlink reference feed. Flash-borrowed tokens cannot make an EOA a validator (requires staking, KYC, and participation scoring), so oracle prices are inaccessible to flash loan attacks.

### 2.2 DEXSettlement Price Independence

DEXSettlement uses **intent-based settlement with EIP-712 signed orders**. Prices are specified by the maker and taker in their signed orders -- the oracle is NOT consulted during trade settlement. `_checkSlippage()` (line 1870) enforces `maxSlippageBps` between maker/taker order price ratios, not against any external price reference.

**Assessment:** DEXSettlement is inherently flash-loan-resistant for price manipulation because trade prices are cryptographically signed by both parties before settlement.

### 2.3 OmniBonding Fixed Price Model

OmniBonding uses `fixedXomPrice` (admin-set via `setXomPrice()`), NOT any on-chain oracle or pool price (confirmed at line 1045: `return fixedXomPrice`). The `priceOracle` state variable exists (line 163) but is currently unused in the `getXomPrice()` function.

**Protections:**
- `PRICE_COOLDOWN = 6 hours` between admin price updates (line 150)
- `MAX_PRICE_CHANGE_BPS = 1000` (10% max per update, line 137)
- Price bounded by `MIN_XOM_PRICE` and `MAX_XOM_PRICE`
- Vesting period (1-30 days) prevents same-tx extraction

**Assessment:** Flash loans cannot manipulate the bonding price because it is admin-set. The vesting period prevents same-transaction arbitrage. Front-running admin price updates is a separate MEV concern (documented as M-02 Round 6) but requires no flash loan capability.

### 2.4 LBP Spot Price Isolation

The LBP's `getSpotPrice()` is a public view function derived from pool reserves and weights. This price IS manipulable by large purchases (inherent AMM property). However, **no other contract in the ecosystem reads from the LBP spot price**:

- DEXSettlement: uses signed order prices (not oracle)
- OmniPriceOracle: uses validator submissions (not pool prices)
- OmniBonding: uses `fixedXomPrice` (admin-set)
- RWAAMM: uses own pool reserves (independent)

**Assessment:** LBP price manipulation is self-contained and cannot propagate to other contracts.

---

## 3. Cross-Contract Arbitrage Chains

### 3.1 RWAAMM Pool Manipulation -> DEXSettlement Arbitrage

```
Attack:
1. Flash-borrow large amount of Token A
2. Swap Token A -> Token B in RWAAMM (moves pool price)
3. Settle a pre-signed DEXSettlement order at the old (better) price
4. Swap Token B -> Token A in RWAAMM (restore price)
5. Repay flash loan, keep the difference
```

**Feasibility: NOT FEASIBLE**
- DEXSettlement uses signed orders with predetermined amounts (`amountIn`, `amountOut`), not pool prices
- The signed order's price is fixed at signing time; RWAAMM manipulation does not change it
- Furthermore, RWAAMM flash swaps are disabled (`FlashSwapsDisabled`)

### 3.2 LBP Price Pump -> OmniSwapRouter Arbitrage

```
Attack:
1. Flash-borrow counter-asset (USDC)
2. Buy XOM from LBP (pushes LBP price up)
3. Sell XOM via OmniSwapRouter through a different adapter at higher price
4. Repay flash loan
```

**Feasibility: LOW (self-arbitrage, not exploit)**
- This is standard cross-venue arbitrage, not an exploit
- LBP's MAX_OUT_RATIO (30%) limits how much XOM can be extracted per swap
- The 0.30% LBP swap fee + OmniSwapRouter's 0.30% default fee = 0.60% total friction
- Net result: the attacker provides useful price arbitrage (equalizing prices across venues)

### 3.3 Oracle Manipulation -> Bonding Arbitrage

```
Attack:
1. Flash-borrow XOM
2. Manipulate OmniPriceOracle to show low XOM price
3. Bond at discounted rate (buying cheap XOM)
4. Repay flash loan
```

**Feasibility: NOT FEASIBLE**
- OmniPriceOracle requires validator status to submit prices (not token-holding-based)
- OmniBonding uses `fixedXomPrice` (admin-set), NOT OmniPriceOracle
- Even if oracle were manipulable, bonding does not read from it
- Vesting period (1-30 days) prevents same-tx claiming

---

## 4. Collateral Manipulation Vectors

### 4.1 Governance Vote Inflation via Flash Loans

**Question:** Can flash loans inflate voting power in OmniGovernance?

**OmniGovernance Voting Power Computation:**

The `_castVote()` function (line 850) uses `getVotingPowerAt(voter, proposal.snapshotBlock)` (line 866), which calls:

1. `omniCoin.getPastVotes(account, blockNumber)` -- ERC20Votes checkpoint-based historical lookup
2. `_getStakedAmountAt(account, blockNumber)` -- OmniCore checkpoint-based historical lookup (ATK-H02 fix)

```solidity
// _castVote (line 866)
uint256 weight = getVotingPowerAt(voter, proposal.snapshotBlock);
```

```solidity
// getVotingPowerAt (line 718-727)
function getVotingPowerAt(address account, uint256 blockNumber) public view returns (uint256) {
    uint256 delegatedPower = omniCoin.getPastVotes(account, blockNumber);
    uint256 stakedPower = _getStakedAmountAt(account, blockNumber);
    return delegatedPower + stakedPower;
}
```

```solidity
// _getStakedAmountAt (line 1008-1029) -- ATK-H02 fix
function _getStakedAmountAt(address account, uint256 blockNumber) internal view returns (uint256 amount) {
    (bool success, bytes memory data) = omniCore.staticcall(
        abi.encodeWithSignature("getStakedAt(address,uint256)", account, blockNumber)
    );
    if (success && data.length > 0) {
        return abi.decode(data, (uint256));
    }
    // ATK-H02: No fallback to current balance
    return 0;
}
```

OmniCore's `getStakedAt()` (line 1181-1188) uses `_stakeCheckpoints[user].upperLookup(blockNumber)` with OpenZeppelin's `Checkpoints.Trace224`.

**Attack Path Analysis:**

*Path A: Flash borrow -> self-delegate -> create proposal -> vote -> repay*
- Fails: `VOTING_DELAY = 1 days` means voting is not active when the tx executes
- After repaying flash loan, `_moveDelegateVotes` reduces checkpoint to 0

*Path B: Flash borrow -> stake in OmniCore -> vote on existing proposal -> repay*
- Fails: `getStakedAt(account, proposal.snapshotBlock)` returns the staked amount at the **proposal's snapshot block**, which was before the current tx
- The attacker's staked amount at that past block was 0

*Path C: Front-run proposal creation*
- Works without flash loans (standard governance timing issue, not flash loan attack)
- VOTING_DELAY of 1 day gives community time to detect

**Verdict: NOT FEASIBLE**

The ATK-H02 fix (removing fallback to current staking amount) was critical. Both components of voting power use historical checkpoints, making flash loan vote inflation impossible.

### 4.2 DEXSettlement Intent Collateral

The intent-based settlement uses `lockIntentCollateral()` / `settleIntent()` with actual token escrow. Flash-loaned tokens can be locked as collateral, but settlement requires a validator signature AND the collateral is held by the contract. The attacker cannot repay the flash loan AND keep the collateral locked simultaneously. **Not exploitable.**

---

## 5. Reward Gaming Vectors

### 5.1 StakingRewardPool Flash-Stake (MITIGATED)

**Prior Vulnerability (ATK-H01):** Flash-loan XOM, stake, claim rewards, unstake, repay.

**Defenses:**
- `MIN_STAKE_AGE = 1 days` (line 189): 24-hour minimum before claiming
- `duration = 0` returns zero rewards (M-02 R6, line 948)
- `MAX_CLAIM_PER_TX = 1_000_000e18` per claim
- `_clampTier()` validation (H-07)
- OmniCore's `stake()` requires canonical lock durations (0, 30d, 180d, 730d); duration 0 earns 0 rewards

```solidity
// _calculateRewards (line 943+)
if (stakeData.duration == 0) return 0;           // M-02 R6
if (stakeData.lockTime < stakeData.duration) return 0;
uint256 stakeStart = stakeData.lockTime - stakeData.duration;
if (stakeStart + MIN_STAKE_AGE > block.timestamp) return 0;  // ATK-H01
```

**Verdict: NOT FEASIBLE** -- Flash-staked tokens with `duration=0` earn zero; any other duration locks tokens for 30+ days.

### 5.2 LiquidityMining Flash-Stake (MITIGATED)

**Prior Vulnerability (H-01 Round 6):** Flash-borrow LP tokens, stake, accrue rewards, unstake.

**Defenses:**
- `MIN_STAKE_DURATION = 1 days` (line 140): 24-hour minimum before withdrawal
- Withdrawal check (line 586-591): `block.timestamp < stakeTimestamp + MIN_STAKE_DURATION` reverts
- Split rewards: 30% immediate, 70% vested over 90 days
- `MAX_REWARD_PER_SECOND` cap

**Verdict: NOT FEASIBLE** -- `MIN_STAKE_DURATION` prevents same-tx withdrawal; flash loan repayment fails.

### 5.3 OmniValidatorRewards Flash-Stake (MITIGATED)

**Prior Vulnerability (H-01 Round 1):** Inflating validator weight via flash-staking.

**Defense:** `_calculateStakingComponent()` (line 2255) checks `stake.lockTime < block.timestamp + 1` (line 2275). Expired or near-expiry locks return 0 staking component. Flash-staked tokens would have immediate/near-immediate lock expiry.

**Verdict: NOT FEASIBLE**

### 5.4 OmniBonding Reward Gaming

**Attack:** Flash-borrow stablecoins, bond at discount, claim XOM, sell, repay.

**Defense:** Vesting period (1-30 days) prevents same-tx claiming. `ActiveBondExists` prevents stacking on same address+asset. Daily capacity limits.

**Verdict: NOT FEASIBLE** for flash loans. Economic sybil risk (multiple addresses with borrowed funds) is separate.

---

## 6. Multi-Step Exploit Chains (3+ Steps)

### Chain A: Governance Proposal -> Emergency Action (4 steps)

```
1. Flash-borrow XOM
2. Create governance proposal for malicious action
3. Fast-track vote
4. Execute malicious proposal, repay
```

**Feasibility: NOT FEASIBLE**
- VOTING_DELAY = 1 day; VOTING_PERIOD = 5 days; plus timelock
- Minimum 6+ days from proposal to execution
- Cannot hold flash-loaned tokens for 6+ days
- PROPOSAL_THRESHOLD = 10,000 XOM (low enough that flash loans are unnecessary to propose)
- QUORUM_BPS = 400 (4% of total supply = ~664M XOM must vote)

### Chain B: LBP Manipulation + External DEX Arbitrage (3 steps)

```
1. Flash-borrow large counterAsset from Aave
2. Buy XOM from LBP at discount (pushing price up)
3. Sell XOM on external DEX at market price, repay
```

**Feasibility: LOW (beneficial arbitrage, not exploit)**
- MAX_OUT_RATIO (30%) limits per-swap extraction from LBP
- Cumulative tracking limits total per-address purchases
- 0.60% round-trip fees (LBP 0.30% + external DEX fees)
- Price floor prevents buying below minimum
- This IS the intended LBP mechanism (Dutch auction price discovery)
- Net effect: price equalization across venues (beneficial)

### Chain C: Multi-Pool Arbitrage via OmniSwapRouter (3 steps)

```
1. Flash-borrow Token A from Aave
2. Multi-hop swap through OmniSwapRouter:
   Token A -> Pool 1 (RWAAMM) -> Token B -> Pool 2 (adapter) -> Token A
3. Repay flash loan, keep profit
```

**Feasibility: LOW (standard MEV)**
- 0.30% fee per OmniSwapRouter swap + pool fees
- Per-hop balance verification prevents adapter manipulation
- RWAAMM constant-product formula increases slippage on large trades
- This is expected market behavior, not a contract vulnerability

### Chain D: LiquidityMining Temporary Dilution (3 steps)

```
1. Flash-borrow large amount of LP tokens from external protocol
2. Stake in LiquidityMining (dilutes existing stakers' reward share)
3. After MIN_STAKE_DURATION (1 day), withdraw LP tokens and repay
```

**Feasibility: PARTIALLY FEASIBLE (grief only, no profit)**
- Step 2 succeeds: staking is instant
- Step 3 cannot happen in same tx (`MIN_STAKE_DURATION = 1 days`)
- Attacker must borrow from lending protocol (not flash loan) for 1+ day
- During lockup, existing stakers receive diluted rewards
- Attacker's cost: interest on LP tokens for 1 day + gas
- Impact: proportional dilution for 1 day

**This is not a flash loan attack** (requires multi-day capital commitment) but is noted as a funded dilution vector.

### Chain E: Cross-Protocol LP Token Value Inflation (5 steps)

```
1. Flash-borrow large TokenA and TokenB
2. Add liquidity to RWAAMM pool, receive LP tokens
3. Stake LP tokens in LiquidityMining
4. Manipulate underlying pool to inflate LP token value
5. Claim inflated rewards, unstake, remove liquidity, repay
```

**Feasibility: NOT FEASIBLE**
- LiquidityMining rewards are based on LP token COUNT (shares), not VALUE
- `MIN_STAKE_DURATION = 1 day` prevents same-tx withdrawal
- Even if LP token value is inflated, reward calculation uses `accRewardPerShare` which is amount-based

### Chain F: OmniSwapRouter Sandwich (3 steps)

```
1. Flash-borrow Token A, front-run victim's swap
2. Execute large swap that moves price unfavorably for victim
3. Back-run victim's swap with reverse trade, repay
```

**Feasibility: NOT FEASIBLE as single-tx attack**
- Victim's `minAmountOut` parameter protects against slippage
- DEXSettlement's commit-reveal mechanism protects against mempool-based front-running
- Standard MEV issue, not a contract vulnerability

---

## Findings Summary

### Severity Ratings

| ID | Severity | Vector | Status |
|----|----------|--------|--------|
| FL-M-01 | Medium | LiquidityMining temporary dilution via borrowed (not flash-loaned) LP tokens | Open (Informational) |
| FL-M-02 | Medium | LBP cumulative tracking bypassable with multiple addresses | Open (Design Trade-off) |
| FL-L-01 | Low | OmniSwapRouter adapter trust boundary -- compromised owner can add malicious adapter | Open (Owner Trust) |
| FL-I-01 | Informational | OmniCoin has no ERC-3156 flash loan/mint capability (positive) | N/A |
| FL-I-02 | Informational | Cross-venue arbitrage via LBP/OmniSwapRouter is beneficial, not harmful | N/A |

---

### FL-M-01: LiquidityMining Temporary Reward Dilution

**Contracts:** LiquidityMining.sol
**Severity:** Medium
**Impact:** Low (grief only, no profit extraction for attacker)

**Description:**
An attacker can borrow LP tokens from a lending protocol (NOT flash loan -- requires multi-day commitment), stake them in LiquidityMining, and lock them for the `MIN_STAKE_DURATION` (1 day). During this window, existing stakers' rewards are diluted proportionally to the attacker's inflated share of the pool.

**Economic Analysis:**
- If pool has 1M LP tokens staked and attacker stakes 9M, existing stakers earn 10% of normal rate for 1 day
- Attacker earns 90% of 1 day's rewards but has 9M LP tokens locked (interest cost)
- The attacker's profit from 1 day of diluted rewards is likely less than the borrowing cost

**Recommendation:**
- Consider a progressive weight increase for new stakes (e.g., linear ramp over 24 hours from 0% to 100% weight)
- This would make dilution more expensive for short-term stakes
- **Note:** This is a known property of share-based reward systems. The MIN_STAKE_DURATION already makes it significantly more expensive than a single-block flash attack.

### FL-M-02: LBP Per-Address Cumulative Tracking Bypass

**Contracts:** LiquidityBootstrappingPool.sol
**Severity:** Medium
**Impact:** Low (limited by MAX_OUT_RATIO per swap)

**Description:**
The LBP tracks cumulative purchases per address (`cumulativePurchases[buyer]`, line 148) to enforce anti-whale limits (M-02 fix). However, an attacker can use multiple Ethereum addresses to bypass this per-address tracking. Each address can purchase up to the cumulative limit independently.

**Mitigating Factors:**
- `MAX_OUT_RATIO = 3000` (30%) limits single-swap impact regardless of address count
- Each swap pays 0.30% fee, making multi-address strategies expensive
- Price floor prevents crashing below minimum
- LBP is a temporary mechanism (time-bounded Dutch auction)
- KYC requirements (if enforced at the application layer) can limit this

**Recommendation:**
- This is a known limitation of on-chain per-address tracking
- Consider implementing a global per-block or per-hour purchase rate limit
- For the LBP's temporary nature, existing protections are adequate

### FL-L-01: OmniSwapRouter Adapter Trust Boundary

**Contracts:** OmniSwapRouter.sol
**Severity:** Low
**Impact:** Medium (if owner key compromised)

**Description:**
The OmniSwapRouter delegates swap execution to registered `ISwapAdapter` contracts. While `addLiquiditySource()` validates `adapter.code.length > 0` (H-03 fix), there is no interface verification, timelock on activation, or bytecode hash validation. An attacker who compromises the owner key could instantly register a malicious adapter.

**Mitigating Factors:**
- Only `onlyOwner` can add adapters
- Balance-before/after checks in the router verify ACTUAL tokens received (adapter cannot fake transfers)
- Per-hop balance verification prevents accounting manipulation

**Remaining Risk:**
A malicious adapter could still:
- Perform unauthorized swaps in third-party pools
- Front-run user swaps by inserting MEV transactions
- Provide unfavorable `getAmountOut()` quotes to extract slippage value

**Recommendation:**
- Add a timelock delay between adapter registration and activation (e.g., 24-48 hours)
- Consider adapter-level pause functionality
- Add adapter bytecode hash verification for known-good implementations

---

## Defense Architecture Assessment

### Systematic Flash Loan Defenses by Contract

| Contract | Defense Mechanism | Effectiveness |
|----------|-------------------|---------------|
| OmniCoin | No flash mint/loan capability (no ERC-3156) | Tokens must be borrowed from external protocols |
| OmniPriceOracle | Validator-gated submission + multi-consensus + TWAP + circuit breaker | Flash loans cannot influence oracle prices |
| OmniGovernance | ERC20Votes checkpoints + 1-day VOTING_DELAY + ATK-H02 staking checkpoint | Flash loans cannot inflate votes |
| DEXSettlement | Intent-based signed orders + commit-reveal MEV protection | Flash loans cannot manipulate settlement prices |
| OmniSwapRouter | Balance-before/after + per-hop verification + minAmountOut | Standard user-facing protection |
| OmniBonding | Admin-set fixedXomPrice + 6h cooldown + vesting (1-30d) | Flash loans cannot influence bond pricing or claim |
| LiquidityBootstrappingPool | MAX_OUT_RATIO 30% + price floor + cumulative tracking | Limits manipulation scope per swap |
| LiquidityMining | MIN_STAKE_DURATION 1 day + 30/70 vesting split | Flash-borrowed LP tokens locked for 1 day |
| StakingRewardPool | MIN_STAKE_AGE 1 day + duration=0 denial + tier clamping | Zero rewards for flash-staked tokens |
| RWAAMM | Flash swaps disabled (H-02) + compliance oracle | No flash swap capability |
| OmniValidatorRewards | Lock expiry check + try/catch resilience | Expired locks get 0 staking component |
| OmniCore | Lock time enforcement + checkpoint tracking | Time-gated unstaking + historical snapshots |

### Cross-Contract Isolation Analysis

The contracts are well-isolated against cross-contract flash loan chains:

1. **DEXSettlement** does not read from OmniPriceOracle for settlement prices
2. **OmniBonding** uses `fixedXomPrice` (admin-set), not any on-chain pool price
3. **LBP** spot price is self-contained and not consumed by other contracts
4. **RWAAMM** pool prices are independent of OmniPriceOracle
5. **OmniGovernance** uses historical checkpoints for BOTH delegated AND staked power
6. **StakingRewardPool** enforces 24-hour minimum age before reward claiming
7. **LiquidityMining** enforces 24-hour minimum stake duration before withdrawal
8. **OmniValidatorRewards** requires unexpired stake locks for weight calculation

This isolation means that even if one contract's state could be temporarily manipulated, the manipulation does not propagate to other contracts within the same transaction.

### Flash Loan Resistance Scorecard

| Contract | Score | Key Defense |
|----------|-------|-------------|
| OmniCoin.sol | 10/10 | No flash loan/mint capability |
| OmniPriceOracle.sol | 10/10 | Multi-validator consensus, TWAP, circuit breaker |
| RWAPool.sol | 10/10 | Flash swaps explicitly disabled (H-02) |
| DEXSettlement.sol | 9/10 | Commit-reveal, volume limits, validator signatures |
| StakingRewardPool.sol | 9/10 | MIN_STAKE_AGE 24h, duration=0 denial |
| LiquidityMining.sol | 9/10 | MIN_STAKE_DURATION 1 day, vested rewards |
| OmniValidatorRewards.sol | 9/10 | Lock expiry check, try/catch resilience |
| OmniGovernance.sol | 9/10 | Checkpoints for both delegated AND staked power (ATK-H02) |
| OmniSwapRouter.sol | 8/10 | Balance-before/after, per-hop checks, fees |
| OmniCore.sol | 8/10 | Lock time enforcement, checkpoint tracking |
| LiquidityBootstrappingPool.sol | 8/10 | MAX_OUT_RATIO, cumulative tracking, price floor |
| RWAAMM.sol | 8/10 | Flash swaps disabled, constant-product formula |
| OmniBonding.sol | 8/10 | Vesting prevents same-tx extraction, admin-set price |

**Overall Ecosystem Score: 8.8/10**

---

## Positive Security Observations

1. **No native flash loan/mint capability:** OmniCoin.sol does not implement ERC-3156 or any flash mint mechanism. Attackers must source flash loans from external protocols, which adds friction and limits available XOM liquidity.

2. **ATK-H02 fix was critical:** The removal of the fallback to current staking amount in OmniGovernance's `_getStakedAmountAt()` closed what would have been the most dangerous flash loan vector in the system. The function now uses OmniCore's `getStakedAt()` with `Checkpoints.Trace224` for historical lookups, returning 0 if unavailable.

3. **Multi-validator oracle is flash-resistant by design:** The requirement for 5+ independent validators to submit prices before finalization, combined with TWAP, circuit breakers, and Chainlink bounds, makes the oracle inherently resistant to any single-actor manipulation.

4. **Time-based defenses are consistent:** StakingRewardPool (24h MIN_STAKE_AGE), LiquidityMining (24h MIN_STAKE_DURATION), and OmniValidatorRewards (lock expiry check) all use consistent time-based defenses that block same-transaction flash loan attacks.

5. **RWAPool flash swap disabled:** Explicitly blocking flash swaps in the compliance-sensitive RWA system prevents a category of regulatory-risk attacks.

6. **Intent-based settlement is inherently flash-resistant:** DEXSettlement's use of pre-signed orders with embedded prices means flash loan price manipulation cannot affect settlement execution.

---

## Recommendations

### No Immediate Action Required

The existing defenses are adequate for all analyzed flash loan vectors. The following are enhancement recommendations for defense-in-depth:

1. **LiquidityMining progressive weight ramp** (FL-M-01): Consider implementing a linear weight increase for new stakes over 24 hours. This would reduce the dilution impact of large same-day stakes without affecting legitimate long-term stakers.

2. **Global purchase rate limit for LBP** (FL-M-02): Consider adding a per-block or per-hour global purchase limit in addition to per-address tracking, to limit the rate at which XOM can be extracted regardless of address count.

3. **OmniSwapRouter adapter timelock** (FL-L-01): Add a delay between adapter registration and activation to prevent instant deployment of malicious adapters if the owner key is compromised.

4. **Monitor external flash loan providers:** As the XOM token gains liquidity on external protocols, the available flash loan volume will increase. Regularly reassess the economic viability of flash loan attacks as liquidity grows.

5. **Document LBP spot price as non-oracle:** Add `@dev` warning to `getSpotPrice()` that it must NEVER be used as a price oracle by other contracts. If OmniBonding ever integrates oracle pricing, ensure it uses OmniPriceOracle (TWAP + multi-validator consensus), never AMM spot prices.

---

## Conclusion

The OmniBazaar smart contract suite demonstrates mature flash loan defenses across all 13 analyzed contracts. The architecture's core design decisions -- multi-validator consensus oracle, checkpoint-based governance voting (including ATK-H02 staking snapshots), intent-based DEX settlement, admin-set bonding prices, disabled flash swaps in RWA pools, and minimum time commitments for staking/mining -- collectively create a system where flash loan attacks are either technically infeasible or economically irrational.

No critical or high-severity flash loan vulnerabilities were identified. The two medium-severity items (LiquidityMining dilution and LBP cumulative tracking bypass) represent inherent properties of their respective mechanisms rather than implementation flaws, and both are mitigated by existing safeguards. The one low-severity item (adapter trust boundary) is a defense-in-depth recommendation for key compromise scenarios.

The most important past fix -- ATK-H02 removing the fallback to current staking amounts in governance voting power -- was verified as correctly implemented. This single fix closed what would have been the highest-impact flash loan vector in the entire system.

---

*Report generated by Claude Opus 4.6 -- Cross-System Adversarial Review*
*Audit methodology: Manual code review with cross-contract attack path analysis*
*Contracts analyzed: 13 (8 full reads, 5 targeted reads)*
*Total lines reviewed: ~11,000+*
