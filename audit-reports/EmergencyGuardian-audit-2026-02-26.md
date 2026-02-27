# Security Audit Report: EmergencyGuardian

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/EmergencyGuardian.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 318
**Upgradeable:** No (immutable deployment)
**Handles Funds:** No (pause and cancel authority only)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IPausable` (custom interface), `TimelockController` (OZ v5.4.0 via low-level call)
**Test Coverage:** `Coin/test/UUPSGovernance.test.js` (Section 3, ~25 test cases)

---

## Executive Summary

EmergencyGuardian is a high-priority governance contract that provides two strictly-scoped emergency powers: (1) any single guardian can immediately pause registered contracts (1-of-N threshold), and (2) three of the active guardians can cancel a queued timelock operation (3-of-5 threshold, auto-executing on the third signature). Guardian membership is managed exclusively by the timelock (governance), and the contract deliberately cannot unpause, queue proposals, upgrade contracts, or modify its own parameters.

The contract is well-designed with a minimal attack surface. The audit identified **0 Critical**, **1 High**, **3 Medium**, **3 Low**, and **3 Informational** findings. The most significant issue is that removed guardians retain their existing cancel signatures, which can be counted toward the 3-of-5 threshold even after they are no longer authorized participants. Additional findings cover the lack of a cancel-signature revocation mechanism, absence of an operation-state pre-check before collecting signatures, and potential for permanent state pollution from signing cancel requests against non-existent operation IDs.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |
| Informational | 3 |

---

## Architecture Analysis

### Design Strengths

1. **Minimal Authority Principle:** The contract deliberately limits itself to pause and cancel. It cannot unpause, queue, execute, upgrade, or change its own parameters. This is excellent security design.

2. **Immutable Timelock Reference:** `TIMELOCK` is declared `immutable`, preventing any post-deployment modification of the target timelock address.

3. **Minimum Guardian Floor:** The `MIN_GUARDIANS = 5` constant with enforcement in both `constructor` and `removeGuardian` prevents the guardian set from being reduced to an insecure size.

4. **Auto-Execute Pattern:** The cancel mechanism auto-fires on the 3rd signature rather than requiring a separate `executeCancel` call. This eliminates the window between reaching threshold and execution where the operation could be front-run.

5. **Custom Errors:** Gas-efficient error handling throughout.

6. **Clean NatSpec:** Complete documentation on all public functions, events, errors, and state variables.

### Dependency Analysis

- **IPausable Interface:** Minimal -- contains only `function pause() external`. The EmergencyGuardian calls `IPausable(target).pause()` which requires that the target contract has granted the EmergencyGuardian the appropriate role (e.g., `ADMIN_ROLE`, `PAUSER_ROLE`). This is documented in the NatSpec and verified in tests.

- **OZ TimelockController.cancel(bytes32):** Called via low-level `TIMELOCK.call(abi.encodeWithSignature("cancel(bytes32)", operationId))`. The OZ v5.4.0 `cancel` function requires `CANCELLER_ROLE`, which the deployment script grants to the EmergencyGuardian address. The function selector for `cancel(bytes32)` is `0xc4d252f5`.

---

## Findings

### [H-01] Removed Guardians Retain Cancel Signatures -- Ghost Votes Toward Threshold

**Severity:** High
**Lines:** 246-256 (removeGuardian), 205-220 (signCancel)
**Category:** Access Control / State Integrity

**Description:**

When a guardian is removed via `removeGuardian()`, their `isGuardian[guardian]` flag is set to `false` and `guardianCount` is decremented. However, any cancel signatures they previously submitted remain in the `cancelSignatures` and `cancelSignatureCount` mappings. These signatures continue to count toward the `CANCEL_THRESHOLD` of 3.

Consider the following scenario:

```
1. Guardian A signs cancel for operationId X (count = 1)
2. Guardian A is removed via timelock governance
3. Guardian B signs cancel for operationId X (count = 2)
4. Guardian C signs cancel for operationId X (count = 3 -- threshold met!)
   => Operation X is cancelled with only 2 active guardians approving
```

The removed guardian's vote was cast when they were authorized, but the contract's NatSpec and design intent says "3-of-5" -- meaning 3 of the current active guardians should be required. After removal, the effective threshold drops to 2-of-N for any operation that the removed guardian had already signed.

In a worst case, if 2 guardians are removed (count goes from 7 to 5, staying above minimum), and both had signed a cancel, then only 1 active guardian's signature is needed to reach the threshold.

**Impact:** Violation of the stated 3-of-5 security model. A cancelled operation cannot be re-scheduled with the same parameters (same salt), so an attacker who controls a removed guardian's historical signatures can effectively reduce the cancel threshold.

**Recommendation:** Invalidate cancel signatures when a guardian is removed:

```solidity
function removeGuardian(address guardian) external onlyTimelock {
    if (!isGuardian[guardian]) revert NotActiveGuardian();
    if (guardianCount - 1 < MIN_GUARDIANS) {
        revert BelowMinGuardians();
    }

    isGuardian[guardian] = false;
    --guardianCount;

    emit GuardianRemoved(guardian);

    // NOTE: Existing cancelSignatures from this guardian remain in storage
    // but cannot be individually invalidated without tracking all operation IDs.
    // Consider adding a "guardian epoch" that invalidates all prior signatures.
}
```

A more robust fix uses an epoch-based invalidation:

```solidity
uint256 public guardianEpoch;

// In removeGuardian and addGuardian:
++guardianEpoch;

// Change cancelSignatures key to include epoch:
// cancelId = keccak256(abi.encodePacked(operationId, guardianEpoch))
```

This way, any guardian set change invalidates all in-progress cancel signature collections, requiring the current guardian set to re-sign from scratch.

---

### [M-01] No Cancel Signature Revocation Mechanism

**Severity:** Medium
**Lines:** 205-220 (signCancel)

**Description:**

Once a guardian calls `signCancel(operationId)`, there is no way to retract the signature. If a guardian signs by mistake, or if new information emerges that the operation is legitimate, the signature cannot be withdrawn. Since the cancel auto-executes at 3 signatures, a mistaken signature permanently reduces the remaining threshold from 3 to 2 for that operation.

In combination with H-01, a removed guardian who signed before removal has a permanent, irrevocable contribution toward cancellation.

**Impact:** Guardians cannot correct mistakes. In a 5-guardian system, once 2 sign (whether by mistake, social engineering, or legitimate concern), only 1 more signature is needed to cancel a potentially important governance operation.

**Recommendation:** Add a `revokeCancel(bytes32 operationId)` function:

```solidity
function revokeCancel(bytes32 operationId) external onlyGuardian {
    if (!cancelSignatures[operationId][msg.sender]) {
        revert NotSigned();
    }
    cancelSignatures[operationId][msg.sender] = false;
    --cancelSignatureCount[operationId];
    emit CancelRevoked(operationId, msg.sender, cancelSignatureCount[operationId]);
}
```

---

### [M-02] No Operation State Pre-Check -- Signatures Collected for Non-Existent or Already-Executed Operations

**Severity:** Medium
**Lines:** 205-220 (signCancel)

**Description:**

`signCancel()` does not verify that `operationId` corresponds to an actual pending operation in the timelock. Guardians can sign cancel requests for:

1. Operation IDs that do not exist (never scheduled)
2. Operation IDs that have already been executed
3. Operation IDs that have already been cancelled

For cases 1 and 2, when the 3rd signature arrives and `_executeCancel` fires, the low-level call to `timelock.cancel(operationId)` will revert with `TimelockUnexpectedOperationState`, which is properly bubbled up. However, gas is wasted on 3 transactions that were doomed to fail.

For case 3 (already cancelled), the same revert occurs but the scenario is benign -- guardians signing a cancel for an already-cancelled operation.

The more subtle concern is state pollution: the `cancelSignatureCount` mapping permanently stores data for invalid operation IDs, and there is no cleanup mechanism.

**Impact:** Low direct impact (the cancel call reverts correctly), but gas waste for guardians and permanent storage pollution. In extreme cases, a griefing guardian could call `signCancel` with many fabricated operation IDs to bloat contract state, though the gas cost makes this impractical.

**Recommendation:** Add a pre-check that queries the timelock for operation state:

```solidity
function signCancel(bytes32 operationId) external onlyGuardian {
    // Verify the operation is actually pending in the timelock
    (bool isPending,) = TIMELOCK.staticcall(
        abi.encodeWithSignature("isOperationPending(bytes32)", operationId)
    );
    if (!isPending) revert OperationNotPending();
    // ... rest of function
}
```

Note: This adds ~2,600 gas for the static call but prevents wasted signatures.

---

### [M-03] Cancel Threshold is Absolute (3), Not Relative to Guardian Count

**Severity:** Medium
**Lines:** 37 (CANCEL_THRESHOLD = 3), 217 (threshold check)

**Description:**

`CANCEL_THRESHOLD` is a constant `3`, regardless of the total number of guardians. If the guardian set grows to 20 members (the NatSpec says "minimum 8 members" for L2BEAT Stage 1 compliance, and there is no upper bound), the cancel threshold remains 3-of-20, which is only 15% of the guardian set.

The threshold was designed as "3-of-5" (60%), but with 8 guardians (the minimum per the NatSpec's own stated requirement), it becomes "3-of-8" (37.5%). With 15 guardians it becomes 3-of-15 (20%).

The contract's NatSpec header claims "3-of-5 cancel emergency powers" but this is only accurate when `guardianCount == 5`.

**Impact:** As the guardian set grows, the relative security of the cancel mechanism weakens. A smaller fraction of guardians can cancel governance operations, which may not align with the intended security model.

**Recommendation:** Either:

(a) Add a maximum guardian count (`MAX_GUARDIANS = 7` or similar) so the 3-of-N ratio stays above 40%, or

(b) Make the threshold dynamic: `cancelThreshold = (guardianCount * 60) / 100` with a floor of 3, or

(c) Document the fixed 3-of-N design as intentional and update the NatSpec to say "3-of-N" rather than "3-of-5".

Option (c) is the lowest-risk change. Options (a) and (b) change the security model and require careful consideration.

---

### [L-01] Low-Level Call for Cancel Instead of Interface Call

**Severity:** Low
**Lines:** 297-317 (_executeCancel)

**Description:**

`_executeCancel` uses a low-level `TIMELOCK.call(abi.encodeWithSignature("cancel(bytes32)", operationId))` instead of importing the `TimelockController` interface and calling it directly. The `abi.encodeWithSignature` approach uses string-based selector computation at runtime, which:

1. Has no compile-time type checking -- a typo in the function signature string (e.g., `"cancel(bytes 32)"`) would silently compute a wrong selector.
2. Is marginally more gas-expensive than `abi.encodeWithSelector` or a direct interface call.
3. Makes the code harder to maintain if the `cancel` function signature changes in a future OZ version.

The current string `"cancel(bytes32)"` is correct and matches the OZ v5.4.0 `TimelockController.cancel(bytes32 id)` function. However, the pattern is fragile.

**Impact:** No current exploit, but increases maintenance risk and eliminates compile-time safety.

**Recommendation:** Import the TimelockController interface and use a typed call:

```solidity
import {TimelockController} from
    "@openzeppelin/contracts/governance/TimelockController.sol";

// In _executeCancel:
TimelockController(TIMELOCK).cancel(operationId);
```

If the design intent is to avoid importing the full TimelockController (to keep deployment size minimal), at minimum use `abi.encodeWithSelector`:

```solidity
(bool success, bytes memory returndata) = TIMELOCK.call(
    abi.encodeWithSelector(bytes4(0xc4d252f5), operationId)
);
```

Or define a minimal interface:

```solidity
interface ITimelockCancel {
    function cancel(bytes32 id) external;
}
```

---

### [L-02] Constructor Does Not Enforce MIN_GUARDIANS as a True Lower Bound on Unique Count

**Severity:** Low
**Lines:** 159-175 (constructor)

**Description:**

The constructor validates `initialGuardians.length < MIN_GUARDIANS` and checks for duplicates and zero addresses within the loop. This is correct -- if all checks pass, exactly `initialGuardians.length` unique, non-zero guardians are registered.

However, the duplicate check (`if (isGuardian[guardian]) revert AlreadyGuardian()`) and zero-address check are inside the same loop. If a zero address appears at index 3 (after 3 valid guardians have been set), the revert happens after 3 guardians have already been written to storage. This is fine because the entire transaction reverts, rolling back all state. But it means the constructor is not atomic in a "check-then-act" sense within the same function -- it interleaves checks and effects.

This pattern is acceptable in constructors because a revert undoes everything, but it would be problematic in a non-constructor context.

**Impact:** None -- constructor reverts undo all state changes. This is informational about the pattern.

**Recommendation:** No code change needed. The pattern is safe in a constructor context. If the guardian initialization logic were ever extracted to a separate function, the interleaved check-effect pattern should be refactored.

---

### [L-03] No Event Emitted for Failed Cancel Attempts

**Severity:** Low
**Lines:** 297-317 (_executeCancel)

**Description:**

When `_executeCancel` is called (after the 3rd signature), if the low-level call to `timelock.cancel()` fails (e.g., operation was already executed or already cancelled), the function reverts. This means the 3rd guardian's transaction fails entirely -- their signature increment is also rolled back.

The issue is that there is no record of the failed cancel attempt. If the 3rd guardian's transaction reverts, the `cancelSignatureCount` stays at 2, and the `cancelSignatures[operationId][guardian3]` stays `false`. A subsequent retry by the same guardian would succeed, but they may not know why the first attempt failed.

**Impact:** User experience issue. A guardian whose cancel-trigger transaction reverts gets a generic error. No event is emitted to explain why.

**Recommendation:** This is inherent to the auto-execute design and difficult to fix without separating signature collection from execution. Consider adding NatSpec documentation warning guardians that the triggering transaction may revert if the timelock operation is no longer pending. Alternatively, add the pre-check from M-02 which would prevent this scenario.

---

### [I-01] `timestamp` Indexed in EmergencyPause Event is Redundant

**Severity:** Informational
**Lines:** 71-75 (EmergencyPause event)

**Description:**

The `EmergencyPause` event declares `uint256 indexed timestamp` as the third indexed parameter. However, `block.timestamp` is already available in every transaction receipt as part of the block header. Indexing the timestamp uses an additional topic slot (3 of 3 non-anonymous topics consumed) without providing additional query capability that block-level filtering does not already provide.

Additionally, making `timestamp` indexed prevents its value from appearing in the event's `data` field, meaning log consumers must decode it from topics. For timestamp values, this is a minor inconvenience.

**Impact:** Marginal gas increase on each `pauseContract` call (indexed parameters cost more) and one wasted topic slot that could be used for a more useful indexed field.

**Recommendation:** Either remove the `indexed` keyword from `timestamp`, or remove the `timestamp` parameter entirely and rely on `block.timestamp` from the transaction receipt:

```solidity
event EmergencyPause(
    address indexed target,
    address indexed guardian
);
```

---

### [I-02] `signatureCount` Indexed in CancelSigned and OperationCancelled Events

**Severity:** Informational
**Lines:** 81-93 (CancelSigned, OperationCancelled events)

**Description:**

Both `CancelSigned` and `OperationCancelled` use `uint256 indexed signatureCount` as an indexed parameter. Indexing a counter value is unusual because:

1. Filtering by "all events where signatureCount == 2" is rarely useful.
2. The value is small (1-N where N is the guardian count), making bloom filter collisions likely.
3. It prevents the value from appearing in the data field, making log decoding slightly more complex.

**Impact:** No functional impact. Marginal gas overhead.

**Recommendation:** Remove `indexed` from `signatureCount` in both events. Keep `operationId` and `guardian` as indexed (these are useful for filtering).

---

### [I-03] NatSpec Claims "3-of-5" but Contract Supports Arbitrary Guardian Counts

**Severity:** Informational
**Lines:** 12-13 (contract NatSpec), 37 (CANCEL_THRESHOLD)

**Description:**

The contract-level NatSpec states: *"2. Cancel (3-of-5 threshold): Requires 3 guardian signatures to cancel..."*

The NatSpec also states: *"Minimum 8 members"* for L2BEAT Stage 1 compliance.

These two statements are contradictory -- with 8+ guardians, the threshold is 3-of-8+, not 3-of-5. The contract code correctly implements a fixed threshold of 3 with a minimum of 5 guardians and no maximum, but the documentation does not accurately describe this.

**Impact:** Documentation inaccuracy. Developers, auditors, and governance participants may have incorrect expectations about the cancel threshold ratio.

**Recommendation:** Update the NatSpec to:

```solidity
/// * 2. **Cancel** (3-of-N threshold): Requires 3 guardian signatures to
/// *    cancel a queued timelock operation. The threshold is fixed at 3
/// *    regardless of guardian count (minimum 5 guardians required).
```

---

## Gas Optimization Notes

1. **Custom errors:** Already used throughout -- good.
2. **Immutable TIMELOCK:** Already immutable -- good.
3. **++i prefix increment:** Used in constructor loop and guardianCount -- good.
4. **No redundant storage reads:** `cancelSignatureCount` is incremented with `++` and the new value captured in a local variable -- good.
5. **No reentrancy guard:** Not needed. The only external call is `TIMELOCK.call(cancel)`, which goes to a trusted OpenZeppelin contract. The contract holds no ETH and has no payable functions or fallback/receive. State changes (signature recording) happen before the external call, following checks-effects-interactions. A reentrancy via a malicious `IPausable.pause()` implementation could re-enter `signCancel` or `pauseContract`, but both have guard conditions (`AlreadySigned` / `isPausable` check) that prevent exploitation.

---

## Test Coverage Analysis

The existing test suite in `Coin/test/UUPSGovernance.test.js` (Section 3: EmergencyGuardian) covers:

| Test Case | Covered |
|-----------|---------|
| Deploy with 5 guardians | Yes |
| Reject < 5 guardians | Yes |
| Reject zero-address timelock | Yes |
| Reject duplicate guardians | Yes |
| Immutable timelock reference | Yes |
| Constants (CANCEL_THRESHOLD, MIN_GUARDIANS) | Yes |
| Pause: reject unregistered contract | Yes |
| Pause: reject non-guardian caller | Yes |
| Pause: successfully pause registered contract | Yes |
| Cancel: collect signatures | Yes |
| Cancel: reject duplicate signatures | Yes |
| Cancel: reject non-guardian signatures | Yes |
| Cancel: auto-cancel at 3 signatures | Yes |
| Cancel: emit CancelSigned events | Yes |
| Guardian management: add via timelock | Yes |
| Guardian management: reject non-timelock caller | Yes |
| Guardian management: reject zero address | Yes |
| Guardian management: reject duplicate | Yes |
| Guardian management: remove when above minimum | Yes |
| Guardian management: reject removal below minimum | Yes |
| Pausable registration and deregistration | Yes |

**Missing Test Coverage:**

| Missing Test | Related Finding |
|--------------|-----------------|
| Removed guardian's prior cancel signatures still count | H-01 |
| Cancel with non-existent operation ID (revert behavior) | M-02 |
| Cancel with already-executed operation (revert behavior) | M-02 |
| Cancel with already-cancelled operation (revert behavior) | M-02 |
| Guardian count > 5, verify 3-of-N still works | M-03 |
| Multiple pausable contracts registered | -- |
| Pause already-paused contract (target behavior) | -- |
| Gas measurement for signCancel chain (1st, 2nd, 3rd) | -- |

---

## Comparison with Industry Standards

| Aspect | EmergencyGuardian | Optimism Security Council | Arbitrum Security Council |
|--------|-------------------|--------------------------|--------------------------|
| Pause threshold | 1-of-N | 1-of-N (similar) | 9-of-12 |
| Cancel threshold | Fixed 3 | N/A (different pattern) | 9-of-12 |
| Signature collection | On-chain sequential | Gnosis Safe multisig | Gnosis Safe multisig |
| Guardian management | Timelock-governed | Governance-governed | Governance-governed |
| Upgrade authority | None | None | None |
| Max guardians | Unlimited | Fixed 8 | Fixed 12 |

The 1-of-N pause threshold aligns with Optimism's Security Council pattern and is appropriate for emergency response. The 3-of-N cancel threshold is lower than typical multisig thresholds but is specifically scoped to cancel-only (cannot execute arbitrary actions).

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Recommendation |
|---|---------|----------|----------------|
| 1 | H-01 | High | Invalidate cancel signatures on guardian removal (epoch-based) |
| 2 | M-01 | Medium | Add `revokeCancel()` function |
| 3 | M-02 | Medium | Add operation-state pre-check in `signCancel()` |
| 4 | M-03 | Medium | Cap guardian count or make threshold dynamic or update NatSpec |
| 5 | L-01 | Low | Use typed interface call instead of `abi.encodeWithSignature` |
| 6 | L-02 | Low | Informational -- constructor pattern is safe |
| 7 | L-03 | Low | Add NatSpec warning about trigger-transaction reverts |
| 8 | I-01 | Info | Remove `indexed` from `timestamp` or remove parameter |
| 9 | I-02 | Info | Remove `indexed` from `signatureCount` fields |
| 10 | I-03 | Info | Fix NatSpec "3-of-5" to "3-of-N" |

---

## Conclusion

EmergencyGuardian is a well-constrained governance safety contract with a deliberately minimal attack surface. The principal concern (H-01) is that guardian removal does not invalidate prior cancel signatures, allowing removed guardians to retain effective influence over the cancel mechanism. This should be addressed before mainnet deployment given the contract's role as a critical governance safeguard.

The contract's design philosophy of minimal authority (no unpause, no upgrade, no queue) is exemplary. The immutable timelock reference, minimum guardian floor, and auto-execute pattern are sound. The remaining Medium findings are defense-in-depth improvements that would strengthen the contract's resilience to operational edge cases.

**Overall Risk Assessment:** Low-Medium (after H-01 remediation: Low)

---

*Report generated 2026-02-26 19:27 UTC*
*Methodology: Static analysis (solhint zero findings) + semantic LLM audit (OWASP SC Top 10 + Business Logic)*
*Contract hash: Review against EmergencyGuardian.sol at 318 lines, Solidity 0.8.24*
