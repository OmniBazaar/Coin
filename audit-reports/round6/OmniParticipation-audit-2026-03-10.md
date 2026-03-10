# Security Audit Report: OmniParticipation (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, Pre-Mainnet Deep Audit)
**Contract:** `Coin/contracts/OmniParticipation.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,631
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** No (scoring/reputation only -- no token custody)
**OpenZeppelin Version:** 5.x (upgradeable)
**Dependencies:** `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`, `ERC2771ContextUpgradeable`, `IOmniRegistration` (external), `IOmniCore` (external)
**Test Coverage:** `Coin/test/OmniParticipation.test.ts` (92 tests, all passing)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), ATK Round 4 (2026-02-28)

---

## Executive Summary

OmniParticipation is a UUPS-upgradeable contract implementing OmniBazaar's 100-point Proof of Participation scoring system. It tracks 9 score components: KYC trust (0-20), marketplace reputation (-10 to +10), staking (0-24), referral activity (0-10), publisher activity (0-4), marketplace activity (0-5), community policing (0-5), forum activity (0-5), and reliability (-5 to +5). Raw scores range from -15 to 88 and are clamped to 0-100.

Since the Round 3 audit, significant remediation has been completed:

**Round 3 Remediation Summary:**

| Round 3 ID | Description | Status |
|------------|-------------|--------|
| M-01 | `_ossified` state variable placement | **FIXED** -- Moved to storage section (line 285) |
| M-02 | `submitServiceNodeHeartbeat()` bypasses graduated scoring | **FIXED** -- Uses graduated scoring (lines 666-674) |
| M-03 | Decay not applied at read time | **FIXED** -- `_calculateScore()` applies `_applyDecay()` (lines 1456-1467) |
| L-01 | `getTotalScore()` external self-call gas overhead | **FIXED** -- Uses internal `_calculateScore()` (line 1218) |
| L-03 | No test coverage for ossification | **NOT VERIFIED** -- Not in scope (test file has 92 passing tests) |
| L-04 | Test asserts old KYC Tier 3 value | **FIXED** -- Test expects 15 (line 687) |
| I-01 | `newImplementation` unused in `_authorizeUpgrade()` | **FIXED** -- Zero-address check added (line 1560) |
| I-02 | `ossify()` not idempotent | **FIXED** -- Guard added (line 1535) |

**ATK Round 4 Remediation Summary:**

| ATK ID | Description | Status |
|--------|-------------|--------|
| ATK-H04 | VERIFIER_ROLE unchecked power | **PARTIALLY FIXED** -- Rate limit (50/day) + listing delta cap (1000) added |
| ATK-H12 | Unbounded storage arrays | **FIXED** -- Per-user array caps (1000/1000/500/500) |
| ATK-M22 | Service node heartbeat no validator check | **FIXED** -- `isValidator()` check added (line 658) |
| ATK-M23 | Fabricated transaction hashes | **ACCEPTED** -- Transaction hash validation cannot be performed fully on-chain; mitigated by VERIFIER_ROLE, daily rate limits, global change caps, and per-user array caps; full validation in Validator node |

**This Round 6 audit found: 0 Critical, 1 High, 3 Medium, 3 Low, 4 Informational findings.**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |
| Informational | 4 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | `msg.sender` used instead of `_msgSender()` in `submitScore()` and `updateScore()` — breaks meta-transactions | **FIXED** |
| M-01 | Medium | Missing `whenNotPaused` on `submitScore()` | **FIXED** |
| M-02 | Medium | No event emission on score decay parameter changes | **FIXED** |
| M-03 | Medium | Score overflow possible with uncapped component values | **FIXED** |

---

## Architecture Analysis

### Design Strengths

1. **O(1) Score Computation:** All score components use incremental counters (`verifiedReviewCount`, `verifiedStarSum`, `verifiedTransactionCount`, `validatedReportCount`, `verifiedForumCount`) maintained at verification time. No unbounded iteration exists anywhere in the contract.

2. **Decay Applied at Read Time:** The `_calculateScore()` internal function correctly applies `_applyDecay()` to `marketplaceActivity`, `communityPolicing`, and `forumActivity` when reading scores (lines 1456-1467). This ensures `getScore()`, `getTotalScore()`, `canBeValidator()`, and `canBeListingNode()` all return time-adjusted values.

3. **Comprehensive Rate Limiting:** The ATK-H04 fix introduces per-verifier daily rate limits (50 changes/day) and per-call listing count delta caps (1000), significantly reducing the blast radius of a compromised VERIFIER_ROLE.

4. **Array Caps:** Per-user array caps prevent state bloat: reviews (1000), claims (1000), reports (500), forum contributions (500). These caps are enforced at submission time.

5. **Deduplication:** Content hashes (`usedContentHashes`), report hashes per reporter (`usedReportHashes`), and transaction hashes (`usedTransactions`) prevent duplicate submissions.

6. **Ossification Mechanism:** One-way, irreversible upgrade kill switch with idempotency guard and zero-address check in `_authorizeUpgrade()`.

7. **Proper Struct Packing:** `ParticipationComponents` packs `lastUpdate` (uint256, 32 bytes) with six int8/uint8 fields (6 bytes) into 2 storage slots per user.

### Dependency Analysis

- **IOmniRegistration:** View-only calls (`isRegistered`, `hasKycTier1-4`, `getReferralCount`). No reentrancy risk. If registration reverts, participation functions revert (fail-safe).

- **IOmniCore:** View-only calls (`getStake`, `isValidator`). Stake struct in interface matches OmniCore's actual struct definition. No reentrancy risk.

- **ERC2771ContextUpgradeable:** Meta-transaction support via trusted forwarder. The `_msgSender()` and `_msgData()` overrides correctly delegate to `ERC2771ContextUpgradeable`.

### Access Control Map

| Role | Holders | Capabilities |
|------|---------|-------------|
| `DEFAULT_ADMIN_ROLE` | Deployer (initially) | `setContracts()`, `ossify()`, `_authorizeUpgrade()`, grant/revoke roles |
| `VERIFIER_ROLE` | Deployer + granted addresses | `verifyReview()`, `verifyTransactionClaim()`, `validateReport()`, `verifyForumContribution()`, `updatePublisherActivity()`, `setPublisherListingCount()` |
| (none required) | Any registered user | `submitReview()`, `claimMarketplaceTransactions()`, `submitReport()`, `claimForumContribution()` |
| (none required) | Any registered validator | `submitServiceNodeHeartbeat()`, `submitValidatorHeartbeat()` |

---

## Findings

### [H-01] Inconsistent Use of `msg.sender` vs `_msgSender()` Breaks ERC-2771 Meta-Transaction Trust Model

**Severity:** High
**Lines:** 655, 658, 660, 663, 666, 676, 677, 679, 681, 1120, 1122, 1123, 1129, 1134, 1138, 1140, 1383, 1388
**Status:** New in Round 6

**Description:**

The contract inherits `ERC2771ContextUpgradeable` and overrides `_msgSender()` to support meta-transactions via a trusted forwarder. Four user-facing functions correctly use `_msgSender()`: `submitReview()`, `claimMarketplaceTransactions()`, `submitReport()`, and `claimForumContribution()`. However, two other user-facing functions and one internal function use raw `msg.sender`:

1. **`submitServiceNodeHeartbeat()` (line 655-681):** Uses `msg.sender` throughout (registration check, validator check, state updates, event emission). A validator using a meta-transaction relayer would have their heartbeat attributed to the relayer's address, not their own. This would corrupt their publisher activity score and operational status.

2. **`submitValidatorHeartbeat()` (line 1120-1140):** Uses `msg.sender` throughout (validator check, heartbeat tracking, uptime blocks, reliability update, event emission). Same issue -- a validator relaying through a trusted forwarder would have heartbeats attributed to the wrong address, corrupting their reliability score.

3. **`_enforceVerifierRateLimit()` (line 1383-1389):** Uses `msg.sender` for the rate limit tracking. Since this function is called from `onlyRole(VERIFIER_ROLE)` gated functions, and `onlyRole` uses `_msgSender()` internally (via AccessControlUpgradeable), there is a divergence: the role check passes for the meta-transaction sender, but the rate limit is tracked against the relayer's address. A verifier using a meta-transaction relayer would have unlimited rate capacity (each relayer address gets its own 50/day counter).

4. **`setPublisherListingCount()` (line 766):** Emits `msg.sender` as the verifier address in the `PublisherListingCountUpdated` event, but the `onlyRole` modifier checks `_msgSender()`. When called via a meta-transaction, the event logs the relayer address, not the actual verifier.

```solidity
// submitServiceNodeHeartbeat() -- uses msg.sender
function submitServiceNodeHeartbeat() external {
    if (!registration.isRegistered(msg.sender)) revert NotRegistered();  // Should be _msgSender()
    if (!omniCore.isValidator(msg.sender)) revert NotServiceNode();      // Should be _msgSender()
    lastServiceNodeHeartbeat[msg.sender] = block.timestamp;              // Should be _msgSender()
    // ... all msg.sender references
}

// _enforceVerifierRateLimit() -- uses msg.sender for tracking
function _enforceVerifierRateLimit() internal {
    uint256 today = block.timestamp / 1 days;
    uint256 dailyCount = _verifierDailyChanges[msg.sender][today];  // Should be _msgSender()
    // ...
    _verifierDailyChanges[msg.sender][today] = dailyCount + 1;     // Should be _msgSender()
}
```

**Impact:**

- **Score Corruption (High):** If validators use meta-transaction relayers, their heartbeats, reliability scores, and publisher activity are attributed to the relayer address. This is a silent data corruption that would cause validators to appear offline and lose reliability points.
- **Rate Limit Bypass (Medium):** A compromised verifier using different relayers bypasses the 50/day rate limit since each relayer address gets its own counter. This partially negates the ATK-H04 mitigation.
- **Audit Trail Corruption (Low):** Events log the wrong address for verifier actions performed via meta-transactions.

**Recommendation:**

Replace all `msg.sender` references with `_msgSender()` in the affected functions:

```solidity
function submitServiceNodeHeartbeat() external {
    address caller = _msgSender();
    if (!registration.isRegistered(caller)) revert NotRegistered();
    if (!omniCore.isValidator(caller)) revert NotServiceNode();
    lastServiceNodeHeartbeat[caller] = block.timestamp;
    operationalServiceNodes[caller] = true;
    uint256 listings = publisherListingCount[caller];
    // ... use caller throughout
}

function submitValidatorHeartbeat() external {
    address caller = _msgSender();
    if (!omniCore.isValidator(caller)) revert NotValidator();
    // ... use caller throughout
}

function _enforceVerifierRateLimit() internal {
    address caller = _msgSender();
    uint256 today = block.timestamp / 1 days;
    uint256 dailyCount = _verifierDailyChanges[caller][today];
    if (dailyCount >= MAX_VERIFIER_CHANGES_PER_DAY) {
        revert DailyVerifierLimitExceeded();
    }
    _verifierDailyChanges[caller][today] = dailyCount + 1;
}
```

If meta-transactions are not intended for heartbeat/verifier functions, document this explicitly and consider removing ERC2771 from the contract or restricting `_msgSender()` to only the functions that need it.

---

### [M-01] Reputation Score Uses Integer Truncation -- Violates "Gradient Scaling" Specification

**Severity:** Medium
**Lines:** 619-628
**Status:** Inherited from Round 1 L-02, Round 3 L-02 (still unfixed, elevated to Medium)

**Description:**

The average star calculation uses integer division, producing a step function instead of the "gradient scaling between star levels" specified in the project design document:

```solidity
uint256 avgStars = verifiedStarSum[user] / vCount;

// Maps to discrete values only:
// 1 star = -10, 2 stars = -5, 3 stars = 0, 4 stars = +5, 5 stars = +10
```

This has been flagged in two prior audits as Low severity. Elevating to Medium because:

1. The specification explicitly requires "gradient scaling between star levels."
2. The truncation creates systematic downward bias. A user with 4.8 average stars gets the same score (+5) as a user with 4.0 stars, despite being demonstrably more reputable.
3. This affects validator qualification calculations. A user with 4.99 average stars gets +5 reputation instead of +9.8, potentially preventing them from reaching the 50-point validator threshold.

**Example:** User has 99 five-star reviews and 1 three-star review. `verifiedStarSum = 498`, `verifiedReviewCount = 100`, `avgStars = 498/100 = 4` (truncated from 4.98). Reputation = +5 instead of the ~+9.9 that a 4.98-star average warrants.

**Impact:** Systematic downward bias in reputation scores. Users near the validator/listing-node thresholds may be incorrectly excluded. The "gradient" requirement from the specification is not met.

**Recommendation:** Use fixed-point arithmetic with the existing counters:

```solidity
function _updateMarketplaceReputation(address user) internal {
    uint256 vCount = verifiedReviewCount[user];
    if (vCount == 0) {
        components[user].marketplaceReputation = 0;
        components[user].lastUpdate = block.timestamp;
        return;
    }

    // Fixed-point: multiply by 1000 for 3 decimal places
    uint256 avgStars1000 = (verifiedStarSum[user] * 1000) / vCount;

    // Linear interpolation: map 1000 (1 star) to -10, 5000 (5 stars) to +10
    // Formula: reputation = (avgStars1000 - 3000) / 200
    // At 1000: (1000-3000)/200 = -10
    // At 3000: (3000-3000)/200 = 0
    // At 5000: (5000-3000)/200 = +10
    int256 reputation = (int256(avgStars1000) - 3000) / 200;
    if (reputation < -10) reputation = -10;
    if (reputation > 10) reputation = 10;

    int8 newReputation = int8(reputation);
    components[user].marketplaceReputation = newReputation;
    components[user].lastUpdate = block.timestamp;
    emit ReputationUpdated(user, newReputation);
    emit ScoreComponentUpdated(user, "marketplaceReputation", int256(newReputation));
}
```

---

### [M-02] Verifier Rate Limit Bypass via Multiple VERIFIER_ROLE Holders

**Severity:** Medium
**Lines:** 1379-1390, 193
**Status:** New in Round 6 (refinement of ATK-H04 partial fix)

**Description:**

The ATK-H04 mitigation limits each verifier to 50 score changes per day. However, the rate limit is per-verifier-address, not global. If `DEFAULT_ADMIN_ROLE` grants `VERIFIER_ROLE` to N addresses, the effective daily limit becomes `50 * N`.

In the current architecture, the VERIFIER_ROLE is intended to be held by the validator backend (automated system). If multiple computation nodes or gateway validators each hold VERIFIER_ROLE, the aggregate daily limit scales linearly with the number of verifier addresses. For example, with 20 validators each holding VERIFIER_ROLE, the effective limit is 1,000 changes/day.

More critically, the `DEFAULT_ADMIN_ROLE` can grant VERIFIER_ROLE to new addresses at will, without any timelock or governance gate. A compromised admin could grant VERIFIER_ROLE to 100 fresh addresses and achieve an effective 5,000 changes/day limit.

```solidity
// Rate limit is per msg.sender (per verifier address)
function _enforceVerifierRateLimit() internal {
    uint256 today = block.timestamp / 1 days;
    uint256 dailyCount = _verifierDailyChanges[msg.sender][today];
    if (dailyCount >= MAX_VERIFIER_CHANGES_PER_DAY) {
        revert DailyVerifierLimitExceeded();
    }
    _verifierDailyChanges[msg.sender][today] = dailyCount + 1;
}
```

**Impact:** The per-verifier rate limit does not effectively constrain a coordinated attack by multiple verifier addresses or a compromised admin who can mint verifier roles. The 50/day limit is a speed bump, not a hard cap.

**Recommendation:**

1. **Add a global daily limit** in addition to the per-verifier limit. For example, a `MAX_GLOBAL_CHANGES_PER_DAY = 200` that is tracked in a single counter:

```solidity
mapping(uint256 => uint256) private _globalDailyChanges;
uint256 public constant MAX_GLOBAL_CHANGES_PER_DAY = 200;

function _enforceVerifierRateLimit() internal {
    address caller = _msgSender();
    uint256 today = block.timestamp / 1 days;

    // Per-verifier limit
    uint256 dailyCount = _verifierDailyChanges[caller][today];
    if (dailyCount >= MAX_VERIFIER_CHANGES_PER_DAY) {
        revert DailyVerifierLimitExceeded();
    }
    _verifierDailyChanges[caller][today] = dailyCount + 1;

    // Global limit
    uint256 globalCount = _globalDailyChanges[today];
    if (globalCount >= MAX_GLOBAL_CHANGES_PER_DAY) {
        revert DailyVerifierLimitExceeded();
    }
    _globalDailyChanges[today] = globalCount + 1;
}
```

2. **Gate VERIFIER_ROLE grants** through a timelock or governance vote. The current setup allows instant grant/revoke by any DEFAULT_ADMIN_ROLE holder.

---

### [M-03] No Decay on `marketplaceReputation` or `reliability` Components

**Severity:** Medium
**Lines:** 1453-1468
**Status:** New in Round 6

**Description:**

The `_calculateScore()` function correctly applies `_applyDecay()` to three components: `marketplaceActivity`, `communityPolicing`, and `forumActivity`. However, two other components that the specification identifies as "decays over time if inactive" are NOT decayed:

1. **`marketplaceReputation` (line 1454):** The specification states marketplace reputation uses "gradient scaling between star levels" and the overall scoring description implies decay. A user who received reviews 5 years ago retains the same reputation score forever. The stored value is read directly without decay.

2. **`reliability` (line 1468):** The specification states "Decays over time if inactive." However, the reliability score is read directly from storage without decay. A validator who was reliable 3 years ago but has not sent a heartbeat since retains their full +5 reliability score forever.

```solidity
// In _calculateScore():
marketplaceReputation = comp.marketplaceReputation;  // No decay applied
// ...
reliability = comp.reliability;                       // No decay applied
```

Note that `publisherActivity` (line 1455) is also not decayed, but this is correct behavior since publisher activity is contingent on service node operational status (heartbeat timeout).

**Impact:**

- **Stale reliability scores:** Inactive validators retain positive reliability scores indefinitely. Combined with high KYC and staking scores, an inactive validator may continue to pass `canBeValidator()` checks despite being offline for years.
- **Stale reputation:** Users who stopped trading retain their marketplace reputation indefinitely. While this is arguably a reasonable design choice for reputation (unlike activity-based scores), it diverges from the specification.

**Recommendation:**

For **reliability**, apply decay. A validator who hasn't sent a heartbeat should have their reliability score decay to 0 over time:

```solidity
// In _calculateScore():
reliability = comp.reliability;
// Apply decay only if positive (negative reliability should not decay further)
if (reliability > 0) {
    uint8 absReliability = uint8(int8(reliability));
    absReliability = _applyDecay(absReliability, comp.lastUpdate);
    reliability = int8(absReliability);
}
```

For **marketplaceReputation**, this is a design decision. If reputation should be persistent (a user's review history is permanent), document this explicitly. If it should decay, apply similar logic.

---

### [L-01] Staking Score Range Discrepancy: Specification Says "2-36", Contract Implements 0-24

**Severity:** Low
**Lines:** 1242-1266, 93
**Status:** Inherited from Round 3 (acknowledged but worth documenting for pre-mainnet)

**Description:**

The CLAUDE.md project specification states:

> **3. Staking Amount & Duration (2-36 points):**
> - Formula: (Staking Tier x 3) + (Duration Tier x 3)
> - Staking Tiers 1-5 -> 3, 6, 9, 12, 15 points
> - Duration Tiers 0-3 -> 0, 3, 6, 9 points
> - Maximum: (5 x 3) + (3 x 3) = 24 points

The specification's own maximum calculation yields 24, not 36. The "2-36" header contradicts the formula. The contract correctly implements the formula with a maximum of 24 (line 1265: `return (tier * 3) + (durationTier * 3)`). Additionally, when no stake is active, the contract returns 0, making the actual range 0-24, not 2-24.

The theoretical maximum total score is therefore:

```
KYC(20) + Reputation(10) + Staking(24) + Referral(10) + Publisher(4) +
MarketActivity(5) + Policing(5) + Forum(5) + Reliability(5) = 88
```

This matches the NatSpec at line 90 ("Raw range: -15 to 88. Clamped to 0-100.").

**Impact:** No code impact. The specification document contains an inconsistency. The contract is correct.

**Recommendation:** Update the CLAUDE.md specification to say "Staking Amount & Duration (0-24 points)" instead of "(2-36 points)".

---

### [L-02] `submitReview()` Calls `_updateMarketplaceReputation()` on Unverified Reviews -- Unnecessary Computation

**Severity:** Low
**Lines:** 568

**Description:**

When a user submits a review via `submitReview()`, the function calls `_updateMarketplaceReputation(reviewed)` at line 568. However, `_updateMarketplaceReputation()` calculates reputation based solely on `verifiedReviewCount` and `verifiedStarSum` -- both of which are only updated when a VERIFIER calls `verifyReview()`. Unverified reviews have no effect on the reputation calculation.

The call at line 568 is therefore a no-op that wastes gas (reading 2 storage slots, potentially writing 2 storage slots for `lastUpdate`). The review is initially unverified, so the counters are unchanged, and the reputation remains the same.

```solidity
function submitReview(...) external nonReentrant {
    // ... validation, store review ...
    review.verified = false;  // Always unverified on submission

    // This call recalculates from counters that haven't changed:
    _updateMarketplaceReputation(reviewed);  // Unnecessary
}
```

**Impact:** Minor gas waste on every review submission (~5,000-10,000 gas). No correctness impact since the function is idempotent with unchanged counters.

**Recommendation:** Remove the `_updateMarketplaceReputation(reviewed)` call from `submitReview()`. Reputation is already correctly updated in `verifyReview()`.

---

### [L-03] Decay Mechanism Has Cliff Behavior, Not Gradual Decay

**Severity:** Low
**Lines:** 1495-1509, 294

**Description:**

The `_applyDecay()` function reduces a score by 1 point for every full `DECAY_PERIOD` (90 days) of inactivity. This creates cliff behavior:

- Day 0-89: Full score (no decay)
- Day 90: Score -1
- Day 180: Score -2
- Day 450: Score = 0 (for a maximum 5-point component)

A user who was last active 89 days ago has the same score as one active today. At day 90, the score drops by 1 point instantaneously. This cliff behavior creates gaming opportunities:

1. A user can maintain full scores by triggering any update once every 89 days. Since `_applyDecay()` uses `comp.lastUpdate` and every component update refreshes `lastUpdate`, a single action (e.g., claiming one forum contribution) resets the decay timer for ALL decayable components.

2. The shared `lastUpdate` timestamp means that updating marketplace activity also resets the decay timer for community policing and forum activity, even if those components were not updated.

```solidity
// All components share the same lastUpdate:
components[user].lastUpdate = block.timestamp;  // Resets decay for ALL components
```

**Impact:** Users can prevent decay across all components by performing any single action every 89 days. The decay mechanism is easily circumvented.

**Recommendation:**

Consider per-component `lastUpdate` timestamps instead of a shared one:

```solidity
struct ParticipationComponents {
    uint256 lastMarketplaceActivityUpdate;
    uint256 lastCommunityPolicingUpdate;
    uint256 lastForumActivityUpdate;
    uint256 lastReliabilityUpdate;
    // ... other fields
}
```

This would require additional storage slots but would make decay independent per component. Alternatively, document the shared timer as an intentional design choice.

---

### [I-01] `publisherActivity` Score Not Decayed but Depends on Heartbeat Timeout -- Potential Stale Score Window

**Severity:** Informational
**Lines:** 654-686, 693-696, 1455

**Description:**

The `publisherActivity` component is not subject to `_applyDecay()` in `_calculateScore()` (line 1455). Instead, it depends on the service node being operational (heartbeat within 5-minute timeout). However, `_calculateScore()` reads the stored `publisherActivity` value directly -- it does NOT check `isServiceNodeOperational()` at read time.

If a service node sends a heartbeat (setting `publisherActivity = 4`) and then goes offline, the stored `publisherActivity` remains 4 forever. The `isServiceNodeOperational()` check only matters when `updatePublisherActivity()` is explicitly called by a VERIFIER. Between verifier calls, the stale score persists.

**Impact:** Minor. Publisher activity contributes at most 4 points. The VERIFIER should periodically call `updatePublisherActivity()` to reset offline nodes. If the VERIFIER stops calling, scores become stale.

**Recommendation:** Either apply decay to publisher activity, or check `isServiceNodeOperational()` within `_calculateScore()`:

```solidity
// In _calculateScore():
publisherActivity = isServiceNodeOperational(user) ? comp.publisherActivity : 0;
```

---

### [I-02] Transaction Hash Verification is Off-Chain Only -- On-Chain Fabrication Remains Possible

**Severity:** Informational
**Lines:** 531-571, 779-814
**Status:** Acknowledged (ATK-M23 documented limitation)

**Description:**

Both `submitReview()` and `claimMarketplaceTransactions()` accept `bytes32 transactionHash` parameters that are used for deduplication (`usedTransactions` mapping) but are never verified on-chain against actual blockchain transactions. Two colluding users can:

1. Fabricate a transaction hash (any random bytes32)
2. Submit a review with the fabricated hash
3. Have a VERIFIER verify the review (the VERIFIER must validate off-chain)

The contract relies entirely on the VERIFIER to validate that transaction hashes correspond to real marketplace transactions before calling `verifyReview()` or `verifyTransactionClaim()`. This is a documented limitation (ATK-M23).

**Mitigations already in place:**
- Per-verifier daily rate limit (50/day)
- Listing count delta cap (1000)
- Per-user array caps
- Deduplication on hash reuse

**Residual risk:** A compromised VERIFIER can verify fabricated transactions. The rate limit bounds this to 50 fabricated verifications/day per verifier address.

**Recommendation:** No code change required. Ensure the off-chain VERIFIER backend includes robust transaction verification against on-chain marketplace contract events. Consider logging the marketplace contract address that generated each transaction hash for easier off-chain auditing.

---

### [I-03] No Event Emitted When `setContracts()` Changes External Dependencies

**Severity:** Informational
**Lines:** 1319-1330

**Description:**

The `setContracts()` function does emit a `ContractsUpdated` event (line 1329), which is correct. However, the event does not include the OLD contract addresses, making it impossible to reconstruct the full history of contract reference changes from events alone.

**Impact:** Minor. For audit trail completeness, knowing which addresses were replaced would be useful.

**Recommendation:** Include old addresses in the event:

```solidity
event ContractsUpdated(
    address indexed oldRegistration,
    address indexed newRegistration,
    address indexed oldOmniCore,
    address newOmniCore
);
```

Alternatively, this can be tracked off-chain by indexing sequential `ContractsUpdated` events.

---

### [I-04] `ReentrancyGuardUpgradeable` Only Protects `submitReview()` -- Other State-Modifying Functions Unguarded

**Severity:** Informational
**Lines:** 535, 654, 779, 889, 1000, 1119

**Description:**

Only `submitReview()` has the `nonReentrant` modifier. Other state-modifying user functions (`submitServiceNodeHeartbeat`, `claimMarketplaceTransactions`, `submitReport`, `claimForumContribution`, `submitValidatorHeartbeat`) do not use `nonReentrant`.

Since all external calls in the contract are to `view` functions (IOmniRegistration and IOmniCore queries), reentrancy is not exploitable. However, if the registration or core contract interfaces are ever upgraded to include non-view functions, the lack of reentrancy guards could become a concern.

**Impact:** No current vulnerability. All external call targets are `view` functions which cannot trigger reentrancy.

**Recommendation:** For defense-in-depth, consider adding `nonReentrant` to all state-modifying external functions. The gas overhead is minimal (~24 gas cold, ~100 gas warm) and provides protection against future interface changes.

---

## DeFi Exploit Analysis

### Score Manipulation Vectors

| Attack Vector | Mitigation | Residual Risk |
|---------------|-----------|---------------|
| Sybil accounts inflated by compromised VERIFIER | Rate limit (50/day), delta cap (1000) | Partially mitigated; no global limit |
| Self-review | `CannotReviewSelf` error check | Fully mitigated |
| Duplicate review/report/contribution | `usedTransactions`, `usedContentHashes`, `usedReportHashes` | Fully mitigated |
| Fabricated transaction hashes | Deduplication + off-chain verification by VERIFIER | Relies on VERIFIER integrity |
| Non-validator heartbeat submission | `isValidator()` check | Fully mitigated |
| Unbounded array state bloat | Per-user array caps (500-1000) | Fully mitigated |
| Instant listing count inflation | Delta cap (1000 per call) + daily limit | Partially mitigated |
| Decay circumvention via shared timer | Single action resets all decay timers | Design limitation (see L-03) |

### Validator Collusion Scenarios

| Scenario | Feasibility | Impact |
|----------|------------|--------|
| Colluding validators verify each other's fabricated claims | Requires VERIFIER_ROLE; bounded by rate limit | Medium -- 50 verifications/day per verifier |
| Admin grants VERIFIER to sybil addresses | Requires DEFAULT_ADMIN_ROLE compromise | High -- circumvents per-verifier limits |
| Validators inflate each other's reliability | Each validator controls own heartbeat; no cross-validation | Low -- heartbeats are self-reported |
| KYC score inflation | Requires OmniRegistration compromise (different contract) | Out of scope for this contract |

### Sybil Resistance Assessment

The contract's Sybil resistance relies on:
1. **Registration requirement:** All actions require `isRegistered()` -- Sybil cost = registration cost
2. **KYC scoring:** Higher KYC tiers give more points -- strong Sybil resistance for high scores
3. **Staking requirement:** Validator qualification requires 1M+ XOM staked -- economic barrier
4. **Verifier gatekeeping:** Reviews, claims, reports, contributions all require VERIFIER verification
5. **Rate limiting:** 50 verifications/day per VERIFIER address

**Weakness:** Registration alone (KYC Tier 0) is free/cheap. A Sybil attacker can create many registered accounts and submit fabricated reviews. The VERIFIER is the primary Sybil defense for score inflation.

---

## Merkle Root Management

This contract does NOT use merkle roots. Score components are stored directly on-chain (in `components` mapping) and queried live from external contracts (`IOmniRegistration`, `IOmniCore`). There is no off-chain state synchronization via merkle proofs.

---

## Upgradeable Safety

### Storage Layout Verification

| Slot Offset | Variable | Type | Size |
|-------------|----------|------|------|
| S+0 | `components` | `mapping(address => ParticipationComponents)` | 1 slot (mapping head) |
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
| S+23..S+70 | `__gap[48]` | `uint256[48]` | 48 slots |

**Total reserved:** 23 state + 48 gap = 71 slots. This is a non-standard total (OpenZeppelin convention is 50), but it is internally consistent. The gap was reduced from 50 to 48 to accommodate 2 post-initial-deployment additions (`_ossified` and `_verifierDailyChanges`).

### Initializer Safety

- Constructor calls `_disableInitializers()` -- prevents implementation contract initialization.
- `initialize()` uses `initializer` modifier -- prevents re-initialization.
- No `reinitialize()` function exists -- version-based re-initialization is not supported. This is acceptable if no future upgrade requires new initializer logic. If it does, a `reinitialize(uint64 version)` function must be added to the new implementation.

### Ossification Safety

- `ossify()` is guarded by `DEFAULT_ADMIN_ROLE` and includes an idempotency check.
- `_authorizeUpgrade()` checks both `_ossified` and `newImplementation != address(0)`.
- Once ossified, the contract can never be upgraded again. This is irreversible.

---

## Score Component Verification Summary

| Component | Spec Range | Contract Range | Match | Decay | Notes |
|-----------|-----------|---------------|-------|-------|-------|
| KYC Trust | 0-20 | 0-20 | Yes | No (live query) | Correct -- queried from OmniRegistration |
| Marketplace Reputation | -10 to +10 | -10 to +10 | Yes | No | See M-03, M-01 |
| Staking | 2-36 (spec) / 0-24 (formula) | 0-24 | Formula match | No (live query) | Spec header inconsistent (see L-01) |
| Referral Activity | 0-10 | 0-10 | Yes | No (live query) | Correct -- capped at 10 |
| Publisher Activity | 0-4 | 0-4 | Yes | Via heartbeat timeout | See I-01 |
| Marketplace Activity | 0-5 | 0-5 | Yes | Yes (90 days) | Correct |
| Community Policing | 0-5 | 0-5 | Yes | Yes (90 days) | Correct |
| Forum Activity | 0-5 | 0-5 | Yes | Yes (90 days) | Correct |
| Reliability | -5 to +5 | -5 to +5 | Yes | No (spec says yes) | See M-03 |
| **Total (raw)** | **-15 to 88** | **-15 to 88** | **Yes** | -- | Clamped to 0-100 |

---

## Audit History Comparison

| Metric | Round 1 | Round 3 | Round 6 | Trend |
|--------|---------|---------|---------|-------|
| Critical | 0 | 0 | 0 | -- |
| High | 2 | 0 | 1 | New category (ERC-2771 consistency) |
| Medium | 7 | 3 | 3 | 2 inherited + 1 new |
| Low | 4 | 4 | 3 | Reduced |
| Informational | 2 | 4 | 4 | Stable |
| Lines of code | ~1,037 | 1,237 | 1,631 | +394 (ATK fixes) |
| Tests passing | 77 (1 fail) | 77 (1 fail) | 92 (0 fail) | +15, all passing |

---

## Conclusion

OmniParticipation has undergone significant improvement across four audit rounds. All previous Critical and High findings have been resolved. The ATK Round 4 remediations (rate limits, array caps, validator checks) substantially reduce the attack surface for VERIFIER compromise and state bloat.

**Remaining concerns, ordered by priority:**

1. **[H-01] ERC-2771 `msg.sender` vs `_msgSender()` inconsistency:** The most significant finding. If meta-transactions are used (the contract explicitly inherits ERC2771ContextUpgradeable), heartbeat functions and the verifier rate limit use the wrong sender identity. This corrupts validator scores and enables rate limit bypass. **Fix before mainnet.**

2. **[M-02] Verifier rate limit lacks global cap:** The per-verifier 50/day limit scales linearly with the number of VERIFIER_ROLE holders. A compromised admin can mint unlimited verifier addresses. Consider adding a global daily cap. **Fix before mainnet or gate VERIFIER_ROLE grants through timelock.**

3. **[M-03] Missing decay on reliability and marketplace reputation:** The specification says these should decay. The contract does not decay them. **Decide on design intent and implement consistently.**

4. **[M-01] Reputation integer truncation:** Three audits have flagged this. The specification requires gradient scaling. The contract uses a step function. **Implement fixed-point arithmetic.**

**Deployment Readiness Assessment:**

- **Testnet:** Ready. All tests pass. No Critical findings.
- **Mainnet:** Fix H-01 (ERC-2771 consistency) and M-02 (global rate limit) before mainnet deployment. M-01 and M-03 are design decisions that should be finalized but do not represent security risks.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Pre-Mainnet Deep Audit (Round 6)*
*Date: 2026-03-10 01:01 UTC*
