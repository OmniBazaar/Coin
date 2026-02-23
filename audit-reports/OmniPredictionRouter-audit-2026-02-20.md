# Security Audit Report: OmniPredictionRouter

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/predictions/OmniPredictionRouter.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 260
**Upgradeable:** No
**Handles Funds:** Yes (routes collateral tokens through fee collection to prediction market platforms)
**Deployed At:** Polygon (Polymarket) and Gnosis (Omen)

## Executive Summary

OmniPredictionRouter is a trustless fee-collecting router for prediction market trades. It pulls collateral from users, deducts a capped fee, and forwards the net amount to a user-specified platform contract via a low-level `.call()`. The audit found **1 critical vulnerability**: an arbitrary external call pattern with no platform target validation, matching the exact exploit class that caused $40M+ in real-world DeFi losses across Transit Swap, LI.FI, Dexible, and Socket/Bungee. Additionally, **3 high-severity issues** were identified: ERC-1155 incompatibility with Polymarket/Omen outcome tokens, missing outcome token sweep in `buyWithFee()`, and absent slippage/deadline protection.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 4 |
| Low | 4 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 68 |
| Passed | 58 |
| Failed | 5 |
| Partial | 5 |
| **Compliance Score** | **85.3%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Basics-Function-6** (FAIL): Arbitrary user input — `platformTarget` and `platformData` allow unrestricted external calls
2. **SOL-EC-5** (FAIL): No platform target whitelisting — any contract address can be called
3. **SOL-EC-12** (FAIL): No contract existence verification — calls to non-existent addresses succeed silently
4. **SOL-AM-SandwichAttack-1** (PARTIAL): Only `buyWithFeeAndSweep()` has slippage protection; `buyWithFee()` has none
5. **SOL-Defi-AS-2** (PARTIAL): Neither function includes a deadline parameter

---

## Critical Findings

### [C-01] Arbitrary External Call — No platformTarget Validation

**Severity:** Critical
**Category:** SC01 Access Control / SC02 Business Logic
**VP Reference:** VP-06 (Missing Access Control), VP-34 (Front-Running)
**Location:** `buyWithFee()` (lines 128-174), `buyWithFeeAndSweep()` (lines 190-245)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-Function-6, SOL-EC-5, SOL-EC-12), Solodit

**Description:**

Both `buyWithFee()` and `buyWithFeeAndSweep()` accept user-controlled `platformTarget` (any address) and `platformData` (arbitrary calldata), then execute a low-level `.call()` from the router's context. Before the call, the router calls `forceApprove(platformTarget, netAmount)` on the collateral token (line 156/220), setting an ERC-20 approval. There is no validation that `platformTarget` is a legitimate prediction market contract, no whitelist, no check against `collateralToken`, and no contract existence verification.

```solidity
// Lines 156-161: Approve + arbitrary call with NO target validation
IERC20(collateralToken).forceApprove(platformTarget, netAmount);
(bool success, bytes memory returnData) = platformTarget.call(platformData);
```

**Exploit Scenario:**

1. Attacker calls `buyWithFee(USDC, 100e6, 0, USDC_ADDRESS, abi.encodeWithSelector(IERC20.approve.selector, attackerAddr, type(uint256).max))`.
2. Router pulls 100 USDC from attacker (fee = 0 is valid).
3. Router calls `USDC.forceApprove(USDC_ADDRESS, 100e6)` — sets approval of USDC to spend from router.
4. Router executes `USDC.call(abi.encodeWithSelector(IERC20.approve.selector, attackerAddr, MAX))` — this grants the attacker unlimited approval to spend the router's USDC.
5. Line 164 resets `USDC.forceApprove(USDC_ADDRESS, 0)` — this resets the router's approval of USDC (itself), NOT the approval granted to the attacker via the `.call()`.
6. The attacker now has permanent unlimited approval. Any future USDC that passes through or is accidentally sent to the router can be drained via `USDC.transferFrom(router, attacker, balance)`.

A simpler variant: set `platformTarget = collateralToken` and `platformData = abi.encodeWithSelector(IERC20.transfer.selector, attacker, netAmount)` to immediately redirect the net amount.

**Real-World Precedent:**

| Protocol | Date | Loss |
|----------|------|------|
| Transit Swap | Oct 2022 | $23M |
| LI.FI (1st hack) | Mar 2022 | $600K |
| LI.FI (2nd hack) | Jul 2024 | $11.6M |
| Dexible | Feb 2023 | $2M |
| Socket/Bungee | Jan 2024 | $3.3M |
| **Total** | | **$40.5M** |

All five exploits used the identical pattern: user-controlled target address + user-controlled calldata + `forceApprove` or prior approval + low-level `.call()`.

**Recommendation:**

Implement a platform whitelist (strongest fix):

```solidity
mapping(address => bool) public approvedPlatforms;

modifier onlyApprovedPlatform(address target) {
    require(approvedPlatforms[target], "unapproved platform");
    _;
}
```

At minimum, add defensive checks:

```solidity
require(platformTarget != collateralToken, "cannot target collateral");
require(platformTarget != address(this), "cannot target self");
require(platformTarget.code.length > 0, "not a contract");
```

---

## High Findings

### [H-01] ERC-1155 Incompatibility with Prediction Market Outcome Tokens

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `buyWithFeeAndSweep()` (lines 231-234)
**Sources:** Agent-B (Critical), Agent-C, Solodit

**Description:**

Polymarket's Conditional Token Framework (CTF) and Omen's ConditionalTokens both implement ERC-1155, not ERC-20. The `buyWithFeeAndSweep()` function uses ERC-20 interfaces to sweep outcome tokens:

```solidity
// Lines 231-234: ERC-20 calls on ERC-1155 tokens
uint256 outcomeBalance = IERC20(outcomeToken).balanceOf(address(this));
if (outcomeBalance < minOutcome) revert InsufficientOutcomeTokens();
if (outcomeBalance > 0) {
    IERC20(outcomeToken).safeTransfer(msg.sender, outcomeBalance);
}
```

ERC-1155 tokens use `balanceOf(address, uint256 tokenId)` (two parameters), not `balanceOf(address)` (one parameter). The function selector mismatch would cause the call to revert or return incorrect data. Outcome tokens from legitimate prediction market trades would be permanently stuck in the router.

**Recommendation:**

Add ERC-1155 support alongside ERC-20:

```solidity
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

// In buyWithFeeAndSweep, add outcomeTokenId parameter for ERC-1155:
function buyWithFeeAndSweepERC1155(
    // ... existing params ...
    uint256 outcomeTokenId
) external nonReentrant {
    // ... trade logic ...
    uint256 outcomeBalance = IERC1155(outcomeToken).balanceOf(address(this), outcomeTokenId);
    if (outcomeBalance < minOutcome) revert InsufficientOutcomeTokens();
    IERC1155(outcomeToken).safeTransferFrom(address(this), msg.sender, outcomeTokenId, outcomeBalance, "");
}
```

The contract must also implement `onERC1155Received` to accept ERC-1155 transfers.

---

### [H-02] buyWithFee() Missing Outcome Token Sweep

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `buyWithFee()` (lines 128-174)
**Sources:** Agent-A (Medium), Agent-C (High), Solodit (High)

**Description:**

The NatSpec for `buyWithFee()` states at line 120: "6. Sweep any outcome tokens back to caller." However, the function does NOT sweep outcome tokens — it only executes the platform call and emits an event. If the platform contract sends outcome tokens to the router (as Polymarket's CTF Exchange does when the `recipient` in `platformData` is the router address), those tokens become trapped.

While `buyWithFeeAndSweep()` exists for this purpose, the `buyWithFee()` NatSpec is misleading. Users or integrators relying on the documented behavior would lose their outcome tokens. The trapped tokens could then be extracted by anyone via the C-01 arbitrary call vulnerability or by `feeCollector` via `rescueTokens()`.

**Recommendation:**

Either:
1. Remove the sweep claim from `buyWithFee()` NatSpec (lines 120-121), or
2. Add a sweep mechanism to `buyWithFee()`, or
3. Add a warning that outcome tokens must be sent directly to `msg.sender` via `platformData` encoding

---

### [H-03] Missing Slippage and Deadline Protection

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-55 (Missing Slippage/Deadline)
**Location:** `buyWithFee()` (lines 128-174), `buyWithFeeAndSweep()` (lines 190-245)
**Sources:** Agent-D, Checklist (SOL-AM-SandwichAttack-1, SOL-Defi-AS-2), Solodit

**Description:**

`buyWithFee()` has **no slippage protection and no deadline**. The trade executes at whatever price the platform offers, with no minimum output guarantee. A sandwich attacker can front-run the user's trade on the underlying platform to extract MEV.

`buyWithFeeAndSweep()` includes `minOutcome` for slippage protection (line 232) but has **no deadline parameter**. A stale transaction sitting in the mempool could execute minutes or hours later at an unfavorable price that still satisfies the `minOutcome` threshold.

**Real-World Precedent:** Multiple Solodit findings across Adapter Finance (Pashov), DaosLive (Shieldify), Alchemix (CodeHawks), and Zaros (CodeHawks) all flag missing deadline/slippage as Medium-to-Critical severity.

**Recommendation:**

Add a deadline parameter to both functions:

```solidity
function buyWithFee(
    address collateralToken,
    uint256 totalAmount,
    uint256 feeAmount,
    address platformTarget,
    bytes calldata platformData,
    uint256 deadline  // NEW
) external nonReentrant {
    require(block.timestamp <= deadline, "expired");
    // ... existing logic ...
}
```

Consider also adding `minOutcome` to `buyWithFee()`.

---

## Medium Findings

### [M-01] Fee-on-Transfer Token Accounting Mismatch

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-46 (Fee-on-Transfer Token)
**Location:** `buyWithFee()` (line 148), `buyWithFeeAndSweep()` (line 212)
**Sources:** Agent-D (High), Solodit (High), Checklist

**Description:**

The contract assumes `safeTransferFrom(msg.sender, address(this), totalAmount)` results in the router receiving exactly `totalAmount`. For fee-on-transfer tokens (e.g., USDT with fee enabled, PAXG), the received amount is less than `totalAmount`. The subsequent fee transfer and platform approval would attempt to use more tokens than available, causing a revert.

On Polygon and Gnosis (the deployment targets), USDC and WXDAI do not have transfer fees, so this fails safely (reverts). However, the contract accepts arbitrary `collateralToken` addresses.

**Recommendation:**

Either restrict `collateralToken` to a whitelist, or use balance-before/after pattern:

```solidity
uint256 balBefore = IERC20(collateralToken).balanceOf(address(this));
IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), totalAmount);
uint256 actualReceived = IERC20(collateralToken).balanceOf(address(this)) - balBefore;
```

---

### [M-02] Donation Attack on Outcome Token Sweep

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `buyWithFeeAndSweep()` (line 231)
**Sources:** Checklist (SOL-AM-DA-1)

**Description:**

The `buyWithFeeAndSweep()` function reads `IERC20(outcomeToken).balanceOf(address(this))` to determine how many outcome tokens to sweep. If someone pre-donates outcome tokens to the router, the next caller receives those donated tokens plus their trade output. While the attacker loses the donated tokens (making this self-harming), it creates unpredictable behavior and could be used for social engineering.

**Recommendation:**

Use a before/after balance delta pattern:

```solidity
uint256 outcomeBefore = IERC20(outcomeToken).balanceOf(address(this));
// ... execute platform call ...
uint256 outcomeReceived = IERC20(outcomeToken).balanceOf(address(this)) - outcomeBefore;
if (outcomeReceived < minOutcome) revert InsufficientOutcomeTokens();
```

---

### [M-03] Gas Griefing via Unbounded External Call

**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-32 (Gas Griefing), VP-33 (Unbounded Return Data)
**Location:** `buyWithFee()` (line 160), `buyWithFeeAndSweep()` (line 224)
**Sources:** Agent-A (Medium), Agent-D (Medium), Solodit (High)

**Description:**

The low-level `.call()` forwards all remaining gas to `platformTarget` with no gas limit. A malicious `platformTarget` could:
1. Consume nearly all gas, leaving insufficient gas for post-call operations (approval reset on line 164/228, sweep, event emission), potentially leaving the approval non-zero.
2. Return a very large bytes payload, causing excessive memory expansion gas costs for the calling user.

**Recommendation:**

Consider specifying a gas reserve:

```solidity
(bool success, bytes memory returnData) = platformTarget.call{gas: gasleft() - 50000}(platformData);
```

Or cap return data using assembly.

---

### [M-04] No Contract Existence Check on platformTarget

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-22 (Missing Validation)
**Location:** `buyWithFee()` (line 160), `buyWithFeeAndSweep()` (line 224)
**Sources:** Checklist (SOL-EC-12)

**Description:**

The contract checks `platformTarget != address(0)` but does not verify that `platformTarget` has deployed code. A low-level `.call()` to an address without code returns `success = true` with empty return data. This means a call to a non-existent or self-destructed contract would succeed silently — the fee would be collected, and the `netAmount` of collateral would remain stuck in the router. The user loses their fee with no trade executed.

**Recommendation:**

Add a code existence check:

```solidity
require(platformTarget.code.length > 0, "not a contract");
```

---

## Low Findings

### [L-01] Wrong Error Names in Constructor and rescueTokens

**Severity:** Low
**VP Reference:** N/A (Code Quality)
**Location:** Constructor (line 99), `rescueTokens()` (line 254)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-Function-4)

**Description:**

The constructor validates `_feeCollector == address(0)` but reverts with `InvalidCollateralToken()` (line 99). The `rescueTokens()` function checks `msg.sender != feeCollector` but reverts with `InvalidPlatformTarget()` (line 254). Both use semantically incorrect error types.

**Recommendation:**

Add dedicated errors:

```solidity
error InvalidFeeCollector();
error Unauthorized();
```

---

### [L-02] USDC Blacklisting Can Block All Trades

**Severity:** Low
**VP Reference:** VP-30 (DoS via Revert)
**Location:** Lines 152, 216 (`safeTransfer` to feeCollector)
**Sources:** Checklist (SOL-AM-DOSA-3)

**Description:**

USDC has blacklisting functionality. If the `feeCollector` address is blacklisted by Circle, the `safeTransfer` to `feeCollector` would revert, blocking ALL trades through the router. Since `feeCollector` is immutable, a new contract deployment would be required.

**Recommendation:**

Document the trust assumption. Consider a fee escrow pattern where fees accumulate in the router and are claimed separately, so blacklisting the collector doesn't block trades.

---

### [L-03] Missing Zero-Address Check on outcomeToken

**Severity:** Low
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** `buyWithFeeAndSweep()` (line 231)
**Sources:** Agent-A (Medium), Agent-D (Low)

**Description:**

`buyWithFeeAndSweep()` does not validate that `outcomeToken != address(0)`. If called with `address(0)`, the `balanceOf` call would revert with an unclear error message.

**Recommendation:**

Add validation: `if (outcomeToken == address(0)) revert InvalidCollateralToken();` (or a dedicated error).

---

### [L-04] Precision Loss on Fee Cap for Dust Amounts

**Severity:** Low
**VP Reference:** VP-13 (Precision Loss)
**Location:** Lines 142, 206
**Sources:** Agent-A (Low), Agent-D (Low)

**Description:**

For very small `totalAmount` values (e.g., 1 wei), the fee cap calculation `(1 * 200) / 10000 = 0` truncates to zero. This is correct behavior (no fee on dust amounts) and not exploitable, but could cause confusion when `feeAmount > 0` is rejected on tiny trades.

**Recommendation:**

Document this behavior in the NatSpec.

---

## Informational Findings

### [I-01] maxFeeBps Inconsistency with OmniFeeRouter

**Severity:** Informational
**Location:** Constructor (line 100)

OmniPredictionRouter caps `maxFeeBps` at 1000 (10%), while OmniFeeRouter caps at 500 (5%). This inconsistency across the OmniBazaar fee router family may cause confusion for integrators. Consider standardizing the cap.

---

### [I-02] Zero-Fee Trades Allowed

**Severity:** Informational
**Location:** Lines 142-143, 206-207

`feeAmount = 0` passes all validation checks (`0 <= maxAllowed`, `0 <= totalAmount`). This is by design — the off-chain system may set zero fees for promotional or internal trades. Document this behavior.

---

### [I-03] Misleading "Minimal Proxy-Friendly" NatSpec

**Severity:** Informational
**Location:** Line 26

The NatSpec claims "Minimal proxy-friendly (no constructor args in bytecode)" but the contract uses a constructor with two parameters that sets immutable state. This is contradictory — the contract cannot be used as a minimal proxy (EIP-1167) implementation because proxies skip the constructor.

**Recommendation:**

Remove the "Minimal proxy-friendly" claim from the NatSpec.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Transit Swap | Oct 2022 | $23M | **Exact match** — unvalidated external call in swap router, attacker set target to token contract to drain user approvals |
| LI.FI (1st) | Mar 2022 | $600K | **Exact match** — arbitrary address + calldata in swap routing function |
| LI.FI (2nd) | Jul 2024 | $11.6M | **Exact match** — same bug class exploited again via `depositToGasZipERC20()` |
| Dexible | Feb 2023 | $2M | **Exact match** — `selfSwap()` allowed arbitrary router address + calldata, attacker called token `transferFrom` |
| Socket/Bungee | Jan 2024 | $3.3M | **Exact match** — `swapExtraData` with unvalidated `.call()`, attacker crafted `transferFrom` calls |
| BabyDogeCoin | Jun 2023 | $135K | Sandwich attack due to missing slippage protection |

## Solodit Similar Findings

- **Transit Swap (SlowMist, Halborn):** Arbitrary external call with user-controlled target and calldata — rated CRITICAL. Exact same pattern as C-01.
- **LI.FI (multiple auditors):** Same vulnerability exploited twice across 2022 and 2024 — rated CRITICAL. "Same mistake twice."
- **Adapter Finance (Pashov):** Missing slippage protection in swap adapter — rated MEDIUM. Same pattern as H-03.
- **DaosLive (Shieldify):** Missing deadline parameter causing stale execution — rated CRITICAL.
- **Backed Protocol (Code4rena):** Fee-on-transfer token incompatibility — rated MEDIUM. Same as M-01.
- **Sudoswap (Cyfrin):** Excess tokens locked in router due to missing sweep — rated HIGH. Similar to H-02.
- **Index Fun (Sherlock):** ERC-1155 interface violations — rated MEDIUM. Related to H-01.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**0 errors, 5 warnings:**
- 2x `ordering`: Import and function ordering suggestions
- 1x `immutable-vars-naming`: `feeCollector` should be `FEECOLLECTOR` (immutable naming convention)
- 2x `code-complexity`: `buyWithFee()` and `buyWithFeeAndSweep()` cyclomatic complexity warnings

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Any address | `buyWithFee()`, `buyWithFeeAndSweep()` | 9/10 (arbitrary external calls) |
| feeCollector (immutable) | `rescueTokens()` | 3/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The `feeCollector` can only call `rescueTokens()` to sweep tokens accidentally sent to the contract. Since all state is immutable and there are no admin functions to change fee parameters or platform targets, the centralization risk is minimal.

**Centralization Risk Rating:** 3/10

The contract's design is intentionally trustless — the real risk is the **opposite of centralization**: the completely permissionless `platformTarget` parameter gives too much power to external callers, not to the admin.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
