# Security Audit Report: OmniNFTLending.sol -- Round 7 (Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet Audit)
**Contract:** `Coin/contracts/nft/OmniNFTLending.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 818
**Upgradeable:** No
**Handles Funds:** Yes (ERC-20 principal escrow, ERC-721 collateral custody, platform fees)
**Previous Audits:** Round 1 (2026-02-20), NFTSuite combined (2026-02-21), Round 6 (2026-03-10)

---

## Executive Summary

OmniNFTLending is a P2P NFT lending contract where lenders deposit ERC-20 principal and borrowers provide ERC-721 collateral. This Round 7 audit builds on the Round 6 pre-mainnet audit, confirming that all previously identified High-severity findings remain resolved. However, this audit identifies one new High-severity finding: the `liquidate()` function uses `msg.sender` instead of `_msgSender()`, breaking ERC-2771 meta-transaction support and creating an inconsistency that could lock lenders out of liquidation when operating through the trusted forwarder.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 1 |
| Low | 4 |
| Informational | 5 |

**Overall Assessment: NOT READY for mainnet until H-01 is fixed. All other findings are low-risk.**

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | High | `liquidate()` uses `msg.sender` instead of `_msgSender()` -- ERC-2771 bypass | **NEW** |
| M-01 | Medium | Duplicate collection addresses in `createOffer()` waste gas silently | **NEW** |
| L-01 | Low | Lender-only liquidation may permanently lock NFTs | OPEN (from R6) |
| L-02 | Low | `startTime` and `offerId` stored but not returned by `getLoan()` | **NEW** |
| L-03 | Low | No validation on `currency` or `collection` addresses being `address(0)` | **NEW** |
| L-04 | Low | `collections` array allows `address(0)` entries | **NEW** |
| I-01 | Info | Fee split to UnifiedFeeVault is trust-based, not enforced on-chain | OPEN (from R6) |
| I-02 | Info | Zero-interest loans produce zero platform fee | OPEN (from R6) |
| I-03 | Info | Self-lending (lender == borrower) is permitted | OPEN (from R6) |
| I-04 | Info | `claimNFT()` may fail permanently if NFT collection is permanently paused | OPEN (from R6) |
| I-05 | Info | Struct packing suppressed with `gas-struct-packing` disable comment | **NEW** |

---

## Remediation Status from Previous Audits

All previously identified High and Medium findings remain resolved:

| ID | Severity | Title | Status | Verification |
|----|----------|-------|--------|--------------|
| R1-H-01 | High | Fee-on-transfer token insolvency | RESOLVED | `_safeTransferInWithBalanceCheck()` (lines 756-767) rejects tokens where received != expected; used in `createOffer()` and `repay()` |
| R1-H-02 | High | Retroactive platform fee change | RESOLVED | `platformFeeBps` stored in `Loan` struct (line 76); snapshotted at loan creation (line 429); `repay()` uses `loan.platformFeeBps` (line 482) |
| R1-H-03 | High | NFT transfer blocks repayment | RESOLVED | try/catch in `repay()` (lines 509-519); `nftClaimable` mapping (line 136); `claimNFT()` function (lines 535-550); `NFTClaimReady` and `NFTClaimed` events |
| R1-M-01 | Medium | Missing zero-address on feeVault | RESOLVED | Constructor validates (line 306); `setFeeVault()` validates (line 627) |
| R1-M-02 | Medium | Interest not annualized | RESOLVED | Pro-rated: `principal * interestBps * durationDays / (BPS_DENOMINATOR * 365)` (lines 401-405) |
| R1-M-03 | Medium | No events on admin operations | RESOLVED | `PlatformFeeUpdated` (line 216), `FeeVaultUpdated` (line 224) events with old/new values |
| R1-M-04 | Medium | Single-step Ownable | RESOLVED | `Ownable2Step` (line 40); `renounceOwnership()` disabled (line 733) |
| R1-M-05 | Medium | Unbounded collections array | RESOLVED | `MAX_COLLECTIONS_PER_OFFER = 50` (line 104); `TooManyCollections` error (line 277) |
| R6-M-01 | Medium | Fee-on-transfer rejection not documented | RESOLVED | NatSpec comment at lines 741-751 explicitly documents the design choice |
| R6-M-02 | Medium | Borrower can repay after loan expiry | RESOLVED | `LoanExpired` error (line 288); check added at lines 472-477 blocking repayment after grace period ends |

---

## New Findings (Round 7)

### [H-01] `liquidate()` Uses `msg.sender` Instead of `_msgSender()` -- ERC-2771 Meta-Transaction Bypass

**Severity:** High
**Location:** `liquidate()`, line 572

**Description:**

The contract inherits `ERC2771Context` and overrides `_msgSender()` to support meta-transactions via a trusted forwarder. Every state-changing function that checks the caller consistently uses `_msgSender()`:

| Function | Caller Check | Method Used |
|----------|-------------|-------------|
| `createOffer()` | line 342 | `_msgSender()` |
| `acceptOffer()` | line 395 | `_msgSender()` |
| `repay()` | line 465-466 | `_msgSender()` |
| `claimNFT()` | line 538 | `_msgSender()` |
| `cancelOffer()` | line 594 | `_msgSender()` |
| **`liquidate()`** | **line 572** | **`msg.sender`** |

The `liquidate()` function at line 572 uses:

```solidity
if (msg.sender != loan.lender) revert NotLender();
```

This should be:

```solidity
if (_msgSender() != loan.lender) revert NotLender();
```

**Impact:**

When a lender calls `liquidate()` through the trusted forwarder (ERC-2771 meta-transaction), `msg.sender` will be the forwarder address, not the lender's actual address. The lender authorization check will fail with `NotLender()`, permanently blocking liquidation via meta-transactions. This means:

1. A lender who relies on a gasless/relayer infrastructure to interact with the contract cannot liquidate defaulted loans.
2. If the lender is a smart contract wallet that routes all calls through the trusted forwarder, the NFT collateral becomes permanently locked after loan default -- the lender cannot liquidate, and the borrower has already defaulted.
3. The inconsistency between `liquidate()` using `msg.sender` and `acceptOffer()` using `_msgSender()` means a loan created via meta-transaction could store a lender address that can never pass the `msg.sender` check in `liquidate()` when called through the same forwarder.

**Scenario:**

1. Lender creates an offer via the trusted forwarder. `_msgSender()` resolves to the lender's real address. `offer.lender = lenderAddress`.
2. Borrower accepts the offer. `loan.lender = lenderAddress`.
3. Loan defaults. Lender tries to call `liquidate()` via the trusted forwarder.
4. `msg.sender` is the forwarder address, not `lenderAddress`.
5. `msg.sender != loan.lender` is true. Transaction reverts with `NotLender()`.
6. NFT is permanently locked (unless the lender can also call directly without the forwarder).

**Recommendation:**

Replace `msg.sender` with `_msgSender()` on line 572:

```solidity
// Before (VULNERABLE):
if (msg.sender != loan.lender) revert NotLender();

// After (FIXED):
if (_msgSender() != loan.lender) revert NotLender();
```

This aligns `liquidate()` with every other caller-checking function in the contract.

---

### [M-01] Duplicate Collection Addresses in `createOffer()` Waste Gas Silently

**Severity:** Medium
**Location:** `createOffer()`, lines 356-359

**Description:**

The `createOffer()` function iterates over the `collections` array and sets `offerCollections[offerId][collections[i]] = true` for each entry. If the same collection address appears multiple times in the array, the mapping is simply overwritten with the same value. This does not create a vulnerability, but it wastes gas and may indicate a user error.

```solidity
uint256 colLen = collections.length;
for (uint256 i; i < colLen; ++i) {
    offerCollections[offerId][collections[i]] = true;
}
```

A lender could pass 50 copies of the same collection address, paying gas for 50 SSTORE operations (warm writes after the first) when only one unique collection was intended. More importantly, the `MAX_COLLECTIONS_PER_OFFER = 50` limit counts duplicates, so a lender intending to accept 50 different collections but accidentally including one duplicate would be blocked by `TooManyCollections` if they attempt 51 entries.

**Impact:** Gas waste and potential user confusion. No security vulnerability, but it degrades the quality of the `MAX_COLLECTIONS_PER_OFFER` bound.

**Recommendation:** Consider emitting the actual number of unique collections set, or adding a duplicate check. However, the gas cost of a duplicate check (reading each previous entry) may exceed the gas saved by skipping duplicate writes, so this is a design trade-off. The simplest approach is to document the behavior:

```solidity
/// @dev Duplicate collection addresses are silently accepted but waste gas.
///      The MAX_COLLECTIONS_PER_OFFER limit counts total entries, not unique ones.
```

---

### [L-01] Lender-Only Liquidation May Permanently Lock NFTs

**Severity:** Low
**Location:** `liquidate()`, line 572
**Status:** OPEN (carried from Round 6 L-03)

**Description:**

Only the lender can call `liquidate()`. If the lender loses access to their private key, is a contract that self-destructs, or becomes permanently unable to transact, the NFT collateral is locked in the contract forever. Neither the borrower (who defaulted) nor any third party can trigger liquidation.

**Recommendation:** Consider allowing anyone to trigger liquidation after an extended grace period (e.g., 90 days post-expiry), sending the NFT to the lender's recorded address. This does not change the economic outcome but provides a fallback for key-loss scenarios.

---

### [L-02] `startTime` and `offerId` Stored in Loan Struct but Not Returned by `getLoan()`

**Severity:** Low
**Location:** `Loan` struct (lines 65-79), `getLoan()` (lines 696-725)

**Description:**

The `Loan` struct contains `startTime` (line 74) and `offerId` (line 66), both of which are set during `acceptOffer()`. However, the `getLoan()` view function (lines 696-725) does not return either field. Consumers must use the auto-generated `loans(uint256)` getter to access them, which returns all fields in struct order but with positional (not named) return values.

This creates a fragmented API surface where some loan data requires the custom view function and other data requires the auto-generated getter.

**Impact:** Off-chain integrations may miss these fields when using only `getLoan()`. The `startTime` is useful for computing elapsed loan duration, and `offerId` is useful for tracing the loan back to its originating offer.

**Recommendation:** Add `startTime` and `offerId` to the `getLoan()` return values, or document that callers should use the auto-generated `loans()` getter for the complete struct.

---

### [L-03] No Validation on `currency` Address Being `address(0)`

**Severity:** Low
**Location:** `createOffer()`, line 326

**Description:**

The `currency` parameter in `createOffer()` is not validated against `address(0)`. If a lender passes `address(0)` as the currency, the `_safeTransferInWithBalanceCheck()` call will revert when attempting `IERC20(address(0)).balanceOf(address(this))`, since `address(0)` has no code. This is self-protecting -- the transaction reverts -- but the error message will be opaque (likely a low-level revert rather than a clear custom error).

**Impact:** No funds at risk. User experience is degraded by an unclear revert message.

**Recommendation:** Add `if (currency == address(0)) revert ZeroAddress();` to `createOffer()` for clearer error reporting.

---

### [L-04] `collections` Array Allows `address(0)` Entries

**Severity:** Low
**Location:** `createOffer()`, lines 356-359

**Description:**

The collections loop does not validate individual collection addresses. An entry of `address(0)` would set `offerCollections[offerId][address(0)] = true`. A borrower could then call `acceptOffer()` with `collection = address(0)`, which would pass the `offerCollections` check but revert on `IERC721(address(0)).safeTransferFrom()` since there is no code at `address(0)`.

This is self-protecting (the NFT transfer reverts), but the `address(0)` entry in `offerCollections` is a waste of storage and may confuse off-chain indexers.

**Impact:** No funds at risk. Minor storage waste and potential off-chain confusion.

**Recommendation:** Add a zero-address check inside the collections loop, or document that `address(0)` entries are harmless but wasteful.

---

### [I-01] Fee Split to UnifiedFeeVault Is Trust-Based, Not Enforced On-Chain

**Severity:** Informational
**Status:** OPEN (carried from Round 6)

The OmniBazaar 70/20/10 fee distribution is handled by the `UnifiedFeeVault` contract, which this contract sends 100% of platform fees to (line 499). The NatSpec at lines 27-28 documents this design. The correctness of the downstream distribution depends entirely on the `UnifiedFeeVault` implementation.

---

### [I-02] Zero-Interest Loans Produce Zero Platform Fee

**Severity:** Informational
**Status:** OPEN (carried from Round 6)

`interestBps = 0` is valid (no minimum interest check). When interest is zero, `platformFee = 0 * feeBps / 10000 = 0`. The platform earns nothing. This is intentional for P2P charitable lending scenarios.

---

### [I-03] Self-Lending (Lender == Borrower) Is Permitted

**Severity:** Informational
**Status:** OPEN (carried from Round 6)

No check prevents `_msgSender() == offer.lender` in `acceptOffer()`. A user can create an offer and accept it with their own NFT. This is economically neutral (the user pays themselves interest, minus the platform fee). It could be used to inflate lending volume metrics or as an NFT time-lock mechanism. Neither outcome is harmful.

---

### [I-04] `claimNFT()` May Fail Permanently If NFT Collection Is Permanently Paused

**Severity:** Informational
**Status:** OPEN (carried from Round 6)

If `repay()` fails to return the NFT (try/catch triggers `nftClaimable[loanId] = true`), the borrower can call `claimNFT()` later. However, if the NFT collection is permanently paused or has a permanent blacklist on the lending contract address, `claimNFT()` will also fail every time. The `nftClaimable` flag ensures the financial settlement is not blocked, but the NFT itself may be permanently locked. This is an inherent limitation of interacting with arbitrary ERC-721 contracts.

---

### [I-05] Struct Packing Suppressed with `gas-struct-packing` Disable Comment

**Severity:** Informational
**Location:** Lines 51, 64

**Description:**

Both the `Offer` and `Loan` structs have `// solhint-disable-next-line gas-struct-packing` comments. The current `Loan` struct layout is:

```
Slot 0: offerId (uint256) -- 32 bytes
Slot 1: borrower (address, 20 bytes) -- 20 bytes, 12 bytes padding
Slot 2: lender (address, 20 bytes) -- 20 bytes, 12 bytes padding
Slot 3: collection (address, 20 bytes) -- 20 bytes, 12 bytes padding
Slot 4: tokenId (uint256) -- 32 bytes
Slot 5: currency (address, 20 bytes) -- 20 bytes, 12 bytes padding
Slot 6: principal (uint256) -- 32 bytes
Slot 7: interest (uint256) -- 32 bytes
Slot 8: startTime (uint64, 8) + dueTime (uint64, 8) + platformFeeBps (uint16, 2) + repaid (bool, 1) + liquidated (bool, 1) = 20 bytes
```

The struct uses 9 storage slots. The address fields each waste 12 bytes of padding. An optimized layout could pack `borrower + startTime + dueTime` into one slot (20 + 8 + 4 = 32, but `dueTime` is `uint64` = 8 bytes, so 20 + 8 + 4 would need `dueTime` reduced to `uint32`), but the current layout prioritizes readability over gas savings. This is an acceptable trade-off for a contract where storage operations are infrequent (one write per loan creation).

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Guard | State Changes Before External Calls | External Calls | Verdict |
|----------|-------|--------------------------------------|----------------|---------|
| `createOffer()` | `nonReentrant` | Offer struct written (line 347), ID incremented (line 345) | `IERC20.balanceOf()`, `IERC20.safeTransferFrom()`, `IERC20.balanceOf()` | SAFE |
| `acceptOffer()` | `nonReentrant` | `offer.active = false` (line 396), Loan struct written (line 416), ID incremented (line 414) | `IERC721.safeTransferFrom()` (callback via `onERC721Received`), `IERC20.safeTransfer()` | SAFE |
| `repay()` | `nonReentrant` | `loan.repaid = true` (line 479) | `IERC20.balanceOf()`, `IERC20.safeTransferFrom()`, `IERC20.balanceOf()`, `IERC20.safeTransfer()` x2, try/catch `IERC721.safeTransferFrom()` | SAFE |
| `claimNFT()` | `nonReentrant` | `nftClaimable[loanId] = false` (line 541) | `IERC721.safeTransferFrom()` (callback) | SAFE |
| `liquidate()` | `nonReentrant` | `loan.liquidated = true` (line 574) | `IERC721.safeTransferFrom()` (callback) | SAFE |
| `cancelOffer()` | `nonReentrant` | `offer.active = false` (line 597) | `IERC20.safeTransfer()` | SAFE |
| `setPlatformFee()` | None needed | State variable update only | No external calls | SAFE |
| `setFeeVault()` | None needed | State variable update only | No external calls | SAFE |

All state-changing functions with external calls use `nonReentrant`. The CEI (Checks-Effects-Interactions) pattern is correctly followed in every function -- state mutations (`loan.repaid = true`, `offer.active = false`, etc.) occur before any external calls. The `ERC721Holder` base contract provides the required `onERC721Received` callback.

---

## Access Control Analysis

| Role | Functions | Permissions |
|------|-----------|-------------|
| Owner (Ownable2Step) | `setPlatformFee()`, `setFeeVault()`, `renounceOwnership()` (disabled) | Can update fee parameters for future loans only; cannot access escrowed funds or NFTs |
| Lender (per-offer) | `createOffer()`, `cancelOffer()`, `liquidate()` | Can create/cancel offers and liquidate defaulted loans |
| Borrower (per-loan) | `acceptOffer()`, `repay()`, `claimNFT()` | Can accept offers, repay loans, and claim stuck NFTs |
| Any EOA | View functions, `acceptOffer()` (any user can accept any active offer) | Read-only access plus offer acceptance |

**Centralization Risk: 3/10 (Low)**

The owner can:
- Update platform fee (capped at 20%, only affects future loans due to snapshotting)
- Change UnifiedFeeVault address (only affects future repayments)

The owner cannot:
- Access escrowed NFTs or ERC-20 principal
- Modify active loan terms or liquidation conditions
- Block repayments or liquidations
- Create loans on behalf of users
- Renounce ownership (disabled at line 733)

**Ownership transfer** uses `Ownable2Step`, requiring the new owner to explicitly accept ownership. This prevents accidental transfers to wrong addresses.

---

## Interest Calculation Analysis

### Pro-Rated Annual Interest (Lines 401-405)

```solidity
uint256 interest = (
    uint256(offer.principal)
        * uint256(offer.interestBps)
        * uint256(offer.durationDays)
) / (uint256(BPS_DENOMINATOR) * DAYS_PER_YEAR);
```

**Verification:**

1. **1-day loan, 10% annual, 1000 USDC:**
   `interest = (1000e18 * 1000 * 1) / (10000 * 365) = 273972602739726 (~0.274 USDC)` -- 10% APR. Correct.

2. **365-day loan, 50% annual, 1000 USDC:**
   `interest = (1000e18 * 5000 * 365) / (10000 * 365) = 500e18 (500 USDC)` -- 50%. Correct.

3. **30-day loan, 10% annual, 100 USDC:**
   `interest = (100e18 * 1000 * 30) / (10000 * 365) = 821917808219178082 (~0.822 USDC)` -- Correct.

**Overflow analysis:** Maximum numerator = `principal * 5000 * 365`. For overflow to occur, `principal` must exceed `2^256 / (5000 * 365) = 2^256 / 1825000 ~= 6.35e72`. This is astronomically higher than any realistic token supply. Safe for all practical values.

**Truncation to zero:** For `principal = 1 wei`, `interestBps = 1`, `durationDays = 1`: `interest = 1 / 3650000 = 0`. Zero interest for dust-sized loans is consistent with the contract allowing zero-interest loans.

---

## Collateral Management Analysis

### NFT Custody Flow

```
createOffer():   Lender deposits ERC-20 principal -> contract holds principal
acceptOffer():   Borrower deposits NFT -> contract holds NFT
                 Contract releases principal -> borrower receives funds
repay():         Borrower deposits principal + interest -> contract holds repayment
                 Contract releases repayment to lender (minus platform fee)
                 Contract sends platform fee to UnifiedFeeVault
                 Contract releases NFT -> borrower (or claimNFT fallback)
liquidate():     Contract releases NFT -> lender claims collateral
cancelOffer():   Contract releases principal -> lender gets funds back
```

**Invariant verification:** The contract never holds both principal and NFT simultaneously for the same loan. After `acceptOffer()`, the principal has been released to the borrower, and only the NFT remains as collateral. The lender's recourse on default is solely the NFT.

### Liquidation Attack Vectors

**Front-running repayment with liquidation:** After the grace period, both `repay()` and `liquidate()` are callable. The `LoanExpired` check at line 472-477 blocks repayment after the grace period ends, creating a clean cutoff: the borrower must repay before `dueTime + LIQUIDATION_GRACE_PERIOD`. After that, only `liquidate()` is available. This resolves the R6-M-02 race condition.

**NFT value manipulation:** Not applicable -- liquidation is purely time-based. NFT floor price changes do not affect liquidation eligibility.

**Flash loan attack on principal:** A lender could flash-loan tokens to create and immediately cancel an offer in the same block. This has no impact -- no loan is created, and the cancellation returns the exact deposited amount.

---

## ERC-2771 Meta-Transaction Analysis

The contract uses `ERC2771Context` for gasless transaction support. The `_msgSender()` override is correctly implemented at lines 778-785. However, the inconsistent usage in `liquidate()` (H-01 above) breaks the meta-transaction model for that function.

**Additional note:** The constructor accepts `trustedForwarder_ = address(0)` without validation. When the trusted forwarder is `address(0)`, `ERC2771Context.isTrustedForwarder()` returns `false` for all callers, and `_msgSender()` falls back to `msg.sender`. This effectively disables meta-transaction support, which is a valid deployment configuration (as seen in the test file at line 39). No vulnerability here.

---

## Solhint Compliance

```
npx solhint contracts/nft/OmniNFTLending.sol

contracts/nft/OmniNFTLending.sol
  473:13  warning  Avoid making time-based decisions in your business logic  not-rely-on-time

1 problem (0 errors, 1 warning)
```

The single `not-rely-on-time` warning at line 473 is for the `block.timestamp > loan.dueTime + LIQUIDATION_GRACE_PERIOD` check in `repay()`. This is a legitimate business requirement -- the grace period cutoff must be time-based. The warning is appropriately suppressed with `// solhint-disable-next-line not-rely-on-time` at line 472. Other time-based checks at lines 408, 426, 563, and 569 are also correctly suppressed.

---

## Test Coverage Analysis

The test file (`test/nft/OmniNFTLending.test.js`) contains 41 test cases covering:

- Deployment (5 tests)
- Create Offer (11 tests, including boundary values)
- Accept Offer (7 tests)
- Repay (8 tests, including zero-fee and post-liquidation)
- Liquidate (8 tests, including grace period boundaries)
- Cancel Offer (5 tests)
- Admin (5 tests)
- View Functions (7 tests)
- Integration (4 tests, including full lifecycle and concurrent loans)

**Coverage gaps identified:**

1. **No test for `liquidate()` via meta-transaction** -- would have caught H-01.
2. **No test for `claimNFT()`** -- the test file does not test the NFT claim fallback path (requires a mock NFT that reverts on transfer).
3. **No test for fee-on-transfer token rejection** -- no test verifies that `TransferAmountMismatch` is triggered.
4. **No test for `MAX_COLLECTIONS_PER_OFFER` boundary** -- no test attempts 50 or 51 collections.
5. **No test for `renounceOwnership()` being disabled** -- no test verifies the revert.
6. **No test for `setFeeVault()` zero-address rejection** -- no test verifies the `ZeroAddress` revert.
7. **No test for `LoanExpired` revert** -- no test attempts repayment after the grace period ends.

---

## Gas Optimization Notes

1. **`Loan` struct uses 9 storage slots.** The three address fields (`borrower`, `lender`, `currency`) each waste 12 bytes of padding. Packing `borrower` with smaller types (e.g., moving `platformFeeBps` next to `borrower`) could save 1 slot, but the current layout prioritizes readability. Acceptable trade-off for infrequent writes.

2. **`DAYS_PER_YEAR` is `uint256` constant.** Using `uint16` would save gas in the interest calculation's multiplication. However, Solidity automatically promotes to `uint256` for arithmetic, so the saving is marginal.

3. **Collections loop** uses `uint256 colLen = collections.length` with `++i` prefix increment. This is already optimized.

4. **Custom errors** are used throughout instead of `require()` strings. Gas-efficient.

5. **Events use `indexed`** on the first three parameters where appropriate. Gas-efficient for filtering.

---

## Conclusion

OmniNFTLending has maintained the strong security posture established in previous audit rounds. All previously identified High and Medium findings remain resolved. The contract demonstrates mature patterns including:

- Fee-on-transfer protection via strict balance checking
- Platform fee snapshotting to prevent retroactive changes
- NFT transfer resilience via try/catch with `claimNFT()` fallback
- Grace period design with clean cutoff preventing repay/liquidate race conditions
- Pro-rated annualized interest calculations
- `Ownable2Step` with disabled `renounceOwnership()`
- CEI pattern correctly followed in all state-changing functions
- `nonReentrant` guard on all externally-facing functions with external calls

**The single blocking issue is H-01:** `liquidate()` uses `msg.sender` instead of `_msgSender()`, which is a one-line fix. Once H-01 is resolved and tests are updated to cover the gaps identified above, this contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet Audit*
