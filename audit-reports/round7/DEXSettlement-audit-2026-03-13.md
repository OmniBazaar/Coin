# Security Audit Report: DEXSettlement (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Deep Security Review)
**Contract:** `Coin/contracts/dex/DEXSettlement.sol`
**Solidity Version:** 0.8.25
**Lines of Code:** 2,191
**Upgradeable:** No (Ownable2Step, immutable deployment)
**Handles Funds:** Yes (direct token transfers via `safeTransferFrom`, intent collateral escrow, fee distribution)
**Previous Audits:** Round 4 (2026-02-28), Round 6 (2026-03-10)
**Test Suite:** 33 tests, all passing

---

## Executive Summary

DEXSettlement has been through extensive remediation across Rounds 4 and 6. This Round 7 audit reviews the current post-remediation state of the contract (2,191 lines) and finds the contract is in strong security posture for mainnet deployment. All Critical and High findings from Rounds 4 and 6 have been properly remediated:

- **H-01 (CEI violation in `settleTrade()`):** FIXED -- state updates now precede all external calls
- **H-02 (cross-token fee mismatch in `settleIntent()`):** FIXED -- both rebate and fee now calculated on `solverAmount` (tokenOut)
- **M-01 (no timelock on fee recipients):** FIXED -- `scheduleFeeRecipients()` / `applyFeeRecipients()` with 48-hour timelock
- **M-03 (taker double-pull griefing):** FIXED -- consolidated into single `safeTransferFrom` to contract, then internal distribution
- **M-04 (gas griefing in `_claimAllPendingFees`):** FIXED -- 100,000 gas stipend on low-level calls

This Round 7 review identifies **0 critical**, **0 high**, **2 medium**, **5 low**, and **6 informational** findings. The contract is well-engineered with comprehensive security controls. The remaining findings are defense-in-depth improvements and minor gas/hygiene items, none of which represent exploitable vulnerabilities given the whitelisted token model and Avalanche deployment context.

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 5 |
| Informational | 6 |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (`Ownable2Step`) | `scheduleFeeRecipients`, `applyFeeRecipients`, `cancelScheduledFeeRecipients`, `scheduleTradingLimits`, `applyTradingLimits`, `cancelScheduledTradingLimits`, `emergencyStopTrading`, `resumeTrading`, `pause`, `unpause`, `removeFeeToken` | 5/10 |
| Anyone (permissionless) | `commitOrder`, `settleTrade`, `invalidateNonce`, `invalidateNonceWord`, `claimFees` | N/A |
| Trader only (self-auth) | `revealOrder` (order.trader == `_msgSender()`), `lockIntentCollateral` (caller becomes coll.trader), `cancelIntent` (coll.trader only, after deadline) | N/A |
| Bilateral (trader or solver) | `settleIntent` (coll.trader or coll.solver) | N/A |

**Owner Capabilities:**
- Halt all trading indefinitely (`pause` + `emergencyStopTrading`)
- Redirect future fee flows with 48-hour timelock (`scheduleFeeRecipients` / `applyFeeRecipients`)
- Modify trading limits with 48-hour timelock (`scheduleTradingLimits` / `applyTradingLimits`)
- Remove tracked fee tokens (`removeFeeToken`)

**Owner CANNOT:**
- Steal user token balances held externally
- Drain intent collateral (no sweep/withdraw function)
- Forge trade signatures or settle without valid dual EIP-712 signatures
- Bypass `renounceOwnership` (disabled, reverts with `InvalidAddress`)
- Overwrite pending timelocked changes (reverts with `PendingChangeExists`)

**Centralization Risk: 5/10** -- Reduced from Round 6's 6/10. The addition of the 48-hour timelock on fee recipient changes significantly improves the trust model. Deployment with a multi-sig (Gnosis Safe) as owner remains strongly recommended.

---

## Medium Findings

### [M-01] `settleIntent()` Missing Fee-on-Transfer Check on Solver Fee Transfer

**Severity:** Medium
**Category:** Token Integration / Accounting
**Location:** `settleIntent()` lines 1347-1353

**Description:**

In `settleIntent()`, the solver's net amount transfer to the trader has a balance-before/after check (lines 1332-1345), but the separate `solverFee` transfer from the solver to the contract at lines 1349-1353 does NOT have a corresponding balance check:

```solidity
// Lines 1347-1353: No balance-before/after check
if (solverFee > 0) {
    IERC20(coll.tokenOut).safeTransferFrom(
        coll.solver,
        address(this),
        solverFee
    );
}
```

If `coll.tokenOut` were a fee-on-transfer token that passed the earlier balance check (e.g., because the fee is only applied on transfers to contracts, not EOAs), the contract would receive fewer tokens than `solverFee`. The subsequent `safeTransfer` calls distributing the fee would then attempt to transfer more than received. This is **fail-safe** (the transaction would revert atomically), but it creates an inconsistency with the M-07 remediation philosophy of explicit detection and clear error messaging.

**Practical Impact:** Low. The whitelisted token model (XOM, USDC, WBTC, WETH) means fee-on-transfer tokens are not expected. The atomic revert provides defense-in-depth. However, the inconsistency means the error message would be a generic SafeERC20 revert rather than the explicit `FeeOnTransferNotSupported` error.

**Recommendation:**

Add a balance check on the solver fee transfer for consistency:

```solidity
if (solverFee > 0) {
    uint256 feeBalBefore = IERC20(coll.tokenOut).balanceOf(address(this));
    IERC20(coll.tokenOut).safeTransferFrom(
        coll.solver, address(this), solverFee
    );
    uint256 feeBalAfter = IERC20(coll.tokenOut).balanceOf(address(this));
    if (feeBalAfter - feeBalBefore != solverFee) {
        revert FeeOnTransferNotSupported();
    }
}
```

---

### [M-02] `settleIntent()` Solver Requires Two Separate Approvals -- Allowance Race Condition

**Severity:** Medium
**Category:** Token Integration / UX
**Location:** `settleIntent()` lines 1334 and 1349

**Description:**

In `settleIntent()`, the solver's tokens are transferred in two separate `safeTransferFrom` calls:

1. Lines 1334-1338: `safeTransferFrom(solver, trader, solverNet)` -- net amount to trader
2. Lines 1349-1353: `safeTransferFrom(solver, contract, solverFee)` -- fee to contract

The solver must approve a total of `solverNet + solverFee = solverAmount` to this contract. Both transfers draw from the same allowance, which works correctly in the normal case. However, there is a subtle issue:

If the solver has approved exactly `solverAmount`, and between the first transfer (which decrements allowance by `solverNet`) and the second transfer (which decrements by `solverFee`), a front-running transaction changes the solver's allowance (e.g., via a separate `approve` call the solver submitted concurrently), the second transfer could fail, reverting the entire settlement.

This is not directly exploitable (atomic revert is safe), but it is a UX concern: the solver must ensure their allowance is stable during the settlement window. On Avalanche with 1-2 second finality, the practical window is very narrow.

More importantly, this mirrors the Round 6 M-03 finding for `_executeAtomicSettlement()` which was remediated by consolidating into a single pull. The same pattern should be applied to `settleIntent()` for consistency.

**Recommendation:**

Consider transferring the full `solverAmount` from the solver to the contract in a single `safeTransferFrom`, then distributing internally:

```solidity
// Single pull from solver
IERC20(coll.tokenOut).safeTransferFrom(coll.solver, address(this), coll.solverAmount);

// Internal distribution
uint256 solverNet = coll.solverAmount - solverFee;
if (solverNet > 0) {
    IERC20(coll.tokenOut).safeTransfer(coll.trader, solverNet);
}
// solverFee remains in contract for fee distribution
```

This reduces external calls from 2 to 1 and eliminates the allowance race condition.

---

## Low Findings

### [L-01] Slippage Check Is Asymmetric -- Only Validates One Direction

**Severity:** Low
**Location:** `_checkSlippage()` lines 1870-1887

**Description:**

The slippage check validates:
```solidity
uint256 minAcceptable = (makerOrder.amountOut
    * (BASIS_POINTS_DIVISOR - maxSlippageBps))
    / BASIS_POINTS_DIVISOR;
if (takerOrder.amountIn < minAcceptable) {
    revert SlippageTooHigh();
}
```

This checks that the taker provides at least `(1 - slippage)` of the maker's requested output. It does NOT symmetrically check that the maker provides at least `(1 - slippage)` of the taker's requested output. Both parties sign their exact amounts, providing implicit protection, but the explicit on-chain slippage check is one-directional.

**Impact:** Low. Both parties have signed their exact amounts, so neither can be made to give more or receive less than they explicitly agreed to. The slippage check is a system-level safety guard against the matching engine constructing unfair matches, not a per-party protection. The asymmetry means the check only catches one class of unfair matches.

**Recommendation:** Add a symmetric check:
```solidity
uint256 minMakerProvide = (takerOrder.amountOut
    * (BASIS_POINTS_DIVISOR - maxSlippageBps))
    / BASIS_POINTS_DIVISOR;
if (makerOrder.amountIn < minMakerProvide) {
    revert SlippageTooHigh();
}
```

**Status from Round 6:** NOT FIXED (carried forward). Low priority.

---

### [L-02] `emergencyStop` and `pause` Are Redundant

**Severity:** Low
**Location:** Multiple functions

**Description:**

The contract has two independent halt mechanisms applied to settlement functions:
- `emergencyStop` (boolean flag, checked manually: `if (emergencyStop) revert EmergencyStopActive()`)
- `whenNotPaused` (OpenZeppelin Pausable modifier)

Both are controlled by the owner. Application is consistent (both are checked on `settleTrade`, `lockIntentCollateral`, `settleIntent`), but redundant. `cancelIntent()` and `claimFees()` correctly skip both checks so users can always reclaim funds and fees.

Having two mechanisms adds ~2,100 gas per settlement call (one SLOAD for `emergencyStop` + the modifier check). More importantly, it creates potential confusion about which to use in an emergency.

**Recommendation:** Consider consolidating into a single mechanism. If distinct semantics are needed (e.g., `pause` = temporary maintenance, `emergencyStop` = permanent until explicit resume), document the distinction clearly in NatSpec.

**Status from Round 6:** NOT FIXED (carried forward). By-design decision.

---

### [L-03] `cancelIntent()` Does Not Prevent IntentId Reuse After Cancellation

**Severity:** Low
**Location:** `cancelIntent()` lines 1392-1423

**Description:**

When an intent is cancelled, `coll.locked` is set to `false` (line 1411) but the storage record persists. Since `lockIntentCollateral()` only checks `coll.locked` (line 1207), the same `intentId` can be re-locked after cancellation. This allows intentId recycling, creating confusing event history:

```
IntentCollateralLocked(intentId, traderA, solverA, ...)
IntentCancelled(intentId, "Cancelled by trader")
IntentCollateralLocked(intentId, traderA, solverB, ...)  // Reused!
IntentSettled(intentId, traderA, solverB, ...)
```

Off-chain indexers that track intent lifecycle by `intentId` would need to handle this case.

**Recommendation:** Add a `cancelled` flag to `IntentCollateral` and check it in `lockIntentCollateral()`:
```solidity
if (intentCollateral[intentId].locked || intentCollateral[intentId].cancelled) {
    revert CollateralAlreadyLocked();
}
```

Or document that intentId recycling is accepted behavior and off-chain indexers must handle it.

**Status from Round 6:** NOT FIXED (carried forward). Low priority.

---

### [L-04] `maxSlippageBps` Can Be Set to Zero via Timelock, Disabling Slippage Protection

**Severity:** Low
**Location:** `scheduleTradingLimits()` line 1010; `_checkSlippage()` line 1874

**Description:**

`scheduleTradingLimits()` validates `_maxSlippageBps <= MAX_SLIPPAGE_BPS` (upper bound at 1000 bps = 10%) and rejects zero for `_maxTradeSize` and `_dailyVolumeLimit`, but does NOT reject zero for `_maxSlippageBps`. In `_checkSlippage()`:

```solidity
if (maxSlippageBps == 0) return; // No slippage check at all
```

Setting `maxSlippageBps = 0` via the 48-hour timelock completely disables the on-chain slippage guard. While the timelock provides a 48-hour observation window, silently disabling a safety mechanism is undesirable.

**Recommendation:** Add `if (_maxSlippageBps == 0) revert InvalidParameters();` in `scheduleTradingLimits()`.

**Status from Round 6:** NOT FIXED (carried forward). Low priority.

---

### [L-05] `_verifyOrdersMatch()` Missing Explicit `tokenIn != tokenOut` Check on Taker Order

**Severity:** Low
**Location:** `_verifyOrdersMatch()` lines 2071-2103

**Description:**

The L-06 remediation added `tokenIn != tokenOut` validation but only on the maker order (line 2076):

```solidity
if (makerOrder.tokenIn == makerOrder.tokenOut) {
    revert InvalidOrder();
}
```

The taker order is not explicitly checked. The cross-matching checks (`makerOrder.tokenIn != takerOrder.tokenOut` and `makerOrder.tokenOut != takerOrder.tokenIn`) combined with the maker self-check implicitly prevent `takerOrder.tokenIn == takerOrder.tokenOut` (since that would force `makerOrder.tokenIn == makerOrder.tokenOut`). However, this implicit protection is hard to reason about and violates the defense-in-depth principle.

**Recommendation:** Add an explicit check:
```solidity
if (takerOrder.tokenIn == takerOrder.tokenOut) {
    revert InvalidOrder();
}
```

**Status from Round 6:** NOT FIXED (carried forward). Low priority.

---

## Informational Findings

### [I-01] `totalFeesCollected` Mixes Token Decimals -- Meaningless Counter

**Location:** State variable line 240; updated at lines 711, 1373

**Description:**

`totalFeesCollected` sums fee amounts across all tokens into a single `uint256`. Tokens have different decimals (18 for XOM/WETH, 6 for USDC, 8 for WBTC), making this counter meaningless for analytics. For example, collecting 1 WBTC fee (1e8) and 100 USDC fee (100e6) yields `totalFeesCollected = 1e8 + 1e8 = 2e8`, which is neither the total in WBTC terms nor USDC terms.

No on-chain logic depends on this value. It is purely informational.

**Recommendation:** Either remove the counter (saves ~5,000 gas per settlement from the SLOAD+SSTORE) or add per-token fee tracking. The gas savings from removal is material at high trading volumes (10,000+ orders/sec target).

**Status:** Carried forward from Round 4, Round 6. Accepted as informational.

---

### [I-02] `FeesDistributed` Event Amounts Are Recalculated, Not Actual Transfer Amounts

**Location:** `_distributeFeesWithRebate()` lines 1728-1731

**Description:**

The event emits recalculated LP and vault amounts:
```solidity
uint256 lpAmt = (netFee * LP_SHARE) / BASIS_POINTS_DIVISOR;
uint256 vaultAmt = netFee - lpAmt;
```

But the actual transfers in `_accrueFeeSplit()` calculate:
```solidity
uint256 lpShare = (fee * LP_SHARE) / BASIS_POINTS_DIVISOR;
uint256 vaultShare = fee - lpShare;
```

Both use the same formula so the amounts match. However, the event calculation is a duplicate computation. If `_accrueFeeSplit()` were ever modified to change the split logic without updating `_distributeFeesWithRebate()`, the event would emit incorrect amounts.

**Recommendation:** Return the actual split amounts from `_accrueFeeSplit()` and use them in the event emission, or accept the current design since both calculations are identical.

---

### [I-03] Commit-Reveal MEV Protection Is Entirely Optional

**Location:** `settleTrade()` lines 767-861; `commitOrder()` line 688; `revealOrder()` line 713

**Description:**

The contract provides commit-reveal infrastructure (`commitOrder`, `revealOrder`, `MIN_COMMIT_BLOCKS`, `MAX_COMMIT_BLOCKS`) but `settleTrade()` never checks whether either order was committed or revealed. The NatSpec documents this: "Commit-reveal is opt-in; MEV protection is not guaranteed without it (M-03)."

On Avalanche with Snowman consensus (1-2 second finality), mempool front-running is significantly less practical than on Ethereum. The off-chain matching model (validators match, anyone settles) also reduces MEV exposure since matched pairs are already agreed with fixed signed prices.

**Assessment:** Accepted architectural decision. Practical MEV risk on Avalanche is low. The commit-reveal infrastructure is available for high-value trades that opt in.

**Status:** Carried forward from Rounds 4 and 6. Acknowledged.

---

### [I-04] ERC2771Context Trust Assumption -- Forwarder Impersonation Power

**Location:** Constructor line 649; `_msgSender()` override lines 2153-2160

**Description:**

The `trustedForwarder_` address set at construction can impersonate any user for all `_msgSender()` calls. If the forwarder contract (OmniForwarder) is compromised, an attacker could:

- Call `commitOrder` as any trader
- Call `revealOrder` as any trader
- Call `lockIntentCollateral` as any trader (escrowing their tokens via approved allowances)
- Call `cancelIntent` as any trader (but only after deadline)
- Call `claimFees` for any address
- Call `invalidateNonce` for any trader (canceling their pending orders)

The forwarder CANNOT:
- Call `settleTrade` maliciously (dual EIP-712 signatures still required)
- Call admin functions (Ownable `_msgSender` is also ERC2771-aware, so this IS a risk if forwarder is compromised AND owner has approved the forwarder)

**Mitigation:** The OmniForwarder inherits OpenZeppelin's `ERC2771Forwarder` which has nonce management, deadline checking, and EIP-712 signature verification. It is immutable (no admin functions). The forwarder address in DEXSettlement is also immutable (set at construction, cannot be changed).

**Recommendation:** This is an accepted trust model. Ensure the OmniForwarder is deployed with audited, immutable code. Consider deploying with `address(0)` as forwarder if gasless meta-transactions are not needed at launch, then redeploying with the forwarder address when the feature is activated.

---

### [I-05] Solhint Warnings: Function Ordering, Complexity, and Line Count

**Location:** Multiple

**Description:**

Solhint reports 11 warnings (0 errors):

| Warning | Location | Assessment |
|---------|----------|------------|
| `max-states-count` (22 vs 20 allowed) | Contract-level | Accepted. The 22 state variables are necessary for the contract's feature set (base settlement + intent settlement + timelocks for 2 admin functions + fee tracking). |
| `gas-indexed-events` -- `nonce` on `OrderCancelled` | Line 312 | Consider indexing for efficient off-chain filtering by nonce. |
| `gas-indexed-events` -- `newMaxSlippageBps` on `TradingLimitsChangeScheduled` | Line 428 | Low value to index; `effectiveAt` is more useful. |
| `gas-indexed-events` -- `effectiveAt` on `TradingLimitsChangeScheduled` | Line 428 | Consider indexing for governance monitoring. |
| `gas-indexed-events` -- `effectiveAt` on `FeeRecipientsChangeScheduled` | Line 448 | Consider indexing for governance monitoring. |
| `ordering` -- `removeFeeToken` after `renounceOwnership` | Line 1124 | Minor ordering issue. `removeFeeToken` is external but placed after the `public pure` `renounceOwnership` override. |
| `code-complexity` -- `lockIntentCollateral` (9 vs 7) | Line 1192 | Accepted. The complexity comes from necessary validation checks. |
| `function-max-lines` -- `settleIntent` (103 vs 100) | Line 1280 | 3 lines over limit. Could be reduced by extracting fee distribution into a helper, but readability is good as-is. |
| `code-complexity` -- `settleIntent` (11 vs 7) | Line 1280 | Accepted. The complexity comes from fee calculation, distribution, and balance checks -- all necessary for correctness. |
| `avoid-low-level-calls` | Line 1820 | Intentional. The low-level call in `_claimAllPendingFees` is necessary to handle reverting tokens without blocking fee recipient changes. |
| `reentrancy` -- state change after transfer | Line 1838 | False positive. The `accruedFees[recipient][token] = amount` re-credit at line 1838 is a failure recovery path inside the `_claimAllPendingFees` try/catch pattern, not a reentrancy vulnerability. The function is called from within `nonReentrant`-protected `applyFeeRecipients`. |

**Recommendation:** The `ordering` warning can be fixed by moving `removeFeeToken` before the `renounceOwnership` override. Other warnings are accepted for the reasons stated.

---

### [I-06] `abi.encodePacked` on Fixed-Size Values in Trade ID Generation

**Location:** `settleTrade()` line 844

**Description:**

```solidity
bytes32 tradeId = keccak256(
    abi.encodePacked(makerHash, takerHash)
);
```

Uses `abi.encodePacked` with two `bytes32` values. Since both inputs are fixed-size (32 bytes each), there is zero collision risk from `encodePacked`. Using `abi.encode` would add 32 bytes of padding per argument (costing ~130 extra gas for the memory expansion) with no security benefit.

**Assessment:** Correct and gas-efficient. No action needed.

---

## EIP-712 Compliance Review

### Domain Separator

```solidity
EIP712("OmniCoin DEX Settlement", "1")
```

- **Name:** "OmniCoin DEX Settlement" -- unique, descriptive
- **Version:** "1" -- appropriate for initial deployment
- **ChainId:** Automatically included by OpenZeppelin's EIP712 via `block.chainid`
- **VerifyingContract:** Automatically included as `address(this)`

**Assessment:** PASS. The domain separator is correctly constructed. Different chain deployments will have different domain separators, preventing cross-chain replay.

### Type Hash

```solidity
bytes32 public constant ORDER_TYPEHASH = keccak256(
    "Order(address trader,bool isBuy,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,uint256 price,uint256 deadline,bytes32 salt,address matchingValidator,uint256 nonce)"
);
```

**Assessment:** PASS. All 11 fields of the `Order` struct are included in canonical order. The type string matches the struct definition exactly.

### Struct Encoding

```solidity
function _hashOrder(Order calldata order) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        ORDER_TYPEHASH, order.trader, order.isBuy, order.tokenIn, order.tokenOut,
        order.amountIn, order.amountOut, order.price, order.deadline,
        order.salt, order.matchingValidator, order.nonce
    ));
}
```

**Assessment:** PASS. Uses `abi.encode` (not `abi.encodePacked`). Includes all fields in order. Prepends the type hash.

### Signature Verification

```solidity
bytes32 makerHash = _hashTypedDataV4(_hashOrder(makerOrder));
address recovered = makerHash.recover(makerSignature);
if (recovered != makerOrder.trader) revert InvalidSignature();
```

**Assessment:** PASS. Uses OpenZeppelin's `ECDSA.recover` which handles `v` normalization and rejects malleable `s` values (EIP-2). `_hashTypedDataV4` properly wraps with domain separator.

**EIP-712 Verdict: PASS** -- Full compliance.

---

## Signature Replay Attack Analysis

### Protection Mechanisms

1. **Nonce Bitmap (Uniswap Permit2 pattern):** Each nonce is a single bit in a 256-bit word. Once used, the order cannot be replayed. Users can have many concurrent orders using different nonces.

2. **`filledOrders` mapping:** Order hashes are marked as filled, providing a secondary replay check independent of nonces.

3. **Domain separator:** Includes `chainId` and `verifyingContract`, preventing cross-chain and cross-contract replay.

4. **`salt` field:** Random value ensures unique order hashes even for structurally identical orders.

5. **`deadline` field:** Orders expire, limiting the replay window.

6. **Order cancellation:** `invalidateNonce` (single nonce) and `invalidateNonceWord` (256 nonces at once) provide efficient cancellation.

### Dual Protection Redundancy

Both `filledOrders[hash]` and `nonceBitmap[trader][word] & bit` are checked in `_verifySignatures()`. An order is rejected if EITHER the hash was previously filled OR the nonce was previously used.

**Replay Verdict: PASS** -- Multi-layer replay protection with efficient cancellation.

---

## Reentrancy Analysis

### `settleTrade()` -- CEI Compliant (H-01 FIXED)

**Checks:** Lines 777-796 (validation, signatures, matching, volume, balances, slippage)
**Effects:** Lines 813-824 (filledOrders, nonces, volume tracking)
**Interactions:** Lines 828-860 (token transfers, fee distribution, event)

All state updates occur BEFORE any external call. Protected by `nonReentrant`. No read-only reentrancy risk.

### `settleIntent()` -- CEI Compliant

**Checks:** Lines 1290-1303 (locked, settled, deadline, access control)
**Effects:** Line 1306 (`coll.settled = true`)
**Interactions:** Lines 1325-1383 (token transfers, fee distribution)

`coll.settled = true` is set before external calls. Protected by `nonReentrant`.

### `cancelIntent()` -- CEI Compliant

**Effects:** Line 1411 (`coll.locked = false`)
**Interactions:** Lines 1414-1417 (`safeTransfer`)

State updated before transfer. Protected by `nonReentrant`.

### `claimFees()` -- CEI Compliant

**Effects:** Line 1162 (`accruedFees[caller][token] = 0`)
**Interactions:** Line 1163 (`safeTransfer`)

State zeroed before transfer. Protected by `nonReentrant`.

### `applyFeeRecipients()` -- Protected

Lines 948-971. `_claimAllPendingFees` uses low-level calls with 100,000 gas stipend and re-credits on failure. Protected by `nonReentrant`.

**Reentrancy Verdict: PASS** -- All paths are CEI compliant and protected by `nonReentrant`.

---

## Fee Distribution Verification

### `settleTrade()` Fee Flow

For a 10,000-token trade (18 decimals):
- Taker fee: `10000e18 * 20 / 10000 = 20e18` (0.20%)
- Maker rebate: `10000e18 * 5 / 10000 = 5e18` (0.05%)
- Net fee: `20e18 - 5e18 = 15e18` (0.15%)

Distribution of net fee:
- LP Pool: `15e18 * 7000 / 10000 = 10.5e18` (70%)
- UnifiedFeeVault: `15e18 - 10.5e18 = 4.5e18` (30%, remainder)

The remainder-to-vault approach (line 1761: `vaultShare = fee - lpShare`) ensures no rounding dust is lost. The sum `lpShare + vaultShare` always equals `fee` exactly.

**Verification with small amounts (rounding edge case):**
For a 1-token trade: `takerFee = 1e18 * 20 / 10000 = 2e15`. `makerRebate = 1e18 * 5 / 10000 = 5e14`. `netFee = 2e15 - 5e14 = 1.5e15`.
LP: `1.5e15 * 7000 / 10000 = 1.05e15`. Vault: `1.5e15 - 1.05e15 = 4.5e14`. Total: `1.05e15 + 4.5e14 = 1.5e15`. CORRECT.

### `settleIntent()` Fee Flow

Both fee and rebate calculated on `solverAmount` (tokenOut):
- Solver fee: `solverAmount * 20 / 10000` (0.20% of tokenOut)
- Trader rebate: `solverAmount * 5 / 10000` (0.05% of tokenOut)
- Net fee: `solverFee - min(traderRebate, solverFee)` = `solverFee - traderRebate` (since rebate < fee by construction)

Same 70/30 LP/Vault split via `_accrueFeeSplit()`.

**H-02 Fix Verification:** Both rebate and fee are now denominated in the same token (tokenOut). No cross-token arithmetic. CORRECT.

**Fee Distribution Verdict: CORRECT** -- Both settlement paths properly implement the 70/30 LP/Vault split with maker rebate.

---

## Balance Accounting Review

### External Balance Model (`settleTrade`)

No internal balance mappings. Uses `safeTransferFrom` directly from user wallets. Users retain custody until settlement executes. This is the safer model -- no deposit/withdrawal state to manage.

### Escrow Model (`settleIntent`)

Trader's tokens are escrowed in the contract between `lockIntentCollateral` and `settleIntent`/`cancelIntent`. The `traderAmount` is stored and used for transfers. The fee-on-transfer detection (M-07) guards the escrow deposit.

### Fee-on-Transfer Detection Coverage

| Transfer | Balance Check | Location |
|----------|---------------|----------|
| Maker -> Taker (settleTrade) | YES | Lines 1644-1655 |
| Taker -> Contract (settleTrade) | YES | Lines 1661-1672 |
| Trader -> Contract (lockIntentCollateral) | YES | Lines 1245-1258 |
| Solver -> Trader (settleIntent, net) | YES | Lines 1332-1345 |
| Solver -> Contract (settleIntent, fee) | **NO** | Lines 1349-1353 |

The missing check on the solver fee transfer (M-01 above) is the only gap. It is fail-safe (atomic revert via SafeERC20 if insufficient funds) but lacks explicit detection.

---

## Front-Running and MEV Analysis

### Settlement Front-Running

`settleTrade()` is permissionless. Signed order parameters and signatures are visible in calldata. On Avalanche:
- 1-2 second consensus finality limits mempool exposure
- The settler receives no economic benefit (fees go to `matchingValidator`, signed into the order)
- Sandwich attacks cannot modify signed amounts/prices

**Assessment:** Low practical risk. The main MEV vector is validator transaction ordering, which is an Avalanche-level concern, not a contract-level vulnerability.

### Flash Loan Resistance

Flash loans cannot directly affect settlement because:
- Orders are pre-signed with fixed amounts (no oracle dependency)
- Balance checks (`_checkBalancesAndAllowances`) and actual `safeTransferFrom` execute in the same transaction
- Flash-loaned tokens would need to be returned before the transaction completes

**Assessment:** Not vulnerable to flash loan attacks.

---

## Remediation Status (All Prior Audit Rounds)

| Round | Finding | Status | Evidence |
|-------|---------|--------|----------|
| R4 C-01 | Intent settlement zero fees | **FIXED** | `settleIntent()` calculates fees, distributes via `_accrueFeeSplit` (lines 1315-1374) |
| R4 H-01 | `applyFeeRecipients` missing `nonReentrant` | **FIXED** | Redesigned with timelock: `applyFeeRecipients()` has `nonReentrant` (line 950) |
| R4 H-02 | Reverting token blocks fee changes | **FIXED** | Low-level `call{gas: 100_000}` with re-credit; `removeFeeToken` escape hatch |
| R4 H-03 | No `matchingValidator` in IntentCollateral | **FIXED** | Field added (line 168), stored at lock time (line 1237) |
| R6 H-01 | CEI violation in `settleTrade()` | **FIXED** | State updates (lines 813-824) before interactions (lines 828-860) |
| R6 H-02 | Cross-token fee mismatch in `settleIntent()` | **FIXED** | Both on `solverAmount` (lines 1315-1318) |
| R6 M-01 | `setFeeRecipients` no timelock | **FIXED** | `scheduleFeeRecipients` / `applyFeeRecipients` with 48h timelock |
| R6 M-03 | Taker double-pull griefing | **FIXED** | Single pull to contract, internal distribution (lines 1657-1682) |
| R6 M-04 | `_claimAllPendingFees` no gas limit | **FIXED** | `{gas: 100_000}` stipend (line 1820) |
| R4 M-01 | Volume tracking one-sided | **FIXED** | Both sides tracked (lines 821-824) |
| R4 M-04 | Timelock overwrite | **FIXED** | `PendingChangeExists` error; cancel functions added |
| R4 M-05 | `settleIntent` CEI violation | **FIXED** | `coll.settled = true` before transfers (line 1306) |
| R4 L-01 | Zero trade limits | **FIXED** | Zero check in `scheduleTradingLimits` (lines 1007-1009) |
| R4 L-02 | `feeTokens` never shrinks | **FIXED** | `removeFeeToken` added (lines 1124-1141) |
| R4 L-05 | `lockIntentCollateral` no emergencyStop | **FIXED** | Check added (line 1203) |
| R4 L-06 | No tokenIn != tokenOut check | **FIXED** | Check in `_verifyOrdersMatch` (line 2076, maker only) |
| R4 L-07 | Event missing slippage | **FIXED** | `maxSlippageBps` in `TradingLimitsChangeScheduled` event |
| R4 L-04 | Slippage asymmetric | **NOT FIXED** | L-01 above (low priority) |
| R6 L-05 | Taker tokenIn!=tokenOut missing | **NOT FIXED** | L-05 above (low priority, implicitly covered) |

---

## Static Analysis

### Slither Results

Slither static analysis was run via Hardhat integration. Findings for DEXSettlement:

| Finding | Severity | Assessment |
|---------|----------|------------|
| Arbitrary `from` in `transferFrom` (4 instances) | Medium | **False Positive.** By design: `settleTrade()` transfers from signed-order traders; `settleIntent()` transfers from designated solver. All sources are authorized via EIP-712 signatures or intent locking. |
| Reentrancy in `_claimAllPendingFees` | Medium | **False Positive.** `accruedFees` is zeroed before the low-level `call` (CEI). The re-credit at line 1838 is a failure recovery path executed only when the transfer fails. The outer function `applyFeeRecipients()` has `nonReentrant`. |
| Reentrancy in `applyFeeRecipients()` | Medium | **False Positive.** Protected by `nonReentrant` modifier (line 950). State updates after `_claimAllPendingFees` (lines 964-965) are only reached after all external calls complete. |

No true-positive findings from Slither.

### Solhint Results

```
contracts/dex/DEXSettlement.sol
  0 errors, 11 warnings (see I-05 for full analysis)
```

All warnings are either accepted (complexity, state count, low-level call) or minor style issues (ordering, event indexing).

### Manual Static Checks

| Check | Result |
|-------|--------|
| Solidity version pinned | PASS -- `pragma solidity 0.8.25;` |
| No floating pragma | PASS |
| SafeERC20 used for all token ops | PASS |
| No raw `transfer`/`transferFrom` | PASS (except intentional low-level call in `_claimAllPendingFees`) |
| No `tx.origin` usage | PASS |
| No `selfdestruct` | PASS |
| No `delegatecall` | PASS |
| No assembly | PASS |
| No unchecked arithmetic | PASS (Solidity 0.8.25 built-in overflow checks) |
| Custom errors used (no revert strings) | PASS |
| Events properly indexed | PASS (some could benefit from additional indexing, see I-05) |
| No storage collisions | PASS (not upgradeable) |
| Constructor validates all addresses | PASS |
| `renounceOwnership` disabled | PASS (line 1113) |
| Timelock on admin functions | PASS (fee recipients and trading limits) |
| Timelock overwrite prevention | PASS (`PendingChangeExists`) |
| Emergency escape for users | PASS (`cancelIntent` ungated by pause) |
| No owner sweep/withdraw | PASS (owner cannot extract user funds) |

### Compilation

Compiles cleanly with Hardhat (solc 0.8.25). No warnings.

### Test Suite

33 tests, all passing. Coverage includes:
- Deployment and initialization
- EIP-712 signature verification (valid and invalid)
- Commit-reveal timing (early, on-time, late)
- Order matching (sides, tokens, prices)
- Permissionless settlement (maker, validator, anyone)
- Fee distribution with maker rebate
- Security (self-trade, expired, replay, validator mismatch)
- Atomic settlement and balance verification
- Emergency controls
- Nonce bitmap management
- Fee-on-transfer detection (lock and settle paths)

---

## Positive Security Features (Confirmed in Round 7)

1. **ReentrancyGuard** on all settlement, claim, and admin functions that perform external calls
2. **Ownable2Step** for safe two-step ownership transfer
3. **`renounceOwnership` disabled** -- prevents accidental lockout
4. **EIP-712** typed data signing with proper domain separation and chain ID binding
5. **SafeERC20** for all token interactions
6. **Nonce bitmap** (Uniswap Permit2 pattern) for efficient concurrent order support
7. **Dual replay protection** (filledOrders + nonce bitmap)
8. **Fee-on-transfer detection** via balance-before/after checks on all major transfers
9. **48-hour timelock** on both trading limits AND fee recipient changes (Round 6 remediation)
10. **Timelock overwrite prevention** (`PendingChangeExists` error)
11. **Push-pattern fee distribution** (immediate transfer during settlement)
12. **Try/catch fee claiming** with gas-limited low-level call and re-credit on failure
13. **`removeFeeToken` escape hatch** for problematic tokens
14. **Self-trade prevention**
15. **`cancelIntent` ungated** by pause -- users always have an escape path
16. **No `emergencyWithdraw`** or sweep -- owner fundamentally cannot extract user funds
17. **`tokenIn != tokenOut` validation** prevents self-swap waste
18. **Zero-value guards** on scheduling functions
19. **Remainder-to-recipient** for rounding dust (prevents accumulation)
20. **Intent escrow** with real token custody (H-03 fix)
21. **CEI compliance** in ALL settlement paths (H-01 fix verified)
22. **Struct packing** in `IntentCollateral` for gas optimization
23. **Gas stipend** (100,000) on low-level calls in force-claim (prevents gas griefing)
24. **Consistent dual halt** (pause + emergencyStop) on all settlement functions
25. **Per-function cancellation** for both timelocked admin operations

---

## Summary of Recommendations (Priority Order)

1. **[M-01] SHOULD FIX:** Add fee-on-transfer balance check on solver fee transfer in `settleIntent()`. Simple addition, consistent with M-07 philosophy.

2. **[M-02] SHOULD FIX:** Consolidate solver transfers in `settleIntent()` into single pull for consistency with `_executeAtomicSettlement()` pattern.

3. **[L-01] through [L-05]:** Fix at developer's discretion. All are defense-in-depth improvements with low practical impact given the whitelisted token model and Avalanche deployment context.

4. **Deploy with multi-sig** (Gnosis Safe) as owner. This is the single most important operational security measure.

5. **Document ERC2771 trust model** in deployment documentation -- the trusted forwarder has significant impersonation power.

6. **Consider removing `totalFeesCollected`** counter to save ~5,000 gas per settlement, or add per-token tracking for meaningful analytics.

---

## Overall Security Assessment

**Rating: STRONG (8.5/10)**

DEXSettlement is a well-engineered, extensively audited contract with comprehensive security controls. It has been through 3 rounds of audit (Rounds 4, 6, 7) with all Critical and High findings remediated. The remaining findings are defense-in-depth improvements, not exploitable vulnerabilities.

**Key Strengths:**
- Trustless design (anyone can settle, no privileged settlement role)
- Dual replay protection (filledOrders + nonce bitmap)
- Comprehensive CEI compliance across all paths
- Proper timelocks on all admin operations
- No admin fund extraction capability
- User escape paths always available (cancelIntent, claimFees)

**Key Residual Risks:**
- Owner can halt trading indefinitely (mitigated by multi-sig deployment)
- ERC2771 forwarder trust assumption (mitigated by immutable, audited forwarder)
- Commit-reveal is optional (mitigated by Avalanche fast finality)

**Recommendation for Mainnet:** The contract is suitable for mainnet deployment with the M-01 and M-02 fixes applied. Multi-sig ownership is essential.

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet Final Review*
*Contract revision: post-Round-6 remediation, 2,191 lines*
*Audit scope: Full contract -- access control, business logic, reentrancy, CEI compliance, EIP-712, fee arithmetic, token integration, front-running/MEV, flash loans, replay attacks, static analysis*
*Previous audits: Round 4 (2026-02-28, 20 findings), Round 6 (2026-03-10, 15 findings)*
*Test suite: 33/33 passing*
