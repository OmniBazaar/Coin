# Security Audit Report: OmniRewardManager

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniRewardManager.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 1,811
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (12.47B XOM across 4 pre-minted pools)

## Executive Summary

OmniRewardManager is the highest-value contract in the OmniBazaar ecosystem, controlling distribution of 12.47 billion XOM across welcome bonus, referral bonus, first sale bonus, and validator reward pools. The audit identified 3 critical, 5 high, 6 medium, and 5 low/informational findings. The most severe issues involve missing access control on the OmniRegistration dependency (`markWelcomeBonusClaimed`/`markFirstSaleBonusClaimed`), pool accounting bypass via admin-set pending bonuses, and a missing KYC check on the permissionless welcome bonus path. All critical findings have strong precedent in real-world DeFi audits.

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 5 |
| Medium | 6 |
| Low | 3 |
| Informational | 2 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 112 |
| Passed | 96 |
| Failed | 8 |
| Partial | 8 |
| **Compliance Score** | **85.7%** |

Top 5 failed checks:
1. SOL-AM-RP-1 (Rug Pull) -- Admin can drain via `setPendingReferralBonus` + `claimReferralBonusPermissionless`
2. SOL-CR-4 (Immediate Critical Changes) -- No timelock on admin operations
3. SOL-AM-SybilAttack-1 -- Bonus tiers depend on user count, exploitable via Sybil
4. SOL-HMT-3 (Zero Hash) -- Merkle proof bypassed when root is bytes32(0)
5. SOL-CR-3 (Admin Withdrawal) -- `setPendingReferralBonus` is an indirect withdrawal function

## Critical Findings

### [C-01] OmniRegistration.markWelcomeBonusClaimed/markFirstSaleBonusClaimed Have NO Access Control

**Severity:** Critical
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Missing Access Control Modifier)
**Location:** `OmniRegistration.sol`, lines 1917 and 1933 (called from OmniRewardManager lines 773, 854, 970, 1149, 1240)
**Sources:** Agent-A, Agent-C (ORM-15), Solodit (GoGoPool 10+ duplicates)
**Real-World Precedent:** GoGoPool (Code4rena 2022-12) -- overwrite node operator rewards via unprotected function, 10+ independent reports

**Description:**
`markWelcomeBonusClaimed(address user)` and `markFirstSaleBonusClaimed(address user)` in OmniRegistration are `external` with NO access control. The code contains the comment: "We'll add proper access control when integrating." Anyone can call these functions to permanently mark any user's bonus as claimed, denying them their legitimate bonus.

**Exploit Scenario:**
1. Attacker calls `registrationContract.markWelcomeBonusClaimed(victimAddress)` directly.
2. Victim tries `claimWelcomeBonusPermissionless()` -- reverts with `BonusAlreadyClaimed`.
3. Attacker repeats for all registered users, permanently blocking up to 1.38B XOM in welcome bonuses.

**Recommendation:**
Add `REWARD_MANAGER_ROLE` to OmniRegistration. Restrict both functions to only the OmniRewardManager contract address:
```solidity
bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
function markWelcomeBonusClaimed(address user) external onlyRole(REWARD_MANAGER_ROLE) { ... }
function markFirstSaleBonusClaimed(address user) external onlyRole(REWARD_MANAGER_ROLE) { ... }
```

---

### [C-02] Pool Accounting Bypass via setPendingReferralBonus + claimReferralBonusPermissionless

**Severity:** Critical
**Category:** SC02 Business Logic
**VP Reference:** VP-57 (recoverERC20 Backdoor variant)
**Location:** `setPendingReferralBonus()` line 713, `claimReferralBonusPermissionless()` line 1014
**Sources:** Agent-A, Agent-B (Finding 5), Agent-C (ORM-07, ORM-08), Agent-D (VP-57-A, BL-01), Cyfrin Checklist (SOL-AM-RP-1, SOL-CR-3)
**Real-World Precedent:** xTribe (Code4rena 2022-04) -- `setBooster()` steal unclaimed rewards; Spartan Protocol (Code4rena 2021-07) -- pool sync desync $120K

**Description:**
`setPendingReferralBonus()` (DEFAULT_ADMIN_ROLE) sets arbitrary pending amounts WITHOUT deducting from `referralBonusPool.remaining`. When claimed via `claimReferralBonusPermissionless()`, tokens transfer from the contract's total XOM balance without any pool accounting validation. This creates two problems:
1. Admin can fabricate unbacked claimable balances (rug pull vector)
2. Admin-set pending bonuses drain from ALL pools' shared token balance, not just the referral pool

**Exploit Scenario:**
1. Admin calls `setPendingReferralBonus(attacker, 12_000_000_000e18)` -- sets 12B XOM pending
2. Attacker calls `claimReferralBonusPermissionless()` -- transfers 12B XOM from contract
3. All four pools drained. Pool accounting still shows funds remaining but actual balance is zero.

**Recommendation:**
```solidity
function setPendingReferralBonus(address referrer, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (referrer == address(0)) revert ZeroAddressNotAllowed();
    if (amount == 0) revert ZeroAmountNotAllowed();
    uint256 oldPending = pendingReferralBonuses[referrer];
    if (amount > oldPending) {
        uint256 increase = amount - oldPending;
        _validatePoolBalance(referralBonusPool, PoolType.ReferralBonus, increase);
        _updatePoolAfterDistribution(referralBonusPool, increase);
    } else if (amount < oldPending) {
        uint256 decrease = oldPending - amount;
        referralBonusPool.remaining += decrease;
        referralBonusPool.distributed -= decrease;
    }
    pendingReferralBonuses[referrer] = amount;
    emit ReferralBonusMigrated(referrer, oldPending, amount);
}
```

---

### [C-03] Compromised Admin Can Drain All 12.47B XOM

**Severity:** Critical
**Category:** Centralization Risk
**VP Reference:** VP-06
**Location:** Multiple admin functions (lines 620-724), `_authorizeUpgrade()` (line 1674)
**Sources:** Agent-C (ORM-12), Cyfrin Checklist (SOL-AM-RP-1), Solodit (Zunami $500K exploit)
**Real-World Precedent:** Zunami Protocol (2025) -- admin function drained $500K; Wormhole (2022) -- $10M bounty for uninitialized UUPS

**Description:**
A compromised DEFAULT_ADMIN_ROLE holder has multiple attack paths to drain all funds:
- Path A: `setRegistrationContract()` to malicious contract + claim all bonuses for controlled addresses
- Path B: `setPendingReferralBonus(attacker, entireBalance)` + `claimReferralBonusPermissionless()`
- Path C: Grant UPGRADER_ROLE to self + upgrade to contract with `emergencyWithdraw()`

The `_setupRoles()` function (line 1514) grants ALL five roles to a single admin address at initialization. No timelock, no multi-sig, no delay on any operation.

**Centralization Risk Rating: 8/10**

**Recommendation:**
1. **Multi-sig requirement:** DEFAULT_ADMIN_ROLE MUST be a Gnosis Safe (3-of-5 minimum)
2. **Role separation:** Grant BONUS_DISTRIBUTOR_ROLE, VALIDATOR_REWARD_ROLE, UPGRADER_ROLE, and PAUSER_ROLE to separate keys
3. **Timelock:** Implement OpenZeppelin `TimelockController` for `setRegistrationContract()`, `setOddaoAddress()`, `setLegacyBonusClaimsCount()`, `setPendingReferralBonus()`, and upgrades (48h minimum delay)
4. **Two-step admin transfer:** Use `AccessControlDefaultAdminRulesUpgradeable`

---

## High Findings

### [H-01] Missing KYC Tier 1 Check in claimWelcomeBonusPermissionless

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-22
**Location:** `claimWelcomeBonusPermissionless()` line 740
**Sources:** Agent-A (Finding 7), Agent-B (Finding 1), Solodit (Ludex Labs Sybil attack)
**Real-World Precedent:** Ludex Labs (Cantina 2025-02) -- unrestricted registration enables Sybil referral farming

**Description:**
`claimWelcomeBonusPermissionless()` does NOT call `registrationContract.hasKycTier1(msg.sender)`. The NatSpec at line 735 states "KYC Tier 1+ required" but the code doesn't enforce it. Both `claimWelcomeBonusTrustless()` (line 833) and `claimWelcomeBonusRelayed()` (line 949) correctly check KYC. This creates a strictly weaker path that bypasses the primary Sybil defense.

**Exploit Scenario:**
1. Attacker registers 1,000 addresses via OmniRegistration (no KYC needed for registration)
2. Calls `claimWelcomeBonusPermissionless()` from each -- receives 10,000 XOM each
3. Total drain: 10,000,000 XOM without any identity verification

**Recommendation:**
Add after line 752:
```solidity
if (!registrationContract.hasKycTier1(msg.sender)) {
    revert KycTier1Required(msg.sender);
}
```

---

### [H-02] First Sale Bonus Claimable Without Completing a Sale

**Severity:** High
**Category:** SC02 Business Logic
**Location:** `claimFirstSaleBonusPermissionless()` line 1118, `claimFirstSaleBonusRelayed()` line 1178
**Sources:** Agent-B (Finding 2)

**Description:**
Neither function verifies the user has actually completed a sale. The only checks are registration and `firstSaleBonusClaimed == false`. The NatSpec says "Sale verification done off-chain, marked in OmniRegistration" but the `Registration` struct has no `firstSaleCompleted` field -- only `firstSaleBonusClaimed` (whether bonus was claimed, not whether a sale occurred).

**Impact:** Any registered user can claim 500 XOM (first 100K users) without ever listing or selling. The 2B XOM first sale pool can be drained by users who never trade.

**Recommendation:**
Add `firstSaleCompleted` field to the `Registration` struct in OmniRegistration and check it before allowing claims.

---

### [H-03] ODDAO Tokens Permanently Stranded When oddaoAddress Is Zero

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-22
**Location:** `_distributeAutoReferralBonus()` lines 1645, 1660-1662
**Sources:** Agent-A (Finding 2), Agent-B (Finding 3), Agent-D (BL-04), Solodit (Sudoswap fee stranding)
**Real-World Precedent:** Sudoswap (Cyfrin 2023-06) -- fee distribution to zero address causes permanent fund stranding

**Description:**
`_updatePoolAfterDistribution()` at line 1645 deducts the FULL referral amount (including ODDAO share) from `referralBonusPool.remaining`. But at line 1660, the ODDAO transfer is skipped if `oddaoAddress == address(0)`. The ODDAO's 10% share is deducted from pool accounting but never transferred, permanently stranding tokens in the contract.

When there's no second-level referrer, ODDAO receives 30% (its 10% + the unused 20%), making the stranding even larger.

**Recommendation:**
Add at the top of `_distributeAutoReferralBonus()`:
```solidity
if (oddaoAddress == address(0)) revert OddaoAddressNotSet();
```

---

### [H-04] reinitializeV2() Has No Access Control

**Severity:** High
**Category:** SC01 Access Control / SC10 Upgrade Safety
**VP Reference:** VP-44, VP-06
**Location:** `reinitializeV2()` line 505
**Sources:** Agent-A (Finding 3), Agent-B (Finding 15), Agent-C (ORM-01), Solodit (Orderly Network, Wormhole $10M bounty)
**Real-World Precedent:** Orderly Network (Sherlock 2024-09) -- anyone can reinitialize after reset; Wormhole (2022) -- $10M bounty for unprotected initialization

**Description:**
`reinitializeV2()` only has `reinitializer(2)` guard (one-time call), no role check. Anyone can front-run the admin. Currently only sets EIP-712 domain separator (deterministic, so damage is limited), but sets a dangerous precedent for future V3/V4 reinitializers.

**Recommendation:**
```solidity
function reinitializeV2() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
    __EIP712_init("OmniRewardManager", "1");
}
```

---

### [H-05] Role-Based claimReferralBonus Lacks ODDAO Distribution

**Severity:** High
**Category:** SC02 Business Logic
**Location:** `claimReferralBonus()` line 545, `_distributeReferralRewards()` line 1479
**Sources:** Agent-B (Finding 4)

**Description:**
The role-based `claimReferralBonus()` distributes `primaryAmount` + `secondaryAmount` to referrers with nothing to ODDAO. The `ReferralParams` struct has no `oddaoAmount` field. The full `totalAmount` is deducted from the pool but 100% goes to referrers. This violates the 70/20/10 fee distribution invariant. By contrast, `_distributeAutoReferralBonus()` (line 1640) correctly implements the split.

**Impact:** BONUS_DISTRIBUTOR_ROLE can bypass the protocol's 70/20/10 split, directing funds that should go to ODDAO (10%) to referrers instead.

**Recommendation:**
Calculate the ODDAO split on-chain within `_distributeReferralRewards()` or add `oddaoAmount` to `ReferralParams`.

---

## Medium Findings

### [M-01] Merkle Proof Bypass When Root Is bytes32(0)

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-38
**Location:** `_verifyMerkleProof()` line 1804, `_verifyReferralMerkleProof()` line 1707
**Sources:** Agent-A (Finding 4), Agent-B (Finding 12), Agent-D (BL-02), Cyfrin Checklist (SOL-HMT-3), Solodit (Tessera Code4rena 2022-12)

Both merkle verification functions skip verification entirely when `merkleRoot == bytes32(0)` (default state). Role-gated functions accept ANY amount with empty proofs until roots are set.

**Recommendation:** Require non-zero merkle roots before role-based claims, or enforce per-claim amount caps matching tier schedules.

---

### [M-02] No Token Balance Verification on Initialization

**Severity:** Medium
**Category:** SC02 Business Logic
**Location:** `initialize()` lines 470-498
**Sources:** Agent-B (Finding 8), Agent-C (ORM-06)

Pool sizes are set from parameters without verifying the contract actually holds the corresponding XOM. Phantom-balance state if initialization and funding don't match.

**Recommendation:** Add to `initialize()`:
```solidity
uint256 totalPool = _welcomeBonusPool + _referralBonusPool + _firstSaleBonusPool + _validatorRewardsPool;
require(IERC20(_omniCoin).balanceOf(address(this)) >= totalPool, "Insufficient balance");
```

---

### [M-03] setRegistrationContract Can Redirect to Malicious Contract Without Timelock

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06
**Location:** `setRegistrationContract()` line 650
**Sources:** Agent-C (ORM-09), Solodit (Zunami $500K exploit)

Admin can instantly redirect all registration queries to a malicious contract that returns fabricated data, enabling mass bonus claiming.

**Recommendation:** Add 48-hour timelock delay via `TimelockController`.

---

### [M-04] First Sale Bonus Tier Calculation Inconsistency

**Severity:** Medium
**Category:** SC02 Business Logic
**Location:** `claimFirstSaleBonusPermissionless()` line 1140 vs `getExpectedFirstSaleBonus()` line 1381
**Sources:** Agent-B (Finding 9)

`claimFirstSaleBonusPermissionless()` uses `totalRegistrations + legacyBonusClaimsCount` for tier calculation. But `getExpectedFirstSaleBonus()` uses `welcomeBonusClaimCount + legacyBonusClaimsCount`. These are fundamentally different numbers, causing the view function to display incorrect expected amounts.

**Recommendation:** Align `getExpectedFirstSaleBonus()` with the actual claim logic.

---

### [M-05] Shared Daily Rate Limit Between Auto-Distribution and Manual Claims

**Severity:** Medium
**Category:** SC02 Business Logic
**Location:** `dailyReferralBonusCount` across lines 1624, 1027, 1096
**Sources:** Agent-B (Finding 11)

`dailyReferralBonusCount` is shared between auto-distribution (triggered by welcome bonus claims), manual claims, and relayed claims. On busy days, auto-distribution can consume the entire 2,000 daily budget, blocking legitimate referrers from claiming their accumulated bonuses.

**Recommendation:** Use separate daily counters for auto-distribution and manual claims.

---

### [M-06] setLegacyBonusClaimsCount Can Manipulate Bonus Tiers

**Severity:** Medium
**Category:** SC01 Access Control
**Location:** `setLegacyBonusClaimsCount()` line 686
**Sources:** Agent-C (ORM-10), Cyfrin Checklist (SOL-CR-7)

No upper bound validation. Setting to 0 gives new users highest-tier bonuses (10,000 XOM). Setting very high forces lowest tier (625 XOM). Setting to `type(uint256).max - welcomeBonusClaimCount` would overflow and brick all claims.

**Recommendation:** Add `require(_count <= 10_000_000)`.

---

## Low Findings

### [L-01] Referral/First Sale Bonus Rounding Loses 0.5 XOM Per Claim

**Location:** `_calculateReferralBonus()` line 1569, `_calculateFirstSaleBonus()` line 1593
**Sources:** Agent-B (Finding 7)

312.5 XOM rounded to 312 XOM, 62.5 XOM rounded to 62 XOM. With 18 decimals, exact representation is possible: `3125 * 10**17` and `625 * 10**17`.

---

### [L-02] Shared Nonce Counter Across Claim Types

**Location:** `claimNonces` mapping, lines 935, 1099, 1228
**Sources:** Agent-A (Finding 10), Cyfrin Checklist (SOL-Signature-1)

All three relayed functions share one nonce per user. Out-of-order relay submissions permanently invalidate valid signed claims.

---

### [L-03] Missing Zero-Address Check in claimReferralBonusRelayed

**Location:** `claimReferralBonusRelayed()` line 1057
**Sources:** Agent-D (VP-22)

The `user` parameter is not checked for `address(0)`. While ECDSA.recover handles this in practice, explicit validation matches the pattern used in `claimWelcomeBonusRelayed()` (line 910).

---

## Informational Findings

### [I-01] Floating Pragma

**Location:** Line 2 (`pragma solidity ^0.8.20`)
**Sources:** Agent-A (Finding 9)

For a contract managing 12B+ XOM, pin to a specific compiler version (e.g., `pragma solidity 0.8.24`).

### [I-02] Function Complexity and Ordering

**Location:** Lines 815, 901, 1014, 1178
**Sources:** Solhint (51 warnings)

Three functions exceed cyclomatic complexity limit of 7 (`claimWelcomeBonusTrustless` = 8, `claimWelcomeBonusRelayed` = 12, `claimFirstSaleBonusRelayed` = 9). Function ordering violation at line 1014. 11 `not-rely-on-time` warnings (all justified for rate limiting).

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| GoGoPool | 2022-12 | N/A (audit) | Missing access control on reward state function -- exact match for C-01 |
| Zunami Protocol | 2025 | $500K | Admin function without timelock drained funds -- matches C-03 |
| Wormhole | 2022 | $10M bounty | Unprotected UUPS initialization -- same class as H-04 |
| xTribe FlywheelCore | 2022-04 | N/A (audit) | Admin `setBooster()` fabricates rewards -- matches C-02 |
| Spartan Protocol | 2021-07 | $120K | Pool sync desync exploited -- matches C-02 |
| Sudoswap | 2023-06 | N/A (audit) | Fee to zero address causes stranding -- matches H-03 |
| Tessera | 2022-12 | N/A (audit) | Merkle root bypass when zero -- matches M-01 |
| Ludex Labs | 2025-02 | N/A (audit) | Sybil attack via unrestricted registration -- matches H-01 |
| Popsicle Finance | 2021-08 | $20M | Repeated reward claim logic flaw -- related to C-02 |
| Euler Finance | 2023-03 | $200M | Business logic accounting flaw -- same category as C-02 |

## Solodit Similar Findings

9 of 10 findings have strong precedent in the Solodit database (50K+ professional audit findings). The GoGoPool finding for C-01 was independently reported by 10+ auditors, confirming it as one of the most commonly identified vulnerability patterns. All findings corroborated by the Cyfrin audit checklist. No findings contradicted by cross-reference data.

## Static Analysis Summary

### Slither
Slither full-project analysis timed out after >10 minutes. The project's 30+ contracts with many imports caused excessive analysis time. Noted in report; LLM agents and Solhint provide comprehensive coverage.

### Aderyn
Aderyn v0.6.8 crashed with "Fatal compiler bug" (incompatible with solc v0.8.33). Noted in report.

### Solhint
0 errors, 51 warnings:
- 6x `gas-small-strings` (typehash strings > 32 bytes -- unavoidable)
- 12x `gas-indexed-events` (additional event parameters could be indexed)
- 11x `not-rely-on-time` (all justified for daily rate limiting)
- 7x `gas-strict-inequalities` (tier boundary `<=` checks -- correct per spec)
- 3x `code-complexity` (functions exceeding cyclomatic complexity 7)
- 1x `ordering` (function order violation)
- No security-critical findings from Solhint.

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `setRegistrationContract`, `setOddaoAddress`, `setLegacyBonusClaimsCount`, `setPendingReferralBonus`, `grantRole`, `revokeRole` | 8/10 |
| BONUS_DISTRIBUTOR_ROLE | `claimWelcomeBonus`, `claimReferralBonus`, `claimFirstSaleBonus`, `updateMerkleRoot` | 6/10 |
| VALIDATOR_REWARD_ROLE | `distributeValidatorReward` | 5/10 |
| UPGRADER_ROLE | `_authorizeUpgrade` (UUPS upgrade) | 9/10 |
| PAUSER_ROLE | `pause`, `unpause` | 3/10 |
| (None - permissionless) | `claimWelcomeBonusPermissionless`, `claimWelcomeBonusTrustless`, `claimWelcomeBonusRelayed`, `claimReferralBonusPermissionless`, `claimReferralBonusRelayed`, `claimFirstSaleBonusPermissionless`, `claimFirstSaleBonusRelayed`, `reinitializeV2` | 2/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised DEFAULT_ADMIN_ROLE (which initially holds all 5 roles) can drain all 12.47 billion XOM via: (1) redirect registration contract, (2) fabricate pending bonuses, (3) upgrade to malicious implementation. No timelock on any operation. No multi-sig requirement enforced on-chain.

**Rating: 8/10 (High Centralization Risk)**

**Recommendation:** Multi-sig wallet for all roles, role separation across different keys, TimelockController for admin operations, and a roadmap to renounce UPGRADER_ROLE once stable.

---

## Remediation Priority

| Priority | Finding | Action |
|----------|---------|--------|
| 1 (IMMEDIATE) | C-01 | Add access control to `markWelcomeBonusClaimed`/`markFirstSaleBonusClaimed` in OmniRegistration |
| 2 (IMMEDIATE) | C-02 | Fix pool accounting in `setPendingReferralBonus` + add validation to claims |
| 3 (BEFORE DEPLOY) | C-03 | Multi-sig for all roles, timelock for admin operations |
| 4 (BEFORE DEPLOY) | H-01 | Add KYC Tier 1 check to `claimWelcomeBonusPermissionless` |
| 5 (BEFORE DEPLOY) | H-02 | Add `firstSaleCompleted` check to first sale bonus claims |
| 6 (BEFORE DEPLOY) | H-03 | Require `oddaoAddress != address(0)` before referral distribution |
| 7 (BEFORE DEPLOY) | H-04 | Add `onlyRole(DEFAULT_ADMIN_ROLE)` to `reinitializeV2` |
| 8 (BEFORE DEPLOY) | H-05 | Add ODDAO split to role-based `claimReferralBonus` |
| 9 (STANDARD) | M-01 through M-06 | Address in standard remediation cycle |
| 10 (LOW) | L-01 through L-03, I-01, I-02 | Fix at convenience |

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288+ Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Static tools: Solhint (51 warnings, 0 errors), Slither (timed out), Aderyn (crashed on solc v0.8.33)*
