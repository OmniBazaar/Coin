# Security Audit Report: OmniPriceOracle

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/oracle/OmniPriceOracle.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 893
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (price data, but feeds into fund-handling contracts)

## Executive Summary

OmniPriceOracle is a UUPS-upgradeable multi-validator price consensus oracle. Validators submit prices per round; when `minValidators` submissions arrive, the round auto-finalizes using median calculation. Chainlink feeds serve as bounds checks, a circuit breaker rejects large single-round changes, and a TWAP circular buffer smooths prices over a 1-hour window. **This contract has significant security issues.** Three Critical findings relate to upgrade safety (missing `__gap`, empty `_authorizeUpgrade`) and unbounded admin parameters. Six High findings include circuit breaker bypass, storage-based sorting DoS, small cartel control, and missing zero-address checks. The contract's 67% Cyfrin checklist compliance is the lowest of any Batch 2 contract.

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 6 |
| Medium | 5 |
| Low | 3 |
| Informational | 2 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 107 |
| Passed | 72 |
| Failed | 22 |
| Partial | 13 |
| **Compliance Score** | **67%** |

Top 5 failed checks:
1. SOL-Basics-PU-9/PU-10: Missing `__gap` storage variable — upgrade will corrupt state
2. SOL-Basics-PU-4: `_authorizeUpgrade()` empty body — no timelock, no validation
3. SOL-Basics-Function-1: `updateParameters()` has no upper/lower bounds validation
4. SOL-Timelock-1: No timelock on any admin operation
5. SOL-Defi-Oracle-14: Circuit breaker bypassable via incremental price walking

---

## Critical Findings

### [C-01] updateParameters() Has No Upper/Lower Bounds — Admin Can Destroy All Safety Mechanisms
**Severity:** Critical
**Category:** Access Control / Input Validation
**VP Reference:** VP-06 (Missing Access Control Safeguard), VP-22 (Missing Validation)
**Location:** `updateParameters()` (lines 650-666)
**Sources:** Agent-A, Agent-D, Cyfrin Checklist (SOL-Basics-Function-1, SOL-CR-4, SOL-CR-7)
**Real-World Precedent:** Mango Markets (Oct 2022) — $117M oracle manipulation loss

**Description:**
The `updateParameters` function accepts arbitrary values for all four critical safety parameters with only a `> 0` guard. An admin (or compromised admin key) can:
- Set `minValidators = 1` — single validator controls all prices
- Set `consensusTolerance = 10000` (100%) — any submission passes consensus
- Set `circuitBreakerThreshold = 10000` (100%) — circuit breaker disabled entirely
- Set `stalenessThreshold = type(uint256).max` — stale prices never detected

```solidity
if (_minValidators > 0) minValidators = _minValidators;
if (_consensusTolerance > 0) consensusTolerance = _consensusTolerance;
```

**Exploit Scenario:**
1. Admin key compromised via phishing or private key leak
2. Attacker calls `updateParameters(1, 10000, type(uint256).max, 10000)`
3. Single validator can now set any price — circuit breaker disabled, staleness disabled
4. All DeFi contracts consuming oracle prices (DEX, escrow, RWAAMM) are exploitable

**Recommendation:**
```solidity
uint256 private constant MIN_VALIDATORS_FLOOR = 3;
uint256 private constant MAX_CONSENSUS_TOLERANCE = 500;  // 5%
uint256 private constant MIN_STALENESS = 300;             // 5 minutes
uint256 private constant MAX_STALENESS = 86400;           // 24 hours
uint256 private constant MAX_CIRCUIT_BREAKER = 2000;      // 20%

function updateParameters(...) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_minValidators > 0) {
        require(_minValidators >= MIN_VALIDATORS_FLOOR, "min too low");
        minValidators = _minValidators;
    }
    // ... similarly for other parameters
    emit ParametersUpdated(minValidators, consensusTolerance, stalenessThreshold, circuitBreakerThreshold);
}
```

---

### [C-02] Missing Storage Gap — UUPS Upgrade Will Corrupt State
**Severity:** Critical
**Category:** Upgrade Safety
**VP Reference:** VP-43 (Storage Layout Violation in Upgrade)
**Location:** End of state variables section (after line 258)
**Sources:** Agent-A, Agent-D, Cyfrin Checklist (SOL-Basics-PU-9, SOL-Basics-PU-10)
**Real-World Precedent:** Strata (Cyfrin), StakeLink (CodeHawks), Zaros (CodeHawks) — all flagged for same issue

**Description:**
The contract is UUPS-upgradeable but declares no `__gap` storage variable. The contract has 14 explicit state variables plus multiple nested mappings. Any future upgrade adding a new state variable will shift all subsequent storage slots, silently corrupting `latestConsensusPrice`, `lastUpdateTimestamp`, TWAP observations, and other critical data.

**Exploit Scenario:**
1. Team upgrades to V2, adding `uint256 public maxPriceAge` between `twapWindow` and `registeredTokens`
2. `registeredTokens` array length reads from `twapWindow`'s slot (value 3600)
3. `getRegisteredTokens()` returns 3600 elements from uninitialized memory
4. `isRegisteredToken` mapping is shifted — no tokens appear "registered"
5. All `submitPrice()` calls revert — oracle is bricked

**Recommendation:**
```solidity
/// @dev Reserved storage gap for future upgrades
uint256[50] private __gap;
```

---

### [C-03] _authorizeUpgrade() Has Empty Body — No Timelock, No Ossification Control
**Severity:** Critical
**Category:** Upgrade Safety / Centralization
**VP Reference:** VP-09 (Unprotected Upgrade), VP-43 (Storage Layout)
**Location:** `_authorizeUpgrade()` (lines 890-892)
**Sources:** Agent-A, Agent-C, Cyfrin Checklist (SOL-Basics-PU-4, SOL-Timelock-1)
**Real-World Precedent:** OpenZeppelin UUPS Vulnerability Disclosure (2021)

**Description:**
The upgrade authorization function has only `onlyRole(DEFAULT_ADMIN_ROLE)` — an empty body with no timelock, no multi-sig, no event emission, no ossification mechanism, and no validation of the new implementation address. A single compromised admin key can instantly replace the entire oracle implementation.

```solidity
function _authorizeUpgrade(
    address newImplementation
) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
```

**Recommendation:**
Implement a 48-hour timelock (matching OmniValidatorRewards pattern):
```solidity
uint256 public constant UPGRADE_DELAY = 48 hours;
address public pendingImplementation;
uint256 public upgradeScheduledAt;

function scheduleUpgrade(address newImpl) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newImpl != address(0) && newImpl.code.length > 0, "invalid");
    pendingImplementation = newImpl;
    upgradeScheduledAt = block.timestamp + UPGRADE_DELAY;
    emit UpgradeScheduled(newImpl, upgradeScheduledAt);
}

function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newImplementation == pendingImplementation, "not scheduled");
    require(block.timestamp >= upgradeScheduledAt, "timelock active");
    delete pendingImplementation;
    delete upgradeScheduledAt;
}
```

---

## High Findings

### [H-01] Circuit Breaker Bypass via Incremental Price Walking
**Severity:** High
**Category:** Oracle Manipulation
**VP Reference:** VP-17 (Spot Price Manipulation), VP-19 (Insufficient TWAP Window)
**Location:** `submitPrice()` (lines 401-409)
**Sources:** Agent-A, Agent-D, Cyfrin Checklist (SOL-Defi-Oracle-14)
**Real-World Precedent:** Folks Finance (Immunefi) — circuit breaker logic bug

**Description:**
The circuit breaker rejects individual submissions deviating >10% from previous consensus. However, each finalized round becomes the new reference. A cartel of 3 validators can "walk" the price 9.9% per round. After 10 rounds (~20 seconds), price moves 157%. After 20 rounds (~40 seconds), price moves 560%. For tokens without Chainlink feeds, there is no backstop.

**Recommendation:**
Implement a cumulative deviation limit over a sliding window:
```solidity
uint256 public maxCumulativeDeviation; // e.g., 2000 bps (20%) per hour
mapping(address => uint256) public anchorPrice;
mapping(address => uint256) public anchorTimestamp;
```

---

### [H-02] setOmniCore() Missing Zero-Address Check — Can Brick Oracle
**Severity:** High
**Category:** Input Validation
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** `setOmniCore()` (lines 672-676)
**Sources:** Agent-A, Agent-C, Cyfrin Checklist (SOL-Basics-Function-1)

**Description:**
Setting `omniCore` to `address(0)` causes every `submitPrice()` call to revert with `NotValidator()` because the zero address has no `isValidator` function. The oracle is permanently bricked until the admin calls `setOmniCore` again with a valid address. No event is emitted for this change.

**Recommendation:**
```solidity
function setOmniCore(address _omniCore) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_omniCore != address(0), "zero address");
    require(_omniCore.code.length > 0, "not a contract");
    emit OmniCoreUpdated(address(omniCore), _omniCore);
    omniCore = IOmniCoreOracle(_omniCore);
}
```

---

### [H-03] _sortArray() Uses Insertion Sort on Storage — Quadratic Gas DoS
**Severity:** High
**Category:** Denial of Service
**VP Reference:** VP-29 (Unbounded Loop / Block Gas Limit)
**Location:** `_sortArray()` (lines 872-883)
**Sources:** Agent-A, Agent-D, Cyfrin Checklist (SOL-Basics-AL-9)
**Real-World Precedent:** Kinetiq M-05 (DoS via deposit spam, Code4rena)

**Description:**
`_sortArray` performs insertion sort directly on a `uint256[] storage` array. Each SLOAD costs ~2,100 gas and each SSTORE costs 5,000-20,000 gas. With `MAX_SUBMISSIONS_PER_ROUND = 50`, worst case (reverse-sorted) produces 1,225 iterations × ~2,300 gas = ~2.8M gas for sorting alone. The finalizing validator bears this cost.

**Recommendation:**
Sort in memory instead of storage:
```solidity
uint256[] memory prices = new uint256[](count);
for (uint256 i = 0; i < count; ++i) prices[i] = submissions[i];
_sortMemoryArray(prices); // O(n²) in memory is ~200x cheaper
```

---

### [H-04] minValidators = 3 Allows Small Cartel to Control All Prices
**Severity:** High
**Category:** Oracle Manipulation / Sybil
**VP Reference:** VP-17 (Spot Price Manipulation), VP-20 (Flash Loan Oracle Manipulation)
**Location:** `submitPrice()` (line 420), `initialize()` (line 348)
**Sources:** Agent-A, Agent-D, Cyfrin Checklist (SOL-AM-SybilAttack-1)

**Description:**
Default `minValidators = 3` means only 3 validators must agree to finalize any round. Auto-finalization at `minValidators` means honest validators who would submit different prices never get a chance — the round is already closed. Chainlink provides no backstop for tokens without configured feeds. Industry standard (Chainlink) uses 21-31 nodes per price feed.

**Recommendation:**
Require `minValidators` to be a meaningful fraction of total active validators (e.g., >= 2/3). Add minimum round duration before finalization is allowed. Set `MIN_VALIDATORS_FLOOR = 5` or higher.

---

### [H-05] submissionCount Truncated to uint8 — Silent Overflow at 256
**Severity:** High
**Category:** Arithmetic
**VP Reference:** VP-14 (Unsafe Downcast)
**Location:** `_finalizeRound()` (line 731), `PriceRound` struct (line 151)
**Sources:** Agent-A, Cyfrin Checklist (SOL-Basics-Type-1)

**Description:**
`PriceRound.submissionCount` is `uint8` (max 255). The cast `uint8(count)` silently truncates values above 255. While `MAX_SUBMISSIONS_PER_ROUND = 50` prevents this today, a future parameter change or upgrade could trigger silent data loss.

**Recommendation:**
Use `SafeCast.toUint8(count)` or change `submissionCount` to `uint16`/`uint32`.

---

### [H-06] getRegisteredTokens() Returns Unbounded Array — No Deregister Function
**Severity:** High
**Category:** Denial of Service
**VP Reference:** VP-29 (Unbounded Loop / Block Gas Limit)
**Location:** `getRegisteredTokens()` (lines 548-554)
**Sources:** Agent-A, Cyfrin Checklist (SOL-Basics-AL-9)

**Description:**
Returns entire `registeredTokens` array (up to `MAX_TOKENS = 500`). No pagination support. No mechanism to deregister tokens — the array grows monotonically. If a token is deprecated, the only fix is a contract upgrade.

**Recommendation:**
Add pagination and a `deregisterToken()` function:
```solidity
function getRegisteredTokensPaginated(uint256 offset, uint256 limit) external view returns (address[] memory, uint256 total);
function deregisterToken(address token) external onlyRole(ORACLE_ADMIN_ROLE);
```

---

## Medium Findings

### [M-01] VALIDATOR_ROLE Defined but Never Used — Dead Code
**Severity:** Medium
**VP Reference:** VP-06 (Missing Access Control)
**Location:** Line 173, `submitPrice()` (line 372)
**Sources:** Agent-A, Cyfrin Checklist (PARTIAL SOL-Basics-AC-2)

**Description:**
`VALIDATOR_ROLE` constant is defined but never checked. Validator auth uses `omniCore.isValidator()` exclusively. This creates confusion and wastes storage. Consider either removing the role or implementing dual-check for defense-in-depth.

---

### [M-02] submitPriceBatch() Silently Skips Invalid Entries
**Severity:** Medium
**VP Reference:** VP-30 (DoS via Silent Failure)
**Location:** `submitPriceBatch()` (lines 440-478)
**Sources:** Agent-A, Cyfrin Checklist (SOL-Basics-AL-13)

**Description:**
All validation failures use `continue` — the caller receives a successful transaction with no indication of which entries were processed. A validator submitting 100 prices might have 50 silently dropped.

**Recommendation:**
Return a `bool[]` bitmap or emit `SubmissionSkipped` events.

---

### [M-03] getTWAP() Iterates Full Buffer Including Stale Observations
**Severity:** Medium
**VP Reference:** VP-29 (Unbounded Loop), VP-19 (TWAP Window)
**Location:** `getTWAP()` (lines 502-530)
**Sources:** Agent-A

**Description:**
Iterates all 1,800 observations regardless of the TWAP window. No early termination when observations fall outside the time window. For view functions, this can cause RPC timeouts. The circular buffer's `_twapIndex` is not used for ordered iteration.

---

### [M-04] Chainlink Feed Returns 0 on Failure — Silently Disables Bounds Check
**Severity:** Medium
**VP Reference:** VP-18 (Stale Chainlink Price Feed)
**Location:** `_getChainlinkPrice()` (lines 815-847)
**Sources:** Agent-A, Cyfrin Checklist (SOL-AM-DOSA-6, SOL-Defi-Oracle-3)

**Description:**
When `_getChainlinkPrice` returns 0 (feed down, stale, or negative), the caller silently skips the Chainlink bounds check. No event is emitted. During Chainlink outages, validators can submit prices with no external bounds check. Additionally, the `answeredInRound >= roundId` staleness check is missing.

**Recommendation:**
Emit `ChainlinkFeedFailed` event. Add `answeredInRound` check. Consider requiring valid Chainlink price when feed is enabled.

---

### [M-05] _twapIndex Cycling Bug — Not Monotonic
**Severity:** Medium
**VP Reference:** VP-12 (Integer Overflow — theoretical)
**Location:** `_addTWAPObservation()` (lines 769-773)
**Sources:** Agent-A

**Description:**
The TWAP write index is set to `idx + 1` (where `idx = _twapIndex % MAX`) instead of `_twapIndex + 1`. This causes the index to cycle between 0 and 1800 rather than monotonically increasing. While the circular buffer still works correctly, it makes the index misleading for any future use.

**Recommendation:**
```solidity
_twapIndex[token] = (_twapIndex[token] + 1) % MAX_TWAP_OBSERVATIONS;
```

---

## Low Findings

### [L-01] violationCount Never Enforced or Decayed
**Severity:** Low
**VP Reference:** VP-34 (Business Logic Flaw)
**Location:** `_flagOutliers()` (lines 786-808)
**Sources:** Agent-A

**Description:**
`violationCount` increments for each outlier submission but has no enforcement threshold, no automatic suspension, no decay, and no admin reset. A validator with 1,000 violations has the same authority as one with 0.

---

### [L-02] No Events for Parameter/OmniCore Changes
**Severity:** Low
**VP Reference:** VP-34 (Auditability)
**Location:** `updateParameters()` (lines 650-666), `setOmniCore()` (lines 672-676)
**Sources:** Agent-A, Cyfrin Checklist (SOL-CR-5, SOL-Basics-Event-1)

**Description:**
Neither function emits events. Off-chain monitoring cannot detect critical parameter changes. If an attacker sets `minValidators = 1` via C-01, there is no on-chain evidence.

---

### [L-03] initialize() Does Not Validate _omniCore Parameter
**Severity:** Low
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** `initialize()` (line 346)
**Sources:** Agent-A, Cyfrin Checklist (PARTIAL SOL-Basics-PU-3)

**Description:**
The initializer does not check that `_omniCore` is non-zero or a valid contract. If deployed with `address(0)`, the oracle is immediately bricked with no recovery via re-initialization.

---

## Informational Findings

### [I-01] Front-Running Risk on submitPrice()
**Severity:** Informational
**Location:** `submitPrice()` (lines 368-423)
**Sources:** Cyfrin Checklist (SOL-Defi-Oracle-10, SOL-Basics-Function-3)

**Description:**
Validators can see other validators' submissions in the mempool and front-run them. Since auto-finalization occurs at `minValidators` (3), the first 3 validators to land determine the median. A commit-reveal scheme would mitigate this.

---

### [I-02] isStale() Not Enforced — Consumers Must Check Themselves
**Severity:** Informational
**Location:** `isStale()` (lines 490-495), `latestConsensusPrice` (line 219)
**Sources:** Cyfrin Checklist (PARTIAL SOL-Defi-Oracle-3)

**Description:**
The oracle provides an `isStale()` function but does not enforce it. `latestConsensusPrice` returns stale data without warning. Downstream contracts that forget to call `isStale()` will consume stale prices.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Mango Markets | Oct 2022 | $117M | Oracle manipulation via insufficient bounds |
| Folks Finance | 2024 | N/A | Circuit breaker logic bug in oracle |
| Euler Finance | Mar 2023 | $197M | Price oracle manipulation |
| Bonq DAO | Feb 2023 | $120M | TellorFlex oracle manipulation |

## Solodit Similar Findings

- [Strata (Cyfrin)](https://solodit.cyfrin.io): Missing __gap in upgradeable contracts
- [StakeLink (CodeHawks)](https://codehawks.cyfrin.io/c/2024-09-stakelink/s/439): UUPS without storage gap
- [Zaros (CodeHawks)](https://codehawks.cyfrin.io/c/2025-01-zaros-part-2/s/450): Missing __gap in multiple contracts
- [Morpheus (CodeHawks)](https://codehawks.cyfrin.io/c/2024-01-Morpheus/s/163): block.timestamp deadline issue

## Static Analysis Summary

### Slither
Slither full-project analysis timed out (>5 minutes). Findings filtered from prior run did not reveal additional issues beyond LLM agents.

### Aderyn
Aderyn crashed with internal error on import resolution (v0.6.8).

### Solhint
0 errors, 23 warnings:
- 2 code-complexity (cyclomatic complexity 13-14 in `submitPrice`/`submitPriceBatch`)
- 10 gas-indexed-events (events could have more indexed parameters)
- 6 gas-strict-inequalities (could use strict comparisons)
- 2 not-rely-on-time (legitimate TWAP usage — acceptable)
- 1 ordering (function order)
- 1 gas-increment-by-one (violationCount++)
- 1 ordering (custom error after interface)

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | updateParameters, setOmniCore, setChainlinkFeed, registerToken, pause, unpause, _authorizeUpgrade | 9/10 |
| ORACLE_ADMIN_ROLE | registerToken, setChainlinkFeed | 3/10 |
| VALIDATOR_ROLE | (defined but never used) | 0/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** 9/10 — A compromised DEFAULT_ADMIN_ROLE can: (1) set all safety parameters to extreme values (C-01), (2) instantly upgrade to malicious implementation (C-03), (3) set OmniCore to zero-address to brick oracle (H-02), (4) set minValidators=1 to enable single-validator price control (C-01 + H-04).

**Recommendation:** This contract urgently needs a timelock on all admin operations, multi-sig requirement for DEFAULT_ADMIN_ROLE, and ossification mechanism for permanent finalization. The OmniValidatorRewards contract demonstrates the correct pattern with 48-hour timelock and ossification — OmniPriceOracle should follow the same design.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
