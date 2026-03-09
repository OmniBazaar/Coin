# Security Audit Report: OmniCore V3 + OmniValidatorRewards V2

**Date:** 2026-03-09
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contracts:**
- `Coin/contracts/OmniCore.sol` (V3 upgrade)
- `Coin/contracts/OmniValidatorRewards.sol` (V2 upgrade)
**Solidity Version:** 0.8.24
**Lines of Code:** 3,273 (1,200 + 2,073)
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (XOM token rewards, staking)

## Audit Scope

This audit focuses on the **V2/V3 upgrade changes** to both contracts:
- **OmniCore V3:** Added Bootstrap.sol integration, `getActiveNodes()`, `isValidator()` fallback, `reinitializeV3()`
- **OmniValidatorRewards V2:** Permissionless `processEpoch()`/`processMultipleEpochs()`, auto `roleMultiplier` from Bootstrap nodeType, `reinitializeV2()`

Pre-existing findings from prior audit rounds (Rounds 1-4) are noted but not counted as new findings.

## Executive Summary

The V2/V3 upgrades are well-engineered with proper use of UUPS patterns, storage gap management, try/catch fallbacks, and reinitializers. The primary risks center on the trust relationship with Bootstrap.sol (which controls the validator list and node types) and the lack of in-contract upgrade timelock on OmniCore. No critical exploitable vulnerabilities were found in the new code.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 4 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 89 |
| Passed | 75 |
| Failed | 5 |
| Partial | 9 |
| **Compliance Score** | **84%** |

Top failed checks:
1. SOL-Basics-AC-4: No two-step admin transfer (both contracts)
2. SOL-CR-4: Admin can change critical OmniCore properties immediately (no timelock)
3. SOL-AM-ReplayAttack-1: Legacy claim nonce not tracked (pre-existing)
4. SOL-AM-DOSA-2: No minimum transaction amount on DEX deposits (pre-existing)
5. SOL-Basics-AL-9: Unbounded memory allocation from Bootstrap (new)

---

## High Findings

### [H-01] OmniCore Lacks In-Contract Upgrade Timelock
**Severity:** High
**Category:** Access Control / Centralization
**VP Reference:** VP-08 (Unprotected Upgrade)
**Location:** `_authorizeUpgrade()` (OmniCore line 444)
**Sources:** Agent-A, Agent-C, Agent-D, Checklist SOL-CR-4, Solodit
**Real-World Precedent:** Zunami Protocol (May 2025) -- $500K loss from overpowered admin

**Description:**
OmniCore's `_authorizeUpgrade()` only checks `onlyRole(ADMIN_ROLE)` and ossification status. Unlike OmniValidatorRewards (which has a 48-hour `proposeUpgrade()` + `UPGRADE_DELAY` timelock), OmniCore allows instant upgrades. A compromised admin key could upgrade the contract to a malicious implementation in a single transaction, draining all staked funds.

**Exploit Scenario:**
1. Attacker gains ADMIN_ROLE (compromised key, social engineering)
2. Deploy malicious OmniCore implementation with `withdrawAll()` function
3. Call `upgradeToAndCall(maliciousImpl, withdrawAllData)` in one transaction
4. All staked XOM and DEX deposits drained instantly

**Recommendation:**
The NatSpec at line 20-25 correctly states the admin SHOULD be a TimelockController. This is an **operational deployment requirement** that must be fulfilled before mainnet deployment. Consider adding an in-contract timelock similar to OmniValidatorRewards' pattern for consistency.

**Mitigating Factor:** The `ossified` flag (line 143) can permanently disable upgrades once set. Until ossified, the risk depends entirely on operational security of the ADMIN_ROLE key.

---

### [H-02] Bootstrap Sybil Attack Enables Reward Dilution
**Severity:** High
**Category:** Business Logic / Access Control
**VP Reference:** VP-08 (Access Control)
**Location:** `getActiveNodes()` (OmniCore lines 911-933), `_computeEpochWeights()` (OmniValidatorRewards line 1726)
**Sources:** Agent-B, Agent-D, Solodit (Ludex Labs finding)
**Real-World Precedent:** Salty Protocol -- "stake first, steal everyone's tokens"

**Description:**
The V2/V3 changes derive the validator list and role multipliers from Bootstrap.sol. If Bootstrap registration is permissionless (or has weak access controls), an attacker can:
1. Register multiple Sybil accounts as gateway nodes (type 0)
2. Each gets the 1.5x role multiplier bonus automatically
3. Submit heartbeats from all accounts
4. Dilute legitimate validators' reward share

**Exploit Scenario:**
1. Attacker registers 50 Sybil addresses in Bootstrap as type 0 (gateway)
2. Runs a script to submit heartbeats every 10s from all 50 addresses
3. When `processEpoch()` is called, all 50 addresses are included in `getActiveNodes()`
4. Each receives proportional rewards with 1.5x gateway bonus
5. Legitimate validators' share is reduced by ~60%

**Recommendation:**
Bootstrap.sol registration should require:
- Minimum staking requirement verified on-chain
- Admin approval or governance vote for new validators
- The `_bootstrapRoleMultiplier()` function should cross-check staking status in OmniCore before granting the 1.5x bonus

**Note:** This finding depends on Bootstrap.sol's actual access controls. If Bootstrap requires ADMIN_ROLE for `registerNode()`, the risk is significantly reduced to a centralization concern rather than a permissionless exploit.

---

## Medium Findings

### [M-01] Permissionless processEpoch() Enables Heartbeat Timing Advantage
**Severity:** Medium
**Category:** Business Logic / Front-running
**VP Reference:** VP-34 (Front-running)
**Location:** `processEpoch()` (OmniValidatorRewards line 843), `_heartbeatScore()` (line 1985)
**Sources:** Agent-A, Agent-D, Solodit (Algebra Finance epoch data)

**Description:**
With `BLOCKCHAIN_ROLE` removed from `processEpoch()`, any validator can time their `submitHeartbeat()` in the same block as `processEpoch()`. This guarantees a heartbeat score of 100 (elapsed < 6s) while other validators may score 25-75.

**Impact:** A validator consistently calling `submitHeartbeat()` + `processEpoch()` atomically gains ~33% more activity weight than an honest validator with 10-second heartbeat intervals.

**Recommendation:**
Accept as known behavior. The advantage is marginal (activity is 30% of total weight, heartbeat is 60% of activity = 18% total), and all validators can adopt the same strategy. The sequential epoch enforcement prevents double-processing. Document as accepted trade-off.

---

### [M-02] getActiveNodes() Gas DoS with Large Bootstrap Registry
**Severity:** Medium
**Category:** Denial of Service
**VP Reference:** VP-29 (Unbounded Loop)
**Location:** `getActiveNodes()` (OmniCore lines 911-933)
**Sources:** Agent-A, Agent-D, Checklist SOL-Basics-AL-9, Solodit (Covalent, Sparkn)

**Description:**
`getActiveNodes()` calls `IBootstrap(bootstrapContract).getActiveNodes(0, 200)` and `getActiveNodes(1, 200)` then concatenates results. While the limit parameter caps each call at 200, if Bootstrap's internal implementation iterates over all registered nodes to find the first 200 active ones, the gas cost could exceed block limits with thousands of registered (but inactive) nodes.

**Impact:** If Bootstrap.sol has 10,000+ registered nodes with many inactive, the iteration within Bootstrap to find 200 active ones could cause `processEpoch()` to revert with out-of-gas.

**Recommendation:**
Verify Bootstrap.sol's `getActiveNodes()` implementation uses efficient enumeration (e.g., EnumerableSet of only active nodes, not filtering all registered nodes). The current 200-per-type limit is appropriate.

---

### [M-03] 200 Validator Cap Creates Systematic Computation Node Exclusion
**Severity:** Medium
**Category:** Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `getActiveNodes()` (OmniCore lines 917-932)
**Sources:** Agent-B

**Description:**
`getActiveNodes()` concatenates gateways first (type 0, limit 200), then computation nodes (type 1, limit 200). If there are exactly 200 gateways and 200 computation nodes, both types are represented. However, `OmniValidatorRewards.processEpoch()` iterates up to `MAX_VALIDATORS_PER_EPOCH` (200) over this combined array, meaning gateways (which appear first) are processed preferentially.

**Impact:** With 200+ gateways, all 200 iteration slots are consumed by gateways, and zero computation nodes receive epoch rewards.

**Recommendation:**
Consider interleaving gateway and computation node addresses in `getActiveNodes()`, or have OmniValidatorRewards iterate over the full combined array (up to 400). Alternatively, process gateways and computation nodes in separate reward pools.

---

### [M-04] Auto Role Multiplier Trusts Bootstrap Without Cross-Verification
**Severity:** Medium
**Category:** Trust Assumption
**VP Reference:** VP-08 (Access Control)
**Location:** `_bootstrapRoleMultiplier()` (OmniValidatorRewards lines 1957-1971)
**Sources:** Agent-D, Solodit

**Description:**
The V2 auto role multiplier reads `nodeType` from Bootstrap.sol and grants 1.5x to any address that Bootstrap reports as an active gateway (type 0). There is no cross-verification that the address actually stakes as a gateway, runs gateway infrastructure, or meets any other qualification beyond Bootstrap registration.

**Recommendation:**
Add a cross-check: `_bootstrapRoleMultiplier()` should also verify the validator has sufficient stake in OmniCore (e.g., `getStake(validator) >= MIN_GATEWAY_STAKE`) before granting the 1.5x bonus. This creates defense-in-depth independent of Bootstrap's access controls.

---

### [M-05] No Two-Step Admin Transfer on Either Contract
**Severity:** Medium
**Category:** Access Control
**VP Reference:** VP-09 (Privilege Management)
**Location:** Both contracts (inheritance declaration)
**Sources:** Checklist SOL-Basics-AC-4, Solodit

**Description:**
Both contracts use `AccessControlUpgradeable` which provides `grantRole()`/`revokeRole()` but not a two-step transfer for `DEFAULT_ADMIN_ROLE`. A botched admin transfer (granting to wrong address, then revoking from current admin) permanently locks both contracts.

**Recommendation:**
Consider upgrading to `AccessControlDefaultAdminRulesUpgradeable` (OpenZeppelin 5.x) which provides a two-step admin transfer with a delay period. This is a future upgrade consideration, not blocking for the current V2/V3 deployment.

---

## Low Findings

### [L-01] Legacy Claim Nonce Not Tracked On-Chain (Pre-existing)
**Severity:** Low (downgraded from Medium)
**Location:** `claimLegacyBalance()` (OmniCore line 1020-1055)
**Sources:** Agent-A, Agent-C, Checklist SOL-AM-ReplayAttack-1, Solodit (Biconomy Nexus)

**Description:**
The `nonce` parameter in `claimLegacyBalance()` is included in the signature hash but never stored or checked against previous uses. However, the `legacyClaimed[usernameHash]` mapping effectively prevents double-claims, making the nonce redundant rather than missing. The state change at line 1043 precedes the transfer at line 1047, so reverting mid-function cannot leave the nonce "consumed but claim unfulfilled."

**Status:** Pre-existing. Mitigated by one-time-claim design. Low practical risk.

---

### [L-02] Block Reward Distribution Doesn't Match Tokenomics Spec
**Severity:** Low
**Location:** `_distributeRewards()` (OmniValidatorRewards lines 1700-1720)
**Sources:** Agent-B, Solodit (Salty)

**Description:**
The CLAUDE.md tokenomics specifies block rewards should split: 50% staking pool, 10% ODDAO, remainder to block producer. OmniValidatorRewards distributes 100% of `epochReward` proportionally to active validators by weight, with no carve-out.

**Status:** This appears to be an intentional design decision -- the Proof of Participation reward system replaces the simple block producer model. The staking pool and ODDAO receive funds through other mechanisms (marketplace fees, DEX fees). Confirm with project team.

---

### [L-03] submitHeartbeat() Lacks nonReentrant Guard
**Severity:** Low
**Location:** `submitHeartbeat()` (OmniValidatorRewards line 742)
**Sources:** Checklist SOL-Heuristics-4

**Description:**
`submitHeartbeat()` has `whenNotPaused` but not `nonReentrant`. Since it only writes to `lastHeartbeat[msg.sender]` and emits an event with no external calls, reentrancy is not exploitable. Added for consistency recommendation only.

---

### [L-04] DEX Deposit Dust Amounts Allowed (Pre-existing)
**Severity:** Low
**Location:** `depositToDEX()` (OmniCore line 836)
**Sources:** Checklist SOL-AM-DOSA-2

**Description:**
`depositToDEX()` allows deposits of 1 wei, which could clog balance mappings with dust. Pre-existing, not introduced by V2/V3.

---

## Informational Findings

### [I-01] Storage Gap Reduction Correctly Managed
**Severity:** Informational
**Location:** OmniCore `__gap[46]` (line 185), OmniValidatorRewards `__gap[29]` (line 431)

Both contracts correctly reduced their storage gaps by 1 when adding the `bootstrapContract` state variable. Manual gap counting is plausible but should be verified with OpenZeppelin's storage layout tool before deployment.

---

### [I-02] Try/Catch Pattern in Bootstrap Calls is Robust
**Severity:** Informational
**Location:** `isValidator()` (OmniCore line 893), `_bootstrapRoleMultiplier()` (OmniValidatorRewards line 1960)

Both contracts wrap Bootstrap calls in try/catch, defaulting to safe fallback values (false for isValidator, 10000 bps for roleMultiplier). This correctly prevents Bootstrap failures from blocking core contract functionality.

---

### [I-03] Ossification Flag Provides Permanent Upgrade Protection
**Severity:** Informational
**Location:** `ossified` flag (OmniCore line 143)

The `ossified` flag can permanently disable upgrades. This is a strong security feature not present in OmniValidatorRewards (which uses timelock instead). Consider adding ossification capability to OmniValidatorRewards as well for long-term immutability.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Zunami Protocol | May 2025 | $500K | Overpowered admin function -- matches H-01 (no upgrade timelock) |
| Salty Protocol | Jan 2024 | N/A (audit) | Incorrect staking reward share -- matches L-02 |
| Biconomy Nexus | Jul 2024 | N/A (audit) | Missing nonce replay -- matches L-01 |
| Covalent | Oct 2021 | N/A (audit) | Unbounded validator iteration -- matches M-02 |
| Ludex Labs | 2024 | N/A (audit) | Unrestricted registration Sybil -- matches H-02 |
| Algebra Finance | 2024 | N/A (audit) | Premature epoch data use -- matches M-01 |

## Solodit Similar Findings

- [Unrestricted Registration Sybil Risk (Ludex Labs)](https://solodit.cyfrin.io/issues/unrestricted-username-registration-and-sybil-attack-risk-cantina-none-ludex-labs-pdf) -- Direct match to H-02
- [Uptime Loss in Suzaku Core](https://solodit.cyfrin.io/issues/uptime-loss-due-to-integer-division-in-uptimetrackercomputevalidatoruptime-can-make-validator-lose-entire-rewards-for-an-epoch-cyfrin-none-suzaku-core-markdown) -- Related to reward precision
- [Premature Epoch Data (Algebra Finance)](https://solodit.cyfrin.io/issues/premature-use-of-unverified-epoch-data-in-withdraw-mixbytes-none-algebra-finance-markdown) -- Related to M-01
- [Nonce Blocking Liquidation (Symmetrical)](https://solodit.cyfrin.io/issues/h-7-liquidation-can-be-blocked-by-incrementing-the-nonce-sherlock-none-symmetrical-git) -- Related to L-01
- [Missing Nonce Signature Replay (Biconomy Nexus)](https://codehawks.cyfrin.io/c/2024-07-biconomy/s/202) -- Related to L-01
- [Staking Pool Incorrect Reward Share (Salty)](https://github.com/code-423n4/2024-01-salty-findings/issues/243) -- Related to L-02

## Static Analysis Summary

### Slither
Slither analysis pending (tool installation issue). Full-project Slither scans against Hardhat were attempted but the binary path was not configured. Findings from LLM agents and checklist verification compensate for this gap.

### Aderyn
Not run for this audit (import resolution issues with workspace-hoisted node_modules).

### Solhint
4 pre-existing warnings only (all `not-rely-on-time` suppressions documented with business justification). No new warnings from V2/V3 changes.

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE (OmniCore) | upgradeToAndCall, setValidator, setOddaoAddress, setStakingPoolAddress, setRequiredSignatures, registerLegacyUser, reinitializeV3, pause/unpause, ossify | 8/10 |
| DEFAULT_ADMIN_ROLE (Rewards) | upgradeToAndCall (via timelock), proposeUpgrade, proposeContracts, applyContracts, emergencyWithdraw, reinitializeV2, pause/unpause | 6/10 |
| VALIDATOR_ROLE (OmniCore) | submitSettlement | 2/10 |
| BLOCKCHAIN_ROLE (Rewards) | recordTransactionProcessing, recordMultipleTransactions | 3/10 |
| PENALTY_ROLE (Rewards) | applyPenalty | 4/10 |
| None (permissionless) | processEpoch, processMultipleEpochs, submitHeartbeat, claimRewards | 2/10 |

## Centralization Risk Assessment

**OmniCore single-key maximum damage:** A compromised ADMIN_ROLE can immediately upgrade the contract to a malicious implementation, draining all staked XOM and DEX deposits. **Risk: 8/10.**

**OmniValidatorRewards single-key maximum damage:** A compromised DEFAULT_ADMIN_ROLE must wait 48 hours after proposing an upgrade (timelock). Community can detect and respond. The admin cannot directly withdraw XOM (`emergencyWithdraw` blocks XOM). **Risk: 4/10.**

**Recommendation:** Deploy a TimelockController (48h minimum delay) controlled by a 3-of-5 multi-sig as the ADMIN_ROLE holder for both contracts. OmniCore's NatSpec already documents this requirement (line 20-25). **This is the single most important operational security action before mainnet goes live.**

---

*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Passes completed: Static Analysis (Solhint), 4x LLM Semantic Audit, Cyfrin Checklist, Solodit Cross-Reference, Triage/Dedup, Report Generation*
