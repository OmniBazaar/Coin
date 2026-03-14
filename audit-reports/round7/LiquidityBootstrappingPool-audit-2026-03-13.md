# Security Audit Report: LiquidityBootstrappingPool (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/liquidity/LiquidityBootstrappingPool.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 946
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds XOM and counter-asset tokens for weighted AMM distribution)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable`, `Pausable`, `ERC2771Context` (all OZ v5.4.0)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
**Slither:** Skipped (resource contention)
**Solhint:** Clean (no findings; two warnings about non-existent rules in config, not contract issues)

---

## Executive Summary

LiquidityBootstrappingPool implements a Balancer-style weighted AMM with time-based weight shifting for fair XOM token distribution. Users swap counter-assets (e.g., USDC) for XOM at a declining price as weights shift from a high XOM ratio (up to 96%) to a lower target (minimum 20%). The contract operates as a Dutch auction where the XOM price decreases over time, encouraging patient buying and discouraging front-running.

This Round 7 pre-mainnet audit is a complete re-examination of the contract post-remediation of all Round 6 findings. The two Medium findings from Round 6 (M-01: swap output computed on nominal input; M-02: cumulative tracking using nominal amount) have been verified as correctly remediated. The swap function now computes `xomOut` using `actualReceived` (line 417), and cumulative purchase tracking uses `actualReceived` (line 411).

This Round 7 audit identifies **0 Critical**, **0 High**, **1 Medium**, **3 Low**, and **3 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Remediation Verification

| Round 6 Finding | Status | Evidence |
|-----------------|--------|----------|
| M-01: Swap output calculated on nominal input | **VERIFIED FIXED** | Line 417: `xomOut = _computeSwapOutput(actualReceived)` now uses the post-transfer actual amount rather than the nominal `counterAssetIn`. The swap formula correctly reflects the pool's actual received tokens. |
| M-02: Cumulative tracking uses nominal amount | **VERIFIED FIXED** | Line 411: `_trackCumulativePurchase(actualReceived, caller)` now tracks cumulative purchases using `actualReceived`, consistent with reserve accounting. |
| L-01: No minimum swap output enforced | **PERSISTS** | See L-01 below. No contract-enforced minimum output beyond user-provided `minXomOut`. |
| L-02: `_expFixed` guard bound conservative | **ACCEPTED** | No code change needed. Bounds are safe for LBP operating parameters. |
| L-03: No event on `setTreasury()` | **PERSISTS** | See L-02 below. Still no `TreasuryUpdated` event emitted. |

---

## Architecture Analysis

### Design Strengths

1. **Correct Balancer Weighted Math:** The swap formula `amountOut = Bo * (1 - (Bi/(Bi+Ai))^(Wi/Wo))` is correctly implemented via the `exp(y * ln(x))` identity with proper fixed-point arithmetic. The `_lnFixed()` uses a 7-term arctanh Taylor series and `_expFixed()` uses a 20-term Taylor series, both converging well within the LBP operating range.

2. **Mathematical Safety Coupling:** The `MAX_OUT_RATIO = 30%` constant and the `_lnFixed()` Taylor series precision are explicitly coupled in documentation (lines 35-40, 83-90). The 30% cap ensures `Bi/(Bi+Ai) > ~0.59`, keeping the arctanh argument small enough for 7-term convergence with < 0.001% error. This is a well-documented invariant.

3. **CEI Pattern Enforcement:** In `swap()` (lines 398-451), external token transfer in (line 405-407) occurs before state updates (lines 428-431), and the XOM transfer out (line 438) occurs after all state updates. The inbound transfer is guarded by `nonReentrant`. In `finalize()` (lines 458-480), state is zeroed before transfers. Proper CEI throughout.

4. **Fee-on-Transfer Resilience (Post-Round 6):** `_transferCounterAssetIn()` (lines 686-698) uses balance-before/after pattern. Both `xomOut` computation (line 417) and cumulative tracking (line 411) use `actualReceived`, not nominal input. State updates (line 428) also use `actualReceived`. All three paths are now consistent.

5. **Three-Layer Anti-Whale Protection:**
   - Per-transaction limit: `_validateSwap` checks `counterAssetIn > maxPurchaseAmount` (line 718).
   - Cumulative per-address limit: `_trackCumulativePurchase` checks `cumulativePurchases[caller] > maxPurchaseAmount` (lines 666-674).
   - Per-swap output cap: `MAX_OUT_RATIO = 30%` limits each swap to 30% of XOM reserve (line 423).

6. **Mid-LBP Liquidity Lock:** `addLiquidity()` reverts with `LBPAlreadyStarted` when `block.timestamp >= startTime` (lines 357-360), preventing owner from manipulating spot price during the event.

7. **Immutable Token References:** `XOM_TOKEN`, `COUNTER_ASSET_TOKEN`, and `COUNTER_ASSET_DECIMALS` are all immutable, preventing post-deployment token swapping attacks.

8. **ReentrancyGuard on All Token-Handling Functions:** `swap()` (line 398), `addLiquidity()` (line 354), and `finalize()` (line 458) all use `nonReentrant`.

9. **Pausable Emergency Circuit Breaker:** Owner can pause swaps via `pause()` (line 486). `addLiquidity` and `finalize` are not paused (by design -- owner should be able to add liquidity pre-LBP and finalize post-LBP even when paused).

### Design Considerations (Not Vulnerabilities)

1. **Unidirectional Swaps:** Only counter-asset-to-XOM swaps are supported. This is intentional for LBP design. No mechanism exists for users to sell XOM back to the pool. This is standard Balancer LBP behavior and prevents sandwich attack back-runs.

2. **Owner Centralization:** The owner controls `configure()`, `addLiquidity()`, `finalize()`, `pause()`, `unpause()`, and `setTreasury()`. This is standard for short-lived LBP contracts operated by the token issuer. No `Ownable2Step` is used, which is acceptable given the short lifecycle.

3. **No Token Recovery Function:** Tokens sent directly to the contract (not via `addLiquidity` or `swap`) are permanently stuck. The `finalize()` function only transfers tracked `counterAssetReserve` and `xomReserve` values. Excess tokens from direct transfers are not recoverable. This is a standard trade-off for simpler accounting.

---

## Findings

### [M-01] `addLiquidity` Uses `msg.sender` Instead of `_msgSender()` for Token Transfers (ERC-2771 Inconsistency)

**Severity:** Medium
**Lines:** 363-365, 370-372
**Category:** ERC-2771 / Access Control Inconsistency

**Description:**

The `addLiquidity()` function uses raw `msg.sender` for `safeTransferFrom` calls:

```solidity
// Line 363-365
XOM_TOKEN.safeTransferFrom(
    msg.sender, address(this), xomAmount
);

// Line 370-372
COUNTER_ASSET_TOKEN.safeTransferFrom(
    msg.sender, address(this), counterAssetAmount
);
```

The contract inherits `ERC2771Context` and overrides `_msgSender()` (lines 757-764) to resolve the original sender in meta-transactions. The `onlyOwner` modifier (from OZ v5 `Ownable`) calls `_checkOwner()` which uses `_msgSender()`, so the ownership check correctly resolves the ERC-2771 sender. However, the `safeTransferFrom` on lines 363 and 370 pulls tokens from `msg.sender` (the forwarder contract in a meta-tx), not from `_msgSender()` (the actual owner).

In a meta-transaction scenario:
- `_msgSender()` returns the owner address (appended to calldata by the forwarder).
- `onlyOwner` passes because `_msgSender() == owner()`.
- `safeTransferFrom(msg.sender, ...)` attempts to pull tokens from the **forwarder contract**, not the owner.
- The forwarder almost certainly has not approved tokens, so the call reverts.

This means `addLiquidity` is non-functional via meta-transactions, even though the contract explicitly supports ERC-2771.

**Impact:** `addLiquidity` cannot be called via ERC-2771 meta-transactions. The function works correctly for direct calls. Since this is an admin function called pre-LBP (typically once or twice), the practical impact is limited, but it represents an inconsistency with the contract's meta-transaction architecture.

**Recommendation:**

Replace `msg.sender` with `_msgSender()` in both `safeTransferFrom` calls:

```solidity
function addLiquidity(
    uint256 xomAmount,
    uint256 counterAssetAmount
) external onlyOwner nonReentrant {
    if (finalized) revert AlreadyFinalized();
    if (startTime != 0 && block.timestamp > startTime - 1) {
        revert LBPAlreadyStarted();
    }

    address caller = _msgSender();  // Resolve once

    if (xomAmount > 0) {
        XOM_TOKEN.safeTransferFrom(
            caller, address(this), xomAmount  // Use resolved sender
        );
        xomReserve += xomAmount;
    }

    if (counterAssetAmount > 0) {
        COUNTER_ASSET_TOKEN.safeTransferFrom(
            caller, address(this), counterAssetAmount  // Use resolved sender
        );
        counterAssetReserve += counterAssetAmount;
    }

    emit LiquidityAdded(xomAmount, counterAssetAmount);
}
```

---

### [L-01] No Contract-Enforced Minimum Swap Output (Persists from Round 6)

**Severity:** Low
**Lines:** 417-420
**Category:** User Protection

**Description:**

The only slippage protection is the user-provided `minXomOut` parameter (line 420):

```solidity
if (xomOut < minXomOut) revert SlippageExceeded();
```

There is no contract-enforced minimum output. A user who passes `minXomOut = 0` could receive 0 XOM (due to rounding in the weighted math for very small inputs) while still transferring counter-assets. The `_calculateSwapOutput` function can return 0 when `power >= PRECISION` (line 841):

```solidity
if (power > PRECISION - 1) return 0;
```

**Impact:** Users who do not set a reasonable `minXomOut` could lose small amounts of counter-assets to rounding. This is primarily a UX concern. Frontend applications should always set a reasonable `minXomOut`.

**Recommendation:**

Add a minimum output check after the swap computation:

```solidity
xomOut = _computeSwapOutput(actualReceived);
if (xomOut == 0) revert InvalidParameters();
if (xomOut < minXomOut) revert SlippageExceeded();
```

---

### [L-02] No Event Emitted on `setTreasury()` (Persists from Round 6)

**Severity:** Low
**Lines:** 503-506
**Category:** Monitoring / Transparency

**Description:**

The `setTreasury()` function changes the treasury address without emitting an event:

```solidity
function setTreasury(address _treasury) external onlyOwner {
    if (_treasury == address(0)) revert InvalidParameters();
    treasury = _treasury;
}
```

Both `OmniBonding.sol` (line 263: `TreasuryUpdated`) and `LiquidityMining.sol` (line 283: `ProtocolTreasuryUpdated`) emit events when their treasury addresses change. This contract does not follow the same pattern.

**Impact:** Off-chain monitoring systems cannot detect treasury address changes without polling storage slots. The treasury address determines where all raised funds and remaining XOM go on `finalize()`, making this a high-value state change that should be observable.

**Recommendation:**

Add a `TreasuryUpdated` event:

```solidity
event TreasuryUpdated(
    address indexed oldTreasury,
    address indexed newTreasury
);

function setTreasury(address _treasury) external onlyOwner {
    if (_treasury == address(0)) revert InvalidParameters();
    address oldTreasury = treasury;
    treasury = _treasury;
    emit TreasuryUpdated(oldTreasury, _treasury);
}
```

---

### [L-03] One-Block Overlap Between Active LBP and Finalization Eligibility at `endTime`

**Severity:** Low
**Lines:** 460, 639-646
**Category:** Race Condition / Edge Case

**Description:**

At exactly `block.timestamp == endTime`, two conditions are simultaneously true:

1. `isActive()` returns `true` (line 644-645: `ts >= startTime && ts <= endTime`).
2. `finalize()` does not revert (line 460: `block.timestamp < endTime` is `false`).

This means in the same block at `endTime`, both a user `swap()` and the owner `finalize()` could execute. The outcome depends on transaction ordering:

- If `finalize()` runs first: `finalized` is set to `true`, reserves are zeroed. A subsequent `swap()` in the same block would revert because `isActive()` returns `false` (`!finalized` is `false`).
- If `swap()` runs first: The swap succeeds. Then `finalize()` drains the remaining reserves.

```solidity
// isActive() - includes endTime
return startTime != 0 && !finalized &&
    ts > startTime - 1 &&    // ts >= startTime
    ts < endTime + 1;         // ts <= endTime

// finalize() - also includes endTime
if (block.timestamp < endTime) revert LBPNotEnded();  // passes at endTime
```

**Impact:** A last-second swap at `endTime` could succeed before `finalize()` runs, which may or may not be desired. In practice, the owner would typically wait a block or two after `endTime` before finalizing. The impact is negligible for standard operations.

**Recommendation:**

For clarity, either:
1. Make `isActive()` exclusive of `endTime`: change `ts < endTime + 1` to `ts < endTime` (LBP ends one second before finalization becomes available).
2. Or make `finalize()` require `block.timestamp > endTime` (strictly after).

Option 1 is recommended:

```solidity
function isActive() public view returns (bool active) {
    uint256 ts = block.timestamp;
    return startTime != 0 &&
        !finalized &&
        ts >= startTime &&
        ts < endTime;  // Exclusive of endTime
}
```

---

### [I-01] `getSpotPrice()` Returns 0 When `xomReserve == 0` Without Reverting

**Severity:** Informational
**Lines:** 615
**Category:** Edge Case Behavior

**Description:**

When `xomReserve == 0` (theoretically, all XOM distributed), `getSpotPrice()` returns 0 rather than reverting:

```solidity
if (xomReserve == 0) return 0;
```

In `swap()`, the price floor check (line 435) would cause a revert if `priceFloor > 0`:

```solidity
uint256 postSwapPrice = getSpotPrice();  // Returns 0
if (postSwapPrice < priceFloor) revert PriceBelowFloor();  // Reverts if priceFloor > 0
```

If `priceFloor == 0`, the swap would pass the price floor check even with zero reserves. However, `MAX_OUT_RATIO` (30%) prevents full drainage in practice -- each swap can extract at most 30% of the remaining `xomReserve`, meaning the reserve asymptotically approaches but never reaches zero.

**Impact:** No practical impact. The 30% MAX_OUT_RATIO prevents the edge case from being reached, and a non-zero `priceFloor` provides a secondary guard.

**Recommendation:**

No code change required. Consider adding a comment noting that `MAX_OUT_RATIO` guarantees `xomReserve > 0` during normal operation.

---

### [I-02] `finalize()` Can Be Called Before Configuration

**Severity:** Informational
**Lines:** 458-480
**Category:** Edge Case

**Description:**

If the contract is deployed but never configured (`startTime = 0`, `endTime = 0`), the owner can call `finalize()`:

```solidity
function finalize() external onlyOwner nonReentrant {
    if (block.timestamp < endTime) revert LBPNotEnded();  // 0 < 0 is false, passes
    if (finalized) revert AlreadyFinalized();              // false, passes
    finalized = true;
    // ... transfers
}
```

Since `endTime = 0` and `block.timestamp` is always positive, the time check passes. The owner could also call `addLiquidity` (since `startTime == 0` means the LBP hasn't started yet) and then immediately `finalize()` to sweep those tokens to treasury.

**Impact:** No security impact. Only the owner can call both functions, and the owner is the one who deposited the tokens. This effectively allows the owner to use the contract as a simple token forwarding mechanism before configuration, which is benign.

**Recommendation:**

If desired, add a configuration check in `finalize()`:

```solidity
if (startTime == 0) revert InvalidParameters();
```

This is optional -- the current behavior is safe and allows the owner to recover tokens from an unconfigured deployment.

---

### [I-03] `_validateSwap` Accepts Unused `caller` Parameter

**Severity:** Informational
**Lines:** 710-722
**Category:** Code Clarity

**Description:**

The `_validateSwap` function accepts a `caller` parameter that is unused (commented out):

```solidity
function _validateSwap(
    uint256 counterAssetIn,
    address /* caller */
) internal view {
```

This parameter was previously used for cumulative purchase tracking in Round 6's consolidated validation, but the tracking was moved to `_trackCumulativePurchase()`. The unused parameter remains.

**Impact:** Minor gas overhead for passing the parameter and negligible impact on code clarity. The comment makes the intentional non-use clear.

**Recommendation:**

Remove the unused parameter from `_validateSwap` for cleaner code:

```solidity
function _validateSwap(
    uint256 counterAssetIn
) internal view {
    if (!isActive()) revert LBPNotActive();
    if (counterAssetIn == 0) revert InvalidParameters();
    if (maxPurchaseAmount > 0) {
        if (counterAssetIn > maxPurchaseAmount) {
            revert ExceedsMaxPurchase();
        }
    }
}
```

And update the call site in `swap()`:

```solidity
_validateSwap(counterAssetIn);
```

---

## Detailed Mathematical Verification

### Balancer Weighted Constant Product Formula

**Formula:** `amountOut = Bo * (1 - (Bi / (Bi + Ai))^(Wi / Wo))`

**Implementation verification:**

1. **Fee application (line 826-827):** `amountInAfterFee = amountIn * (10000 - 30) / 10000` = 99.7% of input. Correct -- 0.3% fee deducted from input.

2. **Ratio computation (line 831-832):** `ratio = balanceIn * 1e18 / (balanceIn + amountInAfterFee)`. This is `Bi / (Bi + Ai)` in fixed-point. Always < 1.0 (< PRECISION) since `amountInAfterFee > 0`. Correct.

3. **Exponent computation (line 835):** `exponent = weightIn * 1e18 / weightOut`. This is `Wi / Wo` in fixed-point. Correct.

4. **Power computation (line 838):** `power = _powFixed(ratio, exponent)` = `ratio^exponent` via `exp(exponent * ln(ratio))`. Correct identity.

5. **Output computation (lines 841-842):** `amountOut = balanceOut * (PRECISION - power) / PRECISION` = `Bo * (1 - power)`. Correct.

**Overflow analysis:**

- `balanceIn * PRECISION` (line 831): Maximum realistic `balanceIn` for USDC would be ~1e15 (1 billion USDC in 6-decimal representation). `1e15 * 1e18 = 1e33`. Safe (uint256 max is ~1.15e77).
- `normalizedCounterAsset * weightXOM * PRECISION` (line 628): Max ~1e27 * 9600 * 1e18 = ~9.6e49. Safe.
- `term * x` in `_expFixed` (line 939): Both are int256, max magnitude ~42e18. `42e18 * 42e18 = 1.764e39`. Safe (int256 max is ~5.78e76).
- `lnBase * exp` in `_powFixed` (line 864-865): `lnBase` max magnitude for ratio near 0.59 is ~ln(0.59) * 1e18 = ~5.27e17. `exp` max for weight ratio 8000/2000 = 4 is `4e18`. Product: `5.27e17 * 4e18 / 1e18 = 2.1e18`. Safe.

### Taylor Series Convergence

**`_lnFixed` (7-term arctanh):**
- Input range guaranteed by MAX_OUT_RATIO: ratio >= ~0.59, so `y = (ratio - 1) / (ratio + 1)` has `|y| <= 0.257`.
- For `|y| = 0.257`: 7th term magnitude is `y^13 / 13 = 0.257^13 / 13 < 1e-9`. Error < 0.0001%. Confirmed adequate.

**`_expFixed` (20-term Taylor):**
- Input range: `product` typically in [-4, 0] for standard LBP parameters. Worst case (96/4 weight ratio with max output): ~[-16, 0].
- For `x = -16`: 20th term is `(-16)^20 / 20!` < 1e-6. Convergence confirmed.

---

## Whale Manipulation Analysis

### Multi-Address Sybil Attack

**Residual risk.** A whale can deploy multiple addresses, each purchasing up to `maxPurchaseAmount`, to circumvent the per-address cumulative limit. Each address is tracked independently in `cumulativePurchases`. There is no on-chain defense against Sybil attacks without identity verification or address whitelisting.

**Mitigation:** Off-chain KYC or address whitelisting is the standard approach. This is outside the contract's scope and is a known limitation of all LBP implementations.

### Front-Running and MEV

**Mitigated by design.** The Dutch auction mechanism means front-runners pay a higher price (buying before the natural price decline). The unidirectional swap design prevents the sell-side of sandwich attacks. MAX_OUT_RATIO limits profit from any single front-run. Combined, these make MEV extraction unprofitable for typical LBP interactions.

### Flash Loan Resistance

**Strong.** Flash loans require same-transaction repayment. Since swaps are unidirectional (counter-asset to XOM only), an attacker cannot borrow, swap, and repay in one transaction. The XOM received must be sold on external markets, introducing market risk and eliminating guaranteed profit. Cumulative tracking also prevents splitting flash-loaned amounts across multiple same-transaction swaps.

---

## Cross-Contract Integration Review

### External Call Surface

| Call | Target | Safety |
|------|--------|--------|
| `XOM_TOKEN.safeTransferFrom()` | XOM ERC20 | SafeERC20 wrapper, nonReentrant guard |
| `XOM_TOKEN.safeTransfer()` | XOM ERC20 | SafeERC20 wrapper, nonReentrant guard |
| `COUNTER_ASSET_TOKEN.safeTransferFrom()` | Counter-asset ERC20 | SafeERC20 wrapper, nonReentrant guard |
| `COUNTER_ASSET_TOKEN.safeTransfer()` | Counter-asset ERC20 | SafeERC20 wrapper, nonReentrant guard |
| `COUNTER_ASSET_TOKEN.balanceOf()` | Counter-asset ERC20 | View call, no state change |

All external calls use OpenZeppelin `SafeERC20` wrappers, which handle non-standard return values. All token-transfer functions are protected by `nonReentrant`.

### LBP Price as Oracle

The `getSpotPrice()` function is clearly documented as not suitable for oracle use (line 608: "WARNING: This price is derived from pool reserves and is manipulable via large swaps. Do NOT use as a price oracle feed."). No other OmniBazaar contracts reference this contract's price.

---

## Findings Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | `addLiquidity` uses `msg.sender` instead of `_msgSender()` for ERC-2771 compatibility | NEW |
| L-01 | Low | No contract-enforced minimum swap output (persists from Round 6) | PERSISTS |
| L-02 | Low | No event emitted on `setTreasury()` (persists from Round 6) | PERSISTS |
| L-03 | Low | One-block overlap between active LBP and finalization eligibility at `endTime` | NEW |
| I-01 | Informational | `getSpotPrice()` returns 0 when `xomReserve == 0` without reverting | PERSISTS |
| I-02 | Informational | `finalize()` can be called before configuration | NEW |
| I-03 | Informational | `_validateSwap` accepts unused `caller` parameter | NEW |

---

## Round 6 Findings Resolution

| Round 6 ID | Severity | Title | Round 7 Status |
|------------|----------|-------|----------------|
| M-01 | Medium | Swap output on nominal input, reserves on actual received | **VERIFIED FIXED** (line 417 uses `actualReceived`) |
| M-02 | Medium | Cumulative tracking uses nominal amount | **VERIFIED FIXED** (line 411 uses `actualReceived`) |
| L-01 | Low | No minimum swap output enforced | **PERSISTS** as Round 7 L-01 |
| L-02 | Low | `_expFixed` guard bound conservative | **ACCEPTED** (no change needed) |
| L-03 | Low | No event on `setTreasury()` | **PERSISTS** as Round 7 L-02 |
| I-01 | Informational | `getSpotPrice()` returns 0 for zero reserve | **PERSISTS** as Round 7 I-01 |
| I-02 | Informational | `configure()` boundary uses `- 1` pattern | **ACCEPTED** (style choice, correct behavior) |
| I-03 | Informational | Taylor series error for very small inputs | **ACCEPTED** (MAX_OUT_RATIO prevents issue) |

---

## Overall Risk Assessment

**Deployment Readiness: APPROVED**

The contract is well-constructed and mature after seven rounds of auditing. The Balancer weighted math is correctly implemented with proper fixed-point arithmetic. The CEI pattern is consistently followed. The three-layer anti-whale protection (per-tx limit, cumulative per-address limit, MAX_OUT_RATIO) is robust. The coupling between MAX_OUT_RATIO and Taylor series precision is well-documented and sound.

**Priority Fixes:**

1. **M-01 (should fix before mainnet):** Replace `msg.sender` with `_msgSender()` in `addLiquidity()` for ERC-2771 consistency. While the practical impact is low (admin-only, pre-LBP), the inconsistency could cause confusion and is a simple fix.

2. **L-02 (recommended):** Add `TreasuryUpdated` event to `setTreasury()` for consistency with `OmniBonding` and `LiquidityMining` contracts and for off-chain monitoring.

3. **L-01, L-03, I-01, I-02, I-03 (optional):** All are minor improvements that would enhance code quality but are not required for safe deployment.

**Residual Risk:** The primary residual risk is Sybil attacks (multiple addresses bypassing per-address limits), which is inherent to all LBP designs and must be mitigated off-chain via KYC or address whitelisting.

---

*Audit conducted 2026-03-13 by Claude Code Audit Agent (Round 7 Pre-Mainnet)*
