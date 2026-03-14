# Security Audit Report: OmniBonding (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/liquidity/OmniBonding.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,204
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds XOM for bond distribution; bonded assets sent to treasury)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable2Step`, `Pausable`, `ERC2771Context` (all OZ v5.4.0)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)
**Slither:** Skipped (resource contention)
**Solhint:** Clean (no findings; only 2 non-existent rule warnings from global config)
**Test Suite:** 118 tests, 118 passing (100%)

---

## Executive Summary

OmniBonding is an Olympus DAO-inspired Protocol Owned Liquidity contract where users deposit stablecoin assets (USDC, USDT, DAI) and receive discounted XOM with linear vesting (1-30 days). The protocol permanently owns the bonded assets, which are sent directly to the treasury. The contract features multi-asset bonding with configurable discount rates (5-15%), daily capacity limits per asset, a fixed-price oracle with absolute bounds and rate-of-change limits, solvency guarantees via `totalXomOutstanding` tracking, a 6-hour cooldown on price updates, ERC2771 meta-transaction support, and token rescue functionality.

Since the Round 6 audit (2026-03-10), all three actionable findings have been remediated:
- H-01 (Ownable -> Ownable2Step): **FIXED** -- contract now inherits `Ownable2Step` (line 68) with `renounceOwnership()` override (line 1056)
- M-01 (withdrawXom underflow): **FIXED** -- safe check added at line 815
- M-02 (front-running setXomPrice): **DOCUMENTED** -- operational mitigation (pause-update-unpause) documented in NatSpec (lines 708-712)

This Round 7 audit identifies **0 Critical**, **0 High**, **2 Medium**, **3 Low**, and **3 Informational** findings. The contract is in strong shape for mainnet deployment with minor remaining improvements.

---

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | `addBondAsset()` does not prevent adding XOM as a bond asset | NEW |
| M-02 | Medium | `depositXom()` uses `msg.sender` instead of `_msgSender()`, breaking ERC-2771 consistency | NEW |
| L-01 | Low | `bond()` performs external call before state updates (CEI relaxation under `nonReentrant`) | NEW |
| L-02 | Low | `dailyCapacity` of zero is accepted, silently disabling all bonding for the asset | NEW |
| L-03 | Low | `PRICE_COOLDOWN` bypass on first `setXomPrice()` after deployment | UNCHANGED (from Round 6 L-03) |
| I-01 | Informational | Dead `priceOracle` code adds unused storage slot and functions | UNCHANGED (from Round 6 I-01) |
| I-02 | Informational | `claimAll()` batch decrement pattern vs per-bond decrement | UNCHANGED (from Round 6 L-02, downgraded) |
| I-03 | Informational | `updateBondTerms()` accepts `dailyCapacity = 0` without validation | NEW |

---

## Round 6 Remediation Status

All three actionable findings from Round 6 have been addressed:

| Round 6 Finding | Status | Evidence |
|-----------------|--------|----------|
| H-01: Single-step `Ownable` ownership transfer | **FIXED** | Contract now inherits `Ownable2Step` (line 7, 68). `renounceOwnership()` override always reverts (lines 1056-1058). `acceptOwnership()` two-step flow confirmed by tests. |
| M-01: `withdrawXom()` underflow on `balance < totalXomOutstanding` | **FIXED** | Safe check `if (balance < totalXomOutstanding) revert InsufficientXomBalance()` added at line 815-816, before the subtraction at line 818. |
| M-02: Front-running `setXomPrice()` to bond at stale price | **DOCUMENTED** | Operational mitigation documented in NatSpec (lines 708-712): pause -> setXomPrice -> unpause. Code-level fix not required since operational procedure eliminates the window. |
| L-01: `_normalizeToPrice()` precision loss for `decimals > 18` | **UNCHANGED** | Still present but mitigated by `if (xomOwed == 0) revert` check. Acceptable for stablecoin-only usage. |
| L-02: `claimAll()` batch decrement pattern | **UNCHANGED** | See I-02 below. Downgraded to Informational since `nonReentrant` prevents any accounting interleaving. |
| L-03: `PRICE_COOLDOWN` bypass on first call | **UNCHANGED** | See L-03 below. Acceptable design but flagged again for awareness. |
| L-04: `bond()` sends assets directly to treasury | **UNCHANGED** | Accepted design decision. Treasury validation is operational. |
| I-01: Dead `priceOracle` code | **UNCHANGED** | See I-01 below. |
| I-02: `ActiveBondExists` prevents partial claim + re-bond | **UNCHANGED** | Intentional design. |
| I-03: Event indexing uses numeric values | **UNCHANGED** | Accepted. |

---

## Architecture Analysis

### Design Strengths

1. **Ownable2Step (Round 6 H-01 Fix):** Ownership transfer now requires explicit acceptance by the new owner via `acceptOwnership()`. Combined with the `renounceOwnership()` override that always reverts, this prevents both accidental transfers and irreversible lockout.

2. **Solvency Invariant:** `totalXomOutstanding` tracks all XOM committed to bond holders. The invariant `XOM.balanceOf(address(this)) >= totalXomOutstanding` is enforced in `bond()` (lines 571-576) and maintained by `claim()` / `claimAll()` (decrement) and `withdrawXom()` (excess-only withdrawal at line 818-819). The safe check at line 815-816 prevents underflow panic.

3. **Triple-Layer Price Controls:**
   - Absolute bounds: `MIN_XOM_PRICE` ($0.0001) to `MAX_XOM_PRICE` ($100)
   - Rate-of-change: `MAX_PRICE_CHANGE_BPS` = 10% per update
   - Cooldown: `PRICE_COOLDOWN` = 6 hours between updates
   - Effective maximum manipulation: ~10% per 6 hours, ~40% per day

4. **Fee-on-Transfer Protection:** Balance-before/after pattern in `bond()` (lines 579-588) and `depositXom()` (lines 790-796) rejects fee-on-transfer tokens that would create accounting discrepancies.

5. **Daily Capacity Limits:** Per-asset daily caps prevent large-scale bonding manipulation. Reset at UTC midnight boundaries.

6. **Bond Cleanup:** Fully-claimed bonds are deleted from storage (lines 637-639, 673-676), freeing gas and enabling re-bonding.

7. **rescueToken with XOM Guard:** Non-XOM tokens can be recovered from the contract, but XOM is excluded (line 855) to maintain the solvency invariant.

8. **Comprehensive NatSpec:** Every function, event, error, constant, and state variable has detailed documentation. Contract-level NatSpec prominently warns about stablecoin-only operation, multisig ownership requirements, and the bonding curve formula.

9. **ERC-2771 Meta-Transaction Support:** `_msgSender()` correctly resolves the original sender for `bond()`, `claim()`, and `claimAll()` when called via the trusted forwarder.

### Remaining Concerns

1. **XOM as Bond Asset:** No guard prevents adding XOM itself as a bond asset. See M-01.
2. **Inconsistent ERC-2771 Usage:** `depositXom()` uses raw `msg.sender`. See M-02.
3. **Fixed Price Oracle:** `getXomPrice()` returns a fixed value set by the owner. The `priceOracle` variable exists but is unused. Bond pricing remains entirely under owner control (subject to rate-of-change and cooldown limits).
4. **Stablecoin-Only Assumption:** `_normalizeToPrice()` assumes all bonded assets are worth $1 per unit. Adding volatile assets without price feeds would be incorrect.

---

## Detailed Findings

### [M-01] `addBondAsset()` Does Not Prevent Adding XOM as a Bond Asset

**Severity:** Medium
**Lines:** 407-458 (addBondAsset), 532-613 (bond)
**Category:** Input Validation / Economic

**Description:**

The `addBondAsset()` function validates that `asset != address(0)` and that the asset has not been added before, but it does not check that `asset != address(XOM)`. If the owner accidentally adds XOM as a bond asset, users could bond XOM tokens to receive more XOM tokens (at a discount), creating a self-referential arbitrage loop:

1. User deposits 100,000 XOM via `bond(xomAddress, 100000e18)`
2. At 10% discount, user receives a bond for ~111,111 XOM
3. After vesting, user claims 111,111 XOM (net gain: 11,111 XOM)
4. User repeats with the claimed XOM

Each cycle extracts `xomOwed - bondAmount` XOM from the contract. The solvency check (`XOM.balanceOf(address(this)) < totalXomOutstanding + xomOwed`) would eventually halt this when the contract runs out of excess XOM, but it would drain reserves intended for legitimate stablecoin bonders.

Additionally, the fee-on-transfer check in `bond()` (lines 579-588) checks the treasury balance of the bonded asset. If XOM is the bonded asset, this check measures XOM balance of the treasury (correct) -- but the XOM balance of the bonding contract itself decreases by `xomOwed` when the user claims. The solvency check handles this correctly, so there is no double-spend, but the economic drain is real.

Since `addBondAsset` is `onlyOwner` and the contract header specifies multisig usage, this requires owner error or compromise. The probability is low but the impact is the accelerated depletion of XOM reserves available for legitimate bonds.

**Impact:** If XOM is added as a bond asset, users can extract XOM at a discount in a self-referential loop, draining reserves faster than intended. The solvency check prevents insolvency but not the economic drain.

**Recommendation:**

Add a check in `addBondAsset()`:

```solidity
if (asset == address(XOM)) revert InvalidParameters();
```

This is a one-line fix with zero gas impact on normal operation.

---

### [M-02] `depositXom()` Uses `msg.sender` Instead of `_msgSender()`, Breaking ERC-2771 Consistency

**Severity:** Medium
**Lines:** 789-798 (depositXom)
**Category:** ERC-2771 Consistency / Meta-Transaction

**Description:**

The `depositXom()` function uses raw `msg.sender` in two places:

```solidity
function depositXom(uint256 amount) external onlyOwner {
    uint256 balBefore = XOM.balanceOf(address(this));
    XOM.safeTransferFrom(msg.sender, address(this), amount);  // Line 791
    // ...
    emit XomDeposited(msg.sender, amount);                      // Line 797
}
```

All other state-changing functions in the contract that interact with the caller use `_msgSender()` (bond at line 539, claim at line 625, claimAll at line 658). The `onlyOwner` modifier itself uses `_msgSender()` internally (via OZ's `Ownable._checkOwner()`).

If `depositXom()` is called via the trusted ERC-2771 forwarder:
1. `onlyOwner` check passes (uses `_msgSender()` which resolves to the actual owner)
2. `safeTransferFrom(msg.sender, ...)` uses the forwarder's address as the `from` parameter
3. The transfer would fail because the forwarder (not the owner) is used as the source
4. The emitted event would log the forwarder's address, not the actual depositor

This creates an inconsistency where meta-transaction authorization succeeds but execution fails. While `depositXom` is an admin function unlikely to be called via meta-transaction in practice, the inconsistency could cause confusion during integration and is a deviation from the contract's ERC-2771 pattern.

**Impact:** `depositXom()` would fail if called via the trusted forwarder. The emitted event would log the wrong address. No fund loss, but breaks ERC-2771 consistency.

**Recommendation:**

Replace `msg.sender` with `_msgSender()`:

```solidity
function depositXom(uint256 amount) external onlyOwner {
    address caller = _msgSender();
    uint256 balBefore = XOM.balanceOf(address(this));
    XOM.safeTransferFrom(caller, address(this), amount);
    uint256 actualReceived = XOM.balanceOf(address(this)) - balBefore;
    if (actualReceived != amount) {
        revert TransferAmountMismatch();
    }
    emit XomDeposited(caller, amount);
}
```

---

### [L-01] `bond()` Performs External Call Before State Updates (CEI Relaxation Under `nonReentrant`)

**Severity:** Low
**Lines:** 579-607
**Category:** Reentrancy / Code Pattern

**Description:**

The `bond()` function performs the bonded asset transfer to treasury (an external call via `safeTransferFrom`) before updating the bond state:

```solidity
// External call (line 581)
terms.asset.safeTransferFrom(caller, treasury, amount);
uint256 actualReceived = terms.asset.balanceOf(treasury) - treasuryBalBefore;
if (actualReceived != amount) revert TransferAmountMismatch();

// State updates (lines 593-607) -- AFTER external call
userBonds[caller][asset] = UserBond({...});
terms.dailyBonded += amount;
terms.totalXomDistributed += xomOwed;
// ...
```

This is a Checks-Effects-Interactions (CEI) pattern relaxation. The `nonReentrant` modifier prevents reentrancy, so no exploit is possible. However, if a future refactor removes `nonReentrant` (or if the modifier is bypassed due to a bug in the ReentrancyGuard implementation), the relaxed CEI would become exploitable via a malicious ERC20 callback.

Note: The bonded asset's `safeTransferFrom` could invoke a callback on a malicious token contract if the token implements hooks (e.g., ERC-777). The `nonReentrant` guard blocks any re-entry, making this safe in the current implementation.

**Impact:** No current vulnerability. The `nonReentrant` guard fully mitigates the risk. This is a defense-in-depth observation.

**Recommendation:**

For defense-in-depth, consider restructuring `bond()` to follow strict CEI by moving state updates before the external call:

```solidity
// 1. Create bond (effects)
userBonds[caller][asset] = UserBond({...});
terms.dailyBonded += amount;
terms.totalXomDistributed += xomOwed;
terms.totalAssetReceived += amount;
totalXomDistributed += xomOwed;
totalValueReceived += assetValue;
totalXomOutstanding += xomOwed;

// 2. Transfer asset to treasury (interaction)
uint256 treasuryBalBefore = terms.asset.balanceOf(treasury);
terms.asset.safeTransferFrom(caller, treasury, amount);
uint256 actualReceived = terms.asset.balanceOf(treasury) - treasuryBalBefore;
if (actualReceived != amount) {
    revert TransferAmountMismatch();
}
```

If the transfer fails, the entire transaction reverts and the state updates are rolled back, so there is no risk of state corruption. This pattern would be safe even without `nonReentrant`.

Note: One subtlety -- if the transfer reverts, the state changes are atomically rolled back anyway. The reorder has no functional impact, only improves defense-in-depth.

---

### [L-02] `dailyCapacity` of Zero Is Accepted, Silently Disabling All Bonding for the Asset

**Severity:** Low
**Lines:** 407-458 (addBondAsset), 472-502 (updateBondTerms), 1088-1091 (_validateBondAsset)
**Category:** Input Validation

**Description:**

Neither `addBondAsset()` nor `updateBondTerms()` validates that `dailyCapacity > 0`. If the owner sets `dailyCapacity = 0`, the daily capacity check in `_validateBondAsset()` becomes:

```solidity
if (terms.dailyBonded + amount > 0) {  // always true for amount > 0
    revert DailyCapacityExceeded();
}
```

This effectively disables bonding for the asset, which is functionally equivalent to `setBondAssetEnabled(asset, false)`. While not a vulnerability, it creates a redundant and less transparent way to disable an asset. An operator troubleshooting "why can't users bond?" would not easily discover that the capacity is zero (as opposed to the asset being explicitly disabled).

**Impact:** Owner confusion. No fund loss. Zero capacity silently prevents all bonds without a clear error message indicating the root cause.

**Recommendation:**

Add a minimum capacity check:

```solidity
if (dailyCapacity == 0) revert InvalidParameters();
```

Or document that `dailyCapacity = 0` is a valid way to pause an individual asset.

---

### [L-03] `PRICE_COOLDOWN` Bypass on First `setXomPrice()` After Deployment (Unchanged from Round 6)

**Severity:** Low
**Lines:** 364-388 (constructor), 715-742 (setXomPrice)
**Category:** Initialization

**Description:**

The constructor sets `fixedXomPrice` but does not initialize `lastPriceUpdateTime`. It defaults to `0`, meaning the first `setXomPrice()` call is not subject to the 6-hour cooldown (since `block.timestamp > 0 + PRICE_COOLDOWN` is always true after deployment).

The first call IS still subject to the 10% rate-of-change limit relative to `_initialXomPrice`. If the initial price needs significant correction after deployment (e.g., deploying with a placeholder price), the owner must make multiple 10% changes across multiple 6-hour cooldown periods.

**Impact:** Post-deployment price adjustment is limited to 10% per 6 hours, even if the initial price was incorrect. This could delay the start of bonding by hours if the initial price needs correction.

**Recommendation:**

Consider adding a one-time initial price override that is only available before the first bond:

```solidity
function setInitialPrice(uint256 newPrice) external onlyOwner {
    if (totalXomDistributed > 0) revert InvalidParameters();
    if (newPrice < MIN_XOM_PRICE || newPrice > MAX_XOM_PRICE) {
        revert PriceOutOfBounds(newPrice);
    }
    fixedXomPrice = newPrice;
    lastPriceUpdateTime = block.timestamp;
    emit XomPriceUpdated(newPrice);
}
```

---

### [I-01] Dead `priceOracle` Code Adds Unused Storage Slot and Functions (Unchanged from Round 6)

**Severity:** Informational
**Lines:** 162, 770-778 (setPriceOracle), 1040-1046 (getXomPrice)
**Category:** Code Hygiene

**Description:**

The `priceOracle` state variable and `setPriceOracle()` function exist but `getXomPrice()` only returns `fixedXomPrice`. The oracle is never queried.

**Impact:** No security impact. One unused storage slot (32 bytes). ~100 bytes of unnecessary bytecode.

**Recommendation:**

Either integrate the oracle into `getXomPrice()` or remove the dead code. If oracle integration is planned for a future phase, add a `@dev` comment with a timeline.

---

### [I-02] `claimAll()` Batch Decrement Pattern vs Per-Bond Decrement (Downgraded from Round 6 L-02)

**Severity:** Informational
**Lines:** 653-691

**Description:**

`claimAll()` accumulates `totalClaimed` in a loop and decrements `totalXomOutstanding` once after the loop (line 687), then performs a single `XOM.safeTransfer` (line 688). This is actually more gas-efficient than per-bond decrement for multiple bonds (1 SSTORE vs N SSTOREs for `totalXomOutstanding`).

In a pathological scenario where `totalXomOutstanding` has somehow drifted below the expected value, the batch subtraction at line 687 could underflow, preventing all claims for the user -- even though individual `claim()` calls might succeed for some bonds.

Since `nonReentrant` prevents interleaving and the `totalXomOutstanding` invariant is maintained by all code paths, this scenario requires an external state corruption (e.g., a bug in XOM token that reduces contract balance without going through `claim`).

**Impact:** Theoretical DoS on `claimAll()` if `totalXomOutstanding` accounting drifts. Individual `claim()` calls remain available as fallback.

**Recommendation:**

Acceptable as-is. The batch pattern is more gas-efficient and `claim()` is available as a single-bond fallback. No code change needed.

---

### [I-03] `updateBondTerms()` Accepts `dailyCapacity = 0` Without Event Differentiation

**Severity:** Informational
**Lines:** 472-502

**Description:**

When `updateBondTerms()` sets `dailyCapacity = 0`, the `BondTermsUpdated` event is emitted with `dailyCapacity = 0`, but there is no distinct event or log to indicate that the asset is effectively disabled via zero capacity (as opposed to a terms update). Off-chain monitoring systems would need to specifically check for zero capacity as a special case.

**Impact:** Monitoring and alerting complexity. No security impact.

**Recommendation:**

If zero capacity is a valid use case, consider emitting `BondAssetEnabledChanged(asset, false)` when capacity is set to zero. Otherwise, enforce `dailyCapacity > 0` (see L-02).

---

## Round 6 Previously Identified Findings -- Current Status

| ID | Round | Severity | Title | Current Status |
|----|-------|----------|-------|----------------|
| H-01 | R6 | High | Single-step `Ownable` ownership transfer | **FIXED** -- Now uses `Ownable2Step` with `renounceOwnership()` override |
| M-01 | R6 | Medium | `withdrawXom()` underflow on `balance < totalXomOutstanding` | **FIXED** -- Safe check at line 815 |
| M-02 | R6 | Medium | Front-running `setXomPrice()` | **DOCUMENTED** -- Pause-update-unpause procedure in NatSpec |
| L-01 | R6 | Low | `_normalizeToPrice()` precision loss for `decimals > 18` | **ACCEPTED** -- Mitigated by `xomOwed == 0` check |
| L-02 | R6 | Low | `claimAll()` batch decrement | **DOWNGRADED** to I-02 -- Acceptable with `nonReentrant` |
| L-03 | R6 | Low | `PRICE_COOLDOWN` bypass on first call | **UNCHANGED** -- Carried forward as L-03 |
| L-04 | R6 | Low | `bond()` sends assets directly to treasury | **ACCEPTED** -- Design decision |
| I-01 | R6 | Info | Dead `priceOracle` code | **UNCHANGED** -- Carried forward as I-01 |
| I-02 | R6 | Info | `ActiveBondExists` prevents re-bonding | **ACCEPTED** -- Intentional design |
| I-03 | R6 | Info | Event indexing uses numeric values | **ACCEPTED** |

---

## Access Control Map

| Function | Modifier(s) | Caller | Notes |
|----------|-------------|--------|-------|
| `addBondAsset()` | `onlyOwner` | Admin | Adds new bond asset. MAX_BOND_ASSETS = 50 |
| `updateBondTerms()` | `onlyOwner` | Admin | Updates discount, vesting, capacity |
| `setBondAssetEnabled()` | `onlyOwner` | Admin | Enable/disable bonding for asset |
| `bond()` | `nonReentrant`, `whenNotPaused` | User | Creates bond position |
| `claim()` | `nonReentrant` | User | Claims vested XOM (works while paused) |
| `claimAll()` | `nonReentrant` | User | Claims all vested XOM (works while paused) |
| `setXomPrice()` | `onlyOwner` | Admin | Price bounds + 10% rate limit + 6h cooldown |
| `setTreasury()` | `onlyOwner` | Admin | Rejects zero and self-reference |
| `setPriceOracle()` | `onlyOwner` | Admin | Sets oracle (currently unused) |
| `depositXom()` | `onlyOwner` | Admin | Funds contract with XOM |
| `withdrawXom()` | `onlyOwner` | Admin | Excess-only withdrawal above obligations |
| `pause()` | `onlyOwner` | Admin | Pauses `bond()` only |
| `unpause()` | `onlyOwner` | Admin | Resumes bonding |
| `rescueToken()` | `onlyOwner` | Admin | Non-XOM tokens only |
| `renounceOwnership()` | `public pure` | Anyone | Always reverts |
| `transferOwnership()` | `onlyOwner` (inherited) | Admin | Two-step via Ownable2Step |
| `acceptOwnership()` | pendingOwner (inherited) | New Owner | Completes two-step transfer |

**Assessment:** All state-changing functions have appropriate access control. User-facing functions (`bond`, `claim`, `claimAll`) correctly use `_msgSender()` for ERC-2771 compatibility. Admin functions use `onlyOwner`. The `whenNotPaused` modifier is applied only to `bond()`, allowing users to always claim their vested tokens.

---

## Economic Invariant Analysis

### Solvency Invariant

**Invariant:** `XOM.balanceOf(address(this)) >= totalXomOutstanding`

**Maintained by:**
- `bond()`: Checks invariant before incrementing `totalXomOutstanding` (line 571-576)
- `claim()`: Decrements `totalXomOutstanding` before transferring XOM (line 633)
- `claimAll()`: Decrements `totalXomOutstanding` before batch transfer (line 687)
- `withdrawXom()`: Only withdraws excess above `totalXomOutstanding` (lines 815-819)
- `depositXom()`: Increases XOM balance (no effect on `totalXomOutstanding`)
- `rescueToken()`: Blocked for XOM (line 855), prevents solvency violation

**Conclusion:** The invariant is correctly maintained across all code paths. No path exists to reduce XOM balance below outstanding obligations.

### Bonding Math Verification

**Formula:** `xomOwed = (assetValue * 1e18) / discountedPrice`

At boundary conditions:
- MIN_XOM_PRICE ($0.0001) + MAX_DISCOUNT (15%): 1 USDC yields ~11.76T XOM (bounded by solvency check)
- MAX_XOM_PRICE ($100) + MIN_DISCOUNT (5%): 1 USDC yields ~0.0105 XOM
- No overflow risk: `assetValue` (max ~1e42 for 1M USDC at 18 decimals) * 1e18 = 1e60, well within uint256 range (1e77)
- Division truncation: Sub-wei precision loss, negligible

### Flash Loan Analysis

**Not viable.** Flash loans require same-block repayment. Bond vesting is 1-30 days minimum. An attacker cannot claim bonded XOM within the same block to repay a flash loan.

### Front-Running Analysis

**Mitigated operationally.** The documented pause-update-unpause procedure (NatSpec lines 708-712) eliminates the front-running window for `setXomPrice()`. No on-chain price impact from individual `bond()` operations (fixed price, not demand-responsive).

---

## Gas Optimization Notes

The contract is already well-optimized:
- Custom errors instead of require strings (saves ~50 gas per revert)
- BondTerms struct packing: `asset` (20) + `enabled` (1) + `decimals` (1) in first slot
- `++i` in loops instead of `i++` (saves ~5 gas per iteration)
- Bond deletion on full claim (gas refund via storage clearing)
- Batch `claimAll()` with single transfer instead of per-bond transfers

No significant gas optimization opportunities remain.

---

## Severity Summary

| Severity | Count | IDs |
|----------|-------|-----|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 2 | M-01, M-02 |
| Low | 3 | L-01, L-02, L-03 |
| Informational | 3 | I-01, I-02, I-03 |

---

## Overall Risk Assessment

**Risk Level:** LOW

OmniBonding is a mature, well-audited contract in its fourth review cycle. All previous High and Medium findings have been remediated or documented with operational mitigations. The two new Medium findings (M-01: XOM as bond asset, M-02: `msg.sender` in `depositXom`) are straightforward one-line fixes with no impact on existing functionality.

The contract's core security properties are strong:
- **Solvency invariant** is robustly maintained across all code paths
- **Reentrancy protection** via `nonReentrant` on all user-facing state-changing functions
- **Two-step ownership** prevents accidental ownership loss
- **Triple-layer price controls** limit owner manipulation to ~10% per 6 hours
- **Daily capacity limits** prevent large-scale bonding manipulation
- **Pause/unpause** provides emergency halt capability while preserving user claim rights

**Deployment Readiness:** CONDITIONALLY APPROVED

Required before mainnet:
- M-01: Add `if (asset == address(XOM)) revert InvalidParameters()` to `addBondAsset()` (1 line)
- M-02: Replace `msg.sender` with `_msgSender()` in `depositXom()` (2 lines)

Recommended but not blocking:
- L-02: Add `if (dailyCapacity == 0) revert InvalidParameters()` validation
- I-01: Remove or integrate dead `priceOracle` code

---

*Audit conducted 2026-03-13 20:45 UTC by Claude Code Audit Agent*
*Contract hash: SHA-256 of OmniBonding.sol at time of audit*
*Test suite: 118/118 passing (100%)*
