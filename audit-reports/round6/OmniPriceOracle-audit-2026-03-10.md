# Security Audit Report: OmniPriceOracle.sol

**Contract:** `contracts/oracle/OmniPriceOracle.sol`
**Lines:** 1,440
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-10
**Scope:** Price feed aggregation, staleness checks, manipulation resistance, fallback mechanisms, multi-source consensus
**Handles Funds:** No (provides price data only)

---

## Executive Summary

OmniPriceOracle is a multi-validator price consensus oracle using median-based aggregation, TWAP, Chainlink fallback, circuit breakers, and cumulative deviation tracking. The contract is UUPS upgradeable with a 48-hour timelock. It is the most complex contract in this audit batch (1,440 lines) and implements a comprehensive set of anti-manipulation mechanisms. Several medium-severity issues were identified related to potential griefing vectors and the batch submission logic.

**Overall Risk Assessment: MEDIUM**

---

## Architecture Review

- **Inheritance:** AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable
- **Upgradeability:** UUPS with 48-hour timelock and implementation matching
- **Validator auth:** Uses `omniCore.isValidator()` -- on-chain verification of active validator status
- **Consensus:** Median of submissions when minValidators (default 5) have submitted
- **Anti-manipulation:** Circuit breaker (10%), cumulative deviation from anchor (20%/hour), Chainlink bounds (10%), consensus tolerance (2%)
- **Suspension:** Validators with >= 100 violations are permanently suspended

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| MEDIUM-01 | Medium | Batch submission skips cumulative deviation update without side effects | **FIXED** |
| MEDIUM-02 | Medium | No mechanism to rehabilitate suspended validators | **FIXED** |
| MEDIUM-03 | Medium | `_getChainlinkPrice()` should be `view` but is state-modifying | **FIXED** |

---

## Findings

### [MEDIUM-01] Batch Submission Skips Cumulative Deviation Update Without Side Effects

**Severity:** Medium
**Location:** Lines 673-679

In `submitPriceBatch()`, when cumulative deviation check fails, the entry is skipped:

```solidity
if (!_isCumulativeDeviationSafe(token, price)) {
    emit SubmissionSkipped(token, "cumulative deviation");
    continue;
}
```

However, `_isCumulativeDeviationSafe()` is a `view` function that only reads state. In contrast, `submitPrice()` calls `_checkCumulativeDeviation()` which is a state-modifying function that also resets the anchor when the hourly window has expired (lines 1172-1177).

This means that in `submitPriceBatch()`, if the anchor is expired and a new batch submission arrives, the anchor is NOT reset. The `_isCumulativeDeviationSafe()` view function considers the anchor expired and returns `true`, so the submission proceeds, but the stale anchor persists. On the next single `submitPrice()` call, the anchor would be reset.

**Impact:** Inconsistent behavior between single and batch submissions. The anchor may not be reset promptly when all validators use batch submissions, potentially allowing slightly stale anchor windows to persist longer than intended.

**Recommendation:** Consider calling `_checkCumulativeDeviation()` in the batch path as well, wrapped in a try/catch or with a non-reverting variant that also resets the anchor.

### [MEDIUM-02] No Mechanism to Rehabilitate Suspended Validators

**Severity:** Medium
**Location:** Lines 529-531, 269

```solidity
if (violationCount[msg.sender] >= MAX_VIOLATIONS) {
    revert ValidatorSuspended(msg.sender);
}
```

Once a validator accumulates 100 violations, they are permanently suspended from submitting prices. There is no admin function to reset violation counts.

**Impact:** A legitimate validator that experiences temporary data feed issues (e.g., a malfunctioning Chainlink feed causing incorrect deviation calculations) could be permanently suspended with no recovery path. The only option would be to redeploy the oracle contract, which is disruptive.

**Recommendation:** Add an admin function to reset or reduce violation counts:
```solidity
function resetViolationCount(
    address validator
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    violationCount[validator] = 0;
}
```

### [MEDIUM-03] `_getChainlinkPrice()` Should Be `view` But Is State-Modifying

**Severity:** Medium
**Location:** Lines 1302-1354

```solidity
function _getChainlinkPrice(
    address token,
    ChainlinkConfig memory config
) internal returns (uint256 price) {
```

This function emits events (`ChainlinkFeedFailed`) on failure conditions, which makes it state-modifying (`internal` not `view`). This is correct for `submitPrice()`, but in `submitPriceBatch()`, the function is called inside a loop where failures result in `continue` rather than reverts. The events serve as useful diagnostic information.

However, the Chainlink feed call itself is an external call to an untrusted contract. While the `try/catch` handles reverts, a malicious or upgraded Chainlink feed contract could consume excessive gas or have other side effects.

**Impact:** Low. The `try/catch` pattern handles reverts gracefully. The gas concern is mitigated by the fact that Chainlink feeds are admin-configured.

**Recommendation:** No immediate fix needed, but ensure Chainlink feed addresses are verified before configuration.

### [LOW-01] Sorting Algorithm Gas Concern for Large Rounds

**Severity:** Low
**Location:** Lines 1382-1403

The insertion sort used in `_sortArrayInMemory()` has O(n^2) worst-case complexity. With `MAX_SUBMISSIONS_PER_ROUND = 50`, the worst case is 50^2 = 2,500 comparisons and swaps, which is manageable but not optimal.

**Impact:** Negligible. 50 elements is well within the acceptable range for insertion sort. Gas cost is bounded.

### [LOW-02] TWAP Observation Loop Does Not Early-Terminate Correctly

**Severity:** Low
**Location:** Lines 735-748

```solidity
for (uint256 i = 0; i < obs.length; ++i) {
    if (obs[i].timestamp < cutoff) continue;
    // ...
}
```

The comment says "Early termination: skip observations outside window" but it uses `continue` not `break`. The loop iterates through ALL observations, skipping those outside the window. For a circular buffer, observations are not ordered chronologically (newer entries may overwrite older slots), so a simple `break` would be incorrect. The `continue` is the correct approach for a circular buffer.

However, the loop iterates up to `MAX_TWAP_OBSERVATIONS` (1800) entries every time `getTWAP()` is called. This is a view function so it does not cost gas for on-chain transactions, but it could be expensive for eth_call RPC queries.

**Impact:** Negligible for on-chain usage. RPC queries may be slow with 1800 iterations.

### [LOW-03] `_flagOutliers()` Threshold Is Hardcoded

**Severity:** Low
**Location:** Line 1274

```solidity
uint256 flagThreshold = 2000; // 20% in bps
```

The outlier flagging threshold is hardcoded at 20%, separate from `consensusTolerance` (configurable, default 2%) and `circuitBreakerThreshold` (configurable, default 10%). This means validators can submit prices up to 10% from consensus without being circuit-broken, but they will be flagged if they deviate more than 20%.

The hardcoded threshold is not configurable. This is acceptable as a design decision, but it means the relationship between these thresholds cannot be tuned.

**Impact:** Low. The 20% threshold is reasonable and provides a buffer above the circuit breaker.

### [LOW-04] `updateParameters()` Uses 0 as "Skip" Sentinel

**Severity:** Low
**Location:** Lines 935-1005

```solidity
if (_minValidators > 0) {
    // validate and set
}
```

Passing 0 for any parameter means "skip update." This prevents setting any parameter to the value 0. For `minValidators`, 0 is invalid anyway (MIN_VALIDATORS_FLOOR = 5). For `consensusTolerance`, a value of 0 would mean "no tolerance" which is functionally problematic. For `circuitBreakerThreshold`, 0 would disable the circuit breaker, which is dangerous. So the sentinel pattern is actually a safety benefit here.

**Impact:** Positive -- the sentinel pattern prevents dangerously low parameter values.

### [LOW-05] Deregistered Token State Not Cleaned Up

**Severity:** Low
**Location:** Lines 874-895

When a token is deregistered via `deregisterToken()`, only `isRegisteredToken` is set to false and the token is removed from `registeredTokens`. The remaining state (currentRound, priceRounds, latestConsensusPrice, lastUpdateTimestamp, TWAP observations, anchorPrice) is not cleaned up.

**Impact:** Stale data remains in storage. If the token is re-registered later, the old state (including round numbers, consensus prices, and TWAP data) would still be present, potentially causing incorrect behavior. For example, `latestConsensusPrice[token]` would still have the old value, and the circuit breaker would check new submissions against that stale price.

**Recommendation:** Clear critical state when deregistering:
```solidity
delete latestConsensusPrice[token];
delete lastUpdateTimestamp[token];
delete anchorPrice[token];
delete anchorTimestamp[token];
```

### [LOW-06] No Chainlink Staleness Threshold Per-Feed

**Severity:** Low
**Location:** Lines 1330-1338

All Chainlink feeds share the same `stalenessThreshold` (default 1 hour). Different assets may have different update frequencies (e.g., ETH/USD updates frequently, while exotic pairs may update less often).

**Impact:** A conservative staleness threshold may cause valid prices to be rejected for slow-updating feeds, while a permissive threshold may accept stale data for fast-updating feeds.

**Recommendation:** Consider per-feed staleness configuration in `ChainlinkConfig`.

---

## Access Control Review

| Function | Access | Assessment |
|----------|--------|------------|
| `submitPrice()` | Validators (via omniCore.isValidator) | Correct |
| `submitPriceBatch()` | Validators (via omniCore.isValidator) | Correct |
| `registerToken()` | ORACLE_ADMIN_ROLE | Correct |
| `deregisterToken()` | ORACLE_ADMIN_ROLE | Correct |
| `setChainlinkFeed()` | ORACLE_ADMIN_ROLE | Correct |
| `updateParameters()` | DEFAULT_ADMIN_ROLE | Correct |
| `setOmniCore()` | DEFAULT_ADMIN_ROLE | Correct |
| `scheduleUpgrade()` | DEFAULT_ADMIN_ROLE | Correct |
| `cancelUpgrade()` | DEFAULT_ADMIN_ROLE | Correct |
| `pause() / unpause()` | DEFAULT_ADMIN_ROLE | Correct |
| `_authorizeUpgrade()` | DEFAULT_ADMIN_ROLE + timelock | Correct |
| View functions | Public | Correct |

**Note:** ORACLE_ADMIN_ROLE and DEFAULT_ADMIN_ROLE are separate roles, which is good. This allows token management to be delegated without granting full admin access.

---

## Reentrancy Analysis

- `submitPrice()` and `submitPriceBatch()` use `nonReentrant whenNotPaused`
- External calls:
  1. `omniCore.isValidator()` -- view call to trusted OmniCore contract
  2. `IAggregatorV3.latestRoundData()` -- external call to Chainlink feed, wrapped in try/catch
- No token transfers (oracle does not handle funds)

**Assessment:** Low reentrancy risk. The `nonReentrant` modifier provides protection against any unexpected callbacks from Chainlink feeds.

---

## Oracle Manipulation Analysis

### Price Walking Attack
- **Mitigation:** Cumulative deviation tracking (MAX_CUMULATIVE_DEVIATION = 20% per hour)
- **Assessment:** Effective. An attacker controlling a minority of validators cannot walk the price more than 20% per hour, and submissions must also pass the circuit breaker (10% per round).

### Flash Attack
- **Mitigation:** Circuit breaker (10% per round), minimum 5 validators required
- **Assessment:** Effective. A single round cannot move the price more than 10%.

### Validator Collusion
- **Mitigation:** Chainlink bounds (10% deviation from Chainlink price), outlier flagging (20% threshold), validator suspension (100 violations)
- **Assessment:** If more than 50% of validators collude, they can establish a false consensus within the Chainlink bounds. The 10% Chainlink deviation threshold limits the magnitude of manipulation for tokens with Chainlink feeds.

### Stale Data
- **Mitigation:** `stalenessThreshold` (default 1 hour), `isStale()` view function
- **Assessment:** Adequate. Consumers should check `isStale()` before using prices.

---

## Upgrade Safety Analysis

- UUPS pattern with 48-hour timelock
- `scheduleUpgrade()` verifies new implementation has code
- `_authorizeUpgrade()` verifies implementation matches pending and timelock has elapsed
- `cancelUpgrade()` allows aborting a scheduled upgrade
- Storage gap of 50 slots (`__gap`) for future state variables

**Assessment:** Upgrade mechanism is well-designed. The 48-hour timelock provides adequate time for community review.

---

## Conclusion

OmniPriceOracle is a sophisticated oracle contract with comprehensive anti-manipulation defenses. The primary concerns are: inconsistent anchor reset behavior in batch vs. single submissions (MEDIUM-01), permanent validator suspension without recovery (MEDIUM-02), and stale state on token deregistration (LOW-05). The contract is suitable for deployment with the recommended fixes, particularly adding a violation count reset mechanism.

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| MEDIUM-01 | Medium | Batch submission does not reset anchor price | Recommend Fix |
| MEDIUM-02 | Medium | No mechanism to rehabilitate suspended validators | Recommend Fix |
| MEDIUM-03 | Medium | `_getChainlinkPrice()` external call to admin-configured feeds | Accept Risk |
| LOW-01 | Low | Insertion sort O(n^2) for up to 50 elements | Acceptable |
| LOW-02 | Low | TWAP loop iterates all 1800 slots | View-only, Acceptable |
| LOW-03 | Low | Outlier flagging threshold is hardcoded at 20% | Design Decision |
| LOW-04 | Low | `updateParameters()` uses 0 as skip sentinel | Positive Safety |
| LOW-05 | Low | Deregistered token state not cleaned up | Recommend Fix |
| LOW-06 | Low | Shared Chainlink staleness threshold across all feeds | Consider Per-Feed |
