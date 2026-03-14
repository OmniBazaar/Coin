# Security Audit Report: OmniTimelockController (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Opus 4.6 -- Deep Manual Review (6-Pass Methodology)
**Contract:** `Coin/contracts/OmniTimelockController.sol`
**Solidity Version:** 0.8.24
**OpenZeppelin Version:** 5.4.0 (TimelockController base)
**Lines of Code:** 347
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (inherits ETH `receive()` and ERC721/ERC1155 holding from TimelockController; all timelocked governance operations pass through this contract)
**Test Coverage:** `Coin/test/UUPSGovernance.test.js` (Section 2, ~12 test cases)
**Previous Audits:** Round 5 (2026-02-26), Round 6 (2026-03-10)
**Slither:** Skipped

---

## Scope

This round-7 pre-mainnet audit covers the OmniTimelockController contract at 347 lines using a 6-pass methodology:

1. **Pass 1:** Solhint static analysis + full contract read
2. **Pass 2:** Manual line-by-line code review
3. **Pass 3:** Access control and authorization mapping
4. **Pass 4:** Economic/financial analysis (delay bounds, proposal lifecycle)
5. **Pass 5:** Integration and edge cases (external calls, zero values, upgrade safety)
6. **Pass 6:** Report generation

The audit focuses on:
- Verification of all prior remediation (M-01 through M-03, L-01 through L-04, GOV-ATK-H02)
- Independent verification of all 11 critical selector constants against keccak256 computation
- Two-tier delay enforcement correctness
- Self-administration access control
- Integration with OmniGovernance and EmergencyGuardian
- Inherited OpenZeppelin TimelockController security

---

## Executive Summary

This audit uncovered a **High-severity finding**: the `SEL_OSSIFY` selector constant (line 93) contains an incorrect value. The constant is set to `0x32e3a7b4`, but the actual keccak256-derived selector for `ossify()` is `0x7271518a`. This means the ossify() protection added in Round 6 (GOV-ATK-H02 fix) is **completely non-functional** -- actual ossify() calls pass through with only a 48-hour ROUTINE delay instead of the intended 7-day CRITICAL delay.

The wrong selector `0x32e3a7b4` was registered in the `_criticalSelectors` mapping during construction, but since no real function has this selector, it protects nothing. The test at line 222 of `UUPSGovernance.test.js` also uses the wrong value, so the test passes despite the bug.

All other aspects of the contract remain well-implemented and match the Round 6 assessment.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 0 |
| Low | 2 |
| Informational | 3 |

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | High | `SEL_OSSIFY` contains wrong selector value -- ossify() protection is non-functional | **OPEN** |
| L-01 | Low | Hardcoded critical selectors can be removed via `removeCriticalSelector()` | Acknowledged (carried from R5/R6) |
| L-02 | Low | No maximum delay enforcement allows unbounded scheduling | Acknowledged (carried from R5/R6) |
| I-01 | Info | `getRequiredDelay()` returns `getMinDelay()` for non-critical ops (correct behavior) | Acknowledged |
| I-02 | Info | `criticalSelectorCount` provides limited utility without enumeration | Acknowledged |
| I-03 | Info | `transferOwnership(address)` not classified as critical | Acknowledged |

---

## Detailed Findings

### [H-01] `SEL_OSSIFY` Contains Wrong Selector Value -- ossify() Protection Is Non-Functional

**Severity:** High
**Line:** 93
**Category:** Incorrect Constant / Broken Security Control

**Description:**

The constant `SEL_OSSIFY` at line 93 is defined as:

```solidity
bytes4 public constant SEL_OSSIFY = 0x32e3a7b4;
```

However, the actual Solidity function selector for `ossify()` is computed as:

```
keccak256("ossify()") = 0x7271518a...
bytes4 selector       = 0x7271518a
```

Independent verification confirms `0x32e3a7b4` does NOT match `ossify()`, `ossify(address)`, `ossify(bool)`, `freeze()`, `lock()`, `finalize()`, or any other obvious function signature. The value `0x32e3a7b4` appears to be a computation error introduced during the Round 6 remediation of GOV-ATK-H02.

**Impact:**

The constructor registers `0x32e3a7b4` in the `_criticalSelectors` mapping (line 148), but no actual contract function has this selector. When a governance proposal calls `ossify()` on any target contract (OmniGovernance, OmniCore, OmniBridge, OmniParticipation, etc.), the timelock's `_isCriticalCall()` extracts the real selector `0x7271518a`, finds it is NOT in the critical mapping, and allows the operation to proceed with only a 48-hour ROUTINE delay.

This defeats the purpose of the GOV-ATK-H02 fix. Ossification -- the most permanent and irreversible action in the protocol -- can proceed with only 2 days of community review instead of the intended 7 days.

**Attack scenario:**

```
1. Attacker passes a governance proposal classified as ROUTINE
   that calls ossify() on OmniGovernance (or any UUPS contract)
2. OmniGovernance._validateNoCriticalSelectors() queries timelock
   with selector 0x7271518a -- timelock returns false (not critical)
3. ROUTINE proposal is created and voted on
4. Proposal is queued with 48-hour delay
5. Community has only 48 hours to detect and cancel
6. If executed, the target contract is PERMANENTLY frozen
7. Any bugs in the current implementation can never be fixed
```

**Why the test didn't catch it:**

The test at line 222 of `UUPSGovernance.test.js` checks:
```javascript
const ossifySel = "0x32e3a7b4"; // bytes4(keccak256("ossify()"))
expect(await timelock.isCriticalSelector(ossifySel)).to.be.true;
```

This passes because the wrong selector IS stored in the mapping -- the test checks the same wrong value. The test should instead compute the selector dynamically or test actual ossify() calldata.

**Root cause:** The comment `// bytes4(keccak256("ossify()"))` suggests the value was intended to be computed from `keccak256("ossify()")`, but an incorrect precomputed value was used. The other 10 selectors were all verified correct in prior audits, suggesting this was an error during the Round 6 addition.

**Recommendation:**

Fix the constant to the correct selector value:

```solidity
/// @notice Ossification selector: ossify()
/// @dev GOV-ATK-H02: Classified as critical because ossification is
///      permanent and irreversible -- the most impactful action in the
///      protocol. Must require 7-day CRITICAL_DELAY, not 48h ROUTINE.
bytes4 public constant SEL_OSSIFY = 0x7271518a;
```

Also fix the test at line 222 of `UUPSGovernance.test.js`:

```javascript
const ossifySel = "0x7271518a"; // bytes4(keccak256("ossify()"))
```

Or better yet, compute it dynamically in the test:

```javascript
const ossifySel = ethers.id("ossify()").substring(0, 10);
```

**Verification command:**

```bash
node -e "const ethers = require('ethers'); console.log(ethers.id('ossify()').substring(0,10))"
# Output: 0x7271518a
```

---

### [L-01] Hardcoded Critical Selectors Can Be Removed via `removeCriticalSelector()`

**Severity:** Low
**Lines:** 184-191
**Category:** Design Choice
**Status:** Acknowledged (carried from Round 5, L-01)

**Description:**

The `removeCriticalSelector()` function can remove any registered selector, including the 11 hardcoded selectors from the constructor (upgradeTo, grantRole, pause, etc.). There is no immutable minimum set.

**Mitigation:** This function is itself classified as critical (M-02 fix) and requires 7-day delay through governance, providing community review time. NatSpec warns this is "strongly discouraged."

**Recommendation:** No code change needed. Operational risk, not a code bug.

---

### [L-02] No Maximum Delay Enforcement Allows Unbounded Scheduling

**Severity:** Low
**Lines:** 267-279, 292-306
**Category:** Griefing
**Status:** Acknowledged (carried from Round 5/R6)

**Description:**

A proposer can schedule operations with arbitrarily large delays (up to `type(uint256).max`), which would never become executable. This is self-griefing since it only affects the proposer's own proposals.

**Mitigation:** EmergencyGuardian can cancel any pending operation via CANCELLER_ROLE. The proposer themselves can also cancel (OZ constructor grants CANCELLER_ROLE to all proposers).

**Recommendation:** No code change needed. The cancel mechanism provides adequate defense.

---

### [I-01] `getRequiredDelay()` Returns `getMinDelay()` for Non-Critical Operations

**Severity:** Informational
**Lines:** 211-218
**Category:** API Design
**Status:** Acknowledged (carried from Round 6)

**Description:**

For non-critical operations, `getRequiredDelay()` returns `getMinDelay()` (which reads `_minDelay` storage) rather than the constant `ROUTINE_DELAY`. If `updateDelay()` has been called to change the base minimum, the returned value reflects the new minimum. This is correct behavior -- the effective minimum is `max(ROUTINE_DELAY_at_deploy, current_minDelay)` because the OZ base enforces `delay >= getMinDelay()` in `_schedule()`.

**Recommendation:** No action needed. Behavior is correct.

---

### [I-02] `criticalSelectorCount` Provides Limited Utility Without Enumeration

**Severity:** Informational
**Line:** 100
**Category:** API Completeness
**Status:** Acknowledged (carried from Round 6)

**Description:**

`criticalSelectorCount` reports how many selectors are registered but does not provide enumeration. Discovery requires replaying `CriticalSelectorUpdated` events from genesis. The `areCriticalSelectors()` batch query enables verification of known selectors.

**Note:** With the H-01 fix, `criticalSelectorCount` should remain 11 (the incorrect selector `0x32e3a7b4` is replaced by the correct `0x7271518a` -- same count).

**Recommendation:** No action needed. Event replay is sufficient for the expected use case.

---

### [I-03] `transferOwnership(address)` Not Classified as Critical

**Severity:** Informational
**Category:** Coverage Gap Analysis

**Description:**

The function selector for `transferOwnership(address)` (`0xf2fde38b`) is not registered as a critical selector. If any governed contract uses the Ownable pattern instead of AccessControl, an ownership transfer would proceed with ROUTINE (48-hour) delay.

**Mitigation:** The OmniBazaar protocol uses AccessControl (with `grantRole`/`revokeRole` classified as critical) rather than Ownable for all governed contracts. No current contract is at risk.

**Recommendation:** If any future governed contract uses Ownable, register `transferOwnership(address)` as a critical selector via `addCriticalSelector()`. No current code change needed.

---

## Prior Findings Remediation Status

| Prior Finding | Severity | Status | Verification |
|---------------|----------|--------|--------------|
| R5-M-01: `updateDelay()` not critical | Medium | RESOLVED | Line 79: `SEL_UPDATE_DELAY = 0x64d62353`. Line 143: registered in mapping. Selector verified correct. |
| R5-M-02: Selector management not critical | Medium | RESOLVED | Lines 83-87: `SEL_ADD_CRITICAL` and `SEL_REMOVE_CRITICAL` defined. Lines 145-146: registered. Selectors verified correct. |
| R5-M-03: Access control pattern | Medium | RESOLVED | Lines 167, 185: `msg.sender != address(this)` check. Matches `updateDelay()` self-administration pattern. |
| R6-M-01/GOV-ATK-H02: `ossify()` not critical | Medium | **REGRESSION** | Line 93: `SEL_OSSIFY = 0x32e3a7b4` is WRONG. Correct selector is `0x7271518a`. The fix was applied but with an incorrect constant value, so the protection is non-functional. See H-01. |
| R5-L-01: Hardcoded selectors removable | Low | Acknowledged | No change. 7-day delay required for removal. |
| R5-L-02: No maximum delay | Low | Acknowledged | No change. Cancel mechanism mitigates. |
| R5-L-03: No batch query | Low | RESOLVED | Lines 242-249: `areCriticalSelectors()` provides batch checking. |
| R5-L-04: Empty calldata always routine | Low | Documented | Line 323: `data.length < 4` returns false. NatSpec documents this. |

---

## Selector Constant Verification

All 11 critical selector constants were independently verified against `keccak256` computation:

| Constant | Value | Function Signature | Expected | Verdict |
|----------|-------|-------------------|----------|---------|
| `SEL_UPGRADE_TO` | `0x3659cfe6` | `upgradeTo(address)` | `0x3659cfe6` | **Correct** |
| `SEL_UPGRADE_TO_AND_CALL` | `0x4f1ef286` | `upgradeToAndCall(address,bytes)` | `0x4f1ef286` | **Correct** |
| `SEL_GRANT_ROLE` | `0x2f2ff15d` | `grantRole(bytes32,address)` | `0x2f2ff15d` | **Correct** |
| `SEL_REVOKE_ROLE` | `0xd547741f` | `revokeRole(bytes32,address)` | `0xd547741f` | **Correct** |
| `SEL_RENOUNCE_ROLE` | `0x36568abe` | `renounceRole(bytes32,address)` | `0x36568abe` | **Correct** |
| `SEL_PAUSE` | `0x8456cb59` | `pause()` | `0x8456cb59` | **Correct** |
| `SEL_UNPAUSE` | `0x3f4ba83a` | `unpause()` | `0x3f4ba83a` | **Correct** |
| `SEL_UPDATE_DELAY` | `0x64d62353` | `updateDelay(uint256)` | `0x64d62353` | **Correct** |
| `SEL_ADD_CRITICAL` | `0xb634ebcf` | `addCriticalSelector(bytes4)` | `0xb634ebcf` | **Correct** |
| `SEL_REMOVE_CRITICAL` | `0x199e6fef` | `removeCriticalSelector(bytes4)` | `0x199e6fef` | **Correct** |
| `SEL_OSSIFY` | `0x32e3a7b4` | `ossify()` | `0x7271518a` | **WRONG (H-01)** |

Verification command used:
```bash
node -e "const e=require('ethers');['upgradeTo(address)','upgradeToAndCall(address,bytes)',
'grantRole(bytes32,address)','revokeRole(bytes32,address)','renounceRole(bytes32,address)',
'pause()','unpause()','updateDelay(uint256)','addCriticalSelector(bytes4)',
'removeCriticalSelector(bytes4)','ossify()'].forEach(s=>console.log(e.id(s).substring(0,10),s))"
```

---

## Two-Tier Delay Architecture Analysis

### Delay Enforcement Flow (Verified Correct for 10 of 11 Selectors)

```
OmniGovernance.queue(proposalId)
  |
  | Determines delay:
  |   CRITICAL proposal -> 7 days
  |   ROUTINE proposal  -> 48 hours
  |
  v
timelock.scheduleBatch(targets, values, payloads, 0, salt, delay)
  |
  v
OmniTimelockController.scheduleBatch() [override]
  |
  | Checks: _batchContainsCritical(payloads)
  |   For each payload, extracts 4-byte selector
  |   Looks up in _criticalSelectors mapping
  |   If critical AND delay < 7 days: revert
  |
  v
super.scheduleBatch() [OpenZeppelin TimelockController]
  |
  | Checks: delay >= getMinDelay() (48 hours base)
  | Sets: _timestamps[operationId] = block.timestamp + delay
  |
  v
Operation is pending. After delay, anyone can executeBatch().
```

### Defense-in-Depth (Broken for ossify())

The system provides two independent layers of critical selector enforcement:

1. **OmniGovernance layer:** `_validateNoCriticalSelectors()` queries the timelock's `isCriticalSelector()` for each action's selector. If critical, ROUTINE proposals are rejected at creation time.

2. **OmniTimelockController layer:** At scheduling time, the timelock independently validates that the delay is sufficient for the batch's criticality.

For `ossify()`, BOTH layers fail because the wrong selector is registered:
- OmniGovernance queries `isCriticalSelector(0x7271518a)` -> returns false (not registered)
- OmniTimelockController checks `_criticalSelectors[0x7271518a]` -> false (not registered)

Both layers would work correctly once the selector is fixed to `0x7271518a`.

### Delay Reduction Attack Analysis (Unchanged from Round 6)

- `updateDelay()` is correctly classified as critical. Reducing the base delay requires 7-day timelock.
- `CRITICAL_DELAY` is a `public constant` -- cannot be changed without new deployment.
- Selector management functions are critical -- require 7-day delay.
- The only path to reducing security is through legitimate governance with 7-day review.

---

## Access Control Mapping

```
DEFAULT_ADMIN_ROLE  --> address(this) [self-administered, OZ constructor line 118]
                        + admin param in constructor [should renounce after setup]

PROPOSER_ROLE       --> OmniGovernance [via grantRole after deployment]
                        + deployer [Phase 1, should revoke]

CANCELLER_ROLE      --> EmergencyGuardian [3-of-N guardian cancel]
                        + deployer [OZ auto-grants to proposers, line 128]

EXECUTOR_ROLE       --> address(0) [anyone can execute after delay]
```

**Notes:**
- OZ `TimelockController` constructor automatically grants CANCELLER_ROLE to all addresses in the `proposers` array (line 128 of OZ base). This means the deployer has CANCELLER_ROLE in addition to PROPOSER_ROLE during Phase 1.
- The `admin` constructor parameter receives DEFAULT_ADMIN_ROLE. This should be renounced after initial role setup is complete.
- Self-call functions (`addCriticalSelector`, `removeCriticalSelector`) use `msg.sender != address(this)` check, not role-based access. This is correct and matches the `updateDelay()` pattern.

---

## Gas Analysis

| Function | Additional Cost (vs. base OZ) | Notes |
|----------|-------------------------------|-------|
| `schedule()` | ~2,100 gas | One cold SLOAD for selector lookup |
| `scheduleBatch()` | ~2,100 * N gas | N SLOADs for N payloads |
| `addCriticalSelector()` | ~20,000 gas | One SSTORE (cold) + event |
| `removeCriticalSelector()` | ~2,900 gas | One SSTORE (warm, zero-out) + event |
| `isCriticalSelector()` | ~2,100 gas | One SLOAD |
| `areCriticalSelectors()` | ~2,100 * N gas | N SLOADs |
| `getRequiredDelay()` | ~4,200 gas | Selector SLOAD + minDelay SLOAD |

All within acceptable bounds for governance operations (infrequent, not gas-sensitive).

---

## Solhint Results

```
[solhint] Warning: Rule 'contract-name-camelcase' doesn't exist
[solhint] Warning: Rule 'event-name-camelcase' doesn't exist
```

No code-level warnings or errors. Only configuration warnings about non-existent rule names in the solhint config file.

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Fix Effort | Recommendation |
|---|---------|----------|------------|----------------|
| 1 | H-01 | High | Trivial | Change `SEL_OSSIFY` from `0x32e3a7b4` to `0x7271518a` |
| 2 | L-01 | Low | -- | Operational: revoke multisig PROPOSER_ROLE after governance operational |
| 3 | L-02 | Low | -- | Acknowledged: cancel mechanism mitigates unbounded delay |
| 4 | I-01 | Info | -- | Acknowledged: correct behavior |
| 5 | I-02 | Info | -- | Acknowledged: event replay sufficient |
| 6 | I-03 | Info | -- | Monitor: register `transferOwnership` if Ownable contracts added |

### MUST-FIX Before Mainnet

1. **H-01:** Change `SEL_OSSIFY` constant from `0x32e3a7b4` to `0x7271518a`. This is a single-character change on line 93 of the contract and line 222 of the test file. Without this fix, the irreversible `ossify()` function is completely unprotected by the critical delay, allowing permanent contract freezing with only 48 hours of community review.

### Should-Fix Before Mainnet

2. **Test improvement:** The test for `ossify()` critical classification (line 222 of `UUPSGovernance.test.js`) should compute the selector dynamically rather than using a hardcoded hex value. This would have caught H-01.

---

## Conclusion

OmniTimelockController has a fundamentally sound architecture: two-tier delays, defense-in-depth with OmniGovernance, self-administration pattern, and proper use of the OpenZeppelin TimelockController base. The contract's core design is well-hardened and 10 of 11 critical selectors are correctly implemented.

However, the single High-severity finding (H-01) is serious: the `ossify()` selector constant contains an incorrect precomputed value, rendering the GOV-ATK-H02 fix from Round 6 completely non-functional. The `ossify()` function -- the most permanent and irreversible action in the protocol -- can currently be executed through the ROUTINE (48-hour) path instead of the CRITICAL (7-day) path. This is a straightforward fix (change one hex constant) but must be applied before mainnet deployment.

The contract is **NOT ready for mainnet deployment** until H-01 is fixed.

**Overall Risk Rating:** Medium (due to H-01; would be Low after fix)

**Pre-Mainnet Readiness:** Blocked on H-01 fix.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/OmniTimelockController.sol` | 347 | Primary audit target |
| `@openzeppelin/contracts/governance/TimelockController.sol` | 471 | Base class behavior verification |
| `Coin/contracts/OmniGovernance.sol` | ~1,090 | Integration verification (queue/execute flows, `_validateNoCriticalSelectors`) |
| `Coin/test/UUPSGovernance.test.js` | ~1,587 | Test coverage and selector verification |
| `Coin/audit-reports/round6/OmniTimelockController-audit-2026-03-10.md` | 413 | Prior findings tracking |

---

*Generated by Claude Opus 4.6 -- Deep Manual Audit (6-Pass Methodology)*
*Date: 2026-03-13*
