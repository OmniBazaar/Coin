# Security Audit Report: NFT Contract Suite

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contracts:**
- `Coin/contracts/nft/OmniNFTCollection.sol` (345 lines)
- `Coin/contracts/nft/OmniNFTFactory.sol` (134 lines)
- `Coin/contracts/nft/OmniNFTRoyalty.sol` (176 lines)
- `Coin/contracts/nft/OmniNFTLending.sol` (460 lines)
- `Coin/contracts/nft/FractionToken.sol` (41 lines)
- `Coin/contracts/nft/OmniFractionalNFT.sol` (369 lines)
- `Coin/contracts/nft/OmniNFTStaking.sol` (532 lines)
**Solidity Version:** ^0.8.24
**Upgradeable:** OmniNFTCollection uses ERC-1167 clones; others are standard
**Handles Funds:** Yes (lending holds loan collateral, staking holds NFTs + rewards, fractional holds buyout deposits)

## Executive Summary

The NFT suite provides collection deployment, royalty management, NFT-backed lending, fractional ownership, and staking rewards. Overall the contracts are well-structured with good use of OpenZeppelin's ReentrancyGuard, SafeERC20, and ERC721Holder. However, the audit found **2 Critical vulnerabilities**: (1) FractionToken's unrestricted `burn()` from ERC20Burnable permanently locks NFTs by breaking the total supply = 100% ownership invariant; and (2) fee-on-transfer token accounting mismatches in lending that cause DoS or fund loss. Additionally, **5 High-severity issues** were found including interest rate miscalculation, buyout mechanism abuse, royalty registration front-running, and locked staking rewards with no creator withdrawal.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 5 |
| Medium | 7 |
| Low | 3 |
| Informational | 1 |

## Findings

### [C-01] FractionToken Unrestricted burn() Permanently Locks NFTs

**Severity:** Critical
**Lines:** FractionToken 15 (inherits ERC20Burnable), OmniFractionalNFT 206, 280, 286
**Agents:** Both

**Description:**

FractionToken inherits `ERC20Burnable` which makes `burn()` publicly callable by any token holder. This breaks the fundamental invariant that fraction token totalSupply represents 100% ownership of the locked NFT:

1. `totalSupply()` decreases but `v.totalShares` in the vault is unchanged
2. `redeem()` requires `balance >= v.totalShares` — permanently impossible after any burn
3. The NFT is permanently locked with no recovery path
4. During a buyout, burned shares' pro-rata payment is permanently locked in the contract

The `OnlyVault()` error and `vault` immutable in FractionToken prove vault-restricted burning was the design intent but was never implemented.

**Impact:** Any fraction holder (even holding 1 token) can grief the entire vault by burning, permanently locking the NFT and any buyout funds.

**Recommendation:** Override `burn()` and `burnFrom()` in FractionToken to restrict to vault only:
```solidity
function burn(uint256) public pure override { revert OnlyVault(); }
function burnFrom(address, uint256) public pure override { revert OnlyVault(); }
```
Add a vault-only internal burn function for legitimate buyout/redeem operations.

---

### [C-02] Fee-on-Transfer Token Accounting Breaks Lending

**Severity:** Critical
**Lines:** OmniNFTLending 211 (createOffer), 267 (acceptOffer), 284-299 (repay)
**Agents:** Both

**Description:**

The lending contract records `offer.principal` as the nominal amount. For fee-on-transfer tokens:
1. Lender deposits 1000 tokens → contract receives 980 (2% fee)
2. Borrower accepts → contract sends `offer.principal` (1000) but only has 980 → **revert**
3. If somehow funded, repayment math assumes exact amounts, creating permanent accounting deficits

The same pattern affects OmniNFTStaking (`createPool` records nominal `totalReward`) and OmniFractionalNFT (`proposeBuyout` records nominal `totalPrice`).

**Impact:** Lending with fee-on-transfer tokens is completely broken (DoS). Staking pools and buyouts accumulate phantom balances that cause last-claimant reverts.

**Recommendation:** Use balance-before/balance-after pattern for all token deposits. Or explicitly disallow fee-on-transfer tokens via an approved currency whitelist.

---

### [H-01] Interest Calculation Not Annualized Despite NatSpec Claiming "Annual"

**Severity:** High
**Lines:** OmniNFTLending 185 (NatSpec), 237-238 (calculation)
**Agents:** Both

**Description:**

NatSpec states `interestBps` is "Annual interest in basis points." But the calculation is:
```solidity
uint256 interest = (offer.principal * offer.interestBps) / BPS_DENOMINATOR;
```

This computes a flat percentage regardless of duration. A 5000 bps (50%) rate charges the same interest for a 1-day loan as a 365-day loan. A 1-day loan at 1000 bps (10% "annual") actually charges 10% of principal — an effective 3,650% APR.

**Impact:** Interest rates are severely misrepresented. Short-term borrowers are massively overcharged relative to stated annual rates.

**Recommendation:** Pro-rate by duration:
```solidity
uint256 interest = (offer.principal * offer.interestBps * offer.durationDays) / (BPS_DENOMINATOR * 365);
```

---

### [H-02] Buyout Mechanism Allows Minority Shareholder Abuse

**Severity:** High
**Lines:** OmniFractionalNFT 231-254 (proposeBuyout)
**Agents:** Both

**Description:**

Any shareholder (even holding 1 fraction out of millions) can propose a buyout at any price. There is no:
- Minimum shareholding requirement to propose
- Voting/veto mechanism for other shareholders
- Cancellation function for the proposer
- Competing proposal mechanism
- Minimum price floor

A 1-token holder can propose a buyout at 0.001 USDC. `BuyoutAlreadyActive` prevents competing proposals. Remaining shareholders must accept the lowball price or hold unredeemable tokens.

**Impact:** Minority shareholder can force a below-market buyout on all other holders.

**Recommendation:** Require minimum shareholding (e.g., 25%) to propose. Add voting period. Allow buyout cancellation with funds return. Allow competing proposals at higher prices.

---

### [H-03] Royalty Registration Front-Running — No Ownership Verification

**Severity:** High
**Lines:** OmniNFTRoyalty 82-110 (setRoyalty)
**Agents:** Both

**Description:**

The first caller to `setRoyalty` for any collection becomes its `registeredOwner` with no verification of actual collection ownership. An attacker can front-run the legitimate owner and register themselves as the royalty recipient for any collection that doesn't natively support ERC-2981.

**Impact:** Royalty theft. An attacker redirects all royalty payments from any unregistered collection to themselves.

**Recommendation:** Verify collection ownership via `Ownable(collection).owner() == msg.sender`, with admin-only fallback for ownerless contracts.

---

### [H-04] Staking Pool Creator Cannot Withdraw Unused Rewards

**Severity:** High
**Lines:** OmniNFTStaking 175-222 (createPool)
**Agents:** Both

**Description:**

Pool creators deposit `totalReward` upfront. If the pool has no stakers for extended periods, or if `totalReward > rewardPerDay * durationDays`, excess tokens are permanently locked. There is no withdrawal function for pool creators after `endTime`.

Additionally, `rewardPerDay` and `totalReward` are independent parameters with no consistency check. A pool with `totalReward = 1000`, `rewardPerDay = 100`, `durationDays = 30` needs 3000 tokens but only has 1000 deposited.

**Impact:** Permanent loss of excess/unused reward tokens. Under-funded pools silently stop distributing early.

**Recommendation:** Add `withdrawExcessRewards()` callable by creator after `endTime`. Validate `rewardPerDay * durationDays <= totalReward` at creation.

---

### [H-05] Clone Name/Symbol Hardcoded — All Collections Report Same Identity

**Severity:** High
**Lines:** OmniNFTCollection 129-158 (initialize)
**Agent:** Agent A

**Description:**

ERC721's `name()` and `symbol()` are set by the constructor ("OmniNFT" / "ONFT") in the implementation contract. Clones share the implementation's code, so all clones return the same name/symbol on-chain regardless of what was passed to `initialize()`. The `_name` and `_symbol` parameters are silently ignored.

**Impact:** All cloned collections report identical on-chain identity. Marketplaces and wallets display wrong metadata. Enables phishing where malicious collections have the same on-chain identity as legitimate ones.

**Recommendation:** Override `name()` and `symbol()` in OmniNFTCollection to return values stored during `initialize()`.

---

### [M-01] No Liquidation Grace Period

**Severity:** Medium
**Lines:** OmniNFTLending 315-333 (liquidate)
**Agent:** Agent B

**Description:**

Liquidation is instant at `block.timestamp >= dueTime`. No grace period. A borrower 1 second late loses their NFT collateral. Network congestion at the exact due time prevents legitimate repayment.

**Recommendation:** Add a configurable grace period (e.g., 24 hours).

---

### [M-02] Buyout Rounding Loss — Funds Permanently Locked

**Severity:** Medium
**Lines:** OmniFractionalNFT 277 (executeBuyout pro-rata)
**Agent:** Agent A

**Description:**

`payment = (v.buyoutPrice * sharesToSell) / v.totalShares` rounds down. Over multiple small sales, rounding errors accumulate. With `buyoutPrice = 100` and `totalShares = 3`: three sales of 1 share each yield 33+33+33 = 99. The remaining 1 token is permanently locked.

**Recommendation:** Track remaining funds explicitly. Give the last shareholder the remaining balance.

---

### [M-03] Pool endTime Not Enforced — Staking Continues Indefinitely

**Severity:** Medium
**Lines:** OmniNFTStaking 229-261 (stake), 488-515 (_calculatePending)
**Agent:** Agent B

**Description:**

Neither `stake()` nor `_calculatePending()` checks `block.timestamp > pool.endTime`. Users can stake after the pool ends and earn rewards beyond the intended duration as long as `remainingReward > 0`.

**Recommendation:** Enforce `endTime` in both `stake()` and reward calculations.

---

### [M-04] Missing Zero-Address Checks on feeRecipient

**Severity:** Medium
**Lines:** OmniNFTLending 367-369, OmniFractionalNFT 315-317
**Agents:** Both

**Description:**

`setFeeRecipient()` in both contracts doesn't validate `newRecipient != address(0)`. Setting feeRecipient to zero address causes `safeTransfer` to revert on repayment, permanently preventing loan repayment and locking borrower NFTs.

**Recommendation:** Add `if (newRecipient == address(0)) revert InvalidRecipient();`

---

### [M-05] No On-Chain 70/20/10 Fee Split in Any NFT Contract

**Severity:** Medium
**Lines:** Multiple contracts
**Agent:** Agent B

**Description:**

OmniBazaar's fee model requires 70/20/10 splits. None of the NFT contracts implement this on-chain:
- OmniNFTFactory: `platformFeeBps` stored but never enforced
- OmniFractionalNFT: `creationFeeBps` stored but never collected
- OmniNFTLending: fee goes to single `feeRecipient`
- OmniNFTRoyalty: single recipient (ERC-2981 limitation)

**Impact:** Zero protocol revenue from NFT operations. Fee collection code is dead code.

**Recommendation:** Implement on-chain fee splitting matching DEXSettlement pattern, or route all fees through a splitter contract.

---

### [M-06] batchMint Missing nonReentrant and Upper Bound

**Severity:** Medium
**Lines:** OmniNFTCollection 253-263
**Agent:** Agent A

**Description:**

`batchMint` loops `quantity` times calling `_safeMint` (which triggers `onERC721Received` callbacks) without `nonReentrant` modifier and without a maximum batch size. Large quantities can exceed block gas limits.

**Recommendation:** Add `nonReentrant`, add `MAX_BATCH_SIZE = 100`, validate `to != address(0)`.

---

### [M-07] Vault ID 0 Ambiguity in nftToVault Mapping

**Severity:** Medium
**Lines:** OmniFractionalNFT 115 (mapping)
**Agent:** Agent A

**Description:**

`nextVaultId` starts at 0. `nftToVault[collection][tokenId]` returns 0 for both vault 0 and unfractionalized NFTs. `getVaultByNFT()` cannot distinguish between them.

**Recommendation:** Start `nextVaultId` at 1.

---

### [L-01] Royalty transferCollectionOwnership Allows Zero Address

**Severity:** Low
**Lines:** OmniNFTRoyalty 117-125
**Agent:** Agent A

**Description:**

Setting `newOwner = address(0)` creates a state where `registeredOwner == address(0)` but `isRegistered == true`. The `setRoyalty` check on line 93 could then allow anyone to re-register as royalty owner.

**Recommendation:** Add `if (newOwner == address(0)) revert InvalidRecipient();`

---

### [L-02] Lending Platform Fee Single Recipient — No 70/20/10

**Severity:** Low
**Lines:** OmniNFTLending 284-299
**Agent:** Agent B

**Description:**

NatSpec states fees are "split off-chain per OmniBazaar 70/20/10 model." This relies on off-chain trust rather than on-chain enforcement.

**Recommendation:** Use a splitter contract as feeRecipient, or implement on-chain splitting.

---

### [L-03] Unbounded Array Growth in Factory and Royalty

**Severity:** Low
**Lines:** OmniNFTFactory 73 (collections), OmniNFTRoyalty 65 (registeredCollections)
**Agent:** Agent A

**Description:**

Both arrays grow without bound with no removal mechanism. No on-chain functions iterate them, so the impact is limited to storage bloat and off-chain enumeration costs.

**Recommendation:** Accept as design tradeoff or add creation fees to discourage spam.

---

### [I-01] Floating Pragma

**Severity:** Informational

All contracts use `^0.8.24`. Pin to a specific version for deployment.

---

## Static Analysis Results

**Solhint:** 0 errors, 75 warnings (gas optimizations, NatSpec, ordering, not-rely-on-time)
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & OmniBazaar invariants (agent)
- Pass 5: Triage & deduplication (manual — 38 raw findings -> 18 unique)
- Pass 6: Report generation

## Conclusion

The NFT suite has **two critical issues and several high-severity gaps**:

1. **FractionToken burn (C-01)** — unrestricted `burn()` permanently locks NFTs. The `OnlyVault` error proves this was meant to be restricted but wasn't implemented.

2. **Fee-on-transfer tokens (C-02)** — accounting mismatches cause DoS in lending and phantom balances in staking/fractional contracts.

3. **Interest rate miscalculation (H-01)** — flat percentage presented as annual rate. 1-day loans at "10% annual" charge 3,650% effective APR.

4. **Buyout abuse (H-02)** — 1-token minority holders can force below-market buyouts with no governance or cancellation.

5. **Clone identity (H-05)** — all collections report the same on-chain name/symbol, enabling phishing.

**Systemic issue:** None of the 7 NFT contracts implement OmniBazaar's 70/20/10 fee distribution on-chain. Fee-related code is either dead (never collected) or sends to a single recipient. This represents zero protocol revenue from the entire NFT vertical.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
