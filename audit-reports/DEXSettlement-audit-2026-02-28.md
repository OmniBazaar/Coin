# Security Audit Report: DEXSettlement

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/dex/DEXSettlement.sol`
**Solidity Version:** 0.8.25
**Lines of Code:** 1,867
**Upgradeable:** No (Ownable2Step, immutable deployment)
**Handles Funds:** Yes (fee accruals, intent collateral escrow)

## Executive Summary

DEXSettlement is a well-engineered trade settlement contract with extensive prior audit remediation (H-01 through H-06, M-01 through M-07). It uses EIP-712 typed data signing, nonce bitmap (Uniswap Permit2 pattern), commit-reveal MEV protection, pull-pattern fee distribution, and 48-hour timelocks on admin changes. The primary vulnerability is a **fee bypass through intent settlement**, which collects zero fees and allows users to avoid the protocol's 70/20/10 fee distribution entirely. Several medium-severity issues around DoS vectors in the fee management system and CEI pattern violations were also identified.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 6 |
| Low | 7 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 108 |
| Passed | 93 |
| Failed | 7 |
| Partial | 8 |
| **Compliance Score** | **86.1%** |

Top 5 most important failed checks:
1. **SOL-EC-13**: CEI pattern violated in `settleTrade()` -- state changes after external transfers
2. **SOL-AM-DOSA-3**: No handling for blacklisted tokens blocking `_claimAllPendingFees()`
3. **SOL-AM-FrA-4**: Commit-reveal scheme not enforced in `settleTrade()`
4. **SOL-Basics-AL-9/10**: `_claimAllPendingFees()` loop over 100 tokens with external calls
5. **SOL-AM-DOSA-2**: No minimum transaction amount enforced

---

## Critical Findings

### [C-01] Intent Settlement Collects Zero Fees -- Complete Fee Bypass Path
**Severity:** Critical
**Category:** Business Logic
**VP Reference:** N/A (Protocol-specific invariant violation)
**Location:** `settleIntent()` (lines 1087-1142)
**Sources:** Agent-A, Agent-B, Cyfrin, Solodit (Perennial V2.4, Yieldoor)
**Real-World Precedent:** Perennial V2.4 (Sherlock 2025) -- users bypass epoch fees via alternative settlement path; Yieldoor (Sherlock 2025) -- deposit fee bypass

**Description:**
The `settleTrade()` function correctly deducts and distributes trading fees (maker 0.1%, taker 0.2%) with the 70/20/10 split. However, `settleIntent()` performs a bilateral token swap without deducting any fees, calling no fee-related functions whatsoever. This creates a completely fee-free trading path that bypasses the protocol's economic model.

Additionally, the `IntentCollateral` struct has no `matchingValidator` field, making fee attribution to the validator impossible even if fees were added.

**Exploit Scenario:**
1. Trader A and Solver B agree on a trade off-chain
2. Trader A calls `lockIntentCollateral()` to escrow their tokens
3. Solver B calls `settleIntent()` to complete the swap
4. Zero fees are collected -- ODDAO, staking pool, and validators receive nothing
5. All rational traders migrate to intent-based settlement to avoid fees entirely

**Recommendation:**
1. Add fee calculation and distribution to `settleIntent()`:
```solidity
// In settleIntent(), before transfers:
uint256 traderFee = (coll.traderAmount * SPOT_MAKER_FEE) / BASIS_POINTS_DIVISOR;
uint256 solverFee = (coll.solverAmount * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;
// Deduct fees from transfer amounts, distribute via _accrueFeeSplit()
```
2. Add `address matchingValidator` to the `IntentCollateral` struct and accept it in `lockIntentCollateral()`

---

## High Findings

### [H-01] `applyFeeRecipients()` Missing `nonReentrant` -- ERC777 Reentry Risk
**Severity:** High
**Category:** Reentrancy (SC08)
**VP Reference:** VP-02 (Cross-Function Reentrancy), VP-05 (ERC777 Callback)
**Location:** `applyFeeRecipients()` (lines 857-877), `_claimAllPendingFees()` (lines 1559-1580)
**Sources:** Agent-A, Cyfrin, Solodit (Popcorn, Concur Finance, AI Arena, Beanstalk Wells)
**Real-World Precedent:** Popcorn Protocol (Code4rena 2023) -- $HIGH -- ERC777 reentrancy in `claimRewards`; LendfMe (2020) -- $25M -- ERC777 imBTC reentrancy

**Description:**
`applyFeeRecipients()` is marked `onlyOwner` but NOT `nonReentrant`. It calls `_claimAllPendingFees()` which iterates over `feeTokens` and performs `safeTransfer()` to the old ODDAO and staking pool addresses. If any fee token is ERC777, the `tokensReceived` callback could re-enter the contract. While the inner loop follows CEI (zeroing `accruedFees` before transfer), the outer function updates `feeRecipients` state after both loops complete, creating a window for cross-function reentrancy.

**Recommendation:**
Add `nonReentrant` modifier to `applyFeeRecipients()`:
```solidity
function applyFeeRecipients() external onlyOwner nonReentrant {
```

---

### [H-02] Reverting Token in `feeTokens` Permanently Blocks Fee Recipient Changes
**Severity:** High
**Category:** Denial of Service (SC09)
**VP Reference:** VP-30 (DoS via Unexpected Revert)
**Location:** `_claimAllPendingFees()` (lines 1559-1580), `_trackFeeToken()` (lines 1540-1548)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin (SOL-AM-DOSA-3, SOL-Basics-AL-9/10), Solodit (Paladin Valkyrie, Vader, Yield, Insure, OZ Managed Oracle)
**Real-World Precedent:** Paladin Valkyrie V2.0 (Cyfrin 2025) -- Critical -- unbounded reward array DoS

**Description:**
`_claimAllPendingFees()` iterates over all tracked fee tokens (up to `MAX_FEE_TOKENS = 100`) and calls `safeTransfer()` for each with a nonzero balance. If any single token's `transfer()` reverts (paused, blacklisted recipient, self-destructed), the entire `applyFeeRecipients()` transaction reverts, permanently blocking fee recipient updates. The `feeTokens` array can only grow and never shrink -- there is no function to remove tokens.

**Exploit Scenario:**
1. A token traded on the DEX is added to `feeTokens`
2. The token admin pauses the token or blacklists the ODDAO address
3. `applyFeeRecipients()` always reverts when trying to force-claim that token
4. Fee recipients can never be updated again

**Recommendation:**
1. Wrap individual transfers in try/catch:
```solidity
if (amount > 0) {
    accruedFees[recipient][token] = 0;
    try IERC20(token).transfer(recipient, amount) {
        emit FeesClaimed(recipient, token, amount);
    } catch {
        accruedFees[recipient][token] = amount; // Re-credit on failure
    }
}
```
2. Add an `onlyOwner` function to remove tokens from the `feeTokens` array

---

### [H-03] No `matchingValidator` in `IntentCollateral` -- Fee Attribution Impossible
**Severity:** High
**Category:** Business Logic
**VP Reference:** N/A (Protocol-specific)
**Location:** `IntentCollateral` struct (lines 140-150), `settleIntent()` (lines 1087-1142)
**Sources:** Agent-B

**Description:**
The `IntentCollateral` struct stores trader, solver, tokens, amounts, and deadline, but has no field for `matchingValidator`. Even if C-01 is fixed to add fee distribution to intent settlement, the validator's 10% fee share cannot be attributed because the validator address is not recorded at lock time and not passed at settlement time.

**Recommendation:**
Add `address matchingValidator` to the `IntentCollateral` struct:
```solidity
struct IntentCollateral {
    address trader;
    bool locked;
    bool settled;
    address solver;
    address matchingValidator; // NEW
    address tokenIn;
    address tokenOut;
    uint256 traderAmount;
    uint256 solverAmount;
    uint256 deadline;
}
```

---

## Medium Findings

### [M-01] Daily Volume Tracking Only Counts Maker Side
**Severity:** Medium
**Category:** Business Logic (SC02)
**VP Reference:** N/A
**Location:** `settleTrade()` (lines 750-751), `_checkVolumeLimits()` (lines 1684-1700)
**Sources:** Agent-A, Agent-B

**Description:**
`totalTradingVolume` and `dailyVolumeUsed` only increment by `makerOrder.amountIn`. The taker's volume is not counted. The `_checkVolumeLimits()` function only checks `dailyVolumeUsed + makerOrder.amountIn` against `dailyVolumeLimit`, ignoring the taker's contribution. This effectively doubles the real daily volume limit and underreports trading statistics by ~50%.

**Recommendation:**
Track both sides: `dailyVolumeUsed += makerOrder.amountIn + takerOrder.amountIn;` or document that volume is intentionally one-sided and adjust limits accordingly.

---

### [M-02] Fee-on-Transfer Check Missing for Fee Transfers
**Severity:** Medium
**Category:** Token Integration (SC06)
**VP Reference:** VP-46 (Fee-on-Transfer)
**Location:** `_executeAtomicSettlement()` (lines 1413-1418, 1439-1444)
**Sources:** Agent-B, Agent-D
**Real-World Precedent:** ZABU Finance (2021) -- fee-on-transfer token exploit

**Description:**
The M-07 balance-before/after check is applied to net transfers to counterparties (lines 1399-1410, 1425-1436) but NOT to the fee transfers to `address(this)` at lines 1413-1418 and 1439-1444. If a fee-on-transfer token passes the net transfer check but takes a fee on the contract transfer, `accruedFees` would overcount, creating an accounting deficit.

**Recommendation:**
Add balance checks to fee transfers, or consolidate all transfers into a single `safeTransferFrom` of the full `amountIn` to the contract, then distribute.

---

### [M-03] Commit-Reveal is Optional -- MEV Protection Unenforced
**Severity:** Medium
**Category:** Front-Running (SC02)
**VP Reference:** VP-34 (Transaction Ordering Dependence)
**Location:** `settleTrade()` (lines 696-779), `commitOrder()` (line 627)
**Sources:** Agent-A, Agent-B, Agent-D, Cyfrin (SOL-AM-FrA-4)

**Description:**
The commit-reveal mechanism (`commitOrder` + `revealOrder`) is entirely optional. `settleTrade()` does not verify that either order was committed/revealed before settlement. The NatSpec acknowledges this: "Users commit order hash (optional, MEV protection)". This means the advertised MEV protection provides zero guarantee.

**Recommendation:**
Either enforce commit-reveal in `settleTrade()` for trades above a configurable threshold, or clearly document in NatSpec and user-facing documentation that commit-reveal is opt-in and MEV protection is not guaranteed. Consider Avalanche's fast finality (1-2s) as a partial mitigation.

---

### [M-04] Timelock Can Be Overwritten by Scheduling New Change
**Severity:** Medium
**Category:** Access Control (SC01)
**VP Reference:** N/A
**Location:** `scheduleFeeRecipients()` (lines 827-849), `scheduleTradingLimits()` (lines 887-906)
**Sources:** Agent-B, Solodit (OZ TimelockController CVE-2021-39167)

**Description:**
Both `scheduleFeeRecipients()` and `scheduleTradingLimits()` allow the owner to call them again while a pending change exists, overwriting the pending values and resetting the timelock. The owner could schedule a benign change for community review, then overwrite it with a malicious change just before expiry.

**Recommendation:**
Revert if a pending change exists: `require(feeRecipientsTimelockExpiry == 0, "Pending change exists");` Add a `cancelScheduledFeeRecipients()` function.

---

### [M-05] `settleIntent()` CEI Violation -- State Updated After External Calls
**Severity:** Medium
**Category:** Reentrancy (SC08)
**VP Reference:** VP-01 (Classic Reentrancy -- mitigated by nonReentrant)
**Location:** `settleIntent()` (lines 1087-1142)
**Sources:** Agent-A, Cyfrin (SOL-EC-13), Solodit (OZ TimelockController CVE)

**Description:**
In `settleIntent()`, `coll.settled = true` occurs at line 1133, AFTER two external token transfers (lines 1111-1114, 1121-1125). While `nonReentrant` prevents exploitation, this violates the CEI pattern. View functions like `getIntentCollateral()` would return stale state during the transfer window, enabling read-only reentrancy if other contracts depend on this state.

**Recommendation:**
Move `coll.settled = true` before the external calls (after access control check at line 1108). Zero gas cost, improved defense-in-depth.

---

### [M-06] Rebasing Tokens Can Cause Stuck Intent Escrow
**Severity:** Medium
**Category:** Token Integration
**VP Reference:** VP-47 (Rebasing Token)
**Location:** `lockIntentCollateral()`, `settleIntent()`, `cancelIntent()` flow
**Sources:** Agent-D, Solodit (Cyfrin Escrow 2023)
**Real-World Precedent:** Cyfrin Escrow (2023) -- Medium -- rebasing token + fixed-amount escrow = stuck funds

**Description:**
If a rebasing token (e.g., stETH, AMPL) is used as `tokenIn`, the trader locks `traderAmount` tokens into escrow. If a negative rebase occurs before settlement, the contract holds fewer tokens than `traderAmount`, causing `safeTransfer` in `settleIntent()` or `cancelIntent()` to revert. The M-07 fee-on-transfer guard catches fee-on-transfer tokens but does not protect against post-deposit rebases.

**Recommendation:**
Document that rebasing tokens are not supported for intent settlement, or use share-based accounting (store the actual received balance, not the requested amount).

---

## Low Findings

### [L-01] `scheduleTradingLimits()` Allows Zero `maxTradeSize` / `dailyVolumeLimit`
**Location:** `scheduleTradingLimits()` (lines 887-906)
**Sources:** Agent-A (VP-23), Agent-C

Setting `maxTradeSize = 0` or `dailyVolumeLimit = 0` after the 48-hour timelock would permanently block all trades. Add `require(_maxTradeSize > 0 && _dailyVolumeLimit > 0)`.

### [L-02] `feeTokens` Array Can Only Grow, Never Shrink
**Location:** `_trackFeeToken()` (lines 1540-1548)
**Sources:** Agent-C, Solodit (Paladin Valkyrie)

Once filled to `MAX_FEE_TOKENS = 100`, no new fee tokens can be tracked, blocking settlement of trades with new token pairs. Add an `onlyOwner` removal function.

### [L-03] Emergency Stop and Pause Are Redundant and Inconsistently Applied
**Location:** Multiple functions
**Sources:** Agent-B

`emergencyStop` and `whenNotPaused` serve overlapping purposes but are applied inconsistently. `lockIntentCollateral()` checks `whenNotPaused` but not `emergencyStop`. Unify into a single mechanism.

### [L-04] Slippage Check Is One-Directional -- Taker Not Protected
**Location:** `_checkSlippage()` (lines 1607-1624)
**Sources:** Agent-B

The slippage check only validates `takerOrder.amountIn >= makerOrder.amountOut * (1 - slippage)`. No symmetric check protects the taker. Per-order signed amounts provide implicit protection, but the explicit check is asymmetric.

### [L-05] `lockIntentCollateral()` Does Not Check `emergencyStop`
**Location:** `lockIntentCollateral()` (line 1012-1020)
**Sources:** Agent-B

Users can still lock collateral during an emergency stop. If settlement remains disabled, collateral is stuck until the deadline passes.

### [L-06] No `tokenIn != tokenOut` Validation in Orders
**Location:** `_verifyOrdersMatch()` (lines 1803-1830)
**Sources:** Agent-A (VP-23)

A user could sign an order where `tokenIn == tokenOut`. The matching logic would pass, creating a pointless self-swap that wastes gas and pays fees.

### [L-07] `TradingLimitsChangeScheduled` Event Missing Slippage Parameter
**Location:** `scheduleTradingLimits()` (line 901-905)
**Sources:** Agent-C

The event emits `newMaxTradeSize`, `newDailyVolumeLimit`, and `effectiveAt`, but not `_maxSlippageBps`. Monitoring systems cannot observe pending slippage changes.

---

## Informational Findings

### [I-01] `totalFeesCollected` Mixes Token Decimals
**Location:** `_distributeFees()` (line 1468)
**Sources:** Agent-A, Agent-B

Sums fees across tokens with different decimals into a single counter, making the statistic meaningless for analytics.

### [I-02] No Partial Fill Support
**Location:** `settleTrade()` (lines 696-779)
**Sources:** Agent-B

Orders are marked as fully filled after settlement. The off-chain order book handles order splitting, which is an acceptable design tradeoff.

### [I-03] `abi.encodePacked` on Fixed-Size Values
**Location:** `settleTrade()` (line 762)
**Sources:** Cyfrin (SOL-Basics-VI-SVI-4)

`keccak256(abi.encodePacked(makerHash, takerHash))` uses two `bytes32` values. No collision risk exists with fixed-size types.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Perennial V2.4 | 2025 | N/A (caught in audit) | Alternative settlement path bypasses fee collection -- mirrors C-01 |
| Yieldoor | 2025 | N/A (caught in audit) | Deposit fee bypass via implementation bug -- mirrors C-01 |
| Popcorn Protocol | 2023 | High | ERC777 reentrancy in reward claim -- mirrors H-01 |
| LendfMe | 2020 | $25M | ERC777 imBTC reentrancy -- mirrors H-01 |
| Paladin Valkyrie V2.0 | 2025 | Critical | Unbounded reward array DoS -- mirrors H-02 |
| ZABU Finance | 2021 | N/A | Fee-on-transfer token exploit -- mirrors M-02 |
| OZ TimelockController | 2021 | $25K bounty | Timelock bypass/manipulation -- mirrors M-04 |
| Cyfrin Escrow | 2023 | Medium | Rebasing token + fixed-amount escrow -- mirrors M-06 |

## Solodit Similar Findings

6 of the findings have direct parallels in the Solodit database:
- **C-01** (fee bypass): Perennial V2.4, Yieldoor -- "alternative code paths missing fee logic"
- **H-01** (ERC777 reentrancy): Popcorn, Concur Finance, AI Arena, Beanstalk Wells
- **H-02** (array DoS): Paladin Valkyrie (Critical), Vader, Yield, Insure Finance, OZ Oracle
- **M-04** (timelock overwrite): OZ TimelockController CVE-2021-39167/39168
- **M-05** (CEI violation): OZ TimelockController, Beanstalk Wells, CodeHawks 2025
- **M-06** (rebasing escrow): Cyfrin Escrow 2023

## Static Analysis Summary

### Slither
Skipped -- full-project analysis timed out (>5 minutes). Prior audits used Slither successfully.

### Aderyn
Skipped -- crashed with internal error on import resolution (v0.6.8). Known workspace compatibility issue.

### Solhint
2 warnings, 0 errors:
1. `max-states-count` -- 22 state declarations vs. 20 allowed (acceptable for contract complexity)
2. `gas-indexed-events` -- `nonce` on `OrderCancelled` could be indexed

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (`Ownable2Step`) | `scheduleFeeRecipients`, `applyFeeRecipients`, `scheduleTradingLimits`, `applyTradingLimits`, `emergencyStopTrading`, `resumeTrading`, `pause`, `unpause` | 6/10 |
| Anyone (permissionless) | `commitOrder`, `settleTrade`, `lockIntentCollateral`, `invalidateNonce`, `invalidateNonceWord`, `claimFees` | N/A |
| Trader only (self-auth) | `revealOrder` (order.trader), `cancelIntent` (coll.trader) | N/A |
| Bilateral (trader+solver) | `settleIntent` (coll.trader or coll.solver) | N/A |

## Centralization Risk Assessment

**Single-key maximum damage:** Owner can halt all trading indefinitely (`pause` + `emergencyStopTrading`) and redirect future fee accruals to attacker-controlled addresses (with 48-hour delay). Owner CANNOT steal user token balances, drain intent collateral, forge trade signatures, or execute settlements without valid dual signatures. No `emergencyWithdraw` or `sweep` function exists.

**Risk Rating: 6/10** -- Moderate centralization. Owner has significant operational power (pause, fee redirect) but no fund extraction capability. Mitigated by 48-hour timelock and Ownable2Step.

**Recommendation:** Deploy with a multi-sig (Gnosis Safe) as owner. Consider governance-controlled ownership transfer after mainnet stabilization.

---

## Positive Security Features

The contract demonstrates strong security engineering:

1. **ReentrancyGuard** on all user-facing settlement and claim functions
2. **Ownable2Step** for safe ownership transfers
3. **EIP-712** typed data signing with proper domain separation
4. **SafeERC20** for all token interactions
5. **Nonce bitmap** (Uniswap Permit2 pattern) for efficient concurrent order support
6. **Fee-on-transfer detection** via balance-before/after checks (M-07)
7. **48-hour timelock** on critical admin parameter changes
8. **Pull-pattern** for fee claims (avoiding push-pattern DoS)
9. **Self-trade prevention** (line 1359)
10. **No emergencyWithdraw** -- owner fundamentally cannot extract user funds
11. **`cancelIntent` not pausable** -- users always have an escape path for locked funds
12. **Remainder-to-ODDAO** for rounding dust handling (M-02)

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
