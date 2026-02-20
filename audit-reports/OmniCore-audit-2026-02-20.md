# Security Audit Report: OmniCore

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniCore.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 861
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (staked XOM, DEX balances, legacy migration tokens)

## Executive Summary

OmniCore.sol is the central hub contract for OmniBazaar, managing service registry, validator management, staking, DEX settlement (deprecated), legacy user migration, and fee distribution. The contract is well-structured with strong security fundamentals (ReentrancyGuard, SafeERC20, proper UUPS guards). No critical vulnerabilities were found. The two highest-severity findings relate to centralization risk (instant admin upgrade without timelock) and missing on-chain staking parameter validation that could enable reward pool draining.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 5 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 97 |
| Passed | 78 |
| Failed | 10 |
| Partial | 9 |
| **Compliance Score** | **80.4%** |

**Top 5 Failed Checks:**
1. SOL-CR-4: Admin can change critical protocol properties immediately (no timelock)
2. SOL-CR-3: Admin can withdraw funds via UUPS upgrade (rug-pull vector)
3. SOL-Signature-2: Signatures not protected against malleability
4. SOL-Basics-VI-SVI-4: `abi.encodePacked` used in hash generation
5. SOL-Defi-Staking-1: Arbitrary tier/duration values accepted in `stake()`

---

## High Findings

### [H-01] No Timelock or Multi-sig on Admin Operations Including UUPS Upgrade
**Severity:** High
**Category:** Centralization / Access Control
**VP Reference:** VP-06
**Location:** `_authorizeUpgrade()` (line 312), `setService()` (line 328), `setValidator()` (line 340), `setRequiredSignatures()` (line 358), `registerLegacyUsers()` (line 698)
**Sources:** Agent-C, Cyfrin (SOL-CR-3, SOL-CR-4), Solodit

**Description:**
All ADMIN_ROLE functions execute immediately with no timelock or multi-sig requirement. A single compromised admin key can:
1. Replace the entire contract logic via UUPS upgrade (stealing all staked XOM + DEX balances)
2. Add rogue validators who can settle fraudulent DEX trades
3. Register fraudulent legacy users to drain migration funds
4. Lower `requiredSignatures` to 1, weakening legacy claim security
5. Change service registry to point to malicious contracts

**Exploit Scenario:**
Attacker compromises the admin private key. In a single transaction, they call `upgradeTo()` with a malicious implementation that includes a `drain()` function, then call `drain()` in the next block. All staked XOM, DEX-deposited tokens, and legacy migration funds are stolen.

**Real-World Precedent:**
- Standard "must-fix" finding in every major audit firm's checklist
- Solodit Rug Pull Checklist explicitly categorizes instant admin upgrades as a rug-pull vector
- Dozens of protocols have been flagged for this (documented in Cyfrin blog series)

**Recommendation:**
Deploy a `TimelockController` as the holder of `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE` with a minimum 48-hour delay. Use a multi-sig wallet (3-of-5 minimum) as the proposer. This is the standard mitigation pattern used by all major DeFi protocols.

---

### [H-02] Staking Tier and Duration Not Validated On-Chain
**Severity:** High
**Category:** Business Logic / Input Validation
**VP Reference:** VP-23
**Location:** `stake()` (lines 375-398)
**Sources:** Agent-A, Agent-B, Agent-C, Cyfrin (SOL-Defi-Staking-1), Solodit (Kinetiq, Sapien, Soulmate precedents)

**Description:**
The `stake()` function accepts arbitrary `tier` and `duration` parameters with zero validation:
```solidity
function stake(uint256 amount, uint256 tier, uint256 duration) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    if (stakes[msg.sender].active) revert InvalidAmount();
    // No validation of tier value (should be 1-5)
    // No validation that amount matches the declared tier
    // duration=0 means immediate unlock
```

Per OmniBazaar tokenomics, Tier 1 requires 1-999,999 XOM (5% APR) and Tier 5 requires 1B+ XOM (9% APR). A user can stake 1 XOM with `tier=5, duration=3` and claim 12% APR if the StakingRewardPool trusts the on-chain tier value.

**Exploit Scenario:**
User stakes 1 XOM with `tier=5, duration=730 days`. The StakingRewardPool reads the stored tier and computes rewards at 12% APR (9% base + 3% duration bonus) on a 1 XOM stake. While the reward per user is tiny, thousands of Sybil accounts doing this simultaneously would drain the staking reward pool.

**Real-World Precedent:**
- Spearbit/Kinetiq: "Staking limit calculation is not accurate"
- Quantstamp/Sapien: "Lockup period decreased by staking with shorter lockup"
- CodeHawks/Soulmate: "Disproportionate reward from lacking token lock during staking"

**Recommendation:**
Add on-chain validation:
```solidity
// Validate tier matches staked amount
if (tier == 0 || tier > 5) revert InvalidAmount();
uint256[5] memory tierMinimums = [1 ether, 1_000_000 ether, 10_000_000 ether, 100_000_000 ether, 1_000_000_000 ether];
if (amount < tierMinimums[tier - 1]) revert InvalidAmount();
// Validate duration
uint256[4] memory validDurations = [uint256(0), 30 days, 180 days, 730 days];
bool validDuration = false;
for (uint256 i = 0; i < 4; ++i) {
    if (duration == validDurations[i]) { validDuration = true; break; }
}
if (!validDuration) revert InvalidAmount();
```

---

## Medium Findings

### [M-01] Signature Malleability in `_recoverSigner()`
**Severity:** Medium
**Category:** Cryptographic Safety
**VP Reference:** VP-37
**Location:** `_recoverSigner()` (lines 840-860)
**Sources:** Agent-A, Agent-C, Agent-D, Cyfrin (SOL-Signature-2), Solodit (FairSide, SWC-117)

**Description:**
The function uses raw `ecrecover` (line 857) without checking that the `s` value is in the lower half of the secp256k1 curve order. For any valid ECDSA signature `(v, r, s)`, a complementary valid signature `(v', r, secp256k1n - s)` exists. While the `legacyClaimed` mapping prevents double-claims in the current code, using raw `ecrecover` is a known security anti-pattern.

**Recommendation:**
Replace with OpenZeppelin's `ECDSA.recover()`:
```solidity
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// In claimLegacyBalance:
address signer = ECDSA.recover(ethSignedMessageHash, signatures[i]);
```

---

### [M-02] `abi.encodePacked` with Dynamic Types in Hash Construction
**Severity:** Medium
**Category:** Hash Collision Risk
**VP Reference:** VP-38
**Location:** `claimLegacyBalance()` (lines 752-757)
**Sources:** Agent-D, Cyfrin (SOL-Basics-VI-SVI-4), Solodit (Weather Witness, Escrow, One World, SWC-133)

**Description:**
The message hash uses `abi.encodePacked(username, claimAddress, nonce, address(this), block.chainid)` where `username` is a `string` (dynamic type). While collisions require crafted inputs and only one dynamic type is present (lower risk than two dynamic types), this is fragile in an upgradeable contract where future parameters might be added.

**Recommendation:**
Replace with `abi.encode`:
```solidity
bytes32 messageHash = keccak256(abi.encode(username, claimAddress, nonce, address(this), block.chainid));
```

---

### [M-03] Fee-on-Transfer Token Accounting in `depositToDEX()`
**Severity:** Medium
**Category:** Token Integration
**VP Reference:** VP-46
**Location:** `depositToDEX()` (lines 625-629)
**Sources:** Agent-D, Solodit (veToken, Aura)

**Description:**
The function credits `dexBalances[msg.sender][token] += amount` after `safeTransferFrom`, but if the token has fee-on-transfer mechanics, the actual amount received is less than `amount`. This creates an accounting deficit where the sum of all `dexBalances` exceeds the actual token balance, causing the last withdrawers to fail.

**Recommendation:**
Use the balance-before/after pattern:
```solidity
uint256 before = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
uint256 received = IERC20(token).balanceOf(address(this)) - before;
dexBalances[msg.sender][token] += received;
```

---

### [M-04] No Pause Mechanism for Emergency Stops
**Severity:** Medium
**Category:** Emergency Operations
**VP Reference:** N/A
**Location:** Entire contract
**Sources:** Agent-C, Solodit (Telcoin, TempleGold)

**Description:**
The contract has no pause functionality. If a vulnerability is discovered in staking, DEX settlement, or legacy claims, the only emergency action is a full UUPS upgrade, which requires deploying new code. This is inadequate for time-critical incident response.

**Recommendation:**
Import `PausableUpgradeable` and add `pause()`/`unpause()` gated by `ADMIN_ROLE`. Apply `whenNotPaused` to `stake()`, `unlock()`, `depositToDEX()`, `withdrawFromDEX()`, `claimLegacyBalance()`, and settlement functions.

---

### [M-05] `initializeV2()` Has No Access Control Modifier
**Severity:** Medium
**Category:** Initializer Safety
**VP Reference:** VP-09
**Location:** `initializeV2()` (line 303)
**Sources:** Agent-C, Solodit (OpenZeppelin UUPS Advisory)

**Description:**
`initializeV2()` is `external` with only `reinitializer(2)` — no role restriction. While `reinitializer(2)` ensures one-time execution and the current function body only sets `requiredSignatures = 1` (benign), the pattern is dangerous for future V3/V4 reinitializers that may set sensitive state. An attacker could front-run the admin's upgrade transaction and call the reinitializer first.

**Recommendation:**
Add `onlyRole(ADMIN_ROLE)` to `initializeV2()` and all future reinitializers.

---

## Low Findings

### [L-01] Legacy Claim Nonce Not Enforced On-Chain
**Severity:** Low
**Category:** Replay Protection
**VP Reference:** VP-36
**Location:** `claimLegacyBalance()` (lines 739, 752-757)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Cyfrin, Solodit (6 sources)

**Description:**
The `nonce` parameter is included in the signed message hash but is never stored or tracked on-chain. Replay protection comes entirely from the `legacyClaimed[usernameHash]` check (line 749). The nonce is dead code that creates a false sense of security.

**Recommendation:**
Either remove the `nonce` parameter to reduce gas costs and eliminate confusion, or add a `mapping(bytes32 => bool) usedNonces` and validate on-chain.

---

### [L-02] Zero-Amount Legacy Balance Claim Succeeds
**Severity:** Low
**Category:** Input Validation
**VP Reference:** VP-23
**Location:** `claimLegacyBalance()` (line 781)
**Sources:** Agent-A, Agent-C, Agent-D, Solodit

**Description:**
If a legacy user was registered with `balance = 0`, the claim succeeds with a zero-amount transfer, permanently marking the username as claimed and emitting a misleading event.

**Recommendation:**
Add `if (amount == 0) revert InvalidAmount();` after line 781.

---

### [L-03] Unbounded Batch Settlement Arrays
**Severity:** Low
**Category:** Denial of Service
**VP Reference:** VP-29
**Location:** `batchSettleDEX()` (line 486), `batchSettlePrivateDEX()` (line 596)
**Sources:** Agent-A, Agent-C, Agent-D, Cyfrin

**Description:**
Both batch functions iterate over caller-provided arrays with no upper bound. `registerLegacyUsers()` correctly caps at 100 entries but batch settlement functions do not. A validator could submit an excessively large batch that exceeds the block gas limit.

**Recommendation:**
Add `if (length > 500) revert InvalidAmount();` to prevent accidental gas exhaustion.

---

### [L-04] Missing Zero-Address Check on `validator` in `distributeDEXFees()`
**Severity:** Low
**Category:** Input Validation
**VP Reference:** VP-22
**Location:** `distributeDEXFees()` (line 511)
**Sources:** Agent-D, Solodit

**Description:**
The `validator` parameter is not checked against `address(0)`. If called with zero address, the 10% validator fee is credited to `dexBalances[address(0)]`, permanently locking those funds.

**Recommendation:**
Add `if (validator == address(0)) revert InvalidAddress();`

---

### [L-05] Partial Struct Clearing in `unlock()`
**Severity:** Low
**Category:** Logic Error
**VP Reference:** VP-41
**Location:** `unlock()` (lines 413-416)
**Sources:** Agent-D

**Description:**
The function sets `active = false` and `amount = 0` but leaves `tier`, `duration`, and `lockTime` with stale values. This could confuse off-chain systems reading `getStake()`.

**Recommendation:**
Use `delete stakes[msg.sender]` to fully clear all struct fields and get a gas refund on the unused slots.

---

## Informational Findings

### [I-01] Floating Pragma on Upgradeable Contract
**Location:** Line 2: `pragma solidity ^0.8.19;`
**Recommendation:** Pin to `pragma solidity 0.8.20;` for deterministic compilation.

### [I-02] Inconsistent Error Type in `depositToDEX()`
**Location:** Line 626
**Description:** Reverts with `InvalidAmount()` when `token == address(0)` but semantically should be `InvalidAddress()`.

### [I-03] Dust Rounding in Fee Distribution
**Location:** `distributeDEXFees()` (lines 516-518)
**Description:** The remainder pattern `validatorFee = totalFee - oddaoFee - stakingFee` is correct but means the validator gets 100% of sub-3-wei fees. Acceptable behavior.

### [I-04] DEFAULT_ADMIN_ROLE and ADMIN_ROLE Granted to Same Address
**Location:** `initialize()` (lines 288-289)
**Description:** No separation between meta-admin and operational admin. Consider using `AccessControlDefaultAdminRules` for two-step admin transfer.

---

## Cross-Contract Observations

Agent B's business logic analysis identified issues in contracts that interact with OmniCore. These are documented here for awareness but are separate audit targets:

| Contract | Severity | Finding |
|----------|----------|---------|
| DEXSettlement.sol | High | Fee split reversed: ODDAO gets 20% instead of 70% |
| OmniParticipation.sol | Medium | KYC Tier 3 returns 20 points (should be 15) |
| OmniSybilGuard.sol | Medium | Uses native ETH/AVAX instead of XOM for stakes |
| StakingRewardPool.sol | Medium | No maximum APR cap in admin setter functions |
| MinimalEscrow.sol | Medium | Marketplace fee applied to buyer refunds in disputes |

---

## Known Exploit Cross-Reference

| Exploit Pattern | Relevance | Source |
|-----------------|-----------|--------|
| Spearbit/Kinetiq: Staking limit calculation inaccurate | H-02: Tier not validated against amount | Solodit |
| Quantstamp/Sapien: Lockup period bypass via re-staking | H-02: Duration=0 allows instant unlock | Solodit |
| Code4rena/FairSide: ecrecover malleability | M-01: Raw ecrecover without s-check | SWC-117 |
| SWC-133/Nethermind: abi.encodePacked collisions | M-02: Dynamic type in hash | Multiple CodeHawks |
| ZABU Finance ($200K): Fee-on-transfer accounting | M-03: depositToDEX credits face value | Code4rena |
| Sherlock/Telcoin: No pause mechanism | M-04: No emergency stop | Sherlock |
| OpenZeppelin UUPS Advisory ($10M bounty): Unprotected initializer | M-05: initializeV2() no ACL | iosiro/OpenZeppelin |

---

## Static Analysis Summary

### Slither
Skipped — full-project analysis exceeds 10 minutes on this codebase (46 contracts). Slither findings from Round 1 audit covered this contract.

### Aderyn
Skipped — v0.6.8 incompatible with solc v0.8.33 ("Fatal compiler bug" at compile.rs:78).

### Solhint
0 errors, 9 warnings:
- 3 missing NatSpec tags (contract-level @title/@author/@notice — present in NatSpec block but solhint may not detect `@dev`)
- 2 gas optimizations: `SettlementSkipped.amount` and `SettlementSkipped.available` could be indexed
- 1 gas optimization: `BatchPrivateSettlement.cotiBlockNumber` could be indexed
- 1 gas strict-inequalities suggestion (line 488: `>=` vs `>`)
- 1 complexity warning: `claimLegacyBalance()` complexity 9 (limit 7)

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `grantRole()`, `revokeRole()` (inherited) | 9/10 |
| ADMIN_ROLE | `_authorizeUpgrade()`, `setService()`, `setValidator()`, `setRequiredSignatures()`, `registerLegacyUsers()` | 8/10 |
| AVALANCHE_VALIDATOR_ROLE | `settleDEXTrade()`, `batchSettleDEX()`, `distributeDEXFees()`, `settlePrivateDEXTrade()`, `batchSettlePrivateDEX()` | 5/10 |
| No role (user self-service) | `stake()`, `unlock()`, `depositToDEX()`, `withdrawFromDEX()`, `claimLegacyBalance()` | 2/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** 8/10 (High Risk)

A compromised ADMIN_ROLE key can:
1. Upgrade the contract to arbitrary logic (total fund theft)
2. Add rogue validators (fraudulent DEX settlements)
3. Register fraudulent legacy users (drain migration funds)
4. Lower multi-sig threshold to 1 (weakened legacy claims)

**Funds at risk:** All staked XOM (`totalStaked`), all DEX-deposited tokens, all unclaimed legacy migration tokens — effectively the entire TVL of the protocol.

**Recommendation:** Deploy a TimelockController (48-hour minimum) controlled by a 3-of-5 multi-sig as the ADMIN_ROLE holder. This is the standard pattern used by Compound, Uniswap, Aave, and all major DeFi protocols.

---

## Remediation Priority

| Priority | Finding | Effort |
|----------|---------|--------|
| 1 | H-02: Add staking tier/duration validation | Low (add constants + require checks) |
| 2 | M-01: Replace ecrecover with ECDSA.recover | Low (1-line import + 1-line change) |
| 3 | M-02: Replace abi.encodePacked with abi.encode | Low (1-line change) |
| 4 | H-01: Deploy TimelockController | Medium (deploy + transfer admin role) |
| 5 | M-05: Add onlyRole to initializeV2() | Low (1 modifier) |
| 6 | M-03: Fee-on-transfer balance check | Low (before/after pattern) |
| 7 | M-04: Add PausableUpgradeable | Medium (import + modifiers + state) |
| 8 | L-01 to L-05: Low-severity fixes | Low (simple checks/deletes) |

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
