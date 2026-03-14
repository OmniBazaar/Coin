# Security Audit Report: OmniFractionalNFT.sol + FractionToken (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Pre-Mainnet Final Review)
**Contracts:**
- `Coin/contracts/nft/OmniFractionalNFT.sol` (lines 102-746, main vault)
- `FractionToken` (lines 31-100, embedded ERC-20)
**Solidity Version:** 0.8.24 (locked)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 746
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes -- custodies ERC-721 NFTs, ERC-20 buyout deposits, ERC-20 creation fees
**Prior Audits:**
- Round 1 (2026-02-20): Initial comprehensive audit
- NFTSuite combined (2026-02-21): Cross-contract review
- Round 6 (2026-03-10): 0C/0H/3M/3L/3I -- Post-remediation deep dive

---

## Executive Summary

This Round 7 pre-mainnet final audit reviews OmniFractionalNFT.sol and its companion FractionToken after extensive remediation across six prior audit rounds. The contract implements a vault that locks ERC-721 NFTs, issues ERC-20 fraction tokens, supports full redemption by a 100% holder, and provides a buyout mechanism allowing qualified shareholders (holding at least 25%) to propose acquisition of the underlying NFT.

The contract has matured substantially. All Critical, High, and Medium findings from prior rounds have been properly remediated, including the critical FractionToken burn restriction (C-01/H-01), buyout timeout and cancellation (H-02), fee-on-transfer handling (H-03), proposer self-dealing prevention (H-04), per-vault refund accounting in `cancelBuyout()` (Round 6 M-01), and the `cancelBuyout()` boundary condition (Round 6 M-03).

However, this audit identifies one Medium-severity finding: the rounding dust sweep in `_processBuyoutSale()` still uses `balanceOf(address(this))` (the entire contract balance) rather than per-vault accounting, which is the same class of vulnerability that was fixed in `cancelBuyout()` during Round 6. Additionally, the `feeCurrency` state variable has no setter function, meaning creation fees cannot be enabled post-deployment.

**Remediation Status from Round 6:**

| Round 6 ID | Severity | Finding | Status |
|------------|----------|---------|--------|
| M-01 | Medium | `cancelBuyout()` refunds entire contract balance | **FIXED** -- Per-vault calculation using `sharesBurned` / `alreadyPaid` / `refundAmount` (lines 499-504) |
| M-02 | Medium | Creation fee denominated in share count, not NFT value | **ACCEPTED** -- NatSpec documentation added at line 274: "intentionally share-based... not a valuation mechanism" |
| M-03 | Medium | `_validateBuyoutNotExpired()` off-by-one boundary | **FIXED** -- `cancelBuyout()` now uses `<=` comparison (line 487): clean boundary, no gap |
| L-01 | Low | `fractionalize()` transfers NFT after state creation | **ACCEPTED** -- EVM atomicity protects; follows CEI pattern |
| L-02 | Low | Re-fractionalization overwrites `nftToVault` | **NOT FIXED** -- See L-02 below |
| L-03 | Low | No ERC-165 validation on `collection` parameter | **NOT FIXED** -- See L-03 below |
| I-01 | Info | No events on `setCreationFee()` | **NOT FIXED** -- See I-01 below |
| I-02 | Info | FractionToken inherits ERC20Burnable despite overriding all burns | **NOT FIXED** -- See I-02 below |
| I-03 | Info | `feeCurrency` not set in constructor, no setter exists | **NOT FIXED** -- See M-02 below |

**New Findings (Round 7):**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 4 |

**Overall Assessment: PRODUCTION READY with M-01 fix recommended before mainnet.**

---

## Solhint Analysis

```
contracts/nft/OmniFractionalNFT.sol
    2:1   warning  Found more than One contract per file. 2 contracts found!        one-contract-per-file
  487:13  warning  GC: Non strict inequality found. Try converting to a strict one  gas-strict-inequalities

2 problems (0 errors, 2 warnings)
```

**Assessment:**
- `one-contract-per-file` (line 2): Acceptable -- FractionToken is a minimal helper deployed by OmniFractionalNFT. Separating it would add deployment complexity without security benefit. The two contracts are tightly coupled by design.
- `gas-strict-inequalities` (line 487): The `<=` comparison in `cancelBuyout()` is semantically correct and was specifically chosen during Round 6 M-03 remediation. Changing to strict `<` would create a 1-second boundary gap. The warning is correctly suppressed by the business logic requirement.

**Verdict:** 0 errors, 2 warnings -- both justified and acceptable.

---

## Test Suite Results

```
66 passing (2s)
0 failing
```

Test coverage spans: deployment validation, fractionalization flow, redemption, buyout proposal, buyout execution, partial buyout, admin functions, view functions, and FractionToken security restrictions. All tests pass cleanly.

---

## Remediation Verification from All Prior Rounds

| ID | Severity | Title | Status | Verification |
|----|----------|-------|--------|--------------|
| C-01/H-01 | Critical/High | FractionToken unrestricted burn() locks NFTs | **RESOLVED** | `burn()` (line 83) and `burnFrom()` (line 96) both enforce `OnlyVault()`. `vaultBurn()` (line 70) provides allowance-free burn for vault. All three paths verified. |
| H-02 | High | No buyout cancellation/timeout | **RESOLVED** | `cancelBuyout()` (lines 477-518) with `BUYOUT_DEADLINE_DURATION = 30 days` (line 143). Only proposer can cancel, only after deadline. |
| H-03 | High | Fee-on-transfer buyout insolvency | **RESOLVED** | Balance-before/after pattern in `proposeBuyout()` (lines 425-434). `v.buyoutPrice = received` stores actual amount received. |
| H-04 | High | Proposer self-dealing squeezes minority | **RESOLVED** | `MIN_PROPOSER_SHARE_BPS = 2500` (line 145) enforced in `_validateProposerShares()` (lines 669-681). `ProposerCannotSellToSelf` check in `executeBuyout()` (line 461). |
| M-01 (R1) | Medium | Creation fee dead code | **RESOLVED** | Fee collection implemented in `fractionalize()` (lines 304-318) using `safeTransferFrom` to `feeVault`. |
| M-02 (R1) | Medium | Rounding dust permanently locked | **RESOLVED** | Last seller receives entire remaining balance (lines 624-630). |
| M-03 (R1) | Medium | burnFrom requires user approval (UX) | **RESOLVED** | `vaultBurn()` (line 70) burns without allowance. Used in `redeem()` (line 380) and `_processBuyoutSale()` (line 619). |
| M-04 (R1) | Medium | Vault ID 0 ambiguity | **RESOLVED** | `nextVaultId = 1` (line 158). `nftToVault` returning 0 now unambiguously means "not fractionalized". |
| M-01 (R6) | Medium | cancelBuyout refunds entire contract balance | **RESOLVED** | Per-vault calculation: `sharesBurned = v.totalShares - token.totalSupply()`, `alreadyPaid = (v.buyoutPrice * sharesBurned) / v.totalShares`, `refundAmount = v.buyoutPrice - alreadyPaid` (lines 500-504). |
| M-03 (R6) | Medium | Buyout boundary off-by-one | **RESOLVED** | `cancelBuyout()` uses `block.timestamp <= v.buyoutDeadline` (line 487). Clean boundary: at deadline, execute allowed and cancel blocked; at deadline+1, execute blocked and cancel allowed. |
| L-01 (R1) | Low | Missing zero-address checks | **RESOLVED** | Constructor validates `initialFeeVault` (line 264). `setFeeVault()` validates (line 538). |
| L-02 (R1) | Low | Single-step ownership | **RESOLVED** | Uses `Ownable2Step` (line 116). |
| L-03 (R1) | Low | executeBuyout allows sharesToSell = 0 | **RESOLVED** | `if (sharesToSell == 0) revert InvalidShareCount()` (line 456). |

---

## New Findings (Round 7)

### [M-01] `_processBuyoutSale()` Rounding Dust Sweep Uses Contract-Wide Balance

**Severity:** Medium
**Location:** `_processBuyoutSale()` lines 624-630
**Status:** NEW

**Description:**

When the last seller burns their shares (bringing `totalSupply` to zero), the rounding dust sweep assigns them the entire contract balance of the buyout currency:

```solidity
if (token.totalSupply() == 0) {
    uint256 remainingBalance =
        IERC20(v.buyoutCurrency).balanceOf(address(this));
    if (remainingBalance > payment) {
        payment = remainingBalance;
    }
}
```

This uses `balanceOf(address(this))` -- the entire contract balance for that ERC-20 token -- rather than the per-vault remaining buyout funds. This is the same class of vulnerability that was correctly fixed in `cancelBuyout()` during Round 6 (M-01), where per-vault accounting was introduced at lines 499-504.

**Exploit Scenario:**
1. Vault A has a buyout in USDC with 100 USDC deposited. Sellers claim 90 USDC pro-rata, leaving 10 USDC of dust.
2. Vault B also has a buyout in USDC with 500 USDC deposited.
3. The last seller in Vault A sells their final shares. `remainingBalance = IERC20(USDC).balanceOf(address(this))` = 510 USDC (10 from Vault A + 500 from Vault B).
4. Since 510 > the calculated pro-rata `payment`, `payment = 510`.
5. The last seller in Vault A receives 510 USDC, draining Vault B's buyout funds.

**Note:** This requires two concurrent buyouts using the same ERC-20 currency, and the rounding dust must exceed zero. In practice, with 18-decimal tokens, rounding dust is typically tiny (sub-wei amounts), but the vulnerability is real in principle and could be triggered by fee-on-transfer tokens or direct ERC-20 transfers to the contract.

**Recommendation:** Apply the same per-vault accounting used in `cancelBuyout()`:

```solidity
if (token.totalSupply() == 0) {
    // Calculate per-vault remaining funds (same method as cancelBuyout)
    uint256 sharesBurned = v.totalShares; // all shares burned at this point
    uint256 alreadyPaidBeforeThis =
        (v.buyoutPrice * (sharesBurned - sharesToSell)) / v.totalShares;
    uint256 vaultRemaining =
        v.buyoutPrice - alreadyPaidBeforeThis;
    if (vaultRemaining > payment) {
        payment = vaultRemaining;
    }
}
```

Or more simply, since totalSupply is zero (all shares burned), the remaining vault-specific funds are:

```solidity
if (token.totalSupply() == 0) {
    uint256 totalPaidBefore =
        (v.buyoutPrice * (v.totalShares - sharesToSell)) / v.totalShares;
    uint256 vaultRemaining = v.buyoutPrice - totalPaidBefore;
    if (vaultRemaining > payment) {
        payment = vaultRemaining;
    }
}
```

---

### [M-02] `feeCurrency` Has No Setter Function -- Creation Fees Permanently Disabled

**Severity:** Medium
**Location:** Storage variable `feeCurrency` (line 153), constructor (lines 258-268)
**Status:** Carried from Round 6 I-03, upgraded to Medium

**Description:**

The `feeCurrency` state variable is declared as `address public feeCurrency` (line 153) but is never initialized in the constructor and has no setter function. It defaults to `address(0)`. The creation fee logic in `fractionalize()` checks `feeCurrency != address(0)` at line 306 as a prerequisite for fee collection. Since `feeCurrency` can never be set to a non-zero value, creation fees are permanently disabled regardless of the `creationFeeBps` setting.

The contract provides `setCreationFee()` (line 526) and `setFeeVault()` (line 536) admin functions, but no `setFeeCurrency()`. This makes the creation fee mechanism dead code.

**Impact:** The platform cannot collect creation fees from NFT fractionalization, which is part of the intended revenue model. This is an operational impact (lost revenue), not a security vulnerability per se, but it renders an entire code path inoperative.

**Recommendation:** Add a `setFeeCurrency()` admin function:

```solidity
/// @notice Update the fee currency for creation fees.
/// @param newFeeCurrency New ERC-20 token address for creation fees.
function setFeeCurrency(address newFeeCurrency) external onlyOwner {
    feeCurrency = newFeeCurrency;
}
```

Or add `feeCurrency` as a constructor parameter. Note that `address(0)` should be permitted to allow disabling fees.

---

### [L-01] Re-Fractionalization Overwrites `nftToVault` Without Clearing Old Entry

**Severity:** Low
**Location:** `fractionalize()` line 344; `redeem()` lines 367-390; `_processBuyoutSale()` lines 639-650
**Status:** Carried from Round 6 L-02, unchanged

**Description:**

After an NFT is redeemed or bought out, the same NFT can be fractionalized again. The new fractionalization at line 344 overwrites `nftToVault[collection][tokenId]` with the new vault ID. The old vault data is still accessible by its vault ID, but `getVaultByNFT()` only returns the latest. Neither `redeem()` nor the buyout completion path clears the `nftToVault` entry.

While functionally correct (the old vault is inactive), this creates stale state that can confuse off-chain indexers tracking vault history through the `nftToVault` mapping.

**Recommendation:** Clear the mapping when a vault is deactivated:

```solidity
// In redeem(), after v.active = false:
delete nftToVault[v.collection][v.tokenId];

// In _processBuyoutSale(), after v.active = false:
delete nftToVault[v.collection][v.tokenId];
```

This saves a small amount of gas (storage refund) and keeps mappings clean.

---

### [L-02] Proposer Can Circumvent `ProposerCannotSellToSelf` Via Share Transfer

**Severity:** Low
**Location:** `executeBuyout()` line 461
**Status:** NEW

**Description:**

The `ProposerCannotSellToSelf` check at line 461 prevents the proposer address from calling `executeBuyout()` directly. However, the proposer can transfer their fraction tokens to another address they control (a "sock puppet") and call `executeBuyout()` from that address. This effectively lets the proposer reclaim a portion of their buyout deposit corresponding to their own shares.

**Economic Analysis:** This is not a fund-extraction vulnerability. The proposer deposited `buyoutPrice` to cover 100% of shares. If the proposer holds X% of shares and sells them via a proxy, they receive `buyoutPrice * X% / totalShares` back, and non-proposer holders still receive their full pro-rata share from the remaining funds. The math is correct because pro-rata is calculated against `totalShares` (the original total), not the current `totalSupply`. The proposer is simply recovering the portion of their deposit that corresponds to shares they already owned.

**Impact:** The `ProposerCannotSellToSelf` check provides a UX guard against accidental self-dealing but does not provide a cryptographic guarantee. This is acceptable because the economic outcome is equivalent whether the proposer's shares are burned for free (current intended path if the proposer holds them until buyout completes) or sold through a proxy (proposer recovers their pro-rata portion).

**Recommendation:** Document this behavior in NatSpec. The check is still valuable as a UX guard to prevent accidental self-payment. No code change required. If stronger prevention is desired, the proposer's shares could be locked or burned at proposal time, but this adds complexity and changes the economic model.

---

### [L-03] No ERC-165 Validation on `collection` Parameter

**Severity:** Low
**Location:** `fractionalize()` line 287
**Status:** Carried from Round 6 L-03, unchanged

**Description:**

The `collection` parameter in `fractionalize()` is not validated as an ERC-721 contract. If a non-ERC721 address is passed (e.g., an EOA or a contract without `safeTransferFrom`), the `IERC721(collection).safeTransferFrom()` call at line 347 will revert, which is safe. However, a malicious contract that implements `safeTransferFrom` without being a legitimate ERC-721 (e.g., returning success without actually custodying a unique token) could create a vault pointing to a fake NFT.

**Impact:** Low -- the fractionalized "NFT" would have no real value, and the attacker would only harm themselves. Other users would see the vault's `collection` address and could verify legitimacy off-chain.

**Recommendation:** Consider adding an ERC-165 `supportsInterface` check:

```solidity
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

if (!IERC165(collection).supportsInterface(type(IERC721).interfaceId)) {
    revert InvalidCollection();
}
```

Note that this does not prevent all malicious contracts (they can lie about ERC-165 support), but it catches common misconfiguration errors.

---

### [I-01] No Events Emitted by Admin Setter Functions

**Severity:** Informational
**Location:** `setCreationFee()` (lines 526-529), `setFeeVault()` (lines 536-539)
**Status:** Carried from Round 6 I-01, unchanged

**Description:**

Neither `setCreationFee()` nor `setFeeVault()` emit events when storage is modified. Off-chain indexers and monitoring dashboards cannot track fee parameter changes without scanning storage diffs.

**Recommendation:** Add events:

```solidity
event CreationFeeUpdated(uint16 indexed oldFee, uint16 indexed newFee);
event FeeVaultUpdated(address indexed oldVault, address indexed newVault);
```

---

### [I-02] FractionToken Inherits ERC20Burnable Despite Overriding All Public Burns

**Severity:** Informational
**Location:** `FractionToken` line 31
**Status:** Carried from Round 6 I-02, unchanged

**Description:**

`FractionToken` inherits `ERC20Burnable` but overrides both `burn()` (line 83) and `burnFrom()` (line 96) with `OnlyVault()` guards. The `vaultBurn()` function (line 70) calls `_burn()` directly from the base `ERC20`. The `ERC20Burnable` inheritance provides no unrestricted functionality -- all its public methods are locked down.

**Impact:** Slightly higher deployment gas due to the unused inheritance. No security impact since all burn paths are properly guarded.

**Recommendation:** Consider removing `ERC20Burnable` inheritance and implementing burn functions directly. This would make the security model clearer (no inherited burn paths to worry about) and save deployment gas:

```solidity
contract FractionToken is ERC20 {
    // ... vaultBurn() and burn()/burnFrom() overrides remain the same
}
```

---

### [I-03] `getVault()` Does Not Return Buyout Fields

**Severity:** Informational
**Location:** `getVault()` lines 555-578
**Status:** NEW

**Description:**

The `getVault()` view function returns 7 of 11 Vault struct fields: `owner`, `collection`, `tokenId`, `fractionToken`, `totalShares`, `active`, `boughtOut`. It omits: `buyoutProposer`, `buyoutPrice`, `buyoutCurrency`, `buyoutDeadline`.

The buyout fields are accessible via the auto-generated `vaults(uint256)` getter from the public mapping (line 160), so no data is inaccessible. However, the `getVault()` function presents itself as a comprehensive view but silently omits buyout state, which can mislead integrators.

**Recommendation:** Either extend `getVault()` to return all 11 fields, or add a separate `getBuyoutState(uint256 vaultId)` view function, or add NatSpec noting that buyout fields must be queried separately via the `vaults` mapping.

---

### [I-04] Duplicate `totalSupply() == 0` Check in `_processBuyoutSale()`

**Severity:** Informational
**Location:** `_processBuyoutSale()` lines 624 and 639
**Status:** NEW

**Description:**

The `_processBuyoutSale()` function checks `token.totalSupply() == 0` twice:
1. Line 624: To trigger the rounding dust sweep.
2. Line 639: To trigger NFT transfer and vault deactivation.

Between these two checks, `IERC20(v.buyoutCurrency).safeTransfer()` is called (line 633), which is an external call. Due to `nonReentrant`, this cannot be exploited. However, the dual check is redundant and costs extra gas (two external calls to `totalSupply()`).

**Recommendation:** Cache the result in a local variable:

```solidity
bool isLastSeller = (token.totalSupply() == 0);
if (isLastSeller) {
    // rounding dust sweep
}
IERC20(v.buyoutCurrency).safeTransfer(caller, payment);
if (isLastSeller) {
    // NFT transfer and vault deactivation
}
```

---

## Reentrancy Analysis

**Status: ADEQUATELY PROTECTED**

| Function | Guard | External Calls | Verdict |
|----------|-------|----------------|---------|
| `fractionalize()` | `nonReentrant` | `safeTransferFrom(IERC20)` fee, `new FractionToken()`, `safeTransferFrom(IERC721)` lock | SAFE |
| `redeem()` | `nonReentrant` | `vaultBurn()` on FractionToken, `safeTransferFrom(IERC721)` unlock | SAFE |
| `proposeBuyout()` | `nonReentrant` | `balanceOf(IERC20)` x2, `safeTransferFrom(IERC20)` deposit | SAFE |
| `executeBuyout()` | `nonReentrant` | Delegates to `_processBuyoutSale()` | SAFE |
| `_processBuyoutSale()` | via parent `nonReentrant` | `vaultBurn()`, `totalSupply()`, `balanceOf(IERC20)`, `safeTransfer(IERC20)`, optionally `safeTransferFrom(IERC721)` | SAFE |
| `cancelBuyout()` | `nonReentrant` | `totalSupply()`, `safeTransfer(IERC20)` refund | SAFE |

All external-facing state-changing functions have `nonReentrant`. The `ERC721Holder.onERC721Received()` callback from `safeTransferFrom` calls cannot re-enter due to the guard.

**CEI Compliance:**
- `redeem()`: State change (`v.active = false`) before burn and NFT transfer -- **compliant**.
- `_processBuyoutSale()`: Burns tokens before payment transfer -- **compliant**. State changes (`v.active = false`, `v.boughtOut = true`) happen after payment but are protected by `nonReentrant`.
- `cancelBuyout()`: State reset (lines 507-510) before refund transfer (line 514) -- **compliant**.
- `proposeBuyout()`: State writes (lines 418-434) interleave with `safeTransferFrom` for the balance-before/after pattern -- **acceptable** because `nonReentrant` prevents re-entry.

---

## Access Control Analysis

**Roles and Permissions:**

| Role | Mechanism | Capabilities |
|------|-----------|-------------|
| **Owner** | `Ownable2Step` (2-step transfer) | `setCreationFee()`, `setFeeVault()` |
| **Vault (per FractionToken)** | `immutable VAULT` in FractionToken | `vaultBurn()`, `burn()`, `burnFrom()` on that specific FractionToken |
| **Any User** | No restriction | `fractionalize()`, `redeem()`, `proposeBuyout()`, `executeBuyout()` |
| **Buyout Proposer** | `v.buyoutProposer` state | `cancelBuyout()` (only after deadline) |

**Analysis:**
- Owner cannot drain funds, modify vault state, or interfere with active buyouts. Owner power is limited to fee configuration.
- `Ownable2Step` prevents accidental ownership transfer (requires `acceptOwnership()` from the new owner).
- FractionToken's `VAULT` is immutable and set at deployment, preventing reassignment.
- No `renounceOwnership()` override -- the inherited `Ownable2Step.renounceOwnership()` can permanently disable admin functions. This is acceptable for this contract since the only admin functions control fee parameters.

---

## Flash Loan Attack Analysis

**Potential Vector:** Flash-borrow fraction tokens to meet the 25% `MIN_PROPOSER_SHARE_BPS` threshold, then propose a buyout.

**Assessment:** Not viable because:
1. `proposeBuyout()` requires depositing real `totalPrice` capital that cannot be repaid in the same transaction.
2. The buyout has a 30-day deadline; the flash-borrowed fraction tokens must be returned in the same transaction, but the buyout position persists.
3. After the flash loan is repaid, the proposer no longer holds 25% of shares, but the buyout is already active. However, other holders are not forced to sell -- they can simply wait for the 30-day deadline to expire, at which point the proposer can only recover their deposit via `cancelBuyout()`.

**Conclusion:** Flash loan attacks are economically non-viable. The real capital commitment requirement is the primary defense.

---

## Buyout Mechanism Security Analysis

The buyout mechanism is well-hardened after seven audit rounds:

1. **Proposer qualification:** Minimum 25% share holding (line 145, enforced at lines 669-681).
2. **Self-dealing prevention:** Proposer cannot call `executeBuyout()` directly (line 461). Proxy circumvention analyzed in L-02 and found to be economically neutral.
3. **Timeout protection:** 30-day deadline (line 143) with `cancelBuyout()` (lines 477-518) for expired proposals.
4. **Rounding protection:** Last seller receives remaining vault balance (lines 624-630). Zero-payment guard (line 616).
5. **Fee-on-transfer handling:** Balance-before/after in `proposeBuyout()` (lines 425-434) stores actual received amount.
6. **Per-vault refund accounting:** `cancelBuyout()` calculates refund from vault-specific data (lines 500-504), not contract-wide balance.
7. **Boundary condition:** Clean `executeBuyout` / `cancelBuyout` boundary at `buyoutDeadline` with no gap and no overlap.

**Remaining concern:** The rounding dust sweep in `_processBuyoutSale()` (M-01 above) still uses `balanceOf(address(this))`, which should be converted to per-vault accounting for consistency with `cancelBuyout()`.

---

## ERC-2771 Meta-Transaction Analysis

The contract inherits `ERC2771Context` and overrides `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` (lines 706-745). All user-facing functions use `_msgSender()` instead of `msg.sender`.

**Trusted Forwarder:** Set at deployment via the `trustedForwarder_` constructor parameter. Immutable (cannot be changed post-deployment per OpenZeppelin's `ERC2771Context` design).

**Risk Assessment:**
- If `trustedForwarder_` is `address(0)` (as in test deployments), meta-transactions are effectively disabled. `ERC2771Context._msgSender()` returns `msg.sender` when the caller is not the trusted forwarder.
- If a malicious forwarder is set, it could spoof `_msgSender()` for all functions. Since the forwarder is immutable and set at deployment, this is only a risk if the deployer configures a malicious or compromised forwarder.
- The FractionToken does NOT inherit `ERC2771Context` -- it uses raw `msg.sender` for the `OnlyVault()` check. This is correct since the vault contract's address should always be the direct caller.

**Verdict:** Safe, assuming a trusted forwarder is deployed correctly or `address(0)` is used to disable meta-transactions.

---

## Gas Optimization Notes

These are informational observations, not findings:

1. **Struct packing:** The `Vault` struct uses 4 address fields (20 bytes each), 2 uint256 fields (32 bytes each), and 2 bool fields (1 byte each). The booleans `active` and `boughtOut` could be packed with an address in the same slot by reordering fields, saving ~1 storage slot per vault. Current ordering is readable but not gas-optimal.

2. **Duplicate totalSupply() calls:** As noted in I-04, `_processBuyoutSale()` reads `totalSupply()` twice. Caching would save one external call.

3. **FractionToken deployment:** Each `fractionalize()` deploys a new contract via `new FractionToken(...)`. Using `Clones` (ERC-1167 minimal proxy) would reduce deployment gas from ~800k to ~50k per fractionalization. This is a significant saving for a production system with many fractionalizations.

---

## Conclusion

OmniFractionalNFT has matured through seven audit rounds into a well-structured and defensively coded vault contract. All Critical and High findings from prior rounds are fully resolved. The FractionToken burn restriction, buyout deadline/cancellation mechanism, fee-on-transfer handling, and proposer qualification are all properly implemented.

**One Medium finding (M-01) should be addressed before mainnet:** The rounding dust sweep in `_processBuyoutSale()` uses `balanceOf(address(this))` instead of per-vault accounting, creating a potential cross-vault fund drain when multiple buyouts use the same ERC-20 currency. This is the same class of vulnerability that was correctly fixed in `cancelBuyout()` during Round 6, and the fix should be applied consistently.

**One Medium finding (M-02) is operational:** The missing `setFeeCurrency()` function means creation fees cannot be enabled. If creation fees are intended for mainnet, a setter must be added.

With M-01 fixed, the contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet Final Audit (2026-03-13 21:00 UTC)*
