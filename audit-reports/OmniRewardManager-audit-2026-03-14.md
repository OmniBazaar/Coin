# Security Audit Report: OmniRewardManager

**Date:** 2026-03-14
**Audited by:** Claude Code Audit Agent (7-Pass Enhanced)
**Contract:** `Coin/contracts/OmniRewardManager.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,550
**Compiled Size:** 16.982 KiB (under 24 KiB limit)
**Upgradeable:** Yes (UUPS with ossify())
**Handles Funds:** Yes (~6.378B XOM across 3 pre-funded reward pools)

## Executive Summary

OmniRewardManager is a well-structured UUPS upgradeable reward distribution contract managing three bonus pools (Welcome 1.383B XOM, Referral 2.995B XOM, First Sale 2B XOM) via gasless EIP-712 relay pattern. The recent refactoring removed 7 non-relayed functions and merkle infrastructure, significantly reducing attack surface. One **Critical** finding was discovered: a double-claim vulnerability via the unregister/re-register cycle in the companion OmniRegistration contract. Two **High** findings relate to UUPS upgrader escalation (inherent) and trusted forwarder compromise risk. Several **Medium** and **Low** findings address admin centralization, shared nonces, and input validation inconsistencies.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 2 |
| Medium | 4 |
| Low | 4 |
| Informational | 5 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 78 |
| Passed | 67 |
| Failed | 2 |
| Partial | 9 |
| **Compliance Score** | **85.9%** |

Top failed/partial checks:
1. SOL-Basics-Function-1: Missing zero-address check in `claimFirstSaleBonus`
2. SOL-AM-RP-1: `setPendingReferralBonus` lacks timelock (admin rug-pull vector)
3. SOL-CR-4: `setOddaoAddress` and `setLegacyBonusClaimsCount` lack timelocks
4. SOL-Timelock-1: Three admin functions changeable immediately
5. SOL-EC-12: No code-existence check on `registrationContract` address

---

## Critical Findings

### [C-01] Double-Claim via Unregister/Re-register Cycle

**Severity:** Critical
**Category:** Business Logic (SC02)
**VP Reference:** VP-34 (State Machine Violation)
**Location:** `claimWelcomeBonus()` line 774, `claimFirstSaleBonus()` line 1000
**Sources:** Adversarial Hacker Review (Pass 5)
**Confidence:** 95%

**Description:**
The `claimWelcomeBonus()` function checks double-claim protection solely via `reg.welcomeBonusClaimed` from the external `registrationContract` (line 774). It does NOT check the local `welcomeBonusClaimed[user]` mapping (line 803), which is set but never consulted as a guard. If an admin on `OmniRegistration` calls `adminUnregister(user)`, it resets the registration struct including `welcomeBonusClaimed = false`. The user can then re-register and claim again. The same applies to `claimFirstSaleBonus()` and `firstSaleBonusClaimed[user]`.

**Exploit Scenario:**
1. Alice claims welcome bonus (10,000 XOM). `welcomeBonusClaimed[Alice] = true` locally, `reg.welcomeBonusClaimed = true` in registration contract.
2. OmniRegistration admin calls `adminUnregister(Alice)`. Registration struct deleted, `welcomeBonusClaimed` reset to `false`.
3. Alice re-registers with fresh credentials, completes KYC Tier 1.
4. Alice claims welcome bonus again -- line 774 checks `reg.welcomeBonusClaimed` which is now `false`. Local mapping `welcomeBonusClaimed[Alice]` is `true` but **never checked**.
5. Repeat to drain pool.

**Estimated Impact:** Could drain the entire 1.383B XOM welcome pool plus cascade 2.995B XOM in referral bonuses. Requires admin collusion on OmniRegistration.

**Recommendation:**
Add local mapping checks as guards (2-line fix per function):

In `claimWelcomeBonus`, after line 776:
```solidity
if (welcomeBonusClaimed[user]) {
    revert BonusAlreadyClaimed(user, PoolType.WelcomeBonus);
}
```

In `claimFirstSaleBonus`, after line 1001:
```solidity
if (firstSaleBonusClaimed[user]) {
    revert BonusAlreadyClaimed(user, PoolType.FirstSaleBonus);
}
```

---

## High Findings

### [H-01] UPGRADER_ROLE Can Escalate to Full Admin via Malicious Upgrade

**Severity:** High
**Category:** Access Control / Privilege Escalation (SC01)
**VP Reference:** VP-42 (Uninitialized Implementation)
**Location:** `_authorizeUpgrade()` line 1467
**Sources:** Agent-C (Access Control), Cyfrin Checklist
**Real-World Precedent:** Standard UUPS risk documented by Trail of Bits and OpenZeppelin

**Description:**
An address with UPGRADER_ROLE can deploy a malicious implementation that grants DEFAULT_ADMIN_ROLE to the attacker, enabling full contract takeover. This is inherent to the UUPS pattern. Mitigated by `ossify()` (line 1448) and documented timelock requirement (NatSpec at line 1256).

**Recommendation:**
- Ensure UPGRADER_ROLE is held ONLY by a TimelockController (48h+ delay)
- Ossify the contract once mature
- Already documented at line 1255-1258; enforce operationally

---

### [H-02] Trusted Forwarder Compromise Enables Admin Impersonation

**Severity:** High
**Category:** Access Control (SC01)
**VP Reference:** VP-09 (Unsafe Delegatecall / ERC-2771)
**Location:** `_msgSender()` line 1512-1519, constructor line 481-484
**Sources:** Adversarial Hacker Review

**Description:**
The ERC-2771 trusted forwarder is immutable (set in constructor). If the forwarder contract is compromised, an attacker can craft calls that append the admin's address to calldata, causing `_msgSender()` to return the admin address. All role-gated functions (`setRegistrationContract`, `setPendingReferralBonus`, etc.) use `_msgSender()` via `onlyRole()`.

**Recommendation:**
- Ensure forwarder is a battle-tested OpenZeppelin implementation with no upgradeability
- Consider using `msg.sender` directly (bypassing `_msgSender()`) for the most sensitive admin functions
- The contract already acknowledges this at lines 475-479

---

## Medium Findings

### [M-01] Shared Nonce Counter Across Three Claim Types

**Severity:** Medium
**Category:** Business Logic (SC02)
**VP Reference:** VP-34 (Front-Running / Transaction Ordering)
**Location:** `claimNonces` mapping used at lines 765, 930, 1017
**Sources:** Agent-A (OWASP), Solodit Cross-Reference
**Real-World Precedent:** Symmetrical (SYMMIO) H-7 -- nonce increment blocking liquidation; Across Protocol -- incorrect shared nonce in Permit2

**Description:**
A single `claimNonces[user]` counter is shared across all three claim functions. If a user signs a welcome bonus claim with nonce=0 AND a referral claim with nonce=0, only the first submitted succeeds. The second reverts with `InvalidClaimNonce`. This creates a race condition between relayers submitting different bonus types for the same user.

**Recommendation:**
This is partially mitigated by natural claim ordering (welcome must precede referral). Document this behavior. Consider per-type nonces if concurrent claims become a UX issue:
```solidity
mapping(address => mapping(PoolType => uint256)) public claimNonces;
```

---

### [M-02] Admin Functions Lack Timelocks (Centralization Risk)

**Severity:** Medium
**Category:** Centralization Risk (SOL-CR-4)
**VP Reference:** VP-06 (Missing Access Control)
**Location:** `setOddaoAddress()` line 612, `setPendingReferralBonus()` line 674, `setLegacyBonusClaimsCount()` line 634
**Sources:** Agent-C (Access Control), Cyfrin Checklist (SOL-Timelock-1)

**Description:**
Three admin functions take effect immediately:
- `setOddaoAddress()`: Can instantly redirect 10% of all referral bonuses
- `setPendingReferralBonus()`: Can create claimable balances up to pool remaining
- `setLegacyBonusClaimsCount()`: Can manipulate bonus tier calculations (capped at 10M)

Only `setRegistrationContract()` has a 48-hour timelock.

**Recommendation:**
- Add timelocks to `setOddaoAddress()` and `setLegacyBonusClaimsCount()`
- Add a `migrationFinalized` flag to permanently lock `setPendingReferralBonus` after migration
- Use Gnosis Safe multi-sig (3-of-5) for DEFAULT_ADMIN_ROLE

---

### [M-03] First Sale Bonus Uses Different Tier Base Than Welcome/Referral

**Severity:** Medium
**Category:** Business Logic (SC02)
**VP Reference:** VP-16 (Off-By-One / Calculation Inconsistency)
**Location:** `claimWelcomeBonus` line 792 vs `claimFirstSaleBonus` line 1020
**Sources:** Agent-B (Business Logic)

**Description:**
Welcome bonus tier uses `welcomeBonusClaimCount + legacyBonusClaimsCount` (line 792), which tracks actual bonus payouts. First sale bonus tier uses `registrationContract.totalRegistrations() + legacyBonusClaimsCount` (line 1020), which tracks total registrations. These diverge because not all registered users claim welcome bonuses. The auto-referral bonus (triggered inside `claimWelcomeBonus`) uses the welcome bonus count, meaning referral tiers track welcome bonus claims.

**Recommendation:**
This appears intentional (documented in M-04 comment at line 1167) but creates inconsistency. Document the design rationale prominently in NatSpec.

---

### [M-04] Daily Rate Limit Exhaustion by Sybil Accounts

**Severity:** Medium
**Category:** Denial of Service (SC09)
**VP Reference:** VP-29 (DoS via Resource Exhaustion)
**Location:** `MAX_DAILY_WELCOME_BONUSES` (1000/day), line 785-788
**Sources:** Adversarial Hacker Review

**Description:**
An attacker with 1,000 Sybil accounts (each with unique KYC Tier 1) could exhaust the daily welcome bonus limit, blocking all legitimate users for 24 hours. Each Sybil account legitimately claims 625+ XOM, so the attacker profits while griefing.

**Recommendation:**
KYC Tier 1 requirement (unique phone + social) makes mass Sybil creation expensive. Current limits are reasonable. Consider per-validator-relayer rate limits for additional protection.

---

## Low Findings

### [L-01] Missing Zero-Address Check in claimFirstSaleBonus

**Severity:** Low
**Location:** `claimFirstSaleBonus()` line 962
**Sources:** Agent-A (OWASP), Cyfrin Checklist (SOL-Basics-Function-1)

**Description:**
Unlike `claimWelcomeBonus` (line 740) and `claimReferralBonus` (line 889), `claimFirstSaleBonus` lacks an explicit `if (user == address(0)) revert ZeroAddressNotAllowed()` check. Implicitly protected by `ECDSA.recover` and registration check, but inconsistent.

**Recommendation:**
Add `if (user == address(0)) revert ZeroAddressNotAllowed();` for consistency.

---

### [L-02] Division Before Multiplication in Referral Distribution (Dust)

**Severity:** Low
**Location:** `_distributeAutoReferralBonus()` lines 1414-1416
**Sources:** Agent-A (OWASP)
**VP Reference:** VP-13 (Precision Loss)

**Description:**
Referral distribution uses separate divisions: `(referralAmount * 70) / 100` and `(referralAmount * 20) / 100`. The residual goes to ODDAO via subtraction (line 1416), capturing any rounding dust. With current tier values (all multiples of 100 at 18 decimals), division is exact and produces zero dust.

**Recommendation:**
No action needed. The residual-to-ODDAO pattern is sound.

---

### [L-03] No Code-Existence Check on registrationContract Address

**Severity:** Low
**Location:** `setRegistrationContract()` lines 572-578
**Sources:** Cyfrin Checklist (SOL-EC-12)

**Description:**
When admin sets `registrationContract`, there is no `extcodesize` check. If set to an EOA, calls to `getRegistration()` etc. would return default values or revert unexpectedly.

**Recommendation:**
Add `require(_registrationContract.code.length > 0, "Not a contract")` in `setRegistrationContract()`.

---

### [L-04] Legacy Claims Count Can Only Increase (No Monotonicity Constraint)

**Severity:** Low
**Location:** `setLegacyBonusClaimsCount()` line 634
**Sources:** Adversarial Hacker Review

**Description:**
`legacyBonusClaimsCount` can be set to any value 0 to 10M. Setting it to 0 pushes users into higher tiers (10,000 XOM instead of 625 XOM). Setting it to 10M pushes users into the lowest tier.

**Recommendation:**
Add monotonicity constraint (only increase) if the intent is one-time migration:
```solidity
if (_count < legacyBonusClaimsCount) revert LegacyClaimsCountCannotDecrease();
```

---

## Informational Findings

### [I-01] Solhint: 28 State Variables Exceed Recommended 20

**Location:** Contract-wide
**Description:** Many are storage gaps (`__gap_removed_*`) for UUPS compatibility. This is expected and necessary.

### [I-02] Code Complexity: 4 Functions Exceed Complexity 7

**Location:** `claimWelcomeBonus` (12), `claimFirstSaleBonus` (10), `claimReferralBonus` (9), `_distributeAutoReferralBonus` (10)
**Description:** These functions have high cyclomatic complexity due to multi-step validation. Consider extracting validation into internal functions.

### [I-03] PUSH0 Opcode -- No Explicit evmVersion in Hardhat Config

**Location:** `hardhat.config.js` lines 85-96
**Description:** Solidity 0.8.24 defaults to `cancun` EVM which uses PUSH0. Safe on Avalanche post-Durango but not explicitly configured.

### [I-04] No Token Recovery Function for Excess/Donated Tokens

**Location:** Contract-wide
**Description:** Tokens accidentally sent beyond pool allocations are permanently locked. No `recoverERC20()` exists. This is a conservative design choice.

### [I-05] Timestamp Dependence in Rate Limiting

**Location:** Lines 784, 923, 1010, 1369, 1378
**Description:** Daily/epoch rate limits use `block.timestamp / 1 days` and `block.timestamp / REFERRAL_EPOCH_DURATION`. Validators have ~2s block time manipulation capability, insufficient to bypass limits.

---

## Adversarial Hacker Review

### Viable Exploits Found

| # | Attack Name | Severity | Attacker Profile | Confidence | Impact |
|---|------------|----------|------------------|------------|--------|
| 1 | Double-Claim via Unregister/Re-register | Critical | Admin on OmniRegistration | 95% | Full pool drain (~6.378B XOM) |
| 2 | Admin Key Full Pool Drain | Critical (centralization) | DEFAULT_ADMIN_ROLE compromise | 99% | Full pool drain |
| 3 | Trusted Forwarder Impersonation | High | Forwarder contract compromise | 90% | Full admin takeover |
| 4 | Daily Rate Limit DoS | Medium | 1000 Sybil KYC accounts | 75% | 24h service disruption |
| 5 | Legacy Claims Count Manipulation | Medium | DEFAULT_ADMIN_ROLE | 95% | Tier gaming |

### Investigated But No Exploit Found

| Attack Category | Defense |
|----------------|---------|
| Cross-chain signature replay | EIP-712 domain includes chainId and contract address |
| Nonce griefing | Signature verification prevents consuming others' nonces |
| Fake IOmniRegistration deployment | 48-hour timelock on registration contract changes |
| Front-running relayer | Tokens sent to `user` (verified by signature), not `msg.sender` |
| Circular referral chains | One-time per welcome bonus; no amplification loop |
| Reentrancy | `nonReentrant` modifier on all claim functions |
| Claiming without registration | `reg.timestamp == 0` + KYC Tier 1 checks |
| Inflating totalRegistrations | Rate-limited to 10K/day in OmniRegistration |
| setPendingReferralBonus unbacked claims | Pool accounting properly adjusted (lines 686-696) |
| Griefing auto-referral to block welcome claims | `return` (not `revert`) when limit exceeded |
| Ossify griefing | Only prevents upgrades; contract continues functioning |

---

## Static Analysis Summary

### Slither (v0.11.5)
46 findings total:
- **2 Medium** (`reentrancy-no-eth`): `claimWelcomeBonus` and `claimFirstSaleBonus` have external calls before state updates. **FALSE POSITIVE** -- both functions have `nonReentrant` modifier.
- **6 Low**: 2 benign reentrancy, 4 timestamp dependencies (all intentional for rate limiting)
- **32 Informational**: 17 naming conventions, 7 too-many-digits, 7 unused-state (storage gaps), 1 dead-code
- **5 Optimization**: constable-states for `__gap_removed_*` variables (expected for UUPS gaps)

### Mythril (v0.24.8)
Timed out. No results produced within 300-second analysis window. This is common for large contracts with many external calls and complex control flow.

### Aderyn (v0.1.9)
Not run due to known `StripPrefixError` bug with workspace-hoisted `node_modules`.

### Solhint
48 warnings, 0 errors:
- `max-states-count` (28 vs 20): Expected for UUPS with storage gaps
- `code-complexity` (4 functions): High but necessary for multi-step validation
- `not-rely-on-time` (6): All intentional for rate limiting
- `gas-strict-inequalities` (14): `<=` used for tier boundaries
- `gas-indexed-events` (10): Some event params unindexed by design
- `gas-small-strings` (6): EIP-712 typehashes necessarily > 32 bytes

---

## Solodit Similar Findings

| Protocol | Finding | Severity | Relevance |
|----------|---------|----------|-----------|
| Symmetrical (SYMMIO) | H-7: Shared nonce blocks liquidation | High | Directly analogous shared nonce pattern |
| Across Protocol | Incorrect nonce in Permit2.permit | Medium | Same per-operation nonce recommendation |
| Biconomy Nexus | Missing nonce enables signature replay | High | Validates importance of independent nonces |

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `setRegistrationContract`, `applyRegistrationContract`, `setOddaoAddress`, `setLegacyBonusClaimsCount`, `setPendingReferralBonus`, `reinitializeV2`, `grantRole`, `revokeRole` | 7/10 |
| UPGRADER_ROLE | `_authorizeUpgrade`, `ossify` | 8/10 |
| PAUSER_ROLE | `pause`, `unpause` | 3/10 |
| (Permissionless) | `claimWelcomeBonus`, `claimReferralBonus`, `claimFirstSaleBonus` (all require user EIP-712 signature) | 2/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised DEFAULT_ADMIN_ROLE key could:
1. Set pending referral bonus to drain up to `referralBonusPool.remaining` (~2.995B XOM)
2. Change ODDAO address to redirect 10% of all future referral distributions
3. Manipulate legacy claims count to alter bonus tiers
4. Queue registration contract change (blocked by 48h timelock)

**Risk Rating:** 7/10

**Recommendation:** Use Gnosis Safe multi-sig (3-of-5 minimum) with TimelockController for DEFAULT_ADMIN_ROLE. Grant UPGRADER_ROLE to a separate TimelockController. Grant PAUSER_ROLE to an emergency response multisig.

---

## Priority Fix List

1. **CRITICAL (C-01):** Add local `welcomeBonusClaimed[user]` and `firstSaleBonusClaimed[user]` as guards in claim functions. **2-line fix per function.**
2. **LOW (L-01):** Add zero-address check to `claimFirstSaleBonus`. **1-line fix.**
3. **MEDIUM (M-02):** Add timelocks to `setOddaoAddress` and add `migrationFinalized` flag for `setPendingReferralBonus`.
4. **MEDIUM (M-01):** Document shared nonce behavior in NatSpec (or implement per-type nonces).
5. **LOW (L-04):** Add monotonicity constraint to `setLegacyBonusClaimsCount`.
6. **HIGH (H-01/H-02):** Operational -- ensure UPGRADER_ROLE behind timelock; audit trusted forwarder contract.

---

*Generated by Claude Code Audit Agent v3 -- 7-Pass Enhanced with exploit database cross-referencing and adversarial attack simulation*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings, adversarial hacker review*
*Static tools: Slither v0.11.5, Solhint, Mythril v0.24.8 (timed out)*
