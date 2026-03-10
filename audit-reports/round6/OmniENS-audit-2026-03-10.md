# Security Audit Report: OmniENS.sol

**Contract:** `contracts/ens/OmniENS.sol`
**Lines:** 889
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-10
**Scope:** Username registration, resolution, transfer, expiration, squatting prevention, access control
**Handles Funds:** No (collects XOM registration fees but does not custody them)
**Previous Audit Fixes Incorporated:** H-01, M-01, M-02, M-03, L-01, L-02, L-03, L-04

---

## Executive Summary

OmniENS is a lightweight, non-upgradeable username registry that maps human-readable usernames to wallet addresses. The contract has been through at least one prior audit round, and the implemented fixes (commit-reveal, fee bounds, CEI pattern, Ownable2Step, zero-address validation) are correct and well-documented. The contract is well-structured and follows Solidity best practices. A small number of low-severity issues remain.

**Overall Risk Assessment: LOW**

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Architecture Review

- **Inheritance:** ReentrancyGuard, Ownable2Step, ERC2771Context -- appropriate choices
- **Token handling:** SafeERC20 used consistently for all XOM transfers
- **Upgradeability:** None (immutable deployment) -- reduces attack surface
- **Meta-transactions:** ERC-2771 support with proper diamond override resolution
- **Fee model:** Pull from user -> split to 3 immutable recipients (70/20/10)

---

## Findings

### [INFO-01] Commit-Reveal Scheme Correctly Implemented

**Status:** PASS

The commit-reveal scheme (H-01 fix) is correctly implemented:
- `commit()` stores `block.timestamp` against a commitment hash
- `register()` calls `_consumeCommitment()` which verifies MIN_COMMITMENT_AGE (1 min) and MAX_COMMITMENT_AGE (24 hours)
- Commitment is deleted after consumption, preventing replay
- `makeCommitment()` helper is provided for off-chain hash calculation

No issues found.

### [INFO-02] Fee Distribution Correctly Implemented

**Status:** PASS

- Fee is calculated proportionally: `(registrationFeePerYear * duration) / 365 days`
- SafeERC20.safeTransferFrom pulls fee from user to contract
- Split: ODDAO gets remainder (avoids dust), staking gets 20%, protocol gets 10%
- Shares sum to exactly BPS (7000 + 2000 + 1000 = 10000)
- Fee bounds enforced: MIN_REGISTRATION_FEE (1 XOM) to MAX_REGISTRATION_FEE (1000 XOM)

No issues found.

### [INFO-03] CEI Pattern Correctly Applied

**Status:** PASS

Both `register()` and `renew()` perform all state changes before the external `_distributeFee()` call (L-04 fix). Combined with `nonReentrant`, this provides double protection against reentrancy.

### [INFO-04] Name Validation is Sound

**Status:** PASS

- Length: 3-32 characters enforced
- Characters: only a-z, 0-9, hyphen (0x2D) allowed
- No leading/trailing hyphens
- Uppercase rejected (case-insensitivity via rejection, not normalization)
- Hash is keccak256 of raw bytes (correct since validation guarantees lowercase)

### [LOW-01] `commit()` Does Not Require Caller Verification

**Severity:** Low
**Location:** Line 319-324

```solidity
function commit(bytes32 commitment) external {
    commitments[commitment] = block.timestamp;
    emit NameCommitted(commitment, _msgSender());
}
```

Anyone can overwrite an existing commitment by submitting the same commitment hash. If Alice commits hash H at time T1, and Bob calls `commit(H)` at time T2 > T1, Alice's commitment is overwritten with T2. This could delay Alice's registration window or reset her MIN_COMMITMENT_AGE timer.

**Impact:** Low. The commitment hash includes a secret, so an attacker would need to know Alice's exact name + address + secret to compute the same hash. In practice, this is infeasible.

**Recommendation:** Consider adding a check `require(commitments[commitment] == 0, "already committed")`, though the practical risk is negligible given the secret component.

### [LOW-02] `transfer()` Expiry Check Uses Off-By-One Pattern

**Severity:** Low
**Location:** Line 405

```solidity
if (block.timestamp > reg.expiresAt - 1) {
    revert NameNotFound(name);
}
```

This is equivalent to `block.timestamp >= reg.expiresAt`. The pattern `expiresAt - 1` is used consistently throughout the contract (lines 405, 524, 544, 563), so it is internally consistent. However, if `expiresAt` were ever 0 (an unregistered name), this would underflow to `type(uint256).max`, but that path is guarded by the `reg.owner != caller` check on line 403 (which would revert for unregistered names since `reg.owner` is `address(0)`).

**Impact:** None in practice due to guard checks. The pattern is consistent.

**Recommendation:** No change needed, but consider using `>=` directly for readability.

### [LOW-03] No Grace Period for Expired Names

**Severity:** Low / Design Observation

When a name expires, any user can immediately register it via the commit-reveal process (1 minute wait). There is no grace period for the previous owner to renew.

**Impact:** Previous owners could lose their names to front-runners if they do not renew before expiry.

**Recommendation:** Consider adding a grace period (e.g., 7 days after expiry) during which only the previous owner can renew. This is a design decision rather than a security vulnerability.

### [LOW-04] `totalRegistrations` Only Increments

**Severity:** Informational
**Location:** Line 373

`totalRegistrations` increments on every registration (including re-registrations of expired names) but never decrements. This counter represents "total registrations ever made" rather than "current active registrations." The NatSpec correctly documents this behavior ("including expired").

**Impact:** None. The counter serves as a historical record and is correctly documented.

### [LOW-05] Reverse Record Not Updated on Name Expiry

**Severity:** Low
**Location:** Lines 536-548

When a name expires, the `reverseRecords` mapping is not automatically cleared. The `reverseResolve()` function handles this gracefully by checking expiry and owner match, but the stale mapping entries remain in storage.

This is cleaned up reactively in `_ensureNameAvailable()` (line 756) when the name is re-registered by someone else. However, if a user has a single expired name, `reverseRecords[user]` still points to that expired name hash, and `reverseResolve()` correctly returns empty string.

**Impact:** None functionally. Minor gas inefficiency from stale storage.

---

## Access Control Review

| Function | Access | Assessment |
|----------|--------|------------|
| `commit()` | Public | Correct -- anyone can commit |
| `register()` | Public + nonReentrant | Correct -- requires valid commitment + fee |
| `transfer()` | Owner of name + nonReentrant | Correct -- checks `reg.owner == caller` |
| `renew()` | Owner of name + nonReentrant | Correct -- checks `reg.owner == caller` |
| `setRegistrationFee()` | onlyOwner | Correct -- bounded by MIN/MAX |
| View functions | Public | Correct -- read-only |

---

## Reentrancy Analysis

- All state-mutating external functions use `nonReentrant` modifier
- CEI pattern followed in `register()` and `renew()` (state changes before `_distributeFee()`)
- `_distributeFee()` uses SafeERC20 which handles non-standard ERC20 tokens
- No ETH handling (no payable functions, no low-level calls)

**Assessment:** No reentrancy risk.

---

## Overflow/Underflow Analysis

- Solidity 0.8.24 provides built-in overflow protection
- Fee calculation `(registrationFeePerYear * duration) / 365 days` -- maximum values: 1000 ether * 365 days = ~3.15e25, well within uint256 range
- `expiresAt - 1` pattern is protected by prior checks ensuring the name exists and is owned

**Assessment:** No overflow risk.

---

## Front-Running Analysis

- Commit-reveal scheme prevents front-running of name registration
- MIN_COMMITMENT_AGE (1 minute) ensures commitment cannot be revealed in the same block
- MAX_COMMITMENT_AGE (24 hours) limits stale commitment window

**Assessment:** Adequately protected.

---

## Conclusion

OmniENS is a well-audited, well-documented contract with appropriate security measures. The prior audit fixes (H-01 through L-04) have been correctly implemented. The remaining findings are low-severity and largely informational. The contract is suitable for mainnet deployment.

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| LOW-01 | Low | `commit()` allows overwrite of existing commitments | Accept Risk |
| LOW-02 | Low | Off-by-one expiry check pattern | Consistent, No Fix Needed |
| LOW-03 | Low | No grace period for expired names | Design Decision |
| LOW-04 | Info | `totalRegistrations` only increments | Documented Behavior |
| LOW-05 | Low | Reverse record not cleared on expiry | Handled Gracefully |
