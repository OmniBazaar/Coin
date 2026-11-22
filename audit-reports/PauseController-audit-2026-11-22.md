# Security Audit Report: PauseController

Date: 2026-11-22 | Audited by: Claude Code Audit Agent (scaled 8-pass) | `Coin/contracts/PauseController.sol` | Solidity 0.8.24 | 207 lines | Not upgradeable | Holds no funds

## Executive Summary

Audited before any deployment, as required. Two high-severity findings were real and are remediated: unpause approvals survived a pause (so a banked quorum could re-open a freshly paused contract instantly), and a guardian removed from the roster still counted toward the unpause threshold. Both are fixed and covered by tests. Three medium and three low findings are fixed; two low findings are accepted by design and one is a deployment requirement. All Critical, High and Medium findings are remediated in the audited source. Seventeen tests pass. Static analysis reports only informational findings.

| Severity | Found | Remediated | Accepted |
|---|---|---|---|
| Critical | 0 | 0 | 0 |
| High | 2 | 2 | 0 |
| Medium | 3 | 3 | 0 |
| Low | 4 | 2 | 2 |
| Info | 4 | 2 | 2 |

## Findings

### [H-01] Banked unpause approvals survive a pause
Severity: High | Category: business logic | Location: `pause`, `forcePause`, `forceUnpause`; consumed by `executeUnpause`
Sources: state/logic agent, access-control agent, OWASP agent (three independent passes) | Survived adversarial verification (3/3)

Description. `approveUnpause` never required the target to be paused, and neither pause function invalidated approvals. Three guardians could approve a healthy contract; days later a guardian pauses it to contain a live exploit, and any caller immediately executes the three-month-old approvals, restoring the exploited state. A governance restart (`forceUnpause`) left the same banked quorum in place.

Exploit. Approve x3 on a running target → wait → guardian pauses during an incident → attacker calls `executeUnpause` in the next block → target is live again mid-exploit.

Remediation. Every state transition (`pause`, `forcePause`, `forceUnpause`, `clearApprovals`, `executeUnpause`) now calls `_resetApprovals`, which zeroes the count, clears the approver list and the challenge timer, and advances the epoch so no stale slot can match. Tested by `testStaleApprovalsDoNotSurvivePause` and `testStaleApprovalsDoNotSurviveForceUnpause`.

### [H-02] A removed guardian's approval still counted
Severity: High | Category: access control | Location: `executeUnpause`, `approveUnpause`
Sources: access-control agent, OWASP agent, state/logic agent | Survived adversarial verification (3/3)

Description. Approval authority was snapshotted to an address at approval time and never re-validated. Removing a compromised signer, which is the standard response, left their approval counting toward the threshold. `clearApprovals` existed but required an operator to remember it per target.

Remediation. Approvers are stored per target and epoch, and `executeUnpause` recomputes the count against the live guardian set (`_validApprovalCount`), so a removed signer cannot contribute. `validApprovalsFor` exposes the same computation. Tested by `testRemovedGuardianCannotContribute`, which asserts the target stays paused with only two current guardians.

### [M-01] Permissionless execution could front-run a revoke
Severity: Medium | Category: business logic / MEV | Location: `executeUnpause`
Source: state/logic agent | Survived (1/1 substantive review)

Description. With the threshold met, the first caller executes. A guardian who sees a new vulnerability and submits `revokeUnpause` can be front-run, so the revoke loses.

Remediation. A one-hour challenge window (`UNPAUSE_DELAY`) starts when the third approval lands. Execution before it reverts `NotReady`; any guardian can revoke inside the window. Tested by `testChallengeWindowEnforced`.

### [M-02] Constructor accepted a codeless or mis-wired guardian set
Severity: Medium | Category: access control | Location: constructor
Sources: access-control agent, OWASP agent

Description. Only zero addresses were rejected. A wrong or not-yet-deployed guardian address would permanently disable every guardian function on a contract that is not upgradeable, while the timelock could still act.

Remediation. The constructor requires code at both addresses and probes `isGuardian(address(0))` with a success and length check, reverting `GuardianProbeFailed` otherwise. Tested by `testConstructorRejectsCodelessGuardianSet`.

### [M-03] A codeless or silently-failing target was reported as paused
Severity: Medium | Category: input validation | Location: `_call`
Sources: OWASP agent, access-control agent, state/logic agent

Description. A call to an address with no code succeeds with empty return data, so a mistyped or pre-deployment address produced a `PausedByGuardian` event with nothing paused. A target whose `pause()` is a silent no-op had the same effect.

Remediation. `_requireContract` rejects targets without code, and `_call` verifies the post-condition through the target's `paused()` getter when it exists, reverting `TargetStateMismatch` on a no-op. Tested by `testCodelessTargetRejected` and `testSilentNoOpTargetRejected`.

### [L-01] Missing zero-address checks on revoke and clear
Severity: Low | Category: input validation | Location: `revokeUnpause`, `clearApprovals`
Remediation. Both now reject the zero address. No reachable impact existed, but the surface was inconsistent.

### [L-02] Duplicate approver after revoke and re-approve
Severity: Low (found during remediation, not by a pass) | Category: arithmetic / state | Location: `revokeUnpause`
Description. Introducing the approver list created a path where revoke-then-re-approve pushed the same guardian twice, which would have counted twice at execution.
Remediation. Approvers are removed by swap-and-pop with a 1-based index, so the list holds each guardian at most once per epoch. Tested by `testRevokeThenReapproveDoesNotDoubleCount`.

### [L-03] No controller-side target allowlist — accepted
Severity: Low | Category: centralization | Location: `pause`, `approveUnpause`, `executeUnpause`
Description. The controller can be pointed at any address, and its authority is bounded only by which contracts grant it the role. The sibling guardian contract keeps a timelock-maintained allowlist.
Decision. Accepted, because the role grant is itself the allowlist and is a governance action per target. A second list would duplicate that control and add a way to desynchronize them. The deploy script asserts, per target, that the controller holds the role and the deployer does not.

### [L-04] Fail-closed guardian lookup is a single external dependency — accepted
Severity: Low | Category: availability | Location: `onlyGuardian`
Description. If the guardian contract is mis-wired or unavailable, guardian functions revert. The timelock paths depend on nothing external, so pause and unpause remain available.
Decision. Accepted: fail-closed is correct for an authorization check. An off-chain monitor asserting a known signer still reads true is the mitigation.

### [L-05] Deployment must revoke the deployer's pause role in the same batch — requirement
Severity: Low | Category: deployment | Location: deployment
Description. If a target keeps an EOA's pause role alongside the controller's, that key both pauses and unpauses and the three-of-N restart gate is bypassed. The contract cannot enforce exclusivity.
Requirement. The deployment batch grants the role to the controller and revokes it from every EOA, then asserts both conditions on chain per target.

### Informational
- `block.timestamp` is used for the challenge window; a validator can shift it by seconds against a one-hour window. No impact.
- `_validApprovalCount` loops with one staticcall per approver; bounded by the guardian set, currently five.
- The low-level call in `_call` is intentional and guarded by a post-condition check.
- Immutable names `TIMELOCK` and `GUARDIANS` are uppercase, matching the sibling guardian contract and the repository convention.

## Refuted Findings

None. Every finding raised by a pass survived review; none was withdrawn as a false positive.

## Static Analysis Summary

| Tool | Result |
|---|---|
| Slither 0.11.5 | 5 detectors, all informational: low-level-calls, calls-loop, timestamp, naming-convention, unused-return (fix applied for the last) |
| Solhint | 0 errors, documentation warnings only |
| Mythril 0.24.8 | SWC-113 multiple calls in one transaction at the guarded low-level call; mitigated by the reentrancy lock and by consuming approvals before the call |

## Access Control Map

| Function | Caller | Risk |
|---|---|---|
| `pause` | any current guardian | 4/10, halt only, reversed by three guardians or the timelock |
| `approveUnpause` | any current guardian | 3/10, needs two more |
| `revokeUnpause` | any current guardian | 2/10 |
| `executeUnpause` | anyone, after three current approvals and one hour | 2/10 |
| `forcePause`, `forceUnpause`, `clearApprovals` | timelock | 9/10 |

## Centralization Risk Assessment

9/10. A compromised timelock key can pause or unpause every administered contract, force-unpause a containment pause, and rotate the guardian roster to a set it controls. The controller holds no funds and cannot move value, so the loss is the protocol's trusted stop signal rather than money. A single compromised guardian is 4/10: halt-only, reversible by three honest guardians or one timelock transaction.

## Status

Audited source is the committed source. All High and Medium findings remediated. Seventeen Foundry cases pass. Not deployed. Before deployment: a fork rehearsal that grants the role to the controller on a real target, pauses through it, and unpauses through the three-approval path; and the deployment batch described in L-05.
