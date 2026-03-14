# Security Audit Report: OmniAccount.sol (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/account-abstraction/OmniAccount.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 862
**Upgradeable:** Yes (Initializable, deployed as ERC-1167 clones via OmniAccountFactory)
**Handles Funds:** Yes (smart wallet -- holds native tokens, interacts with ERC-20s, custodies user funds)
**Dependencies:** `ECDSA`, `MessageHashUtils` (OZ 5.x), `Initializable` (OZ), `ReentrancyGuard` (OZ), `IAccount` (custom)
**Previous Audits:** Suite audit (2026-02-21, 4C/4H/5M/4L), Round 3 (2026-02-26, 0C/0H/2M/2L/5I), Round 6 (2026-03-10, 0C/0H/1M/2L/3I)
**Slither:** Skipped
**Tests:** 19 passing (AccountAbstraction.test.js)

---

## Executive Summary

OmniAccount is the ERC-4337 smart wallet implementation serving as the primary
user account on OmniCoin L1. It supports ECDSA signature validation, session
keys with scoped permissions (target, value, time bounds), daily spending
limits, guardian-based social recovery with a 2-day delay, and batch execution.
It is deployed as ERC-1167 minimal proxy clones via OmniAccountFactory.

This Round 7 audit is the fourth dedicated review of OmniAccount. All prior
Critical, High, Medium, and Low findings from rounds 3 and 6 have been
remediated. The contract is at 862 lines and has not changed structurally since
Round 6. The Round 6 M-01 finding (documentation of wildcard session key +
maxValue risk) was fixed via NatSpec warnings.

**This audit identifies one Critical vulnerability, one Medium finding, two Low
findings, and four Informational observations.**

The Critical finding (C-01) is a **session key privilege escalation via
self-call**. A session key with `allowedTarget == address(0)` (the "any target"
wildcard) can execute arbitrary management functions on the OmniAccount itself by
targeting `address(this)` through the `execute()` function. Because the
`onlyOwner` modifier accepts `msg.sender == address(this)`, the self-call
bypasses owner-only access control. This allows a session key holder to perform
full account takeover via `transferOwnership`, guardian manipulation, spending
limit removal, and recovery cancellation.

### Solhint Results

```
0 errors, 0 warnings
```

Clean. All timestamp-dependent code has inline `solhint-disable-line` comments.
Immutable naming and empty blocks are properly suppressed.

### Severity Summary

| Severity       | Count |
|----------------|-------|
| Critical       | 1     |
| High           | 0     |
| Medium         | 1     |
| Low            | 2     |
| Informational  | 4     |
| **Total**      | **8** |

---

## Remediation Status from Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| Suite C-01: Session key constraints never enforced | Critical | **Fixed** | `_validateSessionKeyCallData()` (lines 822-852) validates selector, target, and value constraints |
| Suite C-02: Spending limits dead code | Critical | **Fixed** | `execute()` (lines 396-405) and `executeBatch()` (lines 434-445) both enforce limits for EntryPoint calls |
| Suite C-03: EntryPoint never deducts gas | Critical | **Fixed** | OmniEntryPoint `_deductGasCost` |
| Suite C-04: Removed guardian approval persists | Critical | **Fixed** | `GuardiansFrozenDuringRecovery` check in both add/remove. Defense-in-depth cleanup in `removeGuardian` (lines 506-512) |
| Suite M-01: Owner blocks recovery by removing guardians | Medium | **Fixed** | Guardian freeze during recovery |
| Suite M-02: No reentrancy guard | Medium | **Fixed** | `nonReentrant` on `execute` and `executeBatch` |
| R3 M-01: Session key validAfter omitted | Medium | **Fixed** | `SessionKey` struct includes `validAfter` (line 40). Packed into return data (lines 370-371) |
| R3 M-02: executeBatch lacks spending limits | Medium | **Fixed** | `executeBatch` (lines 434-445) enforces native and ERC-20 spending limits for EntryPoint calls |
| R3 L-01: approveRecovery emits no event | Low | **Fixed** | `RecoveryApproved` event emitted (lines 559-561) |
| R3 L-02: addSessionKey allows validUntil in past | Low | **Fixed** | `SessionKeyAlreadyExpired` error added (lines 631-633) |
| R6 M-01: Wildcard session key + maxValue > 0 can transfer native tokens to any address | Medium | **Fixed (documentation)** | NatSpec warning added to `addSessionKey` (lines 607-613). **However, the root problem is deeper than documented -- see C-01 below** |
| R6 L-01: executeRecovery callable by anyone | Low | **Acknowledged** | Intentional for gasless relayed execution |
| R6 L-02: block.timestamp manipulation for spending limits | Low | **Acknowledged** | Constrained by Snowman consensus |
| R6 I-01: onlyOwner allows address(this) | Info | **Acknowledged** | Intentional for ERC-4337 composability. **This design decision enables C-01** |
| R6 I-02: ERC-20 spending limit doesn't cover transferFrom | Info | **Acknowledged** | transfer + approve coverage sufficient |
| R6 I-03: Session key replacement doesn't emit revoked event | Info | **Acknowledged** | Minor observability gap |

---

## Critical Findings

### [C-01] Session Key Privilege Escalation via Self-Call to Management Functions

**Severity:** Critical
**Lines:** 282, 389-412, 822-852
**Category:** Access Control / Privilege Escalation
**CVSS:** 9.1 (Critical)

**Description:**

A session key with `allowedTarget == address(0)` (the "any target" wildcard)
can execute **any** owner-only management function on the OmniAccount by
targeting `address(this)` through `execute()`. This is a full account takeover
vulnerability.

The attack chain:

1. Session key holder signs a UserOp where `callData` encodes
   `execute(address(this), 0, abi.encodeCall(transferOwnership, (attacker)))`.

2. `validateUserOp` (line 336) recovers the session key signer and calls
   `_validateSessionKeyCallData` (line 362).

3. `_validateSessionKeyCallData` (lines 822-852) validates:
   - Selector: `execute(address,uint256,bytes)` -- **passes** (line 832)
   - Target: `address(this)` vs `allowedTarget == address(0)` -- **passes**
     because `address(0)` means "any target" (line 843)
   - Value: 0 -- **passes** (line 848)

4. The EntryPoint calls `OmniAccount.execute(address(this), 0, transferOwnership_calldata)`.

5. `execute` (line 393) passes `onlyOwnerOrEntryPoint` because
   `msg.sender == entryPoint`.

6. `execute` performs `address(this).call{value: 0}(abi.encodeCall(transferOwnership, (attacker)))` (line 408).

7. Inside the self-call, `transferOwnership` (line 463) checks `onlyOwner`:
   ```solidity
   modifier onlyOwner() {
       if (msg.sender != owner && msg.sender != address(this)) {
           revert OnlyOwner();
       }
       _;
   }
   ```
   `msg.sender == address(this)` -- **passes**.

8. Ownership is transferred to the attacker.

**All `onlyOwner` functions are exploitable through this path:**

| Function | Exploit Impact |
|----------|---------------|
| `transferOwnership` | Full account takeover |
| `addGuardian` | Add attacker as guardian |
| `removeGuardian` | Remove legitimate guardians (when no recovery active) |
| `addSessionKey` | Create new session keys with broader permissions |
| `revokeSessionKey` | Revoke other session keys |
| `setSpendingLimit` | Set daily limit to 0 (disable limits) or `type(uint256).max` |
| `cancelRecovery` | Block legitimate recovery attempts |

**The `nonReentrant` modifier on `execute` does NOT prevent this.** The
self-call invokes `transferOwnership` directly, not `execute` or `executeBatch`.
`transferOwnership` is not guarded by `nonReentrant`.

**Note:** This also affects session keys where `allowedTarget == address(this)`,
though that configuration is unlikely in practice.

**Root Cause:** The R6 I-01 finding flagged that `onlyOwner` allows
`address(this)` as an intentional ERC-4337 composability feature (the owner
needs to manage the account via UserOps). However, session key validation does
not exclude `address(this)` as a target, creating a privilege escalation bridge
from session-key-level to owner-level access.

**Impact:** Any session key with `allowedTarget == address(0)` has **full owner
privileges**, not just the scoped permissions the owner intended. A compromised
session key grants immediate, complete account takeover with zero delay (no
recovery period, no guardian intervention). This defeats the entire purpose of
the session key scoping system.

**Proof of Concept:**

```solidity
// Attacker has a session key with:
//   allowedTarget = address(0)  (any target)
//   maxValue = 0                (no value, only calls)
//   validUntil = 0              (never expires)

// Step 1: Sign UserOp with callData:
bytes memory callData = abi.encodeCall(
    OmniAccount.execute,
    (
        address(omniAccount),         // target = self
        0,                            // value = 0
        abi.encodeCall(               // data = transferOwnership
            OmniAccount.transferOwnership,
            (attackerAddress)
        )
    )
);

// Step 2: Submit to EntryPoint -- session key signs this
// Step 3: execute() self-calls transferOwnership(attacker)
// Step 4: Attacker is now the owner
```

**Recommendation:**

Add `address(this)` as an excluded target in `_validateSessionKeyCallData`:

```solidity
function _validateSessionKeyCallData(
    bytes calldata callData,
    SessionKey storage sk
) internal view returns (bool valid) {
    if (callData.length < 100) return false;

    bytes4 selector = bytes4(callData[:4]);
    if (selector != bytes4(keccak256("execute(address,uint256,bytes)"))) {
        return false;
    }

    (address target, uint256 value,) = abi.decode(
        callData[4:],
        (address, uint256, bytes)
    );

    // CRITICAL: Prevent session keys from calling management functions
    // via self-call. address(this) self-calls bypass onlyOwner because
    // the modifier allows msg.sender == address(this) for ERC-4337
    // composability. Session keys must never reach this path.
    if (target == address(this)) return false;

    if (sk.allowedTarget != address(0) && target != sk.allowedTarget) {
        return false;
    }

    if (sk.maxValue == 0 && value > 0) return false;
    if (sk.maxValue > 0 && value > sk.maxValue) return false;

    return true;
}
```

Additionally, prevent `addSessionKey` from accepting `address(this)` as
`allowedTarget`:

```solidity
function addSessionKey(
    address signer,
    uint48 validUntil,
    uint48 validAfter,
    address allowedTarget,
    uint256 maxValue
) external onlyOwner {
    if (signer == address(0)) revert InvalidAddress();
    // Prevent session keys scoped to the account itself
    if (allowedTarget == address(this)) revert InvalidAddress();
    ...
}
```

Both defenses should be applied (defense in depth). The
`_validateSessionKeyCallData` check is the primary protection because it covers
the `allowedTarget == address(0)` wildcard case.

---

## Medium Findings

### [M-01] Malformed Session Key UserOp callData Causes validateUserOp Revert Instead of Failure Return

**Severity:** Medium
**Lines:** 837-840
**Category:** ERC-4337 Compliance / Bundler Griefing

**Description:**

When a session key signs a UserOp with valid signature but malformed `callData`,
the `abi.decode` at line 837-840 can revert:

```solidity
(address target, uint256 value,) = abi.decode(
    callData[4:],
    (address, uint256, bytes)
);
```

The minimum length check (line 827: `callData.length < 100`) ensures there are
at least 100 bytes, which covers the selector (4) + address (32) + uint256 (32)
+ bytes offset (32). However, `abi.decode` for a `bytes` type also reads:

1. The offset pointer (at position 64 in the decoded data)
2. The length at the offset location
3. The actual bytes data

If the offset pointer points beyond the calldata boundary, or the encoded
length exceeds available data, `abi.decode` will revert. This causes
`validateUserOp` itself to revert rather than returning `SIG_VALIDATION_FAILED`.

Per ERC-4337, the canonical recommendation is that `validateUserOp` should
return a failure value rather than revert for invalid inputs. However, the
ERC-4337 spec also states that a revert in `validateUserOp` is treated as
validation failure by the EntryPoint. In the OmniEntryPoint implementation, the
revert propagates up through `_validateAccountSig` (line 417), through
`_handleSingleOp` (line 249), and is caught by the `try/catch` in `handleOps`
(line 218). The UserOp is rejected and the nonce is not consumed.

**Impact:**

1. **Bundler griefing:** A session key holder can craft UserOps that pass
   signature verification but revert during calldata decoding. The bundler
   pays gas for the validation attempt but receives no compensation (gas
   accounting is skipped on revert). Repeated submissions can drain bundler
   gas.

2. **Nonce non-consumption:** The nonce is rolled back on revert, so the
   same malformed UserOp can be resubmitted indefinitely. A well-behaved
   bundler will blacklist the sender after repeated failures, but a naive
   bundler could be griefed.

3. **Deviation from ERC-4337 best practice:** The canonical EntryPoint
   expects `validateUserOp` to return failure codes, not revert, for
   "soft" failures like invalid calldata format.

**Recommendation:**

Wrap the `abi.decode` in a try/catch or use a low-level approach:

```solidity
function _validateSessionKeyCallData(
    bytes calldata callData,
    SessionKey storage sk
) internal view returns (bool valid) {
    if (callData.length < 100) return false;

    bytes4 selector = bytes4(callData[:4]);
    if (selector != bytes4(keccak256("execute(address,uint256,bytes)"))) {
        return false;
    }

    // Decode only the fixed-size parameters to avoid revert on
    // malformed bytes encoding. We only need target and value.
    address target = address(uint160(uint256(bytes32(callData[4:36]))));
    uint256 value = uint256(bytes32(callData[36:68]));

    if (sk.allowedTarget != address(0) && target != sk.allowedTarget) {
        return false;
    }

    if (sk.maxValue == 0 && value > 0) return false;
    if (sk.maxValue > 0 && value > sk.maxValue) return false;

    return true;
}
```

This avoids `abi.decode` entirely for the `bytes` parameter (which is not
needed for validation) and cannot revert on malformed data since we only
read fixed-position slots.

---

## Low Findings

### [L-01] NatSpec on RECOVERY_DELAY Constant Describes Recovery Threshold Instead of Delay

**Severity:** Low
**Lines:** 88-90
**Category:** Documentation / Maintainability

**Description:**

The NatSpec comment on the `RECOVERY_DELAY` constant describes the recovery
**threshold** formula instead of the time delay:

```solidity
/// @notice Recovery threshold: requires ceil(guardians / 2) + 1 approvals
/// @dev For 3 guardians = 2 approvals, 5 guardians = 3 approvals, 7 guardians = 4 approvals
uint256 internal constant RECOVERY_DELAY = 2 days;
```

The comment about threshold calculation belongs on the `recoveryThreshold()`
function (line 737), not on the `RECOVERY_DELAY` constant. This constant
represents the mandatory waiting period between recovery initiation and
execution.

**Impact:** Misleading documentation could cause a developer to misunderstand the
purpose of the constant, potentially leading to incorrect usage in future
modifications.

**Recommendation:**

```solidity
/// @notice Time delay between recovery initiation and execution
/// @dev Gives the legitimate owner a 2-day window to detect and
///      cancel malicious recovery attempts via cancelRecovery().
uint256 internal constant RECOVERY_DELAY = 2 days;
```

---

### [L-02] Owner Can Be Set as Session Key Signer, Wasting a Session Key Slot

**Severity:** Low
**Lines:** 621-653
**Category:** Input Validation

**Description:**

`addSessionKey` does not prevent the `owner` address from being registered as a
session key signer. If `owner == signer`, the session key is effectively unused:
`validateUserOp` matches the owner check first (line 354) and returns
`SIG_VALIDATION_SUCCEEDED` without ever reaching the session key path (line
359). The session key entry occupies a slot in `sessionKeyList` (capped at
`MAX_SESSION_KEYS = 10`) but provides no additional functionality.

Similarly, there is no check preventing a guardian address from being used as a
session key signer. While not a vulnerability (guardians cannot sign UserOps
unless they are also a session key), it could indicate a configuration mistake.

**Impact:** Wasted session key slot. Potential confusion for the owner who
expects time-range or target constraints to apply when signing as the owner
(they do not -- the owner always gets `SIG_VALIDATION_SUCCEEDED` with no
constraints).

**Recommendation:**

```solidity
if (signer == owner) revert InvalidAddress();
```

Consider also checking `isGuardian[signer]` as a warning, though this is less
critical.

---

## Informational Findings

### [I-01] onlyOwner Self-Call Allowance Is the Root Enabler of C-01

**Severity:** Informational
**Lines:** 281-286

The `onlyOwner` modifier allows `msg.sender == address(this)`:

```solidity
modifier onlyOwner() {
    if (msg.sender != owner && msg.sender != address(this)) {
        revert OnlyOwner();
    }
    _;
}
```

This is intentional for ERC-4337 composability (the owner manages the account
through UserOps that call `execute(address(this), 0, managementCalldata)`).
However, this design decision creates the attack surface exploited by C-01.

After C-01 is fixed (by blocking `address(this)` as a session key target), the
self-call allowance remains important for owner-initiated management. The owner
can still use self-calls because the owner signature returns
`SIG_VALIDATION_SUCCEEDED` (which has no target restriction -- only session keys
go through `_validateSessionKeyCallData`).

**Assessment:** The self-call allowance in `onlyOwner` is correct for the
owner path. The fix for C-01 should be in session key validation, not in the
modifier itself.

---

### [I-02] EntryPoint Address as Session Key Target Not Explicitly Blocked

**Severity:** Informational
**Lines:** 822-852

In addition to `address(this)` (C-01), a session key could target the
EntryPoint contract. For example:

```solidity
execute(entryPoint, someValue, abi.encodeCall(EntryPoint.withdrawTo, (attacker, amount)))
```

This would allow a session key to withdraw the account's deposit from the
EntryPoint, potentially interfering with gas accounting.

Currently this is mitigated by:
1. `maxValue = 0` prevents sending native value to the EntryPoint for deposits
2. The `withdrawTo` call requires `msg.sender` to match the depositor (the
   account), which is satisfied when called via `execute`

However, the practical impact is limited because EntryPoint deposits are
typically managed by the paymaster on OmniCoin L1 (gasless chain).

**Assessment:** Low practical risk on OmniCoin L1. Consider adding `entryPoint`
to the blocked targets list alongside `address(this)` in the C-01 fix for
defense in depth.

---

### [I-03] Session Key Replacement Still Does Not Emit SessionKeyRevoked Event

**Severity:** Informational
**Lines:** 638-641

Carried forward from R6 I-03. When `addSessionKey` is called for a signer that
is already active, the old session key parameters are silently overwritten
without emitting `SessionKeyRevoked`. Only `SessionKeyAdded` is emitted.

Off-chain monitoring systems see a new `SessionKeyAdded` event but cannot
distinguish between a new key and a replacement without querying the previous
state.

**Assessment:** Minor observability gap. Consider emitting
`SessionKeyRevoked(signer)` before the replacement:

```solidity
if (sessionKeys[signer].active) {
    emit SessionKeyRevoked(signer);
}
```

---

### [I-04] ERC-20 Spending Limit Coverage Gaps (transferFrom, permit)

**Severity:** Informational
**Lines:** 783-795

Carried forward from R6 I-02. The `_checkERC20SpendingLimit` function only
recognizes `transfer(address,uint256)` (0xa9059cbb) and
`approve(address,uint256)` (0x095ea7b3). Other token-moving functions are not
covered:

- `transferFrom(address,address,uint256)` -- 0x23b872dd
- `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` -- 0xd505accf
- Custom functions (e.g., `send`, `burn`)

For `transferFrom`, the account would need a prior `approve` (which IS tracked).
For `permit`, the session key could grant a third-party allowance without
spending limit enforcement, then that third party could call `transferFrom`
separately. However, this requires a multi-step attack and the `approve` check
provides some defense.

**Assessment:** Acceptable for production. The two most common value-transfer
selectors are covered. Adding `transferFrom` coverage would improve defense in
depth but is not critical.

---

## Detailed Code Review

### Constructor and Initialization (Lines 300-320)

Correctly implemented:
- Constructor validates `entryPoint_` non-zero and calls `_disableInitializers()`
- `initialize()` uses `initializer` modifier and validates `owner_` non-zero
- No constructors in inherited ReentrancyGuard that could conflict

**Assessment:** Sound.

### Signature Validation -- validateUserOp (Lines 336-375)

The validation logic correctly:
1. Restricts to `onlyEntryPoint` (line 340)
2. Pays prefund via plain ETH transfer (lines 342-347); failure is intentionally
   ignored per ERC-4337 (EntryPoint enforces deposit sufficiency)
3. Recovers signer using `ECDSA.recover(ethHash, userOp.signature)` with
   `toEthSignedMessageHash` prefix (lines 350-351)
4. Returns `SIG_VALIDATION_SUCCEEDED` (0) for owner (lines 354-355)
5. For session keys: validates constraints (line 362), packs `validUntil` and
   `validAfter` (lines 370-371)
6. Returns `SIG_VALIDATION_FAILED` (1) for unknown signers (line 374)

**Validation data packing verification:**
```solidity
return (uint256(sk.validUntil) << 160)
    | (uint256(sk.validAfter) << 208);
```
- Bits 0-159: 0 (no aggregator) -- correct
- Bits 160-207: validUntil (uint48) -- correct
- Bits 208-255: validAfter (uint48) -- correct

The EntryPoint's `_extractSigResult` correctly extracts and validates both
fields via `uint48(validationData >> 160)` and `uint48(validationData >> 208)`.

**Assessment:** ERC-4337 compliant. Signature handling is sound.

### Execution (Lines 389-453)

**execute()** (lines 389-412):
- `onlyOwnerOrEntryPoint` + `nonReentrant` access control
- Spending limit enforcement for EntryPoint calls: native value (line 399) and
  ERC-20 transfer/approve (line 403)
- Low-level `.call{value}(data)` with revert propagation and event emission

**executeBatch()** (lines 424-453):
- Same access control pattern
- Array length validation (line 430)
- Per-call spending limit enforcement for EntryPoint calls (lines 436-445)
- Sequential execution with atomic revert

Both functions correctly separate owner calls (unrestricted) from EntryPoint
calls (spending-limit-enforced). The `nonReentrant` guard prevents reentrancy
into `execute` or `executeBatch`, though it does not prevent calls to other
functions on `address(this)` (the root cause of C-01).

**Assessment:** Execution logic is sound. Spending limits are correctly enforced
in both paths. C-01 is a validation-layer issue, not an execution-layer issue.

### Guardian Management (Lines 473-524)

Well-implemented:
- `addGuardian`: Recovery freeze check (line 478), zero address check (line 481),
  duplicate check (line 482), max count check (line 483)
- `removeGuardian`: Recovery freeze check (line 499), existence check (line 502),
  defense-in-depth approval cleanup (lines 507-512), swap-and-pop removal
  (lines 514-523)

The `GuardiansFrozenDuringRecovery` revert in both functions prevents the owner
from manipulating the guardian set during active recovery.

**Assessment:** Sound.

### Social Recovery (Lines 530-595)

The recovery flow is well-structured:
- `initiateRecovery` (line 535): Guardian-only, zero address check, single-active check
- `approveRecovery` (line 552): Guardian-only, double-approval prevention,
  emits `RecoveryApproved` event
- `executeRecovery` (line 568): Permissionless (enables relayed execution),
  threshold check, 2-day delay check
- `cancelRecovery` (line 591): Owner-only, clears all state

The threshold formula `(count / 2) + 1`:
- 1 guardian: 1 approval (sole guardian)
- 2 guardians: 2 approvals (both required)
- 3 guardians: 2 approvals (2-of-3)
- 5 guardians: 3 approvals (3-of-5)
- 7 guardians: 4 approvals (4-of-7)

`_clearRecovery` (lines 802-811) iterates current guardians to clear approvals,
resets all struct fields. Guardian approval mappings for removed guardians may
retain stale `true` values, but these are harmless because `initiatedAt` is
reset to 0 (so `approveRecovery` reverts with `NoActiveRecovery`) and new
recovery rounds start fresh.

**Assessment:** Sound.

### Session Keys (Lines 600-673)

**addSessionKey** (lines 621-653):
- Zero address check for signer (line 628)
- Past expiration check: rejects `validUntil != 0 && validUntil < block.timestamp` (lines 631-633)
- Max session keys check (line 634)
- Replacement handling without list duplication (lines 639-641)
- Includes `validAfter` parameter

**revokeSessionKey** (lines 659-673):
- Sets `active = false` and removes from list via swap-and-pop

**_validateSessionKeyCallData** (lines 822-852):
- Restricts to `execute(address,uint256,bytes)` selector (line 832)
- Decodes target and value from calldata (lines 837-840)
- Validates `allowedTarget` and `maxValue` constraints (lines 843-849)
- **DOES NOT block `address(this)` as target** (C-01)

**Assessment:** Session key creation and revocation are sound. Validation has the
critical self-call bypass (C-01).

### Spending Limits (Lines 675-795)

Fully functional:
- `setSpendingLimit` (line 684): Owner-only, resets period, sets new limit
- `_checkAndUpdateSpendingLimit` (lines 755-773): Daily reset at midnight UTC,
  accumulates `spentToday`, reverts on excess
- `_checkERC20SpendingLimit` (lines 783-795): Decodes transfer/approve calldata
- `remainingSpendingLimit` (lines 716-727): View function for remaining allowance
- `_nextMidnight` (lines 858-861): UTC midnight boundary calculation

The `limit.resetTime - 1` pattern at lines 764 and 721 is safe because
`resetTime` is only accessed when `dailyLimit > 0`, which means `setSpendingLimit`
was called (which always sets `resetTime` via `_nextMidnight`). There is no
codepath where `resetTime == 0` and `dailyLimit > 0`.

**Assessment:** Sound. Arithmetic is checked (Solidity 0.8.25). No
overflow/underflow risks.

---

## ERC-4337 Compliance Assessment

| Requirement | Status | Notes |
|-------------|--------|-------|
| `validateUserOp` interface | PASS | Correct signature and return type |
| Signature validation (ECDSA) | PASS | OZ ECDSA with EIP-191 prefix |
| Nonce management | PASS | Delegated to EntryPoint |
| Prefund payment | PASS | Sends `missingAccountFunds` via plain ETH transfer |
| `validUntil` packing | PASS | Bits 160-207, correct for session keys |
| `validAfter` packing | PASS | Bits 208-255, correct for session keys |
| Aggregator support | N/A | Not needed for ECDSA-only |
| Receive native tokens | PASS | `receive() external payable` present |
| Initializable (for clones) | PASS | OZ `Initializable` + `_disableInitializers()` |
| No revert on soft failure | **PARTIAL** | `abi.decode` can revert on malformed calldata (M-01) |

---

## Attack Surface Analysis

### Attack 1: Session Key Privilege Escalation via Self-Call [C-01]

**Scenario:** Attacker with a session key (`allowedTarget = address(0)`) crafts a
UserOp targeting `address(this)` to call `transferOwnership`.

**Chain:** SessionKey sign -> validateUserOp(pass) -> execute(address(this)) ->
self-call transferOwnership -> onlyOwner passes (msg.sender == address(this))

**Assessment:** **EXPLOITABLE.** Full account takeover. See C-01 for details.

### Attack 2: Session Key Escalation to executeBatch

**Scenario:** Attacker with a session key attempts to use `executeBatch` instead
of `execute`.

**Mitigations:**
- `_validateSessionKeyCallData` restricts to `execute()` selector only (line 832)
- Any other selector returns `SIG_VALIDATION_FAILED`

**Assessment:** **Mitigated.**

### Attack 3: Reentrancy During Execution

**Scenario:** A called contract reenters `execute` or `executeBatch`.

**Mitigations:**
- `nonReentrant` on both functions (OZ ReentrancyGuard)

**Assessment:** **Mitigated** for reentry into `execute`/`executeBatch`. Does NOT
prevent self-calls to non-reentrant-guarded functions (C-01 exploits this gap).

### Attack 4: Guardian Collusion for Hostile Recovery

**Scenario:** Majority of guardians collude to steal the account.

**Mitigations:**
- 2-day delay for owner to detect and cancel
- Guardian management frozen during recovery
- RecoveryApproved event for off-chain monitoring

**Assessment:** **Mitigated by design.**

### Attack 5: Cross-Chain UserOp Replay

**Scenario:** Replay a UserOp from OmniCoin L1 on another chain.

**Mitigations:**
- UserOp hash includes `chainid` and EntryPoint address
- `entryPoint` is immutable per OmniAccount instance

**Assessment:** **Mitigated.**

### Attack 6: Bundler Griefing via Malformed callData [M-01]

**Scenario:** Session key holder submits UserOps with valid signatures but
malformed calldata encoding that causes `abi.decode` to revert.

**Mitigations:**
- EntryPoint's try/catch handles the revert
- Nonce is not consumed (revert rolls back)
- Bundler loses gas for validation

**Assessment:** **Low-impact griefing.** Bundlers should implement sender
reputation to mitigate.

### Attack 7: Spending Limit Reset Manipulation

**Scenario:** Validator manipulates `block.timestamp` to reset spending limits.

**Mitigations:**
- Snowman consensus enforces monotonic, bounded timestamps
- Manipulation window is seconds, not hours

**Assessment:** **Mitigated by consensus.**

---

## Role Mapping

| Role | Access Control | Capabilities |
|------|---------------|--------------|
| **Owner** | Direct call or `address(this)` self-call | All management: transferOwnership, guardians, session keys, spending limits, recovery cancel, execute, executeBatch |
| **EntryPoint** | `onlyEntryPoint` for validateUserOp; `onlyOwnerOrEntryPoint` for execute/executeBatch | Trigger validation and execution on behalf of owner/session keys |
| **Session Key** | Via EntryPoint -> validateUserOp -> execute | Scoped execute only (target + value + time constraints). **C-01: currently can escalate to owner via self-call** |
| **Guardian** | `onlyGuardianRole` | Initiate recovery, approve recovery |
| **Anyone** | No restriction | Execute recovery (after threshold + delay), receive() |

---

## Gas Analysis

| Function | Estimated Gas | Notes |
|----------|--------------|-------|
| `initialize` | ~46,000 | One-time, called by factory |
| `execute` (ETH transfer) | ~35,000 | Base + spending limit check |
| `execute` (ERC-20 transfer) | ~55,000 | Base + selector decode + spending check |
| `executeBatch` (2 calls) | ~70,000 | Per-call spending limit overhead |
| `addGuardian` | ~65,000 | Array push + mapping write |
| `removeGuardian` | ~35,000 | Swap-pop + mapping clear |
| `initiateRecovery` | ~55,000 | Struct writes + mapping |
| `approveRecovery` | ~30,000 | Mapping + counter + event |
| `executeRecovery` | ~40,000 | Ownership transfer + clear loop |
| `addSessionKey` | ~70,000 | Struct write + conditional push |
| `validateUserOp` (owner) | ~8,000 | ECDSA recover + comparison |
| `validateUserOp` (session key) | ~15,000 | ECDSA recover + constraint validation |

Bounded arrays (MAX_GUARDIANS=7, MAX_SESSION_KEYS=10) prevent gas DoS.

---

## Summary of Recommendations

| # | Finding | Severity | Action Required |
|---|---------|----------|-----------------|
| 1 | C-01: Session key privilege escalation via self-call | Critical | **Block `address(this)` as target in `_validateSessionKeyCallData`; also reject in `addSessionKey` for defense in depth** |
| 2 | M-01: Malformed calldata causes validateUserOp revert | Medium | Replace `abi.decode` with manual fixed-slot reads (`bytes32` slicing) to avoid revert on malformed bytes encoding |
| 3 | L-01: RECOVERY_DELAY NatSpec describes threshold | Low | Fix the comment to describe the 2-day delay purpose |
| 4 | L-02: Owner address can be registered as session key | Low | Add `if (signer == owner) revert InvalidAddress()` check |
| 5 | I-01: onlyOwner self-call is root enabler of C-01 | Info | No action on modifier; fix C-01 in session key validation |
| 6 | I-02: EntryPoint address not blocked as session key target | Info | Consider adding `entryPoint` to blocked targets for defense in depth |
| 7 | I-03: Session key replacement does not emit revoked event | Info | Emit `SessionKeyRevoked` before overwriting |
| 8 | I-04: ERC-20 spending limit gaps (transferFrom, permit) | Info | Consider adding `transferFrom` selector coverage |

---

## Conclusion

OmniAccount has been progressively hardened through four audit rounds, with all
prior Critical, High, and Medium findings remediated. However, this Round 7
audit identifies a **new Critical vulnerability (C-01)** that was not caught in
previous rounds: session key privilege escalation via self-call.

The vulnerability exists because:
1. The `onlyOwner` modifier intentionally allows `msg.sender == address(this)`
   for ERC-4337 composability (flagged as I-01 in R6 but considered acceptable).
2. Session key validation (`_validateSessionKeyCallData`) does not exclude
   `address(this)` as a call target.
3. A session key can therefore route calls through `execute(address(this), 0,
   managementFunctionCalldata)` to invoke any owner-only function.

**This vulnerability must be fixed before mainnet deployment.** The fix is
straightforward: add `if (target == address(this)) return false;` to
`_validateSessionKeyCallData`. This blocks session keys from self-calling while
preserving the owner's ability to manage the account through UserOps (the owner
path returns `SIG_VALIDATION_SUCCEEDED` before reaching session key validation).

The M-01 finding (malformed calldata causing revert) is a lower-priority
improvement for ERC-4337 spec compliance and bundler robustness.

**Overall Risk Assessment: HIGH** -- the C-01 finding elevates risk above the
deployment threshold. After C-01 remediation, risk returns to LOW.

---

*Report generated 2026-03-13 21:01 UTC*
*Methodology: 6-pass audit (static analysis, OWASP SC Top 10, ERC-4337 spec compliance, prior audit remediation verification, attack surface analysis, report generation)*
*Contract: OmniAccount.sol at 862 lines, Solidity 0.8.25*
