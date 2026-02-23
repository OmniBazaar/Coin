# Security Audit Report: RWAAMM

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWAAMM.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 765
**Upgradeable:** No (immutable by design — "legally defensible")
**Handles Funds:** Yes (routes token transfers through RWA pools, collects fees)

## Executive Summary

RWAAMM is a non-upgradeable AMM factory and router for Real World Asset token pools. It creates constant-product pools via `new RWAPool()`, routes swaps with compliance oracle verification, collects 0.30% protocol fees sent to `RWAFeeCollector`, and implements a 3-of-5 multi-sig emergency pause with immutable signers. The contract is deliberately non-upgradeable as a "legally defensible" design choice.

The audit found **1 Critical vulnerability**: RWAPool.swap() has no access control, allowing anyone to bypass RWAAMM entirely — evading compliance checks, fee collection, pause controls, and event emission. Both agents independently identified this as the root cause of multiple downstream issues. Additionally, **3 High-severity issues** were found: the addLiquidity reserve swap bug at line 527 inverts price ratios for non-canonical token ordering, the 70% LP fee is never explicitly transferred (contradicting documentation), and addLiquidity/removeLiquidity skip compliance checks entirely.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 2 |
| Informational | 2 |

## Findings

### [C-01] RWAPool.swap() Unrestricted — Complete Bypass of Fees, Compliance, and Pause

**Severity:** Critical
**Lines:** 432-448 (RWAAMM.swap fee logic), RWAPool.sol 236 (swap function)
**Agents:** Both

**Description:**

`RWAPool.swap()` is `external` with no access control. Any contract or EOA can:
1. Transfer tokens directly to the pool
2. Call `pool.swap(amount0Out, amount1Out, to, data)`
3. The pool only checks that K hasn't decreased (with NO fee adjustment)

This completely bypasses RWAAMM's:
- **Compliance checks** (`_checkSwapCompliance()` via `IRWAComplianceOracle`)
- **Protocol fees** (0.30% to `FEE_COLLECTOR`)
- **Emergency pause** (`whenNotPaused`, `whenPoolNotPaused`)
- **Event emission** (`SwapExecuted` for monitoring)
- **Deadline enforcement** (`deadline` parameter)

The RWAPool's K-invariant check uses raw unadjusted balances (unlike Uniswap V2 which adjusts for the 0.3% fee), meaning direct pool callers pay zero fees. This is documented in the RWAPool audit (C-01) but the RWAAMM design fundamentally depends on pool-level access control that doesn't exist.

**Impact:** 100% bypass of the RWA compliance infrastructure. Any user who interacts directly with pool contracts trades regulated security tokens without KYC/accreditation verification, pays zero protocol fees, and is immune to emergency pause. The `RWARouter` contract already exploits this (see RWARouter audit C-01).

**Recommendation:** Add `onlyFactory` modifier to `RWAPool.swap()`, `mint()`, and `burn()`:
```solidity
modifier onlyFactory() {
    if (msg.sender != factory) revert NotFactory();
    _;
}
```
This ensures all pool interactions route through RWAAMM where compliance, fees, and pause are enforced.

---

### [H-01] addLiquidity Reserve Swap Inverts Price Ratio

**Severity:** High
**Lines:** 520-534
**Agent:** Both

**Description:**

In `addLiquidity()`, when the user-provided token order doesn't match the pool's canonical `token0`/`token1` order, the contract swaps reserve values:

```solidity
if (!isToken0First) {
    (reserve0, reserve1) = (reserve1, reserve0);  // Line 527
}
```

This swap is intended to align reserves with the user's token ordering for the optimal amount calculation. However, the subsequent calculation on lines 528-533 uses the swapped reserves to compute `amount1Optimal` or `amount0Optimal`. When `isToken0First` is false, the reserves are inverted, causing the optimal ratio calculation to use the reciprocal of the correct price ratio.

For example, if the pool has 1000 TokenA (token0) and 2000 TokenB (token1), the ratio is 1:2. When `!isToken0First`, the reserves become (2000, 1000), yielding a ratio of 2:1 — the inverse. This causes the optimal amount calculation to either require twice as much of one token or half as much, resulting in either a revert (if the user doesn't have enough) or excess tokens being silently under-deposited.

**Impact:** Users adding liquidity with tokens in non-canonical order get incorrect optimal amounts. Either the transaction reverts or liquidity is added at the wrong ratio, causing immediate impermanent loss.

**Recommendation:** Remove the reserve swap. Instead, swap the user's amounts to match canonical ordering:
```solidity
if (!isToken0First) {
    (amountADesired, amountBDesired) = (amountBDesired, amountADesired);
    (amountAMin, amountBMin) = (amountBMin, amountAMin);
}
```

---

### [H-02] 70% LP Fee Never Explicitly Transferred — Documentation Mismatch

**Severity:** High
**Lines:** 432-448, constants at lines 71-73
**Agent:** Agent B

**Description:**

The contract declares fee split constants:
```solidity
uint256 public constant FEE_LP_BPS = 7000;      // 70% to LPs
uint256 public constant FEE_STAKING_BPS = 2000;  // 20% to staking
uint256 public constant FEE_LIQUIDITY_BPS = 1000; // 10% to liquidity
```

But in `swap()`, the **entire** 0.30% protocol fee is sent to `FEE_COLLECTOR`:
```solidity
uint256 protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
uint256 amountInAfterFee = amountIn - protocolFee;
IERC20(tokenIn).safeTransferFrom(msg.sender, poolAddr, amountInAfterFee);
IERC20(tokenIn).safeTransferFrom(msg.sender, FEE_COLLECTOR, protocolFee);
```

The "70% LP" share is implicitly handled by the constant-product formula (LPs earn from the amountInAfterFee increasing pool reserves), but this is not the same as receiving 70% of the extracted fee. The `FEE_LP_BPS` constant is dead code — never referenced in any calculation.

The `RWAFeeCollector.distribute()` then splits the received XOM as 2000/(2000+1000) = 66.67% staking, 33.33% liquidity — which is the correct 20/10 relative split, but it receives 100% of the protocol fee, not 30%.

**Impact:** LP providers receive zero explicit fee revenue. All 0.30% goes to FeeCollector. The documented 70/20/10 split is not what's implemented. `FEE_LP_BPS = 7000` is decorative dead code.

**Recommendation:** Either:
1. Keep current design (LPs earn from AMM curve) but remove `FEE_LP_BPS` and update all documentation to describe the actual model, or
2. Implement true 70/20/10: send only 30% of `protocolFee` to FeeCollector, keep 70% in the pool

---

### [H-03] addLiquidity and removeLiquidity Skip Compliance Checks

**Severity:** High
**Lines:** 488-570 (addLiquidity), 573-618 (removeLiquidity)
**Agents:** Both

**Description:**

`swap()` calls `_checkSwapCompliance()` (line 425) via `IRWAComplianceOracle` to verify the user's KYC/accreditation status before allowing a trade. However, `addLiquidity()` and `removeLiquidity()` perform NO compliance checks.

For RWA security tokens that legally require investor verification, this creates a regulatory bypass:
1. A non-KYC'd user can provide liquidity for a security token pair via `addLiquidity()`
2. They receive LP tokens representing a claim on the underlying security tokens
3. They can then `removeLiquidity()` to withdraw security tokens they should never have been able to acquire

LP tokens themselves are synthetic claims on the underlying assets. Allowing unverified users to hold LP tokens for regulated securities creates the same regulatory liability as allowing them to hold the securities directly.

**Impact:** Non-compliant users can acquire regulated RWA tokens by providing liquidity, completely circumventing the compliance oracle's purpose.

**Recommendation:** Add compliance checks to both `addLiquidity()` and `removeLiquidity()`:
```solidity
_checkSwapCompliance(msg.sender, tokenA);
_checkSwapCompliance(msg.sender, tokenB);
```

---

### [M-01] Constructor Allows Duplicate Emergency Signers

**Severity:** Medium
**Lines:** 161-167
**Agents:** Both

**Description:**

The constructor validates that all 5 emergency signers are non-zero and immutable, but does not check for duplicates:
```solidity
if (emergencySigners_[0] == address(0) || ...) revert InvalidSigner();
```

If the deployer accidentally provides the same address twice (e.g., `[A, B, C, A, D]`), the 3-of-5 threshold effectively becomes 3-of-4 (since A's signature counts for two positions). In the worst case, `[A, A, A, B, C]` makes A a unilateral actor with 3 of 5 "unique" signatures.

Since signers are `immutable`, this cannot be corrected after deployment.

**Impact:** Reduced multi-sig threshold if duplicate addresses are provided at deployment.

**Recommendation:** Add duplicate checking in the constructor:
```solidity
for (uint i = 0; i < 5; i++) {
    for (uint j = i + 1; j < 5; j++) {
        if (emergencySigners_[i] == emergencySigners_[j]) revert DuplicateSigner();
    }
}
```

---

### [M-02] removeLiquidity Missing whenNotPaused Modifier

**Severity:** Medium
**Lines:** 573
**Agents:** Both

**Description:**

`swap()` has `whenNotPaused` modifier (line 399), and `addLiquidity()` has `whenNotPaused` (line 488). However, `removeLiquidity()` has no pause check:

```solidity
function removeLiquidity(
    address tokenA,
    address tokenB,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
```

This is a deliberate design choice in many AMMs — allowing withdrawals during emergencies prevents user funds from being locked. However, for RWA security tokens under compliance requirements, allowing uncontrolled withdrawals during an emergency could violate regulatory freeze orders.

**Impact:** During an emergency pause (potentially triggered by a compliance breach), users can still withdraw regulated tokens.

**Recommendation:** Add `whenNotPaused` to `removeLiquidity()` if regulatory compliance requires freezing withdrawals during emergencies. Alternatively, add a separate `emergencyWithdraw()` with a longer timelock.

---

### [M-03] FeeCollector.collectFees() Never Called — Accounting Dead Code

**Severity:** Medium
**Lines:** 444-448 (RWAAMM), RWAFeeCollector 231-251 (collectFees)
**Agents:** Both

**Description:**

`RWAAMM.swap()` sends fees directly from the user to the FeeCollector via `safeTransferFrom`:
```solidity
IERC20(tokenIn).safeTransferFrom(msg.sender, FEE_COLLECTOR, protocolFee);
```

It never calls `FeeCollector.collectFees()`. This means:
- `accumulatedFees` mapping is never updated
- `_feeTokens` array is never populated
- `FeesCollected` event is never emitted
- All internal accounting in the FeeCollector is non-functional

The `distribute()` function still works because it reads `IERC20(XOM_TOKEN).balanceOf(address(this))` directly, but the tracking layer is entirely dead code.

**Impact:** Fee transparency and audit trail are non-functional. Off-chain systems querying FeeCollector state get empty/zero data.

**Recommendation:** Either route fees through `collectFees()` (requiring AMM to approve FeeCollector) or remove the dead accounting code from FeeCollector and rely on transfer events.

---

### [M-04] createPool Has No Access Control — Anyone Can Create Pools

**Severity:** Medium
**Lines:** 334-363
**Agent:** Agent A

**Description:**

`createPool()` is `external` with only `whenNotPaused` and `nonReentrant` modifiers. Any address can create a pool for any token pair, including:
1. Malicious tokens designed to exploit pool interactions
2. Tokens that should require compliance registration before trading
3. Duplicate pools with slightly different token addresses (token proxies)

In RWAAMM's design, the compliance oracle only checks registered tokens. An attacker could create a pool for an unregistered wrapper of a regulated token, bypassing compliance entirely.

**Impact:** Uncontrolled pool creation enables regulatory bypass through wrapper tokens.

**Recommendation:** Either restrict `createPool()` to a designated registrar role or require that at least one token in the pair is registered in the compliance oracle before pool creation is allowed.

---

### [M-05] emergencyUnpause Emits Wrong Event

**Severity:** Medium
**Lines:** 278-293
**Agent:** Agent A

**Description:**

The `emergencyUnpause()` function emits `EmergencyPaused` instead of `EmergencyUnpaused`:
```solidity
function emergencyUnpause(...) external {
    // ... signature verification ...
    paused = false;
    emit EmergencyPaused(nonce);  // BUG: should be EmergencyUnpaused
}
```

**Impact:** Off-chain monitoring systems tracking pause/unpause events will misinterpret unpauses as pauses, potentially triggering false alerts.

**Recommendation:** Change to `emit EmergencyUnpaused(nonce);`

---

### [L-01] External Self-Call in addLiquidity

**Severity:** Low
**Lines:** 514
**Agent:** Agent A

**Description:**

`addLiquidity()` calls `this.createPool()` (line 514) when no pool exists, using an external CALL instead of an internal function call. This costs ~700 extra gas for the external call overhead plus ABI encoding.

**Recommendation:** Refactor into an internal `_createPool()` function.

---

### [L-02] Fee-on-Transfer Tokens Break Swap Accounting

**Severity:** Low
**Lines:** 432-448
**Agent:** Agent A

**Description:**

The swap flow assumes `safeTransferFrom` delivers the exact `amountInAfterFee` to the pool and `protocolFee` to the FeeCollector. If the token charges a transfer fee, the pool receives less than expected, potentially causing the K-check to fail with an opaque `KValueDecreased` error.

**Recommendation:** Document that fee-on-transfer tokens are unsupported, or measure actual balance changes.

---

### [I-01] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:** Uses `^0.8.20`. For deployed contracts, pin to a specific version.

---

### [I-02] Fee Split Constants Are Decorative

**Severity:** Informational
**Agent:** Agent B

**Description:** `FEE_LP_BPS = 7000`, `FEE_STAKING_BPS = 2000`, `FEE_LIQUIDITY_BPS = 1000` are declared but never used in any fee calculation. They serve as documentation-only constants.

**Recommendation:** Either implement the documented split or remove the constants to avoid confusion.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 23 raw findings -> 13 unique)
- Pass 6: Report generation

## Conclusion

RWAAMM has **one fundamental architectural flaw that cascades into multiple downstream vulnerabilities**:

1. **Pool bypass (C-01)** — RWAPool.swap() has no access control, allowing direct pool interaction that bypasses ALL RWAAMM protections. This is the root cause shared with RWAPool C-01, RWARouter C-01, and RWAFeeCollector accounting failures.

2. **Reserve swap bug (H-01)** — addLiquidity inverts the price ratio when tokens are provided in non-canonical order, causing incorrect liquidity deposits.

3. **LP fee mismatch (H-02)** — the documented 70/20/10 split is not implemented. 100% of the protocol fee goes to FeeCollector; LPs earn only from the AMM curve.

4. **Missing compliance on liquidity (H-03)** — addLiquidity and removeLiquidity skip compliance checks, allowing non-KYC'd users to acquire regulated tokens through LP positions.

**Cross-contract note:** The entire RWA stack (RWAAMM, RWAPool, RWARouter, RWAComplianceOracle, RWAFeeCollector) shares a common architectural weakness: the pool is the "dumb" primitive that holds funds, but it enforces nothing — no fees, no access control, no compliance. All security is delegated to RWAAMM, but RWAAMM cannot prevent direct pool access. The fix is either pool-level access control (`onlyFactory`) or pool-level fee enforcement (fee-adjusted K-check).

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
