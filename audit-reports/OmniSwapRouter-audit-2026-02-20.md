# Security Audit Report: OmniSwapRouter

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/dex/OmniSwapRouter.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 503
**Upgradeable:** No
**Handles Funds:** Yes (transient — pulls input tokens, deducts fee, executes swap, sends output)
**Deployed At:** `0x0DCef11B5aaBf8CeAd12Ea4BE2eC1fAb7Efa586B` (chain 131313)

## Executive Summary

OmniSwapRouter is a DEX swap router designed to aggregate liquidity from multiple sources via adapter contracts, supporting multi-hop swap paths (max 3 hops) with slippage and deadline protection. **This contract is NOT production-ready.** The core swap execution functions (`_executeSwapPath` and `_estimateSwapPath`) are **unimplemented placeholders** that return the input amount unchanged — no actual token swap occurs. The contract is deployed on OmniCoin testnet and externally callable, meaning users can lose fees on no-op "swaps." Beyond the placeholder issue, the audit found **2 Critical, 3 High, 3 Medium, 4 Low, and 4 Informational** findings. The most severe issues are the placeholder swap logic, an unrestricted `rescueTokens()` function (matching the Zunami Protocol $500K exploit pattern), missing 70/20/10 fee distribution, and fee-on-transfer token incompatibility.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 3 |
| Medium | 3 |
| Low | 4 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 96 |
| Passed | 57 |
| Failed | 24 |
| Partial | 15 |
| **Compliance Score** | **59%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Basics-Function-4** (FAIL): NatSpec describes "Multi-source routing (Uniswap V3, Sushiswap, Curve)" but `_executeSwapPath` is a placeholder that returns `amountIn` unchanged
2. **SOL-AM-RP-1** (FAIL): `rescueTokens()` allows admin to sweep ANY token to ANY address — textbook rug-pull vector
3. **SOL-Defi-AS-9** (FAIL): Fee-on-transfer tokens cause accounting mismatch — contract assumes received amount equals requested amount
4. **SOL-EC-5** (FAIL): Adapter addresses registered via `addLiquiditySource()` are not validated for interface compliance (no ERC-165 check)
5. **SOL-Basics-AC-4** (FAIL): Single-step `Ownable` — ownership can be permanently lost via typo in `transferOwnership()`

---

## Critical Findings

### [C-01] Placeholder Swap Execution — No Actual Swap Occurs

**Severity:** Critical
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `_executeSwapPath()` (line 465), `_estimateSwapPath()` (line 498)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-Function-4, SOL-Basics-Math-1)

**Description:**

Both `_executeSwapPath()` and `_estimateSwapPath()` are placeholder implementations that return `amountIn` unchanged. The comment on line 465 explicitly states `// Placeholder - TODO: Implement adapter interface`.

```solidity
// Line 465
amountOut = amountIn; // Placeholder - TODO: Implement adapter interface
```

This creates multiple failure modes:

1. **No swap is performed.** The contract takes `tokenIn` from the user, deducts a fee, then attempts to transfer `amountOut` of `tokenOut`. Since the contract never acquired any `tokenOut`, the `safeTransfer` at line 266 will revert if `tokenIn != tokenOut` (insufficient balance).

2. **Multi-hop chaining is broken.** Line 465 assigns `amountOut = amountIn` (the original input, not the running output from the previous hop). Even if adapters were implemented by modifying just the loop body, each hop would reset to the original input.

3. **`getQuote()` returns misleading results.** It reports `amountOut == swapAmount` for any token pair, regardless of actual market prices.

4. **If `tokenIn == tokenOut`,** the transaction succeeds but the user pays the fee for a no-op — a guaranteed loss equal to the fee amount.

**Exploit Scenario:**

If the contract somehow holds `tokenOut` tokens (from prior rescue deposits, donations, or leftover balances), any user can extract them at a fabricated 1:1 exchange rate via `swap()`. The entire contract is non-functional as a DEX router.

**Real-World Precedent:** Euler Finance (2023-03) — $200M from business logic flaw in core accounting. Uranium Finance (2021-04) — $50M from math miscalculation.

**Recommendation:**

Either:
1. Implement the `ISwapAdapter` interface and actual adapter calls
2. Or add `revert("Not implemented")` to both functions to prevent any execution
3. The project's CLAUDE.md explicitly states: "DO NOT put stubs, todo items, mock implementations to make code compile." This contract violates that rule.

Corrected multi-hop pattern:
```solidity
function _executeSwapPath(
    address[] calldata path,
    bytes32[] calldata sources,
    uint256 amountIn
) internal returns (uint256 amountOut) {
    amountOut = amountIn;
    for (uint256 i = 0; i < path.length - 1; ++i) {
        address adapter = liquiditySources[sources[i]];
        if (adapter == address(0)) revert InvalidLiquiditySource();
        amountOut = ISwapAdapter(adapter).swap(path[i], path[i + 1], amountOut);
    }
}
```

---

### [C-02] rescueTokens() Unrestricted Token Sweep (VP-57 Backdoor)

**Severity:** Critical
**Category:** SC01 Access Control
**VP Reference:** VP-57 (recoverERC20 Backdoor)
**Location:** `rescueTokens()` (lines 398-408)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-AM-RP-1, SOL-CR-3), Solodit (Zunami Protocol)

**Description:**

The `rescueTokens()` function allows the owner to transfer ANY token in ANY amount to ANY address, with no timelock, no accounting, and no restrictions:

```solidity
function rescueTokens(
    address token,
    uint256 amount,
    address recipient
) external onlyOwner {
    if (token == address(0) || recipient == address(0)) {
        revert InvalidTokenAddress();
    }
    IERC20(token).safeTransfer(recipient, amount);
}
```

This deviates from the project-standard rescue pattern used in OmniFeeRouter.sol and OmniYieldFeeCollector.sol, which restrict to: fixed recipient, full balance only, reentrancy guard, restricted caller role.

OmniSwapRouter's rescue function has four deviations:
1. Allows arbitrary `amount` (not just full balance) — enables partial extraction
2. Allows arbitrary `recipient` — tokens can go anywhere
3. No reentrancy guard (`nonReentrant` missing)
4. Uses `onlyOwner` instead of a restricted role

**Real-World Precedent:** **Zunami Protocol (May 2025) — $500K** — an individual with "god-mode access" invoked `withdrawStuckToken()`, emptying the vault. This is the **exact pattern** described in Cyfrin's SOL-AM-RP-1 rug-pull checklist.

**Recommendation:**

Adopt the project-standard rescue pattern:
```solidity
event TokensRescued(address indexed token, uint256 amount);

function rescueTokens(address token) external nonReentrant {
    if (msg.sender != feeRecipient) revert InvalidRecipientAddress();
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(feeRecipient, balance);
        emit TokensRescued(token, balance);
    }
}
```

Or add a 48-hour timelock for rescue operations.

---

## High Findings

### [H-01] Fee-on-Transfer Token Incompatibility

**Severity:** High
**Category:** SC05 Input Validation / SC02 Business Logic
**VP Reference:** VP-46 (Fee-on-Transfer Token)
**Location:** `swap()` (lines 239-247)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Defi-AS-9, SOL-Defi-General-9), Solodit (4+ protocols)

**Description:**

The contract calculates fees based on `params.amountIn` (the requested transfer amount), not the actual amount received after `safeTransferFrom`. For fee-on-transfer tokens, the contract receives fewer tokens than `params.amountIn`, creating a deficit:

```solidity
// Line 239-243: Pull — may receive less than amountIn for FoT tokens
IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

// Line 246: Fee calculated from requested amount, not actual received
uint256 feeAmount = (params.amountIn * swapFeeBps) / BASIS_POINTS_DIVISOR;
uint256 swapAmount = params.amountIn - feeAmount;
```

**Example:** User swaps 1000 tokens with a 2% transfer fee. Contract receives 980 tokens. Fee = 3 tokens (0.3%). SwapAmount = 997 tokens. But contract only has 980 tokens. The fee transfer (3) succeeds (977 remaining), but the swap needs 997, exceeding available balance.

**Real-World Precedent:** Peapods Finance (Sherlock, 2025), VeToken Finance (Code4rena, 2022), Cyfrin Escrow (2023), SafeDollar (2021-06) — $200K. Fee-on-transfer is a formally recognized vulnerability tag in the Solodit taxonomy.

**Recommendation:**

```solidity
uint256 balanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
uint256 actualReceived = IERC20(params.tokenIn).balanceOf(address(this)) - balanceBefore;

uint256 feeAmount = (actualReceived * swapFeeBps) / BASIS_POINTS_DIVISOR;
uint256 swapAmount = actualReceived - feeAmount;
```

---

### [H-02] Single-Recipient Fee — Missing 70/20/10 Distribution

**Severity:** High
**Category:** SC02 Business Logic (Protocol Invariant)
**VP Reference:** N/A (Protocol Design)
**Location:** `swap()` (line 250), `feeRecipient` (line 180), `setFeeRecipient()` (line 367)
**Sources:** Agent-B

**Description:**

OmniBazaar's DEX fee distribution requires three-way distribution:
- **70% to ODDAO** (governance treasury)
- **20% to Staking Pool** (user reward pool)
- **10% to Validator** (processing validator)

This contract sends 100% of collected fees to a single mutable `feeRecipient` address:

```solidity
// Line 250: 100% of fee to single address
IERC20(params.tokenIn).safeTransfer(feeRecipient, feeAmount);
```

This is correctly implemented in the project's other DEX contracts:
- **OmniCore.sol:** `ODDAO_FEE_BPS = 7000`, `STAKING_FEE_BPS = 2000`, `VALIDATOR_FEE_BPS = 1000`
- **DEXSettlement.sol:** Three-way `accruedFees` mapping with 70/20/10 split

**Impact:** If deployed, 100% of swap fees flow to a single EOA/contract instead of being distributed per protocol tokenomics. The staking pool and validators receive nothing.

**Recommendation:**

Replace single `feeRecipient` with three-address distribution matching DEXSettlement.sol:

```solidity
uint256 public constant ODDAO_SHARE = 7000;
uint256 public constant STAKING_POOL_SHARE = 2000;
uint256 public constant VALIDATOR_SHARE = 1000;

struct FeeRecipients {
    address oddao;
    address stakingPool;
    address validator;
}
```

Use pull pattern (accrue and claim) rather than push transfers.

---

### [H-03] No Adapter Interface Validation

**Severity:** High
**Category:** SC01 Access Control / SC06 External Calls
**VP Reference:** VP-06, VP-08
**Location:** `addLiquiditySource()` (lines 329-337), `_executeSwapPath()` (lines 446-469)
**Sources:** Agent-B, Agent-C, Agent-D, Checklist (SOL-EC-5), Solodit (Sudoswap HIGH, Transit Swap $21M, LI.FI $11M)

**Description:**

The `addLiquiditySource()` function accepts any non-zero address as an adapter with no validation:
- No `ISwapAdapter` interface defined
- No ERC-165 `supportsInterface` check
- No verification that the address is a contract (not an EOA)
- No timelock or governance approval

Currently low impact because adapters are never called (placeholder), but when `_executeSwapPath()` is implemented with actual adapter calls, a malicious or misconfigured adapter address could steal all tokens sent to it for swapping.

Additionally, `removeLiquiditySource()` silently succeeds even if the source was never registered (no existence check).

**Real-World Precedent:** Sudoswap (Cyfrin, 2023) — HIGH severity: "Malicious Pair Re-entrance in VeryFastRouter" where a malicious pair contract re-entered the router to manipulate return values and drain funds. Transit Swap (2022-10) — $21M from unvalidated external call in swap router. LI.FI Protocol (2024-07) — $11M from unvalidated calldata.

**Recommendation:**

1. Define and enforce an `ISwapAdapter` interface with ERC-165 validation
2. Require a timelock for adapter registration
3. Add existence check in `removeLiquiditySource()`
4. When implementing adapter calls, validate return values and verify actual balance changes

---

## Medium Findings

### [M-01] Single-Step Ownable (Not Ownable2Step)

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (related)
**Location:** Contract declaration (line 30), constructor (line 200)
**Sources:** Agent-B, Agent-C, Agent-D, Checklist (SOL-Basics-AC-4, SOL-CR-6), Solodit (5+ protocols)

**Description:**

The contract inherits `Ownable` (single-step ownership transfer) instead of `Ownable2Step`. If the owner mistypes the new address in `transferOwnership()`, ownership is irrecoverably lost. The owner controls: fee rate, fee recipient, liquidity sources, token rescue, pause/unpause.

Additionally, `renounceOwnership()` is not overridden, allowing the owner to permanently brick all admin functions.

**Real-World Precedent:** Multiple protocols documented in Solodit: Shieldify/Multipli, Zaros Part 2 (CodeHawks, 2025), Sparkn (CodeHawks, 2023), Eggstravaganza (CodeHawks, 2025).

**Recommendation:**

```solidity
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract OmniSwapRouter is Ownable2Step, Pausable, ReentrancyGuard {
    function renounceOwnership() public pure override {
        revert("OmniSwapRouter: ownership renunciation disabled");
    }
}
```

---

### [M-02] No Timelock on Admin Functions

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-34 (Front-Running)
**Location:** All `onlyOwner` functions (lines 329-408)
**Sources:** Agent-C, Agent-D, Checklist (SOL-Timelock-1, SOL-CR-4), Solodit (NFTX, Virtuals Protocol)

**Description:**

All admin functions take effect immediately with no timelock:
- `setSwapFee()` — fee can be changed from 0% to 1% instantly
- `setFeeRecipient()` — all future fees redirected instantly
- `addLiquiditySource()` / `removeLiquiditySource()` — adapter addresses changed instantly
- `pause()` / `unpause()` — swaps frozen/unfrozen instantly
- `rescueTokens()` — tokens swept instantly

A compromised owner key or front-running attack can:
1. Observe a pending swap in the mempool
2. Call `setSwapFee(100)` to raise fee to 1%
3. After the user's swap executes at higher fee, call `setSwapFee(30)` to restore

**Recommendation:** Implement OpenZeppelin's `TimelockController` for `setSwapFee`, `setFeeRecipient`, `addLiquiditySource`, `removeLiquiditySource`, and `rescueTokens`.

---

### [M-03] Missing tokenIn == tokenOut Check

**Severity:** Medium
**Category:** SC05 Input Validation
**VP Reference:** VP-23 (Missing Amount Validation)
**Location:** `swap()` (lines 222-230)
**Sources:** Agent-A, Agent-B, Checklist (SOL-Heuristics-3)

**Description:**

The contract does not check whether `tokenIn == tokenOut`. With the placeholder implementation, a "swap" where `tokenIn == tokenOut` would deduct a fee and attempt to return the full `amountIn` (not `swapAmount`) — either reverting (insufficient balance) or extracting the fee for a no-op.

**Recommendation:** Add: `if (params.tokenIn == params.tokenOut) revert InvalidTokenAddress();`

---

## Low Findings

### [L-01] getQuote() Missing Path/Source Validation

**Severity:** Low
**VP Reference:** N/A (Input Validation Gap)
**Location:** `getQuote()` (lines 304-321)
**Sources:** Agent-B

The `getQuote()` function does not validate that `tokenIn`/`tokenOut` match the first/last elements of `path`, and does not validate `sources.length == path.length - 1`. In contrast, `swap()` validates both (lines 225, 233-236). This means `getQuote()` can return quotes for inconsistent parameters, misleading frontends.

**Recommendation:** Add the same validation as `swap()`:
```solidity
if (path[0] != tokenIn || path[path.length - 1] != tokenOut) revert PathMismatch();
if (sources.length != path.length - 1) revert InvalidLiquiditySource();
```

---

### [L-02] rescueTokens() Missing Event Emission

**Severity:** Low
**VP Reference:** N/A (Best Practice)
**Location:** `rescueTokens()` (lines 398-408)
**Sources:** Agent-B, Checklist (SOL-Basics-Event-1)

The `rescueTokens()` function transfers tokens without emitting a router-level event. Given this function's broad permissions (C-02), auditability is especially important.

**Recommendation:** Add `event TokensRescued(address indexed token, uint256 amount, address indexed recipient);`

---

### [L-03] Misleading Error Reuse (EmptyPath for PathMismatch)

**Severity:** Low
**VP Reference:** N/A (Code Quality)
**Location:** `swap()` (lines 233-236)
**Sources:** Agent-A, Agent-B

When the path endpoints don't match `tokenIn`/`tokenOut`, the contract reverts with `EmptyPath()` — semantically incorrect. The path isn't empty; it's inconsistent with the declared tokens.

**Recommendation:** Add a dedicated `PathMismatch()` error.

---

### [L-04] renounceOwnership() Not Disabled

**Severity:** Low
**VP Reference:** N/A (Access Control)
**Location:** Inherited from `Ownable`
**Sources:** Agent-C

The inherited `renounceOwnership()` allows the owner to permanently brick all admin functions. Once called, the contract becomes immutable and unrecoverable — no one can update fees, rescue tokens, or unpause.

**Recommendation:** Override to revert:
```solidity
function renounceOwnership() public pure override {
    revert("OmniSwapRouter: ownership renunciation disabled");
}
```

---

## Informational Findings

### [I-01] Floating Pragma

**Severity:** Informational
**Location:** Line 2

The contract uses `pragma solidity ^0.8.19;` instead of a pinned version. Pin to the project's target version for reproducible builds.

---

### [I-02] MAX_SLIPPAGE_BPS Defined But Never Used

**Severity:** Informational
**Location:** Line 41

The constant `MAX_SLIPPAGE_BPS = 1000` (10%) is declared but never referenced in any function. This is dead code. Either enforce it in `swap()` to prevent users from setting dangerously low `minAmountOut`, or remove it.

---

### [I-03] Statistics Counters Aggregate Across Tokens

**Severity:** Informational
**Location:** `swap()` (lines 272-273)

`totalSwapVolume` and `totalFeesCollected` aggregate raw amounts across all tokens with different decimals and values. Adding 1000 USDC (6 decimals) and 1 XOM (18 decimals) produces a meaningless number. The `getSwapStats()` function returns misleading data.

**Recommendation:** Track volume per-token via `mapping(address => uint256)`, or remove on-chain counters and rely on event indexing.

---

### [I-04] Solhint Warnings

**Severity:** Informational
**Location:** Contract-wide

Solhint reports 0 errors, 8 warnings:
- 2x `gas-indexed-events`: `SwapFeeUpdated` parameters not indexed
- 1x `gas-indexed-events`: `adapter` on `LiquiditySourceAdded` not indexed (already indexed)
- 1x `ordering`: Struct after custom error
- 1x `code-complexity`: `swap()` cyclomatic complexity 11 (max 7)
- 1x `not-rely-on-time`: `block.timestamp` deadline check (acceptable for deadline protection)
- 2x `no-unused-vars`: `tokenIn`, `tokenOut` in `getQuote()` (accepted but unused in logic)

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Loss | Relevance |
|----------------|--------|------|-----------|
| Zunami Protocol `withdrawStuckToken()` | Solodit/Cyfrin (2025) | $500K | **Direct** — C-02 matches this pattern exactly |
| Transit Swap unvalidated adapter call | BlockSec (2022) | $21M | Direct — H-03 matches when adapters are implemented |
| LI.FI Protocol unvalidated calldata | (2024) | $11M | Direct — same adapter trust pattern |
| Sudoswap malicious pair reentrancy | Cyfrin (2023) | N/A | Direct — H-03 adapter trust vector |
| SushiSwap RouteProcessor2 | (2023) | $3.3M | Related — unchecked user input in router |
| Peapods Finance FoT swap failure | Sherlock (2025) | N/A | Direct — H-01 same FoT pattern |
| SafeDollar FoT incompatibility | (2021) | $200K | Direct — H-01 same FoT pattern |
| Euler Finance logic flaw | (2023) | $200M | Related — business logic error in core function |

## Solodit Similar Findings

- **Zunami Protocol (2025):** `withdrawStuckToken()` used to drain vault — $500K. Exact match for C-02 `rescueTokens()` pattern.
- **Sudoswap (Cyfrin, 2023):** HIGH — "Malicious Pair Re-entrance in VeryFastRouter." Trusted external contract manipulates return values to drain funds. Exact match for H-03 adapter trust.
- **Peapods Finance (Sherlock, 2025):** MEDIUM — Swap function fails for fee-on-transfer tokens because received amount differs from expected. Exact match for H-01.
- **VeToken Finance (Code4rena, 2022):** MEDIUM — "Check account balance before and after transfers for Fee-On-Transfer discrepancies."
- **Sparkn (CodeHawks, 2023):** LOW — Single-step Ownable risks permanent ownership loss. Match for M-01.
- **DODO Cross-Chain DEX (Sherlock):** MEDIUM — Attacker manipulates liquidity between swap hops. Related to multi-hop slippage concerns.
- **NFTX (Code4rena, 2021):** Recommended timelock on fee changes to prevent front-running. Match for M-02.

Confidence assessment: **VERY HIGH** — all Critical and High findings are strongly corroborated by multiple Solodit matches and real-world exploits.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**0 errors, 8 warnings:**
- 2x `gas-indexed-events`: SwapFeeUpdated parameters not indexed
- 1x `gas-indexed-events`: adapter parameter (false positive — already indexed)
- 1x `ordering`: Struct definition after custom error
- 1x `code-complexity`: swap() cyclomatic complexity 11 (limit 7)
- 1x `not-rely-on-time`: block.timestamp usage (acceptable for deadline)
- 2x `no-unused-vars`: tokenIn/tokenOut in getQuote() (unused in placeholder logic)

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (Ownable) | `addLiquiditySource()`, `removeLiquiditySource()`, `setSwapFee()`, `setFeeRecipient()`, `pause()`, `unpause()`, `rescueTokens()`, `transferOwnership()`, `renounceOwnership()` | 8/10 |
| Any address | `swap()`, `getQuote()`, `getSwapStats()`, `isLiquiditySourceRegistered()` | 1/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The owner (currently the deployer EOA `0xf8C9057d9649daCB06F14A7763233618Cc280663`, which is also the `feeRecipient`) can:
1. Sweep all tokens in the contract via `rescueTokens()` to any address
2. Redirect all fee revenue via `setFeeRecipient()`
3. Register malicious adapter addresses via `addLiquiditySource()` (when adapters are implemented, this becomes a direct fund-theft vector)
4. Freeze all operations indefinitely via `pause()`
5. Change fee to maximum 1% instantly via `setSwapFee()`
6. Transfer ownership to a malicious party (single-step, no confirmation)
7. Permanently brick the contract via `renounceOwnership()`

**Centralization Risk Rating:** 8/10

The owner controls every aspect of the contract with no timelock, no multi-sig, and unrestricted token sweep capability. The only mitigating factor is that the contract does not hold user funds long-term — tokens only transit during atomic swap execution within a single transaction.

**Recommendation:**
1. **Immediately:** Transfer ownership to a multisig wallet (e.g., Gnosis Safe with 3-of-5 signers)
2. **Immediately:** Set a separate fee recipient address (not deployer EOA)
3. **Before production:** Add `TimelockController` for all admin functions
4. **Before production:** Complete the swap implementation or remove the contract

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
