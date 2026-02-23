# Security Audit Report: OmniGovernance

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniGovernance.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 341
**Upgradeable:** No
**Handles Funds:** No (advisory governance — no on-chain execution or token custody)

## Executive Summary

OmniGovernance is an ultra-lean advisory governance contract where users create proposals (identified by off-chain content hashes), vote with XOM token-weighted power over a 3-day period, and mark proposals as executed for validator off-chain action. The contract uses OpenZeppelin's ReentrancyGuard and references OmniCore for token address resolution and validator role checking.

The audit found **1 Critical vulnerability**: voting weight is based on current `balanceOf()` with no snapshot mechanism, enabling both flash-loan governance attacks (Beanstalk-style, $182M precedent) and vote-weight recycling where the same tokens are counted multiple times via transfer between addresses. The NatSpec falsely claims snapshot-based voting. Additionally, staked XOM tokens are excluded from voting weight, disenfranchising the most committed protocol participants. Both audit agents independently confirmed the flash-loan/vote-recycling issue as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 1 |
| Medium | 4 |
| Low | 4 |
| Informational | 2 |

## Findings

### [C-01] Flash Loan Governance Attack & Vote-Weight Recycling — No Balance Snapshot

**Severity:** Critical
**Lines:** 205-212 (_getVotingWeight), 162 (vote), 133 (propose)
**Agents:** Both (Agent A: Critical + High separate findings; Agent B: Critical)

**Description:**

`_getVotingWeight()` at line 207 reads `IERC20(tokenAddress).balanceOf(msg.sender)` — the caller's **current** token balance at the moment of the `vote()` transaction. OmniCoin does not implement `ERC20Votes` (no `getPastVotes`, no checkpointing, no snapshots). The NatSpec at line 158 falsely claims: *"Voting power based on token balance at proposal creation"*.

This enables two independent attacks:

**Attack 1 — Flash Loan Governance:**
```
1. Flash-borrow 664M XOM (4% of 16.6B = quorum)
2. Call vote(proposalId, 1) with 664M weight
3. Return flash loan in same transaction
4. Cost: flash loan fee only. Voting outcome controlled.
```

**Attack 2 — Vote-Weight Recycling (no flash loan needed):**
```
1. Alice holds 100M XOM, votes FOR proposal #5 with 100M weight
2. Alice transfers 100M XOM to Bob (address she controls)
3. Bob votes FOR with 100M weight (same tokens counted twice)
4. Repeat across N addresses — 100M tokens produce N × 100M votes
```

The `hasVoted` mapping only prevents the same *address* from voting twice, not the same *tokens*.

**Real-World Precedent:** Beanstalk (April 2022) — $182M stolen via flash-loan governance takeover using the exact same vulnerability pattern.

**Impact:** Complete subversion of governance outcomes. While OmniGovernance is advisory (no on-chain execution), a passed governance vote provides social legitimacy for malicious parameter changes that validators execute off-chain. An attacker with 66.4M XOM (0.4% of supply) cycling through 10 addresses can single-handedly meet quorum and pass any proposal.

**Recommendation:** Implement OpenZeppelin's `ERC20Votes` extension in OmniCoin.sol and use snapshot-based voting:
```solidity
struct Proposal {
    // ... existing fields ...
    uint256 snapshotBlock;
}

// In propose():
proposals[proposalId].snapshotBlock = block.number - 1;

// In _getVotingWeight():
weight = IVotes(tokenAddress).getPastVotes(msg.sender, proposal.snapshotBlock);
```

---

### [H-01] Staked XOM Tokens Excluded From Governance Voting

**Severity:** High
**Lines:** 205-212
**Agent:** Agent B

**Description:**

When users stake XOM via `OmniCore.stake()`, their tokens are transferred to the OmniCore contract. Their wallet `balanceOf` drops by the staked amount. A user who stakes their entire balance has zero voting weight and cannot vote or propose.

OmniBazaar's staking tiers range from 1M to 1B+ XOM. A Tier 5 staker with 1B+ XOM staked — the most invested participant in the ecosystem — has zero governance power. This creates a perverse incentive: users must choose between staking rewards (5-12% APR) and governance participation.

**Impact:** Governance is dominated by unstaked (less committed) token holders, inverting the Proof of Participation philosophy. The most economically committed users are excluded from protocol governance.

**Recommendation:** Include staked balance in voting weight:
```solidity
function _getVotingWeight() private view returns (uint256 weight) {
    address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
    weight = IERC20(tokenAddress).balanceOf(msg.sender);
    OmniCore.Stake memory userStake = CORE.getStake(msg.sender);
    if (userStake.active) weight += userStake.amount;
    if (weight == 0) revert InsufficientBalance();
}
```

---

### [M-01] Quorum Calculated Against Mutable totalSupply

**Severity:** Medium
**Lines:** 267-269
**Agents:** Both

**Description:**

The `execute()` function calculates quorum using `IERC20(tokenAddress).totalSupply()` at execution time. OmniCoin's total supply grows from ~4.13B to 16.6B over 40 years via block rewards and bonuses. The 4% quorum threshold correspondingly grows from ~165M to ~664M XOM, making governance progressively harder.

A proposal that meets quorum at creation may fail at execution 3+ days later due to newly minted tokens raising the denominator. Conversely, a MINTER_ROLE holder could strategically mint tokens to inflate the quorum and block proposals.

**Recommendation:** Snapshot `totalSupply` at proposal creation and use it for quorum:
```solidity
proposals[proposalId].snapshotSupply = IERC20(tokenAddress).totalSupply();
// In execute(): use proposal.snapshotSupply instead of live totalSupply()
```

---

### [M-02] No Voting Delay — Proposer Gets First-Mover Advantage

**Severity:** Medium
**Lines:** 139
**Agent:** Agent B

**Description:**

Voting starts in the same block as proposal creation (`startTime = block.timestamp`). The proposer can create a proposal and vote atomically in one transaction. Other token holders have no advance notice. Combined with C-01 (no snapshot), there is no window for the community to observe the proposal before voting power is measured.

Standard governance (OpenZeppelin Governor, Compound) includes a 1-2 day `votingDelay`.

**Recommendation:** Add a voting delay:
```solidity
uint256 public constant VOTING_DELAY = 1 days;
uint256 startTime = block.timestamp + VOTING_DELAY;
```

---

### [M-03] NatSpec Falsely Claims Snapshot-Based Voting

**Severity:** Medium
**Lines:** 158
**Agents:** Both

**Description:**

Line 158 states: `@dev Voting power based on token balance at proposal creation`. The implementation uses `balanceOf(msg.sender)` at vote time. There is no snapshot, no checkpoint, no reference to proposal creation time. This directly contradicts the specification and could mislead auditors, integrators, and users into believing the contract is safe from vote-recycling.

**Recommendation:** Either implement the snapshot (see C-01) or correct the NatSpec to: `@dev WARNING: Voting power based on CURRENT balance — same tokens can vote multiple times if transferred`.

---

### [M-04] Missing Zero-Address Validation for CORE

**Severity:** Medium
**Lines:** 117-119
**Agent:** Agent A

**Description:**

The constructor accepts `_core` without validating it is not `address(0)`. Since `CORE` is `immutable`, deploying with `address(0)` produces a permanently broken contract — every function calling `CORE.getService()` or `CORE.hasRole()` reverts.

**Recommendation:** `if (_core == address(0)) revert InvalidAddress();`

---

### [L-01] No Validation That getService() Returns Non-Zero

**Severity:** Low
**Lines:** 129, 206, 267
**Agent:** Agent A

**Description:**

Three functions call `CORE.getService(OMNICOIN_SERVICE)` and use the result without checking for `address(0)`. If the OMNICOIN service is not registered, calls revert with opaque low-level errors rather than descriptive messages.

**Recommendation:** Add a helper that validates the returned address is non-zero.

---

### [L-02] cancel() Uses Misleading Error for Authorization Failure

**Severity:** Low
**Lines:** 289-291
**Agents:** Both

**Description:**

When a non-validator calls `cancel()`, the function reverts with `ProposalNotActive()` — suggesting a proposal state issue when the actual problem is unauthorized access. A dedicated `Unauthorized()` error would improve debuggability.

**Recommendation:** Add `error Unauthorized();` and use it for the role check.

---

### [L-03] No Timelock on Proposal Execution

**Severity:** Low
**Lines:** 252
**Agent:** Agent A

**Description:**

`execute()` can be called by anyone immediately after the voting period ends. There is no timelock, so validators must act on the `ProposalExecuted` event immediately. No window exists for the community to review or challenge passed proposals before they take effect.

**Recommendation:** Consider adding a `TIMELOCK_DELAY = 2 days` between vote end and earliest execution.

---

### [L-04] Missing Proposal Existence Check in execute()

**Severity:** Low
**Lines:** 252-280
**Agent:** Agent B

**Description:**

`execute()` does not check `proposal.startTime == 0` for non-existent proposals. A zero-initialized proposal passes the `executed`/`canceled` checks but reverts with `ProposalNotPassed` (because `0 < 0 + 1`). The error is misleading — the proposal doesn't exist, it didn't "fail to pass."

**Recommendation:** Add `if (proposal.startTime == 0) revert ProposalNotActive();` at the top of `execute()`.

---

### [I-01] proposalHash Indexed Wastes Topic Slot

**Severity:** Informational
**Lines:** 73
**Agent:** Agent A

**Description:**

`bytes32 indexed proposalHash` in the `ProposalCreated` event uses one of the 3 available topic slots. Filtering by exact proposal hash is a niche use case. Moving it to the data portion would be more convenient for log parsers.

**Recommendation:** Remove `indexed` from `proposalHash`.

---

### [I-02] Floating Pragma

**Severity:** Informational
**Lines:** 2
**Agent:** Agent A

**Description:**

`pragma solidity ^0.8.19;` allows compilation with any 0.8.x compiler from 0.8.19 onward. Pin to a specific version for reproducible builds.

**Recommendation:** `pragma solidity 0.8.20;`

---

## Static Analysis Results

**Solhint:** 0 errors, 3 warnings
- 1 function ordering (style)
- 2 gas-strict-inequalities (minor)

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 21 raw findings -> 12 unique)
- Pass 6: Report generation

## Conclusion

OmniGovernance has **one Critical vulnerability that makes the contract fundamentally broken**:

1. **Flash loan + vote recycling (C-01)** allows arbitrary governance manipulation with minimal capital. The root cause is that OmniCoin does not implement `ERC20Votes` — the standard checkpoint-based voting extension used by virtually all production governance systems. Implementing `ERC20Votes` resolves C-01, H-01, M-01, M-02, and M-03 simultaneously.

2. **Staker disenfranchisement (H-01)** excludes the most economically committed participants from governance, inverting the Proof of Participation philosophy.

The contract is advisory-only (no on-chain execution), which limits the direct financial impact of governance manipulation. However, governance outcomes carry social legitimacy and inform validator off-chain actions, so the flash-loan vulnerability remains Critical.

No tests exist for this contract, which should be considered a deployment blocker.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
