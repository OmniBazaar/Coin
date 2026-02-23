# Security Audit Report: OmniRegistration

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniRegistration.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 2403
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (manages registration state, KYC, and bonus eligibility — no token custody)

## Executive Summary

OmniRegistration is a UUPS-upgradeable contract managing user registration, KYC tier progression, Sybil resistance (phone/email/social hash uniqueness), bonus eligibility tracking, and transaction volume limits. It supports two registration paths: validator-assisted (requires phone + email) and trustless (EIP-712 signed proofs, email only). KYC tiers 2-4 use either multi-attestation (3-of-N threshold) or trustless verification (ID, address, selfie, video).

The audit found **1 Critical vulnerability**: `markWelcomeBonusClaimed()` and `markFirstSaleBonusClaimed()` have **zero access control** — any external caller can permanently mark any user's bonus as claimed, denying up to 8.2B XOM in bonuses across all users. The contract explicitly acknowledges this gap: "We'll add proper access control when integrating." Additionally, `adminUnregister()` performs incomplete state cleanup, leaving ghost KYC data and blocked re-registration, and the contract maintains two independent KYC tier tracking systems that disagree. Both audit agents independently confirmed the access control finding as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 2 |
| Medium | 8 |
| Low | 5 |
| Informational | 3 |

## Findings

### [C-01] Missing Access Control on markWelcomeBonusClaimed() and markFirstSaleBonusClaimed()

**Severity:** Critical
**Lines:** 1917, 1933
**Agents:** Both

**Description:**

Both functions are `external` with **no access control modifier**. The NatSpec states "Only callable by OmniRewardManager contract" but line 1919 explicitly admits: `// We'll add proper access control when integrating`. This was never implemented.

Any external caller can permanently mark any registered user's bonus as claimed:

```solidity
// Line 1917 — completely unprotected
function markWelcomeBonusClaimed(address user) external {
    Registration storage reg = registrations[user];
    // ...
    reg.welcomeBonusClaimed = true;
}
```

The `BonusAlreadyClaimed` check makes the attack **irreversible** — once set to `true`, no function exists to reset it.

**Exploit Scenario:**
```
1. Attacker writes a simple script that calls markWelcomeBonusClaimed(user) for every registered address
2. Each user's welcomeBonusClaimed flag is permanently set to true
3. When OmniRewardManager later distributes bonuses, canClaimWelcomeBonus() returns false
4. All users are permanently denied their welcome bonuses (up to 10,000 XOM each)
5. Same attack applies to markFirstSaleBonusClaimed()
6. Total exposure: 6.2B XOM (welcome) + 2.0B XOM (first sale) = 8.2B XOM (49% of total supply)
7. Cost: gas only
```

**Recommendation:** Add a dedicated role:
```solidity
bytes32 public constant BONUS_MARKER_ROLE = keccak256("BONUS_MARKER_ROLE");

function markWelcomeBonusClaimed(address user) external onlyRole(BONUS_MARKER_ROLE) {
    // ... existing logic
}

function markFirstSaleBonusClaimed(address user) external onlyRole(BONUS_MARKER_ROLE) {
    // ... existing logic
}
```
Grant `BONUS_MARKER_ROLE` to the OmniRewardManager contract address after deployment.

---

### [H-01] Incomplete State Cleanup in adminUnregister()

**Severity:** High
**Lines:** 2060-2089, 2096-2129
**Agents:** Both

**Description:**

`adminUnregister()` clears `registrations[user]` (struct delete), `usedEmailHashes`, and `usedPhoneHashes`. However, it does NOT clear:

- `userSocialHashes[user]` / `usedSocialHashes[hash]` — social verification data
- `userEmailHashes[user]` — separate email hash mapping
- `userIDHashes[user]` / `usedIDHashes[hash]` — ID verification data
- `userAddressHashes[user]` / `usedAddressHashes[hash]` — address verification data
- `selfieVerified[user]` — selfie verification status
- `videoSessionHashes[user]` — video session data
- `kycTier1CompletedAt[user]` through `kycTier4CompletedAt[user]` — tier timestamps
- `userKYCProvider[user]`, `userCountries[user]` — KYC provider and country
- `referralCounts[user]`, `userVolumes[user]` — activity tracking

**Impact:**
1. **Blocked re-registration:** Unregistered users cannot re-register with the same social account, ID, or address documents because `usedSocialHashes`, `usedIDHashes`, and `usedAddressHashes` still mark them as taken.
2. **Ghost KYC state:** `getUserKYCTier(user)` still returns the old tier because `kycTierXCompletedAt` timestamps persist. An unregistered user retains KYC privileges. If a new user registers at the same address, they inherit the old user's KYC tier.
3. **Inflated referral counts:** The referrer's `referralCounts` is never decremented (see M-08).

`adminUnregisterBatch()` has identical incomplete cleanup.

**Recommendation:** Clear all associated mappings in `adminUnregister()`:
```solidity
bytes32 socialHash = userSocialHashes[user];
if (socialHash != bytes32(0)) { usedSocialHashes[socialHash] = false; delete userSocialHashes[user]; }
delete userEmailHashes[user];
bytes32 idHash = userIDHashes[user];
if (idHash != bytes32(0)) { usedIDHashes[idHash] = false; delete userIDHashes[user]; }
bytes32 addrHash = userAddressHashes[user];
if (addrHash != bytes32(0)) { usedAddressHashes[addrHash] = false; delete userAddressHashes[user]; }
delete selfieVerified[user]; delete videoSessionHashes[user];
delete kycTier1CompletedAt[user]; delete kycTier2CompletedAt[user];
delete kycTier3CompletedAt[user]; delete kycTier4CompletedAt[user];
delete userKYCProvider[user]; delete userCountries[user];
delete userVolumes[user];
```

---

### [H-02] Missing __gap Storage Variable for UUPS Upgrades

**Severity:** High
**Lines:** End of contract (no gap present)
**Agents:** Both

**Description:**

OmniRegistration is UUPS-upgradeable with 24+ storage variables (mappings, structs, scalars). It has already undergone at least one upgrade cycle (evidenced by `reinitialize()` at line 627 and "Added v2" comments on transaction volume tracking). Every other UUPS contract in the codebase has a storage gap (OmniCore: `[49]`, PrivateOmniCoin: `[46]`, OmniPrivacyBridge: `[44]`). OmniRegistration is the only one missing it.

**Impact:** Future upgrades adding state variables could corrupt existing mapping storage slots, silently corrupting registration data, KYC tiers, or Sybil protection hashes.

**Recommendation:** Add at the end of state variables:
```solidity
uint256[50] private __gap;
```

---

### [M-01] Dual KYC Tier Tracking Creates Inconsistent State

**Severity:** Medium
**Lines:** 98, 146, 209, 215, 224, 1978, 2271
**Agents:** Both

**Description:**

The contract maintains two independent KYC tier sources of truth:

1. **`Registration.kycTier`** (line 98) — set by `registerUser()`, `selfRegisterTrustless()`, and `attestKYC()`. Used by `canClaimWelcomeBonus()` (line 1978).
2. **`kycTierXCompletedAt` mappings** (lines 146, 209, 215, 224) — set by the trustless verification flow. Used by `getUserKYCTier()` (line 2271), which is used by `checkTransactionLimit()`.

These are never synchronized:
- `attestKYC()` updates `Registration.kycTier` but NOT `kycTierXCompletedAt`
- `_checkAndUpdateKycTier1()` updates `kycTier1CompletedAt` but NOT `Registration.kycTier`
- Same desync for Tiers 2-4

**Example:** User at Tier 1 gets attested to Tier 3 via `attestKYC()`:
- `Registration.kycTier` = 3 → `canClaimWelcomeBonus()` returns eligible
- `kycTier3CompletedAt` = 0 → `getUserKYCTier()` returns 1
- `checkTransactionLimit()` enforces Tier 1 limits despite Tier 3 status

**Recommendation:** Unify the two systems. Either deprecate `Registration.kycTier` and use `getUserKYCTier()` everywhere, or synchronize both paths by having `attestKYC()` set `kycTierXCompletedAt` timestamps and having the trustless path update `Registration.kycTier`.

---

### [M-02] Trustless Registration Grants KYC Tier 1 Without Phone or Social Verification

**Severity:** Medium
**Lines:** 888, 704
**Agents:** Both

**Description:**

`registerUser()` correctly requires both `phoneHash` and `emailHash`. `_selfRegisterTrustlessInternal()` only requires `emailHash` (phone is `bytes32(0)`). Both set `kycTier: 1`. However, KYC Tier 1 is defined as requiring email + phone + social media verification.

`canClaimWelcomeBonus()` checks `reg.kycTier >= 1`, which returns `true` for trustless-registered users who only verified email. Meanwhile, `getUserKYCTier()` (via `kycTier1CompletedAt`) returns 0, creating the inconsistency described in M-01.

**Impact:** Trustless-registered users gain Tier 1 privileges (5x higher daily limits, bonus eligibility) with only email verification.

**Recommendation:** Set `kycTier: 0` in the trustless path. Only promote to Tier 1 when `_checkAndUpdateKycTier1()` confirms all three requirements are met.

---

### [M-03] Sybil Resistance Weakened in Trustless Registration Path

**Severity:** Medium
**Lines:** 832
**Agents:** Both

**Description:**

The validator-assisted path requires both `phoneHash` and `emailHash` uniqueness — two independent Sybil resistance factors. The trustless path only requires `emailHash`. Creating disposable email addresses is trivial (free, unlimited, programmatic). Phone numbers are the primary Sybil resistance mechanism.

Combined with M-02 (Tier 1 granted immediately), an attacker can create unlimited accounts with disposable emails, each eligible for welcome bonuses.

**Impact:** An attacker with a `trustedVerificationKey` signing oracle can create Sybil accounts at scale, each claiming up to 10,000 XOM in welcome bonuses.

**Recommendation:** Require phone verification proof as an additional parameter in `selfRegisterTrustless()`, or make bonus eligibility contingent on `kycTier1CompletedAt != 0` (requires phone + social).

---

### [M-04] Transaction Limits Not Enforced On-Chain

**Severity:** Medium
**Lines:** 2183, 2230
**Agent:** Agent B

**Description:**

`checkTransactionLimit()` is a `view` function that returns `(bool allowed, string reason)` but never reverts. `recordTransaction()` unconditionally records volume without calling `checkTransactionLimit()`. Enforcement relies entirely on the caller (marketplace/DEX contract) checking limits before recording.

**Impact:** If any caller with `TRANSACTION_RECORDER_ROLE` skips the limit check (bug, upgrade oversight), transaction limits are silently bypassed. A Tier 0 user with a $500 daily limit could process unlimited volume.

**Recommendation:** Enforce limits inside `recordTransaction()`:
```solidity
function recordTransaction(address user, uint256 amount) external onlyRole(TRANSACTION_RECORDER_ROLE) {
    (bool allowed, string memory reason) = this.checkTransactionLimit(user, amount);
    if (!allowed) revert TransactionLimitExceeded(reason);
    // ... existing logic
}
```

---

### [M-05] Single trustedVerificationKey Is Single Point of Failure

**Severity:** Medium
**Lines:** 133
**Agent:** Agent A

**Description:**

The entire trustless verification system depends on a single `trustedVerificationKey`. If compromised, an attacker can forge proofs for any verification type for any user. There is no multi-key scheme, no key rotation with grace period, and no way to invalidate specific proofs without changing the key (which invalidates ALL pending proofs).

**Impact:** Compromised key enables mass Sybil registration with full KYC Tier 1, each claiming welcome bonuses.

**Recommendation:** Implement key rotation with a grace period or M-of-N multi-key verification.

---

### [M-06] reinitialize() Has No Access Control

**Severity:** Medium
**Lines:** 627
**Agent:** Agent A

**Description:**

`reinitialize(uint64 version)` has no `onlyRole` modifier. While OpenZeppelin's `reinitializer(version)` prevents re-execution for the same version, anyone can call it with the next version number, consuming version slots. The function body only sets values conditionally (zero-checks), limiting damage, but an attacker can front-run a legitimate admin reinitialize call and consume the target version number.

**Recommendation:** Add `onlyRole(DEFAULT_ADMIN_ROLE)`:
```solidity
function reinitialize(uint64 version) public reinitializer(version) onlyRole(DEFAULT_ADMIN_ROLE) {
```

---

### [M-07] No Timelock on UUPS Upgrade Authorization

**Severity:** Medium
**Lines:** 2400
**Agent:** Agent A

**Description:**

`_authorizeUpgrade()` requires only `DEFAULT_ADMIN_ROLE`. A single compromised admin key can immediately upgrade to a malicious implementation, replacing the entire registration system. For a contract managing KYC data and bonus eligibility for a platform handling real money, there is no timelock, multi-sig, or governance vote.

**Recommendation:** Add a timelock delay (48-72h) or use OpenZeppelin's `TimelockController` as the admin.

---

### [M-08] Referral Count Not Decremented on Unregistration

**Severity:** Medium
**Lines:** 2060, 2096 (cf. 719, 904)
**Agent:** Agent B

**Description:**

When a user is registered with a referrer, `referralCounts[referrer]` is incremented. When that user is unregistered via `adminUnregister()`, the referrer's count is never decremented. The referrer retains credit for a referral that no longer exists.

**Impact:** Inflated referral counts affect "Activity as Disseminator" participation score (0-10 points). A register-unregister loop inflates referral counts indefinitely.

**Recommendation:**
```solidity
if (reg.referrer != address(0) && referralCounts[reg.referrer] > 0) {
    --referralCounts[reg.referrer];
}
```

---

### [L-01] attestKYC() Allows Tier Skipping

**Severity:** Low
**Lines:** 929-935
**Agents:** Both

**Description:**

`attestKYC()` checks `tier < 2 || tier > 4` and `tier <= registrations[user].kycTier` but does NOT verify the user has completed the previous tier. A user at Tier 1 can be attested directly to Tier 4, skipping Tiers 2 and 3. The trustless path correctly enforces sequential progression; the attestation path does not.

**Impact:** Three colluding KYC attestors can instantly grant any registered user full Tier 4 without ID, address, selfie, or video verification.

**Recommendation:** Add sequential enforcement:
```solidity
if (tier == 2 && kycTier1CompletedAt[user] == 0) revert PreviousTierRequired();
if (tier == 3 && kycTier2CompletedAt[user] == 0) revert PreviousTierRequired();
if (tier == 4 && kycTier3CompletedAt[user] == 0) revert PreviousTierRequired();
```

---

### [L-02] abi.encodePacked Collision Risk in attestKYC Key

**Severity:** Low
**Lines:** 942, 2001
**Agent:** Agent A

**Description:**

The attestation key uses `keccak256(abi.encodePacked(user, tier))`. While `address` (20 bytes) and `uint8` (1 byte) are fixed-size types (no classic dynamic-type collision), `abi.encode` is the standard best practice for hashing multiple parameters and eliminates any ambiguity.

**Recommendation:** Use `abi.encode` instead of `abi.encodePacked`.

---

### [L-03] Unbounded Loop in attestKYC() Duplicate Check

**Severity:** Low
**Lines:** 946-952
**Agent:** Agent A

**Description:**

The function iterates over `kycAttestations[attestationKey]` to check for duplicate attestors. While practically bounded by `KYC_ATTESTATION_THRESHOLD` (3), the array has no hard cap and could theoretically grow if multiple attestors call in the same block before the tier update takes effect.

**Recommendation:** Add early return: `if (attestors.length >= KYC_ATTESTATION_THRESHOLD) revert InvalidKYCTier();`

---

### [L-04] adminUnregisterBatch() Unbounded Array Input

**Severity:** Low
**Lines:** 2096-2129
**Agent:** Agent A

**Description:**

No maximum size limit on the `address[] calldata users` array. A legitimate admin trying to batch-unregister thousands of users may exceed block gas limits unpredictably.

**Recommendation:** Add `MAX_BATCH_SIZE = 100` check.

---

### [L-05] Missing Zero-Address Check for user in registerUser()

**Severity:** Low
**Lines:** 666
**Agent:** Agent A

**Description:**

The `user` parameter is not validated against `address(0)`. Registering `address(0)` permanently consumes phone/email hash reservations for an unusable address.

**Recommendation:** Add `if (user == address(0)) revert ZeroAddress();`

---

### [I-01] KYC Attestation Array Never Cleaned After Tier Upgrade

**Severity:** Informational
**Lines:** 960-964
**Agent:** Agent A

**Description:**

When `attestKYC()` reaches the threshold and upgrades the tier, the `kycAttestations[attestationKey]` array persists in storage indefinitely. `getKYCAttestationCount()` returns stale data.

**Recommendation:** `delete kycAttestations[attestationKey]` after tier upgrade.

---

### [I-02] Month/Year Calculation Imprecision in Volume Tracking

**Severity:** Informational
**Lines:** 2193-2194, 2236-2237
**Agent:** Agent B

**Description:**

Month uses `block.timestamp / (30 * 86400)` and year uses `block.timestamp / (365 * 86400)`. These approximations don't align with calendar months (28-31 days) or leap years. Transaction limits may reset 1-2 days early or late at period boundaries.

**Recommendation:** Document as intentional simplification. Common pattern in DeFi.

---

### [I-03] No Relay Functions for Address and Selfie Verification

**Severity:** Informational
**Lines:** 1474, 1545
**Agent:** Agent B

**Description:**

Relay functions (`*For()` variants) exist for phone, social, ID, video, third-party KYC, and registration. However, `submitAddressVerification()` and `submitSelfieVerification()` have no relay variants. Users without gas cannot complete Tier 2 via the trustless path.

**Recommendation:** Add `submitAddressVerificationFor()` and `submitSelfieVerificationFor()`.

---

## Static Analysis Results

**Solhint:** 0 errors, 86 warnings
- 14 custom-errors (should use custom errors instead of require with strings)
- 12 gas-indexed-events
- 11 gas-strict-inequalities
- 10 not-rely-on-time (accepted — KYC timestamps are a business requirement)
- 9 function-max-lines (large verification functions)
- 8 max-line-length
- 6 immutable-vars-naming
- 5 gas-increment-by-one
- 4 ordering
- 3 explicit-types
- 2 no-empty-blocks
- 2 other warnings

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 27 raw findings → 19 unique)
- Pass 6: Report generation

## Conclusion

OmniRegistration has **one Critical vulnerability that must be fixed immediately**:

1. **Missing access control on bonus marking (C-01)** is trivially exploitable and permanently denies up to 8.2B XOM in bonuses (49% of total supply). The contract itself acknowledges the gap. The fix is a single-line `onlyRole()` modifier on each function.

2. **Incomplete adminUnregister cleanup (H-01)** makes the function operationally broken for its stated purpose — users cannot cleanly re-register after unregistration, and ghost KYC data persists.

3. **Missing storage gap (H-02)** is a ticking time bomb — the contract has already undergone one upgrade, and the next upgrade adding storage variables risks silent data corruption.

4. **Dual KYC tier tracking (M-01)** is the root cause of several findings. The `Registration.kycTier` field and `kycTierXCompletedAt` mappings give different answers for the same user. Unifying these resolves M-01, M-02, L-01, and part of M-03 simultaneously.

The contract has comprehensive functionality (registration, KYC, Sybil resistance, volume tracking, bonus eligibility) but several design decisions were left incomplete ("We'll add proper access control when integrating"). All such TODO items must be resolved before deployment.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
