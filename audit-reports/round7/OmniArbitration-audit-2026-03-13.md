# Security Audit Report: OmniArbitration (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Round 7)
**Contract:** `Coin/contracts/arbitration/OmniArbitration.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 2,048
**Upgradeable:** Yes (UUPS with 48-hour timelock)
**Handles Funds:** Yes (arbitrator stakes, dispute fees, appeal stakes in XOM)
**Prior Audits:** Round 4 (2026-02-28), Round 6 (2026-03-10)
**Slither:** Skipped (resource contention)
**Tests:** 80 passing (8s)

---

## Executive Summary

OmniArbitration is a trustless dispute resolution system for OmniBazaar marketplace escrows. It implements 3-arbitrator panels (2-of-3 majority), appeals to 5-member panels (3-of-5 majority), evidence submission via IPFS CIDs, timeout default resolution, and a two-phase commit-reveal arbitrator selection mechanism.

**All Round 6 Critical/High/Medium findings have been remediated:**

- R6-H-01 (MinimalEscrow lacks resolveDispute): **FIXED.** MinimalEscrow now implements `getBuyer()`, `getSeller()`, `getAmount()`, and `resolveDispute()` with `onlyArbitration` access control.
- R6-M-01 (Zero-amount disputes): **FIXED.** `DisputedAmountTooSmall` check at line 772 prevents zero-fee disputes.
- R6-M-02 (PendingSelection default resolution): **FIXED.** Both `PendingSelection` and `AppealPendingSelection` are rejected at lines 1280-1285.
- R6-M-03 (Single-phase appeal selection): **FIXED.** Two-phase commit-reveal via `fileAppeal()` + `finalizeAppealSelection()` with `AppealPendingSelection` status (lines 1053-1138).

Additionally, the fee routing has been refactored to use `UnifiedFeeVault` (30% share) instead of separate ODDAO/Protocol treasury addresses, with two removed storage slots preserved as `__removedOddaoTreasury` and `__removedProtocolTreasury` for layout compatibility.

**New findings in this round:** 1 High, 2 Medium, 4 Low, 3 Informational.

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | High | Escrow funds released at initial resolution become irrecoverable if appeal overturns | **NEW** |
| M-01 | Medium | `triggerDefaultResolution` allows `Appealed` status through -- double-decrement and double escrow call | **NEW** |
| M-02 | Medium | `triggerDefaultAppealResolution` callable on `AppealPendingSelection` appeals (deadline=0, arbs=address(0)) | **NEW** |
| L-01 | Low | `_collectAndDistributeFee` always pays initial 3-member panel even after appeal | **OPEN** (from R6-L-01) |
| L-02 | Low | Stale blockhash (>256 blocks) degrades to zero entropy for arbitrator selection | **OPEN** (from R6-L-02) |
| L-03 | Low | `setFeeVault` missing contract code-existence check (inconsistent with `updateContracts`) | **NEW** |
| L-04 | Low | `msg.sender` used in event instead of `_msgSender()` in `triggerDefaultResolution` | **NEW** |
| I-01 | Informational | `DISPUTE_ADMIN_ROLE` granted but unused | **OPEN** (from R6-L-03) |
| I-02 | Informational | Dead code: `_selectAppealArbitrators()` is never called | **NEW** |
| I-03 | Informational | Storage gap arithmetic is incorrect (claims 43 but should be 28) | **NEW** |

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 4 |
| Informational | 3 |

---

## Round 6 Findings -- Remediation Status

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| H-01 | MinimalEscrow lacks resolveDispute() | High | **FIXED** -- MinimalEscrow now implements `resolveDispute()`, `getBuyer()`, `getSeller()`, `getAmount()` with `onlyArbitration` guard |
| M-01 | Zero-amount disputes | Medium | **FIXED** -- `if (fee == 0) revert DisputedAmountTooSmall()` at line 772 |
| M-02 | PendingSelection default resolution | Medium | **FIXED** -- Status check at lines 1280-1285 rejects `PendingSelection` and `AppealPendingSelection` |
| M-03 | Single-phase appeal arbitrator selection | Medium | **FIXED** -- Two-phase via `fileAppeal()` + `finalizeAppealSelection()` with `_selectAppealArbitratorsFromBlock()` |
| L-01 | Fee always paid to initial panel after appeal | Low | **OPEN** -- See L-01 below |
| L-02 | Blockhash returns zero after 256 blocks | Low | **OPEN** -- See L-02 below |
| L-03 | DISPUTE_ADMIN_ROLE unused | Low | **OPEN** -- See I-01 below |
| I-01 | Fee distribution labels differ from spec | Info | **RESOLVED** -- Refactored to use `UnifiedFeeVault` (70/30 split), vault handles internal 70/20/10 |
| I-02 | Double fee collection between contracts | Info | **RESOLVED** -- MinimalEscrow only collects arbitration fee from dispute stakes when `e.disputed == true`, which is only set by MinimalEscrow's own dispute flow, not by `resolveDispute()` called from OmniArbitration |

---

## New Findings (Round 7)

### [H-01] Escrow Funds Released at Initial Resolution Become Irrecoverable if Appeal Overturns

**Severity:** High
**Category:** Business Logic / Fund Flow / Appeal Architecture
**Location:** `_resolveDispute()` (line 1621), `castAppealVote()` (line 1240), `fileAppeal()` (line 1022)

**Description:**

The dispute resolution flow has a critical fund movement sequencing problem. When an initial 2-of-3 vote reaches majority, `_resolveDispute()` is called which immediately:
1. Distributes the dispute fee to arbitrators and fee vault (line 1618)
2. Calls `_triggerEscrowResolution(d.escrowId, isRelease)` (line 1621) -- **this releases or refunds the escrow funds immediately**

After this, `fileAppeal()` can be called to escalate the dispute. If the 5-member appeal panel overturns the original decision, `castAppealVote()` calls `_triggerEscrowResolution()` again (line 1240) with the opposite direction. However, MinimalEscrow's `resolveDispute()` checks `if (e.resolved) revert AlreadyResolved()`, so the second call fails silently (caught by `try/catch` at line 1700, emitting `ResolutionCallFailed`).

**Impact:**

If the initial panel votes "Release" (funds to seller) and the appeal panel votes "Refund" (funds back to buyer), the escrow has already been released to the seller. The appeal overturns the decision, but the buyer's funds cannot be recovered. The appeal mechanism's core purpose -- correcting wrong initial decisions -- is defeated.

Similarly, if the initial panel votes "Refund" and the appeal overturns to "Release", the seller never receives the funds they are entitled to.

**Exploit Scenario:**
1. Seller and 2 of 3 initial arbitrators collude. Arbitrators vote "Release."
2. `_resolveDispute()` releases escrow funds to seller immediately.
3. Buyer files appeal. Appeal panel correctly votes "Refund."
4. `_triggerEscrowResolution()` with `releaseFunds=false` fails because escrow is already resolved.
5. Seller keeps the funds despite losing the appeal.

**Recommendation:**

The escrow funds should NOT be moved during initial dispute resolution if the dispute is still within the appeal window. Two approaches:

**Option A (Deferred resolution):** Do not call `_triggerEscrowResolution()` in `_resolveDispute()`. Instead, add an appeal window (e.g., 3 days after initial resolution). Only move escrow funds when:
- The appeal window expires with no appeal filed (via a new `finalizeResolution()` function), OR
- The appeal resolves (in `castAppealVote` or `triggerDefaultAppealResolution`)

```solidity
function _resolveDispute(uint256 disputeId, VoteType outcome, bool isRelease) internal {
    Dispute storage d = disputes[disputeId];
    d.status = DisputeStatus.Resolved;
    d.resolutionOutcome = outcome; // Store outcome, don't execute yet
    d.appealWindowEnd = block.timestamp + APPEAL_WINDOW;
    // Decrement active counts, distribute fees...
    // DO NOT call _triggerEscrowResolution here
}

function finalizeResolution(uint256 disputeId) external {
    Dispute storage d = disputes[disputeId];
    require(d.status == DisputeStatus.Resolved);
    require(!d.appealed);
    require(block.timestamp > d.appealWindowEnd);
    _triggerEscrowResolution(d.escrowId, d.resolutionOutcome == VoteType.Release);
}
```

**Option B (Escrow holds until appeal):** Move the `_triggerEscrowResolution()` call from `_resolveDispute()` to a separate function that is only callable after the appeal window closes or the appeal resolves.

---

### [M-01] `triggerDefaultResolution` Allows `Appealed` Status Through

**Severity:** Medium
**Category:** State Machine Violation
**Location:** `triggerDefaultResolution()` (lines 1264-1313)

**Description:**

The function rejects `Resolved`, `DefaultResolved`, `PendingSelection`, and `AppealPendingSelection` statuses, but allows `Appealed` status through. When a dispute is in `Appealed` status:

- `d.deadline` is the original 7-day deadline from the initial arbitrator selection (line 846)
- The appeal has its own 5-day deadline (`a.deadline`) but `triggerDefaultResolution` checks `d.deadline`, not `a.deadline`
- After 7 days from initial selection, `block.timestamp >= d.deadline` passes

If called on an `Appealed` dispute:
1. `d.status` is set to `DefaultResolved` (line 1291)
2. `activeDisputeCount[d.arbitrators[i]]` is decremented for the original 3 arbitrators (line 1296) -- but these were already decremented during `_resolveDispute()` before the appeal was filed. If the arbitrators have no other active disputes, this underflows and **reverts** (Solidity 0.8.24 checked arithmetic).
3. If the arbitrators happen to have other active disputes, the decrement succeeds but corrupts their count -- allowing them to potentially withdraw stake while still assigned to another dispute.

**Impact:**

- In the common case, the function reverts due to underflow, providing accidental protection but wasting gas.
- In the uncommon case (arbitrators assigned to multiple disputes), the `activeDisputeCount` is corrupted, potentially allowing arbitrators to withdraw stake while actively assigned.
- If the decrement succeeds, `_triggerEscrowResolution` is called with `releaseFunds=false` (always refund), potentially conflicting with the appeal outcome.

**Recommendation:**

Add `Appealed` to the rejected statuses:

```solidity
if (
    d.status == DisputeStatus.PendingSelection ||
    d.status == DisputeStatus.AppealPendingSelection ||
    d.status == DisputeStatus.Appealed
) {
    revert SelectionNotFinalized(disputeId);
}
```

Or use a whitelist approach that only allows `Active` status:

```solidity
if (d.status != DisputeStatus.Active) {
    revert DisputeAlreadyResolved(disputeId);
}
```

---

### [M-02] `triggerDefaultAppealResolution` Callable on `AppealPendingSelection` Appeals

**Severity:** Medium
**Category:** State Machine Violation / Arithmetic Underflow
**Location:** `triggerDefaultAppealResolution()` (lines 1322-1368), `fileAppeal()` (lines 1058-1071)

**Description:**

When `fileAppeal()` creates an appeal (before `finalizeAppealSelection()` is called), the Appeal struct has:
- `a.deadline = 0` (line 1066)
- `a.arbitrators = [address(0), address(0), address(0), address(0), address(0)]` (lines 1060-1063)
- `a.disputeId = disputeId` (non-zero, line 1059)
- `a.resolved = false` (line 1069)

The `triggerDefaultAppealResolution()` function checks:
1. `a.disputeId == 0` -- passes (disputeId is non-zero)
2. `a.resolved` -- passes (false)
3. `block.timestamp < a.deadline` -- passes! (`a.deadline == 0`, and `block.timestamp >= 0` is always true in unsigned math, so the `< 0` check is false)

The function then attempts `--activeDisputeCount[a.arbitrators[i]]` for 5 iterations where all `a.arbitrators[i]` are `address(0)`. Since `activeDisputeCount[address(0)]` is 0, the decrement underflows and **reverts** in Solidity 0.8.24.

**Impact:**

The underflow provides accidental protection (the function always reverts for `AppealPendingSelection` appeals). However, this is an unintentional revert path. If the EVM semantics ever changed (e.g., wrapping arithmetic), or if `address(0)` somehow had a non-zero active dispute count, the function would resolve the appeal prematurely.

More importantly: if `finalizeAppealSelection()` is never called (because the blockhash expired after 256 blocks), the appeal is permanently stuck in `AppealPendingSelection` with no recovery path. The appeal stake is locked in the contract forever.

**Recommendation:**

Add a status check against the parent dispute:

```solidity
Dispute storage d = disputes[disputeId];
if (d.status == DisputeStatus.AppealPendingSelection) {
    revert SelectionNotFinalized(disputeId);
}
```

Additionally, add a recovery mechanism for stale `AppealPendingSelection` appeals where the blockhash has expired:

```solidity
function cancelStaleAppeal(uint256 disputeId) external nonReentrant {
    Dispute storage d = disputes[disputeId];
    if (d.status != DisputeStatus.AppealPendingSelection) revert();
    Appeal storage a = appeals[disputeId];
    // If blockhash expired (>256 blocks), allow cancellation
    if (block.number <= a.selectionBlock + 256) revert();
    // Return appeal stake to appellant
    xomToken.safeTransfer(a.appellant, a.appealStake);
    a.resolved = true;
    d.status = DisputeStatus.Resolved; // Revert to pre-appeal state
}
```

---

### [L-01] `_collectAndDistributeFee` Always Pays Initial 3-Member Panel Even After Appeal

**Severity:** Low
**Category:** Business Logic / Fairness / Economic Incentives
**Location:** `_collectAndDistributeFee()` (lines 1640-1684)

**Description:**

When a dispute is resolved after appeal, `_collectAndDistributeFee()` distributes the 70% arbitrator share equally among the initial 3-member panel (`d.arbitrators[i]`), not the 5-member appeal panel. However, due to H-01, the fee is already distributed before the appeal is filed (during `_resolveDispute`), so `d.disputeFee == 0` when called from `castAppealVote` (making this a no-op for appeals).

Nonetheless, the design means:
- Initial panel arbitrators are paid regardless of whether their decision is correct or overturned.
- Appeal arbitrators do more work (5 members reviewing a contested case) for zero compensation from the dispute fee.
- This creates a perverse incentive: there is no economic penalty for wrong initial decisions and no reward for correct appeal decisions.

**Recommendation:**

If H-01 is fixed (deferred escrow resolution), restructure fee distribution so that:
- If no appeal: distribute at initial resolution (current behavior, correct)
- If appeal filed: defer fee distribution to appeal resolution and distribute to the appeal panel instead

---

### [L-02] Stale Blockhash (>256 Blocks) Degrades to Zero Entropy for Arbitrator Selection

**Severity:** Low
**Category:** Temporal / EVM Limitation / Randomness
**Location:** `_selectArbitrators()` (line 1774), `_selectAppealArbitratorsFromBlock()` (line 1911)

**Description:**

The EVM `blockhash()` returns `bytes32(0)` for blocks older than 256 blocks from the current block. On Avalanche with 2-second blocks, this window is approximately 512 seconds (~8.5 minutes).

If `finalizeArbitratorSelection()` or `finalizeAppealSelection()` is not called within 256 blocks of dispute/appeal creation, `blockhash(selectionBlock)` returns `bytes32(0)`. Selection still proceeds but with zero entropy: the hash seed becomes `keccak256(abi.encodePacked(escrowId, bytes32(0), block.number, msg.sender, nonce))`. While `block.number` and `msg.sender` provide some variability, an attacker who knows the pool composition could predict exactly which panel will be selected.

For `PendingSelection` disputes: the dispute gets stuck if nobody calls `finalizeArbitratorSelection` within 8.5 minutes. The 5% fee is locked with no recovery path (the dispute cannot be default-resolved due to the M-02 fix from Round 6, and there is no cancellation mechanism).

For `AppealPendingSelection` appeals: the appeal stake is similarly locked.

**Recommendation:**

Add a blockhash validity check:

```solidity
bytes32 selHash = blockhash(selBlock);
if (selHash == bytes32(0)) revert BlockhashExpired();
```

And add recovery functions for stale pending disputes/appeals that refund the fee/stake:

```solidity
function cancelStalePendingDispute(uint256 disputeId) external nonReentrant {
    Dispute storage d = disputes[disputeId];
    require(d.status == DisputeStatus.PendingSelection);
    require(block.number > d.selectionBlock + 256);
    // Refund dispute fee to creator
    xomToken.safeTransfer(/* original caller */, d.disputeFee);
    d.disputeFee = 0;
    d.status = DisputeStatus.DefaultResolved;
    delete escrowToDisputeId[d.escrowId];
}
```

---

### [L-03] `setFeeVault` Missing Contract Code-Existence Check

**Severity:** Low
**Category:** Input Validation / Consistency
**Location:** `setFeeVault()` (lines 1527-1535)

**Description:**

`updateContracts()` (line 1473) validates that both `_participation` and `_escrow` contain deployed contract code via `_participation.code.length == 0` / `_escrow.code.length == 0` checks. However, `setFeeVault()` only checks for `address(0)` but not for code existence.

An admin could accidentally set `feeVault` to an EOA (externally owned account) or an undeployed address. Since `safeTransfer` to an EOA succeeds (ERC-20 standard), the 30% vault share of dispute fees would be sent to a non-vault address with no internal fee distribution logic.

**Impact:**

Low -- requires admin error, and funds are not permanently lost (they go to the EOA which the admin presumably controls). However, the 70/20/10 sub-distribution within the vault (ODDAO / Staking Pool / Protocol Treasury) would not occur.

**Recommendation:**

Add a code-existence check consistent with `updateContracts`:

```solidity
function setFeeVault(address _feeVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_feeVault == address(0)) revert ZeroAddress();
    if (_feeVault.code.length == 0) revert NotAContract(_feeVault);
    feeVault = _feeVault;
    emit FeeVaultUpdated(_feeVault);
}
```

---

### [L-04] `msg.sender` Used in Event Instead of `_msgSender()` in `triggerDefaultResolution`

**Severity:** Low
**Category:** ERC-2771 Consistency
**Location:** `triggerDefaultResolution()` (line 1306)

**Description:**

Line 1306 emits:
```solidity
emit DisputeDefaultResolved(disputeId, msg.sender);
```

The contract uses ERC-2771 meta-transactions via `ERC2771ContextUpgradeable`, and all other user-facing functions use `_msgSender()` to identify the caller. In `triggerDefaultResolution`, if the call is relayed via a trusted forwarder, `msg.sender` would be the forwarder address rather than the actual user.

While this function is unlikely to be called via meta-transaction (anyone can trigger default resolution), the inconsistency could cause indexing/logging issues in off-chain systems that track who triggered resolutions.

**Recommendation:**

Replace `msg.sender` with `_msgSender()`:

```solidity
emit DisputeDefaultResolved(disputeId, _msgSender());
```

---

### [I-01] `DISPUTE_ADMIN_ROLE` Granted But Unused

**Severity:** Informational
**Category:** Dead Code / Access Control
**Location:** Line 300 (definition), line 641 (grant)

**Description:**

`DISPUTE_ADMIN_ROLE` is defined as a constant and granted to `msg.sender` during `initialize()`, but no function in the contract uses `onlyRole(DISPUTE_ADMIN_ROLE)`. This creates a privilege that serves no purpose.

**Recommendation:**

Either remove the role definition and grant, or implement functions gated by it (e.g., an emergency dispute resolution function, or a function to cancel stale pending disputes).

---

### [I-02] Dead Code: `_selectAppealArbitrators()` Is Never Called

**Severity:** Informational
**Category:** Dead Code
**Location:** `_selectAppealArbitrators()` (lines 1818-1881)

**Description:**

The `_selectAppealArbitrators()` function (the original single-phase appeal selection from before the Round 6 M-03 fix) remains in the contract but is never called. After the two-phase fix, `finalizeAppealSelection()` calls `_selectAppealArbitratorsFromBlock()` instead.

This dead code:
- Increases contract deployment gas cost
- Uses the insecure `blockhash(block.number - 1)` single-phase pattern (line 1834)
- Could confuse future auditors or developers

**Recommendation:**

Remove `_selectAppealArbitrators()` entirely. It has been replaced by `_selectAppealArbitratorsFromBlock()`.

---

### [I-03] Storage Gap Arithmetic Is Incorrect

**Severity:** Informational
**Category:** Upgrade Safety / Documentation
**Location:** Line 421-422

**Description:**

The comment states `50 - 7 new state variables = 43 slots reserved` and declares `uint256[43] private __gap`.

Counting all sequential storage slots in the contract (each variable, mapping, and dynamic array occupies one slot in the sequential layout):

| # | Variable | Type | Slots |
|---|----------|------|-------|
| 1 | `participation` | address | 1 |
| 2 | `escrow` | address | 1 |
| 3 | `xomToken` | IERC20 (address) | 1 |
| 4 | `__removedOddaoTreasury` | uint256 | 1 |
| 5 | `__removedProtocolTreasury` | uint256 | 1 |
| 6 | `nextDisputeId` | uint256 | 1 |
| 7 | `disputes` | mapping | 1 |
| 8 | `appeals` | mapping | 1 |
| 9 | `votes` | mapping | 1 |
| 10 | `appealVotes` | mapping | 1 |
| 11 | `arbitratorStakes` | mapping | 1 |
| 12 | `minArbitratorStake` | uint256 | 1 |
| 13 | `appealStakeMultiplier` | uint256 | 1 |
| 14 | `arbitratorPool` | address[] | 1 |
| 15 | `isInArbitratorPool` | mapping | 1 |
| 16 | `evidenceSubmitters` | mapping | 1 |
| 17 | `escrowToDisputeId` | mapping | 1 |
| 18 | `activeDisputeCount` | mapping | 1 |
| 19 | `pendingImplementation` | address | 1 |
| 20 | `upgradeScheduledAt` | uint256 | 1 |
| 21 | `arbitratorPoolIndex` | mapping | 1 |
| 22 | `feeVault` | address | 1 |
| **Total** | | | **22** |

If the intent is to reserve 50 slots for future expansion, the gap should be `50 - 22 = 28`, not 43.

**Current total: 22 + 43 = 65 slots.** This is overly generous but not harmful for the initial deployment. However, if a future upgrade assumes 43 free slots are available and adds 43 new variables, it would exceed the intended 50-slot budget by 15 slots and potentially collide with the gap of a parent or child contract in the inheritance chain.

**Recommendation:**

Update to `uint256[28] private __gap` with comment `50 - 22 state variables = 28 slots reserved`. Alternatively, run `forge inspect OmniArbitration storageLayout` (if Foundry is available) to confirm the exact slot count including inherited base contracts.

---

## Round 4 Findings -- Cumulative Remediation Status

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| C-01 | Fee collection not implemented | Critical | **FIXED** (Round 6) |
| C-02 | Escrow disconnected from resolution | Critical | **FIXED** (Round 6) |
| C-03 | Duplicate disputes / panel shopping | Critical | **FIXED** (Round 6) |
| H-01 | Arbitrator stake withdrawal while assigned | High | **FIXED** (Round 6) |
| H-02 | Weak randomness (single-phase) | High | **FIXED** (Round 6) |
| H-03 | Voting deadlines not enforced | High | **FIXED** (Round 6) |
| H-04 | No upgrade timelock | High | **FIXED** (Round 6) |
| H-05 | Appeal stake permanently locked | High | **FIXED** (Round 6) |
| M-01 | Zero-address in initialize | Medium | **FIXED** (Round 6) |
| M-02 | No `__gap` storage | Medium | **FIXED** (Round 6) |
| M-03 | Unbounded arbitrator pool | Medium | **FIXED** (Round 6) |
| M-04 | updateContracts no validation | Medium | **FIXED** (Round 6) |
| M-05 | Escrow ID 0 sentinel collision | Medium | **FIXED** (Round 6) |
| M-06 | oddaoTreasury not updatable | Medium | **RESOLVED** -- Refactored to UnifiedFeeVault |
| M-07 | Evidence auth during appeal | Medium | **FIXED** (Round 6) |
| M-08 | setMinArbitratorStake no bounds | Medium | **FIXED** (Round 6) |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `updateContracts`, `setMinArbitratorStake`, `setFeeVault`, `scheduleUpgrade`, `cancelUpgrade`, `_authorizeUpgrade`, `pause`, `unpause` | **5/10** (mitigated by 48h upgrade timelock) |
| `DISPUTE_ADMIN_ROLE` | *None (unused)* | **0/10** |
| Arbitrator (stake-based) | `registerArbitrator`, `withdrawArbitratorStake`, `castVote`, `castAppealVote` | **3/10** |
| Buyer/Seller (escrow party) | `createDispute`, `fileAppeal`, `submitEvidence` | **2/10** |
| Any caller | `finalizeArbitratorSelection`, `finalizeAppealSelection`, `triggerDefaultResolution`, `triggerDefaultAppealResolution`, view functions | **1/10** |

---

## Centralization Risk Assessment

**Single-key maximum damage: 5/10**

The 48-hour upgrade timelock significantly limits malicious upgrade windows. An admin can:
- Schedule a malicious upgrade (detectable, 48-hour window for community response)
- Change `participation` to a contract that qualifies anyone (immediate, requires code check)
- Change `escrow` to a malicious contract (immediate, only affects new disputes)
- Change `feeVault` to any non-zero address (immediate, affects future fee distributions)
- Pause the contract (immediate, DoS but no fund theft)

**At-risk funds:** All arbitrator stakes + any undistributed dispute fees + appeal stakes held by the contract.

**Recommendation:** Transfer `DEFAULT_ADMIN_ROLE` to a multi-sig or governance timelock before mainnet.

---

## Security Deep-Dive: Appeal Fund Flow

**Current flow (broken):**
1. Initial 2-of-3 vote resolves -> `_resolveDispute()` -> fees distributed + escrow funds moved immediately
2. Appeal filed (but escrow already resolved)
3. Appeal 3-of-5 vote resolves -> tries to move escrow funds again -> fails (already resolved)
4. If appeal overturns: buyer/seller who should receive funds cannot get them

**Correct flow (recommended):**
1. Initial 2-of-3 vote resolves -> fees distributed, escrow funds held (not moved yet), appeal window starts
2. If no appeal within window: explicit `finalizeResolution()` call moves escrow funds
3. If appeal filed: escrow funds remain held
4. Appeal 3-of-5 vote resolves -> escrow funds moved based on final (appeal) outcome

---

## Security Deep-Dive: Can an Arbitrator Steal Funds?

**Direct theft: NO.** Arbitrators can only vote Release or Refund. Even colluding arbitrators can only influence whether funds go to buyer vs. seller.

**Indirect theft via collusion: MITIGATED** (improved from Round 6).
- Two-phase selection prevents dispute creators from predicting initial panels
- Two-phase selection now also applies to appeal panels (M-03 fix)
- `activeDisputeCount` prevents stake withdrawal during active disputes
- Appeal mechanism (5-member panel) provides a second chance
- **Remaining risk:** The appeal doesn't actually reverse fund movement (H-01)

**Slashing: NOT IMPLEMENTED.** The contract NatSpec mentions "slashing for overturned decisions on appeal" (line 224) but no slashing mechanism exists. Original panel arbitrators whose decision is overturned suffer no economic penalty.

---

## Solhint Output Summary

```
36 problems (0 errors, 36 warnings)
```

Key warnings:
- 5 functions exceed cyclomatic complexity limit of 7 (max observed: 13)
- 4 struct/function ordering violations
- 1 state variable count warning (23 vs limit of 20)
- 2 struct packing inefficiency warnings (Dispute, Appeal)
- Multiple gas optimization suggestions (indexed events, strict inequalities)
- 1 time-based decision warning (acknowledged, necessary for deadline logic)

No errors. All warnings are either gas optimizations or acknowledged design decisions.

---

## Conclusion

OmniArbitration has continued to improve since Round 6, with all Critical, High, and Medium findings from that round properly remediated. The two-phase appeal selection fix and the PendingSelection guard are well-implemented. The MinimalEscrow integration gap (R6-H-01) has been resolved.

**One new High finding remains:** H-01 (escrow funds released at initial resolution become irrecoverable if appeal overturns). This is a fundamental design issue in the appeal flow -- the initial resolution immediately moves escrow funds, making the appeal mechanism unable to reverse incorrect decisions. This undermines the core value proposition of the appeal system.

**Mainnet readiness: CONDITIONAL -- requires H-01 resolution.**

**Required before deployment (blocking):**
1. **HIGH:** Fix the appeal fund flow so escrow resolution is deferred until after the appeal window closes or appeal resolves (H-01)
2. **MEDIUM:** Add `Appealed` to the rejected statuses in `triggerDefaultResolution` (M-01)
3. **MEDIUM:** Guard `triggerDefaultAppealResolution` against `AppealPendingSelection` status; add recovery mechanism for stale appeals (M-02)

**Recommended before deployment (non-blocking):**
1. Distribute appeal fees to appeal panel, not initial panel (L-01)
2. Add blockhash validity check and stale dispute recovery (L-02)
3. Add code-existence check to `setFeeVault` (L-03)
4. Use `_msgSender()` consistently in events (L-04)
5. Remove `DISPUTE_ADMIN_ROLE` or implement functions using it (I-01)
6. Remove dead `_selectAppealArbitrators` function (I-02)
7. Correct storage gap to `uint256[28]` (I-03)
8. Transfer `DEFAULT_ADMIN_ROLE` to multi-sig
9. Implement arbitrator slashing for overturned appeal decisions

---

*Generated by Claude Code Audit Agent -- Pre-Mainnet Round 7*
*Compared against Round 6 audit (2026-03-10): All H/M remediated, 1H + 2M + 4L + 3I new*
