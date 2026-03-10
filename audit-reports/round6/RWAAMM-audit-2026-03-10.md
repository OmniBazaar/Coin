# Security Audit Report: RWAAMM.sol

**Contract:** `contracts/rwa/RWAAMM.sol` (1,017 lines)
**Auditor:** Claude Opus 4.6 (Automated Security Audit)
**Date:** 2026-03-10
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL

---

## Executive Summary

RWAAMM is the core immutable AMM factory for Real World Asset trading. It deploys RWAPool instances, enforces compliance checks via the RWAComplianceOracle, collects and splits protocol fees (0.30% at 70/20/10), and provides emergency pause functionality via 3-of-5 multi-sig. The contract is intentionally non-upgradeable for legal defensibility.

Overall, the contract is well-structured and follows established patterns (Uniswap V2 factory style). The immutable design is appropriate for regulatory defensibility. Several findings are noted below, ranging from a critical compliance bypass to informational observations.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| C-01 | Critical | Router compliance bypass | **FIXED** — onBehalfOf parameter added |
| H-01 | High | Flash swap callback bypasses compliance | **FIXED** |
| H-02 | High | addLiquidity auto-creates pool without compliance | **FIXED** |
| M-01 | Medium | Fee-on-transfer token incompatibility not enforced | **FIXED** |
| M-02 | Medium | Multi-sig nonce shared across all operations | **FIXED** |
| M-03 | Medium | removeLiquidity compliance blocks withdrawals for deregistered users | **FIXED** |
| M-04 | Medium | Sandwich attack vulnerability on RWA swaps | **FIXED** |

---

## Findings

### [C-01] CRITICAL: Router Compliance Bypass -- RWAAMM Checks `msg.sender` (Router) Instead of End User

**Location:** `swap()` line 476, `addLiquidity()` line 602, `removeLiquidity()` line 691
**Severity:** CRITICAL

**Description:**
When a user interacts via RWARouter, the RWAAMM contract's compliance checks verify `_msgSender()`, which resolves to the RWARouter contract address (the immediate caller), not the actual human user. The RWARouter documentation acknowledges this at lines 36-40:

> *"RWAAMM compliance checks verify msg.sender, which is this router contract (not the end user or the `to` recipient)."*

This means any user can execute swaps involving regulated RWA securities (ERC-3643, ERC-1400) as long as the RWARouter contract address is whitelisted in the compliance oracle. The compliance oracle will check whether the *router* can transfer the security token, not whether the *user* is KYC-verified or an accredited investor.

**Impact:**
Non-compliant users (no KYC, non-accredited investors, sanctioned entities) can freely trade regulated securities by routing through RWARouter. This defeats the entire purpose of the compliance layer and creates severe regulatory liability.

**Recommendation:**
The RWAAMM.swap() function should accept an `onBehalfOf` parameter so the router can pass the actual user address for compliance checking. The swap function should verify compliance for `onBehalfOf` rather than `msg.sender`. Example:

```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    uint256 deadline,
    address onBehalfOf  // NEW: actual user for compliance
) external override ...
```

The same pattern should be applied to `addLiquidity()` and `removeLiquidity()`. The `onBehalfOf` address should also be checked against the `to` recipient in the router to prevent compliance evasion by specifying a compliant `onBehalfOf` but sending tokens to a non-compliant `to`.

---

### [H-01] HIGH: Flash Swap Callback in RWAPool Bypasses RWAAMM Compliance Layer

**Location:** `RWAAMM.swap()` line 536 calls `pool.swap(amount0Out, amount1Out, caller, "")` with empty data. However, `RWAPool.swap()` supports flash swap callbacks (lines 340-344 in RWAPool.sol).

**Severity:** HIGH

**Description:**
The RWAAMM.swap() function always passes empty data (`""`) to pool.swap(), so flash swaps are never triggered through the normal path. However, the pool's swap function is restricted to `onlyFactory` (the RWAAMM contract), so external callers cannot directly invoke pool.swap() with non-empty data.

This means flash swaps are effectively disabled, which is correct for compliance. However, if a future code path or authorized caller passes non-empty data, the flash swap callback would execute on the `to` address (the user's address from `_msgSender()`), which could be a contract that re-enters the system through a different path.

**Impact:**
Currently mitigated because RWAAMM always passes empty data. But the flash swap mechanism exists in the pool and could be exploited if the architecture changes or if a bug allows non-empty data to reach pool.swap().

**Recommendation:**
Since flash swaps are not intended for RWA trading (compliance requires pre-verification, not post-verification), consider removing the flash swap callback from RWAPool entirely, or add an explicit `require(data.length == 0)` guard in the pool's swap function. This removes an unnecessary attack surface.

---

### [H-02] HIGH: `addLiquidity()` Auto-Creates Pool Without Compliance Check on Token Addresses

**Location:** `addLiquidity()` lines 608-611

**Severity:** HIGH

**Description:**
When `addLiquidity()` is called and the pool does not exist, it auto-creates a pool if the caller has the `_poolCreators` role. The pool creation does not verify that the tokens are registered in the compliance oracle or that they are legitimate RWA tokens.

A malicious pool creator could create a pool for a fake token that mimics a real RWA token address but has different compliance properties. The pool would be created and users could add liquidity to it.

The `_createPool()` function (line 906) only checks that tokens are not identical and not zero, but does not validate them against the compliance oracle.

**Impact:**
A compromised pool creator could create pools for unregistered or malicious tokens. Users who interact with these pools might receive worthless tokens.

**Recommendation:**
Add token validation in `_createPool()` to verify that at least one token is registered with the compliance oracle, or require both tokens to be explicitly approved for pool creation. Consider adding a whitelist of approved tokens for pool creation.

---

### [M-01] MEDIUM: Fee-on-Transfer Token Incompatibility Not Enforced

**Location:** `swap()` lines 519-529

**Severity:** MEDIUM

**Description:**
The contract documentation (lines 59-64) correctly states that fee-on-transfer (FOT) tokens are not supported and will cause KValueDecreased reverts. However, there is no on-chain enforcement preventing pool creation with FOT tokens.

If a pool is accidentally created with a FOT token, all subsequent swaps will revert with `KValueDecreased` because the pool receives less than `amountToPool`. The pool becomes permanently unusable but the LP tokens are locked.

**Impact:**
Permanently locked liquidity if a pool is created with a FOT token. While the contract reverts (so funds are not lost during swaps), the initial liquidity deposit may succeed if the K-value check in `_update()` passes, trapping the LP's funds.

**Recommendation:**
Add a balance-delta check in `_createPool()` or the first `addLiquidity()` to verify that token transfers deliver exact amounts. Alternatively, maintain a registry of approved tokens that have been verified as non-FOT.

---

### [M-02] MEDIUM: Multi-Sig Nonce Shared Across All Operations Creates Sequencing Dependency

**Location:** `_emergencyNonce` used in `emergencyPause()`, `emergencyUnpause()`, and `setPoolCreator()`

**Severity:** MEDIUM

**Description:**
The `_emergencyNonce` is a single counter shared across all multi-sig operations (pause, unpause, setPoolCreator). If two operations are prepared simultaneously (e.g., pausing pool A and pausing pool B), only the first one submitted will succeed. The second will fail because the nonce has been incremented.

This creates a race condition where emergency actions can fail under time pressure -- exactly when they are most needed.

**Impact:**
During an actual emergency requiring multiple simultaneous actions (e.g., pausing multiple pools), operations must be serialized. A front-running attacker could observe a pending pause transaction and submit their own exploit before the second pause transaction can be re-signed with the new nonce.

**Recommendation:**
Use separate nonce counters per operation type, or use a more flexible nonce scheme (e.g., nonce-per-signer or a bitmap-based nonce).

---

### [M-03] MEDIUM: `removeLiquidity()` Compliance Check Blocks Withdrawals for Deregistered Users

**Location:** `removeLiquidity()` lines 698-699

**Severity:** MEDIUM

**Description:**
The `removeLiquidity()` function checks compliance before allowing withdrawal. If a user's KYC status expires or is revoked, they cannot withdraw their liquidity. Their funds are effectively frozen with no recourse.

**Impact:**
Users who deposited while compliant but later become non-compliant (KYC expiry, status change) cannot retrieve their funds. This creates a compliance asymmetry: the system accepts deposits from compliant users but may refuse withdrawals, which is a form of fund seizure.

**Recommendation:**
Consider relaxing compliance checks on withdrawals (allow non-compliant users to exit positions), or implement an emergency withdrawal mechanism that allows users to withdraw after a timelock period regardless of compliance status. Many regulated venues allow unwinding of positions even for non-compliant parties -- the restriction should be on acquiring new positions, not exiting existing ones.

---

### [M-04] MEDIUM: Sandwich Attack Vulnerability on RWA Swaps

**Location:** `swap()` lines 462-561

**Severity:** MEDIUM

**Description:**
The AMM uses a standard constant-product formula with no built-in MEV protection. While the `amountOutMin` parameter provides user-specified slippage protection, RWA tokens with lower liquidity are more susceptible to sandwich attacks that extract value within the user's slippage tolerance.

Since RWA pools are likely to have lower liquidity than major DeFi pairs, even small trades can create significant price impact, making sandwich attacks profitable at lower thresholds.

**Impact:**
Value extraction from users through MEV. RWA tokens with thin liquidity are especially vulnerable. Regulated securities being subject to MEV extraction creates additional regulatory concerns.

**Recommendation:**
Consider implementing:
1. A maximum price impact check (e.g., reject swaps with >5% price impact for RWA tokens)
2. A commit-reveal scheme for large swaps
3. Integration with a private mempool or MEV protection service
4. Time-weighted average price (TWAP) oracles for price bounds

---

### [L-01] LOW: `getQuote()` and `swap()` Do Not Verify `tokenIn != tokenOut`

**Location:** `getQuote()` line 336, `swap()` line 462

**Severity:** LOW

**Description:**
Neither `getQuote()` nor `swap()` explicitly check that `tokenIn` and `tokenOut` are different. While `getPoolId()` would produce a valid pool ID even for identical tokens, and the pool would not exist (since `_createPool()` rejects identical tokens), the error message would be `PoolNotFound` rather than `IdenticalTokens`, which is less informative.

**Impact:**
Confusing error message. No fund loss.

**Recommendation:**
Add `if (tokenIn == tokenOut) revert IdenticalTokens();` at the start of `swap()` and `getQuote()`.

---

### [L-02] LOW: `_allPoolIds` Array Grows Unboundedly

**Location:** `_createPool()` line 930

**Severity:** LOW

**Description:**
The `_allPoolIds` array grows with each pool creation and is never pruned. The `getAllPoolIds()` function returns the entire array, which could hit gas limits if hundreds or thousands of pools are created.

**Impact:**
`getAllPoolIds()` may become unusable for on-chain consumers. Off-chain consumers using `eth_call` would still work but with increasing gas costs.

**Recommendation:**
Add pagination support for `getAllPoolIds()` similar to the oracle's `getRegisteredTokensPaginated()`.

---

### [L-03] LOW: ERC2771Context `_msgSender()` Trust Assumption

**Location:** Constructor line 213, throughout (all `_msgSender()` calls)

**Severity:** LOW

**Description:**
The contract inherits `ERC2771Context` and uses `_msgSender()` for meta-transaction support. The trusted forwarder is set immutably at deployment. If the trusted forwarder contract is compromised or has a vulnerability, an attacker could spoof any sender address.

**Impact:**
Complete access control bypass if the trusted forwarder is compromised. However, the forwarder is immutable, so it cannot be changed to a malicious address after deployment.

**Recommendation:**
Ensure the trusted forwarder is a well-audited, battle-tested contract (e.g., OpenZeppelin MinimalForwarder or Biconomy). If meta-transactions are not needed at launch, consider deploying with `address(0)` as the trusted forwarder to disable the feature entirely.

---

### [L-04] LOW: Pool Pause Check Missing in `getPool(bytes32)` View Function

**Location:** `getPool(bytes32 poolId)` line 297

**Severity:** LOW

**Description:**
The `getPool()` view function returns pool info including a `status` field that correctly reflects the paused state. However, the `getPool(address, address)` overload at line 403 returns only the pool address with no status indication. Off-chain consumers using this function might not be aware that the pool is paused.

**Impact:**
UI/off-chain consumers may attempt transactions on paused pools, resulting in wasted gas.

**Recommendation:**
Document clearly that `getPool(address, address)` does not indicate pause status, or add a `isPoolPaused(bytes32 poolId)` view function.

---

### [I-01] INFORMATIONAL: Fee Split Constants Sum Correctly

**Verification:**
- `FEE_LP_BPS = 7000` (70%)
- `FEE_STAKING_BPS = 2000` (20%)
- `FEE_LIQUIDITY_BPS = 1000` (10%)
- Sum: 10000 = 100% of the protocol fee

The fee calculation is correct:
- `protocolFee = amountIn * 30 / 10000` (0.30%)
- `lpFee = protocolFee * 7000 / 10000` (70% of fee = 0.21% of amountIn)
- `vaultFee = protocolFee - lpFee` (30% of fee = 0.09% of amountIn)

The `amountToPool = amountInAfterFee + lpFee` correctly donates the LP portion to the pool while the vault fee is sent to UnifiedFeeVault.

**Status:** VERIFIED CORRECT

---

### [I-02] INFORMATIONAL: Constant-Product Formula Verified

**Verification:**
The AMM formula `amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee)` is the standard constant-product formula derived from `(reserveIn + dx) * (reserveOut - dy) = reserveIn * reserveOut`.

The `getQuote()` function at line 365 and `swap()` function at line 510-511 use identical formulas, ensuring quotes match actual swap outputs (excluding external factors like MEV).

**Status:** VERIFIED CORRECT

---

### [I-03] INFORMATIONAL: Multi-Sig Implementation Correctly Prevents Replay

The multi-sig verification includes:
- `block.chainid` (prevents cross-chain replay)
- `address(this)` (prevents cross-contract replay)
- `_emergencyNonce` (prevents same-chain replay)
- Duplicate signature detection (prevents signature reuse within a call)
- Operation-specific prefixes ("PAUSE", "UNPAUSE", "SET_POOL_CREATOR")

**Status:** VERIFIED CORRECT

---

### [I-04] INFORMATIONAL: `swap()` Correctly Handles the Fee/AMM Split

The swap function correctly separates the fee from the AMM calculation:
1. Total fee = 0.30% of amountIn
2. LP fee (70% of total fee) is added to amountToPool but NOT included in the AMM curve calculation
3. AMM output is calculated using only amountInAfterFee (99.70% of amountIn)
4. Pool receives amountInAfterFee + lpFee (increasing K over time)
5. The K-value check in RWAPool will pass because the pool receives MORE than what the AMM formula requires

This means LPs benefit from both the curve spread and explicit fee donations, which is documented and correct.

**Status:** VERIFIED CORRECT

---

## Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | CRITICAL | Router Compliance Bypass | Open |
| H-01 | HIGH | Flash Swap Callback Attack Surface | Open |
| H-02 | HIGH | Pool Creation Without Token Validation | Open |
| M-01 | MEDIUM | FOT Token Incompatibility Not Enforced | Open |
| M-02 | MEDIUM | Shared Multi-Sig Nonce Race Condition | Open |
| M-03 | MEDIUM | Compliance Blocks Withdrawal for Deregistered Users | Open |
| M-04 | MEDIUM | Sandwich Attack Vulnerability | Open |
| L-01 | LOW | Missing tokenIn != tokenOut Check | Open |
| L-02 | LOW | Unbounded Pool ID Array | Open |
| L-03 | LOW | ERC2771 Trust Assumption | Open |
| L-04 | LOW | Pool Pause Status Not Exposed | Open |
| I-01 | INFO | Fee Split Constants Verified | Verified |
| I-02 | INFO | Constant-Product Formula Verified | Verified |
| I-03 | INFO | Multi-Sig Replay Protection Verified | Verified |
| I-04 | INFO | Fee/AMM Split Verified | Verified |

---

## Positive Observations

1. **Immutable design** is excellent for regulatory defensibility
2. **Fee constants are immutable** -- no admin can change the 0.30% fee
3. **ReentrancyGuard** on swap and liquidity functions
4. **Deadline checks** prevent stale transactions
5. **Slippage protection** on all user-facing functions
6. **Pool creator gating** prevents uncontrolled pool creation
7. **Thorough NatSpec documentation** including edge cases
8. **SafeERC20** used consistently for all token transfers
9. **Custom errors** instead of string reverts (gas efficient)
10. **Explicit FOT token warning** in documentation
