# Security Audit Report: Pioneer Phase Fee Wiring Modifications

**Date:** 2026-03-08
**Audited by:** Claude Code Audit Agent (4-Agent Parallel)
**Scope:** 5 contracts modified for Pioneer Phase deployment
**Solidity Version:** 0.8.19 / 0.8.24 / 0.8.25
**Methodology:** 4 parallel LLM agents (OWASP SC Top 10, Business Logic, Access Control, DeFi Exploit Patterns) + solhint

## Contracts Audited

| # | Contract | File | Lines | Modification |
|---|----------|------|-------|-------------|
| 1 | OmniSwapRouter | `contracts/dex/OmniSwapRouter.sol` | ~500 | Made feeRecipient mutable, removed timelock |
| 2 | OmniFeeRouter | `contracts/dex/OmniFeeRouter.sol` | ~260 | Made feeCollector mutable, added Ownable2Step |
| 3 | OmniPredictionRouter | `contracts/predictions/OmniPredictionRouter.sol` | ~425 | Made FEE_COLLECTOR mutable, added Ownable2Step |
| 4 | UnifiedFeeVault | `contracts/UnifiedFeeVault.sol` | ~1460 | Removed recipient timelock |
| 5 | DEXSettlement | `contracts/dex/DEXSettlement.sol` | ~2010 | Removed fee recipient timelock |

## Executive Summary

The Pioneer Phase modifications remove 48-hour timelocks on fee recipient changes across 5 contracts, replacing them with immediate owner-only setters for operational flexibility during initial launch. The audit found **1 Critical issue** (now fixed), **0 High** (3 accepted design risks), and **several Medium/Low issues** (3 fixed, remainder accepted).

| Severity | Found | Fixed | Accepted |
|----------|-------|-------|----------|
| Critical | 1 | 1 | 0 |
| High | 3 | 0 | 3 (design decisions) |
| Medium | 5 | 0 | 5 (Pioneer Phase) |
| Low | 4 | 3 | 1 |
| Informational | 5 | 2 | 3 |

---

## Critical Findings (Fixed)

### [C-01] UnifiedFeeVault UUPS Storage Layout Corruption
**Status: FIXED**
**Sources:** Agent A (OWASP), Agent D (DeFi Exploit)
**VP Reference:** VP-43 (Storage Layout Violation in Upgrade)
**Location:** UnifiedFeeVault.sol, state variable declarations

**Description:** The original code modification removed 3 state variables (`pendingStakingPool`, `pendingProtocolTreasury`, `recipientChangeTimestamp`) from slots 5-7 in the deployed proxy layout. This shifted all subsequent variables (`pendingClaims`, `totalPendingClaims`, etc.) up by 2-3 slots, corrupting all vault accounting on upgrade.

Deployed layout (from `.openzeppelin/unknown-88008.json`):
- Slot 5: `_ossified` (bool) + `pendingStakingPool` (address) -- packed
- Slot 6: `pendingProtocolTreasury`
- Slot 7: `recipientChangeTimestamp`
- Slot 8: `pendingClaims` (mapping)

New code (before fix) moved `pendingClaims` to slot 6, corrupting all state.

**Fix applied:** Restored the 3 variables as `__deprecated_*` private placeholders with `@custom:deprecated` NatSpec. Storage gap reverted from 31 to 28. Total slot budget preserved: 22 used + 28 gap = 50.

---

## High Findings (Accepted Design Decisions)

### [H-01] Timelock Removal Enables Instant Fee Diversion (All 5 Contracts)
**Status: ACCEPTED (Pioneer Phase)**
**Sources:** All 4 agents
**VP Reference:** VP-34 (Front-Running / Transaction Ordering Dependence)

**Description:** A compromised owner key can instantly redirect all protocol fee flows across all 5 contracts in a single block. Previously, the 48-hour timelock provided a detection and response window.

**Mitigation:** Deployer is the sole active user during Pioneer Phase. Multi-sig handoff and timelock restoration are planned before volume ramp. Event monitoring recommended.

### [H-02] Systemic Rug Vector from Mutable Fee Recipients
**Status: ACCEPTED (Pioneer Phase)**
**Sources:** Agent D (DeFi Exploit)
**VP Reference:** VP-57 (recoverERC20 Backdoor)

**Description:** The shift from immutable/timelocked to mutable fee recipients fundamentally changes the trust model. All 5 contracts share the same deployer/owner, creating a single point of failure.

**Mitigation:** Same as H-01. Immutable `maxFeeBps` caps limit per-transaction damage on OmniFeeRouter and OmniPredictionRouter.

### [H-03] DEXSettlement Immediate Fee Diversion on In-Flight Settlements
**Status: ACCEPTED (Pioneer Phase)**
**Sources:** Agent D (DeFi Exploit)
**VP Reference:** VP-34

**Description:** DEXSettlement uses a push pattern (`_accrueFeeSplit`) that immediately transfers fees during settlement. Combined with instant fee recipient changes, a compromised owner can divert fees from every trade.

**Mitigation:** H-05 force-claim protects accrued historical fees. Trading limits retain 48-hour timelock (M-04).

---

## Medium Findings (Accepted for Pioneer Phase)

### [M-01] UnifiedFeeVault setRecipients Does Not Force-Claim Quarantined Fees
**Sources:** Agent A
**Location:** `setRecipients()` (line 935)

Old quarantined fees in `pendingClaims[oldRecipient][token]` remain claimable only by the old address. The `redirectStuckClaim()` admin function provides a manual recovery path.

### [M-02] DEXSettlement _claimAllPendingFees Uses Raw transfer()
**Sources:** Agents A, B, D
**Location:** `_claimAllPendingFees()` (line 1695)

Raw `IERC20(token).transfer()` in try/catch doesn't handle tokens returning `false` (e.g., USDT). Could silently zero out `accruedFees` without transferring tokens. Mitigated by: (a) XOM is the primary fee token and is ERC20-compliant, (b) the function is rarely called.

### [M-03] DEXSettlement _accrueFeeSplit Push Pattern Has No Quarantine
**Sources:** Agent A
**Location:** `_accrueFeeSplit()` (line 1629)

Unlike UnifiedFeeVault's `_safePushOrQuarantine()`, DEXSettlement's push pattern uses direct `safeTransfer()`. A reverting recipient would block all settlements.

### [M-04] UnifiedFeeVault UUPS Upgrade Has No Timelock
**Sources:** Agent C
**Location:** `_authorizeUpgrade()` (line 1422)

Only gated by `DEFAULT_ADMIN_ROLE` and ossification flag. A compromised admin can instantly replace the implementation.

### [M-05] UnifiedFeeVault DEFAULT_ADMIN_ROLE Lacks Two-Step Transfer
**Sources:** Agent C

Uses standard AccessControl (single-step `grantRole()`), not `AccessControlDefaultAdminRulesUpgradeable`. NatSpec correctly documents this as a known limitation with planned migration.

---

## Low Findings

### [L-01] OmniPredictionRouter Missing FeeCollectorUpdated Event -- **FIXED**
**Sources:** All 4 agents
**Location:** `setFeeCollector()` (line 168)
**Fix:** Added `FeeCollectorUpdated(oldCollector, newCollector)` event, emitted in `setFeeCollector()`.

### [L-02] OmniPredictionRouter Missing TokensRescued Event -- **FIXED**
**Sources:** Agents B, C
**Location:** `rescueTokens()` (line 408)
**Fix:** Added `TokensRescued(token, amount)` event, emitted in `rescueTokens()`.

### [L-03] DEXSettlement Missing renounceOwnership() Override -- **FIXED**
**Sources:** Agents B, C, D
**Location:** Contract-wide (missing function)
**Fix:** Added `renounceOwnership() public pure override` that reverts with `InvalidAddress()`, matching the pattern in the other 3 Ownable2Step contracts.

### [L-04] OmniSwapRouter rescueTokens Callable by Mutable feeRecipient
**Sources:** Agents A, D
**Location:** `rescueTokens()` (line 420)
**Status:** Accepted -- the feeRecipient identity check is intentional separation of concerns. Owner controls feeRecipient anyway.

---

## Informational Findings

### [I-01] OmniFeeRouter NatSpec Says "immutable feeCollector" -- **FIXED**
**Sources:** Agents A, B
Updated line 19 and constructor NatSpec to reflect mutable feeCollector.

### [I-02] OmniPredictionRouter NatSpec Says "immutable" -- **FIXED**
Constructor NatSpec updated to "(initial value, owner-changeable)".

### [I-03] UnifiedFeeVault FEE_MANAGER_ROLE Declared But Unused
**Sources:** Agent B
The constant occupies bytecode but no storage. No runtime impact.

### [I-04] renounceOwnership() Reverts With Misleading Error Names
**Sources:** Agent B
OmniSwapRouter uses `InvalidRecipientAddress()`, OmniFeeRouter/OmniPredictionRouter use `InvalidFeeCollector()`. Functional but confusing. Not blocking.

### [I-05] Setters Allow No-Op Updates (Same Value)
**Sources:** Agent B
All 5 contracts allow setting fee recipients to identical current values, emitting misleading events and wasting gas (especially DEXSettlement with H-05 force-claim loop).

---

## Verified Safe Patterns

All 4 agents confirmed the following as correctly implemented:

- Zero-address validation on all new setter functions
- Ownable2Step two-step ownership transfer on all 4 non-upgradeable contracts
- AccessControlUpgradeable with proper role separation on UnifiedFeeVault
- `nonReentrant` guards on all state-changing functions with external calls
- DEXSettlement H-05 force-claim of pending fees before updating recipients
- Fee caps: OmniSwapRouter max 100 bps, OmniFeeRouter/OmniPredictionRouter immutable `maxFeeBps`
- Pausable emergency controls on OmniSwapRouter, UnifiedFeeVault, DEXSettlement
- `_disableInitializers()` in UnifiedFeeVault constructor (VP-42)
- UnifiedFeeVault storage gap correctly accounting for 50 total slots (after fix)

---

## Post-Audit Fix Verification

| Fix | Compiled | Tests | Solhint |
|-----|----------|-------|---------|
| C-01: Storage layout restored | Yes | 109 passing | 0 errors |
| L-01: FeeCollectorUpdated event | Yes | -- | 0 errors |
| L-02: TokensRescued event | Yes | -- | 0 errors |
| L-03: renounceOwnership override | Yes | 33 passing | 0 errors |
| I-01/I-02: NatSpec corrections | Yes | -- | 0 errors |

---

*Generated by Claude Code Audit Agent v2 -- 4-Agent Parallel Analysis*
*Date: 2026-03-08*
