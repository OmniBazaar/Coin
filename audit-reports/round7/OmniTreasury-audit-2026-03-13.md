# Security Audit Report: OmniTreasury

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/OmniTreasury.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 676
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- native XOM, ERC-20, ERC-721, ERC-1155 (Protocol-Owned Liquidity)
**Dependencies:** OpenZeppelin Contracts 5.4.0 (AccessControl, ReentrancyGuard, Pausable, ERC721Holder, ERC1155Holder, SafeERC20)
**Compiler Settings:** Optimizer enabled, 200 runs
**Test Suite:** 80 tests, all passing (3 seconds)
**Slither:** Skipped
**Previous Audits:** Round 5 (2026-03-08), Round 6 (2026-03-10)

---

## Executive Summary

OmniTreasury is the Protocol-Owned Liquidity (POL) wallet receiving the 10% protocol share from every fee-distributing contract in the OmniBazaar ecosystem (via UnifiedFeeVault). It holds native XOM, ERC-20, ERC-721, and ERC-1155 tokens, with governance-controlled outbound transfers and a general-purpose `execute()`/`executeBatch()` capability.

This Round 7 audit confirms that the M-01 finding from Round 6 (persistent ERC-20 allowances after governance transition) has been **fully remediated** with a tracked approval system (`_activeApprovals[]`) and automatic revocation during `transitionGovernance()`. The contract is well-engineered with no Critical or High vulnerabilities. Several Low findings from Round 6 remain open (acknowledged by design), and one new Medium finding has been identified related to the approval tracking mechanism.

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 3 | 1 CARRIED (acknowledged), 1 CARRIED (by design), 1 NEW |
| Low | 5 | 3 CARRIED (acknowledged), 2 NEW |
| Informational | 4 | 3 CARRIED, 1 NEW |
| **Total** | **12** | |

---

## Findings Summary Table

| ID | Severity | Finding | Status | Source |
|----|----------|---------|--------|--------|
| M-01 | Medium | Pioneer Phase single-key centralization | ACKNOWLEDGED | R5 M-01 carried |
| M-02 | Medium | No timelock on governance actions | ACKNOWLEDGED | R5 M-02 / R6 M-02 carried |
| M-03 | Medium | Malicious token in `_activeApprovals` can block `transitionGovernance()` | **NEW** | Manual review |
| L-01 | Low | `transitionGovernance()` self-call permanently bricks contract | OPEN | R6 L-01 carried |
| L-02 | Low | `_adminCount` can reach zero when unpaused | ACKNOWLEDGED | R6 L-02 carried |
| L-03 | Low | `executeBatch()` does not emit per-call events | OPEN | R6 L-03 carried |
| L-04 | Low | Unbounded `_activeApprovals` array growth | **NEW** | Manual review |
| L-05 | Low | `receive()` emits event for zero-value transfers | ACKNOWLEDGED | R6 L-04 carried |
| I-01 | Info | `execute()` can bypass dedicated transfer function guardrails | ACKNOWLEDGED | R6 M-03 (downgraded) |
| I-02 | Info | `transitionGovernance()` callable while paused (intentional) | CORRECT | R6 I-03 carried |
| I-03 | Info | `supportsInterface` ERC-165 override is correct | CORRECT | R6 I-01 carried |
| I-04 | Info | Solhint function ordering warning | **NEW** | Solhint |

---

## Previous Findings Remediation Status

| Round | ID | Finding | Severity | Round 7 Status |
|-------|-----|---------|----------|----------------|
| R6 | M-01 | Persistent ERC-20 allowances after governance transition | Medium | **FIXED** -- `_activeApprovals[]` tracking + `revokeAllApprovals()` + auto-revocation in `transitionGovernance()` |
| R6 | M-02 | No timelock on governance actions | Medium | **ACKNOWLEDGED** -- Will use OmniTimelockController as GOVERNANCE_ROLE holder |
| R6 | M-03 | `execute()` can bypass dedicated transfer functions | Medium | **DOWNGRADED to I-01** -- Inherent to design; off-chain monitoring must watch `Executed` events |
| R6 | L-01 | `transitionGovernance()` self-call bricks contract | Low | **OPEN** -- Not fixed; see L-01 below |
| R6 | L-02 | `_adminCount` can reach zero when unpaused | Low | **ACKNOWLEDGED** -- By design; only paused state has guard |
| R6 | L-03 | `executeBatch()` no per-call events | Low | **OPEN** -- Not fixed; see L-03 below |
| R6 | L-04 | `receive()` zero-value event spam | Low | **ACKNOWLEDGED** -- Harmless on-chain, indexers can filter |
| R6 | I-01 | `supportsInterface` override correctness | Info | **CORRECT** -- Verified against OZ 5.4.0 |
| R6 | I-02 | Contract size within limits | Info | **CORRECT** -- 676 lines, well under 24KB |
| R6 | I-03 | `transitionGovernance()` callable while paused | Info | **CORRECT** -- Good design; allows emergency governance transition |

---

## Medium Findings

### [M-01] Pioneer Phase Single-Key Centralization (Carried -- Acknowledged)

**Severity:** Medium
**Category:** SC01 -- Centralization / Access Control
**Location:** Constructor (line 208-214), all governance functions
**Sources:** Round 5 M-01, Round 6 M-01

**Description:**
During the Pioneer Phase, the deployer (`admin`) holds DEFAULT_ADMIN_ROLE, GOVERNANCE_ROLE, and GUARDIAN_ROLE. A single compromised key can drain all treasury assets via `transferToken()`, `transferNative()`, `execute()`, or `executeBatch()`.

**Status:** Acknowledged and intentional. The `transitionGovernance()` function (line 536-568) provides an atomic handoff to production governance contracts (OmniTimelockController + EmergencyGuardian multi-sig). This finding remains open until the transition is executed.

**Recommendation:** Execute governance transition before treasury balance exceeds a defined threshold (e.g., $100K equivalent). Keep Pioneer Phase as short as possible.

---

### [M-02] No Timelock on Governance Actions (Carried -- Acknowledged)

**Severity:** Medium
**Category:** SC01 -- Access Control
**Location:** All governance functions (lines 235-440)
**Sources:** Round 5 M-02, Round 6 M-02

**Description:**
All governance functions execute immediately with no delay. After transitioning GOVERNANCE_ROLE to OmniTimelockController, all outbound transfers and arbitrary executions will require a timelock delay, providing a monitoring window.

**Status:** Acknowledged and planned. The design relies on OmniTimelockController being the GOVERNANCE_ROLE holder post-Pioneer Phase.

**Recommendation:** Deploy OmniTimelockController with an appropriate delay (e.g., 48 hours) and transition governance early.

---

### [M-03] Malicious Token in `_activeApprovals` Can Block `transitionGovernance()` (NEW)

**Severity:** Medium
**Category:** SC02 -- Business Logic / Denial of Service
**Location:** `_revokeAllApprovalsInternal()` (lines 626-635), `transitionGovernance()` (line 551)

**Description:**
The Round 6 M-01 remediation added `_revokeAllApprovalsInternal()` which iterates over `_activeApprovals` and calls `forceApprove(token, spender, 0)` for each entry. The `forceApprove` function in OpenZeppelin's SafeERC20 (v5.4.0) uses `_callOptionalReturn()` which propagates reverts from the underlying `token.approve()` call (SafeERC20.sol lines 173-183).

If governance calls `approveToken()` on a malicious or buggy ERC-20 token whose `approve()` function reverts when called with amount 0, this creates a permanently stuck entry in `_activeApprovals`. Both `revokeAllApprovals()` AND `transitionGovernance()` will revert when they reach this entry, because the revert propagates up through `forceApprove` -> `_callOptionalReturn` -> `_revokeAllApprovalsInternal`.

**Exploit Scenario:**
```
1. Governance calls approveToken(maliciousToken, spender, 1000)
2. maliciousToken is added to _activeApprovals
3. maliciousToken.approve(spender, 0) reverts (by design or bug)
4. transitionGovernance() reverts at _revokeAllApprovalsInternal()
5. revokeAllApprovals() also reverts
6. Governance transition is blocked
```

**Workaround Available:**
The admin can still transition governance manually by:
1. Calling `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` directly
2. Calling `grantRole(GOVERNANCE_ROLE, newGovernance)` directly
3. Calling `grantRole(GUARDIAN_ROLE, newGuardian)` directly
4. Having the new admin call `revokeRole()` on the old admin

This bypasses `transitionGovernance()` entirely but loses the atomicity guarantee and the automatic approval revocation.

**Impact:** Denial of service on the `transitionGovernance()` atomic transition function. Does not directly cause fund loss. The workaround (manual role grants/revokes) preserves full functionality.

**Recommendation:**
Wrap each `forceApprove` call in a try/catch to make the revocation best-effort:

```solidity
function _revokeAllApprovalsInternal() internal {
    uint256 len = _activeApprovals.length;
    for (uint256 i; i < len; ++i) {
        try IERC20(_activeApprovals[i].token).approve(
            _activeApprovals[i].spender, 0
        ) {} catch {}
    }
    delete _activeApprovals;
    emit AllApprovalsRevoked(len);
}
```

Alternatively, add a function to remove individual entries from `_activeApprovals` by index, so the problematic entry can be cleared before calling `transitionGovernance()`.

---

## Low Findings

### [L-01] `transitionGovernance()` Self-Call Permanently Bricks Contract (Carried -- Open)

**Severity:** Low
**Category:** SC02 -- Business Logic / Logic Error
**Location:** `transitionGovernance()` (lines 536-568)
**Sources:** Round 6 L-01

**Description:**
If the admin calls `transitionGovernance(msg.sender, msg.sender, msg.sender)` -- either accidentally or through a UI bug -- the contract is permanently bricked:

1. `_grantRole(DEFAULT_ADMIN_ROLE, msg.sender)` -- already has role, returns `false`, `_adminCount` stays at 1
2. `_grantRole(GOVERNANCE_ROLE, msg.sender)` -- already has role (constructor granted it), returns `false`
3. `_grantRole(GUARDIAN_ROLE, msg.sender)` -- already has role (constructor granted it), returns `false`
4. `_revokeRole(GOVERNANCE_ROLE, msg.sender)` -- removes role, returns `true`
5. `_revokeRole(GUARDIAN_ROLE, msg.sender)` -- removes role, returns `true`
6. `_revokeRole(DEFAULT_ADMIN_ROLE, msg.sender)` -- removes role, `_adminCount` goes to 0

Result: No address holds any role. The contract cannot be unpaused, cannot have roles granted, and cannot be administered. All funds are permanently locked.

**Status:** Not fixed from Round 6. This finding remains open.

**Recommendation:**
Add a guard against self-transition:
```solidity
error CannotTransitionToSelf();

if (newGovernance == msg.sender || newGuardian == msg.sender || newAdmin == msg.sender) {
    revert CannotTransitionToSelf();
}
```

---

### [L-02] `_adminCount` Can Reach Zero When Unpaused (Carried -- Acknowledged)

**Severity:** Low
**Category:** SC02 -- Business Logic
**Location:** `_revokeRole()` (lines 658-675)

**Description:**
The `_revokeRole` override only prevents removing the last admin when the contract is **paused**. If unpaused and only one admin exists, that admin can renounce via `renounceRole(DEFAULT_ADMIN_ROLE, admin)`, setting `_adminCount` to 0. The contract then has no admin and cannot grant new roles, change role admins, or call `unpause()` if later paused by a guardian.

**Status:** Acknowledged. The paused-state guard prevents the most dangerous scenario (permanently bricked with no one to unpause). The unpaused case is considered an intentional admin action (similar to OZ's default behavior).

**Recommendation:** Consider extending the guard to all states, or at minimum require `_adminCount >= 2` before allowing admin renunciation regardless of pause state.

---

### [L-03] `executeBatch()` Does Not Emit Per-Call Events (Carried -- Open)

**Severity:** Low
**Category:** SC04 -- Event Logging
**Location:** `executeBatch()` (lines 411-440)

**Description:**
Unlike `execute()` which emits `Executed(target, value, data)` for each call, `executeBatch()` only emits a single `BatchExecuted(count)` event. Off-chain monitoring systems cannot determine from events alone which targets were called, what values were sent, or what calldata was used. Full transaction input parsing is required.

**Status:** Not fixed from Round 6. This finding remains open.

**Impact:** Reduced observability for off-chain monitoring. Transaction input parsing is required for full audit trail of batch operations.

**Recommendation:**
Emit `Executed` for each call within the loop:
```solidity
for (uint256 i; i < len; ++i) {
    // ... existing validation and call ...
    emit Executed(targets[i], values[i], calldatas[i]);
}
emit BatchExecuted(len);
```

Gas cost increase is minimal (~375 gas per additional log) and justified by the monitoring improvement.

---

### [L-04] Unbounded `_activeApprovals` Array Growth (NEW)

**Severity:** Low
**Category:** SC03 -- Gas / Denial of Service
**Location:** `approveToken()` (lines 287-313), `_revokeAllApprovalsInternal()` (lines 626-635)

**Description:**
Every call to `approveToken()` with `amount > 0` appends a new entry to `_activeApprovals`, even if the same `(token, spender)` pair already exists. There is no deduplication and no bound on the array size (other than block gas limit).

If governance calls `approveToken(tokenA, spenderA, 100)` repeatedly (e.g., updating an allowance amount), each call adds a duplicate entry. After N calls with the same pair, the array contains N identical entries. While `forceApprove(0)` is idempotent (the N-1 redundant calls are harmless), the gas cost of `revokeAllApprovals()` and `transitionGovernance()` scales linearly with N.

Practical impact: Governance functions are gated by `GOVERNANCE_ROLE`, so only authorized callers can grow the array. Normal usage would produce a small number of entries. However, a compromised governance key (or governance via a malicious proposal) could grow the array to a point where `revokeAllApprovals()` and `transitionGovernance()` exceed the block gas limit.

**Recommendation:**
Consider either:
1. Deduplicating entries by using a mapping `(token, spender) => bool` alongside the array
2. Capping the array size (e.g., `if (_activeApprovals.length >= MAX_APPROVALS) revert TooManyApprovals()`)
3. Accepting this as a GOVERNANCE_ROLE trust assumption (only trusted callers can grow the array)

---

### [L-05] `receive()` Emits Event for Zero-Value Transfers (Carried -- Acknowledged)

**Severity:** Low
**Category:** SC04 -- Event Logging
**Location:** `receive()` (lines 222-224)

**Description:**
The `receive()` function emits `NativeReceived(msg.sender, msg.value)` for every incoming transfer, including zero-value transfers. While harmless on-chain, this could be used to spam the event log with zero-value `NativeReceived` events, polluting off-chain indexer data.

**Status:** Acknowledged. Zero-value native transfers are uncommon in practice, and indexers can filter by `msg.value > 0`.

---

## Informational Findings

### [I-01] `execute()` Can Bypass Dedicated Transfer Function Guardrails (Carried -- Downgraded from M-03 R6)

**Severity:** Informational (downgraded from Medium in R6)
**Location:** `execute()` (lines 381-401), `executeBatch()` (lines 411-440)

**Description:**
The `execute()` function allows GOVERNANCE_ROLE to make arbitrary `call` invocations, which can bypass the dedicated `transferToken()`, `transferNative()`, `transferNFT()`, and `transferERC1155()` functions. This bypasses zero-amount checks, specific event emissions, and any future guardrails on dedicated functions.

**Downgrade Rationale:** This is inherent to the `execute()` design and is a deliberate feature for future protocol integration. After governance transitions to OmniTimelockController, the timelock delay provides sufficient monitoring window. The `SelfCallNotAllowed` guard prevents the most dangerous variant (self-calls). Off-chain monitoring MUST watch `Executed` events in addition to dedicated transfer events.

---

### [I-02] `transitionGovernance()` Callable While Paused (Carried -- Correct by Design)

**Severity:** Informational
**Location:** `transitionGovernance()` (lines 536-568)

**Description:**
`transitionGovernance()` has no `whenNotPaused` modifier. This is **correct design**: if the treasury is paused due to a compromised key, the admin can still transition governance to secure addresses. The new admin can then call `unpause()`. If an attacker has DEFAULT_ADMIN_ROLE, they could also call `unpause()` directly, so this does not represent additional attack surface.

---

### [I-03] `supportsInterface` ERC-165 Override Is Correct (Carried)

**Severity:** Informational
**Location:** `supportsInterface()` (lines 604-615)

**Description:**
The override explicitly adds `IERC721Receiver.interfaceId` and delegates to `super.supportsInterface()`. In OpenZeppelin 5.4.0, `ERC721Holder` does NOT override `supportsInterface()`, so the explicit check is necessary and correct. The `super` chain correctly includes `AccessControl` (for `IAccessControl`) and `ERC1155Holder` (for `IERC1155Receiver`). Verified against OZ 5.4.0 source.

---

### [I-04] Solhint Function Ordering Warning (NEW)

**Severity:** Informational
**Location:** Line 536 (`transitionGovernance()`)

**Description:**
Solhint reports: `Function order is incorrect, external function can not go after external view function (line 503)`. The `transitionGovernance()` external function appears after `getActiveApproval()` external view function, violating the Solidity style guide function ordering convention (external before external view).

**Recommendation:** Move `transitionGovernance()` before the view functions section, or accept as a style preference. No functional impact.

---

## Round 6 M-01 Remediation Verification

The Round 6 M-01 finding (persistent ERC-20 allowances after governance transition) has been **fully remediated**. Verification:

**Changes Made:**
1. **Approval tracking struct** (lines 46-54): `Approval { token, spender }` stores active approval records
2. **`_activeApprovals` array** (line 83): Private dynamic array tracks all non-zero approvals
3. **`approveToken()` updated** (lines 302-310): Pushes to `_activeApprovals` when `amount > 0`
4. **`revokeAllApprovals()`** (lines 477-483): GOVERNANCE_ROLE can revoke all tracked approvals
5. **`_revokeAllApprovalsInternal()`** (lines 626-635): Shared internal logic iterates approvals and calls `forceApprove(0)`
6. **`transitionGovernance()` updated** (line 551): Calls `_revokeAllApprovalsInternal()` before role transitions
7. **View functions** (lines 489-513): `activeApprovalCount()` and `getActiveApproval()` for transparency
8. **`AllApprovalsRevoked` event** (line 167): Emitted after bulk revocation

**Assessment:** The remediation is thorough and addresses the core concern. The approval tracking introduces two secondary findings (M-03 malicious token DoS, L-04 unbounded growth) that are documented above, but neither causes direct fund loss.

---

## DeFi Attack Vector Analysis

### Flash Loan Attacks
**Risk: NONE.** OmniTreasury does not use `balanceOf()` for any decision logic. All outbound transfers are governance-initiated with explicit amounts. Flash loans cannot influence treasury behavior.

### Front-Running
**Risk: LOW.** All governance functions require `GOVERNANCE_ROLE`. A front-runner cannot call these functions. The only concern is if a governance transaction is visible in the mempool, allowing an attacker to front-run and manipulate the state of a target contract before `execute()` interacts with it. Mitigated by OmniTimelockController's queue mechanism post-Pioneer Phase.

### Reentrancy
**Risk: NONE.** All outbound governance functions use `nonReentrant`. The `receive()` function contains no exploitable state changes. The `execute()` function uses `nonReentrant` and blocks self-calls via `SelfCallNotAllowed`. The `ReentrantReceiver` test (test #43) confirms reentrancy is blocked.

### Integer Overflow / Underflow
**Risk: NONE.** Solidity 0.8.24 provides checked arithmetic. `_adminCount` uses `uint256` and cannot underflow below 0 because `_revokeRole` checks `hasRole(role, account)` before decrementing (the `super._revokeRole` call returns `false` if the account doesn't have the role, preventing the decrement).

### Denial of Service
**Risk: LOW.** `executeBatch()` is bounded by `MAX_BATCH_SIZE = 64`. Individual transfer functions have fixed gas costs. `_activeApprovals` can grow unbounded (L-04) but only GOVERNANCE_ROLE can add entries. The `pause()` function can be used as DoS if GUARDIAN_ROLE is compromised, but `unpause()` requires DEFAULT_ADMIN_ROLE (separate key).

### Governance Attack
**Risk: MEDIUM (Pioneer Phase only).** A single compromised key can drain all assets during Pioneer Phase. After transition to OmniTimelockController + EmergencyGuardian, this risk is reduced to LOW.

### Token Compatibility
**Risk: NONE.** SafeERC20 handles standard, non-standard (USDT), and fee-on-transfer tokens correctly. The `forceApprove` function handles tokens requiring zero-first approval pattern.

---

## Access Control Matrix

| Function | Required Role | whenNotPaused | nonReentrant | Notes |
|----------|--------------|---------------|--------------|-------|
| `receive()` | None | No | No | Accepts all incoming XOM |
| `transferToken()` | GOVERNANCE_ROLE | Yes | Yes | |
| `transferNative()` | GOVERNANCE_ROLE | Yes | Yes | |
| `approveToken()` | GOVERNANCE_ROLE | Yes | Yes | Tracks approvals in M-01 fix |
| `transferNFT()` | GOVERNANCE_ROLE | Yes | Yes | |
| `transferERC1155()` | GOVERNANCE_ROLE | Yes | Yes | |
| `execute()` | GOVERNANCE_ROLE | Yes | Yes | SelfCallNotAllowed guard |
| `executeBatch()` | GOVERNANCE_ROLE | Yes | Yes | MAX_BATCH_SIZE = 64, SelfCallNotAllowed |
| `pause()` | GUARDIAN_ROLE | No | No | |
| `unpause()` | DEFAULT_ADMIN_ROLE | No | No | Separates pause/unpause authority |
| `revokeAllApprovals()` | GOVERNANCE_ROLE | No | Yes | Can operate while paused (protective) |
| `transitionGovernance()` | DEFAULT_ADMIN_ROLE | No | No | Can operate while paused (by design) |
| `grantRole()` | DEFAULT_ADMIN_ROLE | No | No | Inherited from OZ AccessControl |
| `revokeRole()` | DEFAULT_ADMIN_ROLE | No | No | Inherited, `_adminCount` tracking |
| `renounceRole()` | Self | No | No | Inherited, `_adminCount` tracking |

**Role Admin Mapping:**
- `DEFAULT_ADMIN_ROLE` admin: `DEFAULT_ADMIN_ROLE` (self-administered)
- `GOVERNANCE_ROLE` admin: `DEFAULT_ADMIN_ROLE`
- `GUARDIAN_ROLE` admin: `DEFAULT_ADMIN_ROLE`

**No unprotected selfdestruct or delegatecall.** The contract explicitly uses only `call` (not `delegatecall`) in `execute()` and `executeBatch()`.

---

## Compliance Summary

| Check Category | Passed | Failed | Partial | N/A |
|----------------|--------|--------|---------|-----|
| Access Control | 11 | 0 | 1 | 0 |
| Reentrancy | 5 | 0 | 0 | 0 |
| Business Logic | 8 | 0 | 2 | 0 |
| Token Handling | 7 | 0 | 1 | 0 |
| Event Logging | 5 | 1 | 0 | 0 |
| Gas / DoS | 4 | 0 | 1 | 0 |
| Centralization | 3 | 0 | 2 | 0 |
| Interface (ERC-165) | 2 | 0 | 0 | 0 |
| Integer Safety | 3 | 0 | 0 | 0 |
| NatSpec / Documentation | 5 | 0 | 0 | 0 |
| **Total** | **53** | **1** | **7** | **0** |
| **Compliance Score** | | | | **92.6%** |

---

## Severity Breakdown

| Severity | Count | Direct Fund Loss Risk |
|----------|-------|-----------------------|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 3 | No direct fund loss; centralization risk during Pioneer Phase; DoS on governance transition |
| Low | 5 | No fund loss; contract brick risk (L-01), gas inefficiency, logging gaps |
| Informational | 4 | None |

---

## Recommendations Summary (Priority Order)

1. **MEDIUM PRIORITY:** Wrap `forceApprove` calls in try/catch within `_revokeAllApprovalsInternal()` to prevent malicious tokens from blocking governance transition (M-03)
2. **MEDIUM PRIORITY:** Transition to OmniTimelockController + EmergencyGuardian multi-sig before treasury accumulates significant funds (M-01, M-02)
3. **LOW PRIORITY:** Add self-transition guard (`newGovernance != msg.sender`, etc.) to prevent permanent contract bricking (L-01)
4. **LOW PRIORITY:** Emit per-call `Executed` events in `executeBatch()` loop for improved monitoring (L-03)
5. **LOW PRIORITY:** Add deduplication or cap to `_activeApprovals` array (L-04)
6. **OPTIONAL:** Add zero-value guard to `receive()` (L-05)
7. **OPTIONAL:** Fix function ordering for solhint compliance (I-04)

---

## Conclusion

OmniTreasury is a well-designed, minimal, non-upgradeable treasury contract. The Round 6 M-01 remediation (approval tracking and automatic revocation during governance transition) is a solid improvement that addresses the stale-approval attack vector. The implementation uses OpenZeppelin 5.4.0's battle-tested AccessControl, ReentrancyGuard, Pausable, ERC721Holder, and ERC1155Holder patterns correctly.

**Key Strengths:**
- Correct separation of pause (GUARDIAN_ROLE) / unpause (DEFAULT_ADMIN_ROLE) authority
- `SelfCallNotAllowed` guard prevents reentrant self-calls via `execute()`
- `_adminCount` tracking prevents the most dangerous admin lockout (paused with no admin)
- No `delegatecall` (only `call`), preventing storage corruption
- SafeERC20 for all token operations
- Comprehensive test suite (80 tests, all passing)
- Atomic governance transition with automatic approval revocation

**Key Risks:**
1. Pioneer Phase centralization (inherent, mitigated by `transitionGovernance()`)
2. Malicious token DoS on governance transition (M-03, medium impact with available workaround)
3. Self-transition bricking (L-01, low probability but permanent impact)

**No Critical or High vulnerabilities were found.** The contract is **production-ready** for mainnet deployment with the understanding that:
- Governance transition to OmniTimelockController must happen early in the Pioneer Phase
- Only trusted ERC-20 tokens should be approved via `approveToken()` (or fix M-03 before deployment)
- The L-01 self-transition fix is strongly recommended before deployment

**Overall Risk Assessment:** LOW -- suitable for mainnet deployment.
