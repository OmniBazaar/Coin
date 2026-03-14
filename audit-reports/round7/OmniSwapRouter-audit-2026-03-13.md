# Security Audit Report: OmniSwapRouter (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 -- Pre-Mainnet)
**Contract:** `Coin/contracts/dex/OmniSwapRouter.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 730
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (transient -- pulls input tokens, deducts fee, executes multi-hop swap via adapters, sends output tokens to recipient)
**Mainnet Deployed At:** `0xF644D0B2E7CEfAb5eEE6ffFF3776aBC9017DB424` (chain 88008)
**Previous Audit:** `audit-reports/round6/OmniSwapRouter-audit-2026-03-10.md` (0 Critical, 2 High, 3 Medium, 3 Low, 4 Informational)
**Slither:** Skipped
**Solhint:** 0 errors, 1 warning (function ordering)
**Tests:** 103 passing (all green)

---

## Executive Summary

OmniSwapRouter is a DEX aggregation router that routes token swaps through registered `ISwapAdapter` adapters across multi-hop paths (max 3 hops), collecting a configurable fee (0.30% default, max 1%). Round 7 reviews the post-remediation state following Round 6. The two High findings (H-01 residual approvals, H-02 unverified output balances) have been successfully remediated. Per-hop balance-before/after verification and approval resets are now correctly implemented. The ERC-2771 meta-transaction integration has been added to the source code.

**This Round 7 audit finds 0 Critical, 0 High, 1 Medium, 3 Low, and 3 Informational issues.** The most significant finding is M-01: the source code (3-arg constructor with ERC2771Context) continues to diverge from the mainnet-deployed bytecode (2-arg constructor without ERC2771Context), with no deploy scripts updated and no OmniForwarder listed in deployments/mainnet.json. All three Low findings are carried over from Round 6 (L-01 getQuote path validation, L-02 volume accounting, L-03 error semantics) and remain unfixed.

---

## Round 6 Remediation Verification

All High and Medium findings from Round 6 have been verified as fixed or accepted:

| Round 6 ID | Severity | Finding | Round 7 Status |
|------------|----------|---------|----------------|
| H-01 | High | Residual token approval on adapters | **VERIFIED FIXED** -- `forceApprove(adapter, 0)` at line 580 after each hop |
| H-02 | High | Output token trusts adapter amountOut | **VERIFIED FIXED** -- Balance-before/after at lines 319-328 (final) and 568-585 (per-hop) |
| M-01 | Medium | No timelock on admin functions | **ACCEPTED** (Pioneer Phase) -- Unchanged, carried forward |
| M-02 | Medium | Source diverged from mainnet bytecode | **NOT FIXED** -- See M-01 below. Deploy scripts still use 2 args. |
| M-03 | Medium | Adapter can steal intermediate tokens | **VERIFIED FIXED** -- Approval reset (H-01 fix) + per-hop balance verification (H-02 fix) eliminate this vector |
| L-01 | Low | getQuote() lacks PathMismatch validation | **NOT FIXED** -- Carried forward as L-01 |
| L-02 | Low | totalSwapVolume uses params.amountIn | **NOT FIXED** -- Carried forward as L-02 |
| L-03 | Low | renounceOwnership uses wrong error | **NOT FIXED** -- Carried forward as L-03 |
| I-01 | Info | Trusted forwarder is immutable | **ACCEPTED** -- Inherent to ERC2771Context |
| I-02 | Info | No ERC-165 check on adapter | **ACCEPTED** -- Owner is trusted role |
| I-03 | Info | Statistics aggregate across tokens | **ACCEPTED** -- Informational only |
| I-04 | Info | removeLiquiditySource silent on non-existent | **ACCEPTED** -- Harmless |

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 3 |
| **Total** | **7** |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (`Ownable2Step`) | `addLiquiditySource()`, `removeLiquiditySource()`, `setSwapFee()`, `setFeeVault()`, `pause()`, `unpause()`, `rescueTokens()`, `transferOwnership()` | 7/10 |
| Any address | `swap()`, `getQuote()`, `getSwapStats()`, `isLiquiditySourceRegistered()`, `acceptOwnership()` | 1/10 |
| Trusted Forwarder (ERC-2771) | Can relay any user's call to `swap()` with spoofed `_msgSender()` | 3/10 (not deployed) |

**Ownership chain (mainnet):** Deployer EOA `0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba` is owner. Fee vault is `UnifiedFeeVault` at `0x732d5711f9D97B3AFa3C4c0e4D1011EBF1550b8c`.

**Who can execute swaps:** Any address with pre-approved `tokenIn` allowance. Gated by `nonReentrant` and `whenNotPaused`.

**Who can modify routes:** Only the owner via `addLiquiditySource()` / `removeLiquiditySource()`. Changes take effect immediately (no timelock).

---

## Medium Findings

### [M-01] Source Code Still Diverges From Mainnet Bytecode (Unfixed from Round 6 M-02)

**Severity:** Medium
**Category:** Deployment Integrity
**Location:** Constructor (lines 263-276), ERC2771Context overrides (lines 692-729)
**Status:** NOT FIXED (carried from Round 6 M-02)

**Description:**

The current source code defines a 3-argument constructor:

```solidity
constructor(
    address _feeVault,
    uint256 _swapFeeBps,
    address trustedForwarder_   // <-- third argument
)
    Ownable(msg.sender)
    ERC2771Context(trustedForwarder_)
```

However, the mainnet-deployed contract at `0xF644D0B2E7CEfAb5eEE6ffFF3776aBC9017DB424` was deployed from `scripts/deploy-treasury-mainnet.js` (line 89) with only 2 arguments:

```javascript
const swapRouter = await SwapRouter.deploy(UNIFIED_FEE_VAULT, 30);
```

All three deploy scripts that reference OmniSwapRouter (`deploy-swap-router-mainnet.js`, `deploy-treasury-mainnet.js`, `deploy-omni-swap-router.ts`) pass only 2 constructor arguments. None have been updated for the 3-argument signature.

Additionally, `OmniForwarder` is not listed in `deployments/mainnet.json`, confirming the ERC-2771 infrastructure has never been deployed on mainnet.

**Impact:**

1. The current source code will NOT compile against the ABI of the deployed contract.
2. Any attempt to verify the source on explorers will fail.
3. Developers integrating with the mainnet contract will encounter ABI mismatches.
4. The Round 6 audit marked this as "FIXED" but it is demonstrably not fixed -- the deployment artifact and source still diverge.

**Evidence:**

- `scripts/deploy-treasury-mainnet.js` line 89: `SwapRouter.deploy(UNIFIED_FEE_VAULT, 30)` (2 args)
- `scripts/deploy-swap-router-mainnet.js` line 38-41: `OmniSwapRouter.deploy(ODDAO_TREASURY, SWAP_FEE_BPS)` (2 args)
- `scripts/deploy-omni-swap-router.ts` lines 83-86: `OmniSwapRouter.deploy(feeRecipient, swapFeeBps)` (2 args)
- `deployments/mainnet.json`: No `OmniForwarder` entry exists

**Recommendation:**

1. Update all deploy scripts to pass 3 constructor arguments (use `ethers.ZeroAddress` for the forwarder if not deploying one).
2. When redeploying, deploy `OmniForwarder` first and pass its address.
3. Add `OmniForwarder` to `deployments/mainnet.json`.
4. Consider maintaining a versioned source archive matching each deployed bytecode for auditability.

---

## Low Findings

### [L-01] getQuote() Lacks PathMismatch and Sources Length Validation (Unfixed from Round 6 L-01)

**Severity:** Low
**Category:** Input Validation Gap
**Location:** `getQuote()` (lines 474-494)
**Status:** NOT FIXED (carried from Round 6 L-01)

**Description:**

The `getQuote()` function validates `amountIn`, `path.length`, and zero addresses, but does NOT validate:

1. `path[0] == tokenIn` and `path[path.length - 1] == tokenOut` (PathMismatch check)
2. `sources.length == path.length - 1` (sources count check)

In contrast, `swap()` performs both checks via `_validateSwapPath()` (lines 664-678).

A frontend calling `getQuote(tokenA, tokenB, amount, [tokenC, tokenD], sources)` would receive a quote for the C->D path, not A->B. If `sources.length` is mismatched, `_estimateSwapPath()` will access `sources[i]` out of bounds, causing an uninformative revert.

**Recommendation:**

Add to `getQuote()` before the fee calculation:

```solidity
if (sources.length != path.length - 1) {
    revert InvalidLiquiditySource();
}
if (path[0] != tokenIn || path[path.length - 1] != tokenOut) {
    revert PathMismatch();
}
```

---

### [L-02] totalSwapVolume Uses params.amountIn Instead of actualReceived (Unfixed from Round 6 L-02)

**Severity:** Low
**Category:** Business Logic (Accounting)
**Location:** `swap()` (line 344)
**Status:** NOT FIXED (carried from Round 6 L-02)

**Description:**

```solidity
// Line 344
totalSwapVolume += params.amountIn;
```

For fee-on-transfer tokens, `params.amountIn` is higher than `actualReceived` (the amount after transfer-fee deduction at lines 301-307). This inflates the reported volume. While `totalSwapVolume` is informational with no security impact, it provides inaccurate data for analytics and governance.

Note: The AUDIT ACCEPTED comment at lines 79-82 states fee-on-transfer tokens are not supported. If this is strictly enforced, this finding has no practical impact. However, the code at lines 301-307 explicitly implements the balance-before/after pattern for fee-on-transfer support, creating an inconsistency in design intent.

**Recommendation:**

Use `actualReceived`:

```solidity
totalSwapVolume += actualReceived;
```

---

### [L-03] renounceOwnership() Reverts With Semantically Incorrect Error (Unfixed from Round 6 L-03)

**Severity:** Low
**Category:** Code Quality
**Location:** `renounceOwnership()` (line 525-527)
**Status:** NOT FIXED (carried from Round 6 L-03)

**Description:**

```solidity
function renounceOwnership() public pure override {
    revert InvalidRecipientAddress();
}
```

`InvalidRecipientAddress` is misleading -- the caller is not providing a recipient. The `FeeSwapAdapter` contract uses the descriptive `OwnershipRenunciationDisabled()` error for the identical pattern (see `FeeSwapAdapter.sol` line 418-419). Consistency across contracts improves developer experience and error handling.

**Recommendation:**

Add a dedicated error and use it:

```solidity
/// @notice Thrown when renounceOwnership is called
error OwnershipRenunciationDisabled();

function renounceOwnership() public pure override {
    revert OwnershipRenunciationDisabled();
}
```

---

## Informational Findings

### [I-01] No Timelock on Admin Functions (Accepted -- Pioneer Phase)

**Severity:** Informational (accepted risk)
**Location:** All `onlyOwner` functions (lines 371-457)
**Status:** ACCEPTED for Pioneer Phase (carried from Round 6 M-01)

**Description:**

All admin functions take effect immediately without a timelock:

| Function | Immediate Effect |
|----------|-----------------|
| `setSwapFee()` | Fee changed from 0% to 1% in one transaction |
| `setFeeVault()` | All future fees redirected to new address |
| `addLiquiditySource()` | New adapter registered (highest risk -- can drain tokens) |
| `removeLiquiditySource()` | Existing adapter deregistered (breaks active paths) |
| `pause()` / `unpause()` | All swaps frozen/unfrozen |
| `rescueTokens()` | Contract balance swept to feeVault |

**Note:** The `FeeSwapAdapter` uses a 24-hour timelock for router changes (`proposeRouter` / `applyRouter` at `FeeSwapAdapter.sol` lines 338-373). This demonstrates the team is aware of the timelock pattern and has implemented it elsewhere. Applying the same pattern to `addLiquiditySource` and `setFeeVault` in OmniSwapRouter is recommended before opening to public users.

**Centralization Risk Rating: 7/10** (unchanged from Round 6)

---

### [I-02] Solhint Function Ordering Warning

**Severity:** Informational
**Location:** Line 692
**Status:** NEW

**Description:**

Solhint reports: "Function order is incorrect, internal view function can not go after internal pure function (line 664)." The ERC2771Context overrides (`_msgSender()`, `_msgData()`, `_contextSuffixLength()`) at lines 692-729 are internal view functions placed after `_validateSwapPath()` which is internal pure (line 664).

Per the Solidity style guide and project coding standards, view functions should precede pure functions within the same visibility level.

**Recommendation:**

Move the three ERC2771Context override functions (`_msgSender`, `_msgData`, `_contextSuffixLength`) to before `_validateSwapPath()`, or group them in a separate clearly-labeled section that precedes the pure functions section.

---

### [I-03] Statistics Counters Aggregate Across Tokens (Unchanged)

**Severity:** Informational
**Location:** `swap()` (lines 344-345)
**Status:** ACCEPTED (carried from Round 6 I-03)

**Description:**

`totalSwapVolume` and `totalFeesCollected` aggregate raw token amounts across all tokens with different decimal places and values. Summing 1000 USDC (6 decimals) and 1 XOM (18 decimals) produces a meaningless aggregate. The `SwapExecuted` event (lines 168-176) already contains per-swap data that can be indexed off-chain for accurate analytics.

---

## DeFi Exploit Analysis

### Sandwich Attack Protection

**Assessment: ADEQUATE**

Two defenses:
1. **Slippage protection:** `params.minAmountOut` enforced against **actual** balance change (line 331), not adapter-reported value. This is the correct post-H-02 behavior.
2. **Deadline enforcement:** `block.timestamp > params.deadline` (line 625) prevents mempool holding.

### Flash Loan Price Manipulation

**Assessment: PARTIALLY PROTECTED**

The router delegates price discovery entirely to adapters. If an adapter routes through a manipulable AMM pool, the router's slippage check is the only defense. Users setting `minAmountOut = 0` are fully exposed.

### Token Approval Management

**Assessment: FIXED (was VULNERABLE in Round 6)**

The router now correctly:
1. Sets exact per-hop approval via `forceApprove(adapter, amountOut)` (line 565)
2. Resets approval to zero after each hop via `forceApprove(adapter, 0)` (line 580)

No residual approvals persist after any hop.

### Output Token Verification

**Assessment: FIXED (was VULNERABLE in Round 6)**

The router now correctly:
1. Records output token balance before swap execution (line 319-320)
2. Derives actual output from balance change (lines 326-328)
3. Enforces slippage on actual received amount (line 331)
4. Performs per-hop balance verification in `_executeSwapPath` (lines 568-585)

Malicious adapters reporting inflated `amountOut` cannot bypass slippage checks.

### Reentrancy

**Assessment: PROTECTED**

- `swap()` uses `nonReentrant` (line 295)
- `rescueTokens()` uses `nonReentrant` (line 451)
- Adapter calls happen within nonReentrant context
- State updates (lines 344-345) occur after all external calls but are informational counters with no fund-flow impact

### Fee-on-Transfer Token Handling

**Assessment: COMPLETE (with caveat)**

- **Input side:** Balance-before/after at lines 301-307. Fee calculated on `actualReceived`.
- **Output side:** Balance-before/after at lines 319-328.
- **Multi-hop intermediaries:** Per-hop balance verification at lines 568-585.
- **Caveat:** The contract header comment (lines 79-82) states fee-on-transfer tokens are "not supported" and only vetted tokens are whitelisted. The code nonetheless handles them correctly as a defense-in-depth measure.

### Rounding

**Assessment: LOW RISK**

Fee: `(actualReceived * swapFeeBps) / BASIS_POINTS_DIVISOR`. Maximum rounding loss: 1 wei per swap. For amounts below 334 wei (at 30 bps), fee rounds to 0. This is not exploitable.

---

## Verified Safe Patterns

The following patterns were verified as correctly implemented:

| Pattern | Location | Status |
|---------|----------|--------|
| ReentrancyGuard on swap() | Line 295 | Correct |
| ReentrancyGuard on rescueTokens() | Line 451 | Correct |
| Ownable2Step | Line 76 | Correct |
| renounceOwnership disabled | Lines 525-527 | Correct (wrong error, see L-03) |
| Pausable with whenNotPaused | Line 295 | Correct |
| SafeERC20 for all token ops | Lines 77, 303, 315, 336, 454, 565, 580 | Correct |
| Pinned pragma 0.8.24 | Line 2 | Correct |
| Fee cap at 100 bps (1%) | Lines 272, 401 | Correct |
| Deadline enforcement | Line 625 | Correct |
| Zero address validation | Lines 271, 375, 417, 613-617, 621-623 | Correct |
| Same-token prevention | Lines 618-620 | Correct |
| Path length validation | Lines 667-668 | Correct |
| Path endpoint consistency | Lines 672-677 | Correct |
| Sources count validation | Lines 669-671 | Correct |
| Adapter code-length check | Line 376 | Correct |
| Approval reset after each hop | Line 580 | Correct |
| Balance-before/after (input) | Lines 301-307 | Correct |
| Balance-before/after (output) | Lines 319-328 | Correct |
| Balance-before/after (per-hop) | Lines 568-585 | Correct |
| Fee sent to feeVault only | Lines 314-315 | Correct |
| rescueTokens to feeVault only | Line 454 | Correct |
| ERC2771Context overrides | Lines 692-729 | Correct |

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Relevance | Status |
|----------------|--------|-----------|--------|
| Multichain residual approvals (2022, $3M) | Approval reuse | **MITIGATED** -- Approvals reset to 0 after each hop (line 580) |
| Transit Swap unvalidated adapter (2022, $21M) | Adapter trust | **MITIGATED** -- onlyOwner adapter registration + code-length check |
| LI.FI Protocol unvalidated calldata (2024, $11M) | Adapter trust | **MITIGATED** -- Same as above |
| SushiSwap RouteProcessor2 (2023, $3.3M) | Router approval management | **MITIGATED** -- Exact approvals + reset pattern |
| Peapods Finance FoT swap failure (2025) | Fee-on-transfer handling | **MITIGATED** -- Balance-before/after on input, output, and per-hop |

---

## Test Coverage Assessment

**Tests:** 103 passing in `test/dex/OmniSwapRouter.test.js`

**Coverage highlights:**
- Constructor validation (zero feeVault, fee too high, boundary values)
- Single-hop, 2-hop, and 3-hop swaps
- Fee deduction and feeVault receipt
- Slippage protection (below minimum, exact boundary)
- Deadline enforcement (past, equal to current)
- Path validation (empty, too long, mismatch, sources count)
- Zero input, same token, zero addresses, zero recipient
- Unregistered liquidity source
- Pause/unpause flow
- rescueTokens (with balance, without balance, non-owner)
- getQuote estimation and validation
- getSwapStats cumulative tracking
- renounceOwnership revert
- Ownable2Step full flow (transfer, accept, reject non-pending)
- Edge cases (tiny amounts, fee rounding, half-rate adapter, sequential swaps, insufficient balance/allowance)

**Missing test coverage (recommended additions):**
1. ERC-2771 meta-transaction forwarding (swap via trusted forwarder)
2. Adapter that returns mismatched amountOut vs actual transfer (tests H-02 fix)
3. Multi-hop with different adapters per hop
4. Concurrent rescueTokens and swap (reentrancy guard verification)
5. setFeeVault to contract address (not just EOA)

---

## Summary of Recommendations (Priority Order)

| Priority | Finding | Severity | Recommendation |
|----------|---------|----------|----------------|
| 1 | M-01 | Medium | Update deploy scripts for 3-arg constructor; deploy OmniForwarder; update mainnet.json |
| 2 | L-01 | Low | Add PathMismatch + sources length validation to getQuote() |
| 3 | L-02 | Low | Use actualReceived for totalSwapVolume |
| 4 | L-03 | Low | Use OwnershipRenunciationDisabled() error (match FeeSwapAdapter) |
| 5 | I-01 | Info | Add timelock for addLiquiditySource and setFeeVault before public launch |
| 6 | I-02 | Info | Fix solhint function ordering (move ERC2771 overrides before pure functions) |

---

## Risk Assessment

**Overall Security Posture: GOOD**

The contract has improved significantly from Round 6. The two High-severity findings (residual approvals and unverified output balances) have been properly remediated with defense-in-depth patterns. The core swap logic is sound, with comprehensive input validation, slippage protection, deadline enforcement, and reentrancy guards.

**Remaining risks are operational, not architectural:**
- Source/bytecode divergence (M-01) is a deployment hygiene issue
- Missing getQuote validation (L-01) affects frontends, not fund safety
- Volume accounting (L-02) affects analytics only
- Error semantics (L-03) affects developer experience only

**Pre-production blocklist (before public launch):**
1. Deploy updated bytecode matching current source (resolves M-01)
2. Transfer ownership to multi-sig (resolves centralization risk)
3. Add timelock on addLiquiditySource and setFeeVault (resolves I-01)

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet Security Audit*
*Contract: OmniSwapRouter.sol (730 lines, Solidity 0.8.24)*
*Previous audit: audit-reports/round6/OmniSwapRouter-audit-2026-03-10.md*
*Test suite: 103 tests passing (test/dex/OmniSwapRouter.test.js)*
