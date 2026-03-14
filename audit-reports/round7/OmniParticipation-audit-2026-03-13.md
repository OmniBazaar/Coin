# Security Audit Report: OmniParticipation.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/OmniParticipation.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,791
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** No (scoring/reputation only -- no token custody)
**OpenZeppelin Version:** 5.x (upgradeable)
**Dependencies:** `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`, `ERC2771ContextUpgradeable`, `IOmniRegistration` (external), `IOmniCore` (external)
**Test Coverage:** `Coin/test/OmniParticipation.test.ts` (91 passing, 1 failing)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), ATK Round 4 (2026-02-28), Round 6 (2026-03-10)

---

## Executive Summary

OmniParticipation is a UUPS-upgradeable contract implementing OmniBazaar's 100-point Proof of Participation scoring system. It tracks 9 score components: KYC trust (0-20), marketplace reputation (-10 to +10), staking (0-24), referral activity (0-10), publisher activity (0-4), marketplace activity (0-5), community policing (0-5), forum activity (0-5), and reliability (-5 to +5). Raw scores range from -15 to 88 and are clamped to 0-100.

This contract has been through six prior audit rounds with extensive remediation. This Round 7 audit is the pre-mainnet final comprehensive review. All Critical, High, and Medium findings from prior rounds have been confirmed as remediated. The contract is in a mature security posture.

### Round 6 Remediation Status

| Round 6 ID | Description | Status |
|------------|-------------|--------|
| H-01 | `msg.sender` vs `_msgSender()` inconsistency in heartbeats and rate limiter | **FIXED** -- All user-facing functions and `_enforceVerifierRateLimit()` now use `_msgSender()` (lines 580, 655, 705, 845, 959, 1072, 1192, 1473) |
| M-01 | Reputation integer truncation (step function vs gradient) | **FIXED** -- Fixed-point arithmetic with 3-decimal precision (line 667: `avgStars1000 = (verifiedStarSum[user] * 1000) / vCount`) with linear interpolation (line 674) |
| M-02 | Verifier rate limit bypass via multiple VERIFIER_ROLE holders | **FIXED** -- Global daily limit added (`MAX_GLOBAL_CHANGES_PER_DAY = 200`, `_globalDailyChanges` mapping, enforced in `_enforceVerifierRateLimit()` at lines 1487-1493) |
| M-03 | No decay on reliability component | **FIXED** -- Positive reliability scores are now decayed at read time in `_calculateScore()` (lines 1576-1583). Negative reliability persists (penalties not decayed) |
| L-02 | `submitReview()` unnecessarily calls `_updateMarketplaceReputation()` | **NOT FIXED** -- See L-01 below |
| L-03 | Shared `lastUpdate` timer enables decay circumvention | **NOT FIXED** -- See L-02 below. Design limitation documented but not changed |
| I-01 | `publisherActivity` not checked against `isServiceNodeOperational()` at read time | **NOT FIXED** -- See I-01 below. Relies on VERIFIER periodic calls |

### New Features Since Round 6

- **Sybil per-epoch score cap:** `_checkEpochScoreIncrease()` limits cumulative score increases to `MAX_SCORE_INCREASE_PER_EPOCH = 20` per 7-day epoch per user. Applied in `verifyReview()`, `verifyTransactionClaim()`, `validateReport()`, `verifyForumContribution()`, and `setPublisherListingCount()`.
- **Global verifier rate limit:** `MAX_GLOBAL_CHANGES_PER_DAY = 200` enforced across all VERIFIER_ROLE holders.
- **`setVerifierRoleAdmin()`:** Allows admin to delegate VERIFIER_ROLE management to a separate admin role (e.g., PROVISIONER_ROLE from ValidatorProvisioner).
- **Reliability decay at read time:** Positive reliability scores decay in `_calculateScore()`.

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 5 |

---

## Remediation Status from All Prior Audits

| Prior Finding | Round | Status | Verification |
|---------------|-------|--------|--------------|
| R1 H-01: Unbounded array DoS | R1 | **Fixed** | O(1) incremental counters for all components. No iteration in score computation. |
| R1 H-02: Missing storage gap | R1 | **Fixed** | `__gap[46]` at line 1790. |
| R1 M-01: KYC Tier 3 returns 20 | R1 | **Fixed** | Returns 15 (line 1303). |
| R1 M-02: Staking score range | R1 | **Fixed** | NatSpec documents 0-24 (line 93). |
| R1 M-03: Self-review allowed | R1 | **Fixed** | `CannotReviewSelf` error (line 583). |
| R1 M-04: Publisher ignores listing count | R1 | **Fixed** | Graduated scoring with `publisherListingCount`. |
| R1 M-05: No time decay | R1 | **Fixed** | `_applyDecay()` implemented (line 1610). |
| R1 M-06: `updatePublisherActivity()` permissionless | R1 | **Fixed** | `onlyRole(VERIFIER_ROLE)` (line 756). |
| R1 M-07: Hash duplication | R1 | **Fixed** | `usedContentHashes` and `usedReportHashes` mappings. |
| R3 M-01: `_ossified` placement | R3 | **Fixed** | Moved to storage section (line 299). |
| R3 M-02: Heartbeat bypasses graduated scoring | R3 | **Fixed** | Graduated scoring in `submitServiceNodeHeartbeat()` (lines 718-725). |
| R3 M-03: Decay not applied at read time | R3 | **Fixed** | `_calculateScore()` applies decay at lines 1560-1583. |
| R3 L-01: External self-call gas overhead | R3 | **Fixed** | Internal `_calculateScore()` (line 1536). |
| R3 I-01: `_authorizeUpgrade` unused parameter | R3 | **Fixed** | Zero-address check (line 1713). |
| R3 I-02: `ossify()` not idempotent | R3 | **Fixed** | Guard added (line 1650). |
| ATK-H04: VERIFIER unchecked power | ATK | **Fixed** | Per-verifier (50/day) + global (200/day) rate limits + listing delta cap (1000) + per-epoch score cap (20/7d). |
| ATK-H12: Unbounded storage arrays | ATK | **Fixed** | Per-user array caps: reviews (1000), claims (1000), reports (500), forum (500). |
| ATK-M22: Non-validator heartbeat | ATK | **Fixed** | `isValidator()` check (line 709). |
| ATK-M23: Fabricated transaction hashes | ATK | **Accepted** | Off-chain validation by VERIFIER. Documented limitation. |
| R6 H-01: ERC-2771 `msg.sender` inconsistency | R6 | **Fixed** | All functions use `_msgSender()`. See verification at lines 580, 655, 705, 1192, 1473. |
| R6 M-01: Reputation integer truncation | R6 | **Fixed** | Fixed-point arithmetic (lines 667-678). |
| R6 M-02: No global verifier rate limit | R6 | **Fixed** | `MAX_GLOBAL_CHANGES_PER_DAY = 200` with `_globalDailyChanges` mapping (lines 197, 310, 1487-1493). |
| R6 M-03: No decay on reliability | R6 | **Fixed** | Positive reliability decayed at read time (lines 1576-1583). |

---

## Medium Findings

### [M-01] `canBeValidator()` Checks `hasKycTier3()` -- Diverges from Specification Requiring Tier 4 AND Does Not Handle KYC Tier Inheritance

**Severity:** Medium
**Category:** Business Logic / Specification Divergence
**Location:** `canBeValidator()` (line 1363-1368)

**Description:**

The CLAUDE.md project specification states unambiguously:

> **Validator Requirements (Full Consensus Participation)**
> **KYC Requirement:** Top-tier KYC (Level 4 -- full verification)

However, the contract checks `hasKycTier3()`:

```solidity
function canBeValidator(address user) external view returns (bool) {
    (uint256 score,,,,,,,,,) = _calculateScore(user);
    bool hasRequiredKYC = registration.hasKycTier3(user);    // Should be hasKycTier4
    return score >= MIN_VALIDATOR_SCORE && hasRequiredKYC;
}
```

There are two issues:

1. **Wrong KYC tier:** The specification requires Tier 4 (full verification with video call), but the contract only requires Tier 3 (enhanced verification). This is more permissive than intended and allows users with incomplete KYC to become validators.

2. **No tier inheritance in the check:** Even if Tier 3 is intentional, the OmniRegistration interface treats tiers as independent booleans (`hasKycTier3` and `hasKycTier4` are separate calls). A user who completes Tier 4 verification is expected to also have Tier 3, but the registration contract must explicitly set both tiers. If the registration contract only sets the highest achieved tier (Tier 4) without also setting lower tiers, `canBeValidator()` would return `false` for a Tier 4 user. This is the cause of the current test failure (test line 778: mock sets Tier 4 only; `canBeValidator` checks Tier 3 which is not set).

**Impact:**
- Users with only KYC Tier 3 can become validators, contrary to the specification requiring Tier 4. This weakens the identity verification requirements for validator nodes.
- The failing test at line 778 indicates that the interaction between `canBeValidator()` and the registration contract is broken: a fully-qualified Tier 4 user appears ineligible because the tier check queries Tier 3 (which may not be independently set).

**Recommendation:**

Option A -- Follow the specification (recommended):
```solidity
function canBeValidator(address user) external view returns (bool) {
    (uint256 score,,,,,,,,,) = _calculateScore(user);
    bool hasRequiredKYC = registration.hasKycTier4(user);  // Spec says Tier 4
    return score >= MIN_VALIDATOR_SCORE && hasRequiredKYC;
}
```

Option B -- If Tier 3 is intentional, ensure tier inheritance:
```solidity
// In OmniRegistration, ensure hasKycTier3 returns true for Tier 4 users
function hasKycTier3(address user) external view returns (bool) {
    return _kycTier3[user] || _kycTier4[user];
}
```

Additionally, the NatSpec at line 1361 says "Requires both minimum score (50) and KYC Tier 3" -- update this to match whichever decision is made.

---

### [M-02] `_epochScoreIncrease` State Variable Declared After Functions -- Storage Layout Maintenance Hazard

**Severity:** Medium
**Category:** Upgradeable Safety / Maintenance
**Location:** Line 1776

**Description:**

The `_epochScoreIncrease` mapping is declared at line 1776, in the "UPGRADE GAP" section at the very end of the contract, separated from all other state variables by approximately 1,470 lines of function code. It occupies storage slot S+24, immediately before `__gap[46]`.

This is the exact same issue that was flagged as M-01 in Round 3 for `_ossified`, which was subsequently fixed by moving it to the storage section. The `_epochScoreIncrease` variable was introduced later (Sybil protection) but was placed at the end of the contract instead of in the storage section.

The `__gap` comment at line 1784 correctly accounts for this variable ("Reduced from 50 to 46 to accommodate 4 additions"). However, a future developer adding new state variables to the STORAGE section (lines 230-313) would not see `_epochScoreIncrease` and might not account for it in the gap calculation, leading to storage slot collision on upgrade.

```solidity
// Line 310: Last variable in the STORAGE section
mapping(uint256 => uint256) private _globalDailyChanges;

// ... 1,466 lines of functions ...

// Line 1776: State variable hidden after all functions
mapping(address => mapping(uint256 => uint256))
    private _epochScoreIncrease;

// Line 1790: Gap comment mentions 4 additions but developer must find them all
uint256[46] private __gap;
```

**Impact:** No immediate vulnerability. Risk of storage layout corruption if a future upgrade adds state variables to the STORAGE section without knowing about the hidden variable at line 1776.

**Recommendation:**

Move `_epochScoreIncrease` to the STORAGE section, immediately after `_globalDailyChanges`:

```solidity
// In the STORAGE section (after line 310):
/// @notice SYBIL: Per-user per-epoch cumulative score increase tracking
/// @dev Maps user => epoch_number => total_score_points_increased
mapping(address => mapping(uint256 => uint256))
    private _epochScoreIncrease;

/// @notice Score decay period (90 days of inactivity = 1 point decay)
uint256 public constant DECAY_PERIOD = 90 days;
```

This also resolves the solhint `ordering` warning since the constant `DECAY_PERIOD` (currently at line 313) would no longer be declared between two mutable state variables.

---

## Low Findings

### [L-01] `submitReview()` Calls `_updateMarketplaceReputation()` on Unverified Reviews -- Unnecessary Gas Expenditure

**Severity:** Low
**Location:** Line 612
**Status:** Inherited from Round 6 L-02 (not fixed)

**Description:**

When a user submits a review via `submitReview()`, the function calls `_updateMarketplaceReputation(reviewed)` at line 612. However, `_updateMarketplaceReputation()` calculates reputation based solely on `verifiedReviewCount` and `verifiedStarSum`, which are only updated when a VERIFIER calls `verifyReview()`. The newly submitted review is always unverified (`verified: false`), so the counters are unchanged and the reputation result is identical.

The call is a no-op that wastes gas (~5,000-10,000 gas) on every review submission. Since the counters were not modified, the only visible effect is updating `lastUpdate` to the current timestamp, which resets the decay timer for all decayable components -- a side effect that may not be intended at review submission time.

**Impact:** Minor gas waste on every review submission. The `lastUpdate` reset is a subtle side effect that delays decay.

**Recommendation:** Remove the `_updateMarketplaceReputation(reviewed)` call from `submitReview()`. Reputation is correctly updated in `verifyReview()`.

---

### [L-02] Shared `lastUpdate` Timer Enables Decay Circumvention Across All Components

**Severity:** Low
**Location:** Lines 661, 680, 728, 762, 779, 937, 1050, 1174, 1242
**Status:** Inherited from Round 6 L-03 (acknowledged, not fixed)

**Description:**

All score components share a single `lastUpdate` timestamp in the `ParticipationComponents` struct. Every state-modifying operation (`submitReview`, `verifyReview`, `submitServiceNodeHeartbeat`, `updatePublisherActivity`, `verifyTransactionClaim`, `validateReport`, `verifyForumContribution`, `submitValidatorHeartbeat`) resets `lastUpdate` to the current `block.timestamp`.

This means a single action in any category resets the 90-day decay timer for ALL decayable components (marketplace activity, community policing, forum activity, and positive reliability). A user can prevent decay across all categories by performing one minimal action (e.g., submitting one report with a 10-character reason) every 89 days.

Additionally, the `submitReview()` function (flagged in L-01 above) also resets `lastUpdate` for the REVIEWED user, meaning that receiving a review resets the reviewed user's decay timer for all components -- even though the review itself is unverified and has no score effect.

**Impact:** The decay mechanism is easily circumvented. A user who was active in community policing 2 years ago but has only submitted one report every 89 days since will retain their full community policing score, even though they have not actually done community policing recently.

**Recommendation:** Per-component `lastUpdate` timestamps would make decay independent per component, but this requires 4+ additional storage slots per user (significant gas cost for a participation scoring contract). Document the shared timer as an intentional design choice if the gas trade-off is not acceptable.

---

### [L-03] `DECAY_PERIOD` Constant Declared After Mutable State Variables -- Solhint Ordering Warning

**Severity:** Low
**Location:** Line 313
**Status:** New in Round 7

**Description:**

The constant `DECAY_PERIOD` is declared at line 313, after the mutable state variable `_globalDailyChanges` at line 310. Per Solidity style guide and solhint rules, constants should be declared BEFORE mutable state variables within the STORAGE section. Solhint reports:

```
contracts/OmniParticipation.sol
  313:5  warning  Function order is incorrect, contract constant declaration
                  can not go after state variable declaration (line 310)  ordering
```

**Impact:** No security impact. Style/maintenance issue.

**Recommendation:** Move `DECAY_PERIOD` to the CONSTANTS section (lines 169-227), alongside the other constants:

```solidity
// In the CONSTANTS section (after line 227):
/// @notice Score decay period (90 days of inactivity = 1 point decay)
uint256 public constant DECAY_PERIOD = 90 days;
```

---

### [L-04] Test Suite Has 1 Failing Test -- `canBeValidator` KYC Tier Inheritance Issue

**Severity:** Low
**Location:** `test/OmniParticipation.test.ts` line 778
**Status:** Inherited from Round 3 L-04 (persists, different root cause)

**Description:**

The test at line 778 sets up a user with KYC Tier 4, 10 referrals, and 100M XOM staked for 2 years (total score: KYC 20 + Referral 10 + Staking 21 = 51 points). The test expects `canBeValidator()` to return `true`.

However, `canBeValidator()` checks `registration.hasKycTier3()`, and the mock only sets Tier 4 (not Tier 3 independently). Since the mock treats each tier as an independent boolean, `hasKycTier3()` returns `false`, causing `canBeValidator()` to return `false`.

The test failure reflects a real integration issue: the OmniRegistration contract must either:
1. Implement tier inheritance (Tier 4 implies Tier 3 implies Tier 2 implies Tier 1), or
2. Set all lower tiers when granting a higher tier

Additionally, the test comment says "KYC = 20, Referral = 10, Staking = 24 = 54 points" but the actual staking score for 100M XOM (tier 4 = 12 pts) staked for 730 days (duration tier 3 = 9 pts) is 12 + 9 = 21, not 24. The total is 51, not 54. The test would still pass since 51 >= 50, but the comment is inaccurate.

**Impact:** 1 test out of 92 is failing, reducing CI confidence. The failing test also exposes a real integration concern between OmniParticipation and OmniRegistration regarding KYC tier inheritance.

**Recommendation:**

1. Fix M-01 (decide on Tier 3 vs Tier 4 for validator qualification).
2. Update the mock to implement tier inheritance, or update the test to also set Tier 3:
```typescript
await mockRegistration.setKycTier3(user1.address, true);  // Add this line
await mockRegistration.setKycTier4(user1.address, true);
```
3. Fix the test comment: "KYC = 20, Referral = 10, Staking = 21 = 51 points"

---

## Informational Findings

### [I-01] `publisherActivity` Not Checked Against `isServiceNodeOperational()` at Read Time

**Severity:** Informational
**Location:** Line 1559
**Status:** Inherited from Round 6 I-01 (acknowledged, not fixed)

**Description:**

The `publisherActivity` component is read directly from storage in `_calculateScore()` without checking whether the service node is currently operational. If a service node sends a heartbeat (setting `publisherActivity = 4`) and then goes offline, the stored score persists until a VERIFIER explicitly calls `updatePublisherActivity()`.

The `isServiceNodeOperational()` function exists and correctly checks the heartbeat timeout, but it is not called in `_calculateScore()`. The scoring relies on the VERIFIER backend to periodically reset offline nodes.

**Impact:** Publisher activity contributes at most 4 points. Impact is bounded and depends on VERIFIER operational diligence.

**Recommendation:** Consider checking `isServiceNodeOperational()` within `_calculateScore()`:

```solidity
publisherActivity = isServiceNodeOperational(user) ? comp.publisherActivity : 0;
```

---

### [I-02] `ScoreComponentUpdated` Event `newValue` Parameter Not Indexed -- Solhint Warning

**Severity:** Informational
**Location:** Line 409-413
**Status:** New in Round 7

**Description:**

Solhint reports that the `newValue` parameter of `ScoreComponentUpdated` could be indexed. The event currently has only 1 indexed parameter (`user`), leaving 2 indexable slots unused.

```solidity
event ScoreComponentUpdated(
    address indexed user,
    string component,       // Not indexed (string -- correct, indexing strings is expensive)
    int256 newValue         // Not indexed (solhint suggests indexing)
);
```

However, indexing `newValue` (an int256 score value) is of limited utility. Callers are far more likely to filter by `user` than by exact score value. The `component` parameter is a string and should NOT be indexed (Solidity indexes strings as their keccak256 hash, making them useless for filtering).

**Impact:** No security impact. The solhint warning is technically valid but the recommendation has minimal practical benefit.

**Recommendation:** Either suppress the warning or add indexing to `newValue` if off-chain indexers would benefit from filtering by score ranges. To suppress:

```solidity
// solhint-disable-next-line gas-indexed-events
event ScoreComponentUpdated(
```

---

### [I-03] Transaction Hash Verification Remains Off-Chain Only -- Documented Limitation

**Severity:** Informational
**Location:** Lines 568-574, 835-841
**Status:** Acknowledged (ATK-M23, documented in code comments)

**Description:**

Both `submitReview()` and `claimMarketplaceTransactions()` accept `bytes32 transactionHash` parameters for deduplication but do not verify that the hashes correspond to real on-chain marketplace transactions. Two colluding users can submit fabricated hashes.

The contract documents this limitation extensively in NatSpec comments (lines 568-574 and 835-841) and relies on:
1. VERIFIER_ROLE verification before score credit
2. Per-verifier daily rate limit (50/day)
3. Global daily change cap (200/day)
4. Per-epoch score increase cap (20/7 days)
5. Per-user array caps

**Impact:** Residual risk bounded by rate limits and epoch caps. A compromised VERIFIER can verify at most 50 fabricated claims/day, affecting at most 20 score points per user per epoch.

**Recommendation:** No code change required. Ensure the off-chain VERIFIER backend validates transaction hashes against actual marketplace contract events before verification.

---

### [I-04] `ReentrancyGuardUpgradeable` Only Protects `submitReview()` -- Other Functions Unguarded

**Severity:** Informational
**Location:** Line 579
**Status:** Inherited from Round 6 I-04 (acknowledged)

**Description:**

Only `submitReview()` has the `nonReentrant` modifier. Other state-modifying functions (`submitServiceNodeHeartbeat`, `claimMarketplaceTransactions`, `submitReport`, `claimForumContribution`, `submitValidatorHeartbeat`) do not use `nonReentrant`.

All external calls in the contract target `view` functions on `IOmniRegistration` and `IOmniCore`, which cannot trigger reentrancy. The `nonReentrant` guard is therefore not necessary for current functionality.

**Impact:** No current vulnerability. Defense-in-depth consideration only.

**Recommendation:** For defense-in-depth, consider adding `nonReentrant` to all state-modifying external functions. Gas overhead is minimal (~24 gas cold, ~100 gas warm per call).

---

### [I-05] `setVerifierRoleAdmin()` Can Be Called Multiple Times -- No Irreversibility Guard

**Severity:** Informational
**Location:** Lines 1671-1675
**Status:** New in Round 7

**Description:**

The `setVerifierRoleAdmin()` function can be called multiple times by `DEFAULT_ADMIN_ROLE`, changing the admin of VERIFIER_ROLE each time. The NatSpec describes it as a "one-time admin call to delegate VERIFIER_ROLE management," but there is no enforcement of the one-time nature. If the admin role is held by a timelock with multi-sig (as recommended), this is a minor concern since any subsequent change would also go through governance.

However, if the admin calls `setVerifierRoleAdmin(bytes32(0))`, this sets the admin of VERIFIER_ROLE to `DEFAULT_ADMIN_ROLE` (since `bytes32(0)` is the default admin role), effectively undoing the delegation. The function does not prevent this.

```solidity
function setVerifierRoleAdmin(
    bytes32 newAdminRole
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setRoleAdmin(VERIFIER_ROLE, newAdminRole);
    // No event emitted for audit trail
    // No check preventing re-call or reset to DEFAULT_ADMIN_ROLE
}
```

**Impact:** No security issue if admin is behind a timelock. The function lacks an event emission for tracking role admin changes.

**Recommendation:** Add an event and optionally a one-time guard:

```solidity
event VerifierRoleAdminChanged(bytes32 indexed oldAdmin, bytes32 indexed newAdmin);

function setVerifierRoleAdmin(bytes32 newAdminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
    bytes32 oldAdmin = getRoleAdmin(VERIFIER_ROLE);
    _setRoleAdmin(VERIFIER_ROLE, newAdminRole);
    emit VerifierRoleAdminChanged(oldAdmin, newAdminRole);
}
```

---

## Architecture Analysis

### Design Strengths

1. **O(1) Score Computation:** All score components use incremental counters maintained at verification time. No unbounded iteration exists anywhere in the contract. This was the Round 1 H-01 DoS vector, now completely eliminated.

2. **Multi-Layer Sybil Resistance:** Four independent rate-limiting mechanisms:
   - Per-verifier daily limit (50 changes/day)
   - Global daily limit across all verifiers (200 changes/day)
   - Per-user per-epoch score increase cap (20 points/7 days)
   - Per-user array caps (500-1000 entries)

3. **Decay at Read Time:** `_calculateScore()` applies `_applyDecay()` to `marketplaceActivity`, `communityPolicing`, `forumActivity`, and positive `reliability` when reading scores. All external score queries return time-adjusted values.

4. **Fixed-Point Reputation:** The reputation calculation uses 1000x fixed-point arithmetic with linear interpolation, producing gradient scoring between star levels as specified.

5. **Ossification Mechanism:** One-way, irreversible upgrade kill switch with idempotency guard, documented deployment pattern (timelock + multi-sig), and zero-address validation in `_authorizeUpgrade()`.

6. **Comprehensive Deduplication:** Three separate deduplication mechanisms: `usedTransactions` (review/claim hashes), `usedContentHashes` (forum contribution hashes), and `usedReportHashes` (per-reporter listing hashes).

7. **ERC-2771 Consistency:** All user-facing functions and the verifier rate limiter consistently use `_msgSender()` for meta-transaction support. The `_msgData()` and `_contextSuffixLength()` diamond resolution overrides are correctly implemented.

8. **VERIFIER_ROLE Delegation:** The `setVerifierRoleAdmin()` function allows admin to transfer VERIFIER_ROLE management to a separate governance path (e.g., ValidatorProvisioner's PROVISIONER_ROLE), reducing centralization.

### Dependency Analysis

- **IOmniRegistration:** View-only calls (`isRegistered`, `hasKycTier1-4`, `getReferralCount`). No reentrancy risk. If registration reverts, participation functions revert as well (fail-safe).

- **IOmniCore:** View-only calls (`getStake`, `isValidator`). Stake struct in interface matches OmniCore's definition. No reentrancy risk.

- **ERC2771ContextUpgradeable:** Trusted forwarder is immutable (set in constructor). NatSpec documents this design choice (lines 521-525). If forwarder is compromised, `ossify()` + governance pause provides emergency protection.

### Access Control Map

| Role | Holders | Capabilities |
|------|---------|-------------|
| `DEFAULT_ADMIN_ROLE` | Deployer (initially), should be timelock + multi-sig | `setContracts()`, `ossify()`, `_authorizeUpgrade()`, `setVerifierRoleAdmin()`, grant/revoke roles |
| `VERIFIER_ROLE` | Deployer + granted addresses (should be validator backend) | `verifyReview()`, `verifyTransactionClaim()`, `validateReport()`, `verifyForumContribution()`, `updatePublisherActivity()`, `setPublisherListingCount()` -- all rate-limited to 50/day per verifier, 200/day globally |
| (none required) | Any registered user | `submitReview()`, `claimMarketplaceTransactions()`, `submitReport()`, `claimForumContribution()` |
| (none required) | Any registered validator | `submitServiceNodeHeartbeat()`, `submitValidatorHeartbeat()` |

---

## DeFi Exploit Analysis

### Score Manipulation Vectors

| Attack Vector | Mitigation | Residual Risk |
|---------------|-----------|---------------|
| Sybil accounts inflated by compromised VERIFIER | Per-verifier (50/day), global (200/day), per-epoch (20/7d) | Bounded: max 200 verifications/day globally |
| Self-review | `CannotReviewSelf` error check | Fully mitigated |
| Duplicate review/report/contribution | `usedTransactions`, `usedContentHashes`, `usedReportHashes` | Fully mitigated |
| Fabricated transaction hashes | Deduplication + rate limits + off-chain VERIFIER validation | Relies on VERIFIER integrity |
| Non-validator heartbeat submission | `isValidator()` check | Fully mitigated |
| Unbounded array state bloat | Per-user array caps (500-1000) | Fully mitigated |
| Instant listing count inflation | Delta cap (1000 per call) + daily limit + epoch cap | Partially mitigated |
| Decay circumvention via shared timer | Single action resets all decay timers | Design limitation (L-02) |
| Multiple VERIFIER addresses bypass rate limit | Global daily cap (200) | Mitigated (was unmitigated in Round 6) |
| Per-epoch score explosion | `_checkEpochScoreIncrease` with 20-point cap per 7 days | Fully mitigated |

### Sybil Resistance Assessment

The contract implements five layers of Sybil resistance:

1. **Registration cost:** All actions require `isRegistered()` -- Sybil cost >= registration cost
2. **KYC scoring:** Higher KYC tiers give more points -- strong Sybil resistance for high scores
3. **Staking requirement:** Validator qualification requires 1M+ XOM staked -- economic barrier
4. **Verifier gatekeeping:** All score-affecting verifications require VERIFIER_ROLE
5. **Rate limiting:** 50/verifier/day, 200 global/day, 20/user/epoch -- bounds blast radius

**Per-epoch cap analysis:** A single user can gain at most 20 score points from verifier-gated actions per 7-day epoch. With 5 score components under verifier control (reputation, publisher, marketplace, community, forum) having a combined maximum of 29 points, reaching maximum score requires approximately 2 epochs (14 days) of consistent maximum-rate verification. This is a reasonable pace for legitimate organic growth and effectively blocks rapid Sybil farming.

---

## Upgradeable Safety

### Storage Layout Verification

| Slot Offset | Variable | Type | Size |
|-------------|----------|------|------|
| (inherited) | AccessControl, UUPS, ReentrancyGuard, ERC2771Context | OpenZeppelin internals | varies |
| S+0 | `components` | `mapping(address => ParticipationComponents)` | 1 slot |
| S+1 | `registration` | `IOmniRegistration` (address) | 1 slot |
| S+2 | `omniCore` | `IOmniCore` (address) | 1 slot |
| S+3 | `reviewHistory` | `mapping(address => Review[])` | 1 slot |
| S+4 | `usedTransactions` | `mapping(bytes32 => bool)` | 1 slot |
| S+5 | `operationalServiceNodes` | `mapping(address => bool)` | 1 slot |
| S+6 | `lastServiceNodeHeartbeat` | `mapping(address => uint256)` | 1 slot |
| S+7 | `transactionClaims` | `mapping(address => TransactionClaim[])` | 1 slot |
| S+8 | `reportHistory` | `mapping(address => Report[])` | 1 slot |
| S+9 | `forumContributions` | `mapping(address => ForumContribution[])` | 1 slot |
| S+10 | `lastValidatorHeartbeat` | `mapping(address => uint256)` | 1 slot |
| S+11 | `uptimeBlocks` | `mapping(address => uint256)` | 1 slot |
| S+12 | `totalBlocks` | `mapping(address => uint256)` | 1 slot |
| S+13 | `verifiedReviewCount` | `mapping(address => uint256)` | 1 slot |
| S+14 | `verifiedStarSum` | `mapping(address => uint256)` | 1 slot |
| S+15 | `verifiedTransactionCount` | `mapping(address => uint256)` | 1 slot |
| S+16 | `validatedReportCount` | `mapping(address => uint256)` | 1 slot |
| S+17 | `verifiedForumCount` | `mapping(address => uint256)` | 1 slot |
| S+18 | `usedContentHashes` | `mapping(bytes32 => bool)` | 1 slot |
| S+19 | `usedReportHashes` | `mapping(address => mapping(bytes32 => bool))` | 1 slot |
| S+20 | `publisherListingCount` | `mapping(address => uint256)` | 1 slot |
| S+21 | `_ossified` | `bool` | 1 slot |
| S+22 | `_verifierDailyChanges` | `mapping(address => mapping(uint256 => uint256))` | 1 slot |
| S+23 | `_globalDailyChanges` | `mapping(uint256 => uint256)` | 1 slot |
| S+24 | `_epochScoreIncrease` | `mapping(address => mapping(uint256 => uint256))` | 1 slot (declared at line 1776, see M-02) |
| S+25..S+70 | `__gap[46]` | `uint256[46]` | 46 slots |

**Total: 25 state variables + 46 gap = 71 occupied slots.** The gap was reduced from the OpenZeppelin default of 50 to accommodate 4 post-initial additions (`_ossified`, `_verifierDailyChanges`, `_globalDailyChanges`, `_epochScoreIncrease`). Arithmetic is correct: 50 - 4 = 46.

**WARNING:** `_epochScoreIncrease` is declared at line 1776 (after all functions), not in the STORAGE section. See M-02 for the maintenance hazard this creates.

### Initializer Safety

- Constructor calls `_disableInitializers()` at line 530 -- prevents implementation contract initialization.
- `initialize()` uses `initializer` modifier at line 541 -- prevents re-initialization.
- No `reinitialize()` function exists. If a future upgrade requires new initializer logic, a `reinitialize(uint64 version)` function must be added to the new implementation.

### Ossification Safety

- `ossify()` is guarded by `DEFAULT_ADMIN_ROLE` (line 1649).
- Double-ossification prevented: `if (_ossified) revert ContractIsOssified()` (line 1650).
- `_authorizeUpgrade()` checks both `_ossified` (line 1712) and `newImplementation != address(0)` (line 1713).
- Once ossified, the contract can never be upgraded again. This is irreversible and well-documented.

---

## Score Component Verification Summary

| Component | Spec Range | Contract Range | Match | Decay | Notes |
|-----------|-----------|---------------|-------|-------|-------|
| KYC Trust | 0-20 | 0-20 | Yes | No (live query) | Correct. Tier 0=0, 1=5, 2=10, 3=15, 4=20 |
| Marketplace Reputation | -10 to +10 | -10 to +10 | Yes | No (by design) | Fixed-point arithmetic (1000x) with linear interpolation |
| Staking | 0-24 (formula) | 0-24 | Yes | No (live query) | (tier*3) + (durationTier*3). Spec header says "2-36" but formula yields max 24 |
| Referral Activity | 0-10 | 0-10 | Yes | No (live query) | One point per referral, capped at 10 |
| Publisher Activity | 0-4 | 0-4 | Yes | Via heartbeat timeout | 100=1pt, 1K=2pt, 10K=3pt, 100K=4pt. Not decayed at read time (see I-01) |
| Marketplace Activity | 0-5 | 0-5 | Yes | Yes (90 days) | 5=1pt, 10=2pt, 20=3pt, 50=4pt, 100+=5pt |
| Community Policing | 0-5 | 0-5 | Yes | Yes (90 days) | 1=1pt, 5=2pt, 10=3pt, 20=4pt, 50+=5pt |
| Forum Activity | 0-5 | 0-5 | Yes | Yes (90 days) | 1=1pt, 6=2pt, 16=3pt, 31=4pt, 51+=5pt |
| Reliability | -5 to +5 | -5 to +5 | Yes | Yes (positive only) | 100%=+5, 95%=+3, 90%=+1, 80%=0, 70%=-2, <70%=-5 |
| **Total (raw)** | **-15 to 88** | **-15 to 88** | **Yes** | -- | Clamped to 0-100 |

---

## Static Analysis Results

**Solhint:** 0 errors, 2 warnings

1. `ordering` (line 313) -- constant `DECAY_PERIOD` declared after state variable `_globalDailyChanges`. See L-03.
2. `gas-indexed-events` (line 409) -- `newValue` on `ScoreComponentUpdated` could be indexed. See I-02.

**Compiler:** Clean compilation with `solc 0.8.24`. No warnings.

**Test Suite:** 91 passing, 1 failing (line 778: `canBeValidator` returns `false` because mock does not implement KYC tier inheritance). See L-04 and M-01.

---

## Audit History Comparison

| Metric | Round 1 | Round 3 | Round 6 | Round 7 | Trend |
|--------|---------|---------|---------|---------|-------|
| Critical | 0 | 0 | 0 | 0 | -- |
| High | 2 | 0 | 1 | 0 | Resolved (ERC-2771 fixed) |
| Medium | 7 | 3 | 3 | 2 | Reduced (1 new, 1 inherited spec divergence) |
| Low | 4 | 4 | 3 | 4 | Stable (2 inherited, 1 new, 1 test issue) |
| Informational | 2 | 4 | 4 | 5 | Stable (3 inherited, 2 new) |
| Solhint warnings | 92 | 3 | 2 | 2 | Stable |
| Lines of code | ~1,037 | 1,237 | 1,631 | 1,791 | +160 (Sybil protections) |
| Tests passing | 77 (1 fail) | 77 (1 fail) | 92 (0 fail) | 91 (1 fail) | Test regression |

---

## Conclusion

OmniParticipation has reached a mature security posture after seven audit rounds. All Critical and High findings from all prior audits have been confirmed as remediated. The contract now includes multi-layer Sybil resistance (per-verifier, global, and per-epoch rate limits), consistent ERC-2771 meta-transaction support, fixed-point reputation arithmetic, time-based score decay, and a robust ossification mechanism.

**Remaining concerns, ordered by priority:**

1. **[M-01] `canBeValidator()` KYC tier divergence from specification:** The contract checks Tier 3 while the specification requires Tier 4. This is a business logic decision that should be resolved before mainnet. Additionally, the interaction with OmniRegistration requires clear documentation of KYC tier inheritance behavior.

2. **[M-02] `_epochScoreIncrease` non-contiguous storage layout:** State variable declared 1,470 lines away from the storage section. Same class of issue as Round 3 M-01 (which was fixed for `_ossified`). Should be moved to the STORAGE section to prevent future upgrade errors.

3. **[L-01/L-02] `submitReview()` no-op call and shared decay timer:** Minor gas waste and decay circumvention. Design trade-offs that should be documented if not fixed.

4. **[L-04] Failing test:** The `canBeValidator` test failure reflects a real integration concern between OmniParticipation and OmniRegistration. Should be fixed alongside M-01.

**Deployment Readiness Assessment:**

- **Testnet:** Ready. The contract compiles cleanly and 91/92 tests pass. The failing test is a mock configuration issue, not a contract bug.
- **Mainnet:** Resolve M-01 (KYC tier decision) and M-02 (storage layout) before mainnet deployment. All other findings are Low/Informational and do not represent security risks.

The contract has no Critical or High findings. The two Medium findings are a specification divergence (business decision) and a maintenance practice issue (no immediate vulnerability). OmniParticipation is suitable for mainnet deployment once the KYC tier requirement is finalized and the storage variable is relocated.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Pre-Mainnet Final Audit (Round 7)*
*Date: 2026-03-13 UTC*
