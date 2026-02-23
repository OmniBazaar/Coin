# Security Audit Report: RWAFeeCollector

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWAFeeCollector.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 430
**Upgradeable:** No (immutable by design)
**Handles Funds:** Yes (receives protocol fees, distributes to staking/liquidity pools)

## Executive Summary

RWAFeeCollector is a non-upgradeable fee aggregation and distribution contract for the RWA AMM. It receives protocol fees from RWAAMM swaps, tracks fee tokens, and distributes XOM balances to the staking pool and liquidity pool on 6-hour epoch intervals. The contract is designed to be the single fee destination for all RWA trading activity.

The audit found **no Critical vulnerabilities in isolation**, but **3 High-severity issues**: (1) the AMM bypasses `collectFees()` entirely by sending tokens directly via `safeTransferFrom`, making all internal accounting dead code; (2) non-XOM fee tokens are permanently stranded with no conversion or rescue mechanism despite NatSpec claiming "automatic conversion to XOM"; and (3) the fee split arithmetic doesn't match the documented 70/20/10 — the collector distributes 66.67%/33.33% (staking/liquidity) because it receives 100% of the fee, not 30%. Both agents identified the architectural disconnect between the AMM's fee transfer pattern and the FeeCollector's expected call pattern.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 4 |
| Low | 3 |
| Informational | 2 |

## Findings

### [H-01] AMM Bypasses collectFees() — All Internal Accounting is Dead Code

**Severity:** High
**Lines:** 231-251 (collectFees), RWAAMM.sol 448
**Agents:** Both

**Description:**

`collectFees()` is gated by `onlyAMM` and designed to be the primary fee intake function. It calls `safeTransferFrom(msg.sender, address(this), amount)` to pull tokens from the AMM, then updates `accumulatedFees`, `_feeTokens`, and emits `FeesCollected`.

However, `RWAAMM.swap()` never calls `collectFees()`. Instead, it transfers fees directly from the user to the FeeCollector:

```solidity
// RWAAMM.sol line 448:
IERC20(tokenIn).safeTransferFrom(msg.sender, FEE_COLLECTOR, protocolFee);
```

This means:
- `accumulatedFees` mapping is always zero for AMM-originated fees
- `_feeTokens` array is never populated
- `FeesCollected` event is never emitted
- `totalCollected` counter is never incremented
- `getFeeTokens()` returns an empty array

The `distribute()` function still works because it reads `IERC20(XOM_TOKEN).balanceOf(address(this))` directly, but the entire tracking and transparency layer is non-functional.

**Impact:** Complete loss of fee transparency. Off-chain dashboards, indexers, and monitoring systems querying `accumulatedFees` or `getFeeTokens()` get empty/zero data. The contract's stated goal of "transparent on-chain distribution" is defeated.

**Recommendation:** Either:
1. Have RWAAMM transfer fee to itself first, then call `feeCollector.collectFees(token, amount)`, or
2. Replace `collectFees()` with a `notifyFeeReceived(token, amount)` function that the AMM calls after the direct transfer, or
3. Remove the dead accounting code and rely solely on Transfer event indexing

---

### [H-02] Non-XOM Fee Tokens Permanently Stranded — No Conversion Mechanism

**Severity:** High
**Lines:** 288-340 (distribute), line 22 (NatSpec)
**Agents:** Both

**Description:**

The NatSpec on line 22 claims "Automatic conversion to XOM for distribution." A `TokensConverted` event is defined (lines 143-151). But there is **no conversion function** anywhere in the contract — no DEX integration, no swap router call, no oracle lookup.

`distribute()` only distributes the XOM balance:
```solidity
uint256 xomBalance = IERC20(XOM_TOKEN).balanceOf(address(this));
if (xomBalance == 0) revert NoFeesToDistribute();
```

Since RWAAMM pools pair various RWA tokens against XOM (and potentially against each other), approximately half of all fee tokens received will be non-XOM. These tokens accumulate indefinitely in the FeeCollector with no mechanism to extract, convert, or distribute them.

The contract is deliberately non-upgradeable, so this cannot be fixed after deployment.

**Impact:** Permanent loss of all non-XOM fee revenue. For a diverse RWA AMM, this could represent 50%+ of total protocol fees locked forever with no recovery path.

**Recommendation:** Add a `convertToXOM(address token, uint256 minAmountOut)` function that swaps non-XOM tokens through RWAAMM. Gate it with a `onlyAuthorized` modifier. As a minimum safety valve, add a token rescue function for accidentally sent tokens, protected by multi-sig.

---

### [H-03] Fee Split Doesn't Match Documented 70/20/10

**Severity:** High
**Lines:** 45-48 (constants), 297-304 (distribution logic)
**Agents:** Both

**Description:**

The contract declares:
```solidity
uint256 public constant FEE_LP_BPS = 7000;      // 70% to LPs (tracking only)
uint256 public constant FEE_STAKING_BPS = 2000;  // 20% to staking
uint256 public constant FEE_LIQUIDITY_BPS = 1000; // 10% to liquidity
```

But `distribute()` splits the ENTIRE XOM balance as:
```solidity
uint256 stakingAmount =
    (xomBalance * FEE_STAKING_BPS) / (FEE_STAKING_BPS + FEE_LIQUIDITY_BPS);
```

This is `xomBalance * 2000 / 3000 = 66.67%` to staking and `33.33%` to liquidity. The `FEE_LP_BPS = 7000` constant is never referenced in any calculation — it's dead code labeled as "tracking only."

The actual fee flow is:
- 0.30% fee extracted from each swap
- 100% of extracted fee sent to FeeCollector
- FeeCollector distributes: 66.67% staking, 33.33% liquidity, 0% to LPs
- LPs earn only from the AMM constant-product curve (not explicit fees)

This contradicts the documented 70/20/10 split and means the staking pool receives 3.3x more than documented (66.67% vs 20%) while LPs receive 0% vs documented 70%.

**Impact:** Material discrepancy between documented and actual fee distribution. Economic model fundamentally different from what's described to stakeholders.

**Recommendation:** If the intent is for LPs to earn from the AMM curve (Uniswap V2 model), remove `FEE_LP_BPS` entirely and document the actual split as 66.67%/33.33%. If the 70/20/10 split is the true intent, RWAAMM must send only 30% of the fee to FeeCollector and keep 70% in the pool.

---

### [M-01] receiveFees() Has No Access Control — Accounting Pollution

**Severity:** Medium
**Lines:** 258-278
**Agent:** Both

**Description:**

`receiveFees()` is callable by anyone with no access modifier:
```solidity
function receiveFees(address token, uint256 amount) external nonReentrant {
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    accumulatedFees[token] += amount;
    // ...
}
```

While this requires actual token transfer (no free inflation), anyone can:
1. Deposit 1 wei of thousands of different tokens, growing `_feeTokens` unboundedly
2. Deposit XOM just before `distribute()` to manipulate distribution amounts (front-running the epoch boundary)
3. Pollute accounting data with arbitrary entries

**Impact:** Unbounded `_feeTokens` growth and manipulable distribution timing.

**Recommendation:** Add `onlyAMM` modifier or maintain an authorized depositor whitelist.

---

### [M-02] Unbounded distributionHistory Array

**Severity:** Medium
**Lines:** 115, 330-337
**Agents:** Both

**Description:**

Every `distribute()` call pushes a `DistributionRecord` (containing two dynamic arrays: `tokens` and `amounts`) into `distributionHistory`. With 6-hour intervals, this grows ~1,460 entries/year. Over the 40-year protocol lifetime, approximately 58,400 entries.

Each record contains variable-length arrays, making storage costs compound. The contract is non-upgradeable, so this cannot be pruned.

**Impact:** Monotonically increasing gas costs for `distribute()` and growing state bloat in a non-upgradeable contract.

**Recommendation:** Emit distribution data exclusively via events (already captured by `FeesDistributed`) and remove the on-chain array, or implement a fixed-size circular buffer.

---

### [M-03] Unbounded _feeTokens Array — Never Pruned

**Severity:** Medium
**Lines:** 84-87, 245-248
**Agents:** Both

**Description:**

Every unique fee token is appended to `_feeTokens` and flagged in `_isFeeToken`:
```solidity
if (!_isFeeToken[token]) {
    _feeTokens.push(token);
    _isFeeToken[token] = true;
}
```

Tokens are never removed, even after distribution or even when their balance reaches zero. Combined with the permissionless `receiveFees()` (M-01), this array can be grown unboundedly by depositing dust amounts of arbitrary tokens.

**Impact:** `getFeeTokens()` returns an increasingly large array. If any function iterates it, gas limits could be reached.

**Recommendation:** Remove on-chain token tracking or add pruning when balances reach zero.

---

### [M-04] DoS if Staking Pool or Liquidity Pool Reverts

**Severity:** Medium
**Lines:** 308-312
**Agent:** Agent A

**Description:**

`distribute()` transfers XOM to both `STAKING_POOL` and `LIQUIDITY_POOL` using `safeTransfer`. If either recipient is a contract that reverts on receive (e.g., a paused pool, a full buffer, or a contract that rejects the token), the entire `distribute()` call fails. No fees can be distributed until the blocking recipient is fixed.

Since `STAKING_POOL` and `LIQUIDITY_POOL` are `immutable`, they cannot be changed if one becomes permanently non-functional.

**Impact:** Permanent DoS on fee distribution if either recipient contract becomes non-functional.

**Recommendation:** Use a pull pattern (recipients claim their share) instead of push, or use low-level `call` with failure handling that quarantines the failed recipient's share.

---

### [L-01] accumulatedFees Never Decremented — Misleading View

**Severity:** Low
**Lines:** 242, 288-340
**Agent:** Agent B

**Description:**

`accumulatedFees[token]` is incremented on fee collection but never decremented after distribution. `getAccumulatedFee()` returns the cumulative total ever collected, not the pending balance. This is misleading for integrators expecting a pending fee amount.

**Recommendation:** Rename to `totalFeesCollected` or decrement after distribution.

---

### [L-02] Epoch Boundary Timing Manipulation

**Severity:** Low
**Lines:** 288-295
**Agent:** Agent A

**Description:**

The distribution interval check uses `block.timestamp`:
```solidity
if (block.timestamp - lastDistribution < DISTRIBUTION_INTERVAL) revert TooEarly();
```

A miner/validator could manipulate the timestamp slightly to control when distributions occur, potentially coordinating with XOM deposits to maximize their staking pool share.

**Impact:** Minor timing manipulation, largely theoretical on Avalanche with 1-2s block times.

**Recommendation:** Accept as inherent to timestamp-based intervals.

---

### [L-03] No Emergency Pause on distribute()

**Severity:** Low
**Lines:** 288
**Agent:** Agent A

**Description:**

`distribute()` has no pause mechanism. If a critical issue is discovered in the staking or liquidity pool contracts, there's no way to halt distributions. The contract has no `Pausable` inheritance and no emergency controls.

**Impact:** Cannot halt distributions during security incidents.

**Recommendation:** Add a simple pause mechanism controlled by the RWAAMM's emergency signers.

---

### [I-01] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:** Uses `^0.8.20`. For deployed contracts, pin to a specific version.

---

### [I-02] TokensConverted Event Never Emitted

**Severity:** Informational
**Agent:** Agent B

**Description:** The `TokensConverted` event (lines 143-151) is defined but never emitted anywhere in the contract, since no conversion function exists (see H-02). This is dead code.

**Recommendation:** Remove the event or implement the conversion functionality.

---

## Static Analysis Results

**Solhint:** 0 errors, 12 warnings (gas optimizations, not-rely-on-time, ordering)
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 20 raw findings -> 12 unique)
- Pass 6: Report generation

## Conclusion

RWAFeeCollector has **three fundamental design gaps that render its transparency features non-functional**:

1. **Dead accounting (H-01)** — the AMM never calls `collectFees()`, so all internal tracking (accumulatedFees, _feeTokens, events) is empty. The contract receives tokens but doesn't know about them.

2. **Stranded non-XOM tokens (H-02)** — no conversion mechanism exists despite NatSpec claiming "automatic conversion." Non-XOM fees are permanently locked in a non-upgradeable contract.

3. **Fee split mismatch (H-03)** — actual distribution is 66.67%/33.33% (staking/liquidity), not the documented 70%/20%/10% (LP/staking/liquidity). The `FEE_LP_BPS = 7000` constant is dead code.

**Cross-contract note:** The FeeCollector's issues are downstream consequences of the RWAAMM's fee transfer pattern (C-01 in RWAAMM audit) and the pool's lack of access control (C-01 in RWAPool audit). Fixing the AMM to call `collectFees()` instead of direct transfer, adding token conversion, and clarifying the fee model documentation would resolve most findings.

**The contract should not be deployed without addressing H-02** — once deployed as immutable, all non-XOM fee revenue is permanently lost.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
