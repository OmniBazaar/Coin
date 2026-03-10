# Cross-System Adversarial Review: Governance Manipulation

**Date:** 2026-03-10
**Auditor:** Claude Opus 4.6 -- Cross-Contract Adversarial Analysis
**Phase:** Pre-Mainnet Security Audit, Phase 2
**Scope:** Cross-contract governance manipulation attack paths spanning OmniGovernance, OmniTimelockController, EmergencyGuardian, OmniCoin, OmniCore, OmniRewardManager, UnifiedFeeVault, and OmniTreasury.

---

## Executive Summary

This review maps attack paths that span multiple contracts in the OmniBazaar governance stack. Where single-contract audits evaluate each component in isolation, this analysis focuses on the *interfaces* between them -- the handoff points, role assumptions, and state dependencies that create cross-system vulnerabilities.

**Key findings:**
- **2 High-severity** cross-contract attack paths identified
- **4 Medium-severity** cross-contract issues
- **3 Low-severity** issues
- **1 Informational** observation

The most critical finding (ATK-H01) demonstrates that a compromised `VALIDATOR_REWARD_ROLE` on OmniRewardManager can drain 6.089 billion XOM (36.7% of total supply) with no on-chain rate limiting, then use those tokens to acquire majority voting power in OmniGovernance and execute a full governance takeover. This is an end-to-end attack chain from reward pool to treasury drain. The second high finding (ATK-H02) identifies that `ossify()` is not classified as a critical selector in OmniTimelockController, meaning permanent, irreversible contract freezing can proceed on the shorter 48-hour ROUTINE delay instead of the 7-day CRITICAL delay.

Several Medium-severity findings relate to the Pioneer Phase transitional period where deployer/multisig retains elevated privileges alongside governance contracts, creating parallel authority paths that undermine the timelock's protective delays.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 3 |
| Informational | 1 |

---

## Post-Audit Remediation Status (2026-03-10)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| ATK-H01 | High | Governance takeover via validator reward pool drain | **FIXED** -- On-chain emission rate limiting added to OmniRewardManager; VALIDATOR_REWARD_ROLE removed entirely |
| ATK-H02 | High | Ossification race condition -- premature permanent freeze via 48-hour routine delay | **FIXED** -- ossify() registered as critical selector in OmniTimelockController (7-day delay) |
| ATK-M01 | Medium | Timelock bypass via Pioneer Phase parallel authority | **FIXED** |
| ATK-M02 | Medium | Proposer cancellation veto on community-approved governance proposals | **FIXED** |
| ATK-M03 | Medium | Fee vault drain via governance -- setRecipients() has no timelock | **FIXED** |
| ATK-M04 | Medium | Admin transfer chain -- OmniCore two-step admin transfer can create backdoor | **FIXED** |

---

## Attack Path Analysis

### ATK-H01: Governance Takeover via Validator Reward Pool Drain

**Severity:** HIGH
**Contracts:** OmniRewardManager -> OmniCoin -> OmniGovernance -> OmniTimelockController -> OmniTreasury / UnifiedFeeVault / OmniCore
**Feasibility:** Requires compromise of `VALIDATOR_REWARD_ROLE` key
**Impact:** Complete protocol takeover -- treasury drain, contract upgrades, role seizure

#### Step-by-Step Exploit

```
Phase 1: Accumulate Voting Power (1 transaction)
─────────────────────────────────────────────────
1. Attacker compromises the VALIDATOR_REWARD_ROLE key
   (or the off-chain validator reward scheduler)

2. Calls OmniRewardManager.distributeValidatorReward() with:
   - validator = attacker's address
   - validatorAmount = 6,089,000,000e18 (entire pool)
   - stakingAmount = 0
   - oddaoAmount = 0

   NO on-chain guardrails prevent this:
   - No maximum per-call limit
   - No rate limiting (no MIN_BLOCK_INTERVAL)
   - No emission schedule enforcement
   - Only check: pool.remaining >= totalAmount (passes on first call)

3. Attacker now holds 6.089B XOM (~36.7% of 16.6B total supply)

Phase 2: Delegate and Create Proposal (1 transaction)
──────────────────────────────────────────────────────
4. Attacker calls OmniCoin.delegate(self) to activate
   ERC20Votes voting power (6.089B >> 10,000 threshold)

5. Attacker calls OmniGovernance.propose() creating a
   CRITICAL proposal with actions:
   a. OmniCore.grantRole(ADMIN_ROLE, attacker)
   b. OmniTreasury.grantRole(GOVERNANCE_ROLE, attacker)
   c. UnifiedFeeVault.grantRole(DEFAULT_ADMIN_ROLE, attacker)
   d. OmniCoin.grantRole(DEFAULT_ADMIN_ROLE, attacker)

   Snapshot is taken at block.number (attacker's 6.089B is
   already delegated and checkpointed)

Phase 3: Wait 1 Day, Then Vote (block.timestamp + 1 day)
─────────────────────────────────────────────────────────
6. After VOTING_DELAY (1 day), voting begins.
   Attacker calls castVote(proposalId, 1) with weight
   = getPastVotes(attacker, snapshotBlock)

   6.089B forVotes vs 0 againstVotes (assuming no opposition
   gathers 6.089B+ in 5 days)

   Quorum requirement: 4% of snapshotTotalSupply
   = 0.04 * 16.6B = 664M XOM
   6.089B >> 664M (quorum easily met)

Phase 4: Queue After Voting Period (block.timestamp + 6 days)
─────────────────────────────────────────────────────────────
7. After VOTING_PERIOD (5 days), proposal is Succeeded.
   Attacker calls queue(proposalId).
   CRITICAL proposal -> 7-day delay in timelock.

Phase 5: Execute After Timelock (block.timestamp + 13 days)
───────────────────────────────────────────────────────────
8. After 7-day CRITICAL_DELAY, anyone can call
   execute(proposalId).

9. Attacker now has ADMIN_ROLE on OmniCore,
   GOVERNANCE_ROLE on OmniTreasury,
   DEFAULT_ADMIN_ROLE on UnifiedFeeVault and OmniCoin.

Phase 6: Drain Everything (immediate)
──────────────────────────────────────
10. OmniTreasury.transferToken(XOM, attacker, balance)
11. OmniTreasury.transferNative(attacker, balance)
12. UnifiedFeeVault: set recipients to attacker, distribute
13. OmniCore: upgrade to malicious implementation
14. OmniCoin: pause all transfers (lock out everyone)
```

#### Timeline

```
Day 0:  Drain validator pool + delegate + propose
Day 1:  Voting starts
Day 6:  Voting ends (attacker has supermajority)
Day 6:  Queue in timelock
Day 13: Execute -- full takeover
```

#### Detection Window

The community has 13 days total to detect and respond:
- Days 0-1: Must detect the abnormal 6.089B XOM transfer from OmniRewardManager
- Days 1-6: Must gather >6.089B XOM in opposition votes (impossible if attacker holds 36.7%)
- Days 6-13: EmergencyGuardian can cancel the queued operation (requires 3-of-N guardians)

However, the attacker's 36.7% of total supply means no opposition vote can achieve majority. The only defense is EmergencyGuardian cancel during the 7-day timelock window.

#### Protection Assessment

**Partially blocked.** EmergencyGuardian's 3-of-N cancel is the sole defense. If 3+ guardians are available, responsive, and not compromised, they can cancel the queued operation. However:
- The attacker could simultaneously create a CRITICAL proposal to `removeGuardian()` for multiple guardians (but this would also need 7-day delay, giving guardians time to cancel both)
- If the guardian set itself is compromised (3 out of 5 minimum), there is no defense

#### Recommendation

Add on-chain rate limiting to `OmniRewardManager.distributeValidatorReward()`:

```solidity
uint256 public constant MAX_BLOCK_REWARD = 16e18; // 16 XOM per call
uint256 public constant MIN_REWARD_INTERVAL = 1;  // 1 second minimum
uint256 public lastRewardTimestamp;

function distributeValidatorReward(ValidatorRewardParams calldata params)
    external onlyRole(VALIDATOR_REWARD_ROLE) nonReentrant whenNotPaused
{
    uint256 total = params.validatorAmount + params.stakingAmount
                  + params.oddaoAmount;
    if (total > MAX_BLOCK_REWARD) revert ExceedsMaxBlockReward();
    if (block.timestamp < lastRewardTimestamp + MIN_REWARD_INTERVAL)
        revert TooFrequentDistribution();
    lastRewardTimestamp = block.timestamp;
    // ... existing logic
}
```

With a 16 XOM/second cap, draining 6.089B XOM would take ~12 years instead of 1 transaction. This converts a single-transaction catastrophic exploit into an impossibility.

---

### ATK-H02: Ossification Race Condition -- Premature Permanent Freeze via 48-Hour Routine Delay

**Severity:** HIGH
**Contracts:** OmniGovernance -> OmniTimelockController -> OmniGovernance.ossify() / OmniCore.ossify() / UnifiedFeeVault.proposeOssification()
**Feasibility:** Requires passing a governance proposal (10K XOM + quorum + majority)
**Impact:** Permanent, irreversible contract freeze -- no future upgrades possible

#### Step-by-Step Exploit

```
1. Attacker creates a ROUTINE governance proposal containing:
   - Target: OmniGovernance (proxy)
   - Calldata: ossify()  [selector 0x32e3a7b4]

2. OmniGovernance._validateNoCriticalSelectors() checks the
   timelock's isCriticalSelector(0x32e3a7b4):
   - ossify() is NOT in the critical selector registry
   - Returns false -> ROUTINE classification accepted

3. Proposal passes vote (requires 4% quorum, simple majority)

4. Attacker calls queue(proposalId):
   - ROUTINE -> 48-hour delay
   - OmniTimelockController.scheduleBatch() checks
     _batchContainsCritical(): false (ossify not critical)
   - Delay of 48 hours accepted (below 7-day threshold)

5. After 48 hours, execute():
   - OmniGovernance._ossified = true
   - Contract is PERMANENTLY non-upgradeable

6. If the current implementation has a subtle bug, a storage
   layout issue, or a missing feature, it can NEVER be fixed.
   The governance system itself is frozen.
```

#### Why This Matters

`ossify()` is the MOST irreversible action in the entire protocol. Unlike `upgradeToAndCall()` (which can be reversed by another upgrade), `grantRole()` (which can be reversed by `revokeRole()`), or `pause()` (which can be reversed by `unpause()`), ossification is permanent and affects the contract's fundamental upgradeability forever.

Yet it receives LESS protective delay (48 hours) than role changes (7 days), pause/unpause (7 days), or upgrade operations (7 days). This is a severity inversion: the most permanent action has the least protection.

The same exploit applies to OmniCore.ossify() -- permanently freezing the core protocol contract.

For UnifiedFeeVault, the ossification path requires two steps (proposeOssification + confirmOssification with internal 48h delay), but the governance proposal itself can bundle both calls with appropriate timing, or use a single call to confirmOssification() after a prior proposeOssification() governance action.

#### Protection Assessment

**NOT blocked.** The `ossify()` selector is NOT registered as a critical selector in OmniTimelockController. Neither OmniGovernance's `_validateNoCriticalSelectors()` nor OmniTimelockController's `_batchContainsCritical()` will flag it. The community has only 48 hours to detect and cancel via EmergencyGuardian.

Confirmed by examining the timelock constructor (lines 128-141): the 10 registered critical selectors are `upgradeTo`, `upgradeToAndCall`, `grantRole`, `revokeRole`, `renounceRole`, `pause`, `unpause`, `updateDelay`, `addCriticalSelector`, `removeCriticalSelector`. `ossify()` is absent.

#### Recommendation

Register `ossify()` as a critical selector in OmniTimelockController:

```solidity
// In OmniTimelockController constructor:
bytes4 public constant SEL_OSSIFY = 0x32e3a7b4; // ossify()
_criticalSelectors[SEL_OSSIFY] = true;
criticalSelectorCount = 11; // was 10
```

This ensures ossification proposals require the full 7-day CRITICAL_DELAY, matching the severity of the action. This was also independently identified in the OmniTimelockController round-6 audit (M-01).

---

### ATK-M01: Timelock Bypass via Pioneer Phase Parallel Authority

**Severity:** MEDIUM
**Contracts:** OmniTimelockController (PROPOSER_ROLE) -> OmniGovernance (ADMIN_ROLE) -> OmniCore (ADMIN_ROLE) -> UnifiedFeeVault (ADMIN_ROLE)
**Feasibility:** During Pioneer Phase when deployer/multisig retains roles alongside governance
**Impact:** Deployer can execute critical actions bypassing governance vote

#### Attack Description

During the Pioneer Phase deployment sequence, the deployer/multisig holds multiple roles simultaneously:

```
Deployer Roles During Pioneer Phase:
├── OmniTimelockController: PROPOSER_ROLE
├── OmniTimelockController: TIMELOCK_ADMIN_ROLE (constructor admin param)
├── OmniGovernance: DEFAULT_ADMIN_ROLE + ADMIN_ROLE
├── OmniCore: DEFAULT_ADMIN_ROLE + ADMIN_ROLE
├── UnifiedFeeVault: DEFAULT_ADMIN_ROLE + ADMIN_ROLE + BRIDGE_ROLE
├── OmniTreasury: DEFAULT_ADMIN_ROLE + GOVERNANCE_ROLE + GUARDIAN_ROLE
├── OmniCoin: DEFAULT_ADMIN_ROLE + MINTER_ROLE + BURNER_ROLE
└── OmniRewardManager: DEFAULT_ADMIN_ROLE + various operational roles
```

While the deployer holds `PROPOSER_ROLE` on the timelock, they can schedule operations directly -- bypassing the governance voting process entirely. The timelock enforces delay (48h routine, 7d critical), but no community vote is required.

```
Attack Path:
1. Deployer calls OmniTimelockController.scheduleBatch() directly
   (has PROPOSER_ROLE, bypasses OmniGovernance entirely)

2. Schedules a batch containing:
   - OmniCore.setOddaoAddress(attackerAddress)
   - UnifiedFeeVault.setRecipients(attacker, attacker)
   - OmniTreasury.transferToken(XOM, attacker, balance)

3. Wait 48h (routine) or 7d (critical depending on selectors)

4. Anyone calls executeBatch()

5. All protocol fees now flow to attacker,
   treasury is drained
```

This is NOT a bug -- it is the intended Pioneer Phase design. The deployer NEEDS these privileges during initial setup. However, the transition from Pioneer Phase to production governance is the most dangerous moment in the protocol's lifecycle.

#### Protection Assessment

**Protected by operational procedure, not by code.** The transition plan calls for:
1. `OmniGovernance.transferAdminToTimelock()` (irreversible admin transfer)
2. Revoking deployer's `PROPOSER_ROLE` from the timelock
3. Revoking deployer's `TIMELOCK_ADMIN_ROLE` from the timelock
4. `OmniTreasury.transitionGovernance()` (atomic role handoff)
5. Revoking deployer roles from OmniCore, UnifiedFeeVault, OmniCoin, OmniRewardManager

If ANY of these steps is skipped or fails, the deployer retains parallel authority.

#### Recommendation

1. Create a deployment script that atomically executes ALL role revocations in a single transaction or batch.
2. Add a "governance readiness check" view function that returns false if any deployer addresses still hold elevated roles.
3. Consider a "deadman switch" -- if the deployer's roles are not revoked within X days of deployment, the deployer's PROPOSER_ROLE on the timelock auto-expires. (This requires a code change to OmniTimelockController, which is non-upgradeable, so it must be included in the initial deployment.)

---

### ATK-M02: Proposer Cancellation Veto on Community-Approved Governance Proposals

**Severity:** MEDIUM
**Contracts:** OmniGovernance (cancel function)
**Feasibility:** Requires being the original proposer of a governance proposal
**Impact:** Single actor can veto community-approved proposals, undermining governance legitimacy

#### Attack Description

```
1. Proposer creates a proposal to reduce marketplace fees
2. Community votes overwhelmingly (80% for, 20% against, quorum met)
3. Proposal enters Succeeded state -> queued in timelock
4. During the 48h-7d timelock delay, an interested party
   (e.g., a large marketplace operator who benefits from high fees)
   bribes/pressures the proposer
5. Proposer calls OmniGovernance.cancel(proposalId)
6. cancel() at line 599: isProposer = (caller == proposal.proposer) -> true
7. Proposal is cancelled at governance level
8. If queued, attempts timelock cancel (may or may not succeed)
9. Community must re-create and re-vote (6+ more days)
```

The proposer retains unilateral veto power over community-approved proposals at ANY stage -- including after the community has voted in favor. This violates the principle that governance proposals, once approved by the community, should only be stoppable by the EmergencyGuardian (for legitimate emergency reasons).

This is the Compound Governor Bravo anti-pattern -- Bravo restricts proposer cancellation and adds threshold-based cancellation by anyone.

#### Protection Assessment

**NOT blocked.** OmniGovernance's `cancel()` function (lines 588-621) allows the proposer to cancel at any stage except after execution or prior cancellation. There is no voting power check on the proposer at cancellation time, and no state restriction preventing cancellation of queued proposals.

The ADMIN_ROLE holder (timelock) can also cancel, which is appropriate for emergency use.

#### Recommendation

Restrict proposer cancellation to pre-vote stages, and add threshold-based cancellation by anyone (Governor Bravo pattern):

```solidity
function cancel(uint256 proposalId) external {
    Proposal storage proposal = proposals[proposalId];
    if (proposal.executed || proposal.cancelled) {
        revert InvalidProposalState(state(proposalId), ProposalState.Pending);
    }

    address caller = _msgSender();

    if (hasRole(ADMIN_ROLE, caller)) {
        // Admin (timelock) can always cancel -- emergency
    } else if (caller == proposal.proposer) {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Pending &&
            currentState != ProposalState.Active) {
            revert NotAuthorizedToCancel();
        }
    } else {
        // Anyone can cancel if proposer's power dropped below threshold
        if (getVotingPower(proposal.proposer) >= PROPOSAL_THRESHOLD) {
            revert NotAuthorizedToCancel();
        }
    }

    proposal.cancelled = true;
    // ... timelock cancel logic
}
```

---

### ATK-M03: Fee Vault Drain via Governance -- `setRecipients()` Has No Timelock

**Severity:** MEDIUM
**Contracts:** OmniGovernance -> OmniTimelockController -> UnifiedFeeVault.setRecipients()
**Feasibility:** Requires passing a governance proposal
**Impact:** All future fee distributions redirected to attacker-controlled addresses

#### Attack Description

```
1. Attacker passes a ROUTINE governance proposal containing:
   - Target: UnifiedFeeVault
   - Calldata: setRecipients(attackerPool, attackerTreasury)
   - selector: setRecipients(address,address)

2. setRecipients() selector is NOT a critical selector
   -> ROUTINE classification accepted
   -> 48-hour timelock delay

3. After 48 hours, execution:
   - stakingPool = attacker's address
   - protocolTreasury = attacker's address

4. All subsequent distribute() calls send:
   - 20% to attacker (instead of StakingRewardPool)
   - 10% to attacker (instead of protocol treasury)
   - 70% stays as pendingBridge (ODDAO share)

5. Attacker can also call bridgeToTreasury() if they
   have BRIDGE_ROLE, or wait for the bridge operator
   to send 70% to the intended ODDAO address.
```

#### Protection Assessment

**Partially blocked.** The governance proposal requires community vote (quorum + majority), which provides transparency. The 48-hour timelock provides a cancel window. However:

1. `setRecipients()` is an ADMIN_ROLE function, not guarded by a critical selector. It executes on the shorter 48h delay.
2. The UnifiedFeeVault's own internal recipient timelock (RECIPIENT_CHANGE_DELAY = 48h) was removed during Pioneer Phase simplification (deprecated state variables `__deprecated_pendingStakingPool`, `__deprecated_pendingProtocolTreasury`, `__deprecated_recipientChangeTimestamp` visible in contract).
3. The `bridgeToTreasury()` function allows BRIDGE_ROLE to send pendingBridge tokens to ANY `bridgeReceiver` address -- if the attacker also acquires BRIDGE_ROLE, they can drain the 70% ODDAO share as well.

A malicious proposal could bundle `setRecipients()` with `grantRole(BRIDGE_ROLE, attacker)`. The `grantRole` selector IS critical (7-day delay would apply to the batch). However, if submitted as two separate proposals -- one ROUTINE for setRecipients (48h) and one CRITICAL for grantRole (7d) -- the attacker gets recipient control in 48 hours.

#### Recommendation

1. Register `setRecipients` selector as a critical selector in OmniTimelockController (requires governance proposal post-deployment).
2. Re-enable the internal 48h timelock on recipient changes within UnifiedFeeVault as defense-in-depth.
3. Consider adding a `MAX_RECIPIENT_CHANGE_FREQUENCY` -- e.g., recipients can only be changed once per 30 days.

---

### ATK-M04: Admin Transfer Chain -- OmniCore Two-Step Admin Transfer Can Create Backdoor

**Severity:** MEDIUM
**Contracts:** OmniGovernance -> OmniTimelockController -> OmniCore.proposeAdminTransfer()
**Feasibility:** Requires passing a governance proposal + 48h wait
**Impact:** Attacker gains ADMIN_ROLE on OmniCore (validator management, staking, DEX settlement)

#### Attack Description

OmniCore has a two-step admin transfer (V3 M-05 fix) at lines 511-554:

```solidity
function proposeAdminTransfer(address newAdmin) external onlyRole(ADMIN_ROLE)
function acceptAdminTransfer() external  // caller must be pendingAdmin
```

The `proposeAdminTransfer()` selector is not `grantRole()`, `revokeRole()`, or `renounceRole()` -- those are the selectors registered as critical in OmniTimelockController. The `proposeAdminTransfer()` function has its own selector (not in the critical registry), meaning:

```
1. Attacker passes a ROUTINE governance proposal:
   - Target: OmniCore
   - Calldata: proposeAdminTransfer(attackerAddress)
   - This is NOT a critical selector -> 48h delay

2. After 48h timelock, execute:
   - OmniCore.pendingAdmin = attackerAddress
   - OmniCore.adminTransferEta = block.timestamp + 48h

3. After 48h OmniCore internal delay (total 96h from proposal),
   attacker calls OmniCore.acceptAdminTransfer()

4. Attacker receives ADMIN_ROLE and DEFAULT_ADMIN_ROLE on OmniCore

5. Attacker now controls:
   - Validator management (setValidator)
   - Service registry (setService)
   - Staking operations (via pause)
   - UUPS upgrades on OmniCore
   - ODDAO/staking address changes
```

Note: `acceptAdminTransfer()` grants both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` to the caller (lines 538-539), but does NOT revoke the roles from the current admin. This means both the timelock AND the attacker hold admin roles. The attacker can then revoke the timelock's roles.

#### Protection Assessment

**Partially blocked.** The governance vote + 48h timelock + 48h internal delay = 96 hours total for detection. EmergencyGuardian can cancel during the first 48h (timelock window). However:
- `proposeAdminTransfer` is not flagged as critical, so only 48h review
- The 48h internal delay on OmniCore provides a second window, but there is no on-chain cancel for the pending admin transfer except by the current admin calling `cancelAdminTransfer()`
- If the timelock IS the current admin, it would need another governance proposal to cancel -- creating a race condition

#### Recommendation

1. Register `proposeAdminTransfer` selector as a critical selector in OmniTimelockController.
2. Fix `acceptAdminTransfer()` to revoke ADMIN_ROLE from ALL current holders (or at minimum, document that it intentionally does not revoke).
3. Consider having `proposeAdminTransfer()` emit an event that EmergencyGuardian monitoring systems watch for.

---

### ATK-L01: Governance-Timelock State Divergence on Failed Cancel

**Severity:** LOW
**Contracts:** OmniGovernance (cancel) -> OmniTimelockController (cancel)
**Feasibility:** Race condition between cancel and execute
**Impact:** Governance reports "Cancelled" but timelock operation still executes

#### Attack Description

```
1. Governance proposal passes and is queued in timelock
2. Someone calls OmniGovernance.cancel(proposalId)
3. cancel() sets proposal.cancelled = true
4. cancel() attempts timelock.cancel(timelockId):
   - If the timelock operation was already executed (race condition),
     or if OmniGovernance lacks CANCELLER_ROLE, the cancel fails
   - TimelockCancelFailed event is emitted (line 616)
   - But proposal.cancelled remains true

5. Governance state: Cancelled
   Timelock state: Still pending (or already executed)

6. Since EXECUTOR_ROLE = address(0), anyone can call
   timelock.executeBatch() directly, executing the operation
   even though governance says "Cancelled"
```

#### Protection Assessment

**Partially addressed.** The `TimelockCancelFailed` event (lines 260-266) provides a signal for off-chain monitoring. However, any UI or tool that only checks `OmniGovernance.state()` will incorrectly show "Cancelled" while the operation executes or remains pending in the timelock.

NOTE: OmniGovernance's `execute()` function checks `state(proposalId) == Queued`, and `state()` returns `Cancelled` if `proposal.cancelled == true`, so governance-side re-execution is blocked. But direct timelock execution bypasses governance entirely.

#### Recommendation

Consider reverting the governance cancellation if the timelock cancel fails:

```solidity
if (proposal.queued) {
    bytes32 timelockId = _getTimelockId(proposalId);
    (bool success, ) = timelock.call(
        abi.encodeWithSignature("cancel(bytes32)", timelockId)
    );
    if (!success) {
        revert TimelockCancelFailed(proposalId, timelockId);
    }
}
```

---

### ATK-L02: EmergencyGuardian `_executeCancel()` Reverts Instead of Gracefully Handling Race Conditions

**Severity:** LOW
**Contracts:** EmergencyGuardian -> OmniTimelockController
**Feasibility:** Natural race condition when timelock operation executes just before 3rd guardian signature
**Impact:** 3rd guardian's transaction reverts; signature state is inconsistent

#### Attack Description

```
1. Guardian A signs cancel for operation X (count = 1)
2. Guardian B signs cancel for operation X (count = 2)
3. Meanwhile, the timelock delay expires and someone calls
   timelock.executeBatch() -- operation X executes
4. Guardian C calls signCancel(operationId):
   - _requireOperationPending() reverts with OperationNotPending
   - Guardian C cannot submit their signature
   - cancelSignatureCount permanently shows 2

Alternative scenario:
3'. Guardian C calls signCancel before execution
   - count reaches 3 -> _executeCancel() fires
   - But between C's transaction being mined and
     _executeCancel's TIMELOCK.call, operation X executes
   - timelock.cancel() fails (operation already done)
   - _executeCancel() reverts (bubbles up timelock error or CancelFailed)
   - C's entire transaction reverts including their signature
```

#### Protection Assessment

**Functionally correct** (the operation executed, so canceling is moot), but **UX is poor**. The `CancelAttemptFailed` event was declared for this purpose (line 137 of EmergencyGuardian) but is never actually emitted -- `_executeCancel()` reverts instead. The NatSpec comment at line 467 says "L-03: Emit event on cancel failure instead of reverting," but the code does the opposite.

#### Recommendation

Implement the emit-and-return pattern documented in the NatSpec:

```solidity
if (!success) {
    emit CancelAttemptFailed(operationId, "Operation no longer pending");
    return; // Don't revert -- preserve signature state
}
```

---

### ATK-L03: `transferAdminToTimelock()` in OmniGovernance Uses `msg.sender` Instead of `_msgSender()`

**Severity:** LOW
**Contracts:** OmniGovernance (transferAdminToTimelock)
**Feasibility:** Only when called via ERC2771 trusted forwarder
**Impact:** Admin roles not revoked from actual admin; both admin and timelock hold admin powers

#### Attack Description

```
1. Admin calls transferAdminToTimelock() via the trusted forwarder
2. onlyRole(ADMIN_ROLE) uses _msgSender() -> passes (admin has role)
3. _grantRole(ADMIN_ROLE, timelock) -> succeeds
4. _grantRole(DEFAULT_ADMIN_ROLE, timelock) -> succeeds
5. _revokeRole(ADMIN_ROLE, msg.sender) -> msg.sender = forwarder
   -> forwarder does NOT have ADMIN_ROLE
   -> _revokeRole is a no-op (OZ does not revert)
6. _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender) -> same, no-op

Result: Both the original admin AND the timelock hold admin roles.
The admin retains full governance bypass capability.
```

#### Protection Assessment

**Partially protected by operational practice.** This function would typically be called directly (not via forwarder). However, if the deployment script or tooling routes through the forwarder, the admin transfer silently fails to revoke the caller's privileges.

#### Recommendation

Replace `msg.sender` with `_msgSender()` on lines 802-803:

```solidity
address caller = _msgSender();
_revokeRole(ADMIN_ROLE, caller);
_revokeRole(DEFAULT_ADMIN_ROLE, caller);
emit AdminTransferredToTimelock(caller, timelockAddr);
```

---

### ATK-I01: OmniTreasury Persistent Allowances After Governance Transition

**Severity:** INFORMATIONAL
**Contracts:** OmniTreasury (approveToken + transitionGovernance)
**Feasibility:** Requires Pioneer Phase governance to have set ERC20 allowances
**Impact:** Post-transition, old allowances remain active and can drain treasury tokens

#### Description

When `OmniTreasury.approveToken()` is called during the Pioneer Phase to approve a spender for some ERC20 token, that allowance persists in the token contract's `_allowances` mapping. When `transitionGovernance()` is called to hand off roles to the timelock and guardian, the ERC20 allowances are NOT revoked.

Any contract or EOA previously approved can continue to call `transferFrom()` on the token contract to move treasury funds, even after the deployer has lost GOVERNANCE_ROLE.

This is not strictly a governance manipulation attack, but it creates a persistent fund extraction path that survives governance transition -- the hallmark of a backdoor.

#### Recommendation

Add a `revokeAllApprovals()` step to `transitionGovernance()`, or maintain an internal registry of (token, spender) pairs that can be enumerated and revoked atomically during transition.

---

## Role & Permission Map (Across All Governance Contracts)

### Post-Deployment (Pioneer Phase) Role Map

```
                    ┌─────────────────────────────┐
                    │          DEPLOYER            │
                    │  (Single Key / Multisig)     │
                    └─────────┬───────────────────┘
                              │ holds ALL of:
    ┌─────────────────────────┼───────────────────────────────┐
    │                         │                               │
    ▼                         ▼                               ▼
┌────────────┐    ┌───────────────────┐    ┌────────────────────────┐
│ OmniCoin   │    │ OmniCore          │    │ OmniTimelockController │
│            │    │                   │    │                        │
│ ADMIN (48h │    │ ADMIN_ROLE        │    │ PROPOSER_ROLE          │
│  delay via │    │ DEFAULT_ADMIN     │    │ TIMELOCK_ADMIN_ROLE    │
│  ACDRA)    │    │                   │    │   (should renounce)    │
│ MINTER     │    │                   │    │                        │
│ BURNER     │    │                   │    │ EXECUTOR_ROLE = 0x0    │
└────────────┘    └───────────────────┘    │   (anyone can execute) │
                                          │                        │
    ┌─────────────────────────────────┐   │ CANCELLER_ROLE =       │
    │ OmniGovernance                  │   │   EmergencyGuardian    │
    │                                 │   └────────────────────────┘
    │ ADMIN_ROLE                      │
    │ DEFAULT_ADMIN_ROLE              │
    └─────────────────────────────────┘
    ┌─────────────────────────────────┐   ┌────────────────────────┐
    │ UnifiedFeeVault                 │   │ OmniTreasury           │
    │                                 │   │                        │
    │ DEFAULT_ADMIN_ROLE              │   │ DEFAULT_ADMIN_ROLE     │
    │ ADMIN_ROLE                      │   │ GOVERNANCE_ROLE        │
    │ BRIDGE_ROLE                     │   │ GUARDIAN_ROLE           │
    │ DEPOSITOR_ROLE (to fee sources) │   └────────────────────────┘
    └─────────────────────────────────┘
    ┌─────────────────────────────────┐   ┌────────────────────────┐
    │ OmniRewardManager               │   │ EmergencyGuardian      │
    │                                 │   │                        │
    │ DEFAULT_ADMIN_ROLE              │   │ 5+ Guardians           │
    │ VALIDATOR_REWARD_ROLE           │   │ Timelock = immutable   │
    │ BONUS_DISTRIBUTOR_ROLE          │   │                        │
    │ UPGRADER_ROLE                   │   │ Pause: 1-of-N          │
    │ PAUSER_ROLE                     │   │ Cancel: 3-of-N         │
    └─────────────────────────────────┘   └────────────────────────┘
```

### Post-Transition (Production) Target Role Map

```
                    ┌─────────────────────────────┐
                    │    OmniGovernance            │
                    │  (Community Proposals)       │
                    └─────────┬───────────────────┘
                              │ proposes via
                              ▼
                    ┌───────────────────────┐
                    │ OmniTimelockController │
                    │                       │
                    │ PROPOSER = Governance  │
                    │ EXECUTOR = anyone      │
                    │ CANCELLER = Guardian   │
                    │ ADMIN = self           │
                    └───────────┬───────────┘
                                │ executes via
            ┌───────────────────┼───────────────────┐
            │                   │                   │
            ▼                   ▼                   ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ OmniCore     │  │ OmniCoin     │  │ OmniTreasury │
    │ ADMIN=TL     │  │ ADMIN=TL     │  │ GOV=TL       │
    │              │  │ MINTER=none  │  │ GUARD=EG     │
    │              │  │ BURNER=pXOM  │  │ ADMIN=TL     │
    └──────────────┘  └──────────────┘  └──────────────┘

    ┌──────────────────────────────────────────────┐
    │ UnifiedFeeVault                              │
    │ ADMIN=TL, BRIDGE_ROLE=operator, DEPOSITOR=FCs│
    └──────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────┐
    │ OmniRewardManager                            │
    │ ADMIN=TL, VAL_REWARD=scheduler,              │
    │ BONUS_DIST=verifier, UPGRADER=TL, PAUSER=EG  │
    └──────────────────────────────────────────────┘

    TL = OmniTimelockController
    EG = EmergencyGuardian
    FCs = Fee-generating contracts (MinimalEscrow, DEXSettlement, etc.)
```

### Critical Role Transitions Required

| Contract | Role | From | To | Method |
|----------|------|------|----|--------|
| OmniGovernance | ADMIN_ROLE + DEFAULT_ADMIN_ROLE | Deployer | Timelock | `transferAdminToTimelock()` |
| OmniTimelockController | PROPOSER_ROLE | Deployer | (revoke only) | `revokeRole()` via timelock |
| OmniTimelockController | TIMELOCK_ADMIN_ROLE | Deployer | (renounce) | `renounceRole()` |
| OmniCore | ADMIN_ROLE + DEFAULT_ADMIN_ROLE | Deployer | Timelock | `proposeAdminTransfer()` + `acceptAdminTransfer()` |
| OmniCoin | DEFAULT_ADMIN_ROLE | Deployer | Timelock | `beginDefaultAdminTransfer()` + `acceptDefaultAdminTransfer()` (ACDRA) |
| OmniCoin | MINTER_ROLE | Deployer | (revoke permanently) | `revokeRole()` |
| UnifiedFeeVault | DEFAULT_ADMIN_ROLE + ADMIN_ROLE | Deployer | Timelock | `grantRole()` + `revokeRole()` |
| OmniTreasury | All roles | Deployer | Timelock/Guardian | `transitionGovernance()` |
| OmniRewardManager | DEFAULT_ADMIN_ROLE + UPGRADER_ROLE | Deployer | Timelock | `grantRole()` + `revokeRole()` |

**WARNING:** If ANY transition is skipped, the deployer retains parallel authority with the timelock, creating a governance bypass (ATK-M01).

---

## Mitigations Already Present

### Strong Protections

| Protection | Contract(s) | Assessment |
|-----------|-------------|------------|
| Snapshot-based voting (ERC20Votes + OmniCore checkpoints) | OmniGovernance, OmniCoin, OmniCore | **Excellent** -- prevents flash-loan vote inflation at voting time |
| Two-tier timelock (48h routine / 7d critical) | OmniTimelockController | **Good** -- but `ossify()` selector missing from critical list (ATK-H02) |
| EmergencyGuardian cancel (3-of-N with epoch invalidation) | EmergencyGuardian, OmniTimelockController | **Excellent** -- properly prevents ghost votes, only defense against majority-holder attacks |
| Immutable EmergencyGuardian (not UUPS) | EmergencyGuardian | **Excellent** -- cannot be upgraded to remove cancel capability |
| Guardian-only pause (cannot unpause) | EmergencyGuardian | **Excellent** -- compromised guardian causes DoS, not theft |
| Ossification pattern | OmniGovernance, OmniCore, UnifiedFeeVault | **Good** -- provides decentralization signal, but should be critical-delay protected |
| Pre-minted supply (no minting after genesis) | OmniCoin, OmniRewardManager | **Excellent** -- eliminates infinite-mint attack vectors |
| MAX_SUPPLY on-chain cap | OmniCoin | **Excellent** -- defense-in-depth against compromised minter |
| `transferAdminToTimelock()` one-shot | OmniGovernance | **Good** -- atomic admin transfer (needs msg.sender fix, ATK-L03) |
| `transitionGovernance()` atomic handoff | OmniTreasury | **Good** -- grants new roles, revokes old in correct order |
| AccessControlDefaultAdminRules (48h delay) | OmniCoin | **Good** -- admin transfer requires 48h wait |
| Two-step admin transfer (48h delay) | OmniCore | **Good** -- prevents accidental admin lockout |
| Pull pattern for fee claims | UnifiedFeeVault | **Good** -- reverting recipients don't block distribution |
| Internal timelocks on swap router / privacy bridge | UnifiedFeeVault | **Good** -- 48h delay on critical config changes |
| Propose/confirm ossification (48h internal delay) | UnifiedFeeVault | **Good** -- prevents accidental ossification |
| Self-call protection | OmniTreasury | **Good** -- `SelfCallNotAllowed` prevents treasury self-exploitation |
| Defense-in-depth critical selector validation | OmniGovernance + OmniTimelockController | **Excellent** -- both governance and timelock independently validate |

### Gaps in Protection

| Gap | Description | Severity |
|-----|-------------|----------|
| No rate limiting on validator rewards | OmniRewardManager can be drained instantly | HIGH |
| `ossify()` not a critical selector | Permanent action on 48h delay | HIGH |
| Pioneer Phase parallel authority | Deployer + governance both have power | MEDIUM (operational) |
| `setRecipients()` not critical selector | Fee redirection on 48h delay | MEDIUM |
| `proposeAdminTransfer()` not critical selector | Admin hijack on 48h delay | MEDIUM |
| `msg.sender` vs `_msgSender()` in admin transfer | Admin roles not revoked via forwarder | LOW |

---

## Recommended Fixes

### Priority 1: Must-Fix Before Mainnet

| # | Fix | Effort | Impact |
|---|-----|--------|--------|
| 1 | Add on-chain rate limiting to `OmniRewardManager.distributeValidatorReward()` (MAX_BLOCK_REWARD + MIN_INTERVAL) | Medium | Blocks ATK-H01 (governance takeover via reward drain) |
| 2 | Register `ossify()` selector (0x32e3a7b4) as critical in OmniTimelockController constructor | Trivial | Blocks ATK-H02 (premature ossification on 48h delay) |
| 3 | Fix `msg.sender` -> `_msgSender()` in `OmniGovernance.transferAdminToTimelock()` | Trivial | Blocks ATK-L03 (admin roles not revoked via forwarder) |

### Priority 2: Should-Fix Before Mainnet

| # | Fix | Effort | Impact |
|---|-----|--------|--------|
| 4 | Restrict proposer cancellation to pre-vote stages in OmniGovernance | Low | Addresses ATK-M02 (proposer veto on approved proposals) |
| 5 | Register `proposeAdminTransfer` selector as critical | Trivial | Addresses ATK-M04 (admin hijack on 48h delay) |
| 6 | Register `setRecipients` selector as critical (via governance proposal post-deploy) | Trivial | Addresses ATK-M03 (fee redirection on 48h delay) |
| 7 | Create atomic Pioneer Phase -> Production transition script with verification | Medium | Addresses ATK-M01 (parallel authority) |

### Priority 3: Consider

| # | Fix | Effort | Impact |
|---|-----|--------|--------|
| 8 | Fix EmergencyGuardian `_executeCancel()` to emit event instead of revert on race condition | Low | Addresses ATK-L02 |
| 9 | Add `_requireOperationPending()` to EmergencyGuardian `revokeCancel()` | Trivial | State hygiene |
| 10 | Track and revoke ERC20 allowances in OmniTreasury during governance transition | Medium | Addresses ATK-I01 |
| 11 | Revert governance cancel if timelock cancel fails | Low | Addresses ATK-L01 (state divergence) |

---

## Conclusion

The OmniBazaar governance stack demonstrates mature architectural design with appropriate separation of concerns: OmniGovernance handles proposal lifecycle, OmniTimelockController enforces delays, EmergencyGuardian provides emergency response, and role-based access control gates all sensitive operations.

The most significant cross-contract vulnerability is the **absence of on-chain rate limiting on OmniRewardManager's validator reward distribution** (ATK-H01). This single gap creates a chain reaction: reward pool drain -> voting power accumulation -> governance takeover -> treasury drain. The entire attack chain can be initiated in a single transaction and complete in 13 days, with the community's only defense being the EmergencyGuardian's 3-of-N cancel during the 7-day timelock window. Adding a simple per-call maximum and minimum interval eliminates this attack path entirely.

The second major finding is that **`ossify()` is not classified as a critical selector** (ATK-H02), allowing the most permanent and irreversible action in the protocol to proceed on a 48-hour delay instead of the 7-day delay applied to lesser operations like role changes and pause/unpause. This is a one-line fix in the OmniTimelockController constructor.

The remaining Medium findings relate to Pioneer Phase transitional risks and governance griefing vectors that should be addressed before production but do not represent immediate fund-loss risk.

The protocol's defensive architecture is fundamentally sound. The snapshot-based voting, two-tier timelock, epoch-based guardian signatures, pre-minted supply, and immutable EmergencyGuardian form a strong multi-layered defense. The recommended fixes address the specific gaps identified in this cross-contract analysis without requiring architectural changes.

**Overall Cross-System Risk Rating:** Medium-High (reducible to Low after Priority 1 fixes)

**Pre-Mainnet Readiness:** Deploy only after fixing ATK-H01 (rate limiting) and ATK-H02 (ossify selector). All other fixes are recommended but not blocking.

---

## Files Reviewed

| File | Lines | Role |
|------|-------|------|
| `Coin/contracts/OmniGovernance.sol` | 1,090 | Governance proposal lifecycle |
| `Coin/contracts/OmniTimelockController.sol` | 339 | Two-tier timelock with critical selectors |
| `Coin/contracts/EmergencyGuardian.sol` | 533 | Emergency pause and cancel authority |
| `Coin/contracts/OmniCoin.sol` | 293 | XOM token with ERC20Votes |
| `Coin/contracts/OmniCore.sol` | 1,369 | Core protocol with staking and checkpoints |
| `Coin/contracts/OmniRewardManager.sol` | 2,108 | Pre-minted reward pool management |
| `Coin/contracts/UnifiedFeeVault.sol` | 1,567 | Fee collection and 70/20/10 distribution |
| `Coin/contracts/OmniTreasury.sol` | 569 | Protocol-Owned Liquidity treasury |
| `Coin/audit-reports/round6/OmniGovernance-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/OmniTimelockController-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/EmergencyGuardian-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/OmniCoin-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/OmniRewardManager-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/UnifiedFeeVault-audit-2026-03-10.md` | -- | Prior single-contract audit |
| `Coin/audit-reports/round6/OmniTreasury-audit-2026-03-10.md` | -- | Prior single-contract audit |

---

*Generated by Claude Opus 4.6 -- Cross-Contract Adversarial Security Review*
*Date: 2026-03-10*
