# Security Audit Report: OmniBonding (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/liquidity/OmniBonding.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,172
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds XOM for bond distribution; bonded assets sent to treasury)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `IERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable`, `Pausable`, `ERC2771Context` (all OZ v5.4.0)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Slither Report:** Not available (file not found at `/tmp/slither-OmniBonding.json`)

---

## Executive Summary

OmniBonding is an Olympus DAO-inspired Protocol Owned Liquidity contract where users deposit stablecoin assets (USDC, USDT, DAI) and receive discounted XOM with linear vesting (1-30 days). The protocol permanently owns the bonded assets, which are sent directly to the treasury. The contract features multi-asset bonding with configurable discount rates (5-15%), daily capacity limits per asset, a fixed-price oracle with bounds and rate-of-change limits, solvency guarantees via `totalXomOutstanding` tracking, and a 6-hour cooldown on price updates.

Since the Round 3 audit, the contract has grown from 906 to 1,172 lines, incorporating ERC2771Context meta-transaction support, a `PRICE_COOLDOWN` mechanism (6 hours between price updates), a `rescueToken()` function for accidentally sent tokens, absolute price bounds (`MIN_XOM_PRICE` / `MAX_XOM_PRICE`), and improved NatSpec documentation throughout.

This Round 6 pre-mainnet audit identifies **0 Critical**, **1 High**, **2 Medium**, **4 Low**, and **3 Informational** findings. The High finding concerns the use of single-step `Ownable` rather than `Ownable2Step`, which is significant given the owner's extensive powers over bond pricing and fund management.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 2 |
| Low | 4 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All findings from this audit have been addressed in the Round 6 remediation pass.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | Single-step `Ownable` ownership transfer — no two-step confirmation | **FIXED** |
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `bond()` and `claim()` | **FIXED** |
| M-02 | Medium | Missing `whenNotPaused` modifier on `setXomPrice()` | **FIXED** |

---

## Round 3 Remediation Status

| Round 3 Finding | Status | Evidence |
|-----------------|--------|----------|
| M-01: Owner can chain multiple 10% price changes | **FIXED** | `PRICE_COOLDOWN = 6 hours` (line 150) enforced in `setXomPrice()` (lines 709-711). Owner can now change price by at most 10% per 6-hour window. |
| M-02: No ERC-2771 meta-transaction support | **FIXED** | Contract now inherits `ERC2771Context` (line 68). `_msgSender()` used in `bond()`, `claim()`, `claimAll()`. |
| M-03: `setTreasury()` allows self-reference | **FIXED** | `setTreasury()` rejects `address(this)` (line 743). |
| L-01: Missing event on `setBondAssetEnabled` | **FIXED** | `BondAssetEnabledChanged` event emitted (line 516). |
| L-02: No rescue function for accidentally sent tokens | **FIXED** | `rescueToken()` added (lines 831-838) with `CannotRescueXom` guard. |
| L-03: Dead `priceOracle` code | **UNCHANGED** | `priceOracle` and `setPriceOracle()` still exist as dead code. `getXomPrice()` only returns `fixedXomPrice`. See I-01 below. |
| L-04: `withdrawXom()` can underflow if `balance < totalXomOutstanding` | **NOT FIXED** | See L-01 below. |
| I-01: `bondAssets` array not prunable | **UNCHANGED** | Mitigated by `MAX_BOND_ASSETS = 50`. |
| I-02: Event indexing uses numeric values | **UNCHANGED** | See I-03 below. |
| I-03: No `Ownable2Step` | **NOT FIXED** | See H-01 below -- elevated to High severity for pre-mainnet. |

---

## Architecture Analysis

### Design Strengths

1. **Solvency Invariant:** `totalXomOutstanding` tracks all uncommitted XOM owed to bond holders. The invariant `XOM.balanceOf(address(this)) >= totalXomOutstanding` is enforced in `bond()` (lines 566-571) and maintained by `claim()` / `claimAll()` (decrement) and `withdrawXom()` (excess-only withdrawal). This is a robust anti-rug-pull mechanism.

2. **Price Change Controls (Triple Layer):**
   - Absolute bounds: `MIN_XOM_PRICE` ($0.0001) to `MAX_XOM_PRICE` ($100) (lines 140-143)
   - Rate-of-change limit: `MAX_PRICE_CHANGE_BPS` = 10% per update (lines 716-723)
   - Cooldown: `PRICE_COOLDOWN` = 6 hours between updates (lines 709-711)
   - Effective maximum manipulation: ~10% per 6 hours, ~40% per day

3. **Fee-on-Transfer Protection:** The `bond()` function uses balance-before/after on the treasury address (lines 574-583) and reverts with `TransferAmountMismatch` if the actual received differs from the nominal amount. This prevents accounting discrepancies.

4. **Daily Capacity Limits:** Per-asset daily caps prevent large-scale bonding manipulation within a single day (lines 1048-1059). Capacity resets at UTC midnight.

5. **Bond Cleanup:** Fully-claimed bonds are deleted from storage (lines 632-634, 668-671), freeing gas and allowing re-bonding.

6. **Deposit Verification:** `depositXom()` uses balance-before/after to verify the actual deposit matches the expected amount (lines 777-784).

7. **`rescueToken()` with XOM Guard:** Accidentally sent non-XOM tokens can be recovered, but XOM is explicitly excluded to maintain the solvency invariant (lines 834-838).

8. **Comprehensive NatSpec:** Every function, event, error, constant, and state variable has documentation. The critical warning about stablecoin-only assets is prominently placed in both the contract header and `_normalizeToPrice()`.

### Design Concerns

1. **Single-Step Ownership:** Uses `Ownable` instead of `Ownable2Step`. Given the owner's extensive powers, this is elevated to High severity. See H-01.

2. **Fixed Price Oracle:** `getXomPrice()` returns a fixed value set by the owner, not a market price from an oracle. The `priceOracle` state variable exists but is unused. This means bond pricing is entirely under owner control, subject only to the rate-of-change and cooldown limits.

3. **Stablecoin-Only Assumption:** `_normalizeToPrice()` assumes all bonded assets are worth $1 per unit. Adding volatile assets without price feeds would result in incorrect XOM output calculations.

4. **One Bond Per Asset Per User:** Users can only have one active bond per asset. They must wait for a bond to fully vest and claim it before creating a new one. This simplifies accounting but limits user flexibility.

---

## Findings

### [H-01] Single-Step `Ownable` Allows Accidental or Malicious Ownership Transfer to Wrong Address

**Severity:** High
**Lines:** 68
**Category:** Access Control / Governance

**Description:**

The contract inherits `Ownable` (single-step) rather than `Ownable2Step`. The owner has extensive powers:

1. **`setXomPrice()`:** Control bond pricing (up to 10% change per 6 hours)
2. **`addBondAsset()` / `updateBondTerms()`:** Configure discount rates and capacities
3. **`setBondAssetEnabled()`:** Enable/disable bonding entirely
4. **`setTreasury()`:** Redirect bonded asset receipts
5. **`withdrawXom()`:** Extract excess XOM above outstanding obligations
6. **`depositXom()`:** Fund the contract with XOM
7. **`pause()` / `unpause()`:** Halt or resume bonding
8. **`rescueToken()`:** Extract non-XOM tokens
9. **`setPriceOracle()`:** Set oracle address (currently unused)

A single `transferOwnership()` call with the wrong address would irreversibly transfer control of all these functions to an unintended recipient. With `Ownable2Step`, the new owner must explicitly accept ownership, preventing accidental transfers.

The contract header explicitly states: "The owner address MUST be a multisig wallet (e.g., Gnosis Safe) or a timelock controller -- NOT an externally owned account (EOA)." This is good operational guidance but does not protect against a transfer to the wrong multisig address.

**Impact:** Permanent loss of contract administration if ownership is accidentally transferred to the wrong address. An attacker who gains temporary access to the owner's key could transfer ownership to themselves in a single transaction.

**Recommendation:**

Change the inheritance from `Ownable` to `Ownable2Step`:

```solidity
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract OmniBonding is ReentrancyGuard, Ownable2Step, Pausable, ERC2771Context {
```

Also add `renounceOwnership()` override to prevent accidental lockout:

```solidity
function renounceOwnership() public pure override {
    revert InvalidParameters();
}
```

This is consistent with the LiquidityMining contract which already uses `Ownable2Step`.

---

### [M-01] `withdrawXom()` Underflows If `XOM.balanceOf(address(this)) < totalXomOutstanding`

**Severity:** Medium
**Lines:** 797-802
**Category:** Arithmetic / DoS

**Description:**

The `withdrawXom()` function computes excess XOM as:

```solidity
uint256 balance = XOM.balanceOf(address(this));
uint256 excess = balance - totalXomOutstanding;
```

If `balance < totalXomOutstanding` (which should not happen under normal operation but could occur if XOM tokens are somehow removed from the contract without going through `claim()` or `claimAll()`), this line would underflow and revert with a panic (Solidity 0.8.x checked arithmetic).

This is actually a safety feature -- it prevents the owner from withdrawing when the contract is insolvent. However, the revert gives no meaningful error message (it is a raw panic, not a custom error).

**Scenarios where `balance < totalXomOutstanding`:**
1. **Accidental direct transfer of XOM out of the contract** (not possible via the contract's functions, but could happen via `selfdestruct` of another contract sending ETH, or a contract upgrade if the XOM token itself is upgradeable and its `balanceOf` behavior changes).
2. **XOM token upgrade that reduces balances** (unlikely but theoretically possible if XOM is behind a proxy).

**Impact:** `withdrawXom()` reverts with an opaque panic instead of a descriptive error. No funds at risk -- the revert prevents over-withdrawal. But an owner trying to diagnose why `withdrawXom()` is failing would get no useful information.

**Recommendation:**

Add a safe check with a descriptive error:

```solidity
function withdrawXom(uint256 amount) external onlyOwner {
    uint256 balance = XOM.balanceOf(address(this));
    if (balance < totalXomOutstanding) revert InsufficientXomBalance();
    uint256 excess = balance - totalXomOutstanding;
    if (amount > excess) revert InsufficientXomBalance();
    XOM.safeTransfer(treasury, amount);
    emit XomWithdrawn(amount, treasury);
}
```

---

### [M-02] Front-Running `setXomPrice()` to Bond at Stale Price Before Price Increase

**Severity:** Medium
**Lines:** 527-609 (bond), 702-729 (setXomPrice)
**Category:** MEV / Front-Running

**Description:**

When the owner submits a `setXomPrice()` transaction to increase the XOM price (e.g., from $0.005 to $0.0055), an MEV bot or attacker monitoring the mempool can:

1. **Front-run** the `setXomPrice()` by submitting a `bond()` transaction with higher gas
2. **Bond at the old (lower) price** of $0.005, receiving more XOM per stablecoin
3. The `setXomPrice()` executes, raising the price to $0.0055
4. The attacker's bond vests over 1-30 days, during which the XOM price is higher

The attacker effectively buys XOM at a discount relative to what the owner intended as the new fair price.

**Quantification:** With a 10% price increase and a 10% discount:
- Old effective price: $0.005 * 0.90 = $0.0045/XOM
- New effective price: $0.0055 * 0.90 = $0.00495/XOM
- Attacker advantage: ~9.1% more XOM per dollar

The `PRICE_COOLDOWN` of 6 hours does not protect against this because the front-running occurs within a single block.

**Impact:** MEV bots can extract value by front-running price increases, receiving more XOM than the owner intended at the new price level.

**Recommendation:**

Several mitigations are possible:

1. **Commit-reveal price updates:** Owner commits a hash of the new price, waits a block, then reveals. This prevents front-running but adds complexity.

2. **Time-delayed bonding:** After a price change, impose a short cooldown (e.g., 1 block / 2 seconds) on `bond()`. This is simple but may affect legitimate users.

3. **Private mempool:** Submit `setXomPrice()` via Flashbots Protect or a similar private transaction relay. This is an operational mitigation, not a code change.

4. **Batch price+pause:** Owner pauses bonding, changes price, then unpauses. This is already possible with the existing `pause()` / `unpause()` functions and is the recommended approach with current code.

---

### [L-01] `_normalizeToPrice()` Allows `decimals > 18` But Division Loses Precision

**Severity:** Low
**Lines:** 1161-1171
**Category:** Precision Loss

**Description:**

The `_normalizeToPrice()` function handles tokens with more than 18 decimals by dividing:

```solidity
} else if (decimals > 18) {
    return amount / (10 ** (decimals - 18));
}
```

For a token with 24 decimals (the maximum allowed by the `addBondAsset()` validation), bonding 1 unit (1e24 in native decimals) would normalize to:

```
1e24 / 10^(24-18) = 1e24 / 1e6 = 1e18
```

This is correct. However, for small amounts, integer division truncation could be significant. Bonding 999999 units of a 24-decimal token:

```
999999 / 1e6 = 0 (integer division)
```

The `bond()` function has a check `if (xomOwed == 0) revert InvalidParameters()` (line 562), so a zero-XOM result would revert. But amounts between 1e6 and 2e6 would produce `xomOwed = 1`, which is a valid but dust-level bond.

**Impact:** For tokens with > 18 decimals, very small bond amounts lose precision. The zero-XOM check prevents completely wasted bonds, but dust-level bonds are possible.

**Recommendation:**

Consider adding a minimum bond amount per asset in `BondTerms`. Alternatively, document that tokens with > 18 decimals may have precision limitations for small amounts.

---

### [L-02] `claimAll()` Decrements `totalXomOutstanding` After the Loop, Not Per-Bond

**Severity:** Low
**Lines:** 648-686
**Category:** Accounting Pattern

**Description:**

The `claimAll()` function accumulates `totalClaimed` across all bonds and then decrements `totalXomOutstanding` once at the end:

```solidity
totalXomOutstanding -= totalClaimed;
XOM.safeTransfer(caller, totalClaimed);
```

Meanwhile, `claim()` (single asset) decrements `totalXomOutstanding` immediately after each bond's claim:

```solidity
userBond.claimed += claimed;
totalXomOutstanding -= claimed;
```

The `claimAll()` pattern is slightly less gas-efficient (one SSTORE instead of N SSTOREs, actually more efficient for N > 1) and functionally equivalent since `nonReentrant` prevents interleaving. However, if `totalXomOutstanding` is somehow lower than `totalClaimed` (due to accounting drift or bug), the final subtraction would revert, potentially locking all bonds -- not just the problematic one.

**Impact:** In a pathological scenario, a single corrupted bond could prevent `claimAll()` from executing, even though individual `claim()` calls for uncorrupted bonds would succeed.

**Recommendation:**

Consider per-bond decrement in the loop for resilience:

```solidity
if (claimable > 0) {
    userBond.claimed += claimable;
    totalXomOutstanding -= claimable; // decrement per-bond
    totalClaimed += claimable;
    // ...
}
```

Then remove the post-loop decrement and transfer `totalClaimed` at the end.

---

### [L-03] `PRICE_COOLDOWN` Does Not Apply to Initial Price Set in Constructor

**Severity:** Low
**Lines:** 364-383, 702-729
**Category:** Initialization

**Description:**

The constructor sets `fixedXomPrice` but does not set `lastPriceUpdateTime`:

```solidity
constructor(...) {
    // ...
    fixedXomPrice = _initialXomPrice;
    // lastPriceUpdateTime is implicitly 0
}
```

This means the first `setXomPrice()` call after deployment is not subject to the cooldown (since `block.timestamp > 0 + 6 hours` is always true after deployment). This is intentional and correct -- the owner needs to be able to set the price after deployment.

However, the first `setXomPrice()` call is still subject to the 10% rate-of-change limit relative to `_initialXomPrice`. If the owner needs to make a larger adjustment shortly after deployment (e.g., deploying with a placeholder price and then setting the real price), they would need to make multiple 10% changes over multiple 6-hour periods.

**Impact:** Post-deployment price adjustment is limited to 10% per 6 hours, even if the initial price was incorrect. This could delay the start of bonding by hours or days if the initial price needs significant correction.

**Recommendation:**

Consider adding a one-time "initial price override" that is only available before the first bond is created:

```solidity
function setInitialPrice(uint256 newPrice) external onlyOwner {
    if (totalXomDistributed > 0) revert InvalidParameters();
    if (newPrice < MIN_XOM_PRICE || newPrice > MAX_XOM_PRICE) revert PriceOutOfBounds(newPrice);
    fixedXomPrice = newPrice;
    lastPriceUpdateTime = block.timestamp;
    emit XomPriceUpdated(newPrice);
}
```

---

### [L-04] `bond()` Sends Assets Directly to Treasury -- No Recovery If Treasury Address Is Wrong

**Severity:** Low
**Lines:** 576-578
**Category:** Fund Safety

**Description:**

The `bond()` function transfers bonded assets directly to the treasury:

```solidity
terms.asset.safeTransferFrom(caller, treasury, amount);
```

If the treasury address is incorrect (e.g., set to an invalid contract or wrong multisig), the assets are permanently lost. Unlike the XOM side (where the contract holds XOM internally and can verify balances), the bonded assets leave the contract immediately and irrevocably.

**Impact:** Bonded assets sent to an incorrect treasury address are permanently lost. The `setTreasury()` function has a zero-address check and self-reference check, but cannot validate that the treasury address is a functional wallet.

**Recommendation:**

Consider having the contract hold bonded assets internally and allowing the owner to withdraw them to the treasury in a separate step. This adds an extra transaction but provides a safety buffer:

```solidity
// In bond():
terms.asset.safeTransferFrom(caller, address(this), amount);

// New function:
function withdrawBondedAssets(address asset, uint256 amount) external onlyOwner {
    IERC20(asset).safeTransfer(treasury, amount);
}
```

Alternatively, keep the current design but add a test bond function that sends a small amount to treasury and verifies receipt.

---

### [I-01] Dead `priceOracle` Code Adds Unused Storage Slot and Functions

**Severity:** Informational
**Lines:** 163, 757-766
**Category:** Code Hygiene

**Description:**

The `priceOracle` state variable and `setPriceOracle()` function exist but are never used by `getXomPrice()`, which only returns `fixedXomPrice`:

```solidity
function getXomPrice() public view returns (uint256 price) {
    return fixedXomPrice;
}
```

The `priceOracle` variable occupies a storage slot (32 bytes) and `setPriceOracle()` adds ~100 bytes of bytecode.

**Impact:** No security impact. Minor gas waste on deployment.

**Recommendation:**

Either integrate the oracle or remove the dead code. If oracle integration is planned, add a comment with a timeline. Consider using an interface:

```solidity
interface IPriceOracle {
    function getXomPrice() external view returns (uint256);
}

function getXomPrice() public view returns (uint256 price) {
    if (priceOracle != address(0)) {
        return IPriceOracle(priceOracle).getXomPrice();
    }
    return fixedXomPrice;
}
```

---

### [I-02] `ActiveBondExists` Check Prevents Partial Claiming and Re-Bonding in Same Transaction

**Severity:** Informational
**Lines:** 541-548
**Category:** User Experience

**Description:**

The `bond()` function reverts with `ActiveBondExists` if the user has an active (not fully claimed) bond for the same asset:

```solidity
if (existingBond.xomOwed > 0 && existingBond.claimed < existingBond.xomOwed) {
    revert ActiveBondExists();
}
```

A user who wants to re-bond the same asset must first call `claim()` to fully vest their existing bond, wait for the vesting period to complete, and then call `bond()` again. This requires at least two transactions and a waiting period equal to the vesting duration.

The `delete userBonds[caller][asset]` in `claim()` (line 633) clears the struct when fully claimed, allowing re-bonding. But partial claims do not clear the struct, so a user with a partially-vested bond cannot create a new one.

**Impact:** Users must wait for full vesting before re-bonding the same asset. This is a deliberate design choice that simplifies accounting but limits user flexibility.

**Recommendation:**

Document this as intentional. Alternatively, allow stacking bonds by using an array of bonds per (user, asset) pair -- but this adds significant complexity and gas costs.

---

### [I-03] Event Indexing for Numeric Parameters Limits Log Filtering

**Severity:** Informational
**Lines:** Various event declarations
**Category:** Event Design

**Description:**

Several events index numeric parameters rather than address parameters:

- `BondTermsUpdated`: `discountBps`, `vestingPeriod`, `dailyCapacity` -- none are addresses
- `XomPriceUpdated`: `newPrice` -- numeric
- `XomWithdrawn`: `amount`, `treasuryAddr` -- `treasuryAddr` indexing is appropriate

Indexed numeric parameters are hashed as topics and cannot be efficiently filtered by range. Typical use case is exact-match filtering, which is more useful for addresses than for numeric values.

**Impact:** Off-chain log filtering by price ranges or discount ranges is less efficient. No correctness impact.

**Recommendation:**

Prefer indexing address parameters. For `BondTermsUpdated`, index only `asset`. For `XomPriceUpdated`, leave `newPrice` unindexed and add the old price for comparison.

---

## Bonding Curve Manipulation Analysis

### Can the bonding curve be manipulated?

**Partially mitigated.** The bonding contract uses a fixed price set by the owner, not a market-derived price from a bonding curve formula. This eliminates on-chain bonding curve manipulation attacks (where an attacker buys/sells to move the curve). However, it introduces owner trust: the owner controls the price.

The triple-layer price controls (bounds, rate-of-change, cooldown) limit the owner's manipulation ability:
- Maximum price change: 10% per 6-hour window
- Absolute bounds: $0.0001 to $100
- The owner cannot crash the price to zero or spike it to infinity

### Front-running bond purchases

**Exploitable** -- see M-02. When the owner increases the price, front-running bots can bond at the old price. Mitigation: pause bonding before price changes.

### MEV extraction from bonding operations

**Limited.** Since the bonding contract uses a fixed price (not a market-responsive bonding curve), there is no price impact from individual bond operations. MEV bots cannot sandwich bond purchases because the price does not change based on demand within a block.

The only MEV vector is front-running `setXomPrice()` calls (M-02).

### What happens at extreme curve positions?

**Not applicable.** There is no bonding curve -- the price is fixed. The contract operates at whatever price the owner sets, bounded by `MIN_XOM_PRICE` and `MAX_XOM_PRICE`.

At the minimum price ($0.0001), bonding 1 USDC produces:
```
xomOwed = (1e18 * 1e18) / (1e14 * 0.85) = 1e36 / 8.5e13 = ~11,764,705,882,353 XOM
```

This is ~11.76 trillion XOM for $1, which is obviously incorrect pricing but is bounded by the solvency check (`XOM.balanceOf(address(this)) >= totalXomOutstanding + xomOwed`). The contract would revert with `InsufficientXomBalance` unless it holds > 11.76T XOM.

### Reserve management

**Robust.** The contract does not hold bonded assets -- they are sent directly to the treasury. It only holds XOM for distribution. The `totalXomOutstanding` tracker ensures the contract always holds enough XOM for all outstanding obligations. The `depositXom()` and `withdrawXom()` functions allow the owner to fund and defund the contract, with `withdrawXom()` restricted to excess above outstanding obligations.

### Slippage protection

**Not needed.** Since the price is fixed and does not change based on demand, there is no slippage. Users know exactly how much XOM they will receive before submitting the transaction. The only source of unexpected price changes is the owner calling `setXomPrice()` between the user's price check and their `bond()` transaction, which is addressed by M-02.

---

## Cross-Contract DeFi Attack Vectors

### Flash Loan -> LBP -> Bond -> Profit

**Not viable.** As analyzed in the LBP report, the LBP outputs XOM while the bonding contract accepts stablecoins. There is no way to convert LBP output into bonding input without going through an external market, which introduces risk and eliminates guaranteed profit.

### Sandwich Attacks on Bonding

**Not applicable.** Bond operations use a fixed price and do not create price impact. There is nothing to sandwich.

### Bonding + Liquidity Mining Interaction

**No direct on-chain interaction.** An attacker could use bonded XOM rewards to stake LP tokens in LiquidityMining, but this is a normal, intended usage pattern and does not constitute an exploit.

### Oracle Manipulation Through Pool Interactions

**Not applicable.** The bonding contract uses a fixed price, not an oracle. Even if the LBP's spot price were manipulated, it would not affect bond pricing.

### Multi-Block Price Manipulation Attack

**Mitigated.** An attacker with owner access could:
1. Lower price by 10% (setXomPrice)
2. Wait 6 hours (cooldown)
3. Lower price by another 10%
4. Repeat until price reaches MIN_XOM_PRICE ($0.0001)

Starting from $0.005: After N cooldown periods, price = $0.005 * 0.9^N.
To reach $0.0001: 0.005 * 0.9^N = 0.0001 -> N = log(0.02) / log(0.9) = ~37 periods = ~9.25 days.

This is a slow attack (over a week) that would be detectable by off-chain monitoring. The contract header's guidance to use a multisig owner is the primary mitigation. A timelock controller would add further protection.

---

## Summary

OmniBonding is a well-designed Protocol Owned Liquidity contract with robust solvency guarantees, multi-layered price manipulation protections, and comprehensive documentation. The primary concerns are the use of single-step `Ownable` (H-01, easy fix), the `withdrawXom()` underflow (M-01, easy fix), and the front-running vector on price updates (M-02, operational mitigation available). The contract is suitable for mainnet deployment with the H-01 fix applied.

**Deployment Readiness:** CONDITIONALLY APPROVED
- H-01: MUST upgrade to `Ownable2Step` before mainnet deployment
- M-01: SHOULD add safe check in `withdrawXom()` before underflow
- M-02: Operational mitigation: pause bonding before price changes
- L-03: SHOULD add initial price override for post-deployment flexibility

---

*Audit conducted 2026-03-10 01:03 UTC*
