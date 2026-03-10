# Security Audit Report: RWAPool.sol

**Contract:** `contracts/rwa/RWAPool.sol` (577 lines)
**Auditor:** Claude Opus 4.6 (Automated Security Audit)
**Date:** 2026-03-10
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL

---

## Executive Summary

RWAPool is a constant-product AMM liquidity pool that implements LP token minting/burning, swap execution with K-invariant enforcement, cumulative price oracles (TWAP), and flash swap callbacks. It follows the Uniswap V2 Pair pattern closely. All state-changing functions (mint, burn, swap, skim) are restricted to the factory (RWAAMM) contract via the `onlyFactory` modifier.

The contract is well-implemented with appropriate reentrancy protection, overflow guards, and the CEI (Checks-Effects-Interactions) pattern in the burn function. Several findings are noted below.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | Permissionless sync() oracle manipulation | **FIXED** |
| H-02 | High | Flash swap callback not compliance-gated | **FIXED** |
| M-01 | Medium | First depositor griefing with low-decimal tokens | **FIXED** |
| M-02 | Medium | Read-only reentrancy on swap() path | **FIXED** |
| M-03 | Medium | kLast consistency and purpose | **FIXED** |

---

## Findings

### [H-01] HIGH: `sync()` Is Permissionless -- Enables Donation-Based Oracle Manipulation

**Location:** `sync()` lines 362-371

**Severity:** HIGH

**Description:**
The `sync()` function is intentionally permissionless (no `onlyFactory` modifier), following the Uniswap V2 convention. The contract's own documentation (lines 358-360) acknowledges this:

> *"TWAP oracle data from this pool should not be used for on-chain pricing decisions, as donations + sync() can manipulate TWAP."*

However, if any external protocol or on-chain consumer uses the TWAP data from these pools for pricing decisions (e.g., lending protocols, options protocols, or even the OmniBazaar DEX itself), an attacker can manipulate the price oracle cheaply:

1. Send a large amount of one token directly to the pool (donation)
2. Call `sync()` to update reserves to reflect the inflated balance
3. The cumulative price accumulators now reflect the manipulated ratio
4. Wait for the TWAP window to pass, then exploit the stale/manipulated price in a dependent protocol
5. Optionally, call `sync()` again after removing the donation (via a subsequent swap)

**Impact:**
Oracle manipulation that could affect any protocol relying on this pool's TWAP data for pricing. The RWA tokens are particularly sensitive because they represent real-world assets whose prices should not be manipulable.

**Recommendation:**
Either:
1. Add `onlyFactory` to `sync()` -- this breaks the escape-hatch use case but closes the oracle manipulation vector
2. Add a flag that allows the factory to disable `sync()` on sensitive pools
3. Add a maximum reserve change per block check (deviation guard)
4. Clearly document that these TWAP accumulators must NOT be used for any on-chain pricing decisions, and remove the price accumulators entirely if they serve no purpose

---

### [H-02] HIGH: Flash Swap Callback Exists But Is Not Compliance-Gated

**Location:** `swap()` lines 340-344

**Severity:** HIGH

**Description:**
The swap function supports flash swap callbacks via the `data` parameter:

```solidity
if (data.length > 0) {
    IRWAPoolCallee(to).rwaPoolCall(
        msg.sender, amount0Out, amount1Out, data
    );
}
```

While the `onlyFactory` modifier ensures only RWAAMM can call `swap()`, and RWAAMM currently always passes empty data, the pool contract itself does not enforce that flash swaps are prohibited. If the RWAAMM implementation changes (new version, or a bug in a future code path), flash swaps could be triggered without compliance checks.

Flash swaps are fundamentally incompatible with RWA compliance because they transfer tokens to the recipient *before* any verification occurs. The callback model assumes the recipient will repay, but a non-compliant user would have already received regulated securities.

**Impact:**
If flash swaps are ever enabled (intentionally or accidentally), non-compliant users could receive regulated tokens even if only temporarily. This creates a securities law violation regardless of whether the tokens are returned.

**Recommendation:**
Add a constructor parameter or immutable flag that disables flash swap callbacks entirely:

```solidity
if (data.length > 0) {
    revert FlashSwapsDisabled();
}
```

If flash swaps are genuinely needed in the future, they should go through a separate compliance-checked path.

---

### [M-01] MEDIUM: First Depositor Can Still Grief via Minimum Deposit Threshold

**Location:** `mint()` lines 221-230

**Severity:** MEDIUM

**Description:**
The contract implements two protections against share inflation attacks:
1. `MINIMUM_LIQUIDITY = 1000` -- burned to dead address
2. `MINIMUM_INITIAL_DEPOSIT = 10_000` -- minimum sqrt(amount0 * amount1)

While `MINIMUM_INITIAL_DEPOSIT` is higher than Uniswap V2's default (which only uses `MINIMUM_LIQUIDITY`), it may still be insufficient for tokens with low decimals.

Consider a token with 6 decimals (like USDC). `MINIMUM_INITIAL_DEPOSIT = 10_000` means the first depositor must provide at least sqrt(amount0 * amount1) >= 10,000. If one token is 18-decimal and the other is 6-decimal:
- Attacker deposits 1 wei of 18-decimal token and 100_000_000 (100 USDC) of 6-decimal token
- sqrt(1 * 100_000_000) = 10_000 -- passes the check
- The initial ratio is extremely skewed, and subsequent depositors must match this ratio

More concerning: after the initial deposit, the attacker can donate tokens directly to the pool to further skew the ratio, then the next depositor loses value to rounding.

**Impact:**
First depositor can set a skewed ratio that causes rounding losses for subsequent depositors. With low-decimal RWA tokens (many real-world securities use 6 or 8 decimals), the attack surface is larger.

**Recommendation:**
Increase `MINIMUM_INITIAL_DEPOSIT` significantly for RWA pools (e.g., to 10^12 or higher), or require that the initial deposit ratio is within bounds of an oracle price. Additionally, consider requiring both `amount0` and `amount1` to individually exceed a minimum threshold, not just their geometric mean.

---

### [M-02] MEDIUM: Read-Only Reentrancy Risk on `getReserves()` During Token Transfer Callbacks

**Location:** `burn()` lines 256-305, `swap()` lines 316-350

**Severity:** MEDIUM

**Description:**
The `burn()` function correctly updates reserves BEFORE token transfers (CEI pattern, lines 287-298), which mitigates read-only reentrancy. However, the `swap()` function transfers tokens BEFORE updating reserves (optimistic transfer, lines 332-337), and then calls `_verifyAndUpdateSwap()` to update state.

If either token's `transfer()` function has a callback (e.g., ERC-777 hooks, or a malicious ERC-3643 transfer hook), the callback executes while the pool's reserves are stale (not yet updated). Any external contract reading `getReserves()` during this callback window would see pre-swap reserves, which could be exploited for price oracle manipulation or arbitrage in dependent protocols.

The `lock()` modifier prevents direct reentrancy into the pool itself, but it does not prevent other contracts from reading `getReserves()` during the callback window.

**Impact:**
A composability risk. If any external protocol uses this pool's `getReserves()` for real-time pricing, an attacker could exploit the stale reserves during the callback window. This is the well-known "read-only reentrancy" pattern.

**Recommendation:**
Consider updating reserves BEFORE the optimistic transfer in swap(), or adding a `reentrancyGuardView()` check that external consumers can call to verify the pool is not mid-transaction. Alternatively, document clearly that `getReserves()` must not be used for real-time pricing during active transactions.

---

### [M-03] MEDIUM: `kLast` Updated in `burn()` Using Local Variables, Potential Drift

**Location:** `burn()` lines 296-298

**Severity:** MEDIUM

**Description:**
In `burn()`, `kLast` is calculated from local variables `newBalance0 * newBalance1` after the `_update()` call. This is consistent because `_update()` writes the same values to `reserve0` and `reserve1`. However, in `mint()`, `kLast` is calculated from storage reads (line 244):

```solidity
kLast = uint256(reserve0) * uint256(reserve1);
```

This reads from storage after `_update()` has written new values, which is correct but uses a different pattern than `burn()`. The inconsistency is not a bug, but if `_update()` truncates values to `uint112`, the multiplication `uint256(reserve0) * uint256(reserve1)` uses the truncated values, which is correct.

The more concerning issue is that `kLast` is never used within the pool itself for any validation. It is exposed via the `kLast()` view function for external protocols. If any external protocol uses `kLast` for calculations, the value could be stale or inconsistent during multi-step operations.

**Impact:**
No direct fund loss. Potential inconsistency for external consumers of `kLast`.

**Recommendation:**
Document clearly that `kLast` is for informational purposes only and should not be used for security-critical calculations by external protocols. If it serves no purpose, consider removing it to reduce storage costs.

---

### [L-01] LOW: `_validateSwapReserves` Error Message May Be Misleading for Dual-Output Swaps

**Location:** `_validateSwapReserves()` lines 560-576

**Severity:** LOW

**Description:**
The validation function checks both `amount0Out < _reserve0` and `amount1Out < _reserve1` using strict less-than. If BOTH outputs are non-zero (which the standard constant-product AMM does not use, but the interface allows), the error message only reports the larger of the two amounts, which could be misleading.

In practice, RWAAMM.swap() always sets one output to zero and the other to `amountOut`, so this is not triggered in normal usage.

**Impact:**
Confusing error message in edge case. No fund loss.

**Recommendation:**
No action needed given current usage pattern. If dual-output swaps are ever supported, refine the error reporting.

---

### [L-02] LOW: `uint112` Reserve Overflow Boundary

**Location:** `_update()` lines 497-503, `_verifyAndUpdateSwap()` lines 458-463

**Severity:** LOW

**Description:**
Reserves are stored as `uint112`, allowing a maximum balance of ~5.19e33. For an 18-decimal token, this is ~5.19e15 tokens (5.19 quadrillion). For most RWA tokens, this is more than sufficient.

However, for tokens with very high total supplies or tokens that perform rebasing (increasing balances), the `uint112` limit could theoretically be reached. The contract correctly checks for this overflow in both `_update()` and `_verifyAndUpdateSwap()`.

**Impact:**
If reserves exceed `uint112.max`, the pool becomes unusable. This is extremely unlikely for RWA tokens but is a hard limit.

**Recommendation:**
No action needed. The `uint112` limit is a conscious design choice from Uniswap V2 that balances storage efficiency with capacity.

---

### [L-03] LOW: TWAP Accumulator Uses `unchecked` Arithmetic

**Location:** `_update()` lines 509-522

**Severity:** LOW

**Description:**
The cumulative price accumulators use `unchecked` blocks for both the timestamp subtraction and the accumulator addition. This is correct behavior -- the accumulators are designed to overflow and consumers compute price differences by subtracting two snapshots (the overflow cancels out).

The timestamp subtraction `blockTimestamp - blockTimestampLast` uses `uint32`, which overflows every ~136 years. This is also correct and matches Uniswap V2 behavior.

**Impact:**
No impact. The `unchecked` usage is correct and intentional.

**Recommendation:**
No action needed. The unchecked pattern is well-established for TWAP accumulators.

---

### [I-01] INFORMATIONAL: `skim()` Correctly Restricted to Factory

The `skim()` function is restricted to `onlyFactory`, preventing arbitrary users from extracting excess tokens. This is the correct security posture for RWA pools where token movements must be controlled.

**Status:** VERIFIED CORRECT

---

### [I-02] INFORMATIONAL: Burn Function CEI Pattern Verified

The `burn()` function correctly follows the Checks-Effects-Interactions pattern:
1. **Checks:** Validates recipient, calculates amounts, checks non-zero
2. **Effects:** Burns LP tokens, updates reserves via `_update()`, writes `kLast`
3. **Interactions:** Transfers tokens to recipient

This prevents read-only reentrancy on the burn path.

**Status:** VERIFIED CORRECT

---

### [I-03] INFORMATIONAL: LP Token Naming

All pools use the same LP token name "RWA Pool LP Token" and symbol "RWA-LP". This means all pool LP tokens are indistinguishable by name/symbol. While they are distinguishable by contract address, it may cause confusion in wallets and block explorers.

**Recommendation:**
Consider including token symbols in the LP token name (e.g., "RWA-LP: USDC/RWA-GOLD") by setting the name in `initialize()` rather than the constructor.

---

### [I-04] INFORMATIONAL: K-Invariant Check Is Correct

The K-invariant check in `_verifyAndUpdateSwap()`:
```solidity
if (balance0 * balance1 < _reserve0 * _reserve1) {
    revert KValueDecreased();
}
```

This correctly ensures K never decreases. Since RWAAMM sends `amountToPool = amountInAfterFee + lpFee` to the pool (which is more than `amountInAfterFee` used for the AMM calculation), K will always increase slightly with each swap due to the LP fee donation.

**Status:** VERIFIED CORRECT

---

### [I-05] INFORMATIONAL: Constructor Sets Factory Correctly

The constructor sets `factory = msg.sender` and the `initialize()` function is restricted to `onlyFactory`. This ensures that only the deploying contract (RWAAMM) can initialize and interact with the pool.

Note: The RWAAMM contract deploys pools via `new RWAPool()` (line 926), which means the RWAAMM's address is `msg.sender` in the pool's constructor. This is correct.

**Status:** VERIFIED CORRECT

---

## Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | HIGH | Permissionless sync() Enables Oracle Manipulation | Open |
| H-02 | HIGH | Flash Swap Callback Not Compliance-Gated | Open |
| M-01 | MEDIUM | First Depositor Griefing With Low-Decimal Tokens | Open |
| M-02 | MEDIUM | Read-Only Reentrancy on swap() Path | Open |
| M-03 | MEDIUM | kLast Consistency and Purpose | Open |
| L-01 | LOW | Misleading Error in Dual-Output Validation | Open |
| L-02 | LOW | uint112 Reserve Overflow Boundary | Open |
| L-03 | LOW | TWAP unchecked Arithmetic (Correct) | Verified |
| I-01 | INFO | skim() Factory Restriction Verified | Verified |
| I-02 | INFO | Burn CEI Pattern Verified | Verified |
| I-03 | INFO | LP Token Naming | Open |
| I-04 | INFO | K-Invariant Check Verified | Verified |
| I-05 | INFO | Constructor Factory Setup Verified | Verified |

---

## Positive Observations

1. **`onlyFactory` modifier** on all state-changing functions (except `sync()`) is the correct access control pattern
2. **Custom reentrancy lock** (unlocked flag) works correctly and saves gas vs OpenZeppelin's ReentrancyGuard
3. **CEI pattern in burn()** prevents read-only reentrancy on the withdrawal path
4. **MINIMUM_INITIAL_DEPOSIT** is a meaningful improvement over Uniswap V2's weak first-deposit protection
5. **Dead address for minimum liquidity** instead of address(0) is a better practice
6. **Overflow guards** on both `_update()` and `_verifyAndUpdateSwap()` provide clear error messages
7. **SafeERC20** used for all external token transfers
8. **Comprehensive NatSpec** with security rationale in comments
