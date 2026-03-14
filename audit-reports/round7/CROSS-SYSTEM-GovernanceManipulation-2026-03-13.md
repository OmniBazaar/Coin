# Cross-System Adversarial Review: Governance Manipulation

**Audit Round:** 7 -- Cross-System Adversarial
**Date:** 2026-03-13 21:07 UTC
**Auditor:** Claude Opus 4.6 (Automated Adversarial Review)
**Scope:** OmniGovernance, OmniTimelockController, EmergencyGuardian, OmniCoin (ERC20Votes), OmniCore
**Severity Scale:** CRITICAL > HIGH > MEDIUM > LOW > INFORMATIONAL

---

## Executive Summary

This cross-system review analyzes governance manipulation vectors across five interconnected contracts: OmniGovernance (proposal lifecycle), OmniTimelockController (execution delay), EmergencyGuardian (emergency powers), OmniCoin (voting power via ERC20Votes), and OmniCore (staking-based voting weight). The analysis covers flash-loan voting attacks, timelock bypass, critical parameter targeting, quorum manipulation via delegation, and treasury/minting drain scenarios.

**Overall Assessment:** The governance architecture is well-designed with multiple layers of defense-in-depth. Prior audit rounds have addressed the most critical vectors (ATK-H02 staking snapshot, H-01 admin transfer, M-02 critical selector enforcement). Several residual risks remain, primarily around the interaction boundaries between contracts.

---

## Analysis 1: Flash Loan Voting

### Question: Can voting power be temporarily inflated via flash loans?

### Finding GOV-XSYS-01: Proposal Creation Uses Current Voting Power (Not Snapshot)

**Severity:** LOW

**Location:** `contracts/OmniGovernance.sol:388-390`

**Description:**
The `propose()` function checks the proposer's voting power at the *current* moment via `getVotingPower(caller)`, which calls `omniCoin.getVotes(account)` (current votes, not past votes). This means an attacker could theoretically flash-borrow XOM, delegate to themselves, and create a proposal within the same transaction.

```solidity
// OmniGovernance.sol:388-390 (propose)
address caller = _msgSender();
uint256 votingPower = getVotingPower(caller);
if (votingPower < PROPOSAL_THRESHOLD) {
    revert InsufficientVotingPower();
}
```

```solidity
// OmniGovernance.sol:698-708 (getVotingPower - uses CURRENT values)
function getVotingPower(address account) public view returns (uint256) {
    uint256 delegatedPower = omniCoin.getVotes(account); // CURRENT
    uint256 stakedPower = _getStakedAmount(account);     // CURRENT
    return delegatedPower + stakedPower;
}
```

**However**, this is mitigated by several factors:
1. The PROPOSAL_THRESHOLD is only 10,000 XOM -- a modest amount that makes this attack economically uninteresting (the attacker gains only the ability to *create* a proposal, not to pass it).
2. ERC20Votes requires `delegate()` to be called, and delegation checkpoints are block-based. In a single transaction, the flash-borrowed tokens would need to be delegated, which creates a checkpoint at `block.number`. But `getVotes()` returns the *current* checkpoint value, which would include the flash-borrowed amount in the same block.
3. The actual *voting* uses snapshot-based `getVotingPowerAt(voter, proposal.snapshotBlock)` with `getPastVotes()` at proposal creation block -- meaning the flash loan would only help create the proposal, not vote on it.

**Impact:** An attacker can create spam proposals without holding 10,000 XOM permanently, but cannot influence voting outcomes. The 1-day VOTING_DELAY ensures voting power is measured at the snapshot block, preventing flash loan voting.

**Risk Assessment:** Low. Creating a proposal is annoying but not exploitable -- it still requires majority quorum to pass. Gas cost to create proposals provides natural spam resistance.

**Recommendation:** Consider using `omniCoin.getPastVotes(caller, block.number - 1)` in `propose()` to use the *prior* block's checkpoint. This is the standard Governor Bravo pattern and would close the theoretical window entirely.

---

### Finding GOV-XSYS-02: Voting Power Snapshot Is Properly Protected

**Severity:** INFORMATIONAL (Positive Finding)

**Location:** `contracts/OmniGovernance.sol:850-885`

**Description:**
Vote casting correctly uses `getVotingPowerAt(voter, proposal.snapshotBlock)` which calls `omniCoin.getPastVotes()` for delegated power and `OmniCore.getStakedAt()` for staked power. This means:

1. **Delegated XOM:** Uses ERC20Votes checkpoints at `proposal.snapshotBlock`. Flash loans obtained *after* the snapshot block have zero voting weight.
2. **Staked XOM:** Uses `OmniCore._stakeCheckpoints` (Trace224) with `upperLookup(blockNumber)`. The ATK-H02 fix removed the fallback to current staking balance, so staking after the snapshot block also has zero weight.
3. **VOTING_DELAY:** 1 day between proposal creation and vote start. Even if an attacker creates a proposal with flash-loaned tokens, they cannot vote with those tokens because the snapshot is at creation time and the tokens are returned in the same block.

**Conclusion:** Flash loan voting is effectively prevented. No action needed.

---

## Analysis 2: Timelock Bypass via EmergencyGuardian

### Question: Can the timelock be bypassed via EmergencyGuardian?

### Finding GOV-XSYS-03: EmergencyGuardian Cannot Execute -- Only Cancel and Pause

**Severity:** INFORMATIONAL (Positive Finding)

**Location:** `contracts/EmergencyGuardian.sol:10-35`

**Description:**
The EmergencyGuardian is deliberately restricted to two actions:
1. **Pause** (1-of-N): Any single guardian can pause registered pausable contracts.
2. **Cancel** (3-of-N): Three guardian signatures can cancel a queued timelock operation.

The EmergencyGuardian explicitly **cannot**:
- Execute operations (no EXECUTOR_ROLE)
- Queue new proposals (no PROPOSER_ROLE)
- Upgrade contracts (no upgrade authority)
- Unpause contracts (governance must unpause via timelock)
- Change its own parameters (timelock manages guardians)

**Conclusion:** The EmergencyGuardian cannot bypass the timelock for execution. It can only *block* executions (cancel) or *halt* contracts (pause). This is the correct design.

---

### Finding GOV-XSYS-04: Guardian Pause Creates Asymmetric Power (Cannot Unpause)

**Severity:** LOW

**Location:** `contracts/EmergencyGuardian.sol:247-253`, multiple contract `pause()`/`unpause()` functions

**Description:**
A single compromised guardian can pause any registered pausable contract (OmniCoin, OmniCore, etc.). To unpause requires governance action through the timelock, which takes minimum 48 hours (ROUTINE_DELAY). During this period:

1. OmniCoin transfers are halted (ERC20Pausable)
2. OmniCore staking/unstaking is halted
3. DEX settlements are halted
4. All dependent services are effectively offline

An attacker who compromises one guardian key can force a minimum 48-hour protocol halt:
- Guardian pauses OmniCoin
- Governance must create a proposal to unpause
- 1 day voting delay + 5 day voting period + timelock delay

Looking at the timelock's critical selectors:
```solidity
// pause() and unpause() are both CRITICAL selectors
_criticalSelectors[SEL_PAUSE] = true;   // 0x8456cb59
_criticalSelectors[SEL_UNPAUSE] = true; // 0x3f4ba83a
```

This means the governance unpause proposal would require CRITICAL classification with 7-day timelock delay, leading to a potential **13-day** protocol halt from a single guardian compromise (1d voting delay + 5d voting period + 7d critical timelock).

**Risk Assessment:** Low severity because the guardian set requires minimum 5 members and should be publicly known individuals. However, the asymmetry between 1-guardian-to-pause vs 13-days-to-unpause is a significant operational risk.

**Recommendation:** Consider adding an "emergency unpause" mechanism that requires either:
- The same guardian who paused (can undo their own pause within a time window)
- A higher threshold of guardians (e.g., 3-of-N to unpause) without going through governance

Alternatively, reclassify `unpause()` as ROUTINE (48h) rather than CRITICAL (7d) since the damage from unpausing is far less than from pausing.

---

### Finding GOV-XSYS-05: Guardian Cancel Threshold Fixed at 3 Regardless of Set Size

**Severity:** INFORMATIONAL

**Location:** `contracts/EmergencyGuardian.sol:57`

**Description:**
The CANCEL_THRESHOLD is fixed at 3, regardless of the total guardian count. With minimum 5 guardians, this requires 60% (3/5). But if the guardian set grows to 20 (as recommended for L2BEAT Stage 2), it becomes only 15% (3/20).

This is explicitly acknowledged in the contract's NatSpec (M-03 rationale) and is a deliberate trade-off favoring emergency response speed over collusion resistance. The cancel power is narrowly scoped (cannot execute, only cancel), which limits abuse potential.

**Conclusion:** Accepted design decision. Documented for completeness.

---

## Analysis 3: Critical Parameter Targeting via Governance Proposals

### Question: Can governance proposals target critical parameters?

### Finding GOV-XSYS-06: Governance Can Re-Grant MINTER_ROLE on OmniCoin

**Severity:** HIGH

**Location:** `contracts/OmniCoin.sol:158`, `contracts/OmniGovernance.sol:374-431`, `contracts/OmniTimelockController.sol:62-63`

**Description:**
After deployment, the plan is to revoke MINTER_ROLE from all addresses, making OmniCoin non-mintable. However, the DEFAULT_ADMIN_ROLE holder (which should be the timelock after governance transition) retains the ability to grant MINTER_ROLE to any address.

A malicious governance proposal could:
1. Call `omniCoin.grantRole(MINTER_ROLE, attackerAddress)` via the timelock
2. After execution, the attacker calls `omniCoin.mint(attacker, MAX_SUPPLY - totalSupply())`

The attack is constrained by:
- `grantRole()` selector `0x2f2ff15d` IS classified as CRITICAL, requiring 7-day delay
- The MAX_SUPPLY cap of 16.6 billion XOM limits minting to `MAX_SUPPLY - totalSupply()` which is 0 after full genesis mint
- So in practice, since `INITIAL_SUPPLY == MAX_SUPPLY == 16.6B XOM`, no additional minting is possible even with MINTER_ROLE

```solidity
// OmniCoin.sol:158-160
function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
    _mint(to, amount);
}
```

**Risk Assessment:** The MAX_SUPPLY cap makes this a non-issue for OmniCoin specifically. However, PrivateOmniCoin also has a MINTER_ROLE and MAX_SUPPLY. If any burn has occurred (reducing totalSupply below MAX_SUPPLY), re-granting MINTER_ROLE would allow re-minting up to MAX_SUPPLY.

**Impact:** If any XOM has been burned (via OmniCoin's burn function or PrivateOmniCoin's privacy conversion), governance could theoretically re-mint up to the burned amount. The 7-day critical delay provides community observation time.

**Recommendation:**
1. After revoking MINTER_ROLE in production, consider adding a permanent mint lock function similar to `ossify()` but specifically for minting:
   ```solidity
   bool private _mintingLocked;
   function lockMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
       _mintingLocked = true;
   }
   function mint(...) { if (_mintingLocked) revert MintingLocked(); ... }
   ```
2. This permanently closes the mint vector regardless of role assignments.

---

### Finding GOV-XSYS-07: Governance Can Drain OmniTreasury via GOVERNANCE_ROLE

**Severity:** MEDIUM

**Location:** `contracts/OmniTreasury.sol:235-252, 381-401`

**Description:**
If the OmniTimelockController holds GOVERNANCE_ROLE on OmniTreasury, then any successfully passed governance proposal can:

1. Call `OmniTreasury.transferToken(XOM, attacker, entireBalance)` to drain ERC-20 tokens
2. Call `OmniTreasury.transferNative(attacker, entireBalance)` to drain native XOM
3. Call `OmniTreasury.execute(target, value, data)` to perform arbitrary calls as the treasury

The `execute()` function has a `SelfCallNotAllowed` check preventing re-entrancy into the treasury itself, but can call any external contract with any calldata.

**Mitigations in place:**
- Requires a passing governance vote (4% quorum, majority for-votes)
- Would be classified as ROUTINE (48h delay) since `transferToken` is not a critical selector
- EmergencyGuardian can cancel the queued operation with 3-of-N signatures
- Community has 48 hours to observe and react

**Risk Assessment:** With a total supply of 16.6B XOM and a 4% quorum requirement, an attacker needs 664M XOM participating in the vote. If the attacker holds >332M XOM (2% of supply) and turnout is minimal, they could pass a drain proposal. Treasury drain functions using only 48h ROUTINE delay is the main concern.

**Recommendation:**
1. Add `transferToken` and `transferNative` selectors to the critical selector list, requiring 7-day delay for treasury drains instead of 48 hours.
2. Consider adding a per-transaction or per-day withdrawal limit on the treasury that requires a CRITICAL governance action to increase.

---

### Finding GOV-XSYS-08: Governance Can Upgrade Any UUPS Contract

**Severity:** MEDIUM

**Location:** Multiple UUPS contracts, `contracts/OmniTimelockController.sol:57-60`

**Description:**
If the timelock holds DEFAULT_ADMIN_ROLE or ADMIN_ROLE on UUPS-upgradeable contracts (OmniCore, OmniGovernance, OmniRewardManager, OmniValidatorRewards, etc.), governance can upgrade their implementations to arbitrary code.

A malicious upgrade proposal could:
1. Deploy a new implementation that removes all access controls
2. Propose `upgradeToAndCall(maliciousImpl, initData)` on OmniCore
3. After the 7-day delay, the upgrade executes, replacing all logic

**Mitigations in place:**
- `upgradeTo` and `upgradeToAndCall` are CRITICAL selectors (7-day delay)
- EmergencyGuardian can cancel during the 7-day window
- OmniCore and OmniGovernance both support `ossify()` to permanently disable upgrades
- Community has 7 days + voting period to observe

**Risk Assessment:** This is the most powerful governance action available and is appropriately gated. The 7-day delay is the industry standard for upgradeable contracts. Once ossified, this vector is permanently closed.

**Recommendation:** After the protocol stabilizes, encourage ossification of critical contracts (OmniCoin is non-upgradeable already, OmniCore and OmniGovernance should be ossified once stable). Note that `ossify()` is itself a CRITICAL selector (GOV-ATK-H02 fix), requiring 7-day delay, which is correct.

---

### Finding GOV-XSYS-09: Governance Can Remove Critical Selectors to Weaken Timelock

**Severity:** MEDIUM

**Location:** `contracts/OmniTimelockController.sol:184-191`

**Description:**
The `removeCriticalSelector()` function allows governance to reclassify critical operations as routine, reducing their timelock from 7 days to 48 hours. A two-stage attack:

1. **Stage 1:** Propose removal of `SEL_UPGRADE_TO` from critical selectors (requires 7-day delay since `removeCriticalSelector` is itself CRITICAL -- M-02 fix).
2. **Stage 2:** After stage 1 executes, propose an upgrade with only 48-hour delay.

**Mitigations:**
- Stage 1 requires 7-day delay (SEL_REMOVE_CRITICAL is CRITICAL itself)
- EmergencyGuardian can cancel stage 1 during its 7-day window
- Stage 2 still requires full governance vote
- Total attack window: 1d delay + 5d voting + 7d timelock + 1d delay + 5d voting + 48h = ~21 days minimum
- Community and guardians have ample time to detect and respond

**Risk Assessment:** The multi-stage nature and extended timeline make this attack impractical. The design is correct.

**Recommendation:** No code change needed. Monitoring and alerting on `CriticalSelectorUpdated` events is sufficient.

---

## Analysis 4: Quorum Manipulation Through Delegation

### Question: Can quorum be manipulated through delegation?

### Finding GOV-XSYS-10: Quorum Based on Total Supply Creates Fixed Target

**Severity:** LOW

**Location:** `contracts/OmniGovernance.sol:137-141, 894-910`

**Description:**
Quorum is defined as 4% of `snapshotTotalSupply` (total supply at proposal creation time). With 16.6B XOM total supply, quorum requires 664M XOM worth of total votes (for + against + abstain).

```solidity
uint256 public constant QUORUM_BPS = 400; // 4%
// ...
uint256 quorumVotes = (proposal.snapshotTotalSupply * QUORUM_BPS) / BASIS_POINTS;
uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
return totalVotes >= quorumVotes;
```

**Delegation dynamics:**
- ERC20Votes requires explicit `delegate()` calls to activate voting power
- If most token holders have not delegated, achieving quorum becomes much harder
- A whale who holds 664M+ XOM and has delegated to themselves can unilaterally meet quorum
- Delegation is free and instant -- no timelock or delay

**Attack scenario:**
1. Attacker accumulates 664M XOM (4% of supply) over time
2. Delegates to self, creates proposal to drain treasury
3. Votes "For" with 664M XOM, meeting both quorum and majority
4. If no one votes "Against", the proposal passes

**Risk Assessment:** This is a fundamental property of token governance. With 4% quorum, an attacker needs approximately 4% of total supply. If large portions of the supply are in reward pools, staking contracts, or the treasury (not circulating), the attacker's 4% of *total supply* could represent a much larger fraction of *circulating supply*.

**Recommendation:**
1. Consider using circulating supply (total supply minus known pool balances) for quorum calculation. This requires more complex logic but better reflects actual governance participation.
2. Consider implementing "time-weighted quorum" where quorum is based on the average voting participation of recent proposals, not a fixed percentage.
3. Ensure large token holders (reward pools, treasury, staking pool) have NOT delegated their voting power.

---

### Finding GOV-XSYS-11: Abstain Votes Count Toward Quorum

**Severity:** INFORMATIONAL

**Location:** `contracts/OmniGovernance.sol:904-909`

**Description:**
Abstain votes count toward quorum but not toward the majority calculation. This means an attacker who cannot muster enough "For" votes can still influence quorum by voting "Abstain" on competing proposals.

```solidity
uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
return totalVotes >= quorumVotes;
```

This is standard Governor Bravo/OpenZeppelin Governor behavior and is generally considered correct -- abstain votes represent engagement without preference, which should count toward the minimum participation threshold.

**Conclusion:** Standard behavior, no action needed.

---

### Finding GOV-XSYS-12: No Double Counting Between Staked and Delegated Voting Power (Verified Correct)

**Severity:** LOW (Verified Safe)

**Location:** `contracts/OmniGovernance.sol:698-727`

**Description:**
Voting power is calculated as `delegatedPower + stakedPower`:

```solidity
function getVotingPower(address account) public view returns (uint256) {
    uint256 delegatedPower = omniCoin.getVotes(account);
    uint256 stakedPower = _getStakedAmount(account);
    return delegatedPower + stakedPower;
}
```

When a user stakes XOM in OmniCore:
1. XOM tokens are transferred from the user to OmniCore via `safeTransferFrom()`
2. This triggers `ERC20Votes._update()`, which reduces the user's delegation checkpoint
3. OmniCore does NOT delegate -- so the delegated power naturally decreases when staking

This means there is **no double counting** in the normal case:
- Before staking 1000 XOM: delegatedPower = 1000, stakedPower = 0, total = 1000
- After staking 1000 XOM: delegatedPower = 0, stakedPower = 1000, total = 1000

**However**, if someone delegates to user A, and user A stakes their own tokens:
- User B delegates 500 XOM to user A
- User A holds 1000 XOM, delegates to self, then stakes 1000 XOM
- After staking: delegatedPower = 500 (from B's delegation), stakedPower = 1000, total = 1500
- But user A only controls 1000 XOM of their own + 500 delegated = 1500 total XOM influence

This is actually correct behavior -- the 1000 staked and 500 delegated represent different tokens.

**Conclusion:** No double counting. The separation of delegation (ERC20Votes checkpoints) and staking (OmniCore checkpoints) is clean because staking transfers tokens, which removes them from the delegation system. Verified correct.

---

## Analysis 5: Treasury Drain and Token Minting via Governance

### Question: Can governance be used to drain treasury or mint tokens?

### Finding GOV-XSYS-13: OmniTreasury.execute() Enables Arbitrary Calls

**Severity:** MEDIUM

**Location:** `contracts/OmniTreasury.sol:381-401`

**Description:**
The `execute()` function allows arbitrary external calls with the treasury's authorization. If the timelock holds GOVERNANCE_ROLE:

1. **Direct drain:** `transferToken()` or `transferNative()` to drain treasury balances
2. **Approval drain:** `approveToken()` to approve an attacker's address, then the attacker calls `transferFrom()` outside governance
3. **Indirect drain via execute():** Call any external contract -- e.g., swap treasury tokens on a DEX to a worthless token, bridge tokens to an attacker-controlled chain, etc.

The approval vector (2) is particularly concerning because:
- `approveToken()` creates a persistent allowance
- After the governance proposal executes, the attacker can drain at any future time
- The `revokeAllApprovals()` function exists but must be called separately

**Mitigations:**
- `transitionGovernance()` calls `_revokeAllApprovalsInternal()` (M-01 Round 6)
- `approveToken` is not a critical selector, so it uses 48h delay
- EmergencyGuardian can cancel during the window
- `SelfCallNotAllowed` prevents using `execute()` to grant additional roles on the treasury itself

**Recommendation:**
1. Add `approveToken`'s function selector to the critical selector list via governance, since persistent approvals are as dangerous as direct transfers.
2. Consider adding a maximum approval amount or time-limited approvals.

---

### Finding GOV-XSYS-14: OmniCoin MAX_SUPPLY Prevents Infinite Mint

**Severity:** INFORMATIONAL (Positive Finding)

**Location:** `contracts/OmniCoin.sol:82-85, 158-160`

**Description:**
OmniCoin has `INITIAL_SUPPLY == MAX_SUPPLY == 16.6B XOM`. Since `initialize()` mints the full MAX_SUPPLY, and `mint()` checks `totalSupply() + amount > MAX_SUPPLY`, no additional tokens can ever be minted regardless of MINTER_ROLE.

Even if governance re-grants MINTER_ROLE, the `mint()` function will revert with `ExceedsMaxSupply()`.

The only way to create new minting room is via `burn()`:
- `ERC20Burnable.burn()` allows any holder to burn their own tokens
- `burnFrom()` requires BURNER_ROLE (currently designed for OmniCore/PrivateOmniCoin)
- After burning, `totalSupply()` decreases, and `mint()` could be called up to `MAX_SUPPLY - totalSupply()`

**Conclusion:** The MAX_SUPPLY cap is an effective defense-in-depth against infinite mint attacks. The burn-then-remint vector exists but requires both BURNER_ROLE and MINTER_ROLE, both gated by governance/admin.

---

### Finding GOV-XSYS-15: OmniCore Fee Recipient Addresses Are Changeable via ROUTINE Delay

**Severity:** MEDIUM

**Location:** `contracts/OmniCore.sol:697-735`

**Description:**
OmniCore's `setOddaoAddress()`, `setStakingPoolAddress()`, and `setProtocolTreasuryAddress()` all require ADMIN_ROLE. If the timelock holds ADMIN_ROLE, governance can redirect all DEX fee flows:

```solidity
function setOddaoAddress(address newOddaoAddress) external onlyRole(ADMIN_ROLE) {
    if (newOddaoAddress == address(0)) revert InvalidAddress();
    oddaoAddress = newOddaoAddress;
}
```

A malicious proposal could:
1. Set `oddaoAddress` to an attacker's address
2. Set `stakingPoolAddress` to the attacker
3. Set `protocolTreasuryAddress` to the attacker
4. All subsequent `distributeDEXFees()` calls send 100% of fees to the attacker

**Mitigations:**
- These function selectors are NOT in the critical selector list by default
- They would use ROUTINE (48h) delay
- EmergencyGuardian can cancel
- The changes are visible on-chain and would be detected by monitoring

**Recommendation:**
1. Add `setOddaoAddress`, `setStakingPoolAddress`, and `setProtocolTreasuryAddress` selectors to the critical selector list, as redirecting fee flows is a high-impact change deserving 7-day delay.
2. Consider adding sanity checks (e.g., new address must be a contract, not an EOA).

---

### Finding GOV-XSYS-16: StakingRewardPool Emergency Withdraw Protects XOM

**Severity:** INFORMATIONAL (Positive Finding)

**Location:** `contracts/StakingRewardPool.sol:818-831`

**Description:**
The `emergencyWithdraw()` function in StakingRewardPool explicitly prevents withdrawing XOM (the reward token):

```solidity
function emergencyWithdraw(...) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (token == address(xomToken)) {
        revert CannotWithdrawRewardToken();
    }
    IERC20(token).safeTransfer(recipient, amount);
}
```

This means even if governance gains DEFAULT_ADMIN_ROLE on StakingRewardPool, it cannot drain the XOM rewards via the emergency function. Draining would require an upgrade (CRITICAL, 7-day delay).

**Conclusion:** Good defense-in-depth. No action needed.

---

## Summary of Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| GOV-XSYS-01 | LOW | Proposal creation uses current (not snapshot) voting power | Open |
| GOV-XSYS-02 | INFO | Voting power snapshot properly protected against flash loans | Verified |
| GOV-XSYS-03 | INFO | EmergencyGuardian cannot bypass timelock for execution | Verified |
| GOV-XSYS-04 | LOW | Single guardian can cause 13-day protocol halt via pause | Open |
| GOV-XSYS-05 | INFO | Guardian cancel threshold fixed at 3 regardless of set size | Accepted |
| GOV-XSYS-06 | HIGH | Governance can re-grant MINTER_ROLE (mitigated by MAX_SUPPLY cap) | Open |
| GOV-XSYS-07 | MEDIUM | Governance can drain OmniTreasury via GOVERNANCE_ROLE | Open |
| GOV-XSYS-08 | MEDIUM | Governance can upgrade any UUPS contract (7-day delay) | Accepted |
| GOV-XSYS-09 | MEDIUM | Governance can remove critical selectors to weaken timelock | Accepted |
| GOV-XSYS-10 | LOW | Quorum based on total supply creates fixed 664M XOM target | Open |
| GOV-XSYS-11 | INFO | Abstain votes count toward quorum (standard behavior) | Accepted |
| GOV-XSYS-12 | LOW | No double counting between staked and delegated power | Verified |
| GOV-XSYS-13 | MEDIUM | OmniTreasury.execute() enables arbitrary calls as treasury | Open |
| GOV-XSYS-14 | INFO | MAX_SUPPLY cap prevents infinite mint even with MINTER_ROLE | Verified |
| GOV-XSYS-15 | MEDIUM | OmniCore fee recipient addresses changeable via ROUTINE delay | Open |
| GOV-XSYS-16 | INFO | StakingRewardPool emergency withdraw protects XOM | Verified |

---

## Prioritized Recommendations

### Immediate (Pre-Deployment)

1. **GOV-XSYS-15:** Add `setOddaoAddress`, `setStakingPoolAddress`, and `setProtocolTreasuryAddress` function selectors to the critical selector list. Fee redirection is high-impact and should require 7-day delay.

2. **GOV-XSYS-07/13:** Add `transferToken`, `transferNative`, `approveToken`, and `execute` selectors from OmniTreasury to the critical selector list. Treasury operations should always require 7-day observation.

### Near-Term (Post-Launch)

3. **GOV-XSYS-01:** Update `propose()` to use `omniCoin.getPastVotes(caller, block.number - 1)` instead of `omniCoin.getVotes(caller)` for flash-loan resistance on proposal creation.

4. **GOV-XSYS-04:** Consider reclassifying `unpause()` from CRITICAL to ROUTINE in the timelock, or adding a guardian-level emergency unpause mechanism to reduce the worst-case protocol halt duration from 13 days to a more reasonable window.

5. **GOV-XSYS-06:** After MINTER_ROLE is revoked in production, consider adding a permanent `lockMinting()` function to OmniCoin that disables `mint()` regardless of role assignments.

### Long-Term

6. **GOV-XSYS-10:** Consider moving to circulating-supply-based quorum once token distribution stabilizes, to prevent quorum from becoming either trivially easy or impossibly hard as token distribution evolves.

7. **GOV-XSYS-08:** Ossify critical contracts (OmniCore, OmniGovernance) once the protocol is stable, permanently closing the upgrade vector.

---

## Cross-System Interaction Matrix

| Source | Target | Interaction | Risk Level |
|--------|--------|-------------|------------|
| OmniGovernance | OmniTimelockController | scheduleBatch/executeBatch via PROPOSER_ROLE | Controlled |
| OmniTimelockController | Any Contract | Arbitrary calls after delay | By Design |
| EmergencyGuardian | OmniTimelockController | cancel() via CANCELLER_ROLE | Controlled |
| EmergencyGuardian | Pausable Contracts | pause() via IPausable | 1-of-N Risk |
| OmniGovernance | OmniCoin (ERC20Votes) | getVotes/getPastVotes for voting power | Snapshot Protected |
| OmniGovernance | OmniCore | getStakedAt() for staking voting power | Checkpoint Protected |
| OmniTimelockController | OmniTreasury | transferToken/execute via GOVERNANCE_ROLE | ROUTINE Delay |
| OmniTimelockController | OmniCoin | grantRole/revokeRole via DEFAULT_ADMIN_ROLE | CRITICAL Delay |
| OmniTimelockController | OmniCore | ADMIN_ROLE operations | CRITICAL for upgrades |

---

*End of Cross-System Adversarial Review*
