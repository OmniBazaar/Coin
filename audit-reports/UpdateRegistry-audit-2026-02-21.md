# Security Audit Report: UpdateRegistry

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/UpdateRegistry.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 778
**Upgradeable:** No
**Handles Funds:** No (registry only — no token transfers)

## Executive Summary

UpdateRegistry is an ODDAO multi-sig software release registry deployed on OmniCoin L1 (chain 131313). It stores release manifests with M-of-N ECDSA signature verification, enforces minimum version requirements, and supports signer set rotation. The contract is well-structured with proper domain separation (chain ID + contract address), action prefixes for most operations, bitmap-based duplicate signature detection, and comprehensive input validation.

However, the audit found a **High-severity `abi.encodePacked` hash collision** vulnerability that could allow a RELEASE_MANAGER to reuse ODDAO signatures across different (component, version) pairs — bypassing the core multi-sig protection. Additionally, **nonce-less signatures** enable replay of previously authorized operations, and the `latestVersion` pointer can be inadvertently overwritten by out-of-order publishing. Both agents independently confirmed the `abi.encodePacked` collision as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 4 |
| Low | 4 |
| Informational | 2 |

## Findings

### [H-01] `abi.encodePacked` Hash Collision on Variable-Length Strings

**Severity:** High
**Lines:** 643, 339, 372, 596
**Agents:** 2A, 2C (confirmed independently)

**Description:**

Multiple functions construct message hashes using `abi.encodePacked` with adjacent variable-length string arguments. `abi.encodePacked` concatenates dynamic types without length prefixes, so different input combinations produce identical packed bytes.

At line 643 (`_verifySignatures`):
```solidity
bytes32 messageHash = keccak256(
    abi.encodePacked(component, version, binaryHash, minVersion, block.chainid, address(this))
);
```

`component` and `version` are adjacent strings:
- `component="ab"`, `version="cd"` → packed: `0x61626364...`
- `component="abc"`, `version="d"` → packed: `0x61626364...`

These produce identical hashes. A signature for release `("ab", "cd", hash, ...)` is also valid for `("abc", "d", hash, ...)`.

The same pattern exists in:
- `revokeRelease` (line 339): `abi.encodePacked("REVOKE", component, version, reason, ...)`
- `setMinimumVersion` (line 372): `abi.encodePacked("MIN_VERSION", component, version, ...)`
- `computeReleaseHash` (line 596): same hash used by off-chain signing tools

**Key attack vector:** A RELEASE_MANAGER could request ODDAO signatures for an innocuous-looking component/version pair, then reuse those signatures to publish a release under a different component/version pair that shares the same packed encoding. This bypasses multi-sig protection — the core security mechanism of the contract. Since validators auto-check this registry for updates, they could be directed to install a compromised binary.

**Impact:** Complete bypass of multi-sig verification for release publication. No key compromise needed — only social engineering of the signing ceremony.

**Recommendation:**

Replace `abi.encodePacked` with `abi.encode` in all message hash constructions:
```solidity
bytes32 messageHash = keccak256(
    abi.encode(component, version, binaryHash, minVersion, block.chainid, address(this))
);
```
`abi.encode` uses ABI standard encoding with length prefixes for dynamic types, making collisions impossible. Apply to all 4 affected locations plus both `compute*Hash` view helpers.

---

### [M-01] Nonce-less Signatures Enable Replay Within Same Contract

**Severity:** Medium
**Lines:** 339, 372, 414
**Agents:** 2A, 2C

**Description:**

No signed message includes a nonce or expiry. Chain ID and contract address prevent cross-chain/cross-contract replay, but same-contract replay is possible.

**Concrete attack — minimum version downgrade:**
1. Signers approve `setMinimumVersion("validator", "2.0.0")` — signatures produced
2. Admin submits, succeeds. Min version = "2.0.0"
3. Later, min version is advanced to "3.0.0"
4. Original "2.0.0" signatures are still valid
5. A compromised admin replays them to downgrade min version back to "2.0.0"

For `updateSignerSet`, if a rotation is approved but operationally cancelled, those signatures remain valid forever and can be submitted at any later time.

**Impact:** Minimum version downgrade attacks and stale signer rotations can be executed without re-obtaining signer approval.

**Recommendation:**

Add a monotonically increasing operation nonce:
```solidity
uint256 public operationNonce;
// In each signed message: abi.encode(..., operationNonce, ...)
// After successful execution: ++operationNonce;
```

---

### [M-02] `latestVersion` Unconditionally Overwritten — Out-of-Order Publishing

**Severity:** Medium
**Lines:** 292, 295-297
**Agents:** 2A, 2C

**Description:**

`publishRelease` unconditionally sets `latestVersion[componentHash] = version` (line 292) with no semantic version comparison. Publishing "1.9.1" (patch for old branch) after "2.0.0" sets latestVersion to "1.9.1".

Similarly, `minimumVersion` (line 295-297) is overwritten if `minVersion` is non-empty, regardless of whether it is lower than the current minimum. Publishing a release with `minVersion="0.1.0"` lowers the minimum below a previously set "1.0.0".

**Impact:** Validators polling `getLatestVersion()` receive stale version info, potentially triggering downgrades. Combined with a compromised admin, minimum version can be lowered to re-enable vulnerable node software.

**Recommendation:**

Add a monotonically increasing `versionSequence` counter per component. Only update `latestVersion` if the new sequence is highest. Enforce that `minimumVersion` can never decrease.

---

### [M-03] Missing Action Prefix on Release Signature

**Severity:** Medium
**Lines:** 642-643
**Agents:** 2C

**Description:**

The release publication signature has no action prefix:
- **Publish:** `keccak256(component, version, binaryHash, minVersion, chainid, addr)` — no prefix
- **Revoke:** `keccak256("REVOKE", component, version, reason, chainid, addr)`
- **Min version:** `keccak256("MIN_VERSION", component, version, chainid, addr)`
- **Update signers:** `keccak256("UPDATE_SIGNERS", ..., chainid, addr)`

Without a prefix, the publish hash begins directly with the `component` string. A release for `component="REVOKE"` produces packed bytes that overlap with a revocation message, creating theoretical cross-action signature confusion (though the fixed-width `binaryHash` in the publish path makes a full collision difficult).

**Impact:** Architectural weakness in domain separation. Combined with the `abi.encodePacked` collision (H-01), the risk increases.

**Recommendation:**

Add `"PUBLISH_RELEASE"` prefix:
```solidity
bytes32 messageHash = keccak256(
    abi.encode("PUBLISH_RELEASE", component, version, binaryHash, minVersion, block.chainid, address(this))
);
```

---

### [M-04] No Timelock on Administrative Operations

**Severity:** Medium
**Lines:** 395-438, 357-380
**Agents:** 2C

**Description:**

All operations execute immediately: role grants (inherited AccessControl), signer rotation, minimum version changes, and release publication. If admin + threshold signer keys are compromised, a complete attack chain (rotate signers → publish malicious release → set minimum version) can execute in a single block with no detection window.

Critically, `grantRole(RELEASE_MANAGER_ROLE, ...)` requires only admin — no ODDAO signer involvement.

**Impact:** No defense-in-depth against key compromise. Zero detection window for the community.

**Recommendation:**

Implement a timelock (24-48h delay) for signer rotation and minimum version changes. Consider requiring multi-sig for role grants.

---

### [L-01] Operator Precedence in Bitmap Check (Readability)

**Severity:** Low
**Lines:** 697

**Description:**

```solidity
if (seenBitmap & bit != 0) continue;
```

In Solidity, `&` has higher precedence than `!=`, so this is parsed correctly as `(seenBitmap & bit) != 0`. However, in C/C++/JavaScript, `!=` has higher precedence than `&`, which would cause a bug. The lack of explicit parentheses is a readability and maintenance hazard.

**Recommendation:** Add explicit parentheses: `if ((seenBitmap & bit) != 0) continue;`

---

### [L-02] Unbounded Component String Length

**Severity:** Low
**Lines:** 740

**Description:**

`_validateReleaseInputs` checks max length for `version`, `minVersion`, and `changelogCID`, but NOT for `component`. A RELEASE_MANAGER could submit a release with an arbitrarily long component string, consuming excessive gas and storage.

**Recommendation:** Add `MAX_COMPONENT_LENGTH = 64` and validate.

---

### [L-03] Revoked `latestVersion` Not Updated

**Severity:** Low
**Lines:** 343-344

**Description:**

When a release is revoked, `latestVersion` is not updated. If the revoked version is the latest, `getLatestVersion()` returns the revoked version with no indication. Nodes using the string-only accessor must make a separate `isVersionRevoked()` call.

**Recommendation:** On revocation of the latest version, walk `versionHistory` backwards to find the most recent non-revoked version and update `latestVersion`.

---

### [L-04] Duplicate Signature Silently Skipped

**Severity:** Low
**Lines:** 697

**Description:**

Duplicate signer signatures are silently `continue`d, while non-signer signatures cause an immediate `revert InvalidSignature`. This asymmetry means bugs in off-chain signing tooling (producing duplicates) go undetected if enough unique signatures remain.

**Recommendation:** Either revert on duplicates for consistency (`revert DuplicateSignature(recovered)`) or document the lenient behavior in NatSpec.

---

### [I-01] No Granular Signer Removal

**Severity:** Informational
**Lines:** 395-438

**Description:**

Individual compromised signers cannot be removed without replacing the entire signer set via `updateSignerSet`. This requires coordinating `threshold + 1` signatures for the new set, which is operationally burdensome during an active compromise.

**Recommendation:** Consider adding `removeSigner(address, bytes[])` for faster incident response.

---

### [I-02] `block.timestamp` Usage in `publishedAt`

**Severity:** Informational
**Lines:** 281

**Description:**

`publishedAt = block.timestamp` is set by the block producer. Minimal impact since it's informational only and not used in security-critical logic. The `solhint-disable-line` comment shows the developer has considered this.

**Recommendation:** No change needed. Accepted risk.

---

## Static Analysis Results

**Solhint:** Clean (no errors reported for OZ 5.x patterns)

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2C: Access Control & Privilege Escalation (agent)
- Pass 5: Triage & deduplication (manual)
- Pass 6: Report generation

## Conclusion

UpdateRegistry is a well-designed multi-sig registry with proper ECDSA verification, bitmap-based duplicate detection, and elevated thresholds for signer rotation. The **`abi.encodePacked` collision (H-01)** is the critical fix — switching to `abi.encode` eliminates the entire class of cross-parameter hash collisions and should be done before deployment. The **nonce-less signatures (M-01)** and **missing action prefix (M-03)** should be addressed simultaneously since they all involve the same hash construction code. The **latestVersion ordering (M-02)** and **timelock (M-04)** are important for operational safety but do not enable direct attacks without additional key compromise.
