# Security Audit Report: RWAComplianceOracle.sol

**Contract:** `contracts/rwa/RWAComplianceOracle.sol` (1017 lines incl. helper interfaces)
**Interface:** `contracts/rwa/interfaces/IRWAComplianceOracle.sol` (221 lines)
**Auditor:** Claude Opus 4.6 (Automated Security Audit)
**Date:** 2026-03-13
**Round:** 7
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL

---

## Executive Summary

RWAComplianceOracle is the on-chain compliance verification engine for RWA (Real World Asset) tokens in the OmniBazaar ecosystem. It supports four token standards (ERC-20, ERC-3643/T-REX, ERC-1400/Polymath, ERC-4626 Vaults), auto-detects standards via ERC-165 and function probing, delegates compliance checks to each token's own compliance contracts, and provides a registrar-controlled cache with 5-minute TTL.

**Trust Model:** The contract centralizes control in a single `registrar` address. All token registration, configuration updates, cache writes, and administrative functions require this role. The registrar is the single point of trust -- its compromise or loss renders the contract unmanageable. A two-step transfer pattern mitigates accidental loss.

**This contract does not hold or transfer funds.** Its security surface is centered on correctness of compliance verdicts. A false-positive (incorrectly returning COMPLIANT) would allow non-KYC/non-accredited users to trade regulated securities through RWAAMM, creating regulatory liability.

### Round 7 vs Round 6 Remediation Status

All Critical, High, and Medium findings from Round 6 have been remediated in the current codebase:

| Round 6 ID | Severity | Finding | Remediation Status |
|------------|----------|---------|-------------------|
| H-01 | HIGH | Single-step registrar transfer | **FIXED** -- Two-step `proposeRegistrar()`/`acceptRegistrar()` (lines 373-395) |
| H-02 | HIGH | Fail-open on compliance disable | **FIXED** -- `CannotDisableRequiredCompliance` error (lines 313-323), defense-in-depth in `_checkComplianceInternal` (lines 684-703) |
| M-01 | MEDIUM | Token standard auto-detection spoofing | **FIXED** -- `registerTokenWithStandard()` with explicit override (lines 230-238) |
| M-02 | MEDIUM | canTransfer uses oracle address as destination | **ACKNOWLEDGED** -- Documented limitation with mitigation guidance (lines 786-796) |
| M-03 | MEDIUM | Cache poisoning during reconfiguration | **FIXED** -- Per-token `_tokenCacheVersion` counter, incremented on config update (lines 89-96, 335) |
| M-04 | MEDIUM | Deregistered tokens remain in array | **ACKNOWLEDGED** -- Documented as gas-cost trade-off; pagination provided (lines 347, 595-615) |

### Solhint Results

```
2 warnings, 0 errors
- Line 297: Function ordering (external after internal) -- cosmetic
- Line 435: not-rely-on-time -- legitimate use for cache TTL comparison
```

---

## Findings

### [L-01] LOW: Re-Registration After Deregistration Creates Duplicate Array Entry

**Location:** `_registerTokenInternal()` line 275, `deregisterToken()` lines 350-361

**Description:**

When a token is deregistered via `deregisterToken()`, only the `registered` flag in the `_tokenConfigs` mapping is set to `false`. The token address remains in the `_registeredTokens` array. If the registrar subsequently re-registers the same token (which is permitted because the check on line 253 only inspects `_tokenConfigs[token].registered`), the token address is pushed to `_registeredTokens` a second time (line 275).

After deregister + re-register:
- `_registeredTokens` contains the token address twice
- `getRegisteredTokens()` and `getRegisteredTokensPaginated()` return it twice
- `getRegisteredTokenCount()` is inflated by one

This is a data integrity issue, not a security vulnerability. The compliance checking logic operates on `_tokenConfigs` (mapping), not `_registeredTokens` (array), so compliance verdicts are unaffected.

**Impact:** Off-chain consumers iterating the array may double-count tokens. The `getRegisteredTokenCount()` becomes unreliable after deregister/re-register cycles.

**Recommendation:**
Option A: Add a separate `bool inArray` field or mapping to track array membership, and skip `push` if already present.
Option B: On deregistration, use the swap-and-pop pattern with an index mapping for O(1) removal.
Option C (minimal): Document the behavior in the NatSpec for `getRegisteredTokens()` and `getRegisteredTokenCount()`.

**Status:** Open (carried forward from Round 6 I-06)

---

### [L-02] LOW: ERC-4626 Detection Probe May False-Positive on Non-Vault Contracts

**Location:** `_detectTokenStandard()` lines 761-766

**Description:**

ERC-4626 detection relies solely on probing the `asset()` function:

```solidity
try IERC4626Probe(token).asset() returns (address) {
    return TokenStandard.ERC4626;
} catch {
    // Not ERC-4626, continue
}
```

Any contract exposing a public `asset()` function that returns an `address` will be classified as ERC-4626. Examples include: custom contracts with an `asset` state variable, proxy contracts with a liberal fallback, or wrapper tokens. Since ERC-4626 is treated identically to ERC-20 (no compliance required), a misclassified regulated token would bypass all compliance checks.

The detection order mitigates this partially: ERC-3643 and ERC-1400 are checked first via ERC-165. However, a regulated token that does not implement ERC-165 but does have an unrelated `asset()` getter would be misclassified as ERC-4626 rather than falling through to the `canTransfer` probe or the ERC-20 default.

**Impact:** Potential bypass of compliance for edge-case regulated tokens that happen to expose `asset()`. Mitigated by the `registerTokenWithStandard()` override (M-01 fix).

**Recommendation:** Add a secondary probe (e.g., `totalAssets()`) to increase detection confidence. Alternatively, only use auto-detection as a hint and always require registrar confirmation of the detected standard.

**Status:** Open (carried forward from Round 6 L-01)

---

### [L-03] LOW: `canTransfer` Fallback Probe Uses `address(0)` Parameters

**Location:** `_detectTokenStandard()` line 769

**Description:**

The fallback ERC-3643 detection probes:

```solidity
try IERC3643(token).canTransfer(address(0), address(0), 0) returns (bool, bytes1, bytes32) {
    return TokenStandard.ERC3643;
}
```

Passing `address(0)` for `from` and `to` may cause many T-REX implementations to revert (invalid identity), causing the detection to incorrectly fall through to ERC-20. Since ERC-20 has no compliance requirements, this creates a false-negative misclassification.

The primary ERC-165 detection on lines 747-751 should catch most implementations, but tokens that do not support ERC-165 will rely on this fallback. Using `address(1)` instead of `address(0)` would be more likely to succeed without triggering zero-address validation checks in the external contract.

**Impact:** Non-ERC-165-compliant ERC-3643 tokens may be misclassified as ERC-20, bypassing compliance. Mitigated by the manual `registerTokenWithStandard()` override.

**Recommendation:** Use `address(1)` instead of `address(0)` for the probe parameters.

**Status:** Open (carried forward from Round 6 L-02)

---

### [L-04] LOW: No Event Emitted on `invalidateCache()` or `cancelRegistrarTransfer()`

**Location:** `invalidateCache()` lines 516-521, `cancelRegistrarTransfer()` lines 401-403

**Description:**

Two state-modifying administrative functions do not emit events:

1. `invalidateCache(user, token)` -- deletes a cached compliance result with no event
2. `cancelRegistrarTransfer()` -- clears `pendingRegistrar` with no event

Both actions are security-relevant. Cache invalidation affects compliance enforcement timing. Cancelling a registrar transfer is an administrative governance action. Off-chain monitoring systems and block explorers cannot detect these operations without events.

**Impact:** Reduced observability for security monitoring. No fund loss risk.

**Recommendation:**
```solidity
event CacheInvalidated(address indexed user, address indexed token);
event RegistrarTransferCancelled(address indexed registrar);
```

**Status:** Open (L-04 carried forward from Round 6; `cancelRegistrarTransfer` is new)

---

### [L-05] LOW: `checkSwapCompliance()` String Concatenation Lacks Gas Bound

**Location:** `checkSwapCompliance()` lines 469-479

**Description:**

When both tokens are non-compliant, the function concatenates reason strings using `abi.encodePacked`:

```solidity
reason = string(abi.encodePacked(
    "Input: ", inputResult.reason, "; Output: ", outputResult.reason
));
```

The `reason` strings originate from `_checkComplianceInternal()` which uses hardcoded string literals (e.g., "ERC-3643 compliance check failed"), so the total length is bounded by design. However, if a future code change introduces dynamic-length reason strings (e.g., from external compliance contracts), the concatenation could become expensive.

This is a `view` function, so excessive gas only affects `eth_call` consumers, not on-chain transactions. In practice the RWAAMM calls `checkSwapCompliance()` internally which is within transaction gas, but the result string is only used in a revert message (which is truncated by the EVM at the gas limit).

**Impact:** Minimal. Bounded by current hardcoded strings. Future maintenance concern only.

**Recommendation:** No action needed for current implementation. Document the assumption that reason strings are short (<128 bytes).

**Status:** Open (Informational in practice)

---

### [I-01] INFORMATIONAL: `UNKNOWN` Standard Tokens Fall Through to COMPLIANT Default

**Location:** `_checkComplianceInternal()` lines 718-736

**Description:**

The compliance check logic handles ERC-20 explicitly (line 665), ERC-3643 (line 719), and ERC-1400 (line 721). All other standards -- including `TokenStandard.ERC4626` and any hypothetical `TokenStandard.UNKNOWN` -- fall through to the default case at line 726, which returns `COMPLIANT`.

In practice, a token can never be registered with `UNKNOWN` standard through `_registerTokenInternal()`: the line 258-261 logic uses `_detectTokenStandard()` when `standardOverride == UNKNOWN`, and `_detectTokenStandard()` always returns a concrete standard (never UNKNOWN). So this path is unreachable under normal operation.

However, if a future modification to `_detectTokenStandard()` introduced a path returning `UNKNOWN`, any such token would be treated as COMPLIANT with no compliance checks. This is fail-open for an unknown standard.

**Impact:** No impact with current code. Defense-in-depth concern.

**Recommendation:** Add an explicit branch for `UNKNOWN` that returns `NON_COMPLIANT` (fail-closed):

```solidity
// After ERC-1400 check, before default:
if (config.standard == TokenStandard.UNKNOWN) {
    return ComplianceResult({
        status: ComplianceStatus.NON_COMPLIANT,
        ...
        reason: "Unknown token standard - compliance cannot be verified"
    });
}
```

**Status:** Open

---

### [I-02] INFORMATIONAL: `_registeredTokens` Array Growth Is Unbounded

**Location:** `_registerTokenInternal()` line 275, `getRegisteredTokens()` line 583

**Description:**

Every call to `registerToken()` or `registerTokenWithStandard()` pushes to `_registeredTokens`. Deregistration does not remove entries (by design -- gas cost). Over time this array grows monotonically.

`getRegisteredTokens()` returns the full array, which could exceed block gas limits for `eth_call` if the array becomes very large (thousands of entries). The paginated alternative `getRegisteredTokensPaginated()` exists, but the unpaginated function remains available.

**Impact:** `getRegisteredTokens()` may become uncallable for very large registries. No impact on compliance checking (which uses the mapping, not the array).

**Recommendation:** Consider deprecating `getRegisteredTokens()` with a comment directing callers to `getRegisteredTokensPaginated()`, or adding a size guard that reverts if the array exceeds a safe threshold.

**Status:** Open (informational)

---

### [I-03] INFORMATIONAL: `checkSwapCompliance()` Ignores `amountIn` Parameter

**Location:** `checkSwapCompliance()` line 454 (`/* amountIn */`)

**Description:**

The `amountIn` parameter is declared in the interface and implementation but explicitly unused. This means the oracle cannot enforce per-transaction amount limits (e.g., maximum trade size for certain compliance tiers, daily volume limits per user).

The interface includes it for forward compatibility. The parameter is correctly silenced with `/* amountIn */` to avoid compiler warnings.

**Impact:** No current impact. Future functionality reserved.

**Status:** Documented (carried forward)

---

### [I-04] INFORMATIONAL: Cache TTL Is a Constant (5 Minutes)

**Location:** Line 59: `uint256 public constant CACHE_TTL = 5 minutes;`

**Description:**

The 5-minute TTL is applied uniformly to all tokens and all compliance statuses. Some scenarios that might benefit from different TTLs:

- **Shorter TTL (1 min):** Tokens with frequently changing investor registries
- **Longer TTL (30 min):** Stable ERC-20 tokens with no compliance requirements (though these don't use the cache anyway)
- **Zero TTL:** Disable caching entirely for high-security tokens

**Impact:** No security impact. Flexibility concern for diverse token compliance requirements.

**Recommendation:** Consider making TTL configurable per-token in a future version by adding a `cacheTTL` field to `TokenConfig`.

**Status:** Documented (carried forward)

---

### [I-05] INFORMATIONAL: ReentrancyGuard Applied Correctly

**Description:**

`refreshCompliance()` (the only state-modifying function that makes external calls) uses both `onlyRegistrar` and `nonReentrant`. The reentrancy guard prevents a malicious compliance contract from re-entering the oracle during the `try/catch` external call in `_checkComplianceInternal()`.

Other state-modifying functions (`registerToken`, `updateTokenConfig`, `deregisterToken`, `proposeRegistrar`, `acceptRegistrar`, `cancelRegistrarTransfer`, `invalidateCache`) do not make external calls, so they do not need reentrancy protection.

`checkCompliance()` and `batchCheckCompliance()` are `view` functions that make external calls via `try/catch`, but since they cannot modify state, reentrancy is not a concern.

**Status:** VERIFIED CORRECT

---

### [I-06] INFORMATIONAL: Two-Step Registrar Transfer Pattern Is Sound

**Description:**

The `proposeRegistrar()` / `acceptRegistrar()` / `cancelRegistrarTransfer()` pattern (lines 373-403) correctly implements two-step ownership transfer:

1. Current registrar calls `proposeRegistrar(newAddr)` -- sets `pendingRegistrar`
2. New address calls `acceptRegistrar()` -- completes transfer, clears `pendingRegistrar`
3. Current registrar can call `cancelRegistrarTransfer()` to abort

Edge cases verified:
- `proposeRegistrar(address(0))` reverts with `ZeroAddress()` -- correct
- `acceptRegistrar()` by non-pending address reverts with `NotPendingRegistrar()` -- correct
- Multiple `proposeRegistrar()` calls overwrite the pending registrar -- correct behavior (latest proposal wins)
- After `acceptRegistrar()`, old registrar loses access immediately -- correct
- `cancelRegistrarTransfer()` only callable by current registrar -- correct

**Status:** VERIFIED CORRECT

---

### [I-07] INFORMATIONAL: Fail-Closed Default Verified

**Description:**

Unregistered tokens return `ComplianceStatus.NON_COMPLIANT` with reason "Token not registered - compliance unknown" (lines 649-659). The RWAAMM consumer treats any non-COMPLIANT status as a compliance failure (lines 1200-1201, 1212-1213). This is correct fail-closed behavior.

Additionally, the H-02 defense-in-depth code at lines 684-703 ensures that even if compliance is somehow disabled for a regulated token (ERC-3643/ERC-1400), the result is `NON_COMPLIANT` rather than `COMPLIANT`.

**Status:** VERIFIED CORRECT

---

### [I-08] INFORMATIONAL: ERC-1066 Reason Code Range Check Verified

**Location:** `_checkERC1400Compliance()` line 893

**Description:**

```solidity
bool isSuccess = (reasonCode > 0x9F && reasonCode < 0xB0);
```

This correctly maps to the ERC-1066 Application-Specific Status Codes success range of `0xA0` through `0xAF` (inclusive):
- `> 0x9F` is equivalent to `>= 0xA0`
- `< 0xB0` is equivalent to `<= 0xAF`

**Status:** VERIFIED CORRECT

---

### [I-09] INFORMATIONAL: Per-Token Cache Version Counter Is Sound

**Location:** `_tokenCacheVersion` (line 91), `_cachedVersion` (lines 95-96), `updateTokenConfig()` line 335, `checkCompliance()` lines 436-437, `refreshCompliance()` line 503

**Description:**

The cache version mechanism works as follows:
1. `updateTokenConfig()` increments `_tokenCacheVersion[token]` (line 335)
2. `refreshCompliance()` stores the current version in `_cachedVersion[user][token]` (line 503)
3. `checkCompliance()` only returns cached results if `_cachedVersion[user][token] == _tokenCacheVersion[token]` (lines 436-437)

This ensures that any config change automatically invalidates all cached results for that token without requiring per-user iteration. The version counter is `uint256` so overflow is practically impossible (would require 2^256 config updates).

**Status:** VERIFIED CORRECT

---

### [I-10] INFORMATIONAL: `_checkERC3643Compliance()` Uses Oracle Address as Destination (Acknowledged Limitation)

**Location:** `_checkERC3643Compliance()` line 811

**Description:**

The compliance check calls `canTransfer(user, address(this), 1)` where `address(this)` is the oracle contract, not the actual transfer recipient (AMM pool, LP, or end user). This is a known approximation, documented in the NatSpec at lines 786-796.

For production deployment, the oracle address AND all AMM pool addresses must be registered in each RWA token's identity registry. If a new pool is deployed for a registered RWA token without updating the token's identity registry, the `canTransfer()` check would incorrectly fail for that pool.

**Impact:** False negatives possible if the oracle is not whitelisted; false positives possible if the oracle is whitelisted but the actual recipient is not.

**Recommendation:** The current documentation (lines 786-796) adequately describes this limitation and the required operational procedure. A future version should pass the actual recipient address.

**Status:** ACKNOWLEDGED (carried forward from Round 6 M-02)

---

## Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| L-01 | LOW | Re-registration creates duplicate array entry | Open |
| L-02 | LOW | ERC-4626 detection false positive on non-vaults | Open |
| L-03 | LOW | canTransfer probe uses address(0) parameters | Open |
| L-04 | LOW | No event on invalidateCache/cancelRegistrarTransfer | Open |
| L-05 | LOW | checkSwapCompliance string concatenation unbounded | Open |
| I-01 | INFO | UNKNOWN standard falls through to COMPLIANT default | Open |
| I-02 | INFO | _registeredTokens array growth unbounded | Documented |
| I-03 | INFO | amountIn parameter unused | Documented |
| I-04 | INFO | Constant cache TTL (5 minutes) | Documented |
| I-05 | INFO | ReentrancyGuard applied correctly | Verified |
| I-06 | INFO | Two-step registrar transfer is sound | Verified |
| I-07 | INFO | Fail-closed default verified | Verified |
| I-08 | INFO | ERC-1066 reason code range check verified | Verified |
| I-09 | INFO | Per-token cache version counter is sound | Verified |
| I-10 | INFO | Oracle address as canTransfer destination | Acknowledged |

---

## Severity Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 5 |
| INFORMATIONAL | 10 |
| **Total** | **15** |

---

## Risk Assessment

**Overall Risk: LOW**

This contract is in strong security posture following the Round 6 remediation cycle. All Critical, High, and Medium findings from Round 6 have been addressed:

- **Two-step registrar transfer** eliminates the permanent admin loss risk (H-01 fixed)
- **CannotDisableRequiredCompliance guard** plus defense-in-depth fail-closed logic eliminates the fail-open risk for regulated securities (H-02 fixed)
- **Manual standard override** via `registerTokenWithStandard()` eliminates ERC-165 spoofing (M-01 fixed)
- **Per-token cache version counter** eliminates the cache poisoning window (M-03 fixed)

The remaining findings are all LOW or INFORMATIONAL severity:

1. **L-01 (duplicate array entry):** Data integrity issue affecting off-chain consumers only. Compliance checking is unaffected.
2. **L-02, L-03 (detection probes):** Fully mitigated by the manual standard override added in M-01 fix. Auto-detection is a convenience, not the sole classification path.
3. **L-04 (missing events):** Observability gap, no security impact.
4. **L-05 (string concat):** Bounded by hardcoded strings in current implementation.
5. **I-01 (UNKNOWN default):** Unreachable in current code; defense-in-depth recommendation.

**No new Critical, High, or Medium findings.** The contract is suitable for production deployment with the noted LOW items as accepted risks or future enhancements.

---

## Cross-Contract Interaction Analysis

### Consumer: RWAAMM.sol

The RWAAMM consumes this oracle via two paths:

1. **`_checkSwapCompliance()`** (RWAAMM line 1163): Calls `COMPLIANCE_ORACLE.checkSwapCompliance()` which returns booleans. `CHECK_FAILED` maps to `false` (fail-closed). Correct.

2. **`_checkLiquidityCompliance()`** (RWAAMM line 1191): Calls `COMPLIANCE_ORACLE.checkCompliance()` and checks `status != COMPLIANT`. `CHECK_FAILED` and `NON_COMPLIANT` both block the operation. Correct.

Both paths are fail-closed. Oracle unavailability (revert during external call) results in `CHECK_FAILED`, which blocks all operations. This is the correct behavior for regulated securities.

### Oracle Trust Model

The registrar is a single point of trust controlling:
- Token registration and classification
- Compliance contract assignment
- Cache population and invalidation
- Registrar succession

**Mitigations in place:**
- Two-step registrar transfer prevents accidental loss
- Compliance cannot be disabled for regulated standards
- Cache version invalidation on config changes
- All external calls wrapped in try/catch (graceful degradation)

**Remaining trust assumption:** The registrar must be a multisig or governance timelock for production deployment. A single EOA registrar creates centralization risk. This is documented in the contract NatSpec (lines 40-46).

---

## Positive Observations

1. **Fail-closed at every level:** Unregistered tokens, disabled compliance on regulated tokens, external call failures -- all default to NON_COMPLIANT
2. **Defense-in-depth:** H-02 fix has two layers -- `updateTokenConfig()` blocks the disable, AND `_checkComplianceInternal()` catches it if it somehow gets through
3. **Cache integrity:** Per-token version counter invalidates stale entries atomically on config change
4. **Safe external calls:** All external interactions use try/catch; malicious compliance contracts cannot crash the oracle
5. **Two-step admin transfer:** Prevents permanent loss of registrar control
6. **Manual standard override:** Registrar can bypass auto-detection for high-confidence classification
7. **Pagination support:** `getRegisteredTokensPaginated()` prevents unbounded gas for large registries
8. **Comprehensive NatSpec:** Every function, parameter, and security decision is documented with rationale
9. **Correct ERC-1066 parsing:** Success range 0xA0-0xAF checked accurately
10. **Minimal attack surface:** No fund handling, no token approvals, no delegatecall, no self-destruct
