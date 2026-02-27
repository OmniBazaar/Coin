# Security Audit Report: OmniParticipation (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniParticipation.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,237
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** No (scoring/reputation only -- no token custody)
**OpenZeppelin Version:** 5.x (upgradeable)
**Dependencies:** `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`, `IOmniRegistration` (external), `IOmniCore` (external)
**Test Coverage:** `Coin/test/OmniParticipation.test.ts` (77 passing, 1 failing)
**Prior Audit:** Round 1 (2026-02-21) -- 0 Critical, 2 High, 7 Medium, 4 Low, 2 Informational

---

## Executive Summary

OmniParticipation is a UUPS-upgradeable contract implementing OmniBazaar's 100-point Proof of Participation scoring system across 9 components: KYC trust, marketplace reputation, staking, referrals, publisher activity, forum participation, marketplace activity, community policing, and reliability. Since the Round 1 audit, the contract has undergone substantial remediation addressing all High and most Medium findings. This Round 3 audit evaluates the current state including the new ossification mechanism.

**Round 1 Remediation Summary:**

| Round 1 ID | Description | Status |
|------------|-------------|--------|
| H-01 | Unbounded array DoS | **FIXED** -- Incremental O(1) counters added |
| H-02 | Missing storage gap | **FIXED** -- `uint256[49] private __gap` added |
| M-01 | KYC Tier 3 returns 20 instead of 15 | **FIXED** -- Returns 15 (line 1031) |
| M-02 | Staking score range 0-24 vs documented 2-36 | **FIXED** -- NatSpec updated to 0-24 |
| M-03 | Self-review allowed | **FIXED** -- `CannotReviewSelf` error added (line 445) |
| M-04 | Publisher activity ignores listing count | **FIXED** -- Graduated scoring with `publisherListingCount` |
| M-05 | No time decay on scores | **FIXED** -- `_applyDecay()` function added |
| M-06 | `updatePublisherActivity()` permissionless | **FIXED** -- Now `onlyRole(VERIFIER_ROLE)` |
| M-07 | Forum/report hash duplication | **FIXED** -- `usedContentHashes` and `usedReportHashes` added |

**New features since Round 1:**
- Ossification mechanism (`ossify()`, `isOssified()`, `_ossified` state variable)
- Decay mechanism (`_applyDecay()`, `DECAY_PERIOD`)
- Incremental counters for all score components
- Batch size limits (`MAX_BATCH_SIZE = 100`)
- Publisher listing count oracle (`setPublisherListingCount()`)
- Duplicate content/report hash prevention

The Round 3 audit found **0 Critical**, **0 High**, **3 Medium**, **4 Low**, and **4 Informational** findings. The contract is in substantially better shape than Round 1.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Informational | 4 |

---

## Architecture Analysis

### Design Strengths

1. **O(1) Score Updates:** All four previously-unbounded array scan functions (`_updateMarketplaceReputation`, `_updateMarketplaceActivity`, `_updateCommunityPolicing`, `_updateForumActivity`) now use incremental counters maintained at verification time. This completely eliminates the Round 1 DoS vector.

2. **Ossification Mechanism:** The `ossify()` function provides a one-way, irreversible kill switch for the UUPS upgrade path. Once called, `_authorizeUpgrade()` will always revert with `ContractIsOssified()`. This is an excellent governance pattern for mature contracts.

3. **Proper Access Control:** All admin functions are gated by appropriate roles (`DEFAULT_ADMIN_ROLE` or `VERIFIER_ROLE`). The previously-permissionless `updatePublisherActivity()` is now correctly restricted.

4. **Comprehensive Input Validation:** Zero-address checks, registration checks, duplicate-hash prevention, batch size limits, and range validation on star ratings are all present.

5. **Time Decay:** The `_applyDecay()` function implements the specified decay behavior (1 point per 90 days of inactivity) with correct floor-at-zero behavior.

6. **Custom Errors:** Gas-efficient error handling throughout, with descriptive error names.

### Dependency Analysis

- **IOmniRegistration:** External calls to `isRegistered()`, `hasKycTier1-4()`, `getReferralCount()`. All are `view` functions, so reentrancy is not a concern. If the registration contract reverts, the participation function reverts as well -- this is acceptable fail-safe behavior.

- **IOmniCore:** External calls to `getStake()` and `isValidator()`. Same `view`-only pattern. The `Stake` struct is defined in the interface, matching the OmniCore implementation.

---

## Findings

### [M-01] `_ossified` State Variable Declared After Functions -- Storage Slot Risk on Re-deployment

**Severity:** Medium
**Lines:** 1227
**Status:** New in Round 3

**Description:**

The `_ossified` state variable is declared at line 1227, well after all other state variables (lines 183-243) and after all functions. While Solidity assigns storage slots based on declaration order and this will work correctly in a *single deployment*, there is an important subtlety:

The variable ordering is:
1. `components` (slot depends on inheritance) through `publisherListingCount` (lines 183-243)
2. `_ossified` (line 1227)
3. `__gap[49]` (line 1236)

The comment on line 1234 says "Reduced from 50 to 49 to accommodate _ossified," which is correct arithmetic. However, placing `_ossified` physically far from the other state variables -- separated by ~980 lines of function code -- creates a maintenance hazard. A future developer adding a new state variable in the "STORAGE" section (between lines 180-247) would unknowingly shift `_ossified` to a different slot, corrupting the gap calculation.

Additionally, the solhint `ordering` warning at line 246 (constant after state variables) reflects a broader organizational issue in the storage declarations section.

**Impact:** No immediate vulnerability. Risk of storage corruption in future upgrades if developers add state variables without understanding the non-contiguous layout.

**Recommendation:** Move `_ossified` declaration to the storage section (between lines 243 and 246), immediately before or after the other state variables. Group all storage declarations together:

```solidity
// After line 243 (publisherListingCount):
/// @notice Whether contract is ossified (permanently non-upgradeable)
bool private _ossified;

/// @notice Score decay period (90 days of inactivity = 1 point decay)
uint256 public constant DECAY_PERIOD = 90 days;

/// @dev Reserved storage gap for future upgrades (49 = 50 - 1 for _ossified)
uint256[49] private __gap;
```

---

### [M-02] `submitServiceNodeHeartbeat()` Bypasses Graduated Publisher Scoring

**Severity:** Medium
**Lines:** 540-553
**Status:** Partially inherited from Round 1 M-04

**Description:**

The Round 1 M-04 fix introduced graduated scoring in `updatePublisherActivity()` (line 573), which correctly checks `publisherListingCount` and awards 0-4 points based on thresholds (100/1K/10K/100K listings). However, `submitServiceNodeHeartbeat()` at line 549 still directly sets `publisherActivity = 4`, bypassing the graduated scoring entirely.

Any registered user who calls `submitServiceNodeHeartbeat()` gets the maximum 4 publisher points regardless of their actual listing count. The graduated scoring in `updatePublisherActivity()` only takes effect if a VERIFIER explicitly calls it *after* the heartbeat, which would then overwrite the 4 back to the correct value. But between heartbeat submissions, the user retains the inflated score.

```solidity
// Line 549: Always awards max points
components[msg.sender].publisherActivity = 4;

// Line 584-588: Graduated scoring (only used if VERIFIER calls updatePublisherActivity)
if (listings >= 100_000) score = 4;
else if (listings >= 10_000) score = 3;
// ...
```

**Impact:** Users can maintain maximum publisher activity score (4 points) by simply calling `submitServiceNodeHeartbeat()` every 5 minutes, without serving any listings. This undermines the graduated incentive structure.

**Recommendation:** Modify `submitServiceNodeHeartbeat()` to use the graduated scoring:

```solidity
function submitServiceNodeHeartbeat() external {
    if (!registration.isRegistered(msg.sender)) revert NotRegistered();

    lastServiceNodeHeartbeat[msg.sender] = block.timestamp;
    operationalServiceNodes[msg.sender] = true;

    // Use graduated scoring based on listing count (not flat 4)
    uint256 listings = publisherListingCount[msg.sender];
    uint8 score;
    if (listings >= 100_000) score = 4;
    else if (listings >= 10_000) score = 3;
    else if (listings >= 1_000) score = 2;
    else if (listings >= 100) score = 1;
    else score = 0;

    components[msg.sender].publisherActivity = score;
    components[msg.sender].lastUpdate = block.timestamp;

    emit ServiceNodeHeartbeat(msg.sender, block.timestamp);
}
```

---

### [M-03] Decay Applied Inconsistently -- Only on Component Update, Not on Score Read

**Severity:** Medium
**Lines:** 969-1011, 1177-1191
**Status:** New in Round 3

**Description:**

The `_applyDecay()` function is called inside `_updateMarketplaceActivity()`, `_updateCommunityPolicing()`, and `_updateForumActivity()` -- i.e., only when those components are being recalculated due to a new verification event. The decay is NOT applied when `getScore()` reads the stored components at lines 988-994.

This means a user's score does not actually decay over time as viewed by callers of `getScore()` / `getTotalScore()` / `canBeValidator()` / `canBeListingNode()`. Instead, it decays only when the next verification event triggers a recalculation. A user who was active 2 years ago but has had no new verifications since will still show their full, un-decayed score.

```solidity
// getScore() reads stored values without decay:
marketplaceActivity = comp.marketplaceActivity;   // No decay applied
communityPolicing = comp.communityPolicing;        // No decay applied
forumActivity = comp.forumActivity;                // No decay applied
```

**Impact:** Scores do not decay for inactive users as viewed by external callers. The decay only takes effect at the next interaction, which may never happen for truly inactive users. `canBeValidator()` and `canBeListingNode()` return stale, inflated results for inactive users.

**Recommendation:** Apply decay at read time in `getScore()`:

```solidity
// In getScore(), after reading stored components:
marketplaceActivity = _applyDecay(comp.marketplaceActivity, comp.lastUpdate);
communityPolicing = _applyDecay(comp.communityPolicing, comp.lastUpdate);
forumActivity = _applyDecay(comp.forumActivity, comp.lastUpdate);
```

This is a pure view operation, so it costs no additional gas for writes. The stored values remain un-decayed (they get decayed on the next write), but all read paths return the correct time-adjusted score.

---

### [L-01] `getTotalScore()` Uses External Self-Call -- Gas Overhead

**Severity:** Low
**Lines:** 1018-1021

**Description:**

`getTotalScore()` calls `this.getScore(user)`, which is an external call to the contract itself. This incurs message-call overhead (extra gas for call frame setup) compared to calling an internal function. While `getScore()` must be `external` (it returns a tuple), the total calculation could be extracted into a shared internal function.

```solidity
function getTotalScore(address user) external view returns (uint256) {
    (uint256 total,,,,,,,,,) = this.getScore(user);
    return total;
}
```

**Impact:** Minor gas overhead (~2,600 gas extra per call) for `getTotalScore()`, `canBeValidator()`, and `canBeListingNode()`, all of which use the `this.getScore()` pattern.

**Recommendation:** Extract the score calculation into an `internal` function `_calculateScore()` and have both `getScore()` and `getTotalScore()` call it:

```solidity
function _calculateScore(address user) internal view returns (uint256 totalScore, ...) {
    // Move calculation logic here
}

function getScore(address user) external view returns (...) {
    return _calculateScore(user);
}

function getTotalScore(address user) external view returns (uint256) {
    (uint256 total,,,,,,,,,) = _calculateScore(user);
    return total;
}
```

---

### [L-02] Reputation Average Still Uses Integer Truncation

**Severity:** Low
**Lines:** 513
**Status:** Inherited from Round 1 L-01 (not fixed)

**Description:**

The average star calculation uses integer division:

```solidity
uint256 avgStars = verifiedStarSum[user] / vCount;
```

A user with verified reviews summing to stars [5, 5, 5, 5, 4] has `verifiedStarSum = 24`, `verifiedReviewCount = 5`, producing `avgStars = 24 / 5 = 4` (integer truncation). This maps to +5 reputation instead of the ~+9.6 that a 4.8-star average should produce.

The specification calls for "gradient scaling between star levels," which the discrete step-function does not implement.

**Impact:** Reputation scores are systematically biased downward. Users with near-perfect reputations are grouped with moderately-rated users. With the O(1) counter approach, implementing fixed-point arithmetic is straightforward.

**Recommendation:** Use fixed-point scaling:

```solidity
// Multiply by 100 for 2 decimal places of precision
uint256 avgStars100 = (verifiedStarSum[user] * 100) / vCount;

// Linear interpolation: map 100 (1 star) to -10, 500 (5 stars) to +10
// Formula: reputation = (avgStars100 - 300) / 20
// At 100: (100-300)/20 = -10, At 300: 0, At 500: +10
int256 reputation = (int256(avgStars100) - 300) / 20;
if (reputation < -10) reputation = -10;
if (reputation > 10) reputation = 10;
```

---

### [L-03] No Test Coverage for Ossification Mechanism

**Severity:** Low
**Lines:** 1198-1220
**Status:** New in Round 3

**Description:**

The ossification mechanism (`ossify()`, `isOssified()`, and the ossification check in `_authorizeUpgrade()`) has zero test coverage. The test suite has 77 passing tests but none exercise the new ossification feature. Key untested scenarios:

1. `ossify()` can only be called by `DEFAULT_ADMIN_ROLE`
2. `ossify()` sets `_ossified` to `true`
3. `isOssified()` returns `true` after ossification
4. `_authorizeUpgrade()` reverts with `ContractIsOssified()` after ossification
5. `ossify()` emits `ContractOssified` event
6. `ossify()` is idempotent (can be called twice without error)

**Impact:** No safety net for regressions in the ossification logic. Given that ossification is irreversible, bugs here could either prevent intended ossification or fail to block upgrades when intended.

**Recommendation:** Add test cases for all six scenarios listed above. At minimum:

```javascript
describe('Ossification', function () {
    it('should not be ossified initially', async function () {
        expect(await participation.isOssified()).to.be.false;
    });

    it('should ossify when called by admin', async function () {
        await participation.connect(owner).ossify();
        expect(await participation.isOssified()).to.be.true;
    });

    it('should reject ossification from non-admin', async function () {
        await expect(participation.connect(unauthorized).ossify()).to.be.reverted;
    });

    it('should block upgrades after ossification', async function () {
        await participation.connect(owner).ossify();
        const V2 = await ethers.getContractFactory('OmniParticipation');
        await expect(
            upgrades.upgradeProxy(await participation.getAddress(), V2)
        ).to.be.revertedWithCustomError(participation, 'ContractIsOssified');
    });
});
```

---

### [L-04] Test Suite Asserts Buggy KYC Tier 3 Value (Inherited, Still Unfixed)

**Severity:** Low
**Lines:** Test file line 661
**Status:** Inherited from Round 1 I-01 (still unfixed)

**Description:**

The contract was correctly fixed to return 15 for KYC Tier 3 (line 1031), but the test at line 661 still asserts the old buggy value:

```typescript
expect(kycTrust).to.equal(20);  // Should be 15
```

This causes the test suite to report 1 failure ("77 passing, 1 failing"). The project's own rule states: "Don't modify the tests for the sake of getting the code to pass the tests." In this case, the *contract* was correctly fixed, but the *test* was not updated to match the corrected behavior.

**Impact:** Test suite shows a persistent failure, which degrades confidence in the CI pipeline and may mask real regressions.

**Recommendation:** Change line 661 of `test/OmniParticipation.test.ts` to:

```typescript
expect(kycTrust).to.equal(15);
```

---

### [I-01] `newImplementation` Parameter Unused in `_authorizeUpgrade()`

**Severity:** Informational
**Lines:** 1216-1220

**Description:**

The `_authorizeUpgrade(address newImplementation)` override does not use the `newImplementation` parameter. Solhint reports this as `no-unused-vars`. While this is a standard pattern (OpenZeppelin's UUPS base requires the signature), the parameter could be used to validate the new implementation address (e.g., check it is not `address(0)`, or verify it implements a specific interface).

```solidity
function _authorizeUpgrade(
    address newImplementation  // <-- unused
) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_ossified) revert ContractIsOssified();
}
```

**Recommendation:** Either suppress the warning with a named comment or add a zero-address check:

```solidity
function _authorizeUpgrade(
    address newImplementation
) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_ossified) revert ContractIsOssified();
    if (newImplementation == address(0)) revert ZeroAddress();
}
```

---

### [I-02] `ossify()` Is Not Idempotent -- No Guard Against Double-Ossification

**Severity:** Informational
**Lines:** 1198-1201

**Description:**

Calling `ossify()` a second time succeeds and emits a duplicate `ContractOssified` event, even though the state was already `true`. While this has no functional impact (setting `true` to `true` is a no-op), it emits a misleading event and wastes gas.

```solidity
function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _ossified = true;  // No check for already-ossified
    emit ContractOssified(address(this));
}
```

**Recommendation:** Add a guard:

```solidity
function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_ossified) revert ContractIsOssified();
    _ossified = true;
    emit ContractOssified(address(this));
}
```

---

### [I-03] Solhint `max-states-count` Warning -- 23 State Declarations

**Severity:** Informational
**Lines:** 97

**Description:**

Solhint reports that the contract has 23 state declarations, exceeding the default limit of 20. This is a code complexity indicator. The state count increased from Round 1 due to the addition of 7 new mappings/variables for the remediation (incremental counters, deduplication hashes, publisher listing count, `_ossified`).

The high state count is justified by the contract's legitimate requirements: it tracks 9 score components across multiple dimensions (reviews, transactions, reports, forum posts, heartbeats) and needs deduplication tracking for each.

**Impact:** No security impact. Code complexity metric.

**Recommendation:** No action required. The state count is proportional to the contract's responsibilities. If future upgrades need more state, consider factoring out sub-systems (e.g., a separate `ForumReputationModule`) to stay within complexity budgets.

---

### [I-04] NatSpec Maximum Score Comment Specifies 88 but System Allows Negative Components

**Severity:** Informational
**Lines:** 86

**Description:**

The NatSpec at line 86 states "0-88 theoretical max, clamped to 0-100." The theoretical maximum is calculated as: 20 + 10 + 24 + 10 + 4 + 5 + 5 + 5 + 5 = 88. This is correct.

However, the theoretical *minimum* is not documented. With two signed components (marketplaceReputation at -10 and reliability at -5), the theoretical minimum is: 0 + (-10) + 0 + 0 + 0 + 0 + 0 + 0 + (-5) = -15, which clamps to 0. This is worth documenting for completeness.

**Recommendation:** Update the NatSpec to: "Score Components (-15 to 88 raw, clamped to 0-100)"

---

## Static Analysis Results

**Solhint:** 0 errors, 3 warnings
- 1 `max-states-count` (23 state declarations, limit is 20 -- justified by design)
- 1 `ordering` (constant `DECAY_PERIOD` declared after state variables)
- 1 `no-unused-vars` (`newImplementation` parameter in `_authorizeUpgrade`)

This is a dramatic improvement from Round 1 (0 errors, 92 warnings). The codebase has been cleaned up significantly.

**Compiler:** Clean compilation with `solc 0.8.24`. No warnings.

**Test Suite:** 77 passing, 1 failing (the KYC Tier 3 test expects old buggy value of 20, contract correctly returns 15).

---

## Round 1 vs Round 3 Comparison

| Metric | Round 1 | Round 3 | Change |
|--------|---------|---------|--------|
| Critical | 0 | 0 | -- |
| High | 2 | 0 | -2 (all fixed) |
| Medium | 7 | 3 | -4 (4 fixed, 3 new/residual) |
| Low | 4 | 4 | 0 (2 inherited, 2 new) |
| Informational | 2 | 4 | +2 (1 inherited, 3 new) |
| Solhint warnings | 92 | 3 | -89 |
| Lines of code | ~1,037 | 1,237 | +200 |
| Test count | ~77 | 77 | 0 |
| New features | -- | Ossification, decay, counters | -- |

---

## Conclusion

OmniParticipation has improved substantially since the Round 1 audit. All Critical and High findings have been resolved. The contract now uses O(1) incremental counters (eliminating the DoS vector), has a proper storage gap, prevents self-reviews, enforces content hash uniqueness, implements graduated publisher scoring, and adds time decay. The new ossification mechanism is well-designed.

**Remaining concerns (ordered by priority):**

1. **Decay not applied at read time (M-03):** The most significant remaining issue. Inactive users retain inflated scores indefinitely as seen by `getScore()`, `canBeValidator()`, and `canBeListingNode()`. The fix is straightforward (apply `_applyDecay()` in `getScore()`).

2. **Heartbeat bypasses graduated scoring (M-02):** `submitServiceNodeHeartbeat()` still awards flat 4 points, bypassing the graduated thresholds that `updatePublisherActivity()` correctly implements.

3. **`_ossified` placement (M-01):** Non-contiguous state variable layout is a maintenance hazard. Moving the declaration to the storage section eliminates the risk.

4. **Test regression (L-04):** The KYC Tier 3 test expects the old buggy value. A one-line fix.

None of these findings represent Critical or High risks. The contract is suitable for testnet deployment, and after addressing M-02 and M-03, suitable for mainnet deployment.

---

## Appendix: Storage Layout

| Slot | Variable | Notes |
|------|----------|-------|
| (inherited) | AccessControl, UUPS, ReentrancyGuard | OZ upgradeable slots |
| S+0 | `components` mapping | ParticipationComponents per address |
| S+1 | `registration` | IOmniRegistration address |
| S+2 | `omniCore` | IOmniCore address |
| S+3 | `reviewHistory` mapping | Review[] per address |
| S+4 | `usedTransactions` mapping | bytes32 -> bool |
| S+5 | `operationalServiceNodes` mapping | address -> bool |
| S+6 | `lastServiceNodeHeartbeat` mapping | address -> uint256 |
| S+7 | `transactionClaims` mapping | TransactionClaim[] per address |
| S+8 | `reportHistory` mapping | Report[] per address |
| S+9 | `forumContributions` mapping | ForumContribution[] per address |
| S+10 | `lastValidatorHeartbeat` mapping | address -> uint256 |
| S+11 | `uptimeBlocks` mapping | address -> uint256 |
| S+12 | `totalBlocks` mapping | address -> uint256 |
| S+13 | `verifiedReviewCount` mapping | Round 2 addition |
| S+14 | `verifiedStarSum` mapping | Round 2 addition |
| S+15 | `verifiedTransactionCount` mapping | Round 2 addition |
| S+16 | `validatedReportCount` mapping | Round 2 addition |
| S+17 | `verifiedForumCount` mapping | Round 2 addition |
| S+18 | `usedContentHashes` mapping | Round 2 addition |
| S+19 | `usedReportHashes` mapping | Round 2 addition |
| S+20 | `publisherListingCount` mapping | Round 2 addition |
| S+21 | `_ossified` | bool (Round 2 addition) |
| S+22..S+70 | `__gap[49]` | Reserved for future upgrades |

Constants (`MIN_VALIDATOR_SCORE`, `MIN_LISTING_NODE_SCORE`, `SERVICE_NODE_TIMEOUT`, `VALIDATOR_TIMEOUT`, `MAX_BATCH_SIZE`, `DECAY_PERIOD`) do not occupy storage slots.

---

*Generated by Claude Code Audit Agent v3 -- 6-Pass Enhanced (Round 3)*
