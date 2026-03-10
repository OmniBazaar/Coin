# Security Audit Report: UpdateRegistry.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/UpdateRegistry.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 878
**Upgradeable:** No (standard deployment)
**Handles Funds:** No (registry only -- no token transfers)
**Tests:** 58 passing (100% pass rate) in `Coin/test/UpdateRegistry.test.js`
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)

---

## Executive Summary

UpdateRegistry is an on-chain ODDAO-approved software release registry deployed on OmniCoin L1 (chain 88008). It stores release manifests for OmniBazaar software components (validator, service-node, wallet-extension, mobile-app, webapp) with M-of-N ECDSA multi-sig signature verification from ODDAO members. The contract enforces minimum version requirements, supports release revocation, and provides signer set rotation with elevated thresholds.

**Round 6 Assessment:** The contract has been thoroughly hardened since Round 1. All Critical and High-severity findings have been fully remediated:

- **R1 H-01 (abi.encodePacked collision):** FIXED -- All message hashes use `abi.encode` throughout.
- **R1 M-01 (Nonce-less signatures):** FIXED -- `operationNonce` added to all signed messages, incremented after each operation.
- **R1 M-02 (latestVersion regression):** FIXED -- `latestReleaseIndex` prevents out-of-order overwrites.
- **R1 M-03 (Missing action prefix):** FIXED -- `"PUBLISH_RELEASE"` prefix on release signatures.
- **R1 M-04 (No timelock):** ACCEPTED -- Mitigated by nonce protection + elevated threshold for signer rotation.
- **R3 M-01 (Minimum version downgrade):** OPEN -- Carried forward. See M-01 below.

**This Round 6 audit finds zero Critical, zero High, one Medium, two Low, and four Informational findings.** The contract is architecturally sound with robust domain separation, proper OpenZeppelin usage, and comprehensive input validation.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 4 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Minimum version can be downgraded -- no monotonic enforcement | **FIXED** |

---

## Remediation Status from All Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| R1 H-01: `abi.encodePacked` hash collision | High | **FIXED** | All message hashes use `abi.encode` (lines 734, 371, 416, 467, 658, 688). |
| R1 M-01: Nonce-less signatures | Medium | **FIXED** | `operationNonce` added to all signed messages (lines 117-118). Incremented at lines 298, 379, 422, 482. Verified at lines 730, 357, 408, 454. |
| R1 M-02: latestVersion regression | Medium | **FIXED** | `latestReleaseIndex` (line 124) tracks highest-indexed release. `latestVersion` only updated when `idx >= latestReleaseIndex[componentHash]` (line 321). |
| R1 M-03: Missing action prefix on publish | Medium | **FIXED** | `"PUBLISH_RELEASE"` prefix added (line 735). Revoke uses `"REVOKE"` (line 373), min version uses `"MIN_VERSION"` (line 417), signer update uses `"UPDATE_SIGNERS"` (line 469). |
| R1 M-04: No timelock on admin operations | Medium | **ACCEPTED** | Nonce protection prevents stale replays. Elevated threshold (threshold+1) on signer rotation provides defense-in-depth. No on-chain timelock. See I-01. |
| R1 L-01: Operator precedence in bitmap check | Low | **FIXED** | Explicit parentheses: `(seenBitmap & bit) != 0` (line 797). |
| R1 L-02 / R3 L-02: Unbounded component string length | Low | **OPEN** | Carried forward as L-01 below. |
| R1 L-03 / R3 L-01: Revoked latestVersion not updated | Low | **OPEN** | Carried forward as L-02 below. |
| R1 L-04 / R3 L-03: Duplicate signature silently skipped | Low | **ACCEPTED** | Documented behavior. Bitmap skip is gas-efficient and harmless. |
| R1 I-01: No granular signer removal | Info | **ACCEPTED** | Operational trade-off. Full set rotation is simpler and avoids partial-state bugs. |
| R1 I-02 / R3 I-04: block.timestamp usage | Info | **ACCEPTED** | Informational only. `publishedAt` is not security-critical. |
| R3 L-04: delete signers gas concern | Low | **ACCEPTED** | Bounded by `MAX_SIGNERS = 20`. O(n^2) is acceptable for n <= 20. |
| R3 L-05: getReleaseByIndex semantically confusing guard | Low | **ACCEPTED** | Functionally correct. Readability concern only. |
| R3 I-02: grantRole no multi-sig | Info | **ACCEPTED** | Manager can't publish without ODDAO signatures. Admin control is intentional. |
| R3 I-03: Indexed string event parameters | Info | **ACCEPTED** | Standard Solidity trade-off. |
| R3 I-05: Component string not stored in struct | Info | **ACCEPTED** | Gas optimization. Component available in event logs. |

---

## Medium Findings

### [M-01] Minimum Version Can Be Downgraded -- No Monotonic Enforcement (Retained from R3 M-01)

**Severity:** Medium
**Category:** Business Logic / Safety Invariant
**Location:** `publishRelease()` (lines 326-329), `setMinimumVersion()` (lines 397-429)

**Description:**

Neither `publishRelease` nor `setMinimumVersion` enforces that the new minimum version is strictly greater than or equal to the current minimum version. Versions are stored as opaque strings with no on-chain semantic version comparison.

In `publishRelease` (lines 327-329):
```solidity
if (bytes(minVersion).length > 0) {
    minimumVersion[componentHash] = minVersion;
}
```

In `setMinimumVersion` (lines 425-426):
```solidity
minimumVersion[componentHash] = version;
```

A release published with `minVersion="1.0.0"` after a previous release set `minimumVersion` to `"2.0.0"` will silently downgrade the minimum to `"1.0.0"`. Similarly, `setMinimumVersion("1.0.0")` will override a current minimum of `"2.0.0"` without any guard.

Both operations require ODDAO multi-sig approval (M-of-N signatures), so exploitation requires compromising `signerThreshold` distinct signer keys. However, this is the same trust boundary that protects release publishing itself. If an attacker has enough signer keys to downgrade the minimum version, they can also publish a malicious release, making this finding compounding rather than independently exploitable.

The operational risk is also relevant: an ODDAO member who signs a release with `minVersion=""` (empty, meaning "don't update minimum") might inadvertently authorize a subsequent release with a lower `minVersion` if the signing tool does not highlight the downgrade.

**Impact:** A compromised or coerced set of ODDAO signers can lower the minimum version requirement, allowing nodes running known-vulnerable software to continue operating. This extends the exploitation window for any security vulnerability fixed in newer versions.

**Recommendation:**

Since on-chain semantic version comparison is complex and error-prone, the most practical approach is monotonic index tracking:

```solidity
/// @notice Monotonically increasing minimum version index per component
mapping(bytes32 => uint256) public minimumVersionIndex;

// In publishRelease, when setting minimumVersion:
if (bytes(minVersion).length > 0) {
    uint256 currentMinIdx = minimumVersionIndex[componentHash];
    // Only update if the new release has a higher index
    if (idx >= currentMinIdx) {
        minimumVersion[componentHash] = minVersion;
        minimumVersionIndex[componentHash] = idx;
    }
}
```

This ensures the minimum version can only be raised (newer releases), never lowered. For `setMinimumVersion()`, require that the specified version corresponds to a published release with an index higher than the current `minimumVersionIndex`.

Alternatively, if deliberate downgrades should be allowed as an emergency measure, emit a distinct `MinimumVersionDowngraded` event so off-chain monitoring can detect it:

```solidity
event MinimumVersionDowngraded(
    string indexed component,
    string previousVersion,
    string newVersion
);
```

---

## Low Findings

### [L-01] Unbounded Component String Length (Retained from R1 L-02)

**Severity:** Low
**Category:** Input Validation / Gas Griefing
**Location:** `publishRelease()` (line 284), `revokeRelease()` (line 352), `setMinimumVersion()` (line 403)

**Description:**

The `_validateReleaseInputs()` function validates maximum lengths for `version` (32), `minVersion` (32), `changelogCID` (128), and `revokeRelease` validates `reason` (256). However, no maximum length is enforced for the `component` parameter in any function.

While the `component` string is not stored in the `ReleaseInfo` struct (only its hash is used as a mapping key), it is:

1. Included in every signed message hash via `abi.encode` (consuming calldata gas proportional to length)
2. Emitted in events (`ReleasePublished`, `ReleaseRevoked`, `MinimumVersionUpdated`) as a `string indexed` parameter (consuming log gas)
3. Passed through `keccak256(bytes(component))` for hashing (consuming computation gas)

A RELEASE_MANAGER with valid ODDAO signatures could submit a release with an extremely long component string (limited only by block gas), consuming excessive gas and creating oversized event logs.

**Impact:** Minor gas griefing and storage waste. The practical impact is low because the caller must have `RELEASE_MANAGER_ROLE` and valid ODDAO signatures, making this a very expensive griefing vector for the attacker.

**Recommendation:**

Add a `MAX_COMPONENT_LENGTH` constant and validate:

```solidity
uint256 public constant MAX_COMPONENT_LENGTH = 64;

// In _validateReleaseInputs:
if (bytes(component).length > MAX_COMPONENT_LENGTH) {
    revert StringTooLong(bytes(component).length, MAX_COMPONENT_LENGTH);
}

// Also add to revokeRelease and setMinimumVersion:
if (bytes(component).length == 0) revert EmptyComponent();
if (bytes(component).length > MAX_COMPONENT_LENGTH) {
    revert StringTooLong(bytes(component).length, MAX_COMPONENT_LENGTH);
}
```

---

### [L-02] Revoked `latestVersion` Not Updated (Retained from R1 L-03)

**Severity:** Low
**Category:** Business Logic / API Design
**Location:** `revokeRelease()` (lines 345-385), `getLatestRelease()` (lines 509-517), `getLatestVersion()` (lines 554-559)

**Description:**

When a release is revoked via `revokeRelease()`, the `latestVersion` mapping is not updated. If the revoked version is the current latest, `getLatestVersion()` returns the revoked version string, and `getLatestRelease()` returns a `ReleaseInfo` struct with `revoked = true`.

Validators querying the registry have two code paths:
1. **`getLatestVersion()` (string-only):** Returns the version string with no revocation signal. A validator using only this accessor will not detect that the latest release has been revoked.
2. **`getLatestRelease()` (full struct):** Returns the complete `ReleaseInfo` including `revoked = true`. A validator checking this field will correctly detect the revocation.

The `verifyRelease()` function (line 630-638) correctly returns `false` for revoked versions, so validators using this function are safe.

The inconsistency between accessors creates a fragile dependency: validators MUST use either `getLatestRelease()` (and check `revoked`) or `verifyRelease()`, never `getLatestVersion()` alone. This is not enforced or clearly documented.

**Impact:** Validators using the simpler `getLatestVersion()` accessor may continue running or auto-updating to a revoked release.

**Recommendation:**

Option A (Preferred): On revocation of the version matching `latestVersion[componentHash]`, walk `versionHistory` backwards to find the most recent non-revoked version:

```solidity
// In revokeRelease, after setting revoked = true:
string memory latest = latestVersion[componentHash];
if (keccak256(bytes(latest)) == versionHash) {
    // Walk backwards to find latest non-revoked
    uint256 count = releaseCount[componentHash];
    for (uint256 i = count; i > 0; --i) {
        bytes32 vh = versionHistory[componentHash][i - 1];
        if (!releases[componentHash][vh].revoked) {
            latestVersion[componentHash] = releases[componentHash][vh].version;
            latestReleaseIndex[componentHash] = i - 1;
            break;
        }
    }
    // If all revoked, clear latestVersion
    if (keccak256(bytes(latestVersion[componentHash])) == versionHash) {
        latestVersion[componentHash] = "";
        latestReleaseIndex[componentHash] = 0;
    }
}
```

Option B: Add a `getLatestNonRevokedVersion()` view function and deprecate `getLatestVersion()`.

Option C (Minimal): Add NatSpec warning on `getLatestVersion()` that callers MUST also check `isVersionRevoked()`.

---

## Informational Findings

### [I-01] No Timelock on Administrative Operations (Retained from R1 M-04, Downgraded)

**Severity:** Informational
**Category:** Defense-in-Depth / Governance
**Location:** `setMinimumVersion()` (lines 397-429), `updateSignerSet()` (lines 446-498)

**Description:**

All operations execute immediately upon submission. If a `DEFAULT_ADMIN_ROLE` holder and sufficient signer keys are compromised simultaneously, an attacker could execute a complete takeover in a single block:

1. Call `updateSignerSet()` to replace all signers with attacker-controlled addresses
2. Call `publishRelease()` with a malicious binary hash
3. Call `setMinimumVersion()` to force nodes to update to the malicious version

All three operations can be executed atomically in a single transaction (using a batching contract) with zero detection window for the community.

The `updateSignerSet()` function does require `signerThreshold + 1` signatures (elevated from the normal threshold), providing some additional security:
```solidity
uint256 requiredSigs = signers.length > signerThreshold
    ? signerThreshold + 1
    : signers.length;
```

This means a 2-of-3 signer set requires 3-of-3 for rotation, and a 3-of-5 signer set requires 4-of-5. This is a meaningful defense-in-depth measure.

Additionally, `grantRole(RELEASE_MANAGER_ROLE, ...)` requires only `DEFAULT_ADMIN_ROLE` with no ODDAO signer involvement, though a RELEASE_MANAGER without ODDAO signatures cannot publish releases.

Since the R3 audit, the nonce protection further reduces risk by preventing signature replay across operations. This finding is downgraded from Medium to Informational because the combination of nonce protection, elevated signer rotation threshold, and per-operation multi-sig provides adequate defense-in-depth for a registry contract that holds no funds.

**Impact:** Zero detection window in a full key compromise scenario. Mitigated by nonce + elevated threshold.

**Recommendation:**

Consider wrapping `updateSignerSet` with `OmniTimelockController` (already deployed in the OmniBazaar ecosystem) for a 24-48 hour delay. This is particularly important because signer rotation is the most dangerous operation -- once completed, the old signers lose all authority.

For `publishRelease` and `revokeRelease`, a timelock would create operational friction for legitimate releases and security patches, so immediate execution is acceptable.

---

### [I-02] `grantRole(RELEASE_MANAGER_ROLE)` Does Not Require Multi-Sig (Retained from R3 I-02)

**Severity:** Informational
**Category:** Access Control Consistency
**Location:** Constructor (lines 236-237), inherited `AccessControl.grantRole()`

**Description:**

The constructor grants both `DEFAULT_ADMIN_ROLE` and `RELEASE_MANAGER_ROLE` to the deployer. Through OpenZeppelin's `AccessControl`, any address with `DEFAULT_ADMIN_ROLE` can unilaterally:

1. Grant `RELEASE_MANAGER_ROLE` to arbitrary addresses via `grantRole()`
2. Revoke `RELEASE_MANAGER_ROLE` from existing managers via `revokeRole()`
3. Grant `DEFAULT_ADMIN_ROLE` to additional addresses via `grantRole()`

While a RELEASE_MANAGER cannot publish releases without valid ODDAO signatures, the ability to add/remove managers without multi-sig approval is architecturally inconsistent with the otherwise strict multi-sig governance model.

A compromised admin could also revoke `RELEASE_MANAGER_ROLE` from the legitimate manager, creating a denial-of-service on release publishing (though this can be recovered by re-granting the role from another admin).

**Impact:** Unilateral role management by admin. Mitigated by the multi-sig requirement on all state-changing operations.

**Recommendation:**

Consider overriding `grantRole()` to require ODDAO signatures for `RELEASE_MANAGER_ROLE` grants. Alternatively, transfer `DEFAULT_ADMIN_ROLE` to a multi-sig wallet or TimelockController after deployment.

---

### [I-03] Indexed String Event Parameters Produce Hashes, Not Readable Values (Retained from R3 I-03)

**Severity:** Informational
**Category:** Usability / Event Design
**Location:** Events at lines 137-143, 150-154, 161-164

**Description:**

Events `ReleasePublished`, `ReleaseRevoked`, and `MinimumVersionUpdated` use `string indexed component`. When a string parameter is `indexed` in a Solidity event, only its `keccak256` hash is stored in the topic -- not the readable string. Off-chain consumers filtering by component name must compute the hash themselves.

For the known set of component identifiers (`"validator"`, `"service-node"`, `"wallet-extension"`, `"mobile-app"`, `"webapp"`), this is manageable -- monitoring tools can pre-compute the five hashes. However, new component names added in the future require updating all monitoring tools.

**Impact:** Developer ergonomics. No security impact.

**Recommendation:**

Document the known component hashes in NatSpec for developer reference:
```solidity
/// "validator"        => keccak256 = 0x...
/// "service-node"     => keccak256 = 0x...
/// "wallet-extension" => keccak256 = 0x...
/// "mobile-app"       => keccak256 = 0x...
/// "webapp"           => keccak256 = 0x...
```

Alternatively, add a `bytes32 indexed componentHash` parameter alongside the `string` for explicit clarity.

---

### [I-04] No Expiry on Signed Messages

**Severity:** Informational
**Category:** Cryptographic Safety / Operational
**Location:** All signature verification functions

**Description:**

Signed messages have no timestamp-based expiry. Once ODDAO signers produce signatures for nonce N, those signatures remain valid indefinitely until nonce N is consumed by any operation. The nonce system provides ordering protection (signatures become invalid once any operation increments the nonce past N), but there is no deadline-based expiry.

Scenario:
1. ODDAO signers sign a release for nonce 5 on Monday.
2. The admin does not submit the transaction.
3. Six months later, the admin submits the transaction. The signatures are still valid (assuming no other operation consumed nonce 5 in the interim).
4. The release is published, even though the binary may be outdated or the decision to release may have been revoked off-chain.

The nonce system provides sufficient protection against unintended replay (any operation at nonce 5 invalidates all other nonce-5 signatures). The risk is limited to intentional delayed submission by a RELEASE_MANAGER, which is an operational concern rather than a technical vulnerability.

**Impact:** Stale but intentionally-delayed signatures remain valid. Mitigated by nonce system (only one operation per nonce).

**Recommendation:**

Add an optional deadline parameter to signed messages:
```solidity
bytes32 messageHash = keccak256(
    abi.encode(
        "PUBLISH_RELEASE", component, version, binaryHash, minVersion,
        nonce, deadline, block.chainid, address(this)
    )
);
if (block.timestamp > deadline) revert SignatureExpired();
```

This is a breaking change to the signing protocol and may not be worth the operational complexity for a registry that holds no funds. An alternative is to establish an off-chain policy that signatures older than N days should be discarded.

---

## Security Questions Assessment

### Can the Registry Be Manipulated to Point to Malicious Implementations?

**Only with M-of-N ODDAO signer compromise.** Publishing a release requires:
1. `RELEASE_MANAGER_ROLE` (granted by admin)
2. `signerThreshold` valid ECDSA signatures from authorized ODDAO signers
3. Correct `operationNonce` value
4. The version must not already exist for that component

An attacker without sufficient signer keys cannot publish a release. The `binaryHash` field in the release struct allows validators to verify the authenticity of downloaded binaries against the on-chain hash.

The most dangerous scenario is a compromised admin who also has `signerThreshold` signer keys: they can publish a malicious release and set the minimum version to force nodes to update. The elevated threshold requirement for signer rotation (`threshold + 1`) provides some defense, but does not protect against the publish+setMinimumVersion path.

### Access Control on Registry Updates

Access control is layered:
1. **Role-based:** `RELEASE_MANAGER_ROLE` for `publishRelease()` and `revokeRelease()`. `DEFAULT_ADMIN_ROLE` for `setMinimumVersion()` and `updateSignerSet()`.
2. **Signature-based:** All operations require M-of-N ODDAO signatures verified on-chain.
3. **Nonce-based:** `operationNonce` prevents replay of previously-used signatures.
4. **Elevated threshold:** `updateSignerSet()` requires `threshold + 1` signatures (or all signers if `signerCount == threshold`).

The combination provides defense-in-depth: even if one layer is compromised (e.g., a RELEASE_MANAGER key), the other layers (ODDAO signatures) prevent unauthorized operations.

### Front-Running Registry Updates

Front-running is not a significant concern:
1. **No MEV opportunity:** The registry holds no funds and there is no financial incentive to front-run a release publication.
2. **Nonce ordering:** The `operationNonce` ensures strict ordering. Two competing transactions for the same nonce will have one succeed and one revert with `StaleNonce`.
3. **Duplicate version guard:** Publishing the same version twice reverts with `DuplicateVersion`, preventing a front-runner from claiming a version identifier.

The only theoretical front-running scenario is a censorship attack: a malicious block producer delays or reorders a legitimate release publication. This is mitigated by the short block times on OmniCoin L1 and the ability to resubmit with the same parameters (the nonce is not consumed until the transaction succeeds).

### Emergency Rollback Mechanisms

The contract has limited emergency capabilities:
1. **Revocation:** `revokeRelease()` marks a release as revoked (with ODDAO multi-sig). Validators can check `isVersionRevoked()` or `verifyRelease()`.
2. **Minimum version override:** `setMinimumVersion()` can force nodes to update past a vulnerable version.
3. **No pause:** The contract has no `Pausable` mechanism. If a vulnerability is discovered in the contract itself, the only recourse is to stop interacting with it.
4. **No upgrade:** The contract is not upgradeable. A bug in the registry logic requires deploying a new contract and migrating all validator configurations to point to the new address.

The lack of pause and upgrade mechanisms is a trade-off: it prevents the admin from tampering with the registry state, but also prevents emergency fixes. For a registry that holds no funds, this trade-off is acceptable.

---

## Vulnerability Pattern Scan (VP-01 through VP-58)

| VP | Pattern | Status | Notes |
|----|---------|--------|-------|
| VP-01 | Classic Reentrancy | **N/A** | No external calls; no ETH transfers; no token operations |
| VP-02 | Cross-Function Reentrancy | **N/A** | No external calls |
| VP-03 | Read-Only Reentrancy | **N/A** | No external calls |
| VP-04 | Cross-Contract Reentrancy | **N/A** | No external calls |
| VP-05 | ERC777 Callback | **N/A** | No token operations |
| VP-06 | Missing Access Control | **SAFE** | `onlyRole` on all state-changing functions; ODDAO multi-sig on all operations |
| VP-07 | tx.origin Usage | **N/A** | Not used |
| VP-08 | Unsafe delegatecall | **N/A** | Not used |
| VP-09 | Unprotected Critical Function | **SAFE** | All state-changing functions require role + multi-sig |
| VP-10 | Unprotected Initializer | **N/A** | No initializer (constructor-based deployment) |
| VP-11 | Default Visibility | **SAFE** | All functions have explicit visibility |
| VP-12 | Unchecked Overflow | **SAFE** | Solidity 0.8.24 checked arithmetic; no `unchecked` blocks |
| VP-13 | Division Before Multiply | **N/A** | No arithmetic operations |
| VP-14 | Unsafe Downcast | **N/A** | No downcasts |
| VP-15 | Rounding Exploitation | **N/A** | No numeric calculations |
| VP-16 | Precision Loss | **N/A** | No numeric calculations |
| VP-17 | Spot Price Manipulation | **N/A** | No price feeds |
| VP-18 | Stale Oracle | **N/A** | No oracles |
| VP-19 | Short TWAP | **N/A** | No TWAP |
| VP-20 | Flash Loan Price | **N/A** | No price dependencies |
| VP-21 | Sandwich Attack | **N/A** | No swaps or price-dependent operations |
| VP-22 | Zero Address | **SAFE** | Checked in `_validateSignerSet()` (line 872) |
| VP-23 | Zero Amount | **N/A** | No amounts |
| VP-24 | Array Mismatch | **N/A** | No parallel arrays |
| VP-25 | msg.value in Loop | **N/A** | No payable functions |
| VP-26 | Unchecked ERC20 | **N/A** | No token operations |
| VP-27 | Unchecked Low-Level | **N/A** | No low-level calls |
| VP-28 | Unchecked Create | **N/A** | No create operations |
| VP-29 | Unbounded Loop | **BOUNDED** | Signer loops bounded by `MAX_SIGNERS = 20`. O(n^2) duplicate check in `_validateSignerSet` is O(400) worst case. |
| VP-30 | DoS via Revert | **N/A** | No push payments or external dependencies |
| VP-31 | Selfdestruct Force-Send | **N/A** | No ETH accounting |
| VP-32 | Gas Griefing | **N/A** | No external calls |
| VP-33 | Unbounded Return Data | **N/A** | No arbitrary external calls |
| VP-34 | Front-Running | **LOW RISK** | No financial incentive to front-run. Nonce ordering prevents replay. |
| VP-35 | Timestamp Dependence | **SAFE** | `publishedAt` is informational only (line 302) |
| VP-36 | Signature Replay | **SAFE** | `operationNonce` consumed per operation; chainId + contract address in message |
| VP-37 | Cross-Chain Replay | **SAFE** | `block.chainid` included in all signed messages |
| VP-38 | Hash Collision (encodePacked) | **SAFE** | Uses `abi.encode` throughout (lines 734, 371, 416, 467) |
| VP-39 | Storage Collision | **N/A** | Not upgradeable |
| VP-40 | Weak Randomness | **N/A** | No randomness |
| VP-41 | Missing Event | **SAFE** | All state changes emit events |
| VP-42 | Uninitialized Implementation | **N/A** | Not upgradeable |
| VP-43 | Storage Layout | **N/A** | Not upgradeable |
| VP-44 | Reinitializer | **N/A** | Not upgradeable |
| VP-45 | Selector Clash | **N/A** | Not upgradeable |
| VP-46 | Fee-on-Transfer | **N/A** | No token operations |
| VP-47 | Rebasing Token | **N/A** | No token operations |
| VP-48 | Missing Return Bool | **N/A** | No token operations |
| VP-49 | Approval Race | **N/A** | No approvals |
| VP-50 | ERC777 Hooks | **N/A** | No token operations |
| VP-51 | Self-Transfer | **N/A** | No transfers |
| VP-52 | Flash Loan Governance | **N/A** | No governance voting |
| VP-53 | Collateral Manipulation | **N/A** | No collateral |
| VP-54 | Missing Initiator Check | **N/A** | No callbacks |
| VP-55 | Missing Slippage | **N/A** | No swaps |
| VP-56 | Share Inflation | **N/A** | No vault mechanics |
| VP-57 | recoverERC20 Backdoor | **N/A** | No token recovery function |
| VP-58 | Transient Storage | **N/A** | Not used |

---

## Access Control Map

| Role | Functions | Risk Level | Notes |
|------|-----------|------------|-------|
| `DEFAULT_ADMIN_ROLE` | `setMinimumVersion()`, `updateSignerSet()`, `grantRole()`, `revokeRole()` | 6/10 | Can set min version (with ODDAO sigs), rotate signers (with threshold+1 sigs), manage roles unilaterally |
| `RELEASE_MANAGER_ROLE` | `publishRelease()`, `revokeRelease()` | 5/10 | Can publish/revoke releases (requires ODDAO sigs). Cannot set minimum version or rotate signers. |
| ODDAO Signers | Authorize all operations via off-chain signatures | 7/10 | M-of-N quorum controls all security-critical operations |
| Public | All view functions | 1/10 | Read-only access to release info, version history, signer list |

## Centralization Risk Assessment

**Single-key maximum damage:**

- **Admin key compromise alone:** Can grant/revoke `RELEASE_MANAGER_ROLE`. Cannot publish releases, set minimum version, or rotate signers without ODDAO signatures. Severity: **3/10**.

- **Admin + threshold signer keys:** Can publish malicious releases, set minimum version to force upgrades, and rotate signers to lock out legitimate ODDAO members. Severity: **9/10**.

- **Threshold signer keys (no admin):** Cannot perform any operation (all functions require a role). Severity: **1/10**.

- **Admin + all signer keys:** Complete takeover. Can replace the entire ODDAO, publish arbitrary releases, and force all nodes to update. Severity: **10/10**.

**Recommendation for production:**
1. `DEFAULT_ADMIN_ROLE` should be a multi-sig wallet or TimelockController
2. ODDAO signer set should be at least 3-of-5
3. ODDAO signer keys should be stored on hardware wallets (HSMs)
4. Monitor `SignerSetUpdated` events off-chain for unauthorized rotations

---

## Test Coverage Assessment

The existing test suite (58 tests, 100% pass rate in `Coin/test/UpdateRegistry.test.js`) provides good coverage of core functionality:

- Deployment and initial state
- Release publishing with valid signatures
- Release info storage and retrieval
- Latest version tracking
- Minimum version setting
- Release count
- Operation nonce incrementing
- Duplicate version rejection
- Input validation (empty fields)
- Insufficient/invalid signature rejection
- Stale nonce rejection
- Access control enforcement
- Multi-component isolation
- Release revocation
- Signer set rotation with elevated threshold
- View function correctness
- Duplicate signature deduplication (bitmap)

**Test gaps identified (carried from R3, still open):**

1. No test for `latestReleaseIndex` regression prevention (publishing older version after newer)
2. No test for minimum version downgrade scenario
3. No test for maximum string length enforcement (`MAX_VERSION_LENGTH`, `MAX_CID_LENGTH`, `MAX_REASON_LENGTH`)
4. No test for `MAX_SIGNERS` boundary (20 signers)
5. No test for `computeReleaseHash` / `computeSignerUpdateHash` matching actual signature verification
6. No test for granting `RELEASE_MANAGER_ROLE` to additional addresses
7. No test for revoking admin/manager roles
8. No test for revoked `latestVersion` behavior (L-02)

---

## Architecture Review

### Strengths

1. **Robust domain separation:** All signed messages include action prefix (`"PUBLISH_RELEASE"`, `"REVOKE"`, `"MIN_VERSION"`, `"UPDATE_SIGNERS"`), chain ID, contract address, and operation nonce. This prevents cross-chain, cross-contract, cross-action, and replay attacks.

2. **Correct use of `abi.encode`:** All message hash constructions use `abi.encode`, which ABI-encodes dynamic types with length prefixes. This makes hash collisions between different parameter combinations impossible, addressing the R1 H-01 finding.

3. **Bitmap-based duplicate detection:** The `seenBitmap` approach in `_verifyMessageSignaturesWithThreshold` is gas-efficient (bit operations in memory) and supports up to 256 signers -- well above `MAX_SIGNERS = 20`.

4. **Elevated threshold for signer rotation:** `updateSignerSet()` requires `signerThreshold + 1` signatures (or all signers if `signerCount == threshold`), providing a higher security bar for the most sensitive operation.

5. **Monotonic nonce:** `operationNonce` incremented after every state-changing operation ensures each signature set can only be used once.

6. **Monotonic latest version tracking:** `latestReleaseIndex` prevents out-of-order publishing from regressing `latestVersion`.

7. **Comprehensive input validation:** Empty strings, zero hashes, zero addresses, duplicate signers, invalid thresholds, and excessive string lengths all validated with descriptive custom errors.

8. **Proper OpenZeppelin usage:** Uses OZ 5.x `AccessControl`, `ECDSA`, and `MessageHashUtils` correctly. `ECDSA.recover()` reverts on invalid signatures and enforces low-S values.

### Remaining Weaknesses

1. **No monotonic minimum version enforcement:** (M-01) Minimum version can be downgraded.
2. **No revoked latestVersion update:** (L-02) Revoked latest version is still returned by `getLatestVersion()`.
3. **Unbounded component string:** (L-01) No maximum length enforcement.
4. **No pause mechanism:** Cannot freeze the registry in an emergency.
5. **No upgrade path:** A bug in the contract requires full redeployment and migration.

---

## Gas Analysis

| Function | Estimated Gas (first call) | Notes |
|----------|---------------------------|-------|
| `publishRelease` (2 sigs) | ~180,000 | Storage-heavy: writes ReleaseInfo struct + mappings + version history |
| `revokeRelease` (2 sigs) | ~55,000 | Storage update: sets bool + string |
| `setMinimumVersion` (2 sigs) | ~50,000 | Storage update: sets string mapping |
| `updateSignerSet` (3 sigs, 3->2) | ~95,000 | Clears old array + mappings, sets new |
| `getLatestRelease` | ~8,000 | Two mapping reads + struct copy to memory |
| `verifyRelease` | ~5,000 | Two mapping reads + bool check |

All gas costs are within reasonable bounds. The O(n^2) duplicate check in `_validateSignerSet` and O(n) signer index lookup in `_getSignerIndex` are bounded by `MAX_SIGNERS = 20`, keeping worst-case gas predictable.

---

## Conclusion

UpdateRegistry has been thoroughly hardened over three audit rounds. All High-severity findings from Round 1 have been properly remediated. The contract now uses `abi.encode` for collision-resistant hashing, includes nonce-based replay protection, has action prefixes for domain separation, and prevents `latestVersion` regression through index tracking.

The remaining findings are:

1. **M-01 (Minimum version downgrade):** The most significant remaining issue. While mitigated by multi-sig, a compromised signer quorum can lower the minimum version, re-enabling vulnerable software. Consider adding monotonic enforcement.

2. **L-01 (Unbounded component string):** Add `MAX_COMPONENT_LENGTH` validation.

3. **L-02 (Revoked latestVersion not updated):** Walk version history backwards on revocation, or add a dedicated non-revoked accessor.

4. **I-01 through I-04:** Informational items covering governance trade-offs and operational best practices.

**Overall Risk Rating: LOW.** The contract holds no funds and all state-changing operations require ODDAO multi-sig approval. The attack surface is limited to scenarios where `signerThreshold` distinct ODDAO signer keys are simultaneously compromised. The elevated threshold for signer rotation and nonce-based replay protection provide robust defense-in-depth.

**Pre-Mainnet Recommendation:** Address the test gaps identified in the test coverage section. Add the missing tests for regression prevention, minimum version downgrade, string length boundaries, and revoked latestVersion behavior.

---
*Generated by Claude Code Audit Agent (Opus 4.6) -- 6-Pass Enhanced*
*Round 6 pre-mainnet audit (prior: Round 1 on 2026-02-21, Round 3 on 2026-02-26)*
*Reference data: 58 vulnerability patterns, Cyfrin checklist, DeFiHackLabs incident database, Solodit findings*
