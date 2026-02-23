# Security Audit Report: RWAPool

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWAPool.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 379
**Upgradeable:** No (factory-deployed)
**Handles Funds:** Yes (holds token reserves for AMM swaps and LP positions)

## Executive Summary

RWAPool is a Uniswap V2-style constant-product AMM pool for Real World Asset tokens. It supports LP token minting/burning, swaps with flash swap callbacks, a cumulative price oracle for TWAP, and utility functions (`skim`, `sync`). Pools are created by the RWAAMM factory and are intended to be accessed through the RWAAMM router, which handles compliance checks, fees, and routing.

The audit found **1 Critical vulnerability**: the pool enforces NO fee in its K-value invariant check, meaning anyone who calls `swap()` directly (bypassing RWAAMM) executes zero-fee swaps, completely circumventing the protocol's economic model and compliance controls. Both agents independently confirmed this as the root cause of multiple downstream issues. Additionally, **3 High-severity issues** were found: the TWAP oracle uses integer division instead of UQ112x112 fixed-point (breaking the oracle for mixed-decimal pairs), no access control on pool functions (bypassing compliance/pause controls), and the first-depositor share inflation attack. These four findings share a common root cause: the pool was designed as a "dumb" primitive with all security delegated to RWAAMM, but unlike Uniswap V2, the pool doesn't enforce fees internally.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 3 |
| Low | 4 |
| Informational | 2 |

## Findings

### [C-01] No Fee Enforcement in K-Value Invariant — Zero-Fee Direct Pool Access

**Severity:** Critical
**Lines:** 274-279
**Agents:** Both

**Description:**

The K-value invariant check in `swap()` uses raw, unadjusted balances:
```solidity
uint256 balance0Adjusted = balance0;
uint256 balance1Adjusted = balance1;
if (balance0Adjusted * balance1Adjusted < _reserve0 * _reserve1) {
    revert KValueDecreased();
}
```

In Uniswap V2, the pool enforces fees by adjusting balances with a 0.3% penalty:
```solidity
// Uniswap V2 (for comparison)
uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
require(balance0Adjusted.mul(balance1Adjusted) >= _reserve0.mul(_reserve1).mul(1000**2));
```

The comment states "Fee is handled by RWAAMM, not the pool." But since `swap()` is `external` with no access control, anyone can call it directly, bypassing RWAAMM entirely. A direct caller transfers tokens to the pool, then calls `swap()` — the pool only checks that K hasn't decreased, accepting zero-fee swaps.

This simultaneously bypasses: protocol fees (0.3%), the 70/20/10 fee split, compliance oracle checks, pause controls, deadline checks, and slippage protection.

**Impact:** 100% fee bypass. LP providers earn zero from trading activity. The protocol's economic model is completely broken. Any user who discovers this can trade RWA tokens with zero fees indefinitely.

**Recommendation:** Either enforce fees inside the pool (preferred):
```solidity
uint256 balance0Adjusted = balance0 * 10000 - amount0In * 30;
uint256 balance1Adjusted = balance1 * 10000 - amount1In * 30;
require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * 10000 ** 2);
```
Or restrict `swap()` to factory-only access:
```solidity
if (msg.sender != factory) revert NotFactory();
```

---

### [H-01] TWAP Oracle Missing UQ112x112 Fixed-Point — Zero Precision for Mixed-Decimal Pairs

**Severity:** High
**Lines:** 346-349
**Agents:** Both

**Description:**

The cumulative price calculation uses plain integer division:
```solidity
unchecked {
    price0CumulativeLast += (_reserve1 * timeElapsed) / _reserve0;
    price1CumulativeLast += (_reserve0 * timeElapsed) / _reserve1;
}
```

Uniswap V2 uses UQ112x112 fixed-point: multiply by `2**112` before dividing to preserve 112 bits of fractional precision. Without this, `_reserve1 / _reserve0` truncates to zero whenever `_reserve1 < _reserve0`.

For RWA pools this is catastrophic: a pool with XOM (18 decimals) and a 6-decimal stablecoin will have `reserve1 / reserve0 = 0` for most price ratios, making the TWAP oracle permanently report zero.

**Impact:** TWAP oracle is non-functional for any token pair where one token's reserve is numerically smaller than the other. Any protocol relying on this oracle for pricing, lending, or liquidation will get zero/incorrect prices.

**Recommendation:** Implement UQ112x112 fixed-point:
```solidity
unchecked {
    price0CumulativeLast += (uint256(_reserve1) << 112) / uint256(_reserve0) * timeElapsed;
    price1CumulativeLast += (uint256(_reserve0) << 112) / uint256(_reserve1) * timeElapsed;
}
```

---

### [H-02] No Access Control on Core Functions — Compliance and Pause Bypass

**Severity:** High
**Lines:** 155 (mint), 189 (burn), 236 (swap), 291 (sync), 300 (skim)
**Agents:** Both

**Description:**

All core pool functions are `external` with no access control beyond the reentrancy lock. While this mirrors Uniswap V2's permissionless design, the context is fundamentally different:

1. **RWAAMM performs compliance checks** (`_checkSwapCompliance`) via `IRWAComplianceOracle`. Direct pool calls bypass all compliance.
2. **RWAAMM has pause functionality** (`emergencyPause`). Direct pool calls bypass emergency controls.
3. **RWA tokens may legally require KYC/accredited investor verification.** Direct `mint()`/`burn()` calls allow non-compliant users to provide liquidity.

In Uniswap V2, bypassing the router only loses convenience. Here, bypassing RWAAMM evades the core security and legal compliance guarantees of the system.

**Impact:** Sanctioned or non-compliant users can trade and provide liquidity for regulated RWA tokens by interacting directly with pool contracts. Emergency pause is ineffective.

**Recommendation:** Add `onlyFactory` modifier to `swap()`, `mint()`, and `burn()`. Keep `sync()` and `skim()` permissionless.

---

### [H-03] First Depositor Share Inflation Attack

**Severity:** High
**Lines:** 164-167
**Agents:** Both

**Description:**

The first deposit mints `sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY` LP tokens, with `MINIMUM_LIQUIDITY = 1000` burned to the dead address. While this matches Uniswap V2, the protection is insufficient for low-decimal RWA tokens:

1. Attacker deposits 1001 wei of each token, receives 1 LP token (1000 burned)
2. Attacker donates large amount directly to pool via `transfer()`, then calls `sync()`
3. Each LP token now represents a large amount of underlying
4. Next depositor's `mint()` calculation rounds down to 0 LP tokens, losing entire deposit

For 18-decimal tokens, MINIMUM_LIQUIDITY = 1000 makes the attack cost prohibitive. For 6-decimal RWA tokens (like USDC-style), 1000 units = $0.001, making the attack very cheap.

**Impact:** First depositor can steal value from subsequent depositors. More severe for low-decimal tokens common in RWA markets.

**Recommendation:** Either increase MINIMUM_LIQUIDITY significantly, require minimum first deposit amounts, or implement virtual shares (OpenZeppelin ERC4626 offset pattern).

---

### [M-01] Free Flash Swaps — No Fee Cost

**Severity:** Medium
**Lines:** 254-256, 274-279
**Agents:** Both

**Description:**

The flash swap mechanism allows optimistic token receipt with a callback, requiring only that K doesn't decrease afterward. Since the K-check has no fee adjustment (C-01), flash swaps are completely free. An attacker can borrow pool assets, use them for arbitrage or oracle manipulation, and return exactly the borrowed amount with zero cost.

In Uniswap V2, the fee-adjusted K-check ensures flash swaps cost 0.3%.

**Impact:** Free flash loans that bypass all protocol fees. Can be used to manipulate external protocols at zero cost to the attacker.

**Recommendation:** Resolved by fixing C-01 (fee-adjusted K-check).

---

### [M-02] Missing Swap Event in Pool Contract

**Severity:** Medium
**Lines:** 231-282
**Agent:** Agent B

**Description:**

The `swap()` function emits no `Swap` event. Only `Sync` is emitted (from `_update()`). While RWAAMM emits its own swap event, direct pool interactions (possible per H-02) produce no swap audit trail. Uniswap V2 Pair emits `Swap(sender, amount0In, amount1In, amount0Out, amount1Out, to)` on every swap.

**Impact:** Direct pool swaps are invisible to block explorers, indexers, and monitoring systems.

**Recommendation:** Add and emit a `Swap` event in the pool contract.

---

### [M-03] Read-Only Reentrancy in burn() — Stale Reserves During Transfer Callbacks

**Severity:** Medium
**Lines:** 208-218
**Agent:** Agent A

**Description:**

In `burn()`, LP tokens are burned and tokens transferred BEFORE reserves are updated:
```solidity
_burn(address(this), liquidity);                    // Line 208
IERC20(token0).safeTransfer(to, amount0);           // Line 211
IERC20(token1).safeTransfer(to, amount1);           // Line 212
// ... then _update() on line 218
```

During the `safeTransfer` calls, if either token triggers a callback (ERC-777 `tokensReceived`, ERC-3643 hooks), external contracts reading `getReserves()` see stale (inflated) reserves while actual balances are already reduced. The `lock` modifier prevents re-entering the pool, but doesn't prevent external protocols from reading stale reserves.

**Impact:** Lending protocols that price LP tokens using `getReserves()` can be manipulated during the callback window.

**Recommendation:** Update reserves BEFORE transfers:
```solidity
_update(balance0 - amount0, balance1 - amount1, reserve0, reserve1);
IERC20(token0).safeTransfer(to, amount0);
IERC20(token1).safeTransfer(to, amount1);
```

---

### [L-01] Missing Zero-Address/Self Checks in initialize()

**Severity:** Low
**Lines:** 123-129
**Agent:** Agent A

**Description:**

`initialize()` doesn't validate `_token0 != address(0)`, `_token1 != address(0)`, or `_token0 != _token1`. While RWAAMM validates these, the pool should enforce independently.

**Recommendation:** Add validation checks.

---

### [L-02] Missing Zero-Address Check on mint() `to` Parameter

**Severity:** Low
**Lines:** 155
**Agent:** Agent A

**Description:**

`mint()` doesn't check for `address(0)` or `address(this)`. OpenZeppelin's ERC20 `_mint` will revert on `address(0)`, but minting to `address(this)` would lock LP tokens.

**Recommendation:** Add `if (to == address(0) || to == address(this)) revert InvalidRecipient();`

---

### [L-03] kLast Updated But Never Used

**Severity:** Low
**Lines:** 181, 219
**Agent:** Agent B

**Description:**

`kLast` is updated after every `mint()` and `burn()` but is never read by any internal function. In Uniswap V2, `kLast` is used for protocol fee accrual via `_mintFee()`. This contract has no `_mintFee()`, so `kLast` updates waste ~5,000 gas per mint/burn.

**Recommendation:** Either implement protocol fee accrual or remove `kLast` updates.

---

### [L-04] No Fee-on-Transfer Token Support

**Severity:** Low
**Lines:** 249-251
**Agent:** Agent B

**Description:**

If either token charges a transfer fee, the actual amount received by the pool is less than the transfer amount. The K-check will fail with an opaque `KValueDecreased` error, making fee-on-transfer tokens completely unusable.

**Recommendation:** Document this limitation or measure actual balance changes instead of relying on transfer amounts.

---

### [I-01] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:** Uses `^0.8.20`. For deployed contracts, pin to a specific version.

---

### [I-02] Fee Split Constants in RWAAMM Are Decorative

**Severity:** Informational
**Agent:** Agent B

**Description:**

RWAAMM defines `FEE_LP_BPS`, `FEE_STAKING_BPS`, `FEE_LIQUIDITY_BPS` constants but sends the entire `protocolFee` to a single `FEE_COLLECTOR` address. The declared 70/20/10 split is not enforced on-chain.

**Recommendation:** Either implement on-chain fee splitting or remove the unused constants.

---

## Static Analysis Results

**Solhint:** 0 errors, 5 warnings
- 2 ordering issues (style)
- 2 code-complexity (functions with >7 branches)
- 1 gas-strict-inequality

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 25 raw findings -> 13 unique)
- Pass 6: Report generation

## Conclusion

RWAPool has **a fundamental architectural flaw that breaks the protocol's economic model**:

1. **No fee in K-check (C-01)** — the pool accepts zero-fee swaps from anyone who calls it directly. This single issue cascades into multiple downstream vulnerabilities: free flash loans, LP providers earning nothing, and protocol revenue bypass.

2. **Broken TWAP oracle (H-01)** — missing UQ112x112 fixed-point makes the oracle return 0 for mixed-decimal pairs (the primary use case for RWA tokens).

3. **No access control (H-02)** — compliance checks, pause controls, and fee collection are all bypassable.

4. **First depositor attack (H-03)** — especially dangerous for low-decimal RWA tokens.

**Root cause:** The contract delegates ALL security to the RWAAMM router, but unlike Uniswap V2, does not enforce fees internally. In Uniswap V2, the router is a convenience layer; here, the router is a security layer — but any user can bypass it. The fix is straightforward: add fee-adjusted K-check inside the pool (matching Uniswap V2's approach) and restrict state-changing functions to factory-only access.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
