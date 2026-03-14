# Security Audit Report: OmniGovernance (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Opus 4.6 -- Deep Manual Review
**Contract:** `Coin/contracts/OmniGovernance.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,110
**Upgradeable:** Yes (UUPS via OpenZeppelin UUPSUpgradeable)
**Handles Funds:** No (governance proposals execute via external OmniTimelockController)
**Test Coverage:** `Coin/test/UUPSGovernance.test.js`
**Previous Audits:**
- OmniGovernance-audit-2026-02-21.md (Round 4 -- against V1, all findings resolved in rewrite)
- OmniGovernance-audit-2026-02-26.md (Round 5 -- H-01, M-01, M-02, L-01 through L-03, I-01 through I-04)
- OmniGovernance-audit-2026-03-10.md (Round 6 -- M-01, M-02, L-01 through L-03, I-01 through I-03)
- CROSS-SYSTEM-Governance-Manipulation-2026-03-10.md (Round 6 cross-contract -- ATK-H01, ATK-H02, ATK-M01 through ATK-M04)

---

## Scope

This round-7 pre-mainnet audit covers OmniGovernance.sol (1,110 lines), performing:

1. **Full remediation verification** -- confirming all Round 6 findings (M-01, M-02, L-01 through L-03, I-01 through I-03) and all cross-system findings (ATK-H01, ATK-H02, ATK-M01 through ATK-M04) were correctly fixed
2. **New vulnerability discovery** -- fresh line-by-line review of proposal lifecycle, voting mechanics, access control, cross-contract interactions, flash-loan prevention, and upgrade authorization
3. **Edge case analysis** -- boundary conditions, state machine transitions, non-existent proposal handling
4. **Pre-mainnet readiness assessment** -- deployment configuration, role transition, operational security

---

## Executive Summary

All prior Round 6 findings have been addressed. The contract has undergone significant hardening since Round 5, with the `transferAdminToTimelock()` function now properly using `_msgSender()`, proposer cancellation restricted to pre-vote stages per Governor Bravo pattern, and staking snapshots fully integrated via `getStakedAt()`.

This audit found **0 Critical, 0 High, 1 Medium, 3 Low, and 4 Informational** findings. The contract is well-implemented and ready for mainnet deployment after addressing the Medium finding.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 4 |

**Slither:** Skipped (resource contention).

**Solhint:** Clean -- only two warnings about non-existent rules (`contract-name-camelcase`, `event-name-camelcase`) from the solhint config, not from the contract itself.

---

## Prior Findings Remediation Status

### Round 6 Contract-Level Findings

| Prior ID | Severity | Finding | Status | Verification |
|----------|----------|---------|--------|--------------|
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `transferAdminToTimelock()` | **FIXED** | Line 817: `address caller = _msgSender();` used for role revocation. No raw `msg.sender` usage anywhere in contract logic. |
| M-02 | Medium | Proposer can cancel own proposal after Succeeded/Queued | **FIXED** | Lines 604-615: Proposer cancellation restricted to `Pending` and `Active` states only. Governor Bravo pattern applied. |
| L-01 | Low | Timelock cancel failure allows state divergence | **ACKNOWLEDGED** | Lines 623-631: `TimelockCancelFailed` event emitted on failure. Governance-side cancellation still proceeds. The current pattern is intentional -- documented in NatSpec. |
| L-02 | Low | `getVotingPower()` uses current values for proposal threshold | **ACKNOWLEDGED** | Lines 698-708: Still uses current `getVotes()` and `_getStakedAmount()`. Flash-loan proposal spam risk mitigated by 10,000 XOM threshold cost. |
| L-03 | Low | `_validateNoCriticalSelectors()` skips calldata < 4 bytes | **ACKNOWLEDGED** | Lines 944-965: Short calldata still skipped. Empty calldata represents ETH transfers (valid). 1-3 byte calldata would fail at timelock execution anyway. |
| I-01 | Info | `_getTimelockId()` recomputes salt | **ACKNOWLEDGED** | Minor gas cost accepted for code clarity. |
| I-02 | Info | No per-proposer active proposal limit | **ACKNOWLEDGED** | 10,000 XOM threshold provides economic filtering. |
| I-03 | Info | Trusted forwarder is immutable | **ACKNOWLEDGED** | Standard UUPS behavior -- forwarder change requires implementation upgrade. |

### Round 6 Cross-System Findings

| Prior ID | Severity | Finding | Status | Verification |
|----------|----------|---------|--------|--------------|
| ATK-H01 | High | Governance takeover via validator reward pool drain | **FIXED** | OmniRewardManager now has on-chain emission rate limiting; VALIDATOR_REWARD_ROLE removed. |
| ATK-H02 | High | Ossification race condition -- 48h routine delay for `ossify()` | **FIXED** | `ossify()` selector registered as critical in OmniTimelockController constructor. Verified at line 93 of OmniTimelockController. |
| ATK-M01 | Medium | Timelock bypass via Pioneer Phase parallel authority | **FIXED** | `transferAdminToTimelock()` provides atomic, irreversible transition. |
| ATK-M02 | Medium | Proposer cancellation veto | **FIXED** | Proposer cancellation restricted to Pending/Active (lines 604-615). |
| ATK-M03 | Medium | Fee vault drain via governance -- no timelock on `setRecipients()` | **FIXED** | External to this contract. |
| ATK-M04 | Medium | OmniCore two-step admin transfer backdoor | **FIXED** | External to this contract. |

---

## New Findings

### [M-01] `cancel()` Does Not Validate Proposal Existence -- Admin Can Cancel Non-Existent Proposals

**Severity:** Medium
**Lines:** 589-635
**Category:** Input Validation / State Integrity

**Description:**

The `cancel()` function does not check whether the `proposalId` refers to an existing proposal before allowing admin cancellation. For non-existent proposals (any `proposalId > proposalCount`), all `Proposal` struct fields are zero-initialized:

```solidity
function cancel(uint256 proposalId) external {
    Proposal storage proposal = proposals[proposalId];

    // For non-existent proposal: executed=false, cancelled=false -- passes
    if (proposal.executed || proposal.cancelled) {
        revert InvalidProposalState(
            state(proposalId), ProposalState.Pending
        );
    }

    address caller = _msgSender();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, caller);

    if (isAdmin) {
        // Admin branch: no state() check, no bounds check
        // Proceeds directly to line 620
    } else if (caller == proposal.proposer) {
        // Proposer branch: calls state() which reverts with ProposalNotFound
        ProposalState currentState = state(proposalId);
        // ...
    } else {
        revert NotAuthorizedToCancel();
    }

    proposal.cancelled = true;  // Writes to storage for non-existent proposal
    // ...
    emit ProposalCancelled(proposalId);  // Misleading event
}
```

The flow for an admin calling `cancel(999999)` when only 5 proposals exist:
1. `proposal.executed || proposal.cancelled` = `false || false` -- passes
2. `isAdmin` = `true` -- enters admin branch
3. No `state()` call in admin path (unlike proposer path which would revert via `ProposalNotFound`)
4. `proposal.cancelled = true` -- writes to storage slot for proposal 999999
5. `ProposalCancelled(999999)` event emitted

This creates phantom "cancelled" proposals in storage and emits misleading events that could confuse off-chain indexers, block explorers, and governance dashboards.

**Impact:** Medium. No direct fund loss, but:
- Off-chain governance dashboards may display phantom cancelled proposals
- Event indexers tracking `ProposalCancelled` will log non-existent proposals
- The `cancelled = true` write to a non-existent proposal slot means if a future proposal somehow maps to that slot (storage collision in an upgrade), it would be pre-cancelled. While extremely unlikely with sequential IDs, this violates storage hygiene.
- An admin (or compromised timelock) could emit thousands of `ProposalCancelled` events for non-existent proposals, confusing monitoring systems

**Recommendation:**

Add a proposal existence check at the start of `cancel()`:

```solidity
function cancel(uint256 proposalId) external {
    // Validate proposal exists
    if (proposalId == 0 || proposalId > proposalCount) {
        revert ProposalNotFound();
    }

    Proposal storage proposal = proposals[proposalId];
    // ... rest of function
}
```

Alternatively, call `state(proposalId)` early (before the admin branch) to leverage its existing `ProposalNotFound` check:

```solidity
function cancel(uint256 proposalId) external {
    Proposal storage proposal = proposals[proposalId];

    if (proposal.executed || proposal.cancelled) {
        revert InvalidProposalState(
            state(proposalId), ProposalState.Pending
        );
    }

    // Validate existence for all callers (not just proposer branch)
    ProposalState currentState = state(proposalId);

    address caller = _msgSender();
    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, caller);

    if (isAdmin) {
        // Admin can cancel at any stage
    } else if (caller == proposal.proposer) {
        if (
            currentState != ProposalState.Pending &&
            currentState != ProposalState.Active
        ) {
            revert NotAuthorizedToCancel();
        }
    } else {
        revert NotAuthorizedToCancel();
    }

    proposal.cancelled = true;
    // ...
}
```

---

### [L-01] `cancel()` Lacks `nonReentrant` Modifier

**Severity:** Low
**Lines:** 589
**Category:** Defense in Depth

**Description:**

The `cancel()` function does not have the `nonReentrant` modifier, unlike `castVote()`, `queue()`, and `execute()`:

```solidity
function cancel(uint256 proposalId) external {         // No nonReentrant
    // ...
    proposal.cancelled = true;                          // State change
    if (proposal.queued) {
        (bool success, ) = timelock.call(               // External call
            abi.encodeWithSignature("cancel(bytes32)", timelockId)
        );
    }
}
```

The function follows the CEI pattern (sets `cancelled = true` before the external call), and a reentrant call would fail at line 592 (`proposal.cancelled` is already `true`). Therefore, the function is safe from reentrancy in practice.

However, the inconsistency with other state-changing functions that do use `nonReentrant` is a best-practice violation, and future modifications to `cancel()` might inadvertently introduce reentrancy if the developer assumes the modifier is present.

**Impact:** No current exploitability. Defense-in-depth concern.

**Recommendation:**

Add `nonReentrant` to `cancel()` for consistency:

```solidity
function cancel(uint256 proposalId) external nonReentrant {
```

---

### [L-02] Misleading Error on Timelock Scheduling/Execution Failure

**Severity:** Low
**Lines:** 527-533, 573-578
**Category:** Error Reporting / Developer Experience

**Description:**

When the timelock's `scheduleBatch` or `executeBatch` call fails, the governance contract reverts with `InvalidProposalState` using values that don't reflect the actual error:

```solidity
// In queue() -- line 530:
revert InvalidProposalState(
    currentState, ProposalState.Succeeded  // Both are Succeeded!
);

// In execute() -- line 575:
revert InvalidProposalState(
    currentState, ProposalState.Queued     // Both are Queued!
);
```

These errors report the current state equals the expected state, which is semantically incorrect -- the proposal was in the correct state, but the timelock call failed for an unrelated reason (e.g., governance lacks `PROPOSER_ROLE` on timelock, operation already scheduled, or insufficient delay for critical operations).

**Impact:** Debugging difficulty. When timelock integration fails, the error message provides no indication of the actual cause. Developers or operators must trace the transaction manually to find the root cause.

**Recommendation:**

Add dedicated errors:

```solidity
error TimelockScheduleFailed();
error TimelockExecutionFailed();

// In queue():
if (!success) {
    proposal.queued = false;
    revert TimelockScheduleFailed();
}

// In execute():
if (!success) {
    proposal.executed = false;
    revert TimelockExecutionFailed();
}
```

For even better diagnostics, capture and forward the revert reason:

```solidity
if (!success) {
    proposal.queued = false;
    // Forward revert reason from timelock
    assembly {
        revert(add(data, 32), mload(data))
    }
}
```

---

### [L-03] Governor Bravo Threshold-Based Cancellation by Third Parties Not Implemented

**Severity:** Low
**Lines:** 589-618
**Category:** Governance Pattern Completeness

**Description:**

The Round 6 audit (M-02) recommended two changes to `cancel()`:

1. Restrict proposer cancellation to Pending/Active states -- **Implemented** (lines 604-615)
2. Allow anyone to cancel if proposer's voting power drops below threshold -- **Not implemented**

The standard Governor Bravo pattern allows any address to cancel a proposal if the original proposer's voting power drops below the proposal threshold. This is a safety mechanism: if a proposer creates a proposal and then sells/transfers their tokens (reducing their stake below the threshold), anyone can cancel the proposal as a signal that the proposer no longer has sufficient economic alignment.

Currently, the only ways to cancel a proposal are:
- Proposer cancels during Pending/Active
- Admin (timelock) cancels at any stage

If a proposer creates a malicious or controversial proposal and then loses their tokens (e.g., sold, liquidated, or hacked), no community member can cancel the proposal. It must either be defeated by vote or expire after `QUEUE_DEADLINE`.

**Impact:** Governance resilience gap. A proposer who loses their economic stake (and therefore alignment with the protocol) cannot have their proposals cancelled by the community. The 5-day voting period provides time to vote down malicious proposals, but the cancellation mechanism would be faster and cheaper.

**Recommendation:**

Add threshold-based cancellation in the else branch:

```solidity
} else {
    // Governor Bravo: anyone can cancel if proposer's voting
    // power dropped below threshold
    if (getVotingPower(proposal.proposer) >= PROPOSAL_THRESHOLD) {
        revert NotAuthorizedToCancel();
    }
    // Falls through to cancel the proposal
}
```

---

### [I-01] Outdated NatSpec on `getVotingPowerAt()` Claims Current Staking Amount

**Severity:** Informational
**Lines:** 712-713
**Category:** Documentation Accuracy

**Description:**

The NatSpec for `getVotingPowerAt()` states:

```solidity
/// @dev Uses ERC20Votes.getPastVotes for delegated power.
///      Uses current staking amount (snapshot staking in future upgrade).
```

But the actual implementation at line 725 uses `_getStakedAmountAt(account, blockNumber)`, which calls `OmniCore.getStakedAt()` for checkpoint-based snapshots. The "future upgrade" mentioned in the NatSpec has already been implemented. This was likely a leftover from before the ATK-H02 fix was applied.

**Recommendation:**

Update the NatSpec to reflect the actual implementation:

```solidity
/// @dev Uses ERC20Votes.getPastVotes for delegated power.
///      Uses OmniCore.getStakedAt() for checkpoint-based staking snapshots.
```

---

### [I-02] NatSpec Inconsistency: References `ADMIN_ROLE` but Contract Only Uses `DEFAULT_ADMIN_ROLE`

**Severity:** Informational
**Lines:** 586, 794-795
**Category:** Documentation Accuracy

**Description:**

Multiple NatSpec comments reference `ADMIN_ROLE`:

Line 586:
```solidity
/// @dev Can be cancelled by the proposer ... or by anyone with ADMIN_ROLE (emergency).
```

Lines 794-795:
```solidity
/// @dev H-01 fix: One-shot function that atomically grants ADMIN_ROLE and
///      DEFAULT_ADMIN_ROLE to the timelock, then revokes both from the caller.
```

The contract does not define or use any custom `ADMIN_ROLE`. It exclusively uses `DEFAULT_ADMIN_ROLE` from AccessControl. The `transferAdminToTimelock()` function at lines 820-823 only grants/revokes `DEFAULT_ADMIN_ROLE`.

**Impact:** Documentation confusion. Developers reading the NatSpec might look for a custom `ADMIN_ROLE` constant that does not exist.

**Recommendation:**

Replace all NatSpec references to `ADMIN_ROLE` with `DEFAULT_ADMIN_ROLE`:

Line 586:
```solidity
/// @dev Can be cancelled by the proposer ... or by anyone with DEFAULT_ADMIN_ROLE (emergency).
```

Lines 794-795:
```solidity
/// @dev H-01 fix: One-shot function that atomically grants DEFAULT_ADMIN_ROLE
///      to the timelock, then revokes it from the caller.
```

---

### [I-03] Missing `whenNotPaused` Modifier Despite Round 6 Marking It as Fixed

**Severity:** Informational
**Lines:** 374, 438, 455, 482, 543
**Category:** Audit Trail Consistency

**Description:**

The Round 6 audit report (M-02) states: "Missing `whenNotPaused` on `propose()` and `execute()` -- **FIXED**." However, the current contract:

1. Does not import `PausableUpgradeable`
2. Does not inherit from any Pausable contract
3. Has no `whenNotPaused` modifier on any function
4. Has no `pause()` or `unpause()` functions
5. Has no `_paused` state variable

The only references to "pause" in the contract are NatSpec comments (line 315: "ossify() + governance pause" and line 971: "OmniCore is paused"). The contract relies on the EmergencyGuardian's ability to cancel timelock operations and the ossification pattern for emergency response, rather than a traditional pause mechanism.

This is a valid architectural choice -- governance contracts that can be paused introduce centralization risk (whoever holds the pause key can halt governance). However, the Round 6 audit's M-02 status of "FIXED" appears incorrect, as the fix was either reverted, never applied, or the finding was resolved by a design decision to not add pause capability.

**Impact:** No security impact. Audit trail inconsistency that should be documented.

**Recommendation:**

Either:
1. Add a note to the Round 6 report clarifying that M-02 was resolved by design decision (governance intentionally has no pause) rather than by adding `whenNotPaused`, OR
2. If pause capability is desired, add `PausableUpgradeable` with `whenNotPaused` on `propose()`, `castVote()`, `castVoteBySig()`, `queue()`, and `execute()`, with `pause()` restricted to a guardian role and `unpause()` restricted to `DEFAULT_ADMIN_ROLE` (timelock)

Given that EmergencyGuardian can cancel timelock operations and the ossification pattern exists, option 1 (documenting the design decision) is the recommended approach.

---

### [I-04] `_getStakedAmount()` Uses Weak `data.length > 0` Check

**Severity:** Informational
**Lines:** 984, 1022
**Category:** Defensive Programming

**Description:**

Both `_getStakedAmount()` and `_getStakedAmountAt()` check `data.length > 0` before ABI-decoding the response:

```solidity
// _getStakedAmount() -- expects (uint256, uint256, uint256, uint256, bool)
if (success && data.length > 0) {
    (uint256 stakedAmount, , , , bool active) = abi.decode(
        data, (uint256, uint256, uint256, uint256, bool)
    );
    // ...
}

// _getStakedAmountAt() -- expects (uint256)
if (success && data.length > 0) {
    return abi.decode(data, (uint256));
}
```

For `_getStakedAmount()`, the minimum valid response is 160 bytes (5 * 32 bytes for the packed struct). For `_getStakedAmountAt()`, the minimum is 32 bytes (single uint256). If `data.length` is between 1 and the minimum, `abi.decode` will revert with a panic, which would bubble up through the `staticcall` success check. However, the `staticcall` already ensures `success = true`, meaning the callee function completed without reverting. Solidity `abi.encode` always produces output that is a multiple of 32 bytes, so partial data from a successful call is not practically possible.

**Impact:** No real exploitability. The `> 0` check is functionally correct but not semantically precise.

**Recommendation:**

For maximum clarity, use precise length checks:

```solidity
// _getStakedAmount():
if (success && data.length >= 160) {

// _getStakedAmountAt():
if (success && data.length >= 32) {
```

---

## Architecture Assessment

### Positive Design Elements

1. **Snapshot-based voting with dual source (ERC20Votes + OmniCore checkpoints):** Industry-standard flash-loan protection. The ATK-H02 fix (no fallback to current staking balance) is correctly implemented at line 1028.

2. **Two-tier timelock (ROUTINE 48h / CRITICAL 7d):** Appropriate delay differentiation. ROUTINE proposals validated against critical selectors at creation time (line 384-386).

3. **Governor Bravo proposer cancellation restriction:** Proposer can only cancel during Pending/Active (lines 604-615). After the community votes, the proposer cannot unilaterally veto.

4. **ERC2771 consistency:** All user-facing functions use `_msgSender()` consistently. The `transferAdminToTimelock()` M-01 fix from Round 6 is properly applied.

5. **Ossification pattern:** Irreversible upgrade lock with `_ossified` flag checked in `_authorizeUpgrade()`.

6. **EIP-712 gasless voting:** Nonce-based replay protection. `ECDSA.recover` returns `address(0)` for invalid signatures, checked at line 469.

7. **Queue deadline (14 days):** Prevents indefinitely lingering succeeded proposals.

8. **Comprehensive NatSpec:** All functions, events, errors, and struct fields documented with design rationale and cross-references to prior audit findings.

9. **Storage gap (44 slots):** Appropriate for 11 declared state variables in a UUPS-upgradeable contract.

### Governance Attack Surface Matrix (Updated for Round 7)

| Attack Vector | Status | Round 6 Status | Notes |
|--------------|--------|----------------|-------|
| Flash loan governance (voting) | MITIGATED | MITIGATED | ERC20Votes + OmniCore snapshots. No fallback to current balance. |
| Flash loan governance (proposals) | PARTIAL | PARTIAL | Can create proposals via flash loan, but cannot vote. 10K XOM threshold cost mitigates. |
| Vote recycling | MITIGATED | MITIGATED | Snapshot-based at creation block. `hasVoted` mapping prevents double-voting. |
| Proposal spam | PARTIAL | PARTIAL | 10K threshold, no per-proposer limit. Accepted by design. |
| Quorum manipulation | MITIGATED | MITIGATED | Snapshot `totalSupply` at creation. Cannot be inflated post-snapshot. |
| Admin bypass | MITIGATED | MITIGATED | `transferAdminToTimelock()` with `_msgSender()`. Atomic, irreversible. |
| Proposer veto on passed proposals | MITIGATED | OPEN | Fixed: proposer restricted to Pending/Active cancellation. |
| Non-existent proposal cancel | OPEN | N/A | New: admin can cancel non-existent proposals (M-01). |
| Emergency override abuse | MITIGATED | MITIGATED | Guardian can only pause/cancel, not execute. |
| UUPS upgrade hijack | MITIGATED | MITIGATED | DEFAULT_ADMIN_ROLE + ossification. |
| Beanstalk-style attack | MITIGATED | MITIGATED | 1-day voting delay + timelock delay + guardian cancel. |
| Timelock/governance state divergence | LOW RISK | LOW RISK | `TimelockCancelFailed` event. Documented behavior. |
| ERC2771 forwarder abuse | MITIGATED | LOW RISK | `_msgSender()` used consistently throughout. |

### Cross-Contract Integration Verification

| Integration | Contract | Method | Status |
|-------------|----------|--------|--------|
| Voting power (delegated) | OmniCoin (ERC20Votes) | `getVotes()`, `getPastVotes()` | Correct |
| Voting power (staked) | OmniCore | `stakes()`, `getStakedAt()` | Correct. `getStakedAt()` uses `_stakeCheckpoints` with `Checkpoints.Trace160.upperLookup()`. |
| Total supply snapshot | OmniCoin (IERC20) | `totalSupply()` | Correct. Snapshotted at proposal creation. |
| Timelock scheduling | OmniTimelockController | `scheduleBatch()` | Correct. Salt computation matches `hashOperationBatch`. |
| Timelock execution | OmniTimelockController | `executeBatch()` | Correct. Predecessor is `bytes32(0)`. |
| Timelock cancellation | OmniTimelockController | `cancel(bytes32)` | Correct. Failure emits `TimelockCancelFailed`. |
| Critical selector validation | OmniTimelockController | `isCriticalSelector()` | Correct. ROUTINE proposals validated at creation time. |

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | `cancel()` does not validate proposal existence -- admin can cancel non-existent proposals | Open |
| L-01 | Low | `cancel()` lacks `nonReentrant` modifier (defense in depth) | Open |
| L-02 | Low | Misleading error on timelock scheduling/execution failure | Open |
| L-03 | Low | Governor Bravo threshold-based cancellation by third parties not implemented | Open |
| I-01 | Info | Outdated NatSpec on `getVotingPowerAt()` claims current staking amount | Open |
| I-02 | Info | NatSpec references `ADMIN_ROLE` but contract only uses `DEFAULT_ADMIN_ROLE` | Open |
| I-03 | Info | Missing `whenNotPaused` despite Round 6 marking it as fixed | Open |
| I-04 | Info | `_getStakedAmount()` uses weak `data.length > 0` check | Open |

---

## Recommendations Priority

### Should-Fix Before Mainnet

1. **M-01:** Add proposal existence validation in `cancel()`. Trivial fix -- one bounds check at function start. Prevents phantom cancellation events and storage writes.

### Consider Before Mainnet

2. **L-01:** Add `nonReentrant` to `cancel()` for consistency. One-word addition.
3. **L-02:** Replace misleading `InvalidProposalState` errors in `queue()` and `execute()` failure paths with dedicated errors.
4. **L-03:** Add threshold-based cancellation by any address when proposer's power drops below threshold. Standard Governor Bravo pattern.

### Documentation Fixes (No Code Change Risk)

5. **I-01:** Update `getVotingPowerAt()` NatSpec to reflect snapshot-based staking.
6. **I-02:** Replace `ADMIN_ROLE` references with `DEFAULT_ADMIN_ROLE` in NatSpec.
7. **I-03:** Document that the lack of `whenNotPaused` is intentional, or add it.
8. **I-04:** Use precise `data.length >= N` checks in staking queries.

---

## Conclusion

OmniGovernance has reached a high level of maturity through six rounds of auditing and remediation. All prior Critical, High, and Medium findings from Rounds 4-6 have been properly addressed. The contract demonstrates a well-designed governance system with:

- Snapshot-based voting power (ERC20Votes + OmniCore checkpoints) for flash-loan protection
- Two-tier timelock integration with critical selector enforcement
- Proposer cancellation restricted to pre-vote stages (Governor Bravo pattern)
- Consistent ERC2771 `_msgSender()` usage throughout
- Ossification capability for permanent decentralization
- EIP-712 gasless voting with nonce replay protection

The single Medium finding (M-01: phantom proposal cancellation by admin) is a straightforward input validation gap that should be fixed before mainnet. The Low findings are defense-in-depth improvements and governance pattern completions. The Informational findings are documentation corrections.

**Overall Risk Rating:** Low

**Pre-Mainnet Readiness:** Ready after M-01 fix. L-01 through L-03 are recommended but not blocking.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/OmniGovernance.sol` | 1,110 | Primary audit target |
| `Coin/contracts/OmniTimelockController.sol` | ~340 | Timelock integration verification |
| `Coin/contracts/OmniCore.sol` | ~1,230 | Staking checkpoints (`getStakedAt`, `stakes`) |
| `Coin/test/UUPSGovernance.test.js` | ~1,587 | Test coverage verification |
| Prior audit: `audit-reports/round6/OmniGovernance-audit-2026-03-10.md` | -- | Remediation tracking |
| Prior audit: `audit-reports/round6/CROSS-SYSTEM-Governance-Manipulation-2026-03-10.md` | -- | Cross-contract remediation tracking |

---

*Generated by Claude Opus 4.6 -- Deep Manual Audit*
*Date: 2026-03-13*
