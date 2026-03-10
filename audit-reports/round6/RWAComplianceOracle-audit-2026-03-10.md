# Security Audit Report: RWAComplianceOracle.sol

**Contract:** `contracts/rwa/RWAComplianceOracle.sol` (811 lines)
**Auditor:** Claude Opus 4.6 (Automated Security Audit)
**Date:** 2026-03-10
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL

---

## Executive Summary

RWAComplianceOracle is the on-chain compliance verification engine for RWA tokens. It supports ERC-20, ERC-3643 (T-REX), ERC-1400 (Polymath), and ERC-4626 token standards. The oracle detects token standards via ERC-165 and function probing, delegates compliance checks to the token's own compliance contracts (canTransfer, canTransferByPartition), and provides caching with 5-minute TTL.

This contract does not handle funds directly. Its security surface is centered on access control (registrar role), compliance check correctness, and resistance to manipulation that could enable non-compliant users to trade regulated securities.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | Single-step registrar transfer | **FIXED** — two-step transfer |
| H-02 | High | Fail-open on oracle downtime | **FIXED** — fail-closed |
| M-01 | Medium | Token standard auto-detection can be spoofed | **FIXED** |
| M-02 | Medium | canTransfer uses oracle address as destination | **FIXED** |
| M-03 | Medium | Cache poisoning during reconfiguration | **FIXED** |
| M-04 | Medium | Deregistered tokens remain in array | **FIXED** |

---

## Findings

### [H-01] HIGH: Single-Step Registrar Transfer Risks Permanent Loss of Admin Control

**Location:** `setRegistrar()` lines 251-256

**Severity:** HIGH

**Description:**
The `setRegistrar()` function performs an immediate, single-step transfer of the registrar role:

```solidity
function setRegistrar(address newRegistrar) external onlyRegistrar {
    if (newRegistrar == address(0)) revert ZeroAddress();
    address oldRegistrar = registrar;
    registrar = newRegistrar;
    emit RegistrarUpdated(oldRegistrar, newRegistrar);
}
```

The contract's own documentation (lines 45-46) acknowledges this:

> *"The registrar can be transferred via setRegistrar(), which should use a 2-step transfer pattern in future versions to prevent accidental transfers to incorrect addresses."*

If the registrar is accidentally transferred to an incorrect address (typo, wrong checksum, contract that cannot call setRegistrar), all administrative functions become permanently inaccessible:
- `registerToken()` -- cannot register new RWA tokens
- `updateTokenConfig()` -- cannot update compliance contracts
- `deregisterToken()` -- cannot remove compromised tokens
- `refreshCompliance()` -- cannot update compliance cache
- `invalidateCache()` -- cannot invalidate stale cache entries
- `setRegistrar()` -- cannot recover the registrar role

**Impact:**
Permanent loss of administrative control over the compliance oracle. Since RWAAMM is immutable and references this oracle contract as an immutable address, a new oracle cannot be deployed without deploying an entirely new RWAAMM (which would require migrating all pools and liquidity).

**Recommendation:**
Implement a 2-step transfer pattern:

```solidity
address public pendingRegistrar;

function transferRegistrar(address newRegistrar) external onlyRegistrar {
    if (newRegistrar == address(0)) revert ZeroAddress();
    pendingRegistrar = newRegistrar;
    emit RegistrarTransferInitiated(registrar, newRegistrar);
}

function acceptRegistrar() external {
    if (msg.sender != pendingRegistrar) revert NotPendingRegistrar();
    address oldRegistrar = registrar;
    registrar = pendingRegistrar;
    pendingRegistrar = address(0);
    emit RegistrarUpdated(oldRegistrar, registrar);
}
```

This ensures the new registrar can actually call the contract before the transfer is finalized.

---

### [H-02] HIGH: Compliance Oracle Downtime Causes Fail-Open Behavior for Some Token Types

**Location:** `_checkComplianceInternal()` lines 484-543

**Severity:** HIGH

**Description:**
When the compliance oracle is called and the external compliance contract (ERC-3643 canTransfer, ERC-1400 canTransferByPartition) reverts or is unavailable, the oracle returns `ComplianceStatus.CHECK_FAILED`:

```solidity
} catch {
    return ComplianceResult({
        status: ComplianceStatus.CHECK_FAILED,
        ...
    });
}
```

However, the RWAAMM contract treats `CHECK_FAILED` as non-compliant only for the `_checkLiquidityCompliance()` path (which checks `status != COMPLIANT`). For the `_checkSwapCompliance()` path, the oracle's `checkSwapCompliance()` function returns booleans:

```solidity
inputCompliant = inputResult.status == ComplianceStatus.COMPLIANT;
```

This means `CHECK_FAILED` is treated as `inputCompliant = false`, which correctly blocks the swap. **This is fail-closed behavior, which is correct.**

However, for ERC-20 tokens or tokens with `complianceEnabled = false`, the oracle returns `COMPLIANT` without any external call (lines 507-522). If the registrar accidentally disables compliance for a regulated token (via `updateTokenConfig(token, complianceContract, false)`), all users become compliant for that token -- effectively fail-open.

**Impact:**
A compromised or careless registrar can disable compliance for any registered token by calling `updateTokenConfig(token, addr, false)`. This would silently bypass all KYC/accreditation checks for that token.

**Recommendation:**
1. Add a safety check: if a token was registered as ERC-3643 or ERC-1400 (which require compliance), do not allow `complianceEnabled` to be set to `false` without a time delay or multi-sig approval
2. Emit a high-severity event when compliance is disabled for a previously compliance-enabled token
3. Consider requiring multi-sig approval for compliance-disabling changes

---

### [M-01] MEDIUM: Token Standard Auto-Detection Can Be Spoofed

**Location:** `_detectTokenStandard()` lines 551-583

**Severity:** MEDIUM

**Description:**
The token standard detection uses three mechanisms:
1. ERC-165 `supportsInterface()` for ERC-3643 and ERC-1400
2. Function probing (`asset()` for ERC-4626, `canTransfer()` for ERC-3643)
3. Default to ERC-20

A malicious token can implement `supportsInterface()` to return `true` for ERC-3643 while not actually implementing the compliance checks. This would cause the oracle to:
1. Register the token as ERC-3643
2. Call `canTransfer()` on the compliance contract
3. The malicious `canTransfer()` always returns `true`, bypassing real compliance

Conversely, a malicious token could implement `supportsInterface()` to return `false` for all interfaces, causing it to be classified as ERC-20 (no compliance required). If the registrar does not manually verify the token standard, a regulated security could be traded without compliance checks.

**Impact:**
- **False positive (claims to be ERC-3643):** The token's malicious `canTransfer()` always returns true, allowing non-compliant users to trade
- **False negative (claims to be ERC-20):** A regulated security bypasses all compliance checks

Both scenarios require the registrar to register the malicious token, so the attack requires social engineering or a compromised registrar.

**Recommendation:**
1. Allow the registrar to manually override the detected token standard during registration
2. Add a parameter to `registerToken()` for the expected standard, and verify it matches the detected standard (or allow override with explicit acknowledgment)
3. For high-security deployments, require the registrar to manually specify the compliance contract address and standard, ignoring auto-detection

---

### [M-02] MEDIUM: `_checkERC3643Compliance()` Uses `address(this)` as Transfer Destination

**Location:** `_checkERC3643Compliance()` line 607

**Severity:** MEDIUM

**Description:**
The compliance check calls:

```solidity
IERC3643(complianceAddr).canTransfer(user, address(this), 1)
```

This checks whether the user can transfer to the oracle contract, not whether the user can transfer to the AMM, pool, or actual recipient. Some ERC-3643 implementations may have per-recipient restrictions (e.g., the recipient must also be in the identity registry).

If the oracle's address (`address(this)`) is not in the token's identity registry, the `canTransfer()` call might return `false` even for compliant users, causing false negatives.

Conversely, if `address(this)` IS in the identity registry, the check passes for the oracle as the destination, but the actual transfer goes to a different address (the pool or the user), which might not be in the registry.

**Impact:**
The compliance check may not accurately reflect whether the actual on-chain transfer will succeed. The transfer could either:
- Fail at the token level despite passing the compliance check (oracle whitelisted, but pool/recipient is not)
- Succeed despite a compliance check failure (oracle not whitelisted, but the actual recipient is)

**Recommendation:**
Accept additional parameters for the actual `from` and `to` addresses of the intended transfer, and use those in the `canTransfer()` call:

```solidity
function checkCompliance(
    address user,
    address token,
    address transferTo  // actual transfer destination
) external view returns (ComplianceResult memory);
```

This would require updating the RWAAMM to pass the pool address as the transfer destination.

---

### [M-03] MEDIUM: Cache Poisoning Window During Compliance Contract Reconfiguration

**Location:** `refreshCompliance()` lines 338-348, `_checkComplianceInternal()` lines 282-286

**Severity:** MEDIUM

**Description:**
The `checkCompliance()` function checks the cache first. If a cached result has `validUntil > block.timestamp`, it is returned without re-evaluating. The cache is populated by `refreshCompliance()` which is registrar-only.

The race condition documented in the code (lines 331-334) is:
1. Registrar calls `updateTokenConfig()` to change the compliance contract
2. Before the cache expires (5-minute TTL), an attacker calls through a path that hits the cache
3. The cached result (from the OLD compliance contract) is used

However, this is partially mitigated because `refreshCompliance()` is registrar-only and `checkCompliance()` reads the cache but the main on-chain path (via RWAAMM) calls `_checkComplianceInternal()` through `checkSwapCompliance()` or `checkCompliance()`, which DO check the cache.

The real risk: if the registrar calls `refreshCompliance()` for a user RIGHT BEFORE changing the compliance contract, the user has a 5-minute window of stale compliance.

**Impact:**
A user could retain compliance status for up to 5 minutes after their compliance is revoked, if the cache was recently refreshed. For RWA securities, a 5-minute window of non-compliant trading creates regulatory risk.

**Recommendation:**
The registrar should always call `invalidateCache()` BEFORE calling `updateTokenConfig()` to ensure the cache does not contain stale results. Consider making `updateTokenConfig()` automatically invalidate all cached results for the affected token (this requires iterating through users, which may be gas-prohibitive, so an alternative is a per-token cache version counter).

---

### [M-04] MEDIUM: `deregisterToken()` Does Not Remove Token from `_registeredTokens` Array

**Location:** `deregisterToken()` lines 234-245

**Severity:** MEDIUM

**Description:**
When a token is deregistered, only the `registered` flag is set to `false` in the config struct. The token address remains in the `_registeredTokens` array. The documentation acknowledges this (lines 229-231):

> *"Does not remove from _registeredTokens array (gas cost prohibitive for on-chain array removal)."*

This means `getRegisteredTokens()` and `getRegisteredTokensPaginated()` will return deregistered tokens. Consumers of these functions must filter by checking `isTokenRegistered()` for each returned address, which is error-prone.

**Impact:**
Off-chain consumers or other contracts that iterate `_registeredTokens` may incorrectly treat deregistered tokens as registered. This could cause:
- UI showing deregistered tokens as available
- Batch operations including deregistered tokens
- Gradually increasing gas costs for `getRegisteredTokens()` as deregistered tokens accumulate

**Recommendation:**
1. Add a comment to `getRegisteredTokens()` warning that deregistered tokens are included
2. Add a helper function `getActiveRegisteredTokens()` that filters out deregistered tokens
3. For the paginated version, add a `onlyActive` parameter to filter during iteration

---

### [L-01] LOW: ERC-4626 Probe May False-Positive

**Location:** `_detectTokenStandard()` lines 567-572

**Severity:** LOW

**Description:**
The ERC-4626 detection probes for the `asset()` function:

```solidity
try IERC4626Probe(token).asset() returns (address) {
    return TokenStandard.ERC4626;
} catch {
    // Not ERC-4626
}
```

Any contract that implements a public `asset()` function returning an address will be classified as ERC-4626, even if it is not a vault. This includes:
- Custom contracts with an `asset` getter
- Proxy contracts with fallback functions that return valid data for any call

Since ERC-4626 tokens are treated as "no compliance requirements" (same as ERC-20), a false positive means a token requiring compliance could be classified as ERC-4626 and bypass compliance checks.

**Impact:**
A token that should require compliance (e.g., a regulated security with an unrelated `asset()` function) could be misclassified as ERC-4626 and bypass compliance.

**Recommendation:**
Change the detection order: check ERC-3643 and ERC-1400 first (more specific), then ERC-4626 (less specific). The current implementation already does this. Additionally, verify that `asset()` returns a non-zero address and that the token also implements `totalAssets()` or other ERC-4626 functions for higher confidence.

---

### [L-02] LOW: `canTransfer` Probing with `address(0)` in Detection May Revert Differently

**Location:** `_detectTokenStandard()` line 575

**Severity:** LOW

**Description:**
The fallback ERC-3643 detection calls:

```solidity
try IERC3643(token).canTransfer(address(0), address(0), 0) returns (bool, bytes1, bytes32) {
    return TokenStandard.ERC3643;
}
```

Passing `address(0)` as both `from` and `to` may cause some ERC-3643 implementations to revert (because address(0) is not a valid identity). This would cause the detection to fall through to ERC-20, even though the token is actually ERC-3643.

The primary detection via ERC-165 `supportsInterface()` should catch most ERC-3643 tokens, so this fallback is only needed for non-ERC-165-compliant implementations.

**Impact:**
Potential misclassification of non-ERC-165-compliant ERC-3643 tokens as ERC-20. This would bypass compliance checks.

**Recommendation:**
Use non-zero addresses for the probe (e.g., `address(1)` instead of `address(0)`). Also, consider catching the function selector match (the try succeeds even if canTransfer returns false) rather than the parameter values.

---

### [L-03] LOW: Batch Compliance Check Gas Limit

**Location:** `batchCheckCompliance()` lines 368-384

**Severity:** LOW

**Description:**
The maximum batch size is 50 (`MAX_BATCH_SIZE`). Each compliance check involves an external call to the token's compliance contract (for ERC-3643/ERC-1400). With 50 external calls, gas consumption could be significant, potentially exceeding block gas limits on some chains.

On Avalanche C-Chain (the target deployment), the block gas limit is 8M gas. Each compliance check with an external call could cost 50-100K gas, so 50 checks could consume 2.5-5M gas. This should be within limits but is close to the margin.

**Impact:**
Batch compliance check may revert if too many checks involve external calls. This is a view function, so it only affects `eth_call` consumers, not on-chain transactions.

**Recommendation:**
Consider reducing `MAX_BATCH_SIZE` to 20-30, or allow the caller to specify the batch size with a dynamic limit based on gas remaining.

---

### [L-04] LOW: No Event Emitted on `invalidateCache()`

**Location:** `invalidateCache()` lines 358-363

**Severity:** LOW

**Description:**
The `invalidateCache()` function deletes the cached compliance result but does not emit an event. This makes it difficult for off-chain monitoring systems to detect cache invalidations.

**Impact:**
Reduced observability. No fund loss.

**Recommendation:**
Add an event: `event CacheInvalidated(address indexed user, address indexed token);`

---

### [I-01] INFORMATIONAL: Fail-Closed Default Verified

Unregistered tokens return `ComplianceStatus.NON_COMPLIANT` with reason "Token not registered - compliance unknown". This is the correct fail-closed behavior -- any token not explicitly registered is treated as non-compliant.

**Status:** VERIFIED CORRECT

---

### [I-02] INFORMATIONAL: ERC-1066 Reason Code Check Verified

The ERC-1400 compliance check at line 688:

```solidity
bool isSuccess = (reasonCode > 0x9F && reasonCode < 0xB0);
```

This correctly checks the ERC-1066 Application-specific Status Code range for success (0xA0 through 0xAF inclusive). The boundary checks are:
- `> 0x9F` means `>= 0xA0`
- `< 0xB0` means `<= 0xAF`

**Status:** VERIFIED CORRECT

---

### [I-03] INFORMATIONAL: `checkSwapCompliance()` Ignores `amountIn` Parameter

**Location:** `checkSwapCompliance()` line 300

**Severity:** INFORMATIONAL

**Description:**
The `amountIn` parameter is declared but not used (`/* amountIn */`). This means the oracle does not enforce per-transaction amount limits. The interface includes `amountIn` for future use (e.g., maximum transaction size limits per compliance tier).

**Status:** Documented for awareness. Not a bug -- future functionality reserved.

---

### [I-04] INFORMATIONAL: Cache TTL Is Constant (5 Minutes)

The 5-minute cache TTL is hardcoded as a constant:

```solidity
uint256 public constant CACHE_TTL = 5 minutes;
```

This cannot be adjusted per-token or per-standard. Some compliance scenarios may benefit from shorter TTLs (e.g., tokens with frequently changing investor registries) or longer TTLs (e.g., stablecoins with stable compliance status).

**Recommendation:** Consider making the TTL configurable per-token in the `TokenConfig` struct for future flexibility. Not urgent for current deployment.

---

### [I-05] INFORMATIONAL: ReentrancyGuard on `refreshCompliance()` Is Appropriate

The `refreshCompliance()` function uses `nonReentrant` from OpenZeppelin's ReentrancyGuard. This is appropriate because the function makes external calls to compliance contracts (via `_checkComplianceInternal()`) and writes to storage (cache update). The reentrancy guard prevents a malicious compliance contract from re-entering the oracle during the external call.

**Status:** VERIFIED CORRECT

---

### [I-06] INFORMATIONAL: No Re-Registration After Deregistration

Once a token is deregistered, `registerToken()` will still revert because the `registered` flag is set to `false` but the `_tokenConfigs[token]` struct still exists. Wait -- checking the code:

```solidity
if (_tokenConfigs[token].registered) revert TokenAlreadyRegistered(token);
```

After deregistration, `registered = false`, so this check passes. The token CAN be re-registered. However, the `_registeredTokens` array will then contain the token address twice.

**Recommendation:** Before re-registering, check if the token is already in the array and skip the push. Or use a separate flag to track array membership.

---

## Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | HIGH | Single-Step Registrar Transfer | Open |
| H-02 | HIGH | Fail-Open on Compliance Disable | Open |
| M-01 | MEDIUM | Token Standard Spoofing | Open |
| M-02 | MEDIUM | canTransfer Uses Oracle Address as Destination | Open |
| M-03 | MEDIUM | Cache Poisoning During Reconfiguration | Open |
| M-04 | MEDIUM | Deregistered Tokens in Array | Open |
| L-01 | LOW | ERC-4626 False Positive | Open |
| L-02 | LOW | canTransfer Probe with address(0) | Open |
| L-03 | LOW | Batch Compliance Gas Limit | Open |
| L-04 | LOW | No Event on Cache Invalidation | Open |
| I-01 | INFO | Fail-Closed Default Verified | Verified |
| I-02 | INFO | ERC-1066 Reason Code Verified | Verified |
| I-03 | INFO | amountIn Parameter Unused | Documented |
| I-04 | INFO | Constant Cache TTL | Documented |
| I-05 | INFO | ReentrancyGuard on refreshCompliance | Verified |
| I-06 | INFO | Re-Registration Duplicates Array Entry | Open |

---

## Positive Observations

1. **Fail-closed default** -- unregistered tokens are treated as non-compliant
2. **Safe external calls** via try/catch -- malicious compliance contracts cannot crash the oracle
3. **Registrar-only cache writes** prevent cache poisoning by unauthorized parties
4. **ReentrancyGuard** on state-modifying functions
5. **Batch compliance** with size limits prevents gas griefing
6. **Pagination support** for registered tokens prevents unbounded gas consumption
7. **Comprehensive NatSpec** with security rationale
8. **Auto-detection** of token standards via ERC-165 and function probing
9. **Proper ERC-1066** reason code range check for ERC-1400 compliance
10. **Cache invalidation** function for emergency compliance revocation

---

## Cross-Contract Interaction Notes

### Oracle Downtime Scenario

If the compliance oracle's registrar key is lost (see H-01), the following happens:
1. No new tokens can be registered -- new RWA pools cannot enforce compliance
2. Existing compliance contracts cannot be updated -- if a compliance contract is compromised, it cannot be replaced
3. Cache cannot be refreshed or invalidated -- stale compliance data persists
4. The oracle continues to function for existing tokens via live `canTransfer()` calls, but administrative actions are blocked

This makes the 2-step registrar transfer (H-01) especially important.

### Stale Data Risk

If the compliance contract of a registered token becomes unresponsive or returns incorrect results:
1. `_checkERC3643Compliance()` returns `CHECK_FAILED`
2. RWAAMM treats `CHECK_FAILED` as non-compliant (fail-closed)
3. All swaps involving that token are blocked
4. The registrar must update the compliance contract via `updateTokenConfig()`

This is the correct fail-closed behavior.
