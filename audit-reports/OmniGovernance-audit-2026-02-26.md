# Security Audit Report: OmniGovernance (UUPS Upgradeable)

**Date:** 2026-02-26
**Audited by:** Claude Opus 4.6 -- Deep Manual Review
**Contract:** `Coin/contracts/OmniGovernance.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 914 (including NatSpec and whitespace)
**Upgradeable:** Yes (UUPS via OpenZeppelin UUPSUpgradeable)
**Handles Funds:** No (governance proposals execute via external OmniTimelockController)
**Test Coverage:** 94 tests passing (UUPSGovernance.test.js)
**Previous Audit:** OmniGovernance-audit-2026-02-21.md (against obsolete V1 contract -- all prior findings resolved)

## Scope

This audit covers the rewritten OmniGovernance contract, which is a UUPS-upgradeable on-chain governance system with:
- Two proposal types (ROUTINE: 48h timelock, CRITICAL: 7-day timelock)
- Snapshot-based voting via ERC20Votes delegation + OmniCore staking checkpoints
- EIP-712 gasless voting (castVoteBySig)
- On-chain execution through OmniTimelockController
- Ossification pattern (permanent upgrade lock)
- EmergencyGuardian integration (pause + 3-of-5 cancel)

The audit also reviewed the interacting contracts: OmniTimelockController (283 lines), EmergencyGuardian (318 lines), and relevant portions of OmniCore (staking checkpoints) and OmniCoin (ERC20Votes).

## Executive Summary

The contract has been completely rewritten since the prior audit (2026-02-21). All Critical and High findings from the prior audit have been resolved:

- **C-01 (Flash loan / vote recycling):** RESOLVED. Voting power now uses ERC20Votes `getPastVotes()` with snapshot at proposal creation block, plus OmniCore `getStakedAt()` checkpoint-based staking snapshots. Vote recycling via token transfer is impossible.
- **H-01 (Staker disenfranchisement):** RESOLVED. Staked XOM is now included in voting power via `_getStakedAmountAt()`.
- **M-01 (Mutable totalSupply quorum):** RESOLVED. `snapshotTotalSupply` is captured at proposal creation.
- **M-02 (No voting delay):** RESOLVED. 1-day `VOTING_DELAY` constant is enforced.
- **M-03 (False NatSpec):** RESOLVED. NatSpec accurately describes snapshot-based voting.
- **M-04 (Zero address CORE):** RESOLVED. `initialize()` validates all addresses against zero.

The rewritten contract follows Compound Governor Bravo / OpenZeppelin Governor patterns and represents a substantial improvement. This audit found **0 Critical**, **1 High**, **2 Medium**, **3 Low**, and **4 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 3 |
| Informational | 4 |

---

## Findings

### [H-01] Governance Bypass via Direct Timelock Scheduling -- ADMIN_ROLE Holder Can Skip Governance Vote

**Severity:** High
**Lines:** 292-316 (initialize), OmniTimelockController.sol lines 210, 235
**Category:** Access Control / Governance Bypass

**Description:**

During `initialize()`, the `admin` parameter receives both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` on the OmniGovernance contract. Separately, in the deployment flow (visible in the test suite), the deployer also has `PROPOSER_ROLE` on the OmniTimelockController. This means the deployer can:

1. Schedule operations directly on the timelock (bypassing governance voting entirely)
2. Call `ossify()` on OmniGovernance directly (no timelock required)
3. Call `_authorizeUpgrade()` to upgrade the governance contract directly

The `cancel()` function at line 544 also allows the `ADMIN_ROLE` holder to cancel any proposal at any time, including proposals that have already passed and are queued for execution. This creates an asymmetric power: admin can block community governance but cannot be blocked by governance.

The architecture *intends* for the timelock to eventually hold `ADMIN_ROLE` (self-referential governance), and for the deployer to renounce their roles after setup. However, the contract itself does not enforce this transition. If the deployer never renounces, or if the initial multisig is compromised, the entire governance system can be bypassed.

**Impact:** The admin can unilaterally upgrade the governance contract, ossify it to lock in a compromised implementation, or cancel any community proposal. This makes governance advisory rather than binding during the period when admin retains elevated roles.

**Recommendation:**

1. Add a `transferAdminToTimelock()` function that atomically grants ADMIN_ROLE to the timelock and revokes it from the deployer, with an on-chain event. This provides an auditable, irreversible transition.
2. Consider adding an `adminTransitionDeadline` -- a block number after which the admin cannot use elevated powers unless they have been transferred to the timelock.
3. Document the expected deployment sequence explicitly in the contract NatSpec, including when role renunciation must occur.

```solidity
/// @notice Transfer admin authority to the timelock (irreversible)
/// @dev Should be called after governance is fully operational.
///      Revokes ADMIN_ROLE and DEFAULT_ADMIN_ROLE from current admin.
function transferAdminToTimelock() external onlyRole(ADMIN_ROLE) {
    _grantRole(ADMIN_ROLE, timelock);
    _grantRole(DEFAULT_ADMIN_ROLE, timelock);
    _revokeRole(ADMIN_ROLE, msg.sender);
    _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    emit AdminTransferredToTimelock(msg.sender, timelock);
}
```

---

### [M-01] Quorum Off-by-One: `totalVotes > quorumVotes - 1` Allows Quorum at Exactly One Vote Below Intended Threshold

**Severity:** Medium
**Lines:** 808

**Description:**

The `_proposalPassed()` function at line 808 uses:

```solidity
return totalVotes > quorumVotes - 1;
```

This is mathematically equivalent to `totalVotes >= quorumVotes`, which is the intended behavior. However, when `quorumVotes` is 0 (which occurs if `snapshotTotalSupply` is 0), this expression becomes `totalVotes > type(uint256).max` due to unsigned integer underflow, which always returns false. This means that if a proposal is somehow created when `totalSupply()` returns 0 (e.g., all tokens burned or a deployment-time edge case), the proposal can never pass regardless of vote counts.

While the `totalSupply() == 0` scenario is unlikely in practice (genesis supply is 4.13B XOM), it represents a correctness issue. More importantly, the `> x - 1` pattern is non-standard and makes the code harder to audit. Solidity 0.8.x arithmetic would revert on `0 - 1` underflow, making proposals permanently unpossable if supply were ever zero.

**Impact:** Edge case where zero-supply scenario makes all proposals unpossable. Low probability but high impact if triggered.

**Recommendation:**

Replace with the straightforward comparison:

```solidity
return totalVotes >= quorumVotes;
```

This is clearer, avoids the underflow edge case, and matches the standard Governor pattern.

---

### [M-02] Proposal Type Not Validated by Timelock -- OmniGovernance Uses Hardcoded Delays Instead of Leveraging Timelock's Critical Selector Detection

**Severity:** Medium
**Lines:** 458-460 (queue function)

**Description:**

In `queue()`, the delay is determined by `proposal.proposalType`:

```solidity
uint256 delay = proposal.proposalType == ProposalType.CRITICAL
    ? 7 days
    : 48 hours;
```

The OmniTimelockController has its own critical selector detection system (`_isCriticalCall()` / `_batchContainsCritical()`) that independently validates whether a scheduled operation requires CRITICAL_DELAY. However, OmniGovernance hardcodes the delay based on the proposer's self-classification.

This creates a mismatch risk: a proposer could classify a CRITICAL operation (e.g., `upgradeToAndCall`) as ROUTINE, pass it with a 48h delay designation in OmniGovernance, and then call `queue()` which would attempt to schedule it in the timelock with 48h delay. The timelock *would* reject this (because `scheduleBatch` checks critical selectors), causing `queue()` to revert and the proposal to become un-queueable.

The result is that a passed ROUTINE proposal containing critical function selectors can never be executed -- it silently becomes stuck in Succeeded state until it expires after QUEUE_DEADLINE (14 days). Users who voted may not understand why the proposal cannot proceed.

**Impact:** Proposals with mismatched type classification become permanently stuck. No funds at risk, but governance process is disrupted and user trust is damaged.

**Recommendation:**

1. In `queue()`, query the timelock's `getBatchRequiredDelay()` to determine the actual required delay, rather than trusting the proposer's classification:

```solidity
uint256 delay = _getRequiredDelay(actions);
```

2. Alternatively, validate during `propose()` that ROUTINE proposals do not contain critical selectors:

```solidity
if (proposalType == ProposalType.ROUTINE) {
    // Validate no critical selectors in the batch
    for (uint256 i = 0; i < calldatas.length; ++i) {
        if (calldatas[i].length >= 4) {
            (bool isCritical) = IOmniTimelock(timelock)
                .isCriticalSelector(bytes4(calldatas[i][:4]));
            if (isCritical) revert CriticalActionInRoutineProposal();
        }
    }
}
```

---

### [L-01] `state()` Returns `Pending` for Non-Existent Proposals

**Severity:** Low
**Lines:** 592-625

**Description:**

For a `proposalId` that was never created, `proposals[proposalId]` is a zero-initialized struct. The `state()` function checks `proposal.voteStart == 0` and returns `ProposalState.Pending` for this case. This means querying any arbitrary proposal ID (e.g., `state(999999)`) returns `Pending` rather than reverting or returning a distinct "non-existent" state.

This ambiguity means off-chain indexers and frontends cannot distinguish between "proposal exists and is in pending period before voting starts" vs "proposal does not exist." The `queue()` and `execute()` functions are protected (they check for `Succeeded` and `Queued` states respectively), so this is not exploitable, but it is a UX and integration concern.

**Recommendation:**

Add a non-existence check or a separate `NonExistent` state:

```solidity
if (proposal.voteStart == 0 && proposal.proposer == address(0)) {
    revert ProposalDoesNotExist();
}
```

---

### [L-02] `cancel()` Silently Accepts Timelock Cancel Failure

**Severity:** Low
**Lines:** 566-575

**Description:**

When cancelling a queued proposal, the governance contract calls `timelock.cancel(timelockId)` via low-level call. If this fails (e.g., the timelock operation was already executed, or the governance contract lacks CANCELLER_ROLE on the timelock), the failure is silently swallowed:

```solidity
(bool success, ) = timelock.call(
    abi.encodeWithSignature("cancel(bytes32)", timelockId)
);
// If timelock cancel fails (already executed/not pending),
// the governance cancel still proceeds
success; // silence unused warning
```

The governance marks the proposal as `cancelled = true`, but the timelock operation remains pending and will execute after the delay expires. This creates a state inconsistency: governance says "cancelled" but the operation proceeds. Anyone calling `timelock.execute()` (EXECUTOR_ROLE is `address(0)` = anyone) can still execute it.

**Impact:** A proposal marked as cancelled in governance can still execute via the timelock. The `execute()` function on OmniGovernance would revert (because `proposal.cancelled` makes `state()` return `Cancelled`, not `Queued`), but direct execution on the timelock bypasses governance entirely.

**Recommendation:**

Revert if the timelock cancel fails, or at minimum emit an event indicating the timelock cancel failed so off-chain systems can alert:

```solidity
if (!success) {
    emit TimelockCancelFailed(proposalId, timelockId);
}
```

---

### [L-03] `cancel()` Error Message Is Misleading for Authorization Failures

**Severity:** Low
**Lines:** 544-561

**Description:**

When a non-proposer, non-admin calls `cancel()`, the function reverts with:

```solidity
revert InvalidProposalState(
    state(proposalId), ProposalState.Pending
);
```

This error indicates a state issue rather than an authorization issue. The caller receives a confusing error about proposal state when the actual problem is lack of permissions.

Additionally, the original Compound Governor Bravo design allows *anyone* to cancel a proposal if the proposer's voting power drops below the threshold. This is an important safeguard: if a proposer's tokens are sold/transferred after creating a proposal, the community can cancel it. The current implementation only allows the proposer themselves or an admin to cancel.

**Recommendation:**

1. Use a dedicated error: `error NotAuthorizedToCancel();`
2. Consider adding threshold-based cancellation:

```solidity
bool proposerBelowThreshold = getVotingPower(proposal.proposer) < PROPOSAL_THRESHOLD;
if (!isProposer && !isAdmin && !proposerBelowThreshold) {
    revert NotAuthorizedToCancel();
}
```

---

### [I-01] `_getStakedAmountAt()` Fallback to Current Balance Creates Inconsistency Window

**Severity:** Informational
**Lines:** 868-888

**Description:**

`_getStakedAmountAt()` tries `OmniCore.getStakedAt(account, blockNumber)` first. If it fails (call returns false), it falls back to `_getStakedAmount(account)` which reads the *current* staking state. This fallback exists for "backward compatibility with older OmniCore versions."

In the deployed system, OmniCore does implement `getStakedAt()`, so this fallback should never trigger. However, if it did trigger (e.g., OmniCore is paused or upgraded to a version without `getStakedAt()`), the fallback would use current staking amounts for snapshot-based voting, re-introducing the flash-loan vulnerability for the staking component.

**Impact:** No current impact since `getStakedAt()` is implemented. Risk only materializes if OmniCore is replaced with an incompatible version.

**Recommendation:**

Consider reverting instead of falling back:

```solidity
if (success && data.length > 0) {
    return abi.decode(data, (uint256));
}
// If snapshot staking is unavailable, return 0 (conservative)
return 0;
```

---

### [I-02] `_getStakedAmount()` Decodes Five Return Values But Only Uses Two

**Severity:** Informational
**Lines:** 844-857

**Description:**

`_getStakedAmount()` calls `omniCore.staticcall("stakes(address)")` and decodes the return as `(uint256, uint256, uint256, uint256, bool)`, but only uses `stakedAmount` and `active`. The three intermediate values (`tier`, `duration`, `lockTime`) are decoded and discarded.

This is correct and safe (the EVM ABI decoder does not care about unused values), but it means this function will break if OmniCore's `Stake` struct is ever modified to have a different number of fields or different types. Consider using a typed interface instead.

**Recommendation:**

Define a minimal interface:

```solidity
interface IOmniCoreStaking {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }
    function stakes(address user) external view returns (
        uint256 amount, uint256 tier, uint256 duration,
        uint256 lockTime, bool active
    );
}
```

Then call via the interface instead of raw `staticcall`. This provides compile-time type safety and clearer failure modes.

---

### [I-03] Proposal Actions Not Validated Against Timelock EXECUTOR_ROLE

**Severity:** Informational
**Lines:** 469-479 (queue), 516-526 (execute)

**Description:**

Both `queue()` and `execute()` interact with the timelock via low-level `call` rather than typed interface calls. If the governance contract does not have `PROPOSER_ROLE` on the timelock, or if the operation has already been scheduled/executed, the low-level call silently fails and is handled by reverting with a misleading `InvalidProposalState` error.

Using a typed interface (`IOmniTimelockController`) would provide better error messages and prevent ABI encoding mistakes (e.g., if `scheduleBatch` signature changes in a timelock upgrade).

**Recommendation:**

Replace low-level calls with typed interface calls:

```solidity
IOmniTimelockController(timelock).scheduleBatch(
    actions.targets, actions.values, actions.calldatas,
    bytes32(0), salt, delay
);
```

This provides automatic revert reason propagation and type safety.

---

### [I-04] Storage Gap Size Should Be Documented Against Actual Storage Usage

**Severity:** Informational
**Lines:** 181

**Description:**

The storage gap is `uint256[44] private __gap`. For UUPS upgradeable contracts, the total slots (state variables + gap) should sum to a round number (typically 50). The contract has:

- `omniCoin` (1 slot)
- `omniCoinERC20` (1 slot)
- `omniCore` (1 slot)
- `timelock` (1 slot)
- `proposalCount` (1 slot)
- `proposals` mapping (1 slot)
- `_proposalActions` mapping (1 slot)
- `hasVoted` mapping (1 slot)
- `voteWeight` mapping (1 slot)
- `_voteNonces` mapping (1 slot)
- `_ossified` (1 slot)
- `__gap` (44 slots)
- Total: 55 slots

Additionally, the inherited upgradeable contracts (AccessControlUpgradeable, ReentrancyGuardUpgradeable, EIP712Upgradeable, UUPSUpgradeable, Initializable) each have their own storage gaps. The sum across all inheritance is not trivially verifiable.

**Recommendation:**

Add a NatSpec comment documenting the expected total slot count and how the gap was calculated:

```solidity
/// @notice Storage gap for future upgrades
/// @dev 11 state variables + 44 gap = 55 slots for this contract.
///      Inherited gaps: AccessControl(49) + ReentrancyGuard(49) +
///      EIP712(49) + UUPS(49) + Initializable(0) = 196 inherited.
uint256[44] private __gap;
```

---

## Architecture Assessment

### Positive Design Elements

1. **Snapshot-based voting (ERC20Votes + OmniCore checkpoints):** Eliminates the critical flash-loan and vote-recycling vulnerabilities from V1. The `getPastVotes()` mechanism is the industry standard (used by Compound, Uniswap, ENS governance).

2. **Two-tier timelock (ROUTINE 48h / CRITICAL 7d):** Provides appropriate delay for different risk levels. The timelock's critical selector detection independently validates delay requirements, creating a defense-in-depth layer.

3. **Ossification pattern:** The ability to permanently disable upgrades is a strong decentralization signal. Once ossified, the contract becomes immutable even if admin keys are compromised.

4. **EmergencyGuardian integration:** The 1-of-N pause + 3-of-5 cancel architecture provides emergency response capability without granting excessive power. Guardians cannot upgrade, unpause, or create proposals.

5. **EIP-712 gasless voting:** Reduces barrier to participation, especially for smaller token holders who would otherwise pay gas to vote.

6. **1-day voting delay:** Prevents proposal-and-vote-in-same-block attacks, giving the community time to evaluate proposals before voting begins.

7. **Queue deadline (14 days):** Prevents succeeded proposals from lingering indefinitely. Forces timely action or expiration.

8. **Comprehensive test coverage:** 94 tests covering the full governance lifecycle, including edge cases, access control, and integration flows.

### Governance Attack Surface Analysis

| Attack Vector | Status | Notes |
|--------------|--------|-------|
| Flash loan governance | MITIGATED | ERC20Votes snapshots + 1-day voting delay |
| Vote recycling | MITIGATED | Snapshot-based voting power at proposal creation block |
| Proposal spam | MITIGATED | 10,000 XOM threshold filters low-value proposals |
| Quorum manipulation | MITIGATED | Snapshot totalSupply at creation, not execution |
| Timelock bypass | PARTIAL | Admin can schedule directly on timelock (see H-01) |
| Emergency override | MITIGATED | EmergencyGuardian can only pause and cancel, not execute |
| Upgrade hijack | MITIGATED | UUPS + ADMIN_ROLE + ossification pattern |
| Beanstalk-style attack | MITIGATED | Timelock delay provides community review window |

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (all legitimate warnings suppressed with inline comments and documented rationale)

**Compilation:** Clean (Solidity 0.8.24, no warnings)

**Test Suite:** 94/94 passing (28s)

---

## Prior Audit Findings Resolution

| Finding | Severity | Status | Resolution |
|---------|----------|--------|------------|
| C-01: Flash loan / vote recycling | Critical | RESOLVED | ERC20Votes + snapshot voting |
| H-01: Staker disenfranchisement | High | RESOLVED | `_getStakedAmountAt()` includes staked XOM |
| M-01: Mutable totalSupply quorum | Medium | RESOLVED | `snapshotTotalSupply` at creation |
| M-02: No voting delay | Medium | RESOLVED | `VOTING_DELAY = 1 days` |
| M-03: False NatSpec | Medium | RESOLVED | NatSpec accurately describes snapshots |
| M-04: Zero address CORE | Medium | RESOLVED | All addresses validated in `initialize()` |
| L-01: No getService validation | Low | RESOLVED | Direct address storage, no service registry |
| L-02: Misleading cancel error | Low | PARTIALLY | Still uses InvalidProposalState (see L-03 this audit) |
| L-03: No timelock | Low | RESOLVED | Full timelock integration with 2-tier delays |
| L-04: Missing existence check | Low | PARTIALLY | Returns Pending for non-existent (see L-01 this audit) |
| I-01: Indexed proposalHash | Info | RESOLVED | Event structure redesigned |
| I-02: Floating pragma | Info | RESOLVED | Pinned to `0.8.24` |

---

## Conclusion

The OmniGovernance contract has undergone a complete rewrite that resolves all Critical and High findings from the prior audit. The new implementation follows industry-standard patterns (ERC20Votes, TimelockController, UUPS) and includes multiple layers of protection against governance attacks.

The most significant remaining concern is **H-01 (Admin Governance Bypass)**, which is a deployment-configuration issue rather than a code bug. The contract functions correctly, but its security properties depend entirely on the admin role being transferred to the timelock and the deployer renouncing elevated privileges after setup. This transition should be enforced programmatically or at minimum documented as a deployment-blocking prerequisite.

The two Medium findings (M-01: quorum edge case, M-02: proposal type mismatch) represent correctness issues that do not create direct financial risk but could cause governance disruption.

**Overall Assessment:** The contract is well-engineered and suitable for deployment, contingent on:
1. Implementing the admin-to-timelock transition mechanism (H-01)
2. Fixing the quorum comparison (M-01)
3. Documenting the expected deployment sequence and role configuration

**Risk Rating:** Medium (reduced from Critical in prior audit)

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/OmniGovernance.sol` | 914 | Primary audit target |
| `Coin/contracts/OmniTimelockController.sol` | 283 | Timelock integration |
| `Coin/contracts/EmergencyGuardian.sol` | 318 | Emergency response |
| `Coin/contracts/OmniCore.sol` | ~850 | Staking checkpoints (`getStakedAt`, `_stakeCheckpoints`) |
| `Coin/contracts/OmniCoin.sol` | ~215 | ERC20Votes delegation |
| `Coin/test/UUPSGovernance.test.js` | ~1400 | Test coverage verification |
| `@openzeppelin/contracts/utils/structs/Checkpoints.sol` | ~500 | `upperLookup` semantics verification |

---

*Generated by Claude Opus 4.6 -- Deep Manual Audit*
*Date: 2026-02-26 19:27 UTC*
