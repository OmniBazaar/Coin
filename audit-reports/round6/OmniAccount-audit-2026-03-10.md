# Security Audit Report: OmniAccount.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniAccount.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 853
**Upgradeable:** Yes (Initializable, deployed as ERC-1167 clones via OmniAccountFactory)
**Handles Funds:** Yes (smart wallet -- holds native tokens, interacts with ERC-20s, custodies user funds)
**Dependencies:** `ECDSA`, `MessageHashUtils` (OZ 5.x), `Initializable` (OZ), `ReentrancyGuard` (OZ), `IAccount` (custom)
**Previous Audits:** Suite audit (2026-02-21, 4C/4H/5M/4L), Round 3 (2026-02-26, 0C/0H/2M/2L/5I)

---

## Executive Summary

OmniAccount is the ERC-4337 smart wallet implementation serving as the primary user account on OmniCoin L1. It supports ECDSA signature validation, session keys with scoped permissions and time bounds, daily spending limits, guardian-based social recovery with a 2-day delay, and batch execution. It is deployed as ERC-1167 minimal proxy clones via OmniAccountFactory.

This Round 6 audit is a comprehensive pre-mainnet review. The contract has grown from 798 lines (Round 3) to 853 lines, primarily from the addition of the `validAfter` field to session keys (fixing R3 M-01) and spending limit enforcement in `executeBatch` (fixing R3 M-02). Both Round 3 Medium findings have been remediated. The Round 3 Low findings (missing `approveRecovery` event and past `validUntil` acceptance) have also been fixed.

**All prior findings are remediated.** This audit identifies one new Medium finding, two Low findings, and three Informational observations.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Session key with allowedTarget == address(0) and maxValue > 0 can transfer native tokens to any address | **FIXED** |

---

## Remediation Status from Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| Suite C-01: Session key constraints never enforced | Critical | **Fixed** | `_validateSessionKeyCallData()` (lines 813-843) validates selector, target, and value constraints. Confirmed working in R3. |
| Suite C-02: Spending limits dead code | Critical | **Fixed** | `execute()` (lines 396-405) and `executeBatch()` (lines 434-445) both enforce limits for EntryPoint calls. |
| Suite C-03: EntryPoint never deducts gas | Critical | **Fixed** | OmniEntryPoint now has `_deductGasCost`. |
| Suite C-04: Removed guardian approval persists | Critical | **Fixed** | `GuardiansFrozenDuringRecovery` check in both `addGuardian` and `removeGuardian`. Defense-in-depth cleanup in `removeGuardian` (lines 506-512). |
| Suite M-01: Owner blocks recovery by removing guardians | Medium | **Fixed** | Guardian freeze during recovery. |
| Suite M-02: No reentrancy guard | Medium | **Fixed** | `nonReentrant` on `execute` and `executeBatch`. |
| R3 M-01: Session key validAfter omitted | Medium | **Fixed** | `SessionKey` struct now includes `validAfter` field (line 40). `validateUserOp` packs both `validUntil` and `validAfter` into return data (lines 370-371). `addSessionKey` accepts `validAfter` parameter (line 615). |
| R3 M-02: executeBatch lacks spending limits | Medium | **Fixed** | `executeBatch` (lines 434-445) now enforces native and ERC-20 spending limits for EntryPoint calls, identical to `execute`. |
| R3 L-01: approveRecovery emits no event | Low | **Fixed** | `RecoveryApproved` event added (lines 176-179) and emitted in `approveRecovery` (lines 559-561). |
| R3 L-02: addSessionKey allows validUntil in past | Low | **Fixed** | `addSessionKey` (lines 621-624) now rejects `validUntil` values in the past (except 0, which means no expiry). `SessionKeyAlreadyExpired` error added. |
| R3 I-01: onlyOwner allows address(this) | Info | **Acknowledged** | Intentional design for ERC-4337 composability. Documented. |
| R3 I-02: approve() spending limit overly broad | Info | **Acknowledged** | Current approach (enforce on both transfer and approve) is the safer default. |
| R3 I-03: recoveryThreshold returns 0 with no guardians | Info | **Acknowledged** | Safe because `initiateRecovery` requires `onlyGuardianRole`. |
| R3 I-04: Unbounded array iteration | Info | **Acceptable** | Bounded by `MAX_GUARDIANS = 7` and `MAX_SESSION_KEYS = 10`. |
| R3 I-05: Prefund transfer failure silently ignored | Info | **Acceptable** | Per ERC-4337 spec, EntryPoint enforces deposit sufficiency. |

---

## Detailed Code Review

### Constructor and Initialization (Lines 300-320)

Correctly implemented:
- Constructor validates `entryPoint_` non-zero and calls `_disableInitializers()` to protect the implementation contract
- `initialize()` uses the `initializer` modifier (prevents re-initialization) and validates `owner_` non-zero

**Assessment:** Sound. Standard ERC-1167 clone initialization pattern.

### Signature Validation -- validateUserOp (Lines 336-375)

The validation logic correctly:
1. Restricts to `onlyEntryPoint` (line 340)
2. Pays prefund via plain ETH transfer (lines 342-347)
3. Recovers signer using `ECDSA.recover(ethHash, userOp.signature)` with `toEthSignedMessageHash` prefix (lines 350-351)
4. Returns `SIG_VALIDATION_SUCCEEDED` (0) for owner signature (lines 354-355)
5. For session keys: validates `sk.active && sk.signer == signer` (line 360), enforces call constraints via `_validateSessionKeyCallData` (line 362), and packs both `validUntil` and `validAfter` into return data (lines 370-371)
6. Returns `SIG_VALIDATION_FAILED` (1) for unknown signers (line 374)

**Session key time-range packing (new):**

```solidity
return (uint256(sk.validUntil) << 160)
    | (uint256(sk.validAfter) << 208);
```

Per ERC-4337 validation data format:
- Bits 0-159: aggregator (0 = none)
- Bits 160-207: validUntil (uint48)
- Bits 208-255: validAfter (uint48)

The packing is correct. `validUntil` occupies bits 160-207 (48 bits), and `validAfter` occupies bits 208-255 (48 bits). The lower 160 bits are 0 (no aggregator). The EntryPoint's `_extractSigResult` correctly extracts and validates both fields.

**Assessment:** Sound. ECDSA signature recovery, session key constraint validation, and time-range packing are all correct.

### Execution (Lines 389-453)

**execute()** (lines 389-412):
- `onlyOwnerOrEntryPoint` + `nonReentrant` access control
- Spending limit enforcement for EntryPoint calls: native value (line 399) and ERC-20 transfer/approve (line 403)
- Low-level `.call{value: value}(data)` execution with revert propagation
- Event emission

**executeBatch()** (lines 424-453):
- Same access control and reentrancy protection
- Array length validation
- **NEW:** Spending limit enforcement per call in the batch (lines 436-445)
- Sequential execution with revert on any failure

**Assessment:** Sound. Both functions enforce spending limits consistently for EntryPoint calls. The `nonReentrant` guard prevents reentrancy from called contracts.

### Guardian Management (Lines 473-524)

Well-implemented with all necessary checks:
- `addGuardian`: Recovery freeze check, zero address check, duplicate check, max count check (MAX_GUARDIANS = 7)
- `removeGuardian`: Recovery freeze check, existence check, defense-in-depth approval cleanup, swap-and-pop array removal

**Assessment:** Sound. The `GuardiansFrozenDuringRecovery` check prevents the owner from manipulating guardians during an active recovery.

### Social Recovery (Lines 530-595)

The recovery flow is well-structured:
- `initiateRecovery`: Guardian-only, zero address check, single-active-recovery check
- `approveRecovery`: Guardian-only, double-approval prevention, **now emits RecoveryApproved event**
- `executeRecovery`: Anyone can call (enables relayed execution), checks threshold and 2-day delay
- `cancelRecovery`: Owner-only

The threshold formula `(count / 2) + 1` provides correct majority requirements:
- 1 guardian: 1 approval, 2 guardians: 2 approvals, 3 guardians: 2 approvals, 5 guardians: 3 approvals, 7 guardians: 4 approvals

**Assessment:** Sound.

### Session Keys (Lines 600-664)

**addSessionKey** (lines 612-644):
- Zero address check for signer
- **NEW:** Rejects `validUntil` in the past (lines 621-624), except 0 (no expiry)
- Max session keys check (MAX_SESSION_KEYS = 10)
- Handles replacement without list duplication (line 630)
- Includes `validAfter` parameter (line 615)

**revokeSessionKey** (lines 650-664):
- Sets `active = false` and removes from list via swap-and-pop

**_validateSessionKeyCallData** (lines 813-843):
- Restricts to `execute(address,uint256,bytes)` selector only
- Decodes target and value from calldata
- Validates `allowedTarget` and `maxValue` constraints

**Assessment:** Sound. Session keys are properly scoped with time bounds, target restrictions, and value limits.

### Spending Limits (Lines 670-786)

The spending limit system is fully functional:
- `setSpendingLimit`: Owner-only, resets period and sets new limit
- `_checkAndUpdateSpendingLimit`: Enforces with daily reset at midnight UTC
- `_checkERC20SpendingLimit`: Decodes transfer/approve calldata
- `remainingSpendingLimit`: View function for remaining allowance
- `_nextMidnight`: UTC midnight boundary calculation

**Assessment:** Sound.

---

## Medium Findings

### [M-01] Session Key with allowedTarget == address(0) and maxValue > 0 Can Transfer Native Tokens to Any Address

**Severity:** Medium
**Lines:** 613-644 (`addSessionKey`), 833-841 (`_validateSessionKeyCallData`)
**Category:** Access Control / Session Key Scope

**Description:**

When a session key is created with `allowedTarget = address(0)` (meaning "any target is allowed") and `maxValue > 0`, the session key can call `execute(target, value, data)` with any `target` and any `value` up to `maxValue`. This effectively allows the session key to transfer native tokens to any arbitrary address.

The validation logic at lines 833-841:

```solidity
// Validate target constraint (address(0) means any target is allowed)
if (sk.allowedTarget != address(0) && target != sk.allowedTarget) {
    return false;
}

// Validate value constraint (maxValue == 0 means no native transfers allowed)
if (sk.maxValue == 0 && value > 0) return false;
if (sk.maxValue > 0 && value > sk.maxValue) return false;
```

This means a session key with `allowedTarget = 0` and `maxValue = 1 ether` can:
1. Call `execute(attackerAddress, 1 ether, "")` -- sends 1 ETH to attacker
2. Repeat up to the spending limit (if set) or indefinitely (if no spending limit)

The spending limit (enforced in `execute` for EntryPoint calls) provides some protection, but:
- If no spending limit is set (`dailyLimit == 0`), the session key can drain the account up to `maxValue` per call with no daily cap.
- If a spending limit IS set, the session key is constrained to `min(maxValue, dailyLimit)` per day.

The issue is that `allowedTarget = address(0)` combined with `maxValue > 0` is an extremely broad permission. The owner may intend "this session key can interact with any dApp" without realizing it also means "this session key can send native tokens to any address."

**Impact:** A compromised session key with `allowedTarget = 0` and `maxValue > 0` can drain native tokens from the account (up to spending limits). The owner may not realize the breadth of this permission when creating the session key.

**Recommendation:**

1. **Documentation:** Add NatSpec warnings to `addSessionKey` clarifying that `allowedTarget = address(0)` with `maxValue > 0` grants the ability to transfer native tokens to any address.

2. **Consider splitting permissions:** Separate "allowed to interact with any contract" from "allowed to send native value." A session key could have `allowedTarget = address(0)` (any contract) with `maxValue = 0` (no native transfers), which allows calling any contract but not transferring ETH. This is already supported -- the documentation should make this the recommended pattern.

3. **Optional: Require explicit opt-in for wildcard + value.** If both `allowedTarget == address(0)` and `maxValue > 0`, require the owner to pass an additional flag confirming they understand the risks. This adds friction but prevents accidental over-permissioning.

---

## Low Findings

### [L-01] Recovery Can Be Executed by Anyone After Conditions Are Met

**Severity:** Low
**Lines:** 568-585 (`executeRecovery`)
**Category:** Access Control / Griefing

**Description:**

`executeRecovery()` has no access restriction -- anyone can call it once the threshold and delay conditions are met:

```solidity
function executeRecovery() external {
    if (recoveryRequest.initiatedAt == 0) revert NoActiveRecovery();
    if (recoveryRequest.approvalCount < recoveryThreshold()) {
        revert NoActiveRecovery();
    }
    if (block.timestamp < recoveryRequest.initiatedAt + RECOVERY_DELAY) {
        revert RecoveryDelayNotMet();
    }
    // ... transfers ownership
}
```

This is intentional -- it allows guardians or relayers to execute the recovery without requiring the new owner to have gas. However, it also means:

1. A front-runner can call `executeRecovery` before the guardian, claiming the `RecoveryCompleted` event attribution.
2. An automated bot could monitor recovery requests and execute them the moment the delay expires, even if the guardians want to wait longer.

Neither scenario changes the outcome (the new owner is always `recoveryRequest.newOwner`), but the immediate execution may be undesirable if guardians are still deliberating.

**Impact:** No direct security impact. The new owner is always the address specified in the recovery request. The griefing is limited to timing and event attribution.

**Recommendation:** This is an acceptable design for gasless execution. Consider adding a NatSpec comment explaining the deliberate permissionless design:

```solidity
/// @dev Callable by anyone -- enables relayed/gasless execution.
///      The outcome is deterministic (newOwner is fixed when initiated).
```

---

### [L-02] Spending Limit Reset Uses block.timestamp Which Can Be Manipulated by Validators

**Severity:** Low
**Lines:** 754-758 (`_checkAndUpdateSpendingLimit`), 849-851 (`_nextMidnight`)
**Category:** Timestamp Dependence

**Description:**

The spending limit daily reset relies on `block.timestamp`:

```solidity
if (block.timestamp > limit.resetTime - 1) {
    limit.spentToday = 0;
    limit.resetTime = _nextMidnight();
}
```

On OmniCoin L1 (Avalanche Subnet-EVM with Snowman consensus), block timestamps are set by the block producer. A malicious validator could:
1. Set the block timestamp far in the future, resetting the spending limit prematurely.
2. Set the block timestamp in the past, preventing the reset from occurring.

However, Snowman consensus enforces that block timestamps must be monotonically increasing and within reasonable bounds of wall-clock time. The practical manipulation window is typically a few seconds, which is insufficient to meaningfully affect daily spending limits.

**Impact:** Negligible on Avalanche Subnet-EVM due to consensus timestamp constraints. Noted for completeness.

**Recommendation:** No code change needed. This is a fundamental limitation of on-chain time tracking and is acceptable for daily granularity.

---

## Informational Findings

### [I-01] onlyOwner Modifier Allows Self-Calls -- Documented and Intentional

**Severity:** Informational
**Lines:** 281-286

The `onlyOwner` modifier permits `msg.sender == address(this)`:

```solidity
modifier onlyOwner() {
    if (msg.sender != owner && msg.sender != address(this)) {
        revert OnlyOwner();
    }
    _;
}
```

This enables the owner to manage the account through UserOps (the owner signs a UserOp that calls `execute(address(this), 0, abi.encodeCall(addGuardian, (newGuardian)))`). This is standard ERC-4337 composability and is documented.

A compromised owner key can use this to perform all management operations in a single batch transaction (remove guardians, add attacker session keys, cancel recovery, transfer ownership). This is inherent to single-key ownership and is the threat model that social recovery addresses.

**Assessment:** Acceptable. Documented.

---

### [I-02] ERC-20 Spending Limit Does Not Cover transferFrom or Other Token Functions

**Severity:** Informational
**Lines:** 774-786 (`_checkERC20SpendingLimit`)

The spending limit enforcement only recognizes `transfer(address,uint256)` and `approve(address,uint256)` selectors. Other ERC-20 functions that move tokens are not covered:
- `transferFrom(address,address,uint256)` -- if the session key calls `transferFrom` on a token where the account has approved itself, spending limits are bypassed.
- Custom token functions (e.g., `send`, `burn`, `permit`)

However, for `transferFrom` to work, the account would need a prior approval, which itself is subject to the `approve` spending limit check. This creates a two-step defense. Custom functions are uncommon and would require the session key to know the specific selector.

**Assessment:** Acceptable for production. The two most common value-transfer selectors are covered.

---

### [I-03] Session Key Replacement Does Not Emit SessionKeyRevoked Event

**Severity:** Informational
**Lines:** 630-641 (`addSessionKey`)

When a session key is replaced (same signer address, `sk.active == true`), the function overwrites the struct without emitting a `SessionKeyRevoked` event for the old key. Only `SessionKeyAdded` is emitted. Off-chain monitoring systems would see the updated key without knowing the old one was replaced.

**Recommendation:** Consider emitting `SessionKeyRevoked(signer)` before the replacement if the key was previously active.

---

## Attack Surface Analysis

### Attack 1: Signature Forgery / Account Takeover

**Scenario:** Attacker forges an ECDSA signature to pass `validateUserOp`.

**Mitigations:**
- OpenZeppelin's `ECDSA.recover` handles ecrecover edge cases (malleable signatures, zero address recovery)
- `toEthSignedMessageHash` prefix prevents raw hash signing attacks
- The UserOp hash includes `chainid` and EntryPoint address (from EntryPoint)

**Assessment:** **Mitigated.** ECDSA signature forgery requires the private key.

### Attack 2: Session Key Escalation to Owner Privileges

**Scenario:** Attacker with a session key tries to call `transferOwnership`, `addGuardian`, or other management functions.

**Mitigations:**
- `_validateSessionKeyCallData` restricts session keys to the `execute(address,uint256,bytes)` selector only (line 823)
- `executeBatch` is not allowed for session keys
- Target and value constraints are enforced

**Assessment:** **Mitigated.** A session key can only call `execute` with validated parameters. Management functions require owner signature.

### Attack 3: Reentrancy in execute/executeBatch

**Scenario:** A called contract reenters `execute` or `executeBatch` during execution.

**Mitigations:**
- Both functions have `nonReentrant` modifier
- OpenZeppelin's `ReentrancyGuard` prevents nested calls

**Assessment:** **Mitigated.** Reentrancy is prevented by the guard.

### Attack 4: Guardian Collusion / Hostile Recovery

**Scenario:** A majority of guardians collude to steal the account.

**Mitigations:**
- 2-day delay allows the owner to detect and cancel (`cancelRecovery`)
- Guardian management is frozen during recovery
- Maximum 7 guardians, threshold requires `(count/2) + 1`

**Assessment:** **Mitigated by design.** The 2-day delay is the primary defense. Off-chain monitoring (RecoveryApproved event) enables automated alerts.

### Attack 5: Cross-Chain Replay

**Scenario:** Replay a UserOp from OmniCoin L1 on another chain.

**Mitigations:**
- UserOp hash includes `chainid` and EntryPoint address (in EntryPoint)
- The `entryPoint` is immutable per OmniAccount instance

**Assessment:** **Mitigated.**

---

## ERC-4337 Compliance Assessment

| Requirement | Status | Notes |
|-------------|--------|-------|
| `validateUserOp` interface | PASS | Correct signature and return type |
| Signature validation (ECDSA) | PASS | OZ ECDSA with EIP-191 prefix |
| Nonce management | PASS | Delegated to EntryPoint |
| Prefund payment | PASS | Sends missingAccountFunds via plain ETH transfer |
| `validUntil` packing | PASS | Bits 160-207, correct for session keys |
| `validAfter` packing | PASS | Bits 208-255, now included (R3 M-01 fix) |
| Aggregator support | N/A | Not needed for ECDSA-only |
| Receive native tokens | PASS | `receive() external payable` present |
| Initializable (for clones) | PASS | OZ `Initializable` + `_disableInitializers()` in constructor |

---

## Summary of Recommendations

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | M-01 | Medium | Document that `allowedTarget=0` + `maxValue>0` enables native transfers to any address; recommend `maxValue=0` for general dApp session keys |
| 2 | L-01 | Low | Add NatSpec documenting the intentionally permissionless `executeRecovery` |
| 3 | L-02 | Low | No code change; timestamp manipulation is constrained by consensus |
| 4 | I-01 | Info | No action; documented and intentional |
| 5 | I-02 | Info | No action; transfer + approve coverage is sufficient |
| 6 | I-03 | Info | Consider emitting `SessionKeyRevoked` on replacement |

---

## Conclusion

OmniAccount has reached a mature and well-hardened state through three rounds of audit and remediation. All four Critical findings from the original suite audit and both Medium findings from Round 3 have been properly remediated:

- **Session key constraints** are enforced with target, value, and now time-range (`validAfter`) restrictions
- **Spending limits** are enforced in both `execute` and `executeBatch` for EntryPoint calls
- **Guardian management** is frozen during active recovery
- **Recovery approvals** now emit events for off-chain monitoring
- **Session key expiration** is validated on creation

The single remaining Medium finding (M-01) is a documentation/design issue: wildcard session keys (`allowedTarget = 0`) with native value permissions (`maxValue > 0`) grant broader access than the owner may intend. This is not a vulnerability -- it is working as designed -- but the permission model should be clearly documented.

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1. The contract provides comprehensive smart wallet functionality with proper security controls across all feature areas.

---

*Report generated 2026-03-10*
*Methodology: 6-pass audit (static analysis, OWASP SC Top 10, ERC-4337 spec compliance, prior audit remediation verification, attack surface analysis, report generation)*
*Contract: OmniAccount.sol at 853 lines, Solidity 0.8.25*
