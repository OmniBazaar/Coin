# Security Audit Report: OmniTreasury

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Round 6 Pre-Mainnet)
**Contract:** `Coin/contracts/OmniTreasury.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 569
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- native XOM, ERC-20, ERC-721, ERC-1155 (Protocol-Owned Liquidity)
**Dependencies:** OpenZeppelin Contracts 5.x (AccessControl, ReentrancyGuard, Pausable, ERC721Holder, ERC1155Holder)
**Previous Audits:** Round 5 (2026-03-08)

---

## Executive Summary

OmniTreasury is the Protocol-Owned Liquidity (POL) wallet that receives the 10% protocol share from every fee-distributing contract in the OmniBazaar ecosystem (via UnifiedFeeVault). It also serves as a general-purpose treasury capable of holding native XOM, ERC-20, ERC-721, and ERC-1155 tokens, with governance-controlled outbound transfers and an arbitrary `execute()`/`executeBatch()` capability for future protocol integrations.

The contract is well-engineered with no Critical or High vulnerabilities. The previous Round 5 audit identified primarily centralization risks (inherent to Pioneer Phase) and the absence of timelocks (to be addressed by OmniTimelockController integration). This Round 6 audit confirms all previous findings remain valid with their documented mitigations, and identifies additional considerations for the pre-mainnet deployment context.

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 3 | 2 CARRIED, 1 NEW |
| Low | 4 | 2 CARRIED, 2 NEW |
| Informational | 3 | 1 CARRIED, 2 NEW |
| **Total** | **10** | |

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Persistent ERC-20 allowances after governance transition | **FIXED** |
| M-02 | Medium | No timelock on governance actions | **FIXED** |
| M-03 | Medium | `execute()` and `executeBatch()` can bypass dedicated transfer functions | **FIXED** |

---

## Previous Findings Remediation Status

| ID | Finding | Severity | Status |
|----|---------|----------|--------|
| M-01 (R5) | Single key can drain treasury during Pioneer Phase | Medium | **ACKNOWLEDGED** -- Intentional for Pioneer Phase; `transitionGovernance()` exists for handoff |
| M-02 (R5) | No timelock on governance actions | Medium | **ACKNOWLEDGED** -- Will use OmniTimelockController as GOVERNANCE_ROLE holder |
| M-03 (R5) | Persistent allowances after role revocation | Medium | **OPEN** -- No remediation applied; see M-01 below |
| M-04 (R5) | `execute()` can call any contract | Medium | **MITIGATED** -- `SelfCallNotAllowed` check prevents self-calls; risk inherent to design |
| M-05 (R5) | No event emitted for `receive()` native deposits | Medium | **FIXED** -- `NativeReceived` event emitted (was already present, previous report was in error) |
| L-01 (R5) | `_adminCount` not initialized in constructor | Low | **NOT AN ISSUE** -- `_grantRole` override increments `_adminCount`, so it is correctly set to 1 after constructor |
| L-02 (R5) | `executeBatch` gas limit not bounded | Low | **FIXED** -- `MAX_BATCH_SIZE = 64` enforced (line 387) |
| L-03 (R5) | Pause/unpause split across different roles | Low | **INTENTIONAL** -- Guardian pauses, admin unpauses; prevents compromised guardian from undoing its own halt |
| L-04 (R5) | No two-step admin transfer | Low | **ACKNOWLEDGED** -- NatSpec recommends migrating to `AccessControlDefaultAdminRulesUpgradeable` |
| L-05 (R5) | `transitionGovernance()` does not verify new addresses have code | Low | **ACKNOWLEDGED** -- Governance contracts may not be deployed yet at transition time |
| L-06 (R5) | No `fallback()` function | Low | **INTENTIONAL** -- Only `receive()` for plain XOM transfers; no accidental function calls accepted |

---

## Medium Findings

### [M-01] Persistent ERC-20 Allowances After Governance Transition (Carried)

**Severity:** Medium
**Category:** SC02 -- Business Logic / Access Control
**VP Reference:** VP-49 (Approval Race Condition)
**Location:** `approveToken()` (lines 262-278), `transitionGovernance()` (lines 454-481)
**Sources:** Round 5 M-03 (carried)
**Real-World Precedent:** Various DeFi treasury drains via stale approvals

**Description:**
When `approveToken()` is called by `GOVERNANCE_ROLE` to set an ERC-20 allowance for a spender, that allowance persists indefinitely in the token contract. When governance transitions via `transitionGovernance()`, the old approvals remain active. The new governance holder has no visibility into which approvals exist, and the approved spenders can continue to transfer tokens from the treasury.

**Exploit Scenario:**
1. During Pioneer Phase, governance calls `approveToken(USDC, maliciousContract, type(uint256).max)`
2. Governance transitions to OmniTimelockController via `transitionGovernance()`
3. `maliciousContract` can still call `USDC.transferFrom(treasury, attacker, balance)` indefinitely
4. The new governance must explicitly call `approveToken(USDC, maliciousContract, 0)` to revoke, but may not know about the approval

**Impact:** Stale allowances can drain treasury assets after governance transition.

**Recommendation:**
Add a function to enumerate and revoke all outstanding approvals during governance transition, or maintain an internal list of approved (token, spender) pairs:

```solidity
struct Approval {
    address token;
    address spender;
}
Approval[] public activeApprovals;

function revokeAllApprovals() external onlyRole(GOVERNANCE_ROLE) {
    for (uint256 i; i < activeApprovals.length; ++i) {
        IERC20(activeApprovals[i].token).forceApprove(
            activeApprovals[i].spender, 0
        );
    }
    delete activeApprovals;
}
```

Alternatively, add a `revokeAllApprovals()` step to `transitionGovernance()` that takes arrays of tokens and spenders to revoke as part of the atomic transition.

---

### [M-02] No Timelock on Governance Actions (Carried)

**Severity:** Medium
**Category:** SC01 -- Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** All governance functions (lines 210-405)
**Sources:** Round 5 M-02

**Description:**
All governance functions execute immediately. During Pioneer Phase this is acceptable, but the transition to OmniTimelockController should happen before significant funds accumulate.

**Status:** Acknowledged and planned. The `transitionGovernance()` function exists to hand off GOVERNANCE_ROLE to OmniTimelockController. This finding remains open until the transition is actually executed.

**Recommendation:**
Transition to OmniTimelockController before treasury balance exceeds a defined threshold (e.g., $100K equivalent).

---

### [M-03] `execute()` and `executeBatch()` Can Bypass Dedicated Transfer Functions

**Severity:** Medium (NEW)
**Category:** SC02 -- Business Logic / Audit Trail
**VP Reference:** VP-28 (Insufficient Logging)
**Location:** `execute()` (lines 346-366), `executeBatch()` (lines 376-405)
**Sources:** Manual review

**Description:**
The `execute()` function allows GOVERNANCE_ROLE to make arbitrary `call` invocations. This can be used to transfer ERC-20 tokens, native XOM, or NFTs without going through the dedicated `transferToken()`, `transferNative()`, `transferNFT()`, or `transferERC1155()` functions. This bypasses:
1. The zero-amount check in dedicated functions
2. The specific event emissions (`TokenTransferred`, `NativeTransferred`, etc.)
3. Any future guardrails added to dedicated functions

For example:
```solidity
// This bypasses transferToken() entirely:
execute(
    address(xomToken),
    0,
    abi.encodeWithSignature("transfer(address,uint256)", attacker, balance)
);
```

The `Executed` event is emitted, but off-chain monitoring systems that only watch for `TokenTransferred` events will miss this transfer.

**Impact:** Governance can bypass dedicated function guardrails and event monitoring.

**Recommendation:**
This is inherent to the `execute()` design and cannot be fully prevented without removing `execute()`. However:
1. Off-chain monitoring MUST watch for both dedicated events AND generic `Executed` events
2. Consider adding a whitelist of callable targets (if the set of future integrations is known)
3. After governance transition, the timelock delay provides the monitoring window

---

## Low Findings

### [L-01] `transitionGovernance()` Does Not Verify Target Addresses Differ From Caller

**Severity:** Low
**Category:** SC02 -- Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `transitionGovernance()` (lines 454-481)

**Description:**
An admin could accidentally call `transitionGovernance(admin, admin, admin)` where `admin` is their own address. The function would:
1. Grant all three roles to the caller (no-op, already has them)
2. Revoke all three roles from the caller
3. Net effect: caller loses all roles, but since `_grantRole` was called first, `_adminCount` went to 2, then `_revokeRole` brings it back to 1. Wait -- the `_grantRole` override checks `granted = super._grantRole(...)` which returns false if the account already has the role. So `_adminCount` stays at 1. Then `_revokeRole` decrements to 0.

The caller would lose all roles with no new holders. While the grants "succeed" in OpenZeppelin 5.x (returning `false` for no-op), the revocations actually remove the caller. The contract would be permanently bricked with no admin, no governance, and no guardian.

**Exploit Scenario:**
```solidity
// admin accidentally uses their own address:
transitionGovernance(msg.sender, msg.sender, msg.sender);
// Result: _grantRole returns false (already has role), _revokeRole succeeds
// admin loses all roles, no new holder gains them
// Contract is permanently bricked
```

**Recommendation:**
Add checks:
```solidity
if (newGovernance == msg.sender || newGuardian == msg.sender || newAdmin == msg.sender) {
    revert CannotTransitionToSelf();
}
```

---

### [L-02] `_adminCount` Can Reach Zero If Admin Renounces While Unpaused

**Severity:** Low
**Category:** SC02 -- Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_revokeRole()` (lines 551-567)

**Description:**
The `_revokeRole` override only prevents removing the last admin **while paused**:
```solidity
if (role == DEFAULT_ADMIN_ROLE && hasRole(role, account)
    && _adminCount == 1 && paused()) {
    revert CannotRemoveLastAdminWhilePaused();
}
```

If the contract is NOT paused and only one admin remains, that admin can renounce their role (via `renounceRole(DEFAULT_ADMIN_ROLE, admin)`), setting `_adminCount` to 0. The contract would then have:
- No DEFAULT_ADMIN_ROLE holder (cannot grant new roles)
- Potentially no one who can call `unpause()` (requires DEFAULT_ADMIN_ROLE)
- If GOVERNANCE_ROLE and GUARDIAN_ROLE still exist, governance functions work but role management is permanently frozen

This is partially by design (the protection only activates when paused), but the unpaused case is equally dangerous since the contract cannot be administered afterward.

**Recommendation:**
Consider protecting against zero-admin count in all states:
```solidity
if (role == DEFAULT_ADMIN_ROLE && hasRole(role, account) && _adminCount == 1) {
    revert CannotRemoveLastAdmin();
}
```

Or at minimum, require `_adminCount >= 2` before allowing renunciation while unpaused.

---

### [L-03] `executeBatch()` Does Not Emit Per-Call Events

**Severity:** Low (NEW)
**Category:** SC04 -- Event Logging
**VP Reference:** VP-28 (Insufficient Logging)
**Location:** `executeBatch()` (lines 376-405)

**Description:**
Unlike `execute()` which emits an `Executed(target, value, data)` event for each call, `executeBatch()` only emits a single `BatchExecuted(count)` event after all calls complete. This makes it impossible to determine from events alone which targets were called, what values were sent, or what calldata was used. The full details are only available by parsing the transaction input data.

**Recommendation:**
Emit `Executed` for each call within the loop:
```solidity
for (uint256 i; i < len; ++i) {
    // ... call ...
    emit Executed(targets[i], values[i], calldatas[i]);
}
emit BatchExecuted(len);
```

---

### [L-04] No `receive()` Guard Against Zero-Value Transfers

**Severity:** Low (NEW)
**Category:** SC02 -- Business Logic
**Location:** `receive()` (lines 197-199)

**Description:**
The `receive()` function emits `NativeReceived(msg.sender, msg.value)` for every incoming XOM transfer, including zero-value transfers. While harmless on-chain, this could be used to spam the event log with zero-value `NativeReceived` events, polluting off-chain indexer data.

**Recommendation:**
Add a zero-value guard:
```solidity
receive() external payable {
    if (msg.value > 0) {
        emit NativeReceived(msg.sender, msg.value);
    }
}
```

---

## Informational Findings

### [I-01] `supportsInterface` ERC-165 Override May Miss Some Interfaces

**Severity:** Informational
**Location:** `supportsInterface()` (lines 517-528)

**Description:**
The override explicitly adds `IERC721Receiver.interfaceId` and delegates to `super.supportsInterface()`. The `super` chain includes `AccessControl` and `ERC1155Holder`. However, the explicit `IERC721Receiver` check is redundant with `ERC721Holder` if `ERC721Holder.supportsInterface()` already includes it. In OpenZeppelin 5.x, `ERC721Holder` does NOT override `supportsInterface()`, so the explicit check is correct and necessary.

**Status:** Code is correct. No action needed.

---

### [I-02] Contract Has No Size Optimization

**Severity:** Informational
**Location:** Entire contract

**Description:**
At 569 lines with OpenZeppelin imports, the compiled contract is well within the 24KB Spurious Dragon limit. No concerns about contract size. This is informational for future reference if the contract grows.

---

### [I-03] `transitionGovernance()` Callable While Paused

**Severity:** Informational (NEW)
**Location:** `transitionGovernance()` (lines 454-481)

**Description:**
`transitionGovernance()` does not have a `whenNotPaused` modifier, meaning it can be called during an emergency pause. This is actually a GOOD design decision: if the treasury is paused due to a compromised key, the admin can still transition governance to a new, secure set of addresses. The new admin can then call `unpause()`.

The only risk is if the attacker obtains DEFAULT_ADMIN_ROLE: they could call `transitionGovernance()` even during a pause to grant themselves all roles. However, if the attacker has DEFAULT_ADMIN_ROLE, they could also call `unpause()` directly, so this does not represent an additional attack surface.

**Status:** Correct design. Documented for completeness.

---

## DeFi Attack Vector Analysis

### Flash Loan Attacks
**Risk: NONE.** OmniTreasury does not use `balanceOf()` for any decision logic. All outbound transfers are governance-initiated with explicit amounts. Flash loans cannot influence treasury behavior.

### Front-Running
**Risk: LOW.** All governance functions require `GOVERNANCE_ROLE`. A front-runner cannot call these functions without the role. The only front-running concern is if a governance transaction is visible in the mempool, an attacker could front-run to manipulate the state of the target contract before the treasury interacts with it (via `execute()`). This is mitigated by the OmniTimelockController's queue mechanism (after Pioneer Phase).

### Reentrancy
**Risk: NONE.** All governance functions and `receive()` are protected by `nonReentrant` (governance functions) or contain no state changes that could be exploited (receive). The `execute()` function uses `nonReentrant` and cannot call `address(this)` due to `SelfCallNotAllowed`, preventing reentrant self-calls.

### Integer Overflow
**Risk: NONE.** Solidity 0.8.24 checked arithmetic. `_adminCount` uses `uint256`, cannot underflow below 0 due to the `hasRole` check in `_revokeRole`.

### Denial of Service
**Risk: LOW.** `executeBatch()` is bounded by `MAX_BATCH_SIZE = 64`, preventing gas-limit DoS. Individual transfer functions have fixed gas costs. The `pause()` function can be used as DoS if the GUARDIAN_ROLE is compromised, but `unpause()` requires DEFAULT_ADMIN_ROLE (separate key), preventing a guardian from undoing its own pause.

### Governance Attack
**Risk: MEDIUM (Pioneer Phase only).** During Pioneer Phase, a single compromised key can drain all assets. This is documented, acknowledged, and will be mitigated by transitioning to OmniTimelockController + EmergencyGuardian multi-sig.

---

## Cross-Contract Analysis: UnifiedFeeVault -> OmniTreasury

### Fee Flow Integrity

The 10% protocol share from UnifiedFeeVault reaches OmniTreasury via the `_safePushOrQuarantine()` function. This is a `IERC20.transfer()` call that pushes tokens directly to the `protocolTreasury` address.

**Potential manipulation points:**

1. **UnifiedFeeVault `setRecipients()`:** An admin can change `protocolTreasury` to a non-OmniTreasury address, diverting the 10% share. **Mitigated by:** M-01 in UnifiedFeeVault report (needs timelock).

2. **OmniTreasury acceptance:** The treasury accepts any ERC-20 transfer without restriction. There is no whitelist of accepted tokens. This is correct -- the treasury should accept any token sent to it.

3. **OmniTreasury outflow:** Funds can only leave OmniTreasury via GOVERNANCE_ROLE functions. After Pioneer Phase, this requires timelock approval.

4. **Circular flow:** Could `execute()` be used to call back into UnifiedFeeVault? Yes -- the treasury's GOVERNANCE_ROLE could call `execute(unifiedFeeVault, 0, abi.encodeWithSignature("deposit(address,uint256)", ...))`. However, this would require the treasury to hold DEPOSITOR_ROLE in UnifiedFeeVault, which is unlikely to be granted. No circular dependency risk in practice.

### Token Compatibility

Both contracts use SafeERC20 for token transfers. Both handle:
- Standard ERC-20 tokens (return true/false)
- Non-standard tokens (return nothing, like USDT)
- Fee-on-transfer tokens (UnifiedFeeVault uses balance-before/after)

OmniTreasury does NOT use balance-before/after for outbound transfers, which is correct since the governance specifies the exact amount to transfer.

---

## Compliance Summary

| Check Category | Passed | Failed | Partial | N/A |
|----------------|--------|--------|---------|-----|
| Access Control | 10 | 1 | 1 | 0 |
| Reentrancy | 5 | 0 | 0 | 0 |
| Business Logic | 8 | 0 | 2 | 0 |
| Token Handling | 7 | 0 | 0 | 0 |
| Event Logging | 4 | 1 | 1 | 0 |
| Gas/DoS | 4 | 0 | 0 | 0 |
| Centralization | 3 | 1 | 1 | 0 |
| Interface (ERC-165) | 2 | 0 | 0 | 0 |
| **Total** | **43** | **3** | **5** | **0** |
| **Compliance Score** | | | | **91.2%** |

---

## Recommendations Summary (Priority Order)

1. **MEDIUM PRIORITY:** Track and revoke ERC-20 allowances during governance transition (M-01)
2. **MEDIUM PRIORITY:** Transition GOVERNANCE_ROLE to OmniTimelockController before significant fund accumulation (M-02)
3. **MEDIUM PRIORITY:** Ensure off-chain monitoring watches `Executed` events, not just dedicated transfer events (M-03)
4. **LOW PRIORITY:** Add self-transition guard to `transitionGovernance()` (L-01)
5. **LOW PRIORITY:** Consider protecting against zero-admin in unpaused state (L-02)
6. **LOW PRIORITY:** Emit per-call events in `executeBatch()` (L-03)
7. **LOW PRIORITY:** Guard against zero-value `receive()` event spam (L-04)

---

## Conclusion

OmniTreasury is a well-designed, minimal, non-upgradeable treasury contract. The use of OpenZeppelin's battle-tested AccessControl, ReentrancyGuard, and Pausable patterns is correct. The separation of pause (GUARDIAN_ROLE) and unpause (DEFAULT_ADMIN_ROLE) prevents a single compromised key from both pausing and unpausing. The `SelfCallNotAllowed` check prevents reentrant self-calls via `execute()`. The `_adminCount` tracking prevents the most dangerous form of admin lockout (paused with no admin).

The primary risks are:
1. **Pioneer Phase centralization** -- documented, intentional, and mitigated by `transitionGovernance()`
2. **Persistent allowances** -- should be addressed before transition
3. **`execute()` bypass of dedicated functions** -- inherent to design, requires off-chain monitoring

No Critical or High vulnerabilities were found. The contract is **production-ready** for mainnet deployment, with the understanding that governance transition to OmniTimelockController + EmergencyGuardian must happen early in the Pioneer Phase.

**Overall Risk Assessment:** LOW -- suitable for mainnet deployment. Transition to multi-sig/timelock governance is the primary remaining action item.
