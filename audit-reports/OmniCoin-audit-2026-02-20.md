# Security Audit Report: OmniCoin

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniCoin.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 142
**Upgradeable:** No
**Handles Funds:** Yes (XOM token — base layer token for OmniBazaar ecosystem)

## Executive Summary

OmniCoin.sol is a clean, minimal ERC20 token built on well-audited OpenZeppelin v5 contracts. Its small attack surface (142 lines, no external calls, no DeFi logic) results in no Critical findings. The three High findings relate to spec mismatches (wrong initial supply), cross-contract governance vulnerability (missing ERC20Votes), and missing defense-in-depth (no supply cap). Centralization risk is rated 9/10 due to combined mint/burn/pause authority with no timelock.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 3 |
| Low | 3 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 76 |
| Passed | 68 |
| Failed | 3 |
| Partial | 5 |
| **Compliance Score** | **89.5%** |

Top 5 failed/partial checks:
1. **SOL-Basics-AC-4** (FAIL): No two-step privilege transfer — uses `AccessControl` instead of `AccessControlDefaultAdminRules`
2. **SOL-CR-4** (FAIL): Admin can change critical properties immediately — no timelock on role grants
3. **SOL-CR-6** (FAIL): Single-step ownership transfer — admin role can be lost permanently on typo
4. **SOL-AM-RP-1** (PARTIAL): Admin can effectively pull assets — MINTER_ROLE mints unlimited, BURNER_ROLE burns from anyone
5. **SOL-Basics-AC-6** (PARTIAL): Inherited `burn()` from ERC20Burnable is publicly callable without BURNER_ROLE

---

## High Findings

### [H-01] INITIAL_SUPPLY Mismatch (1B vs 4.13B)
**Severity:** High
**Category:** Business Logic
**VP Reference:** N/A (spec mismatch)
**Location:** `INITIAL_SUPPLY` constant (line 32)
**Sources:** Agent-B, Solodit
**Real-World Precedent:** VTVL (2022-09) — supply constant logic mismatch

**Description:**
The `INITIAL_SUPPLY` constant is hardcoded to 1,000,000,000 (1 billion) XOM:

```solidity
uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens
```

Per the OmniBazaar specification (CLAUDE.md): "Current Circulating: ~4.13 billion XOM (genesis amount for migration)." The genesis supply represents tokens migrating from the legacy OmniBazaar system. Minting only 1B at genesis leaves 3.13B XOM unaccounted for.

**Exploit Scenario:**
If deployment scripts rely on `INITIAL_SUPPLY` to distribute the full genesis allocation, legacy token holders migrating from the old system would receive approximately 24.2% of their expected tokens. The deployer would need to separately mint the remaining 3.13B via `mint()`, introducing a manual step prone to error.

**Recommendation:**
Correct the constant to match the specification:

```solidity
uint256 public constant INITIAL_SUPPLY = 4_130_000_000 * 10**18; // 4.13 billion genesis tokens
```

Or confirm this is intentional and that deployment scripts mint the remainder, then document this decision.

---

### [H-02] Missing ERC20Votes — Governance Vulnerable to Flash Loans
**Severity:** High
**Category:** Access Control / Business Logic (cross-contract)
**VP Reference:** VP-52 (Flash Loan Governance Attack)
**Location:** OmniCoin.sol (contract-level — missing `ERC20Votes` inheritance); OmniGovernance.sol line 207 (`balanceOf(msg.sender)`)
**Sources:** Agent-B, Solodit
**Real-World Precedent:** Beanstalk (2022-04) — $80M; Vader Protocol (2021-04); FST Token

**Description:**
OmniCoin does **not** inherit `ERC20Votes`. The separate `OmniGovernance.sol` contract determines voting weight by calling `IERC20(tokenAddress).balanceOf(msg.sender)` at the time of the `vote()` call — not at proposal creation time. This creates two attack vectors:

1. **Flash loan attack:** An attacker borrows massive XOM via flash loan, votes with amplified weight, then returns the tokens — all in one transaction. Cost: only gas fees.
2. **Double voting:** A user votes, transfers tokens to another address, and that address votes on the same proposal with the same tokens. Repeatable across N addresses.

**Exploit Scenario:**
1. Attacker creates a governance proposal to drain treasury
2. Obtains flash loan of 1B XOM from any DEX pool
3. Calls `vote(proposalId, true)` with 1B weight — exceeds any realistic quorum
4. Returns flash loan
5. Proposal passes and attacker executes it

**Recommendation:**
Add `ERC20Votes` to OmniCoin:

```solidity
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

contract OmniCoin is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, ERC20Votes, AccessControl {
    function _update(address from, address to, uint256 amount)
        internal override(ERC20, ERC20Pausable, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
```

Then update OmniGovernance to use `getPastVotes(voter, proposal.startTime)` instead of `balanceOf(msg.sender)`.

---

### [H-03] No On-Chain Supply Cap
**Severity:** High
**Category:** Business Logic / Access Control
**VP Reference:** N/A (defense-in-depth gap)
**Location:** `mint()` (line 76-78)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist, Solodit
**Real-World Precedent:** Cover Protocol (2020-12) — unlimited minting; DAO Maker (2021-09) — $4M unauthorized minting; VTVL (2022-09) — supply cap bypass

**Description:**
The `mint()` function has no maximum supply check:

```solidity
function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    _mint(to, amount);
}
```

Per tokenomics, the lifetime total is 16.6B XOM (4.13B genesis + 6.089B block rewards + 1.383B welcome bonuses + 2.995B referral bonuses + 2.0B first sale bonuses). However, the contract itself enforces no upper bound. Any holder of `MINTER_ROLE` can mint unlimited tokens.

The MintController contract provides an external cap, but this is an architectural constraint, not an on-chain invariant. If `MINTER_ROLE` is granted directly (bypassing MintController), or if MintController has a bug, the cap is ineffective.

**Exploit Scenario:**
1. MINTER_ROLE is compromised (key leak, phishing, contract exploit)
2. Attacker mints 100B XOM to their address
3. Dumps on market, destroying token value for all holders
4. No on-chain defense prevents this

**Recommendation:**
Add a defense-in-depth supply cap using OpenZeppelin's pattern:

```solidity
uint256 public constant MAX_SUPPLY = 16_600_000_000 * 10**18; // 16.6B lifetime cap

function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
    _mint(to, amount);
}
```

---

## Medium Findings

### [M-01] burnFrom() Bypasses Allowance — Broad BURNER_ROLE Scope
**Severity:** Medium (acknowledged as intentional)
**Category:** Access Control
**VP Reference:** VP-06
**Location:** `burnFrom()` (line 86-88)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Solodit
**Real-World Precedent:** SafeMoon (2023-03) — $8.9M unprotected burn; CodeHawks foundry-defi-stablecoin (2023-07)

**Description:**
The overridden `burnFrom()` calls `_burn(from, amount)` directly without checking or consuming an ERC20 allowance:

```solidity
function burnFrom(address from, uint256 amount) public override onlyRole(BURNER_ROLE) {
    _burn(from, amount);  // No _spendAllowance() call
}
```

Standard `ERC20Burnable.burnFrom()` calls `_spendAllowance(account, _msgSender(), value)` before burning. This override removes that safety net entirely. Any `BURNER_ROLE` holder can burn tokens from ANY address without that address's consent.

Per the OmniBazaar spec, this is intentional for the XOM-to-pXOM privacy conversion via PrivateOmniCoin. However, the broad scope means a compromised BURNER_ROLE key can destroy any user's entire balance.

**Recommendation:**
1. Ensure BURNER_ROLE is granted ONLY to the PrivateOmniCoin contract, never to EOAs in production
2. Add a deployment verification test asserting the deployer has renounced BURNER_ROLE after setup
3. Add explicit NatSpec documenting the design decision:

```solidity
/// @dev SECURITY: Intentionally bypasses allowance. BURNER_ROLE must only be granted
/// to audited contracts (PrivateOmniCoin), never to EOAs.
```

---

### [M-02] Centralization Risk — No Timelock on Admin Operations
**Severity:** Medium
**Category:** Centralization
**VP Reference:** VP-06
**Location:** `pause()` (line 94), `unpause()` (line 102), inherited `grantRole()`/`revokeRole()`
**Sources:** Agent-C, Agent-D, Checklist (SOL-CR-4 FAIL), Solodit
**Real-World Precedent:** Ronin Network (2022-03) — $624M compromised keys; Harmony Bridge (2022-06) — $100M

**Description:**
All administrative operations take immediate effect with no delay:
- Pausing/unpausing the entire token economy
- Granting MINTER_ROLE (enabling unlimited inflation)
- Granting BURNER_ROLE (enabling arbitrary token destruction)
- Transferring DEFAULT_ADMIN_ROLE

After `initialize()`, the deployer simultaneously holds DEFAULT_ADMIN_ROLE, MINTER_ROLE, and BURNER_ROLE. A single compromised key gives an attacker:
- Unlimited minting (infinite dilution)
- Arbitrary burning (direct confiscation)
- Transfer freeze (denial of service)
- Irrevocable privilege escalation

**Centralization Risk Rating: 9/10**

**Recommendation:**
1. Transfer DEFAULT_ADMIN_ROLE to a multisig or TimelockController post-deployment
2. Add a `setupRoles()` function that atomically grants roles to correct contracts and renounces deployer roles
3. Consider OpenZeppelin's `TimelockController` as the admin with a 48-hour delay for role changes

---

### [M-03] No Two-Step Admin Transfer
**Severity:** Medium
**Category:** Access Control
**VP Reference:** VP-06
**Location:** Inherited `AccessControl` (line 8)
**Sources:** Agent-C, Checklist (SOL-Basics-AC-4 FAIL, SOL-CR-6 FAIL), Solodit

**Description:**
OpenZeppelin's basic `AccessControl` allows single-step admin transfer via `grantRole(DEFAULT_ADMIN_ROLE, newAddress)` + `revokeRole(DEFAULT_ADMIN_ROLE, oldAddress)`. If `newAddress` is wrong (typo, wrong checksum, contract without role capability), admin access is permanently and irreversibly lost.

OpenZeppelin v5 provides `AccessControlDefaultAdminRules` which enforces a two-step transfer with configurable delay and cancellation window. OmniCoin uses the basic `AccessControl` instead.

**Recommendation:**
Replace `AccessControl` with `AccessControlDefaultAdminRules`:

```solidity
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

contract OmniCoin is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, AccessControlDefaultAdminRules {
    constructor()
        ERC20("OmniCoin", "XOM")
        ERC20Permit("OmniCoin")
        AccessControlDefaultAdminRules(48 hours, msg.sender)
    { ... }
}
```

---

## Low Findings

### [L-01] Inherited burn() Unrestricted
**Severity:** Low
**Category:** Access Control
**VP Reference:** VP-06
**Location:** Inherited from `ERC20Burnable` (not overridden)
**Sources:** Agent-A, Agent-C, Solodit (CodeHawks 2023-07)

**Description:**
OmniCoin overrides `burnFrom()` with BURNER_ROLE restriction but does NOT override `burn(uint256)` inherited from ERC20Burnable. This means any token holder can voluntarily burn their own tokens by calling `burn(amount)` without BURNER_ROLE.

This creates an asymmetry:
- `burn(100)` — anyone can self-burn (no role needed)
- `burnFrom(addr, 100)` — requires BURNER_ROLE

If self-burning is intended (standard ERC20Burnable behavior), no fix needed. If ALL burning should require BURNER_ROLE, override `burn()`.

**Recommendation:**
Confirm intent. If self-burn should be restricted:
```solidity
function burn(uint256 amount) public override onlyRole(BURNER_ROLE) {
    _burn(msg.sender, amount);
}
```

---

### [L-02] Contract Brickable if initialize() Never Called
**Severity:** Low
**Category:** Initializer Safety
**VP Reference:** VP-09
**Location:** Constructor (line 49) and `initialize()` (line 57)
**Sources:** Agent-C

**Description:**
If the deployer loses access to their key after deployment but before calling `initialize()`, the contract is permanently empty: no tokens, no roles, no admin. The immutable `_deployer` check prevents anyone else from initializing.

**Recommendation:**
Very low practical risk — deployer typically calls `initialize()` in the same script. Consider combining initialization into the constructor if the two-step pattern is not required.

---

### [L-03] batchTransfer No address(this) Check
**Severity:** Low
**Category:** Input Validation
**VP Reference:** VP-22
**Location:** `batchTransfer()` (line 120-123)
**Sources:** Agent-C

**Description:**
The function checks for `address(0)` but not `address(this)`. Tokens sent to the contract itself would be permanently locked since OmniCoin has no rescue function.

**Recommendation:**
```solidity
if (recipients[i] == address(0) || recipients[i] == address(this)) revert InvalidRecipient();
```

---

## Informational Findings

### [I-01] Floating Pragma
**Location:** Line 2: `pragma solidity ^0.8.19;`
**Sources:** Agent-A, Agent-D, Solhint, Solodit (universal finding)
**Recommendation:** Pin to specific tested version: `pragma solidity 0.8.24;`

### [I-02] No BatchTransfer Aggregate Event
**Location:** `batchTransfer()` (line 113-126)
**Sources:** Agent-A
**Description:** Individual `Transfer` events are emitted per-transfer, but no aggregate `BatchTransfer(address indexed sender, uint256 count)` event exists for off-chain indexer convenience.

### [I-03] batchTransfer Allows Zero-Amount Transfers
**Location:** `batchTransfer()` (line 120-123)
**Sources:** Agent-A, Agent-D
**Description:** `amounts[i] = 0` succeeds, emitting a `Transfer` event with value 0. Harmless but wastes gas and pollutes event logs.

### [I-04] approve()/permit() Work While Paused
**Location:** Inherited ERC20 `approve()` and ERC20Permit `permit()`
**Sources:** Agent-C
**Description:** Standard OpenZeppelin behavior. Users can set up approvals during pause so transfers execute immediately upon unpause. Not a vulnerability.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Beanstalk DAO | 2022-04 | $80M | Flash loan governance attack — identical pattern to H-02 (balanceOf voting without checkpoints) |
| SafeMoon | 2023-03 | $8.9M | Unprotected burn function — similar to M-01 (burnFrom bypasses allowance) |
| Cover Protocol | 2020-12 | N/A | Unlimited minting via logic flaw — same impact as H-03 (no supply cap) |
| DAO Maker | 2021-09 | $4M | Unauthorized minting — MINTER_ROLE compromise scenario |
| Ronin Network | 2022-03 | $624M | Compromised admin keys — centralization risk like M-02 |
| Harmony Bridge | 2022-06 | $100M | Compromised 2-of-5 multisig — shows need for proper admin controls |
| VTVL | 2022-09 | N/A | Supply cap bypass — parallel to H-03 |
| Vader Protocol | 2021-04 | N/A | Flash loan governance voting — parallel to H-02 |

## Solodit Similar Findings

| Finding | Protocol | Platform | Relevance |
|---------|----------|----------|-----------|
| Flash loan governance manipulation | Vader Protocol | Code4rena 2021-04 | Identical to H-02 |
| Supply cap not enforced | VTVL | Code4rena 2022-09 | Identical to H-03 |
| ERC20Burnable burnFrom exposed | Foundry DeFi Stablecoin | Cyfrin CodeHawks 2023-07 | Identical to L-01 |
| Centralization risk — admin withdrawal | Venus | Quantstamp | Parallel to M-02 |
| Role removal grants unauthorized roles | Audit 507 | Code4rena 2025-07 | Related to M-03 |
| Floating pragma | Multiple protocols | Universal | Identical to I-01 |

## Static Analysis Summary

### Slither
Skipped — full-project analysis exceeds 10-minute timeout. Contract is too simple to justify isolated recompilation.

### Aderyn
Skipped — v0.6.8 crashes with "Fatal compiler bug" against solc v0.8.33.

### Solhint
0 errors, 2 warnings:
1. **ordering** (line 42): Immutable declaration after custom error definition — cosmetic
2. **immutable-vars-naming** (line 42): `_deployer` should be `_DEPLOYER` per Solhint convention — cosmetic

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `pause()`, `unpause()`, `grantRole()`, `revokeRole()` | 9/10 |
| MINTER_ROLE | `mint()` | 8/10 (unlimited minting) |
| BURNER_ROLE | `burnFrom()` | 7/10 (burn from any address) |
| (any holder) | `transfer()`, `transferFrom()`, `approve()`, `permit()`, `burn()`, `batchTransfer()` | 1/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised DEFAULT_ADMIN_ROLE holder can: (1) grant MINTER_ROLE to themselves and mint unlimited tokens, (2) grant BURNER_ROLE and burn any user's tokens, (3) pause all transfers indefinitely, (4) grant admin to other addresses and lock out legitimate administrators. Combined impact: total destruction of token economy.

**Rating: 9/10**

**Recommendation:** Transfer DEFAULT_ADMIN_ROLE to a multisig or TimelockController. Revoke individual roles from deployer EOA after granting them to audited contracts. Use AccessControlDefaultAdminRules for two-step admin transfer.

## Remediation Priority

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| 1 | H-02: Add ERC20Votes | Medium | Prevents $80M-class governance attack |
| 2 | H-03: Add MAX_SUPPLY cap | Low | Prevents unlimited minting on role compromise |
| 3 | H-01: Fix INITIAL_SUPPLY | Low | Correct genesis distribution |
| 4 | M-02: Add timelock | Medium | Prevents instant admin abuse |
| 5 | M-03: Use AccessControlDefaultAdminRules | Low | Prevents accidental admin loss |
| 6 | M-01: Document burnFrom intent | Low | Clarifies intentional design |
| 7 | L-01: Override or document burn() | Low | Resolves access control asymmetry |
| 8 | L-03: Add address(this) check | Trivial | Prevents token lockup |
| 9 | L-02: Consider atomic init | Low | Eliminates bricking risk |

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 58 vulnerability patterns, 166 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
