# Security Audit Report: DEXSettlement

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/dex/DEXSettlement.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 1,079
**Upgradeable:** No (Ownable, not proxy)
**Handles Funds:** Yes (ERC20 token swaps, fee collection)

## Executive Summary

DEXSettlement is a trustless on-chain trade settlement contract using dual EIP-712 signatures, commit-reveal MEV protection, and a pull-based fee distribution system. The audit identified **1 Critical**, **6 High**, **7 Medium**, **5 Low**, and **6 Informational** findings across the core settlement path, intent-based settlement subsystem, fee distribution, and admin controls. The most severe issue is the reversed fee distribution split that contradicts the OmniBazaar protocol specification. The intent-based settlement subsystem (Phase 3) has multiple critical design flaws including missing access control, missing token binding, and phantom collateral locking.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 6 |
| Medium | 7 |
| Low | 5 |
| Informational | 6 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 72 |
| Passed | 55 |
| Failed | 10 |
| Partial | 7 |
| **Compliance Score** | **76%** |

Top 5 failed checks:
1. **SOL-Basics-Function-9 (Critical):** `settleIntent()` callable by anyone with arbitrary solver/tokens
2. **SOL-AM-FrA-4 (High):** Commit-reveal not enforced in settlement path
3. **SOL-AM-ReplayAttack-1 (High):** No order cancellation mechanism; signed orders valid until deadline
4. **SOL-CR-4 (Medium):** Admin can change fee recipients immediately with no timelock
5. **SOL-Basics-Math-1 (Medium):** Fee calculation on output token + misleading transfer comments

---

## Critical Findings

### [C-01] DEX Fee Split Reversed from Protocol Specification

**Severity:** Critical
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** Constants at lines 65-72; `_distributeFees()` (line 834)
**Sources:** Agent-B
**Real-World Precedent:** Regnum Aurum FeeCollector incorrect claim logic (Codehawks)

**Description:**

The contract implements the fee split as:
- 70% -> Liquidity/Staking Pool (`LIQUIDITY_POOL_SHARE = 7000`)
- 20% -> ODDAO (`ODDAO_SHARE = 2000`)
- 10% -> Protocol (`PROTOCOL_SHARE = 1000`)

The OmniBazaar protocol specification mandates DEX trading fees follow:
- **70% -> ODDAO**
- **20% -> Staking Pool**
- **10% -> Validator** (who matched the orders)

The 70% and 20% recipients are swapped. Additionally, the 10% "Protocol" share goes to a static address, but per spec it should go to the `matchingValidator` dynamically. The `matchingValidator` parameter is passed to `_distributeFees()` but only used in event emission -- it receives zero fees.

**Exploit Scenario:**

ODDAO receives 71.4% less revenue than intended (20% instead of 70%). The staking pool is overfunded at 70% instead of 20%. Validators have zero economic incentive to match orders since they receive 0% instead of the intended 10%.

**Recommendation:**

```solidity
uint256 public constant ODDAO_SHARE = 7000;        // 70% -> ODDAO
uint256 public constant STAKING_POOL_SHARE = 2000;  // 20% -> Staking Pool
uint256 public constant VALIDATOR_SHARE = 1000;      // 10% -> Matching Validator
```

In `_distributeFees()`, accrue the 10% share to `matchingValidator` instead of the static `protocol` address.

---

## High Findings

### [H-01] settleIntent() Has No Access Control -- Anyone Can Redirect Trader Funds

**Severity:** High
**Category:** Access Control
**VP Reference:** VP-06
**Location:** `settleIntent()` (line 1010)
**Sources:** Agent-A, Agent-B, Agent-C, Checklist (SOL-Basics-Function-9), Solodit
**Real-World Precedent:** CoW Swap Solver Exploit (Feb 2023) -- $166K loss

**Description:**

The `settleIntent()` function can be called by anyone and accepts arbitrary `solver`, `tokenIn`, and `tokenOut` parameters. The `IntentCollateral` struct only records amounts and the trader address -- not which tokens are being swapped or who the solver is. A malicious caller can:

1. Observe a trader's locked intent with `traderAmount=100` and `solverAmount=1000`
2. Call `settleIntent(intentId, attackerAddress, worthlessToken, traderValuableToken)`
3. If the trader has approved this contract for the specified tokens, the swap executes at the attacker's chosen terms

This is nearly identical to the CoW Swap exploit where a malicious solver redirected settlement funds through insufficient access control.

**Exploit Scenario:**
1. Alice calls `lockIntentCollateral(intentId, 100e18, 1000e18, deadline)` intending to trade USDC for XOM.
2. Attacker calls `settleIntent(intentId, attackerAddr, aliceApprovedToken, cheapToken)`.
3. Alice loses valuable tokens; attacker profits.

**Recommendation:**
- Add `require(msg.sender == collateral.trader || msg.sender == solver)` check
- Store `tokenIn`, `tokenOut`, and `solver` in the `IntentCollateral` struct during `lockIntentCollateral()`
- Require solver signature or pre-commitment before settlement

---

### [H-02] Intent Collateral Struct Does Not Record Token Addresses

**Severity:** High
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `IntentCollateral` struct (line 910); `lockIntentCollateral()` (line 979)
**Sources:** Agent-A, Agent-C

**Description:**

The `IntentCollateral` struct stores `traderAmount` and `solverAmount` but not `tokenIn` or `tokenOut`. The tokens are specified at settlement time via `settleIntent()` parameters, which means the trader has no on-chain guarantee about which tokens will be exchanged. Even if access control is added (H-01), the token binding issue allows the authorized settler to choose different tokens than the trader intended.

**Recommendation:**

Add `tokenIn` and `tokenOut` fields to `IntentCollateral`. Set them in `lockIntentCollateral()` and validate them in `settleIntent()`.

---

### [H-03] lockIntentCollateral() Does Not Actually Escrow Tokens

**Severity:** High
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `lockIntentCollateral()` (line 979)
**Sources:** Agent-A, Agent-B, Agent-C

**Description:**

Despite the name "lockIntentCollateral", this function does NOT transfer any tokens into the contract. It only records amounts in storage. The actual token transfers happen in `settleIntent()` via `safeTransferFrom`. The "collateral" is merely a promise:
- No guarantee the trader will have tokens at settlement time
- The trader can move tokens away after "locking"
- Settlement will simply revert if tokens are unavailable

**Recommendation:**

Either actually escrow tokens by transferring them into the contract during `lockIntentCollateral()` (and return them on cancel), or rename the function to `recordIntentTerms()` to accurately reflect behavior.

---

### [H-04] Fee Collected from Output Token Without Balance/Allowance Verification

**Severity:** High
**Category:** Business Logic
**VP Reference:** VP-15, VP-34
**Location:** `_executeAtomicSettlement()` (lines 806-821); `_checkBalancesAndAllowances()` (lines 750-775)
**Sources:** Agent-A, Agent-B, Checklist (SOL-Basics-Math-1)

**Description:**

Fees are calculated as a percentage of `amountOut`:
```solidity
uint256 makerFee = (makerOrder.amountOut * SPOT_MAKER_FEE) / BASIS_POINTS_DIVISOR;
```

The fee is then collected via `safeTransferFrom(makerOrder.trader, address(this), makerFee)` on `makerOrder.tokenOut` (the token the maker *receives*). However, `_checkBalancesAndAllowances()` only verifies `tokenIn` balances and allowances. The maker must:
1. Already hold extra `tokenOut` tokens, or rely on receiving them first in the settlement
2. Have pre-approved the contract for `tokenOut` spending

Since the maker is *buying* `tokenOut`, they likely haven't pre-approved it. The settlement comments say "minus maker fee" but the code does NOT subtract fees from transfers -- it charges them as additional separate transfers.

**Recommendation:**

Deduct fees from transfer amounts instead of collecting them separately. For example, transfer `amountIn - fee` to the counterparty and `fee` to the contract in a single step, so fees come from tokens the trader is already sending.

---

### [H-05] Fee Recipient Change Orphans Previously Accrued Fees

**Severity:** High
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `updateFeeRecipients()` (line 539)
**Sources:** Agent-A

**Description:**

When the owner calls `updateFeeRecipients()`, the `feeRecipients` struct is overwritten. However, fees already accrued under old addresses in the `accruedFees` mapping remain keyed to those old addresses. If the old address was compromised (the reason for changing it), the compromised address can still call `claimFees()` and drain all previously accrued fees.

**Exploit Scenario:**
1. Fees accrue to `feeRecipients.oddao = 0xOLD` over many trades.
2. `0xOLD` is compromised; owner changes ODDAO to `0xNEW`.
3. Compromised `0xOLD` drains all previously accrued fees.

**Recommendation:**

Either force-claim pending fees to old recipients before updating, or migrate accrued balances to new addresses in `updateFeeRecipients()`.

---

### [H-06] No Order Cancellation Mechanism

**Severity:** High
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `settleTrade()` (lines 467-497)
**Sources:** Checklist (SOL-AM-ReplayAttack-1), Solodit (1inch comparison)

**Description:**

Once a user signs an EIP-712 order, there is no way to cancel it before the deadline expires. The only implicit "cancel" is settling another order to increment the nonce, but:
- The sequential nonce means only ONE order can be active (see M-01)
- There is no explicit `cancelOrder()` or `incrementNonce()` function
- A signed order remains valid and executable until its `deadline` timestamp

Industry standard DEX protocols (1inch, 0x, Uniswap) all provide explicit order cancellation mechanisms. The absence creates risk: a user who signed an order at an unfavorable price cannot revoke it.

**Recommendation:**

Add an explicit nonce increment function:
```solidity
function incrementNonce() external {
    ++nonces[msg.sender];
    emit NonceIncremented(msg.sender, nonces[msg.sender]);
}
```

Or better: switch to a nonce bitmap and add order-specific cancellation via `cancelOrder(bytes32 orderHash)`.

---

## Medium Findings

### [M-01] Sequential Nonce Prevents Concurrent Orders

**Severity:** Medium
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `settleTrade()` (lines 467-468, 496-497)
**Sources:** Agent-A, Agent-B, Agent-C, Solodit (Symmetrical H-7)
**Real-World Precedent:** Symmetrical (Sherlock 2023) -- nonce manipulation blocked liquidations

**Description:**

The contract uses a strictly sequential nonce per trader. Each order's nonce must exactly match the current counter. This means a trader can only have ONE pending order at a time. For a DEX claiming 10,000+ orders/second throughput, this is a severe bottleneck.

**Recommendation:**

Replace with a nonce bitmap pattern (like Uniswap Permit2) or remove the nonce check entirely -- the `filledOrders` mapping already prevents replay since the order hash includes the `salt` for uniqueness.

---

### [M-02] Fee Rounding Dust Permanently Locked in Contract

**Severity:** Medium
**Category:** Arithmetic
**VP Reference:** VP-15
**Location:** `_distributeFees()` (lines 848-863)
**Sources:** Agent-A, Agent-B, Agent-C, Checklist

**Description:**

Fee distribution splits each fee via integer division. The sum of the three shares may be less than the original fee. The difference (dust) remains in the contract with no recovery mechanism. Over millions of trades, this accumulates.

**Recommendation:**

Assign remainder to one recipient: `uint256 lp = makerFee - od - pr;`
Or add an admin `sweepDust()` function.

---

### [M-03] cancelIntent() Missing Deadline Enforcement

**Severity:** Medium
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `cancelIntent()` (line 1058)
**Sources:** Agent-A, Agent-B, Agent-C

**Description:**

NatSpec says "Can be called by trader if deadline passed" but the code has no deadline check. The trader can cancel immediately after locking, griefing solvers who may have already committed resources.

**Recommendation:**

Add: `if (block.timestamp <= collateral.deadline) revert("deadline not passed");`

---

### [M-04] No Timelock on Critical Admin Functions

**Severity:** Medium
**Category:** Centralization
**VP Reference:** VP-06
**Location:** `updateFeeRecipients()` (line 539), `updateTradingLimits()` (line 562)
**Sources:** Agent-C, Checklist (SOL-CR-4, SOL-CR-5)

**Description:**

All admin functions execute immediately with no timelock or multi-sig. `updateFeeRecipients()` is particularly sensitive -- a compromised owner can silently redirect all future fee revenue. No event is emitted for fee recipient changes.

**Recommendation:**

Implement a 48-hour timelock for `updateFeeRecipients()` and `updateTradingLimits()`. Emit events for all admin state changes.

---

### [M-05] matchingValidator Can Be address(0)

**Severity:** Medium
**Category:** Input Validation
**VP Reference:** VP-22
**Location:** `settleTrade()` (lines 447-449)
**Sources:** Agent-B

**Description:**

The contract verifies both orders reference the same `matchingValidator` but doesn't check for `address(0)`. Once the fee split is corrected (C-01) to route 10% to the validator, fees attributed to `address(0)` would be permanently burned.

**Recommendation:**

Add: `if (makerOrder.matchingValidator == address(0)) revert InvalidAddress();`

---

### [M-06] maxSlippageBps Set But Never Used in Settlement Logic

**Severity:** Medium
**Category:** Business Logic (Dead Code)
**VP Reference:** VP-34
**Location:** `maxSlippageBps` (line 332); `updateTradingLimits()` (line 571)
**Sources:** Agent-C, Checklist (SOL-AM-SandwichAttack-1)

**Description:**

The `maxSlippageBps` state variable is initialized, can be updated, and is emitted in events, but is never checked during `settleTrade()` or `settleIntent()`. This creates a false sense of slippage protection. The contract header claims "Slippage protection" as a key security feature.

**Recommendation:**

Either implement actual slippage checking in settlement logic, or remove the dead code and update documentation.

---

### [M-07] Fee-on-Transfer Token Incompatibility

**Severity:** Medium
**Category:** Token Integration
**VP Reference:** VP-46
**Location:** `_executeAtomicSettlement()` (lines 785-822)
**Sources:** Agent-D, Solodit (OpenLeverage, Astaria, Backed)
**Real-World Precedent:** OpenLeverage (Code4rena 2022) -- fee-on-transfer accounting mismatch

**Description:**

The contract uses `safeTransferFrom` without balance-before/after checks. If a fee-on-transfer token is used, the receiver gets fewer tokens than `amountIn`, breaking the atomic swap accounting. The counterparty would be shortchanged.

**Recommendation:**

Either implement balance-before/after checks, or document that fee-on-transfer tokens are not supported and consider adding a token whitelist.

---

## Low Findings

### [L-01] Commit-Reveal MEV Protection Not Enforced

**Severity:** Low
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `commitOrder()` (line 378); `settleTrade()` (line 425)
**Sources:** Agent-A, Agent-B, Checklist (SOL-AM-FrA-4)

**Description:**

The commit-reveal mechanism is entirely optional. `settleTrade()` never checks whether orders were committed or revealed. The contract NatSpec confirms this is "optional" but the contract header prominently claims "Commit-reveal prevents front-running" as a key security feature, which is misleading.

**Recommendation:**

Either enforce commit-reveal in `settleTrade()`, or remove the dead code, or clearly document that MEV protection is not actually provided on-chain.

---

### [L-02] totalFeesCollected Mixes Token Denominations

**Severity:** Low
**Category:** Arithmetic
**VP Reference:** VP-13
**Location:** `_distributeFees()` (line 844)
**Sources:** Agent-A, Agent-C

**Description:**

`totalFeesCollected` sums fees from different tokens regardless of decimals (e.g., USDC 6 decimals + XOM 18 decimals). The resulting number is meaningless for accounting or display purposes.

**Recommendation:**

Track fees per token, or document that `totalFeesCollected` is an approximate indicator only.

---

### [L-03] Daily Volume Limit Exploitable at UTC Midnight Boundary

**Severity:** Low
**Category:** Business Logic
**VP Reference:** VP-35
**Location:** `settleTrade()` (lines 434-437)
**Sources:** Agent-B

**Description:**

The daily volume reset at `block.timestamp / 1 days` creates a boundary at UTC midnight. A trader could use nearly the full daily limit just before midnight and the full limit again immediately after, effectively doubling the intended daily cap.

**Recommendation:**

This is an accepted limitation of daily limit designs. Consider a rolling window if precision is critical.

---

### [L-04] Partial Fill Logic Accepts Asymmetric Amounts But Transfers Full Amount

**Severity:** Low
**Category:** Business Logic
**VP Reference:** VP-34
**Location:** `_verifyOrdersMatch()` (lines 728-730); `_executeAtomicSettlement()` (lines 785-803)
**Sources:** Agent-B

**Description:**

`_verifyOrdersMatch()` allows `takerOrder.amountIn < makerOrder.amountOut`, accepting partial fills. But `_executeAtomicSettlement()` transfers the full `makerOrder.amountIn`, and the order is marked as fully filled. The maker sends more than they receive, losing the difference.

**Recommendation:**

Either enforce exact matching (`==` instead of `<=`) or implement proper partial fill logic that transfers only matched amounts.

---

### [L-05] Single-Step Ownable (Should Be Ownable2Step)

**Severity:** Low
**Category:** Access Control
**VP Reference:** VP-06
**Location:** Contract declaration (line 40)
**Sources:** Checklist (SOL-Basics-AC-4)

**Description:**

The contract uses `Ownable` with single-step ownership transfer. If ownership is transferred to an incorrect address, it is irrecoverably lost.

**Recommendation:**

Use `Ownable2Step` for a two-step transfer process requiring the new owner to accept.

---

## Informational Findings

### [I-01] Floating Pragma

**Location:** Line 2
**Sources:** Agent-A, Solhint

The contract uses `pragma solidity ^0.8.19;`. Pin to a specific version for deterministic compilation.

---

### [I-02] Redundant Pause Mechanisms

**Location:** `emergencyStop` (line 317) and `Pausable` (inherited)
**Sources:** Agent-B, Agent-C

Two independent pause mechanisms serve overlapping purposes. `emergencyStop` is checked manually; `Pausable` uses the `whenNotPaused` modifier. `lockIntentCollateral()` checks `whenNotPaused` but NOT `emergencyStop`, creating inconsistency.

**Recommendation:** Consolidate to a single mechanism (prefer OpenZeppelin's `Pausable`).

---

### [I-03] updateFeeRecipients() Missing Event Emission

**Location:** `updateFeeRecipients()` (line 539)
**Sources:** Agent-B, Agent-C, Checklist (SOL-CR-5)

Critical configuration change with no on-chain log. Add an event for transparency.

---

### [I-04] commitOrder() Uses Wrong Error Type

**Location:** `commitOrder()` (line 379)
**Sources:** Agent-C

`if (orderHash == bytes32(0)) revert InvalidAddress();` -- Should use a semantically correct error like `InvalidOrderHash()`.

---

### [I-05] IntentCollateral Struct Can Be Packed More Efficiently

**Location:** `IntentCollateral` struct (line 910)
**Sources:** Solhint (gas-struct-packing)

Booleans `locked` and `settled` are packed inefficiently with `address` and `uint256` fields. Reorder for optimal 32-byte slot packing.

---

### [I-06] settleTrade() Cyclomatic Complexity Exceeds Threshold

**Location:** `settleTrade()` (line 425)
**Sources:** Solhint (code-complexity)

Cyclomatic complexity of 15 vs recommended maximum of 7. Consider extracting sub-functions for validation steps.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance to DEXSettlement |
|---------|------|------|-----------------------------|
| CoW Swap Solver | Feb 2023 | $166K | Near-identical pattern: settlement contract allows arbitrary caller to redirect funds via insufficient access control on settlement function. Mirrors H-01. |
| Symmetrical (Sherlock) | 2023 | N/A | Sequential nonce manipulation blocked liquidations. Demonstrates weaponization of strict nonce ordering. Mirrors M-01. |
| OpenLeverage | Jan 2022 | N/A | Fee-on-transfer tokens cause accounting mismatch in swap settlement. Mirrors M-07. |
| Astaria | Jan 2023 | N/A | Fee-on-transfer tokens break ERC4626 vault accounting. Related pattern to M-07. |
| Jimbo's Protocol | May 2023 | $7.5M | Insufficient slippage control exploited. Related to M-06 (maxSlippageBps dead code). |

## Solodit Similar Findings

- **CoW Protocol settlement access control** -- Direct precedent for H-01
- **Symmetrical H-7: nonce manipulation** -- Direct precedent for M-01
- **Multiple protocols (OpenLeverage, Astaria, Backed, Juicebox)** -- Fee-on-transfer incompatibility (M-07)
- **1inch Limit Order Protocol** -- Industry standard for bitmap nonces and explicit order cancellation
- **Regnum Aurum FeeCollector** -- Incorrect fee claim logic precedent (C-01)

10 of 12 key findings have direct or pattern-matching precedent in the Solodit/audit ecosystem, providing high confidence in the findings.

## Static Analysis Summary

### Slither
Skipped (full-project analysis exceeds 10-minute timeout). Aderyn v0.6.8 incompatible with solc v0.8.33.

### Solhint
0 errors, 22 warnings:
- 6x `not-rely-on-time` -- Timestamp usage (deadlines, daily volume reset). Necessary for business logic.
- 5x `gas-indexed-events` -- Events could benefit from more indexed parameters.
- 2x `code-complexity` -- `settleTrade()` (15) and `_verifyOrdersMatch()` (9) exceed complexity threshold of 7.
- 2x `gas-small-strings` -- ORDER_TYPEHASH exceeds 32 bytes (inherent to EIP-712).
- 1x `max-line-length` -- Line 50 at 194 chars (ORDER_TYPEHASH keccak string).
- 1x `ordering` -- Struct defined after custom errors.
- 1x `gas-struct-packing` -- IntentCollateral struct packing inefficiency.
- 1x `gas-strict-inequalities` -- Non-strict inequality in deadline check.

### Aderyn
Skipped (v0.6.8 crashes with "Fatal compiler bug" against solc v0.8.33).

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `owner` (Ownable) | `updateFeeRecipients()`, `updateTradingLimits()`, `emergencyStopTrading()`, `resumeTrading()`, `pause()`, `unpause()` | 5/10 |
| Any address | `commitOrder()`, `revealOrder()` (self-restricted), `settleTrade()` (sig-verified), `claimFees()` (self-restricted), `lockIntentCollateral()`, `settleIntent()` (**NO AUTH**), `cancelIntent()` (self-restricted) | Varies |

## Centralization Risk Assessment

**Single-key maximum damage:** The owner can halt all trading indefinitely, redirect all future fee revenue, and manipulate trading limits. The owner CANNOT steal user principal (tokens remain in user wallets until settlement), forge orders, or upgrade/destroy the contract.

**Deployed configuration (testnet):** All fee recipient addresses AND the owner are the same EOA (`0xf8C9057d9649daCB06F14A7763233618Cc280663`). This is acceptable for testnet but must be remediated before mainnet.

**Centralization Risk Rating:** 5/10 (moderate). Elevates to 7/10 with the current testnet single-address deployment.

**Recommendation:** Use a multi-sig wallet (e.g., Gnosis Safe) for ownership. Implement timelocks on `updateFeeRecipients()` and `updateTradingLimits()`. Deploy with distinct addresses for each fee recipient role.

---

## Remediation Priority

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| 1 | C-01: Fee split reversed | Low | Revenue misallocation |
| 2 | H-01: settleIntent no access control | Medium | Fund theft (CoW Swap precedent) |
| 3 | H-02: Missing token binding in intents | Medium | Arbitrary token substitution |
| 4 | H-04: Fee on output token w/o verification | Medium | Settlement failures |
| 5 | H-03: Phantom collateral lock | Medium | False security guarantee |
| 6 | H-05: Fee recipient change orphans fees | Low | Compromised key can drain accrued fees |
| 7 | H-06: No order cancellation | Low | Users cannot revoke signed orders |
| 8 | M-01: Sequential nonce | Medium | 1 order per user at a time |
| 9 | M-05: Validator can be address(0) | Low | Fees burned to zero address |
| 10 | M-06: maxSlippageBps dead code | Low | False sense of slippage protection |
| 11 | M-07: Fee-on-transfer incompatibility | Medium | Incorrect swap amounts |
| 12 | M-02: Fee rounding dust locked | Low | Accumulated dust |
| 13 | M-03: cancelIntent no deadline check | Low | Griefing solvers |
| 14 | M-04: No timelock on admin functions | Medium | Centralization risk |

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 58 vulnerability patterns, 370 Cyfrin checks, 681 DeFiHackLabs incidents, Solodit 50K+ findings*
