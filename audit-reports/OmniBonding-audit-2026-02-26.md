# Security Audit Report: OmniBonding (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/liquidity/OmniBonding.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 906
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds XOM for bond distribution, receives bonded assets via treasury)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** IERC20, SafeERC20, ReentrancyGuard, Ownable, Pausable (all OZ v5.4.0)
**Deployment:** Fuji testnet at `0x1F976D7F01a31Fd6A1afd3508BfC562D778404Dd` (chain 131313)
**Test Coverage:** No dedicated test file found
**Previous Audit:** Round 1 (2026-02-21) -- 1 Critical, 3 High, 3 Medium, 3 Low, 3 Info

---

## Executive Summary

OmniBonding is an Olympus DAO-inspired Protocol Owned Liquidity contract where users deposit stablecoin assets (USDC, USDT, DAI) and receive discounted XOM with linear vesting (1-30 days). The protocol permanently owns the bonded assets. The contract uses OpenZeppelin's ReentrancyGuard, Ownable, Pausable, and SafeERC20. It features multi-asset bonding with configurable discount rates (5-15%), daily capacity limits per asset, and a fixed-price oracle with bounds and rate-of-change limits.

**Round 1 Remediation Status:** All Critical and High findings from Round 1 have been remediated:

| Round 1 Finding | Status | Evidence |
|-----------------|--------|----------|
| C-01: Fractional-reserve insolvency | **FIXED** | `totalXomOutstanding` tracker added (lines 143-146); solvency check at line 446-450 uses `totalXomOutstanding + xomOwed` |
| H-01: Owner rug pull via withdrawXom | **FIXED** | `withdrawXom()` (lines 632-638) now computes `excess = balance - totalXomOutstanding` and rejects over-withdrawals |
| H-02: Unconstrained price manipulation | **FIXED** | `setXomPrice()` (lines 574-592) enforces `MIN_XOM_PRICE`/`MAX_XOM_PRICE` bounds and `MAX_PRICE_CHANGE_BPS` (10%) rate limit |
| H-03: $1/unit pricing assumption | **MITIGATED** | Contract header, `_normalizeToPrice()` NatSpec, and function documentation now explicitly warn against adding non-stablecoin assets. Not a code fix but an operational safeguard. |
| M-01: Unbounded claimAll loop | **FIXED** | `MAX_BOND_ASSETS = 50` constant enforced in `addBondAsset()` (line 300) |
| M-02: Fee-on-transfer accounting | **FIXED** | Balance-delta pattern in `bond()` (lines 453-461) with `TransferAmountMismatch` revert |
| M-03: Stale bond struct | **FIXED** | `delete userBonds[msg.sender][asset]` in both `claim()` (line 511) and `claimAll()` (line 548) |
| L-01: Daily capacity midnight | **ACCEPTED** | Documented as expected behavior |
| L-02: No minimum bond amount | **FIXED** | Zero-amount rejection at line 413; zero-XOM-output rejection at line 441 |
| L-03: No decimals validation | **FIXED** | `decimals > 24` check at line 319 |
| I-01: Dead priceOracle code | **PARTIAL** | `priceOracle` and `setPriceOracle()` still exist as dead code (not integrated into `getXomPrice()`) |
| I-02: bondAssets array pruning | **MITIGATED** | `MAX_BOND_ASSETS = 50` caps growth but still no removal mechanism |
| I-03: Questionable event indexing | **NOT FIXED** | `xomOwed` still indexed in `BondCreated`; `amount` indexed in `BondClaimed`; `discountBps` and `vestingPeriod` indexed in `BondTermsUpdated` |

This Round 3 audit re-evaluates the entire contract from scratch using the full 6-pass methodology. The contract is significantly improved since Round 1. The audit found **0 Critical**, **0 High**, **3 Medium**, **4 Low**, and **4 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Informational | 4 |

---

## Architecture Analysis

### Design Strengths

1. **Solvency Accounting:** The `totalXomOutstanding` tracker (added since Round 1) correctly maintains an invariant: `XOM.balanceOf(address(this)) >= totalXomOutstanding` at all times. This is enforced in `bond()` (creation) and maintained by `claim()`/`claimAll()` (decrement) and `withdrawXom()` (excess-only withdrawal). This is a robust pattern.

2. **Price Change Bounds:** `setXomPrice()` now enforces absolute bounds (`MIN_XOM_PRICE` = $0.0001, `MAX_XOM_PRICE` = $100) and rate-of-change limits (`MAX_PRICE_CHANGE_BPS` = 10% per call). This significantly reduces the owner's ability to manipulate bond pricing.

3. **Fee-on-Transfer Protection:** The balance-delta pattern in `bond()` rejects tokens where the received amount differs from the sent amount, preventing accounting discrepancies.

4. **Storage Cleanup:** Fully-claimed bonds are deleted, freeing storage and allowing users to re-bond the same asset without friction.

5. **Custom Errors:** Gas-efficient error handling throughout with descriptive error types including parameters where useful (`PriceChangeExceedsLimit`, `PriceOutOfBounds`).

6. **SafeERC20 Usage:** All ERC20 interactions use SafeERC20 wrappers, preventing silent transfer failures.

7. **NatSpec Quality:** Comprehensive documentation on all public and internal functions, state variables, events, errors, and structs. The `_normalizeToPrice()` documentation explicitly warns about the stablecoin-only assumption.

### Dependency Analysis

- **OpenZeppelin 5.4.0:** All inherited contracts (ReentrancyGuard, Ownable, Pausable, SafeERC20) are from the latest stable OZ v5 release. The `Ownable(msg.sender)` constructor call is the correct OZ v5 pattern.

- **No Upgradeability:** The contract is not upgradeable. This is appropriate for a bonding contract since users need assurance that terms cannot be arbitrarily changed by a proxy upgrade. However, it means bugs require redeployment and migration.

---

## Pass 1: Static Analysis (solhint)

```
npx solhint contracts/liquidity/OmniBonding.sol
```

**Result:** 0 errors, 0 warnings (excluding 2 non-existent rule warnings for `contract-name-camelcase` and `event-name-camelcase` from `.solhint.json` config).

All `not-rely-on-time` instances have appropriate `solhint-disable-line` comments with correct business justification (vesting period calculations, daily capacity resets).

All `gas-strict-inequalities` instances have appropriate disable comments.

---

## Pass 2: OWASP Smart Contract Top 10 Analysis

### SC01 -- Reentrancy

**Status: SAFE**

All state-mutating external functions (`bond()`, `claim()`, `claimAll()`) are protected by `nonReentrant`. State updates occur before external calls (SafeERC20 transfers). The checks-effects-interactions pattern is correctly followed:

- `bond()`: Validates, calculates, checks solvency, transfers asset (external call), then updates state. **Note:** The `safeTransferFrom` to treasury (line 455) occurs *before* state updates (lines 476-481). However, this is acceptable because (a) `nonReentrant` prevents re-entry, and (b) the solvency check (line 446) uses the *pre-transfer* XOM balance, which is conservative -- a re-entrant call would see the same or higher balance.

- `claim()`: Updates `userBond.claimed` and `totalXomOutstanding` *before* `XOM.safeTransfer()` (line 514). Correct CEI.

- `claimAll()`: Updates all bond structs in the loop *before* the single `XOM.safeTransfer()` at line 560. Correct CEI.

### SC02 -- Access Control

**Status: ADEQUATE with observations**

Owner-only functions: `addBondAsset`, `updateBondTerms`, `setBondAssetEnabled`, `setXomPrice`, `setTreasury`, `setPriceOracle`, `depositXom`, `withdrawXom`, `pause`, `unpause`.

The contract uses single-owner access control (`Ownable`). For a production bonding contract handling significant value, a multisig or timelock would be preferable, but this is a deployment-pattern concern rather than a contract bug. See M-01.

### SC03 -- Arithmetic

**Status: SAFE**

Solidity 0.8.24 provides built-in overflow/underflow protection. Key arithmetic operations:

- `discountedPrice = (xomPrice * (BASIS_POINTS - terms.discountBps)) / BASIS_POINTS` (line 434-436): Safe because `discountBps <= MAX_DISCOUNT_BPS = 1500 < BASIS_POINTS = 10000`, so the subtraction never underflows.

- `xomOwed = (assetValue * PRICE_PRECISION) / discountedPrice` (line 437-438): `PRICE_PRECISION = 1e18`. The maximum `assetValue` for a stablecoin bond is bounded by `dailyCapacity` (admin-set). With 18-decimal normalization and 1e18 precision, this is safe for any realistic amounts.

- `excess = balance - totalXomOutstanding` (line 634): Safe because `balance >= totalXomOutstanding` is an invariant maintained by `bond()`. If a bug violates this invariant, the subtraction reverts, which is the correct failure mode.

- Linear vesting: `vested = (userBond.xomOwed * elapsed) / vestingDuration` (line 872): Safe. `elapsed <= vestingDuration` (enforced by the `block.timestamp >= vestingEnd` early return). `xomOwed * elapsed` could theoretically overflow for extremely large XOM amounts with long elapsed times, but with 18-decimal tokens and realistic amounts (<10^28 wei), the product stays well within uint256 range.

### SC04 -- Denial of Service

**Status: ADEQUATE**

- `claimAll()` bounded by `MAX_BOND_ASSETS = 50`. Each iteration: 1 SLOAD for `userBond`, 1 view call `_calculateClaimable`. Worst case: 50 * ~5,000 gas = 250,000 gas. Well within block limits.

- `getBondAssets()` returns the full array. With 50 max elements, this is fine for view calls.

- No external callback patterns that could be used for griefing.

### SC05 -- Gas Limit Vulnerabilities

**Status: SAFE** -- Addressed above under SC04.

### SC06 -- Unchecked External Calls

**Status: SAFE** -- All external calls use SafeERC20 which reverts on failure.

### SC07 -- Front-Running

**Status: OBSERVATION** -- See M-02.

### SC08 -- Integer Overflow/Underflow

**Status: SAFE** -- Solidity 0.8.24 checked arithmetic.

### SC09 -- Insecure Randomness

**Status: N/A** -- No randomness used.

### SC10 -- Centralization Risks

**Status: OBSERVATION** -- See M-01.

---

## Pass 3: Business Logic & Economic Analysis

### Bond Pricing Model

The XOM price is owner-set with bounds ($0.0001 to $100) and rate-of-change limits (10% per call). The discount is applied as: `effectivePrice = xomPrice * (10000 - discountBps) / 10000`. With `discountBps` in [500, 1500], the effective price is [85%, 95%] of the stated XOM price.

**Economic Risk:** The 10% rate-of-change limit per call (`MAX_PRICE_CHANGE_BPS = 1000`) has no cooldown. An owner can make 10 sequential calls to `setXomPrice()` in a single transaction (via a batch contract), changing the price by up to ~(0.9^10 or 1.1^10) = ~65% decrease or ~159% increase. See M-02.

### Vesting Model

Linear vesting from `vestingStart` to `vestingEnd` with proper `claimed` tracking. The formula `vested = (xomOwed * elapsed) / vestingDuration` is standard and correct. Edge case: if `vestingStart == vestingEnd` (zero-duration vesting), division by zero would occur, but this is prevented by `MIN_VESTING_PERIOD = 1 days`.

### Daily Capacity

The midnight-boundary reset (daily capacity resets at `block.timestamp / 1 days` boundary) is documented and accepted. A user can bond up to `2 * dailyCapacity` across the boundary, which is a known and accepted property.

### Solvency Invariant

The invariant `XOM.balanceOf(address(this)) >= totalXomOutstanding` is maintained by:
1. `bond()` checks `balance >= totalXomOutstanding + xomOwed` before incrementing `totalXomOutstanding`
2. `claim()` decrements `totalXomOutstanding` by `claimed` amount
3. `claimAll()` decrements `totalXomOutstanding` by `totalClaimed`
4. `withdrawXom()` only allows withdrawal of `balance - totalXomOutstanding`
5. `depositXom()` increases balance without changing `totalXomOutstanding`

**Potential violation:** If XOM implements a fee-on-transfer or deflationary mechanism, `depositXom()` would receive fewer tokens than expected, and the balance could fall below `totalXomOutstanding`. However, XOM (OmniCoin.sol) is a standard ERC20 without fee-on-transfer, so this is not a practical concern for the current deployment. See L-01.

---

## Pass 4: Edge Case & Adversarial Analysis

### Scenario 1: Bond With Rebase/Elastic Token

If a rebase token (like OHM or AMPL) is added as a bond asset, the daily capacity tracking (`dailyBonded`) would be based on pre-rebase amounts. The fee-on-transfer check (balance-delta) would catch negative rebases during transfer but not positive ones. However, the contract's NatSpec explicitly restricts usage to stablecoins, and the owner controls which assets are added. **No code fix needed; operational safeguard is sufficient.**

### Scenario 2: Concurrent Bonds on Same Asset

The `ActiveBondExists` check (lines 420-427) correctly prevents a user from creating a second bond on the same asset while an active bond exists. After full claim and struct deletion (M-03 fix), the user can re-bond. **Working correctly.**

### Scenario 3: Claim After Contract Pause

`claim()` and `claimAll()` are NOT protected by `whenNotPaused`. This is **correct behavior** -- users should always be able to claim vested tokens even when bonding is paused. Only `bond()` is pausable. **Good design.**

### Scenario 4: Treasury Set to Zero Address

`setTreasury()` correctly rejects `address(0)`. However, there is no check that the treasury is not set to `address(this)` (the bonding contract itself). If the treasury is set to the bonding contract, `bond()` would transfer assets from the user to the bonding contract, and the asset balance increase would not be tracked. The solvency check uses XOM balance only, so this does not affect solvency, but it creates an accounting discrepancy where `totalAssetReceived` counts assets that are stuck in the contract. See L-02.

### Scenario 5: XOM Token With Blocklist

If the XOM token implements a blocklist (like USDC) and the bonding contract is blocklisted, all `claim()` calls would revert. The `totalXomOutstanding` would be permanently stuck. However, XOM (OmniCoin.sol) does not have a blocklist. **No code fix needed for current deployment.**

### Scenario 6: `deleteUserBond` Race in `claimAll()`

In `claimAll()`, the loop modifies `userBonds[msg.sender][asset]` via `delete` inside the iteration (line 548). This is safe because the loop iterates over `bondAssets[]` (a separate storage array), not over `userBonds`. The `delete` only affects the mapping entry, not the loop index or bounds. **Safe.**

### Scenario 7: Precision Loss in Small Bonds

A user bonds 1 wei of a 6-decimal token (e.g., USDC). `_normalizeToPrice(1, 6)` returns `1e12`. With XOM price of 5e15 ($0.005) and 10% discount: `discountedPrice = 5e15 * 8500 / 10000 = 4.25e15`. `xomOwed = 1e12 * 1e18 / 4.25e15 = 235`. This produces 235 wei of XOM, which is non-zero and passes the L-02 check. The actual value is negligible ($0.000000000000000235). This is harmless -- the gas cost of the transaction far exceeds the bond value. **No fix needed.**

---

## Findings

### [M-01] Single-Owner Centralization -- No Timelock or Multisig Protection

**Severity:** Medium
**Lines:** 35 (Ownable), 574, 598, 609, 622, 632, 643, 650, 291, 352, 389
**Category:** Centralization / Trust Model

**Description:**

The contract uses OpenZeppelin's `Ownable` with a single EOA as owner. The owner has the following powers:

1. **Set XOM price** (bounded by 10% per call, but no cooldown between calls)
2. **Add/update/disable bond assets** (can change discount, vesting period, daily capacity)
3. **Change treasury address** (redirect all bonded asset inflows)
4. **Withdraw excess XOM** (excess above outstanding obligations)
5. **Pause/unpause bonding** (DoS new bonds)
6. **Deposit XOM** (permissionless to fund, but owner-only)

While each individual power is bounded (price limits, solvency checks), the combination of these powers in a single key creates operational risk. If the owner key is compromised, the attacker can:

- Redirect treasury to their own address
- Set XOM price to minimum ($0.0001), creating extremely favorable bonds
- Bond assets at massive discount
- Change treasury back and withdraw excess XOM

The `setXomPrice` bounds and rate limits provide some protection, but with no cooldown, multiple calls in one transaction can achieve large price changes.

**Impact:** Single point of failure for all administrative operations. Key compromise enables value extraction within the bounded parameters.

**Recommendation:** Transfer ownership to a multisig (Gnosis Safe) or timelock controller before mainnet deployment. For the timelock approach:

```solidity
// After deployment:
bonding.transferOwnership(timelockAddress);
```

At minimum, add a cooldown to `setXomPrice()`:

```solidity
uint256 public lastPriceUpdate;
uint256 public constant PRICE_UPDATE_COOLDOWN = 1 hours;

function setXomPrice(uint256 newPrice) external onlyOwner {
    if (block.timestamp < lastPriceUpdate + PRICE_UPDATE_COOLDOWN) {
        revert PriceUpdateTooSoon();
    }
    // ... existing bounds checks ...
    lastPriceUpdate = block.timestamp;
    fixedXomPrice = newPrice;
}
```

---

### [M-02] No Cooldown on Price Updates -- Multi-Call Price Manipulation Within Bounds

**Severity:** Medium
**Lines:** 574-592
**Category:** Economic Security

**Description:**

`setXomPrice()` enforces a maximum change of `MAX_PRICE_CHANGE_BPS = 1000` (10%) per call, but there is no cooldown between calls. An owner (or compromised key, or owner-controlled batch contract) can invoke `setXomPrice()` multiple times in a single transaction or across multiple transactions in the same block.

**Proof of Concept:**

Starting price: $0.005 (5e15)

```
Call 1: 5e15 * 0.9 = 4.5e15  (10% decrease)
Call 2: 4.5e15 * 0.9 = 4.05e15
Call 3: 4.05e15 * 0.9 = 3.645e15
...
Call 10: ~1.743e15 (~65% total decrease)
```

After 10 calls: price drops from $0.005 to ~$0.00174. A bonder at this price receives ~2.87x more XOM than at the original price. The owner can then reverse the price with 10 more calls.

While the absolute bounds (`MIN_XOM_PRICE = 1e14`, `MAX_XOM_PRICE = 100e18`) prevent catastrophic manipulation, they still allow a 1000x range between min and max.

**Impact:** Owner can effectively front-run bonders by lowering price before their own bond and raising it after, or vice versa to disadvantage users. The 10% per-call limit only creates a minor inconvenience (10 calls instead of 1).

**Recommendation:** Add a per-update cooldown:

```solidity
uint256 public lastPriceUpdateTime;
uint256 public constant PRICE_COOLDOWN = 6 hours;

function setXomPrice(uint256 newPrice) external onlyOwner {
    if (block.timestamp < lastPriceUpdateTime + PRICE_COOLDOWN) {
        revert PriceCooldownActive();
    }
    // ... existing checks ...
    lastPriceUpdateTime = block.timestamp;
    fixedXomPrice = newPrice;
}
```

This limits effective price change to ~10% per 6 hours, making manipulation impractical for front-running individual bonds.

---

### [M-03] Missing `setBondAssetEnabled` Event Emission

**Severity:** Medium
**Lines:** 389-398
**Category:** Monitoring / Off-Chain Integration

**Description:**

`setBondAssetEnabled()` changes the `enabled` flag on a bond asset but emits no event. This is the only admin state-change function that is silent. All other admin functions emit events (`BondTermsUpdated`, `BondAssetAdded`, `XomPriceUpdated`, `XomWithdrawn`).

The lack of an event means:
1. Off-chain monitoring systems cannot detect when an asset is enabled or disabled.
2. The frontend/Validator cannot reactively update the UI when bond availability changes.
3. Audit trails for admin actions have a gap.

**Impact:** No on-chain record of asset enable/disable actions. Operational monitoring blind spot.

**Recommendation:** Emit an event:

```solidity
/// @notice Emitted when a bond asset is enabled or disabled
/// @param asset Asset address
/// @param enabled New enabled state
event BondAssetEnabledChanged(
    address indexed asset,
    bool indexed enabled
);

function setBondAssetEnabled(
    address asset,
    bool enabled
) external onlyOwner {
    BondTerms storage terms = bondTerms[asset];
    if (address(terms.asset) == address(0)) {
        revert AssetNotSupported();
    }
    terms.enabled = enabled;
    emit BondAssetEnabledChanged(asset, enabled);
}
```

---

### [L-01] `depositXom()` Does Not Verify Actual Received Amount

**Severity:** Low
**Lines:** 622-624
**Category:** Accounting Integrity

**Description:**

`depositXom()` uses `XOM.safeTransferFrom(msg.sender, address(this), amount)` without a balance-delta check. If XOM were to implement fee-on-transfer in the future, the contract would receive fewer tokens than `amount`, potentially violating the solvency invariant `balanceOf(this) >= totalXomOutstanding`.

The `bond()` function correctly uses the balance-delta pattern for bonded assets (M-02 Round 1 fix), but `depositXom()` does not apply the same pattern.

Currently, XOM (OmniCoin.sol) is a standard ERC20 without fee-on-transfer, so this is not an active vulnerability.

**Impact:** If XOM is ever upgraded to include transfer fees (unlikely), the solvency invariant could be silently violated. Subsequent `bond()` calls would correctly fail the solvency check, so user funds are not at risk, but the contract would become unable to accept new bonds until additional XOM is deposited.

**Recommendation:** Add a balance-delta check for consistency:

```solidity
function depositXom(uint256 amount) external onlyOwner {
    uint256 balBefore = XOM.balanceOf(address(this));
    XOM.safeTransferFrom(msg.sender, address(this), amount);
    uint256 actualReceived = XOM.balanceOf(address(this)) - balBefore;
    if (actualReceived != amount) revert TransferAmountMismatch();
}
```

---

### [L-02] Treasury Can Be Set to the Bonding Contract Address

**Severity:** Low
**Lines:** 598-603
**Category:** Input Validation

**Description:**

`setTreasury()` validates against `address(0)` but does not prevent setting treasury to `address(this)`. If the treasury is set to the bonding contract itself:

1. `bond()` transfers bonded assets from the user to the bonding contract (instead of an external treasury).
2. The bonded assets become trapped in the contract with no withdrawal mechanism (only `withdrawXom()` exists for XOM, not for arbitrary ERC20s).
3. The fee-on-transfer check would pass (the contract receives the full amount).
4. `totalAssetReceived` would be overstated from the protocol's perspective.

**Impact:** Bonded assets become permanently locked in the contract. The owner can correct by calling `setTreasury()` again, but assets already transferred to `address(this)` would require a contract upgrade (impossible for a non-upgradeable contract) or a rescue function to recover.

**Recommendation:** Add a self-reference check:

```solidity
function setTreasury(address _treasury) external onlyOwner {
    if (_treasury == address(0)) revert InvalidParameters();
    if (_treasury == address(this)) revert InvalidParameters();
    treasury = _treasury;
}
```

---

### [L-03] `priceOracle` and `setPriceOracle()` Remain as Dead Code

**Severity:** Low
**Lines:** 123-124, 609-616
**Category:** Code Quality / Maintenance

**Description:**

Carried forward from Round 1 (I-01). The `priceOracle` state variable and `setPriceOracle()` function exist but are never referenced by `getXomPrice()`, which returns only `fixedXomPrice`. This dead code:

1. Increases deployment cost (~20,000 gas for the storage slot, ~5,000 gas for the function bytecode).
2. Creates false expectations -- a developer reading the code might assume the oracle is active.
3. The `setPriceOracle()` function validates against `address(0)` but nothing else. There is no interface verification (no `supportsInterface` or trial call).

**Impact:** No security impact. Operational confusion and wasted deployment gas.

**Recommendation:** Either:

(a) Remove `priceOracle` and `setPriceOracle()` entirely until the oracle integration is ready, or

(b) Implement the oracle integration in `getXomPrice()`:

```solidity
function getXomPrice() public view returns (uint256 price) {
    if (priceOracle != address(0)) {
        // Query oracle
        return IPriceOracle(priceOracle).getPrice(address(XOM));
    }
    return fixedXomPrice;
}
```

---

### [L-04] No Emergency Rescue Function for Non-XOM Tokens Sent Directly

**Severity:** Low
**Lines:** Contract-wide
**Category:** Fund Recovery

**Description:**

If a user accidentally sends ERC20 tokens (other than XOM) directly to the contract via `transfer()` (bypassing `bond()`), those tokens are permanently locked. The contract has:

- `withdrawXom()` for XOM (owner-only, excess only)
- No function for recovering other ERC20s
- No `receive()` or `fallback()` for native tokens (good -- prevents accidental ETH/AVAX sends)

For bonded assets, the transfer goes to `treasury` (not the contract), so accidental ERC20 sends to the bonding contract are not a normal flow. However, mistakes happen.

**Impact:** Any ERC20 tokens accidentally sent to the contract are permanently lost. This is common across DeFi contracts but avoidable.

**Recommendation:** Add a rescue function restricted to non-XOM tokens:

```solidity
/// @notice Rescue accidentally sent ERC20 tokens (not XOM)
/// @param token Token to rescue
/// @param amount Amount to rescue
function rescueToken(
    address token,
    uint256 amount
) external onlyOwner {
    if (token == address(XOM)) revert InvalidParameters();
    IERC20(token).safeTransfer(treasury, amount);
}
```

---

### [I-01] Questionable Event Indexing Choices

**Severity:** Informational
**Lines:** 156-162, 168-172, 179-184
**Category:** Gas Optimization / Log Usability

**Description:**

Carried forward from Round 1 (I-03). Several events index continuous `uint256` values that are impractical to filter on:

- `BondCreated`: `xomOwed` indexed (line 160) -- filtering by exact XOM amount is useless. `user` and `asset` are appropriately indexed.

- `BondClaimed`: `amount` indexed (line 172) -- same issue. Should index `user` and `asset` (already done) but not `amount`.

- `BondTermsUpdated`: `discountBps` (line 181) and `vestingPeriod` (line 182) are indexed. These are small-range values where indexing has marginal utility. `dailyCapacity` is not indexed (correct). `asset` is appropriately indexed.

Each unnecessary `indexed` keyword costs ~375 gas per event emission and wastes one of the 3 available topic slots.

**Impact:** Minor gas waste. Does not affect security.

**Recommendation:** Remove `indexed` from:
- `BondCreated.xomOwed`
- `BondClaimed.amount`
- `BondTermsUpdated.discountBps`
- `BondTermsUpdated.vestingPeriod`

---

### [I-02] `bondAssets` Array Remains Append-Only -- No Removal Mechanism

**Severity:** Informational
**Lines:** 135, 337
**Category:** Code Maintenance

**Description:**

Carried forward from Round 1 (I-02). `bondAssets` can only grow (via `addBondAsset()`). Disabled assets remain in the array. While `MAX_BOND_ASSETS = 50` caps growth, disabled assets increase gas costs for `claimAll()` and `getBondAssets()` without providing value.

With 50 max assets and realistic usage (3-5 stablecoins), this is unlikely to be a problem. However, if assets are added and disabled over time, the effective set shrinks while the array size does not.

**Impact:** Minor gas inefficiency for `claimAll()` and view functions when disabled assets accumulate.

**Recommendation:** Consider adding a swap-and-pop removal function for disabled assets with no outstanding obligations:

```solidity
function removeBondAsset(address asset) external onlyOwner {
    // Verify no outstanding bonds exist for this asset
    // (requires iterating users or tracking per-asset outstanding)
    // Remove from bondAssets array via swap-and-pop
}
```

Given the complexity of tracking per-asset obligations across all users, the current approach (cap at 50, accept gas overhead) is a reasonable tradeoff.

---

### [I-03] Constructor Does Not Validate `_initialXomPrice` Against Bounds

**Severity:** Informational
**Lines:** 265-278
**Category:** Input Validation Consistency

**Description:**

The constructor validates that `_initialXomPrice != 0` but does not enforce the same bounds that `setXomPrice()` requires (`MIN_XOM_PRICE` to `MAX_XOM_PRICE`). The contract can be deployed with an initial price outside the operational bounds (e.g., $0.00000001 or $10,000).

After deployment, the owner would need to incrementally move the price toward the valid range via multiple `setXomPrice()` calls (limited by `MAX_PRICE_CHANGE_BPS` per call), which could take many transactions.

**Impact:** Deployment misconfiguration. No security impact since `bond()` would still work (or fail) based on the actual price value, and `setXomPrice()` can correct the price over time.

**Recommendation:** Add bounds validation in the constructor:

```solidity
if (
    _initialXomPrice < MIN_XOM_PRICE
        || _initialXomPrice > MAX_XOM_PRICE
) {
    revert PriceOutOfBounds(_initialXomPrice);
}
```

---

### [I-04] `totalXomDistributed` and `totalValueReceived` Monotonically Increase With No Getter Aggregation

**Severity:** Informational
**Lines:** 138-141, 479-480
**Category:** Analytics / Observability

**Description:**

`totalXomDistributed` and `totalValueReceived` are global counters that only increase. They track lifetime totals, not current obligations. While useful for analytics, they cannot be used to derive the contract's current state. For current obligations, `totalXomOutstanding` is the correct metric.

Additionally, per-asset totals (`terms.totalXomDistributed`, `terms.totalAssetReceived`) are tracked in `BondTerms` but there is no aggregation view function that returns totals for all assets in a single call. Frontend/backend consumers must iterate `getBondAssets()` and query each individually.

**Impact:** No security impact. Minor inconvenience for off-chain consumers.

**Recommendation:** Consider adding a summary view function:

```solidity
function getProtocolStats()
    external
    view
    returns (
        uint256 distributed,
        uint256 outstanding,
        uint256 valueReceived,
        uint256 assetCount
    )
{
    return (
        totalXomDistributed,
        totalXomOutstanding,
        totalValueReceived,
        bondAssets.length
    );
}
```

---

## Gas Optimization Notes

1. **Custom errors throughout:** Good -- saves ~200 gas per revert vs. require strings.
2. **SafeERC20:** Adds ~2,000 gas per transfer but is essential for non-compliant ERC20s.
3. **Struct packing in BondTerms:** `asset` (address, 20 bytes) + `enabled` (bool, 1 byte) + `decimals` (uint8, 1 byte) = 22 bytes, fits in one slot. The remaining fields are full-slot uint256s. This is optimal for the current struct layout.
4. **`++i` prefix increment in claimAll loop:** Used correctly (line 531).
5. **Storage pointer pattern:** `BondTerms storage terms = bondTerms[asset]` avoids memory copy -- good.
6. **Single transfer in claimAll:** Instead of transferring XOM per-asset, `claimAll()` accumulates `totalClaimed` and does one `safeTransfer` at the end (line 560). This saves ~30,000 gas per additional asset claimed.
7. **Immutable XOM:** `IERC20 public immutable XOM` avoids SLOAD for the XOM address. Good.

---

## Test Coverage Analysis

**No dedicated test file was found for OmniBonding.** This is a deployment blocker for mainnet. The contract is deployed on Fuji testnet but has no automated test coverage.

**Required Test Cases:**

| Category | Test Case | Priority |
|----------|-----------|----------|
| Core | Bond creation with valid parameters | Critical |
| Core | Claim vested XOM (partial and full) | Critical |
| Core | ClaimAll across multiple assets | Critical |
| Solvency | Solvency check rejects over-committed bonds (C-01 fix) | Critical |
| Solvency | WithdrawXom respects outstanding obligations (H-01 fix) | Critical |
| Price | SetXomPrice respects bounds and rate limit (H-02 fix) | Critical |
| Price | Multiple setXomPrice calls in sequence | High |
| Transfer | Fee-on-transfer rejection (M-02 fix) | High |
| Access | Only owner can call admin functions | High |
| Edge | Zero-amount bond rejection (L-02 fix) | Medium |
| Edge | Zero-XOM-output rejection | Medium |
| Edge | Daily capacity enforcement and reset | Medium |
| Edge | Active bond prevents re-bonding same asset | Medium |
| Edge | Struct cleanup after full claim enables re-bonding | Medium |
| Pause | Bond blocked when paused, claim works when paused | Medium |
| View | calculateBondOutput matches actual bond output | Medium |
| View | getBondTerms returns correct daily remaining | Low |
| Gas | claimAll with MAX_BOND_ASSETS (50) stays under block limit | Low |

---

## Comparison with Industry Standards

| Aspect | OmniBonding | Olympus V2 (BondFixedTermSDA) | Redacted Cartel |
|--------|-------------|-------------------------------|-----------------|
| Pricing | Fixed (owner-set with bounds) | SDA (control variable, decay) | Chainlink oracle |
| Vesting | Linear, 1-30 days | Fixed term or SDA | Fixed term |
| Solvency | `totalXomOutstanding` tracker | Treasury backing | Treasury backing |
| Multi-asset | Yes (up to 50) | Yes (per-market) | Yes |
| Access control | Ownable (single key) | Policy/Guardian roles | Multisig |
| Pause | Pausable | Per-market deactivation | Pausable |
| Fee-on-transfer | Rejected | Not checked | Not checked |
| Price oracle | Fixed (TODO: Chainlink) | On-chain TWAP or oracle | Chainlink |

OmniBonding's solvency tracking is more conservative than Olympus V2 (which relies on treasury backing rather than per-contract obligation tracking). The fixed-price model is simpler but more centralized than SDA or oracle-based pricing.

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Recommendation | Effort |
|---|---------|----------|----------------|--------|
| 1 | M-01 | Medium | Transfer ownership to multisig or timelock before mainnet | Deployment |
| 2 | M-02 | Medium | Add cooldown to `setXomPrice()` (6h suggested) | Small |
| 3 | M-03 | Medium | Emit event in `setBondAssetEnabled()` | Trivial |
| 4 | L-01 | Low | Add balance-delta check to `depositXom()` | Small |
| 5 | L-02 | Low | Reject `treasury == address(this)` in `setTreasury()` | Trivial |
| 6 | L-03 | Low | Remove or implement `priceOracle` / `setPriceOracle()` | Small |
| 7 | L-04 | Low | Add `rescueToken()` for non-XOM ERC20s | Small |
| 8 | I-01 | Info | Remove `indexed` from continuous uint256 event params | Trivial |
| 9 | I-02 | Info | Accept current design (MAX_BOND_ASSETS cap sufficient) | None |
| 10 | I-03 | Info | Validate initial price against bounds in constructor | Trivial |
| 11 | I-04 | Info | Add `getProtocolStats()` view function | Small |
| -- | Tests | **Blocker** | Create comprehensive test suite (see table above) | Large |

---

## Conclusion

OmniBonding has undergone significant improvement since the Round 1 audit. All Critical and High findings have been addressed:

- **Fractional-reserve insolvency (C-01):** Fully fixed with `totalXomOutstanding` tracker and comprehensive solvency accounting.
- **Owner rug pull (H-01):** Fully fixed with obligation-aware withdrawal limits.
- **Price manipulation (H-02):** Substantially mitigated with absolute bounds and per-call rate limits, though the lack of cooldown (M-02 in this report) leaves residual risk.
- **$1/unit assumption (H-03):** Documented as a design constraint with clear NatSpec warnings.

The remaining findings are Medium and Low severity. The most important action items are:

1. **Add a cooldown to price updates (M-02)** to prevent multi-call manipulation within a single block.
2. **Transfer ownership to a multisig (M-01)** before mainnet deployment.
3. **Emit events for all state changes (M-03)** for operational monitoring.
4. **Create a test suite** -- the absence of tests is the single largest risk factor. The contract logic is sound, but untested code should not handle real user funds on mainnet.

**Overall Risk Assessment:** Low-Medium (suitable for continued testnet operation; requires M-01, M-02, and test suite before mainnet)

---

*Report generated 2026-02-26 19:52 UTC*
*Methodology: 6-Pass Enhanced -- (1) Static analysis via solhint, (2) OWASP Smart Contract Top 10, (3) Business Logic & Economic Analysis, (4) Edge Case & Adversarial Analysis, (5) Triage & deduplication, (6) Report generation*
*Round 3 audit against OmniBonding.sol at 906 lines, Solidity 0.8.24, OpenZeppelin 5.4.0*
*Previous audit: Round 1 (2026-02-21) -- all Critical/High findings remediated*
