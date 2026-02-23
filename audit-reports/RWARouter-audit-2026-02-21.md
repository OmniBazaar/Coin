# Security Audit Report: RWARouter

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWARouter.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 660
**Upgradeable:** No (standard deployment)
**Handles Funds:** Yes (routes token transfers through pools)

## Executive Summary

RWARouter is a Uniswap V2-style router for RWA AMM pools. It provides single-hop and multi-hop swap functions with deadline enforcement, slippage protection (`amountOutMin`/`amountInMax`), and liquidity management (`addLiquidity`/`removeLiquidity`). The router calculates fees internally using the classic 997/1000 pattern and calls `IRWAPool.swap()` directly.

The audit found **1 Critical vulnerability**: the router calls pool contracts directly, completely bypassing RWAAMM's compliance checks, pause controls, and fee collection. This is not just a fee issue — it creates a parallel trading path that evades all regulatory compliance. Both agents independently identified this as the fundamental architectural flaw. Additionally, **3 High-severity issues** were found: quote functions return inaccurate amounts vs the actual RWAAMM path, multi-hop swaps bypass pause controls at each hop, and `addLiquidity()` reverts for non-existent pools (unlike RWAAMM which auto-creates them).

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 4 |
| Low | 3 |
| Informational | 2 |

## Findings

### [C-01] Router Bypasses RWAAMM Entirely — Compliance, Fees, and Pause Evasion

**Severity:** Critical
**Lines:** 186-230 (swapExactTokensForTokens), 290-330 (_swap), 370-405 (_getAmountOut)
**Agents:** Both

**Description:**

RWARouter calls `IRWAPool.swap()` directly (line 315), completely bypassing the RWAAMM contract. RWAAMM is the intended entry point for all RWA trading and provides:
1. **Compliance checks** via `_checkSwapCompliance()` and `IRWAComplianceOracle`
2. **Emergency pause** via `emergencyPause` with 3-of-5 multi-sig
3. **Fee collection** via `protocolFee` sent to `FEE_COLLECTOR` / `RWAFeeCollector`
4. **Event emission** for monitoring (`SwapExecuted` events)

The router implements its own fee calculation (997/1000 in `_getAmountOut`) but this fee is never extracted — it becomes a hidden donation to LP providers. The router transfers the full input amount to the pool, then calls `swap()`. Since the pool's K-check has no fee enforcement (see RWAPool audit C-01), the "fee" is simply baked into the worse exchange rate the user gets, with the surplus staying in the pool reserves.

This means:
- **Zero protocol fees collected** — RWAFeeCollector receives nothing from router trades
- **No compliance verification** — sanctioned/non-compliant users trade freely
- **Pause is ineffective** — pausing RWAAMM doesn't affect router swaps
- **No audit trail** — router doesn't emit swap events comparable to RWAAMM

**Impact:** Complete circumvention of OmniBazaar's RWA regulatory compliance infrastructure. Any user who interacts with RWARouter instead of RWAAMM trades RWA security tokens without KYC/accreditation checks, pays zero protocol fees, and is immune to emergency pause.

**Recommendation:** Either:
1. **Delete RWARouter** and route all swaps through RWAAMM (preferred — eliminates the bypass entirely), or
2. **Route through RWAAMM** — have the router call `RWAAMM.swap()` instead of `IRWAPool.swap()`, or
3. **Restrict pool access** — add `onlyFactory` modifier to `RWAPool.swap()` so only RWAAMM can call it (then the router physically cannot bypass)

---

### [H-01] Quote Functions Return Inaccurate Amounts vs Actual RWAAMM Path

**Severity:** High
**Lines:** 370-405 (_getAmountOut), 410-445 (_getAmountIn), 450-460 (getAmountsOut)
**Agent:** Agent B

**Description:**

The router's quote functions use 997/1000 fee adjustment:
```solidity
uint256 amountInWithFee = amountIn * 997;
uint256 numerator = amountInWithFee * reserveOut;
uint256 denominator = reserveIn * 1000 + amountInWithFee;
```

But the actual RWAAMM swap path charges `PROTOCOL_FEE_BPS = 30` (0.30%) differently — it deducts the fee from the input amount before calculating the swap output. The router's 0.3% and RWAAMM's 0.30% produce different results because:
1. Router: fee is embedded in the constant-product formula
2. RWAAMM: fee is deducted upfront, then full remaining amount goes through the formula

Users who call `getAmountsOut()` to preview a swap via the router get one price, but if they then swap through RWAAMM (the correct path), they get a different price. This creates confusion and potential front-running opportunities.

**Impact:** Misleading price quotes. Users relying on router quotes for RWAAMM swaps will experience unexpected slippage.

**Recommendation:** If the router is retained (see C-01), its quote functions should use the same fee calculation as RWAAMM, or be clearly documented as router-specific quotes.

---

### [H-02] Multi-Hop Swaps Bypass Pause Controls at Each Hop

**Severity:** High
**Lines:** 290-330 (_swap)
**Agent:** Agent B

**Description:**

Multi-hop swaps (e.g., `swapExactTokensForTokens` with a `path` of 3+ tokens) iterate through intermediate pools via `_swap()`. Each hop calls `IRWAPool.swap()` directly. Even if RWAAMM's `emergencyPause` is activated for a specific token pair, the router will continue swapping through that pair's pool.

This is especially dangerous for multi-hop paths where one intermediate pair has been paused due to a security incident (e.g., a compliance breach, oracle failure, or liquidity crisis). The pause is meant to halt all trading, but the router ignores it.

**Impact:** Emergency pause is ineffective for router-originated trades. Security incidents cannot be contained by pausing RWAAMM.

**Recommendation:** Resolved by fixing C-01 (routing through RWAAMM or restricting pool access).

---

### [H-03] addLiquidity Reverts for Non-Existent Pools

**Severity:** High
**Lines:** 95-140 (addLiquidity), 530-550 (_getPool)
**Agents:** Both

**Description:**

`addLiquidity()` calls `_getPool()` which queries `IRWAAMMFactory(factory).getPool(tokenA, tokenB)`. If no pool exists, `_getPool()` returns `address(0)`, and the subsequent calls to the pool contract revert with an opaque error. Compare to RWAAMM's `addLiquidity()` (line 512-514), which auto-creates pools:
```solidity
if (pool == address(0)) {
    pool = _createPool(token0, token1);
}
```

The router provides no equivalent functionality. Users who try to add liquidity for a new token pair via the router will get an unhelpful revert.

**Impact:** Router cannot be used for initial liquidity provision. Users must know to use RWAAMM directly for the first deposit, creating a confusing UX split.

**Recommendation:** Either add auto-pool-creation to the router (calling `RWAAMM.createPool()`), or clearly document that the router is for existing pools only and initial liquidity must go through RWAAMM.

---

### [M-01] No Minimum amountOut Enforcement — Sandwich Attack Vector

**Severity:** Medium
**Lines:** 186 (swapExactTokensForTokens parameter)
**Agent:** Agent A

**Description:**

The `amountOutMin` parameter accepts `0`, meaning a user can submit a swap with zero slippage protection. While this is the user's choice, front-end applications and integrators may default to `amountOutMin = 0`, making users vulnerable to sandwich attacks where a MEV bot front-runs the transaction, moves the price, and extracts value.

Unlike Uniswap's router which also accepts 0, RWA tokens have lower liquidity and wider spreads, making sandwich attacks more profitable per transaction.

**Impact:** Users who set `amountOutMin = 0` lose value to MEV. Given RWA tokens' typically low liquidity, the impact per trade is higher than in mainstream DeFi.

**Recommendation:** Consider requiring `amountOutMin > 0` or adding a maximum slippage parameter (e.g., 5%) that the contract enforces even if the user doesn't specify one.

---

### [M-02] Fee-on-Transfer Token Loss

**Severity:** Medium
**Lines:** 305-310 (_swap)
**Agent:** Agent B

**Description:**

The router calculates the expected output based on the full `amountIn`, then transfers tokens to the pool. If either token charges a transfer fee, the pool receives less than expected. The pool's K-check may pass (if the shortfall is small enough) but the output amount will be less than quoted, or the K-check will fail with an opaque `KValueDecreased` error.

**Impact:** Fee-on-transfer RWA tokens are silently broken or produce unexpected results.

**Recommendation:** Measure actual balance changes instead of assuming transfer amounts. Or document this as an unsupported token type.

---

### [M-03] Cross-Pool Reentrancy in Multi-Hop Swaps

**Severity:** Medium
**Lines:** 290-330 (_swap)
**Agent:** Agent A

**Description:**

Multi-hop swaps involve sequential pool interactions. If an intermediate token has transfer callbacks (ERC-777 `tokensReceived`, ERC-3643 hooks), a callback during one hop could re-enter the router before the next hop completes. The router has no reentrancy guard (`nonReentrant` modifier is absent).

While each individual pool has its own `lock` modifier preventing re-entry into that specific pool, a callback could re-enter the router and initiate a new swap through a different pool, potentially exploiting price inconsistencies during the multi-hop execution.

**Impact:** Potential price manipulation during multi-hop swaps via callback-enabled tokens.

**Recommendation:** Add OpenZeppelin's `ReentrancyGuard` to all swap and liquidity functions.

---

### [M-04] WRAPPED_NATIVE Declared But Never Used

**Severity:** Medium
**Lines:** 30 (WRAPPED_NATIVE declaration)
**Agent:** Agent B

**Description:**

`address public immutable WRAPPED_NATIVE` is declared and set in the constructor but is never referenced in any function. There are no `swapExactETHForTokens` or `swapTokensForExactETH` functions. This suggests incomplete implementation of native token wrapping functionality.

If native token swaps were intended but not implemented, users expecting this functionality will be confused. The constructor requires a valid `WRAPPED_NATIVE` address, wasting a deployment parameter.

**Impact:** Dead code. Missing feature if native token swaps were intended.

**Recommendation:** Either implement native token swap functions or remove the `WRAPPED_NATIVE` parameter.

---

### [L-01] Post-Swap Output Amount Not Verified Against Pool Balance

**Severity:** Low
**Lines:** 315-320 (_swap)
**Agent:** Agent A

**Description:**

After calling `pool.swap()`, the router does not verify that the recipient actually received the expected output tokens. While the pool's K-check provides some protection, for tokens with non-standard transfer behavior (rebasing, hooks), the actual received amount may differ.

**Recommendation:** Check the recipient's balance change after the swap for critical applications.

---

### [L-02] No Path Cycle Detection in Multi-Hop

**Severity:** Low
**Lines:** 290-330 (_swap)
**Agent:** Agent A

**Description:**

The `path` array in multi-hop swaps is not validated for cycles (e.g., `[A, B, A]`). A cyclic path would result in a swap that ends where it started, wasting gas and potentially creating arbitrage opportunities that extract value from intermediate pools.

**Recommendation:** Add a check that no token appears more than once in the path array.

---

### [L-03] Misleading Error Messages

**Severity:** Low
**Lines:** Various custom errors
**Agents:** Both

**Description:**

Several error messages are misleading:
- `InsufficientOutputAmount` is thrown even when the issue is the pool not existing
- `InvalidPath` only checks `path.length >= 2` but doesn't validate token addresses
- No specific error for "pool doesn't exist" — users get opaque reverts from `_getPool`

**Recommendation:** Add `PoolNotFound(address tokenA, address tokenB)` error and use it in `_getPool()`.

---

### [I-01] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:** Uses `^0.8.20`. For deployed contracts, pin to a specific version.

---

### [I-02] RWAFeeCollector Receives Zero Fees from Router Path

**Severity:** Informational
**Agent:** Agent B

**Description:**

The RWAFeeCollector contract is designed to receive and distribute protocol fees from RWAAMM. Since the router bypasses RWAAMM entirely, any trading volume routed through the router generates zero revenue for the protocol's fee distribution system (staking pool, liquidity pool, ODDAO). This is a direct economic consequence of C-01.

**Recommendation:** Resolved by fixing C-01.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 24 raw findings -> 13 unique)
- Pass 6: Report generation

## Conclusion

RWARouter has **one fundamental architectural flaw that undermines the entire RWA compliance infrastructure**:

1. **Direct pool access (C-01)** — the router calls `IRWAPool.swap()` directly, bypassing RWAAMM's compliance checks, fee collection, pause controls, and event emission. This creates a parallel, unregulated trading path for security tokens. Combined with the RWAPool's lack of fee enforcement (RWAPool C-01) and access control (RWAPool H-02), the router provides a complete workaround for every security measure in the RWA stack.

2. **Inaccurate quotes (H-01)** — users who preview swaps via the router get different prices than the RWAAMM path, creating confusion and MEV opportunities.

3. **Pause bypass (H-02)** — emergency controls are ineffective against router-originated trades.

4. **No pool creation (H-03)** — the router cannot be used for initial liquidity provision.

**Strong recommendation:** Either delete `RWARouter.sol` entirely (routing all trades through RWAAMM), or restrict `RWAPool.swap()` to factory-only access. The router in its current form creates a regulatory and economic bypass that defeats the purpose of the entire RWA compliance system.

**Cross-contract note:** This finding is shared with RWAPool C-01, RWAPool H-02, and the RWAComplianceOracle audit. The root cause is architectural: the RWA stack has two entry points (RWAAMM and RWARouter) but only one (RWAAMM) enforces compliance and fees.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
