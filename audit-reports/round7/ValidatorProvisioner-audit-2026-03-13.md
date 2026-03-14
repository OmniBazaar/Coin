# Security Audit Report: ValidatorProvisioner.sol

**Audit Round:** 7 (Pre-Mainnet)
**Date:** 2026-03-13
**Auditor:** Claude Opus 4.6
**Contract:** `contracts/ValidatorProvisioner.sol`
**Solidity Version:** 0.8.24
**Framework:** Hardhat + OpenZeppelin Upgradeable (UUPS)

---

## Executive Summary

ValidatorProvisioner is a permissionless validator onboarding/offboarding contract that manages 7 roles across 6 target contracts. It checks on-chain qualifications (participation score, KYC tier, staking amount) before granting or revoking validator roles atomically. The contract is well-structured with clear separation of concerns. No critical or high-severity issues were found. The primary findings relate to a documentation-vs-code mismatch on the default KYC tier, missing validation bounds on threshold parameters, lack of pause functionality, and minor observability gaps.

---

## Tooling Results

| Tool | Result |
|------|--------|
| Solhint | 0 errors, 6 warnings (NatSpec @author on interfaces, function ordering, indexed event param) |
| Slither | Skipped |

### Solhint Warnings

| Line | Warning | Assessment |
|------|---------|------------|
| 25, 57, 71 | Missing `@author` on interfaces | **Info** - Interfaces are internal to this file; low impact |
| 90 | Function ordering (external after external view) | **Info** - OZ interface layout artifact |
| 230 | `minStake` on `ThresholdsUpdated` could be indexed | **Low** - Would improve log filterability |
| 611 | Function ordering (internal after internal view) | **Info** - Minor style issue |

---

## Findings

### VP-M01: NatSpec Says Default KYC Tier = 4, Code Sets 3

**Severity:** Medium
**Location:** Lines 108, 187, 325
**Category:** Documentation / Configuration Mismatch

**Description:**
The contract-level NatSpec at line 108 states:
```
KYC tier >= minKYCTier (default: 4)
```
The state variable NatSpec at line 187 states:
```
Minimum KYC tier required (1-4, default: 4)
```
However, the `initialize()` function at line 325 sets:
```solidity
minKYCTier = 3;
```

Per the project's CLAUDE.md, the design spec says validators require "Top-tier KYC (Level 4 - full verification)." This discrepancy means the deployed contract would accept Tier 3 validators by default, which violates the stated requirement for full (Tier 4) KYC verification.

**Impact:** Validators with only Tier 3 KYC (enhanced verification, but not the full video-call + background check of Tier 4) could be permissionlessly provisioned. This weakens the trust boundary since validators attest KYC for other users, handle settlement, and process transactions.

**Recommendation:** Change line 325 to `minKYCTier = 4;` to match the NatSpec and project design specification, OR update the NatSpec and design docs to reflect the intended Tier 3 minimum if that is deliberate.

---

### VP-M02: No Validation Bounds on `setThresholds` Parameters

**Severity:** Medium
**Location:** Lines 440-456
**Category:** Access Control / Input Validation

**Description:**
The `setThresholds()` function validates `_minKYCTier <= 4` but does NOT validate:
1. `_minParticipationScore` - Can be set to 0 (bypassing participation check) or to values > 100 (making provisioning impossible since max score is 100).
2. `_minStakeAmount` - Can be set to 0 (bypassing the staking requirement entirely).

A compromised or careless owner could call `setThresholds(0, 0, 0)` to reduce all qualifications to zero, allowing any address with an active stake of 0 (which is contradictory with `stake.active` check, but `stake.amount >= 0` would pass) to be provisioned as a validator.

Note: The `_checkQualifications` function does require `stake.active` to be true, so a zero stake amount with `active == false` would still revert. However, an active stake with `amount = 0` would pass.

**Impact:** Owner can effectively disable all qualification gates. While this is owner-only, it should have sensible lower bounds as a defense-in-depth measure.

**Recommendation:** Add minimum floor validation:
```solidity
if (_minParticipationScore > 100) revert InvalidScore();
if (_minStakeAmount == 0) revert ZeroAmount();
```
Consider also enforcing a reasonable floor, e.g., `_minParticipationScore >= 10`.

---

### VP-M03: `setContracts` Orphans Roles on Old Contracts

**Severity:** Medium
**Location:** Lines 467-486
**Category:** State Consistency

**Description:**
When `setContracts()` updates contract references, validators that were previously provisioned retain their roles on the **old** contracts. The `provisionedValidators` mapping still marks them as provisioned. If `deprovisionValidator()` is later called, it will try to revoke roles from the **new** contracts where the validator may never have been granted roles. While OpenZeppelin's `revokeRole` is idempotent (no revert if role not held), this creates an inconsistent state:

1. Old contracts: Validator still has VALIDATOR_ROLE, KYC_ATTESTOR_ROLE, VERIFIER_ROLE, BLOCKCHAIN_ROLE
2. New contracts: Validator never had roles, revocation is a no-op
3. `provisionedValidators[validator]` is set to false despite roles persisting on old contracts

The NatSpec acknowledges this ("Does NOT re-provision existing validators on the new contracts") but does not address the deprovision path.

**Impact:** After a contract swap, deprovisioned validators retain active roles on old target contracts. If old contracts remain in use during migration or are accidentally referenced, the validator retains full privileges.

**Recommendation:** Either:
(a) Add a `migrateValidators(address[] calldata validators)` function that revokes roles on old contracts and grants on new ones, OR
(b) Document that `setContracts` should only be called after all validators are force-deprovisioned and re-provisioned, OR
(c) Store old contract references temporarily and revoke from both old and new during deprovision.

---

### VP-L01: No Emergency Pause Mechanism

**Severity:** Low
**Location:** Entire contract
**Category:** Operational Safety

**Description:**
The contract does not inherit `PausableUpgradeable` and has no `pause()`/`unpause()` mechanism. If a vulnerability is discovered in the qualification checks or external contracts, there is no way to halt provisioning short of upgrading the implementation.

The `forceDeprovision()` function helps for individual validators, but cannot prevent new provisioning of malicious actors in a mass-exploit scenario.

**Impact:** Delayed response to active exploits. The owner can upgrade the contract, but upgrade deployment takes time.

**Recommendation:** Add `PausableUpgradeable` and apply `whenNotPaused` to `provisionValidator()` and `deprovisionValidator()` (the permissionless functions). Leave `forceProvision()` and `forceDeprovision()` unpaused so the owner can still manage validators during emergencies.

---

### VP-L02: No Maximum Validator Cap

**Severity:** Low
**Location:** Lines 344-360, 397-409
**Category:** Economic / Rate Limiting

**Description:**
There is no upper bound on `provisionedCount`. The permissionless `provisionValidator()` allows unlimited validators as long as qualifications are met. While qualifications (especially the 1M XOM staking requirement) provide an economic barrier, there is no governance-controlled cap.

The project spec mentions: "Legacy limit: Square root of total user count (top participation scores only)" and notes a "new system under discussion."

**Impact:** If staking requirements are lowered via `setThresholds`, the lack of a cap could lead to over-provisioning, diluting block rewards and potentially degrading network performance.

**Recommendation:** Consider adding a `maxValidators` parameter with a reasonable default (e.g., 200) that the owner can adjust. This aligns with the validator iteration cap of 200 in OmniValidatorRewards.

---

### VP-L03: `_authorizeUpgrade` Does Not Validate New Implementation

**Severity:** Low
**Location:** Lines 690-694
**Category:** Upgrade Safety

**Description:**
The `_authorizeUpgrade` function only checks `onlyOwner` but does not validate that `newImplementation` is a non-zero address or a valid contract. While UUPSUpgradeable performs some checks internally, an explicit zero-address check is a defense-in-depth best practice.

**Impact:** Minimal. OpenZeppelin's UUPS proxy validates internally. But explicit checks clarify intent.

**Recommendation:** Add:
```solidity
if (newImplementation == address(0)) revert ZeroAddress();
```

---

### VP-L04: `ContractsUpdated` Event Lacks Parameters

**Severity:** Low
**Location:** Lines 237, 485, 502
**Category:** Observability

**Description:**
The `ContractsUpdated` event emits no parameters. When either `setContracts()` or `setPrivacyContracts()` is called, off-chain monitoring cannot distinguish which contracts were changed or what the new addresses are without reading storage.

**Impact:** Reduced off-chain observability and audit trail quality.

**Recommendation:** Add parameters to the event:
```solidity
event ContractsUpdated(
    address indexed omniRegistration,
    address indexed omniParticipation,
    address omniCore,
    address omniValidatorRewards
);
```
Or create separate events for `setContracts` and `setPrivacyContracts`.

---

### VP-L05: No Reentrancy Guard on Multi-External-Call Functions

**Severity:** Low
**Location:** Lines 611-643, 650-683
**Category:** Reentrancy

**Description:**
`_grantAllRoles()` and `_revokeAllRoles()` each make 5-7 external calls to different contracts. While state is updated (provisionedValidators, provisionedCount) after the calls return, the checks-effects-interactions pattern is inverted: state is set in the calling function (`provisionValidator` line 356-357) AFTER `_grantAllRoles` returns. This means during the external calls, `provisionedValidators[validator]` is still `false`.

However, exploiting this would require one of the target contracts (OmniRegistration, OmniParticipation, OmniCore, OmniValidatorRewards, PrivateDEX, PrivateDEXSettlement) to have a callback into ValidatorProvisioner, which is unlikely since these are all trusted OZ AccessControl contracts.

**Impact:** Negligible in practice since all target contracts are trusted, controlled by the project, and use standard OZ AccessControl (no callbacks). However, if `setContracts` points to a malicious contract, the reentrancy vector becomes viable.

**Recommendation:** Either:
(a) Set `provisionedValidators[validator] = true` and increment `provisionedCount` BEFORE calling `_grantAllRoles()`, or
(b) Add `ReentrancyGuardUpgradeable` as a defense-in-depth measure.

---

### VP-I01: `minKYCTier` State Variable NatSpec Says "default: 4"

**Severity:** Info
**Location:** Line 187
**Category:** Documentation

**Description:**
The state variable NatSpec comment says "default: 4" but the initialize function sets it to 3. This is the same root issue as VP-M01 but specifically flagged for the inline comment.

**Recommendation:** Align comment with actual initialization value.

---

### VP-I02: Solhint Interface Ordering and `@author` Warnings

**Severity:** Info
**Location:** Lines 25, 57, 71, 90, 611
**Category:** Style

**Description:**
Six solhint warnings: three missing `@author` tags on internal interfaces, two function ordering issues, and one gas optimization suggestion for indexed event parameter.

**Recommendation:**
1. Add `@author OmniBazaar Team` to all three interfaces.
2. Reorder functions: move `provisionValidator` in `IOmniCoreProvisioner` before `getStake` (external before external view), and move `_grantAllRoles` before `_getKYCTier` (internal before internal view).
3. Add `indexed` keyword to `minStake` parameter in `ThresholdsUpdated` event.

---

### VP-I03: `isRegistered` Check Not Used

**Severity:** Info
**Location:** `IOmniRegistrationProvisioner` interface (line 29)
**Category:** Dead Code

**Description:**
The `IOmniRegistrationProvisioner` interface declares `isRegistered(address)` but it is never called anywhere in the contract. The qualification checks rely solely on KYC tier, participation score, and staking. While registration is implicitly required (a user cannot have KYC or participation score without being registered), the unused interface method adds unnecessary interface surface.

**Recommendation:** Remove `isRegistered` from the interface since it is not used, or add an explicit registration check in `_checkQualifications` for clarity and defense-in-depth.

---

### VP-I04: Storage Slot Packing Opportunity

**Severity:** Info
**Location:** Lines 185-191
**Category:** Gas Optimization

**Description:**
`minKYCTier` (uint8) occupies an entire 32-byte slot because it is declared between two `uint256` values. If moved adjacent to an `address` variable, it could share a slot (address = 20 bytes, uint8 = 1 byte, fitting in 32 bytes).

Current layout:
- Slot N: `minParticipationScore` (uint256)
- Slot N+1: `minKYCTier` (uint8, wastes 31 bytes)
- Slot N+2: `minStakeAmount` (uint256)

**Recommendation:** Reorder to pack `minKYCTier` with one of the address variables (e.g., `privateDEXSettlement`). Note: since this is upgradeable, slot layout changes require careful migration. Best addressed in a future V2 upgrade or before first mainnet deployment.

---

## Findings Summary

| ID | Severity | Title |
|----|----------|-------|
| VP-M01 | Medium | NatSpec says default KYC tier = 4, code sets 3 |
| VP-M02 | Medium | No validation bounds on `setThresholds` parameters |
| VP-M03 | Medium | `setContracts` orphans roles on old contracts |
| VP-L01 | Low | No emergency pause mechanism |
| VP-L02 | Low | No maximum validator cap |
| VP-L03 | Low | `_authorizeUpgrade` does not validate new implementation |
| VP-L04 | Low | `ContractsUpdated` event lacks parameters |
| VP-L05 | Low | No reentrancy guard on multi-external-call functions |
| VP-I01 | Info | `minKYCTier` inline NatSpec says "default: 4" |
| VP-I02 | Info | Solhint interface ordering and `@author` warnings |
| VP-I03 | Info | `isRegistered` declared in interface but never called |
| VP-I04 | Info | Storage slot packing opportunity for `minKYCTier` |

## Severity Counts

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 5 |
| Info | 4 |

---

## Risk Assessment

**Overall Risk: LOW-MEDIUM**

The contract is well-designed with proper access control (Ownable2Step), UUPS upgradeability, and clean separation between permissionless and owner-only operations. The permissionless provisioning/deprovisioning logic correctly checks on-chain qualifications and the `StillQualified` guard prevents premature removal.

**Key Strengths:**
1. **Atomic role management** - All 7 roles granted/revoked in a single transaction
2. **Two-step ownership** - Ownable2StepUpgradeable prevents accidental ownership transfer
3. **Correct external contract integration** - Proper use of IAccessControl and custom provisioner interfaces
4. **Optional privacy contracts** - Clean handling of zero-address for undeployed PrivateDEX/PrivateDEXSettlement
5. **forceProvision/forceDeprovision** - Essential admin escape hatches for alpha phase
6. **Storage gap** - 40-slot gap for future upgrade storage

**Key Risks:**
1. **VP-M01** should be resolved before mainnet -- the KYC tier default must match the project's security requirements
2. **VP-M02** allows owner to trivially bypass all qualification gates, though owner trust is assumed
3. **VP-M03** creates a migration hazard if contracts are ever swapped; operational procedures must account for this

**Pre-Mainnet Checklist:**
- [ ] Fix VP-M01: Set `minKYCTier = 4` in initialize() or update design spec
- [ ] Fix VP-M02: Add bounds validation to `setThresholds`
- [ ] Document VP-M03: Create operational runbook for contract migration
- [ ] Consider VP-L01: Add PausableUpgradeable for emergency response
- [ ] Consider VP-L02: Add `maxValidators` cap aligned with OmniValidatorRewards iteration cap

---

*Report generated by Claude Opus 4.6 -- Round 7 pre-mainnet audit series*
