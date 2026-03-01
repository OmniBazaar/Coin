# Security Audit Report: OmniArbitration

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/arbitration/OmniArbitration.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1091
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (arbitrator stakes, appeal stakes in XOM)

## Executive Summary

OmniArbitration is a dispute resolution system for OmniBazaar marketplace escrows.
It provides 3-arbitrator panels (2-of-3 majority), appeals to 5-member panels
(3-of-5 majority), evidence submission via IPFS CIDs, and timeout default resolution.
The contract demonstrates strong Solidity engineering (UUPS, ReentrancyGuard,
Pausable, SafeERC20, custom errors) but has **critical business logic gaps**: fees
are defined but never collected, dispute resolution is disconnected from actual fund
movement in escrow, arbitrators can withdraw stakes while assigned, and deadlines
are not enforced in voting functions. The randomness model uses blockhash which
is manipulable by block proposers.

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 5 |
| Medium | 8 |
| Low | 4 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 170 |
| Passed | 138 |
| Failed | 11 |
| Partial | 12 |
| **Compliance Score** | **81%** |

Top 5 most important failed checks:
1. SOL-Basics-PU-9: No `__gap` storage variable (upgrade collision risk)
2. SOL-CR-4: Admin can change critical properties immediately (no timelock)
3. SOL-Heuristics-16: Asymmetric register/withdraw (pool never cleaned)
4. SOL-Basics-AC-4: Single-step privilege transfer (no two-step admin)
5. SOL-Timelock-1: No timelocks for admin configuration changes

---

## Critical Findings

### [C-01] Fee Collection and Distribution Not Implemented
**Severity:** Critical
**Category:** Business Logic (Incomplete Implementation)
**VP Reference:** VP-34
**Location:** Contract-wide; `calculateFee()` (line 881)
**Sources:** Agent-A, Agent-B, Agent-D, Solodit
**Real-World Precedent:** CodeHawks 2023-07-Escrow — fee disconnection

**Description:**
The contract defines a 5% arbitration fee with 70/20/10 split (arbitrators/validator/
ODDAO) via constants (`ARBITRATION_FEE_BPS = 500`, `ARBITRATOR_FEE_SHARE = 7000`,
`VALIDATOR_FEE_SHARE = 2000`, `ODDAO_FEE_SHARE = 1000`) and a `calculateFee()`
pure view function. However, **no function in the entire contract actually collects
or distributes these fees**. When disputes resolve via `castVote()` (line 622-638),
`castAppealVote()` (line 750-772), or `triggerDefaultResolution()` (line 784-807),
only status changes and events occur — zero XOM is transferred.

**Exploit Scenario:**
Arbitrators perform dispute resolution work (staking 10,000+ XOM, reviewing
evidence, voting) with zero compensation. The documented economic model is
entirely unimplemented, creating zero financial incentive for honest arbitration.

**Recommendation:**
Implement a `_collectAndDistributeFee()` internal function called during
resolution that transfers the 5% fee from the escrow and distributes per the
70/20/10 split. This requires coordination with MinimalEscrow to enable
arbitration-initiated fund movement.

---

### [C-02] Dispute Resolution Disconnected from Escrow Fund Movement
**Severity:** Critical
**Category:** Business Logic (Incomplete Implementation)
**VP Reference:** VP-34
**Location:** `castVote()` lines 622-638, `triggerDefaultResolution()` lines 784-807
**Sources:** Agent-B, Solodit
**Real-World Precedent:** CodeHawks 2023-07-Escrow — orphaned arbitration

**Description:**
When a dispute resolves (Release to seller or Refund to buyer), the contract
sets `d.status = DisputeStatus.Resolved` and emits events, but **never calls
the escrow contract** to actually release or refund the escrowed funds.
`IArbitrationEscrow` only has `getBuyer()`, `getSeller()`, `getAmount()` — no
`release()` or `refund()` functions. Furthermore, MinimalEscrow has its own
independent dispute system that OmniArbitration does not interact with — the two
systems can produce contradictory outcomes for the same escrow.

**Exploit Scenario:**
1. Buyer disputes escrow #42 via OmniArbitration
2. Arbitrators vote "Refund" — buyer wins
3. Buyer's funds remain locked in MinimalEscrow because OmniArbitration
   cannot trigger refund
4. Meanwhile, seller calls MinimalEscrow's own dispute mechanism and wins there
5. Contradictory resolutions: OmniArbitration says refund, MinimalEscrow says
   release

**Recommendation:**
Either: (a) Add `resolveDispute(uint256 escrowId, bool release)` to
`IArbitrationEscrow` and call it on resolution, or (b) Make MinimalEscrow
delegate all dispute handling to OmniArbitration, or (c) Add mutual locking
so only one system handles each escrow.

---

### [C-03] Duplicate Disputes Per Escrow — Panel Shopping Attack
**Severity:** Critical
**Category:** Business Logic (State Machine Violation)
**VP Reference:** VP-29
**Location:** `createDispute()` lines 483-527
**Sources:** Agent-A, Agent-B, Agent-D, Checklist, Solodit
**Real-World Precedent:** Popsicle Finance (2021-08) — $20M repeated claim logic

**Description:**
There is no mapping to track which escrows already have disputes. A buyer or
seller can call `createDispute(escrowId)` repeatedly, each time generating a
new `disputeId` with a potentially different arbitrator panel (if called in
different blocks, `blockhash` changes the selection). This enables "panel
shopping" — creating multiple disputes until a favorable panel is selected.

**Exploit Scenario:**
1. Buyer calls `createDispute(42)` → dispute #1 with arbitrators [A, B, C]
2. Buyer sees panel is unfavorable, waits one block
3. Buyer calls `createDispute(42)` again → dispute #2 with [D, E, F]
4. Buyer engages only with the favorable panel
5. Unfavorable dispute #1 times out → default refund (buyer wins anyway)

**Recommendation:**
```solidity
mapping(uint256 => uint256) public escrowToDisputeId;
// In createDispute():
if (escrowToDisputeId[escrowId] != 0)
    revert EscrowAlreadyDisputed(escrowId);
escrowToDisputeId[escrowId] = disputeId;
```

---

## High Findings

### [H-01] Arbitrator Can Withdraw Stake While Actively Assigned to Dispute
**Severity:** High
**Category:** Business Logic (State Machine Violation)
**VP Reference:** VP-29
**Location:** `withdrawArbitratorStake()` lines 450-470
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist, Solodit
**Real-World Precedent:** Quantstamp/Sapien-2 — lockup bypass; Kinetiq H-03

**Description:**
The NatSpec says "if not actively assigned" but no actual check exists. An
arbitrator assigned to an active dispute panel can withdraw their entire stake
immediately, then vote dishonestly with zero economic risk. The slashing
mechanism mentioned in the NatSpec (line 131: "Slashing for overturned decisions
on appeal") is also **completely unimplemented**.

**Exploit Scenario:**
1. Arbitrator registers with 10,000 XOM stake
2. Gets assigned to dispute panel
3. Immediately withdraws entire 10,000 XOM
4. Votes corruptly (colluding with one party)
5. Even if appealed and overturned, zero stake to slash

**Recommendation:**
Track active dispute assignments per arbitrator:
```solidity
mapping(address => uint256) public activeDisputeCount;
// In _selectArbitrators: activeDisputeCount[selected[i]]++;
// In resolution: activeDisputeCount[arb]--;
// In withdrawArbitratorStake: require(activeDisputeCount[msg.sender] == 0);
```
Also implement the slashing mechanism promised in the NatSpec.

---

### [H-02] Weak Randomness in Arbitrator Selection (Validator Manipulable)
**Severity:** High
**Category:** Weak Randomness / Oracle Manipulation
**VP Reference:** VP-40, VP-22
**Location:** `_selectArbitrators()` lines 978-986, `_selectAppealArbitrators()` lines 1034-1043
**Sources:** Agent-A, Agent-B, Agent-D, Solodit
**Real-World Precedent:** Multiple gambling/lottery exploits; Cyfrin Glossary canonical example

**Description:**
Arbitrator selection uses `blockhash(block.number - 1)`, `block.number`,
`msg.sender`, and a nonce for entropy. On Avalanche, the block proposer knows
`blockhash(block.number - 1)` before building the current block. A malicious
validator-proposer (or one colluding with a dispute party) can predict the
arbitrator selection and delay transaction inclusion to a favorable block. The
contract acknowledges this risk (line 955: "consider upgrading to Chainlink VRF").

**Exploit Scenario:**
1. Malicious validator sees `createDispute()` in mempool
2. Simulates arbitrator selection for current block vs next block
3. Includes transaction only in the block that yields a favorable panel
4. Combined with C-03 (duplicate disputes), the attacker has unlimited attempts

**Recommendation:**
Use commit-reveal for dispute creation or integrate Chainlink VRF. As an
interim measure, use a two-phase approach: `commitDispute()` records intent,
then `revealDispute()` in a future block uses that block's hash for selection.

---

### [H-03] Voting Deadlines Not Enforced — Post-Deadline Voting Race Condition
**Severity:** High
**Category:** Business Logic (Missing Temporal Guard)
**VP Reference:** VP-29
**Location:** `castVote()` lines 584-639, `castAppealVote()` lines 715-773
**Sources:** Agent-A, Agent-B, Checklist, Solodit
**Real-World Precedent:** Code4rena / Party Protocol (2023-10) — voting window bypass

**Description:**
Neither `castVote()` nor `castAppealVote()` check whether their respective
deadlines have passed. The `Dispute.deadline` (7 days) and `Appeal.deadline`
(5 days) fields are stored but never enforced in the voting functions. An
arbitrator can vote indefinitely after the deadline, as long as no one has
triggered default resolution.

Additionally, there is no `triggerDefaultAppealResolution()` function — if
the appeal deadline passes without resolution, the appeal hangs forever.

**Exploit Scenario:**
1. Dispute created with 7-day deadline
2. No arbitrators vote within 7 days
3. Before buyer calls `triggerDefaultResolution()`, an arbitrator front-runs
   with `castVote(disputeId, Release)` plus one more vote → 2-of-3 Release
4. Seller gets the funds instead of the buyer-favorable default

**Recommendation:**
```solidity
// In castVote():
if (block.timestamp > d.deadline) revert DeadlineExpired(d.deadline);
// In castAppealVote():
if (block.timestamp > a.deadline) revert DeadlineExpired(a.deadline);
```
Also add `triggerDefaultAppealResolution()` that upholds the original decision
on appeal timeout.

---

### [H-04] UUPS Upgrade Has No Timelock — Single Key Can Drain All Funds
**Severity:** High
**Category:** Centralization Risk / Upgrade Safety
**VP Reference:** VP-42
**Location:** `_authorizeUpgrade()` lines 1088-1090
**Sources:** Agent-C, Checklist

**Description:**
A single `DEFAULT_ADMIN_ROLE` holder can instantly upgrade the contract to a
malicious implementation that drains all arbitrator stakes and appeal stakes.
There is no timelock, governance vote, or multi-sig requirement enforced at
the contract level. No admin configuration change emits events for monitoring.

**Centralization Risk Score: 8/10**

**Recommendation:**
Route `_authorizeUpgrade()` through the governance timelock
(`OmniTimelockController`), or implement a time-delayed upgrade pattern.
At minimum, emit events in `_authorizeUpgrade()` and all admin setters.

---

### [H-05] Appeal Stake Permanently Locked on Failed Appeal
**Severity:** High
**Category:** Business Logic (Funds Locking)
**VP Reference:** VP-29
**Location:** `castAppealVote()` lines 766-769
**Sources:** Agent-A, Agent-B, Agent-D, Solodit
**Real-World Precedent:** Cyfrin/Sudoswap — excess ETH locked in router forever

**Description:**
When an appeal succeeds (overturns original), the appeal stake is returned to
the appellant (line 768). When the appeal fails (upholds original), the appeal
stake simply remains in the contract forever. No function distributes or
recovers these locked funds. Over time, failed appeal stakes accumulate as
dead capital.

**Recommendation:**
```solidity
if (overturned) {
    xomToken.safeTransfer(a.appellant, a.appealStake);
} else {
    // Distribute forfeited stake per 70/20/10 or to counterparty
    xomToken.safeTransfer(oddaoTreasury, a.appealStake);
}
```

---

## Medium Findings

### [M-01] Missing Zero-Address Validation in `initialize()`
**Severity:** Medium
**Category:** Input Validation
**VP Reference:** VP-22, VP-32
**Location:** `initialize()` lines 391-413
**Sources:** Agent-A, Agent-C, Agent-D, Checklist, Solodit

**Description:**
All four address parameters (`_participation`, `_escrow`, `_xomToken`,
`_oddaoTreasury`) are accepted without zero-address checks. Since `initializer`
ensures this function runs only once, deploying with a zero address requires
redeploying the proxy.

**Recommendation:** Add `require(_addr != address(0))` for each parameter.

---

### [M-02] No `__gap` Storage Variable for Upgrade Safety
**Severity:** Medium
**Category:** Upgrade Safety
**VP Reference:** VP-39, VP-43
**Location:** After state variable declarations (line 271)
**Sources:** Agent-C, Agent-D, Checklist, Solodit
**Real-World Precedent:** EFVault (2023-02) — $5.1M storage collision; Audius (2022)

**Description:**
No `uint256[N] private __gap` is declared. Future upgrades adding state variables
risk storage slot collision.

**Recommendation:** Add `uint256[50] private __gap;` after all state variables.

---

### [M-03] Arbitrator Pool Array Grows Unbounded with Ghost Entries
**Severity:** Medium
**Category:** Denial of Service
**VP Reference:** VP-40, VP-41
**Location:** `arbitratorPool` (line 264), `withdrawArbitratorStake()` line 464
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist, Solodit
**Real-World Precedent:** Cyfrin/Paladin Valkyrie v2.0 — unbounded pool growth (Critical)

**Description:**
When arbitrators withdraw below minimum, `isInArbitratorPool` is set to `false`
but the address is never removed from the `arbitratorPool` array. Over time,
ghost entries accumulate. The selection loop (capped at 200 iterations) may
fail to find enough valid arbitrators in a sparse pool, causing
`NotEnoughArbitrators` reverts even when qualified arbitrators exist.
Re-registered arbitrators can appear multiple times, gaining selection bias.

**Recommendation:** Implement swap-and-pop removal, or use OpenZeppelin's
`EnumerableSet` for the arbitrator pool.

---

### [M-04] `updateContracts()` Can Set Malicious Addresses — No Events, No Timelock
**Severity:** Medium
**Category:** Access Control / Centralization
**VP Reference:** VP-06
**Location:** `updateContracts()` lines 908-918, `setMinArbitratorStake()` lines 924-928
**Sources:** Agent-C, Checklist

**Description:**
A compromised `DEFAULT_ADMIN_ROLE` can replace `participation` with a
contract that qualifies anyone as arbitrator, or replace `escrow` with one
that fabricates buyer/seller data. No events are emitted and no timelock
delays the change.

**Recommendation:** Add events, address validation (`address.code.length > 0`),
and ideally a timelock or governance approval.

---

### [M-05] Escrow ID 0 Sentinel Collision
**Severity:** Medium
**Category:** Input Validation
**VP Reference:** VP-32
**Location:** Lines 545, 591, 655, 722, 788
**Sources:** Agent-A, Agent-B, Checklist

**Description:**
Dispute existence is checked via `d.escrowId == 0`. If MinimalEscrow uses
0-indexed IDs (it does — `escrowCounter` starts at 0), a dispute for
escrow #0 would appear "not found" to all subsequent operations.

**Recommendation:** Use `d.createdAt == 0` as sentinel, or add a `bool exists`
field to the `Dispute` struct.

---

### [M-06] `oddaoTreasury` Not Updatable After Initialization
**Severity:** Medium
**Category:** Emergency / Configuration
**VP Reference:** N/A
**Location:** `oddaoTreasury` (line 237), `initialize()` (line 408)
**Sources:** Agent-C

**Description:**
The `oddaoTreasury` address is set once in `initialize()` with no admin setter.
If the ODDAO treasury needs to change (key compromise, migration), a full
contract upgrade is required. `xomToken` is also not updatable. This is
inconsistent with `updateContracts()` which allows updating `participation`
and `escrow`.

**Recommendation:** Add `setOddaoTreasury(address)` gated by admin role with
zero-address check.

---

### [M-07] Evidence Authorization Wrong During Appeal Phase
**Severity:** Medium
**Category:** Business Logic
**VP Reference:** VP-29
**Location:** `submitEvidence()` lines 554-565
**Sources:** Agent-B

**Description:**
When a dispute is in `Appealed` status, `submitEvidence()` only checks the
original 3 arbitrators for authorization, not the 5 appeal arbitrators. Appeal
panel members cannot submit evidence. Meanwhile, original panel members (whose
decision is being reviewed) can still submit during appeal.

**Recommendation:** Check appeal arbitrators when `d.status == Appealed`.

---

### [M-08] `setMinArbitratorStake()` Has No Bounds
**Severity:** Medium
**Category:** Input Validation
**VP Reference:** VP-23
**Location:** `setMinArbitratorStake()` lines 924-928
**Sources:** Agent-C, Checklist

**Description:**
Can be set to 0 (allowing zero-stake arbitrators) or `type(uint256).max`
(preventing all new registrations). No event emitted.

**Recommendation:** Add bounds (e.g., `100 ether <= _minStake <= 10_000_000 ether`)
and emit an event.

---

## Low Findings

### [L-01] `submitEvidence()` Missing `nonReentrant` Modifier
**Severity:** Low
**VP Reference:** VP-02
**Location:** `submitEvidence()` line 540
**Sources:** Agent-A, Agent-D

No external calls are made, so no current exploit path. Defense-in-depth gap.

---

### [L-02] `triggerDefaultResolution()` Missing `whenNotPaused` — Callable by Anyone
**Severity:** Low
**VP Reference:** VP-06
**Location:** `triggerDefaultResolution()` line 784
**Sources:** Agent-A, Agent-C

No access control and no pause check. NatSpec says "Either party can trigger"
but code allows anyone. The missing `whenNotPaused` means default resolutions
proceed even during emergency pause.

---

### [L-03] `DISPUTE_ADMIN_ROLE` Defined But Never Used
**Severity:** Low
**VP Reference:** N/A
**Location:** Lines 193-194, 403
**Sources:** Agent-C

Dead code that could confuse future developers. Remove or implement gated functions.

---

### [L-04] Precision Loss Enabling Zero-Fee Appeals
**Severity:** Low
**VP Reference:** VP-13
**Location:** `fileAppeal()` lines 667-668
**Sources:** Agent-D

For very small disputed amounts, `(amount * 500) / 10000` could equal 0,
and `(0 * 5000) / 10000` = 0, allowing free appeals with no stake.

**Recommendation:** Add `require(fee > 0, "amount too small")`.

---

## Informational Findings

### [I-01] Solhint Warnings — Gas Optimizations and Ordering
**Severity:** Informational

26 Solhint warnings: struct packing (Dispute, Appeal), non-indexed event
parameters (`stake`, `amount`), post-increment instead of pre-increment
(lines 742, 744, 1006, 1010, 1073, 1077), function ordering, and cyclomatic
complexity (5 functions exceed threshold of 7).

### [I-02] `abi.encodePacked` with String Literal in Appeal Selection
**Severity:** Informational
**VP Reference:** VP-38
**Location:** `_selectAppealArbitrators()` line 1040

The `"appeal"` string literal mixed with fixed-size types in `abi.encodePacked`
is technically a collision risk, though practically infeasible.

### [I-03] `appealStakeMultiplier` Not Admin-Configurable
**Severity:** Informational
**Location:** Line 261

Set to 5000 (50%) during init with no setter. Requires full upgrade to change.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Popsicle Finance | 2021-08 | $20M | Repeated claim logic flaw — same as C-03 panel shopping |
| EFVault | 2023-02 | $5.1M | Storage collision in proxy upgrade — same class as M-02 |
| Quantstamp/Sapien-2 | 2024 | N/A | Lockup bypass — same as H-01 stake withdrawal |
| KyberSwap | 2023-11 | $48M | Precision loss in tick math — relates to L-04 |
| Rari Capital | 2021-05 | $11M | Cross-function reentrancy — relates to L-01 |

## Solodit Similar Findings

- **CodeHawks StakeLink #439** — No storage gap (same as M-02)
- **CodeHawks Zaros Part 2 #450** — Missing `__gap` (same as M-02)
- **CodeHawks Hawk High #377** — Missing storage gap (same as M-02)
- **CodeHawks SparkN #268** — Missing zero-address check (same as M-01)
- **Cyfrin/Paladin Valkyrie v2.0** — Unbounded pool growth (same as M-03)
- **Code4rena Insure #19** — Unbounded loop DoS (relates to M-03)
- **Pashov/Saffron L-04** — Missing vault expiration (relates to H-03)
- **Cyfrin/Sudoswap** — Excess ETH locked forever (same as H-05)

## Static Analysis Summary

### Slither
Slither analysis timed out (>5 minutes) on the full Hardhat project. Not included.

### Aderyn
Aderyn v0.6.8 crashed with an internal error on import resolution. Not included.

### Solhint
26 warnings, 0 errors. Key issues:
- 2 struct packing warnings (Dispute, Appeal)
- 2 non-indexed event parameter warnings
- 5 cyclomatic complexity warnings (functions exceed threshold of 7)
- 4 pre-increment optimization warnings
- 8 non-strict inequality warnings (gas optimization)
- 2 function ordering warnings
- 3 other gas optimization warnings

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `updateContracts`, `setMinArbitratorStake`, `pause`, `unpause`, `_authorizeUpgrade` | **8/10** |
| `DISPUTE_ADMIN_ROLE` | *None (unused)* | **0/10** |
| *No role (public)* | `registerArbitrator`, `withdrawArbitratorStake`, `createDispute`, `submitEvidence`, `castVote`, `fileAppeal`, `castAppealVote`, `triggerDefaultResolution` | N/A |

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised `DEFAULT_ADMIN_ROLE` can upgrade
the contract to drain all XOM held (arbitrator stakes + appeal stakes). Can also
redirect `participation` and `escrow` to malicious contracts, manipulating all
future dispute outcomes.

**Risk Score: 8/10**

**Recommendation:** Transfer `DEFAULT_ADMIN_ROLE` to a multisig or governance
timelock before mainnet. Add timelock to `_authorizeUpgrade()`. Emit events
on all admin operations.

---
*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Static tools: Solhint (completed), Slither (timed out), Aderyn (crashed)*
