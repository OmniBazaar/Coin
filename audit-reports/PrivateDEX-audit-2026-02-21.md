# Security Audit Report: PrivateDEX

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/PrivateDEX.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 657
**Upgradeable:** Yes (UUPS)
**Handles Funds:** No (order matching only — settlement occurs on Avalanche via OmniCore)

## Executive Summary

PrivateDEX is a UUPS-upgradeable privacy-preserving DEX order matching contract built on COTI V2 MPC technology. Users submit orders with encrypted amounts and prices (ctUint64), a MATCHER_ROLE operator matches orders via MPC comparison, and settlement happens off-chain via OmniCore. The contract uses OpenZeppelin's AccessControl, ReentrancyGuard, Pausable, and UUPSUpgradeable.

The audit found **3 Critical vulnerabilities**: (1) the MATCHER_ROLE can fabricate the `encMatchAmount` parameter in `executePrivateTrade()`, allowing theft of arbitrary amounts since no verification binds it to `calculateMatchAmount()`; (2) the three-step matching flow (canOrdersMatch → calculateMatchAmount → executePrivateTrade) has a TOCTOU race condition — there is no cryptographic binding between steps, so conditions can change between calls; (3) the contract uses unchecked MPC arithmetic (`MpcCore.add`/`sub`/`mul`) instead of checked variants, enabling silent overflow/underflow on encrypted values. Both audit agents independently confirmed the fabricated match amount as the top-priority finding.

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 4 |
| Medium | 4 |
| Low | 3 |
| Informational | 2 |

## Findings

### [C-01] MATCHER_ROLE Can Fabricate Match Amount — Unlimited Theft Vector

**Severity:** Critical
**Lines:** 394-451, 397
**Agents:** Both

**Description:**

`executePrivateTrade()` accepts `encMatchAmount` as an externally-supplied `ctUint64` parameter (line 397). The function blindly adds this amount to both orders' `encFilled` fields (lines 409, 414) without verifying that it matches the output of `calculateMatchAmount()`.

The intended flow is:
1. Matcher calls `canOrdersMatch()` → returns true
2. Matcher calls `calculateMatchAmount()` → returns encrypted match amount
3. Matcher calls `executePrivateTrade(buyId, sellId, matchAmount)` → updates orders

But there is NO cryptographic binding between steps 2 and 3. The matcher can:
1. Call `calculateMatchAmount()` to get the legitimate amount (ignore it)
2. Create a fabricated `ctUint64` via `MpcCore.setPublic64(arbitraryValue)`
3. Pass the fabricated amount to `executePrivateTrade()`

Since `executePrivateTrade()` only checks `onlyRole(MATCHER_ROLE)` and order existence — NOT that the match amount is legitimate — the matcher can set any fill amount. This corrupts order state and, when settlement occurs on OmniCore, causes incorrect token transfers.

**Exploit Scenario:**
```
1. Alice submits buy order for 1000 pXOM at price 1.00
2. Bob submits sell order for 1000 pXOM at price 1.00
3. Matcher calls executePrivateTrade(aliceId, bobId, encryptedValue(999999))
4. Both orders show filled = 999999 (far exceeding their actual amounts)
5. Settlement on OmniCore transfers incorrect amounts
```

**Impact:** Complete corruption of trade execution. A malicious or compromised matcher can steal arbitrary amounts during settlement, manipulate order states, and undermine all privacy guarantees.

**Recommendation:** Bind the match amount cryptographically to the calculation:
```solidity
function executePrivateTrade(
    bytes32 buyOrderId,
    bytes32 sellOrderId
    // REMOVE encMatchAmount parameter — calculate internally
) external onlyRole(MATCHER_ROLE) whenNotPaused nonReentrant returns (bytes32 tradeId) {
    // Calculate match amount internally (cannot be fabricated)
    ctUint64 encMatchAmount = _calculateMatchAmount(buyOrderId, sellOrderId);
    // ... rest of execution
}
```

---

### [C-02] TOCTOU Race Condition — Decoupled Three-Step Matching Flow

**Severity:** Critical
**Lines:** 285-321, 330-354, 394-451
**Agent:** Agent B

**Description:**

The three matching functions are independent transactions with no binding:

1. `canOrdersMatch()` — checks price compatibility at time T1
2. `calculateMatchAmount()` — calculates fill amount at time T2
3. `executePrivateTrade()` — executes at time T3

Between T1 and T3:
- Either order can be cancelled
- Either order can be partially filled by another trade
- Order prices are re-read at each step

The `executePrivateTrade()` function does NOT re-validate:
- Order status (lines 402-404 only check existence, not status)
- Price compatibility (buy price >= sell price)
- That the match amount doesn't exceed remaining amounts

A cancelled or fully-filled order can still be "executed" by the matcher because `executePrivateTrade()` has no status check.

**Impact:** Orders can be matched after cancellation. Already-filled orders can be over-filled. Price conditions that were valid at check time may be invalid at execution time.

**Recommendation:** Add comprehensive validation in `executePrivateTrade()`:
```solidity
// Check order statuses
if (buyOrder.status == OrderStatus.FILLED || buyOrder.status == OrderStatus.CANCELLED)
    revert InvalidOrderStatus();
if (sellOrder.status == OrderStatus.FILLED || sellOrder.status == OrderStatus.CANCELLED)
    revert InvalidOrderStatus();

// Re-validate price compatibility
gtUint64 gtBuyPrice = MpcCore.onBoard(buyOrder.encPrice);
gtUint64 gtSellPrice = MpcCore.onBoard(sellOrder.encPrice);
if (!MpcCore.decrypt(MpcCore.ge(gtBuyPrice, gtSellPrice)))
    revert InvalidOrderStatus();
```

---

### [C-03] Unchecked MPC Arithmetic — Silent Overflow/Underflow

**Severity:** Critical
**Lines:** 344, 348, 351, 375, 376, 409, 414
**Agent:** Agent A

**Description:**

The contract uses `MpcCore.add()`, `MpcCore.sub()`, and `MpcCore.mul()` throughout. COTI V2's MpcCore library provides both checked variants (`checkedAdd`, `checkedSub`, `checkedMul`) that revert on overflow, and unchecked variants that silently wrap. This contract exclusively uses the unchecked variants.

Critical locations:
- Line 344: `MpcCore.sub(gtBuyAmount, gtBuyFilled)` — if filled > amount (due to C-01), this wraps to a huge value
- Line 348: `MpcCore.sub(gtSellAmount, gtSellFilled)` — same risk
- Line 409: `MpcCore.add(gtBuyFilled, gtMatchAmount)` — can overflow uint64 max
- Line 414: `MpcCore.add(gtSellFilled, gtMatchAmount)` — same
- Line 375: `MpcCore.mul(gtAmount, gtFeeBps)` — multiplication overflow

With the uint64 max of ~18.4e18, even small amounts can overflow when multiplied by fee basis points if the amounts are already large.

**Impact:** Silent arithmetic wrapping can corrupt fill tracking, cause incorrect order status, and lead to theft during settlement.

**Recommendation:** Replace all unchecked MPC operations with checked variants:
```solidity
// Before:
gtUint64 gtBuyRemaining = MpcCore.sub(gtBuyAmount, gtBuyFilled);
// After:
gtUint64 gtBuyRemaining = MpcCore.checkedSub(gtBuyAmount, gtBuyFilled);

// Before:
gtUint64 gtNewBuyFilled = MpcCore.add(gtBuyFilled, gtMatchAmount);
// After:
gtUint64 gtNewBuyFilled = MpcCore.checkedAdd(gtBuyFilled, gtMatchAmount);

// Before:
gtUint64 gtProduct = MpcCore.mul(gtAmount, gtFeeBps);
// After:
gtUint64 gtProduct = MpcCore.checkedMul(gtAmount, gtFeeBps);
```

---

### [H-01] Unbounded orderIds Array — DoS on View Functions

**Severity:** High
**Lines:** 99, 266, 542, 570-613
**Agents:** Both

**Description:**

The `orderIds` array is append-only — orders are pushed at line 266 but never removed, even when cancelled or filled. Two view functions iterate the entire array:
- `getPrivacyStats()` (line 542): Iterates ALL orderIds to count active orders
- `getOrderBook()` (line 570): Iterates ALL orderIds TWICE (count + fill)

After thousands of orders, these functions will exceed the block gas limit for `eth_call`, making them unusable. The `getOrderBook()` function is particularly expensive because it performs `keccak256(bytes(order.pair))` string hashing inside the loop.

**Impact:** Core query functions become permanently unusable as order count grows. Integrators relying on `getPrivacyStats()` or `getOrderBook()` will experience failures.

**Recommendation:** Maintain separate active-order arrays per pair, or use a counter-based approach:
```solidity
mapping(string => bytes32[]) public activeOrdersByPair;
uint256 public activeOrderCount;

// In submitPrivateOrder():
activeOrdersByPair[pair].push(orderId);
++activeOrderCount;

// On cancel/fill: swap-and-pop from activeOrdersByPair
```

---

### [H-02] No Overfill Guard — encFilled Can Exceed encAmount

**Severity:** High
**Lines:** 406-415
**Agent:** Agent B

**Description:**

`executePrivateTrade()` adds the match amount to `encFilled` without checking that the new filled amount doesn't exceed `encAmount`. While the `eq` check at lines 420-421 determines if an order is fully filled, there is no `le` (less-than-or-equal) check to prevent overfilling.

Combined with C-01 (fabricated match amount), the matcher can set `encFilled` to any value, including values exceeding `encAmount`. The only check is equality — if filled > amount, the order status becomes `PARTIALLY_FILLED` instead of `FILLED`, allowing further matching.

Even without malicious intent, rounding in MPC arithmetic could cause slight overfills that leave orders in a perpetual `PARTIALLY_FILLED` state.

**Recommendation:** Add an overfill check using MPC comparison:
```solidity
gtUint64 gtNewBuyFilled = MpcCore.checkedAdd(gtBuyFilled, gtMatchAmount);
gtBool notOverfilled = MpcCore.ge(gtBuyAmount, gtNewBuyFilled);
if (!MpcCore.decrypt(notOverfilled)) revert InvalidAmount();
```

---

### [H-03] Order ID Collision — Weak Entropy Source

**Severity:** High
**Lines:** 241-246
**Agent:** Agent B

**Description:**

Order IDs are computed as:
```solidity
orderId = keccak256(abi.encodePacked(msg.sender, pair, block.timestamp, totalOrders));
```

Using `abi.encodePacked` with a variable-length `string` (`pair`) creates collision risk — for example, `("pXOM", "-USDC")` and `("pXOM-", "USDC")` produce different logical meanings but could hash identically with adjacent parameters.

More importantly, `pair` is user-controlled. A malicious user can craft pair strings that produce specific hash collisions with existing orders, potentially overwriting them in the `orders` mapping (though the `totalOrders` counter mitigates this by incrementing monotonically).

**Impact:** Theoretical order ID collision. The monotonic counter makes practical exploitation difficult, but the use of `abi.encodePacked` with variable-length data is a known anti-pattern.

**Recommendation:** Use `abi.encode` instead of `abi.encodePacked`:
```solidity
orderId = keccak256(abi.encode(msg.sender, pair, block.timestamp, totalOrders));
```

---

### [H-04] uint64 Precision Limits Violate 18-Digit Precision Requirement

**Severity:** High
**Lines:** All MPC operations
**Agent:** Agent B

**Description:**

The OmniBazaar specification requires "18-digit precision" for all DEX calculations. COTI V2's `ctUint64`/`gtUint64` types support a maximum of `2^64 - 1 = 18,446,744,073,709,551,615` — which is ~18.4 digits. With 18-decimal tokens, this limits orders to ~18.4 XOM per order.

For a DEX that needs to handle large institutional orders, whale trades, and liquidity provision, this is fundamentally insufficient. A single Tier 5 staker (1B+ XOM) cannot place a single order for their holdings.

**Impact:** Privacy-preserving DEX is limited to retail-scale orders only. Large traders cannot use the private DEX.

**Recommendation:** Same as PrivateOmniCoin C-01 — requires COTI V2 to support wider integer types, or implement a scaling factor approach.

---

### [M-01] MAX_ORDERS_PER_USER Is Lifetime Cap, Not Active-Order Cap

**Severity:** Medium
**Lines:** 57, 238
**Agent:** Agent B

**Description:**

`userOrders[msg.sender].length >= MAX_ORDERS_PER_USER` counts ALL orders ever submitted (including cancelled and filled). Once a user hits 100 lifetime orders, they can never submit another order — even if all 100 are cancelled or filled. The `userOrders` array is append-only.

**Impact:** Active traders will be permanently locked out after 100 orders. A griefer can create 100 orders and cancel them all, permanently consuming their quota.

**Recommendation:** Track active order count separately:
```solidity
mapping(address => uint256) public activeOrderCount;

// In submitPrivateOrder():
if (activeOrderCount[msg.sender] >= MAX_ORDERS_PER_USER) revert TooManyOrders();
++activeOrderCount[msg.sender];

// In cancelPrivateOrder() and when filling:
--activeOrderCount[order.trader];
```

---

### [M-02] No Order Expiration Mechanism

**Severity:** Medium
**Lines:** 79-89
**Agent:** Agent B

**Description:**

Orders have no expiry timestamp. An OPEN order remains matchable indefinitely, even if submitted months or years ago. Stale orders at outdated prices can be matched against fresh orders, potentially causing unfavorable fills.

In traditional DEX design, orders have TTL (time-to-live) or GTC (good-till-cancelled) with maximum duration.

**Impact:** Users who forget to cancel orders may be filled at outdated prices. Market makers face stale-order risk.

**Recommendation:** Add expiry to the order struct:
```solidity
struct PrivateOrder {
    // ... existing fields ...
    uint256 expiry;  // Block timestamp after which order is invalid
}

// In executePrivateTrade():
if (block.timestamp > buyOrder.expiry) revert InvalidOrderStatus();
```

---

### [M-03] No Slippage Protection for Traders

**Severity:** Medium
**Lines:** 231-272
**Agent:** Agent B

**Description:**

The `submitPrivateOrder()` function has no slippage or minimum fill amount parameter. Traders cannot specify minimum acceptable fill amounts or maximum acceptable price deviation. The matcher has full discretion over matching, and the trader has no recourse if matched at an unfavorable price (given C-01 allows arbitrary match amounts).

**Recommendation:** Add optional slippage parameters or allow traders to set minimum fill amounts.

---

### [M-04] Matcher Can Front-Run and Binary-Search Encrypted Prices

**Severity:** Medium
**Lines:** 285-321
**Agent:** Agent A

**Description:**

`canOrdersMatch()` reveals a boolean result (`true`/`false`) about the price relationship. A malicious matcher can binary-search the price space by:
1. Submitting probe orders at known prices
2. Calling `canOrdersMatch()` against a target order
3. Narrowing the price range with each probe

After ~64 probes (log2 of uint64 range), the matcher knows the exact encrypted price. This violates the privacy guarantee that "only trader can decrypt their own data."

**Impact:** Encrypted prices can be reverse-engineered by the matcher through oracle queries. Privacy is illusory against the matcher role.

**Recommendation:** Rate-limit `canOrdersMatch()` calls per order pair, or use a commitment scheme where the matcher commits to a match before learning the result.

---

### [L-01] canOrdersMatch Has No Access Control

**Severity:** Low
**Lines:** 285-321
**Agent:** Agent A

**Description:**

`canOrdersMatch()` is callable by anyone, not just MATCHER_ROLE. Any address can probe whether two orders can match, leaking boolean price relationship information. While the full binary-search attack (M-04) requires creating probe orders, even the simple boolean leak reduces privacy.

**Recommendation:** Add `onlyRole(MATCHER_ROLE)` modifier.

---

### [L-02] calculateMatchAmount Has No Access Control

**Severity:** Low
**Lines:** 330-354
**Agent:** Agent A

**Description:**

Like `canOrdersMatch()`, `calculateMatchAmount()` is callable by anyone. While the return value is encrypted (`ctUint64`), the caller can potentially learn information from gas usage patterns or MPC operation side-channels.

**Recommendation:** Add `onlyRole(MATCHER_ROLE)` modifier.

---

### [L-03] grantMatcherRole Uses InvalidAmount Error

**Severity:** Low
**Lines:** 643-645
**Agent:** Agent A

**Description:**

`grantMatcherRole()` reverts with `InvalidAmount()` when `matcher == address(0)`. The error name is misleading — it's not an amount issue, it's an address validation issue.

**Recommendation:** Use a dedicated error: `error InvalidAddress();`

---

### [I-01] Unused ReentrancyGuard on View Functions

**Severity:** Informational
**Agent:** Agent A

**Description:**

The contract inherits `ReentrancyGuardUpgradeable` but only uses `nonReentrant` on `submitPrivateOrder` and `executePrivateTrade`. The MPC-calling functions `canOrdersMatch()`, `calculateMatchAmount()`, `calculateTradeFees()`, and `isOrderFullyFilled()` are state-changing (due to MPC) but not protected.

**Recommendation:** Consider adding `nonReentrant` to all MPC-calling functions.

---

### [I-02] Event Data Leak — pair String Is Public

**Severity:** Informational
**Agent:** Agent B

**Description:**

The `PrivateOrderSubmitted` event includes `string pair` in plain text. While amounts and prices are encrypted, the trading pair reveals what assets the user is trading, partially compromising privacy. An observer can build a user's trading portfolio by pair.

**Recommendation:** Consider encrypting or hashing the pair in events if full privacy is desired.

---

## Static Analysis Results

**Solhint:** 0 errors, 8 warnings
- 2 function ordering (style)
- 3 not-rely-on-time (accepted — order timestamps are business requirement)
- 2 gas-strict-inequalities
- 1 no-global-import

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 37 raw findings -> 16 unique)
- Pass 6: Report generation

## Conclusion

PrivateDEX has **three Critical vulnerabilities that make the contract fundamentally insecure**:

1. **Fabricated match amount (C-01)** allows the MATCHER_ROLE to set arbitrary fill amounts, completely undermining trade integrity. The fix is to calculate match amounts internally rather than accepting them as parameters.

2. **TOCTOU race condition (C-02)** means the three-step matching flow has no binding — orders can be cancelled, filled, or modified between validation and execution. All validation must be repeated in `executePrivateTrade()`.

3. **Unchecked MPC arithmetic (C-03)** enables silent overflow/underflow on encrypted values. All `MpcCore.add/sub/mul` calls must be replaced with `checkedAdd/checkedSub/checkedMul`.

4. **Unbounded array DoS (H-01)** will permanently disable `getPrivacyStats()` and `getOrderBook()` as order count grows.

5. **uint64 precision (H-04)** limits orders to ~18.4 XOM — same fundamental limitation as PrivateOmniCoin.

The contract requires significant security hardening before any deployment. The MATCHER_ROLE has excessive unilateral power that must be constrained. No tests exist for this contract, which should be considered a deployment blocker.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
