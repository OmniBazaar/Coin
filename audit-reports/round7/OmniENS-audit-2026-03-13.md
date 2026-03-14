# Security Audit Report: OmniENS.sol (Round 7)

**Contract:** `contracts/ens/OmniENS.sol`
**Lines of Code:** 964
**Solidity Version:** 0.8.24
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-13
**Scope:** Full manual review -- name registration, commit-reveal, transfer, renewal, expiry, system registration, access control, fee handling, ERC-2771 meta-transactions, upgrade safety
**Handles Funds:** No (collects XOM registration fees via `safeTransferFrom` to UnifiedFeeVault; does not custody funds)
**Upgradeable:** No (immutable deployment)
**Previous Audit Rounds:** Round 4 (2026-02-28), Round 6 (2026-03-10)

---

## Executive Summary

OmniENS is a non-upgradeable, lightweight username registry mapping human-readable usernames (3-32 lowercase alphanumeric + hyphen characters) to wallet addresses on Avalanche Subnet-EVM. The contract has been through two prior audit rounds, and all previously identified findings (H-01 commit-reveal, M-01 fee overcharge on capped renewal, M-02 constructor zero-address validation, M-03 reverse record overwrite event, L-01 through L-04) have been correctly remediated and are verified as properly implemented.

This Round 7 audit performs a deep manual review focusing on areas not fully explored in prior rounds: ERC-2771 meta-transaction security, system registration privilege escalation paths, `abi.encodePacked` collision risks in commitment hashing, transfer/renewal edge cases under expiry boundary conditions, and inter-contract integration with UnifiedFeeVault. One medium finding related to `isAvailable()` returning misleading results for system-reserved names is identified. The remaining findings are low severity or informational.

**Overall Risk Assessment: LOW**

---

## Summary of Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | `isAvailable()` returns `true` for expired system-reserved names that cannot be registered | New |
| L-01 | Low | `abi.encodePacked` collision risk in `makeCommitment()` | Accept Risk |
| L-02 | Low | `commit()` permits overwriting existing commitments | Acknowledged (Round 6 LOW-01) |
| L-03 | Low | No grace period for expired names | Acknowledged (Round 6 LOW-03) |
| L-04 | Low | `transfer()` does not check `systemRegistered` flag | New |
| L-05 | Low | `renew()` allows renewal of expired names without re-validation of availability | New |
| I-01 | Info | Self-transfer not guarded | Acknowledged (Round 4 I-02) |
| I-02 | Info | No token rescue function | Acknowledged (Round 4 I-03) |
| I-03 | Info | `totalRegistrations` only increments | Acknowledged (Round 6 LOW-04) |
| I-04 | Info | `systemRenew()` does not validate `additionalDuration` minimum | New |
| I-05 | Info | Event emission after external call in `register()` | New |

---

## Prior Audit Fix Verification

All fixes from Round 4 (2026-02-28) and Round 6 (2026-03-10) are verified as correctly implemented:

| Fix ID | Description | Verification |
|--------|-------------|--------------|
| H-01 | Commit-reveal scheme for registration | PASS -- `commit()` + `_consumeCommitment()` with MIN/MAX age bounds, commitment deletion after use, `makeCommitment()` helper |
| M-01 | Fee overcharge on capped renewal | PASS -- `actualDuration` computed before fee calculation (lines 456-461) |
| M-02 | Constructor zero-address validation | PASS -- Both `_xomToken` and `_feeVault` checked (lines 294-295) |
| M-03 | Reverse record overwrite event | PASS -- `_setReverseRecord()` emits `ReverseRecordOverwritten` for active records (lines 750-769) |
| L-01 | NatSpec corrected for `_nameHash()` | PASS -- Accurately states hashing of raw bytes, case enforced by `_validateName()` |
| L-02 | Ownable2Step | PASS -- Contract inherits `Ownable2Step` (line 115) |
| L-03 | Fee bounds validation | PASS -- MIN/MAX constants enforced in `setRegistrationFee()` (lines 593-598) |
| L-04 | CEI pattern | PASS -- All state changes precede `_distributeFee()` in both `register()` and `renew()` |

---

## Architecture Review

### Inheritance Chain

```
OmniENS
  |-- ReentrancyGuard (OpenZeppelin)
  |-- Ownable2Step -> Ownable -> Context (OpenZeppelin)
  |-- ERC2771Context -> Context (OpenZeppelin)
```

The diamond inheritance on `Context` is resolved correctly via explicit overrides of `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` (lines 850-893), all delegating to `ERC2771Context`.

### State Architecture

- **Registrations:** `mapping(bytes32 => Registration)` -- name hash to owner/registeredAt/expiresAt
- **Reverse records:** `mapping(address => bytes32)` -- address to most recent name hash (one-to-one)
- **Name strings:** `mapping(bytes32 => string)` -- name hash to original string for reverse lookups
- **Commitments:** `mapping(bytes32 => uint256)` -- commit-reveal timestamp tracking
- **System names:** `mapping(bytes32 => bool)` -- names registered via `systemRegister()` are protected even after expiry

### Fee Flow

All fees flow directly from the user to the immutable `feeVault` (UnifiedFeeVault) via `SafeERC20.safeTransferFrom`. The contract never holds XOM. UnifiedFeeVault handles the 70/20/10 split (ODDAO / Staking Pool / Protocol Treasury). This is consistent with the project fee-distribution architecture.

---

## Detailed Findings

### [M-01] `isAvailable()` Returns `true` for Expired System-Reserved Names

**Severity:** Medium
**Location:** Lines 653-662

```solidity
function isAvailable(
    string calldata name
) external view returns (bool) {
    bytes32 nameHash = _nameHash(name);
    Registration storage reg = registrations[nameHash];

    if (reg.owner == address(0)) return true;
    // solhint-disable-next-line not-rely-on-time
    return block.timestamp > reg.expiresAt - 1;
}
```

**Description:**
`isAvailable()` checks only whether a name is unregistered or expired. It does not check `systemRegistered[nameHash]`. When a system-registered name expires, `isAvailable()` returns `true`, but `register()` will revert with `SystemReservedName`. This creates a misleading UX: a user checks availability, sees `true`, commits (paying gas), waits MIN_COMMITMENT_AGE, then gets reverted at registration.

The test suite on line 1045-1050 explicitly documents this discrepancy:
```javascript
it("should still allow isAvailable to return true for expired system name", async function () {
    // isAvailable checks expiry only, not systemRegistered
    // (the protection is in register(), not isAvailable())
```

**Impact:** Users waste gas on commit transactions for names they can never register. Off-chain UIs relying on `isAvailable()` will display incorrect availability, degrading user trust.

**Recommendation:**
Add a `systemRegistered` check to `isAvailable()`:

```solidity
function isAvailable(
    string calldata name
) external view returns (bool) {
    bytes32 nameHash = _nameHash(name);
    Registration storage reg = registrations[nameHash];

    if (reg.owner == address(0) && !systemRegistered[nameHash]) {
        return true;
    }
    if (systemRegistered[nameHash]) return false;
    return block.timestamp > reg.expiresAt - 1;
}
```

Alternatively, provide a separate `isSystemReserved(string name)` view function so UIs can distinguish the two cases.

---

### [L-01] `abi.encodePacked` Collision Risk in `makeCommitment()`

**Severity:** Low
**Location:** Lines 718-720

```solidity
function makeCommitment(
    string calldata name,
    address nameOwner,
    bytes32 secret
) external pure returns (bytes32 commitment) {
    return keccak256(
        abi.encodePacked(name, nameOwner, secret)
    );
}
```

**Description:**
`abi.encodePacked` with a variable-length `string` followed by fixed-length types creates a theoretical collision risk. For example, the name `"ab"` + address `0xCD...` and the name `"abCD"` (if the leading bytes of the address matched) could in theory produce the same packed encoding.

**Impact:** Negligible in practice. The `address` type is 20 bytes and `bytes32` is 32 bytes, both fixed-length. The only variable-length element is `name`, which appears first. Since `name` is validated to be 3-32 lowercase alphanumeric characters (0x61-0x7A, 0x30-0x39, 0x2D), and address bytes contain values outside this range, a collision would require the address to start with bytes that are valid lowercase ASCII, which while possible, is not exploitable because the attacker would also need to know the secret. The actual security of the commitment depends on the secret being unpredictable, not on the hash being collision-free.

**Recommendation:** Consider using `abi.encode` instead of `abi.encodePacked` for defense-in-depth. However, the practical risk is negligible.

---

### [L-02] `commit()` Permits Overwriting Existing Commitments

**Severity:** Low
**Location:** Lines 315-320
**Previously Identified:** Round 6 LOW-01

```solidity
function commit(bytes32 commitment) external {
    commitments[commitment] = block.timestamp;
    emit NameCommitted(commitment, _msgSender());
}
```

**Description:**
Anyone can overwrite an existing commitment by submitting the same commitment hash, resetting the MIN_COMMITMENT_AGE timer. Since the commitment hash includes a secret, an attacker would need to know the victim's name + address + secret, which is infeasible.

**Impact:** Negligible. The secret protects against this attack vector.

**Status:** Accept Risk (unchanged from Round 6).

---

### [L-03] No Grace Period for Expired Names

**Severity:** Low
**Previously Identified:** Round 6 LOW-03

**Description:**
When a name expires, any user can immediately begin the commit-reveal process to re-register it. The previous owner has no grace period for renewal. The commit-reveal process introduces a 1-minute delay, but this provides only minimal protection.

**Impact:** Previous owners could lose their names if they do not renew before expiry. This is mitigated by the fact that the owner can `renew()` at any time before or after expiry (as long as no one else has re-registered).

**Status:** Design decision. System-registered names are protected by the `systemRegistered` flag. For paid registrations, the absence of a grace period is an accepted design choice.

---

### [L-04] `transfer()` Does Not Check `systemRegistered` Flag

**Severity:** Low
**Location:** Lines 386-414

```solidity
function transfer(
    string calldata name,
    address newOwner
) external nonReentrant {
    address caller = _msgSender();

    if (newOwner == address(0)) {
        revert ZeroAddress();
    }

    bytes32 nameHash = _nameHash(name);
    Registration storage reg = registrations[nameHash];

    if (reg.owner != caller) revert NotNameOwner();
    if (block.timestamp > reg.expiresAt - 1) {
        revert NameNotFound(name);
    }

    // No check for systemRegistered[nameHash]
    ...
    reg.owner = newOwner;
```

**Description:**
A system-registered name can be transferred by its current owner to any address. Once transferred, the `systemRegistered` flag remains `true` for the name hash, but the new owner is a regular user who may not understand the system name implications. The name remains protected from re-registration after expiry (since `systemRegistered` is never cleared), but the new owner:
1. Cannot be renewed via regular `renew()` (they must pay fees)
2. Can only be renewed via `systemRenew()` by the contract owner

This is not necessarily a bug -- it may be intentional that the contract owner (validator network) can reassign system names. However, if a system name is transferred to a user and then expires, no one except the contract owner can renew it, and no regular user can register it.

**Impact:** Low. The contract owner controls system registration and can always `systemRegister()` the name again. The transferred user retains the name until expiry and can transfer it further. No funds are at risk.

**Recommendation:** Consider whether `transfer()` should be blocked for system-registered names, or whether a `systemTransfer()` function should be provided that also updates the owner in the system's records.

---

### [L-05] `renew()` Allows Renewal of Expired Names Without Re-Validation of Availability

**Severity:** Low
**Location:** Lines 427-476

```solidity
function renew(
    string calldata name,
    uint256 additionalDuration
) external nonReentrant {
    address caller = _msgSender();
    ...
    bytes32 nameHash = _nameHash(name);
    Registration storage reg = registrations[nameHash];

    if (reg.owner != caller) revert NotNameOwner();
    // No expiry check -- allows renewal after expiry
```

**Description:**
`renew()` checks that `reg.owner == caller` but does not check whether the name has expired. This is by design (documented in the NatSpec and tested), allowing the original owner to renew an expired name without going through commit-reveal again. However, this creates a race condition: if an expired name has not been re-registered, both the old owner's `renew()` and a new user's `register()` (after commit-reveal) could potentially execute.

The race is safe because:
1. `register()` calls `_ensureNameAvailable()`, which checks `block.timestamp < reg.expiresAt` -- this would pass for an expired name.
2. If the old owner renews first, the new expiry is set, and the new user's `register()` would revert with `NameTaken`.
3. If the new user registers first (via commit-reveal), the `registrations[nameHash].owner` changes, and the old owner's `renew()` reverts with `NotNameOwner`.

**Impact:** No actual vulnerability. Both paths are mutually exclusive due to the atomic nature of transactions. The old owner's ability to renew without commit-reveal is a valid UX improvement. However, it does create a scenario where the old owner can front-run a new user's registration if they see the commit transaction in the mempool.

**Recommendation:** Accept as design decision. Document clearly that expired names can be renewed by the original owner without commit-reveal, creating a de facto implicit grace period.

---

### [I-01] Self-Transfer Not Guarded

**Severity:** Informational
**Location:** Lines 386-414
**Previously Identified:** Round 4 I-02

`transfer(name, msg.sender)` is allowed and wastes gas. The reverse record is cleared and re-set to the same value. No functional impact.

---

### [I-02] No Token Rescue Function

**Severity:** Informational
**Previously Identified:** Round 4 I-03

If ERC-20 tokens other than XOM are accidentally sent to the contract address, they are permanently locked. Since the contract has no `payable` functions and never holds XOM (fees go directly to UnifiedFeeVault), the risk is minimal.

---

### [I-03] `totalRegistrations` Only Increments

**Severity:** Informational
**Location:** Line 369
**Previously Identified:** Round 6 LOW-04

The counter represents "total registrations ever" not "currently active." NatSpec correctly documents this behavior. No fix needed.

---

### [I-04] `systemRenew()` Does Not Validate `additionalDuration` Minimum

**Severity:** Informational
**Location:** Lines 558-582

```solidity
function systemRenew(
    string calldata name,
    uint256 additionalDuration
) external onlyOwner nonReentrant {
    ...
    uint256 newExpiry = base + additionalDuration;
    // No MIN_DURATION check on additionalDuration
```

**Description:**
Unlike `renew()` (which requires `additionalDuration >= MIN_DURATION`), `systemRenew()` accepts any value including 0 or 1 second. Since this is an `onlyOwner` function and the owner is the trusted validator network, this is not a security concern. However, a `systemRenew("name", 0)` call would be a no-op that wastes gas.

**Impact:** None. The owner is trusted and can choose any duration.

---

### [I-05] Event Emission After External Call in `register()`

**Severity:** Informational
**Location:** Lines 371-378

```solidity
// L-04: External call AFTER state changes (CEI pattern)
if (fee > 0) {
    _distributeFee(caller, fee);
}

emit NameRegistered(
    name, caller, expiresAt, fee
);
```

**Description:**
The `NameRegistered` event is emitted after the external `_distributeFee()` call. While this does not create a reentrancy vulnerability (protected by `nonReentrant`), strictly speaking the CEI pattern would emit the event before the external call. In practice, this ordering is acceptable because:
1. `nonReentrant` prevents re-entry
2. The event data is derived from local variables, not post-call state
3. Off-chain consumers reading events from transaction receipts see the final state regardless of emission order

**Impact:** None. The event correctly reflects the registration state.

---

## Access Control Review

| Function | Access | Modifier(s) | Assessment |
|----------|--------|-------------|------------|
| `commit()` | Public | None | PASS -- Anyone can commit; secret protects hash |
| `register()` | Public | `nonReentrant` | PASS -- Requires valid commitment + fee payment |
| `transfer()` | Name owner | `nonReentrant` | PASS -- `reg.owner == caller` check |
| `renew()` | Name owner | `nonReentrant` | PASS -- `reg.owner == caller` check |
| `systemRegister()` | Contract owner | `onlyOwner`, `nonReentrant` | PASS -- Privileged but owner-only |
| `systemRenew()` | Contract owner | `onlyOwner`, `nonReentrant` | PASS -- Privileged but owner-only |
| `setRegistrationFee()` | Contract owner | `onlyOwner` | PASS -- Bounded by MIN/MAX |
| `resolve()` | Public | `view` | PASS -- Read-only |
| `reverseResolve()` | Public | `view` | PASS -- Read-only |
| `isAvailable()` | Public | `view` | See M-01 -- does not check systemRegistered |
| `getRegistration()` | Public | `view` | PASS -- Read-only |
| `calculateFee()` | Public | `view` | PASS -- Read-only |
| `makeCommitment()` | Public | `pure` | PASS -- Read-only helper |

---

## Reentrancy Analysis

- All state-mutating external functions use `nonReentrant`
- CEI pattern followed in `register()` and `renew()` -- state changes before `_distributeFee()`
- `_distributeFee()` uses `SafeERC20.safeTransferFrom` (pull pattern from user to vault)
- No ETH handling (no `payable`, no `receive()`, no `fallback()`)
- No low-level `call`, `delegatecall`, or `staticcall`

**Assessment:** No reentrancy risk.

---

## Overflow/Underflow Analysis

- Solidity 0.8.24 provides built-in overflow/underflow protection
- Fee calculation: `(registrationFeePerYear * duration) / 365 days` -- max values: `1000 ether * 365 days = 3.1536e25`, well within `uint256`
- `expiresAt - 1` pattern (lines 401, 622, 642, 661): underflow is protected by prior checks ensuring the name exists (`reg.owner != address(0)`) and is owned. For unregistered names, `expiresAt` is 0, but `reg.owner` is `address(0)`, so the `reg.owner != caller` check reverts first.
- `base + additionalDuration` in `renew()`: `block.timestamp` (~1.7e9 currently) + `MAX_DURATION` (~3.15e7) is well within `uint256`. Even in 2100, timestamps will be ~4.1e9, still safe.

**Assessment:** No overflow/underflow risk.

---

## Front-Running Analysis

- **Registration:** Protected by commit-reveal scheme with MIN_COMMITMENT_AGE (1 minute) and MAX_COMMITMENT_AGE (24 hours). The commitment hash includes a secret, preventing hash prediction.
- **Renewal:** Not front-runnable -- only the name owner can renew.
- **Transfer:** Not front-runnable -- only the name owner can transfer.
- **System operations:** Not front-runnable -- only the contract owner can call.
- **Fee changes:** `setRegistrationFee()` takes effect immediately. A pending `register()` transaction could be affected by a fee change in the same block. Impact is bounded by MIN/MAX fee constants (1-1000 XOM).

**Assessment:** Adequately protected.

---

## ERC-2771 Meta-Transaction Security Review

### Override Correctness

The contract correctly resolves the diamond inheritance between `Context` (via `Ownable2Step`) and `ERC2771Context`:

```solidity
function _msgSender() internal view override(Context, ERC2771Context)
    returns (address) {
    return ERC2771Context._msgSender();
}
```

All three overrides (`_msgSender`, `_msgData`, `_contextSuffixLength`) delegate to `ERC2771Context`, which is the correct resolution.

### Trusted Forwarder Configuration

The `trustedForwarder_` is set in the constructor and is immutable (via `ERC2771Context`). Setting it to `address(0)` disables meta-transactions entirely. The test suite deploys with `ethers.ZeroAddress`, confirming this path works.

### Security Implications

If a trusted forwarder is configured:
- The forwarder can spoof `_msgSender()` by appending an address to calldata
- This means the forwarder can register names on behalf of any user (if they also control the commitment/secret)
- The forwarder can transfer names by spoofing the owner's address
- The forwarder can renew names by spoofing the owner's address

This is the expected behavior for ERC-2771 and is a trust assumption on the forwarder contract. The contract owner should only set a trusted forwarder that has been audited and is known to correctly relay transactions.

**Note:** `onlyOwner` functions (`systemRegister`, `systemRenew`, `setRegistrationFee`) use `_msgSender()` via the `Ownable` modifier chain. If the forwarder is compromised, it could potentially call these functions as if it were the owner. This is the standard ERC-2771 trust model.

**Assessment:** Correctly implemented. The trust assumption on the forwarder is standard and documented.

---

## System Registration Privilege Analysis

### Owner Powers

The contract owner (validator network) can:
1. **Register names for users for free** (`systemRegister`) -- bypasses commit-reveal and fees
2. **Renew system names for free** (`systemRenew`) -- bypasses fees
3. **Change registration fee** (`setRegistrationFee`) -- bounded 1-1000 XOM
4. **Transfer ownership** (`transferOwnership` + `acceptOwnership`) -- two-step via Ownable2Step

The contract owner CANNOT:
- Modify or delete existing non-system registrations
- Transfer names they do not own
- Withdraw any funds from the contract (it holds none)
- Change the XOM token address or fee vault address (immutable)
- Pause the contract (no pause functionality)
- Upgrade the contract (non-upgradeable)

### `systemRegistered` Flag Permanence

Once `systemRegistered[nameHash]` is set to `true`, it is never set back to `false`. This means:
- A system-registered name is permanently protected from regular registration, even after expiry
- The only way to re-register a system name is through `systemRegister()` (owner only)
- There is no mechanism to "release" a system name back to the public pool

This is a design decision, not a vulnerability. If the validator network wishes to release a system name, they would need to deploy a new contract version.

### Centralization Risk

**Single-key maximum damage: 3/10**

The owner can:
- Set fee to 1000 XOM/year (maximum bound), increasing costs for new registrations
- System-register names to block regular users from registering them
- System-renew names to keep them permanently reserved

The owner cannot affect existing registrations, drain funds, or prevent name resolution.

---

## Edge Case Analysis

### 1. Name Hash Collision

Two different valid names could theoretically produce the same `keccak256` hash. The probability is astronomically low (~1/2^256) and is not a practical concern.

### 2. Zero-Duration Registration

`_validateDuration()` enforces `duration >= MIN_DURATION` (30 days), preventing zero-duration registrations.

### 3. Maximum Expiry Overflow

`block.timestamp + MAX_DURATION` (365 days in seconds = 31,536,000). Even at year 2100 timestamps (~4.1 billion), this is far from `uint256` overflow.

### 4. Re-Registration Race Between Old Owner Renewal and New User Registration

As analyzed in L-05, both `renew()` and `register()` are mutually exclusive for the same name hash due to transactional atomicity. No double-spend or double-registration is possible.

### 5. Transfer to Self

As noted in I-01, `transfer(name, msg.sender)` is a no-op that wastes gas. It clears and immediately re-sets the reverse record. No harm besides wasted gas.

### 6. System Name Transferred to Regular User

If the owner calls `systemRegister("alice", user1, ...)` and then user1 calls `transfer("alice", user2)`, the name remains `systemRegistered`. After expiry, neither user2 nor any other regular user can re-register it. Only the owner can re-register it via `systemRegister()`. This is analyzed in L-04.

### 7. Name Validation Boundary: Hyphen-Only Names

The name `"---"` (three hyphens) would pass the character validation (hyphen is allowed) but would be rejected by the leading/trailing hyphen check (lines 932). The name `"a-b"` is valid. The name `"a--b"` is valid (consecutive hyphens in the middle are allowed).

### 8. Empty Name

`bytes("")` has length 0, which is caught by `len < MIN_NAME_LENGTH` (3).

---

## Gas Optimization Notes

These are observations, not findings:

1. **`_validateName()` loop:** The character validation loop iterates over each byte. For maximum-length names (32 chars), this costs ~32 * ~200 gas = ~6,400 gas. This is acceptable.

2. **String storage in `nameStrings`:** Storing the full name string on every registration is expensive (~20,000 gas for a new slot + ~5,000 per 32-byte chunk). This is necessary for reverse resolution and is an accepted cost.

3. **`totalRegistrations` counter:** A single SSTORE (~5,000 gas for non-zero to non-zero). Acceptable.

---

## Integration Review: OmniENS <-> UnifiedFeeVault

- OmniENS sends 100% of registration fees directly to `feeVault` (immutable address)
- UnifiedFeeVault handles the 70/20/10 split internally
- OmniENS uses `safeTransferFrom(payer, feeVault, totalFee)` -- pull pattern from user
- The user must have approved OmniENS to spend their XOM tokens
- If the user has insufficient balance or approval, `safeTransferFrom` reverts cleanly

**Assessment:** Integration is correct. No funds are trapped in OmniENS.

---

## Integration Review: OmniENS <-> OmniBazaarResolver

- `OmniBazaarResolver` is deployed on Ethereum mainnet as an ENSIP-10 wildcard resolver
- It redirects `*.omnibazaar.eth` lookups to an off-chain CCIP-Read gateway
- The gateway reads OmniENS state on Avalanche Subnet-EVM and returns signed responses
- `OmniBazaarResolver` verifies the ECDSA signature and TTL before returning data
- The two contracts are deployed on different chains and do not interact directly on-chain

**Assessment:** No cross-contract vulnerability. The trust boundary is at the gateway signer.

---

## Solhint Results

```
0 errors, 0 warnings (after inline disable comments)
```

All `not-rely-on-time` warnings are appropriately suppressed with `solhint-disable-line` comments. The time-dependent operations (expiry checks, commitment age) are inherent to the contract's business logic and require `block.timestamp`.

---

## Test Coverage Assessment

The test suite (`test/OmniENS.test.js`, 1148 lines) covers 13 test categories with comprehensive coverage:

1. Initialization (8 tests)
2. Name Validation (8 tests)
3. Commit-Reveal (8 tests)
4. Registration (8 tests)
5. Transfer (6 tests)
6. Renewal (8 tests)
7. Resolution (7 tests)
8. Availability (3 tests)
9. Admin Functions (9 tests)
10. Edge Cases (5 tests)
11. System Registration (12 tests)
12. System Name Protection (5 tests)
13. System Renewal (6 tests)

**Not covered in tests:**
- ERC-2771 meta-transaction flow (trusted forwarder is set to `address(0)` in tests)
- `transfer()` of a system-registered name (L-04 scenario)
- `renew()` after ownership transfer
- `isAvailable()` for system-reserved expired names returning `true` (M-01 -- the test documents this as intentional but it is a UX issue)

---

## Conclusion

OmniENS is a well-designed, well-audited contract that has been iteratively improved across three audit rounds. All previously identified findings have been correctly remediated. The contract follows Solidity best practices: ReentrancyGuard on all mutating functions, CEI pattern, SafeERC20, Ownable2Step, custom errors, comprehensive NatSpec, and bounded admin parameters.

The single medium finding (M-01: misleading `isAvailable()` for system-reserved names) is a UX concern that can be addressed either in the contract or in the front-end. The low-severity findings are accepted risks or design decisions that do not pose security threats. No critical or high-severity findings were identified.

**The contract is suitable for mainnet deployment.**

---

## Appendix: Access Control Map

```
Owner (Deployer -> Ownable2Step)
  |
  |-- systemRegister(name, owner, duration)    [onlyOwner, nonReentrant]
  |-- systemRenew(name, additionalDuration)    [onlyOwner, nonReentrant]
  |-- setRegistrationFee(newFee)               [onlyOwner, bounded]
  |-- transferOwnership(newOwner)              [onlyOwner, 2-step]
  |-- renounceOwnership()                     [onlyOwner]
  |
Name Owner (Registration.owner)
  |
  |-- transfer(name, newOwner)                 [nonReentrant]
  |-- renew(name, additionalDuration)          [nonReentrant]
  |
Public
  |
  |-- commit(commitment)                       [no guard]
  |-- register(name, duration, secret)         [nonReentrant]
  |-- resolve(name)                            [view]
  |-- reverseResolve(addr)                     [view]
  |-- isAvailable(name)                        [view]
  |-- getRegistration(name)                    [view]
  |-- calculateFee(duration)                   [view]
  |-- makeCommitment(name, owner, secret)      [pure]
```

---

*Generated by Claude Opus 4.6 -- Manual Security Audit*
*Round 7 of ongoing security review process*
*Contract: OmniENS.sol (964 lines, Solidity 0.8.24)*
