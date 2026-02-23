# Security Audit Report: LiquidityBootstrappingPool

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/liquidity/LiquidityBootstrappingPool.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 514
**Upgradeable:** No
**Handles Funds:** Yes (holds XOM and counter-asset for weighted AMM distribution)

## Executive Summary

LiquidityBootstrappingPool is a Balancer-style weighted AMM with time-based weight shifting for fair XOM token distribution. Users swap counter-assets (e.g., USDC) for XOM at a declining price as weights shift from high XOM ratio (90%) to balanced (50/50). The contract uses OpenZeppelin's ReentrancyGuard, Ownable, Pausable, and SafeERC20.

The audit found **1 Critical vulnerability**: the swap output formula is fundamentally wrong -- it is not an approximation of the Balancer weighted constant product formula but a completely different formula that gives ~45x overpayment at 90/10 weight ratios, enabling immediate pool drainage. Additionally, the price floor check uses pre-swap reserves (completely ineffective), the CEI pattern is violated in swap(), and fee-on-transfer tokens cause permanent fund locking. Both audit agents independently confirmed the formula error as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 2 |
| Medium | 5 |
| Low | 4 |
| Informational | 3 |

## Findings

### [C-01] AMM Swap Formula Is Fundamentally Wrong -- ~45x Overpayment at LBP Weight Ratios

**Severity:** Critical
**Lines:** 492-513 (line 509-512)
**Agents:** Agent A (Medium), Agent B (Critical -- mathematical proof of 45x overpayment)

**Description:**

The contract claims to implement "Balancer-style weighted AMM" math, but the `_calculateSwapOutput()` formula is NOT the Balancer weighted constant product formula -- it is a completely different formula that gives massively wrong results at the extreme weight ratios used in LBPs.

**True Balancer formula:**
```
amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountIn))^(weightIn/weightOut))
```

**Contract formula (line 509-512):**
```
amountOut = balanceOut * amountIn * weightOut / (balanceIn * weightIn + amountIn * weightOut)
```

The contract formula applies weights as linear coefficients, NOT as exponents in a geometric mean invariant. These are fundamentally different mathematical objects.

**Proof of Concept (90/10 LBP start):**
```
balanceIn = 10,000 USDC (counter-asset reserve)
weightIn = 1000 (counter-asset weight, 10%)
balanceOut = 100,000,000 XOM (XOM reserve)
weightOut = 9000 (XOM weight, 90%)
amountIn = 1,000 USDC

True Balancer: 100M * (1 - (10000/11000)^0.1111) = 1,053,000 XOM
Contract:      100M * 1000 * 9000 / (10000*1000 + 1000*9000) = 47,368,421 XOM

Overpayment: 47.37M / 1.05M = ~45x
```

The first buyer can drain the pool almost immediately. A single $1,000 USDC swap would extract 47.4M XOM instead of the correct 1.05M XOM.

**Impact:** Complete pool drainage. An attacker can extract the entire XOM reserve with minimal counter-asset input. The LBP is non-functional.

**Recommendation:** Implement the actual Balancer weighted power math using a fixed-point exponentiation library (e.g., Balancer V2's `LogExpMath.sol` which provides `pow(base, exp)` using natural log/exp with 18-decimal fixed point). The formula must compute fractional exponents: `ratio^(weightIn/weightOut)`.

---

### [H-01] Price Floor Check Uses Pre-Swap Reserves -- Completely Ineffective

**Severity:** High
**Lines:** 294-303
**Agents:** Both (Agent A: High, Agent B: Critical)

**Description:**

The `swap()` function checks the price floor at line 294 by calling `getSpotPrice()`, which reads the current `counterAssetReserve` and `xomReserve` state variables. However, at that point these reserves have NOT been updated (updates happen at lines 302-303). The check validates the **pre-swap** price, not the **post-swap** price.

Every swap decreases the XOM price (more counter-asset in, less XOM out). The post-swap price will always be lower than the pre-swap price. This means a swap can push the price below the price floor without being reverted -- the check only blocks swaps when the price is *already* below the floor.

**Impact:** The price floor mechanism is completely ineffective at preventing the price from being pushed below the floor.

**Recommendation:** Compute the post-swap spot price using the updated reserves before executing the transfer:
```solidity
uint256 postCounterReserve = counterAssetReserve + counterAssetIn;
uint256 postXomReserve = xomReserve - xomOut;
uint256 normalizedCounter = postCounterReserve * (10 ** (18 - counterAssetDecimals));
uint256 postPrice = (normalizedCounter * weightXOM * PRECISION) / (postXomReserve * weightCounterAsset);
if (postPrice < priceFloor) revert PriceBelowFloor();
```

---

### [H-02] CEI Violation -- Token Transfers Before State Updates

**Severity:** High
**Lines:** 298-307
**Agents:** Both (Agent A: Medium, Agent B: High)

**Description:**

In `swap()`, token transfers (interactions) occur at lines 298-299 BEFORE state variable updates (effects) at lines 302-307:

```solidity
// Interactions FIRST (wrong):
counterAsset.safeTransferFrom(msg.sender, address(this), counterAssetIn);  // L298
xom.safeTransfer(msg.sender, xomOut);                                       // L299
// Effects SECOND (wrong):
counterAssetReserve += counterAssetIn;  // L302
xomReserve -= xomOut;                    // L303
```

The `nonReentrant` modifier prevents direct reentrancy, but:
1. If either token has ERC-777 callbacks, the callback executes with stale reserves
2. View functions like `getSpotPrice()` return incorrect values during the callback window (read-only reentrancy)
3. Cross-contract reentrancy (callback calls a different contract that reads this pool's state) is not protected

**Impact:** Potential state inconsistency exploitable through token callbacks or cross-contract reads. Mitigated by `nonReentrant` for direct reentrancy, but read-only reentrancy remains.

**Recommendation:** Reorder to CEI: update state variables before executing transfers.

---

### [M-01] Fee-on-Transfer Tokens Cause Reserve Desync and Fund Locking

**Severity:** Medium
**Lines:** 298, 302; 250-256
**Agent:** Agent B

**Description:**

If `counterAsset` is a fee-on-transfer token, the contract receives less than `counterAssetIn` but tracks the full amount. Over time, `counterAssetReserve` exceeds actual balance. The `finalize()` function attempts to transfer `counterAssetReserve` (the inflated tracked amount), which will revert if actual balance is less, permanently locking all tokens.

**Impact:** If a fee-on-transfer token is the counter-asset, the pool becomes permanently insolvent and finalization is blocked.

**Recommendation:** Measure actual received amount with balance-delta pattern, or validate that the counter-asset has no transfer fees in the constructor.

---

### [M-02] Flash Loan Can Circumvent Anti-Whale maxPurchaseAmount

**Severity:** Medium
**Lines:** 274-276
**Agent:** Agent A

**Description:**

The `maxPurchaseAmount` check limits a single swap transaction. An attacker can flash-borrow counter-asset and split it across multiple `swap()` calls via a contract intermediary, bypassing the anti-whale protection. There is no per-address cooldown, per-block limit, or cumulative purchase tracking.

**Impact:** Anti-whale protection is completely bypassable via a single transaction with multiple swap calls.

**Recommendation:** Add cumulative per-address purchase tracking or per-block swap limits.

---

### [M-03] Decimal Overflow if counterAssetDecimals > 18

**Severity:** Medium
**Lines:** 408-409
**Agent:** Agent B

**Description:**

`getSpotPrice()` computes `counterAssetReserve * (10 ** (18 - counterAssetDecimals))`. If `counterAssetDecimals > 18`, the subtraction underflows (uint arithmetic), producing a massive exponent that causes an overflow revert. Since `swap()` calls `getSpotPrice()`, all swaps would permanently revert.

The constructor does not validate `counterAssetDecimals <= 18`.

**Impact:** Pool is permanently unusable if counter-asset has >18 decimals (rare but possible).

**Recommendation:** Add `if (_counterAssetDecimals > 18) revert InvalidParameters();` in constructor.

---

### [M-04] No Maximum Swap Impact Check

**Severity:** Medium
**Lines:** 269-313
**Agent:** Agent B

**Description:**

There is no check that a single swap does not extract too large a percentage of the XOM reserve. Production Balancer pools typically cap single swaps at 30-50% of the output reserve. Combined with the incorrect AMM math (C-01), a single swap could drain >90% of XOM.

**Impact:** Large swaps cause extreme price impact, exploitable by well-capitalized actors.

**Recommendation:** Add `MAX_OUT_RATIO` check: `if (xomOut > (xomReserve * 3000) / BASIS_POINTS) revert ExceedsMaxSwapImpact();`

---

### [M-05] Sandwich Attack via Predictable Weight Shifts

**Severity:** Medium
**Lines:** 373-395, 269-313
**Agent:** Agent B

**Description:**

The weight-shifting mechanism is entirely time-based and fully predictable. MEV bots can observe pending swaps in the mempool and front-run with their own swap to get a better price. The `minXomOut` slippage parameter provides partial user-side protection, but sophisticated front-running can still extract value within slippage bounds. The unidirectional nature of the pool (counter-asset to XOM only) partially mitigates sandwich attacks since the attacker cannot sell XOM back through the pool.

**Impact:** Standard AMM front-running applies. Users may receive worse execution prices.

**Recommendation:** Document MEV risks for users. Consider commit-reveal scheme for large swaps.

---

### [L-01] Missing Zero-Amount Validation in swap()

**Severity:** Low
**Lines:** 269
**Agent:** Agent A

**Description:** `swap()` does not validate `counterAssetIn > 0`. A zero-amount swap succeeds, emitting a `Swap` event with zero values and wasting gas.

**Recommendation:** Add `if (counterAssetIn == 0) revert InvalidParameters();`

---

### [L-02] configure() Allows Past startTime

**Severity:** Low
**Lines:** 217-218
**Agent:** Agent A

**Description:** `configure()` validates `_startTime >= _endTime` but not `_startTime > block.timestamp`. The owner could accidentally set a past startTime, making the LBP immediately active before liquidity is added.

**Recommendation:** Add `if (_startTime <= block.timestamp) revert InvalidParameters();`

---

### [L-03] finalize() Uses Tracked Reserves Instead of Actual Balances

**Severity:** Low
**Lines:** 319-341
**Agent:** Agent B

**Description:** `finalize()` transfers `counterAssetReserve` and `xomReserve` (tracked amounts) to treasury. Any discrepancy between tracked and actual balances (from rounding, fee-on-transfer, or direct transfers) leaves dust permanently locked.

**Recommendation:** Use `counterAsset.balanceOf(address(this))` and `xom.balanceOf(address(this))` in finalize.

---

### [L-04] spotPrice Indexed in Swap Event Wastes Gas

**Severity:** Low
**Lines:** 108
**Agent:** Agent B

**Description:** The `spotPrice` parameter is `indexed` in the Swap event. Indexing a continuous uint256 price value is useless for filtering and wastes ~375 gas per event.

**Recommendation:** Remove `indexed` from `spotPrice`.

---

### [I-01] Spot Price From Pool Reserves Should Not Be Used as Oracle

**Severity:** Informational
**Lines:** 402-416
**Agent:** Agent A

**Description:** `getSpotPrice()` is `public view` and derives price directly from pool reserves. It is trivially manipulable by anyone who can swap. External contracts should not depend on this function as a price oracle.

**Recommendation:** Add NatSpec warning that this is for informational use only, not an oracle.

---

### [I-02] No Emergency Token Recovery for Third-Party Tokens

**Severity:** Informational
**Agent:** Agent B

**Description:** Tokens accidentally sent directly to the contract (other than XOM and counter-asset) are permanently locked. No `recoverToken()` function exists.

**Recommendation:** Add a restricted token recovery function for non-pool tokens.

---

### [I-03] isActive() Boundary Allows Swap and Finalize in Same Block

**Severity:** Informational
**Lines:** 444
**Agent:** Agent B

**Description:** At `endTime`, both `swap()` and `finalize()` can theoretically be called. The `finalized` flag prevents double execution, and whichever lands first wins. Standard race condition at boundary, mitigated by state flag.

**Recommendation:** Consider `block.timestamp < endTime` in `isActive()` for cleaner semantics.

---

## Static Analysis Results

**Solhint:** 0 errors, 24 warnings
- 3 immutable naming (convention only)
- 12 gas-indexed-events (minor gas optimization)
- 7 gas-strict-inequalities (minor gas optimization)
- 1 function ordering (style)
- 1 not-rely-on-time (accepted -- business requirement)

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual -- 24 raw findings -> 15 unique)
- Pass 6: Report generation

## Conclusion

LiquidityBootstrappingPool has **one show-stopping Critical vulnerability that makes the contract non-functional**:

1. **AMM formula error (C-01)** produces ~45x overpayment at 90/10 weight ratios, enabling immediate pool drainage. The formula is NOT an approximation of Balancer weighted math -- it is a fundamentally different formula. The fix requires implementing proper fractional exponentiation (e.g., Balancer V2's LogExpMath library).

2. **Price floor bypass (H-01)** makes the price floor mechanism completely ineffective. The fix is straightforward: compute post-swap price.

3. **CEI violation (H-02)** creates read-only reentrancy risk for external consumers. The fix is to reorder operations.

This contract **must not be deployed or tested with real funds** until C-01 is fixed. No tests exist for this contract, which should be considered a deployment blocker.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
