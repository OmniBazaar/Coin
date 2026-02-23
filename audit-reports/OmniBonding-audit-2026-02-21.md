# Security Audit Report: OmniBonding

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/liquidity/OmniBonding.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 655
**Upgradeable:** No
**Handles Funds:** Yes (holds XOM for bond distribution, receives bonded assets)

## Executive Summary

OmniBonding is an Olympus DAO-inspired bonding contract where users deposit assets (USDC, ETH, LP tokens) and receive discounted XOM with linear vesting (1-30 days). The contract uses OpenZeppelin's ReentrancyGuard, Ownable, Pausable, and SafeERC20. It features multi-asset bonding with configurable discount rates (5-15%), daily capacity limits, and a fixed-price oracle (TODO for real oracle integration).

The audit found **1 Critical vulnerability**: the solvency check only compares XOM balance against the *current* bond, ignoring all outstanding obligations from previous bonds, enabling a fractional-reserve insolvency where later claimers cannot receive their owed XOM. The `withdrawXom()` function compounds this by allowing the owner to drain all XOM with no obligation check (rug pull vector). The XOM price oracle is entirely owner-controlled with no bounds, timelock, or external anchor, enabling price manipulation attacks. Both audit agents independently confirmed the solvency issue as the top priority fix.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 3 |
| Low | 3 |
| Informational | 3 |

## Findings

### [C-01] Solvency Check Ignores Outstanding Obligations -- Fractional Reserve Insolvency

**Severity:** Critical
**Lines:** 349
**Agents:** Both (Agent A: implicit in withdrawXom finding, Agent B: Critical with detailed PoC)

**Description:**

The `bond()` function checks solvency at line 349:
```solidity
if (xom.balanceOf(address(this)) < xomOwed) revert InsufficientXomBalance();
```

This only checks whether the contract's current XOM balance exceeds the XOM owed for the *current* bond. It does NOT subtract XOM already committed to other users with active, unclaimed bonds.

**Proof of Concept:**
```
1. Contract holds 1,000,000 XOM
2. User A bonds, owed 800,000 XOM. Check: 1,000,000 >= 800,000 (PASS)
3. User B bonds, owed 800,000 XOM. Check: 1,000,000 >= 800,000 (PASS)
   - Balance unchanged because XOM is not transferred at bond time
4. Total obligations: 1,600,000 XOM. Contract has 1,000,000 XOM
5. First claimer gets their XOM. Second claimer's transaction reverts.
```

This is a classic fractional-reserve vulnerability. Every bond that passes the check increases unfunded liabilities. The contract becomes a first-come-first-served bank run.

**Impact:** Users who bond later or claim later will lose their XOM. They have already sent their assets (USDC, etc.) to the treasury, which cannot be recovered.

**Recommendation:** Track total outstanding obligations:
```solidity
uint256 public totalXomOutstanding;

// In bond():
if (xom.balanceOf(address(this)) < totalXomOutstanding + xomOwed) revert InsufficientXomBalance();
totalXomOutstanding += xomOwed;

// In claim():
totalXomOutstanding -= claimed;
```

---

### [H-01] Owner Can Withdraw XOM Backing Active Bonds (Rug Pull Vector)

**Severity:** High
**Lines:** 462-464
**Agents:** Both (Agent A: Medium, Agent B: Critical)

**Description:**

`withdrawXom()` allows the owner to withdraw ANY amount of XOM with no check against outstanding obligations:

```solidity
function withdrawXom(uint256 amount) external onlyOwner {
    xom.safeTransfer(treasury, amount);
}
```

Even if C-01 is fixed with a `totalXomOutstanding` tracker, this function bypasses all safeguards. The owner can:
1. Wait for users to bond assets (sending real USDC/ETH to treasury)
2. Call `withdrawXom()` for the full XOM balance
3. Users have vesting claims that revert on `claim()`

No timelock, no multisig, no obligation check. The NatSpec says "emergency only" but there is no on-chain enforcement.

**Impact:** Total loss of all user-bonded funds. Users' assets are in the treasury and irrecoverable.

**Recommendation:** Restrict withdrawals to excess XOM above obligations:
```solidity
function withdrawXom(uint256 amount) external onlyOwner {
    uint256 available = xom.balanceOf(address(this)) - totalXomOutstanding;
    if (amount > available) revert InsufficientXomBalance();
    xom.safeTransfer(treasury, amount);
}
```

---

### [H-02] Unconstrained Owner Price Manipulation

**Severity:** High
**Lines:** 426-430, 486-490
**Agents:** Both (Agent A: Medium, Agent B: High)

**Description:**

`setXomPrice()` allows the owner to set XOM price to any non-zero value instantly:
- **Set price to 1 wei:** `xomOwed` becomes astronomically large, draining the entire XOM reserve
- **Set price very high:** `xomOwed` rounds to 0, users bond assets and receive nothing
- **Front-run bonds:** Owner adjusts price between the user's submission and execution

The `priceOracle` state variable exists but is never used. `getXomPrice()` returns only the fixed price. No bounds, no timelock, no rate-of-change limits.

**Impact:** Owner can extract unlimited value from bonders or deny them XOM entirely.

**Recommendation:**
1. Add minimum/maximum price bounds as constants
2. Add timelock to price changes (24h delay)
3. Add maximum price change per period (e.g., 10% per day)
4. Integrate a real oracle (Chainlink, TWAP)

---

### [H-03] Asset Price Normalization Assumes All Assets Worth $1 Per Unit

**Severity:** High
**Lines:** 644-654, 342
**Agents:** Both (Agent A: Medium, Agent B: High)

**Description:**

`_normalizeToPrice()` only adjusts decimal precision -- it does NOT apply any exchange rate. The implicit assumption is that 1 unit of any bonded asset equals $1 USD.

This is correct for stablecoins (USDC, USDT, DAI) but completely wrong for:
- **ETH/WETH (18 decimals):** 1 ETH treated as $1 instead of ~$2,500-$4,000. ETH bonders suffer ~99.97% loss
- **AVAX (18 decimals):** 1 AVAX treated as $1 instead of ~$15-$40
- **LP tokens:** Varying value per unit, all treated as $1

The contract header claims support for "USDC, ETH, LP tokens, AVAX" but the pricing only works for stablecoins.

**Impact:** Non-stablecoin bonders suffer massive losses. Conversely, worthless tokens bonded at $1/unit drain XOM reserves.

**Recommendation:** Add per-asset price feeds to the `BondTerms` struct. For non-stablecoins, use Chainlink oracle or configurable price multiplier:
```solidity
uint256 assetValueUSD = _normalizeDecimals(amount, terms.decimals) * terms.assetPriceUSD / 1e18;
```

---

### [M-01] Unbounded claimAll() Loop -- Gas Exhaustion DoS

**Severity:** Medium
**Lines:** 401-420
**Agents:** Both

**Description:**

`claimAll()` iterates over the entire `bondAssets` array. This array is append-only (no removal function). Each iteration performs a storage read (~2,100 gas cold SLOAD). With 100+ assets, the function may exceed block gas limits. Additionally, if the single `xom.safeTransfer()` at the end reverts, all accumulated claims for all assets are lost in that transaction.

Users can still call `claim(asset)` individually, so this is a convenience-function failure, not total loss.

**Impact:** Function becomes unusable as asset count grows. Transfer failure wastes all gas.

**Recommendation:** Add `MAX_BOND_ASSETS = 50` in `addBondAsset()`, or allow users to pass specific assets: `claimMultiple(address[] calldata assets)`.

---

### [M-02] Fee-on-Transfer Token Accounting Discrepancy

**Severity:** Medium
**Lines:** 352, 366-368
**Agent:** Agent B

**Description:**

If a bonded asset is a fee-on-transfer token, the treasury receives less than `amount`, but `dailyBonded`, `totalAssetReceived`, and `xomOwed` all use the full pre-fee `amount`. The user receives XOM based on tokens they nominally sent, not tokens the protocol actually received.

**Impact:** Protocol gradually loses value. Analytics overstate asset accumulation.

**Recommendation:** Use balance-delta pattern to measure actual received amount, or document that fee-on-transfer tokens are not supported.

---

### [M-03] Stale Bond Struct Not Cleaned After Full Claim

**Severity:** Medium
**Lines:** 322-327, 389
**Agents:** Both

**Description:**

When a user fully claims their bond (`claimed == xomOwed`), the struct remains in storage with `xomOwed > 0`. The active bond check allows rebonding (correctly), but users with partially claimed bonds at vesting end must execute a final `claim()` transaction just to clear the way for a new bond. Additionally, `totalXomDistributed` grows monotonically with no cleanup path.

**Impact:** Operational friction for users. Accounting variables become inflated.

**Recommendation:** Auto-delete struct when `claimed == xomOwed` in `claim()`:
```solidity
if (userBond.claimed == userBond.xomOwed) delete userBonds[msg.sender][asset];
```

---

### [L-01] Daily Capacity Double-Spend at Midnight Boundary

**Severity:** Low
**Lines:** 330-334
**Agent:** Agent B

**Description:**

Daily capacity resets at exactly 00:00:00 UTC (`block.timestamp / 1 days`). A user can bond up to full capacity at 23:59:59, then again at 00:00:00, effectively doubling the daily limit within a ~2-second window.

**Impact:** Daily capacity protection is weaker than it appears. Standard pattern in DeFi.

**Recommendation:** Document as expected behavior. A sliding window adds significant complexity.

---

### [L-02] No Minimum Bond Amount Enforcement

**Severity:** Low
**Lines:** 314-375
**Agents:** Both

**Description:**

`bond()` accepts `amount = 0`. A zero-amount bond succeeds (creates a struct with `xomOwed = 0`), emits a misleading event, and wastes gas. Very small amounts may produce `xomOwed = 0` after rounding.

**Recommendation:** Add `if (amount == 0) revert InvalidParameters();` and `if (xomOwed == 0) revert InvalidParameters();`

---

### [L-03] No Decimals Validation in addBondAsset

**Severity:** Low
**Lines:** 233-266
**Agent:** Agent A

**Description:**

`addBondAsset()` accepts any `uint8` for decimals (0-255). Values >18 cause `_normalizeToPrice()` to divide, potentially truncating small amounts to zero. Values >24 are invalid for any real token.

**Recommendation:** Add `require(decimals <= 24, "invalid decimals")`.

---

### [I-01] priceOracle State Variable Is Dead Code

**Severity:** Informational
**Lines:** 445-448, 486-490
**Agent:** Agent A

**Description:**

`setPriceOracle()` sets the `priceOracle` address but it is never read anywhere. `getXomPrice()` ignores it and returns only `fixedXomPrice`. This is acknowledged by the TODO comment but represents dead code.

**Recommendation:** Either implement the oracle integration or remove `priceOracle` and `setPriceOracle()` until needed.

---

### [I-02] bondAssets Array Cannot Be Pruned

**Severity:** Informational
**Lines:** 262
**Agent:** Agent B

**Description:**

`bondAssets` is append-only. Disabled assets remain in the array permanently, increasing gas costs for `claimAll()` and `getBondAssets()`.

**Recommendation:** Add `removeBondAsset()` with swap-and-pop, or enforce a hard cap.

---

### [I-03] Questionable Event Indexing on xomOwed

**Severity:** Informational
**Lines:** 130
**Agents:** Both

**Description:**

`BondCreated` indexes `xomOwed` (continuous uint256). Filtering by exact XOM amount is impractical. This wastes ~375 gas per event and uses one of the 3 available topic slots.

**Recommendation:** Remove `indexed` from `xomOwed`.

---

## Static Analysis Results

**Solhint:** 0 errors, 14 warnings
- 1 immutable naming (convention)
- 1 struct ordering
- 1 struct packing efficiency
- 5 gas-indexed-events
- 3 not-rely-on-time (accepted -- business requirement)
- 1 gas-increment-by-one
- 1 gas-strict-inequalities

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual -- 22 raw findings -> 13 unique)
- Pass 6: Report generation

## Conclusion

OmniBonding has **one Critical vulnerability that must be fixed before any deployment**:

1. **Fractional-reserve insolvency (C-01)** allows the contract to promise more XOM than it can deliver. The fix is straightforward: track `totalXomOutstanding` and include it in the solvency check.

2. **Owner rug pull (H-01)** via `withdrawXom()` compounds C-01 by allowing the owner to drain obligated XOM. Must enforce obligation-aware withdrawal limits.

3. **Unconstrained price manipulation (H-02)** gives the owner a single-key vector to extract unlimited value. Needs bounds, timelock, and ultimately a real oracle.

4. **$1/unit pricing assumption (H-03)** makes the contract only functional for stablecoins despite claiming ETH/AVAX/LP support. Needs per-asset price feeds.

No tests exist for this contract, which should be considered a deployment blocker. The `priceOracle` integration (marked TODO) must be completed before production use.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
