# Security Audit Report: OmniBazaarResolver (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Opus 4.6 -- 7-Pass Comprehensive Audit
**Contract:** `Coin/contracts/ens/OmniBazaarResolver.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 215
**Upgradeable:** No (immutable deployment)
**Handles Funds:** No (pure name resolution, no token handling)
**Dependencies:** `ECDSA` (OpenZeppelin v5.x), `Ownable2Step` (OpenZeppelin v5.x)
**Deployed Size:** 3.855 KiB (well within 24 KiB limit)
**Test Coverage:** `Coin/test/OmniBazaarResolver.test.js` (28 test cases -- all passing)
**Previous Audits:** None (first audit for this contract)

---

## Executive Summary

OmniBazaarResolver is a lightweight, non-upgradeable ENSIP-10 wildcard resolver with ERC-3668 CCIP-Read support. It is designed for deployment on Ethereum mainnet to resolve `*.omnibazaar.eth` names by redirecting ENS clients to an off-chain gateway that reads name records from OmniENS on the Avalanche Subnet-EVM. The contract stores zero name-to-address mappings; all resolution data originates from the gateway and is verified on-chain via ECDSA signature.

The contract is compact (215 lines), well-documented, and follows a clean separation of concerns:
- `resolve()` always reverts with `OffchainLookup` to trigger CCIP-Read
- `resolveWithProof()` verifies the gateway's ECDSA signature and TTL before returning data
- Admin functions allow the owner to update gateway URLs, signer, and TTL

This audit found **0 Critical, 0 High, 0 Medium, 2 Low, and 3 Informational** findings. The contract is production-ready.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 3 |

---

## Pass 1: Static Analysis Results

### Solhint

Zero contract-specific findings. Solhint reported only two warnings about nonexistent rules in the configuration (`contract-name-camelcase`, `event-name-camelcase`), neither of which pertains to the contract code itself. The contract passes all configured solhint rules.

---

## Pass 2: Line-by-Line Manual Review

### Custom Errors (Lines 13-37)

```solidity
error OffchainLookup(
    address sender,
    string[] urls,
    bytes callData,
    bytes4 callbackFunction,
    bytes extraData
);
error InvalidSignature();
error ResponseExpired();
error NoGatewayURLs();
error ZeroSigner();
```

**Analysis:**
- `OffchainLookup` matches the ERC-3668 specification selector `0x556f1830` exactly. The parameter order and types conform to the standard.
- All remaining errors use custom errors (not `require` strings): Gas-efficient and correct.
- No missing error definitions for the contract's revert paths.

**Verdict:** Sound. No issues.

### State Variables (Lines 55-65)

```solidity
string[] public gatewayURLs;
address public signer;
uint256 public responseTTL;
```

**Analysis:**
- `gatewayURLs` is a dynamic string array. Solidity auto-generates a getter that returns a single element by index, so the separate `getGatewayURLs()` view function (line 194) is necessary for returning the full array. CORRECT.
- `signer` is a plain `address` (not `address payable`). This is correct since no ETH is sent to the signer.
- `responseTTL` is stored as `uint256` but is only consumed off-chain by the gateway to calculate the `expires` timestamp. The on-chain `resolveWithProof()` does NOT enforce `responseTTL` directly -- it only checks the `expires` field from the gateway response. See L-01 below.

**Verdict:** Sound. L-01 noted for the unenforced TTL.

### Constructor (Lines 92-103)

```solidity
constructor(
    string[] memory _gatewayURLs,
    address _signer,
    uint256 _responseTTL
) Ownable(msg.sender) {
    if (_gatewayURLs.length == 0) revert NoGatewayURLs();
    if (_signer == address(0)) revert ZeroSigner();

    gatewayURLs = _gatewayURLs;
    signer = _signer;
    responseTTL = _responseTTL;
}
```

**Analysis:**
- Zero-length URL array validation: CORRECT
- Zero-address signer validation: CORRECT
- No validation on `_responseTTL` (zero is accepted): INTENTIONAL -- test confirms zero TTL is accepted (line 130 of test file). A zero TTL means the gateway must set `expires = block.timestamp`, making responses valid only for the current block. This is a valid use case for maximum freshness.
- `Ownable(msg.sender)` sets deployer as owner: CORRECT
- No re-initialization risk since this is a plain constructor (not `initialize()`): CORRECT
- No empty string validation for individual URLs: See I-01

**Verdict:** Sound.

### setGatewayURLs (Lines 109-115)

```solidity
function setGatewayURLs(
    string[] calldata _gatewayURLs
) external onlyOwner {
    if (_gatewayURLs.length == 0) revert NoGatewayURLs();
    gatewayURLs = _gatewayURLs;
    emit GatewayURLsUpdated(_gatewayURLs);
}
```

**Analysis:**
- Access control via `onlyOwner`: CORRECT
- Empty array validation: CORRECT
- Uses `calldata` for gas efficiency: CORRECT
- Event emission after state change: CORRECT
- No validation of URL string content (empty strings, malformed URLs accepted): See I-01
- No upper bound on array length: The array length is bounded by the block gas limit. An extremely large array would make the `resolve()` revert data expensive but would not cause a contract-level vulnerability. ACCEPTED.

**Verdict:** Sound.

### setSigner (Lines 119-124)

```solidity
function setSigner(address _signer) external onlyOwner {
    if (_signer == address(0)) revert ZeroSigner();
    address oldSigner = signer;
    signer = _signer;
    emit SignerUpdated(oldSigner, _signer);
}
```

**Analysis:**
- Access control via `onlyOwner`: CORRECT
- Zero-address validation: CORRECT
- Old value captured before write for event emission: CORRECT
- No check for `_signer == signer` (no-op protection): Not needed since the gas cost is borne by the owner and the event emission provides an audit trail regardless.
- Signer rotation does not invalidate in-flight responses: Responses signed by the old signer will fail `resolveWithProof()` once the signer is changed. This is expected behavior for key rotation. No revocation list is needed because response TTLs are short (default 300 seconds).

**Verdict:** Sound.

### setResponseTTL (Lines 128-132)

```solidity
function setResponseTTL(uint256 _responseTTL) external onlyOwner {
    uint256 oldTTL = responseTTL;
    responseTTL = _responseTTL;
    emit ResponseTTLUpdated(oldTTL, _responseTTL);
}
```

**Analysis:**
- Access control via `onlyOwner`: CORRECT
- No upper bound on TTL: See L-01
- Old value captured for event: CORRECT
- Zero TTL accepted: INTENTIONAL (see constructor analysis)

**Verdict:** Sound. L-01 noted.

### resolve (Lines 142-154)

```solidity
function resolve(
    bytes calldata name,
    bytes calldata data
) external view returns (bytes memory) {
    bytes memory callData = abi.encode(name, data);
    revert OffchainLookup(
        address(this),
        gatewayURLs,
        callData,
        this.resolveWithProof.selector,
        callData // extraData = callData for verification
    );
}
```

**Analysis:**
- Always reverts with `OffchainLookup` as required by ERC-3668: CORRECT
- `sender` is `address(this)`: CORRECT -- ERC-3668 mandates this for the client to validate the revert originated from the expected contract.
- `callData` is `abi.encode(name, data)`: This bundles the DNS-encoded name and the resolver calldata (e.g., `addr(bytes32)`) for the gateway to interpret. CORRECT.
- `callbackFunction` is `this.resolveWithProof.selector`: CORRECT -- points the client to the callback function.
- `extraData` is set to the same `callData`: This is forwarded to `resolveWithProof()` for context verification. The gateway cannot substitute a different name/query because `extraData` is signed into the response hash. CORRECT.
- Function is `view` with `returns (bytes memory)` but never returns: The `returns` declaration is required by the ENSIP-10 interface signature. The function always reverts. CORRECT.
- No input validation on `name` or `data`: Not needed since the function always reverts. The gateway handles parsing.
- `abi.encode` (not `abi.encodePacked`) for `callData`: CORRECT -- uses padded encoding, no collision risk.

**Verdict:** Sound. Correctly implements ERC-3668 OffchainLookup.

### resolveWithProof (Lines 164-190)

```solidity
function resolveWithProof(
    bytes calldata response,
    bytes calldata extraData
) external view returns (bytes memory) {
    (bytes memory result, uint64 expires, bytes memory sig) =
        abi.decode(response, (bytes, uint64, bytes));

    // Check TTL
    if (block.timestamp > expires) revert ResponseExpired();

    // Reconstruct the signed message (EIP-191 personal sign)
    bytes32 messageHash = keccak256(
        abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            keccak256(
                abi.encodePacked(result, expires, extraData)
            )
        )
    );

    // Verify signature
    address recovered = ECDSA.recover(messageHash, sig);
    if (recovered != signer) revert InvalidSignature();

    return result;
}
```

**Analysis:**

1. **ABI decoding:** `abi.decode(response, (bytes, uint64, bytes))` -- decodes the gateway response into result, expiry timestamp, and signature. If the encoding is malformed, Solidity reverts automatically. CORRECT.

2. **TTL check (line 173):** `block.timestamp > expires` -- rejects responses where the current block time exceeds the expiry. The `solhint-disable-next-line not-rely-on-time` comment is appropriate since the TTL check is a valid business use of `block.timestamp`. CORRECT.
   - Edge case: `block.timestamp == expires` is ACCEPTED (not expired). This is the standard `>` check pattern and is correct.
   - `expires` is `uint64`: sufficient until year 584,942,417,355. No overflow concern.

3. **Signature construction (lines 176-183):**
   - Inner hash: `keccak256(abi.encodePacked(result, expires, extraData))`
     - `result` is `bytes` (dynamic), `expires` is `uint64` (8 bytes), `extraData` is `bytes` (dynamic).
     - `abi.encodePacked` with multiple dynamic types has a known collision risk when the boundary between `result` and `extraData` shifts. See L-02 below.
   - Outer hash: `keccak256("\x19Ethereum Signed Message:\n32" || innerHash)`
     - This is the standard EIP-191 personal sign prefix. Since `innerHash` is exactly 32 bytes, the `\n32` length is correct.
     - The prefix prevents cross-protocol signature reuse (e.g., a valid Ethereum transaction cannot be replayed as a CCIP-Read response).
   - CORRECT for the CCIP-Read use case.

4. **ECDSA.recover (line 186):**
   - OpenZeppelin v5.x `ECDSA.recover()` reverts on invalid signatures (zero address, invalid s-value, invalid v-value). It does NOT return `address(0)` for invalid signatures. This means the contract is protected against the classic "zero signer" attack where `recover` returns `address(0)` and the check `recovered != signer` passes if `signer` is also zero. Since the constructor and `setSigner` both reject `address(0)`, and OZ v5 `recover` reverts rather than returning zero, this is doubly protected. CORRECT.
   - Signature malleability: OZ v5 ECDSA enforces that `s` is in the lower half of the curve order (s <= secp256k1n/2). This prevents a valid signature from being transformed into a different valid signature for the same message. CORRECT.

5. **Return value:** `return result` -- the raw bytes are returned to the ENS client, which decodes them according to the original query (e.g., `addr(bytes32)` returns an address). CORRECT.

6. **No reentrancy risk:** The function is `view` (no state changes) and makes no external calls (ECDSA.recover is a library call using inline assembly for `ecrecover`). CORRECT.

7. **No replay protection beyond TTL:** A valid signed response can be replayed until `expires`. This is by design -- CCIP-Read responses are cacheable. The TTL limits the window. CORRECT.

**Verdict:** Sound. L-02 noted for `encodePacked` collision risk. Core signature verification is correct.

### getGatewayURLs (Lines 194-200)

```solidity
function getGatewayURLs()
    external
    view
    returns (string[] memory)
{
    return gatewayURLs;
}
```

**Analysis:** Simple view function returning the full dynamic array. No issues.

**Verdict:** Sound.

### supportsInterface (Lines 208-214)

```solidity
function supportsInterface(
    bytes4 interfaceId
) external pure returns (bool) {
    return
        interfaceId == 0x9061b923 || // ENSIP-10 resolve(bytes,bytes)
        interfaceId == 0x01ffc9a7; // ERC-165
}
```

**Analysis:**
- `0x9061b923` is `bytes4(keccak256("resolve(bytes,bytes)"))`: This is the correct ENSIP-10 interface ID. Verified by computing `keccak256("resolve(bytes,bytes)")` = `0x9061b923...`. CORRECT.
- `0x01ffc9a7` is the ERC-165 `supportsInterface(bytes4)` selector: CORRECT.
- The function does NOT declare support for `IExtendedResolver` (`0x9061b923` is exactly that interface). The naming is consistent.
- `pure` visibility: CORRECT -- no state access.
- Does not declare support for `addr(bytes32)`, `text(bytes32,string)`, etc.: This is correct. The resolver implements these indirectly via CCIP-Read. The ENS Universal Resolver uses `resolve(bytes,bytes)` as the entry point and wraps the inner query.

**Verdict:** Sound.

---

## Pass 3: Business Logic Analysis

### CCIP-Read Flow

The contract implements the standard ERC-3668 CCIP-Read flow:

```
1. Client calls resolve(name, data) on OmniBazaarResolver
2. Contract reverts with OffchainLookup(sender, urls, callData, callback, extraData)
3. Client fetches gateway URL with callData
4. Gateway reads OmniENS on Avalanche Subnet-EVM
5. Gateway signs (result, expires) with the authorized signer key
6. Client calls resolveWithProof(response, extraData) on OmniBazaarResolver
7. Contract verifies signature, TTL, and returns result
```

| Aspect | Assessment |
|--------|------------|
| ENSIP-10 compliance | `resolve(bytes,bytes)` with `OffchainLookup` revert: CORRECT |
| ERC-3668 compliance | `OffchainLookup` error signature, callback selector, extraData forwarding: CORRECT |
| ERC-165 compliance | Reports ENSIP-10 and ERC-165 support: CORRECT |
| Signature scheme | EIP-191 personal sign with inner hash binding result + expires + extraData: CORRECT |
| TTL enforcement | `block.timestamp > expires` check: CORRECT |
| Replay protection | Bounded by TTL expiry: CORRECT for CCIP-Read |
| Cross-protocol replay | Prevented by EIP-191 `\x19Ethereum Signed Message:\n32` prefix: CORRECT |

### Trust Model

The contract has a clear trust model:

| Component | Trust Level | Justification |
|-----------|-------------|---------------|
| Owner (deployer) | Full trust | Can change signer, gateway URLs, TTL. Protected by Ownable2Step. |
| Signer | Delegated trust | Can sign arbitrary resolution results. A compromised signer can return incorrect addresses for names. |
| Gateway | Limited trust | Delivers responses but cannot forge signatures. A compromised gateway can only serve stale/expired responses (rejected by TTL) or refuse to serve (DoS). |
| ENS client | Untrusted | The client forwards the OffchainLookup parameters and calls resolveWithProof. The contract verifies everything. |

**Key risk:** If the signer key is compromised, an attacker can sign responses mapping any `*.omnibazaar.eth` name to any address, enabling phishing attacks. This is mitigated by:
- Keeping the signer key in a secure environment (e.g., HSM)
- Short TTL (default 300 seconds) limits the damage window after key rotation
- Owner can immediately rotate the signer via `setSigner()`
- Ownable2Step protects against accidental/malicious ownership transfer

### Gateway Redundancy

The contract supports multiple gateway URLs (`string[] public gatewayURLs`). Per ERC-3668, the client tries URLs in order until one succeeds. This provides:
- **Redundancy:** If one gateway is down, others can serve the request
- **Load balancing:** Client-side round-robin across gateways

No issues with the multi-gateway implementation.

### What the Contract CANNOT Do

| Action | Verification |
|--------|-------------|
| Store name records | No mapping of names to addresses exists on-chain |
| Transfer or hold funds | No payable functions, no receive/fallback, no token handling |
| Modify ENS registry | No ENS registry interaction (resolver is set externally) |
| Self-destruct | No selfdestruct opcode |
| Upgrade | No proxy pattern, no UUPS, no delegatecall |

---

## Pass 4: DeFi Attack Vectors

### Signer Key Compromise

**Scenario:** An attacker obtains the signer private key.

**Analysis:**
- The attacker can sign responses mapping `alice.omnibazaar.eth` to an attacker-controlled address.
- Users resolving `alice.omnibazaar.eth` via ENS will receive the attacker's address and may send funds to it.
- The attacker can target specific names (e.g., a known marketplace seller) for targeted phishing.

**Mitigation:**
- Owner detects the compromise (e.g., monitoring signed responses)
- Owner calls `setSigner(newSigner)` to rotate the key
- All responses signed with the old key become invalid immediately (they fail the `recovered != signer` check)
- Existing cached responses with the old signer continue to be served by clients until TTL expires (max 300 seconds default)

**Risk level:** Medium (off-chain operational risk). The contract correctly handles rotation. The window of vulnerability is bounded by detection time + transaction confirmation time.

### Gateway Manipulation

**Scenario:** An attacker compromises the CCIP-Read gateway.

**Analysis:**
- The attacker cannot forge signatures (they do not have the signer key).
- The attacker can refuse to serve responses (DoS).
- The attacker can serve expired/invalid responses (rejected by TTL and signature checks).
- The attacker can serve valid cached responses (within TTL, no harm since the data is still correct).
- If multiple gateways are configured, the client falls back to the next URL.

**Risk level:** Low. Gateway compromise results in at most a DoS, not incorrect resolution.

### Signature Replay

**Scenario:** An attacker captures a valid (result, expires, signature) tuple and replays it.

**Analysis:**
- The response is valid until `expires`. Replaying it before expiry returns the same correct result. This is not harmful -- it is equivalent to the ENS client caching the response.
- After `expires`, the replay is rejected by the TTL check.
- The `extraData` parameter binds the response to a specific name query. An attacker cannot take a response for `alice.omnibazaar.eth` and replay it for `bob.omnibazaar.eth` because the `extraData` differs and the signature verification fails.

**Risk level:** None. Replay within TTL is by design; replay across names is prevented.

### Front-Running resolveWithProof

**Scenario:** An attacker front-runs a `resolveWithProof()` call.

**Analysis:**
- `resolveWithProof()` is a `view` function. It does not modify state.
- Front-running a view function has no impact -- the attacker simply gets the same result the legitimate caller would get.
- There is no MEV extraction opportunity.

**Risk level:** None.

### abi.encodePacked Collision in Signature Hash

**Scenario:** An attacker crafts a (result, expires, extraData) triple that produces the same inner hash as a legitimately signed response, but with different semantic meaning.

**Analysis:** See L-02 below for detailed treatment.

**Risk level:** Low. Theoretical collision requires specific byte alignment.

---

## Pass 5: Cross-Contract Integration Analysis

### Integration with ENS (Ethereum Mainnet)

| Aspect | Verification |
|--------|-------------|
| Resolver registration | Owner must call `ENSRegistry.setResolver(namehash("omnibazaar.eth"), address(resolver))` on Ethereum mainnet |
| ENSIP-10 wildcard | The ENS Universal Resolver calls `resolve(bytes,bytes)` on the resolver for *.omnibazaar.eth lookups. OmniBazaarResolver responds with OffchainLookup. |
| ERC-165 detection | The ENS Universal Resolver calls `supportsInterface(0x9061b923)` to detect ENSIP-10 support. OmniBazaarResolver returns `true`. |
| Standard ENS calls | Direct calls to `addr(bytes32)` or `text(bytes32,string)` are NOT implemented on the resolver. All resolution goes through `resolve(bytes,bytes)` + CCIP-Read. This is correct for an ENSIP-10 wildcard resolver. |

**Integration correctness:** Sound. The contract conforms to ENSIP-10 and ERC-3668 specifications.

### Integration with OmniENS (Avalanche Subnet-EVM)

The OmniBazaarResolver does not interact with OmniENS on-chain. The gateway reads OmniENS data off-chain and signs the response. The integration is:

```
OmniBazaarResolver (Ethereum) --[CCIP-Read]--> Gateway --[RPC]--> OmniENS (Avalanche)
```

The contract has no Avalanche dependencies, imports, or cross-chain calls. All cross-chain communication is handled by the gateway.

### Integration with CCIP-Read Clients

| Client | Compatibility |
|--------|---------------|
| ethers.js v6 | Built-in CCIP-Read support via `provider.getResolver()` |
| viem | Built-in CCIP-Read support via `getEnsAddress()` |
| ENS Universal Resolver | Calls `resolve(bytes,bytes)`, handles OffchainLookup, calls `resolveWithProof()` |
| Legacy ENS clients | Will fail gracefully (do not understand OffchainLookup revert) |

**Integration correctness:** Sound. Standard CCIP-Read flow is compatible with all modern ENS clients.

---

## Pass 6: Upgradeability & Storage

### Non-Upgradeable Contract

OmniBazaarResolver is a plain Solidity contract. There is no:
- `UUPSUpgradeable` inheritance
- `_authorizeUpgrade()` function
- `initialize()` function
- Proxy pattern
- `delegatecall` usage

**Verdict:** No upgradeability concerns. The contract is deployed once and cannot be modified.

### Storage Layout

| Slot | Variable | Type | Size | Notes |
|------|----------|------|------|-------|
| 0 | `_owner` (Ownable) | address | 20 bytes | Inherited from Ownable |
| 1 | `_pendingOwner` (Ownable2Step) | address | 20 bytes | Inherited from Ownable2Step |
| 2 | `gatewayURLs` | string[] | 32 bytes (length) | Dynamic array; elements stored at keccak256(2) |
| 3 | `signer` | address | 20 bytes | Full slot (address uses 20 bytes, 12 bytes padding) |
| 4 | `responseTTL` | uint256 | 32 bytes | Full slot |

**Storage analysis:** Clean and compact layout. No packing opportunities (each variable naturally occupies its own slot). No storage gaps needed (non-upgradeable).

**Potential optimization:** `signer` (20 bytes) and `responseTTL` could be packed into a single slot if `responseTTL` were declared as `uint96` (12 bytes). This would save one storage slot and reduce cold SLOAD gas by 2,100 per call to `resolveWithProof()`. However, `resolveWithProof()` is a `view` function (no gas cost when called externally), so this optimization provides no user-facing gas savings. See I-02.

---

## Pass 7: Test Coverage Assessment

| Test Case | Status | Notes |
|-----------|--------|-------|
| Constructor: set gateway URLs | PASS | |
| Constructor: set signer | PASS | |
| Constructor: set responseTTL | PASS | |
| Constructor: set owner to deployer | PASS | |
| Constructor: reject empty URLs | PASS | |
| Constructor: reject zero signer | PASS | |
| Constructor: accept zero TTL | PASS | |
| resolve(): revert with OffchainLookup | PASS | Verifies selector, sender, URLs, callback |
| resolveWithProof(): accept valid signature | PASS | Full end-to-end with signResponse helper |
| resolveWithProof(): reject wrong signer | PASS | |
| resolveWithProof(): reject expired response | PASS | |
| resolveWithProof(): reject tampered result | PASS | |
| resolveWithProof(): reject tampered extraData | PASS | |
| supportsInterface(): ENSIP-10 | PASS | |
| supportsInterface(): ERC-165 | PASS | |
| supportsInterface(): reject random | PASS | |
| supportsInterface(): reject ERC-721 | PASS | |
| setGatewayURLs(): update as owner | PASS | With event verification |
| setGatewayURLs(): reject empty array | PASS | |
| setGatewayURLs(): reject non-owner | PASS | |
| setSigner(): update as owner | PASS | With event verification |
| setSigner(): reject zero address | PASS | |
| setSigner(): reject non-owner | PASS | |
| setResponseTTL(): update as owner | PASS | With event verification |
| setResponseTTL(): allow zero | PASS | |
| setResponseTTL(): reject non-owner | PASS | |
| Ownership: two-step transfer | PASS | |
| Ownership: reject non-pending-owner | PASS | |

**28 / 28 tests passing.**

**Missing test coverage (non-critical):**

| Missing Test | Severity | Notes |
|--------------|----------|-------|
| resolve() with multiple gateway URLs | Low | Verify all URLs are included in OffchainLookup revert |
| resolveWithProof() with signature of length != 65 | Low | OZ ECDSA reverts with ECDSAInvalidSignatureLength |
| resolveWithProof() with empty result bytes | Low | Edge case: gateway returns empty result |
| resolveWithProof() exactly at expiry (block.timestamp == expires) | Low | Verify accepted (not expired) |
| setSigner() to same signer (no-op) | Low | Cosmetic: event emitted with old == new |
| setGatewayURLs() with array containing empty strings | Low | Verify empty strings accepted |
| renounceOwnership() | Low | Inherited from Ownable -- verify it works or is overridden |

These are test coverage gaps, not contract vulnerabilities. The existing 28 tests cover all critical paths including tamper detection for result, extraData, signature, and expiry.

---

## New Findings

### [L-01] `responseTTL` Is Not Enforced On-Chain

**Severity:** Low
**Lines:** 65, 128-132, 164-190
**Category:** Business Logic

**Description:**

The `responseTTL` state variable is stored on-chain (line 65) and can be updated by the owner via `setResponseTTL()` (line 128). However, it is never read by `resolveWithProof()`. The TTL check at line 173 uses only the `expires` field from the gateway response:

```solidity
if (block.timestamp > expires) revert ResponseExpired();
```

The gateway is expected to read `responseTTL` from the contract and set `expires = block.timestamp + responseTTL` when constructing responses. But a misconfigured or compromised gateway can set any `expires` value:
- A very large `expires` (e.g., `type(uint64).max`) would make the response valid for billions of years.
- A `expires` shorter than the intended TTL would cause the response to expire prematurely (no security issue, just a UX issue).

The contract trusts the gateway to set a reasonable `expires` value. Since the gateway also signs the response with the signer key, a gateway setting an unreasonable `expires` is equivalent to a signer compromise (same trust level).

**Impact:** If the signer key is used outside the gateway (e.g., in a compromised application), an attacker could sign responses with very long TTLs that remain valid even after signer rotation. However, this requires signer key compromise, at which point the attacker can sign arbitrary responses regardless.

**Recommendation:**

For defense-in-depth, consider adding an on-chain TTL enforcement check in `resolveWithProof()`:

```solidity
// After the existing TTL check:
if (expires > block.timestamp + responseTTL && responseTTL > 0) {
    revert ResponseTTLExceeded();
}
```

This ensures the gateway cannot set an `expires` value further than `responseTTL` seconds into the future. The `responseTTL > 0` guard preserves the zero-TTL behavior.

Alternatively, accept as-is and document that `responseTTL` is advisory (for gateway consumption only, not enforced on-chain). This is a common pattern in CCIP-Read resolvers.

---

### [L-02] `abi.encodePacked` With Dynamic Types in Signature Hash

**Severity:** Low
**Lines:** 179-182
**Category:** Cryptographic Safety

**Description:**

The inner hash in `resolveWithProof()` uses `abi.encodePacked` with multiple dynamic types:

```solidity
keccak256(
    abi.encodePacked(result, expires, extraData)
)
```

Where `result` is `bytes` (dynamic), `expires` is `uint64` (fixed, 8 bytes), and `extraData` is `bytes` (dynamic).

When `abi.encodePacked` is used with adjacent dynamic types, there is a theoretical collision risk where the boundary between `result` and `extraData` can shift. For example:

- `result = 0x1234`, `extraData = 0x5678` produces the packed encoding `0x1234<expires_8_bytes>5678`
- `result = 0x1234<expires_8_bytes>56`, `extraData = 0x78` produces a different packed encoding

In this contract, the risk is mitigated by the fact that `expires` (uint64, 8 bytes) sits between the two dynamic types, acting as a fixed-size separator. The collision would require the attacker to embed the exact `expires` bytes at the boundary, which constrains the attack significantly.

Furthermore, the attacker would need the signer's private key to produce a valid signature for the colliding hash, making this a theoretical concern only.

**Impact:** Theoretical. No practical exploit path exists because:
1. The `uint64 expires` acts as a partial separator
2. The attacker would need the signer key to exploit any collision
3. The `extraData` is not attacker-controlled (it comes from the contract's `resolve()` function)

**Recommendation:**

For maximum cryptographic safety, use `abi.encode` instead of `abi.encodePacked` for the inner hash:

```solidity
keccak256(
    abi.encode(result, expires, extraData)
)
```

`abi.encode` pads each element to 32-byte boundaries and includes length prefixes for dynamic types, eliminating all collision risk. This requires updating the gateway signing logic to match.

Alternatively, accept as-is with documentation that the collision risk is mitigated by the fixed-size `expires` separator and the signer-key requirement.

---

### [I-01] No Validation of Individual Gateway URL Content

**Severity:** Informational
**Lines:** 97, 109-115
**Category:** Input Validation

**Description:**

Both the constructor and `setGatewayURLs()` validate that the URL array is non-empty, but do not validate individual URL strings. An owner can set:
- Empty strings (`""`) as URLs
- URLs without the required `{sender}` or `{data}` placeholders
- Non-HTTP/HTTPS URLs

**Impact:** None on-chain. The contract simply includes these URLs in the `OffchainLookup` revert data. Invalid URLs will cause the ENS client to fail gracefully (skip the invalid URL and try the next one per ERC-3668). This is an operational issue, not a security issue.

**Recommendation:** Accept as-is. URL validation on-chain would consume significant gas for string operations and the responsibility for correct URLs lies with the contract owner. Document the URL format requirements in the deployment guide.

---

### [I-02] Storage Slot Packing Opportunity Not Used

**Severity:** Informational
**Lines:** 63-65
**Category:** Gas Optimization

**Description:**

`signer` (20 bytes) and `responseTTL` (32 bytes as uint256) occupy two separate storage slots. If `responseTTL` were declared as `uint96` (12 bytes, maximum value ~79 billion seconds or ~2,500 years), both could fit in a single slot:

```solidity
address public signer;       // 20 bytes
uint96 public responseTTL;   // 12 bytes -- packs with signer
```

This would save one storage slot (2,100 gas per cold SLOAD).

**Impact:** Negligible. `resolveWithProof()` reads `signer` but not `responseTTL`, so no gas savings in the hot path. `setResponseTTL()` and `setSigner()` are admin-only functions called rarely. The primary readers of `responseTTL` are off-chain (gateway reads the public getter).

**Recommendation:** Accept as-is. The gas savings are negligible for the contract's usage pattern. Changing to `uint96` adds a minor documentation burden (maximum TTL = 2,500 years).

---

### [I-03] `renounceOwnership()` Is Inherited but Not Overridden

**Severity:** Informational
**Lines:** 52 (Ownable2Step inheritance)
**Category:** Access Control

**Description:**

`Ownable2Step` inherits from `Ownable`, which includes `renounceOwnership()`. Calling this function sets the owner to `address(0)`, permanently locking all admin functions (`setGatewayURLs`, `setSigner`, `setResponseTTL`).

In OpenZeppelin v5.x, `Ownable2Step` does NOT override `renounceOwnership()` -- it only overrides `transferOwnership()` to add the two-step mechanism. This means `renounceOwnership()` bypasses the two-step protection and takes effect immediately.

**Impact:** If the owner accidentally calls `renounceOwnership()`:
- Gateway URLs cannot be updated (if the gateway goes down, resolution stops permanently)
- Signer cannot be rotated (if the signer key is compromised, there is no recovery)
- TTL cannot be changed

This is not exploitable by third parties (only the owner can call it). It is a self-inflicted risk.

**Recommendation:**

Override `renounceOwnership()` to prevent accidental use:

```solidity
/// @notice Disabled — ownership renunciation would permanently lock admin functions
/// @dev Override to prevent accidental lockout
function renounceOwnership() public pure override {
    revert("OmniBazaarResolver: renounce disabled");
}
```

Or, if renunciation is a desired feature for eventual decentralization, document it explicitly and add a confirmation mechanism (e.g., require a specific magic value).

---

## Compliance Summary

| Requirement | Status | Notes |
|-------------|--------|-------|
| NatSpec documentation | PASS | Complete NatSpec on all public/external functions, events, errors, state variables, and constructor parameters. Contract-level NatSpec with deployment instructions. |
| Custom errors (not require strings) | PASS | 5 custom errors defined. No `require()` with strings. |
| Solhint compliance | PASS | Zero contract-specific findings. `solhint-disable-next-line not-rely-on-time` used once with valid justification. |
| Gas optimization | PASS | `calldata` for function parameters, `view`/`pure` where appropriate, custom errors, no redundant storage reads in `resolveWithProof`. |
| Access control | PASS | `onlyOwner` on all admin functions. `Ownable2Step` for safe ownership transfer. |
| Event emission | PASS | All state-changing admin functions emit events with old and new values. |
| Line length (120 chars) | PASS | All lines within 120 characters. |
| Solidity version | PASS | Pinned to `0.8.24`. |
| ERC-3668 compliance | PASS | `OffchainLookup` error signature correct. Callback pattern correct. |
| ENSIP-10 compliance | PASS | `resolve(bytes,bytes)` signature correct. `supportsInterface` returns correct values. |
| EIP-191 signature | PASS | Personal sign prefix correct. OZ ECDSA v5 handles malleability and zero-address. |

---

## Overall Risk Rating

**Risk Level: LOW**

OmniBazaarResolver is a compact, well-designed CCIP-Read resolver that correctly implements ENSIP-10 and ERC-3668. The contract stores no resolution data on-chain, handles no funds, and has a minimal attack surface. The ECDSA signature verification is implemented correctly using OpenZeppelin v5.x, which provides built-in protections against signature malleability and zero-address recovery.

The two Low findings are:
1. **L-01 (unenforced TTL):** The on-chain `responseTTL` is advisory only. The gateway is trusted to set appropriate `expires` values. This is acceptable given that the gateway and signer share the same trust level.
2. **L-02 (encodePacked with dynamic types):** Theoretical collision risk mitigated by the fixed-size `uint64 expires` separator and the signer-key requirement. No practical exploit path.

The three Informational findings are minor improvements (URL validation, storage packing, renounceOwnership override) with no security impact.

**Pre-Mainnet Readiness: READY**

No blocking issues. L-01 and L-02 should be evaluated for defense-in-depth improvements but are not required for deployment. I-03 (`renounceOwnership` override) is recommended as a safety measure.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/ens/OmniBazaarResolver.sol` | 215 | Primary audit target |
| `Coin/test/OmniBazaarResolver.test.js` | 442 | Test coverage verification |
| `Coin/contracts/ens/OmniENS.sol` | 889 | Cross-contract context (not directly referenced by resolver) |
| `Coin/hardhat.config.js` | 234 | Build configuration and network setup |
| `Coin/audit-reports/OmniENS-audit-2026-02-28.md` | -- | Prior ENS-related audit for context |
| `Coin/audit-reports/round6/OmniENS-audit-2026-03-10.md` | -- | Prior ENS-related audit for context |

---

*Generated by Claude Opus 4.6 -- 7-Pass Comprehensive Audit*
*Date: 2026-03-13*
