# Security Audit Report: OmniArbitration (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Round 6)
**Contract:** `Coin/contracts/arbitration/OmniArbitration.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,938
**Upgradeable:** Yes (UUPS with 48-hour timelock)
**Handles Funds:** Yes (arbitrator stakes, dispute fees, appeal stakes in XOM)
**Prior Audit:** Round 4 (2026-02-28) -- 3 Critical, 5 High, 8 Medium, 4 Low, 3 Informational

---

## Executive Summary

OmniArbitration is a trustless dispute resolution system for OmniBazaar marketplace escrows. It implements 3-arbitrator panels (2-of-3 majority), appeals to 5-member panels (3-of-5 majority), evidence submission via IPFS CIDs, timeout default resolution, and a two-phase commit-reveal arbitrator selection mechanism.

**Compared to the Round 4 audit (2026-02-28), ALL Critical, ALL High, and 7 of 8 Medium findings have been fixed.** The contract has been substantially rewritten (~77% more code: 1,938 lines vs 1,091 lines) with comprehensive remediation:

- C-01 (Fee collection unimplemented): **FIXED.** `_collectAndDistributeFee()` implemented (lines 1596-1651) with 70/20/10 split.
- C-02 (Escrow disconnection): **FIXED.** `IArbitrationEscrow.resolveDispute()` interface added, `_triggerEscrowResolution()` calls it on resolution.
- C-03 (Duplicate disputes / panel shopping): **FIXED.** `escrowToDisputeId` mapping prevents multiple disputes per escrow (line 391).
- H-01 (Stake withdrawal while assigned): **FIXED.** `activeDisputeCount` tracking prevents withdrawal (lines 396, 700-703).
- H-02 (Weak randomness): **FIXED.** Two-phase commit: `createDispute()` stores `selectionBlock`, `finalizeArbitratorSelection()` uses `blockhash(selectionBlock)` 2+ blocks later (lines 809-850).
- H-03 (Voting deadlines not enforced): **FIXED.** Deadline checks added to `castVote()` (line 957) and `castAppealVote()` (line 1106). `triggerDefaultAppealResolution()` added (lines 1253-1299).
- H-04 (No upgrade timelock): **FIXED.** 48-hour timelock via `scheduleUpgrade()` / `_authorizeUpgrade()` (lines 1499-1883).
- H-05 (Appeal stake permanently locked): **FIXED.** Failed appeal stakes forfeited to ODDAO treasury (lines 1162-1168).
- M-01 (Zero-address in initialize): **FIXED.** All five parameters validated (lines 621-625).
- M-02 (No `__gap`): **FIXED.** `uint256[44] private __gap` at line 412.
- M-03 (Unbounded arbitrator pool): **FIXED.** Swap-and-pop removal via `_removeFromArbitratorPool()` (lines 1685-1700) and `arbitratorPoolIndex` mapping (line 408).
- M-04 (updateContracts no validation): **FIXED.** Code-existence checks and event added (lines 1409-1429).
- M-05 (Escrow ID 0 sentinel): **FIXED.** `d.createdAt == 0` used as sentinel (lines 813, 873, 950, 1020, 1210).
- M-06 (oddaoTreasury not updatable): **FIXED.** `setOddaoTreasury()` and `setProtocolTreasury()` admin setters added (lines 1463-1491).
- M-07 (Evidence auth wrong during appeal): **FIXED.** Appeal arbitrators checked when `d.status == Appealed` (lines 901-912).
- M-08 (setMinArbitratorStake no bounds): **FIXED.** Bounded between 100 XOM and 10,000,000 XOM (lines 1436-1455).

**New findings in this round:** 1 High (critical cross-contract integration gap), 3 Medium, 3 Low, 2 Informational.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | MinimalEscrow lacks resolveDispute() | **FIXED** — interface integrated |
| M-01 | Medium | Zero-amount disputes and zero-fee appeals | **FIXED** |
| M-02 | Medium | triggerDefaultResolution allows PendingSelection disputes | **FIXED** |
| M-03 | Medium | Appeal arbitrator selection uses single-phase randomness | **FIXED** |

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |
| Informational | 2 |

---

## Round 4 Findings -- Remediation Status

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| C-01 | Fee collection not implemented | Critical | **FIXED** -- `_collectAndDistributeFee()` at lines 1596-1651 |
| C-02 | Escrow disconnected from resolution | Critical | **FIXED** -- `_triggerEscrowResolution()` calls `escrow.resolveDispute()` |
| C-03 | Duplicate disputes / panel shopping | Critical | **FIXED** -- `escrowToDisputeId` mapping at line 391 |
| H-01 | Arbitrator stake withdrawal while assigned | High | **FIXED** -- `activeDisputeCount` guard at line 701 |
| H-02 | Weak randomness (single-phase) | High | **FIXED** -- Two-phase commit with `selectionBlock` at line 782 |
| H-03 | Voting deadlines not enforced | High | **FIXED** -- Deadline checks at lines 957, 1106; appeal timeout at line 1253 |
| H-04 | No upgrade timelock | High | **FIXED** -- 48h timelock at lines 1499-1883 |
| H-05 | Appeal stake permanently locked | High | **FIXED** -- Forfeited to ODDAO treasury at line 1164 |
| M-01 | Zero-address in initialize | Medium | **FIXED** -- All five params validated at lines 621-625 |
| M-02 | No `__gap` storage | Medium | **FIXED** -- `uint256[44] private __gap` at line 412 |
| M-03 | Unbounded arbitrator pool | Medium | **FIXED** -- Swap-and-pop via `_removeFromArbitratorPool()` |
| M-04 | updateContracts no validation | Medium | **FIXED** -- Code-existence + event at lines 1409-1429 |
| M-05 | Escrow ID 0 sentinel collision | Medium | **FIXED** -- `d.createdAt == 0` sentinel |
| M-06 | oddaoTreasury not updatable | Medium | **FIXED** -- `setOddaoTreasury()` at line 1463 |
| M-07 | Evidence auth during appeal | Medium | **FIXED** -- Appeal arbitrators checked at lines 901-912 |
| M-08 | setMinArbitratorStake no bounds | Medium | **FIXED** -- Bounded 100-10M XOM at lines 1440-1448 |
| L-01 | submitEvidence missing nonReentrant | Low | **ACKNOWLEDGED** -- no external calls in function |
| L-02 | triggerDefaultResolution no pause check | Low | **ACKNOWLEDGED** -- intentional (allows resolution during emergencies) |
| L-03 | DISPUTE_ADMIN_ROLE unused | Low | **ACKNOWLEDGED** -- still granted but no functions use it |
| L-04 | Precision loss enabling zero-fee appeals | Low | **OPEN** -- see M-01 below (expanded analysis) |
| I-01 | Solhint gas warnings | Info | **ACKNOWLEDGED** |
| I-02 | abi.encodePacked collision risk | Info | **ACKNOWLEDGED** -- still present at line 1804 |
| I-03 | appealStakeMultiplier not configurable | Info | **ACKNOWLEDGED** -- still hardcoded |

---

## New Findings (Round 6)

### [H-01] MinimalEscrow Lacks `resolveDispute()` Function -- Cross-Contract Integration Failure

**Severity:** High
**Category:** Cross-Contract Integration / Broken Interface
**Location:** `_triggerEscrowResolution()` (lines 1662-1677), `IArbitrationEscrow` interface (lines 70-77), MinimalEscrow.sol (entire contract)
**Impact:** Dispute resolution will silently fail to move escrowed funds

**Description:**
OmniArbitration defines `IArbitrationEscrow` with a `resolveDispute(uint256, bool)` function (line 70-77) and calls it in `_triggerEscrowResolution()` at line 1667. However, **MinimalEscrow.sol does not implement this function.** MinimalEscrow has:
- `getEscrow(uint256)` returning the full `Escrow` struct -- but NOT individual `getBuyer()`, `getSeller()`, `getAmount()` functions
- Its own independent 2-of-3 dispute resolution system (`commitDispute()`, `revealAndStartDispute()`, `voteOnDispute()`)
- No external `resolveDispute()` entry point

This means:
1. `escrow.resolveDispute()` will revert at runtime because the function does not exist on MinimalEscrow
2. The `try/catch` in `_triggerEscrowResolution()` (line 1667-1676) will catch the revert and emit `ResolutionCallFailed` -- but the funds will NOT be moved
3. `escrow.getBuyer()`, `escrow.getSeller()`, `escrow.getAmount()` in `createDispute()` (lines 752-754) will also revert because MinimalEscrow has `getEscrow()` (returning a struct) instead of individual getter functions

**Furthermore, MinimalEscrow has its own complete arbitration system:**
- `commitDispute()` + `revealAndStartDispute()` -- commit-reveal dispute creation
- `voteOnDispute()` -- 2-of-3 voting by buyer, seller, and random arbitrator
- `_resolveEscrow()` -- handles fund release, marketplace fees, and arbitration fees
- 5% arbitration fee collected from dispute stakes

This creates two completely independent dispute resolution systems for the same escrows, with no coordination between them.

**Exploit Scenario:**
1. Buyer creates dispute via OmniArbitration, pays 5% fee
2. `createDispute()` reverts at `escrow.getBuyer(escrowId)` because the function does not exist
3. If the interface were somehow satisfied (e.g., an adapter contract), arbitration could proceed but `_triggerEscrowResolution()` would silently fail
4. Meanwhile, seller uses MinimalEscrow's own dispute system to get a favorable outcome
5. Double fee collection: both systems charge 5% independently

**Recommendation:**
Three options (in order of preference):
1. **Add `resolveDispute()`, `getBuyer()`, `getSeller()`, `getAmount()` to MinimalEscrow** and grant OmniArbitration a special role to call them. Remove or disable MinimalEscrow's independent arbitration (or make it defer to OmniArbitration).
2. **Create an adapter contract** that wraps MinimalEscrow's `getEscrow()` struct into the individual getter interface and adds a `resolveDispute()` that calls the appropriate MinimalEscrow functions.
3. **Deploy OmniArbitration with a dedicated escrow contract** that implements `IArbitrationEscrow`, separate from MinimalEscrow. Route marketplace transactions through this new escrow.

This is the single most important finding in this audit. **The contract will not function at all in its current form when connected to MinimalEscrow.**

---

### [M-01] Zero-Amount Disputes and Zero-Fee Appeals Possible for Dust Escrows

**Severity:** Medium
**Category:** Business Logic / Precision Loss
**Location:** `createDispute()` (lines 762-763), `fileAppeal()` (lines 1032-1035)
**Related:** Round 4 L-04 (upgraded to Medium after analysis)

**Description:**
For very small escrow amounts, the 5% fee calculation can round to zero:
```solidity
uint256 fee = (amount * ARBITRATION_FEE_BPS) / BPS;
// If amount = 1 wei: fee = (1 * 500) / 10000 = 0
// If amount = 19 wei: fee = (19 * 500) / 10000 = 0
```

With `fee == 0`:
- The dispute creator pays nothing, creating a zero-cost griefing vector
- `safeTransferFrom(caller, address(this), 0)` succeeds (ERC-20 spec allows zero transfers)
- Appeal stake = `(0 * 5000) / 10000 = 0` -- free appeal with no economic commitment
- `_collectAndDistributeFee()` returns early at line 1601 (`if (fee == 0) return`) -- arbitrators get nothing

For amounts up to 19 wei, disputes are completely free. While this seems like a trivially small amount, on a zero-gas-fee chain like OmniCoin, an attacker can create millions of zero-cost disputes to:
- Exhaust arbitrators' `activeDisputeCount`, preventing them from withdrawing stakes
- Fill up the `MAX_EVIDENCE = 50` slots with junk evidence
- Waste arbitrator time and attention

**Recommendation:**
Add a minimum disputed amount check:
```solidity
uint256 fee = (amount * ARBITRATION_FEE_BPS) / BPS;
if (fee == 0) revert DisputedAmountTooSmall();
```
Or set a minimum escrow amount that ensures a meaningful fee.

---

### [M-02] `triggerDefaultResolution()` Allows Resolution of `PendingSelection` Disputes

**Severity:** Medium
**Category:** Business Logic / State Machine Violation
**Location:** `triggerDefaultResolution()` (lines 1205-1244)

**Description:**
The function rejects disputes with status `Resolved` or `DefaultResolved` (lines 1211-1216) but allows `PendingSelection` status through. A dispute in `PendingSelection` has:
- `d.deadline == 0` (deadline is only set in `finalizeArbitratorSelection()`)
- `d.arbitrators` are all `address(0)` (not yet selected)

Because `d.deadline == 0`, the check `block.timestamp < d.deadline` (line 1218) will never revert (any positive timestamp is >= 0). This means anyone can immediately trigger default resolution on a dispute before arbitrators are even selected.

**Exploit Scenario:**
1. Buyer calls `createDispute(escrowId)` -- dispute is in `PendingSelection` with `deadline = 0`
2. Attacker (or even the buyer in the same transaction via a contract) calls `triggerDefaultResolution(disputeId)`
3. `block.timestamp < 0` is false -- passes
4. Dispute resolves as "Refund" to buyer without any arbitration
5. The 5% fee is distributed to arbitrators at `address(0)` (the three unset arbitrator slots)
6. `_collectAndDistributeFee()` sends XOM to `address(0)` via `safeTransfer` -- which reverts, meaning fees are stuck

**However**, the `activeDisputeCount` decrement loop (lines 1225-1229) correctly checks for `address(0)` arbitrators, avoiding underflow. But the fee distribution at line 1626 sends tokens to `d.arbitrators[i]` which is `address(0)` -- `safeTransfer` to zero address reverts in most ERC-20 implementations.

**Net effect:** The `safeTransfer` to `address(0)` will revert, causing `triggerDefaultResolution()` to fail entirely for `PendingSelection` disputes. This means the dispute gets stuck: it cannot be default-resolved (reverts) and it cannot have arbitrators selected (if someone forgets to call `finalizeArbitratorSelection()` within 256 blocks, the blockhash expires and selection becomes impossible).

**Recommendation:**
Add an explicit status check:
```solidity
if (d.status == DisputeStatus.PendingSelection) {
    revert SelectionNotFinalized(disputeId);
}
```
Or allow `PendingSelection` disputes to be cancelled/refunded after a timeout (e.g., if `finalizeArbitratorSelection()` is not called within 256 blocks).

---

### [M-03] Appeal Arbitrator Selection Uses `blockhash(block.number - 1)` -- Single-Phase (Not Two-Phase)

**Severity:** Medium
**Category:** Weak Randomness / Inconsistent Security Model
**Location:** `_selectAppealArbitrators()` (lines 1798-1806), called from `fileAppeal()` (line 1046)

**Description:**
The initial dispute uses a secure two-phase commit-reveal for arbitrator selection:
1. `createDispute()` stores `d.selectionBlock = block.number`
2. `finalizeArbitratorSelection()` uses `blockhash(d.selectionBlock)` 2+ blocks later

However, the appeal arbitrator selection in `_selectAppealArbitrators()` uses `blockhash(block.number - 1)` (line 1801) directly within `fileAppeal()`. This is a single-phase selection -- the appellant knows `blockhash(block.number - 1)` at the time they submit the transaction and can predict (or at least influence) the appeal panel.

On Avalanche (2-second block time), the appellant can:
1. Simulate `_selectAppealArbitrators()` off-chain for the current block
2. If the panel is unfavorable, wait one block and re-simulate
3. Submit `fileAppeal()` only when a favorable panel would be selected

This is the same vulnerability class that the two-phase fix for H-02 was designed to prevent, but it was not applied to appeals.

**Recommendation:**
Apply the same two-phase commit-reveal to appeal arbitrator selection:
```solidity
function fileAppeal(uint256 disputeId) external {
    // ... existing checks ...
    // Store block for two-phase selection
    d.appealSelectionBlock = block.number;
    d.status = DisputeStatus.AppealPendingSelection;
}

function finalizeAppealSelection(uint256 disputeId) external {
    // Wait 2+ blocks, use blockhash(d.appealSelectionBlock)
    // Select 5 arbitrators
}
```

---

### [L-01] `_collectAndDistributeFee()` Always Pays Initial Panel (3 Arbitrators) Even After Appeal

**Severity:** Low
**Category:** Business Logic / Fairness
**Location:** `_collectAndDistributeFee()` (lines 1614-1631)

**Description:**
When a dispute is resolved after appeal, `_collectAndDistributeFee()` distributes the 70% arbitrator share equally among the initial 3-member panel (`d.arbitrators[i]`), not the 5-member appeal panel. The appeal arbitrators who did the actual work of reviewing the case and voting receive nothing from the fee.

This creates a perverse incentive: initial panel arbitrators get paid regardless of whether their decision was correct or overturned. Appeal arbitrators do more work (5 members reviewing a contested case) for zero compensation.

**Recommendation:**
When resolving after appeal, distribute the arbitrator fee share to the appeal panel instead:
```solidity
if (d.status == DisputeStatus.Appealed || d.appealed) {
    // Distribute to appeal panel (5 arbitrators)
    Appeal storage a = appeals[disputeId];
    uint256 perArb = arbShare / 5;
    // ...
} else {
    // Distribute to initial panel (3 arbitrators)
}
```

---

### [L-02] `blockhash()` Returns Zero After 256 Blocks -- Stale `PendingSelection` Disputes Become Unresolvable

**Severity:** Low
**Category:** Temporal / EVM Limitation
**Location:** `_selectArbitrators()` (line 1741), `finalizeArbitratorSelection()` (lines 809-850)

**Description:**
The EVM `blockhash()` function returns `bytes32(0)` for blocks older than 256 blocks from the current block. If `finalizeArbitratorSelection()` is not called within 256 blocks of `createDispute()`, then `blockhash(d.selectionBlock)` returns `bytes32(0)`.

On Avalanche with 2-second blocks, this window is approximately 512 seconds (~8.5 minutes). After this window:
- `_selectArbitrators()` uses `bytes32(0)` as the hash seed
- All disputes created but not finalized within 8.5 minutes would use the same zero hash
- Selection becomes deterministic and predictable (no randomness)
- A dispute in `PendingSelection` has no way to be finalized with proper randomness
- `triggerDefaultResolution()` cannot resolve it either (see M-02)

The dispute's 5% fee is locked in the contract with no recovery path.

**Recommendation:**
1. Add a check in `finalizeArbitratorSelection()`:
```solidity
bytes32 selHash = blockhash(d.selectionBlock);
if (selHash == bytes32(0)) {
    // Blockhash expired -- allow re-commit
    d.selectionBlock = block.number;
    // Or: refund fee and cancel dispute
}
```
2. Consider adding a `cancelStalePendingDispute()` function that refunds the fee if the blockhash window has expired.

---

### [L-03] `DISPUTE_ADMIN_ROLE` Granted But Never Used in Any Function

**Severity:** Low
**Category:** Dead Code / Access Control
**Location:** Line 296 (role definition), line 633 (role granted)

**Description:**
`DISPUTE_ADMIN_ROLE` is defined as a constant (line 296) and granted to `msg.sender` during `initialize()` (line 633), but no function in the contract uses `onlyRole(DISPUTE_ADMIN_ROLE)`. This creates a privilege that serves no purpose.

**Recommendation:**
Either remove the role definition and grant, or implement functions gated by it (e.g., `forceResolveDispute()` for emergency admin resolution).

---

### [I-01] Fee Distribution Labels Differ from Specification

**Severity:** Informational
**Category:** Documentation / Naming
**Location:** Lines 311-314

**Description:**
The OmniBazaar specification states the arbitration fee split as:
- 70% Arbitrators
- 20% **Validator** (processing the transaction)
- 10% **ODDAO**

The contract implements:
- 70% Arbitrators (`ARBITRATOR_FEE_SHARE = 7000`)
- 20% ODDAO (`ODDAO_FEE_SHARE = 2000`)
- 10% Protocol (`PROTOCOL_FEE_SHARE = 1000`)

The "Validator" (20%) and "ODDAO" (10%) shares are swapped compared to the specification. Additionally, "Protocol treasury" is used instead of "Validator."

This may be intentional (the design may have been updated), but the discrepancy should be documented to avoid confusion.

**Recommendation:**
Either update the constants to match the spec (swap `ODDAO_FEE_SHARE` and `PROTOCOL_FEE_SHARE`), rename them to match, or add a NatSpec comment explaining the deviation.

---

### [I-02] Double Fee Collection Between OmniArbitration and MinimalEscrow

**Severity:** Informational (contingent on H-01 being resolved)
**Category:** Architecture / Economic Design
**Location:** OmniArbitration `createDispute()` (line 764), MinimalEscrow `_resolveEscrow()` (line 744)

**Description:**
Both contracts independently collect a 5% arbitration fee:
- **OmniArbitration:** Collects fee from the dispute creator via `safeTransferFrom` at dispute creation (line 764)
- **MinimalEscrow:** Deducts fee from dispute stakes during escrow resolution (line 744), sent to `FEE_COLLECTOR`

If H-01 is resolved and both systems are connected, a disputed escrow would be charged 5% twice (10% total), or the fee collection needs to be coordinated so only one system charges.

**Recommendation:**
When integrating the two contracts:
- Either remove fee collection from MinimalEscrow for OmniArbitration-managed disputes
- Or remove fee collection from OmniArbitration and let MinimalEscrow handle it
- Ensure one and only one 5% fee is collected per dispute

---

## Security Deep-Dive: Can an Arbitrator Steal Funds?

**Direct theft: NO.** Arbitrators cannot directly access escrowed funds. They can only vote Release or Refund. Even colluding arbitrators can only influence whether funds go to buyer vs. seller.

**Indirect theft via collusion: PARTIALLY MITIGATED.**
- Two-phase selection prevents dispute creators from predicting initial panels
- `activeDisputeCount` prevents stake withdrawal during active disputes
- Appeal mechanism (5-member panel) provides a second chance if initial panel colluded
- **Remaining risk:** Appeal selection is single-phase (M-03), so an appellant colluding with arbitrators could choose when to file appeal based on the predicted panel

**Slashing: NOT IMPLEMENTED.** The NatSpec mentions "slashing for overturned decisions on appeal" (contract header line 221) but no slashing mechanism exists. Original panel arbitrators whose decision is overturned on appeal suffer no economic penalty.

---

## Security Deep-Dive: Can a Dispute Be Opened Fraudulently?

**Fraudulent disputes: PARTIALLY MITIGATED.**
- Only buyer or seller of the escrow can create disputes (line 757)
- One dispute per escrow prevents panel shopping (line 748)
- 5% fee creates economic cost for frivolous disputes
- **Remaining risk:** For dust amounts (<20 wei), disputes are free (M-01)
- **Remaining risk:** `PendingSelection` disputes can be default-resolved immediately (M-02)

---

## Security Deep-Dive: Sybil Resistance in Arbitrator Selection

**Sybil prevention: GOOD.**
- Arbitrators must have participation score >= 50 and KYC Tier 4 (line 661)
- Minimum stake of 10,000 XOM per arbitrator (line 664)
- `canBeValidator()` check at selection time as well (line 1756)
- KYC Tier 4 requires video verification -- difficult to Sybil

**Selection bias: LOW RISK.**
- Deterministic selection using blockhash + escrowId + nonce
- Two-phase commit prevents creator prediction for initial panel
- **Remaining risk:** Appeal selection is single-phase (M-03)
- Small pool sizes could lead to repeated selection of same arbitrators

---

## Security Deep-Dive: Cross-Contract Marketplace-to-Arbitration Flow

**Current state: BROKEN (see H-01).**

The intended flow is:
1. Buyer purchases listing via MinimalEscrow (creates escrow with buyer/seller/amount)
2. If dispute arises, buyer/seller calls `OmniArbitration.createDispute(escrowId)`
3. OmniArbitration reads escrow details via `IArbitrationEscrow` interface
4. Arbitrators review evidence and vote
5. Resolution triggers `escrow.resolveDispute()` to move funds

**What actually happens:**
- Step 2 reverts because `escrow.getBuyer()` does not exist on MinimalEscrow
- MinimalEscrow has `getEscrow()` returning a struct, not individual getters
- MinimalEscrow has NO `resolveDispute()` external function
- MinimalEscrow has its own complete, independent arbitration system

**This is the critical integration gap that must be resolved before mainnet.**

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `updateContracts`, `setMinArbitratorStake`, `setOddaoTreasury`, `setProtocolTreasury`, `scheduleUpgrade`, `cancelUpgrade`, `_authorizeUpgrade`, `pause`, `unpause` | **5/10** (improved from 8/10 with timelock) |
| `DISPUTE_ADMIN_ROLE` | *None (unused)* | **0/10** |
| Arbitrator (stake-based) | `registerArbitrator`, `withdrawArbitratorStake`, `castVote`, `castAppealVote` | **3/10** |
| Buyer/Seller (escrow party) | `createDispute`, `fileAppeal`, `submitEvidence` | **2/10** |
| Any caller | `finalizeArbitratorSelection`, `triggerDefaultResolution`, `triggerDefaultAppealResolution`, view functions | **1/10** |

---

## Centralization Risk Assessment

**Single-key maximum damage: 5/10** (improved from 8/10 in Round 4)

The 48-hour upgrade timelock significantly limits the window for malicious upgrades. An admin can:
- Schedule a malicious upgrade (detectable, 48-hour window for community response)
- Change `participation` to a contract that qualifies anyone (immediate, but requires code-existence check)
- Change `escrow` to a malicious contract (immediate, but only affects new disputes)
- Change treasury addresses (immediate, only affects future fee distributions)
- Pause the contract (immediate, DoS but no fund theft)

**At-risk funds:** All arbitrator stakes + any undistributed dispute fees + appeal stakes held by the contract.

**Recommendation:** Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig or governance timelock before mainnet.

---

## Storage Gap Verification

The `__gap` comment states "50 - 6 new state variables = 44 slots reserved." Let me verify:

Sequential state variables:
1. `participation` -- 1 slot (address, 20 bytes)
2. `escrow` -- 1 slot (address)
3. `xomToken` -- 1 slot (address)
4. `oddaoTreasury` -- 1 slot (address)
5. `protocolTreasury` -- 1 slot (address)
6. `nextDisputeId` -- 1 slot (uint256)
7. `minArbitratorStake` -- 1 slot (uint256)
8. `appealStakeMultiplier` -- 1 slot (uint256)
9. `pendingImplementation` -- 1 slot (address)
10. `upgradeScheduledAt` -- 1 slot (uint256)

Mappings (do not consume sequential slots):
- `disputes`, `appeals`, `votes`, `appealVotes`, `arbitratorStakes`, `isInArbitratorPool`, `evidenceSubmitters`, `escrowToDisputeId`, `activeDisputeCount`, `arbitratorPoolIndex`

Dynamic array:
- `arbitratorPool` -- 1 slot (length pointer)

**Total sequential slots: 11** (10 variables + 1 array)

**The comment says 6 but the actual count is 11.** The gap should be `50 - 11 = 39`, not 44. However, this analysis may differ depending on what "6 new state variables" refers to (variables added since the prior version). If the original contract had 5 sequential variables and 6 were added, the gap would be `50 - 5 - 6 = 39`.

**Current gap: 44 slots. Should be: 39 slots.**

This is not a vulnerability for the initial deployment (the proxy storage layout is set at first initialization). It only matters if a future upgrade adds variables expecting 44 free slots -- five of which are actually occupied. Future upgrade developers must recalculate the gap from actual storage layout, not rely on the comment.

**Recommendation:** Update the comment and `__gap` to the correct value of 39 (or whatever the precise count is after careful slot auditing, accounting for inherited base contract slots in OpenZeppelin).

**Important caveat:** The gap reservation convention (50 - N) is relative to the contract's own variables, not including inherited base contracts. OpenZeppelin's upgradeable contracts already reserve their own gaps. If the intent is to reserve 50 slots for this contract's state, and the contract uses 11 slots (10 scalars + 1 array), then `__gap` should be `uint256[39] private __gap`. This needs careful verification with `forge inspect OmniArbitration storage-layout` before deployment.

---

## Conclusion

OmniArbitration has undergone major remediation since the Round 4 audit. All 3 Critical, all 5 High, and 7 of 8 Medium findings have been properly fixed. The contract now includes two-phase arbitrator selection, fee collection and distribution, escrow integration (via interface), active dispute guards, upgrade timelock, and proper input validation.

**One blocking finding remains:** H-01 (MinimalEscrow integration). The `IArbitrationEscrow` interface does not match MinimalEscrow's actual API, and MinimalEscrow has its own independent arbitration system. This must be resolved before mainnet deployment.

**Mainnet readiness: CONDITIONAL -- requires H-01 resolution.**

**Required before deployment:**
1. **CRITICAL:** Resolve MinimalEscrow / OmniArbitration integration (H-01)
2. Fix `PendingSelection` default resolution bug (M-02)
3. Add minimum disputed amount check (M-01)
4. Apply two-phase selection to appeals (M-03)
5. Verify storage gap arithmetic (44 vs calculated 39)
6. Transfer `DEFAULT_ADMIN_ROLE` to multi-sig

**Recommended (non-blocking):**
1. Distribute appeal fees to appeal panel, not initial panel (L-01)
2. Handle blockhash expiration for stale pending disputes (L-02)
3. Remove or use `DISPUTE_ADMIN_ROLE` (L-03)
4. Align fee split labels with specification (I-01)
5. Coordinate fee collection between contracts (I-02)
6. Implement arbitrator slashing for overturned decisions

---

*Generated by Claude Code Audit Agent -- Pre-Mainnet Round 6*
*Compared against Round 4 audit (2026-02-28): 3C + 5H + 7M remediated, 1H + 3M + 3L + 2I new*
