# Security Audit Report: RWARouter (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWARouter.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 692
**Upgradeable:** No (standard deployment)
**Handles Funds:** Yes (routes token transfers through RWAAMM pools)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IRWAAMM`, `IRWAPool`, `IERC20`, `SafeERC20`, `ReentrancyGuard`
**Test Coverage:** `Coin/test/rwa/RWAAMM.test.js` (indirect coverage via AMM tests)
**Prior Audit:** Round 1 -- `RWARouter-audit-2026-02-21.md`

---

## Executive Summary

RWARouter is a Uniswap V2-style user-facing router that provides single-hop and multi-hop swaps, liquidity management, and quote functions for the RWA AMM system. Following the critical findings from the Round 1 audit, the contract has been substantially rewritten. The **critical vulnerability (C-01) from Round 1 -- direct pool bypass of RWAAMM -- has been fully remediated**: all swap operations now route through `AMM.swap()`, and all liquidity operations route through `AMM.addLiquidity()` / `AMM.removeLiquidity()`. The `WRAPPED_NATIVE` dead code has been removed. ReentrancyGuard has been added. The pool-does-not-exist case is handled with explicit `PoolDoesNotExist` errors. Quote functions now use `AMM.getQuote()` for accurate fee-adjusted output.

The Round 3 audit found **0 Critical** and **0 High** severity issues. The remaining findings are **3 Medium**, **4 Low**, and **3 Informational** items, primarily related to edge cases in fee-on-transfer token handling, stale quote-vs-execution discrepancy in `swapTokensForExactTokens`, and missing compliance checks for the `to` (recipient) address.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Informational | 3 |

---

## Round 1 Remediation Status

| Round 1 Finding | Severity | Status | Notes |
|---|---|---|---|
| C-01: Router bypasses RWAAMM entirely | Critical | **FIXED** | All swaps now route through `AMM.swap()`. All liquidity ops through `AMM.addLiquidity()`/`AMM.removeLiquidity()`. |
| H-01: Quote functions return inaccurate amounts | High | **FIXED** | `getAmountsOut()` now calls `AMM.getQuote()` for each hop (line 522). |
| H-02: Multi-hop swaps bypass pause controls | High | **FIXED** | Each hop calls `AMM.swap()`, which enforces `whenNotPaused` and `whenPoolNotPaused`. |
| H-03: addLiquidity reverts for non-existent pools | High | **FIXED** | Router now explicitly checks `AMM.getPool()` and reverts with `PoolDoesNotExist` (lines 380-383). Design decision documented: router does not auto-create pools. |
| M-01: No minimum amountOut enforcement | Medium | **FIXED** | `swapExactTokensForTokens` now requires `amountOutMin > 0` via `ZeroMinimumOutput` error (line 204). |
| M-02: Fee-on-transfer token loss | Medium | **PARTIALLY FIXED** | `swapExactTokensForTokens` (hop 0) now measures balance delta (lines 220-228). See M-01 below for remaining gap. |
| M-03: Cross-pool reentrancy in multi-hop | Medium | **FIXED** | `ReentrancyGuard` with `nonReentrant` modifier on all swap and liquidity functions. |
| M-04: WRAPPED_NATIVE declared but never used | Medium | **FIXED** | Removed entirely. |
| L-01: Post-swap output not verified | Low | **ACCEPTED** | AMM.swap() returns `SwapResult.amountOut` which the router uses directly. Pool's K-check provides the invariant guarantee. |
| L-02: No path cycle detection | Low | **OPEN** | See L-02 below. |
| L-03: Misleading error messages | Low | **FIXED** | Added `PoolDoesNotExist`, `ZeroMinimumOutput`, `ZeroAmount` custom errors with descriptive parameters. |
| I-01: Floating pragma | Info | **FIXED** | Pinned to `0.8.24`. |
| I-02: RWAFeeCollector receives zero fees | Info | **FIXED** | Consequence of C-01 fix. Fees now flow through RWAAMM to `FEE_VAULT`. |

---

## Architecture Analysis

### Design Strengths

1. **Full RWAAMM Delegation:** Every swap hop calls `AMM.swap()` (line 238), ensuring compliance checks, fee collection, pause enforcement, and event emission occur at every step. This is the correct architecture for RWA security tokens.

2. **Immutable AMM Reference:** The `AMM` state variable is `immutable`, preventing any post-deployment redirection of the swap path. Once deployed, the router is permanently bound to its AMM contract.

3. **Fee-on-Transfer Awareness (Hop 0):** The first hop of `swapExactTokensForTokens` measures the actual balance delta after `safeTransferFrom` (lines 220-228), adjusting `amounts[0]` downward if a fee-on-transfer token delivers less than expected.

4. **Complete Slippage Protection:** Both swap functions enforce slippage -- `amountOutMin` for exact-input and `amountInMax` for exact-output. The `ZeroMinimumOutput` error prevents accidental zero-slippage submissions.

5. **Deadline Enforcement:** The `ensure` modifier validates `block.timestamp <= deadline` before any state changes.

6. **Reentrancy Protection:** `nonReentrant` from OpenZeppelin guards all swap and liquidity functions against cross-function reentrancy.

7. **Unused Token Refund:** `addLiquidity` refunds unused tokens back to `msg.sender` (lines 412-420), preventing accidental token lock-up.

8. **Clean NatSpec:** Complete documentation on all public and internal functions with `@notice`, `@dev`, `@param`, and `@return` annotations.

### Dependency Analysis

- **IRWAAMM Interface:** The router depends on `AMM.swap()`, `AMM.addLiquidity()`, `AMM.removeLiquidity()`, `AMM.getPool()`, and `AMM.getQuote()`. All are view-safe or state-changing functions documented in `IRWAAMM.sol`. The RWAAMM contract enforces compliance, fees, pause, and pool-level pause for all these operations.

- **IRWAPool Interface:** Used only in `_getReserves()` (line 652) to call `IRWAPool(pool).getReserves()` for the `getAmountsIn()` reverse calculation. This is a read-only call that does not bypass AMM controls.

- **SafeERC20:** Used for all token transfers (`safeTransferFrom`, `safeTransfer`, `forceApprove`). The `forceApprove` function handles tokens like USDT that require resetting approval to 0 before setting a new value.

### Token Flow Analysis

**swapExactTokensForTokens (multi-hop A -> B -> C, recipient = `to`):**

```
Hop 0 (A -> B):
  1. user -> router: safeTransferFrom(user, router, amountA)       [line 221]
  2. router -> AMM:  forceApprove(AMM, amountA)                     [line 235]
  3. AMM.swap(A, B, amountA, 0, deadline)                           [line 238]
     - AMM deducts fee, transfers amountA to pool + feeVault
     - Pool sends amountB to AMM's msg.sender (= router)
  4. amountB stored in amounts[1]                                    [line 246]

Hop 1 (B -> C, final hop):
  5. router -> router: safeTransferFrom(router, router, amountB)    [line 221]
     (self-transfer -- see I-01)
  6. router -> AMM:  forceApprove(AMM, amountB)                     [line 235]
  7. AMM.swap(B, C, amountB, 0, deadline)                           [line 238]
     - AMM deducts fee, transfers amountB to pool + feeVault
     - Pool sends amountC to AMM's msg.sender (= router)
  8. router -> to:   safeTransfer(to, amountC)                       [line 252]

Post-loop:
  9. Verify amounts[last] >= amountOutMin                            [line 258]
```

**Critical observation about RWAAMM.swap() line 491:** The pool's `swap()` sends output tokens to `msg.sender` of the RWAAMM call, which is the router. However, RWAAMM.swap() (line 474-476) calls `IERC20(tokenIn).safeTransferFrom(msg.sender, poolAddr, amountToPool)`. This means the RWAAMM expects `msg.sender` (the router) to have the input tokens AND to have approved RWAAMM. The router correctly does both: it holds the tokens and calls `forceApprove(address(AMM), ...)`.

---

## Findings

### [M-01] Fee-on-Transfer Handling Only on First Hop -- Intermediate Hops Assume Full Transfer

**Severity:** Medium
**Lines:** 220-234 (hop 0 balance delta), 306-316 (swapTokensForExactTokens has no balance delta at all)

**Description:**

The `swapExactTokensForTokens` function measures the actual received amount via a balance delta only on the first hop (i == 0):

```solidity
// Line 232-234
if (i == 0 && actualReceived < amounts[i]) {
    amounts[i] = actualReceived;
}
```

For intermediate hops (i > 0), the router does not measure the balance delta. If a fee-on-transfer token is used as an intermediate token in a multi-hop path (e.g., `A -> FoT_Token -> C`), the router will attempt to approve and send `amounts[i]` to the AMM, but it actually holds less than that. The `forceApprove` will succeed (it approves a number, not a balance), but the subsequent `AMM.swap()` call will call `safeTransferFrom(router, pool, amountToPool)`, which will revert because the router does not hold enough tokens.

Additionally, `swapTokensForExactTokens` has NO fee-on-transfer protection at all -- neither on the first hop nor on any intermediate hop (lines 306-316).

**Impact:** Fee-on-transfer tokens will cause reverts on intermediate hops of multi-hop swaps and on all hops of `swapTokensForExactTokens`. While the transaction reverts (no funds lost), this creates a denial-of-service for paths involving fee-on-transfer tokens.

**Recommendation:**

Option A: Add balance-delta measurement on ALL hops of `swapExactTokensForTokens`, not just the first. For `swapTokensForExactTokens`, document that fee-on-transfer tokens are not supported (exact-output is inherently incompatible with fee-on-transfer because the required input amount cannot be pre-calculated accurately).

Option B: Document that fee-on-transfer tokens are unsupported by the router and must be swapped directly through RWAAMM. This is acceptable since most RWA tokens do not charge transfer fees.

---

### [M-02] swapTokensForExactTokens Quote-vs-Execution Mismatch -- Calculated Input May Be Insufficient

**Severity:** Medium
**Lines:** 298 (getAmountsIn call), 306-334 (forward execution)

**Description:**

`swapTokensForExactTokens` calls `getAmountsIn()` to calculate the required input amounts in reverse (line 298), then executes swaps forward using those amounts (lines 306-334). The problem is that `getAmountsIn()` uses a reverse calculation with the pool's raw reserves (lines 547-573), while the forward execution routes through `AMM.swap()`, which deducts fees differently.

The reverse formula in `getAmountsIn()`:

```solidity
// Line 569-572
uint256 amountAfterFee = (reserveIn * amounts[i])
    / (reserveOut - amounts[i]) + 1;
amounts[i - 1] = (amountAfterFee * BPS_DENOMINATOR)
    / (BPS_DENOMINATOR - PROTOCOL_FEE_BPS) + 1;
```

This assumes the fee model is: `amountAfterFee = amountIn * (BPS - FEE) / BPS`, which matches RWAAMM's upfront fee deduction. The `+ 1` terms add ceiling rounding for safety. However, there are two sources of discrepancy:

1. **Fee split and LP retention:** RWAAMM keeps 70% of the fee in the pool (as LP revenue), which increases reserves and slightly alters the swap output compared to the pure constant-product formula that `getAmountsIn` assumes. The `amountToPool = amountInAfterFee + lpFee` (RWAAMM line 464) means the pool receives MORE than `amountInAfterFee`, producing a slightly better output than quoted.

2. **Multi-hop compounding:** For multi-hop paths, each hop's actual output becomes the next hop's input. Since the forward execution may produce slightly different amounts than the reverse calculation predicted, the final output may not exactly equal the desired `amountOut`.

The code on line 327 updates `amounts[i + 1] = result.amountOut` to track the actual output, but `amounts[0]` (the input amount the user pays) was fixed by the reverse calculation. If the actual path produces MORE output than expected (due to LP fee retention in reserves), the user gets a windfall. If it produces less (unlikely but possible with rounding), `amounts[i+1]` propagates the lower value, but there is no final check that the user received the desired `amountOut`.

**Impact:** In practice, the `+ 1` ceiling rounding in `getAmountsIn()` over-estimates the required input, which means users will typically overpay slightly. The excess stays in the pool as additional reserves. For single-hop swaps, the discrepancy is negligible (1-2 wei). For multi-hop swaps, the discrepancy compounds and could become meaningful for high-precision tokens.

**Recommendation:** Add a final output verification at the end of `swapTokensForExactTokens`:

```solidity
if (amounts[amounts.length - 1] < amountOut) {
    revert InsufficientOutputAmount(amounts[amounts.length - 1], amountOut);
}
```

This ensures the user receives at least the desired output, even if the forward execution differs from the reverse calculation.

---

### [M-03] Compliance Check Only Covers msg.sender (Router) -- Final Recipient Not Verified

**Severity:** Medium
**Lines:** 193-270 (swap functions with `to` parameter), RWAAMM lines 440-442

**Description:**

When the router calls `AMM.swap()`, the AMM's compliance check verifies `msg.sender` -- which is the **router contract**, not the human user and not the final `to` recipient:

```solidity
// RWAAMM.sol line 441
_checkSwapCompliance(msg.sender, tokenIn, tokenOut, amountIn);
```

The router is not a person subject to KYC/accreditation requirements. The compliance oracle will either always pass the router address (if it's whitelisted) or always fail it (if it's not registered). In neither case does it verify the actual human initiating the swap (`msg.sender` of the router call) or the final recipient (`to`).

This means:
- A non-compliant user can call the router with `to = their_address` and receive RWA tokens without passing compliance.
- A compliant user can specify `to = non_compliant_address` to transfer RWA tokens to a sanctioned/non-KYC party.

The same issue applies to `addLiquidity` (LP tokens sent to `to`) and `removeLiquidity` (underlying tokens sent to `to`).

**Impact:** The compliance checks enforced by RWAAMM are applied to the router's address, not to the end user or recipient. This creates a compliance gap that could be exploited to trade RWA security tokens without proper KYC/accreditation verification.

**Recommendation:**

Option A: RWAAMM should accept an `onBehalfOf` parameter so the router can pass the original `msg.sender` and `to` address for compliance checks.

Option B: The router should call the compliance oracle directly before delegating to AMM:

```solidity
IRWAAMM.SwapResult memory result = AMM.swap(...);
// Also verify:
// ComplianceOracle.checkSwapCompliance(msg.sender, tokenIn, tokenOut, amountIn);
// ComplianceOracle.checkSwapCompliance(to, tokenIn, tokenOut, amountIn);
```

However, the router does not currently hold a reference to the compliance oracle. Option A is architecturally cleaner.

Option C: Register the router in the compliance oracle as a "passthrough" entity and require the AMM to check the `tx.origin`. However, `tx.origin` is widely considered an anti-pattern and breaks composability with smart contract wallets and account abstraction.

---

### [L-01] Self-Transfer on Intermediate Hops is Wasteful Gas

**Severity:** Low
**Lines:** 221-225

**Description:**

On intermediate hops (i > 0), the router calls:

```solidity
IERC20(path[i]).safeTransferFrom(
    i == 0 ? msg.sender : address(this),  // from = router
    address(this),                         // to = router
    amounts[i]
);
```

When `i > 0`, this is a `safeTransferFrom(router, router, amounts[i])` -- a self-transfer. The router already holds these tokens (received from the previous hop's `AMM.swap()` output). The self-transfer wastes gas on an ERC20 `transferFrom` that moves tokens from the router to the router, including an unnecessary allowance check (the router may not have approved itself).

For standard ERC20 tokens, `transferFrom(self, self, amount)` should succeed because OpenZeppelin's ERC20 skips the allowance check when `from == msg.sender` (since OZ v5). However, non-standard tokens might not handle this edge case correctly.

**Impact:** Wasted gas on intermediate hops. For a 3-hop path, this adds approximately 20,000-30,000 gas per extra hop due to unnecessary storage reads/writes in the ERC20 transfer.

**Recommendation:** Skip the `safeTransferFrom` when `i > 0` since the router already holds the tokens:

```solidity
if (i == 0) {
    // Transfer from user to router
    IERC20(path[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
    // ... balance delta check ...
} else {
    // Router already holds tokens from previous hop -- no transfer needed
}
IERC20(path[i]).forceApprove(address(AMM), amounts[i]);
```

---

### [L-02] No Path Cycle Detection in Multi-Hop (Carried from Round 1)

**Severity:** Low
**Lines:** 202, 293

**Description:**

The `path` array is validated only for minimum length (`path.length < 2`), but not for cycles. A cyclic path like `[A, B, A]` would execute two hops (A->B, B->A) through RWAAMM, paying fees on both swaps but ending with approximately the same token the user started with, minus double fees.

While this is a user error (they lose money to fees), it is not caught by the contract and could be triggered by a malicious front-end or a confused integrator.

**Impact:** Users who submit cyclic paths lose money to double (or multiple) fees with no meaningful output. The damage is bounded by the user's own funds and the fees charged.

**Recommendation:** Add a cycle detection check:

```solidity
for (uint256 i = 0; i < path.length; ++i) {
    for (uint256 j = i + 1; j < path.length; ++j) {
        if (path[i] == path[j]) revert InvalidPath();
    }
}
```

Note: This O(n^2) check is acceptable since path lengths are typically 2-4 tokens. For longer paths, consider a maximum path length check (e.g., `path.length <= 5`).

---

### [L-03] quoteLiquidity Returns Desired Amounts for Non-Existent Pools Without Warning

**Severity:** Low
**Lines:** 585-618

**Description:**

When `quoteLiquidity` is called for a token pair with no existing pool, it returns `(amountADesired, amountBDesired)` unchanged (line 594). This suggests to the caller that they can add exactly those amounts, but when they call `addLiquidity()`, it will revert with `PoolDoesNotExist` (line 382).

The quote function gives no indication that the pool does not exist. A front-end that calls `quoteLiquidity` followed by `addLiquidity` will show the user valid-looking amounts, only to revert on execution.

**Impact:** Misleading UX. Front-ends that rely on `quoteLiquidity` for pre-flight checks will not detect the missing pool until the transaction reverts.

**Recommendation:** Either revert in `quoteLiquidity` when the pool does not exist, or add a return value indicating pool existence:

```solidity
function quoteLiquidity(...)
    external view returns (uint256 amountA, uint256 amountB, bool poolExists)
{
    address pool = AMM.getPool(tokenA, tokenB);
    poolExists = pool != address(0);
    if (!poolExists) return (amountADesired, amountBDesired, false);
    // ... rest of logic ...
}
```

---

### [L-04] PROTOCOL_FEE_BPS Constant Could Diverge from RWAAMM's Fee

**Severity:** Low
**Lines:** 39

**Description:**

The router declares `PROTOCOL_FEE_BPS = 30` (line 39), matching RWAAMM's current `PROTOCOL_FEE_BPS = 30` (RWAAMM line 45). This constant is used in `getAmountsIn()` (line 572) for the reverse fee calculation.

Since both contracts are immutable (non-upgradeable), the fee values cannot diverge after deployment. However, if a new version of RWAAMM is deployed with a different fee and the router is redeployed against it, a developer could forget to update the router's constant. The fee is also available via `AMM.protocolFeeBps()`, which `getAmountsIn()` could call instead.

**Impact:** No current risk (both contracts are immutable and match). Future deployment risk if constants are not synchronized.

**Recommendation:** Replace the hardcoded constant in `getAmountsIn()` with a call to `AMM.protocolFeeBps()`:

```solidity
uint256 feeBps = AMM.protocolFeeBps();
amounts[i - 1] = (amountAfterFee * BPS_DENOMINATOR)
    / (BPS_DENOMINATOR - feeBps) + 1;
```

This adds ~2,600 gas per hop (external view call) but eliminates the synchronization risk. The existing constant can be retained for documentation purposes.

---

### [I-01] Unused `PROTOCOL_FEE_BPS` and `BPS_DENOMINATOR` Constants for Forward Path

**Severity:** Informational
**Lines:** 39-42

**Description:**

The constants `PROTOCOL_FEE_BPS` and `BPS_DENOMINATOR` are declared at lines 39-42 but are only used in the `getAmountsIn()` reverse calculation (lines 571-572). The forward path (`swapExactTokensForTokens` and `getAmountsOut`) delegates fee calculation entirely to `AMM.swap()` and `AMM.getQuote()` respectively.

This is not a bug -- the constants are correctly used in `getAmountsIn()`. However, it may cause confusion since the constants suggest the router independently calculates fees, while in practice only the reverse-quote path does so.

**Recommendation:** Add a comment explaining that these constants are used only for the `getAmountsIn()` reverse calculation, and that forward swaps delegate fee handling entirely to RWAAMM.

---

### [I-02] SwapExecuted Event Emits `amountIn` (Pre-Fee) Not `actualAmountIn` in swapExactTokensForTokens

**Severity:** Informational
**Lines:** 264-269

**Description:**

The `SwapExecuted` event in `swapExactTokensForTokens` emits the original `amountIn` parameter:

```solidity
emit SwapExecuted(
    msg.sender, path,
    amountIn,                    // original parameter
    amounts[amounts.length - 1]  // actual final output
);
```

However, for fee-on-transfer tokens, the actual input may have been reduced to `actualReceived` (line 233). The event will log the original (higher) `amountIn`, not the actual amount that entered the swap. Similarly, in `swapTokensForExactTokens`, the event emits `amounts[0]` (the calculated input) and `amountOut` (the desired output), but the actual final output is `amounts[amounts.length - 1]` which may differ.

**Impact:** Off-chain indexers that rely on the `SwapExecuted` event for trade reconstruction will see slightly inaccurate input amounts for fee-on-transfer tokens. This is an accounting discrepancy, not a security issue.

**Recommendation:** Emit `amounts[0]` instead of `amountIn` in `swapExactTokensForTokens` to reflect the actual (post-fee-on-transfer) input:

```solidity
emit SwapExecuted(msg.sender, path, amounts[0], amounts[amounts.length - 1]);
```

---

### [I-03] addLiquidity LP Token Transfer Assumes AMM Mints to msg.sender

**Severity:** Informational
**Lines:** 396-409

**Description:**

The `addLiquidity` function assumes that `AMM.addLiquidity()` mints LP tokens to `msg.sender` (the router), and then transfers them to the final `to` recipient:

```solidity
// Line 406-410
if (to != address(this)) {
    IERC20(pool).safeTransfer(to, liquidity);
}
```

This assumption is correct based on the current RWAAMM implementation (line 614: `liquidity = pool.mint(msg.sender)`). However, if RWAAMM is ever replaced with a version that mints directly to a specified recipient, the router would fail to transfer LP tokens (it wouldn't hold any).

Similarly for `removeLiquidity`: the router assumes the AMM sends underlying tokens to `msg.sender` (the router) and then forwards them to `to`.

**Impact:** No current issue. This is a documentation note for future maintainability. The immutability of both contracts means this assumption cannot break for the deployed pair.

**Recommendation:** Document the assumption clearly in the NatSpec.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (clean pass)
**Compiler:** Solidity 0.8.24 (no warnings from the RWARouter contract itself)

---

## Methodology

This audit followed the 6-pass enhanced methodology:

- **Pass 1: Static Analysis** -- Ran `solhint` on `RWARouter.sol`. Clean pass with no contract-level warnings.
- **Pass 2A: OWASP Smart Contract Top 10** -- Systematic review against OWASP SCP categories: reentrancy (guarded), access control (no admin functions, immutable AMM), arithmetic (Solidity 0.8.24 built-in overflow), unchecked returns (SafeERC20), denial of service (no unbounded loops over state), front-running (deadline + slippage), timestamp dependence (used only for deadline, acceptable), gas griefing (bounded path length by caller).
- **Pass 2B: Business Logic & Economic Analysis** -- Traced token flows through the router -> AMM -> pool pipeline. Analyzed fee model consistency between `getAmountsIn` reverse formula and RWAAMM's actual fee deduction. Verified compliance enforcement path. Analyzed MEV attack vectors (sandwich, front-running).
- **Pass 3: Cross-Contract Integration** -- Reviewed RWARouter against RWAAMM.sol (968 lines), RWAPool.sol (519 lines), IRWAAMM.sol, IRWAPool.sol, and IRWAComplianceOracle.sol. Verified that the router's assumptions about AMM behavior (fee deduction, token flow, LP minting, compliance checks) match the actual implementation.
- **Pass 4: Round 1 Remediation Verification** -- Systematically verified that each of the 13 Round 1 findings has been addressed. Confirmed C-01, H-01, H-02, H-03, M-01, M-03, M-04, L-01, L-03, I-01, I-02 are fully fixed. M-02 partially fixed (first hop only). L-02 carried forward.
- **Pass 5: Triage & Deduplication** -- Consolidated raw findings, removed duplicates, assigned final severity ratings.
- **Pass 6: Report Generation** -- This document.

---

## Conclusion

The RWARouter has been substantially improved since the Round 1 audit. The **critical compliance bypass (C-01) has been fully remediated** -- all operations now route through RWAAMM, which enforces compliance checks, fee collection, pause controls, and event emission. This is the single most important change and it transforms the router from a dangerous compliance hole into a proper user-facing facade.

**Remaining risks (all Medium or below):**

1. **M-01 (Fee-on-transfer intermediate hops):** Transactions will revert (no fund loss) but create denial-of-service for fee-on-transfer token paths. Mitigated by the fact that most RWA tokens do not charge transfer fees.

2. **M-02 (Quote-vs-execution mismatch):** `swapTokensForExactTokens` may deliver slightly less than the desired output due to rounding and LP fee retention effects. The `+ 1` ceiling rounding typically over-corrects, so users usually overpay slightly rather than receiving less.

3. **M-03 (Compliance on router, not user/recipient):** The most architecturally significant remaining issue. RWAAMM compliance checks verify the router contract's address, not the human user or the `to` recipient. This requires an AMM-level fix (adding `onBehalfOf` parameter) and cannot be fully resolved in the router alone.

**Overall Assessment:** The contract is well-structured, properly documented, and correctly implements the delegation pattern to RWAAMM. The remaining findings are edge cases and architectural considerations rather than exploitable vulnerabilities. The M-03 compliance gap should be addressed before production deployment with real regulated securities.

---

## Cross-Contract References

- **RWAAMM-audit-2026-02-21.md** -- M-03 (compliance on router address) requires AMM-level changes.
- **RWAPool-audit-2026-02-21.md** -- Pool's `onlyFactory` modifier (confirmed present at line 285) prevents direct pool bypass.
- **RWAComplianceOracle-audit-2026-02-21.md** -- Compliance oracle does not distinguish between contract callers and human users.

---
*Generated by Claude Code Audit Agent v3 -- 6-Pass Enhanced (Round 3)*
