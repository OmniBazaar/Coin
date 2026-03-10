# Security Audit Report: RWARouter.sol

**Contract:** `contracts/rwa/RWARouter.sol` (772 lines)
**Auditor:** Claude Opus 4.6 (Automated Security Audit)
**Date:** 2026-03-10
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL

---

## Executive Summary

RWARouter is the user-facing router that delegates all swap and liquidity operations to RWAAMM. It supports single-hop and multi-hop swaps, exact-input and exact-output swap modes, and liquidity add/remove operations. All operations are routed through RWAAMM to ensure compliance, fee collection, and pause controls are enforced.

The router is well-structured with proper reentrancy protection, deadline enforcement, and slippage checks. The most significant finding is the compliance bypass inherited from the RWAAMM architecture (RWAAMM checks the router's address, not the end user's).

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| C-01 | Critical | Compliance bypass via msg.sender | **FIXED** — passes _msgSender() as onBehalfOf |
| H-01 | High | Multi-hop balance verification missing | **FIXED** |
| H-02 | High | Last-hop balance delta incorrect | **FIXED** |
| M-01 | Medium | Residual token dust accumulation in router | **FIXED** |
| M-02 | Medium | Zero slippage on intermediate hops | **FIXED** |
| M-03 | Medium | addLiquidity compliance on router address | **FIXED** |

---

## Findings

### [C-01] CRITICAL: Compliance Bypass -- Router Is the `msg.sender` for All RWAAMM Calls

**Location:** All swap and liquidity functions
**Severity:** CRITICAL

**Description:**
This is the same issue as RWAAMM C-01, manifested at the router level. When users interact through the router:

1. User calls `RWARouter.swapExactTokensForTokens()`
2. Router calls `AMM.swap()` -- the AMM sees `msg.sender = RWARouter`
3. AMM's compliance check calls `COMPLIANCE_ORACLE.checkSwapCompliance(RWARouter, ...)`
4. If the router address is whitelisted, ALL users pass compliance

The router itself acknowledges this at lines 36-40 but defers to "off-chain compliance verification" and "a future AMM upgrade." This is insufficient for production deployment with regulated securities.

**Impact:**
Any user, regardless of KYC status, accreditation, or sanctions status, can trade regulated securities through the router. This creates severe regulatory exposure.

**Recommendation:**
See RWAAMM audit C-01. The solution requires an `onBehalfOf` parameter in RWAAMM's functions. The router should be updated to pass `_msgSender()` as the `onBehalfOf` parameter for all RWAAMM calls.

Additionally, the `to` parameter in swap functions should also be compliance-checked, as a compliant user could swap tokens to a non-compliant recipient address.

---

### [H-01] HIGH: `swapTokensForExactTokens` Intermediate Hops Transfer from `address(this)` Without Prior Balance Verification

**Location:** `swapTokensForExactTokens()` lines 370-398

**Severity:** HIGH

**Description:**
In the `swapTokensForExactTokens()` function, intermediate hops (i > 0) execute:

```solidity
IERC20(path[i]).safeTransferFrom(
    i == 0 ? caller : address(this),
    address(this),
    amounts[i]
);
```

For `i > 0`, this does `safeTransferFrom(address(this), address(this), amounts[i])` -- a self-transfer. This is wasteful (burns gas for no effect) but not directly harmful.

The real concern is that `amounts[i]` is calculated by `getAmountsIn()` (reverse calculation), but the actual output from the previous hop may differ from `amounts[i]` due to rounding or fee-on-transfer behavior. If the actual output from hop `i-1` is less than `amounts[i]`, the self-transfer succeeds (the router already holds the tokens), but the subsequent `AMM.swap()` call will approve and send `amounts[i]` tokens, potentially using tokens that were already held by the router from unrelated operations.

**Impact:**
If the router holds residual tokens from previous operations (e.g., dust from rounding, or tokens sent directly to the router), those tokens could be consumed by a subsequent swap. This could lead to accounting discrepancies or, in edge cases, using another user's residual tokens.

**Recommendation:**
1. Replace the self-transfer with a balance check: verify that the router holds at least `amounts[i]` of `path[i]` before proceeding
2. Add a `sweepTokens()` function that allows the admin (or anyone) to recover tokens stuck in the router
3. Consider using the balance-delta pattern consistently in `swapTokensForExactTokens()` as is done in `swapExactTokensForTokens()`

---

### [H-02] HIGH: `swapExactTokensForTokens` Multi-Hop Balance-Delta Measurement Is Incorrect for Last Hop

**Location:** `swapExactTokensForTokens()` lines 292-305

**Severity:** HIGH

**Description:**
The balance-delta measurement logic for intermediate vs. final hops contains a subtle issue:

```solidity
uint256 outputBalBefore = (recipient != address(this))
    ? 0
    : IERC20(path[i + 1]).balanceOf(address(this));
// AMM.swap() has already transferred output...
if (i < path.length - 2) {
    uint256 actualOutput = IERC20(path[i + 1]).balanceOf(
        address(this)
    ) - outputBalBefore;
    amounts[i + 1] = actualOutput;
} else {
    amounts[i + 1] = result.amountOut;
}
```

For the last hop (when `recipient` is the final `to` address, not `address(this)`), `outputBalBefore` is set to `0` and the actual output is taken from `result.amountOut`. However, `AMM.swap()` sends the output tokens to `_msgSender()` (which is the router, not the `to` address). The router then transfers to `to` on lines 308-312.

Wait -- re-reading the RWAAMM.swap() function: at line 536, `pool.swap(amount0Out, amount1Out, caller, "")` where `caller = _msgSender()` = the router. So the pool sends output tokens to the router. Then the router transfers to `to` on line 309.

The issue is: `result.amountOut` from AMM.swap() is the *calculated* amount, not the *actual* amount received by the router. For standard ERC-20 tokens, these are equal. But for fee-on-transfer tokens, the actual amount received could be less. The last hop does NOT use the balance-delta pattern, so FOT tokens would cause the router to attempt transferring more than it received.

**Impact:**
For the final hop with fee-on-transfer tokens, the router would try to transfer `result.amountOut` to the recipient, but only received `result.amountOut - feeOnTransfer`. The `safeTransfer` would fail if the router does not hold enough tokens.

For standard ERC-20 tokens (which all RWA tokens should be), this is not an issue. The RWAAMM documentation states FOT tokens are not supported.

**Recommendation:**
Apply the balance-delta pattern consistently on ALL hops, including the last one:

```solidity
uint256 outputBalBefore = IERC20(path[i + 1]).balanceOf(address(this));
// ... AMM.swap() ...
uint256 actualOutput = IERC20(path[i + 1]).balanceOf(address(this)) - outputBalBefore;
amounts[i + 1] = actualOutput;

if (recipient != address(this)) {
    IERC20(path[i + 1]).safeTransfer(recipient, actualOutput);
}
```

---

### [M-01] MEDIUM: Residual Token Dust Can Accumulate in the Router

**Location:** `addLiquidity()` lines 491-498, general router design

**Severity:** MEDIUM

**Description:**
The `addLiquidity()` function correctly refunds unused tokens:

```solidity
uint256 remainingA = amountADesired - amountA;
uint256 remainingB = amountBDesired - amountB;
```

However, this calculation assumes that `amountA <= amountADesired` and `amountB <= amountBDesired`. This is guaranteed by the RWAAMM's optimal amount calculation. But rounding in the pool's `mint()` function could cause the actual amounts consumed to differ slightly from what RWAAMM reports.

Additionally, for swap operations, if the AMM consumes less than the approved amount (due to rounding), the residual approval persists. While `forceApprove` is used (which handles this), small dust amounts of tokens could remain in the router.

**Impact:**
Token dust accumulates over time. For RWA tokens, this means the router holds regulated securities without a specific owner, creating a compliance issue. The accumulated dust could also be extracted by an attacker through carefully crafted operations.

**Recommendation:**
1. Add a `sweepTokens(address token, address to)` function (admin-only) to recover dust
2. After all swap/liquidity operations, add a zero-approval call to clear any residual approvals
3. Consider using `balanceOf(address(this))` to determine actual amounts rather than relying on RWAAMM's reported amounts

---

### [M-02] MEDIUM: `swapExactTokensForTokens` Passes `amountOutMin = 0` to Intermediate RWAAMM Hops

**Location:** `swapExactTokensForTokens()` line 286

**Severity:** MEDIUM

**Description:**
Each hop passes `amountOutMin = 0` to `AMM.swap()`:

```solidity
IRWAAMM.SwapResult memory result = AMM.swap(
    path[i],
    path[i + 1],
    amounts[i],
    0, // Min checked at end for full path
    deadline
);
```

While the final output is checked against `amountOutMin` after all hops complete (line 316), the intermediate hops have no slippage protection. This means if the price changes between when the transaction is submitted and when it executes, intermediate hops could produce significantly less output than expected, and the final output could still be above `amountOutMin` if the last hop is favorable.

More importantly, this opens the door for targeted sandwich attacks on intermediate hops, where an attacker manipulates an intermediate pool knowing the user's slippage check only applies to the final output.

**Impact:**
Value extraction via sandwich attacks on intermediate pools in multi-hop swaps. The final `amountOutMin` check provides some protection, but the attacker can extract value from intermediate hops as long as the total loss stays within the user's tolerance.

**Recommendation:**
Consider allowing per-hop minimum amounts, or calculate expected intermediate outputs and enforce a maximum deviation (e.g., 1% per hop). Alternatively, implement a TWAP-based price check on each intermediate pool.

---

### [M-03] MEDIUM: `addLiquidity()` Compliance Check Is on Router Address, Not User

**Location:** `addLiquidity()` lines 474-482

**Severity:** MEDIUM

**Description:**
This is the liquidity-specific manifestation of C-01. When the router calls `AMM.addLiquidity()`, the AMM checks compliance for `_msgSender()` which is the router. Non-compliant users can add liquidity to RWA pools through the router.

Additionally, the `to` parameter (LP token recipient) is never compliance-checked. A non-compliant address could receive LP tokens representing exposure to regulated securities.

**Impact:**
Non-compliant users gain economic exposure to regulated securities via LP positions.

**Recommendation:**
The router should pass the actual user (`_msgSender()` in the router context) and the `to` recipient to the AMM for compliance verification.

---

### [L-01] LOW: `getAmountsIn()` Uses +1 Rounding That May Compound Over Multi-Hop

**Location:** `getAmountsIn()` lines 649-652

**Severity:** LOW

**Description:**
The reverse calculation adds `+1` for ceiling rounding:

```solidity
uint256 amountAfterFee = (reserveIn * amounts[i])
    / (reserveOut - amounts[i]) + 1;
amounts[i - 1] = (amountAfterFee * BPS_DENOMINATOR)
    / (BPS_DENOMINATOR - PROTOCOL_FEE_BPS) + 1;
```

Each hop adds two `+1` rounding increments. For a 3-hop path, this accumulates 6 extra wei across the two calculations per hop. While negligible for large amounts, for very small amounts the rounding could be significant relative to the trade size.

The `swapTokensForExactTokens()` function correctly handles this by checking that the final output meets the desired amount (line 405), so the user is protected.

**Impact:**
Users pay slightly more than the theoretical minimum for exact-output swaps, especially on multi-hop routes. The excess is typically negligible (a few wei per hop).

**Recommendation:**
No action needed. The current implementation is conservative (users pay slightly more) which is the safe direction. Document the expected rounding behavior for frontend developers.

---

### [L-02] LOW: `ensure` Modifier Rejects `deadline == 0`

**Location:** `ensure()` modifier lines 176-186

**Severity:** LOW

**Description:**
The modifier explicitly rejects `deadline == 0`, which is good practice (prevents accidental omission of deadline). However, this behavior differs from RWAAMM's `checkDeadline` modifier (lines 257-264), which would accept `deadline == 0` as a valid (expired) deadline.

If a user calls RWAAMM directly with `deadline == 0`, the RWAAMM would revert with `DeadlineExpired(0, block.timestamp)` since `block.timestamp > 0`. So the behavior is effectively the same -- both reject `deadline == 0`.

**Impact:**
No impact. Both contracts reject `deadline == 0` for different reasons but with the same effect.

**Recommendation:**
No action needed. The explicit zero check is a good defensive practice.

---

### [L-03] LOW: `removeLiquidity()` Does Not Verify Returned Amounts Match Token Order

**Location:** `removeLiquidity()` lines 552-559

**Severity:** LOW

**Description:**
The router calls `AMM.removeLiquidity(tokenA, tokenB, ...)` and receives `(amountA, amountB)`. The AMM internally swaps the amounts based on pool token order and swaps back before returning. However, the router then transfers `amountA` of `tokenA` and `amountB` of `tokenB` to the recipient without independently verifying the token order matches.

If the AMM has a bug in its token-order correction (line 712-714 of RWAAMM), the router would send the wrong amounts of the wrong tokens.

**Impact:**
Dependent on RWAAMM's correctness. Currently RWAAMM correctly handles token ordering.

**Recommendation:**
Consider adding a balance-delta verification: measure the router's balance change for each token and use those as the actual amounts to transfer, rather than trusting the AMM's reported values.

---

### [L-04] LOW: No Maximum Path Length Check

**Location:** `swapExactTokensForTokens()` line 236, `swapTokensForExactTokens()` line 355

**Severity:** LOW

**Description:**
The path length is checked for a minimum of 2 but there is no maximum. Extremely long paths could consume excessive gas or be used for denial-of-service. Each hop involves multiple external calls (approve, swap), storage reads, and token transfers.

**Impact:**
Potential gas griefing. No fund loss since gas costs are borne by the caller.

**Recommendation:**
Add a maximum path length (e.g., 4-5 hops). Multi-hop routes with more than 3-4 hops are rarely economically rational.

---

### [I-01] INFORMATIONAL: `quoteLiquidity()` Returns Desired Amounts for Non-Existent Pools

**Location:** `quoteLiquidity()` lines 672-675

**Severity:** INFORMATIONAL

**Description:**
When `pool == address(0)`, the function returns `(amountADesired, amountBDesired)`. This is correct behavior for first-deposit calculations (any ratio is accepted), but could mislead a frontend into thinking the amounts are validated.

**Status:** Acceptable behavior. Documented for awareness.

---

### [I-02] INFORMATIONAL: Router Does Not Emit Events for Intermediate Swap Hops

**Location:** `swapExactTokensForTokens()` line 322

**Severity:** INFORMATIONAL

**Description:**
The router emits a single `SwapExecuted` event with the full path, input amount, and final output amount. Individual hop details (intermediate amounts, fees per hop) are not emitted by the router, though each hop does emit events from the AMM and pool levels.

**Status:** Acceptable. Indexers can reconstruct intermediate hops from AMM/pool events.

---

### [I-03] INFORMATIONAL: `forceApprove` Used Correctly

The router uses `IERC20.forceApprove()` (OpenZeppelin's SafeERC20) to set approvals before each AMM call. This correctly handles tokens that require approval to be set to 0 before changing (like USDT).

**Status:** VERIFIED CORRECT

---

### [I-04] INFORMATIONAL: Deadline Passed to Both Router and AMM

Both the router's `ensure()` modifier and the AMM's `checkDeadline()` modifier check the same deadline. This is redundant but harmless -- the router check saves gas by reverting early before any token transfers.

**Status:** Acceptable. Defense in depth.

---

## Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | CRITICAL | Compliance Bypass via Router msg.sender | Open |
| H-01 | HIGH | Intermediate Hop Uses Residual Router Tokens | Open |
| H-02 | HIGH | Last-Hop Balance-Delta Not Applied (FOT Edge Case) | Open |
| M-01 | MEDIUM | Token Dust Accumulation in Router | Open |
| M-02 | MEDIUM | Zero Slippage on Intermediate Hops | Open |
| M-03 | MEDIUM | addLiquidity Compliance on Router Address | Open |
| L-01 | LOW | Rounding Compounds in Multi-Hop getAmountsIn | Open |
| L-02 | LOW | ensure() Rejects deadline == 0 (Correct) | Verified |
| L-03 | LOW | Token Order Trust in removeLiquidity | Open |
| L-04 | LOW | No Maximum Path Length | Open |
| I-01 | INFO | quoteLiquidity for Non-Existent Pools | Verified |
| I-02 | INFO | No Per-Hop Events | Verified |
| I-03 | INFO | forceApprove Used Correctly | Verified |
| I-04 | INFO | Redundant Deadline Check (Defense in Depth) | Verified |

---

## Positive Observations

1. **All operations routed through RWAAMM** -- the router never interacts with pools directly, ensuring compliance/fees/pause are always enforced at the AMM level
2. **Reentrancy protection** via OpenZeppelin ReentrancyGuard
3. **Explicit zero-deadline rejection** prevents accidental unprotected transactions
4. **Balance-delta pattern** on first hop of `swapExactTokensForTokens` handles FOT tokens
5. **Refund mechanism** in `addLiquidity()` returns unused tokens
6. **forceApprove** handles non-standard approval tokens (like USDT)
7. **Comprehensive error types** with descriptive parameters
8. **Output verification guard** in `swapTokensForExactTokens()` (line 405) per audit recommendation M-02
9. **ERC2771Context** for meta-transaction support
10. **Clean separation of concerns** -- router handles user interaction, AMM handles business logic
