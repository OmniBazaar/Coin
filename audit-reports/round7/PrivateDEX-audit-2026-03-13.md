# Security Audit Report: PrivateDEX.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 20:58 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/PrivateDEX.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,323
**Upgradeable:** Yes (UUPS with two-step ossification, 7-day delay)
**Handles Funds:** No (order matching only -- settlement via PrivateDEXSettlement on Avalanche)
**OpenZeppelin Version:** 5.x (upgradeable contracts)
**Dependencies:** `MpcCore` (COTI V2 MPC library), OZ `AccessControlUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `UUPSUpgradeable`, `ERC2771ContextUpgradeable`
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
**Solhint Output:** 0 errors, 1 warning (`gas-strict-inequalities` at line 1102 -- acceptable, see I-04)

---

## Executive Summary

PrivateDEX is a UUPS-upgradeable privacy-preserving DEX order matching contract built on COTI V2 MPC garbled circuits. Users submit orders with encrypted amounts and prices (`ctUint64`), a `MATCHER_ROLE` operator matches orders using MPC comparison and execution, and actual token settlement occurs externally on Avalanche via `PrivateDEXSettlement`. The contract has undergone three prior audit rounds with all Critical, High, and Medium findings remediated.

This Round 7 audit is a comprehensive pre-mainnet final review. Since Round 6, one new function has been added: `cleanupUserOrders()` (lines 882-907), which addresses the M-02 storage growth concern from Round 6 by allowing users to prune terminal (FILLED/CANCELLED) order IDs from their `userOrders` array. Additionally, the `setMatcherRoleAdmin()` function (lines 994-998) has been added for ValidatorProvisioner integration.

This audit identifies the following:

### Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 5 |

No new Critical or High findings. The contract has reached a mature security posture suitable for mainnet deployment, contingent on operational deployment of ADMIN_ROLE behind a multi-sig or TimelockController.

---

## Remediation Status from All Prior Audits

| Prior Finding | Round | Severity | Status | Verification |
|---------------|-------|----------|--------|--------------|
| R1 C-01: MATCHER_ROLE can fabricate match amount | R1 | Critical | **Fixed** | `executePrivateTrade()` computes `min(buyRemaining, sellRemaining)` internally (lines 713-731). Parameter removed. |
| R1 C-02: TOCTOU race between canOrdersMatch/executePrivateTrade | R1 | Critical | **Fixed** | `executePrivateTrade()` re-validates status (660-672), sides (675-676), pair (679-684), expiry (688-700), price (703-711). Fully self-contained. |
| R1 C-03: Unchecked MPC arithmetic | R1 | Critical | **Fixed** | All arithmetic uses `checkedAdd`/`checkedSub`/`checkedMul` (lines 568, 575, 615, 739, 743). |
| R1 H-01: Unbounded orderIds iteration | R1 | High | **Partially Fixed** | `getPrivacyStats()` uses O(1) counter. `getOrderBook()` still iterates but is view-only with `maxOrders` cap. See M-01 below. |
| R1 H-02: No overfill guard | R1 | High | **Fixed** | Overfill check at lines 746-756 with `ge(amount, newFilled)` + decrypt. |
| R1 H-03: Weak order ID entropy | R1 | High | **Fixed** | Uses `abi.encode` with `prevrandao`, per-user counter, `totalOrders` (lines 405-412). |
| R1 H-04: uint64 precision limitation | R1 | High | **Acknowledged** | Architectural COTI V2 constraint. Documented in NatSpec (lines 55-59). |
| R1 M-01: Active order count tracks lifetime | R1 | Medium | **Fixed** | `activeOrderCount` decremented on fill/cancel (lines 768-770, 789-791, 853-855). |
| R1 M-02: No order expiry | R1 | Medium | **Fixed** | Expiry field (line 135), checked in `canOrdersMatch()` (496-507) and `executePrivateTrade()` (688-700). |
| R1 M-03: No minimum fill amount | R1 | Medium | **Fixed** | `encMinFill` field (line 136), `_checkMinFill()` function (lines 1235-1249). |
| R1 M-04: canOrdersMatch() unrestricted | R1 | Medium | **Fixed** | Requires `MATCHER_ROLE` (line 465). |
| R3 C-01: Fabricated match amount (carried) | R3 | Critical | **Fixed** | Same as R1 C-01. |
| R3 C-02: No price re-validation in executePrivateTrade | R3 | Critical | **Fixed** | MPC `ge(buyPrice, sellPrice)` at lines 703-711 with `PriceIncompatible()` revert. |
| R3 H-01: Unchecked MPC arithmetic (carried) | R3 | High | **Fixed** | Same as R1 C-03. |
| R3 H-02: calculateTradeFees no access control | R3 | High | **Fixed** | `MATCHER_ROLE` + `uint64 feeBps` type + `MAX_FEE_BPS` cap (lines 596-603). |
| R3 H-03: uint64 precision (carried) | R3 | High | **Acknowledged** | Same as R1 H-04. |
| R3 M-01: Ossification has no timelock | R3 | Medium | **Fixed** | Two-step: `requestOssification()` + `confirmOssification()` + 7-day `OSSIFICATION_DELAY` (lines 1011-1046). |
| R3 M-02: Double onboard of encMatchAmount | R3 | Medium | **Fixed** | Match amount computed once internally; `_checkMinFill` accepts `gtUint64` directly (lines 734-735). |
| R3 M-03: Trade ID uses abi.encodePacked | R3 | Medium | **Fixed** | Uses `abi.encode` + `block.prevrandao` (lines 808-815). |
| R6 H-01: uint64 precision (carried) | R6 | High | **Acknowledged** | Architectural. Documented extensively in NatSpec. |
| R6 M-01: getOrderBook() unbounded iteration | R6 | Medium | **Acknowledged** | View-only function for off-chain use. See M-01 below. |
| R6 M-02: No mechanism to clean up orderIds array | R6 | Medium | **Partially Fixed** | `cleanupUserOrders()` added for per-user cleanup (lines 882-907). Global `orderIds` array remains append-only. See M-02 below. |
| R6 L-01: Order ID collision theoretical risk | R6 | Low | **Acknowledged** | Negligible. `(caller, userCount)` provides uniqueness. |
| R6 L-02: canOrdersMatch/calculateMatchAmount redundant | R6 | Low | **Acknowledged** | Kept as pre-flight utility functions for matchers. |
| R6 L-03: ERC-2771 forwarder immutable | R6 | Low | **Acknowledged** | Standard pattern; rotation requires upgrade. |
| R6 I-01: getOrderBook() returns stale expired orders | R6 | Info | **Not Fixed** | See I-01 below. |
| R6 I-02: Trading pair plaintext in events | R6 | Info | **Acknowledged** | Design decision for matcher efficiency. |
| R6 I-03: MAX_ORDERS_PER_USER may be insufficient | R6 | Info | **Acknowledged** | Protective limit, configurable via upgrade only. |
| R6 I-04: Storage gap calculation accurate | R6 | Info | **Confirmed** | Gap = 50 - 6 = 44 is correct. |
| R6 M-01 (msg.sender) | R6 | Medium | **Fixed** | All public functions use `_msgSender()`. |
| R6 M-02 (missing whenNotPaused) | R6 | Medium | **Fixed** | `submitPrivateOrder()` and `cancelPrivateOrder()` have `whenNotPaused`. |

---

## Findings

### [M-01] `getOrderBook()` Iterates Full `orderIds` Array -- Unbounded Gas (Carried Forward from R6 M-01)

**Severity:** Medium
**Lines:** 1142-1221
**Status:** ACKNOWLEDGED -- intended for off-chain use only

**Description:**

`getOrderBook()` iterates the entire `orderIds` array twice: once to count matching orders (lines 1158-1177) and once to fill result arrays (lines 1192-1218). The `maxOrders` parameter caps output size but not iteration cost. After tens of thousands of lifetime orders, this function will exceed the block gas limit even for `eth_call`.

**Mitigating factors:**
- View function; cannot corrupt state.
- Intended for off-chain monitoring/UI use, not on-chain consumption.
- Production order book queries should use event-based off-chain indexing, as documented in the function NatSpec (lines 1122-1135).
- Core operations (submit, match, execute, cancel) are O(1) -- they access orders by ID directly and are unaffected.

**Impact:** `getOrderBook()` becomes unusable as total lifetime order count grows. No effect on core DEX operations.

**Recommendation:** Accept as known limitation. Document that production deployments should use event-based indexing (e.g., The Graph) rather than this on-chain view function. Consider adding `@dev` NatSpec stating "WARNING: O(totalOrders) gas cost -- unsuitable for on-chain calls in production."

---

### [M-02] Global `orderIds` Array Grows Without Bound (Carried Forward from R6 M-02, Partially Addressed)

**Severity:** Medium
**Lines:** 165, 435

**Description:**

The `orderIds` array is append-only. Every submitted order adds an entry that persists permanently regardless of status. The Round 6 M-02 finding recommended cleanup mechanisms. The new `cleanupUserOrders()` function (lines 882-907) addresses the per-user `userOrders` array but the global `orderIds` array remains uncapped.

Over the contract's lifetime:
- Storage cost: Each `bytes32` entry consumes one storage slot (20,000 gas cold write at submission, permanent 32 bytes).
- At 100,000 orders: `orderIds.length` = 100,000, `getOrderBook()` iterates 100,000 entries.
- The `orderIds` array itself is only consumed by `getOrderBook()` -- no core operation iterates it.

**What `cleanupUserOrders()` does address:**
- Users can compact their own `userOrders[msg.sender]` array by removing FILLED/CANCELLED entries (lines 891-906).
- Uses swap-and-pop pattern with bounded `maxCleanup` parameter to limit gas cost per call.
- Correctly only processes the caller's own orders.

**What remains unaddressed:**
- The global `orderIds` array has no cleanup mechanism.
- Adding swap-and-pop removal to `orderIds` would break index-based references held by external indexers, as noted in the NatSpec at lines 1128-1135.

**Impact:** Permanent storage growth of the global `orderIds` array. No direct security impact. The per-user cleanup via `cleanupUserOrders()` mitigates the more pressing per-user storage growth concern.

**Recommendation:** Accept as a design trade-off. The `orderIds` array serves as an immutable on-chain audit trail. Off-chain indexers should use events, not array iteration. Consider adding a NatSpec comment on the `orderIds` declaration noting it is intentionally append-only.

---

### [L-01] `cleanupUserOrders()` Lacks `nonReentrant` Guard

**Severity:** Low
**Lines:** 882-907

**Description:**

The new `cleanupUserOrders()` function modifies storage (swap-and-pop on the `userOrders` array) but does not have the `nonReentrant` modifier. All other state-modifying functions in the contract use `nonReentrant`.

**Analysis of exploit potential:**
- The function does not call any external contracts, make MPC precompile calls, or transfer tokens.
- It only modifies `userOrders[caller]` -- the caller's own array.
- The swap-and-pop pattern is deterministic and does not depend on external state.
- Solidity 0.8.24 storage array `.pop()` does not invoke any callbacks.
- There is no re-entrancy vector in the current implementation.

**Impact:** No exploitable re-entrancy path exists in the current code. However, adding `nonReentrant` would provide defense-in-depth consistent with the contract's established pattern and protect against re-entrancy if the function is modified in a future upgrade.

**Recommendation:** Add `nonReentrant` to `cleanupUserOrders()` for consistency and defense-in-depth:
```solidity
function cleanupUserOrders(
    uint256 maxCleanup
) external nonReentrant returns (uint256 removed) {
```

---

### [L-02] `cleanupUserOrders()` Lacks `whenNotPaused` Guard

**Severity:** Low
**Lines:** 882-907

**Description:**

The `cleanupUserOrders()` function can be called even when the contract is paused. This is inconsistent with `submitPrivateOrder()` and `cancelPrivateOrder()`, which require `whenNotPaused`.

**Counter-argument:** There is a legitimate case for allowing cleanup during pause -- users should be able to manage their storage even when trading is halted. This is similar to the `claimFees()` pattern in `PrivateDEXSettlement` (which intentionally omits `whenNotPaused`).

**Impact:** Low. The function performs only storage cleanup (removing terminal order IDs from a user's array). It does not affect order state, matching, or trading. Allowing it during pause may actually be desirable.

**Recommendation:** Either:
1. Add `whenNotPaused` for consistency with other user-facing functions, or
2. Add a NatSpec comment explicitly documenting the intentional omission, e.g.: `@dev Intentionally callable while paused -- users may clean up storage even during emergency pause.`

---

### [L-03] `ossificationRequestTime` Can Be Reset by Calling `requestOssification()` Again

**Severity:** Low
**Lines:** 1011-1022

**Description:**

An admin can call `requestOssification()` multiple times, each time resetting `ossificationRequestTime` to the current `block.timestamp`. This restarts the 7-day delay. If multiple admins share the `DEFAULT_ADMIN_ROLE`, a malicious or compromised admin could perpetually delay ossification by repeatedly calling `requestOssification()` to reset the timer.

Conversely, this is also a safety mechanism: if ossification was requested prematurely, the admin can re-request to restart the delay period rather than being forced to confirm a premature ossification.

**Impact:** Low. Both interpretations (safety mechanism vs. griefing vector) are valid. In a multi-sig setup, re-requesting requires multi-sig approval, limiting the griefing risk. In a single-admin setup, the admin already has full control.

**Recommendation:** Add a state check to prevent re-request if already pending:
```solidity
function requestOssification()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (ossificationRequestTime != 0) revert OssificationAlreadyRequested();
    ossificationRequestTime = block.timestamp;
    ...
}
```
Alternatively, add a `cancelOssification()` function with its own event, making the intention explicit.

---

### [L-04] `isOrderFullyFilled()` Is Publicly Callable -- Information Leak for Encrypted Orders

**Severity:** Low
**Lines:** 920-941

**Description:**

`isOrderFullyFilled()` is callable by any address (no role restriction). It decrypts the result of `MpcCore.eq(filled, amount)` and returns a boolean indicating whether an order is fully filled. While the order's status field is already public (and transitions to `FILLED` when fully filled), this function provides a redundant on-chain confirmation mechanism that performs an MPC decrypt.

When called on a `PARTIALLY_FILLED` order, the function reveals whether the partially-filled order has actually reached full fill (which may occur if the status update in `executePrivateTrade()` failed to detect it due to MPC network issues). This is a minor information leak beyond what is already visible in the public `status` field.

More importantly, the function does not have `whenNotPaused`, allowing MPC operations during emergency pause.

**Mitigating factors:**
- The `status` field already reveals whether an order is `FILLED`.
- The function only reveals a boolean (filled or not), not amounts.
- The `nonReentrant` guard prevents abuse within a single transaction.

**Impact:** Minimal additional information leak beyond the public `status` field. MPC resource consumption during pause is the larger concern.

**Recommendation:** Consider adding `whenNotPaused` to prevent MPC operations during emergency pause. Access restriction to the order's trader or `MATCHER_ROLE` is optional but would reduce unnecessary MPC precompile invocations.

---

### [I-01] `getOrderBook()` Returns Expired Orders (Carried Forward from R6 I-01)

**Severity:** Informational
**Lines:** 1158-1177

**Description:**

`getOrderBook()` filters by status (OPEN or PARTIALLY_FILLED) but does not check order expiry. An expired order with status OPEN will be included in the results. The order cannot actually be matched (expiry is checked in `canOrdersMatch()` and `executePrivateTrade()`), but the returned order book contains stale entries.

**Recommendation:** Add an expiry filter:
```solidity
if (order.expiry != 0 && block.timestamp > order.expiry) continue;
```

---

### [I-02] `cleanupUserOrders()` Does Not Emit an Event

**Severity:** Informational
**Lines:** 882-907

**Description:**

The `cleanupUserOrders()` function modifies the `userOrders` storage array (removing terminal entries via swap-and-pop) but does not emit any event recording the cleanup. Off-chain indexers tracking `userOrders` state would not be notified of array mutations.

**Mitigating factors:**
- The NatSpec at line 877 explicitly notes that off-chain indexers should use events, not array indexes.
- The function is a storage optimization, not a business logic operation.

**Recommendation:** Consider emitting an event for observability:
```solidity
event UserOrdersCleaned(address indexed user, uint256 removed);
```

---

### [I-03] `setMatcherRoleAdmin()` Allows Irrevocable Admin Transfer of MATCHER_ROLE

**Severity:** Informational
**Lines:** 994-998

**Description:**

The `setMatcherRoleAdmin()` function calls `_setRoleAdmin(MATCHER_ROLE, newAdminRole)`, which transfers admin authority over `MATCHER_ROLE` from `DEFAULT_ADMIN_ROLE` to `newAdminRole`. After this call:

1. Only holders of `newAdminRole` can `grantRole`/`revokeRole` for `MATCHER_ROLE`.
2. `DEFAULT_ADMIN_ROLE` holders can no longer directly manage `MATCHER_ROLE`.
3. The `grantMatcherRole()` and `revokeMatcherRole()` convenience functions (lines 968-984) still use `onlyRole(DEFAULT_ADMIN_ROLE)`, so they call `_grantRole`/`_revokeRole` which bypass the role admin check. This creates an inconsistency: the convenience functions still work with `DEFAULT_ADMIN_ROLE`, but direct `grantRole(MATCHER_ROLE, addr)` calls require `newAdminRole`.

**Analysis:**
- This is the intended integration pattern for `ValidatorProvisioner`, which would hold the new admin role and programmatically manage MATCHER_ROLE grants for validated nodes.
- The convenience functions (`grantMatcherRole`/`revokeMatcherRole`) use internal `_grantRole`/`_revokeRole` which bypass OZ's role admin check, so `DEFAULT_ADMIN_ROLE` retains a backdoor to manage matchers. This dual-path access may be intentional (admin override) or an oversight.

**Impact:** No direct security vulnerability. The `DEFAULT_ADMIN_ROLE` retains control via the internal functions, which provides a safety net.

**Recommendation:** Document whether the dual-path access (convenience functions via `DEFAULT_ADMIN_ROLE` + standard `grantRole` via `newAdminRole`) is intentional. If the intent is for `newAdminRole` to have exclusive control, the convenience functions should be updated to check `newAdminRole` instead of `DEFAULT_ADMIN_ROLE`, or removed entirely after provisioner integration.

---

### [I-04] Solhint `gas-strict-inequalities` Warning on `getUserOrdersPaginated()` (Acceptable)

**Severity:** Informational
**Lines:** 1102

**Description:**

Solhint reports a `gas-strict-inequalities` warning at line 1102:
```solidity
if (offset >= total || limit == 0) {
```

The `>=` operator uses 3 gas more than `>` per comparison. This is a negligible gas difference in a view function.

**Recommendation:** No change needed. The `>=` is semantically correct (if offset equals total, there are no elements to return). A strict `>` would be incorrect here.

---

### [I-05] Trading Pair String Emitted in Plaintext (Carried Forward from R6 I-02)

**Severity:** Informational
**Lines:** 221-225, 442

**Description:**

The `PrivateOrderSubmitted` event includes `string pair` in plaintext. While amounts and prices are encrypted, the trading pair reveals what assets the user is trading. An observer can correlate addresses with trading interests.

This is an acknowledged design decision: pair visibility enables off-chain matchers to identify potential matches without decrypting order details. The trade-off between matcher efficiency and trader privacy is reasonable for a semi-private DEX.

**Recommendation:** No change. Acknowledged design decision.

---

## Architecture Analysis

### New Code Review: `cleanupUserOrders()` (Lines 882-907)

This function was added after Round 6 to address M-02 (no mechanism to clean up `userOrders`). Detailed analysis:

**Logic correctness:**
```solidity
while (i < len && processed < maxCleanup) {
    OrderStatus status = orders[arr[i]].status;
    if (status == OrderStatus.FILLED || status == OrderStatus.CANCELLED) {
        arr[i] = arr[len - 1];  // Swap with last
        arr.pop();               // Remove last
        --len;                   // Update local length tracker
        ++removed;               // Count removals
    } else {
        ++i;                     // Only advance if not removed
    }
    ++processed;                 // Always count toward limit
}
```

- **Swap-and-pop correctness:** When a terminal entry is found at index `i`, it is replaced with the last element and the array is shortened. Index `i` is NOT incremented, so the swapped-in element is checked on the next iteration. This is correct.
- **Length tracking:** `len` is decremented alongside `.pop()`, keeping the local variable synchronized with the actual array length. This prevents out-of-bounds access.
- **Processed counter:** `processed` increments on every iteration (both remove and skip paths), ensuring the function terminates within `maxCleanup` iterations regardless of array content. This bounds gas cost.
- **Edge cases:**
  - Empty array: `len = 0`, loop does not execute, returns 0. Correct.
  - `maxCleanup = 0`: Loop condition `processed < 0` is immediately false. Returns 0. Correct.
  - All entries terminal: Array is fully cleaned in one call (if `maxCleanup >= len`). Correct.
  - No terminal entries: Loop advances `i` and `processed` for each entry, returns 0. Correct.
  - Single element array with terminal status: `arr[0] = arr[0]` (self-swap, harmless), then `.pop()`. Array becomes empty. Correct.

**Security properties:**
- Caller identity: Uses `_msgSender()` for ERC-2771 compatibility. Only modifies caller's own `userOrders`. Correct.
- No external calls: Pure storage manipulation. No re-entrancy vector.
- Does not modify `orders` mapping: Only removes references from the user's array, not the orders themselves. Order data remains accessible by ID.
- Does not affect `activeOrderCount` or `totalActiveOrders`: These counters are managed by `executePrivateTrade()` and `cancelPrivateOrder()`. `cleanupUserOrders()` only removes already-terminal entries from the tracking array. Correct.

**Verdict:** The function is correctly implemented. Findings L-01 and L-02 (missing `nonReentrant` and `whenNotPaused`) are defense-in-depth suggestions, not exploitable issues.

### New Code Review: `setMatcherRoleAdmin()` (Lines 994-998)

This function delegates MATCHER_ROLE admin authority to a new role (intended for ValidatorProvisioner integration).

**Logic correctness:**
- Calls OZ `_setRoleAdmin(MATCHER_ROLE, newAdminRole)`, which is the standard mechanism.
- Protected by `onlyRole(DEFAULT_ADMIN_ROLE)`.
- Does not validate that `newAdminRole` is a role that has been granted to any address. This is acceptable -- the admin should ensure the provisioner holds the new role before calling this.

**Security properties:**
- One-way: Once set, `DEFAULT_ADMIN_ROLE` cannot re-set the role admin back to itself via `grantRole`/`revokeRole` (OZ checks `getRoleAdmin(role)` in `grantRole` and `revokeRole`). However, the convenience functions `grantMatcherRole()`/`revokeMatcherRole()` use `_grantRole`/`_revokeRole` (internal, no admin check), so `DEFAULT_ADMIN_ROLE` retains a backdoor. See I-03.
- No event emitted by `setMatcherRoleAdmin()` itself, but OZ's `_setRoleAdmin` emits `RoleAdminChanged(MATCHER_ROLE, oldAdmin, newAdminRole)`. Sufficient.

**Verdict:** Correctly implemented for the intended ValidatorProvisioner integration pattern.

### Design Strengths (Confirmed from Prior Rounds)

1. **Internal Match Amount Computation (C-01 Fix):** `executePrivateTrade()` computes `min(buyRemaining, sellRemaining)` internally (lines 713-731). The matcher cannot fabricate or influence match amounts. The critical security fix from Round 1 remains intact and correctly implemented.

2. **Comprehensive Self-Contained Validation (C-02 Fix):** `executePrivateTrade()` re-validates all preconditions: order existence (653-658), status (660-672), sides (675-676), pair (679-684), expiry (688-700), price compatibility (703-711), overfill (746-756), and minimum fill (734-735). No dependency on prior `canOrdersMatch()` calls.

3. **Checked MPC Arithmetic Throughout (H-01 Fix):** All arithmetic uses checked variants:
   - `checkedSub` for remaining amounts (lines 568, 575, 721, 728)
   - `checkedAdd` for filled amount updates (lines 739, 743)
   - `checkedMul` for fee calculation (line 615)
   These revert on overflow/underflow, providing fail-closed behavior.

4. **Two-Step Ossification (M-01 Fix):** `requestOssification()` + `confirmOssification()` with 7-day `OSSIFICATION_DELAY` (lines 1011-1046). Prevents accidental irreversible lockout.

5. **Overfill Protection:** Double protection: `checkedAdd` reverts on arithmetic overflow, and explicit `ge(amount, newFilled)` + `decrypt()` guard at lines 746-756 catches logical overfill.

6. **ERC-2771 Meta-Transaction Support:** Diamond inheritance between `ContextUpgradeable` and `ERC2771ContextUpgradeable` correctly resolved via explicit overrides of `_msgSender()` (lines 1280-1287), `_msgData()` (lines 1297-1304), and `_contextSuffixLength()` (lines 1315-1322).

7. **Comprehensive NatSpec Documentation:** Every public/external function, event, error, and state variable has complete NatSpec documentation including parameter descriptions, security notes, audit finding cross-references, and architecture rationale.

### Privacy Analysis (Unchanged from Round 6)

**Encrypted (private):**
- Order amounts (`encAmount`, `encFilled`, `encMinFill`)
- Order prices (`encPrice`)
- Match amounts (computed internally, never stored publicly)
- Fee amounts (computed in `calculateTradeFees()`, returned encrypted)

**Public (observable):**
- Trader addresses, trading pair strings, order direction (buy/sell)
- Order timestamps, expiry, status transitions
- Trade occurrence (via `PrivateOrderMatched` events)
- Number of orders per user (`activeOrderCount`, `userOrders`)

**Privacy threat model remains unchanged:** Passive observers see who trades, on what pairs, in what direction, and when -- but not amounts or prices. MATCHER_ROLE holders additionally observe MPC comparison booleans. COTI MPC nodes handle garbled values but cannot reconstruct plaintext (assuming MPC protocol security).

### MPC Operation Safety (All Operations Verified)

| Operation | Locations | Safety |
|-----------|-----------|--------|
| `onBoard` | Lines 525, 527, 564, 566, 606, 704, 706, 718, 720, 724, 726, 936, 937, 1239 | Converts ciphertext to computation type; no arithmetic risk |
| `offBoard` | Lines 416, 581, 618, 759, 760 | Converts computation type to ciphertext; no arithmetic risk |
| `setPublic64` | Lines 415, 609, 610 | Creates public value; no risk |
| `ge` | Lines 528, 708, 747, 753, 1245 | Comparison; reveals boolean only |
| `eq` | Lines 765, 787 | Comparison; reveals boolean only |
| `min` | Lines 579, 731 | Minimum; no overflow risk |
| `checkedSub` | Lines 568, 575, 721, 728 | Reverts on underflow |
| `checkedAdd` | Lines 739, 743 | Reverts on overflow |
| `checkedMul` | Line 615 | Reverts on overflow |
| `div` | Line 616 | Division; result <= dividend |
| `decrypt` | Lines 531, 709, 748, 754, 766, 788, 938, 1246 | Reveals boolean/value; access-controlled or public |

**Total MPC operations per `executePrivateTrade()` call:** ~19 (8 onBoard, 2 checkedSub, 1 min, 2 ge+decrypt for min fill, 1 ge+decrypt for price, 2 checkedAdd, 2 ge+decrypt for overfill, 2 eq+decrypt for full fill). This is within acceptable limits for COTI MPC precompile gas costs.

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `pause()`, `unpause()`, `grantMatcherRole()`, `revokeMatcherRole()`, `setMatcherRoleAdmin()`, `requestOssification()`, `confirmOssification()`, `_authorizeUpgrade()` | 6/10 |
| `MATCHER_ROLE` | `canOrdersMatch()`, `calculateMatchAmount()`, `calculateTradeFees()`, `executePrivateTrade()` | 7/10 |
| Any address | `submitPrivateOrder()` (self), `cancelPrivateOrder()` (self), `cleanupUserOrders()` (self), `isOrderFullyFilled()` (any order), all view functions | 2/10 |

**MATCHER_ROLE trust boundary:** The matcher can choose which orders to match and when (ordering/timing control), but cannot fabricate match amounts, bypass price compatibility checks, or overfill orders. Matcher power is limited to selective matching (potential for censorship or timing-based front-running).

**ADMIN_ROLE trust boundary:** The admin can halt trading (pause), upgrade to a new implementation (before ossification), grant/revoke roles, delegate MATCHER_ROLE admin authority, and permanently ossify. A compromised admin could halt trading or upgrade to a malicious implementation (mitigated by multi-sig + timelock in production).

---

## Centralization Risk Assessment

**Single-key maximum damage (ADMIN_ROLE):** Halt all trading (pause), upgrade to malicious implementation (before ossification), grant matcher role to attacker, permanently ossify preventing future fixes, or delegate MATCHER_ROLE admin to a malicious provisioner.

**Single-key maximum damage (MATCHER_ROLE):** Selectively match orders (front-running by timing), refuse to match certain orders (censorship), spam MPC operations (resource exhaustion). Cannot fabricate amounts, bypass price checks, or modify orders.

**Centralization Risk Rating:** 5/10 (Moderate). Matcher power is significantly constrained. Admin upgrade authority is time-locked via ossification. Production deployment should use multi-sig + TimelockController for ADMIN_ROLE.

---

## Economic Invariants

1. **Fill amount never exceeds order amount:** Enforced by `checkedAdd` (overflow revert) and explicit `ge(amount, newFilled)` overfill guard. Both conditions are checked on every trade execution. **Verified: Correct.**

2. **Active order count is consistent:** `activeOrderCount[trader]` and `totalActiveOrders` are incremented on submit (+1) and decremented on fill/cancel (-1). The `> 0` guards before decrement prevent underflow. **Verified: Correct.** Note: if a FILLED/CANCELLED order is somehow re-matched (impossible due to status checks at lines 660-672), the counter would not be double-decremented because the function reverts before reaching the counter update.

3. **Match amount equals minimum of remaining amounts:** `min(buyRemaining, sellRemaining)` is computed internally (lines 729-731) using MPC. No external input influences the match amount. **Verified: Correct.**

4. **Orders cannot be matched after expiry:** Expiry check in both `canOrdersMatch()` (lines 496-507) and `executePrivateTrade()` (lines 688-700). Zero expiry means no expiry (good-till-cancelled). **Verified: Correct.**

5. **Filled/Cancelled orders cannot be matched or cancelled again:** Status checks at the top of `executePrivateTrade()` (lines 660-672) and `cancelPrivateOrder()` (lines 842-847). **Verified: Correct.**

---

## Edge Case Analysis

| Scenario | Behavior | Correct? |
|----------|----------|----------|
| Both buy and sell orders fully fill each other | Both transition to FILLED, counters decremented by 2 | Yes |
| Match amount is zero (e.g., encrypted zero amounts) | Zero-fill trade: filled amounts unchanged, both orders transition to PARTIALLY_FILLED. Nuisance (gas waste, events) but not exploitable | Acceptable |
| Self-matching (trader matches own buy and sell) | Allowed -- no check prevents self-matching. MATCHER_ROLE decides which orders to match. The trader has no control over matching (only submission) | Acceptable |
| Order with expiry = 0 | Good-till-cancelled. Expiry checks skip when `expiry == 0`. Correct | Yes |
| Order with expiry in the past | Submission succeeds (no expiry validation at submit time). Matching reverts with `OrderExpired()`. The order wastes a slot until cancelled or cleaned up | See note below |
| User hits MAX_ORDERS_PER_USER = 100 | `TooManyOrders()` revert. User must cancel or wait for fills to free slots | Yes |
| `cleanupUserOrders()` on empty array | Loop does not execute, returns 0 | Yes |
| `cleanupUserOrders(0)` | `processed < 0` is false immediately, returns 0 | Yes |
| Admin calls `confirmOssification()` without prior request | Reverts with `OssificationNotRequested()` | Yes |
| Admin calls `confirmOssification()` before 7 days | Reverts with `OssificationDelayNotElapsed()` | Yes |
| Upgrade attempted after ossification | `_authorizeUpgrade()` reverts with `ContractIsOssified()` | Yes |

**Note on past-expiry submission:** A user can submit an order with an expiry timestamp in the past. The order consumes a slot and increments counters, but can never be matched (expiry check reverts). The user must explicitly cancel to free the slot. Consider adding an expiry validation at submission time:
```solidity
if (expiry != 0 && expiry <= block.timestamp) revert OrderExpired();
```
This is not a security vulnerability (the order simply cannot be matched), but it is a minor UX issue and gas waste. Classified as informational and not listed as a separate finding because the impact is limited to the submitting user's own gas and order slots.

---

## Upgrade Safety

1. **UUPS pattern:** `_authorizeUpgrade()` requires `DEFAULT_ADMIN_ROLE` and checks `_ossified` flag. Correct.
2. **Initializer protection:** Constructor calls `_disableInitializers()`. `initialize()` uses `external initializer` modifier. Correct.
3. **Storage gap:** `uint256[44] private __gap` with accurate documentation. Gap = 50 - 6 named sequential variables = 44. **Verified: Correct.**
4. **Storage layout:** All mappings (4) use hashed slots and do not interfere with sequential layout. The 6 sequential variables are: `orderIds` (1 slot for length), `totalOrders` (1), `totalTrades` (1), `_ossified` (1), `totalActiveOrders` (1), `ossificationRequestTime` (1). **Verified: Correct.**
5. **Immutable forwarder:** `trustedForwarder_` is stored in implementation bytecode, not proxy storage. Safe for proxies. Rotation requires implementation upgrade.
6. **Inherited initializers:** All parent contracts initialized: `__AccessControl_init()`, `__Pausable_init()`, `__ReentrancyGuard_init()`, `__UUPSUpgradeable_init()`. No `__ERC2771Context_init()` needed (uses constructor-based immutable). **Verified: Correct.**

---

## Conclusion

The PrivateDEX contract has undergone four rounds of security audit (Round 1, 3, 6, 7) and all Critical and High severity findings from prior rounds have been remediated. The only High-severity item remaining is the architectural uint64 precision limitation, which is a fundamental constraint of the COTI V2 MPC garbled circuits architecture and is extensively documented.

The new `cleanupUserOrders()` function is correctly implemented and addresses the Round 6 M-02 per-user storage growth concern. The `setMatcherRoleAdmin()` function enables ValidatorProvisioner integration as designed.

**Deployment readiness:** The contract is suitable for mainnet deployment with the following operational requirements:

1. **ADMIN_ROLE** must be assigned to a multi-sig wallet behind a TimelockController.
2. **MATCHER_ROLE** must be assigned to the validator infrastructure (via ValidatorProvisioner after `setMatcherRoleAdmin()` integration).
3. The **uint64 precision limitation** (~18.4M XOM max per order) must be documented in the user-facing UI and API.
4. Production **order book queries** should use event-based off-chain indexing, not `getOrderBook()`.
5. The **ERC-2771 trusted forwarder** address must be the audited OmniForwarder deployment.

**Overall Risk Rating:** Low. The contract demonstrates a mature security posture with comprehensive validation, fail-closed arithmetic, and defense-in-depth patterns.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Round 7 Pre-Mainnet Final Security Audit*
*Methodology: Solhint static analysis, manual line-by-line review, prior audit remediation verification, MPC operation safety analysis, privacy leak assessment, economic invariant verification, edge case analysis, upgrade safety review*
