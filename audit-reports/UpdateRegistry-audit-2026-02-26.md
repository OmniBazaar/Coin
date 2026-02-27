# Security Audit Report: UpdateRegistry

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (Comprehensive 6-Pass)
**Contract:** `Coin/contracts/UpdateRegistry.sol`
**Solidity Version:** 0.8.24
**OpenZeppelin Version:** 5.4.0
**Lines of Code:** 878
**Upgradeable:** No
**Handles Funds:** No (registry only -- no token transfers)
**Tests:** 58 passing (100% pass rate)
**Prior Audit:** 2026-02-21 (first audit, found H-01, M-01 through M-04, L-01 through L-04, I-01, I-02)

---

## Executive Summary

UpdateRegistry is an ODDAO multi-sig software release registry deployed on OmniCoin L1 (chain 131313). It stores release manifests with M-of-N ECDSA signature verification, enforces minimum version requirements for software components, and supports signer set rotation with elevated thresholds.

This is a re-audit following the initial 2026-02-21 review. The contract has been substantially hardened since the first audit. All previous high and medium findings have been remediated:

- **H-01 (abi.encodePacked collision):** FIXED -- now uses `abi.encode` throughout
- **M-01 (nonce-less signatures):** FIXED -- `operationNonce` added to all signed messages
- **M-02 (latestVersion regression):** FIXED -- `latestReleaseIndex` prevents regression
- **M-03 (missing action prefix):** FIXED -- `"PUBLISH_RELEASE"` prefix added
- **M-04 (no timelock):** ACCEPTED RISK -- see Informational notes

The contract is well-structured with proper domain separation (chain ID + contract address + action prefix + nonce), bitmap-based duplicate signature detection, comprehensive input validation, and elevated thresholds for signer rotation. No critical or high severity issues remain.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 5 |
| Informational | 5 |

---

## Findings

### [M-01] Minimum Version Can Be Downgraded via `setMinimumVersion` or `publishRelease`

**Severity:** Medium
**Lines:** 326-329 (`publishRelease`), 397-429 (`setMinimumVersion`)

**Description:**

Neither `publishRelease` nor `setMinimumVersion` enforces that the new minimum version is greater than or equal to the current minimum version. Although both operations require ODDAO multi-sig approval, a compromised or coerced set of signers could lower the minimum version to re-enable nodes running vulnerable software.

In `publishRelease` (line 327-329):
```solidity
if (bytes(minVersion).length > 0) {
    minimumVersion[componentHash] = minVersion;
}
```

In `setMinimumVersion` (line 425-426):
```solidity
minimumVersion[componentHash] = version;
```

Neither performs a semantic version comparison. If the current minimum is "2.0.0", a release published with `minVersion="1.0.0"` or a `setMinimumVersion("1.0.0")` call will silently downgrade the minimum.

**Impact:** A compromised admin + threshold signers can lower minimum version requirements, allowing nodes running known-vulnerable software to continue operating. This is mitigated by the multi-sig requirement but remains the most significant remaining attack surface.

**Recommendation:**

Store the minimum version as a monotonically increasing counter or require on-chain semantic version comparison. At minimum, emit a distinct event when the minimum version decreases so off-chain monitoring can detect it:

```solidity
string memory currentMin = minimumVersion[componentHash];
minimumVersion[componentHash] = version;
if (bytes(currentMin).length > 0) {
    emit MinimumVersionChanged(component, currentMin, version);
}
```

---

### [L-01] Revoked `latestVersion` Not Updated

**Severity:** Low
**Lines:** 345-385 (`revokeRelease`), 509-517 (`getLatestRelease`)

**Description:**

When a release is revoked via `revokeRelease`, the `latestVersion` mapping is not updated. If the revoked version is the current latest, `getLatestVersion()` returns the revoked version string, and `getLatestRelease()` returns a `ReleaseInfo` struct with `revoked = true`.

Validators that only call `getLatestVersion()` without also calling `isVersionRevoked()` or `verifyRelease()` will not discover that the latest version has been revoked. While `getLatestRelease()` does include the `revoked` field, the string-only `getLatestVersion()` provides no revocation signal.

**Impact:** Validators using the simpler `getLatestVersion()` accessor may not detect that the latest release has been revoked, potentially continuing to run or download compromised software.

**Recommendation:**

On revocation of the version that matches `latestVersion[componentHash]`, walk `versionHistory` backwards to find the most recent non-revoked version and update `latestVersion`. Alternatively, add a dedicated `getLatestNonRevokedVersion()` view function.

---

### [L-02] Unbounded Component String Length

**Severity:** Low
**Lines:** 284, 352, 403

**Description:**

`_validateReleaseInputs` validates maximum lengths for `version` (32), `minVersion` (32), `changelogCID` (128), and `revokeRelease` validates `reason` (256), but no maximum length is enforced for the `component` parameter in any function.

A RELEASE_MANAGER could submit a release with an arbitrarily long component string (e.g., 10KB), consuming excessive gas and calldata storage. While the string is stored in the `ReleaseInfo` struct (as `version`, not `component` -- the component is only used as a hash key and in events), indexed event parameters for long strings produce large log entries.

**Impact:** Minor gas griefing and storage waste. The practical impact is low because the caller must have RELEASE_MANAGER_ROLE and valid ODDAO signatures.

**Recommendation:**

Add a `MAX_COMPONENT_LENGTH` constant (e.g., 64 bytes) and validate in `_validateReleaseInputs`:

```solidity
uint256 public constant MAX_COMPONENT_LENGTH = 64;

// In _validateReleaseInputs and other functions:
if (bytes(component).length > MAX_COMPONENT_LENGTH) {
    revert StringTooLong(bytes(component).length, MAX_COMPONENT_LENGTH);
}
```

---

### [L-03] Duplicate Signature Silently Skipped Instead of Reverting

**Severity:** Low
**Lines:** 795-798

**Description:**

In `_verifyMessageSignaturesWithThreshold`, when a signer's signature appears more than once, the duplicate is silently skipped via `continue` (line 797):

```solidity
if ((seenBitmap & bit) != 0) continue;
```

In contrast, a signature from a non-signer causes an immediate revert (line 789). This asymmetric behavior means that bugs in off-chain signing tooling that produce duplicate signatures go undetected as long as enough unique valid signatures remain. A signing ceremony could erroneously include the same key's signature multiple times, masking a coordination failure.

**Impact:** Off-chain signing bugs may go undetected, giving false confidence in the signing ceremony's correctness.

**Recommendation:**

Either revert on duplicate signatures for strict behavior, or document the lenient behavior explicitly in NatSpec. Strict mode is preferred for a security-critical registry:

```solidity
if ((seenBitmap & bit) != 0) revert DuplicateSignature(recovered);
```

---

### [L-04] `delete signers` Does Not Zero Array Length in All EVM Contexts

**Severity:** Low
**Lines:** 488

**Description:**

The `updateSignerSet` function uses `delete signers` to clear the dynamic array before populating it with new signers. While `delete` on a dynamic storage array does reset the length to zero in standard Solidity semantics, the prior loop (lines 485-487) has already iterated through the full array to clear `isSigner` mappings, so the gas cost of `delete` includes zeroing all slots.

For a maximum of 20 signers (`MAX_SIGNERS`), this is bounded and acceptable. However, if `MAX_SIGNERS` were ever increased significantly, the gas cost of the `delete` plus the O(n) duplicate-check in `_validateSignerSet` (O(n^2)) could become problematic.

**Impact:** Bounded by `MAX_SIGNERS = 20`. No current risk, but the O(n^2) pattern in `_validateSignerSet` means gas cost grows quadratically with signer count.

**Recommendation:**

No immediate change needed given `MAX_SIGNERS = 20`. Document the quadratic gas behavior in NatSpec for future maintainers.

---

### [L-05] `getReleaseByIndex` Underflow-Safe but Semantically Confusing Guard

**Severity:** Low
**Lines:** 617

**Description:**

```solidity
if (releaseCount[componentHash] == 0 || index > releaseCount[componentHash] - 1) {
```

This check is correct and avoids underflow (the `== 0` short-circuit prevents the subtraction), but `index > releaseCount[componentHash] - 1` is equivalent to `index >= releaseCount[componentHash]`. The current form obscures the intent.

**Impact:** No functional issue. Readability concern only.

**Recommendation:**

Simplify to the more idiomatic:
```solidity
if (index >= releaseCount[componentHash]) {
    revert VersionNotFound(component, "index out of range");
}
```

---

### [I-01] No Timelock on Administrative Operations

**Severity:** Informational
**Lines:** 397-429 (`setMinimumVersion`), 446-498 (`updateSignerSet`)

**Description:**

All operations execute immediately upon submission. If an admin key and sufficient signer keys are compromised simultaneously, an attacker could execute a complete takeover in a single block: rotate signers, publish a malicious release, and set a minimum version forcing nodes to update -- all with no detection window.

The `updateSignerSet` function does require `threshold + 1` signatures (elevated from the normal threshold), which provides some additional security. However, `grantRole(RELEASE_MANAGER_ROLE, ...)` only requires `DEFAULT_ADMIN_ROLE` with no ODDAO signer involvement.

This was identified as M-04 in the prior audit. Given that the contract now has nonce protection preventing replay, and the elevated threshold for signer rotation, the risk is reduced but not eliminated.

**Impact:** Zero detection window for the community in a full key compromise scenario.

**Recommendation:**

Consider wrapping `updateSignerSet` and `setMinimumVersion` with a timelock (24-48h delay). OmniTimelockController is already deployed in the OmniBazaar ecosystem and could serve this purpose. Alternatively, add an off-chain monitoring alert for `SignerSetUpdated` and `MinimumVersionUpdated` events.

---

### [I-02] `grantRole(RELEASE_MANAGER_ROLE)` Does Not Require Multi-Sig

**Severity:** Informational
**Lines:** 236-237

**Description:**

The constructor grants both `DEFAULT_ADMIN_ROLE` and `RELEASE_MANAGER_ROLE` to the deployer. Through OpenZeppelin's `AccessControl`, any address with `DEFAULT_ADMIN_ROLE` can grant `RELEASE_MANAGER_ROLE` to arbitrary addresses using `grantRole()` without any ODDAO signer involvement.

While a RELEASE_MANAGER cannot publish releases without valid ODDAO signatures, they can submit transactions that consume the `operationNonce`, potentially causing a denial-of-service if they submit a transaction with valid but stale parameters before the legitimate submission. More importantly, the ability to add managers without multi-sig approval is architecturally inconsistent with the otherwise strict multi-sig governance model.

**Impact:** A compromised admin can add RELEASE_MANAGERS unilaterally, though those managers still need ODDAO signatures to publish releases.

**Recommendation:**

Consider overriding `grantRole` to require ODDAO signatures for `RELEASE_MANAGER_ROLE` grants, or document this as an accepted administrative privilege.

---

### [I-03] Indexed String Event Parameters Produce Hashes, Not Readable Values

**Severity:** Informational
**Lines:** 138, 151, 162

**Description:**

Events `ReleasePublished`, `ReleaseRevoked`, and `MinimumVersionUpdated` use `string indexed component`. When a string parameter is `indexed` in a Solidity event, only its `keccak256` hash is stored in the topic -- not the readable string. Off-chain consumers filtering by component name must compute the hash themselves.

This is standard Solidity behavior, but in combination with non-indexed `string version` fields in the same events, the inconsistency may confuse developers building monitoring tools. The component string IS also hashed for the topic (correct), but the actual string value is NOT available in the indexed topic -- it must be read from the non-indexed event data or be known a priori.

**Impact:** Developer ergonomics. No security impact.

**Recommendation:**

This is a conscious trade-off (indexing enables efficient topic filtering). Document in NatSpec that the `component` topic contains `keccak256(bytes(component))`, not the raw string. Alternatively, add a `bytes32 indexed componentHash` parameter alongside the string for explicit clarity.

---

### [I-04] `block.timestamp` Usage in `publishedAt` (Acknowledged)

**Severity:** Informational
**Lines:** 302

**Description:**

`publishedAt = block.timestamp` is set by the block producer and can be manipulated within typical bounds (a few seconds). This is used purely for informational purposes and is not involved in any security-critical logic. The developer has acknowledged this with a `solhint-disable-line not-rely-on-time` comment.

**Impact:** No security impact. Informational only.

**Recommendation:** No change needed. Accepted risk.

---

### [I-05] Component String Stored Redundantly in `ReleaseInfo`

**Severity:** Informational
**Lines:** 301-310

**Description:**

The `ReleaseInfo` struct stores the `version` string but not the `component` string. The component is stored implicitly as the mapping key (`keccak256(bytes(component))`). If a consumer needs the original component string, they must obtain it from event logs or off-chain records, not from the struct.

Conversely, the `version` string IS stored in the struct even though it's also a mapping key. This is useful but creates a minor inconsistency: one mapping key is reconstructable from on-chain data, the other is not.

**Impact:** No security impact. Minor API ergonomics consideration.

**Recommendation:** No change needed. The current design correctly avoids storing the component string redundantly in every release struct (saving gas). The component name is available in the event logs.

---

## Remediation Status of Prior Audit (2026-02-21)

| Finding | Severity | Status | Notes |
|---------|----------|--------|-------|
| H-01: `abi.encodePacked` collision | High | FIXED | All message hashes now use `abi.encode` |
| M-01: Nonce-less signatures | Medium | FIXED | `operationNonce` added to all signed messages, incremented after each operation |
| M-02: `latestVersion` regression | Medium | FIXED | `latestReleaseIndex` prevents out-of-order updates (line 321-324) |
| M-03: Missing action prefix | Medium | FIXED | `"PUBLISH_RELEASE"` prefix added (line 735) |
| M-04: No timelock | Medium | ACCEPTED | Documented as I-01 in this audit; risk reduced by nonce + elevated threshold |
| L-01: Operator precedence | Low | FIXED | Explicit parentheses added: `(seenBitmap & bit) != 0` |
| L-02: Unbounded component length | Low | OPEN | Carried forward as L-02 |
| L-03: Revoked latestVersion | Low | OPEN | Carried forward as L-01 |
| L-04: Duplicate signature skip | Low | OPEN | Carried forward as L-03 |
| I-01: No granular signer removal | Info | ACCEPTED | Operational trade-off |
| I-02: `block.timestamp` usage | Info | ACCEPTED | Informational only |

---

## Architecture Review

### Strengths

1. **Robust domain separation:** All signed messages include chain ID, contract address, action prefix (`"PUBLISH_RELEASE"`, `"REVOKE"`, `"MIN_VERSION"`, `"UPDATE_SIGNERS"`), and the operation nonce. This prevents cross-chain, cross-contract, cross-action, and replay attacks.

2. **Correct use of `abi.encode`:** All message hash constructions use `abi.encode`, which ABI-encodes dynamic types with length prefixes, making hash collisions between different parameter combinations impossible.

3. **Bitmap-based duplicate detection:** The `seenBitmap` approach in `_verifyMessageSignaturesWithThreshold` is gas-efficient (single storage read per signer index lookup, bit operations in memory) and supports up to 256 signers -- well above the `MAX_SIGNERS = 20` limit.

4. **Elevated threshold for signer rotation:** `updateSignerSet` requires `threshold + 1` signatures (or all signers if `signerCount == threshold`), providing a higher security bar for the most sensitive operation.

5. **Nonce-based replay protection:** The `operationNonce` is incremented after every state-changing operation (publish, revoke, setMinimumVersion, updateSignerSet), ensuring each set of ODDAO signatures can only be used exactly once.

6. **Monotonic latest version tracking:** `latestReleaseIndex` prevents out-of-order publishing from regressing `latestVersion`, correctly handling patch releases for older branches.

7. **Comprehensive input validation:** Empty strings, zero hashes, zero addresses, duplicate signers, invalid thresholds, and excessive string lengths are all validated with descriptive custom errors.

8. **Proper OpenZeppelin usage:** Uses OZ 5.4.0's `AccessControl`, `ECDSA`, and `MessageHashUtils` correctly. The `recover` function in OZ 5.x reverts on invalid signatures (no silent address(0) return), and enforces low-S values.

### Areas for Improvement

1. **No on-chain semantic version comparison:** The contract stores versions as opaque strings. It cannot enforce that minimum versions only increase or that latest versions follow semantic versioning. This is a deliberate simplicity trade-off but limits on-chain safety guarantees.

2. **No expiry on signed messages:** Signatures have no timestamp-based expiry. A valid set of ODDAO signatures for nonce N must be used before any other operation increments the nonce, but there is no time-based deadline. If signers produce signatures for nonce N and the admin delays submission, the signatures remain valid indefinitely until nonce N is consumed. This is mitigated by the nonce system (signatures become invalid once any operation increments the nonce past N).

3. **No emergency pause:** The contract has no `Pausable` mechanism. If a vulnerability is discovered, the only recourse is to stop interacting with the contract; there is no way to freeze operations on-chain.

---

## Gas Analysis

| Function | Estimated Gas (first call) | Notes |
|----------|---------------------------|-------|
| `publishRelease` (2 sigs) | ~180,000 | Storage-heavy: writes ReleaseInfo struct + mappings |
| `revokeRelease` (2 sigs) | ~55,000 | Storage update: sets bool + string |
| `setMinimumVersion` (2 sigs) | ~50,000 | Storage update: sets string mapping |
| `updateSignerSet` (3 sigs, 3->2) | ~95,000 | Clears old array + mappings, sets new |
| `getLatestRelease` | ~8,000 | Two mapping reads + struct copy |
| `verifyRelease` | ~5,000 | Two mapping reads + bool check |

All gas costs are within reasonable bounds for the operations performed. The O(n^2) duplicate check in `_validateSignerSet` and O(n) signer index lookup in `_getSignerIndex` are bounded by `MAX_SIGNERS = 20`, keeping worst-case gas predictable.

---

## Test Coverage Assessment

The existing test suite (58 tests, all passing) provides good coverage:

- Deployment and initial state validation
- Release publishing with valid signatures and event emission
- Release info storage and retrieval
- Latest version tracking across multiple releases
- Minimum version setting (with and without value)
- Release count incrementing
- Operation nonce incrementing across all operations
- Duplicate version rejection
- Input validation (empty version, empty hash, empty component)
- Insufficient signature rejection
- Non-signer signature rejection
- Stale nonce (replay) rejection
- Access control enforcement (non-manager, non-admin)
- Multi-component isolation
- Release revocation (success, non-existent, double revocation)
- Signer set rotation with elevated threshold
- Old signer mapping cleanup
- View function correctness (getRelease, getReleaseByIndex, verifyRelease, etc.)
- Duplicate signature deduplication (bitmap)

**Test gaps identified:**

1. No test for `latestReleaseIndex` regression prevention (publishing older version after newer)
2. No test for minimum version downgrade scenario
3. No test for maximum string length enforcement (`MAX_VERSION_LENGTH`, `MAX_CID_LENGTH`, `MAX_REASON_LENGTH`)
4. No test for `MAX_SIGNERS` boundary (20 signers)
5. No test for `computeReleaseHash` / `computeSignerUpdateHash` matching actual signature verification
6. No test for granting RELEASE_MANAGER_ROLE to additional addresses
7. No test for revoking admin/manager roles

---

## Static Analysis Results

**Solhint:** Clean -- no errors or warnings (only benign rule-not-found warnings for deprecated rule names)

**Compiler:** Clean -- compiles without warnings under solc 0.8.24 with optimizer enabled (200 runs, viaIR)

**Contract Size:** 11.222 KiB deployed (within 24.576 KiB limit)

---

## Methodology

- **Pass 1:** Source code review and architecture analysis
- **Pass 2:** Prior audit remediation verification (H-01, M-01 through M-04, L-01 through L-04)
- **Pass 3:** OWASP Smart Contract Top 10 analysis (access control, injection, logic errors, DoS, reentrancy, oracle manipulation, signature verification, flash loan, integer overflow, unchecked returns)
- **Pass 4:** Privilege escalation and multi-sig bypass analysis
- **Pass 5:** Static analysis (solhint, compiler warnings)
- **Pass 6:** Test coverage analysis and gap identification

---

## Conclusion

UpdateRegistry has been substantially hardened since the 2026-02-21 audit. All high and medium findings from the prior audit have been fixed. The contract now uses `abi.encode` for collision-resistant hashing, includes nonce-based replay protection, has action prefixes for domain separation, and prevents `latestVersion` regression through index tracking.

The remaining Medium finding (M-01, minimum version downgrade) is mitigated by the multi-sig requirement but represents a meaningful attack surface if signer keys are compromised. The Low findings are minor improvements to defensive coding and developer ergonomics. The Informational findings document architectural trade-offs that are reasonable for the contract's intended use case.

**Overall Assessment:** The contract is suitable for production deployment on OmniCoin L1. The M-01 finding (minimum version downgrade) should be addressed before or shortly after deployment through either on-chain enforcement or robust off-chain monitoring of `MinimumVersionUpdated` events.

**Risk Rating:** LOW (post-remediation). The previous audit rating was MEDIUM-HIGH due to H-01.
