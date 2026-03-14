# Security Audit Report: RWAPool (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Deep Security Review)
**Contract:** `Coin/contracts/rwa/RWAPool.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 635
**Upgradeable:** No (factory-deployed, immutable)
**Handles Funds:** Yes (holds token reserves for AMM swaps and LP positions)
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
**Dependencies:** OpenZeppelin v5.x (ERC20, IERC20, SafeERC20, Math), IRWAPool interface
**Related Contracts:** RWAAMM.sol (factory, 1,221 lines), RWARouter.sol (847 lines), RWAComplianceOracle.sol, IRWAPool.sol (199 lines)

---

## Executive Summary

RWAPool is a constant-product AMM liquidity pool for Real World Asset / XOM token pairs, closely following the Uniswap V2 Pair architecture. It implements LP token minting/burning, optimistic swaps with K-invariant enforcement, cumulative price oracles (TWAP via UQ112x112 fixed-point), and utility functions (skim, sync). All state-changing functions (mint, burn, swap, skim) are restricted to the factory (RWAAMM) contract via the `onlyFactory` modifier. Users interact exclusively through RWAAMM or RWARouter, which enforce compliance, fee collection, and pause controls.

This Round 7 audit reviews the contract post-remediation of all Critical and High findings from Rounds 1, 3, and 6. The contract has grown from 379 lines (Round 1) to 635 lines as defense-in-depth improvements were incorporated. All previous Critical and High findings have been properly remediated:

- **C-01 (Round 1: Zero-fee direct access):** FIXED -- `onlyFactory` modifier on `swap()`, `mint()`, `burn()`, `skim()`
- **H-01 (Round 1: TWAP UQ112x112 missing):** FIXED -- `<< 112` shift before division
- **H-02 (Round 1: No access control):** FIXED -- `onlyFactory` on all value-affecting functions
- **H-03 (Round 1: First depositor attack):** FIXED -- `MINIMUM_INITIAL_DEPOSIT = 10_000`
- **H-01 (Round 6: Permissionless sync() oracle manipulation):** FIXED -- Rate-limited to once per block via `_lastSyncBlock`
- **H-02 (Round 6: Flash swap not compliance-gated):** FIXED -- `FlashSwapsDisabled()` revert on non-empty data
- **M-01 (Round 6: First depositor griefing):** FIXED -- `MINIMUM_INITIAL_DEPOSIT = 10_000` documented with guidance
- **M-02 (Round 6: Read-only reentrancy):** FIXED -- Documented in NatSpec with security warning
- **M-03 (Round 6: kLast consistency):** FIXED -- `burn()` uses local variables; NatSpec documents purpose

This Round 7 review identifies **0 critical**, **0 high**, **1 medium**, **4 low**, and **5 informational** findings. The contract is in strong security posture for mainnet deployment. The remaining findings are defense-in-depth improvements and minor hygiene items, none of which represent exploitable vulnerabilities given the factory-only access model and Avalanche deployment context.

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 4 |
| Informational | 5 |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Factory (`onlyFactory`) | `initialize`, `mint`, `burn`, `swap`, `skim` | N/A (delegated to RWAAMM) |
| Anyone (permissionless) | `sync`, `getReserves`, `token0`, `token1`, `price0CumulativeLast`, `price1CumulativeLast`, `kLast`, `MINIMUM_LIQUIDITY`, all ERC20 view/transfer functions | 2/10 |
| Constructor only | Sets `factory = msg.sender` | One-time |

**Factory Capabilities (via RWAAMM):**
- Mint LP tokens to any address (line 244, `mint(to)`)
- Burn LP tokens held by the pool (line 291, `burn(to)`)
- Execute swaps with arbitrary output amounts (line 360, `swap(...)`)
- Skim excess tokens to any address (line 437, `skim(to)`)

**Factory CANNOT:**
- Change the factory address after deployment (no setter, immutable after constructor)
- Re-initialize the pool (AlreadyInitialized check, line 227)
- Modify reserve values directly (only via internal `_update()`)
- Bypass the K-invariant check in swap (line 525)
- Bypass the reentrancy lock (line 188)

**Permissionless Surface:**
- `sync()` is rate-limited to once per block (line 416, audit fix H-01)
- ERC20 transfers of LP tokens are unrestricted (standard ERC20 behavior)
- All view functions are unrestricted

**Centralization Risk: 2/10** -- The pool itself has minimal centralization. The factory address is set at construction and cannot be changed. The factory (RWAAMM) has its own access control model (3-of-5 multi-sig for emergency controls, pool creator whitelist for pool creation). The pool trusts the factory unconditionally for all state-changing operations.

---

## Previous Audit Remediation Verification

### Round 6 Findings -- All Verified Fixed

**H-01 (Permissionless sync() oracle manipulation):**
Lines 413-429 now include `_lastSyncBlock` check:
```solidity
if (_lastSyncBlock == block.number) {
    revert SyncRateLimited();
}
_lastSyncBlock = block.number;
```
An attacker can still donate and call `sync()` once per block, but cannot repeatedly manipulate the TWAP accumulators within a single block. The NatSpec at lines 404-411 correctly warns that TWAP data should not be used for on-chain pricing without additional safeguards. **Verified Fixed.**

**H-02 (Flash swap callback not compliance-gated):**
Lines 383-389 now unconditionally revert on non-empty data:
```solidity
if (data.length > 0) {
    revert FlashSwapsDisabled();
}
```
The `IRWAPoolCallee` interface (lines 17-31) remains declared for potential future use but is never invoked. The NatSpec at lines 346-353 documents the securities law rationale. **Verified Fixed.**

**M-01 (First depositor griefing with low-decimal tokens):**
`MINIMUM_INITIAL_DEPOSIT = 10_000` (line 98) with comprehensive NatSpec at lines 85-97 documenting the economics for 6-decimal tokens. For a pair of 6-decimal tokens, sqrt(10_000 * 10_000) = 10,000 passes the check, requiring at least 0.01 of each token. The NatSpec advises pool creators to deposit "substantially more than the minimum." **Verified Fixed (documented mitigation).**

**M-02 (Read-only reentrancy on swap path):**
NatSpec at lines 354-358 explicitly warns: "External protocols MUST NOT use getReserves() for real-time pricing during active swap transactions. The lock modifier prevents direct reentrancy into the pool but does not protect external readers." **Verified Fixed (documented warning).**

**M-03 (kLast consistency and purpose):**
`burn()` now uses local variables at line 331: `kLast = newBalance0 * newBalance1;`. NatSpec at lines 133-140 documents that kLast is for external consumers only and "MUST NOT rely on kLast for security-critical calculations as it may be stale." **Verified Fixed.**

### Round 3 Findings -- All Verified Fixed

**M-01 (kLast in burn() uses stale values):** Fixed via local variable computation (line 331). **Verified Fixed.**

**M-02 (K-invariant multiplication overflow):** Fixed via explicit uint112 bounds check at lines 516-521 before the K multiplication. **Verified Fixed.**

---

## Findings

### [M-01] Optimistic Token Transfer in `swap()` Sends Tokens Before Flash Swap Revert Check

**Severity:** Medium
**Category:** Logic Ordering / Defense in Depth
**Location:** `swap()` lines 376-389

**Description:**

The `swap()` function transfers output tokens optimistically at lines 376-381, and only THEN checks whether flash swap data is non-empty at lines 388-389:

```solidity
// Lines 376-381: Optimistic transfer FIRST
if (amount0Out > 0) {
    IERC20(token0).safeTransfer(to, amount0Out);
}
if (amount1Out > 0) {
    IERC20(token1).safeTransfer(to, amount1Out);
}

// Lines 388-389: Flash swap check AFTER transfer
if (data.length > 0) {
    revert FlashSwapsDisabled();
}
```

If RWAAMM were to accidentally pass non-empty `data` to the pool's `swap()`, the tokens would be transferred to the recipient first, and then the transaction would revert. Since the entire transaction reverts, the tokens are not lost -- the state is rolled back. However, the ordering is counterintuitive and wastes gas on the transfer before discovering the revert condition.

More importantly, this means the `FlashSwapsDisabled()` revert occurs AFTER external token transfer calls. If the output token has a callback (e.g., ERC-777 tokensReceived hook or ERC-3643 transfer hook), the callback would execute during the `safeTransfer` at line 377 or 380, before the revert at line 389. While the reentrancy lock prevents re-entering the pool, the callback executes in a state where:
1. The tokens have been sent to the recipient
2. The reserves have not been updated
3. The transaction will eventually revert

Any side effects in the callback that are not transaction-scoped (e.g., off-chain logging, cross-contract state that is not reverted) could observe this inconsistent state.

**Impact:** No direct fund loss because the full transaction reverts. The concern is (a) wasted gas on transfers that will be reverted, and (b) theoretical callback execution in an inconsistent state window that gets rolled back. Given that RWAAMM currently always passes empty `data`, this requires a factory bug to trigger.

**Recommendation:** Move the flash swap check before the optimistic transfers:

```solidity
// Check flash swap FIRST
if (data.length > 0) {
    revert FlashSwapsDisabled();
}

// Then transfer
if (amount0Out > 0) {
    IERC20(token0).safeTransfer(to, amount0Out);
}
if (amount1Out > 0) {
    IERC20(token1).safeTransfer(to, amount1Out);
}
```

This is a pure defense-in-depth improvement that eliminates the inconsistent ordering without any downside.

---

### [L-01] `initialize()` Lacks Independent Input Validation

**Severity:** Low
**Category:** Defense in Depth
**Location:** `initialize()` lines 223-231

**Description:**

The `initialize()` function accepts `_token0` and `_token1` without validating that:
1. Neither is `address(0)`
2. They are not equal to each other
3. Neither is equal to `address(this)` (the pool itself)

```solidity
function initialize(
    address _token0,
    address _token1
) external override onlyFactory {
    if (token0 != address(0)) revert AlreadyInitialized();
    token0 = _token0;
    token1 = _token1;
}
```

The RWAAMM factory's `_createPool()` function (RWAAMM.sol lines 988-991) does validate `token0 != token1` and neither is `address(0)` before calling `initialize()`. However, the pool should not rely solely on the caller's validation.

Additionally, the `AlreadyInitialized` guard checks `token0 != address(0)`. If a factory bug passed `_token0 = address(0)` on the first call, `token0` would remain `address(0)` and a second `initialize()` call would succeed, potentially overwriting `token1`.

**Impact:** Requires a factory bug. A pool initialized with invalid tokens would fail on all subsequent operations (IERC20 calls to address(0) revert). The double-initialization edge case requires both a factory bug AND a second factory call with the same pool.

**Recommendation:** Add defense-in-depth validation:

```solidity
if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
if (_token0 == _token1) revert IdenticalTokens();
```

This is a low-effort fix with meaningful risk reduction for an immutable contract.

---

### [L-02] `sync()` Rate Limiting Does Not Prevent Cross-Block Donation Attacks

**Severity:** Low
**Category:** Oracle Security
**Location:** `sync()` lines 413-429

**Description:**

The Round 6 fix (H-01) limits `sync()` to once per block via `_lastSyncBlock`. This prevents an attacker from calling `sync()` multiple times within a single block to skew the TWAP accumulators. However, it does not prevent multi-block donation attacks:

1. Block N: Attacker donates a large amount of token0 to the pool, calls `sync()`
2. Block N+1: TWAP accumulator captures the manipulated price for 1 block period
3. Block N+2: Attacker swaps via RWAAMM to recover the donated tokens, or calls `sync()` again after removing the donation

The per-block rate limit raises the cost (attacker must hold the donation for at least 1 block) but does not eliminate TWAP manipulation for pools where the TWAP window is short (e.g., 1-5 blocks).

The contract's NatSpec (lines 404-411) correctly warns: "TWAP data from this pool should still not be used for on-chain pricing decisions without additional safeguards." This is the appropriate mitigation -- any protocol consuming this TWAP should use long windows (e.g., 30 minutes) and additional deviation checks.

**Impact:** Low. The NatSpec warning is clear and appropriate. Multi-block TWAP manipulation requires significant capital (the donation must exceed the pool's natural reserves to meaningfully move the price) and earns no direct profit from the pool itself. The risk is to external protocols that consume the TWAP, and those protocols are warned.

**Recommendation:** The current implementation and documentation are adequate. No code change required. If RWA-specific TWAP consumers are planned, consider implementing a separate time-weighted oracle contract with built-in deviation guards rather than relying on the pool's raw cumulative accumulators.

---

### [L-03] `skim()` Does Not Validate Recipient Is Not the Pool Itself

**Severity:** Low
**Category:** Input Validation
**Location:** `skim()` lines 437-456

**Description:**

The `skim()` function checks `to != address(0)` but does not check `to != address(this)`:

```solidity
function skim(address to) external override lock onlyFactory {
    if (to == address(0)) revert InvalidRecipient();
    // ... transfers excess to `to`
}
```

If `to == address(this)`, the transfers would send tokens from the pool to itself. For standard ERC20 tokens, this is a no-op (balance does not change). For tokens with transfer hooks or fee-on-transfer behavior, this could trigger unexpected side effects.

In contrast, `burn()` at line 295 correctly checks `to != address(this)`. The `_validateSwapParams()` at line 605 checks `to != token0 && to != token1` but not `to != address(this)` (which is handled by the K-invariant check instead).

**Impact:** Negligible. Skimming to the pool itself is a no-op. Requires a factory bug (RWAAMM would need to pass the pool's own address as the `skim()` recipient). No fund loss.

**Recommendation:** Add `to != address(this)` check for consistency with `burn()`:

```solidity
if (to == address(0) || to == address(this)) revert InvalidRecipient();
```

---

### [L-04] LP Token Name and Symbol Are Identical Across All Pools

**Severity:** Low
**Category:** Usability / Standards Compliance
**Location:** Constructor, line 212

**Description:**

All RWAPool instances use the same ERC20 name and symbol:

```solidity
constructor() ERC20("RWA Pool LP Token", "RWA-LP") {
    factory = msg.sender;
}
```

Since every pool deploys with identical name/symbol, LP tokens from different pools (e.g., USDC/XOM vs RWA-GOLD/XOM) are indistinguishable in wallet UIs and block explorers. Users holding LP tokens from multiple pools cannot tell them apart without comparing contract addresses.

**Impact:** No security impact. Poor user experience in wallets and portfolio trackers.

**Recommendation:** Pass token symbols into the constructor or `initialize()` to generate unique names:

```solidity
constructor(string memory name, string memory symbol)
    ERC20(name, symbol) { ... }
```

Or generate names from the token addresses in `initialize()`. This would require changing the deployment pattern in RWAAMM since the constructor cannot access token addresses (they are set in `initialize()`).

---

### [I-01] `IRWAPoolCallee` Interface Declared But Never Invokable

**Severity:** Informational
**Location:** Lines 17-31

**Description:**

The `IRWAPoolCallee` interface is declared at the top of the file and defines the `rwaPoolCall()` callback function. However, since flash swaps are unconditionally disabled (lines 388-389 revert with `FlashSwapsDisabled()`), this interface is dead code. No contract can ever receive a `rwaPoolCall()` from this pool.

The interface still serves as documentation of the flash swap pattern and could be useful if flash swaps are ever re-enabled in a future version. However, its presence may confuse developers into thinking flash swaps are supported.

**Recommendation:** Consider moving the interface to a separate file (e.g., `interfaces/IRWAPoolCallee.sol`) with a prominent NatSpec comment that flash swaps are disabled in the current version. Alternatively, remove it entirely and re-add it if/when flash swaps are implemented.

---

### [I-02] Event Parameter Indexing Inconsistency in `IRWAPool`

**Severity:** Informational
**Location:** `IRWAPool.sol` lines 18, 24-28, 39-45, 47-57

**Description:**

The interface events have inconsistent indexing strategies:

| Event | Indexed Parameters | Non-Indexed Parameters |
|-------|-------------------|----------------------|
| `Sync` | reserve0, reserve1 (both uint256) | none |
| `Mint` | sender (address), amount0 (uint256), amount1 (uint256) -- all 3 indexed | none |
| `Swap` | sender (address), to (address) | amount0In, amount1In, amount0Out, amount1Out |
| `Burn` | sender (address), amount0 (uint256), to (address) | amount1 |

Indexing `uint256` values (as in `Sync` and `Mint`) hashes the value into a topic, making exact-match filtering possible but preventing range queries. For reserve values and amounts, this is rarely useful. The `Swap` event follows the Uniswap V2 convention (index addresses only), while other events do not.

The `Burn` event indexes `amount0` but not `amount1`, which is asymmetric and could confuse indexer developers.

**Impact:** No security impact. Minor gas cost difference (375 gas per indexed parameter). Inconsistency may cause confusion for event consumers.

**Recommendation:** Standardize on the Uniswap V2 convention: index `address` parameters, do not index `uint256` amounts. This would require updating the interface, which is a breaking change for existing event consumers.

---

### [I-03] `kLast` Storage Write in `mint()` and `burn()` Costs Gas With No Internal Consumer

**Severity:** Informational
**Location:** Lines 277, 331

**Description:**

`kLast` is written after every `mint()` and `burn()` call:

```solidity
// mint(), line 277:
kLast = uint256(reserve0) * uint256(reserve1);

// burn(), line 331:
kLast = newBalance0 * newBalance1;
```

Each SSTORE costs approximately 5,000 gas (warm) or 20,000 gas (cold, first write after deployment). No function within the pool reads `kLast`. The only consumer is the `kLast()` public getter exposed via the interface.

In Uniswap V2, `kLast` supports protocol fee accrual via `_mintFee()`. This pool has no equivalent mechanism. The variable is documented (NatSpec at lines 133-140) as being for "external consumers (e.g., protocol fee calculations, analytics)" with a warning that it should not be used for security-critical calculations.

If no external protocol reads `kLast`, this is wasted gas on every mint/burn operation.

**Impact:** ~5,000 gas wasted per mint/burn. No security impact.

**Recommendation:** If protocol fee accrual is planned, implement the full `_mintFee()` pattern. If not, consider removing the `kLast` writes to save gas. The interface getter can remain for backwards compatibility, returning 0.

---

### [I-04] `_verifyAndUpdateSwap()` Redundant Overflow Check

**Severity:** Informational
**Location:** Lines 516-521 and lines 556-561

**Description:**

The uint112 overflow check appears in both `_verifyAndUpdateSwap()` (lines 516-521) and `_update()` (lines 556-561):

```solidity
// _verifyAndUpdateSwap(), lines 516-521:
if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
    revert Overflow();
}

// _update(), lines 556-561:
if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
    revert Overflow();
}
```

Since `_verifyAndUpdateSwap()` calls `_update()` at line 529, the same check is performed twice with the same values. The check in `_verifyAndUpdateSwap()` (lines 516-521) was added per Round 3 audit finding M-02 to ensure the K-invariant multiplication at line 525 does not overflow. This is a valid reason -- the K-check happens BEFORE `_update()`, so the guard must precede it. The `_update()` check is a defense-in-depth duplicate.

**Impact:** ~200 gas wasted on the redundant comparison (negligible). No security impact. The redundancy is justifiable as defense in depth.

**Recommendation:** No change required. The redundancy is intentional and well-documented. The cost is negligible.

---

### [I-05] `DEAD_ADDRESS` Minimum Liquidity Lock Is Convention-Based, Not Cryptographic

**Severity:** Informational
**Location:** Lines 101-102, 263

**Description:**

The minimum liquidity (1,000 LP tokens) is minted to `0x000000000000000000000000000000000000dEaD`:

```solidity
address private constant DEAD_ADDRESS =
    0x000000000000000000000000000000000000dEaD;
// ...
_mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
```

This is a widely-used convention in DeFi (Uniswap V2, SushiSwap, PancakeSwap, etc.), but the address is not provably unspendable. The private key is 256 bits, and while the probability of anyone possessing it is astronomically small (~1/2^256), it is not mathematically zero. In contrast, `address(0)` is provably unspendable because OpenZeppelin's ERC20 `_transfer()` explicitly blocks transfers from `address(0)`.

The reason `address(0)` is not used is that OpenZeppelin's `_mint()` reverts when minting to `address(0)`. Overriding this behavior would require a custom `_mint()` implementation, adding complexity.

**Impact:** Theoretical only. The dead address convention is trusted across the entire DeFi ecosystem. If anyone controlled this key, the impact would be recovering 1,000 LP tokens worth a negligible amount from every Uniswap V2-style pool ever deployed.

**Recommendation:** No change required. The convention is well-established and the risk is negligible.

---

## Cross-Contract Integration Analysis

### RWAAMM Integration (Factory)

The RWAAMM-RWAPool integration is sound:

1. **Pool Deployment:** RWAAMM deploys pools via `new RWAPool()` (RWAAMM line 1020), correctly setting `factory = msg.sender`. The subsequent `pool.initialize(tokenA, tokenB)` call (line 1021) is protected by `onlyFactory` in the pool.

2. **Fee Model:** RWAAMM deducts 0.30% protocol fee upfront, splits it 70/20/10 (LP/Staking/Protocol), and sends `amountInAfterFee + lpFee` to the pool via `safeTransferFrom` (RWAAMM line 561-563). The pool's K-invariant check uses raw balances without fee adjustment, which is correct because the pool receives more than the AMM-calculated input (the LP fee donation increases K).

3. **Compliance Layer:** RWAAMM checks compliance via the oracle before delegating to the pool. The pool trusts the factory to have performed compliance checks. This is correct -- the `onlyFactory` modifier ensures no bypass.

4. **Swap Parameters:** RWAAMM always passes empty `data` to `pool.swap()` (RWAAMM line 578: `pool.swap(amount0Out, amount1Out, caller, "")`). The pool's flash swap check is defense-in-depth against future factory changes.

5. **Burn Recipient:** RWAAMM passes `caller` as the burn recipient (RWAAMM line 768: `pool.burn(caller)`). The pool validates `to != address(0) && to != address(this)`.

**No integration vulnerabilities found.**

### RWARouter Integration

The RWARouter-RWAPool integration is indirect (Router -> RWAAMM -> Pool):

1. **Token Approval:** The router approves RWAAMM for token transfers, not the pool directly. RWAAMM then transfers tokens to the pool. This is the correct two-step pattern.

2. **LP Token Flow:** For `addLiquidity`, RWAAMM mints LP tokens to `caller` (the router's `msg.sender`, which is the RWAAMM contract). The router then transfers LP tokens to the final recipient. This correctly routes through the factory's access control.

3. **Multi-Hop Swaps:** The router executes multi-hop swaps by calling RWAAMM.swap() at each hop. Each hop goes through the full compliance/fee/pause check. The pool is never called directly.

**No integration vulnerabilities found.**

---

## Economic Invariant Analysis

### Constant-Product Invariant (x * y = k)

The K-invariant check at line 525 is correct:

```solidity
if (balance0 * balance1 < _reserve0 * _reserve1) {
    revert KValueDecreased();
}
```

This ensures that every swap either maintains or increases K. Since RWAAMM sends `amountInAfterFee + lpFee` to the pool (where `lpFee` is 70% of the 0.30% protocol fee), K increases with every swap by the LP fee amount. This is the source of LP yield from fees.

**Verified: K can never decrease through normal operations.** The only way K decreases is via `burn()` (proportional withdrawal) or `skim()` (excess removal), both factory-gated.

### LP Token Economics

First deposit: `liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY`
Subsequent deposits: `liquidity = min(amount0/reserve0, amount1/reserve1) * totalSupply`

Both formulas are correct and match Uniswap V2. The `MINIMUM_INITIAL_DEPOSIT = 10_000` check prevents micro-deposits that enable share inflation attacks.

**Verified: LP token value monotonically increases** (from K growth via fee donations) for non-withdrawing LPs.

### Withdrawal (burn) Proportionality

```solidity
amount0 = (liquidity * balance0) / _totalSupply;
amount1 = (liquidity * balance1) / _totalSupply;
```

This uses `balance` (actual token balances) rather than `reserve` (stored reserves). This means any donations (tokens sent directly to the pool) are distributed to LP holders proportionally upon withdrawal. This is correct behavior -- donations should not be lost.

**Verified: No rounding attack** is economically viable with `MINIMUM_INITIAL_DEPOSIT = 10_000` for RWA tokens (typically 6-18 decimals).

---

## Reentrancy Analysis

### Direct Reentrancy

The `lock()` modifier (lines 187-192) prevents all direct reentrancy:

```solidity
modifier lock() {
    if (unlocked != 1) revert Locked();
    unlocked = 0;
    _;
    unlocked = 1;
}
```

Functions protected: `mint`, `burn`, `swap`, `sync`, `skim`. The `lock` modifier is applied alongside `onlyFactory` where applicable, providing defense in depth.

**The reentrancy lock uses 0/1 instead of OpenZeppelin's 1/2 pattern.** Both are correct. The 0/1 pattern saves one SSTORE (5,000 gas) on deployment because the initial value (1) matches the "unlocked" state, while OpenZeppelin's pattern initializes to 1 ("not entered") and toggles to 2 ("entered"), always requiring a warm SSTORE.

### Read-Only Reentrancy

The `swap()` function uses the optimistic transfer pattern (transfer first, verify K-invariant after). During the `safeTransfer` at lines 377/380, `getReserves()` returns stale (pre-swap) values. Any external contract reading reserves during a token transfer callback would see incorrect prices.

This is documented in the NatSpec (lines 354-358) and is an inherent property of the optimistic transfer design. The `burn()` function correctly uses CEI (update reserves before transfer), eliminating read-only reentrancy on the withdrawal path.

**Status: Documented risk, inherent to design. Acceptable for mainnet.**

---

## Gas Optimization Notes

The contract is reasonably gas-optimized:

1. **Custom reentrancy lock** (0/1 toggle) instead of OpenZeppelin's ReentrancyGuard saves gas on the status check
2. **Local variable caching** of `reserve0`, `reserve1`, `totalSupply()` in `mint()` and `burn()` avoids repeated SLOAD
3. **`unchecked` blocks** for TWAP accumulator arithmetic (lines 567-581) where overflow is intentional
4. **Custom errors** throughout instead of `require()` strings, saving deployment and runtime gas
5. **Single-slot storage packing** for `reserve0` (uint112) + `reserve1` (uint112) + `blockTimestampLast` (uint32) = 256 bits = one storage slot

Minor gas waste: `kLast` SSTORE on every mint/burn (~5,000 gas each, see I-03). The redundant uint112 check (see I-04) wastes ~200 gas per swap.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (2 meta-warnings about nonexistent rule names in config, same as all prior rounds)

The contract passes all solhint checks cleanly. Key observations:
- Pragma pinned to `0.8.24` (not floating)
- All `block.timestamp` usages are in the `_update()` function (line 564), appropriately handled via `solhint-disable-next-line not-rely-on-time`
- `unchecked` blocks used correctly for intentional-overflow TWAP arithmetic
- SafeERC20 used consistently for all external token transfers
- All external functions have NatSpec documentation

---

## Round-Over-Round Comparison

| Metric | Round 1 | Round 3 | Round 6 | Round 7 |
|--------|---------|---------|---------|---------|
| Lines of Code | 379 | 519 | 577 | 635 |
| Critical | 1 | 0 | 0 | 0 |
| High | 3 | 0 | 2 | 0 |
| Medium | 3 | 2 | 3 | 1 |
| Low | 4 | 4 | 3 | 4 |
| Informational | 2 | 3 | 5 | 5 |
| Solhint warnings | 5 | 0 | 0 | 0 |

The contract has matured significantly across four audit rounds. All Critical and High findings from all previous rounds have been remediated. The line count increase reflects defense-in-depth additions (rate-limited sync, flash swap disablement, enhanced NatSpec, uint112 overflow guards). The single remaining Medium finding (M-01, flash swap check ordering) is a code quality improvement with no direct exploitability.

---

## Findings Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | Optimistic Transfer Before Flash Swap Revert Check | Open |
| L-01 | Low | `initialize()` Lacks Independent Input Validation | Open |
| L-02 | Low | `sync()` Rate Limiting Does Not Prevent Cross-Block Donation Attacks | Accepted (documented) |
| L-03 | Low | `skim()` Does Not Validate Recipient Is Not Pool Itself | Open |
| L-04 | Low | LP Token Name and Symbol Identical Across All Pools | Open |
| I-01 | Info | `IRWAPoolCallee` Interface Declared But Never Invokable | Open |
| I-02 | Info | Event Parameter Indexing Inconsistency in IRWAPool | Open |
| I-03 | Info | `kLast` Storage Write Costs Gas With No Internal Consumer | Open |
| I-04 | Info | `_verifyAndUpdateSwap()` Redundant Overflow Check | Accepted |
| I-05 | Info | `DEAD_ADDRESS` Convention-Based, Not Cryptographic | Accepted |

---

## Risk Assessment

**Overall Risk: LOW**

The RWAPool contract is in strong security posture for mainnet deployment. The factory-only access model (enforced by `onlyFactory`) ensures that all value-affecting operations go through RWAAMM's compliance, fee, and pause layers. The contract cannot be directly exploited by external actors.

**Deployment Recommendation:** The contract is suitable for mainnet deployment. Before deploying, consider addressing:
1. **M-01:** Move the flash swap revert check before optimistic transfers (minimal code change, pure defense-in-depth)
2. **L-01:** Add validation to `initialize()` (minimal code change, meaningful risk reduction for an immutable contract)
3. **L-03:** Add `address(this)` check to `skim()` (one-line change for consistency)

All other findings are informational or accepted risks that do not require code changes.

---

## Methodology

This Round 7 audit followed a comprehensive deep security review:

1. **Previous Audit Verification:** Each finding from Rounds 1, 3, and 6 individually verified against the current codebase with specific line references
2. **Line-by-Line Manual Review:** All 635 lines reviewed for reentrancy, access control, overflow/underflow, unchecked external calls, front-running, and logic errors
3. **Cross-Contract Integration Analysis:** RWAAMM (1,221 lines), RWARouter (847 lines), and IRWAComplianceOracle reviewed for integration correctness, permission assumptions, and compliance bypass vectors
4. **Economic Invariant Verification:** Constant-product formula, LP token economics, fee model, and first-depositor attack economics analyzed
5. **Reentrancy Analysis:** Both direct and read-only reentrancy paths mapped for all external calls
6. **Static Analysis:** Solhint with project configuration
7. **Access Control Mapping:** All roles, modifiers, and their capabilities documented

---
*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet Final Review*
