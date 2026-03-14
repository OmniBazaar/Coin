# Cross-System Adversarial Review: Fee Evasion

**Date:** 2026-03-13
**Scope:** All fee-collecting and fee-distributing contracts in the OmniBazaar smart contract suite
**Reviewer:** Claude Opus 4.6 (Adversarial Cross-System Analysis)
**Round:** 7 (supersedes prior version)

---

## Contracts Reviewed

| Contract | Path | Fee Role |
|----------|------|----------|
| UnifiedFeeVault | `contracts/UnifiedFeeVault.sol` | Central 70/20/10 distribution hub |
| DEXSettlement | `contracts/dex/DEXSettlement.sol` | Trading fee collection (70% LP / 30% Vault) |
| OmniFeeRouter | `contracts/dex/OmniFeeRouter.sol` | External DEX swap fee wrapper |
| OmniSwapRouter | `contracts/dex/OmniSwapRouter.sol` | Multi-source swap routing with fee |
| FeeSwapAdapter | `contracts/FeeSwapAdapter.sol` | Token-to-XOM swap bridge for vault |
| MinimalEscrow | `contracts/MinimalEscrow.sol` | Marketplace & arbitration fee collection |
| OmniChatFee | `contracts/chat/OmniChatFee.sol` | Per-message chat fee collection |
| OmniYieldFeeCollector | `contracts/yield/OmniYieldFeeCollector.sol` | Yield performance fee collection |
| OmniMarketplace | `contracts/marketplace/OmniMarketplace.sol` | Listing registry (no fees) |
| OmniArbitration | `contracts/arbitration/OmniArbitration.sol` | Dispute fee collection (70% arbs / 30% Vault) |
| OmniBridge | `contracts/OmniBridge.sol` | Cross-chain bridge fee collection |
| OmniPredictionRouter | `contracts/predictions/OmniPredictionRouter.sol` | Prediction market fee collection |
| RWAAMM | `contracts/rwa/RWAAMM.sol` | RWA AMM swap fee (70% LP / 30% Vault) |

---

## Executive Summary

The OmniBazaar fee architecture is well-structured around UnifiedFeeVault as the central distribution hub implementing the protocol-standard 70/20/10 split (ODDAO / Staking Pool / Protocol Treasury). Most fee-collecting contracts use immutable or timelocked configurations with hardcoded constant split ratios. Previous audit rounds (1-6) have addressed the most severe issues.

This cross-system review identifies **1 High**, **4 Medium**, and **5 Low/Informational** findings related to fee evasion vectors, with an emphasis on cross-contract interactions and the consistency of fee routing across the entire suite.

**Overall Assessment: GOOD** -- The fee system is robust against most evasion vectors. The primary issues are (1) multiple contracts lacking timelocks on fee vault changes ("Pioneer Phase"), (2) MinimalEscrow bypassing the marketplace fee sub-split logic, and (3) several contracts using plain `safeTransfer` to the vault instead of calling `deposit()`, creating accounting gaps.

---

## Fee Architecture Diagram

```
User Transactions
       |
       v
+------------------+  +------------------+  +------------------+
|  MinimalEscrow   |  |  DEXSettlement   |  |  OmniChatFee     |
|  (1% mktplace)   |  |  (0.20% taker)   |  |  (baseFee/msg)   |
|  (5% arbitration)|  |  70% LP / 30% VFV|  |  100% to VFV     |
+--------+---------+  +--------+---------+  +--------+---------+
         |                      |                     |
         v                      v                     v
+--------+---------+  +--------+---------+  +---------+
| UnifiedFeeVault  |  | LP Pool (70%)    |  |         |
| 70% ODDAO bridge |  +------------------+  |         |
| 20% StakingPool  |                        |         |
| 10% Protocol     |<---------+-------------+         |
+------------------+          |                        |
                     +--------+---------+              |
                     | OmniFeeRouter    |              |
                     | (fee to vault)   +--------------+
                     +------------------+
                     +------------------+   +------------------+
                     | OmniArbitration  |   | OmniSwapRouter   |
                     | 70% Arbitrators  |   | (fee to vault)   |
                     | 30% to Vault     |   +------------------+
                     +------------------+
                     +------------------+   +------------------+
                     | RWAAMM           |   | OmniYieldFeeCollr|
                     | 70% LP pool      |   | (fee to vault)   |
                     | 30% to Vault     |   +------------------+
                     +------------------+
                     +------------------+   +------------------+
                     | OmniBridge       |   | OmniPrediction   |
                     | (fee to vault)   |   | (fee to vault)   |
                     +------------------+   +------------------+

Legend:
  VFV = UnifiedFeeVault (handles 70/20/10 split internally)
  All "to vault" arrows use plain safeTransfer(), NOT deposit()
  Only DEXSettlement and RWAAMM have LP pool splits before vault
```

---

## Analysis 1: Fee Bypass Routes

### 1.1 UnifiedFeeVault -- Direct Deposit Bypass

**Status: MITIGATED (DEPOSITOR_ROLE gate)**

The `deposit()` function is gated by `onlyRole(DEPOSITOR_ROLE)`. Users cannot deposit directly. The `distribute()` function is permissionless, but it only distributes what is already in the vault -- it does not pull funds from users. The `depositMarketplaceFee()` function is also gated by `DEPOSITOR_ROLE`.

**Verdict: No bypass possible.**

### 1.2 MinimalEscrow -- Fee Bypass via Collusion

**Status: ARCHITECTURAL LIMITATION (Accepted)**

Marketplace fee (1%) is collected only on `releaseFunds()` (line 511) and `_resolveEscrow()` when recipient is the seller. Refunds to the buyer via `refundBuyer()` correctly do NOT charge fees. A buyer and seller could collude: use escrow for trust, then call `refundBuyer()` to return funds fee-free, completing the real exchange off-chain. This is inherent to escrow-based marketplace fees.

**Verdict: By design. Cannot be mitigated at the smart contract level.**

### 1.3 DEXSettlement -- P2P Transfer Bypass

**Status: ARCHITECTURAL LIMITATION (Informational)**

Users could bypass DEX fees by transferring tokens directly between wallets (P2P transfer) instead of using the DEX. The DEX fee (0.20% taker) is only enforced when `settleTrade()` or `settleIntent()` is called. This is inherent to all DEX designs -- the fee is the price of the matching service, not a transfer tax.

**Verdict: By design.**

### 1.4 OmniChatFee -- Free Tier Bypass via Multiple Wallets

**Status: INFORMATIONAL (I-01)**

The free tier tracks `monthlyMessageCount` per address. A user could create multiple wallets to get 20 free messages per wallet per month. This is mitigated at the validator layer (KYC/participation scoring), not at the contract level.

**Verdict: Mitigated by off-chain KYC.**

### 1.5 OmniMarketplace -- No Fees Collected

**Status: NOT APPLICABLE**

OmniMarketplace is a pure listing registry. It does not collect any fees. Marketplace transaction fees are collected by MinimalEscrow at settlement time.

**Verdict: No fee to evade.**

### 1.6 Direct ERC20 Transfers Bypass All Fee Collection

**Status: ARCHITECTURAL LIMITATION (Accepted)**

OmniCoin (XOM) is a standard ERC20 without fee-on-transfer. Any user can `transfer()` XOM directly to any address, completely bypassing all marketplace fees, DEX fees, and chat fees. This is inherent to non-taxed ERC20 tokens. The fee contracts only capture fees when users voluntarily route through them (for the service they provide: escrow, order matching, messaging infrastructure).

**Verdict: By design. The contracts enforce fees on services, not on raw token transfers.**

---

## Analysis 2: Fee Recipient Manipulation

### 2.1 UnifiedFeeVault -- Recipient Change Timelock

**Status: SECURE (48h timelock)**

All configuration changes are protected by 48-hour timelocks:
- `proposeRecipients()` / `applyRecipients()` -- 48h timelock
- `proposeSwapRouter()` / `applySwapRouter()` -- 48h timelock
- `proposePrivacyBridge()` / `applyPrivacyBridge()` -- 48h timelock
- `proposeXomToken()` / `applyXomToken()` -- 48h timelock
- `proposeTokenBridgeMode()` / `applyTokenBridgeMode()` -- 48h timelock

**Verdict: Robust timelock protection.**

### 2.2 DEXSettlement -- Fee Recipient Change

**Status: SECURE (48h timelock + force-claim)**

- `scheduleFeeRecipients()` / `applyFeeRecipients()` -- 48h timelock
- Force-claims all pending fees to old recipients before updating addresses (H-05)
- `cancelScheduledFeeRecipients()` available for cancellation

**Verdict: Well-protected.**

### 2.3 OmniFeeRouter -- Fee Collector Change

**Status: SECURE (24h timelock)**

- `proposeFeeCollector()` / `applyFeeCollector()` -- 24h timelock

**Verdict: Protected. 24h is shorter than 48h used elsewhere; acceptable for Pioneer Phase.**

### 2.4 FeeSwapAdapter -- Router Change

**Status: SECURE (24h timelock)**

- `proposeRouter()` / `applyRouter()` -- 24h timelock

**Verdict: Protected.**

### 2.5 MinimalEscrow -- Immutable FEE_VAULT

**Status: SECURE (immutable)**

`FEE_VAULT` is declared `immutable`. Cannot be changed after deployment.

**Verdict: Cannot be changed.**

### 2.6 OmniChatFee -- Immutable feeVault

**Status: SECURE (immutable)**

`feeVault` is declared `immutable`. Cannot be changed after deployment.

**Verdict: Cannot be changed.**

### 2.7 OmniYieldFeeCollector -- Immutable feeVault

**Status: SECURE (immutable)**

`feeVault` is declared `immutable`. Cannot be changed after deployment.

**Verdict: Cannot be changed.**

### 2.8 FINDING FE-H-01: Multiple Contracts Lack Timelock on setFeeVault()

| ID | Severity | Title |
|----|----------|-------|
| FE-H-01 | **HIGH** | OmniSwapRouter, OmniArbitration, OmniBridge, OmniPredictionRouter all lack timelock on fee vault changes |

**Affected Contracts:**

| Contract | Function | Access Control | Timelock |
|----------|----------|----------------|----------|
| OmniSwapRouter | `setFeeVault()` (line 414) | `onlyOwner` | **NONE** (Pioneer Phase comment) |
| OmniSwapRouter | `setSwapFee()` (line 398) | `onlyOwner` | **NONE** (Pioneer Phase comment) |
| OmniArbitration | `setFeeVault()` (line 1527) | `DEFAULT_ADMIN_ROLE` | **NONE** (no comment) |
| OmniBridge | `setFeeVault()` (line 687) | `ADMIN_ROLE` via OmniCore | **NONE** (no comment) |
| OmniPredictionRouter | `setFeeVault()` (line 190) | `onlyOwner` | **NONE** (Pioneer Phase comment) |

**Issue:** These four contracts allow instant fee vault redirection with a single owner/admin transaction. If any admin key is compromised, an attacker could immediately redirect all future fees from these contracts to their own address. By contrast, UnifiedFeeVault, DEXSettlement, OmniFeeRouter, and FeeSwapAdapter all require 24-48 hour timelocks for equivalent changes, giving the community detection and response time.

**Impact:**
- **OmniSwapRouter**: All swap fees (0.30% default) instantly redirected
- **OmniSwapRouter fee rate**: `setSwapFee()` could be set to 0, eliminating all swap fees; or set to max (100 bps = 1%), overcharging users
- **OmniArbitration**: 30% of all arbitration fees (VAULT_SHARE) instantly redirected
- **OmniBridge**: All bridge fees instantly redirected
- **OmniPredictionRouter**: All prediction market fees instantly redirected

**Root Cause:** Inconsistent application of the timelock pattern. Some contracts were updated during Round 6 audit; others were left with "Pioneer Phase" comments indicating future timelocking.

**Attack Scenario:**
1. Attacker compromises the owner/admin private key (phishing, key theft, etc.)
2. Attacker calls `setFeeVault(attackerAddress)` on all four contracts in a single block
3. All future fees are instantly redirected to the attacker
4. No timelock window for community detection or response
5. Attacker can also set `setSwapFee(0)` to eliminate evidence via reduced fee events

**Recommendation:** Add propose/apply timelock pattern (minimum 24h, preferably 48h) to all four contracts' `setFeeVault()` functions, matching the pattern used in OmniFeeRouter:

```solidity
address public pendingFeeVault;
uint256 public feeVaultChangeTime;
uint256 public constant FEE_VAULT_DELAY = 48 hours;

function proposeFeeVault(address _feeVault) external onlyOwner {
    if (_feeVault == address(0)) revert InvalidRecipientAddress();
    pendingFeeVault = _feeVault;
    feeVaultChangeTime = block.timestamp + FEE_VAULT_DELAY;
    emit FeeVaultProposed(_feeVault, feeVaultChangeTime);
}

function applyFeeVault() external onlyOwner {
    if (pendingFeeVault == address(0)) revert NoPendingChange();
    if (block.timestamp < feeVaultChangeTime) revert TimelockNotExpired();
    address oldVault = feeVault;
    feeVault = pendingFeeVault;
    delete pendingFeeVault;
    delete feeVaultChangeTime;
    emit FeeVaultUpdated(oldVault, feeVault);
}
```

Similarly, `setSwapFee()` in OmniSwapRouter should use a timelock pattern.

---

## Analysis 3: Rounding Exploitation and Dust Evasion

### 3.1 UnifiedFeeVault -- Dust Protection

**Status: SECURE**

- `distribute()` skips amounts < 10 tokens: `if (distributable < 10) return;`
- `depositMarketplaceFee()` enforces `MIN_SALE_AMOUNT = 10_000`
- Protocol share gets remainder to avoid rounding dust: `uint256 protocolShare = distributable - oddaoShare - stakingShare;`

**Verdict: Dust protection in place.**

### 3.2 OmniFeeRouter -- Minimum Swap Amount

**Status: SECURE**

`MIN_SWAP_AMOUNT = 1e15` enforced in `_validateFee()`: `if (totalAmount < MIN_SWAP_AMOUNT) revert AmountTooSmall();`

**Verdict: Dust-protected.**

### 3.3 FeeSwapAdapter -- Minimum Swap Amount

**Status: SECURE**

`MIN_SWAP_AMOUNT = 1e15` enforced in `swapExactInput()`.

**Verdict: Dust-protected.**

### 3.4 OmniChatFee -- Minimum Fee Floor

**Status: SECURE**

`MIN_FEE = 1e15` (0.001 XOM). The `_collectFee()` function enforces: `if (fee < MIN_FEE) fee = MIN_FEE;`

**Verdict: Dust-protected.**

### 3.5 OmniArbitration -- Minimum Dispute Amount

**Status: SECURE**

`createDispute()` enforces: `if (fee == 0) revert DisputedAmountTooSmall();` Since fee = `(amount * 500) / 10000`, amounts < 20 wei would produce zero fees and be rejected.

**Verdict: Protected.**

### 3.6 FINDING FE-L-01: DEXSettlement Has No Minimum Trade Size

| ID | Severity | Title |
|----|----------|-------|
| FE-L-01 | Low | No minimum trade size in DEXSettlement allows zero-fee dust trades |

**Issue:** While `maxTradeSize` sets an upper bound, there is no minimum trade size. For very small trades (e.g., `amountIn = 49 wei`), the taker fee calculation `(49 * 20) / 10000 = 0` would result in zero fees. The maker rebate would also be zero.

The `_accrueFeeSplit()` function handles the zero case gracefully (it checks `if (lpShare > 0)` and `if (vaultShare > 0)` before transfers), so no revert would occur, but fees would be evaded.

Similarly, in `settleIntent()`, the `solverFee` and `traderRebate` are calculated from `coll.solverAmount`. For `solverAmount = 499 wei`, `solverFee = (499 * 20) / 10000 = 0`.

**Impact:** Very low. Executing a trade for 49 wei has no practical economic benefit. Gas costs alone would dwarf any fee savings.

**Recommendation:** Consider adding a minimum trade amount (e.g., 10000 wei) to prevent zero-fee trades as a defense-in-depth measure:
```solidity
uint256 public constant MIN_TRADE_SIZE = 10_000;
// In _executeAtomicSettlement and settleIntent:
if (traderAmount < MIN_TRADE_SIZE) revert TradeTooSmall();
```

### 3.7 70/20/10 Split -- Hardcoded Constants

**Status: SECURE across all contracts**

All split ratios are defined as `constant` values:
- **UnifiedFeeVault:** `ODDAO_BPS=7000`, `STAKING_BPS=2000`, `PROTOCOL_BPS=1000`
- **DEXSettlement:** `LP_SHARE=7000`, `VAULT_SHARE=3000`
- **OmniArbitration:** `ARBITRATOR_FEE_SHARE=7000`, `VAULT_SHARE=3000`
- **RWAAMM:** `FEE_LP_BPS=7000` (vault gets remainder)

Constants are embedded in bytecode, not storage. They cannot be changed even via UUPS upgrade without replacing the contract entirely. UnifiedFeeVault has ossification support to permanently prevent upgrades.

**Verdict: Immutable. Cannot be manipulated.**

---

## Analysis 4: Direct Settlement Bypassing Fee Contracts

### 4.1 FINDING FE-M-01: MinimalEscrow Fees Bypass depositMarketplaceFee() Sub-Splits

| ID | Severity | Title |
|----|----------|-------|
| FE-M-01 | **MEDIUM** | Escrow marketplace fees bypass depositMarketplaceFee() sub-splits (referrers/nodes unpaid) |

**Issue:** MinimalEscrow sends marketplace fees to UnifiedFeeVault via plain `safeTransfer()` at multiple locations:
- `releaseFunds()` line 515: `OMNI_COIN.safeTransfer(FEE_VAULT, feeAmount)`
- `_resolveEscrow()` lines 1040, 1069: `OMNI_COIN.safeTransfer(FEE_VAULT, ...)`
- Private escrow: lines 1281, 1395, 1427

The vault receives the tokens but they are NOT routed through `depositMarketplaceFee()`. Per the CLAUDE.md specification, marketplace fees should be sub-split as:
- **0.50% Transaction fee:** 70% ODDAO, 20% staking, 10% protocol
- **0.25% Referral fee:** 70% referrer, 20% L2 referrer, 10% ODDAO
- **0.25% Listing fee:** 70% listing node, 20% selling node, 10% ODDAO

UnifiedFeeVault has `depositMarketplaceFee()` that implements this 3-way sub-split with referrer/node routing. However, MinimalEscrow calls plain `safeTransfer()`, which means:

1. **Referrers receive nothing** -- the referral fee (0.25%) is absorbed into the generic 70/20/10 split
2. **Listing/selling nodes receive nothing** -- the listing fee (0.25%) is similarly absorbed
3. **Fee distribution does not match the specification**

**Impact:** Referrers and listing/selling nodes are systematically underpaid for all marketplace transactions that go through escrow. This is a design-level fee evasion -- not by users, but by the system itself failing to route fees correctly.

**Root Cause:** MinimalEscrow was designed with a simple `safeTransfer(FEE_VAULT, feeAmount)` pattern before `depositMarketplaceFee()` was added to UnifiedFeeVault. The integration was never updated.

**Attack Scenario:** None -- this is not user-exploitable. It is a systematic under-payment to referrers and listing nodes.

**Recommendation:** MinimalEscrow should call `UnifiedFeeVault.depositMarketplaceFee()` instead of plain `safeTransfer()`. This requires:
1. MinimalEscrow needs to accept referrer, L2 referrer, listing node, and selling node addresses as parameters to `createEscrow()`
2. MinimalEscrow needs `DEPOSITOR_ROLE` on UnifiedFeeVault
3. MinimalEscrow needs to approve UnifiedFeeVault for the fee amount before calling `depositMarketplaceFee()`
4. Store the referrer/node addresses in the `Escrow` struct for use at `releaseFunds()` time

### 4.2 FINDING FE-M-02: Multiple Contracts Send Fees via Plain Transfer, Not deposit()

| ID | Severity | Title |
|----|----------|-------|
| FE-M-02 | **MEDIUM** | Six contracts bypass UnifiedFeeVault deposit() gate and fee accounting |

**Affected Contracts:**

| Contract | Fee Transfer Method | vault.deposit() Called? |
|----------|--------------------|-----------------------|
| MinimalEscrow | `OMNI_COIN.safeTransfer(FEE_VAULT, ...)` | No |
| OmniChatFee | `safeTransferFrom(user, feeVault, fee)` | No |
| OmniYieldFeeCollector | `safeTransfer(feeVault, totalFee)` | No |
| OmniSwapRouter | `safeTransfer(feeVault, feeAmount)` | No |
| OmniArbitration | `xomToken.safeTransfer(feeVault, vaultAmount)` | No |
| OmniBridge | `safeTransfer(feeVault, fees)` | No |
| OmniPredictionRouter | `safeTransfer(feeVault, feeAmount)` | No |
| RWAAMM | `safeTransferFrom(caller, FEE_VAULT, vaultFee)` | No |
| DEXSettlement | `safeTransfer(feeRecipients.feeVault, vaultShare)` | No |

**Issue:** UnifiedFeeVault has a `deposit(address token, uint256 amount)` function gated by `DEPOSITOR_ROLE` that:
1. Emits `FeesDeposited(token, amount, actualReceived, sender)`
2. Updates `totalFeesCollected[token]`
3. Provides a consistent audit trail for all incoming fees

None of the nine fee-collecting contracts call `deposit()`. They all use plain `safeTransfer()` to send tokens directly to the vault's address. The vault receives the tokens, and they are distributable via `distribute()` (which uses `balanceOf()`), but:

1. **`totalFeesCollected` mapping is never updated** for these fees
2. **`FeesDeposited` event is never emitted**, making off-chain indexing incomplete
3. **Fee source attribution is lost** -- the vault cannot distinguish which contract sent which fees

**Impact:** Accounting and transparency gap. The vault's `totalFeesCollected` counter dramatically underreports actual fees. Off-chain dashboards, block explorers, and analytics relying on `FeesDeposited` events will show incomplete data. The actual fee distribution is NOT affected (funds are distributable).

**Recommendation:** Either:
1. **Preferred:** Grant each fee-collecting contract `DEPOSITOR_ROLE` and modify them to call `vault.deposit(token, amount)` with an approval flow
2. **Alternative:** Add a `notifyDeposit(address token, uint256 amount)` function to UnifiedFeeVault that only updates the accounting (events + counter) without transferring tokens, callable by the same `DEPOSITOR_ROLE`. Contracts would `safeTransfer()` first, then `notifyDeposit()`

### 4.3 RWAAMM Double-Pull Pattern

**Status: INFORMATIONAL (I-02)**

RWAAMM splits the protocol fee into LP (70%) and vault (30%) portions, then executes two separate `safeTransferFrom` calls from the caller:
```solidity
IERC20(tokenIn).safeTransferFrom(caller, poolAddr, amountToPool);  // trade + LP fee
IERC20(tokenIn).safeTransferFrom(caller, FEE_VAULT, vaultFee);     // vault fee
```

This is a valid pattern but requires the caller to have approved RWAAMM for `amountIn` (the full amount including both portions). The vault portion is transferred directly from the caller to `FEE_VAULT`, bypassing both the RWAAMM contract itself and the vault's `deposit()` function.

**Verdict:** Functionally correct. The immutable `FEE_VAULT` prevents redirection. Subject to FE-M-02 accounting gap.

---

## Analysis 5: Fee Token Manipulation

### 5.1 Platform-Wide Fee-on-Transfer Token Policy

**Status: ACCEPTED RISK (Documented)**

All contracts include the audit-accepted comment:
```
AUDIT ACCEPTED (Round 6): Fee-on-transfer and rebasing tokens are not
supported. OmniCoin (XOM) is the primary token and does not have these
features. Only vetted tokens (XOM, USDC, WBTC, WETH) are whitelisted.
```

### 5.2 Balance-Before/After Pattern Usage

| Contract | FoT Protection | Method |
|----------|---------------|--------|
| UnifiedFeeVault | Yes | Balance check in `deposit()` and `depositMarketplaceFee()` |
| DEXSettlement | Yes | Revert with `FeeOnTransferNotSupported()` |
| OmniFeeRouter | Yes | Proportional recalculation from actual received |
| OmniSwapRouter | Yes | Balance-before/after on input and output |
| OmniYieldFeeCollector | Yes | Balance-before/after on yield amount |
| FeeSwapAdapter | Yes | Balance-before/after on swap input |
| OmniChatFee | No | Immutable XOM (no FoT) -- acceptable |
| MinimalEscrow | No | Immutable OMNI_COIN (no FoT) -- acceptable |
| RWAAMM | No | Direct `safeTransferFrom` without balance check |

### 5.3 FINDING FE-L-02: MinimalEscrow createEscrow() Lacks Balance-Before/After Check

| ID | Severity | Title |
|----|----------|-------|
| FE-L-02 | Low | MinimalEscrow.createEscrow() lacks balance-before/after for defense-in-depth |

**Issue:** `createEscrow()` uses `OMNI_COIN.safeTransferFrom(buyer, address(this), amount)` without balance verification. If XOM were ever upgraded to include fee-on-transfer behavior (even accidentally via proxy upgrade), the escrow would record `amount` in storage but hold fewer actual tokens. Subsequent `releaseFunds()` would attempt to transfer more than available.

**Current Mitigation:** `OMNI_COIN` is immutable and points to XOM, which is not fee-on-transfer. Risk is zero in practice.

**Recommendation:** Add a balance check for defense-in-depth:
```solidity
uint256 balBefore = OMNI_COIN.balanceOf(address(this));
OMNI_COIN.safeTransferFrom(buyer, address(this), amount);
uint256 actualReceived = OMNI_COIN.balanceOf(address(this)) - balBefore;
if (actualReceived != amount) revert FeeOnTransferNotSupported();
```

### 5.4 FINDING FE-L-03: RWAAMM Lacks FoT Guard on Swap Input

| ID | Severity | Title |
|----|----------|-------|
| FE-L-03 | Low | RWAAMM swap function does not verify actual received amounts |

**Issue:** RWAAMM's `_executeSwap()` function calls `safeTransferFrom(caller, poolAddr, amountToPool)` and `safeTransferFrom(caller, FEE_VAULT, vaultFee)` without balance-before/after checks. For fee-on-transfer tokens, the pool and vault would receive less than expected, breaking the constant-product invariant.

**Current Mitigation:** Only whitelisted, non-FoT tokens are supported. RWA tokens are vetted.

**Recommendation:** Add balance checks on both transfers, or revert with `FeeOnTransferNotSupported()` if amounts mismatch.

---

## Analysis 6: Cross-Contract Fee Leakage

### 6.1 FINDING FE-M-03: OmniFeeRouter feeCollector Not Validated as UnifiedFeeVault

| ID | Severity | Title |
|----|----------|-------|
| FE-M-03 | **MEDIUM** | OmniFeeRouter feeCollector can be any address, not necessarily UnifiedFeeVault |

**Issue:** OmniFeeRouter's `feeCollector` is intended to be the UnifiedFeeVault, but the 24h-timelocked `proposeFeeCollector()` / `applyFeeCollector()` flow does not validate that the new address is actually a UnifiedFeeVault instance. The owner could (intentionally or via compromised key) set `feeCollector` to any address, including an EOA.

Unlike MinimalEscrow, OmniChatFee, and OmniYieldFeeCollector (which have immutable vault addresses), OmniFeeRouter's vault is mutable. The timelock mitigates the urgency of admin key compromise, but does not prevent a malicious admin from redirecting fees to a non-vault address after the 24h delay.

**Impact:** If `feeCollector` is set to a non-vault address, fees from external DEX swaps would be permanently lost to the protocol's distribution mechanism (no 70/20/10 split).

**Recommendation:** Either:
1. Make `feeCollector` immutable (requires redeployment if vault changes)
2. Add an interface check: `if (IERC165(addr).supportsInterface(type(IUnifiedFeeVault).interfaceId) == false) revert NotAVault();`
3. Accept the risk with the existing 24h timelock (current approach)

### 6.2 FINDING FE-M-04: DEXSettlement Intent Settlement -- Zero Net Fee on Low-Value Trades

| ID | Severity | Title |
|----|----------|-------|
| FE-M-04 | **MEDIUM** | Intent settlement rebate can exceed or equal fee, resulting in zero net protocol revenue |

**Issue:** In `settleIntent()`, the fee structure is:
```solidity
uint256 traderRebate = (coll.solverAmount * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;  // 0.05%
uint256 solverFee = (coll.solverAmount * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;        // 0.20%
```

The net fee is `solverFee - min(traderRebate, solverFee)`. For normal amounts, net fee = `0.20% - 0.05% = 0.15%`, which is correct.

However, the code handles an edge case at line 1358:
```solidity
uint256 rebate = traderRebate > solverFee ? solverFee : traderRebate;
uint256 netFee = solverFee - rebate;
```

If `traderRebate > solverFee` (which cannot happen with the current constants since 5 < 20), then `netFee = 0` and no fees are distributed. While this edge case is not reachable with current constants, if `SPOT_MAKER_REBATE` were ever changed to equal or exceed `SPOT_TAKER_FEE` (both are constants, so this would require a contract upgrade), all intent settlement fees would be zero.

More practically, for `solverAmount` values between 500 and 999 wei:
- `solverFee = (999 * 20) / 10000 = 1`
- `traderRebate = (999 * 5) / 10000 = 0`
- `netFee = 1 - 0 = 1`
- `_accrueFeeSplit(1, tokenOut)`: `lpShare = (1 * 7000) / 10000 = 0`, `vaultShare = 1 - 0 = 1`
- Only 1 wei goes to vault, 0 to LP

This is technically correct but represents negligible revenue. Subject to FE-L-01 minimum trade size recommendation.

**Impact:** Low in isolation (dust trades), but combined with the lack of minimum trade size (FE-L-01), a bot could execute many zero-fee or near-zero-fee intent settlements to benefit from the matching service without paying meaningful fees.

**Recommendation:** Add minimum trade size to `settleIntent()` matching the recommendation in FE-L-01.

### 6.3 MinimalEscrow Private Escrow Arbitration Fee Denomination Mismatch

**Status: INFORMATIONAL (I-03)**

In `_resolvePrivateEscrow()`, the arbitration fee is calculated from `privateEscrowAmounts[escrowId]` (pXOM denomination) but paid from XOM dispute stakes. If pXOM:XOM ever depegs, arbitration fee amounts would be miscalculated.

**Current Mitigation:** pXOM and XOM are designed to be 1:1 convertible. The privacy bridge fee (0.3%) is the only source of deviation.

**Verdict:** Document the assumption. Monitor the peg.

---

## Summary of Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| FE-H-01 | **HIGH** | OmniSwapRouter, OmniArbitration, OmniBridge, OmniPredictionRouter lack timelock on fee vault changes | **NEW** |
| FE-M-01 | **MEDIUM** | MinimalEscrow marketplace fees bypass depositMarketplaceFee() sub-splits (referrers/nodes unpaid) | **NEW** |
| FE-M-02 | **MEDIUM** | Nine contracts bypass UnifiedFeeVault deposit() gate and fee accounting | **NEW** |
| FE-M-03 | **MEDIUM** | OmniFeeRouter feeCollector not validated as UnifiedFeeVault | **NEW** |
| FE-M-04 | **MEDIUM** | Intent settlement zero net fee edge case on low-value trades | **NEW** |
| FE-L-01 | Low | No minimum trade size in DEXSettlement allows zero-fee dust trades | **NEW** |
| FE-L-02 | Low | MinimalEscrow.createEscrow() lacks balance-before/after check | **NEW** |
| FE-L-03 | Low | RWAAMM swap function lacks fee-on-transfer guard | **NEW** |
| I-01 | Info | OmniChatFee free tier bypassable via multiple wallets (mitigated by KYC) | **NEW** |
| I-02 | Info | RWAAMM double-pull pattern -- functionally correct but unusual | **NEW** |
| I-03 | Info | Private escrow arbitration fee cross-denomination assumption (pXOM:XOM 1:1) | **NEW** |

---

## Fee Evasion Vector Matrix

| Attack Vector | UnifiedFeeVault | DEXSettlement | MinimalEscrow | OmniChatFee | OmniFeeRouter | OmniArbitration | OmniSwapRouter | OmniBridge | RWAAMM |
|--------------|----------------|---------------|---------------|-------------|---------------|-----------------|----------------|------------|--------|
| **Direct bypass** | DEPOSITOR_ROLE | EIP-712 sigs | Escrow flow | Free tier cap | Fee validation | Party check | Path validation | Bridge flow | Pool check |
| **Recipient theft** | 48h timelock | 48h timelock | Immutable | Immutable | 24h timelock | **NO TIMELOCK** | **NO TIMELOCK** | **NO TIMELOCK** | Immutable |
| **Split manipulation** | Constants | Constants | Delegates to vault | Delegates to vault | N/A | Constants | N/A | N/A | Constants |
| **Dust evasion** | MIN_SALE_AMOUNT | **No minimum** | N/A | MIN_FEE | MIN_SWAP_AMOUNT | Zero-fee check | No minimum | N/A | No minimum |
| **FoT protection** | Balance check | Revert guard | **No check** | Immutable XOM | Balance check | Immutable XOM | Balance check | N/A | **No check** |
| **Vault tracking** | Self (deposit) | **Plain transfer** | **Plain transfer** | **Plain transfer** | **Plain transfer** | **Plain transfer** | **Plain transfer** | **Plain transfer** | **Plain transfer** |

---

## Positive Observations

1. **Hardcoded fee splits** across all contracts prevent admin manipulation of ratios
2. **Consistent timelock pattern** (48h) in UnifiedFeeVault and DEXSettlement -- the two highest-value fee contracts
3. **Pull pattern** (pendingClaims) in UnifiedFeeVault prevents DoS from reverting recipients
4. **Force-claim on recipient change** (H-05 in DEXSettlement) prevents orphaned fees
5. **Ossification support** in UnifiedFeeVault allows permanent finalization
6. **Comprehensive fee-on-transfer guards** in DEXSettlement and OmniFeeRouter
7. **MIN_SALE_AMOUNT** in UnifiedFeeVault prevents rounding-loss fee evasion
8. **DEPOSITOR_ROLE whitelist** prevents unauthorized deposits that could inflate distributable amounts
9. **rescueToken()** in UnifiedFeeVault correctly accounts for committed funds (pendingBridge + totalPendingClaims)
10. **Remainder-to-last-recipient** pattern used consistently to prevent dust loss from integer division
11. **Immutable fee vault addresses** in MinimalEscrow, OmniChatFee, OmniYieldFeeCollector, and RWAAMM eliminate vault redirection risk for those contracts
12. **Router allowlist** in OmniFeeRouter prevents arbitrary-calldata attacks
13. **Ownable2Step** used consistently across owner-controlled contracts prevents accidental ownership transfer

---

## Priority Remediation Order

1. **FE-H-01** (HIGH): Add timelocks to OmniSwapRouter, OmniArbitration, OmniBridge, OmniPredictionRouter -- prevents instant fee theft on key compromise
2. **FE-M-01** (MEDIUM): Update MinimalEscrow to call `depositMarketplaceFee()` -- ensures referrers and nodes are paid
3. **FE-M-02** (MEDIUM): Implement `notifyDeposit()` or grant DEPOSITOR_ROLE to fee-collecting contracts -- fixes accounting gap
4. **FE-M-04** (MEDIUM): Add minimum trade size to DEXSettlement -- prevents zero-fee trades
5. **FE-M-03** (MEDIUM): Consider making OmniFeeRouter feeCollector immutable or adding interface check
6. **FE-L-01 through FE-L-03** and informational items -- address during normal development cycle

---

*End of Cross-System Fee Evasion Review*
