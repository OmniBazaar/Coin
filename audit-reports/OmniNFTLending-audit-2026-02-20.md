# Security Audit Report: OmniNFTLending

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/nft/OmniNFTLending.sol`
**Solidity Version:** ^0.8.24
**Lines of Code:** 460
**Upgradeable:** No
**Handles Funds:** Yes (ERC20 principal escrow + ERC721 collateral custody)

## Executive Summary

OmniNFTLending is a P2P NFT lending contract where lenders deposit ERC20 principal and borrowers provide ERC721 collateral. The contract is well-structured with proper use of ReentrancyGuard, SafeERC20, ERC721Holder, and Checks-Effects-Interactions ordering. No critical vulnerabilities were found. Three high-severity findings were identified: (1) fee-on-transfer token incompatibility that can cause insolvency, (2) retroactive platform fee changes affecting active loans, and (3) malicious/paused NFT collections blocking repayment and forcing borrower liquidation. The Cyfrin compliance score of 73% reflects medium-severity gaps primarily in admin parameter management and token compatibility.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 5 |
| Low | 4 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 79 |
| Passed | 58 |
| Failed | 8 |
| Partial | 13 |
| **Compliance Score** | **73%** |

**Top 5 Failed Checks:**
1. **SOL-AM-DOSA-3** — Token blacklisting can permanently lock NFT collateral (no fallback repayment)
2. **SOL-CR-4** — Admin can change critical fee parameters immediately (no timelock)
3. **SOL-CR-6** — Single-step ownership transfer (should use Ownable2Step)
4. **SOL-Basics-Function-1** — Missing input validation (currency, feeRecipient zero-address)
5. **SOL-Defi-Lending-9** — No pause mechanism for emergency response

---

## High Findings

### [H-01] Fee-on-Transfer Token Incompatibility — Contract Insolvency Risk

**Severity:** High
**Category:** SC02 Business Logic / Token Integration
**VP Reference:** VP-46 (Fee-on-Transfer Token)
**Location:** `createOffer()` (line 211), `acceptOffer()` (line 267), `repay()` (lines 290-300)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin Checklist, Solodit
**Real-World Precedent:** Velodrome (Code4rena 2022-05 #150), Notional Finance (Sherlock 2023-12 #58), ZABU Finance (2021-09)

**Description:**
The contract uses `safeTransferFrom` to pull tokens and records the parameter amount, not the actual amount received. For fee-on-transfer tokens (STA, PAXG, USDT with fee enabled), the contract receives fewer tokens than recorded in `offer.principal`. When `acceptOffer()` later sends the full `principal` to the borrower, it uses funds from other deposits. Similarly, `repay()` receives less than `totalFromBorrower` but distributes the full recorded amounts.

**Exploit Scenario:**
1. Lender creates offer with 100 tokens of a 2% fee-on-transfer token. Contract receives 98 but records 100.
2. Borrower accepts. Contract sends 100 tokens (using 2 from another offer's deposit).
3. Repeated across multiple loans, each draining 2% from the pool, until the last lender cannot cancel or the last borrower cannot be paid.

**Recommendation:**
Either restrict `currency` to a whitelist of known-safe tokens, or use balance-before/after accounting:
```solidity
uint256 balBefore = IERC20(currency).balanceOf(address(this));
IERC20(currency).safeTransferFrom(msg.sender, address(this), principal);
uint256 received = IERC20(currency).balanceOf(address(this)) - balBefore;
if (received != principal) revert FeeOnTransferNotSupported();
```

---

### [H-02] Retroactive Platform Fee Change Affects Active Loans

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `repay()` (line 284), `setPlatformFee()` (line 358)
**Sources:** Agent-A, Agent-B, Agent-C, Cyfrin Checklist, Solodit
**Real-World Precedent:** Blueberry (Sherlock 2023-04 #4 — High), Ostium (Pashov 2025-01 — Medium)

**Description:**
The `platformFeeBps` is read from contract storage at repayment time (line 284), not snapshotted when the loan is created. The owner can change the fee after a loan has been accepted, retroactively altering the lender's expected interest payout. A fee increase from 10% to 20% of interest means the lender receives 10% less interest than expected when they created the offer. Neither the lender nor borrower can opt out of the change.

**Impact:**
At maximum fee (2000 bps = 20% of interest), the platform can redirect up to 20% of all accrued interest from active loans. Combined with no timelock (M-03), fee changes are immediate and undetectable without on-chain monitoring.

**Recommendation:**
Snapshot `platformFeeBps` into the `Loan` struct at creation time:
```solidity
struct Loan {
    // ... existing fields ...
    uint16 platformFeeBps; // snapshotted at loan creation
}

// In acceptOffer():
loans[loanId].platformFeeBps = platformFeeBps;

// In repay():
uint256 platformFee = (loan.interest * loan.platformFeeBps) / BPS_DENOMINATOR;
```

---

### [H-03] Malicious/Paused NFT Collection Blocks Repayment — Forced Liquidation

**Severity:** High
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Unexpected Revert)
**Location:** `repay()` (lines 302-306), `liquidate()` (lines 326-330)
**Sources:** Agent-B, Agent-C, Agent-D, Cyfrin Checklist, Solodit
**Real-World Precedent:** Revert Lend (Code4rena 2024-03 #54 — High H-06), Particle Protocol (Code4rena 2023-05 #44 — Medium), Blueberry (Sherlock 2023-04 #4 — High)

**Description:**
During `repay()`, after the borrower pays principal + interest, the contract calls `IERC721(loan.collection).safeTransferFrom(address(this), msg.sender, loan.tokenId)`. If the NFT collection is paused, implements a blacklist, or has a malicious `_beforeTokenTransfer` hook that reverts, the entire repayment transaction reverts. The borrower has the funds to repay but cannot — their loan will eventually be liquidated and they lose their NFT.

The same issue affects `liquidate()` — if the NFT cannot be transferred to the lender, the lender cannot claim collateral either, permanently locking the NFT in the contract.

**Impact:**
Borrower loses both principal AND NFT collateral despite being willing to repay. If the NFT collection is upgradeable, the behavior could change after loan creation. Solodit severity upgrade from Medium to High based on Revert Lend H-06 precedent.

**Recommendation:**
Separate repayment into two phases:
```solidity
function repay(uint256 loanId) external nonReentrant {
    // ... existing checks and fee calculations ...
    loan.repaid = true;

    // Transfer ERC20 payments (these should succeed)
    IERC20(loan.currency).safeTransferFrom(msg.sender, address(this), totalFromBorrower);
    IERC20(loan.currency).safeTransfer(loan.lender, lenderAmount);
    if (platformFee > 0) IERC20(loan.currency).safeTransfer(feeRecipient, platformFee);

    // Try NFT return; if it fails, borrower can claim later
    try IERC721(loan.collection).safeTransferFrom(address(this), msg.sender, loan.tokenId) {
        // success
    } catch {
        // Mark NFT as claimable by borrower
        nftClaimable[loanId] = true;
    }
    emit LoanRepaid(loanId, msg.sender, totalFromBorrower, platformFee);
}

function claimNFT(uint256 loanId) external nonReentrant {
    require(nftClaimable[loanId] && msg.sender == loans[loanId].borrower);
    nftClaimable[loanId] = false;
    IERC721(loans[loanId].collection).safeTransferFrom(address(this), msg.sender, loans[loanId].tokenId);
}
```

---

## Medium Findings

### [M-01] Missing Zero-Address Validation on feeRecipient

**Severity:** Medium
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** Constructor (line 166), `setFeeRecipient()` (line 367)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin Checklist

**Description:**
Neither the constructor nor `setFeeRecipient()` validates against `address(0)`. If `feeRecipient` is set to the zero address, `safeTransfer` in `repay()` (line 299) will revert for most ERC20 tokens, permanently blocking all repayments on active loans and forcing liquidation.

**Recommendation:**
```solidity
if (initialFeeRecipient == address(0)) revert InvalidAddress();
// ... and in setFeeRecipient():
if (newRecipient == address(0)) revert InvalidAddress();
```

---

### [M-02] Interest Labeled "Annual" but Calculated as Flat Rate

**Severity:** Medium
**VP Reference:** VP-34 (Logic Error / Documentation Mismatch)
**Location:** `acceptOffer()` (lines 237-238), `OfferCreated` event NatSpec (line 56)
**Sources:** Agent-A, Agent-B

**Description:**
The `OfferCreated` event NatSpec describes `interestBps` as "Annual interest in basis points" (line 56), but the interest is calculated as a flat percentage of principal regardless of loan duration: `interest = (principal * interestBps) / BPS_DENOMINATOR`. A 30-day loan at "50% annual" interest charges the full 50% — effectively 608% APR. A borrower who repays a 365-day 10% loan after 1 day pays ~3,650% APR.

**Impact:**
Users who interpret the rate as annual will dramatically overpay on short-term loans. This is either a documentation bug or a calculation bug.

**Recommendation:**
Either update NatSpec to say "flat interest rate for the loan term" (not "annual"), or pro-rate:
```solidity
uint256 interest = (offer.principal * offer.interestBps * offer.durationDays) / (BPS_DENOMINATOR * 365);
```

---

### [M-03] No Timelock on Admin Operations

**Severity:** Medium
**VP Reference:** VP-34 (Logic Error)
**Location:** `setPlatformFee()` (line 358), `setFeeRecipient()` (line 367)
**Sources:** Agent-C, Cyfrin Checklist, Solodit

**Description:**
Both admin functions take effect immediately. Combined with H-02 (retroactive fee changes), the owner can increase fees on active loans with zero notice. Neither function emits events, making changes undetectable to off-chain monitoring.

**Recommendation:**
Add a 48-hour timelock on admin parameter changes, or at minimum emit events:
```solidity
event PlatformFeeUpdated(uint16 oldFee, uint16 newFee);
event FeeRecipientUpdated(address oldRecipient, address newRecipient);
```

---

### [M-04] Single-Step Ownership Transfer

**Severity:** Medium
**VP Reference:** VP-06 (Access Control)
**Location:** Line 20 (inherits `Ownable`)
**Sources:** Cyfrin Checklist (SOL-CR-6)

**Description:**
Uses OpenZeppelin `Ownable` with single-step `transferOwnership()`. If the owner transfers to a wrong address, admin privileges are permanently lost. Should use `Ownable2Step` for two-step transfer with acceptance.

**Recommendation:**
Replace `Ownable` with `Ownable2Step`.

---

### [M-05] Unbounded Collections Array

**Severity:** Medium
**VP Reference:** VP-29 (Unbounded Loop)
**Location:** `createOffer()` (lines 206-208)
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin Checklist

**Description:**
The `collections` array parameter has no upper bound. Each entry writes a cold storage slot (~20,000 gas). A lender passing thousands of entries would consume excessive gas and create a large storage footprint with no cleanup mechanism.

**Recommendation:**
```solidity
uint256 public constant MAX_COLLECTIONS_PER_OFFER = 50;
if (collections.length > MAX_COLLECTIONS_PER_OFFER) revert TooManyCollections();
```

---

## Low Findings

### [L-01] Lender-Only Liquidation May Lock NFTs Permanently

**Severity:** Low
**Location:** `liquidate()` (line 321)
**Sources:** Agent-C, Agent-D

**Description:**
Only the lender can call `liquidate()`. If the lender loses their key or is an inaccessible contract, the NFT is permanently locked. Some protocols allow any address to trigger liquidation of expired loans.

**Recommendation:**
Consider allowing anyone to trigger liquidation after a grace period (e.g., 30 days post-expiry), sending the NFT to the lender's address.

---

### [L-02] No Pause Mechanism

**Severity:** Low
**Location:** Contract-wide
**Sources:** Agent-C, Cyfrin Checklist

**Description:**
No `Pausable` inheritance. If a vulnerability is discovered, there is no way to halt operations. `cancelOffer()` should remain callable when paused so lenders can recover principal.

---

### [L-03] Missing Zero-Address Check on currency Parameter

**Severity:** Low
**VP Reference:** VP-22
**Location:** `createOffer()` (line 199)
**Sources:** Agent-A, Agent-D

**Description:**
The `currency` parameter is not validated against `address(0)`. While `safeTransferFrom` on address(0) would revert, an explicit early check provides a clearer error message.

---

### [L-04] Borrower Can Repay After Expiry — Race With Liquidation

**Severity:** Low
**VP Reference:** VP-34 (Front-Running)
**Location:** `repay()` (lines 276-309), `liquidate()` (lines 315-333)
**Sources:** Agent-A, Agent-B, Solodit
**Real-World Precedent:** Revert Lend (Code4rena 2024-03 #486 — Medium)

**Description:**
No check in `repay()` that `block.timestamp < loan.dueTime`. After expiry, both `repay()` and `liquidate()` are callable simultaneously. The first transaction mined wins. This may be intentional (borrower-friendly grace), but creates MEV extraction opportunities.

**Recommendation:**
Document this behavior explicitly. If unintentional, add `if (block.timestamp > loan.dueTime) revert LoanExpired();` in `repay()`.

---

## Informational Findings

### [I-01] 70/20/10 Fee Split Not Enforced On-Chain

**Location:** `repay()` (line 299)
**Description:** All platform fees go to a single `feeRecipient`. The OmniBazaar 70/20/10 split relies on off-chain distribution. Documented in NatSpec.

### [I-02] Zero-Interest Loans Permitted

**Location:** `createOffer()` (line 190)
**Description:** `interestBps = 0` is valid. Platform earns zero fee from such loans. Likely intentional for P2P lending.

### [I-03] Self-Lending Permitted (Lender == Borrower)

**Location:** `acceptOffer()` (line 223)
**Description:** No check preventing `msg.sender == offer.lender`. Economically neutral but could inflate metrics.

### [I-04] Floating Pragma

**Location:** Line 2
**VP Reference:** VP-59
**Description:** `^0.8.24` should be pinned to exact version for production deployment.

---

## Known Exploit Cross-Reference

| Exploit/Audit | Date | Loss/Severity | Relevance |
|---------------|------|---------------|-----------|
| Revert Lend H-06 | Mar 2024 | High | Identical: NFT safeTransferFrom revert blocks liquidation/repayment |
| Blueberry #4 | Apr 2023 | High | Identical: parameter change blocks repayment but allows liquidation |
| Velodrome #150 | May 2022 | Medium | Identical: fee-on-transfer token accounting mismatch |
| Notional Finance #58 | Dec 2023 | Medium | Similar: fee-on-transfer causes vault insolvency |
| Particle Protocol #44 | May 2023 | Medium | Similar: NFT withdrawal blocked via sandwich |
| ZABU Finance | Sep 2021 | $600K | Related: fee-on-transfer exploit in DeFi protocol |

---

## Solodit Similar Findings

- **Fee-on-transfer**: 4 direct matches across Velodrome, Backed, Notional, Virtuals — all Medium+
- **NFT transfer DoS**: 3 matches (Revert Lend H-06, Particle M-01, Blueberry H) — severity upgraded from Medium to High based on precedent
- **Retroactive parameter change**: 2 matches (Blueberry H, Ostium M) — confirmed High severity
- **Unbounded arrays**: Covered by Cyfrin checklist SOL-Basics-AL-9/10 — consistent Medium
- **Missing timelock**: Covered by Cyfrin SOL-CR-4 — consistent Medium

---

## Static Analysis Summary

### Slither
Full-project analysis exceeds timeout (>3 minutes). Skipped.

### Aderyn
v0.6.8 crashes with "Fatal compiler bug" against solc v0.8.33. Skipped.

### Solhint
0 errors, 13 warnings:
- 1x ordering (events after custom errors)
- 5x gas-indexed-events
- 1x gas-struct-packing (Offer struct)
- 3x gas-increment-by-one
- 2x not-rely-on-time (timestamp usage — justified for day-granularity loans)
- 1x use-forbidden-name (variable `l` in getLoan)

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (deployer) | `setPlatformFee()`, `setFeeRecipient()`, `transferOwnership()`, `renounceOwnership()` | 4/10 |
| Lender (per-offer) | `cancelOffer()`, `liquidate()` | 2/10 |
| Borrower (per-loan) | `repay()` | 1/10 |
| Any EOA | `createOffer()`, `acceptOffer()` | 1/10 |

---

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised owner can:
1. Increase platform fee to 20% of interest on all active loans (retroactively)
2. Redirect all future platform fees to attacker address
3. Set feeRecipient to address(0), blocking all repayments and forcing liquidations

**What the owner CANNOT do:**
- Cannot directly drain escrowed principal or NFT collateral
- Cannot modify loan terms (principal, interest, due time)
- Cannot create loans on behalf of users

**Centralization Score: 4/10** (limited to fee parameter manipulation; no direct fund extraction)

**Recommendation:**
- Use Ownable2Step for two-step ownership transfer
- Add timelock on fee parameter changes
- Snapshot fee parameters into loans at creation time

---

## Remediation Priority

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| 1 | H-01: Fee-on-transfer token handling | Medium | Prevents insolvency |
| 2 | H-02: Snapshot platformFeeBps in loans | Low | Protects active loan terms |
| 3 | H-03: Two-phase repayment for NFT DoS | Medium | Prevents forced liquidation |
| 4 | M-01: Zero-address check on feeRecipient | Trivial | Prevents repayment DoS |
| 5 | M-02: Fix NatSpec or pro-rate interest | Low | Prevents user confusion |
| 6 | M-03: Add events + timelock for admin ops | Low | Transparency |
| 7 | M-04: Ownable2Step | Trivial | Prevents ownership loss |
| 8 | M-05: Collections array bound | Trivial | Prevents gas waste |

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 58 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Static tools: Solhint (13 warnings, 0 errors). Slither and Aderyn skipped due to compatibility issues.*
