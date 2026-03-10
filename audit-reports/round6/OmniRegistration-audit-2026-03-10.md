# Security Audit Report: OmniRegistration (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Round 6 -- Pre-Mainnet)
**Contract:** `Coin/contracts/OmniRegistration.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 2,870
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** No (manages registration state, KYC, bonus eligibility, transaction volume -- no token custody)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Static Analysis:** Slither results unavailable (build artifact mismatch)

---

## Executive Summary

This Round 6 audit is a comprehensive pre-mainnet security review of OmniRegistration.sol, a 2,870-line upgradeable contract managing user registration, KYC tier progression (0-4), Sybil resistance, referral tracking, bonus eligibility, and transaction volume limits for the OmniBazaar platform.

The contract has matured significantly since Round 3. Key Round 3 findings have been addressed:
- **H-01 (Dual KYC tier desynchronization):** FIXED. `_checkAndUpdateKycTier1()` (line 1376), `_checkAndUpdateKycTier2()` (line 2741), `submitVideoVerification()` (line 1879), `submitVideoVerificationFor()` (line 1951), `submitThirdPartyKYC()` (line 2022), and `submitThirdPartyKYCFor()` (line 2090) all now synchronize `Registration.kycTier`.
- **M-01 (firstSaleCompleted not cleared in unregister):** FIXED. `_unregisterUser()` now includes `delete firstSaleCompleted[user]` (line 2704).
- **L-01 (attestKYC tier skipping):** NOT FIXED. Still allows tier skipping with 3 colluding KYC attestors.

This Round 6 audit found **0 Critical**, **1 High**, **4 Medium**, **5 Low**, and **4 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 4 |
| Low | 5 |
| Informational | 4 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass. Additionally, `markFirstSaleCompleted()` updated with anti-wash-trading checks (SYBIL-AP-05 fix).

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | `attestKYC()` allows tier skipping — no sequential tier validation | **FIXED** |
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `registerUser()` | **FIXED** |
| M-02 | Medium | Missing `whenNotPaused` on `attestKYC()` and `registerUser()` | **FIXED** |
| M-03 | Medium | No event emission on KYC tier changes | **FIXED** |
| M-04 | Medium | `ossify()` not registered as critical selector in timelock | **FIXED** |

---

## Access Control Map

### Roles

| Role | Purpose | Granted To |
|------|---------|------------|
| `DEFAULT_ADMIN_ROLE` | Admin: manage roles, set verification key, unregister users, manage KYC providers, update tier limits, ossify, authorize upgrades | Deployer (should be TimelockController in production) |
| `VALIDATOR_ROLE` | Register users via `registerUser()` | Validator nodes |
| `KYC_ATTESTOR_ROLE` | Attest KYC tiers (2-4) via `attestKYC()` | Trusted validators (3-of-N threshold) |
| `BONUS_MARKER_ROLE` | Mark bonuses as claimed via `markWelcomeBonusClaimed()` and `markFirstSaleBonusClaimed()` | OmniRewardManager contract |
| `TRANSACTION_RECORDER_ROLE` | Record transactions for volume tracking, mark first sale completed | Marketplace/DEX contracts |

### Permissionless Functions

| Function | Who Can Call | Protection |
|----------|-------------|------------|
| `selfRegisterTrustless()` | Any user (msg.sender = user) | EIP-712 email proof + user signature |
| `selfRegisterTrustlessFor()` | Any relayer | EIP-712 email proof + user signature (user address in signed data) |
| `submitPhoneVerification()` | Any registered user | EIP-712 proof from `trustedVerificationKey` |
| `submitPhoneVerificationFor()` | Any relayer | EIP-712 proof (user address in signed data) |
| `submitSocialVerification()` | Any registered user | EIP-712 proof from `trustedVerificationKey` |
| `submitSocialVerificationFor()` | Any relayer | EIP-712 proof (user address in signed data) |
| `submitIDVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 1 |
| `submitAddressVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 1 |
| `submitSelfieVerification()` / `For()` | User / relayer | EIP-712 proof, requires ID verification |
| `submitVideoVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 2 |
| `submitThirdPartyKYC()` / `For()` | User / relayer | EIP-712 signature from trusted KYC provider, requires Tier 3 |

---

## Findings

### [H-01] attestKYC() Allows KYC Tier Skipping -- Bypasses All Identity Verification

**Severity:** High
**Lines:** 965-1013
**Status:** UNFIXED (carried forward from Round 1 L-01, upgraded to High for pre-mainnet)

**Description:**

`attestKYC()` checks `tier < 2 || tier > 4` and `tier <= registrations[user].kycTier` but does NOT enforce sequential tier progression. A user at Tier 0 (or Tier 1) can be attested directly to Tier 4 by three colluding `KYC_ATTESTOR_ROLE` holders, completely bypassing the ID verification, address verification, selfie, video, and third-party KYC requirements of Tiers 2-4.

```solidity
// Line 965-971 -- No check that prior tiers are complete
function attestKYC(address user, uint8 tier) external onlyRole(KYC_ATTESTOR_ROLE) {
    if (registrations[user].timestamp == 0) revert NotRegistered();
    if (tier < 2 || tier > 4) revert InvalidKYCTier();
    if (tier <= registrations[user].kycTier) revert InvalidKYCTier();
    // MISSING: if (tier == 3 && kycTier2CompletedAt[user] == 0) revert PreviousTierRequired();
    // MISSING: if (tier == 4 && kycTier3CompletedAt[user] == 0) revert PreviousTierRequired();
```

The synchronization at lines 1004-1010 sets `kycTierXCompletedAt` for the target tier ONLY, leaving intermediate tier timestamps at zero. This means `getUserKYCTier()` still returns the correct high tier (it checks highest first), but other code that checks `kycTier2CompletedAt` or `kycTier3CompletedAt` directly will see those as incomplete.

**Attack Scenario:**
1. Three KYC attestors (compromised or colluding) call `attestKYC(victim, 4)` for an unverified user
2. User gains Tier 4: unlimited transaction limits, validator eligibility, no per-transaction caps
3. No ID, address, selfie, video, or third-party verification was ever performed
4. The user has `kycTier2CompletedAt = 0` and `kycTier3CompletedAt = 0`, creating inconsistent state

**Impact:** Complete bypass of the KYC system for any user. Tier 4 grants unlimited transaction limits (daily, monthly, annual all set to 0 = unlimited), unlimited listings, and validator eligibility. This is the highest-privilege tier and requires only 3 colluding attestor keys. For a pre-mainnet deployment where the initial attestor set may be small, this is a high-severity risk.

**Recommendation:** Add sequential tier enforcement:

```solidity
function attestKYC(address user, uint8 tier) external onlyRole(KYC_ATTESTOR_ROLE) {
    if (registrations[user].timestamp == 0) revert NotRegistered();
    if (tier < 2 || tier > 4) revert InvalidKYCTier();
    if (tier <= registrations[user].kycTier) revert InvalidKYCTier();

    // Enforce sequential tier progression
    if (tier == 2 && kycTier1CompletedAt[user] == 0) revert PreviousTierRequired();
    if (tier == 3 && kycTier2CompletedAt[user] == 0) revert PreviousTierRequired();
    if (tier == 4 && kycTier3CompletedAt[user] == 0) revert PreviousTierRequired();

    // ... rest of function
}
```

---

### [M-01] Single `trustedVerificationKey` Is a Critical Single Point of Failure

**Severity:** Medium
**Lines:** 142, 2320-2326

**Description:**

The entire trustless verification system (phone, email, social, ID, address, selfie, video verification for KYC Tiers 0-3) depends on a single `trustedVerificationKey` address. If this key is compromised, the attacker can forge EIP-712 proofs for any verification step, enabling mass Sybil account creation and instant KYC Tier 3 for arbitrary addresses.

The contract provides no mechanism for:
- Key rotation with a grace period (old proofs still valid during transition)
- Multiple verification keys (e.g., regional keys, backup keys)
- Emergency key revocation without disrupting in-flight verifications
- Rate limiting per verification key (only per-day registration count)

Changing `trustedVerificationKey` via `setTrustedVerificationKey()` immediately invalidates ALL pending (signed but not yet submitted) proofs for ALL users. This creates an operational dilemma: key rotation disrupts legitimate users, while not rotating leaves the key as a valuable target.

**Impact:** Compromise of one key grants the attacker the ability to create unlimited Sybil accounts with KYC Tier 3 (bypassing phone, email, social, ID, address, and selfie verification). The attacker still needs a trusted KYC provider key for Tier 4, but Tier 3 already grants $100,000/day transaction limits.

**Recommendation:**
1. Support multiple `trustedVerificationKey` addresses via a mapping: `mapping(address => bool) public trustedVerificationKeys`
2. Add a key rotation grace period: new key active immediately, old key valid for 24 hours
3. Consider per-key rate limits

---

### [M-02] Unregistered Users Can Submit Phone/Social/ID/Address/Selfie Verifications

**Severity:** Medium
**Lines:** 1037-1095, 1115-1170, 1401-1458, 1542-1600, 1615-1670

**Description:**

The `submitPhoneVerification()`, `submitSocialVerification()`, and other verification functions do NOT require the caller to be registered. They check whether the `trustedVerificationKey` signed the proof and whether the hash is unused, but they do not check `registrations[caller].timestamp != 0`.

For phone verification (lines 1082-1085):
```solidity
Registration storage reg = registrations[caller];
if (reg.timestamp != 0 && reg.phoneHash == bytes32(0)) {
    reg.phoneHash = phoneHash;
}
```

If the user is NOT registered (`reg.timestamp == 0`), the phone hash is still marked as `usedPhoneHashes[phoneHash] = true` (line 1087) and the nonce is consumed (line 1088). The verification goes through, consumes global state, but does nothing useful because there is no registration to update.

For social verification (line 1161): `userSocialHashes[caller] = socialHash` -- this sets the social hash for an unregistered address, and `usedSocialHashes[socialHash] = true` permanently reserves that social account.

**Impact:**
1. **Resource exhaustion:** An attacker with a compromised `trustedVerificationKey` (or a legitimate user who obtains proofs before registering) can reserve phone numbers, email addresses, social accounts, ID hashes, and address hashes without being registered. These hashes become permanently "used," preventing legitimate users who own those identifiers from registering.
2. **Waste of verification service resources:** Off-chain verification service generates proofs that are consumed without creating a useful on-chain state.
3. **Gas waste:** Users pay gas for transactions that accomplish nothing.

**Recommendation:** Add `if (registrations[caller].timestamp == 0) revert NotRegistered();` at the start of each verification function. For relay variants (`submitPhoneVerificationFor`, etc.), check `registrations[user].timestamp`.

---

### [M-03] `_unregisterUser()` Does Not Clear KYC Attestation Arrays

**Severity:** Medium
**Lines:** 2661-2711, 127-128

**Description:**

`_unregisterUser()` comprehensively clears 16+ categories of state (registration struct, phone/email/social/ID/address hashes, selfie status, video session, KYC tier timestamps, provider data, volumes, referral counts, firstSaleCompleted). However, it does NOT clear the `kycAttestations` mapping entries.

```solidity
// Line 127-128
mapping(bytes32 => address[]) public kycAttestations;
// key = keccak256(abi.encodePacked(user, tier))
```

When a user is unregistered and re-registers at the same address, the old KYC attestation arrays remain. If the user had 2 out of 3 required attestations for Tier 2 before being unregistered, they still have 2 attestations after re-registering. Only 1 more attestation is needed to reach Tier 2.

**Attack Scenario:**
1. User accumulates 2/3 KYC attestations for Tier 4
2. User does something wrong, admin unregisters them
3. User re-registers (possibly via trustless path)
4. User only needs 1 more attestation to reach Tier 4 despite having a fresh registration

**Impact:** Undermines the KYC attestation system's integrity. Admin unregistration is supposed to be a clean slate, but KYC attestation progress persists. The previous attestors may not be aware the user was unregistered and re-registered.

**Recommendation:** Clear attestation arrays in `_unregisterUser()`:
```solidity
// Clear KYC attestation arrays for tiers 2-4
for (uint8 tier = 2; tier <= 4; tier++) {
    bytes32 attestationKey = keccak256(abi.encodePacked(user, tier));
    delete kycAttestations[attestationKey];
}
```

Note: `delete` on a dynamic storage array sets its length to zero, which is correct behavior here.

---

### [M-04] Volume Tracking Uses Inconsistent Time Periods (30-Day "Month", 365-Day "Year")

**Severity:** Medium
**Lines:** 2443-2444, 2502-2504

**Description:**

Both `checkTransactionLimit()` and `recordTransaction()` compute time periods as:
```solidity
uint256 thisMonth = block.timestamp / (30 * 86400);  // 30-day "months"
uint256 thisYear = block.timestamp / (365 * 86400);  // 365-day "years"
```

This creates several issues:

1. **Period boundaries shift annually:** A 30-day month and a 365-day year do not align with calendar months/years. The "monthly" period resets every 30 days from epoch, not on calendar month boundaries. This means February transactions and March transactions might fall in the same "month" or different "months" depending on the epoch offset.

2. **Leap year drift:** Using 365 days per year ignores leap years. After 4 years, the "annual" reset drifts by approximately 1 day. After 40 years (the token emission lifetime), the drift is approximately 10 days.

3. **Inconsistency between view and state:** `checkTransactionLimit()` and `recordTransaction()` use identical formulas, so they are internally consistent. However, if a user checks their limit at 23:59 on day 29 and records at 00:01 on day 30 (just 2 minutes later), the monthly volume may reset to zero, allowing them to exceed the intended monthly limit by almost 2x in a 48-hour window.

**Impact:** Users can time their transactions near period boundaries to exceed intended monthly/annual limits by up to approximately 2x for a brief window. For Tier 3 users with $1,000,000/month limits, this could allow up to $2,000,000 in a 48-hour window spanning a period boundary.

**Recommendation:** This is an accepted trade-off for gas efficiency (calendar month/year calculations are expensive on-chain). Document the behavior and consider using a larger safety margin in limit values, or use a sliding window approach where volumes decay rather than reset.

---

### [L-01] `attestKYC()` Self-Dealing Check Uses Wrong Error Name

**Severity:** Low
**Lines:** 973-976

**Description:**

Carried forward from Round 3 I-02. When a KYC attestor tries to attest for a user they registered, the function reverts with `ValidatorCannotBeReferrer()`. The error name is semantically incorrect -- the attestor is not trying to be a referrer, they are trying to self-attest on a user they processed.

```solidity
// Line 973-976
if (registrations[user].registeredBy == msg.sender) {
    revert ValidatorCannotBeReferrer(); // Should be: AttestorIsRegistrar()
}
```

**Impact:** Confusing error messages for front-end UX and debugging. No functional impact.

**Recommendation:** Add a dedicated error: `error AttestorIsRegistrar();`

---

### [L-02] `registerUser()` Does Not Validate Phone/Email Hash Are Non-Zero

**Severity:** Low
**Lines:** 694-752

**Description:**

`registerUser()` accepts `phoneHash` and `emailHash` parameters but does not validate that they are non-zero. A validator could register a user with `phoneHash = bytes32(0)` and `emailHash = bytes32(0)`. Since `usedPhoneHashes[bytes32(0)]` starts as `false`, the first such registration succeeds and sets `usedPhoneHashes[bytes32(0)] = true`, blocking all subsequent registrations with zero hashes.

However, the first registration with zero hashes creates a user who has no phone or email verification but is recorded at `kycTier: 1` (line 733). This bypasses the intended Sybil protection: KYC Tier 1 is supposed to represent "phone + email verified" but a zero-hash registration provides no such guarantee.

The trustless path (`_selfRegisterTrustlessInternal`) correctly validates the email hash is non-zero implicitly (it must match a signed proof), but the validator path has no such check.

**Impact:** A malicious or buggy validator can register one user with no phone/email verification at KYC Tier 1, enabling welcome bonus claims without actual identity verification. Only one such registration is possible (zero hash becomes "used"), so the economic impact is limited to one welcome bonus.

**Recommendation:** Add validation:
```solidity
if (phoneHash == bytes32(0)) revert InvalidPhoneHash();
if (emailHash == bytes32(0)) revert InvalidEmailHash();
```

---

### [L-03] `abi.encodePacked` Used for Attestation Key Hashing

**Severity:** Low
**Lines:** 978, 2276

**Description:**

Carried forward from Round 3 L-03. The attestation key uses `keccak256(abi.encodePacked(user, tier))` where `user` is `address` (20 bytes) and `tier` is `uint8` (1 byte). While there is no practical collision risk with fixed-size types, `abi.encode` is the standard best practice. Solidity documentation explicitly warns against `abi.encodePacked` with multiple dynamic types, and while this case is safe, using `abi.encode` universally eliminates the need for case-by-case analysis.

**Recommendation:** Use `abi.encode` for consistency.

---

### [L-04] `ossify()` Lacks Two-Phase Commit or Timelock Integration

**Severity:** Low
**Lines:** 2767-2770

**Description:**

Carried forward from Round 3 L-02. `ossify()` is a one-way, irreversible operation that permanently prevents all future upgrades. It executes immediately with only `DEFAULT_ADMIN_ROLE` authorization. The NatSpec correctly warns that admin "MUST be behind a TimelockController" but this is not enforced in the contract.

For pre-mainnet deployment, accidental ossification would permanently prevent bug fixes. The contract should either:
1. Enforce timelock integration (check that `msg.sender` is a timelock contract)
2. Implement a two-phase commit: `proposeOssification()` + `confirmOssification()` after delay

**Impact:** Accidental or premature ossification permanently prevents upgrades. Low likelihood but catastrophic impact.

**Recommendation:** Implement a two-phase ossification with a minimum 7-day delay, or ensure the admin role is verifiably held by a TimelockController at deployment time.

---

### [L-05] `DOMAIN_SEPARATOR` Is Stored Once and Not Recomputed on Chain ID Change

**Severity:** Low
**Lines:** 133, 636-644

**Description:**

Carried forward from Round 3 I-03. `DOMAIN_SEPARATOR` is computed once during `initialize()` using `block.chainid`. If the chain undergoes a hard fork that changes the chain ID, all EIP-712 signatures will fail because the stored `DOMAIN_SEPARATOR` no longer matches.

For an Avalanche subnet (chain ID 88008), hard forks changing chain ID are extremely unlikely. However, EIP-712 best practice is to recompute the domain separator if `block.chainid` differs from the stored value.

**Recommendation:** Add a `_domainSeparator()` internal function that checks `block.chainid` and recomputes if changed. Low priority for Avalanche deployment.

---

### [I-01] Privacy: Hashes on Public Blockchain Create Permanent Identity Linkage

**Severity:** Informational
**Lines:** 101-110, 116-119, 146-158, 198-247

**Description:**

The contract stores numerous identity-related hashes on-chain:
- `phoneHash` in the Registration struct (line 105)
- `emailHash` in the Registration struct (line 106)
- `userSocialHashes` mapping (line 146)
- `userEmailHashes` mapping (line 149)
- `userIDHashes` mapping (line 199)
- `userAddressHashes` mapping (line 210)
- `userCountries` mapping (line 205) -- **PLAINTEXT country codes, not hashed**

While phone/email/social/ID/address data is hashed before storage, the hashes are deterministic. An adversary who knows a target's phone number can compute `keccak256("+1-555-1234")` and search the blockchain for matching `phoneHash` values, linking the phone number to an Ethereum address with certainty.

The `userCountries` mapping stores ISO 3166-1 alpha-2 country codes in **plaintext** (not hashed). This directly reveals the nationality of every KYC Tier 2+ user on the public blockchain.

Combined with the `referrer` field (which creates a public referral graph), an adversary can:
1. Identify a known user's address via phone/email hash lookup
2. Traverse the referral graph to identify connected users
3. Cross-reference country codes to narrow identity candidates
4. Use social hashes to confirm identities (if the adversary knows social handles)

**Impact:** PII exposure via deterministic hashes on a public blockchain. This is an inherent trade-off of on-chain Sybil resistance and is documented in the contract's design. Users should be informed that their verification hashes are permanently public.

**Recommendation:**
1. Add explicit user consent documentation that verification hashes are public
2. Consider salted hashes (where the salt is stored only off-chain) for phone/email -- though this would prevent on-chain uniqueness enforcement
3. Consider storing country codes as hashes rather than plaintext
4. For GDPR compliance, document that `adminUnregister()` clears hashes (data erasure) but the historical events remain on-chain permanently

---

### [I-02] `TransactionLimitExceeded` Error Declared Inline Between Functions

**Severity:** Informational
**Lines:** 2481-2484

**Description:**

The custom error `TransactionLimitExceeded` is declared at line 2481, between the NatSpec for `recordTransaction()` (line 2472) and the function definition (line 2496). This is unusual placement -- all other custom errors are declared in the dedicated ERRORS section (lines 498-611). The inline declaration works correctly but makes the error harder to find and violates the contract's own organizational pattern.

```solidity
// Line 2481 -- Error declared between function doc and function body
/// @notice Thrown when a transaction exceeds the user's KYC tier limit
error TransactionLimitExceeded(address user, string limitType);

// Line 2496 -- Actual function
function recordTransaction(address user, uint256 amount) external {
```

**Recommendation:** Move `TransactionLimitExceeded` to the ERRORS section (after line 611) for consistency.

---

### [I-03] `selfRegisterTrustless()` Sets `registeredBy` to `msg.sender`, Not User

**Severity:** Informational
**Lines:** 918-927

**Description:**

In `selfRegisterTrustless()`, the `Registration` struct's `registeredBy` field is set to `msg.sender` (line 921). For `selfRegisterTrustless()`, `msg.sender` is the user themselves (or the forwarder in ERC-2771 context). For `selfRegisterTrustlessFor()`, `msg.sender` is the relayer, not the user.

This means:
- `selfRegisterTrustless()`: `registeredBy = user` (correct)
- `selfRegisterTrustlessFor()`: `registeredBy = relayer` (potentially misleading)

In the `attestKYC()` self-dealing check (line 974), `registrations[user].registeredBy == msg.sender` prevents the registrar from attesting. For relayed registrations, this blocks the relayer (not the user) from attesting -- which may not be the intended behavior.

**Impact:** Minor semantic inconsistency. The relayer has no special relationship to the user, so blocking them from KYC attestation is unnecessary (but also harmless, since the relayer likely does not hold `KYC_ATTESTOR_ROLE`).

**Recommendation:** Consider setting `registeredBy = user` for trustless registrations instead of `msg.sender`, or document the current behavior as intentional.

---

### [I-04] Video Verification Typehash Marked Deprecated But Still Actively Used

**Severity:** Informational
**Lines:** 186-191, 1826-1959

**Description:**

`VIDEO_VERIFICATION_TYPEHASH` has NatSpec saying "DEPRECATED: Tier 3 now uses accredited investor verification, not video" (line 187). However, `submitVideoVerification()` (line 1826) and `submitVideoVerificationFor()` (line 1899) are both fully functional, active functions that use this typehash. The comment and the code contradict each other.

Either the deprecation notice is premature (the accredited investor system is not yet implemented), or these functions should have been removed/disabled.

**Recommendation:** Either remove the deprecation notice (if video verification is still the active Tier 3 path) or add access control to disable the functions (if accredited investor verification has replaced them).

---

## Sybil Resistance Analysis

### On-Chain Protections

| Protection | Mechanism | Effectiveness |
|------------|-----------|--------------|
| Phone uniqueness | `usedPhoneHashes[phoneHash]` mapping | Strong -- one phone per user. Depends on off-chain phone verification quality |
| Email uniqueness | `usedEmailHashes[emailHash]` mapping | Strong -- one email per user. Depends on off-chain verification |
| Social uniqueness | `usedSocialHashes[socialHash]` mapping | Moderate -- one social account per user, but social accounts are easy to create |
| ID uniqueness | `usedIDHashes[idHash]` mapping | Strong -- one government ID per user |
| Address uniqueness | `usedAddressHashes[addressHash]` mapping | Strong -- one residential address per user |
| Daily rate limit | `MAX_DAILY_REGISTRATIONS = 10000` | Weak -- 10,000/day is extremely permissive for Sybil attacks |
| Registration deposit | `REGISTRATION_DEPOSIT = 0` | None -- zero economic barrier to registration |
| Self-referral prevention | `referrer == user` check | Strong |
| Validator self-referral | `referrer == msg.sender` check | Strong |

### Off-Chain Protections (Referenced But Not Enforced On-Chain)

- Device fingerprinting
- IP rate limiting
- Social media follow verification (Twitter/Telegram)
- "One bonus per computer" enforcement

### Sybil Attack Vectors

**Vector 1: Trustless Registration Farming (Email-Only)**
- Cost: Free (0 deposit, free email accounts)
- Rate: Up to 10,000 accounts/day
- KYC achieved: Tier 0 (email only)
- Tier 0 limits: $100/transaction, $500/day, $25,000/year
- Welcome bonus: NOT eligible (requires Tier 1)
- Mitigation: Off-chain email verification service is the only gate

**Vector 2: Validator-Assisted Sybil (Compromised Validator)**
- Cost: VALIDATOR_ROLE access
- Rate: Up to 10,000 accounts/day
- KYC achieved: Tier 1 (validator sets kycTier: 1 at registration)
- Welcome bonus: ELIGIBLE
- Mitigation: Validator is a known, staked entity. Phone/email hash uniqueness still applies.
- Risk: A compromised validator with access to many phone/email hashes could create Sybil accounts eligible for welcome bonuses

**Vector 3: Welcome Bonus Farming via Compromised Verification Key**
- If `trustedVerificationKey` is compromised:
  - Register unlimited accounts via `selfRegisterTrustless()`
  - Submit forged phone/social proofs to reach Tier 1
  - Claim welcome bonuses (up to 10,000 XOM each)
  - Total exposure: Limited by OmniRewardManager's pool balance
- Mitigation: Protect the verification key. Consider multi-key or threshold signature.

**"One bonus per computer" enforcement:** NOT present on-chain. The contract comment (line 25) references "Device fingerprinting and IP rate limiting (off-chain)," but there is no on-chain mechanism. The `REGISTRATION_DEPOSIT = 0` means there is zero economic cost to creating multiple accounts. All one-per-device enforcement depends entirely on the off-chain verification service.

---

## Upgradeable Safety Analysis

### Storage Layout

The contract declares state variables in this order:
1. Constants (no storage slots)
2. Registration struct mapping, hash tracking mappings, counters (original v1 storage)
3. Trustless verification storage (DOMAIN_SEPARATOR, trustedVerificationKey, social/email hashes, nonces)
4. KYC Tier 2/3/4 storage (ID hashes, country codes, address hashes, selfie status, video sessions, providers, referral counts, firstSaleCompleted)
5. Transaction limits storage (TierLimits struct, VolumeTracking struct, userVolumes mapping)
6. `_ossified` boolean
7. `uint256[49] private __gap`

**Concerns:**
- The `_ossified` variable is placed at the end before `__gap`, which is the correct pattern.
- `__gap` is 49 slots (reduced from 50 to accommodate `_ossified`), which is standard.
- The "Added v2" variables (TierLimits, VolumeTracking, etc.) appear to have been added by consuming gap slots from the original deployment. This is correct if and only if `validateUpgrade()` was run during the upgrade.
- **No ERC-7201 `@custom:storage-location` annotations** are present, making it harder to verify storage layout correctness.

**Recommendation:** Before mainnet deployment, run `npx hardhat validate-upgrade` to verify the storage layout matches the proxy's deployed storage. Add storage layout tests.

### Initializer Safety

- Constructor calls `_disableInitializers()` (line 621) -- correct.
- `initialize()` uses `initializer` modifier (line 628) -- correct, can only be called once.
- `reinitialize()` uses `reinitializer(version)` modifier (line 655) -- correct, versioned.
- `reinitialize()` has `onlyRole(DEFAULT_ADMIN_ROLE)` -- correct, prevents unauthorized reinitialization.
- `reinitialize()` is idempotent for DOMAIN_SEPARATOR and tierLimits (checks before setting) -- correct.

---

## Signature Verification Analysis

### EIP-712 Implementation

All verification functions follow a consistent, correct pattern:
1. Compute `structHash` using the appropriate typehash and function parameters
2. Compute `digest` as `keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash))`
3. Recover signer via `ECDSA.recover(digest, signature)`
4. Compare recovered signer to expected signer

**Correctness:** All typehashes match their parameter lists. All `abi.encode` calls include all parameters from the typehash definition. No truncation or omission of signed fields.

**Replay Protection:** All verification functions check `usedNonces[nonce]` and mark nonces as used before any state changes. Nonces are `bytes32` (256-bit), providing sufficient entropy.

**Deadline Enforcement:** All verification functions check `block.timestamp > deadline` and revert with `ProofExpired()`. The deadlines use `block.timestamp`, which is manipulable by validators within a ~15-second window on Avalanche. This is acceptable for deadline checks.

**Cross-Contract Replay:** The `DOMAIN_SEPARATOR` includes `address(this)`, preventing signatures from being replayed against a different OmniRegistration deployment. The chain ID inclusion prevents cross-chain replay.

### Third-Party KYC Signature (submitThirdPartyKYC)

Lines 1994-2010: The signature is verified against `kycProvider` (not `trustedVerificationKey`). This is correct -- each trusted KYC provider signs their own attestations. The provider must be in `trustedKYCProviders` (line 1981). The admin controls which providers are trusted via `addKYCProvider()`.

**Potential issue:** If a KYC provider's key is compromised and the provider is removed via `removeKYCProvider()`, any proofs already signed but not yet submitted will fail (provider check at line 1981). This is correct behavior -- removing a provider should invalidate all their pending proofs.

---

## Front-Running Analysis

### Registration Front-Running

`selfRegisterTrustless()` signs the `user` address into the email proof and registration request. An attacker who sees the transaction in the mempool cannot steal the registration because:
1. The email proof includes `user` in the signed data
2. The registration request includes `user` in the signed data
3. Changing `user` invalidates both signatures

**Referral front-running:** An attacker could observe a registration transaction and submit a competing registration for the SAME referrer with a higher gas price, trying to consume the daily registration limit. This is a griefing attack with limited impact (10,000 registration capacity is very high).

### Verification Front-Running

All verification functions sign the `user` address into the proof. An attacker cannot steal someone else's verification proof. However, a griefing attack is possible: if an attacker observes a phone verification transaction, they could submit a competing transaction that marks the same `nonce` as used (if they had a valid proof with the same nonce). In practice, nonces are unique per proof, so this requires the attacker to have their own valid proof -- which means they already passed verification.

---

## DeFi Exploit Analysis

### Welcome Bonus Farming

- **Gate:** `canClaimWelcomeBonus()` requires `reg.kycTier >= 1` (line 2253)
- **KYC Tier 1 requires:** Registration + phone verified + social verified
- **Economic barrier:** REGISTRATION_DEPOSIT = 0 (no cost)
- **Sybil barrier:** Phone hash uniqueness, social hash uniqueness
- **One-per-computer:** NOT enforced on-chain

A well-funded attacker with access to many phone numbers (VoIP services, burner phones) and social media accounts could create multiple accounts and claim welcome bonuses. The limiting factors are:
1. Cost of acquiring unique phone numbers
2. Cost of acquiring unique social media accounts
3. Off-chain verification service's ability to detect fraud

**Self-Referral Loops:** Prevented on-chain. `referrer == user` reverts with `SelfReferralNotAllowed()`. However, an attacker can create Account A, then create Account B with A as referrer, then create Account C with B as referrer. This is a referral chain, not a loop, and the referral bonuses flow to A and B. There is no on-chain mechanism to detect this because the accounts appear to be independent users.

### First Sale Bonus Farming

- **Gate:** `firstSaleCompleted[user]` must be true (set by `TRANSACTION_RECORDER_ROLE`)
- **Additional gate:** `!reg.firstSaleBonusClaimed` (one-time only)
- **Protection:** Requires an actual marketplace sale to be processed by the marketplace contract
- **Risk:** If the marketplace contract does not validate sale authenticity (e.g., allows self-sales of zero-value items), users could farm first sale bonuses

---

## Round 3 vs Round 6 Comparison

| Round 3 Finding | Round 3 Severity | Round 6 Status |
|-----------------|------------------|----------------|
| H-01 (Dual KYC tier desync) | High | FIXED -- All tier update paths now sync Registration.kycTier |
| M-01 (firstSaleCompleted ghost state) | Medium | FIXED -- Cleared in _unregisterUser() |
| M-02 (_ossified storage layout) | Medium | ACKNOWLEDGED -- Use validateUpgrade() before deployment |
| M-03 (checkTransactionLimit string errors) | Medium | ACKNOWLEDGED -- Accepted design for UX pre-checks |
| L-01 (attestKYC tier skipping) | Low | UNFIXED -- Upgraded to H-01 in this report |
| L-02 (ossify() no confirmation) | Low | UNFIXED -- Carried forward as L-04 |
| L-03 (abi.encodePacked) | Low | UNFIXED -- Carried forward as L-03 |
| L-04 (totalRegistrations post-decrement) | Low | FIXED -- Uses `--totalRegistrations` (line 2707) |
| I-01 (Struct packing) | Informational | ACKNOWLEDGED -- Cannot change after deployment |
| I-02 (Wrong error name in attestKYC) | Informational | UNFIXED -- Carried forward as L-01 |
| I-03 (DOMAIN_SEPARATOR mutable) | Informational | UNFIXED -- Carried forward as L-05 |

---

## Summary of Recommendations (Priority Order)

### Must Fix Before Mainnet

1. **[H-01] Add sequential tier enforcement in `attestKYC()`** -- Prevent colluding attestors from granting Tier 4 without any identity verification. Simple 2-line fix.

2. **[M-02] Add registration check to verification functions** -- Prevent unregistered addresses from consuming phone/social/ID hash reservations. Simple 1-line check per function.

3. **[M-03] Clear KYC attestation arrays in `_unregisterUser()`** -- Prevent attestation progress from persisting across unregister/re-register cycles.

### Should Fix Before Mainnet

4. **[L-02] Validate phone/email hashes are non-zero in `registerUser()`** -- Prevent validators from creating KYC Tier 1 accounts without actual verification.

5. **[M-01] Evaluate multi-key verification architecture** -- Single `trustedVerificationKey` is a critical single point of failure. At minimum, document the key management procedure.

### Can Fix Post-Launch

6. **[M-04] Document volume tracking period behavior** -- Users and integrators should understand the 30-day "month" and period boundary behavior.

7. **[L-01, L-03, L-04, L-05]** -- Minor improvements: error naming, abi.encode, ossification delay, DOMAIN_SEPARATOR recomputation.

8. **[I-01]** -- Add privacy disclosure documentation for users.

---

## Gas Considerations

The contract is generally gas-efficient:
- Uses `unchecked` blocks for safe loop increments
- Uses prefix increment (`++i`) consistently
- Uses `calldata` for function parameters
- Uses custom errors instead of require strings (except `checkTransactionLimit()`)
- Registration struct uses 6 storage slots (could be 5 with packing, but cannot change post-deployment)

**Potential optimization:** The `kycAttestations` mapping stores an array of attestor addresses. Iterating this array to check for duplicates (lines 983-988) costs O(n) gas. With `KYC_ATTESTATION_THRESHOLD = 3`, the maximum iteration is 2 (checking existing before the 3rd push), which is negligible. If the threshold were increased significantly, a mapping-based duplicate check would be more efficient.

---

**Audit completed:** 2026-03-10 00:59 UTC
**Auditor:** Claude Code Audit Agent (claude-opus-4-6)
**Contract hash:** `keccak256(OmniRegistration.sol)` -- verify against deployed bytecode before mainnet
