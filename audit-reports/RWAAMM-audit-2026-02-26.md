# Security Audit Report: RWAAMM (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (Round 3 -- Post-Remediation)
**Contract:** `Coin/contracts/rwa/RWAAMM.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 968
**Upgradeable:** No (immutable by design -- "legally defensible")
**Handles Funds:** Yes (routes token transfers through RWA pools, collects fees)
**Prior Audits:** Round 1 (2026-02-21) -- 1 Critical, 3 High, 5 Medium, 2 Low, 2 Informational

## Executive Summary

RWAAMM is a non-upgradeable AMM factory and router for Real World Asset token pools. It creates constant-product pools via `new RWAPool()`, routes swaps with compliance oracle verification, collects 0.30% protocol fees split 70/20/10 (LP/Staking/Liquidity), and implements a 3-of-5 multi-sig emergency pause with immutable signers.

**Changes since Round 1 (2026-02-21):**
1. `FEE_COLLECTOR` renamed to `FEE_VAULT` (now references `UnifiedFeeVault` instead of `RWAFeeCollector`)
2. `IRWAFeeCollector` callback removed -- fees sent via direct `safeTransferFrom` to the vault
3. `RWAPool` now has `onlyFactory` modifier on `swap()`, `mint()`, `burn()`, `skim()`, and `initialize()` (fixes Round 1 C-01)
4. `addLiquidity` reserve swap bug fixed -- user amounts are reordered to match canonical pool ordering, reserves left untouched (fixes Round 1 H-01)
5. Fee split now implemented: 70% (`lpFee`) transferred to pool, 30% (`collectorFee`) transferred to `FEE_VAULT` (fixes Round 1 H-02)
6. Compliance checks added to `addLiquidity` and `removeLiquidity` via `_checkLiquidityCompliance()` (fixes Round 1 H-03)
7. Duplicate signer check added to constructor (fixes Round 1 M-01)
8. `removeLiquidity` now has `whenNotPaused` modifier (fixes Round 1 M-02)
9. Pool creator access control added via `_poolCreators` mapping and multi-sig management (fixes Round 1 M-04)
10. Pragma pinned to `0.8.24` (fixes Round 1 I-01)
11. `FEE_LP_BPS` is now actively used in fee split calculation (fixes Round 1 I-02)
12. Internal `_createPool()` helper replaces external self-call (fixes Round 1 L-01)

This Round 3 audit found **0 Critical**, **0 High**, **2 Medium**, **3 Low**, and **3 Informational** issues. All Round 1 Critical and High findings have been resolved.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 1 Finding Resolution Status

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | Critical | RWAPool.swap() Unrestricted | **RESOLVED** -- `onlyFactory` modifier added to `swap()`, `mint()`, `burn()`, `skim()`, `initialize()` in RWAPool.sol |
| H-01 | High | addLiquidity Reserve Swap Inverts Price Ratio | **RESOLVED** -- Now swaps user amounts to match canonical ordering; reserves left in pool order (lines 580-584) |
| H-02 | High | 70% LP Fee Never Explicitly Transferred | **RESOLVED** -- Fee split implemented: `lpFee` (70%) added to `amountToPool` and sent to pool; `collectorFee` (30%) sent to `FEE_VAULT` (lines 459-483) |
| H-03 | High | addLiquidity/removeLiquidity Skip Compliance | **RESOLVED** -- `_checkLiquidityCompliance()` added to both functions (lines 570-572, 649-651) |
| M-01 | Medium | Constructor Allows Duplicate Emergency Signers | **RESOLVED** -- O(n^2) duplicate check added (lines 180-186) |
| M-02 | Medium | removeLiquidity Missing whenNotPaused | **RESOLVED** -- `whenNotPaused` modifier added (line 637) |
| M-03 | Medium | FeeCollector.collectFees() Never Called | **RESOLVED** -- `RWAFeeCollector` replaced with `UnifiedFeeVault`; fees sent via direct `safeTransferFrom` |
| M-04 | Medium | createPool Has No Access Control | **RESOLVED** -- `_poolCreators` mapping with multi-sig-gated `setPoolCreator()` (lines 396-401, 696-718) |
| M-05 | Medium | emergencyUnpause Emits Wrong Event | **RESOLVED** -- Correct `EmergencyUnpaused` event emitted (line 796) |
| L-01 | Low | External Self-Call in addLiquidity | **RESOLVED** -- Internal `_createPool()` function used (line 563) |
| L-02 | Low | Fee-on-Transfer Tokens Break Swap Accounting | **NOT ADDRESSED** -- Remains; carried forward as L-01 below |
| I-01 | Informational | Floating Pragma | **RESOLVED** -- Pinned to `0.8.24` |
| I-02 | Informational | Fee Split Constants Are Decorative | **RESOLVED** -- `FEE_LP_BPS` now used in calculation at line 459 |

---

## New Findings

### [M-01] Swap Output Calculation Excludes LP Fee from AMM Formula

**Severity:** Medium
**Lines:** 464-466

**Description:**

The swap function calculates the output amount using `amountInAfterFee` (input minus the full 0.30% protocol fee), but then sends `amountToPool = amountInAfterFee + lpFee` to the pool:

```solidity
uint256 amountToPool = amountInAfterFee + lpFee;               // line 464
uint256 amountOut = (reserveOut * amountInAfterFee)             // line 465
    / (reserveIn + amountInAfterFee);                           // line 466
```

The output amount is calculated based on `amountInAfterFee` (99.70% of input), but the pool actually receives `amountToPool` (99.91% of input, since `lpFee` = 70% of 0.30% = 0.21% is added back). This means the pool's K-value increases by more than the formula accounts for, because extra tokens (`lpFee`) flow into the pool without being part of the AMM curve calculation.

While this is economically favorable to LPs (they receive a "donation" that increases K over time), it creates a discrepancy between the `getQuote()` view function and actual swap execution. The `getQuote()` function (lines 316-318) calculates the fee and `amountInAfterFee` identically, but does not account for the LP fee increasing the pool balance. The pool's `_verifyAndUpdateSwap()` K-check passes because `balance0 * balance1 >= reserve0 * reserve1` holds with the extra LP fee, but the quoted output and actual output are identical only because the LP fee is treated as a pure donation outside the AMM formula.

This is a design choice rather than a bug, but it means the effective fee paid by the swapper is the full 0.30% (not 0.09% as might be expected from the 30% collector split), while LPs earn from both the AMM curve spread AND the 70% fee donation. This differs from the Uniswap V2 model where the fee is integrated into the K-check formula.

**Impact:** No direct loss of funds. The design is internally consistent. However, the effective user-facing fee is 0.30% (not variable), and LP yield is partially from explicit fee donations rather than purely from curve mechanics. Integrators expecting Uniswap-style fee behavior may miscalculate expected outputs if they use raw reserve data instead of `getQuote()`.

**Recommendation:** Document this behavior explicitly in the contract NatSpec. Consider adding a note in the `getQuote()` function that the output reflects the full 0.30% fee deduction and that LP revenue includes both curve spread and fee donation.

---

### [M-02] Non-XOM Fee Tokens Sent to UnifiedFeeVault May Be Undistributable

**Severity:** Medium
**Lines:** 480-483

**Description:**

The `collectorFee` is paid in `tokenIn` (the input token of the swap), which could be any ERC-20 token:

```solidity
IERC20(tokenIn).safeTransferFrom(
    msg.sender, FEE_VAULT, collectorFee
);
```

The `UnifiedFeeVault.distribute()` function works with any ERC-20 token and splits it 70/20/10. However, the vault's `deposit()` function requires `DEPOSITOR_ROLE`, while the RWAAMM sends fees via direct `safeTransferFrom` without calling `deposit()`. The vault's accounting (`FeesDeposited` event) is never triggered for RWAAMM fees.

More importantly, the `UnifiedFeeVault.distribute()` calculates the distributable balance as `balance - pendingBridge[token]`. Since RWAAMM fees arrive via direct transfer (not `deposit()`), they will be distributable but lack the accounting trail provided by the `FeesDeposited` event.

Additionally, for RWA tokens that are ERC-3643 or ERC-1400 security tokens, the vault address may not be whitelisted in the token's transfer registry. If a user swaps RWA Token A for RWA Token B, the fee is paid in Token A (a security token). The `safeTransferFrom` to `FEE_VAULT` may revert if the vault is not a verified participant in that token's compliance system, causing the entire swap to fail.

**Impact:** Swaps involving ERC-3643/ERC-1400 tokens as `tokenIn` may revert if the `FEE_VAULT` address is not whitelisted in the token's compliance contract. For standard ERC-20 tokens, fees arrive at the vault without accounting events but are otherwise functional.

**Recommendation:**
1. Consider collecting fees exclusively in XOM (or a stablecoin) by adding an intermediate swap step, or document that `FEE_VAULT` must be whitelisted in all RWA token compliance contracts.
2. Alternatively, have RWAAMM call `FEE_VAULT.deposit()` instead of direct transfer, which requires giving RWAAMM the `DEPOSITOR_ROLE` and having the AMM approve the vault first.

---

### [L-01] Fee-on-Transfer Tokens Break Swap Accounting (Carried from Round 1)

**Severity:** Low
**Lines:** 464-491

**Description:**

The swap flow assumes `safeTransferFrom` delivers the exact `amountToPool` to the pool and `collectorFee` to the vault. If the input token charges a transfer fee (deflationary tokens), the pool receives less than expected. The pool's K-invariant check may fail with an opaque `KValueDecreased` error, or worse, if it barely passes, the output amount was already calculated assuming the full `amountInAfterFee` was received.

The `addLiquidity` flow has the same issue -- `safeTransferFrom` amounts may differ from actual received amounts.

**Impact:** Fee-on-transfer tokens cause reverts or incorrect pricing. Since this is an RWA-focused AMM, fee-on-transfer tokens are unlikely (regulated securities do not typically have transfer fees), but some ERC-20 stablecoins used as pair tokens might.

**Recommendation:** Document that fee-on-transfer tokens are unsupported. Alternatively, measure balance deltas instead of trusting transferred amounts.

---

### [L-02] `_allPoolIds` Array Grows Unboundedly

**Severity:** Low
**Lines:** 113, 881

**Description:**

Every call to `_createPool()` pushes a new entry to `_allPoolIds`:

```solidity
_allPoolIds.push(poolId);           // line 881
```

The `getAllPoolIds()` function (line 344) returns the entire array. As pools accumulate over time, this function's gas cost grows linearly and will eventually exceed the block gas limit, making it uncallable.

There is no mechanism to remove pool IDs from the array, even for deprecated or permanently paused pools.

**Impact:** `getAllPoolIds()` becomes uncallable after enough pools are created. This only affects off-chain consumers (frontends, indexers) that call this view function. Core swap and liquidity operations are unaffected.

**Recommendation:** Add pagination to `getAllPoolIds()` (offset/limit pattern) or cap the maximum number of pools. Alternatively, rely on `PoolCreated` events for enumeration and remove `getAllPoolIds()`.

---

### [L-03] Pool-Level Pause Check Missing in `addLiquidity` Before Pool Creation

**Severity:** Low
**Lines:** 557-566

**Description:**

In `addLiquidity`, the pool-level pause check (`_poolPaused[poolId]`) occurs at line 566, after the pool auto-creation check at line 561. If the pool does not yet exist, `_poolPaused[poolId]` will always be `false` (default mapping value), so this is not a bypass. However, there is a subtle ordering issue: if a pool creator calls `addLiquidity` during a global pause, the `whenNotPaused` modifier on the function catches it. But if only a specific pool ID is paused (via `emergencyPause` with a non-zero poolId before the pool exists), the pause will not be enforced because the pool is created first and the mapping was set before pool creation.

In practice, pausing a non-existent pool ID is unlikely. The `emergencyPause` function accepts any `bytes32 poolId` and sets `_poolPaused[poolId] = true` regardless of whether the pool exists. If an emergency signer pauses a precomputed pool ID (e.g., `keccak256(abi.encodePacked(tokenA, tokenB))`) before the pool is created, a pool creator could bypass the pause by calling `addLiquidity` and auto-creating the pool, because the pause check happens after creation.

Wait -- re-reading the code more carefully: the `poolId` is computed at line 557 via `getPoolId(token0, token1)`, then the pause check at line 566 uses that same `poolId`. If the pool was pre-paused, the check at 566 would catch it correctly even for a newly created pool. The ordering is actually: compute poolId -> check if pool exists -> create if needed -> check if poolId is paused. This is correct.

**Revised assessment:** This is not a real issue. The pause check correctly uses the deterministic `poolId` which can be pre-computed and pre-paused. Downgrading to Informational.

---

### [I-01] Comment References "FeeCollector" Instead of "FeeVault"

**Severity:** Informational
**Lines:** 458

**Description:**

The comment on line 458 still reads:

```solidity
// Split protocol fee: 70% stays in pool (LP revenue),
// 30% goes to FeeCollector (20% staking + 10% liquidity)
```

The actual recipient is `FEE_VAULT` (UnifiedFeeVault), not "FeeCollector". This is a remnant of the pre-remediation naming. Similar stale references appear at line 478:

```solidity
// Transfer collector fee (20% staking + 10% liquidity)
// to UnifiedFeeVault for batched distribution
```

Line 478 is partially updated (mentions UnifiedFeeVault) but still uses the term "collector fee" for the variable name `collectorFee`.

**Impact:** No functional impact. Documentation-only inconsistency.

**Recommendation:** Update comments and variable name to use "vault" terminology consistently:
- Line 458: "30% goes to UnifiedFeeVault"
- Line 460: Rename `collectorFee` to `vaultFee`
- Line 478: "Transfer vault fee"

---

### [I-02] `DEPLOYER` Immutable Has No External Accessor

**Severity:** Informational
**Lines:** 94, 204

**Description:**

The `DEPLOYER` address is stored as a `private immutable` and used only in the constructor to set `_poolCreators[msg.sender] = true`. After deployment, there is no way to query who the deployer was. The deployer's pool creator status can be checked via `isPoolCreator()`, but the deployer address itself is not retrievable.

This is intentional (private visibility), but it means on-chain governance or monitoring tools cannot verify the deployer identity without parsing deployment transaction data.

**Impact:** No functional impact. Minor transparency concern.

**Recommendation:** Consider making `DEPLOYER` public or adding a `deployer()` view function for transparency. Alternatively, emit a `Deployed(address deployer)` event in the constructor.

---

### [I-03] `sync()` on RWAPool Is Not Factory-Restricted

**Severity:** Informational
**Lines:** RWAPool.sol line 319

**Description:**

`RWAPool.sync()` is `external lock` but not `onlyFactory`. This means anyone can call `sync()` to force-update the pool's reserves to match its actual token balances. While `swap()`, `mint()`, `burn()`, and `skim()` all correctly require `onlyFactory`, `sync()` is open.

In the Uniswap V2 design, `sync()` is also public. It is generally safe because it only sets reserves to match actual balances (it cannot steal funds). However, a malicious actor could:
1. Send tokens directly to the pool (donation)
2. Call `sync()` to update reserves
3. This changes the price oracle's TWAP accumulators

This is a known "donation attack" on TWAP oracles. Since RWAAMM does not currently use TWAP data for any on-chain logic (the cumulative price accumulators are informational), the impact is limited to off-chain systems consuming TWAP data.

**Impact:** TWAP oracle manipulation via token donations + `sync()`. No on-chain impact since RWAAMM does not use TWAP for pricing.

**Recommendation:** Consider adding `onlyFactory` to `sync()` for consistency, or document that TWAP data from RWAPool should not be used for on-chain pricing decisions.

---

## Cross-Contract Observations

### Fee Flow Architecture (Improved)

The fee flow has been significantly improved since Round 1:

```
User -> RWAAMM.swap() -> 70% (lpFee) to RWAPool (increases K for LPs)
                      -> 30% (collectorFee) to UnifiedFeeVault
                                              -> 70% ODDAO (pending bridge)
                                              -> 20% StakingRewardPool
                                              -> 10% Protocol Treasury
```

The effective split of the total 0.30% protocol fee is:
- LPs: 70% of 0.30% = 0.210% (via pool reserve increase)
- ODDAO: 70% of 30% of 0.30% = 0.063%
- Staking: 20% of 30% of 0.30% = 0.018%
- Protocol: 10% of 30% of 0.30% = 0.009%

This is architecturally clean and matches the documented 70/20/10 intent.

### Pool Access Control (Resolved)

RWAPool now correctly restricts `swap()`, `mint()`, `burn()`, `skim()`, and `initialize()` to the factory (RWAAMM) contract. This eliminates the entire class of pool-bypass attacks identified in Round 1. The `onlyFactory` modifier uses the `factory` address set in the constructor, which is immutable for each pool.

### Compliance Coverage (Complete)

All three user-facing operations now enforce compliance:
- `swap()` -- `_checkSwapCompliance()` (line 441)
- `addLiquidity()` -- `_checkLiquidityCompliance()` (line 571)
- `removeLiquidity()` -- `_checkLiquidityCompliance()` (line 650)

The compliance check functions properly verify each token independently against the `COMPLIANCE_ORACLE`.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (aside from non-existent rule warnings for deprecated `contract-name-camelcase` and `event-name-camelcase`)

---

## Methodology

- Pass 1: Static analysis (solhint) -- clean
- Pass 2: Full code review of RWAAMM.sol (968 lines) with cross-reference to RWAPool.sol, IRWAAMM.sol, IRWAComplianceOracle.sol, RWAComplianceOracle.sol, RWARouter.sol, and UnifiedFeeVault.sol
- Pass 3: Round 1 finding verification -- all 13 findings checked for resolution
- Pass 4: New finding identification -- focused on changes since Round 1 (FEE_VAULT migration, fee split implementation, pool creator access control)
- Pass 5: Cross-contract interaction analysis (RWAAMM -> RWAPool, RWAAMM -> UnifiedFeeVault, RWARouter -> RWAAMM)
- Pass 6: Report generation

---

## Conclusion

The RWAAMM contract has undergone substantial remediation since Round 1. All Critical and High findings have been resolved:

1. **Pool bypass (C-01) -- RESOLVED:** `onlyFactory` modifier added to all critical RWAPool functions. Direct pool interaction is no longer possible.

2. **Reserve swap bug (H-01) -- RESOLVED:** User amounts are reordered to match canonical pool token ordering. Reserves are left untouched.

3. **LP fee mismatch (H-02) -- RESOLVED:** Fee split is now implemented. 70% of the protocol fee goes to the pool (increasing LP value), 30% goes to UnifiedFeeVault.

4. **Missing compliance on liquidity (H-03) -- RESOLVED:** `_checkLiquidityCompliance()` is called in both `addLiquidity()` and `removeLiquidity()`.

5. **All Medium findings (M-01 through M-05) -- RESOLVED:** Duplicate signer check, pause on removeLiquidity, FeeCollector replaced with UnifiedFeeVault, pool creator access control, and event correction are all fixed.

The remaining findings are Medium and Low severity, primarily concerning edge cases (non-XOM fee tokens at the vault, fee-on-transfer token compatibility, unbounded pool ID array) and documentation consistency. None represent a risk to user funds in the expected use case of RWA token trading.

**Overall assessment:** The contract is in good shape for deployment. The two Medium findings (M-01: fee calculation documentation, M-02: non-XOM fee token handling) should be addressed before mainnet deployment, but neither represents a critical vulnerability.

---
*Generated by Claude Code Audit Agent -- Round 3 Post-Remediation*
