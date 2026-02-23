# Security Audit Report: OmniFractionalNFT + FractionToken

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contracts:** `contracts/nft/OmniFractionalNFT.sol` (369 lines) + `contracts/nft/FractionToken.sol` (41 lines)
**Solidity Version:** ^0.8.24
**Lines of Code:** 410
**Upgradeable:** No
**Handles Funds:** Yes (NFTs + ERC-20 buyout deposits)

## Executive Summary

OmniFractionalNFT is a vault that locks ERC-721 NFTs and issues ERC-20 fraction tokens, with a buyout mechanism allowing share-holders to sell their fractions for pro-rata payment. The audit identified **4 High-severity findings** centered on the buyout mechanism: unrestricted token burning that breaks redemption invariants, permanent fund lockup from missing buyout cancellation, fee-on-transfer token insolvency, and proposer self-dealing that squeezes minority shareholders. No Critical findings were identified. The creation fee system is fully declared but never collected (dead code). Centralization risk is very low (2/10) — the owner can only adjust fee parameters, not access locked funds.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 4 |
| Medium | 4 |
| Low | 4 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 111 |
| Passed | 80 |
| Failed | 18 |
| Partial | 13 |
| **Compliance Score** | **72.1%** |

Top 5 failed checks:
1. **SOL-Basics-AC-2** — Unrestricted `burn()` on FractionToken desynchronizes vault state
2. **SOL-Heuristics-16** — No buyout cancellation; asymmetric fund lock
3. **SOL-Token-FE-6** — Fee-on-transfer tokens cause insolvency in buyout
4. **SOL-AM-DOSA-3** — Blacklistable tokens can permanently lock buyout funds
5. **SOL-Basics-Function-4** — NatSpec promises "1% creation fee" that is never collected

---

## High Findings

### [H-01] Unrestricted FractionToken.burn() breaks redeem and enables buyout fund lock

**Severity:** High
**Category:** SC02 (Business Logic) + SC01 (Access Control)
**VP Reference:** VP-06 (Missing Access Control)
**Location:** `FractionToken.sol` line 15 (inherits `ERC20Burnable`); `OmniFractionalNFT.sol` lines 206, 277, 286
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin (SOL-Basics-AC-2), Solodit (Fractional v2 H-09/H-11, arXiv 2409.08190)
**Real-World Precedent:** Fractional v2 (Code4rena 2022-07) — 20 High-severity findings; SafeMoon ($8.9M) — unprotected burn

**Description:**
`FractionToken` inherits `ERC20Burnable` which exposes a public `burn(uint256)` function callable by any token holder. This allows shares to be destroyed independently of the vault's `redeem()` and `executeBuyout()` workflows. When shares are burned externally:

1. `totalSupply()` decreases but `v.totalShares` remains unchanged
2. `redeem()` checks `balance < v.totalShares` — if any shares are burned, no one can ever accumulate `totalShares` tokens, permanently locking the NFT
3. In `executeBuyout()`, external burns can trigger `totalSupply() == 0` prematurely, transferring the NFT to the proposer while unclaimed buyout payments remain locked in the contract

The `OnlyVault()` error is declared in `FractionToken` (line 20) but is never used — suggesting vault-restricted burning was intended but never implemented.

**Exploit Scenario:**
1. NFT fractionalized into 1000 shares. Alice has 999, Bob has 1
2. Bob calls `FractionToken.burn(1)` directly
3. Only 999 shares exist but `v.totalShares` is still 1000
4. Alice can never call `redeem()` (she can never hold 1000 shares)
5. In a buyout scenario: if buyout is active and all remaining holders sell via `executeBuyout()`, when `totalSupply()` hits 0, the burned share's pro-rata payment remains permanently locked

**Recommendation:**
Override `burn()` and `burnFrom()` in `FractionToken` to restrict to the vault:
```solidity
function burn(uint256 amount) public override {
    if (msg.sender != vault) revert OnlyVault();
    super.burn(amount);
}
function burnFrom(address account, uint256 amount) public override {
    if (msg.sender != vault) revert OnlyVault();
    super.burnFrom(account, amount);
}
```
Additionally, consider using `totalSupply()` instead of `v.totalShares` in `redeem()` as defense-in-depth.

---

### [H-02] No buyout cancellation or timeout — proposer funds permanently locked

**Severity:** High
**Category:** SC02 (Business Logic)
**VP Reference:** VP-30 (DoS via State Lock), VP-34 (Logic Error)
**Location:** `proposeBuyout()` lines 231-254; missing `cancelBuyout()` function
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin (SOL-Heuristics-16), Solodit (Fractional v2 H-02/H-07/H-14, Tessera H-06)
**Real-World Precedent:** Fractional v2 (Code4rena 2022-07) — 5+ findings in "buyout fund lockup" category; Tessera (Code4rena 2022-12) — H-06 permanently stuck funds

**Description:**
Once `proposeBuyout()` is called, the proposer's ERC-20 deposit is locked in the contract with no escape mechanism:
- No `cancelBuyout()` function exists
- No timeout or expiry on the buyout proposal
- No way to modify the buyout terms
- `BuyoutAlreadyActive` check (line 239) blocks any new proposals

If shareholders choose not to sell (or if share tokens are lost/burned), the proposer's funds are permanently locked. A single stale proposal permanently blocks the entire buyout mechanism.

**Exploit Scenario:**
1. User deposits 100 ETH worth of tokens via `proposeBuyout()`
2. All shareholders refuse to sell at that price
3. User's 100 ETH is locked forever — no cancel, no timeout, no admin recovery
4. No one else can propose a better buyout either

**Recommendation:**
Add a buyout deadline and cancellation mechanism:
```solidity
// Add to Vault struct:
uint256 buyoutDeadline;

// In proposeBuyout():
v.buyoutDeadline = block.timestamp + 7 days;

// New function:
function cancelBuyout(uint256 vaultId) external nonReentrant {
    Vault storage v = vaults[vaultId];
    if (v.buyoutProposer != msg.sender) revert NotProposer();
    if (block.timestamp <= v.buyoutDeadline) revert BuyoutStillActive();
    uint256 remaining = IERC20(v.buyoutCurrency).balanceOf(address(this));
    v.buyoutProposer = address(0);
    v.buyoutPrice = 0;
    IERC20(v.buyoutCurrency).safeTransfer(msg.sender, remaining);
}
```

---

### [H-03] Fee-on-transfer tokens cause buyout insolvency

**Severity:** High
**Category:** SC06 (Unchecked External Calls)
**VP Reference:** VP-46 (Fee-on-Transfer Token)
**Location:** `proposeBuyout()` lines 243-251; `executeBuyout()` line 277
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-Token-FE-6), Solodit (Notional Finance — exact match)
**Real-World Precedent:** Notional Finance (Sherlock 2023-12 #58) — vault insolvency from nominal vs actual amount; ZABU Finance ($0 quantified); SafeDollar ($200K)

**Description:**
`proposeBuyout()` records `v.buyoutPrice = totalPrice` (line 243) before pulling tokens via `safeTransferFrom` (line 247). For fee-on-transfer tokens, the contract receives less than `totalPrice`. However, `executeBuyout()` calculates payments based on the full `buyoutPrice`, distributing more than actually held. The last shareholder(s) face a revert — their shares are not burned, the NFT is stuck, and the buyout can never complete.

**Exploit Scenario:**
1. Buyout proposed with 100 tokens of a 2% fee-on-transfer token
2. Contract receives 98 tokens but records `buyoutPrice = 100`
3. First holder sells 50% of shares: receives 50 tokens. Contract balance: 48
4. Second holder tries to sell remaining 50%: `safeTransfer(msg.sender, 50)` reverts (only 48 available)
5. NFT permanently stuck — second holder can never sell, buyout never completes

**Recommendation:**
Use balance-before/after pattern:
```solidity
uint256 balBefore = IERC20(currency).balanceOf(address(this));
IERC20(currency).safeTransferFrom(msg.sender, address(this), totalPrice);
uint256 received = IERC20(currency).balanceOf(address(this)) - balBefore;
v.buyoutPrice = received;
```

---

### [H-04] Proposer self-dealing squeezes minority shareholders

**Severity:** High
**Category:** SC02 (Business Logic)
**VP Reference:** VP-34 (Front-Running / Transaction Ordering)
**Location:** `proposeBuyout()` lines 231-254; `executeBuyout()` lines 263-298
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-Heuristics-3), Solodit (Fractional v2 H-04/H-05/H-08, PartyDAO)
**Real-World Precedent:** Fractional v2 (Code4rena 2022-07) — H-04 "Division rounding makes fraction-price zero, Eve got Bob's fractions for 0"; PartyDAO (Code4rena 2022-09) — majority extraction at minority expense

**Description:**
Nothing prevents the buyout proposer from also being a shareholder. The proposer can exploit this to acquire the NFT at near-zero effective cost:

1. Proposer holds 900 of 1000 shares, minority holder has 100
2. Proposer calls `proposeBuyout(vaultId, 10, currency)` — offers only 10 tokens total
3. Proposer calls `executeBuyout(vaultId, 900)` — receives `(10 * 900) / 1000 = 9` tokens back
4. Minority holder can sell 100 shares for `(10 * 100) / 1000 = 1` token — far below fair value
5. Net cost to proposer: 1 token for the entire NFT

With very low `totalPrice`, integer division can round minority payments to zero: `(1 * 100) / 1000 = 0`. The minority holder burns their shares for nothing.

**Recommendation:**
- Require a minimum buyout price per share or minimum total price
- Add a shareholder voting/acceptance mechanism with a time-delay
- Exclude the proposer's own shares from the buyout (only allow buying from other holders):
```solidity
if (msg.sender == v.buyoutProposer) revert ProposerCannotSellToSelf();
```

---

## Medium Findings

### [M-01] Creation fee declared but never collected (dead code)

**Severity:** Medium
**Category:** SC02 (Business Logic)
**VP Reference:** VP-34 (Logic Error)
**Location:** `creationFeeBps` line 105, `feeRecipient` line 107, `feeCurrency` line 109, `setCreationFee()` line 306, `setFeeRecipient()` line 315, `fractionalize()` lines 143-193
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin (SOL-Basics-Function-4)

**Description:**
The contract NatSpec (line 22) states: "1% creation fee sent to the platform fee recipient." Three storage variables (`creationFeeBps`, `feeRecipient`, `feeCurrency`), validation logic in the constructor, and two admin setter functions exist for fee management. However, `fractionalize()` never reads any of these variables. No fee is ever collected or transferred. This is dead code that:
- Wastes ~60,000 gas on deployment for unused storage slots
- Misleads integrators and governance about actual fee behavior
- Does not conform to OmniBazaar's 70/20/10 fee distribution model

**Recommendation:**
Either implement fee collection in `fractionalize()` (with proper 70/20/10 split), or remove all fee-related state variables, constants, and setter functions.

---

### [M-02] Rounding dust in pro-rata payment — zero payment for small shares

**Severity:** Medium
**Category:** SC07 (Arithmetic)
**VP Reference:** VP-13 (Precision Loss), VP-15 (Rounding Exploitation)
**Location:** `executeBuyout()` line 277
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-Basics-Math-4/5), Solodit (Fractional v2 H-04 — exact match)
**Real-World Precedent:** Fractional v2 (Code4rena 2022-07) Issue #310 — identical calculation, "fractions sold for free"

**Description:**
`payment = (v.buyoutPrice * sharesToSell) / v.totalShares` rounds down. If `sharesToSell` is small enough: `(999 * 1) / 1000 = 0`. The holder burns their share and receives nothing. Additionally, cumulative rounding across many small `executeBuyout()` calls leaves dust permanently locked — no sweep or recovery function exists.

**Recommendation:**
1. Add `if (payment == 0) revert PaymentTooSmall();`
2. For the last holder (when `totalSupply() == sharesToSell` after burn), pay the entire remaining contract balance instead of the calculated amount:
```solidity
if (token.totalSupply() == sharesToSell) {
    payment = IERC20(v.buyoutCurrency).balanceOf(address(this));
} else {
    payment = (v.buyoutPrice * sharesToSell) / v.totalShares;
    if (payment == 0) revert PaymentTooSmall();
}
```

---

### [M-03] burnFrom requires manual user approval — undocumented UX friction

**Severity:** Medium
**Category:** SC05 (Input Validation) — UX
**VP Reference:** N/A
**Location:** `redeem()` line 211, `executeBuyout()` line 280
**Sources:** Agent-B, Agent-C, Solodit (Pieces Protocol H-3, arXiv paper)

**Description:**
Both `redeem()` and `executeBuyout()` call `token.burnFrom(msg.sender, amount)`, which requires the caller to have previously called `fractionToken.approve(vaultAddress, amount)`. This two-transaction pattern is:
- Not documented in the NatSpec for either function
- Unintuitive since the vault deployed the FractionToken
- Causes unexpected `ERC20InsufficientAllowance` reverts for users

The `vault` immutable and `OnlyVault()` error in FractionToken suggest vault-authorized burning was intended but never implemented.

**Recommendation:**
Add a vault-authorized burn function to FractionToken that skips the allowance check:
```solidity
function vaultBurn(address account, uint256 amount) external {
    if (msg.sender != vault) revert OnlyVault();
    _burn(account, amount);
}
```
Then use `token.vaultBurn()` instead of `token.burnFrom()` in `redeem()` and `executeBuyout()`. This also resolves H-01 (restricting burn to vault-only).

---

### [M-04] Vault ID 0 ambiguity with default mapping values

**Severity:** Medium
**Category:** SC02 (Business Logic)
**VP Reference:** VP-34 (Logic Error)
**Location:** `nextVaultId` line 111, `nftToVault` line 115, `getVaultByNFT()` lines 363-368
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-Heuristics-11)

**Description:**
`nextVaultId` starts at 0. The first vault gets `vaultId = 0`. The `nftToVault` mapping returns 0 for any unmapped entry. `getVaultByNFT()` returns 0 for both "this NFT is in vault 0" and "this NFT was never fractionalized." The NatSpec acknowledges this (line 362: "0 if not fractionalized") but the ambiguity prevents off-chain and on-chain consumers from making reliable lookups.

**Recommendation:**
Start `nextVaultId` at 1:
```solidity
uint256 public nextVaultId = 1;
```

---

## Low Findings

### [L-01] Missing zero-address checks on feeRecipient, currency, collection

**Severity:** Low
**VP Reference:** VP-22
**Location:** Constructor line 128, `setFeeRecipient()` line 315, `proposeBuyout()` line 234, `fractionalize()` line 143
**Sources:** Agent-A, Agent-C, Agent-D, Cyfrin (SOL-Basics-Function-1)

**Description:**
Multiple parameters lack zero-address validation: `initialFeeRecipient` in constructor, `newRecipient` in `setFeeRecipient()`, `currency` in `proposeBuyout()`, and `collection` in `fractionalize()`. Most are self-protecting (calls to `address(0)` revert), but the lack of explicit checks provides confusing error messages.

**Recommendation:** Add `if (addr == address(0)) revert InvalidAddress();` checks.

---

### [L-02] Single-step ownership transfer (Ownable not Ownable2Step)

**Severity:** Low
**VP Reference:** N/A
**Location:** Line 24, constructor line 126
**Sources:** Agent-C, Cyfrin (SOL-Basics-AC-4)

**Description:** Uses `Ownable` instead of `Ownable2Step`. A typo in `transferOwnership()` permanently loses admin access. Impact is low since the owner role is limited to fee management.

**Recommendation:** Replace `Ownable` with `Ownable2Step`.

---

### [L-03] executeBuyout allows sharesToSell = 0

**Severity:** Low
**VP Reference:** VP-23
**Location:** `executeBuyout()` line 263
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-Basics-Function-5)

**Description:** `executeBuyout(vaultId, 0)` burns 0 tokens, pays 0, wastes gas. No state change occurs.

**Recommendation:** Add `if (sharesToSell == 0) revert InvalidShareCount();`

---

### [L-04] Re-fractionalization overwrites nftToVault mapping

**Severity:** Low
**VP Reference:** VP-34
**Location:** `fractionalize()` line 176
**Sources:** Agent-A, Agent-B, Agent-D

**Description:** After redemption, the same NFT can be fractionalized again, silently overwriting `nftToVault` with the new vault ID. Old vault data becomes unreachable via the lookup mapping.

**Recommendation:** Clear `nftToVault` in `redeem()` and `executeBuyout()`, or check for active vaults before allowing re-fractionalization.

---

## Informational Findings

### [I-01] Floating pragma ^0.8.24

**Location:** Both files, line 2
Lock to `pragma solidity 0.8.24;` for production.

### [I-02] feeCurrency and OnlyVault error declared but unused

**Location:** `OmniFractionalNFT.sol` line 109; `FractionToken.sol` lines 17, 20
Dead code. Remove or implement.

### [I-03] No pause mechanism

**Location:** Contract-wide
No way to halt operations during an active exploit. Consider adding `Pausable` on `fractionalize()` and `proposeBuyout()`, keeping `redeem()` unpausable.

### [I-04] No admin events on setCreationFee and setFeeRecipient

**Location:** Lines 306, 315
Admin parameter changes are not logged. Add `CreationFeeUpdated` and `FeeRecipientUpdated` events.

---

## Known Exploit Cross-Reference

| Exploit / Audit | Date | Loss / Findings | Relevance |
|-----------------|------|-----------------|-----------|
| Fractional v2 (Code4rena) | 2022-07 | 20 High, 12 Medium | **Direct comparable** — same contract pattern (NFT vault + fraction tokens + buyout). H-04 (rounding to zero), H-09 (asset burn locks NFT), H-14 (buyout fund lockup) directly match H-01, H-02, M-02 |
| Tessera (Code4rena) | 2022-12 | H-06 permanent fund lock | Buyout funds stuck from verification failures — matches H-02 |
| Notional Finance (Sherlock) | 2023-12 | Issue #58 insolvency | Exact structural match for H-03 (fee-on-transfer nominal vs actual) |
| SafeMoon | 2023 | $8.9M | Unprotected burn function — matches H-01 |
| PartyDAO (Code4rena) | 2022-09 | Majority extraction | Majority holder squeezes minority — matches H-04 |
| arXiv 2409.08190 | 2024 | Security analysis | Recommends `onlyVault` modifiers on all FractionToken mutations |

## Solodit Similar Findings

- **Fractional v2 H-04** — "Division rounding can make fraction-price lower than intended (down to zero)" — exact match for M-02
- **Fractional v2 H-02/H-07** — Forced/perpetual buyout states with no exit — matches H-02
- **Fractional v2 H-09/H-11** — Asset destruction + precision loss locking NFTs — matches H-01
- **Notional Finance #58** — Fee-on-transfer vault insolvency — exact match for H-03
- **Pieces Protocol H-3** — burnFrom failure in claimNft — same attack surface as M-03
- **Virtuals Protocol #05** — Fee-induced reserve inconsistency — same pattern as H-03

Confidence assessment: All High findings corroborated at 90-98% confidence by real-world audit precedent.

## Static Analysis Summary

### Slither
Skipped — full-project analysis exceeds timeout. Known limitation.

### Aderyn
Skipped — v0.6.8 incompatible with solc v0.8.33. Known limitation.

### Solhint
0 errors, 5 warnings:
- Event ordering (OmniFractionalNFT line 53)
- `totalPrice` could be indexed (line 71)
- Non-strict inequality (line 150)
- Increment optimization (line 152)
- Immutable naming convention (FractionToken line 17)

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (Ownable) | `setCreationFee()`, `setFeeRecipient()`, `transferOwnership()`, `renounceOwnership()` | 2/10 |
| Any caller | `fractionalize()`, `redeem()`, `proposeBuyout()`, `executeBuyout()` | N/A (permissionless, gated by token/NFT ownership) |

## Centralization Risk Assessment

**Single-key maximum damage:** Owner can change `creationFeeBps` (up to 5%) and `feeRecipient` — but since fees are **never collected** (M-01), these have zero effect. Owner **cannot** access locked NFTs, cannot withdraw buyout funds, cannot mint fraction tokens, cannot interfere with active vaults.

**Centralization Score: 2/10** — Minimal admin privilege. The owner role is strictly cosmetic in the current implementation.

**Recommendation:** No additional protections needed for owner role given current scope. If fee collection is implemented, add timelock on fee changes.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Cross-referenced against: Fractional v2 (Code4rena 2022-07), Tessera (2022-12), Notional Finance (Sherlock 2023-12), arXiv 2409.08190*
