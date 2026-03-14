# Security Audit Report: OmniRegistration (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Post-Remediation Review)
**Contract:** `Coin/contracts/OmniRegistration.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 2,726
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** No (manages registration state, KYC, bonus eligibility, transaction volume -- no token custody)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
**Static Analysis:** solhint (116 warnings, 0 errors); Hardhat compiler (compiles successfully with optimizer + viaIR)
**Tests:** 90 tests passing (8 seconds)

---

## Executive Summary

This Round 7 audit is a comprehensive post-remediation review following the Round 6 audit (2026-03-10). The Round 6 audit identified 1 High, 4 Medium, 5 Low, and 4 Informational findings. The contract has undergone significant remediation since Round 6:

**Round 6 Findings Remediation Status:**

| Round 6 ID | Severity | Finding | Round 7 Status |
|------------|----------|---------|----------------|
| H-01 | High | `attestKYC()` tier skipping | **FIXED** -- Sequential tier enforcement added (lines 1091-1093) |
| M-01 | Medium | Single `trustedVerificationKey` SPOF | **ACKNOWLEDGED** -- Accepted design trade-off |
| M-02 | Medium | Unregistered users can submit verifications | **PARTIALLY FIXED** -- Some functions now check, others do not |
| M-03 | Medium | `_unregisterUser()` does not clear attestation arrays | **FIXED** -- Lines 2408-2414 clear attestation arrays |
| M-04 | Medium | Volume tracking inconsistent time periods | **ACKNOWLEDGED** -- Accepted design trade-off |
| L-01 | Low | Wrong error name in `attestKYC()` self-dealing | **NOT FIXED** -- Still uses `ValidatorCannotBeReferrer()` |
| L-02 | Low | `registerUser()` no validation of zero hashes | **NOT FIXED** |
| L-03 | Low | `abi.encodePacked` for attestation key | **NOT FIXED** |
| L-04 | Low | `ossify()` lacks two-phase commit | **NOT FIXED** |
| L-05 | Low | `DOMAIN_SEPARATOR` not recomputed on chain ID change | **NOT FIXED** |
| I-01 | Informational | Privacy: hashes create permanent identity linkage | **ACKNOWLEDGED** |
| I-02 | Informational | `TransactionLimitExceeded` declared inline | **NOT FIXED** |
| I-03 | Informational | `registeredBy` is relayer, not user, for trustless | **ACKNOWLEDGED** |
| I-04 | Informational | Video verification typehash deprecated but used | **FIXED** -- Video functions and typehash removed entirely |

This Round 7 audit found **0 Critical**, **1 High**, **3 Medium**, **5 Low**, and **5 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 5 |
| Informational | 5 |

---

## Access Control Map

### Roles

| Role | Purpose | Granted To |
|------|---------|------------|
| `DEFAULT_ADMIN_ROLE` | Admin: manage roles, set verification key, unregister users, manage KYC providers, update tier limits, ossify, authorize upgrades, set OmniRewardManager, set authorized recorders | Deployer (should be TimelockController in production) |
| `VALIDATOR_ROLE` | Register users via `registerUser()` | Validator nodes (admin managed via `setValidatorRoleAdmin()`) |
| `KYC_ATTESTOR_ROLE` | Attest KYC tiers (2-4) via `attestKYC()` | Trusted validators (3-of-N threshold) |
| `omniRewardManagerAddress` | Mark bonuses as claimed via `markWelcomeBonusClaimed()` / `markFirstSaleBonusClaimed()` | OmniRewardManager contract |
| `authorizedRecorders[addr]` | Record transactions, mark first sale completed | Marketplace/DEX/Escrow contracts |

### Permissionless Functions

| Function | Who Can Call | Protection |
|----------|-------------|------------|
| `selfRegisterTrustless()` | Any user (msg.sender = user) | EIP-712 email proof + user signature |
| `selfRegisterTrustlessFor()` | Any relayer | EIP-712 email proof + user signature |
| `submitPhoneVerification()` | Any registered user | EIP-712 proof from `trustedVerificationKey` |
| `submitPhoneVerificationFor()` | Any relayer | EIP-712 proof (user in signed data) |
| `submitSocialVerification()` | Any registered user | EIP-712 proof from `trustedVerificationKey` |
| `submitSocialVerificationFor()` | Any relayer | EIP-712 proof (user in signed data) |
| `submitIDVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 1 |
| `submitAddressVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 1 |
| `submitSelfieVerification()` / `For()` | User / relayer | EIP-712 proof, requires ID verification |
| `submitPersonaVerification()` / `For()` | User / relayer | EIP-712 proof, requires KYC Tier 2 |
| `submitAMLClearance()` | Any relayer | EIP-712 proof, NO registration check |
| `submitAccreditedInvestorCertification()` | Any registered user | EIP-712 proof, requires Persona |
| `submitThirdPartyKYC()` / `For()` | User / relayer | EIP-712 from trusted KYC provider, requires Tier 3 |

---

## Findings

### [H-01] `_unregisterUser()` Does Not Clear Persona, AML, or Accredited Investor State

**Severity:** High
**Lines:** 2375-2433 (function `_unregisterUser`)
**State Affected:**
- `personaVerificationHashes[user]` (line 281) -- NOT cleared
- `isAccreditedInvestor[user]` (line 284) -- NOT cleared
- `accreditedInvestorCriteria[user]` (line 290) -- NOT cleared
- `accreditedInvestorCertifiedAt[user]` (line 293) -- NOT cleared
- `amlCleared[user]` (line 296) -- NOT cleared
- `amlClearedAt[user]` (line 299) -- NOT cleared
- `referralCounts[user]` (line 268) -- the user's OWN count is NOT cleared (only the referrer's count is decremented)

**Description:**

The `_unregisterUser()` function performs comprehensive cleanup of 16+ categories of per-user state: registration struct, email/phone/social/ID/address hash reservations, selfie status, video session hashes (legacy), KYC tier completion timestamps, KYC provider data, volume tracking, first sale status, and KYC attestation arrays (added in Round 6 M-03 fix). However, it omits six per-user mappings introduced for the Persona/AML/Accredited Investor subsystem (KYC Tier 3).

```solidity
// Line 2375-2433: _unregisterUser() cleanup
// These are MISSING from the cleanup:
// delete personaVerificationHashes[user];
// delete isAccreditedInvestor[user];
// delete accreditedInvestorCriteria[user];
// delete accreditedInvestorCertifiedAt[user];
// delete amlCleared[user];
// delete amlClearedAt[user];
// delete referralCounts[user];
```

**Attack Scenario:**

1. User completes full KYC through Tier 3 (Persona + AML + accredited investor)
2. Admin unregisters the user (e.g., for misconduct or GDPR deletion request)
3. User re-registers at the same address (via trustless path or validator)
4. After completing only Tier 1 + Tier 2 verifications, `_checkAndUpdateKycTier3()` is called
5. `personaVerificationHashes[user]` is already non-zero (from pre-unregister)
6. `amlCleared[user]` is already `true` (from pre-unregister)
7. User immediately qualifies for Tier 3 without completing any Tier 3 verification
8. User then has KYC Tier 3: $100,000/day limits, unlimited annual, unlimited listings

Additionally, `isAccreditedInvestor[user]` persists, meaning the re-registered user retains accredited investor status without re-certification.

**Impact:** Admin unregistration, which is intended as a "clean slate" for cases like account deletion, misconduct, or GDPR compliance, does not actually reset the user to a clean state. Persona verification, AML clearance, and accredited investor certification persist, allowing the user to bypass Tier 3 verification requirements upon re-registration. This undermines the KYC system's integrity -- the same class of issue that was previously fixed for KYC attestation arrays (Round 6 M-03).

**Recommendation:** Add the following to `_unregisterUser()`, after the existing cleanup at line 2426:

```solidity
// Clear Persona / AML / accredited investor state
delete personaVerificationHashes[user];
delete isAccreditedInvestor[user];
delete accreditedInvestorCriteria[user];
delete accreditedInvestorCertifiedAt[user];
delete amlCleared[user];
delete amlClearedAt[user];
// Clear user's own referral count (user referred N people)
delete referralCounts[user];
```

---

### [M-01] `submitAMLClearance()` Does Not Check User Registration

**Severity:** Medium
**Lines:** 1643-1666

**Description:**

`submitAMLClearance()` is the ONLY verification function that accepts a `user` parameter from the caller without checking whether that user is registered. Compare:

| Function | Registration Check | User Source |
|----------|--------------------|-------------|
| `submitPhoneVerification()` | `registrations[caller].timestamp == 0` (line 1167) | `_msgSender()` |
| `submitPhoneVerificationFor()` | `registrations[user].timestamp == 0` (line 1247) | parameter |
| `submitSocialVerification()` | `registrations[caller].timestamp == 0` (line 1203) | `_msgSender()` |
| `submitIDVerification()` | `registrations[caller].timestamp == 0` (line 1398) | `_msgSender()` |
| `submitPersonaVerification()` | implicitly via `kycTier2CompletedAt[caller] == 0` (line 1584) | `_msgSender()` |
| **`submitAMLClearance()`** | **NONE** | parameter |

The `_checkAndUpdateKycTier3()` call at line 1664 provides partial protection because it checks `kycTier2CompletedAt[user] == 0`, which will be zero for unregistered users. However, the function still writes:

```solidity
amlCleared[user] = cleared;        // Written for unregistered addresses
amlClearedAt[user] = block.timestamp;  // Written for unregistered addresses
```

This means AML clearance state can be pre-populated for addresses that have not yet registered. If the user later registers and progresses to Tier 2, the pre-existing `amlCleared[user] = true` persists. When they submit Persona verification, `_checkAndUpdateKycTier3()` will see both `personaVerificationHashes[user] != 0` and `amlCleared[user] == true`, immediately completing Tier 3.

**Impact:** While the attack requires a valid EIP-712 signature from `trustedVerificationKey` (so only the verification service can forge AML proofs), it creates ghost state for arbitrary addresses. A compromised or buggy verification service could pre-clear thousands of addresses for AML, reducing future KYC Tier 3 to a single Persona verification step instead of two.

**Recommendation:** Add registration check at the start of `submitAMLClearance()`:

```solidity
if (registrations[user].timestamp == 0) revert NotRegistered();
```

---

### [M-02] Contract Size Exceeds 24 KB Spurious Dragon Limit

**Severity:** Medium
**Lines:** Entire contract (2,726 lines)

**Description:**

With the optimizer enabled (`runs: 200`, `viaIR: true`), OmniRegistration compiles to **25,750 bytes deployed** (26,066 bytes init code). The Ethereum Spurious Dragon limit is 24,576 bytes (24 KB). Hardhat emits:

```
Warning: Contract code size is 26368 bytes and exceeds 24576 bytes
(a limit introduced in Spurious Dragon).
```

The contract is deployed on an Avalanche subnet (chain ID 88008) where the limit is configurable via genesis/upgrade.json. The custom subnet may have raised or removed this limit. However:

1. If the subnet uses default Subnet-EVM settings, deployment will fail
2. The contract cannot be deployed on standard Ethereum, Avalanche C-Chain, or any EVM chain with the default limit
3. Future growth (adding new functions, fixing issues) will worsen the size problem

**Root Cause:** The contract bundles registration, 5-tier KYC verification (with 12+ verification functions), relay/meta-transaction variants of each, transaction volume tracking, tier limit management, Sybil resistance, referral tracking, bonus eligibility, accredited investor certification, AML clearance, admin functions, and UUPS upgradeability into a single contract.

**Impact:** Deployment failure on standard EVM chains. On the custom subnet, the limit must be explicitly raised in the chain configuration. This creates a coupling between the contract and the chain configuration that should be documented.

**Recommendation:** Short-term: ensure the custom subnet genesis/upgrade.json sets `contractMaxCodeSize` to at least 32768 (32 KB) or higher. Long-term: consider splitting the contract using the Diamond pattern (EIP-2535) or extracting KYC Tier 2/3/4 verification into a separate `OmniKYCVerification` contract that OmniRegistration delegates to.

Additionally, reducing optimizer `runs` from 200 to a lower value (e.g., 50) prioritizes code size over runtime gas cost and may bring the contract under 24 KB.

---

### [M-03] Interface `IOmniRegistration` Is Stale and Mismatches Implementation

**Severity:** Medium
**Lines:** `contracts/interfaces/IOmniRegistration.sol` (entire file)

**Description:**

The `IOmniRegistration` interface declares functions and errors that no longer exist in the implementation, and is missing functions that do exist:

**Declared in interface but NOT in implementation:**

| Element | Interface Line | Status |
|---------|---------------|--------|
| `function registerUser(...) external payable` | 145-150 | Implementation is NOT payable |
| `function refundDeposit() external` | 162 | Does not exist in implementation |
| `event DepositRefunded(...)` | 82 | Does not exist in implementation |
| `error InsufficientDeposit()` | 110 | Does not exist in implementation |
| `error DepositAlreadyRefunded()` | 122 | Does not exist in implementation |
| `error KYCRequired()` | 125 | Does not exist in implementation |

**Present in implementation but NOT in interface:**

| Element | Implementation Line | Status |
|---------|-------------------|--------|
| `getUserKYCTier()` | 2272 | Missing from interface |
| `checkTransactionLimit()` | 2148 | Missing from interface |
| `recordTransaction()` | 2210 | Missing from interface |
| `markFirstSaleCompleted(seller, amount, buyer)` | 1885 | Signature mismatch (interface has 3 params, correct) |
| All KYC Tier 2/3/4 verification functions | 1389-1775 | Missing from interface |
| All relay `*For()` functions | Various | Missing from interface |
| `submitAMLClearance()` | 1643 | Missing from interface |
| `submitAccreditedInvestorCertification()` | 1682 | Missing from interface |
| Transaction limit types and events | 2087-2262 | Missing from interface |

**Impact:** Any contract that imports `IOmniRegistration` (e.g., `OmniRewardManager`, `OmniParticipation`, `ValidatorProvisioner`) uses a stale interface. If they call `registerUser()` with `payable`, they will send ETH/AVAX that the implementation cannot accept (no `receive()` or `fallback()`). The `refundDeposit()` function does not exist and calls will revert at the proxy level.

`OmniRewardManager` uses its own imported `IOmniRegistration` and calls `getRegistration()`, `markWelcomeBonusClaimed()`, `markFirstSaleBonusClaimed()`, and `hasCompletedFirstSale()` -- these all exist and match, so the current integration works. However, the stale interface is a maintenance hazard and could cause issues for new integrations.

**Recommendation:** Update `IOmniRegistration` to match the current implementation. Remove deprecated functions (`refundDeposit`, payable modifier), add missing functions, and ensure all cross-contract callers use the updated interface.

---

### [L-01] `attestKYC()` Self-Dealing Check Uses Semantically Wrong Error

**Severity:** Low
**Lines:** 1096-1098
**Status:** Carried forward from Round 6 L-01 (originally Round 3 I-02)

**Description:**

When a KYC attestor tries to attest for a user they registered, the function reverts with `ValidatorCannotBeReferrer()`. The error name describes a referral scenario, not an attestation scenario:

```solidity
// Line 1096-1098
if (registrations[user].registeredBy == msg.sender) {
    revert ValidatorCannotBeReferrer(); // Semantically: AttestorCannotBeRegistrar
}
```

**Impact:** Confusing error messages for front-end UX and debugging. No functional impact.

**Recommendation:** Add a dedicated error: `error AttestorCannotBeRegistrar();` and use it at line 1097.

---

### [L-02] `registerUser()` Does Not Validate Phone/Email Hash Are Non-Zero

**Severity:** Low
**Lines:** 802-863
**Status:** Carried forward from Round 6 L-02

**Description:**

`registerUser()` accepts `phoneHash` and `emailHash` parameters but does not validate they are non-zero. A validator could register a user with `bytes32(0)` hashes. The first such registration succeeds (since `usedPhoneHashes[bytes32(0)]` starts `false`), marking `usedPhoneHashes[bytes32(0)] = true` and blocking all subsequent zero-hash registrations. The resulting user has `kycTier: 1` despite having no actual phone or email verification.

**Impact:** A malicious or buggy validator can create one user with no phone/email verification at KYC Tier 1. Limited economic impact (one welcome bonus).

**Recommendation:** Add validation:
```solidity
if (phoneHash == bytes32(0)) revert ZeroAddress(); // or new error
if (emailHash == bytes32(0)) revert ZeroAddress(); // or new error
```

---

### [L-03] `abi.encodePacked` Used for Attestation Key Hashing

**Severity:** Low
**Lines:** 1100, 2412
**Status:** Carried forward from Round 6 L-03

**Description:**

`keccak256(abi.encodePacked(user, tier))` is used to compute attestation mapping keys. While there is no practical collision risk with fixed-size types (`address` = 20 bytes, `uint8` = 1 byte), `abi.encode` is the standard best practice.

**Recommendation:** Use `abi.encode` instead of `abi.encodePacked` for consistency and to eliminate the need for case-by-case analysis.

---

### [L-04] `ossify()` Lacks Two-Phase Commit or Timelock Enforcement

**Severity:** Low
**Lines:** 2560-2563
**Status:** Carried forward from Round 6 L-04

**Description:**

`ossify()` is a one-way, irreversible operation. The NatSpec correctly warns that admin "MUST be behind a TimelockController" but this is not enforced in the contract. Accidental ossification permanently prevents bug fixes.

**Recommendation:** Implement a two-phase ossification with a minimum 7-day delay, or verify the admin role is held by a TimelockController at deployment time.

---

### [L-05] `DOMAIN_SEPARATOR` Not Recomputed on Chain ID Change

**Severity:** Low
**Lines:** 148, 744-752
**Status:** Carried forward from Round 6 L-05

**Description:**

`DOMAIN_SEPARATOR` is computed once during `initialize()` using `block.chainid`. A hard fork changing the chain ID would invalidate all EIP-712 signatures. For an Avalanche subnet (chain ID 88008), this is extremely unlikely.

**Recommendation:** Low priority. Add a `_domainSeparator()` function that recomputes if `block.chainid` changes.

---

### [I-01] `AccreditedInvestorCertified` Event Emits `block.timestamp` Instead of Off-Chain `timestamp`

**Severity:** Informational
**Lines:** 1706

**Description:**

The `submitAccreditedInvestorCertification()` function emits:

```solidity
emit AccreditedInvestorCertified(caller, criteria, certified, block.timestamp);
```

Other verification events emit the off-chain `timestamp` parameter:
- `PersonaVerified(caller, verificationHash, timestamp)` -- off-chain timestamp
- `AMLCleared(user, cleared, timestamp)` -- off-chain timestamp
- `IDVerified(caller, idHash, country, timestamp)` -- off-chain timestamp

The inconsistency means off-chain indexers cannot determine when the accredited investor certification was actually performed versus when it was submitted on-chain.

**Recommendation:** Change to `emit AccreditedInvestorCertified(caller, criteria, certified, timestamp);` to match the pattern used by other verification events.

---

### [I-02] Storage Gap Comment Incorrectly States Mappings Do Not Consume Sequential Slots

**Severity:** Informational
**Lines:** 2709-2725

**Description:**

The comment on `__gap` states:

```solidity
///      (authorizedRecorders is a mapping and does not consume a
///      sequential slot.)
```

This is technically incorrect. In Solidity, a `mapping` declaration reserves exactly one storage slot at the sequential position. The actual key-value data is stored at `keccak256(key, slot)` derived positions, but the slot itself is reserved. From the Solidity documentation:

> "For mappings, the slot stays empty, but it is still needed to ensure that [...] two neighboring mappings have different hash distributions."

The practical impact is that if a developer adds a new state variable assuming 48 gap slots are available, they would be off by one slot due to `authorizedRecorders` consuming a slot that the comment says it does not.

However, since `authorizedRecorders` is declared BEFORE `__gap`, the actual storage layout is correct -- the gap starts at the correct position. The comment is misleading but the code is safe.

**Recommendation:** Correct the comment:

```solidity
///      Reduced from 49 to 48 to accommodate omniRewardManagerAddress.
///      Note: authorizedRecorders is a mapping and occupies one sequential
///      slot (slot position reserved even though data stored at derived
///      locations). The gap size of 48 accounts for _ossified (1 slot),
///      omniRewardManagerAddress (1 slot), and authorizedRecorders (1 slot),
///      totaling 48 + 3 = 51, minus the original 50, meaning one extra
///      slot has been consumed from the gap since the original deployment.
```

Or verify the exact slot accounting and adjust accordingly.

---

### [I-03] `TransactionLimitExceeded` Error Declared Between Function NatSpec and Definition

**Severity:** Informational
**Lines:** 2195-2198
**Status:** Carried forward from Round 6 I-02

**Description:**

The custom error `TransactionLimitExceeded` is declared at lines 2195-2198, between the NatSpec for `recordTransaction()` (line 2186) and the function definition (line 2210). All other custom errors are in the dedicated ERRORS section (lines 594-714).

**Recommendation:** Move `TransactionLimitExceeded` to the ERRORS section for organizational consistency.

---

### [I-04] TODO Comment Indicates Incomplete Feature

**Severity:** Informational
**Lines:** 2278

**Description:**

```solidity
// TODO: Add expiration check when accreditation system implemented
```

This TODO in `getUserKYCTier()` indicates that KYC Tier 3 has no expiration check. Accredited investor certifications and AML clearances typically expire (1-2 years). Without an expiration check, a user who was AML-cleared 5 years ago retains Tier 3 indefinitely.

Per project standards (CLAUDE.md): "NEVER: DO NOT put stubs, todo items, mock implementations to make code compile" and "Complete work NOW (don't put it off)."

**Recommendation:** Either implement the expiration check (e.g., 365 days for AML clearance, 730 days for accredited investor status) or remove the TODO and document the design decision that Tier 3 does not expire.

---

### [I-05] `getUserKYCTier()` May Return Higher Tier Than `Registration.kycTier`

**Severity:** Informational
**Lines:** 2272-2290, 1966-1969

**Description:**

`getUserKYCTier()` checks `kycTierXCompletedAt` timestamps (highest first) and returns the highest tier achieved. `canClaimWelcomeBonus()` checks `reg.kycTier >= 1` using the `Registration` struct field. These two data sources are synchronized in most paths (the `_checkAndUpdateKycTierX()` functions update both), but the `resetKycTier3()` admin function (line 2517) resets the completion timestamps and the struct field independently.

The `resetKycTier3()` function correctly sets `reg.kycTier = 2` when resetting Tier 3 (line 2538). However, if the admin wanted to reset a user from Tier 2 to Tier 1, there is no `resetKycTier2()` function. The only way to fully reset a user is `adminUnregister()` + re-registration.

**Impact:** No current exploit -- the admin functions are internally consistent. This is a maintenance note: future admin tier reset functions must update both `kycTierXCompletedAt` and `Registration.kycTier`.

---

## Sybil Resistance Analysis (Updated)

### Round 7 Improvements

Since Round 6, the following Sybil resistance improvements have been implemented:

1. **SYBIL-H02: Referrer KYC Tier 1 Requirement** (lines 828, 1022) -- Referrers must have completed KYC Tier 1 (`kycTier1CompletedAt[referrer] != 0`). This prevents Tier 0 accounts from acting as referrers in referral bonus chains. The check is enforced in both `registerUser()` (validator path) and `_selfRegisterTrustlessInternal()` (trustless path).

2. **SYBIL-H05: First Sale Anti-Wash-Trading** (lines 1885-1921) -- `markFirstSaleCompleted()` now validates:
   - Minimum sale amount: `saleAmount >= MIN_FIRST_SALE_AMOUNT` (100 XOM)
   - Account age: `block.timestamp >= reg.timestamp + MIN_FIRST_SALE_AGE` (7 days)
   - Shared referrer check: buyer and seller cannot share the same referrer

3. **Sequential KYC Tier Enforcement** (lines 1091-1093) -- `attestKYC()` now enforces `PreviousTierRequired()` checks, preventing tier skipping.

### Remaining Sybil Vectors

| Vector | Cost | KYC Achieved | Bonus Eligible | Mitigation |
|--------|------|-------------|----------------|------------|
| Trustless registration farming | Free (email) | Tier 0 | No welcome bonus | Off-chain email verification quality |
| Compromised validator registration | VALIDATOR_ROLE access | Tier 1 | Yes (welcome bonus) | Phone/email uniqueness, staked validator |
| Compromised verification key | trustedVerificationKey | Tier 3 (all verifications) | Yes (all bonuses) | Protect key, consider multi-key |
| Referral chain farming | Multiple accounts + KYC Tier 1 | N/A | Referral bonuses on each sale | Shared-referrer check, referrer KYC requirement |
| Wash trading for first sale bonus | 2 accounts + 100 XOM sale + 7 days | First sale bonus | Yes | MIN_FIRST_SALE_AMOUNT, MIN_FIRST_SALE_AGE, shared referrer check |

**New observation:** The SYBIL-H05 shared referrer check (lines 1909-1917) has a bypass: if either the buyer or the seller has `referrer == address(0)`, the check passes. An attacker can create Account A with no referrer and Account B with a referrer, then sell from B to A. The shared referrer check sees A has no referrer and passes. To strengthen: also check if A is B's referrer or B is A's referrer (direct referral relationship).

---

## Upgradeable Safety Analysis

### Storage Layout Verification

The contract declares state variables in this order:
1. Constants (no storage slots)
2. `registrations`, `usedPhoneHashes`, `usedEmailHashes`, `dailyRegistrationCount`, `totalRegistrations`, `kycAttestations`, `DOMAIN_SEPARATOR`, `trustedVerificationKey`, `userSocialHashes`, `userEmailHashes`, `kycTier1CompletedAt`, `usedSocialHashes`, `usedNonces` (v1 storage)
3. KYC Tier 2/3/4 storage: `userIDHashes`, `usedIDHashes`, `userCountries`, `userAddressHashes`, `usedAddressHashes`, `selfieVerified`, `kycTier2CompletedAt`, `videoSessionHashes`, `kycTier3CompletedAt`, `trustedKYCProviders`, `kycProviderNames`, `kycTier4CompletedAt`, `userKYCProvider`, `referralCounts`, `firstSaleCompleted` (v2 storage)
4. Persona/AML/Accredited storage: `personaVerificationHashes`, `isAccreditedInvestor`, `accreditedInvestorCriteria`, `accreditedInvestorCertifiedAt`, `amlCleared`, `amlClearedAt` (v2.x storage)
5. Transaction limits: `tierLimits`, `userVolumes` (v2.x storage -- these are mappings, 2 slots)
6. `_ossified` (bool -- 1 slot)
7. `omniRewardManagerAddress` (address -- 1 slot)
8. `authorizedRecorders` (mapping -- 1 slot)
9. `__gap` (uint256[48] -- 48 slots)

**Gap Accounting Concern:** The comment states `authorizedRecorders` does not consume a sequential slot. This is incorrect -- it does consume one slot. If the original deployment had `__gap[50]`, and subsequent upgrades consumed slots for `_ossified` (1) and `omniRewardManagerAddress` (1) and `authorizedRecorders` (1), the gap should be 47, not 48. However, if `authorizedRecorders` was part of the original gap accounting and was always at its current position, the layout is safe.

**Recommendation:** Run `npx hardhat validate-upgrade` to verify the current storage layout matches the deployed proxy. Add storage layout tests.

### Initializer Safety

- Constructor: `_disableInitializers()` -- correct
- `initialize()`: `initializer` modifier -- correct, one-time
- `reinitialize()`: `reinitializer(version)` modifier + `onlyRole(DEFAULT_ADMIN_ROLE)` -- correct
- `reinitialize()`: idempotent checks for DOMAIN_SEPARATOR and tierLimits -- correct

---

## Signature Verification Analysis

### EIP-712 Correctness

All 12 verification functions follow a consistent, correct EIP-712 pattern:
1. Compute `structHash` using appropriate typehash + all parameters
2. Compute `digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash))`
3. Recover signer via `ECDSA.recover()`
4. Compare to expected signer

**Verification:** All typehashes match their parameter lists. No field omissions or truncations. The DOMAIN_SEPARATOR includes `name`, `version`, `chainId`, and `verifyingContract`.

### Replay Protection

- All proofs use `bytes32 nonce` (256-bit entropy)
- `usedNonces[nonce]` checked before use, marked after verification
- Cross-contract replay prevented by `address(this)` in DOMAIN_SEPARATOR
- Cross-chain replay prevented by `block.chainid` in DOMAIN_SEPARATOR

### Deadline Enforcement

All verification functions check `block.timestamp > deadline` and revert with `ProofExpired()`. The `block.timestamp` is manipulable by validators within ~2 seconds on Avalanche. This is acceptable for deadline enforcement.

---

## Front-Running Analysis

### Registration Front-Running

Both `selfRegisterTrustless()` and `selfRegisterTrustlessFor()` include the `user` address in the signed email proof AND the signed registration request. An attacker cannot steal registration by changing the user address -- both signatures would become invalid.

**Griefing:** An attacker could observe a registration transaction and submit a competing transaction to consume the daily registration limit. With `MAX_DAILY_REGISTRATIONS = 10000`, this requires 10,000 transactions per day -- a significant cost on Avalanche.

### Verification Front-Running

All verification proofs include the `user` address in the signed data. Proof theft is not possible. Nonce uniqueness prevents any form of replay.

---

## Gas Analysis

### Efficient Patterns

- `unchecked` blocks for safe loop increments
- Prefix increment (`++i`) consistently
- `calldata` for function parameters
- Custom errors instead of require strings (except `checkTransactionLimit()` which returns strings for UX)
- Storage pointer (`Registration storage reg`) to avoid redundant SLOADs

### Potential Optimizations

1. **`_unregisterUser()` gas cost:** Performs ~30 SSTORE operations (many `delete`s). With the recommended fix adding 7 more deletes, total gas could reach ~150,000+. This is within acceptable limits for an admin-only function.

2. **`attestKYC()` loop:** O(n) attestor duplicate check (lines 1104-1110). With `KYC_ATTESTATION_THRESHOLD = 3`, maximum iteration is 2. Acceptable.

3. **Contract size:** At 25.75 KB, the contract is 1.17 KB over the Spurious Dragon limit. Reducing optimizer `runs` from 200 to 50 would save ~2-5% code size, potentially bringing it under the limit.

---

## Cross-Contract Integration Analysis

### OmniRewardManager Integration

`OmniRewardManager` calls:
- `registrationContract.getRegistration(user)` -- returns Registration struct, works correctly
- `registrationContract.markWelcomeBonusClaimed(user)` -- gated by `omniRewardManagerAddress` check, works correctly
- `registrationContract.markFirstSaleBonusClaimed(user)` -- same gating, works correctly
- `registrationContract.hasCompletedFirstSale(user)` -- returns `firstSaleCompleted[user]`, works correctly

**Integration risk:** If `omniRewardManagerAddress` is not set (remains `address(0)`), all bonus claiming calls revert with `Unauthorized()`. This is fail-safe behavior.

### OmniParticipation Integration

`OmniParticipation` declares a local `IOmniRegistration` interface (not importing from `contracts/interfaces/`) and calls:
- `registration.isRegistered(user)` -- works correctly
- `registration.getRegistration(user)` -- works correctly

### ValidatorProvisioner Integration

`ValidatorProvisioner` uses `IOmniRegistrationProvisioner` interface and calls:
- `omniRegistration.grantRole(VALIDATOR_ROLE, ...)` -- works via AccessControl, gated by role admin
- `omniRegistration.revokeRole(VALIDATOR_ROLE, ...)` -- works via AccessControl, gated by role admin

**Observation:** `setValidatorRoleAdmin()` (line 2640) delegates VALIDATOR_ROLE and KYC_ATTESTOR_ROLE admin to a new role. If this is called before `ValidatorProvisioner` is set up, the provisioner needs the new admin role to manage validators. The ordering of admin setup operations is critical.

---

## Round 6 vs Round 7 Comparison

| Round 6 Finding | Round 6 Severity | Round 7 Status | Notes |
|-----------------|------------------|----------------|-------|
| H-01 (attestKYC tier skipping) | High | **FIXED** | Sequential enforcement at lines 1091-1093 |
| M-01 (Single trustedVerificationKey SPOF) | Medium | **ACKNOWLEDGED** | Accepted design trade-off |
| M-02 (Unregistered users can submit verifications) | Medium | **PARTIALLY FIXED** | Phone/social/ID checks added; AML still missing (see M-01 above) |
| M-03 (_unregisterUser attestation cleanup) | Medium | **FIXED** | Lines 2408-2414 |
| M-04 (Volume tracking time periods) | Medium | **ACKNOWLEDGED** | Accepted trade-off |
| L-01 (Wrong error name) | Low | **NOT FIXED** | Carried forward |
| L-02 (Zero hash validation) | Low | **NOT FIXED** | Carried forward |
| L-03 (abi.encodePacked) | Low | **NOT FIXED** | Carried forward |
| L-04 (ossify two-phase) | Low | **NOT FIXED** | Carried forward |
| L-05 (DOMAIN_SEPARATOR recompute) | Low | **NOT FIXED** | Carried forward |
| I-01 (Privacy: deterministic hashes) | Informational | **ACKNOWLEDGED** | |
| I-02 (TransactionLimitExceeded inline) | Informational | **NOT FIXED** | Carried forward |
| I-03 (registeredBy = relayer) | Informational | **ACKNOWLEDGED** | |
| I-04 (Video verification deprecated but used) | Informational | **FIXED** | Video functions removed entirely |

**New findings in Round 7:**
- H-01: `_unregisterUser()` missing Persona/AML/accredited cleanup (NEW)
- M-01: `submitAMLClearance()` missing registration check (NEW)
- M-02: Contract exceeds 24 KB size limit (NEW -- first flagged)
- M-03: Interface `IOmniRegistration` stale (NEW -- first flagged)
- I-01: Event timestamp inconsistency (NEW)
- I-02: Storage gap comment incorrect (NEW)
- I-04: TODO comment for incomplete feature (NEW)
- I-05: getUserKYCTier/Registration.kycTier dual tracking note (NEW)

---

## Summary of Recommendations (Priority Order)

### Must Fix Before Mainnet

1. **[H-01] Complete `_unregisterUser()` cleanup** -- Add `delete` calls for `personaVerificationHashes`, `isAccreditedInvestor`, `accreditedInvestorCriteria`, `accreditedInvestorCertifiedAt`, `amlCleared`, `amlClearedAt`, and `referralCounts[user]`. This is a 7-line fix.

2. **[M-01] Add registration check to `submitAMLClearance()`** -- Single line: `if (registrations[user].timestamp == 0) revert NotRegistered();`

3. **[M-02] Verify subnet contract size limit** -- Ensure the custom Avalanche subnet configuration allows contracts > 24 KB, or reduce contract size by lowering optimizer `runs` or splitting the contract.

### Should Fix Before Mainnet

4. **[M-03] Update `IOmniRegistration` interface** -- Remove deprecated functions, add missing functions, align with current implementation.

5. **[L-02] Validate phone/email hashes non-zero in `registerUser()`** -- Prevent zero-hash KYC Tier 1.

6. **[I-04] Address TODO comment** -- Implement Tier 3 expiration or document the design decision.

### Can Fix Post-Launch

7. **[L-01, L-03, L-04, L-05]** -- Minor improvements carried forward from previous rounds.

8. **[I-01, I-02, I-03, I-05]** -- Informational consistency improvements.

---

## Solhint Analysis Summary

116 warnings, 0 errors. Breakdown:

| Category | Count | Notes |
|----------|-------|-------|
| `gas-small-strings` | 26 | EIP-712 typehash strings; cannot be shortened (by design) |
| `gas-indexed-events` | 30 | Non-indexed event parameters; adding indexed improves filtering but increases gas |
| `gas-strict-inequalities` | 7 | `>=` used where `>` could work; reviewed, all are semantically correct |
| `not-rely-on-time` | 14 | `block.timestamp` usage; reviewed, all are legitimate business requirements (registration timestamps, rate limiting, deadlines) |
| `no-global-import` | 5 | OpenZeppelin imports; stylistic preference |
| `max-states-count` | 1 | 40 state declarations vs 20 allowed; inherent in contract scope |
| `code-complexity` | 5 | Functions with cyclomatic complexity > 7; reviewed, complexity is from validation logic |
| `max-line-length` | 5 | Lines > 120 chars; mostly in EIP-712 typehash definitions |
| `use-natspec` | 18 | Missing @notice/@param tags on some functions/variables |
| `ordering` | 1 | Struct after constant; cannot change without storage layout impact |
| `gas-struct-packing` | 1 | Registration struct packing; cannot change after deployment |

All warnings have been reviewed. The `not-rely-on-time` warnings are legitimate business requirements. The `gas-small-strings` warnings are EIP-712 typehash definitions that cannot be shortened. The `use-natspec` warnings for missing @param tags should be addressed for documentation completeness.

---

## Test Coverage Assessment

90 tests passing across:
- Basic registration (validator path and trustless path)
- Phone/social/email verification
- KYC Tier 1 completion
- KYC Tier 2 (ID + address verification)
- KYC Tier 3 (Persona + AML + accredited investor)
- KYC Tier 4 (third-party KYC)
- Admin functions (unregister, KYC provider management, tier reset)
- Relay pattern functions
- SYBIL-H02 referrer KYC requirement
- Rate limiting

**Coverage gaps identified:**
- No test for `_unregisterUser()` clearing Persona/AML/accredited state (H-01)
- No test for `submitAMLClearance()` on unregistered address (M-01)
- No test for `markFirstSaleCompleted()` shared referrer bypass with `address(0)` referrer
- No test for volume tracking period boundary behavior
- No test for `setValidatorRoleAdmin()` + subsequent provisioner interactions
- No test for `ossify()` + subsequent upgrade attempt
- No test for DOMAIN_SEPARATOR consistency across reinitialize

---

**Audit completed:** 2026-03-13
**Auditor:** Claude Code Audit Agent (claude-opus-4-6)
**Contract hash:** Verify against deployed bytecode before mainnet deployment
**Previous audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
