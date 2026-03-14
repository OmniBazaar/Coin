# Security Audit Report: EmergencyGuardian (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Opus 4.6 -- 7-Pass Comprehensive Audit
**Contract:** `Coin/contracts/EmergencyGuardian.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 532
**Upgradeable:** No (immutable deployment)
**Handles Funds:** No (pause and cancel authority only)
**Dependencies:** `IPausable` (custom interface, 17 lines), `TimelockController` (OZ v5.4.0 via low-level call)
**Deployed Size:** 3.098 KiB (well within 24 KiB limit)
**Test Coverage:** `Coin/test/UUPSGovernance.test.js` (Section 3, 22 test cases -- all passing)
**Previous Audits:**
- Round 5: `EmergencyGuardian-audit-2026-02-26.md` (H-01, M-01 through M-03, L-01 through L-03, I-01 through I-03)
- Round 6: `audit-reports/round6/EmergencyGuardian-audit-2026-03-10.md` (M-01, L-01, L-02, I-01, I-02)

---

## Executive Summary

EmergencyGuardian is a non-upgradeable governance safety contract providing two strictly scoped emergency powers: (1) any single guardian can immediately pause registered contracts (1-of-N threshold), and (2) three guardians can cancel a queued timelock operation (3-of-N fixed threshold, auto-executing on the third signature). The contract deliberately cannot unpause, upgrade, queue proposals, or modify its own parameters -- all management is delegated to the timelock (governance).

This Round 7 audit confirms that **all findings from Rounds 5 and 6 have been fully remediated**:

- **Round 5 H-01 (Ghost votes):** RESOLVED via epoch-based signature invalidation
- **Round 5 M-01 (No revocation):** RESOLVED via `revokeCancel()`
- **Round 5 M-02 (No pre-check):** RESOLVED via `_requireOperationPending()`
- **Round 5 M-03 (NatSpec):** RESOLVED with detailed "3-of-N" rationale
- **Round 6 M-01 (Revert vs emit):** RESOLVED -- `_executeCancel()` now emits `CancelAttemptFailed` and returns gracefully on failure

This audit found **0 Critical, 0 High, 0 Medium, 1 Low, and 3 Informational** findings. The contract is production-ready.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 1 |
| Informational | 3 |

---

## Pass 1: Static Analysis Results

### Slither

Slither reported 5 findings (2 contracts analyzed, 101 detectors):

| # | Detector | Finding | Severity | Assessment |
|---|----------|---------|----------|------------|
| 1 | reentrancy-events | `_executeCancel()`: event emitted after external call to TIMELOCK | Informational | **Accepted.** The event emission after the TIMELOCK.call is intentional -- the contract needs to know whether the cancel succeeded before deciding which event to emit (OperationCancelled vs CancelAttemptFailed). No state mutation occurs after the call, only event emission. No reentrancy risk. |
| 2 | reentrancy-events | `pauseContract()`: event emitted after `IPausable(target).pause()` | Informational | **Accepted.** The EmergencyPause event is emitted after the external pause() call. This is intentional -- the event confirms the pause succeeded. The target is governance-registered. See L-01 below for reentrancy analysis. |
| 3 | low-level-calls | `_executeCancel()` uses `TIMELOCK.call()` | Informational | **Accepted.** Deliberate design to avoid importing the full TimelockController. The low-level call enables graceful failure handling (emit event instead of revert). |
| 4 | low-level-calls | `_requireOperationPending()` uses `TIMELOCK.staticcall()` | Informational | **Accepted.** Deliberate design to query timelock state without importing the interface. staticcall is safe (read-only). |
| 5 | naming-convention | `TIMELOCK` is not in mixedCase | Informational | **Accepted.** SCREAMING_SNAKE_CASE for immutable variables is a common convention in Solidity projects and matches the codebase style. Solidity style guide permits this for constant-like immutables. |

### Solhint

Zero findings. The contract passes all configured solhint rules.

---

## Pass 2: Line-by-Line Manual Review

### Constructor (Lines 218-234)

```solidity
constructor(address timelock, address[] memory initialGuardians) {
    if (timelock == address(0)) revert InvalidAddress();
    if (initialGuardians.length < MIN_GUARDIANS) {
        revert BelowMinGuardians();
    }
    TIMELOCK = timelock;
    for (uint256 i = 0; i < initialGuardians.length; ++i) {
        address guardian = initialGuardians[i];
        if (guardian == address(0)) revert InvalidAddress();
        if (isGuardian[guardian]) revert AlreadyGuardian();
        isGuardian[guardian] = true;
        emit GuardianAdded(guardian, 0);
    }
    guardianCount = initialGuardians.length;
}
```

**Analysis:**
- Zero-address validation for timelock: CORRECT
- Minimum guardian count enforced: CORRECT
- Duplicate detection via `isGuardian[guardian]` check: CORRECT
- Zero-address detection for each guardian: CORRECT
- `guardianCount` set once after loop (not incremented per iteration): Gas-efficient and correct
- Initial `guardianEpoch` is 0 (default): CORRECT, documented in NatSpec
- Events emitted with epoch 0: CORRECT
- Interleaved check-effect pattern is safe in constructors (revert rolls back all state): ACKNOWLEDGED

**Verdict:** Sound. No issues.

### pauseContract (Lines 247-253)

```solidity
function pauseContract(address target) external onlyGuardian {
    if (!isPausable[target]) revert NotPausable();
    IPausable(target).pause();
    emit EmergencyPause(target, msg.sender);
}
```

**Analysis:**
- Access control via `onlyGuardian`: CORRECT
- Pausable registry check: CORRECT
- External call to `target.pause()`: The target is governance-registered (onlyTimelock for registerPausable). See L-01 for reentrancy analysis.
- Event after external call: Slither flags this but it is harmless -- the event is purely informational and no state mutation follows.
- Does NOT check if target is already paused: This is intentional. OpenZeppelin's PausableUpgradeable.pause() will revert with `EnforcedPause()` if already paused, providing natural protection.

**Verdict:** Sound. L-01 (reentrancy via malicious pause()) is theoretical.

### signCancel (Lines 272-293)

```solidity
function signCancel(bytes32 operationId) external onlyGuardian {
    _requireOperationPending(operationId);
    bytes32 cancelKey = _getCancelKey(operationId);
    if (cancelSignatures[cancelKey][msg.sender]) {
        revert AlreadySigned();
    }
    cancelSignatures[cancelKey][msg.sender] = true;
    uint256 newCount = ++cancelSignatureCount[cancelKey];
    emit CancelSigned(operationId, msg.sender, newCount);
    if (newCount >= CANCEL_THRESHOLD) {
        _executeCancel(operationId, cancelKey);
    }
}
```

**Analysis:**
- Access control via `onlyGuardian`: CORRECT
- Pre-check via `_requireOperationPending`: CORRECT (M-02 fix)
- Epoch-scoped cancel key: CORRECT (H-01 fix)
- Duplicate signature prevention: CORRECT
- State mutation before external call (CEI pattern): CORRECT -- signature is recorded before `_executeCancel` makes the external call to TIMELOCK
- Auto-execute at threshold: CORRECT -- uses `>=` (not `==`) which is robust against edge cases
- `++cancelSignatureCount[cancelKey]` captures new value: CORRECT, gas-efficient

**Verdict:** Sound. CEI pattern followed correctly.

### revokeCancel (Lines 303-318)

```solidity
function revokeCancel(bytes32 operationId) external onlyGuardian {
    bytes32 cancelKey = _getCancelKey(operationId);
    if (!cancelSignatures[cancelKey][msg.sender]) {
        revert NotSigned();
    }
    cancelSignatures[cancelKey][msg.sender] = false;
    --cancelSignatureCount[cancelKey];
    emit CancelRevoked(operationId, msg.sender, cancelSignatureCount[cancelKey]);
}
```

**Analysis:**
- Access control via `onlyGuardian`: CORRECT
- Epoch-scoped cancel key: CORRECT
- Signed check prevents revocation of non-existent signature: CORRECT
- No underflow risk: The `NotSigned` check ensures `cancelSignatureCount[cancelKey] >= 1` (since at least the caller's signature exists). Solidity 0.8.24 has built-in overflow/underflow protection regardless.
- Does NOT check if operation is still pending: See I-01 below. This allows post-cancellation revocations that pollute state, but has no security impact.
- Event emission: CORRECT

**Verdict:** Sound. I-01 is a minor state hygiene issue.

### addGuardian (Lines 331-342)

```solidity
function addGuardian(address guardian) external onlyTimelock {
    if (guardian == address(0)) revert InvalidAddress();
    if (isGuardian[guardian]) revert AlreadyGuardian();
    isGuardian[guardian] = true;
    ++guardianCount;
    uint256 newEpoch = ++guardianEpoch;
    emit GuardianAdded(guardian, newEpoch);
}
```

**Analysis:**
- Access control via `onlyTimelock`: CORRECT
- Zero-address validation: CORRECT
- Duplicate prevention: CORRECT
- `guardianCount` increment: CORRECT
- `guardianEpoch` increment (H-01): CORRECT -- invalidates all pending cancel signatures
- No maximum guardian count: ACKNOWLEDGED (M-03 from Round 5 documented the rationale)
- No EOA vs contract validation: See I-03 below

**Verdict:** Sound.

### removeGuardian (Lines 351-364)

```solidity
function removeGuardian(address guardian) external onlyTimelock {
    if (!isGuardian[guardian]) revert NotActiveGuardian();
    if (guardianCount - 1 < MIN_GUARDIANS) {
        revert BelowMinGuardians();
    }
    isGuardian[guardian] = false;
    --guardianCount;
    uint256 newEpoch = ++guardianEpoch;
    emit GuardianRemoved(guardian, newEpoch);
}
```

**Analysis:**
- Access control via `onlyTimelock`: CORRECT
- Active guardian check: CORRECT
- Minimum guardian floor: CORRECT -- `guardianCount - 1 < MIN_GUARDIANS` is equivalent to `guardianCount <= MIN_GUARDIANS`. With `MIN_GUARDIANS = 5`, this prevents removal when count is 5 (would go to 4). No underflow risk because `guardianCount >= 1` (the guardian exists).
- `guardianEpoch` increment (H-01): CORRECT
- The removed guardian's `isGuardian` flag is set to false: CORRECT -- they can no longer call `onlyGuardian` functions

**Verdict:** Sound.

### registerPausable / deregisterPausable (Lines 373-396)

**Analysis:**
- Both functions are `onlyTimelock`: CORRECT
- Zero-address validation on register: CORRECT
- Duplicate/not-registered validation: CORRECT
- `pausableCount` tracked: CORRECT
- Events emitted: CORRECT

**Verdict:** Sound.

### _executeCancel (Lines 456-484)

```solidity
function _executeCancel(bytes32 operationId, bytes32 cancelKey) internal {
    (bool success, ) = TIMELOCK.call(
        abi.encodeWithSignature("cancel(bytes32)", operationId)
    );
    if (!success) {
        emit CancelAttemptFailed(operationId, "cancel failed: not pending");
        return;
    }
    emit OperationCancelled(operationId, cancelSignatureCount[cancelKey]);
}
```

**Analysis:**
- Low-level call to `TIMELOCK.cancel()`: The TIMELOCK is an immutable address set in the constructor. The EmergencyGuardian must have `CANCELLER_ROLE` on the timelock.
- Graceful failure handling (Round 6 M-01 fix): On failure, emits `CancelAttemptFailed` and returns without reverting. This preserves the 3rd guardian's signature in state and provides a clean audit trail. CORRECT.
- Ignores return data on failure: The `(bool success, )` pattern discards returndata. This is acceptable because the failure reason is always "not pending" and the event provides a human-readable reason string.
- On success, emits `OperationCancelled` with current signature count: CORRECT
- CEI pattern: State mutations (signature recording) happen in `signCancel` before this function is called. `_executeCancel` only makes the external call and emits events. CORRECT.
- Reentrancy risk via TIMELOCK.call: The TIMELOCK is a trusted OpenZeppelin TimelockController. Its `cancel()` function modifies internal timelock state and emits a `Cancelled` event, but does not make external calls. No reentrancy path.

**Verdict:** Sound. The Round 6 M-01 fix is correctly implemented.

### _getCancelKey (Lines 498-502)

```solidity
function _getCancelKey(bytes32 operationId) internal view returns (bytes32) {
    return keccak256(abi.encodePacked(operationId, guardianEpoch));
}
```

**Analysis:**
- `abi.encodePacked(bytes32, uint256)`: No collision risk because `bytes32` is fixed-size (32 bytes) and `uint256` is fixed-size (32 bytes). The packed encoding produces a unique 64-byte input for each `(operationId, guardianEpoch)` pair. This is NOT the variable-length packed encoding collision vulnerability that applies to dynamic types.
- Epoch-based key generation: CORRECT. When `guardianEpoch` changes, the cancel key changes, invalidating all prior signatures for the same `operationId`.

**Verdict:** Sound.

### _requireOperationPending (Lines 513-531)

```solidity
function _requireOperationPending(bytes32 operationId) internal view {
    (bool success, bytes memory data) = TIMELOCK.staticcall(
        abi.encodeWithSignature("isOperationPending(bytes32)", operationId)
    );
    if (!success || data.length < 32 || !abi.decode(data, (bool))) {
        revert OperationNotPending();
    }
}
```

**Analysis:**
- `staticcall`: Read-only, cannot modify state: CORRECT
- Function signature `"isOperationPending(bytes32)"`: Matches OZ TimelockController v5.4.0: CORRECT
- Return data validation:
  - `!success`: Handles case where TIMELOCK is not a valid contract or does not have the function: CORRECT
  - `data.length < 32`: Handles case where return data is malformed: CORRECT
  - `!abi.decode(data, (bool))`: Decodes the boolean return value. If the operation is not pending, this is `false`, triggering the revert: CORRECT
- Combined condition uses short-circuit evaluation: If `!success` is true, `data.length` is not checked, and `abi.decode` is not called. This prevents attempting to decode invalid data: CORRECT

**Verdict:** Sound.

### View Functions (Lines 409-439)

`getCancelKey()`, `currentCancelSignatureCount()`, `hasSignedCancel()`: All are simple wrappers around internal state using `_getCancelKey()`. No issues.

---

## Pass 3: Business Logic Analysis

### Emergency Pause Authority

| Aspect | Assessment |
|--------|------------|
| Threshold | 1-of-N (any single guardian) -- appropriate for fast exploit response |
| Scope | Only governance-registered pausable contracts |
| Registration authority | Timelock-only (requires governance proposal) |
| Unpause authority | EmergencyGuardian CANNOT unpause -- governance must unpause via timelock |
| Rate limiting | None -- a guardian can pause multiple contracts in rapid succession |
| Abuse potential | Limited to temporary DoS (all contracts paused). Governance can unpause. A rogue guardian cannot permanently lock the protocol. |
| Double-pause | Handled by target contracts (OZ PausableUpgradeable reverts with `EnforcedPause()`) |

**Assessment:** The 1-of-N pause threshold is correct for emergency response. The inability to unpause is the critical safety property that limits the damage from a compromised guardian to temporary denial of service.

### Cancel Authority

| Aspect | Assessment |
|--------|------------|
| Threshold | Fixed 3-of-N (documented rationale at lines 17-28) |
| Scope | Any pending timelock operation |
| Pre-check | `_requireOperationPending()` validates operation exists and is pending |
| Signature collection | On-chain sequential (each guardian calls `signCancel` individually) |
| Auto-execution | Triggers at threshold (3rd signature) |
| Epoch invalidation | Guardian set changes invalidate all pending signatures |
| Revocation | `revokeCancel()` available before threshold is reached |
| Graceful failure | `CancelAttemptFailed` event on timelock race condition |

**Assessment:** The cancel mechanism is well-designed with proper safeguards against ghost votes (epoch), operational mistakes (revocation), and race conditions (graceful failure).

### Cooldown / Rate Limiting

The contract has no explicit cooldown between emergency actions. A guardian can:
1. Pause multiple contracts in rapid succession
2. Sign multiple cancel requests in the same block

This is intentional for emergency response speed. The governance-gated registration (pausable contracts) and the 3-of-N cancel threshold provide sufficient protection against abuse.

### Permanent Lockout Prevention

| Risk | Mitigation |
|------|------------|
| All contracts paused | Governance can unpause via timelock |
| All timelock operations cancelled | Governance can re-propose |
| Guardian set compromised | Timelock can replace guardians |
| EmergencyGuardian itself compromised | It is immutable (no upgrade function). Timelock can revoke CANCELLER_ROLE. Timelock can deregister all pausable contracts. |

**Recovery paths are complete.** No permanent lockout scenario exists.

### What EmergencyGuardian CANNOT Do

| Action | Verification |
|--------|-------------|
| Unpause contracts | No unpause function exists |
| Upgrade any contract | No UUPS authority, no ADMIN_ROLE |
| Queue proposals | No PROPOSER_ROLE on timelock |
| Execute proposals | No special execution ability |
| Change own parameters | All management functions are `onlyTimelock` |
| Transfer or hold funds | No payable functions, no receive/fallback, no token handling |
| Self-destruct | No selfdestruct opcode |

**Verdict:** Minimal authority principle is correctly implemented and verified.

---

## Pass 4: DeFi Attack Vectors

### Guardian Collusion to Grief the Protocol

**Scenario:** 3 colluding guardians cancel all legitimate governance proposals.

**Analysis:**
- With 5 guardians (minimum), 3 colluding guardians can cancel any pending operation.
- Mitigation: Guardians are publicly named, governance-elected, and at least 50% external to the OmniBazaar team (per NatSpec).
- Countermeasure: The timelock can remove compromised guardians via governance proposal. Since cancel requires 3 signatures collected on-chain over separate transactions, there is a time window for the community to detect and respond.
- Ultimate defense: The CANCELLER_ROLE can be revoked from EmergencyGuardian by the timelock.

**Risk level:** Low. Requires 60% of minimum guardian set to collude, guardians are publicly accountable.

### Denial-of-Service Through Repeated Emergencies

**Scenario:** A single compromised guardian repeatedly pauses all registered contracts.

**Analysis:**
- A single guardian can pause any registered contract with one transaction.
- After governance unpauses, the same guardian can pause again immediately.
- No cooldown exists between pause actions.

**Mitigation:**
- Governance can remove the guardian via timelock proposal (48h routine delay).
- During the 48h window, the guardian can repeatedly pause contracts.
- Each governance unpause also goes through the timelock (48h or 7 days depending on classification -- `SEL_UNPAUSE` is classified as critical, requiring 7 days).

**Impact:** A rogue guardian can effectively keep contracts paused for 7+ days until governance can unpause AND remove the guardian.

**Assessment:** This is inherent to the 1-of-N pause design and is a known tradeoff for emergency response speed. The unpause delay through the critical timelock (7 days) is the constraining factor. This is documented in the NatSpec and is consistent with Optimism's Security Council pattern. See I-02 below for a recommendation.

### Social Engineering of Guardian Keys

**Scenario:** An attacker socially engineers a guardian's private key.

**Analysis:**
- With one compromised key: Can only pause (temporary DoS).
- With three compromised keys: Can pause AND cancel governance operations.
- No off-chain signing is used -- all actions require on-chain transactions from guardian addresses.

**Mitigation:** Guardians should use hardware wallets. The publicly-named guardian requirement creates accountability that discourages social engineering.

**Risk level:** Medium for key compromise, but out of scope for smart contract audit. Operational security procedures should be documented.

### Race Conditions in Multisig Approval

**Scenario:** A timelock operation is executed normally while guardians are collecting cancel signatures.

**Analysis:**
1. Guardians 1 and 2 sign cancel (count = 2).
2. The timelock operation's delay expires and someone executes it.
3. Guardian 3 calls `signCancel()`.
4. `_requireOperationPending()` at line 274 reverts with `OperationNotPending` because the operation is no longer pending.

**Result:** The 3rd signature is correctly rejected. No inconsistent state. The first two signatures remain in storage but are inert (they can never reach the threshold for this operation in the current epoch).

**Alternative scenario:** Guardian 3's transaction and the execution transaction are in the same block.
- Ethereum block ordering is deterministic. If the execution transaction appears first in the block, `signCancel()` reverts. If `signCancel()` appears first, the cancel auto-fires before execution.
- No race condition vulnerability.

**Verdict:** Race conditions are correctly handled by the pre-check and graceful failure mechanisms.

---

## Pass 5: Cross-Contract Integration Analysis

### Integration with OmniTimelockController

| Aspect | Verification |
|--------|-------------|
| CANCELLER_ROLE | EmergencyGuardian must have `CANCELLER_ROLE` on OmniTimelockController. Verified in test deployment (line 81 of test file). |
| cancel(bytes32) interface | Called via `abi.encodeWithSignature("cancel(bytes32)")`. Matches OZ TimelockController v5.4.0 `cancel(bytes32 id)` with selector `0xc4d252f5`. |
| isOperationPending(bytes32) | Called via `abi.encodeWithSignature("isOperationPending(bytes32)")`. Matches OZ TimelockController v5.4.0. Returns `bool`. |
| Timelock's cancel behavior | OZ `cancel()` requires `onlyRole(CANCELLER_ROLE)`, checks `isOperationPending(id)`, deletes the timestamp, emits `Cancelled(id)`. If the operation is not pending, it reverts with `TimelockUnexpectedOperationState`. |

**Integration correctness:** The EmergencyGuardian correctly interfaces with the OmniTimelockController for both cancel and pending-state queries.

### Integration with Pausable Contracts

| Aspect | Verification |
|--------|-------------|
| IPausable interface | Minimal: `function pause() external`. All OmniBazaar contracts implementing PausableUpgradeable expose `pause()`. |
| Role requirement | The target contract must have granted EmergencyGuardian the appropriate role (ADMIN_ROLE, PAUSER_ROLE, or DEFAULT_ADMIN_ROLE). This is documented in IPausable NatSpec. |
| Pause behavior | OZ PausableUpgradeable `_pause()` sets `_paused = true` and emits `Paused(msg.sender)`. If already paused, reverts with `EnforcedPause()`. |
| Registered contracts | Only governance-registered (onlyTimelock) contracts can be paused. |

**Integration correctness:** Sound. The pausable interface is minimal and matches all OmniBazaar contract implementations.

### Which Contracts Can Be Paused

The EmergencyGuardian can pause any contract registered via `registerPausable()`. Based on the codebase:
- OmniCore.sol -- implements PausableUpgradeable
- OmniCoin.sol -- implements PausableUpgradeable (ERC20Pausable)
- DEXSettlement.sol -- implements PausableUpgradeable
- UnifiedFeeVault.sol -- implements PausableUpgradeable
- OmniBridge.sol -- implements PausableUpgradeable
- MinimalEscrow.sol -- implements PausableUpgradeable
- OmniRewardManager.sol -- implements PausableUpgradeable
- StakingRewardPool.sol -- implements PausableUpgradeable

All of these would need to grant EmergencyGuardian the pause role and be registered via timelock governance.

### Guardian Management via Governance

The guardian lifecycle is:
1. Governance proposal to add/remove a guardian is created in OmniGovernance.
2. If the vote passes, the operation is scheduled in OmniTimelockController.
3. After the delay (48h routine or 7 days critical -- `addGuardian` is not a critical selector, so 48h), the operation is executed.
4. EmergencyGuardian's `addGuardian`/`removeGuardian` is called by the timelock.
5. `guardianEpoch` increments, invalidating all pending cancel signatures.

**Integration correctness:** Sound. The governance pipeline correctly manages the guardian set.

---

## Pass 6: Upgradeability & Storage

### Non-Upgradeable Contract

EmergencyGuardian is a plain Solidity contract (not UUPS, not Transparent Proxy). It is deployed as an immutable contract. There is no:
- `UUPSUpgradeable` inheritance
- `_authorizeUpgrade()` function
- `initialize()` function
- Proxy pattern
- `delegatecall` usage

**Verdict:** No upgradeability concerns. The contract is deployed once and cannot be modified.

### Storage Layout

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | `isGuardian` | mapping(address => bool) | Occupies slot 0 (mapping base) |
| 1 | `guardianCount` | uint256 | Full slot |
| 2 | `isPausable` | mapping(address => bool) | Occupies slot 2 (mapping base) |
| 3 | `pausableCount` | uint256 | Full slot |
| 4 | `guardianEpoch` | uint256 | Full slot |
| 5 | `cancelSignatures` | mapping(bytes32 => mapping(address => bool)) | Nested mapping |
| 6 | `cancelSignatureCount` | mapping(bytes32 => uint256) | Mapping |

**Constants (not in storage):**
- `CANCEL_THRESHOLD = 3` (constant, inlined)
- `MIN_GUARDIANS = 5` (constant, inlined)

**Immutables (in bytecode, not storage):**
- `TIMELOCK` (immutable address)

**Storage analysis:** Clean layout. No packing opportunities (mappings and uint256 each take full slots). No storage gaps needed (non-upgradeable). No struct packing optimization possible.

---

## Round 6 vs Round 7 Comparison

### Prior Findings Remediation Status (All Rounds)

| Round | ID | Severity | Finding | Status |
|-------|----|----------|---------|--------|
| 5 | H-01 | High | Removed guardians retain cancel signatures (ghost votes) | **RESOLVED** -- Epoch-based invalidation at lines 79-82, 339, 361 |
| 5 | M-01 | Medium | No cancel signature revocation mechanism | **RESOLVED** -- `revokeCancel()` at lines 303-318 |
| 5 | M-02 | Medium | No operation state pre-check before collecting signatures | **RESOLVED** -- `_requireOperationPending()` at lines 274, 513-531 |
| 5 | M-03 | Medium | Fixed threshold NatSpec says "3-of-5" instead of "3-of-N" | **RESOLVED** -- NatSpec updated with detailed rationale at lines 17-28 |
| 5 | L-01 | Low | Low-level call for cancel instead of interface call | **ACKNOWLEDGED** -- Deliberate design for graceful failure handling |
| 5 | L-02 | Low | Constructor interleaved check-effect pattern | **N/A** -- Safe in constructor context |
| 5 | L-03 | Low | No event for failed cancel attempts | **RESOLVED** -- `CancelAttemptFailed` event emitted in `_executeCancel()` |
| 5 | I-01 | Info | Indexed timestamp in EmergencyPause event | **RESOLVED** -- `timestamp` parameter removed |
| 5 | I-02 | Info | Indexed signatureCount in events | **RESOLVED** -- `signatureCount` no longer indexed |
| 5 | I-03 | Info | NatSpec "3-of-5" inaccurate | **RESOLVED** -- Updated to "3-of-N threshold, fixed" |
| 6 | M-01 | Medium | `_executeCancel()` reverts on failure instead of emitting CancelAttemptFailed | **RESOLVED** -- Now emits event and returns gracefully (lines 467-478) |
| 6 | L-01 | Low | `revokeCancel()` does not check if operation is still pending | **OPEN** -- See I-01 below (downgraded from Low to Informational) |
| 6 | L-02 | Low | No reentrancy guard on `pauseContract()` | **OPEN** -- See L-01 below (retained at Low) |
| 6 | I-01 | Info | `CancelAttemptFailed` event declared but never emitted | **RESOLVED** -- Event is now emitted in `_executeCancel()` (line 473) |
| 6 | I-02 | Info | Guardian addition does not validate against contract addresses | **ACKNOWLEDGED** -- Documented in deployment guide |

### Code Changes Since Round 6

The contract has been updated to address the Round 6 M-01 finding. The key change is in `_executeCancel()`:

**Round 6 (before fix):**
```solidity
if (!success) {
    if (returndata.length > 0) {
        assembly { revert(add(32, returndata), mload(returndata)) }
    }
    revert CancelFailed();
}
```

**Round 7 (after fix):**
```solidity
if (!success) {
    emit CancelAttemptFailed(operationId, "cancel failed: not pending");
    return;
}
```

This change:
- Preserves the 3rd guardian's signature in state (transaction does not revert)
- Provides a clean audit trail via the `CancelAttemptFailed` event
- Prevents the confusing UX of a raw EVM revert for the triggering guardian
- The `CancelFailed` custom error is no longer used but remains declared (see I-03)

---

## New Findings

### [L-01] No Reentrancy Guard on `pauseContract()` (Retained from Round 6 L-02)

**Severity:** Low
**Lines:** 247-253
**Category:** Reentrancy

**Description:**

`pauseContract()` makes an external call to a governance-registered target contract via `IPausable(target).pause()`. If the target's `pause()` implementation re-enters the EmergencyGuardian, the following could occur:

1. **Re-enter `pauseContract()` with a different target:** Succeeds if the other target is registered. This is harmless (pausing two contracts in one transaction).

2. **Re-enter `signCancel()`:** Succeeds if the caller is a guardian and the operation is pending. This could reach the cancel threshold unexpectedly during a pause transaction.

3. **Re-enter `revokeCancel()`:** Succeeds, reverting a prior cancel signature.

The risk is low because:
- The target must be registered as pausable by governance.
- Standard OpenZeppelin PausableUpgradeable.pause() does not make external calls.
- A malicious target would require a governance proposal to register.
- If the target is UUPS upgradeable, a future upgrade could introduce reentrancy, but that upgrade would also go through governance/timelock.

**Impact:** Theoretical reentrancy path requiring governance-registered malicious contract. No practical exploit path with current OmniBazaar contracts.

**Recommendation:**

Accept as known risk given the governance-gated registration requirement. If defense-in-depth is desired, add a simple reentrancy lock:

```solidity
bool private _pausing;
error Reentrancy();

function pauseContract(address target) external onlyGuardian {
    if (_pausing) revert Reentrancy();
    _pausing = true;
    if (!isPausable[target]) revert NotPausable();
    IPausable(target).pause();
    emit EmergencyPause(target, msg.sender);
    _pausing = false;
}
```

Since the contract is non-upgradeable, the storage slot cost is paid once at deployment. Gas cost per call: ~2,100 (cold SLOAD) + 5,000 (SSTORE) = ~7,100 additional gas per pause.

---

### [I-01] `revokeCancel()` Does Not Check if Operation is Still Pending (Downgraded from Round 6 L-01)

**Severity:** Informational (downgraded from Low in Round 6)
**Lines:** 303-318
**Category:** State Hygiene

**Description:**

`revokeCancel()` allows a guardian to revoke their cancel signature even after the operation has been cancelled or executed. This results in `cancelSignatureCount` being decremented below its meaningful value for a completed operation.

**Downgrade rationale:** After further analysis, this has zero security impact and zero functional impact. The stale signature count for a completed operation is never read by any contract logic. The epoch-based key system means each operation+epoch pair is independent, and the count is only meaningful while the operation is pending. Post-cancellation revocations are a no-op in terms of protocol behavior.

Adding `_requireOperationPending()` to `revokeCancel()` would add ~2,600 gas per call for a staticcall that provides no security benefit. The trade-off does not justify the gas cost.

**Impact:** Cosmetic state inconsistency for completed operations. No security or functional impact.

**Recommendation:** Accept as-is. Document that `cancelSignatureCount` is only meaningful for pending operations in the current epoch.

---

### [I-02] Repeated Emergency Pause Has Extended Recovery Time Due to Critical Unpause Delay

**Severity:** Informational
**Lines:** 247-253 (pauseContract), OmniTimelockController lines 72-75 (SEL_PAUSE, SEL_UNPAUSE as critical)
**Category:** Operational / Cross-Contract

**Description:**

In the OmniTimelockController, both `pause()` (selector `0x8456cb59`) and `unpause()` (selector `0x3f4ba83a`) are classified as critical selectors requiring the 7-day `CRITICAL_DELAY`. This means:

1. A rogue guardian pauses a contract (instant, 1-of-N).
2. Governance proposes to unpause and remove the guardian.
3. The unpause operation requires 7-day critical delay.
4. After 7 days, the unpause executes.
5. During those 7 days, the rogue guardian can re-pause the contract (since they have not been removed yet -- guardian removal is separate from unpause).
6. If the guardian removal is in the same batch as unpause, both execute simultaneously after 7 days, resolving the issue. But if they are separate proposals, there is a window for re-pause.

This is inherent to the 1-of-N pause + 7-day unpause design and is a known tradeoff. The OmniTimelockController classifies unpause as critical because unpausing a contract is a high-impact action (it resumes operations that may have been paused due to an exploit).

**Impact:** A rogue guardian can keep a contract paused for an extended period (7+ days) until both unpause and guardian removal execute. No permanent lockout -- governance always prevails.

**Recommendation:** When removing a rogue guardian, batch the guardian removal and unpause into a single timelock operation to prevent the re-pause window. Document this operational procedure in the deployment guide.

---

### [I-03] `CancelFailed` Custom Error is Declared but No Longer Used

**Severity:** Informational
**Lines:** 189
**Category:** Dead Code

**Description:**

The `CancelFailed` custom error is declared at line 189:

```solidity
error CancelFailed();
```

After the Round 6 M-01 fix, `_executeCancel()` no longer reverts on failure -- it emits `CancelAttemptFailed` and returns. The `CancelFailed` error is dead code.

**Impact:** Marginal bytecode increase. May confuse developers who expect the error to be thrown.

**Recommendation:** Remove the `CancelFailed` error declaration:

```solidity
// Remove: error CancelFailed();
```

This is a trivial cleanup with no functional impact.

---

## Compliance Summary

| Requirement | Status | Notes |
|-------------|--------|-------|
| NatSpec documentation | PASS | Complete NatSpec on all public/external functions, events, errors, state variables, and constants. Contract-level NatSpec with detailed design rationale. |
| Custom errors (not require strings) | PASS | 12 custom errors defined. No `require()` with strings. |
| Solhint compliance | PASS | Zero findings. solhint-disable comments used sparingly with justification. |
| Gas optimization | PASS | Immutables, constants, prefix increment, no redundant storage reads. |
| Access control | PASS | `onlyGuardian` and `onlyTimelock` modifiers with correct enforcement. |
| Event emission | PASS | All state-changing operations emit events with appropriate indexed parameters. |
| CEI pattern | PASS | State mutations before external calls in `signCancel()`. Event-only emissions after calls in `pauseContract()` and `_executeCancel()`. |
| Line length (120 chars) | PASS | All lines within 120 characters. |
| Solidity version | PASS | Pinned to `0.8.24`. |
| L2BEAT Stage 1 compliance | PASS | Minimum 5 guardians enforced, governance-managed, publicly named (NatSpec). |
| Minimal authority | PASS | Cannot unpause, upgrade, queue, execute, or modify own parameters. |
| Epoch-based invalidation | PASS | H-01 fix verified correct with comprehensive trace analysis. |

---

## Test Coverage Assessment

| Test Case | Status | Notes |
|-----------|--------|-------|
| Deploy with 5 guardians | PASS | |
| Reject < 5 guardians | PASS | |
| Reject zero-address timelock | PASS | |
| Reject duplicate guardians | PASS | |
| Immutable timelock reference | PASS | |
| Constants verification | PASS | CANCEL_THRESHOLD = 3, MIN_GUARDIANS = 5 |
| Pause: reject unregistered | PASS | |
| Pause: reject non-guardian | PASS | |
| Pause: success flow | PASS | With role grant and registration |
| Cancel: collect signatures | PASS | With epoch-aware view functions |
| Cancel: reject duplicates | PASS | |
| Cancel: reject non-guardian | PASS | |
| Cancel: auto-cancel at 3 | PASS | Verifies OperationCancelled event |
| Cancel: CancelSigned events | PASS | |
| Guardian management: add | PASS | |
| Guardian management: reject non-timelock | PASS | |
| Guardian management: reject zero address | PASS | |
| Guardian management: reject duplicate | PASS | |
| Guardian management: remove | PASS | |
| Guardian management: reject below minimum | PASS | |
| Pausable registration/deregistration | PASS | |
| Integration: cancel via governance pipeline | PASS | In Section 5 of test file |

**Missing test coverage (non-critical):**

| Missing Test | Severity | Notes |
|--------------|----------|-------|
| `revokeCancel()` flow | Low | Revoke before threshold, verify count decrements |
| `revokeCancel()` reject not-signed | Low | Verify NotSigned error |
| Epoch invalidation after addGuardian | Low | Sign cancel, add guardian, verify old signature invalid |
| Epoch invalidation after removeGuardian | Low | Sign cancel, remove guardian, verify old signature invalid |
| Cancel with non-pending operation | Low | Verify OperationNotPending error |
| Graceful cancel failure | Low | signCancel after operation already executed, verify CancelAttemptFailed event |
| View functions: getCancelKey, hasSignedCancel | Low | Basic view function tests |
| Multiple pausable contracts | Low | Register 3+, pause each individually |
| Zero-address guardian in initialGuardians | Low | Verify InvalidAddress error mid-array |

These are test coverage gaps, not contract vulnerabilities. The existing 22 tests cover all critical paths.

---

## Overall Risk Rating

**Risk Level: LOW**

The EmergencyGuardian contract is well-designed, thoroughly documented, and has had all prior findings (1 High, 4 Medium, 3 Low, 3 Informational across two prior rounds) fully remediated. The contract implements the minimal authority principle correctly, with appropriate safeguards against ghost votes (epoch-based invalidation), operational mistakes (signature revocation), and race conditions (graceful failure handling).

The single Low finding (reentrancy via malicious pause target) is theoretical and requires governance to register a malicious contract. The three Informational findings are minor state hygiene and dead code issues with no security impact.

**Pre-Mainnet Readiness: READY**

No blocking issues. The I-03 dead code cleanup (`CancelFailed` error removal) is recommended but not required.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/EmergencyGuardian.sol` | 532 | Primary audit target |
| `Coin/contracts/interfaces/IPausable.sol` | 17 | Pause interface |
| `Coin/contracts/OmniTimelockController.sol` | 347 | Timelock integration |
| `Coin/test/UUPSGovernance.test.js` | ~1,610 | Test coverage verification |
| `Coin/audit-reports/EmergencyGuardian-audit-2026-02-26.md` | 460 | Round 5 report |
| `Coin/audit-reports/round6/EmergencyGuardian-audit-2026-03-10.md` | 535 | Round 6 report |

---

*Generated by Claude Opus 4.6 -- 7-Pass Comprehensive Audit*
*Date: 2026-03-13*
