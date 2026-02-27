# Security Audit Report: OmniPrivacyBridge (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniPrivacyBridge.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 596
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (locks XOM, mints/burns pXOM)
**OpenZeppelin Version:** 5.x (contracts-upgradeable)
**Dependencies:** `IERC20`, `SafeERC20`, `AccessControlUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `UUPSUpgradeable`
**Test Coverage:** `Coin/test/OmniPrivacyBridge.test.js` (39 test cases; 29 passing, 10 failing due to fee-constant mismatch)
**Previous Audit:** Round 1 (2026-02-21) -- 2 Critical, 3 High, 4 Medium, 3 Low, 2 Informational

---

## Executive Summary

OmniPrivacyBridge is a UUPS-upgradeable contract that facilitates XOM (public) to pXOM (private) conversion. Users lock XOM in the bridge, receive minted pXOM (minus a 0.5% fee), and can later burn pXOM to redeem XOM 1:1. The bridge tracks `totalLocked` and `bridgeMintedPXOM` for solvency accounting. An ossification mechanism allows the admin to permanently disable upgradeability.

**This is a Round 3 re-audit.** The contract has undergone significant remediation since Round 1:
- **C-01 (emergencyWithdraw rug pull): FIXED.** The function now updates `totalLocked` and auto-pauses on XOM withdrawal.
- **C-02 (1B unbacked pXOM at genesis): FIXED.** The bridge now tracks `bridgeMintedPXOM` and only allows redemption of bridge-minted pXOM, not genesis supply.
- **H-01 (uint64 max conversion limit): FIXED.** The `MAX_CONVERSION_AMOUNT` constant has been removed; limits are now controlled by the configurable `maxConversionLimit` (default 10M XOM).
- **H-02 (double fee): FIXED.** PrivateOmniCoin no longer charges a fee on `convertToPrivate()`. The bridge is now the sole fee point (0.5%).
- **H-03 (fee accounting desync): FIXED.** `totalLocked` now tracks `amountAfterFee`, and fees are tracked separately via `totalFeesCollected`. A `withdrawFees()` function has been added.
- **M-01 (external pXOM minting draining bridge): FIXED.** The `bridgeMintedPXOM` counter prevents non-bridge pXOM from being redeemed.
- **M-02 (no rate limiting): FIXED.** Daily volume limits with configurable `dailyVolumeLimit` (default 50M/day).
- **M-03 (missing limit check in pXOM->XOM): FIXED.** `convertPXOMtoXOM()` now checks `maxConversionLimit`.
- **M-04 (trapped fees): FIXED.** `withdrawFees()` gated by `FEE_MANAGER_ROLE` added.
- **L-02 (zero-address checks): FIXED.** `initialize()` validates both token addresses.
- **I-02 (floating pragma): FIXED.** Now uses `pragma solidity 0.8.24;`.

**New feature added since Round 1:** Ossification (`ossify()`, `isOssified()`, `_ossified` state variable) allows permanent disabling of UUPS upgradeability.

The Round 3 audit found **0 Critical**, **0 High**, **2 Medium**, **4 Low**, and **4 Informational** findings. The contract is in substantially better shape than Round 1. All prior Critical and High issues have been properly remediated. The remaining findings are operational risks and code hygiene items.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 4 |

---

## Architecture Analysis

### Design Strengths

1. **Clean Solvency Invariant:** `totalLocked` now tracks only the backed amount (post-fee), and `bridgeMintedPXOM` prevents genesis pXOM from draining bridge XOM. The invariant `totalLocked >= bridgeMintedPXOM` holds at all times under normal operation.

2. **Separated Fee Accounting:** Fees are tracked via `totalFeesCollected` and held in the contract's XOM balance alongside (but logically separate from) locked funds. `withdrawFees()` only releases the fee portion.

3. **Defense in Depth on Emergency Withdraw:** `emergencyWithdraw()` now updates `totalLocked` and auto-pauses the bridge when XOM is withdrawn, preventing redemptions against depleted reserves.

4. **Ossification:** The `ossify()` function provides a credible commitment mechanism -- once called, the contract can never be upgraded again, eliminating the upgrade-key-compromise vector permanently.

5. **Daily Volume Limits:** `_checkAndUpdateDailyVolume()` enforces a configurable per-day cap on conversion volume (default 50M XOM), mitigating flash-loan-based mixing attacks.

6. **Symmetrical Limit Enforcement:** Both `convertXOMtoPXOM()` and `convertPXOMtoXOM()` check `maxConversionLimit`, fixing the asymmetry from Round 1.

7. **CEI Pattern:** State variables are updated before external calls in `convertPXOMtoXOM()`, properly following Checks-Effects-Interactions.

8. **Custom Errors:** Gas-efficient revert messages throughout.

9. **Storage Gap:** 38-slot `__gap` properly reserves space for future upgrades (12 state variables + 38 gap = 50 total slots).

### Dependency Analysis

- **IERC20 / SafeERC20:** Standard OpenZeppelin. `safeTransferFrom` and `safeTransfer` protect against non-standard ERC20 return values.
- **IPrivateOmniCoin:** Custom interface extending IERC20 with `mint()`, `burnFrom()`, and `privacyAvailable()`. The bridge holds `MINTER_ROLE` and `BURNER_ROLE` on PrivateOmniCoin.
- **AccessControlUpgradeable:** Role-based access with `DEFAULT_ADMIN_ROLE`, `OPERATOR_ROLE`, `FEE_MANAGER_ROLE`.
- **PausableUpgradeable:** Emergency stop capability.
- **ReentrancyGuardUpgradeable:** Standard reentrancy protection on conversion functions.
- **UUPSUpgradeable:** Proxy upgrade pattern with `_authorizeUpgrade()` gated by admin role and ossification check.

---

## Round 1 Remediation Verification

### C-01: emergencyWithdraw Breaks Solvency Invariant -- VERIFIED FIXED

**Round 1:** `emergencyWithdraw()` drained XOM without updating `totalLocked`.
**Current Code (Lines 421-444):** When withdrawing XOM, the function now decrements `totalLocked` by the withdrawal amount (capping at 0 if `amount >= totalLocked`) and calls `_pause()` to prevent redemptions. This correctly protects pXOM holders from a rug-pull scenario.

**Residual concern:** See M-01 below regarding the conditional `totalLocked` update logic.

### C-02: 1B Unbacked pXOM at Genesis -- VERIFIED FIXED

**Round 1:** Genesis pXOM could drain bridge XOM.
**Current Code (Lines 340-347):** `convertPXOMtoXOM()` now checks `amount > bridgeMintedPXOM` and `amount > totalLocked`. Since `bridgeMintedPXOM` only increments when pXOM is minted through the bridge (line 312), genesis pXOM cannot be redeemed. The solvency invariant is properly maintained.

### H-01: uint64 MAX_CONVERSION_AMOUNT -- VERIFIED FIXED

**Round 1:** `MAX_CONVERSION_AMOUNT = type(uint64).max` limited conversions to ~18.4 XOM.
**Current Code:** The `MAX_CONVERSION_AMOUNT` constant has been completely removed. Conversion limits are now controlled solely by the configurable `maxConversionLimit` (default 10M XOM, line 257), which can be adjusted by admin via `setMaxConversionLimit()`.

### H-02: Double Fee (0.6% total) -- VERIFIED FIXED

**Round 1:** Both bridge and PrivateOmniCoin charged 0.3%.
**Current State:** Bridge charges 0.5% (line 77: `PRIVACY_FEE_BPS = 50`). PrivateOmniCoin's `convertToPrivate()` charges 0% (confirmed: line 350 emits `fee = 0`). The fee is charged in exactly one location.

**Note:** The fee has changed from 0.3% (Round 1) to 0.5% (current). See I-01 for documentation mismatch.

### H-03: Fee Accounting Desync -- VERIFIED FIXED

**Round 1:** `totalLocked += amount` (full amount including fee) but only `amount - fee` pXOM was minted.
**Current Code (Lines 303-306):** `totalLocked += amountAfterFee` and `totalFeesCollected += fee`. The fee XOM stays in the contract but is tracked separately and withdrawable via `withdrawFees()`. The invariant `totalLocked == sum(bridgeMintedPXOM outstanding)` is maintained.

### M-01 through M-04, L-01 through L-03, I-01, I-02: All addressed as described in the Executive Summary.

---

## Findings

### [M-01] emergencyWithdraw totalLocked Update Has Edge-Case Logic Flaw

**Severity:** Medium
**Lines:** 431-436
**Status:** New finding

**Description:**

The `emergencyWithdraw` function handles `totalLocked` updates with a conditional:

```solidity
if (amount < totalLocked) {
    totalLocked -= amount;
} else {
    totalLocked = 0;
}
```

This conditional uses strict `<` rather than `<=`. When `amount == totalLocked` (an admin withdrawing exactly the locked amount), the `else` branch executes and sets `totalLocked = 0`, which is correct. However, the semantic intent is unclear -- the `if` branch handles `amount < totalLocked` and the `else` branch handles `amount >= totalLocked`. The `amount > totalLocked` case (admin withdrawing more XOM than is logically locked, which includes fee XOM held in the contract) silently sets `totalLocked = 0` without reverting.

This means an admin can withdraw fee XOM that has not yet been claimed via `withdrawFees()`, bypassing the `FEE_MANAGER_ROLE` access control. The `emergencyWithdraw` function (gated by `DEFAULT_ADMIN_ROLE`) can extract all XOM from the contract -- including unclaimed fees -- while `withdrawFees()` (gated by `FEE_MANAGER_ROLE`) is the intended mechanism for fee extraction.

**Impact:** Role bypass: `DEFAULT_ADMIN_ROLE` can extract fees that should require `FEE_MANAGER_ROLE`. In practice, admin is typically the more privileged role, so this is a design concern rather than an escalation vector. However, if the roles are held by different entities (e.g., admin = governance timelock, fee manager = treasury multi-sig), this bypasses the intended separation.

**Recommendation:** Consider either:
1. Only allow withdrawing up to `balance - totalLocked - totalFeesCollected` for non-XOM-token amounts (but emergency withdraw should remain unrestricted for genuine emergencies), or
2. Zero out `totalFeesCollected` proportionally when XOM is emergency-withdrawn, so the accounting stays consistent, or
3. Document this as intentional behavior: emergency withdraw supersedes fee manager.

---

### [M-02] Daily Volume Reset Has Off-by-One in Time Check

**Severity:** Medium
**Lines:** 551
**Status:** New finding

**Description:**

The daily volume reset condition is:

```solidity
if (block.timestamp > currentDayStart + 1 days - 1) {
```

This is equivalent to `block.timestamp >= currentDayStart + 1 days` (since all values are integers), which resets the counter when exactly 86400 seconds have passed. However, the `- 1` formulation is unnecessarily confusing and differs from the natural pattern `block.timestamp >= currentDayStart + 1 days`.

More importantly, after the reset, `currentDayStart` is set to `block.timestamp`, not to the start of the new period. This causes **period drift**: if a conversion happens at `T + 86401`, the new period starts at `T + 86401` rather than `T + 86400`. Over time, the daily window shifts later and later. A user could exploit this by timing transactions at the boundary to get two days' worth of volume within approximately 24 hours plus a few seconds:

1. Convert up to `dailyVolumeLimit` at timestamp T + 86399 (end of day 1).
2. Convert again at timestamp T + 86401 (day 2 just started, counter reset).
3. Total volume in a ~2 second window: `2 * dailyVolumeLimit`.

This is inherent to any rolling-window implementation, but the `-1` formulation makes it slightly worse by allowing the reset at exactly `currentDayStart + 86400` (timestamp N) but then also allowing the boundary case at `currentDayStart + 86399` (timestamp N-1) for the previous period.

**Impact:** Minor: an attacker can do `2 * dailyVolumeLimit` worth of conversions in a short boundary window. At the default 50M/day limit, this means 100M XOM could be converted in seconds at the day boundary. This is a rate-limiting bypass, not a fund-safety issue.

**Recommendation:** Use the cleaner formulation:

```solidity
if (block.timestamp >= currentDayStart + 1 days) {
    currentDayVolume = 0;
    currentDayStart = currentDayStart + 1 days; // fixed period, no drift
}
```

Using `currentDayStart + 1 days` for the new period start (instead of `block.timestamp`) eliminates drift and ensures consistent 24-hour windows.

---

### [L-01] Fee Constant Mismatch Between Bridge and PrivateOmniCoin Documentation

**Severity:** Low
**Lines:** 46, 77 (OmniPrivacyBridge); 95-97, 297 (PrivateOmniCoin)
**Status:** New finding

**Description:**

OmniPrivacyBridge charges 0.5% (50 bps, line 77), but PrivateOmniCoin's NatSpec still references 0.3%:

- PrivateOmniCoin line 95-96: `/// @dev Retained for reference; fee is charged by OmniPrivacyBridge,`
- PrivateOmniCoin line 97: `uint16 public constant PRIVACY_FEE_BPS = 30;`
- PrivateOmniCoin line 297: `/// No fee is charged here; the OmniPrivacyBridge charges 0.3%.`
- OmniPrivacyBridge NatSpec line 46: `XOM -> pXOM: Locks XOM, mints private pXOM balance (0.5% fee)` (correct)

PrivateOmniCoin retains `PRIVACY_FEE_BPS = 30` as a constant that is never used in fee calculations (the contract charges 0% in `convertToPrivate`), but its existence at a different value from the bridge's 50 bps creates confusion.

The test suite (`OmniPrivacyBridge.test.js`) uses `PRIVACY_FEE_BPS = 30n` (line 11), which is why 10 of 39 tests fail -- they expect 0.3% deductions but the contract deducts 0.5%.

**Impact:** Documentation inconsistency and test suite regression. No on-chain impact (PrivateOmniCoin's constant is unused for fee calculation).

**Recommendation:**
1. Update PrivateOmniCoin's NatSpec (line 297) to say `0.5%` instead of `0.3%`.
2. Either remove the unused `PRIVACY_FEE_BPS = 30` constant from PrivateOmniCoin or update it to 50 for consistency.
3. Update the test suite to use `PRIVACY_FEE_BPS = 50n`.

---

### [L-02] Solhint Warnings: Function Ordering and Unused Parameter

**Severity:** Low
**Lines:** 568, 588
**Status:** New finding

**Description:**

Solhint reports two warnings:

1. **Line 568:** `ossify()` is an `external` function placed after the `internal` function `_checkAndUpdateDailyVolume()` (line 544). Per Solidity style guide, external functions should precede internal functions.

2. **Line 588:** The `newImplementation` parameter in `_authorizeUpgrade(address newImplementation)` is unused. This is inherent to the UUPS pattern (OpenZeppelin's interface requires the parameter), but solhint flags it.

**Impact:** Code hygiene. No functional impact.

**Recommendation:**
1. Move `ossify()` and `isOssified()` to the "ADMIN FUNCTIONS" section (before `_checkAndUpdateDailyVolume()`).
2. Silence the unused parameter warning with a NatSpec comment or use the pattern:

```solidity
function _authorizeUpgrade(
    address /* newImplementation */
)
```

---

### [L-03] Event Over-Indexing on Amount Parameters (Carried from Round 1)

**Severity:** Low
**Lines:** 147-152, 157, 162, 172, 179-180, 187-188
**Status:** Carried forward (Round 1 L-03), not yet fixed

**Description:**

Multiple events index `uint256` amount parameters (`amountIn`, `amountOut`, `fee`, `amount`, `oldLimit`, `newLimit`). Indexing amounts creates topic hashes that are useless for equality filtering (the full uint256 range makes collision-free topic queries impractical). Only addresses and small enums benefit from indexing.

Events affected:
- `ConvertedToPrivate`: `amountIn`, `amountOut`, and `fee` are all indexed (3 of 4 params)
- `ConvertedToPublic`: `amountOut` is indexed
- `MaxConversionLimitUpdated`: both `oldLimit` and `newLimit` are indexed
- `EmergencyWithdrawal`: `amount` is indexed
- `FeesWithdrawn`: `amount` is indexed
- `DailyVolumeLimitUpdated`: both `oldLimit` and `newLimit` are indexed

This wastes gas on every event emission. Each indexed parameter costs 375 gas (LOG topic) vs ~8 gas per byte as non-indexed data.

**Impact:** Wasted gas on every conversion. For `ConvertedToPrivate` with 3 indexed amounts, this wastes approximately 1,125 gas per call vs non-indexed.

**Recommendation:** Keep `user` (address) indexed. Remove `indexed` from all amount/limit parameters. For example:

```solidity
event ConvertedToPrivate(
    address indexed user,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee
);
```

---

### [L-04] No Ossification Event Confirmation or Delay Mechanism

**Severity:** Low
**Lines:** 568-571
**Status:** New finding

**Description:**

The `ossify()` function permanently and irreversibly disables upgradeability in a single transaction. While this is gated by `DEFAULT_ADMIN_ROLE`, there is no timelock, delay, or two-step confirmation process. A single admin transaction ossifies the contract forever.

The NatSpec states `Can only be called by admin (through timelock)`, but the contract itself does not enforce timelock usage -- this is a deployment-time assumption that the admin role is held by a timelock controller.

If the admin role is held directly by an EOA (as it is during initial deployment before role transfer), ossification is a one-click irreversible action.

**Impact:** Low, because ossification is a safety-enhancing action (it removes the upgrade vector). The risk is accidental ossification before the contract is ready, which would require redeployment.

**Recommendation:** Either:
1. Enforce that `ossify()` can only be called via a timelock (check `msg.sender` against a timelock address), or
2. Implement a two-step ossification: `proposeOssification()` sets a timestamp, and `confirmOssification()` can only be called after a delay, or
3. Accept the current design and document that admin role MUST be transferred to a timelock before ossification is called.

---

### [I-01] Test Suite Regression: 10 of 39 Tests Failing

**Severity:** Informational
**Status:** New finding

**Description:**

The test suite at `Coin/test/OmniPrivacyBridge.test.js` has 10 failing tests, all caused by the fee constant changing from 0.3% (30 bps) to 0.5% (50 bps). The test file still uses `PRIVACY_FEE_BPS = 30n` on line 11.

Failing tests include: conversion amount assertions, statistics checks, and full-cycle integration tests. All failures show the pattern of expecting 0.3% deductions but receiving 0.5% deductions.

Additionally, the `convertPXOMtoXOM` full-cycle test (test #6) fails with `InsufficientLockedFunds` because the test attempts to convert back the full pre-fee amount, but the bridge now correctly tracks `bridgeMintedPXOM` and rejects amounts exceeding bridge-minted supply.

**Impact:** Test suite does not validate current contract behavior. Reduces confidence in the correctness of the contract changes.

**Recommendation:** Update the test file:
1. Change `PRIVACY_FEE_BPS = 30n` to `PRIVACY_FEE_BPS = 50n` on line 11.
2. Adjust conversion cycle tests to account for `bridgeMintedPXOM` limits.
3. Add tests for the new features: `ossify()`, `isOssified()`, daily volume limits, `withdrawFees()`, and `setDailyVolumeLimit()`.

---

### [I-02] bridgeMintedPXOM Could Desynchronize If pXOM Is Burned Externally

**Severity:** Informational
**Lines:** 340, 347, 351
**Status:** New finding

**Description:**

`convertPXOMtoXOM()` decrements `bridgeMintedPXOM` (line 347) and calls `privateOmniCoin.burnFrom(msg.sender, amount)` (line 351). If a user calls `privateOmniCoin.burn()` directly (PrivateOmniCoin inherits ERC20BurnableUpgradeable, which provides `burn(uint256)` for anyone to burn their own tokens), the bridge's `bridgeMintedPXOM` counter is NOT decremented.

This creates a scenario where:
1. User converts 100 XOM to 99.5 pXOM via bridge. `bridgeMintedPXOM = 99.5`.
2. User calls `privateOmniCoin.burn(99.5)` directly.
3. `bridgeMintedPXOM` still equals 99.5, but only 0 pXOM exists.
4. 99.5 XOM remains permanently locked in the bridge with no way to redeem.

While this does not create an exploitable vulnerability (no one can steal funds), it does mean XOM can become permanently locked if users interact with pXOM directly rather than through the bridge.

**Impact:** User error can cause permanent locking of their XOM in the bridge. Not exploitable by attackers, but a usability concern. The locked XOM would still be recoverable via `emergencyWithdraw()` by admin.

**Recommendation:** Document this behavior prominently: "Users MUST redeem pXOM through the bridge. Burning pXOM directly will permanently lock the corresponding XOM." Alternatively, consider adding a reconciliation function that allows admin to adjust `bridgeMintedPXOM` downward when direct burns are detected.

---

### [I-03] convertPXOMtoXOM Does Not Check privacyAvailable()

**Severity:** Informational
**Lines:** 328-357
**Status:** New finding

**Description:**

`convertXOMtoPXOM()` does not check `privateOmniCoin.privacyAvailable()`, and neither does `convertPXOMtoXOM()`. The `IPrivateOmniCoin` interface defines `privacyAvailable()` but neither conversion function calls it. The `PrivacyNotAvailable` custom error is defined (line 208) but never used.

Since the bridge operates on public pXOM (minting/burning ERC20 tokens, not MPC-encrypted balances), and PrivateOmniCoin's `privacyAvailable()` refers to MPC availability rather than ERC20 availability, this is likely intentional -- the bridge works regardless of MPC status.

**Impact:** None functionally. The unused error `PrivacyNotAvailable` is dead code and wastes contract bytecode.

**Recommendation:** Either:
1. Remove the `PrivacyNotAvailable` error and the `privacyAvailable()` function from the `IPrivateOmniCoin` interface used by the bridge (if the check is intentionally omitted), or
2. Add a check if there is a scenario where conversions should be blocked when privacy is unavailable.

---

### [I-04] Storage Gap Arithmetic Comment Counts 12 Variables But Only 10 Are Contract-Owned

**Severity:** Informational
**Lines:** 130-136
**Status:** New finding

**Description:**

The storage gap comment states "Current storage: 12 variables" and lists them. However, inherited contracts (AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable) have their own storage slots managed by their own gaps. The 12 variables listed in the comment are the contract's OWN state variables, which is the correct count for gap calculation purposes (50 - 12 = 38). The comment is not wrong, but it could benefit from clarifying that these are "this contract's own state variables, excluding inherited storage."

**Impact:** None. The gap size (38) is correct.

**Recommendation:** No change needed. Optionally clarify the comment for future maintainers.

---

## Static Analysis Results

**Solhint:** 0 errors, 2 warnings
- Warning 1: Function ordering -- `ossify()` (external) placed after `_checkAndUpdateDailyVolume()` (internal). See L-02.
- Warning 2: Unused variable `newImplementation` in `_authorizeUpgrade()`. See L-02.

**Compiler:** Compiles cleanly under `0.8.24` with optimizer (200 runs). No compiler warnings.

**Contract Size:** 6.807 KiB (well under the 24 KiB limit).

---

## Methodology

- **Pass 1:** Static analysis (solhint, compiler, contract size verification)
- **Pass 2A:** OWASP Smart Contract Top 10 analysis (access control, reentrancy, integer overflow, front-running, DoS, oracle manipulation)
- **Pass 2B:** Business logic and economic analysis (solvency invariants, fee accounting, daily limits, conversion cycle integrity)
- **Pass 3:** Round 1 remediation verification (systematic check of all 14 prior findings)
- **Pass 4:** New feature analysis (ossification, daily volume limits, fee withdrawal)
- **Pass 5:** Test suite review (coverage, regression, correctness)
- **Pass 6:** Report generation and deduplication

---

## Round 1 Finding Disposition Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | Critical | emergencyWithdraw breaks solvency | **FIXED** -- updates totalLocked, auto-pauses |
| C-02 | Critical | 1B unbacked pXOM at genesis | **FIXED** -- bridgeMintedPXOM prevents genesis redemption |
| H-01 | High | ~18.4 XOM conversion limit | **FIXED** -- MAX_CONVERSION_AMOUNT removed |
| H-02 | High | Double fee (0.6% total) | **FIXED** -- single fee point (bridge only, 0.5%) |
| H-03 | High | Fee accounting desync | **FIXED** -- totalLocked tracks post-fee, separate fee counter |
| M-01 | Medium | External pXOM minting drains bridge | **FIXED** -- bridgeMintedPXOM counter |
| M-02 | Medium | No rate limiting | **FIXED** -- daily volume limit enforced |
| M-03 | Medium | Missing limit check in pXOM->XOM | **FIXED** -- maxConversionLimit checked both directions |
| M-04 | Medium | Trapped fees, no withdrawal | **FIXED** -- withdrawFees() added |
| L-01 | Low | burnFrom bypasses allowance | **ACCEPTED** -- by design, documented |
| L-02 | Low | Missing zero-address checks | **FIXED** -- initialize() validates both addresses |
| L-03 | Low | Event over-indexing | **NOT FIXED** -- carried forward as L-03 |
| I-01 | Info | No UUPS proxy tests | **FIXED** -- proxy-based deployment in test suite |
| I-02 | Info | Floating pragma | **FIXED** -- now `0.8.24` |

---

## Conclusion

OmniPrivacyBridge has undergone substantial and effective remediation since Round 1. All 2 Critical and 3 High severity findings have been properly fixed. The contract now maintains a sound solvency invariant through `bridgeMintedPXOM` tracking, has proper fee separation via `totalFeesCollected` and `withdrawFees()`, enforces daily volume limits, and provides symmetrical conversion limit checks.

The remaining findings are operational concerns (M-01: emergency withdraw can bypass fee manager role; M-02: daily volume boundary allows brief 2x throughput) and code hygiene items (L-01 through L-04). None of these represent fund-safety risks.

**Key action items before production deployment:**
1. Fix the test suite regression (I-01) -- update `PRIVACY_FEE_BPS` to 50 and add tests for ossification, daily limits, and fee withdrawal.
2. Update PrivateOmniCoin's NatSpec to reference 0.5% instead of 0.3% (L-01).
3. Fix daily volume reset drift by using `currentDayStart + 1 days` for period advancement (M-02).
4. Address solhint warnings: reorder `ossify()` and comment out unused `newImplementation` parameter (L-02).
5. Transfer admin role to a timelock/multi-sig before mainnet deployment.

**Overall Assessment:** The contract is suitable for testnet deployment and, after addressing the action items above, for mainnet deployment behind a governance timelock.

---
*Generated by Claude Code Audit Agent v3 -- 6-Pass Enhanced (Round 3)*
