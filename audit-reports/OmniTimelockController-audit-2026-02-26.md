# Security Audit Report: OmniTimelockController

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniTimelockController.sol`
**Solidity Version:** 0.8.24
**OpenZeppelin Version:** 5.4.0 (TimelockController base)
**Lines of Code:** 283
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (inherits ETH receive() and ERC721/ERC1155 holding from TimelockController; all timelocked operations pass through this contract)

## Executive Summary

OmniTimelockController is the central governance gatekeeper for OmniBazaar. Every admin operation across the protocol flows through this contract's two-tier delay system: 48-hour delays for routine operations (parameter changes, fee adjustments) and 7-day delays for critical operations (contract upgrades, role management, pause/unpause). The contract extends OpenZeppelin's battle-tested `TimelockController` v5.4.0, overriding `schedule()` and `scheduleBatch()` to inject critical-delay enforcement based on function selector classification.

The contract is well-architected with correct selector verification, proper use of custom errors, and a clean separation between hardcoded critical selectors and the admin-extensible registry. The OpenZeppelin base class handles the heavy lifting (operation lifecycle, execution, cancellation, role management), and the custom layer is minimal and focused.

**No critical or high vulnerabilities were found.** The primary findings relate to missing critical selector classifications that could allow governance-sensitive operations to bypass the 7-day delay, and an access control pattern on selector management that could be tightened. The contract is suitable for production deployment after addressing the medium-severity findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Informational | 5 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 62 |
| Passed | 55 |
| Failed | 2 |
| Partial | 5 |
| **Compliance Score** | **88.7%** |

**Top Failed/Partial Checks:**
1. SOL-CR-4 (Partial): `updateDelay()` not classified as critical selector (M-01)
2. SOL-AccessControl-3 (Partial): `addCriticalSelector`/`removeCriticalSelector` use `onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE)` which could be open if EXECUTOR_ROLE is granted to address(0) (M-03)
3. SOL-Basics-IV-1 (Partial): No event emitted when critical delay is enforced vs routine delay
4. SOL-Events-1 (Partial): Missing explicit event for delay tier applied to scheduled operation
5. SOL-Testing-1 (Partial): Missing test coverage for `removeCriticalSelector` and edge cases

---

## Medium Findings

### [M-01] `updateDelay()` Not Classified as Critical Selector

**Severity:** Medium
**Lines:** 33-36 (ROUTINE_DELAY/CRITICAL_DELAY constants), 96-104 (constructor critical selector registration)
**Category:** Business Logic / Access Control

**Description:**

The inherited `TimelockController.updateDelay()` (selector `0x64d62353`) allows changing the base minimum delay for all future operations. This function is callable only by the timelock itself (`msg.sender == address(this)`), but it is not registered as a critical selector.

If a proposer schedules a call to `updateDelay(0)` targeting the timelock's own address, it only needs to wait the 48-hour ROUTINE_DELAY. After execution, the base minimum delay drops to zero, allowing all subsequent routine operations to be scheduled with zero delay. While critical operations still require `CRITICAL_DELAY` (enforced by the `schedule()` override), the entire 48-hour floor for routine operations is removed.

**Attack Scenario:**
```
1. Malicious proposer schedules: timelock.updateDelay(0) with 48h delay
2. After 48h, anyone executes the operation
3. Base minimum delay is now 0 seconds
4. Proposer can now schedule and immediately execute any routine operation
   (parameter changes, fee adjustments, service registry updates)
5. No observation window for users to react to routine changes
```

This is especially dangerous because fee adjustments, scoring weight changes, and service registry updates are classified as routine. With a zero-second delay, these changes become instant and unobservable.

**Real-World Precedent:**
- Compound Governance delayed parameter changes are a standard pattern specifically to prevent this class of attack
- L2BEAT Stage 1 criteria explicitly require >24h security council timelock

**Recommendation:**

Register `updateDelay` as a critical selector in the constructor so that changing the minimum delay requires the full 7-day observation period:

```solidity
bytes4 public constant SEL_UPDATE_DELAY = 0x64d62353;

// In constructor:
_criticalSelectors[SEL_UPDATE_DELAY] = true;
criticalSelectorCount = 8; // was 7
```

Additionally, consider overriding `updateDelay()` to enforce a minimum floor:

```solidity
function updateDelay(uint256 newDelay) external override {
    if (msg.sender != address(this)) {
        revert TimelockUnauthorizedCaller(msg.sender);
    }
    if (newDelay < 1 hours) {
        revert DelayBelowCriticalMinimum(newDelay, 1 hours);
    }
    emit MinDelayChange(getMinDelay(), newDelay);
    // Cannot directly set _minDelay (private), so call super
    // This requires restructuring to work; alternatively, add
    // the floor check in a wrapper.
}
```

---

### [M-02] `addCriticalSelector` and `removeCriticalSelector` Not Self-Classified as Critical

**Severity:** Medium
**Lines:** 118-126 (addCriticalSelector), 135-143 (removeCriticalSelector)
**Category:** Business Logic / Meta-Governance

**Description:**

The functions `addCriticalSelector()` (selector `0xb634ebcf`) and `removeCriticalSelector()` (selector `0x199e6fef`) are not themselves registered as critical selectors. This means a proposer can schedule a call to `removeCriticalSelector(SEL_UPGRADE_TO)` with only a 48-hour delay. Once executed, the `upgradeTo()` selector is no longer classified as critical, and a subsequent upgrade can be scheduled with only 48 hours of delay instead of 7 days.

**Attack Scenario:**
```
1. Proposer schedules: timelock.removeCriticalSelector(0x3659cfe6)
   with 48-hour delay (routine)
2. After 48h, execute: upgradeTo is no longer critical
3. Proposer schedules: omniCore.upgradeTo(maliciousImpl)
   with 48-hour delay (now routine since selector removed)
4. After 48h, execute: protocol upgraded to malicious implementation
Total time: 96 hours instead of the intended 7 days + 48 hours
```

This is a two-step delay reduction attack. While 96 hours is still significant, it circumvents the design intent of requiring 7 days for critical operations. Emergency guardians only have 96 hours to detect and cancel instead of the intended 7+ days.

**Recommendation:**

Register both selector management functions as critical selectors:

```solidity
bytes4 public constant SEL_ADD_CRITICAL = 0xb634ebcf;
bytes4 public constant SEL_REMOVE_CRITICAL = 0x199e6fef;

// In constructor:
_criticalSelectors[SEL_ADD_CRITICAL] = true;
_criticalSelectors[SEL_REMOVE_CRITICAL] = true;
criticalSelectorCount = 9; // was 7
```

This ensures any changes to the critical selector registry itself require the full 7-day delay.

---

### [M-03] Access Control on Selector Management Uses `onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE)`

**Severity:** Medium
**Lines:** 120, 137
**Category:** Access Control

**Description:**

The `addCriticalSelector()` and `removeCriticalSelector()` functions use the modifier `onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE)`. Per the OpenZeppelin `TimelockController` constructor (line 118 of the base), `DEFAULT_ADMIN_ROLE` is granted to `address(this)` (the timelock itself). This is correct for the self-administration pattern.

However, the `onlyRoleOrOpenRole` modifier (TimelockController line 146-151) also checks `hasRole(role, address(0))`. The `EXECUTOR_ROLE` is intentionally granted to `address(0)` to make execution open, but `DEFAULT_ADMIN_ROLE` should never be granted to `address(0)`. If it were (through a misconfigured governance proposal), `addCriticalSelector` and `removeCriticalSelector` would become callable by anyone.

While `DEFAULT_ADMIN_ROLE` being granted to `address(0)` would be a catastrophic misconfiguration across the entire AccessControl system (not unique to this contract), the selector management functions would be among the most dangerous capabilities opened up, as they control the critical delay classification.

The intended access pattern is that these functions are only callable via the timelock itself (self-administration). A more precise modifier would be:

```solidity
modifier onlySelf() {
    if (msg.sender != address(this)) {
        revert TimelockUnauthorizedCaller(msg.sender);
    }
    _;
}
```

This matches the pattern used by `updateDelay()` in the base contract.

**Recommendation:**

Replace `onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE)` with a direct self-call check:

```solidity
function addCriticalSelector(bytes4 selector) external {
    if (msg.sender != address(this)) {
        revert TimelockUnauthorizedCaller(msg.sender);
    }
    // ...
}
```

This eliminates the (however unlikely) `address(0)` grant vector and makes the intent explicit: these functions are only callable through the timelock's own execution pipeline.

---

## Low Findings

### [L-01] Hardcoded Critical Selectors Can Be Removed

**Severity:** Low
**Lines:** 135-143 (removeCriticalSelector)
**Category:** Configuration Safety

**Description:**

The NatSpec at line 131-132 notes *"Hardcoded selectors (upgrade, role management, pause) can be removed but this is strongly discouraged."* While the warning exists, the contract does not enforce it. A governance proposal can call `removeCriticalSelector(SEL_UPGRADE_TO)` and permanently downgrade UUPS upgrades from critical to routine classification.

This is classified as Low rather than Medium because: (1) it requires a governance proposal to pass, (2) the NatSpec warning exists, and (3) the 48-hour routine delay is still a meaningful observation window (assuming M-02 is fixed so removal itself requires 7 days).

**Recommendation:**

Consider adding an immutable minimum set that cannot be removed:

```solidity
mapping(bytes4 => bool) private _immutableCriticalSelectors;

constructor(...) {
    _immutableCriticalSelectors[SEL_UPGRADE_TO] = true;
    _immutableCriticalSelectors[SEL_UPGRADE_TO_AND_CALL] = true;
    _immutableCriticalSelectors[SEL_GRANT_ROLE] = true;
    _immutableCriticalSelectors[SEL_REVOKE_ROLE] = true;
    // ...
}

function removeCriticalSelector(bytes4 selector) external ... {
    if (_immutableCriticalSelectors[selector]) {
        revert CannotRemoveImmutableSelector(selector);
    }
    // ...
}
```

Alternatively, document this as an intentional design decision if the governance community should have full authority over selector classification.

---

### [L-02] No Maximum Delay Enforcement

**Severity:** Low
**Lines:** 203-215 (schedule), 228-242 (scheduleBatch)
**Category:** Denial of Service

**Description:**

A proposer can schedule operations with arbitrarily large delays (e.g., `type(uint256).max` seconds). While this does not allow stealing funds, it could be used to grief the system: schedule a critical operation with a 1000-year delay, permanently locking the operation slot (since the same operation hash cannot be scheduled twice while pending). The operation must be cancelled before it can be re-scheduled with a reasonable delay.

The EmergencyGuardian's cancel capability (3-of-5 threshold) mitigates this, but it still wastes guardian attention and gas.

**Recommendation:**

Consider adding a maximum delay sanity check:

```solidity
uint256 public constant MAX_DELAY = 30 days;

function schedule(...) public override onlyRole(PROPOSER_ROLE) {
    if (delay > MAX_DELAY) revert DelayExceedsMaximum(delay, MAX_DELAY);
    // ...
}
```

---

### [L-03] `criticalSelectorCount` Can Desynchronize If Same Selector Added Twice Via Different Code Paths

**Severity:** Low
**Lines:** 121-126 (addCriticalSelector), 138-143 (removeCriticalSelector)
**Category:** State Consistency

**Description:**

The `addCriticalSelector` function correctly checks `if (!_criticalSelectors[selector])` before incrementing the count, and `removeCriticalSelector` checks `if (_criticalSelectors[selector])` before decrementing. This prevents double-counting.

However, the `criticalSelectorCount` is a public state variable with no corresponding enumeration function. Users cannot query which selectors are registered, only how many exist. If a frontend or monitoring system needs to verify the complete set of critical selectors, it must replay all `CriticalSelectorUpdated` events from genesis. This is not a vulnerability but a usability gap that could lead to monitoring blind spots.

**Recommendation:**

Consider adding an array-based enumeration or a public getter that accepts an array of selectors and returns their critical status:

```solidity
function areCriticalSelectors(
    bytes4[] calldata selectors
) external view returns (bool[] memory results) {
    results = new bool[](selectors.length);
    for (uint256 i = 0; i < selectors.length; ++i) {
        results[i] = _criticalSelectors[selectors[i]];
    }
}
```

---

### [L-04] Empty Calldata (ETH Transfers) Always Classified as Routine

**Severity:** Low
**Lines:** 258-262 (_isCriticalCall)
**Category:** Design Decision

**Description:**

`_isCriticalCall()` returns `false` for `data.length < 4`, meaning plain ETH transfers from the timelock are always treated as routine operations (48-hour delay). While this is documented behavior and a reasonable default, large ETH transfers from the timelock could be sensitive operations that stakeholders would want more time to review.

The contract holds ETH via the inherited `receive()` function for operational purposes. A governance proposal could schedule a large ETH withdrawal to an arbitrary address with only 48 hours of notice.

**Recommendation:**

Document this as an intentional design decision. If ETH withdrawals above a threshold should require critical delay, this would need custom logic in the schedule override that also checks the `value` parameter, not just the calldata.

---

## Informational Findings

### [I-01] Function Selectors Verified Correct

**Severity:** Informational
**Lines:** 39-58 (selector constants)

**Description:**

All 7 hardcoded function selector constants were independently verified against Solidity's `keccak256` computation:

| Selector | Function | Verified |
|----------|----------|----------|
| `0x3659cfe6` | `upgradeTo(address)` | Correct |
| `0x4f1ef286` | `upgradeToAndCall(address,bytes)` | Correct |
| `0x2f2ff15d` | `grantRole(bytes32,address)` | Correct |
| `0xd547741f` | `revokeRole(bytes32,address)` | Correct |
| `0x36568abe` | `renounceRole(bytes32,address)` | Correct |
| `0x8456cb59` | `pause()` | Correct |
| `0x3f4ba83a` | `unpause()` | Correct |

No selector collision or typo risk.

---

### [I-02] OpenZeppelin TimelockController v5.4.0 Base Is Well-Audited

**Severity:** Informational

**Description:**

The base `TimelockController` from OpenZeppelin v5.4.0 has been audited multiple times by professional firms and has extensive production track record. The inherited functionality (operation lifecycle, execution flow, reentrancy protection via `_beforeCall`/`_afterCall`, ERC721/ERC1155 holding) is considered battle-tested.

Key inherited security properties:
- Reentrancy during execution is safe due to `_afterCall` checking operation is still Ready
- `_schedule` is private, preventing override-based attacks on delay enforcement
- `cancel()` requires CANCELLER_ROLE (held by EmergencyGuardian)
- `execute()`/`executeBatch()` use `onlyRoleOrOpenRole(EXECUTOR_ROLE)` with address(0) grant for open execution

The custom `schedule()`/`scheduleBatch()` overrides correctly call `super.schedule()`/`super.scheduleBatch()` after delay validation, preserving all base class invariants.

---

### [I-03] Contract Is Non-Upgradeable by Design

**Severity:** Informational

**Description:**

OmniTimelockController is deployed as a plain (non-UUPS, non-proxy) contract. This is the correct design choice for a timelock controller, as the timelock itself should not be upgradeable by the entities it governs. Changes to timelock parameters (minimum delay) go through the timelock's own `updateDelay()` mechanism, which requires scheduling and executing a self-targeted operation.

If the timelock logic needs to change, a migration to a new timelock contract is required, involving re-granting roles on all governed contracts. This is intentional friction.

---

### [I-04] Test Coverage Is Adequate but Has Gaps

**Severity:** Informational

**Description:**

The existing test suite (`test/UUPSGovernance.test.js`) has 13 passing tests for OmniTimelockController covering:
- Delay constants verification
- Critical selector classification for all 7 initial selectors
- `getRequiredDelay()` for routine and critical calldata
- Single operation scheduling (routine and critical)
- Batch operation scheduling with mixed criticality
- Execution after delay

**Missing test coverage:**
1. `addCriticalSelector()` and `removeCriticalSelector()` (never tested)
2. `getBatchRequiredDelay()` return values
3. Scheduling with delay greater than critical minimum (e.g., 14 days)
4. Scheduling with empty calldata (ETH transfer)
5. Interaction with `updateDelay()` on the base
6. Executing critical operations after CRITICAL_DELAY

**Recommendation:** Add tests for the missing scenarios, particularly for selector management functions and the `updateDelay` interaction.

---

### [I-05] NatSpec Documentation Is Thorough and Accurate

**Severity:** Informational

**Description:**

The contract has comprehensive NatSpec documentation on all public and internal functions, events, errors, and state variables. The contract-level documentation accurately describes the two-tier delay system, role architecture, and design philosophy. The inline comments correctly explain design decisions (e.g., why empty calldata returns false for critical classification).

The documentation correctly notes that hardcoded selectors can be removed (line 131-132) and that changes go through the timelock itself (line 28). This transparency is good practice for a governance-critical contract.

No misleading or inaccurate documentation was found.

---

## Architecture Assessment

### Role Architecture (Correct)

```
PROPOSER_ROLE    --> OmniGovernance (+ deployer in Phase 1)
EXECUTOR_ROLE    --> address(0) (anyone can execute after delay)
CANCELLER_ROLE   --> EmergencyGuardian (3-of-5 guardian cancel)
DEFAULT_ADMIN    --> address(this) (self-administered)
                     + admin param in constructor (should renounce)
```

This follows the standard OpenZeppelin recommended pattern. The deployment script (`scripts/deploy-governance-system.ts`) correctly renounces the deployer's `DEFAULT_ADMIN_ROLE` in Phase 5d.

### Two-Tier Delay Flow (Correct)

```
schedule(target, value, data, predecessor, salt, delay)
  |
  v
_isCriticalCall(data)
  |                |
  | true           | false
  v                v
delay >= 7 days?   delay >= 48h? (base _schedule check)
  |                |
  | yes            | yes
  v                v
super.schedule()   super.schedule()
  |                |
  v                v
Wait delay         Wait delay
  |                |
  v                v
execute()          execute()
```

### Integration Points (Verified)

1. **OmniGovernance** (line 469-479 of OmniGovernance.sol): Calls `timelock.scheduleBatch()` via low-level call in `queue()`. Correctly passes the appropriate delay (7 days for CRITICAL, 48 hours for ROUTINE proposals).

2. **EmergencyGuardian** (line 297-317 of EmergencyGuardian.sol): Calls `timelock.cancel()` via low-level call when 3-of-5 guardian threshold is reached. Correctly holds CANCELLER_ROLE.

3. **Deployment Script** (lines 240-258 of deploy-governance-system.ts): Correctly deploys with deployer as initial proposer, address(0) as executor, and admin address. Correctly wires roles and renounces admin.

### Gas Analysis

The contract adds minimal gas overhead to the base TimelockController:
- `schedule()`: One additional SLOAD for `_isCriticalCall` (selector lookup in mapping) = ~2,100 gas
- `scheduleBatch()`: N additional SLOADs for N payloads in the batch = ~2,100 * N gas
- `addCriticalSelector()`: One SSTORE + emit = ~20,000 gas
- All view functions: Pure computation on calldata + one SLOAD = negligible

The contract is well within acceptable gas bounds for a governance operation.

---

## Summary of Recommendations

### Must-Fix (Before Production)

1. **[M-01]** Register `updateDelay()` selector (`0x64d62353`) as a critical selector to prevent 48-hour minimum delay reduction.

2. **[M-02]** Register `addCriticalSelector()` and `removeCriticalSelector()` selectors as critical to prevent 48-hour delay on security-classification changes.

### Should-Fix (Before Production)

3. **[M-03]** Replace `onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE)` with a direct `msg.sender == address(this)` check on `addCriticalSelector`/`removeCriticalSelector` to match the `updateDelay()` pattern.

### Consider (Non-Blocking)

4. **[L-01]** Evaluate whether hardcoded critical selectors should be immutable (non-removable).
5. **[L-02]** Add a maximum delay sanity check to prevent griefing.
6. **[L-03]** Add batch query function for critical selector status.
7. **[I-04]** Expand test coverage for selector management and `updateDelay` interaction.

---

## Conclusion

OmniTimelockController is a well-designed contract that correctly implements two-tier delay enforcement on top of a battle-tested OpenZeppelin foundation. The custom code surface is minimal (approximately 180 lines beyond imports and comments), reducing the attack surface. All function selectors are verified correct. The integration with OmniGovernance and EmergencyGuardian follows established patterns.

The three medium findings relate to missing critical selector classifications that could allow governance-sensitive operations (delay changes, selector management) to bypass the 7-day delay. These are straightforward fixes that require adding 3 additional selectors to the constructor's critical registry and tightening the access control modifier. No fundamental design changes are needed.

After addressing M-01 through M-03, the contract is suitable for production deployment on OmniCoin mainnet.
