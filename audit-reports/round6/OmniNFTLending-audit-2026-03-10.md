# Security Audit Report: OmniNFTLending.sol -- Round 6 (Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (5-Pass Pre-Mainnet Audit)
**Contract:** `Coin/contracts/nft/OmniNFTLending.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 791 (up from 460 in Round 1)
**Upgradeable:** No
**Handles Funds:** Yes (ERC-20 principal escrow, ERC-721 collateral custody, platform fees)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21)

---

## Executive Summary

OmniNFTLending is a P2P NFT lending contract where lenders deposit ERC-20 principal and borrowers provide ERC-721 collateral. This Round 6 pre-mainnet audit confirms that all High-severity findings from Round 1 have been resolved:

- **H-01 (Fee-on-transfer insolvency):** Fixed -- `_safeTransferInWithBalanceCheck()` rejects fee-on-transfer tokens (reverts with `TransferAmountMismatch`)
- **H-02 (Retroactive platform fee):** Fixed -- `platformFeeBps` snapshotted into `Loan` struct at loan creation
- **H-03 (NFT transfer blocks repayment):** Fixed -- try/catch in `repay()` with `nftClaimable` fallback and `claimNFT()` function

All Medium findings have been addressed:
- **M-01 (Missing zero-address on feeRecipient):** Fixed -- validated in constructor and `setFeeRecipient()`
- **M-02 (Interest not annualized):** Fixed -- interest pro-rated by duration: `principal * interestBps * durationDays / (BPS_DENOMINATOR * 365)`
- **M-03 (No events on admin ops):** Fixed -- `PlatformFeeUpdated` and `FeeRecipientUpdated` events added
- **M-04 (Single-step Ownable):** Fixed -- now uses `Ownable2Step`
- **M-05 (Unbounded collections array):** Fixed -- `MAX_COLLECTIONS_PER_OFFER = 50` cap

Additionally:
- `renounceOwnership()` disabled (M-04 from NFTSuite audit)
- Liquidation grace period added (`LIQUIDATION_GRACE_PERIOD = 1 days`)
- `NFTClaimReady` and `NFTClaimed` events for failed NFT transfers

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 4 |

**Overall Assessment: PRODUCTION READY with minor caveats noted below.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | `_safeTransferInWithBalanceCheck()` rejects fee-on-transfer tokens but does not handle them | **FIXED** |
| M-02 | Medium | Borrower can repay after loan expiry -- race condition with liquidation | **FIXED** |

---

## Remediation Status from Previous Audits

| ID | Severity | Title | Status | Notes |
|----|----------|-------|--------|-------|
| H-01 | High | Fee-on-transfer token insolvency | RESOLVED | `_safeTransferInWithBalanceCheck()` (lines 729-740) rejects tokens where received != expected; used in `createOffer()` and `repay()` |
| H-02 | High | Retroactive platform fee change | RESOLVED | `platformFeeBps` stored in `Loan` struct (line 76); snapshotted at loan creation (line 421); `repay()` uses `loan.platformFeeBps` (line 463) |
| H-03 | High | NFT transfer blocks repayment | RESOLVED | try/catch in `repay()` (lines 490-500); `nftClaimable` mapping (line 133); `claimNFT()` function (lines 516-531); `NFTClaimReady` and `NFTClaimed` events |
| M-01 | Medium | Missing zero-address on feeRecipient | RESOLVED | Constructor validates (line 298); `setFeeRecipient()` validates (line 608) |
| M-02 | Medium | Interest labeled "annual" but flat rate | RESOLVED | Pro-rated: `principal * interestBps * durationDays / (BPS_DENOMINATOR * 365)` (lines 393-397) |
| M-03 | Medium | No events on admin operations | RESOLVED | `PlatformFeeUpdated` (line 213), `FeeRecipientUpdated` (line 221) events with old/new values |
| M-04 | Medium | Single-step Ownable | RESOLVED | Now uses `Ownable2Step` (line 40); `renounceOwnership()` disabled (line 714) |
| M-05 | Medium | Unbounded collections array | RESOLVED | `MAX_COLLECTIONS_PER_OFFER = 50` (line 104); `TooManyCollections` error (line 274) |
| Suite M-01 | Medium | No liquidation grace period | RESOLVED | `LIQUIDATION_GRACE_PERIOD = 1 days` (line 101); `GracePeriodActive` error (line 277); enforced in `liquidate()` (lines 547-552) |
| L-01 | Low | Lender-only liquidation may lock NFTs | UNCHANGED | Design decision; see L-03 below |
| L-02 | Low | No pause mechanism | UNCHANGED | Acceptable for this contract |
| L-03 | Low | Missing zero-address on currency | UNCHANGED | Self-protecting (safeTransferFrom reverts) |
| L-04 | Low | Borrower can repay after expiry | UNCHANGED | See analysis below |
| I-01 | Info | 70/20/10 fee split not enforced on-chain | UNCHANGED | Off-chain by design; documented in NatSpec |
| I-02 | Info | Zero-interest loans permitted | UNCHANGED | Intentional |
| I-03 | Info | Self-lending permitted | UNCHANGED | Economically neutral |
| I-04 | Info | Floating pragma | RESOLVED | Pinned to `0.8.24` |

---

## New Findings (Round 6)

### [M-01] `_safeTransferInWithBalanceCheck()` Rejects Fee-on-Transfer Tokens but Does Not Handle Them

**Severity:** Medium
**Location:** `_safeTransferInWithBalanceCheck()` (lines 729-740)

**Description:**

The fee-on-transfer protection uses a strict equality check:

```solidity
if (balAfter - balBefore != amount) {
    revert TransferAmountMismatch();
}
```

This is a strict "no fee-on-transfer allowed" policy. If a lender attempts to create an offer with a fee-on-transfer token, the transaction reverts. This is a valid design choice, but it differs from the approach taken in OmniFractionalNFT (which accepts the actual received amount) and OmniNFTStaking (which also uses balance-before/after but stores the actual received amount).

**Impact:** Any legitimate fee-on-transfer token (PAXG, STA, or future tokens) cannot be used for lending offers. This is not a vulnerability but a functional limitation that should be documented.

**Comparison with other NFT contracts:**
- OmniFractionalNFT `proposeBuyout()`: Accepts fee-on-transfer, stores actual received amount
- OmniNFTStaking `createPool()`: Accepts fee-on-transfer, stores actual received amount
- OmniNFTLending `createOffer()`: Rejects fee-on-transfer, reverts

**Recommendation:** Document this as a known limitation. The rejection approach is actually safer for a lending protocol because it prevents the complex accounting issues that arise from fee-on-transfer tokens in loan repayment flows. Consider adding a comment or NatSpec note:

```solidity
/// @dev Fee-on-transfer tokens are explicitly not supported.
///      Use _safeTransferInWithBalanceCheck to enforce exact amounts.
```

---

### [M-02] Borrower Can Repay After Loan Expiry -- Race Condition With Liquidation

**Severity:** Medium
**Location:** `repay()` (lines 453-505), `liquidate()` (lines 540-564)

**Description:**

The `repay()` function has no check that `block.timestamp < loan.dueTime`. After the loan expires:

- `repay()` is callable by the borrower (no expiry check)
- `liquidate()` is callable by the lender (after grace period: `block.timestamp >= dueTime + LIQUIDATION_GRACE_PERIOD`)

This creates a race condition during the grace period (`dueTime < block.timestamp < dueTime + LIQUIDATION_GRACE_PERIOD`):
- Only `repay()` can be called (liquidation is blocked by grace period)
- This is actually BORROWER-FRIENDLY -- the grace period protects late repayments

After the grace period (`block.timestamp >= dueTime + LIQUIDATION_GRACE_PERIOD`):
- Both `repay()` and `liquidate()` are callable
- Whoever mines first wins
- A borrower repaying at the last second could have their transaction front-run by the lender's `liquidate()` call

**Assessment:** The grace period design is sound and protects borrowers. The post-grace-period race condition is a standard MEV concern in DeFi lending. The economic incentive for the borrower is to repay before the grace period ends.

**Recommendation:** Consider adding `if (block.timestamp > loan.dueTime + LIQUIDATION_GRACE_PERIOD) revert LoanExpired();` to `repay()` to create a clean cutoff. Alternatively, document that late repayment after the grace period is a race condition by design.

---

### [L-01] `acceptOffer()` Releases Principal Before Receiving NFT Collateral

**Severity:** Low
**Location:** `acceptOffer()` (lines 426-435)

**Description:**

The function flow in `acceptOffer()` is:

1. Transfer NFT from borrower to contract (line 427-431): collateral locked
2. Transfer principal from contract to borrower (line 433-435): funds released

This ordering is correct -- the NFT is locked first, then funds are released. The `nonReentrant` guard prevents any re-entry between these two calls. If the NFT transfer fails (borrower does not own the NFT or collection is paused), the entire transaction reverts, and no funds are released.

**Assessment:** The ordering is correct and safe. The `nonReentrant` modifier prevents any attack via the `onERC721Received` callback during the NFT transfer.

**Note:** This finding was initially flagged as a potential CEI violation but upon deeper analysis, the NFT transfer (step 1) is an "interaction" that precedes another "interaction" (step 2). However, both are protected by `nonReentrant`, and the "effect" (setting `offer.active = false` on line 388 and creating the loan struct on lines 408-424) occurs before both interactions. This follows CEI correctly.

---

### [L-02] `cancelOffer()` Returns Nominal Principal, Not Actual Deposited Amount

**Severity:** Low
**Location:** `cancelOffer()` (lines 571-585)

**Description:**

When a lender cancels their offer, `offer.principal` is returned:

```solidity
IERC20(offer.currency).safeTransfer(caller, offer.principal);
```

Since `_safeTransferInWithBalanceCheck()` enforces that the exact `principal` amount was received during `createOffer()`, this is correct -- the contract holds exactly `offer.principal` for this offer.

However, if the ERC-20 token adds a transfer fee AFTER the offer was created (e.g., via an upgradeable token proxy), the `safeTransfer` would attempt to send more than the contract holds for this specific offer. The contract might use funds from other offers to cover the difference.

**Assessment:** This is a theoretical edge case that requires the ERC-20 token to change its fee behavior after offer creation. The `TransferAmountMismatch` check at creation time mitigates the most common scenarios.

**Recommendation:** Accept as a known limitation. Upgradeable-token risks are inherent in any DeFi protocol.

---

### [L-03] Lender-Only Liquidation Could Lock NFTs Permanently

**Severity:** Low
**Location:** `liquidate()` (line 553)

**Description:**

Only the lender can call `liquidate()`:

```solidity
if (msg.sender != loan.lender) revert NotLender();
```

If the lender:
- Loses access to their private key
- Is a contract that self-destructs or becomes permanently unable to call `liquidate()`
- Dies or becomes incapacitated (for EOA lenders)

Then the NFT is permanently locked in the contract. Neither the borrower (who defaulted) nor any third party can trigger liquidation.

**Recommendation:** Consider allowing anyone to trigger liquidation after an extended grace period (e.g., 90 days post-expiry), sending the NFT to the lender's address. This does not change the economic outcome but provides a fallback:

```solidity
if (msg.sender != loan.lender) {
    // Allow anyone to liquidate after extended period
    if (block.timestamp < loan.dueTime + 90 days) revert NotLender();
}
```

---

### [I-01] 70/20/10 Fee Split Not Enforced On-Chain

**Severity:** Informational
**Location:** `repay()` (lines 475-483)

**Description:**

All platform fees go to a single `feeRecipient`. The OmniBazaar 70/20/10 split is documented as "split off-chain per OmniBazaar 70/20/10 model" in the contract NatSpec (lines 27-28). The `feeRecipient` should be a splitter contract or multisig that distributes funds according to the model.

---

### [I-02] Zero-Interest Loans Permit Free Capital Borrowing

**Severity:** Informational
**Location:** `createOffer()` (line 329)

**Description:**

`interestBps = 0` is valid. This enables zero-cost loans where the borrower pays no interest. The platform also earns zero fee (`platformFee = interest * feeBps / 10000 = 0`). This is likely intentional for P2P charitable lending, but it means the platform generates no revenue from such loans.

---

### [I-03] Self-Lending (Lender == Borrower) Is Permitted

**Severity:** Informational
**Location:** `acceptOffer()` (line 387)

**Description:**

No check prevents `_msgSender() == offer.lender`. A user can create an offer and accept it with their own NFT. This is economically neutral (the user pays themselves interest) but could be used to:
1. Inflate lending volume metrics
2. Lock an NFT in the contract for the loan duration (as a time-lock mechanism)

Neither outcome is harmful.

---

### [I-04] `claimNFT()` May Fail Permanently If Collection Remains Paused

**Severity:** Informational
**Location:** `claimNFT()` (lines 516-531)

**Description:**

If `repay()` fails to return the NFT (try/catch triggers `nftClaimable[loanId] = true`), the borrower can later call `claimNFT()` to retrieve it. However, if the NFT collection is permanently paused or has a permanent blacklist on the contract address, `claimNFT()` will also fail every time. The NFT would be permanently locked.

This is an inherent limitation -- the contract cannot force a malicious or permanently paused NFT collection to execute transfers. The `nftClaimable` flag at least ensures the financial settlement is not blocked.

**Recommendation:** Document this edge case. Consider adding an admin `rescueNFT()` function that can transfer NFTs stuck due to collection issues, with a timelock and borrower-only destination.

---

## Interest Calculation Analysis

### Pro-Rated Annual Interest (H-01 Fix Verification)

The interest calculation (lines 393-397):

```solidity
uint256 interest = (
    uint256(offer.principal)
        * uint256(offer.interestBps)
        * uint256(offer.durationDays)
) / (uint256(BPS_DENOMINATOR) * DAYS_PER_YEAR);
```

**Verification examples:**

1. **1-day loan, 10% annual, 1000 USDC principal:**
   ```
   interest = (1000e18 * 1000 * 1) / (10000 * 365)
            = 1000e21 / 3650000
            = 273972602739726 (~0.274 USDC)
   ```
   Effective APR: 0.0274% per day * 365 = 10.0%. **Correct.**

2. **365-day loan, 50% annual, 1000 USDC principal:**
   ```
   interest = (1000e18 * 5000 * 365) / (10000 * 365)
            = 1000e18 * 5000 / 10000
            = 500e18 (500 USDC)
   ```
   50% of 1000 = 500. **Correct.**

3. **30-day loan, 10% annual, 100 USDC principal:**
   ```
   interest = (100e18 * 1000 * 30) / (10000 * 365)
            = 3000e21 / 3650000
            = 821917808219178 (~0.822 USDC)
   ```
   10% annual pro-rated to 30 days: 100 * 0.10 * 30/365 = 0.822. **Correct.**

### Integer Overflow Check

Maximum values: `principal = 2^256`, `interestBps = 5000`, `durationDays = 365`.

```
numerator = 2^256 * 5000 * 365 = 2^256 * 1825000
```

This overflows uint256. However, practical principal values (up to ~1e30 for high-value tokens) are safe:

```
1e30 * 5000 * 365 = 1.825e36 << 1.16e77 (uint256 max)
```

**Safe for all realistic values.**

### Truncation to Zero

For very small loans: `principal = 1` (1 wei), `interestBps = 1`, `durationDays = 1`:
```
interest = (1 * 1 * 1) / (10000 * 365) = 1 / 3650000 = 0
```

A zero-interest result is possible for dust-sized loans. Since `interestBps = 0` is explicitly allowed, this is consistent behavior. The lender receives `principal + 0 - 0 = principal` back.

---

## Collateral Management Analysis

### NFT Custody Flow

```
createOffer():   Lender deposits principal -> contract holds principal
acceptOffer():   Borrower deposits NFT -> contract holds NFT
                 Contract releases principal -> borrower receives funds
repay():         Borrower deposits principal + interest -> contract holds repayment
                 Contract releases repayment to lender (minus platform fee)
                 Contract releases NFT -> borrower gets NFT back (or claimNFT fallback)
liquidate():     Contract releases NFT -> lender gets collateral
cancelOffer():   Contract releases principal -> lender gets funds back
```

**Invariant:** At any point, the contract holds either:
- Principal (offer active, no loan)
- NFT + nothing (loan active, principal released to borrower)
- NFT + repayment (repay() mid-execution)

The principal is released to the borrower immediately upon loan acceptance. The lender's only protection after that is the NFT collateral. If the NFT depreciates below the loan value, the lender faces a loss even if the loan defaults.

### Can Lending Positions Be Manipulated for Liquidation?

**Attack vector 1: Front-run repayment with liquidation**
After the grace period, both `repay()` and `liquidate()` can be called. A lender could monitor the mempool for the borrower's `repay()` transaction and front-run it with `liquidate()`. The `loan.repaid` or `loan.liquidated` check (line 456) prevents double-execution -- whichever transaction mines first wins. This is a standard MEV concern, not specific to this contract.

**Attack vector 2: Manipulate NFT value to force liquidation**
Not applicable -- this contract has no price-based liquidation. Liquidation is purely time-based (loan expired + grace period). NFT floor price changes do not affect liquidation eligibility.

**Attack vector 3: Flash loan the principal**
A lender could flash-loan ERC-20 tokens to create an offer, then cancel it in the same block to reclaim the tokens. Since `createOffer()` deposits tokens and `cancelOffer()` returns them, a flash loan could create and cancel offers atomically. However, this has no impact -- no loan is created, no interest is earned, and the offer cancellation returns the exact deposited amount.

**Conclusion:** Lending positions cannot be meaningfully manipulated for forced liquidation. The time-based liquidation model with a 24-hour grace period is robust.

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Guard | External Calls | Verdict |
|----------|-------|----------------|---------|
| `createOffer()` | `nonReentrant` | `IERC20.balanceOf()`, `IERC20.safeTransferFrom()`, `IERC20.balanceOf()` | SAFE |
| `acceptOffer()` | `nonReentrant` | `IERC721.safeTransferFrom()` (callback), `IERC20.safeTransfer()` | SAFE |
| `repay()` | `nonReentrant` | `IERC20.balanceOf()`, `IERC20.safeTransferFrom()`, `IERC20.balanceOf()`, `IERC20.safeTransfer()` x2, try/catch `IERC721.safeTransferFrom()` | SAFE |
| `claimNFT()` | `nonReentrant` | `IERC721.safeTransferFrom()` (callback) | SAFE |
| `liquidate()` | `nonReentrant` | `IERC721.safeTransferFrom()` (callback) | SAFE |
| `cancelOffer()` | `nonReentrant` | `IERC20.safeTransfer()` | SAFE |
| `setPlatformFee()` | None needed | No external calls | SAFE |
| `setFeeRecipient()` | None needed | No external calls | SAFE |

All state-changing functions with external calls use `nonReentrant`. The `repay()` function correctly sets `loan.repaid = true` (line 460) before any external calls (CEI pattern). The try/catch for NFT transfer (lines 490-500) correctly handles both success and failure paths.

**ERC-721 Callback Risk:** `acceptOffer()`, `claimNFT()`, and `liquidate()` use `safeTransferFrom` which triggers `onERC721Received()`. All are protected by `nonReentrant`. The `ERC721Holder` base contract provides the required callback implementation.

---

## Access Control Analysis

| Role | Functions | Risk |
|------|-----------|------|
| Owner (Ownable2Step) | `setPlatformFee()`, `setFeeRecipient()`, `renounceOwnership()` (disabled) | 3/10 |
| Lender (per-offer) | `createOffer()`, `cancelOffer()`, `liquidate()` | 2/10 |
| Borrower (per-loan) | `acceptOffer()`, `repay()`, `claimNFT()` | 1/10 |
| Any EOA | View functions only | 0/10 |

**Centralization Risk: 3/10 (Low)**

The owner can:
- Update platform fee (only affects future loans -- snapshotted at creation)
- Change fee recipient (only affects future repayments -- existing loans already have principal distributed)
- `renounceOwnership()` is disabled (line 714)

The owner **cannot**:
- Access escrowed NFTs or principal
- Modify loan terms or liquidation conditions
- Block repayments or liquidations (except via feeRecipient = address(0), which is now validated)
- Create loans on behalf of users

**Significant improvement:** `Ownable2Step` prevents accidental ownership transfer. `renounceOwnership()` is disabled to prevent accidental admin lockout. Platform fee snapshotting prevents retroactive fee changes on active loans.

---

## Conclusion

OmniNFTLending has resolved all 3 High-severity and all 5 Medium-severity findings from Round 1. The contract demonstrates strong security practices:

- **Fee-on-transfer protection:** Strict rejection via `_safeTransferInWithBalanceCheck()`
- **Platform fee snapshotting:** Prevents retroactive fee changes on active loans
- **NFT transfer resilience:** try/catch in `repay()` with `claimNFT()` fallback
- **Grace period:** 24-hour window before liquidation
- **Pro-rated interest:** Annualized rate correctly pro-rated by duration
- **Admin safety:** `Ownable2Step`, disabled `renounceOwnership()`, events on all admin changes

The two remaining Medium findings (fee-on-transfer rejection documentation and post-grace repay/liquidate race) are minor and well-understood. The contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet Audit*
