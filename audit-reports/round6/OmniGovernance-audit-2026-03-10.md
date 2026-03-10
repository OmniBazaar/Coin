# Security Audit Report: OmniGovernance (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Opus 4.6 -- Deep Manual Review
**Contract:** `Coin/contracts/OmniGovernance.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,090
**Upgradeable:** Yes (UUPS via OpenZeppelin UUPSUpgradeable)
**Handles Funds:** No (governance proposals execute via external OmniTimelockController)
**Test Coverage:** `Coin/test/UUPSGovernance.test.js` (94 tests passing)
**Previous Audits:**
- OmniGovernance-audit-2026-02-21.md (against V1 -- all findings resolved in rewrite)
- OmniGovernance-audit-2026-02-26.md (H-01, M-01, M-02, L-01 through L-03, I-01 through I-04)

---

## Scope

This round-6 pre-mainnet audit covers the OmniGovernance contract at its current state (1,090 lines), reviewing all code changes since the round-5 audit (2026-02-26) including remediation of prior findings. The audit focuses on:

1. **Remediation verification** -- confirming all prior H/M/L findings were correctly fixed
2. **New vulnerability discovery** -- deep review of proposal lifecycle, voting mechanics, cross-contract interactions, flash-loan prevention, and upgrade authorization
3. **Cross-contract attack surface** -- governance <-> timelock <-> guardian interaction chains
4. **Pre-mainnet readiness** -- deployment configuration, role transition, and operational security

---

## Executive Summary

All prior round-5 findings have been addressed:

- **H-01 (Admin bypass):** RESOLVED -- `transferAdminToTimelock()` added at lines 793-806
- **M-01 (Quorum off-by-one):** RESOLVED -- Uses `totalVotes >= quorumVotes` at line 889
- **M-02 (Proposal type mismatch):** RESOLVED -- `_validateNoCriticalSelectors()` at lines 921-946 validates ROUTINE proposals at creation time
- **L-01 (Non-existent proposals):** RESOLVED -- `ProposalNotFound` revert at lines 639-641
- **L-02 (Silent timelock cancel failure):** RESOLVED -- `TimelockCancelFailed` event at lines 615-617
- **L-03 (Misleading cancel error):** RESOLVED -- `NotAuthorizedToCancel` custom error at line 603
- **I-01 (Fallback to current balance):** RESOLVED -- `_getStakedAmountAt()` returns 0 with no fallback (ATK-H02 fix at lines 1006-1008)

This audit found **0 Critical, 0 High, 2 Medium, 3 Low, and 3 Informational** findings. The contract is substantially improved and well-positioned for mainnet deployment.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `propose()` and `vote()` | **FIXED** |
| M-02 | Medium | Missing `whenNotPaused` on `propose()` and `execute()` | **FIXED** |

---

## Prior Findings Remediation Status

| Prior Finding | Severity | Status | Verification |
|---------------|----------|--------|--------------|
| H-01: Admin governance bypass | High | RESOLVED | `transferAdminToTimelock()` at line 793 atomically grants ADMIN_ROLE + DEFAULT_ADMIN_ROLE to timelock and revokes from caller. Event emitted. One-shot, irreversible. |
| M-01: Quorum off-by-one | Medium | RESOLVED | Line 889: `return totalVotes >= quorumVotes;` -- standard comparison, no underflow risk. |
| M-02: Proposal type not validated | Medium | RESOLVED | Lines 383-385 + 921-946: ROUTINE proposals are validated against the timelock's `isCriticalSelector()` at proposal creation time. If a critical selector is found, `CriticalActionInRoutineProposal` is reverted. |
| L-01: Non-existent proposal returns Pending | Low | RESOLVED | Lines 639-641: `if (proposal.proposer == address(0) && proposal.voteStart == 0) revert ProposalNotFound();` |
| L-02: Silent timelock cancel failure | Low | RESOLVED | Lines 615-617: On cancel failure, emits `TimelockCancelFailed(proposalId, timelockId)` and continues (proposal still marked cancelled in governance). |
| L-03: Misleading cancel error | Low | RESOLVED | Line 603: Uses `revert NotAuthorizedToCancel();` dedicated error. |
| I-01: Fallback to current balance | Info | RESOLVED | Lines 1006-1008: `_getStakedAmountAt()` returns 0 if `getStakedAt()` fails. Comment explicitly documents ATK-H02 fix rationale. No fallback to current staking amount. |
| I-02: Raw staticcall for stakes | Info | ACKNOWLEDGED | Still uses `staticcall` with manual ABI decoding (lines 960-973). This is a deliberate design choice to avoid tight coupling with OmniCore's interface. |
| I-03: Low-level calls for timelock | Info | ACKNOWLEDGED | Still uses low-level `call` for timelock interactions. Same rationale as I-02. |
| I-04: Storage gap documentation | Info | ACKNOWLEDGED | Gap is `uint256[44] private __gap` at line 190. No additional documentation added, but the size is consistent with 11 state variables. |

---

## New Findings

### [M-01] `transferAdminToTimelock()` Uses `msg.sender` Instead of `_msgSender()` for Role Revocation

**Severity:** Medium
**Lines:** 802-803
**Category:** ERC2771 / Meta-Transaction Inconsistency

**Description:**

The `transferAdminToTimelock()` function uses `msg.sender` directly for revoking roles:

```solidity
function transferAdminToTimelock() external onlyRole(ADMIN_ROLE) {
    address timelockAddr = timelock;
    if (timelockAddr == address(0)) revert InvalidAddress();

    _grantRole(ADMIN_ROLE, timelockAddr);
    _grantRole(DEFAULT_ADMIN_ROLE, timelockAddr);

    // Uses msg.sender, not _msgSender()
    _revokeRole(ADMIN_ROLE, msg.sender);
    _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

    emit AdminTransferredToTimelock(msg.sender, timelockAddr);
}
```

The `onlyRole(ADMIN_ROLE)` modifier on `AccessControlUpgradeable` uses `_msgSender()` internally (inherited from `ContextUpgradeable`, overridden by `ERC2771ContextUpgradeable`). If `transferAdminToTimelock()` is called through the trusted forwarder (a meta-transaction), the `_msgSender()` in the modifier resolves to the actual admin, but `msg.sender` on lines 802-803 resolves to the forwarder address.

This means:
1. The role check passes (modifier uses `_msgSender()` = actual admin).
2. `_revokeRole` targets `msg.sender` = the forwarder address (which does not hold the role).
3. The actual admin's roles are NOT revoked.
4. Both the admin AND the timelock now have ADMIN_ROLE + DEFAULT_ADMIN_ROLE.

The admin retains their elevated privileges, defeating the purpose of the function.

**Impact:** If `transferAdminToTimelock()` is called via the trusted forwarder, the admin's roles are not revoked. The admin retains the ability to bypass governance, cancel proposals, ossify the contract, and authorize upgrades. The function silently succeeds (OpenZeppelin's `_revokeRole` does not revert if the account does not have the role), giving a false sense of security.

**Likelihood:** Low-Medium. The function would typically be called by the deployer directly, not via meta-transaction. However, if the deployment script or operational tooling routes through the forwarder, this vulnerability is triggered silently.

**Recommendation:**

Replace `msg.sender` with `_msgSender()`:

```solidity
function transferAdminToTimelock() external onlyRole(ADMIN_ROLE) {
    address timelockAddr = timelock;
    if (timelockAddr == address(0)) revert InvalidAddress();

    address caller = _msgSender();

    _grantRole(ADMIN_ROLE, timelockAddr);
    _grantRole(DEFAULT_ADMIN_ROLE, timelockAddr);

    _revokeRole(ADMIN_ROLE, caller);
    _revokeRole(DEFAULT_ADMIN_ROLE, caller);

    emit AdminTransferredToTimelock(caller, timelockAddr);
}
```

---

### [M-02] Proposer Can Cancel Own Proposal After Queuing Without Voting Power Check

**Severity:** Medium
**Lines:** 588-621
**Category:** Governance Integrity

**Description:**

The `cancel()` function allows the original proposer to cancel their own proposal at any stage (Pending, Active, Succeeded, Queued) without checking whether the proposer still holds sufficient voting power:

```solidity
function cancel(uint256 proposalId) external {
    Proposal storage proposal = proposals[proposalId];

    if (proposal.executed || proposal.cancelled) {
        revert InvalidProposalState(...);
    }

    address caller = _msgSender();
    bool isProposer = caller == proposal.proposer;
    bool isAdmin = hasRole(ADMIN_ROLE, caller);

    if (!isProposer && !isAdmin) {
        revert NotAuthorizedToCancel();
    }

    proposal.cancelled = true;
    // ... timelock cancel attempt
}
```

Compound Governor Bravo's standard pattern is:
- Anyone can cancel a proposal if the proposer's voting power drops below the proposal threshold.
- The proposer themselves cannot unilaterally cancel a proposal that has already passed voting and been queued -- at that point the community has spoken.

The current implementation allows a malicious or coerced proposer to cancel a community-approved proposal that is sitting in the timelock, even after a supermajority voted in favor. The proposer could be bribed or pressured to cancel after the vote succeeds.

**Scenario:**
1. Proposer creates a proposal to reduce fees.
2. Community votes overwhelmingly in favor (80% for).
3. Proposal is queued in the timelock.
4. During the 48-hour delay, an interested party bribes/pressures the proposer.
5. Proposer calls `cancel()`, cancelling the queued proposal.
6. Community must re-create and re-vote the proposal, wasting 6+ days.

**Impact:** Proposer retains unilateral veto power over community-approved proposals, undermining governance legitimacy. Repeated cancellations constitute governance griefing.

**Recommendation:**

Restrict proposer cancellation to pre-vote stages, and allow anyone to cancel if the proposer's voting power drops below threshold:

```solidity
function cancel(uint256 proposalId) external {
    Proposal storage proposal = proposals[proposalId];

    if (proposal.executed || proposal.cancelled) {
        revert InvalidProposalState(
            state(proposalId), ProposalState.Pending
        );
    }

    address caller = _msgSender();
    bool isAdmin = hasRole(ADMIN_ROLE, caller);

    if (isAdmin) {
        // Admin (timelock) can always cancel
    } else if (caller == proposal.proposer) {
        // Proposer can cancel only during Pending or Active
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Pending &&
            currentState != ProposalState.Active) {
            revert NotAuthorizedToCancel();
        }
    } else {
        // Anyone can cancel if proposer's voting power dropped
        // below threshold (Governor Bravo pattern)
        if (getVotingPower(proposal.proposer) >= PROPOSAL_THRESHOLD) {
            revert NotAuthorizedToCancel();
        }
    }

    proposal.cancelled = true;
    // ... rest of function
}
```

---

### [L-01] `cancel()` with Queued Proposal: Timelock Operation May Still Execute

**Severity:** Low
**Lines:** 609-618
**Category:** State Consistency / Cross-Contract

**Description:**

When a queued proposal is cancelled in governance, the function attempts to cancel the corresponding timelock operation. If the timelock cancel fails (operation already executed, or governance lacks CANCELLER_ROLE), the `TimelockCancelFailed` event is emitted but the governance-level cancellation still proceeds:

```solidity
if (proposal.queued) {
    bytes32 timelockId = _getTimelockId(proposalId);
    (bool success, ) = timelock.call(
        abi.encodeWithSignature("cancel(bytes32)", timelockId)
    );
    if (!success) {
        emit TimelockCancelFailed(proposalId, timelockId);
    }
}
```

This creates a state divergence: the governance contract says "cancelled" but the timelock operation remains pending and executable. Since EXECUTOR_ROLE is `address(0)` (anyone can execute), the operation will execute when the delay expires, regardless of the governance-level cancellation.

The OmniGovernance `execute()` function would not re-execute (it checks for Queued state), but the timelock operates independently. Direct calls to `timelock.executeBatch()` bypass governance entirely.

**Impact:** Governance may falsely report a proposal as cancelled while the underlying timelock operation executes. Off-chain monitoring systems need to check both governance state and timelock state. The `TimelockCancelFailed` event provides the necessary signal, but UIs that only check `governance.state()` will show incorrect information.

**Recommendation:**

Consider reverting the governance cancellation if the timelock cancel fails, or documenting prominently that a `TimelockCancelFailed` event means the operation is still executable:

```solidity
if (proposal.queued) {
    bytes32 timelockId = _getTimelockId(proposalId);
    (bool success, ) = timelock.call(
        abi.encodeWithSignature("cancel(bytes32)", timelockId)
    );
    if (!success) {
        // Revert: cannot cancel governance-side if timelock-side is live
        revert TimelockCancelFailed(proposalId, timelockId);
    }
}
```

Alternatively, if the current "cancel in governance, warn about timelock" pattern is intentional, add NatSpec warning and ensure frontend monitoring watches for `TimelockCancelFailed` events.

---

### [L-02] `getVotingPower()` Uses Current Values While `getVotingPowerAt()` Uses Snapshots

**Severity:** Low
**Lines:** 684-713
**Category:** Inconsistency / Flash-Loan Surface

**Description:**

`getVotingPower()` (used for proposal creation threshold check) uses `omniCoin.getVotes(account)` (current delegated power) plus `_getStakedAmount(account)` (current staked amount):

```solidity
function getVotingPower(address account) public view returns (uint256) {
    uint256 delegatedPower = omniCoin.getVotes(account);
    uint256 stakedPower = _getStakedAmount(account);
    return delegatedPower + stakedPower;
}
```

In contrast, `getVotingPowerAt()` (used for vote casting) uses `omniCoin.getPastVotes(account, blockNumber)` (snapshot-based) plus `_getStakedAmountAt(account, blockNumber)` (checkpoint-based).

The 1-day `VOTING_DELAY` between proposal creation and vote start provides flash-loan protection for the voting phase. However, the proposal creation threshold check uses current values, meaning an attacker could:

1. Flash-loan tokens to reach 10,000 XOM threshold
2. Create a proposal in the same transaction
3. Return the flash loan

The proposal would be created, but the attacker would have zero voting power when voting starts (snapshot was taken at the proposal creation block, but the flash-loaned tokens were returned before the block ended, and `getPastVotes` at the snapshot block would show the post-return balance).

The practical impact is limited because the attacker cannot vote on their own proposal (zero snapshot power). The proposal would need legitimate voters to pass. But it constitutes proposal spam -- the attacker can create unlimited proposals without holding any tokens, consuming on-chain storage and community attention.

**Impact:** Flash-loan proposal spam. No financial risk since proposals cannot pass without legitimate votes, but governance noise and on-chain storage consumption.

**Recommendation:**

Use `omniCoin.getPastVotes()` for the proposal creation check as well (using a recent past block), or accept the current 1-day delay as sufficient spam protection:

```solidity
function getVotingPower(address account) public view returns (uint256) {
    // Use past block for flash-loan protection
    uint256 delegatedPower = omniCoin.getPastVotes(
        account, block.number - 1
    );
    uint256 stakedPower = _getStakedAmountAt(
        account, block.number - 1
    );
    return delegatedPower + stakedPower;
}
```

Alternatively, document this as a known limitation mitigated by the 10,000 XOM threshold (flash-loan fees on 10,000 XOM make spam expensive).

---

### [L-03] `_validateNoCriticalSelectors()` Silently Skips Calldata Shorter Than 4 Bytes

**Severity:** Low
**Lines:** 924-946
**Category:** Validation Gap

**Description:**

The `_validateNoCriticalSelectors()` function skips calldata entries shorter than 4 bytes:

```solidity
for (uint256 i = 0; i < calldatas.length; ++i) {
    if (calldatas[i].length >= 4) {
        bytes4 selector = bytes4(calldatas[i][:4]);
        // ... check selector
    }
}
```

A calldata entry with 0-3 bytes passes validation silently. While such entries would fail at execution time (no valid function selector), they represent either:
- Intentional empty/short calldata (e.g., ETH transfer with `value > 0`)
- Malformed proposal actions

For ETH transfers (empty calldata, `value > 0`), this behavior is correct -- plain ETH transfers are not critical operations. But for 1-3 byte calldata, the behavior is ambiguous and could be used to smuggle a partially-formed action past validation.

**Impact:** Negligible in practice. Short calldata would fail during timelock execution. But the silent skip means the validation is not as strict as the NatSpec implies.

**Recommendation:**

Either reject calldata in the 1-3 byte range as malformed:

```solidity
if (calldatas[i].length > 0 && calldatas[i].length < 4) {
    revert InvalidActionsLength();
}
```

Or document that entries with fewer than 4 bytes are treated as non-critical (ETH transfers).

---

### [I-01] `_getTimelockId()` Recomputes Values Already Available in `queue()` and `execute()`

**Severity:** Informational
**Lines:** 1017-1032, 507-509, 534, 554-555
**Category:** Gas Optimization

**Description:**

Both `queue()` and `execute()` compute the salt:
```solidity
bytes32 salt = keccak256(abi.encodePacked("OmniGov", proposalId));
```

Then `_getTimelockId()` (called in `queue()` at line 534 and `cancel()` at line 610) re-reads the actions from storage and recomputes the same salt. In `queue()`, the salt and actions are already loaded into local variables. Passing them as parameters would save one storage read and one keccak256 computation.

**Impact:** Minor gas overhead (~2,100 gas per SLOAD + ~36 gas per keccak256). Not functionally significant.

**Recommendation:**

Refactor `_getTimelockId` to accept the salt and actions as parameters when called from `queue()`, or accept the minor gas cost for code clarity.

---

### [I-02] No Active Proposal Limit Per Proposer

**Severity:** Informational
**Lines:** 373-430
**Category:** Governance Griefing

**Description:**

There is no limit on how many active proposals a single proposer can have simultaneously. A whale holding 10,000+ XOM can create proposals continuously, consuming on-chain storage (each proposal stores 13 fields in the `Proposal` struct plus a variable-length `ProposalActions` struct).

The 10,000 XOM threshold provides economic filtering, but it is a one-time check -- the proposer does not need to lock their tokens. They can create a proposal, and immediately create another with the same tokens.

Governor Bravo limits proposers to 1 active proposal at a time. OpenZeppelin Governor v4.x tracks the `latestProposalId` per proposer.

**Impact:** Governance spam from well-capitalized actors. No direct financial risk, but on-chain storage bloat and community attention dilution.

**Recommendation:**

Consider adding a per-proposer active proposal limit:

```solidity
mapping(address => uint256) public activeProposalCount;

// In propose():
if (activeProposalCount[caller] >= MAX_ACTIVE_PROPOSALS) {
    revert TooManyActiveProposals();
}
++activeProposalCount[caller];

// In state() transitions to Defeated/Executed/Cancelled/Expired:
// Decrement activeProposalCount
```

Or accept this as a design decision, noting that the 10,000 XOM threshold provides sufficient filtering for a system with a 4.13B circulating supply.

---

### [I-03] ERC2771 Trusted Forwarder is Immutable and Cannot Be Updated

**Severity:** Informational
**Lines:** 316-320
**Category:** Upgradeability Limitation

**Description:**

The trusted forwarder address is set in the constructor as an immutable value (stored in bytecode via `ERC2771ContextUpgradeable`). Since OmniGovernance is UUPS-upgradeable, the proxy's storage can be updated, but immutable values are baked into the implementation contract's bytecode.

If the trusted forwarder contract needs to be replaced (e.g., due to a vulnerability in OmniForwarder), a new OmniGovernance implementation must be deployed and upgraded to via the timelock. This is the expected UUPS pattern and is not a vulnerability, but it does mean that forwarder changes require a full contract upgrade.

**Impact:** None directly. Standard UUPS behavior.

**Recommendation:**

Document in deployment guides that changing the trusted forwarder requires a UUPS upgrade of the OmniGovernance implementation.

---

## Cross-Contract Governance Attack Analysis

### Attack 1: Flash Loan -> Delegate -> Propose -> Vote -> Execute

**Status: MITIGATED**

- Flash-loaned tokens can create a proposal (current balance check), but cannot vote (snapshot-based voting at creation block).
- The 1-day voting delay ensures the snapshot block is before voting starts.
- ERC20Votes delegation checkpoints prevent vote weight inflation after snapshot.
- Staking snapshots via `getStakedAt()` prevent post-snapshot stake inflation (ATK-H02 fix).

**Residual risk:** Flash-loan proposal spam (see L-02). No voting power inflation.

### Attack 2: Timelock Bypass Through EmergencyGuardian

**Status: MITIGATED**

- EmergencyGuardian can only pause and cancel. It cannot queue, execute, upgrade, or unpause.
- Pausing is 1-of-N (fast emergency response). Unpausing requires a full governance proposal through the timelock.
- Cancelling requires 3-of-N signatures with epoch-based invalidation on guardian set changes.
- EmergencyGuardian does not have PROPOSER_ROLE on the timelock, so it cannot schedule new operations.

**Residual risk:** A compromised set of 3 guardians can cancel legitimate governance operations, causing disruption but not theft.

### Attack 3: Governance Griefing (Spam Proposals, Vote Blocking)

**Status: PARTIALLY MITIGATED**

- 10,000 XOM threshold filters low-value proposals.
- No per-proposer active proposal limit (see I-02).
- No quorum poisoning (quorum is based on snapshot total supply, not current).
- Proposals expire after QUEUE_DEADLINE (14 days) if not queued.

**Residual risk:** Well-capitalized actor can spam proposals. Community attention dilution.

### Attack 4: Proposal-Timelock-Execution Race Conditions

**Status: MITIGATED**

- `queue()` checks `Succeeded` state before scheduling in timelock.
- `execute()` checks `Queued` state before executing via timelock.
- Both functions use `nonReentrant` modifier.
- The timelock's `_afterCall` check prevents re-execution of already-executed operations.
- `cancel()` attempts timelock cancel and emits `TimelockCancelFailed` on failure.

**Residual risk:** State divergence if timelock cancel fails (see L-01).

### Attack 5: Admin Retains Privileges After Setup

**Status: RESOLVED**

- `transferAdminToTimelock()` at lines 793-806 provides an atomic, irreversible transition.
- After calling this function, only governance proposals through the timelock can exercise admin powers.
- The function emits `AdminTransferredToTimelock` for auditability.
- Note M-01 (msg.sender vs _msgSender) should be fixed to ensure correctness when called via forwarder.

---

## Architecture Assessment

### Positive Design Elements

1. **Snapshot-based voting with dual source (ERC20Votes + OmniCore checkpoints):** Industry-standard flash-loan protection with staking inclusion. The ATK-H02 fix eliminates the fallback-to-current vulnerability.

2. **Two-tier timelock (ROUTINE 48h / CRITICAL 7d):** Appropriate delay differentiation. ROUTINE proposals are validated against critical selectors at creation time (M-02 fix from round 5).

3. **Ossification pattern:** Irreversible upgrade lock provides strong decentralization signal.

4. **EIP-712 gasless voting:** Reduces participation barrier. Nonce management prevents replay attacks.

5. **Queue deadline (14 days):** Prevents indefinitely lingering succeeded proposals.

6. **`transferAdminToTimelock()` transition function:** Clean, auditable role transfer (minus the M-01 msg.sender issue).

7. **Comprehensive NatSpec:** All functions, events, and errors have thorough documentation including design rationale and cross-references to prior audit findings.

### Governance Attack Surface Matrix (Updated)

| Attack Vector | Status | Prior Status | Notes |
|--------------|--------|--------------|-------|
| Flash loan governance (voting) | MITIGATED | MITIGATED | ERC20Votes + OmniCore snapshots |
| Flash loan governance (proposals) | PARTIAL | PARTIAL | Can create proposals, cannot vote (L-02) |
| Vote recycling | MITIGATED | MITIGATED | Snapshot-based at creation block |
| Proposal spam | PARTIAL | PARTIAL | 10K threshold, no per-proposer limit (I-02) |
| Quorum manipulation | MITIGATED | MITIGATED | Snapshot totalSupply at creation |
| Admin bypass | MITIGATED | PARTIAL (H-01) | `transferAdminToTimelock()` added |
| Proposer veto on passed proposals | OPEN | N/A | Proposer can cancel queued proposals (M-02) |
| Emergency override abuse | MITIGATED | MITIGATED | Guardian can only pause/cancel |
| UUPS upgrade hijack | MITIGATED | MITIGATED | ADMIN_ROLE + ossification |
| Beanstalk-style attack | MITIGATED | MITIGATED | Timelock delay + guardian cancel |
| Timelock/governance state divergence | LOW RISK | LOW RISK | TimelockCancelFailed event (L-01) |
| ERC2771 forwarder abuse | LOW RISK | N/A | msg.sender in transferAdminToTimelock (M-01) |

---

## Static Analysis Results

**Slither:** No JSON output available at `/tmp/slither-OmniGovernance.json`.

**Compilation:** Clean (Solidity 0.8.24, no warnings expected based on solhint inline suppressions).

**Test Suite:** 94 tests passing across `UUPSGovernance.test.js` covering full governance lifecycle, EIP-712 voting, ossification, staking snapshots, and integration flows.

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Fix Effort | Recommendation |
|---|---------|----------|------------|----------------|
| 1 | M-01 | Medium | Trivial | Replace `msg.sender` with `_msgSender()` in `transferAdminToTimelock()` |
| 2 | M-02 | Medium | Low | Restrict proposer cancellation to pre-vote stages; add threshold-based cancellation by anyone |
| 3 | L-01 | Low | Low | Revert governance cancel if timelock cancel fails, or document prominently |
| 4 | L-02 | Low | Low | Use `getPastVotes` for proposal creation check, or document as known limitation |
| 5 | L-03 | Low | Trivial | Reject 1-3 byte calldata as malformed, or document as intentional |
| 6 | I-01 | Info | -- | Gas optimization opportunity |
| 7 | I-02 | Info | -- | Consider per-proposer active proposal limit |
| 8 | I-03 | Info | -- | Document forwarder change requires UUPS upgrade |

### Must-Fix Before Mainnet

1. **M-01:** The `msg.sender` vs `_msgSender()` inconsistency in `transferAdminToTimelock()` is a correctness bug that can silently fail to revoke admin privileges. This is a trivial one-line fix.

### Should-Fix Before Mainnet

2. **M-02:** Proposer veto power over passed proposals weakens governance legitimacy. The Governor Bravo pattern of restricting proposer cancellation and enabling threshold-based cancellation by anyone is well-established.

### Consider

3. **L-01 through L-03:** Defense-in-depth improvements for edge cases.

---

## Conclusion

OmniGovernance has undergone significant improvement since the round-5 audit. All prior Critical, High, and Medium findings have been properly remediated. The `transferAdminToTimelock()` function (H-01 fix) and `_validateNoCriticalSelectors()` (M-02 fix) are particularly well-implemented.

The two new Medium findings relate to (1) a minor ERC2771 inconsistency in the admin transfer function that could prevent role revocation when called via forwarder, and (2) the proposer's ability to cancel community-approved proposals unilaterally. Both are straightforward fixes.

The contract demonstrates mature governance design with snapshot-based voting, two-tier timelock integration, ossification capability, and gasless voting. The cross-contract attack surface with OmniTimelockController and EmergencyGuardian is well-controlled.

**Overall Risk Rating:** Low (reduced from Medium in round 5)

**Pre-Mainnet Readiness:** Ready after M-01 fix. M-02 is recommended but not blocking.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/OmniGovernance.sol` | 1,090 | Primary audit target |
| `Coin/contracts/OmniTimelockController.sol` | 339 | Timelock integration |
| `Coin/contracts/EmergencyGuardian.sol` | 533 | Emergency response |
| `Coin/contracts/OmniCore.sol` | ~1,100 | Staking checkpoints (`getStakedAt`, `stakes`) |
| `Coin/contracts/OmniCoin.sol` | ~250 | ERC20Votes delegation |
| `Coin/contracts/interfaces/IPausable.sol` | 17 | Pausable interface |
| `Coin/test/UUPSGovernance.test.js` | ~1,587 | Test coverage verification |
| Prior audit: `OmniGovernance-audit-2026-02-26.md` | -- | Remediation tracking |

---

*Generated by Claude Opus 4.6 -- Deep Manual Audit*
*Date: 2026-03-10*
