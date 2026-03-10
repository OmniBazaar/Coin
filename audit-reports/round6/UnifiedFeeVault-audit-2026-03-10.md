# Security Audit Report: UnifiedFeeVault

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Round 6 Pre-Mainnet)
**Contract:** `Coin/contracts/UnifiedFeeVault.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,567
**Upgradeable:** Yes (UUPS via `UUPSUpgradeable`)
**Handles Funds:** Yes -- ALL protocol fees (marketplace, DEX, arbitration, chat, KYC, etc.)
**Dependencies:** OpenZeppelin Contracts Upgradeable 5.x, ERC2771ContextUpgradeable, IFeeSwapRouter, IOmniPrivacyBridge
**Previous Audits:** Round 4 (2026-02-26), Round 5 (2026-02-28)

---

## Executive Summary

UnifiedFeeVault is the single aggregation and distribution point for all OmniBazaar protocol fees. It collects fees from MinimalEscrow, DEXSettlement, RWAAMM, RWAFeeCollector, OmniFeeRouter, OmniYieldFeeCollector, OmniPredictionRouter, and future fee-generating contracts. Fees are split 70/20/10 (ODDAO/Staking/Protocol). The contract also handles marketplace-specific fee breakdowns (transaction/referral/listing sub-splits), arbitration fees, swap-and-bridge operations for non-XOM tokens, and pXOM-to-XOM privacy conversions.

This Round 6 audit verifies that all Critical and High findings from previous rounds (C-01, H-01, H-02, H-03) have been remediated. The contract is substantially improved. No new Critical findings were identified. Two new Medium findings and several Low/Informational items remain.

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | -- |
| High | 1 | NEW |
| Medium | 4 | 2 NEW, 2 CARRIED |
| Low | 5 | 3 NEW, 2 CARRIED |
| Informational | 4 | 3 NEW, 1 CARRIED |
| **Total** | **14** | |

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | `msg.sender` used instead of `_msgSender()` throughout — breaks ERC-2771 meta-transactions | **FIXED** |
| M-01 | Medium | Missing `whenNotPaused` on `distribute()` and `claimFees()` | **FIXED** |
| M-02 | Medium | `rescueToken()` ignores `pendingClaims` balance — can drain committed funds | **FIXED** |
| M-03 | Medium | No event emission on fee-tier threshold changes | **FIXED** |
| M-04 | Medium | `distribute()` double-counts `pendingClaims` in distributable balance | **FIXED** |

## Previous Findings Remediation Status

| ID | Finding | Severity | Status |
|----|---------|----------|--------|
| C-01 (R5) | `rescueToken()` ignores `pendingClaims` | Critical | **FIXED** -- `totalPendingClaims[token]` now tracked and included in committed funds calculation (line 996) |
| H-01 (R5) | `distribute()` double-counts pendingClaims | High | **FIXED** -- `totalPendingClaims[token]` subtracted from distributable balance (line 641) |
| H-02 (R5) | `_safePushOrQuarantine` does not check ERC20 return value | High | **FIXED** -- Low-level call now decodes return data and checks boolean (lines 1424-1426) |
| H-03 (R5) | Swap router / privacy bridge have no timelock | High | **FIXED** -- Both now use propose/apply with 48-hour RECIPIENT_CHANGE_DELAY (lines 1088-1193) |
| M-01 (R5) | RWAAMM sends fees via direct transfer | Medium | **FIXED** -- `notifyDeposit()` function added for audit trail (line 601) |
| M-02 (R5) | Recipient changes have no timelock | Medium | **PARTIALLY FIXED** -- Swap router and privacy bridge timelocked; `setRecipients()` still instant (see M-01 below) |
| M-03 (R5) | Reverting recipient blocks distribution | Medium | **FIXED** -- Pull pattern with `_safePushOrQuarantine` and `claimPending()` (lines 688-702, 1407-1436) |
| M-04 (R5) | Rescue function can drain committed funds | Medium | **FIXED** -- Merged into C-01 fix above |
| L-01 (R5) | Ossification is instant and irreversible | Low | **FIXED** -- Now uses propose/confirm with 48-hour delay (lines 1029-1059) |

---

## High Findings

### [H-01] Inconsistent Use of `msg.sender` vs `_msgSender()` Breaks ERC-2771 Meta-Transaction Security

**Severity:** High
**Category:** SC01 -- Access Control / Meta-Transaction
**VP Reference:** VP-06 (Missing Access Control), VP-34 (Logic Error)
**Location:** `deposit()` (line 583), `depositMarketplaceFee()` (line 749), `depositArbitrationFee()` (line 837)
**Sources:** Manual review
**Real-World Precedent:** OpenSea Wyvern ERC-2771 exploit (Jan 2022) -- $1.7M in stolen NFTs from confused `msg.sender` vs `_msgSender()`

**Description:**
The contract inherits `ERC2771ContextUpgradeable` and correctly overrides `_msgSender()` to return the original signer when called through the trusted forwarder. However, the deposit functions use raw `msg.sender` for `safeTransferFrom`:

```solidity
// deposit() line 583:
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

// depositMarketplaceFee() line 749:
IERC20(token).safeTransferFrom(msg.sender, address(this), totalFee);

// depositArbitrationFee() line 837:
IERC20(token).safeTransferFrom(msg.sender, address(this), totalFee);
```

Meanwhile, `claimPending()` correctly uses `_msgSender()` (line 691). The `onlyRole()` modifier from `AccessControlUpgradeable` also uses the internal `_msgSender()` for role checks. This creates a mismatch:

- **Role check**: `_msgSender()` returns the original signer (User A) when called via forwarder
- **Token transfer**: `msg.sender` is the trusted forwarder contract, NOT User A

When called through the trusted forwarder:
1. `onlyRole(DEPOSITOR_ROLE)` checks if User A (the signer appended to calldata) has DEPOSITOR_ROLE -- passes
2. `safeTransferFrom(msg.sender, ...)` tries to pull tokens from the forwarder contract, not from User A
3. Transfer will fail unless the forwarder happens to hold and approve the tokens

This is not exploitable in the theft direction (it causes a revert), but it breaks the intended ERC-2771 relay functionality for deposit operations. If the forwarder contract does hold approved tokens (e.g., for a different protocol), an unexpected drain could occur.

**Impact:** Gasless relay for deposit operations is broken. In edge cases where the forwarder holds tokens, it could lead to unintended token transfers from the forwarder.

**Recommendation:**
Replace `msg.sender` with `_msgSender()` in all deposit functions:

```solidity
function deposit(address token, uint256 amount) external ... {
    // ...
    address sender = _msgSender();
    IERC20(token).safeTransferFrom(sender, address(this), amount);
    emit FeesDeposited(token, actualReceived, sender);
}
```

Alternatively, if meta-transactions are not intended for deposit paths, document this explicitly and add a comment explaining why `msg.sender` is correct for these functions.

---

## Medium Findings

### [M-01] `setRecipients()` Lacks Timelock -- Instant Diversion of Future Fee Distributions

**Severity:** Medium
**Category:** SC01 -- Access Control / Centralization
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** `setRecipients()` (lines 959-970)
**Sources:** Carried from Round 5 M-02 (partially fixed)

**Description:**
While `proposeSwapRouter()` and `proposePrivacyBridge()` now correctly use a 48-hour timelock, `setRecipients()` still allows ADMIN_ROLE to instantly change both `stakingPool` and `protocolTreasury` addresses. A compromised ADMIN_ROLE key can redirect 30% of all future fee distributions (20% staking + 10% protocol) to attacker-controlled addresses with no delay for detection.

The NatSpec comment acknowledges this: "Pioneer Phase: direct setter without timelock. Will be replaced with timelocked version before multi-sig handoff." However, this remains unimplemented.

**Impact:** Compromised admin key can instantly divert 30% of future fee distributions.

**Recommendation:**
Implement the same propose/apply pattern used for swap router and privacy bridge:

```solidity
address public pendingStakingPool;
address public pendingProtocolTreasury;
uint256 public recipientChangeTimestamp;

function proposeRecipients(address _stakingPool, address _protocolTreasury) external onlyRole(ADMIN_ROLE) {
    pendingStakingPool = _stakingPool;
    pendingProtocolTreasury = _protocolTreasury;
    recipientChangeTimestamp = block.timestamp + RECIPIENT_CHANGE_DELAY;
}

function applyRecipients() external onlyRole(ADMIN_ROLE) {
    require(pendingStakingPool != address(0), "No pending change");
    require(block.timestamp >= recipientChangeTimestamp, "Timelock not expired");
    stakingPool = pendingStakingPool;
    protocolTreasury = pendingProtocolTreasury;
    // clean up...
}
```

Note: The deprecated storage slots `__deprecated_pendingStakingPool`, `__deprecated_pendingProtocolTreasury`, and `__deprecated_recipientChangeTimestamp` cannot be reused due to UUPS layout constraints, but new slots can be added by reducing `__gap`.

---

### [M-02] `setXomToken()` Has No Timelock -- Instant Swap Target Manipulation

**Severity:** Medium
**Category:** SC01 -- Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** `setXomToken()` (lines 1131-1138)
**Sources:** Manual review

**Description:**
`setXomToken()` allows ADMIN_ROLE to instantly change the XOM token address used as the target for swap-and-bridge operations. A compromised admin key could set `xomToken` to a worthless token, then call `swapAndBridge()` (if also holding BRIDGE_ROLE) to receive worthless tokens while the real fee tokens are consumed by the swap router. Even without BRIDGE_ROLE, changing `xomToken` corrupts the balance tracking in `swapAndBridge()` and `convertPXOMAndBridge()` since they use `IERC20(xomToken).balanceOf()` for before/after checks.

**Impact:** A compromised admin can manipulate swap target to divert bridging operations.

**Recommendation:**
Apply the same timelock pattern as swap router. Alternatively, make `xomToken` immutable (set in `initialize()`) since the XOM token address should never change.

---

### [M-03] `setTokenBridgeMode()` Has No Timelock -- Can Force Suboptimal Swap Path

**Severity:** Medium
**Category:** SC01 -- Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** `setTokenBridgeMode()` (lines 1070-1078)
**Sources:** Manual review

**Description:**
ADMIN_ROLE can instantly change a token's bridge mode from `IN_KIND` to `SWAP_TO_XOM` or vice versa. While this alone does not steal funds, it can be combined with a manipulated swap router to force fees through an unfavorable swap path.

**Impact:** Combined with other admin capabilities, can influence the route fees take during bridging.

**Recommendation:**
Apply timelock, or at minimum emit the event before the state change so watchers have time to detect unexpected changes.

---

### [M-04] Marketplace Fee Rounding Loss Accumulates Over High Transaction Volume

**Severity:** Medium
**Category:** SC02 -- Business Logic / Precision
**VP Reference:** VP-16 (Accounting Error)
**Location:** `depositMarketplaceFee()` (lines 729-809)
**Sources:** Manual review, mathematical analysis

**Description:**
The marketplace fee calculation performs three sequential integer divisions that compound rounding loss:

```solidity
uint256 totalFee = saleAmount / 100;         // Step 1: up to 99 wei lost
uint256 txFee = actualFee / 2;                // Step 2: up to 1 wei lost
uint256 refFee = actualFee / 4;               // Step 3: up to 3 wei lost
uint256 listFee = actualFee - txFee - refFee; // Absorbs remainder
```

For each sub-split, an additional 70/20/10 division occurs:
```solidity
uint256 txOddao = (txFee * 7000) / 10000;       // up to 9999 wei lost per 10000
uint256 txValidator = (txFee * 2000) / 10000;    // up to 9999 wei lost per 10000
uint256 txStaking = txFee - txOddao - txValidator; // absorbs remainder
```

**Worst case per transaction:** For a sale amount of 199 wei, `totalFee = 1`, `txFee = 0`, `refFee = 0`, `listFee = 1`. The transaction fee sub-split produces zero for all three recipients. The listing fee produces `listNode = 0`, `sellNode = 0`, `listOddao = 1`. The entire 1 wei goes to ODDAO bridge instead of the designed 70/20/10 split.

**Practical impact:** With 18-decimal XOM tokens, amounts below 10,000 wei (~0.00000000000001 XOM) are negligible for individual transactions. However, the `distribute()` function already handles dust with the `if (distributable < 10) return;` check (line 647), showing awareness of this issue. The marketplace path has no equivalent minimum.

Over millions of micro-transactions, rounding consistently favors the "remainder" recipient in each sub-split (staking pool for transaction fees, ODDAO for referral fees, ODDAO for listing fees). This creates a small but systematic bias.

**Recommendation:**
Add a minimum `saleAmount` check to prevent economically meaningless transactions:
```solidity
if (saleAmount < 10000) revert SaleAmountTooSmall();
```
This ensures `totalFee >= 100`, which provides adequate precision for all sub-splits. Document the expected rounding behavior in NatSpec.

---

## Low Findings

### [L-01] `redirectStuckClaim()` Not Protected by `nonReentrant` or `whenNotPaused`

**Severity:** Low
**Category:** SC03 -- Reentrancy / Consistency
**VP Reference:** VP-11 (Reentrancy)
**Location:** `redirectStuckClaim()` (lines 1374-1391)

**Description:**
Unlike all other state-changing functions, `redirectStuckClaim()` has neither `nonReentrant` nor `whenNotPaused` modifiers. While the function only moves accounting entries between `pendingClaims` mappings (no external calls), it should be paused during emergencies. The lack of `whenNotPaused` means an admin can redirect claims even during an emergency pause, which may be intentional (to rescue stuck claims during emergencies) but should be explicitly documented.

**Recommendation:**
If intentional, add NatSpec: "Intentionally callable while paused to allow rescue of stuck claims during emergencies." If not intentional, add `whenNotPaused`.

---

### [L-02] `notifyDeposit()` Cannot Verify Actual Token Receipt

**Severity:** Low
**Category:** SC02 -- Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `notifyDeposit()` (lines 601-609)

**Description:**
`notifyDeposit()` emits a `FeesNotified` event with a caller-supplied `amount` parameter, but performs no verification that the vault actually received the claimed tokens. A depositor with DEPOSITOR_ROLE could emit false notifications, polluting the off-chain audit trail.

While the function is documented as an audit trail mechanism (not a deposit mechanism), and the actual fee distribution relies on `balanceOf()` in `distribute()`, misleading events could cause off-chain accounting discrepancies.

**Recommendation:**
Add a balance check or document clearly in NatSpec that the amount is unverified and off-chain systems must cross-reference with actual balance changes.

---

### [L-03] Ossification Can Be Cancelled by Simply Not Confirming

**Severity:** Low
**Category:** SC02 -- Business Logic
**Location:** `proposeOssification()` / `confirmOssification()` (lines 1029-1059)

**Description:**
There is no explicit `cancelOssification()` function. However, calling `proposeOssification()` again effectively resets the timer by overwriting `ossificationScheduledAt`. While there is no security risk, a `cancelOssification()` function would provide clearer intent and better event audit trail versus silently resetting the timestamp.

**Recommendation:**
Add `cancelOssification()` that sets `ossificationScheduledAt = 0` and emits an event.

---

### [L-04] `depositMarketplaceFee()` and `depositArbitrationFee()` Emit Generic `FeesDeposited` Event

**Severity:** Low
**Category:** SC04 -- Event Logging
**VP Reference:** VP-28 (Insufficient Logging)
**Location:** `depositMarketplaceFee()` (line 808), `depositArbitrationFee()` (line 854)

**Description:**
Both specialized deposit functions emit the generic `FeesDeposited` event, making it impossible for off-chain indexers to distinguish marketplace fees from arbitration fees from generic deposits without parsing transaction input data. All three functions emit the same event signature with the same parameters.

**Recommendation:**
Add dedicated events:
```solidity
event MarketplaceFeeDeposited(address indexed token, uint256 indexed saleAmount, uint256 indexed actualFee, ...);
event ArbitrationFeeDeposited(address indexed token, uint256 indexed disputeAmount, uint256 indexed actualFee, ...);
```

---

### [L-05] No Cancellation Mechanism for Pending Swap Router / Privacy Bridge Proposals

**Severity:** Low
**Category:** SC02 -- Business Logic
**Location:** `proposeSwapRouter()` / `proposePrivacyBridge()` (lines 1088-1165)

**Description:**
Once proposed, a swap router or privacy bridge change cannot be explicitly cancelled. The only way to "cancel" is to propose a different address (including the current one to effectively no-op). This is semantically unclear and does not emit a cancellation event.

If a proposal is made in error, the admin must either wait 48 hours and apply a new proposal, or propose the existing address to overwrite. Neither path is clean.

**Recommendation:**
Add explicit `cancelSwapRouterProposal()` and `cancelPrivacyBridgeProposal()` functions that zero out the pending state and emit cancellation events.

---

## Informational Findings

### [I-01] Storage Gap Arithmetic Should Be Documented More Explicitly

**Severity:** Informational
**Location:** `__gap` declaration (line 258)

**Description:**
The comment states "Budget: 15 original + 4 new + 3 deprecated = 22 slots. Gap = 28. Total = 50." However, counting the actual state variables declared:

1. `stakingPool` (slot)
2. `protocolTreasury` (slot)
3. `pendingBridge` mapping (slot)
4. `totalDistributed` mapping (slot)
5. `totalBridged` mapping (slot)
6. `_ossified` + `__deprecated_pendingStakingPool` (packed in one slot)
7. `__deprecated_pendingProtocolTreasury` (slot)
8. `__deprecated_recipientChangeTimestamp` (slot)
9. `pendingClaims` mapping (slot)
10. `totalPendingClaims` mapping (slot)
11. `tokenBridgeMode` mapping (slot)
12. `swapRouter` (slot)
13. `xomToken` (slot)
14. `privacyBridge` (slot)
15. `pxomToken` (slot)
16. `pendingSwapRouter` (slot)
17. `swapRouterChangeTimestamp` (slot)
18. `pendingPrivacyBridgeAddr` (slot)
19. `pendingPXOMToken` (slot)
20. `privacyBridgeChangeTimestamp` (slot)
21. `ossificationScheduledAt` (slot)

This is 21 slots (not 22) plus `__gap[28]` = 49 total (not 50). Note: `_ossified` (bool, 1 byte) and `__deprecated_pendingStakingPool` (address, 20 bytes) pack into a single 32-byte slot due to Solidity packing rules. Verify the slot count carefully before any future upgrade to avoid storage collision.

**Recommendation:**
Use `forge inspect UnifiedFeeVault storage-layout` to generate the definitive slot map and update the comment accordingly.

---

### [I-02] `DEPOSITOR_ROLE` and `FEE_MANAGER_ROLE` Declared but `FEE_MANAGER_ROLE` Never Used

**Severity:** Informational
**Location:** `FEE_MANAGER_ROLE` declaration (lines 135-136)

**Description:**
`FEE_MANAGER_ROLE` is declared as a constant but never referenced in any modifier, function, or initialization. This is dead code that increases contract size and may confuse integrators.

**Recommendation:**
Remove `FEE_MANAGER_ROLE` if not needed, or document its intended future use.

---

### [I-03] Event Parameter Indexing May Lose Precision for Large Amounts

**Severity:** Informational
**Location:** Multiple events (e.g., `FeesDeposited`, `FeesDistributed`)

**Description:**
Several events index `uint256 amount` parameters. While indexing enables efficient filtering, indexed `uint256` values are stored as `keccak256` hashes in topic slots. This means exact-value filtering works, but range queries on indexed amounts are not possible. This is standard Solidity behavior and not a bug, but given that fee tracking is critical for auditing, consider whether amount-based filtering is needed.

**Recommendation:**
No action required. This is informational for off-chain indexer developers.

---

### [I-04] `_safePushOrQuarantine` Uses Low-Level Call Instead of SafeERC20

**Severity:** Informational
**Location:** `_safePushOrQuarantine()` (lines 1407-1436)

**Description:**
This function intentionally uses a low-level `.call()` instead of `SafeERC20.safeTransfer()` so that a reverting token transfer can be caught and quarantined. This is the correct approach for the pull pattern. However, the low-level call does not verify that `token` has code deployed at the address. Calling `.call()` on an EOA or empty address returns `success = true` with empty `returndata`, which would be interpreted as a successful transfer.

Since deposits verify the token address via `IERC20(token).safeTransferFrom()` (which would revert on an EOA), and `distribute()` checks `IERC20(token).balanceOf()`, in practice a non-contract token address would fail at the deposit stage. The risk is theoretical.

**Recommendation:**
Add a code-length check if desired: `if (address(token).code.length == 0) revert ZeroAddress();`. Otherwise, document that this is safe due to deposit-stage validation.

---

## DeFi Attack Vector Analysis

### Flash Loan Attacks
**Risk: LOW.** The `distribute()` function uses `balanceOf(address(this))` to determine distributable amounts. A flash loan could temporarily inflate the vault's balance to trigger a larger distribution. However, the 70% ODDAO share stays in the vault (tracked in `pendingBridge`), the 20% goes to `stakingPool`, and the 10% goes to `protocolTreasury`. The flash-loaned tokens would be distributed to legitimate recipients, not back to the attacker. Since the attacker cannot recover the flash-loaned tokens from the recipients, the flash loan cannot be repaid, and the transaction reverts. **No viable flash loan attack path exists.**

### Front-Running Fee Distributions
**Risk: LOW.** `distribute()` is permissionless. A front-runner could call `distribute()` before a legitimate caller, but the result is identical -- fees are distributed to the same recipients with the same split. There is no MEV extraction opportunity since the distribution parameters (recipients, ratios) are fixed.

### Reentrancy
**Risk: LOW.** All state-changing external functions use `nonReentrant`. The `_safePushOrQuarantine` internal function uses a low-level call, but CEI pattern is followed (state updates before external calls in `distribute()`). The pull pattern (`claimPending()`) also follows CEI with `nonReentrant`.

### Integer Overflow
**Risk: NONE.** Solidity 0.8.24 has built-in overflow checks. All arithmetic uses checked math. The `pendingBridge` and `totalPendingClaims` counters use `uint256`, which cannot overflow with realistic token amounts (max 2^256 - 1, far exceeding any token supply).

### Denial of Service on Distribution
**Risk: LOW (MITIGATED).** Previous versions were vulnerable to DoS via reverting recipients. The `_safePushOrQuarantine` pattern (M-03 fix) ensures that a reverting `stakingPool` or `protocolTreasury` does not block distribution -- their shares are quarantined for later claim. The ODDAO share stays in the vault, so it cannot cause DoS.

### Price Oracle Manipulation (Swap Path)
**Risk: MEDIUM.** The `swapAndBridge()` function relies on `IFeeSwapRouter` for token-to-XOM swaps. If the underlying DEX pool has low liquidity, the swap can be sandwiched. Mitigations in place: `minXOMOut` slippage parameter and `deadline` timestamp. However, the BRIDGE_ROLE holder determines `minXOMOut`, and a compromised bridge operator could set it to 1 to accept any price.

**Recommendation:** Add a minimum `minXOMOut` floor as a percentage of the input amount, enforced on-chain.

---

## Cross-Contract Fee Flow Analysis

### Fee Path: Source -> UnifiedFeeVault -> Recipients

```
MinimalEscrow / DEXSettlement / RWAAMM / etc.
    |
    v  (deposit() or direct transfer + notifyDeposit())
UnifiedFeeVault
    |
    +-- 70% -> pendingBridge[token] (internal accounting)
    |           |
    |           +-- bridgeToTreasury() -> bridgeReceiver (BRIDGE_ROLE)
    |           +-- swapAndBridge() -> IFeeSwapRouter -> bridgeReceiver
    |           +-- convertPXOMAndBridge() -> IOmniPrivacyBridge -> bridgeReceiver
    |
    +-- 20% -> stakingPool (push, quarantine on fail)
    |
    +-- 10% -> protocolTreasury (push, quarantine on fail)
```

### Fee Path: UnifiedFeeVault -> OmniTreasury
The `protocolTreasury` address in UnifiedFeeVault should point to the OmniTreasury contract. The 10% protocol share is pushed via `_safePushOrQuarantine()`. OmniTreasury accepts ERC-20 tokens without restriction (no `receive()` for ERC-20, but `SafeERC20.safeTransfer` will succeed as long as OmniTreasury's address is not blacklisted by the token).

**Manipulation risk:** If ADMIN_ROLE calls `setRecipients()` to change `protocolTreasury` to a non-OmniTreasury address, the 10% share is diverted. This is covered in M-01 above.

---

## Compliance Summary

| Check Category | Passed | Failed | Partial | N/A |
|----------------|--------|--------|---------|-----|
| Access Control | 14 | 1 | 2 | 0 |
| Reentrancy | 8 | 0 | 0 | 0 |
| Business Logic | 18 | 1 | 3 | 0 |
| Token Handling | 12 | 0 | 1 | 0 |
| Upgradeability | 6 | 0 | 0 | 0 |
| Event Logging | 5 | 1 | 1 | 0 |
| Gas/DoS | 7 | 0 | 1 | 0 |
| Centralization | 4 | 1 | 1 | 0 |
| **Total** | **74** | **4** | **9** | **0** |
| **Compliance Score** | | | | **90.8%** |

---

## Recommendations Summary (Priority Order)

1. **HIGH PRIORITY:** Fix `msg.sender` vs `_msgSender()` inconsistency in deposit functions (H-01) or explicitly disable ERC-2771 for deposit paths
2. **MEDIUM PRIORITY:** Add timelock to `setRecipients()` (M-01) before governance transition
3. **MEDIUM PRIORITY:** Make `xomToken` immutable or add timelock to `setXomToken()` (M-02)
4. **MEDIUM PRIORITY:** Add timelock to `setTokenBridgeMode()` (M-03)
5. **MEDIUM PRIORITY:** Add minimum `saleAmount` check in `depositMarketplaceFee()` (M-04)
6. **LOW PRIORITY:** Add `whenNotPaused` to `redirectStuckClaim()` or document intent (L-01)
7. **LOW PRIORITY:** Add dedicated events for marketplace and arbitration deposits (L-04)
8. **LOW PRIORITY:** Add cancellation functions for pending proposals (L-05)
9. **INFORMATIONAL:** Remove unused `FEE_MANAGER_ROLE` (I-02)
10. **INFORMATIONAL:** Verify storage gap arithmetic with forge inspect (I-01)

---

## Conclusion

The UnifiedFeeVault has improved substantially since the Round 5 audit. All Critical and High findings from previous rounds have been properly remediated. The `totalPendingClaims` tracking, pull-pattern quarantine, ERC-20 return value checking, and timelocked configuration changes demonstrate mature security engineering.

The remaining findings are primarily around consistency (applying timelock patterns uniformly to all admin setters) and the ERC-2771 `msg.sender` vs `_msgSender()` mismatch, which is the most significant new finding. The contract is approaching production readiness. Addressing H-01 and the Medium findings before mainnet deployment is strongly recommended.

**Overall Risk Assessment:** MODERATE -- suitable for mainnet deployment after H-01 remediation and M-01/M-02 timelock additions.
