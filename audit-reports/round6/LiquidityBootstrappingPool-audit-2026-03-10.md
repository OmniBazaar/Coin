# Security Audit Report: LiquidityBootstrappingPool (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/liquidity/LiquidityBootstrappingPool.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 911
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds XOM and counter-asset for weighted AMM distribution)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable`, `Pausable`, `ERC2771Context` (all OZ v5.4.0)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Slither Report:** Not available (file not found at `/tmp/slither-LiquidityBootstrappingPool.json`)

---

## Executive Summary

LiquidityBootstrappingPool implements a Balancer-style weighted AMM with time-based weight shifting for fair XOM token distribution. Users swap counter-assets (e.g., USDC) for XOM at a declining price as weights shift from a high XOM ratio (up to 96%) to a lower target ratio (minimum 20%). The contract operates as a Dutch auction where the XOM price decreases over time, encouraging patient buying and discouraging front-running.

Since the Round 3 audit, the contract has incorporated ERC2771Context for meta-transaction support and consolidated swap validation logic. The Taylor series `_expFixed()` function's division pattern (`int256(i) * one`) -- flagged as H-01 in Round 3 -- is confirmed correct in this review after careful re-analysis. The cumulative anti-whale protection and MAX_OUT_RATIO are both properly enforced.

This Round 6 pre-mainnet audit identifies **0 Critical**, **0 High**, **2 Medium**, **3 Low**, and **3 Informational** findings. The contract is substantially mature for deployment with the noted mitigations.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Swap output calculated on nominal input but reserves updated with actual received amount | **FIXED** |
| M-02 | Medium | Cumulative purchase tracking uses nominal amount, not actual received | **FIXED** |

---

## Round 3 Remediation Status

| Round 3 Finding | Status | Evidence |
|-----------------|--------|----------|
| H-01: `_expFixed` Taylor series division error | **RE-EVALUATED: CORRECT** | The division by `int256(i) * one` is correct for fixed-point arithmetic. When `term` and `x` are both scaled by 1e18, `term * x` produces a 1e36-scaled value. Dividing by `i * 1e18` yields `(term * x) / (i * PRECISION)` = `term_{n-1} * x_raw / i` in 1e18 scale. This is the correct Taylor series recurrence for fixed-point values. |
| M-01: No ERC-2771 meta-transaction support | **FIXED** | Contract now inherits `ERC2771Context` (line 59). `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` properly overridden (lines 722-761). `swap()` uses `_msgSender()` (line 389). |
| M-02: Redundant validation in `swap()` | **FIXED** | Consolidated into `_validateSwap()` (lines 644-664) which merges active check, zero-amount check, per-tx limit check, and cumulative limit check. |
| M-03: `addLiquidity` available during LBP | **FIXED** | `addLiquidity()` reverts with `LBPAlreadyStarted` when `block.timestamp >= startTime` (lines 347-350). |
| L-01 through L-04, I-01 through I-04 | **REVIEWED** | See individual findings below for any that persist. |

---

## Architecture Analysis

### Design Strengths

1. **Correct Balancer Weighted Math:** The swap formula `amountOut = Bo * (1 - (Bi/(Bi+Ai))^(Wi/Wo))` is correctly implemented via the `exp(y * ln(x))` identity with proper fixed-point arithmetic. The `_lnFixed()` uses a 7-term arctanh Taylor series and `_expFixed()` uses a 20-term Taylor series, both converging well within the LBP operating range.

2. **Mathematical Safety Coupling:** The `MAX_OUT_RATIO = 30%` constant and the `_lnFixed()` Taylor series precision are explicitly coupled in documentation (lines 36-40, 78-86). The 30% cap ensures `Bi/(Bi+Ai) > ~0.5`, keeping the arctanh argument small enough for 7-term convergence with < 0.001% error.

3. **CEI Pattern Enforcement:** State updates (lines 410-413) precede external token transfers (line 420) in `swap()`, correctly following Checks-Effects-Interactions.

4. **Fee-on-Transfer Resilience:** `_transferCounterAssetIn()` (lines 675-687) uses balance-before/after pattern. State updates use `actualReceived` (line 410), not the nominal `counterAssetIn`.

5. **Cumulative Anti-Whale:** Per-address cumulative purchase tracking in `_validateSwap()` (lines 656-663) prevents circumventing `maxPurchaseAmount` via multiple transactions or flash loans.

6. **MAX_OUT_RATIO Cap (30%):** Prevents single-swap pool drainage (line 400). Each swap can extract at most 30% of the XOM reserve.

7. **Immutable Token References:** `XOM_TOKEN`, `COUNTER_ASSET_TOKEN`, and `COUNTER_ASSET_DECIMALS` are immutable.

8. **Mid-LBP Liquidity Lock:** `addLiquidity()` is blocked after the LBP starts (line 348-350), preventing owner from manipulating spot price during the event.

9. **ERC2771 Meta-Transaction Support:** Properly integrated with overridden `_msgSender()`, `_msgData()`, and `_contextSuffixLength()`.

### Design Considerations (Not Vulnerabilities)

1. **Unidirectional Swaps:** Only counter-asset-to-XOM swaps are supported. This is intentional for LBP design -- there is no mechanism for users to sell XOM back to the pool. This is standard for Balancer LBPs.

2. **Owner Centralization:** The owner controls `configure()`, `addLiquidity()`, `finalize()`, `pause()`, `unpause()`, and `setTreasury()`. This is standard for LBP contracts which are short-lived (days to weeks) and operated by the token issuer.

3. **No Ownable2Step:** Unlike LiquidityMining, this contract uses single-step `Ownable` rather than `Ownable2Step`. Given the short-lived nature of LBPs, this is acceptable but noted.

---

## Findings

### [M-01] Swap Output Calculated on Nominal Input But Reserves Updated with Actual Received Amount

**Severity:** Medium
**Lines:** 394, 405-411
**Category:** Business Logic / Accounting

**Description:**

The `swap()` function computes `xomOut` based on the nominal `counterAssetIn` (line 394):

```solidity
xomOut = _computeSwapOutput(counterAssetIn);
```

But then transfers the counter-asset and measures the actual received amount (line 405-407):

```solidity
uint256 actualReceived = _transferCounterAssetIn(counterAssetIn, caller);
```

The reserves are updated with `actualReceived` (line 410):

```solidity
counterAssetReserve += actualReceived;
```

But `xomOut` was computed using the nominal `counterAssetIn`, not `actualReceived`. For fee-on-transfer tokens where `actualReceived < counterAssetIn`, the user receives more XOM than the AMM formula would produce for the actual input amount. This creates a favorable arbitrage for users of fee-on-transfer counter-assets.

**Impact:** If a fee-on-transfer token is used as the counter-asset, each swap extracts slightly more XOM than the pool should provide, slowly draining the XOM reserve at a rate proportional to the transfer fee.

**Likelihood:** Low -- USDC (the primary intended counter-asset) is not a fee-on-transfer token, and the contract already measures `actualReceived` for reserve tracking. This would only be exploitable if a fee-on-transfer token were deliberately chosen as the counter-asset.

**Recommendation:**

Recompute `xomOut` using `actualReceived` after the transfer:

```solidity
uint256 actualReceived = _transferCounterAssetIn(counterAssetIn, caller);

// Recompute output based on actual received
xomOut = _computeSwapOutputFromAmount(actualReceived);
if (xomOut < minXomOut) revert SlippageExceeded();
```

Alternatively, reject fee-on-transfer tokens entirely by requiring `actualReceived == counterAssetIn`.

---

### [M-02] Cumulative Purchase Tracking Uses Nominal Amount, Not Actual Received

**Severity:** Medium
**Lines:** 656
**Category:** Anti-Whale Bypass

**Description:**

The `_validateSwap()` function increments `cumulativePurchases[caller]` with the nominal `counterAssetIn` (line 656):

```solidity
cumulativePurchases[caller] += counterAssetIn;
```

This runs before the actual transfer and before `actualReceived` is known. For standard tokens this is fine. However, the cumulative tracking is inconsistent with the reserve tracking (which uses `actualReceived`). If a fee-on-transfer token is used, the cumulative tracker over-counts the user's actual spending, making the anti-whale protection stricter than intended -- this is a conservative failure mode and not exploitable.

Conversely, the `totalRaised` counter (line 412) correctly uses `actualReceived`. This means `sum(cumulativePurchases)` across all users will exceed `totalRaised`, which is a minor accounting inconsistency.

**Impact:** Minor accounting inconsistency. The anti-whale protection is conservative (stricter than intended) for fee-on-transfer tokens, which is safe. No funds at risk.

**Recommendation:**

For consistency, consider moving the cumulative tracking to after the transfer so it uses `actualReceived`. Alternatively, document this as intentionally conservative.

---

### [L-01] No Minimum Swap Output Enforced Beyond User-Provided `minXomOut`

**Severity:** Low
**Lines:** 397
**Category:** User Protection

**Description:**

The only slippage protection is the user-provided `minXomOut` parameter. There is no contract-enforced minimum output (e.g., requiring at least 1 wei of XOM output). A user who passes `minXomOut = 0` could receive 0 XOM (due to rounding in the math for very small swaps) while still transferring counter-assets.

**Impact:** Users who do not set `minXomOut` could lose small amounts of counter-assets to rounding. This is primarily a UX concern -- frontend applications should always set a reasonable `minXomOut`.

**Recommendation:**

Add a minimum output check:

```solidity
if (xomOut == 0) revert InvalidParameters();
```

---

### [L-02] `_expFixed` Guard Bound of 42 * PRECISION Is Conservative But Could Truncate Valid Results

**Severity:** Low
**Lines:** 895-897
**Category:** Mathematical Precision

**Description:**

The `_expFixed()` function returns 0 for `x < -42 * one` and reverts for `x > 42 * one - 1`:

```solidity
if (x < -42 * one) return 0;
if (x > 42 * one - 1) revert ExpInputOverflow();
```

For LBP swaps, the exponent `product = lnBase * exponent / PRECISION` is typically in the range [-4, 0] (since the base is a ratio < 1 and the exponent is a weight ratio). The -42 lower bound is extremely conservative. However, for weight ratios near the extremes (e.g., 96/4 = 24x weight ratio), if the ratio `Bi/(Bi+Ai)` is very small (near the MAX_OUT_RATIO limit), the product could approach -16 to -20. These are still well within the -42 bound.

**Impact:** No practical impact for the LBP's operating parameters. The 20-term Taylor series converges well for `x` in [-20, 0]. For `x < -20`, the result approaches 0 and the 20-term series may lose precision, but the MAX_OUT_RATIO prevents the swap from reaching this range.

**Recommendation:**

No code change required. The bound is safe. Consider adding a comment noting that the MAX_OUT_RATIO ensures the practical range is [-20, 0].

---

### [L-03] No Event Emitted on `setTreasury()`

**Severity:** Low
**Lines:** 485-488
**Category:** Monitoring / Transparency

**Description:**

The `setTreasury()` function changes the treasury address without emitting an event:

```solidity
function setTreasury(address _treasury) external onlyOwner {
    if (_treasury == address(0)) revert InvalidParameters();
    treasury = _treasury;
}
```

Unlike the LiquidityMining and OmniBonding contracts, which emit `TreasuryUpdated` events on treasury changes, this contract has no equivalent event.

**Impact:** Off-chain monitoring systems cannot detect treasury address changes without polling storage.

**Recommendation:**

Add a `TreasuryUpdated` event:

```solidity
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

function setTreasury(address _treasury) external onlyOwner {
    if (_treasury == address(0)) revert InvalidParameters();
    address old = treasury;
    treasury = _treasury;
    emit TreasuryUpdated(old, _treasury);
}
```

---

### [I-01] `getSpotPrice()` Returns 0 When `xomReserve == 0` Without Reverting

**Severity:** Informational
**Lines:** 597
**Category:** Edge Case Behavior

**Description:**

When `xomReserve == 0` (all XOM swapped out), `getSpotPrice()` returns 0 rather than reverting. This means `swap()` would pass the price floor check (`0 < priceFloor` is false, so `PriceBelowFloor` would revert) only if `priceFloor > 0`. If `priceFloor == 0`, swaps would succeed even when the pool is fully drained, though MAX_OUT_RATIO would prevent draining to exactly 0 in practice.

**Impact:** No practical impact. MAX_OUT_RATIO prevents full drainage, and a zero price floor is unlikely in production.

**Recommendation:**

Document this behavior. Consider reverting if `xomReserve == 0` to make the state explicit.

---

### [I-02] `configure()` Allows Reconfiguration Up to `startTime - 1` But Not Exactly at `startTime`

**Severity:** Informational
**Lines:** 299
**Category:** Boundary Condition

**Description:**

The `configure()` function checks `block.timestamp > startTime - 1` (equivalent to `block.timestamp >= startTime`):

```solidity
if (startTime != 0 && block.timestamp > startTime - 1) {
    revert LBPAlreadyStarted();
}
```

This means the owner can reconfigure in the same block as `startTime` only if the block timestamp is strictly less than `startTime`. This is correct and intentional, but the `- 1` pattern is unusual compared to the more readable `>=` operator.

**Impact:** None. Behavior is correct.

**Recommendation:**

Consider using `block.timestamp >= startTime` for readability, acknowledging the solhint `gas-strict-inequalities` rule.

---

### [I-03] `_lnFixed()` Taylor Series Error for Very Small Inputs (Below ~0.1)

**Severity:** Informational
**Lines:** 845-879
**Category:** Mathematical Precision

**Description:**

The `_lnFixed()` function uses a 7-term arctanh Taylor series. For inputs near 0 (e.g., `x = 0.05 * PRECISION`), the argument `y = (x - 1) / (x + 1)` approaches -1, and the Taylor series for `arctanh(y)` converges very slowly. At `y = -0.9` (corresponding to `x = 0.0526...`), the 7-term series has an error of approximately 0.1%.

However, the contract's `MAX_OUT_RATIO = 30%` ensures that the ratio `Bi / (Bi + Ai)` never drops below approximately 0.59 for any valid swap. At this ratio, the Taylor series error is < 0.001%.

**Impact:** No practical impact. The MAX_OUT_RATIO constraint keeps inputs well within the series' convergence region. This is well-documented in the contract header (lines 35-40).

**Recommendation:**

No change needed. The coupling between MAX_OUT_RATIO and the Taylor series precision is correctly documented. If MAX_OUT_RATIO is ever increased, additional Taylor series terms must be added.

---

## Whale Manipulation Analysis

### Can whales manipulate the LBP to buy cheap?

**Mitigated.** The contract has three layers of whale protection:

1. **`maxPurchaseAmount`:** Caps per-transaction spending (lines 652-654).
2. **`cumulativePurchases` mapping:** Tracks total spending per address across all transactions (lines 656-663). A whale cannot split purchases across multiple transactions to circumvent the cap.
3. **`MAX_OUT_RATIO = 30%`:** Limits each swap to 30% of the XOM reserve (line 400). Even without `maxPurchaseAmount`, a whale cannot drain the pool in a single transaction.

**Residual risk:** A whale can use multiple addresses to circumvent the per-address cumulative limit. This is an inherent limitation of on-chain identity systems. Off-chain KYC or address whitelisting is the only mitigation, which is outside the contract's scope.

### Front-Running During Weight Shifts

**Mitigated by design.** The LBP weight-shifting mechanism creates a Dutch auction where prices naturally decrease over time. Front-running a weight shift to buy before the price drops further is the opposite of the typical front-running attack -- the front-runner pays a higher price than if they waited. The MAX_OUT_RATIO also limits the profit from any single front-run transaction.

MEV bots could sandwich other users' swaps (front-run + back-run), but the unidirectional-only design (no sell side) prevents the back-run half of a sandwich attack. A bot cannot sell XOM back to the pool to capture value.

### Flash Loan Resistance

**Strong.** Flash loans require repayment within the same transaction. Since the LBP only supports one-directional swaps (counter-asset to XOM), a flash-loan attacker cannot borrow counter-asset, swap for XOM, and then repay the flash loan in the same transaction -- they would need to sell the XOM elsewhere, which introduces external market risk and is not a guaranteed profit.

The cumulative purchase tracking also prevents splitting a flash-loaned amount across multiple swaps within the same transaction.

---

## Cross-Contract DeFi Attack Vectors

### Flash Loan -> LBP -> Bond -> Profit

**Not viable.** The LBP outputs XOM tokens, but the OmniBonding contract accepts stablecoins (USDC/USDT/DAI) as input, not XOM. An attacker cannot flash-loan USDC, buy XOM from the LBP, and then bond XOM for more USDC -- the bonding contract does not accept XOM as a bond asset.

### Sandwich Attacks on LBP

**Partially mitigated.** As noted above, the unidirectional swap design prevents the back-run half of a sandwich. An attacker could front-run a large buy to get a better price, but they cannot sell back to the pool to capture the price impact from the victim's trade.

### LBP Price as Oracle for Bonding

**Not applicable.** The OmniBonding contract uses a fixed price set by the owner (`fixedXomPrice`), not a price derived from any pool. The LBP's spot price cannot be used to manipulate bond pricing.

---

## Summary

LiquidityBootstrappingPool is a well-constructed LBP implementation with correct Balancer weighted math, strong anti-whale protections, and proper CEI pattern enforcement. The two Medium findings relate to fee-on-transfer token handling edge cases that are unlikely to affect the primary USDC counter-asset deployment. The contract is suitable for mainnet deployment with the recommended mitigations applied.

**Deployment Readiness:** APPROVED with Low-priority fixes recommended
- M-01: Should be addressed if fee-on-transfer tokens are ever used as counter-asset
- M-02: Conservative failure mode, acceptable as-is
- L-03: Should be fixed for monitoring purposes (add `TreasuryUpdated` event)

---

*Audit conducted 2026-03-10 01:03 UTC*
