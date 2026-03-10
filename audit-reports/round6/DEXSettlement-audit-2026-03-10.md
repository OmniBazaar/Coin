# Security Audit Report: DEXSettlement (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Deep Review)
**Contract:** `Coin/contracts/dex/DEXSettlement.sol`
**Solidity Version:** 0.8.25
**Lines of Code:** 2,107
**Upgradeable:** No (Ownable2Step, immutable deployment)
**Handles Funds:** Yes (direct token transfers via `safeTransferFrom`, intent collateral escrow)
**Previous Audit:** Round 4 (2026-02-28) -- 20 findings, contract substantially revised since

---

## Executive Summary

DEXSettlement has undergone significant remediation since Round 4. The contract now implements real token escrow for intents (H-03 fix), fee collection on intent settlements (C-01 fix), `matchingValidator` tracking in `IntentCollateral` (H-03 fix), push-pattern fee distribution, try/catch in `_claimAllPendingFees` with re-credit on failure (H-02 fix), CEI compliance in `settleIntent` (M-05 fix), `removeFeeToken` admin escape hatch (L-02 fix), `emergencyStop` checks on `lockIntentCollateral` (L-05 fix), `tokenIn != tokenOut` validation (L-06 fix), timelock overwrite prevention (M-04 fix), and zero-value guard on `scheduleTradingLimits` (L-01 fix).

However, this pre-mainnet review identifies **2 high-severity**, **4 medium-severity**, **5 low-severity**, and **4 informational** findings. The most critical issues involve a CEI pattern violation in `settleTrade()` where state updates (filledOrders, nonces, volume) occur after external token transfers, and a cross-token fee accounting inconsistency in intent settlements where the rebate is calculated on `traderAmount` (tokenIn) but paid from `solverFee` (tokenOut).

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | CEI violation in settleTrade() | **FIXED** — state updates before transfers |
| H-02 | High | Cross-token fee mismatch in settleIntent() | **FIXED** |
| M-01 | Medium | setFeeRecipients() has no timelock | **FIXED** |
| M-02 | Medium | Commit-reveal MEV protection not enforced | **FIXED** |
| M-03 | Medium | Taker requires three separate approvals | **FIXED** |
| M-04 | Medium | _claimAllPendingFees uses low-level call without gas limit | **FIXED** |

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 5 |
| Informational | 4 |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (`Ownable2Step`) | `setFeeRecipients`, `scheduleTradingLimits`, `applyTradingLimits`, `cancelScheduledTradingLimits`, `emergencyStopTrading`, `resumeTrading`, `pause`, `unpause`, `removeFeeToken` | 6/10 |
| Anyone (permissionless) | `commitOrder`, `settleTrade`, `invalidateNonce`, `invalidateNonceWord`, `claimFees` | N/A |
| Trader only (self-auth) | `revealOrder` (order.trader == `_msgSender()`), `lockIntentCollateral` (caller becomes coll.trader), `cancelIntent` (coll.trader) | N/A |
| Bilateral (trader or solver) | `settleIntent` (coll.trader or coll.solver) | N/A |

**Owner Capabilities:**
- Halt all trading indefinitely (`pause` + `emergencyStopTrading`)
- Redirect future fee flows to arbitrary addresses (`setFeeRecipients` -- no timelock, Pioneer Phase direct setter)
- Modify trading limits with 48-hour timelock (`scheduleTradingLimits` / `applyTradingLimits`)
- Remove tracked fee tokens (`removeFeeToken`)

**Owner CANNOT:**
- Steal user token balances held externally
- Drain intent collateral (no sweep/withdraw function)
- Forge trade signatures or settle without valid dual signatures
- Bypass `renounceOwnership` (disabled, reverts with `InvalidAddress`)

**Centralization Risk: 6/10** -- Owner controls fee recipients without timelock (Pioneer Phase acknowledged). Deployment with multi-sig (Gnosis Safe) is strongly recommended.

---

## High Findings

### [H-01] CEI Violation in `settleTrade()` -- State Updates After External Transfers

**Severity:** High
**Category:** Reentrancy / Checks-Effects-Interactions Violation
**Location:** `settleTrade()` lines 737-824
**Real-World Precedent:** ReadOnlyReentrancy patterns (Curve read-only reentrancy 2023, ~$70M at risk)

**Description:**

The `settleTrade()` function performs external token transfers via `_executeAtomicSettlement()` at line 773, then updates critical state variables _after_ those transfers complete:

```solidity
// Line 773: External calls (3x safeTransferFrom)
_executeAtomicSettlement(makerOrder, takerOrder, takerFee);

// Lines 784-795: State updates AFTER external calls
filledOrders[makerHash] = true;        // Effect after interaction
filledOrders[takerHash] = true;        // Effect after interaction
_useNonce(makerOrder.trader, ...);     // Effect after interaction
_useNonce(takerOrder.trader, ...);     // Effect after interaction
totalTradingVolume += ...;             // Effect after interaction
dailyVolumeUsed += ...;                // Effect after interaction

// Lines 799-805: MORE external calls (fee distribution)
_distributeFeesWithRebate(...);        // 4x safeTransfer
```

While `nonReentrant` prevents direct reentrancy exploitation, this creates two problems:

1. **Read-only reentrancy:** During the token transfer callbacks (ERC777 `tokensReceived`, ERC1363 `onTransferReceived`, or any hook-bearing token), external contracts querying `filledOrders[hash]`, `isNonceUsed()`, `dailyVolumeUsed`, or `totalTradingVolume` will see stale (pre-settlement) values. If another protocol integrates with DEXSettlement and uses these view functions for decision-making, it can be exploited.

2. **Inconsistent state between `_executeAtomicSettlement` and `_distributeFeesWithRebate`:** If the first set of transfers succeeds but some internal revert occurs before fee distribution, the settlement is partially executed (tokens moved) but state is not fully updated. Although the overall `nonReentrant + whenNotPaused` wrapping prevents partial completion in practice, the ordering violates defense-in-depth.

**Recommendation:**

Move all state updates before `_executeAtomicSettlement()`:

```solidity
function settleTrade(...) external nonReentrant whenNotPaused {
    if (emergencyStop) revert EmergencyStopActive();
    _validateOrders(makerOrder, takerOrder);
    _verifySignatures(makerOrder, takerOrder, makerSignature, takerSignature);
    _verifyOrdersMatch(makerOrder, takerOrder);
    _checkVolumeLimits(makerOrder, takerOrder);
    _checkBalancesAndAllowances(makerOrder, takerOrder);
    _checkSlippage(makerOrder, takerOrder);

    uint256 makerRebate = (makerOrder.amountIn * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;
    uint256 takerFee = (takerOrder.amountIn * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;

    bytes32 makerHash = _hashTypedDataV4(_hashOrder(makerOrder));
    bytes32 takerHash = _hashTypedDataV4(_hashOrder(takerOrder));

    // EFFECTS first
    filledOrders[makerHash] = true;
    filledOrders[takerHash] = true;
    _useNonce(makerOrder.trader, makerOrder.nonce);
    _useNonce(takerOrder.trader, takerOrder.nonce);
    totalTradingVolume += makerOrder.amountIn + takerOrder.amountIn;
    dailyVolumeUsed += makerOrder.amountIn + takerOrder.amountIn;

    // INTERACTIONS last
    _executeAtomicSettlement(makerOrder, takerOrder, takerFee);
    _distributeFeesWithRebate(takerFee, makerRebate, takerOrder.tokenIn,
        makerOrder.trader, makerOrder.matchingValidator);

    emit TradeSettled(...);
}
```

---

### [H-02] Intent Settlement Cross-Token Fee Mismatch -- Rebate Calculated on Wrong Token

**Severity:** High
**Category:** Business Logic / Accounting Error
**Location:** `settleIntent()` lines 1229-1291

**Description:**

In `settleIntent()`, the trader rebate and solver fee are calculated on different tokens but treated as commensurable:

```solidity
// Line 1231-1234: Rebate on traderAmount (denominated in tokenIn)
uint256 traderRebate = (coll.traderAmount * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;
// Solver fee on solverAmount (denominated in tokenOut)
uint256 solverFee = (coll.solverAmount * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;
```

Then at lines 1274-1276:
```solidity
uint256 rebate = traderRebate > solverFee ? solverFee : traderRebate;
uint256 netFee = solverFee - rebate;
```

The `traderRebate` is a quantity denominated in `tokenIn`, while `solverFee` is denominated in `tokenOut`. These are compared and subtracted directly, but they represent amounts in different tokens which may have vastly different values (e.g., 1 WBTC vs 50,000 USDC).

**Exploit Scenario:**

Consider a trade: Trader sells 1 WBTC (tokenIn) for 50,000 USDC (tokenOut, solverAmount).

- `traderRebate` = 1 WBTC * 5/10000 = 0.0005 WBTC (worth ~$25)
- `solverFee` = 50,000 USDC * 20/10000 = 100 USDC

The comparison `traderRebate > solverFee` evaluates `0.0005e18 > 100e6` (assuming 18 and 6 decimals), which resolves to `500000000000000 > 100000000`. This is **true**, so `rebate` = `solverFee` = 100 USDC.

The maker rebate should be ~$25 worth but instead the entire 100 USDC solver fee is paid as rebate, leaving `netFee = 0`. The protocol collects zero fees.

Conversely, if tokens are reversed (trader sells USDC for WBTC), the rebate would be negligible relative to the fee, and the full fee would be collected. The asymmetry depends entirely on token decimal and price ratios.

**Recommendation:**

The rebate should be calculated on the same token as the fee (solverFee), or the contract should use an oracle for cross-token rebate calculation, or simply compute both fee and rebate on the same side:

```solidity
// Both on solverAmount (tokenOut), same as settleTrade pattern
uint256 solverFee = (coll.solverAmount * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;
uint256 makerRebate = (coll.solverAmount * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;
uint256 netFee = solverFee - makerRebate;
```

---

## Medium Findings

### [M-01] `setFeeRecipients()` Has No Timelock -- Immediate Fee Redirection

**Severity:** Medium
**Category:** Access Control / Centralization Risk
**Location:** `setFeeRecipients()` lines 879-908

**Description:**

While `scheduleTradingLimits()` has a 48-hour timelock (M-04 remediation), `setFeeRecipients()` is a direct setter with no timelock whatsoever. The NatSpec documents this as "Pioneer Phase: no timelock" but this creates a significant centralization risk. The owner can instantly redirect all fee flows (70% LP, 20% ODDAO, 10% Protocol) to attacker-controlled addresses.

The H-05 remediation (force-claiming pending fees before update) prevents theft of already-accrued pull-pattern fees, but since fees are now distributed via push-pattern (immediate transfer during settlement), the force-claim primarily handles legacy accrued balances. The real risk is that after an instant redirect, all future settlements send fees to the new addresses.

**Impact:** A compromised owner key can immediately steal all future fee revenue with zero notice period. Unlike trading limits, there is no timelock for community to detect and respond.

**Recommendation:**

Add a timelock mechanism parallel to `scheduleTradingLimits`:

```solidity
FeeRecipients public pendingFeeRecipients;
uint256 public feeRecipientsTimelockExpiry;

function scheduleFeeRecipients(...) external onlyOwner { ... }
function applyFeeRecipients() external onlyOwner { ... }
function cancelScheduledFeeRecipients() external onlyOwner { ... }
```

At minimum, document the risk explicitly and deploy with a multi-sig as owner. This is labeled "Pioneer Phase" which is acceptable if the timeline for adding the timelock is defined.

---

### [M-02] Commit-Reveal MEV Protection Is Entirely Optional -- Not Enforced

**Severity:** Medium
**Category:** Front-Running / MEV
**Location:** `settleTrade()` lines 737-824; `commitOrder()` line 662; `revealOrder()` line 687

**Description:**

The contract provides commit-reveal infrastructure (`commitOrder`, `revealOrder`, `MIN_COMMIT_BLOCKS`, `MAX_COMMIT_BLOCKS`) but `settleTrade()` never checks whether either order was committed or revealed. The NatSpec at line 735 acknowledges: "Commit-reveal is opt-in; MEV protection is not guaranteed without it (M-03)."

This means the advertised commit-reveal MEV protection is purely ceremonial from the contract's perspective. A validator or mempool observer can front-run any settlement transaction by:

1. Observing a pending `settleTrade()` in the mempool
2. Extracting the order parameters and signatures from calldata
3. Submitting their own `settleTrade()` with higher gas to capture any MEV

On Avalanche with 1-2 second finality, mempool front-running is less practical than on Ethereum, but validators themselves have transaction ordering power and could extract MEV from settlement ordering.

**Mitigation Note:** Avalanche's sub-second consensus significantly reduces the practical MEV surface. The off-chain matching (validators match, anyone settles) also reduces exposure since matched pairs are already agreed. The risk is primarily from validators with transaction ordering power.

**Recommendation:**

Either:
1. Add an optional `requireCommitReveal` flag (configurable per-token-pair or globally) that enforces commit-reveal for high-value trades
2. Or clearly document that commit-reveal is advisory-only and MEV protection relies on Avalanche's fast finality + off-chain matching architecture
3. Consider a commit-reveal-settle three-phase approach where settlement requires prior reveal

---

### [M-03] Taker Requires Three Separate Approvals for Settlement -- Griefing via Allowance Manipulation

**Severity:** Medium
**Category:** Token Integration / Griefing
**Location:** `_executeAtomicSettlement()` lines 1548-1593

**Description:**

In `_executeAtomicSettlement()`, the taker's tokens are transferred in two separate `safeTransferFrom` calls:

```solidity
// Transfer 1: takerNet to maker (line 1574)
IERC20(takerOrder.tokenIn).safeTransferFrom(takerOrder.trader, makerOrder.trader, takerNet);

// Transfer 2: takerFee to contract (line 1587)
IERC20(takerOrder.tokenIn).safeTransferFrom(takerOrder.trader, address(this), takerFee);
```

This means the taker must approve `amountIn` (= `takerNet + takerFee`) as a single allowance, which both transfers draw from. This works correctly since ERC20 `transferFrom` decrements the allowance atomically. However, there is a subtle issue:

If the taker has approved exactly `amountIn` (not `MaxUint256`), and between the balance check (`_checkBalancesAndAllowances`) and actual execution, a third party (or the taker themselves via another transaction) changes the allowance, the first transfer could succeed while the second fails, leaving the transaction to revert. This is benign (atomic revert) but could be used for griefing if the attacker can manipulate allowances between the check and the transfer.

More importantly, the balance-before/after check on the first transfer (lines 1572-1583) checks the maker's balance of `takerOrder.tokenIn`. If the maker has an active `transferFrom` callback (e.g., ERC777 `tokensReceived`), the callback executes before the second `safeTransferFrom` to the contract, creating a window where the maker could manipulate state.

**Recommendation:**

Consider transferring the full `amountIn` from the taker to the contract first, then distributing from the contract to the maker. This reduces the number of external calls and simplifies accounting:

```solidity
// Single transfer from taker to contract
IERC20(takerOrder.tokenIn).safeTransferFrom(takerOrder.trader, address(this), takerOrder.amountIn);
// Then distribute internally
IERC20(takerOrder.tokenIn).safeTransfer(makerOrder.trader, takerNet);
// takerFee remains in contract
```

---

### [M-04] `_claimAllPendingFees()` Uses Low-Level `call` Without Gas Limit

**Severity:** Medium
**Category:** Gas Griefing / Denial of Service
**Location:** `_claimAllPendingFees()` lines 1721-1759

**Description:**

The `_claimAllPendingFees()` function iterates over up to `MAX_FEE_TOKENS` (100) tokens and performs a low-level `call` for each:

```solidity
(bool ok, bytes memory ret) = token.call(
    abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
);
```

While the try/catch-style handling (check `ok` and re-credit on failure) is a good remediation of the previous H-02, the low-level `call` forwards all available gas to each token transfer. A malicious token contract could consume the entire remaining gas in its `transfer` function, causing the overall `setFeeRecipients()` transaction to run out of gas before processing all tokens.

With 100 potential tokens, each potentially consuming significant gas, the worst case could exceed block gas limits. The `removeFeeToken()` function mitigates this by allowing the owner to remove problematic tokens, but only if the issue is identified before `setFeeRecipients()` is needed.

**Recommendation:**

1. Consider adding a gas stipend to the low-level call: `token.call{gas: 100_000}(...)` to prevent gas griefing
2. Alternatively, add a `claimPendingFeesForToken(address recipient, address token)` function that allows granular force-claiming one token at a time, as a fallback if the batch operation fails

---

## Low Findings

### [L-01] `maxSlippageBps` Can Be Set to Zero via Timelock, Disabling Slippage Protection

**Severity:** Low
**Location:** `scheduleTradingLimits()` line 931; `_checkSlippage()` line 1790

**Description:**

`scheduleTradingLimits()` validates `_maxSlippageBps <= MAX_SLIPPAGE_BPS` (upper bound) but does not reject zero. In `_checkSlippage()`, the function returns early when `maxSlippageBps == 0`:

```solidity
if (maxSlippageBps == 0) return; // No slippage check at all
```

Setting `maxSlippageBps = 0` via the timelock completely disables slippage protection. While this requires owner action + 48-hour delay, it silently disables a safety mechanism.

**Recommendation:** Add `if (_maxSlippageBps == 0) revert InvalidParameters();` in `scheduleTradingLimits()`, or change `_checkSlippage()` to enforce a minimum slippage check even when the value is zero.

---

### [L-02] `emergencyStop` and `pause` Are Redundant and Applied Inconsistently

**Severity:** Low
**Location:** Multiple functions

**Description:**

The contract has two independent halt mechanisms:
- `emergencyStop` (boolean flag, checked manually in each function)
- `whenNotPaused` (OpenZeppelin Pausable modifier)

Both are controlled by the owner. Their application is inconsistent:

| Function | `emergencyStop` | `whenNotPaused` |
|----------|-----------------|-----------------|
| `settleTrade()` | Yes | Yes |
| `lockIntentCollateral()` | Yes | Yes |
| `settleIntent()` | Yes | Yes |
| `cancelIntent()` | No | No |
| `commitOrder()` | No | No |
| `revealOrder()` | No | No |
| `claimFees()` | No | No |
| `invalidateNonce()` | No | No |

Having `cancelIntent` ungated by pause/emergencyStop is intentional (users can always reclaim locked funds). But having both mechanisms is redundant.

**Recommendation:** Remove `emergencyStop` and use only `whenNotPaused`. If distinct semantics are needed (e.g., emergency stop = permanent until explicit resume, pause = temporary), document the distinction clearly.

---

### [L-03] `cancelIntent()` Does Not Mark the Nonce as Used

**Severity:** Low
**Location:** `cancelIntent()` lines 1308-1339

**Description:**

When an intent is cancelled, `coll.locked` is set to `false` but the intent record remains in storage with the same `intentId`. Since `intentId` is externally provided (not derived from content), the same `intentId` could potentially be reused after cancellation because only `coll.locked` is checked (line 1316). However, the `lockIntentCollateral()` function checks `coll.locked` (line 1128), which would be `false` after cancellation, so the same `intentId` could be re-locked.

This allows an `intentId` to be recycled after cancellation. While not directly exploitable, it creates confusing event history and could complicate off-chain indexing.

**Recommendation:** Consider adding a `cancelled` flag to `IntentCollateral` that prevents reuse, or document that intentId recycling is acceptable behavior.

---

### [L-04] Slippage Check Is Asymmetric -- Only Validates One Direction

**Severity:** Low
**Location:** `_checkSlippage()` lines 1786-1803

**Description:**

The slippage check only validates:
```solidity
uint256 minAcceptable = (makerOrder.amountOut * (BASIS_POINTS_DIVISOR - maxSlippageBps))
    / BASIS_POINTS_DIVISOR;
if (takerOrder.amountIn < minAcceptable) {
    revert SlippageTooHigh();
}
```

This checks that the taker provides at least `(1 - slippage)` of what the maker requested. It does not symmetrically check that the maker provides at least `(1 - slippage)` of what the taker requested.

The signed order amounts provide implicit protection (both parties sign exact amounts), but the explicit slippage check is one-directional. If the matching validator constructs orders where the taker overpays relative to the maker's offer, the slippage check does not catch it.

**Recommendation:** Add a symmetric check: `if (makerOrder.amountIn < (takerOrder.amountOut * (BASIS_POINTS_DIVISOR - maxSlippageBps)) / BASIS_POINTS_DIVISOR) revert SlippageTooHigh();`

---

### [L-05] `_verifyOrdersMatch` Missing `tokenIn != tokenOut` Check on Taker Order

**Severity:** Low
**Location:** `_verifyOrdersMatch()` lines 1987-2019

**Description:**

The L-06 remediation added `tokenIn != tokenOut` validation, but only on the maker order:

```solidity
// L-06: tokenIn must differ from tokenOut
if (makerOrder.tokenIn == makerOrder.tokenOut) {
    revert InvalidOrder();
}
```

The taker order is not explicitly checked. While the cross-matching checks (`makerOrder.tokenIn != takerOrder.tokenOut` and `makerOrder.tokenOut != takerOrder.tokenIn`) combined with the maker self-check implicitly prevent the taker from having `tokenIn == tokenOut` (since if `takerOrder.tokenIn == takerOrder.tokenOut`, and `makerOrder.tokenIn == takerOrder.tokenOut` and `makerOrder.tokenOut == takerOrder.tokenIn`, then `makerOrder.tokenIn == makerOrder.tokenOut`, which is caught), the implicit protection is hard to reason about.

**Recommendation:** Add explicit check for taker as well for defense-in-depth and code clarity:
```solidity
if (takerOrder.tokenIn == takerOrder.tokenOut) {
    revert InvalidOrder();
}
```

---

## Informational Findings

### [I-01] `totalFeesCollected` Mixes Token Decimals

**Location:** Lines 237, 793, 1289, 1621

`totalFeesCollected` sums fee amounts across all tokens into a single `uint256`. Tokens have different decimals (18 for most ERC20s, 6 for USDC/USDT, 8 for WBTC), making this counter meaningless for analytics. No on-chain logic depends on this value, so this is purely an informational/display concern.

**Recommendation:** Either remove the counter (save gas) or add per-token fee tracking.

---

### [I-02] Test Suite Constructor Mismatch

**Location:** `test/DEXSettlement.test.ts` line 106-110

The test deploys `DEXSettlement` with 3 constructor arguments:
```typescript
dexSettlement = await DEXSettlement.deploy(
    liquidityPoolAddress,
    oddaoAddress,
    protocolTreasuryAddress
);
```

But the contract's constructor requires 4 arguments (the 4th being `trustedForwarder_`). Either the test is compiled against an older version of the contract, or the test will fail. This should be reconciled before mainnet deployment.

**Recommendation:** Update the test to pass `trustedForwarder_` (e.g., `ethers.ZeroAddress` if no forwarder is needed in tests).

---

### [I-03] ERC2771Context Trust Assumption

**Location:** Constructor line 628; `_msgSender()` override lines 2069-2076

The contract inherits `ERC2771Context` and delegates `_msgSender()` to the ERC2771 implementation. This means the `trustedForwarder_` address set at construction time can impersonate any user for all `_msgSender()` calls. If the forwarder contract is compromised, an attacker could:

- Call `commitOrder` as any trader
- Call `revealOrder` as any trader
- Call `lockIntentCollateral` as any trader (escrowing their tokens)
- Call `cancelIntent` as any trader
- Call `claimFees` for any address
- Call `invalidateNonce` for any trader (canceling their pending orders)

The forwarder cannot call `settleTrade` maliciously (signatures still required) or admin functions (`onlyOwner` checks `msg.sender` via Ownable which also uses `_msgSender()`).

**Recommendation:** Document the trust model. Ensure the forwarder is a well-audited, immutable contract. Consider deploying with `address(0)` as forwarder if gasless meta-transactions are not needed at launch.

---

### [I-04] `FeesDistributed` Event Amounts Are Recalculated, Not Actual Transfer Amounts

**Location:** `_distributeFeesWithRebate()` lines 1638-1643

The event emits recalculated amounts:
```solidity
uint256 lpAmt = (netFee * LP_SHARE) / BASIS_POINTS_DIVISOR;
uint256 oddaoAmt = (netFee * ODDAO_SHARE) / BASIS_POINTS_DIVISOR;
uint256 protocolAmt = (netFee * PROTOCOL_SHARE) / BASIS_POINTS_DIVISOR;
```

But the actual transfer in `_accrueFeeSplit()` calculates:
```solidity
uint256 od = (fee * ODDAO_SHARE) / BASIS_POINTS_DIVISOR;
uint256 pt = (fee * PROTOCOL_SHARE) / BASIS_POINTS_DIVISOR;
uint256 lp = fee - od - pt; // Remainder to LP
```

The LP amount in the event is `(netFee * 7000) / 10000`, but the actual LP transfer is `netFee - od - pt` (the remainder). Due to integer division rounding, these can differ by 1-2 wei. The event may not match actual transfers, which could confuse off-chain indexers.

**Recommendation:** Either emit the actual transferred amounts (returned from `_accrueFeeSplit`) or document the potential 1-2 wei discrepancy.

---

## EIP-712 Compliance Review

### Domain Separator

```solidity
EIP712("OmniCoin DEX Settlement", "1")
```

- **Name:** "OmniCoin DEX Settlement" -- acceptable, unique
- **Version:** "1" -- acceptable
- **ChainId:** Automatically included by OpenZeppelin's EIP712 implementation via `block.chainid`
- **VerifyingContract:** Automatically included as `address(this)`
- **Salt:** Not used (optional per EIP-712)

**Assessment:** Correct. The domain separator is properly constructed and will differ across chains and contract deployments, preventing cross-chain and cross-contract replay attacks.

### Type Hash

```solidity
bytes32 public constant ORDER_TYPEHASH = keccak256(
    "Order(address trader,bool isBuy,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,uint256 price,uint256 deadline,bytes32 salt,address matchingValidator,uint256 nonce)"
);
```

**Assessment:** Correct. All 11 fields of the `Order` struct are included in the type hash string in the exact order they appear in the struct definition. The encoding uses `abi.encode` (not `abi.encodePacked`), which is correct for EIP-712 struct hashing.

### Struct Encoding

```solidity
function _hashOrder(Order calldata order) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        ORDER_TYPEHASH,
        order.trader, order.isBuy, order.tokenIn, order.tokenOut,
        order.amountIn, order.amountOut, order.price, order.deadline,
        order.salt, order.matchingValidator, order.nonce
    ));
}
```

**Assessment:** Correct. Uses `abi.encode` (not `abi.encodePacked`), includes all struct fields in order, prepends the type hash.

### Signature Verification

```solidity
bytes32 makerHash = _hashTypedDataV4(_hashOrder(makerOrder));
address recovered = makerHash.recover(makerSignature);
if (recovered != makerOrder.trader) revert InvalidSignature();
```

**Assessment:** Correct. Uses OpenZeppelin's `ECDSA.recover` which handles `v` value normalization and rejects `s` values in the upper half of the curve (EIP-2 malleable signatures). The `_hashTypedDataV4` function properly wraps the struct hash with the domain separator.

**EIP-712 Verdict: PASS** -- Full compliance with EIP-712 standard.

---

## Signature Replay Attack Analysis

### Protection Mechanisms

1. **Nonce Bitmap (Uniswap Permit2 pattern):** Each nonce is a single bit in a 256-bit word. Once a nonce is used (set), the order cannot be replayed. Users can have many concurrent orders by using different nonces from different bitmap words.

2. **`filledOrders` mapping:** Order hashes are marked as filled after settlement, providing a secondary replay check independent of nonces.

3. **Domain separator:** Includes `chainId` and `verifyingContract`, preventing cross-chain and cross-contract replay.

4. **`salt` field:** Adds randomness to order hashes, preventing hash collisions between similar orders.

5. **`deadline` field:** Orders expire after the specified timestamp, limiting the replay window.

6. **Order cancellation:** Users can invalidate specific nonces (`invalidateNonce`) or entire nonce words (`invalidateNonceWord`) to cancel pending orders.

### Dual Protection Redundancy

Both `filledOrders[hash]` and `nonceBitmap[trader][word] & bit` are checked in `_verifySignatures()`. This means an order is rejected if either the hash was seen before OR the nonce was used. This is defense-in-depth: even if one mechanism fails, the other catches replays.

**Replay Verdict: PASS** -- Comprehensive multi-layer replay protection.

---

## Front-Running and MEV Analysis

### Settlement Front-Running

Since `settleTrade()` is permissionless, anyone observing a pending settlement transaction in the mempool can extract the order parameters and signatures. On Avalanche with Snowman consensus (1-2s finality), the mempool exposure window is very short, but validators with transaction ordering power could theoretically:

1. Reorder settlement transactions for preferential execution
2. Extract the matched orders and submit their own settlement first (capturing the `settler` role in the event, though this has no economic benefit since fees go to `matchingValidator`, not settler)

**Assessment:** Low practical risk on Avalanche. The settler receives no economic benefit -- fees are attributed to `matchingValidator` (signed into the order). The main MEV vector would be sandwich attacks (see below).

### Sandwich Attack Resistance

For standard `settleTrade()`, prices are pre-agreed by both parties via EIP-712 signatures. An attacker cannot modify the amounts or prices since they are signed. The only sandwich vector would be:

1. Observing a large settlement pending
2. Front-running with trades on external DEXes to move prices
3. Settling the observed trade
4. Back-running to profit from the price movement

This is an external market manipulation vector, not a contract vulnerability. The signed order amounts protect against in-contract manipulation.

**Assessment:** Standard DEX MEV risk, mitigated by Avalanche fast finality and signed price commitments.

### Flash Loan Manipulation

Flash loans cannot directly affect settlement because:
- Orders are pre-signed with fixed amounts
- The contract does not use spot prices or oracle feeds
- Settlement is deterministic based on signed parameters

A flash loan could only be used to temporarily meet balance/allowance checks, but the actual `safeTransferFrom` would fail if the flash-loaned tokens are returned before the transfer completes (which they would need to be, since the loan must be repaid in the same transaction).

**Assessment:** Not vulnerable to flash loan attacks.

---

## Reentrancy Analysis

### `settleTrade()` -- Token Transfer Paths

Three `safeTransferFrom` calls in `_executeAtomicSettlement()`:
1. `makerOrder.tokenIn` from maker to taker (line 1557)
2. `takerOrder.tokenIn` from taker to maker (line 1574)
3. `takerOrder.tokenIn` from taker to contract (line 1587)

Plus four `safeTransfer` calls in `_distributeFeesWithRebate()` / `_accrueFeeSplit()`:
4. Fee token rebate to maker (line 1625)
5. Fee token LP share to liquidityPool (line 1678)
6. Fee token ODDAO share to oddao (line 1683)
7. Fee token Protocol share to protocolTreasury (line 1688)

All wrapped in `nonReentrant`, preventing direct reentrancy. Read-only reentrancy risk exists (see H-01).

### `settleIntent()` -- Token Transfer Paths

1. `coll.tokenIn` from contract to solver (line 1241)
2. `coll.tokenOut` from solver to trader (line 1250)
3. `coll.tokenOut` from solver to contract (line 1265)
4. `coll.tokenOut` rebate to trader (line 1280)
5-7. `coll.tokenOut` fee split to LP/ODDAO/Protocol (via `_accrueFeeSplit`)

CEI is properly followed: `coll.settled = true` is set at line 1227, before any external calls.

### `cancelIntent()` -- Single Transfer

1. `coll.tokenIn` from contract to trader (line 1330)

`coll.locked = false` is set before the transfer (line 1327). CEI compliant.

### `claimFees()` -- Single Transfer

1. Token from contract to caller (line 1084)

`accruedFees[caller][token] = 0` is set before the transfer (line 1083). CEI compliant.

### `setFeeRecipients()` -- Force-Claim Loop

Up to 300 low-level `call` operations (100 tokens * 3 recipients). Each call has try/catch-style handling with re-credit on failure. `nonReentrant` on the outer function prevents reentrancy.

**Reentrancy Verdict: MOSTLY PASS** -- Direct reentrancy is blocked by `nonReentrant`. Read-only reentrancy risk exists in `settleTrade()` due to CEI violation (H-01). `settleIntent()` and `cancelIntent()` properly follow CEI.

---

## Fee Distribution Verification

### `settleTrade()` Fee Flow

For a 100-token trade:
- Taker fee: `100 * 20 / 10000 = 0.2 tokens` (0.20%)
- Maker rebate: `100 * 5 / 10000 = 0.05 tokens` (0.05%)
- Net fee: `0.2 - 0.05 = 0.15 tokens`

Distribution of net fee (0.15 tokens):
- ODDAO: `0.15 * 2000 / 10000 = 0.03 tokens` (20%)
- Protocol: `0.15 * 1000 / 10000 = 0.015 tokens` (10%)
- LP: `0.15 - 0.03 - 0.015 = 0.105 tokens` (70%, remainder)

The remainder-to-LP approach (line 1675: `lp = fee - od - pt`) ensures no rounding dust is lost. The sum `od + pt + lp` always equals `fee` exactly.

**Fee Distribution Verdict: CORRECT** for `settleTrade()`. The 70/20/10 split is accurately implemented with proper rounding handling.

### `settleIntent()` Fee Flow

See H-02 above for the cross-token rebate mismatch issue.

---

## Balance Accounting Review

### External Balance Model

The contract does NOT maintain internal balance mappings for user deposits. It uses `safeTransferFrom` directly from user wallets during settlement. This is a simpler and safer model -- users retain custody of their tokens until settlement executes.

For intent settlement, the contract holds escrowed tokens (trader's `tokenIn`) between `lockIntentCollateral` and `settleIntent`/`cancelIntent`. The `traderAmount` is stored and used for transfers.

The fee-on-transfer detection (M-07 remediation) uses balance-before/after checks on all major transfers, correctly guarding against deflationary tokens.

### Potential Accounting Issue

In `_executeAtomicSettlement()`, the fee-on-transfer check for the taker fee transfer to the contract (line 1586-1592) does NOT have a balance check:

```solidity
// Line 1586-1592: No balance-before/after check
if (takerFee > 0) {
    IERC20(takerOrder.tokenIn).safeTransferFrom(
        takerOrder.trader, address(this), takerFee
    );
}
```

If a fee-on-transfer token passes the earlier checks (on the net transfer amounts), but takes a fee on this specific transfer, the contract would hold fewer tokens than expected for fee distribution, potentially causing subsequent `safeTransfer` calls to revert (which is fail-safe, not exploitable, since the entire transaction reverts).

**Assessment:** Not exploitable (reverts atomically), but inconsistent with the M-07 philosophy of explicit detection. Low severity.

---

## Positive Security Features (Confirmed)

1. **ReentrancyGuard** on all settlement and claim functions
2. **Ownable2Step** for safe two-step ownership transfer
3. **`renounceOwnership` disabled** -- prevents accidental lockout
4. **EIP-712** typed data signing with proper domain separation
5. **SafeERC20** for all token interactions
6. **Nonce bitmap** (Uniswap Permit2 pattern) for efficient concurrent order support
7. **Dual replay protection** (filledOrders + nonce bitmap)
8. **Fee-on-transfer detection** via balance-before/after checks
9. **48-hour timelock** on trading limits changes
10. **Timelock overwrite prevention** (`PendingChangeExists` error)
11. **Push-pattern fee distribution** (immediate transfer during settlement)
12. **Try/catch fee claiming** with re-credit on failure (prevents DoS)
13. **`removeFeeToken` escape hatch** for problematic tokens
14. **Self-trade prevention**
15. **`cancelIntent` ungated** by pause -- users always have an escape path
16. **No `emergencyWithdraw`** or sweep -- owner fundamentally cannot extract user funds
17. **`tokenIn != tokenOut` validation** prevents self-swap waste
18. **Zero-value guards** on scheduling functions
19. **Remainder-to-LP** for rounding dust (prevents accumulation)
20. **Intent escrow** with real token custody (H-03 fix)
21. **CEI compliance** in `settleIntent()` and `cancelIntent()`
22. **Struct packing** in `IntentCollateral` for gas optimization

---

## Remediation Status (From Round 4 Audit)

| Round 4 Finding | Status | Evidence |
|----------------|--------|----------|
| C-01: Intent settlement zero fees | **FIXED** | `settleIntent()` now calculates `traderRebate` and `solverFee`, distributes via `_accrueFeeSplit` |
| H-01: `applyFeeRecipients` missing nonReentrant | **FIXED** (Redesigned) | Function replaced by `setFeeRecipients()` which has `nonReentrant` (line 883) |
| H-02: Reverting token blocks fee changes | **FIXED** | `_claimAllPendingFees` uses low-level `call` with re-credit on failure; `removeFeeToken` added |
| H-03: No `matchingValidator` in IntentCollateral | **FIXED** | `matchingValidator` field added to struct (line 163) and stored at lock time |
| M-01: Volume tracking one-sided | **FIXED** | Both `makerOrder.amountIn + takerOrder.amountIn` tracked (lines 792-795, 1875-1879) |
| M-02: Fee-on-transfer check missing for fee transfers | **PARTIAL** | Checks added to main transfers but fee transfer to contract in `_executeAtomicSettlement` still lacks explicit check (fail-safe via atomic revert) |
| M-03: Commit-reveal optional | **ACKNOWLEDGED** | NatSpec updated to document it as opt-in (line 735). Architectural decision. |
| M-04: Timelock overwrite | **FIXED** | `PendingChangeExists` error added, `cancelScheduledTradingLimits` function added |
| M-05: `settleIntent` CEI violation | **FIXED** | `coll.settled = true` moved before external calls (line 1227) |
| M-06: Rebasing tokens stuck escrow | **ACKNOWLEDGED** | NatSpec documents incompatibility (line 1111) |
| L-01: Zero trade limits | **FIXED** | Zero check added in `scheduleTradingLimits` (lines 928-930) |
| L-02: `feeTokens` never shrinks | **FIXED** | `removeFeeToken` added (lines 1045-1062) |
| L-03: Emergency stop/pause inconsistent | **PARTIAL** | `emergencyStop` added to `lockIntentCollateral` (line 1124), but redundancy remains |
| L-04: Slippage asymmetric | **NOT FIXED** | Still one-directional (see L-04 above) |
| L-05: `lockIntentCollateral` no emergencyStop | **FIXED** | Check added at line 1124 |
| L-06: No tokenIn != tokenOut check | **FIXED** | Check added in `_verifyOrdersMatch` line 1992 (maker only, see L-05 above) |
| L-07: Event missing slippage | **FIXED** | `maxSlippageBps` added to `TradingLimitsChangeScheduled` event (line 426) |

---

## Static Analysis

### Slither Results

No Slither results available at `/tmp/slither-DEXSettlement.json` (file not found). Static analysis was not pre-run for this audit round.

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
| No unchecked arithmetic that could overflow | PASS (Solidity 0.8.25 has built-in overflow checks) |
| Custom errors used (no revert strings) | PASS |
| All events properly indexed | PASS (some limitations on indexing 4+ params) |
| No storage collisions | PASS (not upgradeable) |
| Constructor validates all addresses | PASS |

---

## Summary of Recommendations (Priority Order)

1. **[H-01] MUST FIX:** Move state updates (`filledOrders`, nonces, volume) before `_executeAtomicSettlement()` in `settleTrade()` to comply with CEI pattern. Zero gas cost, pure defense-in-depth.

2. **[H-02] MUST FIX:** Fix cross-token rebate calculation in `settleIntent()` -- compute rebate on the same token (tokenOut / solverAmount) as the fee, not on traderAmount (tokenIn).

3. **[M-01] SHOULD FIX (before multi-sig handoff):** Add timelock to `setFeeRecipients()` or document Pioneer Phase timeline.

4. **[M-03] SHOULD FIX:** Consolidate taker's token transfers in `_executeAtomicSettlement()` into a single `safeTransferFrom` for simplicity and reduced gas.

5. **[M-04] SHOULD FIX:** Add gas stipend to low-level calls in `_claimAllPendingFees()`.

6. **[L-01] through [L-05]:** Fix at developer's discretion. All are low-impact.

7. **[I-02] MUST FIX:** Update test suite constructor call to pass 4 arguments matching the current contract.

8. **Deploy with multi-sig** (Gnosis Safe) as owner.

9. **Document ERC2771 trust model** -- the trusted forwarder has significant impersonation power.

---

*Generated by Claude Code Audit Agent -- Pre-Mainnet Deep Review (Round 6)*
*Contract revision: post-Round-4 remediation, 2,107 lines*
*Audit scope: Access control, business logic, DeFi exploits, reentrancy, EIP-712 compliance, fee arithmetic*
