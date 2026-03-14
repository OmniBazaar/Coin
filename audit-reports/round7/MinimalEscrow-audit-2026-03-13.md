# Security Audit Report: MinimalEscrow (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Pre-Mainnet Final Review)
**Contract:** `Coin/contracts/MinimalEscrow.sol`
**Solidity Version:** 0.8.24 (locked)
**Lines of Code:** 1,593
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- XOM and pXOM tokens held in escrow for marketplace transactions
**Prior Audits:**
- Round 1 (2026-02-20): 0C/6H/8M/7L/5I -- Initial comprehensive audit
- Round 6 (2026-03-10): 0C/2H/4M/5L/4I -- Post-remediation deep dive

---

## Executive Summary

This Round 7 pre-mainnet final audit reviews MinimalEscrow.sol after extensive remediation from Rounds 1 and 6. The contract implements a 2-of-3 multisig escrow with commit-reveal dispute resolution, pull-based withdrawal, OmniArbitration integration, COTI V2 MPC privacy support, and ERC2771 gasless meta-transactions.

The contract has matured significantly across seven audit rounds. The vast majority of prior findings have been properly remediated. This audit focuses on residual edge cases, cross-contract integration with OmniArbitration, accounting invariant verification, and attack surface analysis for the final mainnet deployment.

**Remediation Status from Round 6:**

| Round 6 ID | Severity | Finding | Status |
|------------|----------|---------|--------|
| H-01 | High | Private escrow missing arbitration fee | **FIXED** -- Arbitration fee deduction added to `_resolvePrivateEscrow()` (lines 1411-1432) |
| H-02 | High | Dispute stake lost on failed reveal | **PARTIALLY FIXED** -- `reclaimExpiredStake()` added (lines 678-705) but re-commit overwrite still possible (see H-01 below) |
| M-01 | Medium | Disputed escrow stuck if arbitrator unavailable | **FIXED** -- `claimDisputeTimeout()` added (lines 720-751) with 30-day DISPUTE_TIMEOUT |
| M-02 | Medium | Private escrow push transfers | **FIXED** -- Pull pattern applied to `releasePrivateFunds()` (line 1286), `refundPrivateBuyer()` (line 1329), `_resolvePrivateEscrow()` (line 1403) |
| M-03 | Medium | Arbitration fee vs stake size mismatch | **ACCEPTED** -- By design; dispute stakes are 0.1%, arbitration fee is 5%; clamping handles the shortfall |
| M-04 | Medium | Counterparty stake has no enforcement | **ACCEPTED** -- Off-chain consideration for arbitrators; no on-chain deadline |
| L-01 | Low | Dust escrow zero stake | **NOT FIXED** -- No minimum escrow amount enforced (see L-01 below) |
| L-02 | Low | Immutable ADMIN | **ACCEPTED** -- Immutable by design; mitigated by OmniArbitration integration |
| L-03 | Low | Non-disputed path uses push transfers | **ACCEPTED** -- Self-imposed DoS for direct paths is tolerable |
| L-04 | Low | Private escrow plaintext amount | **FIXED** -- Amount moved to `privateEscrowAmounts` private mapping; `escrow.amount` set to 0 for private escrows (PRIV-H03) |
| L-05 | Low | Error reuse in addArbitrator | **NOT FIXED** -- Still uses `AlreadyDisputed` error (see I-01) |

**New Findings (Round 7):**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 4 |
| Informational | 5 |

---

## Solhint Analysis

```
contracts/MinimalEscrow.sol
   298:5   warning  GC: [totalArbitrationFee] on Event [ArbitrationFeeCollected] could be Indexed    gas-indexed-events
   298:5   warning  GC: [arbitratorShare] on Event [ArbitrationFeeCollected] could be Indexed        gas-indexed-events
   328:5   warning  GC: [amount] on Event [CounterpartyStakePosted] could be Indexed                 gas-indexed-events
   413:5   warning  Missing @notice tag in function '<anonymous>' (constructor)                      use-natspec
   441:13  warning  Avoid making time-based decisions in your business logic                         not-rely-on-time
   692:13  warning  GC: Non strict inequality found                                                  gas-strict-inequalities
   874:5   warning  Function order incorrect, external after external view                           ordering
  1298:5   warning  Function has cyclomatic complexity 8 but allowed no more than 7                  code-complexity

0 errors, 8 warnings
```

All warnings are cosmetic or accepted by design:
- `gas-indexed-events`: Event indexing is a gas/usability tradeoff -- acceptable
- `use-natspec`: Constructor has NatSpec via `@param` tags above `@dev` block -- cosmetic
- `not-rely-on-time`: Legitimate business use (arbitrator seed initialization)
- `gas-strict-inequalities`: `<=` at line 692 is intentional (`reclaimExpiredStake` grace period boundary)
- `ordering`: Acceptable -- code is logically grouped by feature (IArbitrationEscrow section)
- `code-complexity`: `refundPrivateBuyer` complexity 8 vs limit 7 -- acceptable for this pattern

---

## Access Control Map

| Role | Functions | Direct Risk | Notes |
|------|-----------|-------------|-------|
| **ADMIN** (immutable, deployer) | `addArbitrator()`, `removeArbitrator()`, `pause()`, `unpause()`, `recoverERC20()`, `setArbitrationContract()` | Medium | Cannot drain active escrows or claimable balances; can disrupt dispute resolution; can set arbitration contract |
| **Arbitration Contract** (mutable via admin) | `resolveDispute()` | High | If set to malicious address, can resolve any undisputed escrow and drain funds to attacker via pull pattern |
| **Buyer** (`_msgSender()`) | `createEscrow()`, `releaseFunds()`, `refundBuyer()` (after expiry), `commitDispute()`, `revealDispute()`, `postCounterpartyStake()`, `vote()`, `withdrawClaimable()`, `reclaimExpiredStake()`, `claimDisputeTimeout()` | Low | Creates and funds escrow; releases to seller |
| **Seller** (set at creation) | `refundBuyer()` (voluntary), `commitDispute()`, `revealDispute()`, `postCounterpartyStake()`, `vote()`, `withdrawClaimable()`, `reclaimExpiredStake()` | Low | Receives funds on release |
| **Arbitrator** (assigned on dispute) | `vote()` | Low | Can only vote on the specific disputed escrow they are assigned to |
| **Trusted Forwarder** (ERC2771, immutable) | Relay any user-facing call | High | If compromised, can impersonate any user for `_msgSender()`-based functions |
| **Anyone** | `getEscrow()`, `hasUserVoted()`, `privacyAvailable()`, `getBuyer()`, `getSeller()`, `getAmount()`, view functions | None | Read-only access |

---

## Escrow Lifecycle (Complete State Machine)

```
                                    +-----------+
                                    |  Created  |
                                    | (funded)  |
                                    +-----+-----+
                                          |
                   +--------------------+-+-------------------+
                   |                    |                     |
            Buyer calls          Seller calls           Time passes
           releaseFunds()       refundBuyer()           (> expiry)
                   |                    |                     |
            +------v------+     +------v------+     +--------v--------+
            |  Released   |     |  Refunded   |     |  Buyer refunds  |
            |  to Seller  |     |  to Buyer   |     |  (buyer calls   |
            |  (push,fee) |     |  (push,     |     |   refundBuyer)  |
            +-------------+     |   no fee)   |     |  (push, no fee) |
                                +-------------+     +-----------------+

       If disputed (after 24h):
                                    +-----------+
                                    |  Created  |
                                    +-----+-----+
                                          |
                                   commitDispute() [stake paid]
                                          |
                                    +-----v-----+
                                    | Committed |----> reclaimExpiredStake()
                                    +-----+-----+     (if reveal missed + 25h)
                                          |
                                   revealDispute() [arbitrator assigned]
                                          |
                                    +-----v-----+
                                    | Disputed  |<--postCounterpartyStake()
                                    +-----+-----+
                                          |
                          +---------------+---------------+
                          |               |               |
                   2-of-3 vote()   OmniArbitration    claimDisputeTimeout()
                          |        resolveDispute()   (30d after expiry)
                          |               |               |
                +---------+---------+     |         +-----v-----+
                |                   |     |         | Refund to |
          2 release votes    2 refund     |         | Buyer     |
                |            votes  |     |         | (pull,    |
          +-----v----+  +----v-----+     |         | no fee,   |
          | Release  |  | Refund   |     |         | stakes    |
          | to Seller|  | to Buyer |     |         | returned) |
          | (pull,   |  | (pull,   |     |         +-----------+
          | mkt fee, |  | no fee,  |     |
          | arb fee) |  | arb fee) |     |
          +----------+  +----------+     |
                                   +-----v-----+
                                   | Resolved  |
                                   | by Arb    |
                                   | Contract  |
                                   | (pull,    |
                                   | mkt fee   |
                                   | if release|
                                   | arb fee   |
                                   | if disp)  |
                                   +-----------+
```

---

## High Findings

### [H-01] Re-Commit After Failed Reveal Orphans Previous Dispute Stake (Residual from Round 6 H-02)

**Severity:** High
**Category:** Business Logic -- Stuck Funds
**Location:** `commitDispute()` (lines 568-595), `reclaimExpiredStake()` (lines 678-705)
**Round 6 Reference:** H-02 -- Partially fixed

**Description:**

Round 6 H-02 identified that dispute stakes are permanently lost when a commit is never revealed. The `reclaimExpiredStake()` function was added as the fix. However, the re-commit overwrite scenario was NOT blocked: if a user calls `commitDispute()` a second time (after the first reveal deadline passes but before calling `reclaimExpiredStake()`), the old stake is orphaned.

The vulnerability arises because `commitDispute()` does not check whether a previous commitment already exists with an unreclaimed stake. The assignment at line 585 (`disputeStakes[escrowId][caller] = requiredStake`) overwrites the previous stake amount, while `totalEscrowed` at line 586 increments by the new stake amount. The old stake amount is now untracked.

**Attack trace:**

```
1. Buyer creates escrow for 100,000 XOM (escrowId=1)
2. After 24h, buyer calls commitDispute(1, commitment1)
   - Pays 100 XOM stake (0.1% of 100,000)
   - disputeStakes[1][buyer] = 100 XOM
   - totalEscrowed[XOM] += 100 XOM (now: 100,100 XOM)

3. Buyer misses the 1-hour reveal window
   - escrow.disputed remains false
   - 25 hours pass (reveal deadline + grace period)

4. Instead of calling reclaimExpiredStake(), buyer calls
   commitDispute(1, commitment2) again
   - escrow.disputed is still false, so AlreadyDisputed check passes
   - New 100 XOM stake transferred from buyer
   - disputeStakes[1][buyer] = 100 XOM (OVERWRITTEN, not accumulated)
   - totalEscrowed[XOM] += 100 XOM (now: 100,200 XOM)

5. The first 100 XOM stake is orphaned:
   - disputeStakes only records 100 XOM (the second stake)
   - totalEscrowed records 200 XOM of stake
   - reclaimExpiredStake() would only return 100 XOM
   - The other 100 XOM is permanently locked

6. totalEscrowed is now inflated by 100 XOM, reducing
   recoverable tokens via recoverERC20() and creating an
   accounting imbalance that persists forever.
```

**Impact:**
- Users permanently lose their dispute stake when re-committing without first reclaiming
- `totalEscrowed` accounting becomes permanently inflated
- `recoverERC20()` underestimates the recoverable amount
- Repeated re-commits compound the locked amount
- This is a plausible user scenario (e.g., mis-timed the first reveal, immediately retry)

**Recommendation:**

Add a check in `commitDispute()` that refunds any existing unrevealed stake before accepting a new one:

```solidity
function commitDispute(uint256 escrowId, bytes32 commitment)
    external nonReentrant whenNotPaused
{
    // ... existing validation ...

    // Refund any existing unrevealed stake (prevents overwrite orphan)
    uint256 existingStake = disputeStakes[escrowId][caller];
    if (existingStake > 0) {
        disputeStakes[escrowId][caller] = 0;
        totalEscrowed[address(OMNI_COIN)] -= existingStake;
        OMNI_COIN.safeTransfer(caller, existingStake);
        emit DisputeStakeReturned(escrowId, caller, existingStake);
    }

    // Transfer new stake
    uint256 requiredStake =
        (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
    OMNI_COIN.safeTransferFrom(caller, address(this), requiredStake);
    disputeStakes[escrowId][caller] = requiredStake;
    totalEscrowed[address(OMNI_COIN)] += requiredStake;
    // ...
}
```

Alternative: block re-commitment entirely by checking `disputeCommitments[escrowId].revealDeadline != 0`.

---

## Medium Findings

### [M-01] setArbitrationContract() Has No Guard Against Malicious or Zero-Code Addresses

**Severity:** Medium
**Category:** Access Control -- Configuration Risk
**Location:** `setArbitrationContract()` (lines 1145-1154)

**Description:**

The `setArbitrationContract()` function allows ADMIN to set any address as the authorized arbitration contract, including EOAs, self-destructed contracts, or malicious contracts. Unlike `OmniArbitration.updateContracts()` (which validates `code.length > 0` per M-04 of the OmniArbitration audit), `setArbitrationContract()` has no such validation.

A malicious or compromised admin could set `arbitrationContract` to an EOA they control, then call `resolveDispute()` directly to resolve ANY escrow (disputed or not, since `resolveDispute()` does not check `escrow.disputed`). The `resolveDispute()` function uses the pull pattern, so funds would be credited to the buyer or seller's claimable balance, but the admin controls which party receives them.

```solidity
// Line 1145-1154: No validation on the address
function setArbitrationContract(
    address _arbitrationContract
) external onlyAdmin {
    address oldArbitration = arbitrationContract;
    arbitrationContract = _arbitrationContract;
    emit ArbitrationContractUpdated(oldArbitration, _arbitrationContract);
}

// Line 874-971: resolveDispute does NOT check escrow.disputed
function resolveDispute(
    uint256 escrowId,
    bool releaseFunds
) external nonReentrant onlyArbitration {
    Escrow storage e = escrows[escrowId];
    if (e.buyer == address(0)) revert EscrowNotFound();
    if (e.resolved) revert AlreadyResolved();
    // NOTE: No check for e.disputed -- any unresolved escrow can be resolved
    // ...
}
```

**Impact:**
- Compromised admin can resolve any unresolved escrow (not just disputed ones) via the arbitration pathway
- This bypasses the normal 2-of-3 vote or buyer-release flow
- Could be used to force-release funds to seller or force-refund to buyer on any active escrow
- Marketplace fee is still applied on release, so the protocol benefits, but the transaction integrity is violated

**Recommendation:**

1. Add `escrow.disputed` check to `resolveDispute()`:
```solidity
function resolveDispute(uint256 escrowId, bool releaseFunds)
    external nonReentrant onlyArbitration
{
    Escrow storage e = escrows[escrowId];
    if (e.buyer == address(0)) revert EscrowNotFound();
    if (e.resolved) revert AlreadyResolved();
    if (!e.disputed) revert NotDisputed(); // Prevent resolving non-disputed escrows
    // ...
}
```

2. Add code-existence validation to `setArbitrationContract()`:
```solidity
function setArbitrationContract(address _arbitrationContract) external onlyAdmin {
    if (_arbitrationContract != address(0) && _arbitrationContract.code.length == 0) {
        revert InvalidAddress();
    }
    // ...
}
```

---

### [M-02] Private Escrow Dispute Path Uses Public Escrow Amount for Arbitration Fee Calculation

**Severity:** Medium
**Category:** Business Logic -- Incorrect Calculation
**Location:** `_resolvePrivateEscrow()` (line 1412)

**Description:**

In `_resolvePrivateEscrow()`, the arbitration fee is calculated as:
```solidity
uint256 arbitrationFee = (amount * ARBITRATION_FEE_BPS) / BASIS_POINTS; // line 1412
```

Where `amount` comes from `privateEscrowAmounts[escrowId]` (line 1383). However, the dispute stake was calculated from `escrow.amount` (which is 0 for private escrows) in `commitDispute()`:
```solidity
uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS; // line 583
```

Since `escrow.amount` is 0 for private escrows (PRIV-H03 fix sets it to 0 at line 1241), the dispute stake calculation produces 0. The `safeTransferFrom` for 0 tokens succeeds on most ERC20 implementations, so `commitDispute()` completes without actually requiring a stake.

Subsequently, in `_resolvePrivateEscrow()`, the arbitration fee calculation uses the real amount from `privateEscrowAmounts`, but the deduction is clamped to the dispute stakes (which are 0). Therefore:
- No dispute stake is actually collected
- No arbitration fee is actually deducted
- Both `buyerDeduction` and `sellerDeduction` are 0
- `totalCollected` is 0, so the arbitration fee transfer is skipped

**Impact:**
- Private escrow disputes are effectively free (no dispute stake required)
- No arbitration fee is collected on private escrow disputes
- The Round 6 H-01 fix for private escrow arbitration fee is ineffective because it relies on dispute stakes that were never actually collected
- Creates a strong incentive to use private escrows for dispute-prone transactions to avoid all costs

**Recommendation:**

The dispute stake for private escrows should be calculated from `privateEscrowAmounts[escrowId]` rather than `escrow.amount`. Since `commitDispute()` and `postCounterpartyStake()` are shared between public and private paths, the fix requires checking `isPrivateEscrow[escrowId]`:

```solidity
function commitDispute(uint256 escrowId, bytes32 commitment)
    external nonReentrant whenNotPaused
{
    // ... existing validation ...

    // Calculate stake from the correct amount source
    uint256 escrowAmount = isPrivateEscrow[escrowId]
        ? privateEscrowAmounts[escrowId]
        : escrow.amount;
    uint256 requiredStake =
        (escrowAmount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;

    // ... rest of function ...
}
```

Apply the same fix to `postCounterpartyStake()` at line 659.

---

### [M-03] Dual Dispute Resolution Paths Can Cause Double-Resolution for the Same Escrow

**Severity:** Medium
**Category:** Business Logic -- State Machine Integrity
**Location:** `vote()` (lines 759-781), `resolveDispute()` (lines 874-971), `claimDisputeTimeout()` (lines 720-751)

**Description:**

A disputed escrow now has THREE possible resolution paths:
1. **2-of-3 vote** via `vote()` -> `_resolveEscrow()` (lines 776-780)
2. **OmniArbitration** via `resolveDispute()` (line 874)
3. **Dispute timeout** via `claimDisputeTimeout()` (line 720)

All three paths check `if (escrow.resolved) revert AlreadyResolved()`, which prevents double-resolution. This is correct and working.

However, there is a subtle race condition between paths 1 and 2: if the MinimalEscrow 2-of-3 vote and the OmniArbitration panel both attempt to resolve the same disputed escrow, the first transaction to be mined wins, and the second reverts. This is expected behavior.

The actual concern is that `resolveDispute()` (the OmniArbitration path) does NOT check `escrow.disputed`. This means OmniArbitration could call `resolveDispute()` on an escrow that was never disputed (e.g., a normal escrow where the buyer simply has not yet released funds). The `resolveDispute()` function would then:
1. Mark the escrow as resolved
2. Credit funds to buyer or seller via pull pattern
3. Skip the arbitration fee (since `escrow.disputed == false`)
4. Skip stake returns (since no stakes exist)

This bypasses the normal buyer-only release or seller-only refund flow. While this requires the OmniArbitration contract to initiate, it represents a trust boundary violation: the MinimalEscrow contract delegates resolution authority to `arbitrationContract` without verifying that the escrow actually needs external arbitration.

**Impact:**
- The OmniArbitration contract (or any contract at `arbitrationContract` address) can force-resolve any non-disputed escrow
- This is an expanded version of M-01 above, specifically about the state machine gap
- If OmniArbitration has a bug that calls `resolveDispute()` on the wrong escrow ID, funds move incorrectly

**Recommendation:**

Add `if (!e.disputed) revert NotDisputed();` to `resolveDispute()`. This is the same fix as M-01 recommendation #1 above.

---

## Low Findings

### [L-01] Dust Escrows Produce Zero Dispute Stake (Unfixed from Round 6)

**Severity:** Low
**Category:** Economic Exploit -- Free Dispute Spam
**Location:** `commitDispute()` (line 583), `createEscrow()` (line 464)

**Description:**

For escrows with `amount < 1000` (e.g., 999 wei), the dispute stake calculation `(999 * 10) / 10000 = 0` produces zero. The `safeTransferFrom` for 0 tokens succeeds, allowing free dispute spam. The `postCounterpartyStake()` function catches this with `if (requiredStake == 0) revert InsufficientStake()` at line 660, but `commitDispute()` has no such guard.

With the DISPUTE_TIMEOUT feature, a disputer can create dust escrows, commit disputes for free, reveal them (assigning arbitrators to trivial disputes), and then let them timeout after 30 days + expiry.

**Impact:**
- Free dispute spam on dust escrows
- Arbitrator assignment for trivial amounts
- Griefing vector (wastes arbitrator capacity)

**Recommendation:**

Add a minimum escrow amount check in `createEscrow()` and `createPrivateEscrow()`:
```solidity
uint256 public constant MIN_ESCROW_AMOUNT = 10000; // 10,000 wei minimum
// or even higher for practical use:
uint256 public constant MIN_ESCROW_AMOUNT = 1 ether; // 1 XOM minimum

function createEscrow(...) external ... {
    if (amount < MIN_ESCROW_AMOUNT) revert InvalidAmount();
    // ...
}
```

Or add a minimum stake check in `commitDispute()`:
```solidity
uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
if (requiredStake == 0) revert InsufficientStake();
```

---

### [L-02] Private Escrow MarketplaceFeeCollected Event Leaks Amount via Reverse Calculation

**Severity:** Low
**Category:** Privacy Leak
**Location:** `releasePrivateFunds()` (line 1283), `_resolvePrivateEscrow()` (line 1397)

**Description:**

Private escrows are designed to hide the transaction amount. The `PrivateEscrowCreated` and `PrivateEscrowResolved` events correctly omit the amount. However, when funds are released to the seller, the `MarketplaceFeeCollected` event emits `feeAmount`:

```solidity
emit MarketplaceFeeCollected(escrowId, FEE_VAULT, feeAmount); // line 1283
```

Since `feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS`, any observer can reverse-calculate the original amount:
```
original_amount = feeAmount * BASIS_POINTS / MARKETPLACE_FEE_BPS
                = feeAmount * 10000 / 100
                = feeAmount * 100
```

Additionally, the `FundsClaimable` event (line 1288) emits `sellerAmount = amount - feeAmount`, which directly reveals the payout amount. Combined with the fee, the full escrow amount is trivially recoverable.

**Impact:**
- Complete de-anonymization of private escrow amounts from on-chain event data
- The privacy guarantee of private escrows is effectively nullified for seller-release scenarios
- Refund scenarios are also leaked via `FundsClaimable` event

**Recommendation:**

For COTI deployment where privacy matters, consider:
1. Suppressing fee-related events for private escrows
2. Emitting a separate `PrivateEscrowFeeCollected(escrowId)` event without amounts
3. Suppressing `FundsClaimable` events for private escrows (use `PrivateEscrowResolved` instead)

Note: This is a COTI-network-specific concern. On non-COTI chains, privacy features are disabled, so this is moot.

---

### [L-03] releaseFunds() Uses Push Transfer While Disputed Path Uses Pull

**Severity:** Low
**Category:** Inconsistency
**Location:** `releaseFunds()` (line 519), `refundBuyer()` (line 557)

**Description:**

The non-disputed "happy path" functions use direct `safeTransfer()` (push pattern):
```solidity
OMNI_COIN.safeTransfer(escrow.seller, sellerAmount); // line 519
OMNI_COIN.safeTransfer(escrow.buyer, amount);         // line 557
```

While the disputed resolution path uses the pull pattern:
```solidity
claimable[address(OMNI_COIN)][recipient] += recipientAmount; // line 1079
```

This inconsistency means:
- Disputed escrow recipients must call `withdrawClaimable()` to receive funds
- Non-disputed escrow recipients receive funds directly
- If the seller's address is a contract that reverts on `transfer()`, `releaseFunds()` will revert permanently, and the buyer cannot release funds

For the non-disputed path, this is partially self-imposed: the buyer calls `releaseFunds()`, and if the seller's contract reverts, the buyer can wait for expiry and call `refundBuyer()`. However, the seller's contract might also prevent `refundBuyer()` from completing if the buyer address is also a reverting contract.

**Impact:**
- Low risk -- the non-disputed path is a two-party agreement where the calling party controls the flow
- Inconsistent UX between disputed and non-disputed resolution

**Recommendation:**

Consider using pull pattern uniformly for all fund disbursements, or document this as an accepted design choice. The current approach is defensible since the non-disputed path is simpler and the caller is typically the beneficiary's counterpart.

---

### [L-04] NatSpec Comment at Line 1077 References Incorrect Line Number

**Severity:** Low
**Category:** Documentation
**Location:** `_resolveEscrow()` (line 1077)

**Description:**

The comment at line 1077 states:
```solidity
// Note: totalEscrowed already decremented at line 688 for full amount.
```

The actual decrement is at line 1031 (`totalEscrowed[address(OMNI_COIN)] -= amount;`), not line 688. This is a stale reference from a previous version of the contract.

**Recommendation:**

Update the comment to reference the correct line:
```solidity
// Note: totalEscrowed already decremented at line 1031 for full amount.
```

Or better, use a relative reference:
```solidity
// Note: totalEscrowed already decremented above for the full escrow principal.
```

---

## Informational Findings

### [I-01] addArbitrator Reuses AlreadyDisputed Error for Duplicate Registration

**Location:** `addArbitrator()` (line 1163)

```solidity
if (isRegisteredArbitrator[arbitrator]) revert AlreadyDisputed(); // already registered
```

This error is semantically incorrect. Off-chain monitoring tools and block explorers will display "AlreadyDisputed" when an arbitrator is already registered, confusing operators and users.

**Recommendation:** Add a dedicated `AlreadyRegistered()` custom error, or reuse `InvalidAddress()`.

---

### [I-02] Struct Slot Packing Comment Slightly Inaccurate

**Location:** Lines 39-50

```solidity
struct Escrow {
    address buyer;        // slot 1: 20 bytes
    address seller;       // slot 2: 20 bytes
    address arbitrator;   // slot 3: 20 bytes
    uint8 releaseVotes;   // slot 3: 1 byte
    uint8 refundVotes;    // slot 3: 1 byte
    bool resolved;        // slot 3: 1 byte
    bool disputed;        // slot 3: 1 byte (total: 24 bytes in slot 3)
    uint256 amount;       // slot 4: 32 bytes
    uint256 expiry;       // slot 5: 32 bytes
    uint256 createdAt;    // slot 6: 32 bytes
}
```

The comments correctly identify that `buyer` is in slot 1 and `seller` is in slot 2 (for the first mapping struct -- actual slot numbers depend on the mapping key). The packing of `arbitrator` + `releaseVotes` + `refundVotes` + `resolved` + `disputed` into slot 3 is correct (20 + 1 + 1 + 1 + 1 = 24 bytes).

However, `buyer` at slot 1 occupies only 20 bytes, leaving 12 bytes unused. `seller` at slot 2 also leaves 12 bytes unused. The struct could be further optimized by moving `uint8` fields next to `buyer` or `seller`, but this would break the current storage layout and the gas savings are minimal since the struct is read/written atomically via `escrows[escrowId]`.

No action needed; the current layout is acceptable.

---

### [I-03] REVEAL_GRACE_PERIOD + revealDeadline Can Exceed Escrow Expiry

**Location:** `reclaimExpiredStake()` (line 692)

The `reclaimExpiredStake()` function requires:
```solidity
block.timestamp > commitment.revealDeadline + REVEAL_GRACE_PERIOD
```

Where `REVEAL_GRACE_PERIOD = 24 hours` and `revealDeadline = commitTime + 1 hour`. So the user must wait 25 hours after commit to reclaim their stake.

If the escrow has a short duration (e.g., `MIN_DURATION = 1 hour`), the escrow could expire before the stake reclaim window opens. In this scenario:
- Escrow expires after 1 hour
- Stake reclaim requires waiting 25 hours
- During the 24-hour gap, the buyer could call `refundBuyer()` (non-disputed path, after expiry)
- The escrow resolves, but the dispute stake is still locked
- After 25 hours, the stake can be reclaimed via `reclaimExpiredStake()`

This is not a bug -- both the escrow and the stake are handled correctly. The buyer gets their escrow refund via `refundBuyer()` and their stake back via `reclaimExpiredStake()` (separate transactions). However, it may confuse users who expect a single resolution path.

**Recommendation:** Document this two-transaction scenario in user-facing documentation.

---

### [I-04] claimDisputeTimeout Refunds Buyer Even When Seller May Be in the Right

**Location:** `claimDisputeTimeout()` (lines 720-751)

When a disputed escrow times out (30 days after expiry), the buyer automatically receives a full refund. This is the default "safe" behavior, but it can be unfair to sellers who delivered goods/services and whose arbitrator became unavailable.

The OmniArbitration integration provides a better dispute resolution path (with a proper arbitrator panel and deadline enforcement), so this function serves as a backstop for the legacy internal 2-of-3 vote path.

**Recommendation:** This is acceptable as a safety net. Consider adding documentation noting that the OmniArbitration path should be the primary dispute resolution mechanism, with `claimDisputeTimeout()` as a last resort.

---

### [I-05] OmniArbitration Can Call resolveDispute() Without MinimalEscrow Being Aware of the Dispute

**Location:** `resolveDispute()` (lines 874-971), OmniArbitration `createDispute()` (OmniArbitration.sol line 749)

The OmniArbitration contract creates disputes via `createDispute()`, which calls `escrow.getBuyer()`, `escrow.getSeller()`, and `escrow.getAmount()` for information. But OmniArbitration does NOT call any function on MinimalEscrow to "register" the dispute. The MinimalEscrow's `escrow.disputed` flag is NOT set when OmniArbitration creates a dispute.

This means:
1. A user could create a dispute in OmniArbitration for escrow ID 5
2. Meanwhile, the buyer calls `releaseFunds()` or `refundBuyer()` on escrow ID 5 in MinimalEscrow
3. The escrow resolves via the non-disputed path
4. When OmniArbitration later calls `resolveDispute(5, ...)`, it reverts with `AlreadyResolved`

This is actually correct behavior -- first-to-resolve wins. But it means OmniArbitration dispute fees could be collected for a dispute that never actually resolves through the arbitration path. The OmniArbitration contract would emit a `ResolutionCallFailed` event (line 1703 in OmniArbitration.sol) but the dispute fee has already been distributed.

This is a cross-contract design consideration, not a bug in MinimalEscrow. The OmniArbitration audit should track this.

---

## Accounting Invariant Analysis

### Invariant: `contractBalance >= totalEscrowed + totalClaimable` (per token)

For this invariant to hold, every increment to `totalEscrowed` or `totalClaimable` must correspond to an incoming token transfer, and every outgoing transfer must decrement one of these counters.

**Public escrow (XOM) flow:**

| Operation | Token Flow | totalEscrowed | totalClaimable |
|-----------|-----------|---------------|----------------|
| `createEscrow()` | buyer -> contract | +amount | - |
| `releaseFunds()` (non-disputed) | contract -> seller, contract -> feeVault | -amount | - |
| `refundBuyer()` (non-disputed) | contract -> buyer | -amount | - |
| `commitDispute()` | caller -> contract | +stake | - |
| `postCounterpartyStake()` | caller -> contract | +stake | - |
| `reclaimExpiredStake()` | contract -> caller | -stake | - |
| `_resolveEscrow()` (disputed) | contract -> feeVault (mkt+arb fees) | -amount, -arbFee | +recipientAmount, +stakeReturns |
| `resolveDispute()` (OmniArb) | contract -> feeVault (mkt+arb fees) | -amount, -arbFee | +recipientAmount, +stakeReturns |
| `claimDisputeTimeout()` | - | -amount, -stakes | +amount, +stakes |
| `withdrawClaimable()` | contract -> caller | - | -amount |
| `recoverERC20()` | contract -> recipient | - | - |

**Invariant verification for `_resolveEscrow()`:**
1. `totalEscrowed -= amount` (line 1031) -- escrow principal
2. `totalEscrowed -= totalCollected` (line 1068) -- arbitration fee from stakes
3. `totalClaimable += recipientAmount` (line 1080) -- recipient payout
4. `totalEscrowed -= stakeAmount` (line 1101, via `_returnDisputeStake`) -- remaining stakes
5. `totalClaimable += stakeAmount` (line 1103, via `_returnDisputeStake`) -- stake credits

The feeVault receives `feeAmount` (marketplace) + `totalCollected` (arbitration) via direct transfer. These amounts are deducted from `totalEscrowed`. The recipient receives `recipientAmount` via `claimable`, which is credited to `totalClaimable`.

Check: Does `totalEscrowed decrease == totalClaimable increase + direct transfers`?

- totalEscrowed decrease: `amount + totalCollected + buyerStakeRemaining + sellerStakeRemaining`
- totalClaimable increase: `recipientAmount + buyerStakeRemaining + sellerStakeRemaining`
- Direct transfers: `feeAmount + totalCollected`

Where `recipientAmount = amount - feeAmount` (if release to seller) or `amount` (if refund).

For release: decrease = `amount + totalCollected + stakeReturns`, increase = `(amount - feeAmount) + stakeReturns`, direct = `feeAmount + totalCollected`. Sum of increase + direct = `amount + totalCollected + stakeReturns`. Matches.

For refund: decrease = `amount + totalCollected + stakeReturns`, increase = `amount + stakeReturns`, direct = `totalCollected`. Sum = `amount + totalCollected + stakeReturns`. Matches.

**INVARIANT HOLDS** for the normal flow.

**Invariant violation via H-01 (re-commit overwrite):**

After the re-commit scenario described in H-01:
- `totalEscrowed` is inflated by the orphaned stake amount
- `contractBalance` contains the orphaned tokens
- `contractBalance >= totalEscrowed + totalClaimable` still holds (excess tokens trapped)
- But `recoverERC20()` will NOT make these tokens recoverable because `totalEscrowed` is inflated

This is a "trapped funds" issue, not an "undercollateralization" issue. The invariant still holds, but recoverable amount is understated.

---

## Cross-Contract Integration Analysis

### MinimalEscrow <-> OmniArbitration

**Interface compliance:**

| IArbitrationEscrow Method | MinimalEscrow Implementation | Status |
|---------------------------|------------------------------|--------|
| `getBuyer(escrowId)` | Returns `escrows[escrowId].buyer` | Correct |
| `getSeller(escrowId)` | Returns `escrows[escrowId].seller` | Correct |
| `getAmount(escrowId)` | Returns `escrows[escrowId].amount` | **Concern** for private escrows (returns 0) |
| `resolveDispute(escrowId, releaseFunds)` | Full resolution with fees + pull pattern | Correct but missing `disputed` check (see M-01) |

**Cross-contract timing issues:**

1. OmniArbitration's `createDispute()` reads `escrow.getAmount()`. For private escrows, this returns 0, causing OmniArbitration to revert with `DisputedAmountTooSmall` (the fee calculation yields 0). **Private escrows cannot use OmniArbitration.** This may be by design (privacy escrows use the internal 2-of-3 vote path instead).

2. OmniArbitration's `_triggerEscrowResolution()` uses try/catch (line 1700), so if MinimalEscrow's `resolveDispute()` reverts, the OmniArbitration dispute still resolves and fees are distributed. This is correct -- it prevents MinimalEscrow from blocking OmniArbitration resolution.

### MinimalEscrow <-> UnifiedFeeVault

**Fee routing correctness:**

All marketplace and arbitration fees are sent to `FEE_VAULT` (immutable). The UnifiedFeeVault handles the 70/20/10 distribution. This separation of concerns is correct and allows fee distribution logic to be upgraded without redeploying MinimalEscrow.

**Concern:** If `FEE_VAULT` is a contract that reverts on `transfer()`, non-disputed `releaseFunds()` and disputed vote-resolution paths will revert permanently. The pull pattern only applies to recipient payouts, not fee transfers. However, since FEE_VAULT is set at deployment and is a known, trusted contract, this risk is low.

### MinimalEscrow <-> OmniForwarder (ERC2771)

**Meta-transaction analysis:**

The OmniForwarder is a minimal wrapper around OpenZeppelin's `ERC2771Forwarder`. The forwarder address is immutable (set in constructor). All user-facing functions correctly use `_msgSender()` for the caller address. Admin functions (`addArbitrator`, `removeArbitrator`, `pause`, `unpause`, `recoverERC20`, `setArbitrationContract`) correctly use `msg.sender` via the `onlyAdmin` modifier.

**Commit-reveal integrity:** The commit hash includes `_msgSender()` (line 616), and the reveal verifies against `_msgSender()` (line 616). If the same user relays both commit and reveal through the forwarder, the addresses match. If different relayers submit the two transactions, `_msgSender()` returns the same original signer (the user), so the commit-reveal still works correctly.

---

## DeFi Exploit Analysis

### Can the buyer create escrow, receive goods, then refund?

**Mitigated.** The buyer cannot unilaterally refund before expiry. `refundBuyer()` requires seller agreement or expiry timeout with no dispute. If the seller disputes before expiry, the expiry-based refund is blocked (`!escrow.disputed` check at line 547).

### Can the seller prevent the buyer from getting a refund?

**Partially mitigated.** The seller cannot prevent a refund if they agree (`refundBuyer()` by seller) or if the escrow expires without dispute. If the seller raises a dispute, the buyer needs the arbitrator's vote to refund. If the arbitrator goes offline, `claimDisputeTimeout()` provides a 30-day escape hatch.

### Arbitrator nonce grinding for biased selection

**Partially mitigated.** The commit-reveal pattern prevents the disputer from knowing the arbitrator BEFORE committing. However, with a known `arbitratorSeed`, `escrow.createdAt`, and the arbitrator list, the disputer can pre-compute which nonces select which arbitrators. The commit locks the nonce, but the disputer can choose a favorable nonce before committing.

With `MAX_ARBITRATORS = 100` and typically far fewer actual arbitrators, the selection space is small. A sophisticated attacker can select a specific arbitrator with high probability.

**Note:** The OmniArbitration system uses two-phase blockhash-based selection (not nonce-based), which is significantly more resistant to this attack. For the legacy internal vote path, the risk is accepted.

### Flash loan interaction

**Not applicable.** Escrow creation requires `safeTransferFrom`, locking tokens for the duration. Flash-loaned tokens cannot be returned within the same transaction.

### Reentrancy

**Mitigated.** All state-changing external functions have `nonReentrant`. OmniCoin (XOM) is a standard ERC20 without ERC-777 hooks. The CEI pattern is followed throughout.

### Integer overflow

**Not applicable.** Solidity 0.8.24 has built-in overflow checks. Maximum realistic value: 16.6B * 10^18 * 500 = ~8.3 * 10^30, well within uint256 range.

---

## Centralization Risk Assessment

| Risk Factor | Assessment | Severity |
|-------------|------------|----------|
| ADMIN key compromise | Can add/remove arbitrators, pause contract, set arbitration contract, recover non-escrowed tokens. Cannot drain active escrows. **NEW:** Can set arbitration contract to malicious address to force-resolve non-disputed escrows (see M-01). | Medium-High |
| ADMIN key loss | No new arbitrators, no pause/unpause, no token recovery, no arbitration contract updates. Existing escrows can still resolve. | Medium |
| Trusted Forwarder compromise | Can impersonate any user for all `_msgSender()`-based functions. Could create fake escrows, release funds, vote in disputes. Forwarder address is immutable. | High |
| FEE_VAULT failure | If FEE_VAULT reverts on receive, `releaseFunds()` and disputed resolutions revert. Refund paths (no fee) are unaffected. | Low |
| Arbitrator collusion | Single arbitrator per dispute (legacy path); commit-reveal provides limited protection. OmniArbitration uses 3-of-3 panels with two-phase selection for better protection. | Medium |
| Arbitration Contract compromise | If the authorized `arbitrationContract` is compromised, it can force-resolve any escrow. Mitigated by admin control over the address. | High |

**Overall Centralization Rating:** 5/10

The ADMIN key and arbitration contract address are the two primary centralization vectors. The immutable forwarder is a fixed trust assumption. OmniArbitration integration significantly improves the dispute resolution quality but adds a new trust boundary.

---

## Test Coverage Analysis

**Test suite:** 32 tests passing (MinimalEscrow.test.js: 28, MinimalEscrowPrivacy.test.js: 4 + documentation)

**Well-covered areas:**
- Escrow creation (parameters, token transfer, duration limits, zero amount, self-escrow)
- Release and refund (happy path, expiry refund, double resolution, marketplace fee)
- Dispute resolution (delay, commit-reveal, arbitrator selection, arbitration fee)
- Arbitrator management (add, remove, non-admin rejection, no-arbitrator revert)
- Voting system (counting, refund votes, double voting, 2-vote threshold, H-03 check)
- Pull-pattern withdrawal (claimable balance, withdrawal, zero-balance rejection)
- Privacy features (deployment, detection, function signatures, events, errors, constants)

**Missing test coverage:**

| Area | Risk | Priority |
|------|------|----------|
| `reclaimExpiredStake()` | H-01 re-commit scenario | Critical |
| `claimDisputeTimeout()` | M-01 from Round 6 | High |
| `resolveDispute()` (OmniArbitration path) | M-01/M-03 from this round | High |
| `setArbitrationContract()` | M-01 from this round | High |
| `postCounterpartyStake()` | Dual-stake mechanics | Medium |
| `recoverERC20()` | Admin recovery | Medium |
| `pause()` / `unpause()` | Emergency controls | Medium |
| Private escrow dispute (commitDispute on private escrow) | M-02 from this round | Medium |
| Re-commit after failed reveal (H-01) | Stake orphaning | Critical |
| Dust escrow (amount < 1000 wei) | L-01 zero stake | Low |
| Marketplace fee on disputed release to seller | Fee correctness | Low |
| `withdrawClaimable()` with private tokens (pXOM) | Pull pattern for pXOM | Low |

---

## Remediation Priority (Round 7 Findings)

| Priority | ID | Finding | Effort | Blocking Mainnet? |
|----------|----|---------|--------|--------------------|
| 1 | H-01 | Re-commit orphans previous dispute stake | Low (add refund or block re-commit) | **Yes** -- funds loss bug |
| 2 | M-01 | setArbitrationContract no validation + resolveDispute missing disputed check | Low (add checks) | **Yes** -- force-resolution vector |
| 3 | M-02 | Private escrow zero dispute stake | Medium (branch on isPrivateEscrow) | **Yes** for COTI deployment |
| 4 | M-03 | resolveDispute on non-disputed escrow | Low (same fix as M-01 #1) | **Yes** (same as M-01) |
| 5 | L-01 | Dust escrow zero stake | Low (add minimum) | Recommended |
| 6 | L-02 | Privacy event amount leak | Low (suppress events) | For COTI deploy |
| 7 | L-03 | Push vs pull inconsistency | Design decision | Optional |
| 8 | L-04 | Stale line number in comment | Trivial | Optional |
| 9 | I-01 | Error reuse in addArbitrator | Trivial | Optional |

---

## Summary of Mainnet Blockers

1. **H-01 (Re-commit stake orphan):** Must be fixed before mainnet. Users can permanently lose dispute stakes through a plausible user flow (miss reveal, re-commit). The fix is a small code addition to `commitDispute()`.

2. **M-01/M-03 (resolveDispute missing disputed check):** Must be fixed before mainnet. The `resolveDispute()` function callable by the arbitration contract can force-resolve non-disputed escrows, bypassing the buyer-release or seller-refund flow. Adding `if (!e.disputed) revert NotDisputed()` is a one-line fix.

3. **M-02 (Private escrow zero stake):** Must be fixed before COTI deployment. Private escrows have a zero dispute stake because `commitDispute()` reads `escrow.amount` which is 0 for private escrows. This makes private escrow disputes free and arbitration fees uncollectable.

---

## Gas Optimization Notes

The contract is well-optimized:
- Struct packing in `Escrow` saves 2 storage slots
- Custom errors instead of require strings
- `++i` prefix increment
- `constant` and `immutable` for fixed values
- Swap-and-pop for arbitrator removal (O(1))
- SafeERC20 for all token operations

No additional gas optimizations recommended.

---

## Compilation Status

- Compiles successfully with Solidity 0.8.24
- No compiler warnings for this contract
- Contract size is within the 24KB deployment limit

---

*Generated by Claude Code Audit Agent (Round 7 -- Pre-Mainnet Final Review)*
*Contract: MinimalEscrow.sol (1,593 lines, Solidity 0.8.24)*
*Prior audits: Round 1 (2026-02-20) 0C/6H/8M/7L/5I; Round 6 (2026-03-10) 0C/2H/4M/5L/4I*
*This audit: 0C/1H/3M/4L/5I -- focused on residual bugs, cross-contract integration, and accounting invariants*
