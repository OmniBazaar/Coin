# Security Audit Report: OmniParticipation

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniParticipation.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 1037
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (scoring/reputation only — no token custody)

## Executive Summary

OmniParticipation is a UUPS-upgradeable contract that implements OmniBazaar's 100-point Proof of Participation scoring system across 9 components: KYC trust, marketplace reputation, staking, referrals, publisher activity, forum participation, marketplace activity, community policing, and reliability. It queries OmniRegistration and OmniCore for cross-contract data and uses append-only arrays for activity history with VERIFIER_ROLE-gated verification.

The audit found **no Critical vulnerabilities** but **2 High-severity issues**: (1) unbounded array growth in 4 score recalculation functions creates a DoS attack vector where an adversary can permanently brick a target's score updates, and (2) missing UUPS storage gap. Additionally, multiple **Medium-severity specification mismatches** were found: KYC Tier 3 awards 20 points instead of the documented 15, staking score range is 0-24 (not 2-36 as documented), publisher activity ignores listing count thresholds, no time decay on scores, and self-reviews are possible. Both audit agents independently confirmed the unbounded array DoS as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 7 |
| Low | 4 |
| Informational | 2 |

## Findings

### [H-01] Unbounded Array Growth — DoS via Score Recalculation Gas Exhaustion

**Severity:** High
**Lines:** 410, 555, 637, 728
**Agents:** Both

**Description:**

Four internal functions iterate over entire history arrays every time they recalculate a score:
- `_updateMarketplaceReputation()` loops over `reviewHistory[user]`
- `_updateMarketplaceActivity()` loops over `transactionClaims[user]`
- `_updateCommunityPolicing()` loops over `reportHistory[user]`
- `_updateForumActivity()` loops over `forumContributions[user]`

These arrays are append-only — entries are only ever pushed, never removed. Once any array becomes large enough (thousands of entries), the gas cost of recalculation exceeds the block gas limit, permanently bricking the associated functions for that user.

**Exploit Scenario:**
```
1. Attacker registers and obtains unique transaction hashes (bytes32 values)
2. Attacker calls submitReview(targetUser, 1, hash) thousands of times with different hashes
3. reviewHistory[targetUser] grows to 50,000+ entries
4. Now verifyReview(targetUser, index) reverts due to out-of-gas in _updateMarketplaceReputation loop
5. Target user's reputation is permanently frozen
```

The attack costs only gas — the attacker just needs to be a registered user. The `claimMarketplaceTransactions()` function also has no batch size limit, allowing rapid array inflation.

**Impact:** A user's participation data becomes permanently frozen once arrays grow beyond gas limits. An attacker can deliberately bloat a target's review history to brick their score updates.

**Recommendation:** Replace O(n) full-array scans with incremental counters:
```solidity
mapping(address => uint256) public verifiedReviewCount;
mapping(address => uint256) public verifiedStarSum;

// In verifyReview(): increment counters instead of re-scanning
verifiedReviewCount[user]++;
verifiedStarSum[user] += review.stars;

// In _updateMarketplaceReputation(): use counters directly
uint256 avgStars = verifiedStarSum[user] / verifiedReviewCount[user];
```

Also add a batch size limit to `claimMarketplaceTransactions()`:
```solidity
if (transactionHashes.length > 50) revert BatchTooLarge();
```

---

### [H-02] Missing Storage Gap for UUPS Upgrades

**Severity:** High
**Lines:** End of storage declarations (after line 232)
**Agents:** Both

**Description:**

The contract uses UUPS upgradeable pattern but does not declare a `__gap` storage variable. Every other UUPS contract in the OmniBazaar codebase includes a storage gap (OmniCore: `[49]`, PrivateOmniCoin: `[46]`, etc.). Without a gap, adding new state variables in a future upgrade risks storage slot collision with existing data.

**Impact:** Any future upgrade adding state variables will corrupt existing participation scores, review histories, and all other stored data.

**Recommendation:** Add at the end of the storage declarations:
```solidity
/// @dev Reserved storage gap for future upgrades
uint256[50] private __gap;
```

---

### [M-01] KYC Tier 3 Returns 20 Points Instead of 15

**Severity:** Medium
**Lines:** 896
**Agents:** Both

**Description:**

Per the NatSpec and CLAUDE.md specification, KYC Tier 3 (Enhanced) should award 15 points. The code returns 20 for both Tier 4 and Tier 3:

```solidity
if (registration.hasKycTier4(user)) return 20;  // Correct: Tier 4 = 20
if (registration.hasKycTier3(user)) return 20;  // BUG: Tier 3 should be 15
```

The test suite at line 660 also validates the buggy behavior (`expect(kycTrust).to.equal(20)`), providing false assurance.

**Impact:** KYC Tier 3 users receive 5 extra points. The distinction between Enhanced KYC and Full KYC (with video call) is erased from the scoring perspective. Users may reach the 50-point validator threshold more easily, though `canBeValidator()` separately requires Tier 4.

**Recommendation:** Change line 896 to `return 15;`. Fix the test assertion to expect 15.

---

### [M-02] Staking Score Range Is 0-24, Not 2-36 as Documented

**Severity:** Medium
**Lines:** 907-928
**Agent:** Agent B

**Description:**

The documentation states staking score range is "2-36" (line 89), but the formula `(tier * 3) + (durationTier * 3)` with tier max=5 and durationTier max=3 yields a maximum of `(5 * 3) + (3 * 3) = 24`. Users with no active stake get 0. The actual range is 0-24.

This means the theoretical maximum total score is 88, not 100:
- Documented: 20 + 10 + 36 + 10 + 4 + 5 + 5 + 5 + 5 = 100
- Actual: 20 + 10 + 24 + 10 + 4 + 5 + 5 + 5 + 5 = 88

Achieving 100 points is mathematically impossible with the current formula.

**Impact:** The scoring system is 12 points less generous than documented. The 100-point clamping in `getScore()` is unreachable.

**Recommendation:** Either update the multipliers (e.g., use 5 and 7 for tier/duration to reach a max of 46, then cap at 36), or update the documentation to reflect the actual 0-24 range.

---

### [M-03] Self-Review Allowed — Users Can Inflate Own Reputation

**Severity:** Medium
**Lines:** 354-381
**Agent:** Agent B

**Description:**

`submitReview()` does not check that `msg.sender != reviewed`. A user can submit a 5-star review of themselves. While the VERIFIER_ROLE gate provides some protection, if verification is automated (checking transaction existence but not participant identity), self-reviews will be verified.

**Impact:** Users can fraudulently inflate their marketplace reputation score by up to +10 points.

**Recommendation:** Add `if (msg.sender == reviewed) revert CannotReviewSelf();` at the top of `submitReview()`.

---

### [M-04] Publisher Activity Ignores Listing Count Thresholds

**Severity:** Medium
**Lines:** 487-494
**Agent:** Agent B

**Description:**

The specification defines publisher activity as graduated: 100 listings=1pt, 1,000=2pt, 10,000=3pt, 100,000=4pt. The contract instead awards binary 0 or 4 points based solely on whether a service node heartbeat is fresh. There is no listing count measurement.

Any registered user who calls `submitServiceNodeHeartbeat()` once gets the full 4 publisher points, regardless of whether they actually serve any listings.

**Impact:** The publisher score incentive structure is completely absent. Users get maximum points with zero publisher activity.

**Recommendation:** Integrate with an on-chain listing count oracle, or have the VERIFIER_ROLE set publisher score based on off-chain listing count data.

---

### [M-05] No Time Decay on Scores Despite Specification Requirement

**Severity:** Medium
**Lines:** `_updateForumActivity()`, `_updateMarketplaceActivity()`, `_updateCommunityPolicing()`
**Agent:** Agent B

**Description:**

The specification states Forum Participation, Marketplace Activity, and Community Policing scores "decay over time if inactive." The contract implements none of this decay. Once a score is earned, it persists forever. The `lastUpdate` timestamp is stored but never used in any decay calculation.

A user who was active 3 years ago but has been completely inactive since retains their full score.

**Impact:** Scores become permanently inflated. Inactive users maintain artificially high participation scores, undermining the Proof of Participation philosophy.

**Recommendation:** Add a decay mechanism that reduces scores based on time elapsed since `lastUpdate` (e.g., reduce by 1 point per 90 days of inactivity, floor at 0).

---

### [M-06] `updatePublisherActivity()` Is Permissionless — Griefing Vector

**Severity:** Medium
**Lines:** 487-494
**Agents:** Both

**Description:**

`updatePublisherActivity(address user)` is a `public` function with no access control. Anyone can call it for any user. If a service node's heartbeat has expired (every 5 minutes), any third party can force-reset their `publisherActivity` to 0 at a strategically chosen moment — for example, right before a `canBeValidator` or `canBeListingNode` qualification check.

**Impact:** An adversary can zero a target's publisher score at critical moments, potentially dropping them below qualification thresholds.

**Recommendation:** Add `onlyRole(VERIFIER_ROLE)` modifier, or compute publisher activity dynamically in `getScore()` by checking `isServiceNodeOperational()` at read time.

---

### [M-07] Forum Contribution and Report Hashes Not Checked for Uniqueness

**Severity:** Medium
**Lines:** 674-698 (forum), 596-627 (reports)
**Agents:** Both

**Description:**

Unlike `submitReview()` and `claimMarketplaceTransactions()` which check `usedTransactions[hash]` to prevent duplicates, `claimForumContribution()` has no duplicate check on `contentHash`, and `submitReport()` has no check for duplicate `listingHash` per reporter. A user can submit the same contribution or report multiple times, inflating their unverified count and — if verification is automated — their verified scores.

**Impact:** Users can claim the same forum contribution repeatedly. With 51 verified duplicate contributions, they earn the maximum 5 forum points from a single actual contribution.

**Recommendation:** Add `usedContentHashes` and `usedReports` mappings to prevent duplicate submissions.

---

### [L-01] Reputation Average Uses Integer Truncation

**Severity:** Low
**Lines:** 432-441
**Agents:** Both

**Description:**

The average star calculation uses integer division (`totalStars / verifiedCount`), which truncates fractional results. An average of 4.9 stars becomes 4, scoring +5 instead of approaching +10. The specification calls for "gradient scaling between star levels," which this discrete step-function does not implement.

**Impact:** Reputation scores are systematically biased downward. Users with near-perfect reputations are grouped with moderately-rated users.

**Recommendation:** Use fixed-point arithmetic (multiply by 100 before division, then interpolate between discrete points).

---

### [L-02] Missing Zero-Address Check on `reviewed` in submitReview

**Severity:** Low
**Lines:** 354
**Agent:** Agent A

**Description:**

The `reviewed` parameter is not checked against `address(0)`. While `registration.isRegistered(address(0))` will likely return false, this depends on the OmniRegistration implementation.

**Recommendation:** Add `if (reviewed == address(0)) revert ZeroAddress();`

---

### [L-03] Empty Array Accepted in claimMarketplaceTransactions

**Severity:** Low
**Lines:** 505
**Agents:** Both

**Description:**

An empty array can be passed, which skips the loop, triggers a no-op recalculation, and emits a misleading `TransactionsClaimed(user, 0)` event.

**Recommendation:** Add `require(transactionHashes.length > 0, "empty array")`.

---

### [L-04] isServiceNodeOperational Subtraction Pattern

**Severity:** Low
**Lines:** 479
**Agent:** Agent A

**Description:**

`block.timestamp - lastServiceNodeHeartbeat[serviceNode]` is safe when heartbeat is 0 (returns a large number, correctly yielding `false`). No actual vulnerability — noted for completeness.

**Recommendation:** No action required.

---

### [I-01] Test Suite Validates Buggy KYC Tier 3 Behavior

**Severity:** Informational
**Agent:** Agent B

**Description:**

The test at line 660 asserts `expect(kycTrust).to.equal(20)` for KYC Tier 3, matching the buggy contract rather than the specification. This violates the project's own rule: "Don't modify the tests for the sake of getting the code to pass the tests."

**Recommendation:** Fix both the contract (M-01) and the test to use 15.

---

### [I-02] Score Component Maximum Mismatch

**Severity:** Informational
**Agent:** Agent B

**Description:**

The NatSpec comments list different ranges than the implementation produces. Line 89 claims "Staking Score (2-36)" but the actual range is 0-24. This could mislead integrators and auditors.

**Recommendation:** Update all NatSpec ranges to match the actual implementation.

---

## Static Analysis Results

**Solhint:** 0 errors, 92 warnings
- 66 gas-strict-inequalities (minor gas optimization)
- 12 code-complexity (functions with >7 branches)
- 7 not-rely-on-time (accepted — business requirement for heartbeat timeouts)
- 4 max-line-length
- 2 function-max-lines
- 1 no-global-import

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 22 raw findings -> 15 unique)
- Pass 6: Report generation

## Conclusion

OmniParticipation has **no Critical vulnerabilities** but has significant design issues that should be addressed before production deployment:

1. **Unbounded array DoS (H-01)** is the most urgent issue — an attacker can permanently brick a target's score updates by inflating their review history. The fix is straightforward: replace O(n) array scans with incremental counters.

2. **Missing storage gap (H-02)** is a standard UUPS deployment hazard.

3. **Multiple specification mismatches (M-01 through M-05)** indicate the contract was implemented from an evolving specification. KYC Tier 3 scoring, staking ranges, publisher thresholds, and time decay all differ from the documented design. These should be reconciled before deployment.

4. **Self-review (M-03)** and **content hash duplication (M-07)** allow gaming of the scoring system.

No tests exist for the DoS scenario (array inflation), which should be considered a deployment concern.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
