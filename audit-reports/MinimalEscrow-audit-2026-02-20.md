# Security Audit Report: MinimalEscrow

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/MinimalEscrow.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 869
**Upgradeable:** No
**Handles Funds:** Yes (XOM and pXOM tokens in escrow)

## Executive Summary

MinimalEscrow implements a 2-of-3 multisig escrow with commit-reveal dispute resolution and COTI V2 MPC privacy support. The audit identified **0 Critical, 6 High, 8 Medium, 7 Low, and 5 Informational** findings. The most significant issues are: (1) marketplace fees charged on buyer refunds during disputed escrows, penalizing the winning buyer; (2) fee handling asymmetry between public and private escrow resolution paths; (3) voting permitted on non-disputed escrows, creating a fee-paying backdoor; (4) specification violations in fee distribution (single collector vs 70/20/10) and missing arbitration fees. The contract follows CEI pattern and uses SafeERC20 throughout, but lacks pause functionality and uses push-based transfers vulnerable to recipient-side DoS.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 6 |
| Medium | 8 |
| Low | 7 |
| Informational | 5 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 85 |
| Passed | 70 |
| Failed | 8 |
| Partial | 7 |
| **Compliance Score** | **82%** |

**Top 5 Failed Checks:**
1. SOL-Basics-Math-5: Fee charged on buyer refunds (rounding direction penalizes buyer)
2. SOL-Heuristics-16: Fee asymmetry between public and private escrow resolution
3. SOL-AM-DOSA-2: No minimum escrow amount (dust escrows enable free dispute spam)
4. SOL-AM-MA-2: Block properties used for arbitrator randomness
5. SOL-Basics-AC-4: Immutable ADMIN with no key rotation capability

## Static Analysis Summary

### Slither
Skipped -- full-project Slither analysis exceeds 10-minute timeout on this codebase.

### Aderyn
Skipped -- Aderyn v0.6.8 crashes with "Fatal compiler bug" against solc v0.8.33.

### Solhint
- **Errors:** 0
- **Warnings:** 2
  - `not-rely-on-time`: 8 instances (all legitimate business use of block.timestamp for escrow expiry and dispute timing)
  - `ordering`: Modifier `onlyAdmin` placed before constructor (cosmetic)

---

## High Findings

### [H-01] Marketplace Fee Charged on Buyer Refunds in Disputed Escrows
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_resolveEscrow()` (line 568)
**Sources:** Agent-A, Agent-B, Checklist (SOL-Basics-Math-5, SOL-Heuristics-16), Solodit (Cyfrin escrow contest)

**Description:**
The `_resolveEscrow()` function deducts a marketplace fee from ALL resolutions, including buyer refunds. When a dispute is resolved in the buyer's favor (2 refund votes), the buyer loses 1% of their escrowed funds to the FEE_COLLECTOR, even though the buyer did nothing wrong.

```solidity
// Line 568-569: Fee charged regardless of recipient
uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
uint256 recipientAmount = amount - feeAmount;
```

**Exploit Scenario:**
1. Buyer escrows 10,000 XOM for a purchase
2. Seller fails to deliver; buyer initiates dispute
3. Dispute resolves in buyer's favor (2 refund votes)
4. Buyer receives only 9,900 XOM (100 XOM marketplace fee deducted)
5. Buyer loses 100 XOM despite winning the dispute

**Real-World Precedent:** Cyfrin/2023-07-escrow -- Multiple findings around fee handling inconsistencies in dispute resolution.

**Recommendation:**
Only charge marketplace fee when funds are released to seller (successful sale). Skip fee on buyer refunds:
```solidity
function _resolveEscrow(Escrow storage escrow, uint256 escrowId, address recipient) private {
    escrow.resolved = true;
    uint256 amount = escrow.amount;
    escrow.amount = 0;

    uint256 recipientAmount = amount;
    // Only charge fee when releasing to seller (successful transaction)
    if (recipient == escrow.seller) {
        uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
        recipientAmount = amount - feeAmount;
        if (feeAmount > 0) {
            OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
            totalMarketplaceFees[address(OMNI_COIN)] += feeAmount;
            emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
        }
    }
    OMNI_COIN.safeTransfer(recipient, recipientAmount);
    // ...
}
```

---

### [H-02] Fee Asymmetry Between Public and Private Escrow Resolution
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_resolvePrivateEscrow()` (line 828) vs `_resolveEscrow()` (line 568)
**Sources:** Agent-B, Agent-D (BL-03), Checklist (SOL-Heuristics-16)

**Description:**
Public and private escrow resolution have inconsistent fee handling:

| Scenario | Public Escrow | Private Escrow |
|----------|--------------|----------------|
| Happy-path release to seller | Fee charged (line 356) | Fee charged (line 733) |
| Seller-agreed refund to buyer | No fee (line 397) | No fee (line 775) |
| Disputed release to seller | Fee charged (line 568) | **No fee** (line 828) |
| Disputed refund to buyer | Fee charged (line 568) | **No fee** (line 828) |

Private disputed resolutions skip fees entirely, while public disputed resolutions always charge fees (even on buyer refunds per H-01). This creates an economic incentive to use private escrows for dispute-prone transactions to avoid fees.

**Exploit Scenario:**
Users systematically choose private escrows over public escrows to avoid marketplace fees on disputed transactions. The protocol loses all fee revenue from disputed trades.

**Recommendation:**
Add fee collection to `_resolvePrivateEscrow()` for seller-directed resolutions (matching the fix from H-01 -- fee only when releasing to seller):
```solidity
function _resolvePrivateEscrow(Escrow storage escrow, uint256 escrowId, address recipient) private {
    escrow.resolved = true;
    uint256 amount = escrow.amount;
    escrow.amount = 0;

    uint256 recipientAmount = amount;
    if (recipient == escrow.seller) {
        uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
        recipientAmount = amount - feeAmount;
        if (feeAmount > 0) {
            PRIVATE_OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
            totalMarketplaceFees[address(PRIVATE_OMNI_COIN)] += feeAmount;
            emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
        }
    }
    PRIVATE_OMNI_COIN.safeTransfer(recipient, recipientAmount);
    // ...
}
```

---

### [H-03] vote() Allows Voting on Non-Disputed Escrows
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `vote()` (line 470), `_validateVote()` (line 606-614)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (partial), Solodit (Cyfrin escrow state machine)

**Description:**
The `_validateVote()` function does not verify that `escrow.disputed == true` before allowing votes. For non-disputed escrows, only buyer and seller pass the participant check (the arbitrator check requires `escrow.disputed`), so 2-of-2 agreement between buyer and seller triggers `_resolveEscrow()`.

This creates a backdoor: instead of using `releaseFunds()` (buyer-only, fee on release) or `refundBuyer()` (seller-only or expiry, no fee on refund), parties can use `vote()` on a non-disputed escrow. When both vote for refund, `_resolveEscrow()` is called, which charges the marketplace fee on the refund (per H-01) -- the buyer pays a fee on their own refund that they wouldn't pay via `refundBuyer()`.

**Exploit Scenario:**
1. Buyer and seller agree to cancel a transaction
2. Seller could call `refundBuyer()` (no fee) -- but instead both parties call `vote(escrowId, false)`
3. With 2 refund votes, `_resolveEscrow()` charges a 1% fee on the buyer's refund
4. Or: A malicious seller calls `vote(escrowId, true)` before the buyer uses `releaseFunds()`, consuming one of the two required release votes and potentially triggering resolution on the buyer's subsequent vote via a different code path

**Recommendation:**
Add a disputed check to `_validateVote()`:
```solidity
function _validateVote(Escrow storage escrow, uint256 escrowId) private view {
    if (escrow.resolved) revert AlreadyResolved();
    if (!escrow.disputed) revert NotParticipant(); // Only allow voting on disputed escrows
    if (hasVoted[escrowId][msg.sender]) revert AlreadyVoted();
    // ...
}
```

---

### [H-04] Missing Granular Fee Distribution (Spec Violation)
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** N/A (Specification deviation)
**Location:** `FEE_COLLECTOR` (line 83), all fee distribution points (lines 360, 572, 737)
**Sources:** Agent-B, Solodit (centralization risk pattern)

**Description:**
Per the OmniBazaar specification, marketplace fees should be split:
- **Transaction Fee (0.50%):** 70% ODDAO, 20% Validator, 10% Staking Pool
- **Referral Fee (0.25%):** 70% Referrer, 20% Referrer's Referrer, 10% ODDAO
- **Listing Fee (0.25%):** 70% Listing Node, 20% Selling Node, 10% ODDAO

The contract sends 100% of fees to a single `FEE_COLLECTOR` address. This means validators, staking pool, referrers, and listing nodes receive nothing from escrow fees. The single-address pattern also creates centralization risk -- if FEE_COLLECTOR is compromised or set to a reverting contract, all escrow resolutions fail.

**Recommendation:**
Either implement on-chain fee splitting with multiple recipient addresses, or document that fee distribution is handled off-chain by the FEE_COLLECTOR contract (e.g., a splitter contract or multisig that redistributes).

---

### [H-05] One-Sided Dispute Stake Creates Moral Hazard
**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `commitDispute()` (line 421-423)
**Sources:** Agent-B, Agent-D, Solodit (UMA dispute bond analogy)

**Description:**
Only the party initiating the dispute pays a 0.1% stake. The counterparty risks nothing by being dishonest, creating a moral hazard:
- If a seller fails to deliver, the buyer must pay 0.1% to dispute
- The dishonest seller risks nothing and might benefit from the buyer not wanting to pay the stake
- For small escrows, the dispute cost may exceed the benefit of disputing

The OmniBazaar specification states "0.1% dispute stake" but doesn't specify single-sided. Industry best practice (UMA Optimistic Oracle, Sherlock) requires both parties to post bonds.

**Exploit Scenario:**
1. Seller lists item for 100,000 XOM, receives payment via escrow
2. Seller never delivers the item
3. Buyer must pay 100 XOM dispute stake to challenge
4. Seller risks nothing -- even if they lose the dispute, their stake is returned since they never posted one
5. This creates asymmetric incentives favoring dishonest sellers

**Recommendation:**
Require the counterparty to also post a dispute stake after a dispute is raised, or forfeit the dispute (resulting in automatic resolution favoring the disputer):
```solidity
// After dispute is revealed, counterparty has 24 hours to post matching stake
// If they don't, dispute is auto-resolved in disputer's favor
```

---

### [H-06] Missing 5% Arbitration Fee Mechanism
**Severity:** High (Spec Violation)
**Category:** SC02 Business Logic
**VP Reference:** N/A (Missing feature)
**Location:** Contract-wide (absent feature)
**Sources:** Agent-B, Solodit (Cyfrin escrow contest arbiter fee issues)

**Description:**
Per the OmniBazaar specification:
> **Arbitration Fee:** 5% of disputed amount, paid by 50% buyer + 50% seller, split 70% Arbitrator / 20% Validator / 10% ODDAO

The contract has no arbitration fee mechanism. Arbitrators receive no compensation for resolving disputes, removing any economic incentive to participate. The Cyfrin escrow contest (2023-07-escrow) documented similar issues where arbiter fee configuration was missing or inconsistent.

**Recommendation:**
Add an arbitration fee deduction in `_resolveEscrow()` when the escrow is disputed:
```solidity
if (escrow.disputed) {
    uint256 arbitrationFee = (amount * ARBITRATION_FEE_BPS) / BASIS_POINTS; // 500 = 5%
    uint256 arbitratorShare = (arbitrationFee * 7000) / BASIS_POINTS; // 70%
    uint256 validatorShare = (arbitrationFee * 2000) / BASIS_POINTS;  // 20%
    uint256 oddaoShare = arbitrationFee - arbitratorShare - validatorShare; // 10%
    // Transfer shares to respective recipients
}
```

---

## Medium Findings

### [M-01] DoS via Reverting Token Transfer Blocks Resolution
**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Revert)
**Location:** `_resolveEscrow()` (line 576), `_returnDisputeStake()` (line 595)
**Sources:** Agent-D, Checklist (partial), Solodit (Cyfrin escrow #869 HIGH, #852 MEDIUM)

**Description:**
The contract uses push-based transfers for all fund movements. If the recipient address is a contract that reverts on `transfer()`, or if the token implements blacklisting (as USDC/USDT do), the entire resolution transaction reverts. This permanently locks funds in the escrow.

**Real-World Precedent:**
- Cyfrin/2023-07-escrow #869 (HIGH): "Receipt can't be confirmed if seller is blacklisted by the asset"
- Cyfrin/2023-07-escrow #852 (MEDIUM): "Malicious seller can grief buyer by using a USDC blacklisted address"
- CodeHawks The Standard Protocol #627: "Blacklisted accounts prevent vault's liquidation"

**Recommendation:**
Implement a pull-based withdrawal pattern:
```solidity
mapping(address => mapping(address => uint256)) public claimable; // token => user => amount

function _resolveEscrow(...) private {
    // Instead of pushing:
    // OMNI_COIN.safeTransfer(recipient, amount);
    // Use pull pattern:
    claimable[address(OMNI_COIN)][recipient] += recipientAmount;
}

function claimFunds(address token) external nonReentrant {
    uint256 amount = claimable[token][msg.sender];
    claimable[token][msg.sender] = 0;
    IERC20(token).safeTransfer(msg.sender, amount);
}
```

---

### [M-02] Weak Randomness for Arbitrator Selection
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-40 (Weak Randomness)
**Location:** Constructor (lines 290-293), `selectArbitrator()` (line 530)
**Sources:** Agent-B, Agent-D, Checklist (FAIL SOL-AM-MA-2), Solodit (Sherlock 2024-06-boost #66)

**Description:**
The `arbitratorSeed` is generated from `block.timestamp` and `block.prevrandao` at deployment time. While `block.prevrandao` is better than deprecated `block.difficulty`, it is partially influenceable by validators on Avalanche. A malicious deployer could redeploy the contract until a favorable seed is obtained, biasing arbitrator selection.

**Real-World Precedent:**
- Sherlock 2024-06-boost-aa-wallet #66: "Using weak source of randomness via block.prevrandao + block.timestamp"
- Cyfrin Puppy Raffle: Canonical weak randomness example in security courses

**Recommendation:**
Use Chainlink VRF for the initial seed, or accept the current implementation with the understanding that post-deployment selection is strengthened by the commit-reveal nonce (which the deployer cannot predict for future disputes).

---

### [M-03] Unbounded Arbitrator Loop in selectArbitrator
**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-29 (Unbounded Loop)
**Location:** `selectArbitrator()` (line 538)
**Sources:** Agent-A, Agent-D, Solodit (Code4rena 2022-01-yield #36, 2022-01-insure #25, 2021-12-vader #36)

**Description:**
The `selectArbitrator()` function iterates over the entire `arbitratorList` array to find a candidate that is not the buyer or seller. The `arbitratorList` can grow without bound via `addArbitrator()`. With a large enough list, the loop could exceed block gas limits.

**Real-World Precedent:**
- Code4rena 2022-01-yield #36: "Unbounded loop on array can lead to DoS"
- Code4rena 2022-01-insure #25: Same pattern
- Code4rena 2021-12-vader #36: "Unbounded loop on array that can only grow"

**Recommendation:**
Add a maximum arbitrator count (e.g., 100) or use an indexed mapping instead of array iteration.

---

### [M-04] Anyone Can Trigger Expired Escrow Refund
**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Missing Access Control)
**Location:** `refundBuyer()` (line 388), `refundPrivateBuyer()` (line 766)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (partial SOL-AM-GA-1), Solodit (partial)

**Description:**
After escrow expiry, anyone can call `refundBuyer()` -- not just the buyer, seller, or arbitrator. While the buyer receives their funds regardless, this enables griefing: a third party can front-run a last-second `releaseFunds()` call by triggering the expired refund first.

**Recommendation:**
Add a participant check for the expiry-based refund path:
```solidity
if (block.timestamp > escrow.expiry && !escrow.disputed) {
    if (msg.sender == escrow.buyer || msg.sender == escrow.seller) {
        canRefund = true;
    }
}
```

---

### [M-05] Missing nonReentrant on commitDispute and revealDispute
**Severity:** Medium
**Category:** SC08 Reentrancy
**VP Reference:** VP-06 (Missing Modifier)
**Location:** `commitDispute()` (line 408), `revealDispute()` (line 438)
**Sources:** Agent-A, Agent-C, Agent-D, Solodit (CodeHawks Inheritable Wallet #107)

**Description:**
`commitDispute()` transfers tokens (dispute stake via `safeTransferFrom`) but lacks the `nonReentrant` modifier. If XOM implements ERC-777 hooks, a callback during the stake transfer could re-enter the contract. `revealDispute()` modifies critical state (setting `escrow.disputed = true` and assigning the arbitrator) but also lacks `nonReentrant`.

**Recommendation:**
Add `nonReentrant` modifier to both functions:
```solidity
function commitDispute(uint256 escrowId, bytes32 commitment) external nonReentrant { ... }
function revealDispute(uint256 escrowId, uint256 nonce) external nonReentrant { ... }
```

---

### [M-06] No Pause Mechanism
**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Missing Safety Feature)
**Location:** Contract-wide
**Sources:** Agent-C, Solodit (CodeHawks TempleGold #191)

**Description:**
The contract has no way to pause operations during an emergency (e.g., discovered vulnerability, compromised arbitrator). All escrow creation, voting, and resolution functions remain callable at all times.

**Real-World Precedent:**
- CodeHawks TempleGold #191: "Lack of Comprehensive Pausability for Critical Functions"

**Recommendation:**
Import OpenZeppelin Pausable and add `whenNotPaused` modifier to state-changing functions. Grant pause authority to ADMIN.

---

### [M-07] No Token Recovery Function
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-57 (Missing recoverERC20)
**Location:** Contract-wide
**Sources:** Agent-C, Agent-D

**Description:**
If tokens are accidentally sent directly to the contract address (not via `createEscrow()`), they are permanently locked. There is no `recoverERC20()` function to rescue them.

**Recommendation:**
Add a token recovery function restricted to ADMIN that can only withdraw tokens not currently held in active escrows. Ensure it cannot withdraw escrowed funds by tracking total escrowed amounts per token.

---

### [M-08] Commitment Overwrite in commitDispute
**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `commitDispute()` (line 425)
**Sources:** Agent-A

**Description:**
A party can call `commitDispute()` multiple times, overwriting the previous commitment without penalty. Each call transfers a new dispute stake, but the mapping `disputeStakes[escrowId][msg.sender]` is overwritten (not accumulated), so earlier stakes are effectively lost to the contract.

```solidity
// Line 423: Overwrites previous stake amount
disputeStakes[escrowId][msg.sender] = requiredStake;
// Line 425: Overwrites previous commitment
disputeCommitments[escrowId] = DisputeCommitment({...});
```

**Recommendation:**
Add a check that no commitment already exists:
```solidity
if (disputeCommitments[escrowId].commitment != bytes32(0)) revert AlreadyDisputed();
```

---

## Low Findings

### [L-01] Dust Escrows Enable Free Dispute Spam
**Location:** `createEscrow()` (line 313), `commitDispute()` (line 421)

Escrows with amount = 1 wei produce a dispute stake of 0 (integer division rounds down: `1 * 10 / 10000 = 0`). This enables free dispute spam that consumes storage and increments `escrowCounter`. Add a minimum escrow amount (e.g., 1000 wei).

---

### [L-02] Immutable ADMIN with No Key Rotation
**Location:** Line 89

If the admin key is lost or compromised, arbitrator management (`addArbitrator`, `removeArbitrator`) is permanently disabled or permanently controlled by the attacker. Consider implementing a two-step admin transfer pattern.

---

### [L-03] No Timelock on Arbitrator Changes
**Location:** `addArbitrator()` (line 626), `removeArbitrator()` (line 639)

Admin can instantly add or remove arbitrators without delay. Removing all arbitrators makes future disputes impossible. Adding a malicious arbitrator gives them immediate eligibility. Consider a timelock for arbitrator registry changes.

---

### [L-04] Zero Commitment Accepted
**Location:** `commitDispute()` (line 408)

`commitDispute(escrowId, bytes32(0))` is accepted. A zero commitment is trivially forgeable by anyone who knows the escrowId. Add `if (commitment == bytes32(0)) revert InvalidCommitment();`

---

### [L-05] releaseFunds / releasePrivateFunds Silent No-Op for Seller
**Location:** `releaseFunds()` (line 350-366), `releasePrivateFunds()` (line 727-743)

When the seller calls `releaseFunds()`, the function passes the participant check but silently returns without any state change (the inner `if` requires `msg.sender == escrow.buyer`). This wastes gas and creates confusion. Add an explicit revert for unauthorized callers within the release path.

---

### [L-06] Dispute Stake Locked Between Commit and Reveal
**Location:** `commitDispute()` (line 422), `revealDispute()` (line 443)

The dispute stake is transferred during commit but the dispute is not formalized until reveal (up to 1 hour later). If the committer never reveals, their stake is permanently locked (no refund mechanism for expired commitments).

---

### [L-07] removeArbitrator Mapping/Array Inconsistency Risk
**Location:** `removeArbitrator()` (lines 639-653)

The mapping `isRegisteredArbitrator[arbitrator] = false` is set on line 641 before the array search on line 645. If the loop doesn't find the address in the array (theoretically impossible but defensive coding should account for it), the mapping is cleared but the address remains in the array, causing permanent state inconsistency.

---

## Informational Findings

### [I-01] Missing DisputeCommitted Event
**Location:** `commitDispute()` (line 408-430)

No event is emitted when a dispute commitment is recorded. Off-chain monitoring cannot detect the commit phase. Add: `emit DisputeCommitted(escrowId, msg.sender, commitment);`

---

### [I-02] uint64 Precision Limit for Private Escrows
**Location:** `createPrivateEscrow()` (line 685)

COTI V2 MPC uses `gtUint64`, limiting encrypted amounts to 2^64 - 1 = 18,446,744,073,709,551,615. With XOM's 18 decimals, this caps private escrows at ~18.4 XOM -- far too low for most marketplace transactions. This is a COTI platform limitation, not a contract bug.

---

### [I-03] Floating Pragma
**Location:** Line 2

`pragma solidity ^0.8.19` allows compilation with any 0.8.x version >= 0.8.19. Lock to a specific version for deployment: `pragma solidity 0.8.19;`

---

### [I-04] Plaintext Amount Stored for Private Escrows
**Location:** `createPrivateEscrow()` (line 701)

Private escrows store `uint256(plainAmount)` in `escrow.amount`, making the "private" amount publicly readable via `getEscrow()` or direct storage reads. The encrypted amount in `encryptedEscrowAmounts` provides no additional privacy since the plaintext is also stored.

---

### [I-05] abi.encodePacked with Fixed-Size Types
**Location:** Lines 290, 447, 530

`abi.encodePacked` is used with fixed-size types (uint256, address). While safe (no hash collision risk with fixed-size types), `abi.encode` is more defensive and prevents future issues if variable-length types are added.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Cyfrin Escrow Contest | 2023-07 | N/A (audit) | 376 submissions; blacklist DoS, arbiter fee issues, state machine violations -- all directly applicable |
| Fomo3D | 2018-08 | ~$3M | Weak randomness via block variables -- same pattern as arbitratorSeed |
| King of Ether | 2016 | ~$1M | DoS via reverting transfer -- same pattern as push-based resolution |
| Popsicle Finance | 2021-08 | $25M | Unrestricted caller triggering state changes -- similar to anyone-triggers-refund |

## Solodit Similar Findings

- **Cyfrin/2023-07-escrow #869 (HIGH):** Seller blacklisted by asset blocks resolution -- identical to M-01
- **Cyfrin/2023-07-escrow #852 (MEDIUM):** Malicious seller uses blacklisted address to grief buyer -- identical to M-01
- **Sherlock 2024-06-boost #66 (MEDIUM):** Weak randomness via prevrandao + timestamp -- identical to M-02
- **Code4rena 2022-01-yield #36:** Unbounded loop DoS -- identical to M-03
- **CodeHawks TempleGold #191:** Missing pausability for critical functions -- identical to M-06
- **CodeHawks Inheritable Wallet #107:** Missing/incorrect nonReentrant -- identical to M-05

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| ADMIN (deployer) | `addArbitrator()`, `removeArbitrator()` | 4/10 |
| Buyer | `createEscrow()`, `releaseFunds()`, `refundBuyer()` (expiry), `commitDispute()`, `vote()` | 3/10 |
| Seller | `releaseFunds()` (no-op), `refundBuyer()`, `commitDispute()`, `vote()` | 3/10 |
| Arbitrator | `vote()` (disputed only) | 2/10 |
| Anyone | `refundBuyer()` (after expiry) | 1/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The ADMIN key (immutable, set to deployer) can add/remove arbitrators without delay. A compromised admin could:
1. Remove all legitimate arbitrators (blocking all future dispute resolution)
2. Add a colluding arbitrator (biasing dispute outcomes)
3. Cannot directly steal escrowed funds

**Centralization Rating:** 4/10 (moderate -- admin cannot drain funds but can disrupt dispute resolution)

**Recommendation:** Implement a timelock for arbitrator changes and consider migrating ADMIN to a multi-sig or governance contract.

## Remediation Priority

| Priority | ID | Finding | Effort |
|----------|----|---------|--------|
| 1 | H-01 | Fee on buyer refunds | Low (add recipient check) |
| 2 | H-02 | Fee asymmetry public/private | Low (add fee to private resolution) |
| 3 | H-03 | vote() on non-disputed escrows | Low (add disputed check) |
| 4 | M-05 | Missing nonReentrant | Low (add modifier) |
| 5 | H-05 | One-sided dispute stake | Medium (design decision) |
| 6 | M-01 | DoS via reverting transfer | Medium (pull pattern refactor) |
| 7 | M-08 | Commitment overwrite | Low (add existence check) |
| 8 | H-04 | Missing granular fee split | High (architecture change) |
| 9 | H-06 | Missing arbitration fee | Medium (add fee mechanism) |
| 10 | M-04 | Anyone triggers expired refund | Low (add participant check) |
| 11 | M-06 | No pause mechanism | Low (import Pausable) |
| 12 | M-02 | Weak randomness | Medium (VRF integration) |
| 13 | M-03 | Unbounded arbitrator loop | Low (add max cap) |
| 14 | M-07 | No token recovery | Low (add rescue function) |

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
