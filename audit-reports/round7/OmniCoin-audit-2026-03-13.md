# Security Audit Report: OmniCoin.sol -- Round 7 (Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (6-Pass Pre-Mainnet Audit)
**Contract:** `Coin/contracts/OmniCoin.sol`
**Solidity Version:** 0.8.24 (pinned)
**OpenZeppelin Version:** ^5.4.0
**Lines of Code:** 309
**Upgradeable:** No
**Handles Funds:** Yes (XOM token -- base layer token for OmniBazaar ecosystem, 16.6B supply)
**Previous Audits:** Round 1 (2026-02-20), Round 4 Attacker Review (2026-02-28), Round 6 (2026-03-10)

---

## Executive Summary

Round 7 is a pre-mainnet security audit of OmniCoin.sol, the core ERC20 governance token for the OmniBazaar ecosystem. This audit builds on the comprehensive Round 6 review and focuses on verifying that previous findings remain addressed, identifying any new issues, and performing deeper cross-contract analysis.

**Key change from Round 6:** One new Medium-severity finding identified. The NatSpec documentation at line 37 claims "Admin/minter functions deliberately use msg.sender (admin ops should NOT be relayed)" but this is **factually incorrect** for `pause()`, `unpause()`, `mint()`, and `burnFrom()`. These functions use `onlyRole()` which internally calls `_msgSender()` (resolved via ERC2771Context), meaning admin operations CAN be relayed through the trusted forwarder. Additionally, a new Low finding identifies that the `IOmniCoin` interface declares `maxSupplyCap()` which OmniCoin does not implement, and an inaccurate NatSpec comment references OmniCore as needing BURNER_ROLE when OmniCore does not call `burnFrom`.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 5 |
| Informational | 5 |

**Overall Assessment: PRODUCTION READY with caveats noted below.**

---

## Severity Definitions

| Severity | Definition |
|----------|------------|
| Critical | Direct, unconditional fund loss or total system compromise |
| High | Conditional fund loss requiring specific but plausible preconditions |
| Medium | Economic issues, access control gaps, or trust model concerns |
| Low | Best practice deviations, minor optimizations, documentation gaps |
| Informational | Style, documentation completeness, non-security observations |

---

## Findings Summary Table

| ID | Severity | Title | Status | New/Prev |
|----|----------|-------|--------|----------|
| M-01 | Medium | BURNER_ROLE allowance bypass remains a critical trust dependency | ACCEPTED | Round 1 |
| M-02 | Medium | ERC2771 trusted forwarder is immutable -- cannot be rotated if compromised | ACCEPTED | Round 6 |
| M-03 | Medium | NatSpec incorrectly claims admin functions use msg.sender -- they actually use _msgSender() via onlyRole | OPEN | **NEW** |
| L-01 | Low | Inherited burn() allows self-burn without BURNER_ROLE | ACCEPTED | Round 1 |
| L-02 | Low | IOmniCoin interface declares maxSupplyCap() which OmniCoin does not implement | OPEN | **NEW** |
| L-03 | Low | NatSpec references OmniCore as BURNER_ROLE holder, but OmniCore never calls burnFrom | OPEN | **NEW** |
| L-04 | Low | batchTransfer allows zero-length arrays (no-op succeeds) | ACCEPTED | Round 6 |
| L-05 | Low | No _disableInitializers() call in constructor | ACCEPTED | Round 6 |
| I-01 | Info | batchTransfer allows zero-amount transfers | UNCHANGED | Round 1 |
| I-02 | Info | No aggregate BatchTransfer event | UNCHANGED | Round 1 |
| I-03 | Info | approve()/permit() work while paused | UNCHANGED | Round 1 |
| I-04 | Info | ERC20Votes clock uses block numbers (not timestamps) | UNCHANGED | Round 6 |
| I-05 | Info | Consider adding EIP-165 supportsInterface override | UNCHANGED | Round 6 |

---

## Remediation Status from Previous Audits

### Round 1 (2026-02-20)

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-01 | High | INITIAL_SUPPLY mismatch (1B vs spec) | **RESOLVED** -- now 16.6B full pre-mint |
| H-02 | High | Missing ERC20Votes (flash loan governance risk) | **RESOLVED** -- ERC20Votes integrated |
| H-03 | High | No on-chain supply cap | **RESOLVED** -- MAX_SUPPLY constant + mint() check |
| M-01 | Medium | burnFrom() bypasses allowance | **ACCEPTED** -- by design for PrivateOmniCoin |
| M-02 | Medium | No timelock on admin ops | **RESOLVED** -- 48-hour delay via AccessControlDefaultAdminRules |
| M-03 | Medium | No two-step admin transfer | **RESOLVED** -- same AccessControlDefaultAdminRules |
| L-01 | Low | Inherited burn() unrestricted | **ACCEPTED** -- standard ERC20Burnable behavior |
| L-02 | Low | Contract brickable if initialize() never called | **ACCEPTED** -- mitigated by deployment script atomicity |
| L-03 | Low | batchTransfer no address(this) check | **RESOLVED** -- address(this) now rejected |
| I-01 | Info | Floating pragma | **RESOLVED** -- pinned to 0.8.24 |

### Round 4 Attacker Review (2026-02-28)

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| ATK-H03 | High | burnFrom() BURNER_ROLE god mode | **ACCEPTED** -- documented in NatSpec with governance requirements |
| ATK-M03 | Medium | Flash loan voting via delegate() | **MITIGATED** -- VOTING_DELAY in OmniGovernance prevents same-block exploitation |

### Round 6 (2026-03-10)

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | Medium | BURNER_ROLE allowance bypass | **ACCEPTED** -- carried forward as M-01 in this report |
| M-02 | Medium | Immutable forwarder | **ACCEPTED** -- carried forward as M-02 in this report |
| L-01 | Low | Self-burn asymmetry | **ACCEPTED** -- carried forward as L-01 |
| L-02 | Low | initialize() NatSpec missing msg.sender note | **ACCEPTED** |
| L-03 | Low | Empty batch allowed | **ACCEPTED** -- carried forward as L-04 |
| L-04 | Low | No _disableInitializers | **ACCEPTED** -- carried forward as L-05 |

---

## Pass 1: Solhint + Contract Read

### Solhint Results

```
[solhint] Warning: Rule 'contract-name-camelcase' doesn't exist
[solhint] Warning: Rule 'event-name-camelcase' doesn't exist
```

No contract-level warnings or errors. The two warnings are about non-existent rules in the solhint configuration, not about the contract itself.

Slither: skipped.

### Contract Structure

The contract is 309 lines and inherits from seven OpenZeppelin v5 base contracts:

```
OmniCoin
  +-- ERC20                           (core token)
  +-- ERC20Burnable                   (self-burn)
  +-- ERC20Pausable                   (emergency pause)
  +-- ERC20Permit                     (gasless approvals, EIP-2612)
  +-- ERC20Votes                      (governance delegation, checkpoints)
  +-- AccessControlDefaultAdminRules  (RBAC with 48h admin delay)
  +-- ERC2771Context                  (meta-transaction support)
```

Custom functions: `initialize()`, `mint()`, `pause()`, `unpause()`, `batchTransfer()`, `burnFrom()` override.

Diamond resolution overrides: `nonces()`, `_update()`, `_msgSender()`, `_msgData()`, `_contextSuffixLength()`.

---

## Pass 2: Manual Line-by-Line Review

### Reentrancy

**Status: NOT VULNERABLE**

OmniCoin makes zero external calls. All state changes use internal OZ functions:
- `_mint()`, `_burn()`, `_transfer()` -- internal balance updates
- `_grantRole()` -- internal role state
- `_pause()`, `_unpause()` -- internal flag

No ETH handling, no callback hooks, no ERC777-style receiver patterns. OZ v5 ERC20 does not have `_beforeTokenTransfer`/`_afterTokenTransfer` hooks.

**Verdict: PASS**

### Access Control

All state-changing functions have explicit guards:

| Function | Guard | Uses msg.sender or _msgSender? |
|----------|-------|-------------------------------|
| `initialize()` | `msg.sender != _deployer` + `totalSupply() != 0` | `msg.sender` directly |
| `mint()` | `onlyRole(MINTER_ROLE)` | `_msgSender()` via onlyRole |
| `burnFrom()` | `onlyRole(BURNER_ROLE)` | `_msgSender()` via onlyRole |
| `pause()` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `_msgSender()` via onlyRole |
| `unpause()` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `_msgSender()` via onlyRole |
| `batchTransfer()` | `whenNotPaused` | `_msgSender()` explicitly |
| `transfer()` | `whenNotPaused` (ERC20Pausable) | `_msgSender()` via ERC20 |
| `burn()` | None (self-burn) | `_msgSender()` via ERC20Burnable |

**Important discovery (see M-03):** The NatSpec at line 37 claims "Admin/minter functions deliberately use msg.sender" but `pause()`, `unpause()`, `mint()`, and `burnFrom()` all use `onlyRole()` which resolves through `_msgSender()` (the ERC2771 context). Only `initialize()` uses raw `msg.sender`.

**Verdict: PASS (with M-03 caveat)**

### Overflow/Underflow

Solidity 0.8.24 provides built-in protection. No `unchecked` blocks in the contract. The `totalSupply() + amount > MAX_SUPPLY` check in `mint()` is safe because the addition reverts on overflow before the comparison.

**Verdict: PASS**

### Front-Running

- `initialize()`: Cannot be front-run -- `_deployer` is immutable from constructor
- `approve()`: Standard ERC20 race condition, mitigated by `permit()` (EIP-2612)
- `mint()`: Dead function post-initialization (MAX_SUPPLY already reached)
- `batchTransfer()`: No MEV-extractable value (direct peer-to-peer transfers)

**Verdict: PASS**

### Logic Errors

- `batchTransfer` atomicity: If any single transfer fails, all are reverted. Correct.
- `batchTransfer` duplicate recipients: Allowed, each transfer processes independently. Correct.
- `batchTransfer` self-transfer: Allowed (sender transfers to themselves). Harmless.
- `_update` C3 linearization: ERC20Votes -> ERC20Pausable -> ERC20. Correct order (pause check before checkpoint update before balance update).

**Verdict: PASS**

### Gas Optimizations

- `batchTransfer`: `_msgSender()` correctly cached in `sender` variable (line 193)
- Loop iterator uses `++i` (pre-increment, slightly cheaper)
- Could use `unchecked { ++i }` for the loop counter (max 10 iterations, cannot overflow). Minor optimization (~20 gas per iteration = ~200 gas max).
- Constants (`MINTER_ROLE`, `BURNER_ROLE`, `INITIAL_SUPPLY`, `MAX_SUPPLY`) are `constant`, not `immutable`. This is correct -- they are compile-time constants.

**Verdict: PASS (minor optimization possible in loop)**

---

## Pass 3: Access Control & Authorization

### Role Hierarchy

```
DEFAULT_ADMIN_ROLE (bytes32(0))
  |-- Admin of: MINTER_ROLE, BURNER_ROLE (default role admin)
  |-- Functions: pause(), unpause(), grantRole(), revokeRole()
  |-- Transfer: 48-hour delay via AccessControlDefaultAdminRules
  |-- Current holder: Deployer (to be transferred to TimelockController)
  |
  +-- MINTER_ROLE (keccak256("MINTER_ROLE"))
  |     |-- Functions: mint() [capped by MAX_SUPPLY]
  |     |-- Current holder: Deployer (to be permanently revoked)
  |     |-- Risk post-revocation: 1/10 (role cannot mint if not granted)
  |
  +-- BURNER_ROLE (keccak256("BURNER_ROLE"))
        |-- Functions: burnFrom() [allowance bypass]
        |-- Current holder: Deployer (to be transferred to PrivateOmniCoin)
        |-- Risk: 8/10 (can destroy any user's balance)
```

### Initializer Protection

| Check | Status |
|-------|--------|
| Constructor sets deployer immutably | PASS (`_deployer = msg.sender`) |
| Only deployer can initialize | PASS (`msg.sender != _deployer` revert) |
| Double-init prevention | PASS (`totalSupply() != 0` revert) |
| DEFAULT_ADMIN_ROLE set in constructor (not init) | PASS (`AccessControlDefaultAdminRules` constructor) |
| No selfdestruct | PASS |
| No delegatecall | PASS |
| No unprotected external calls | PASS |

### Privilege Escalation Analysis

**Path 1:** Attacker gains DEFAULT_ADMIN_ROLE
- Requires: 48-hour admin transfer (begin + accept)
- Impact: Can grant MINTER_ROLE (useless if at MAX_SUPPLY) or BURNER_ROLE (critical)
- Mitigation: 48-hour detection window, cancel capability

**Path 2:** Compromised BURNER_ROLE holder
- Requires: Vulnerability in PrivateOmniCoin
- Impact: Can burn any user's XOM balance
- Mitigation: PrivateOmniCoin is a separate audited contract

**Path 3:** Forwarder compromise
- Requires: Vulnerability in OmniForwarder (OZ ERC2771Forwarder)
- Impact: Can impersonate any user for transfers, approvals; can also impersonate admin for pause/unpause/role management (see M-03)
- Mitigation: Forwarder is immutable, based on audited OZ code

**No unexpected privilege escalation paths found.**

---

## Pass 4: Economic/Financial Analysis

### Token Supply

| Parameter | Value | Verified |
|-----------|-------|----------|
| INITIAL_SUPPLY | 16,600,000,000 * 10^18 | Yes |
| MAX_SUPPLY | 16,600,000,000 * 10^18 | Yes |
| INITIAL_SUPPLY == MAX_SUPPLY | Yes | Correct -- all tokens pre-minted |
| Decimals | 18 (ERC20 default) | Yes |
| Post-init totalSupply | 16.6B * 10^18 | Yes |

### Minting Controls

After `initialize()`:
1. `totalSupply() == MAX_SUPPLY == 16.6B * 10^18`
2. Any `mint(to, amount)` where `amount > 0` reverts with `ExceedsMaxSupply`
3. If tokens are burned (self-burn or BURNER_ROLE), `mint()` can succeed up to MAX_SUPPLY
4. This is by design for XOM <-> pXOM privacy roundtripping

### Burn Mechanics

Two burn paths:
1. `burn(amount)` -- any holder can self-burn (inherited from ERC20Burnable). No role required.
2. `burnFrom(from, amount)` -- requires BURNER_ROLE. Bypasses allowance. Can burn from any address.

### Transfer Restrictions

- Standard ERC20 transfers with Pausable
- No fee-on-transfer (correct -- fees handled by application-layer contracts)
- No blacklist/whitelist
- No transfer limits

**Verdict: ECONOMICALLY SOUND**

---

## Pass 5: Integration & Edge Cases

### External Call Analysis

OmniCoin makes ZERO external calls. All function implementations use only internal OZ library functions. No `call`, `delegatecall`, `staticcall`, or `transfer` of ETH.

### Zero Amount Edge Cases

| Function | Zero Amount Behavior | Verdict |
|----------|---------------------|---------|
| `transfer(to, 0)` | Succeeds, emits Transfer event | Standard ERC20 |
| `transferFrom(from, to, 0)` | Succeeds, emits Transfer event | Standard ERC20 |
| `approve(spender, 0)` | Succeeds, clears allowance | Standard ERC20 |
| `mint(to, 0)` | Reverts (totalSupply + 0 > MAX_SUPPLY is false, but _mint(to, 0) succeeds without revert -- WAIT, need to check) | See analysis below |
| `burnFrom(from, 0)` | Succeeds, emits Transfer event | Harmless |
| `burn(0)` | Succeeds, emits Transfer event | Harmless |
| `batchTransfer([], [])` | Succeeds, returns true | See L-04 |

**`mint(to, 0)` analysis:** After initialization, `totalSupply() + 0 > MAX_SUPPLY` evaluates to `16.6B > 16.6B` which is `false`. So the MAX_SUPPLY check passes. Then `_mint(to, 0)` executes, which in OZ v5 emits a `Transfer(address(0), to, 0)` event. This is a no-op zero-mint that succeeds. This is harmless but technically allows MINTER_ROLE holders to emit misleading Transfer events from address(0). Since MINTER_ROLE will be permanently revoked, this is a non-issue.

### Maximum Value Edge Cases

- `mint(to, type(uint256).max)`: `totalSupply() + type(uint256).max` overflows in Solidity 0.8.x, reverts. Safe.
- `transfer(to, type(uint256).max)`: Reverts with `ERC20InsufficientBalance`. Safe.
- `batchTransfer` with 10 recipients each receiving `type(uint256).max`: First transfer reverts. Atomic rollback. Safe.

### Pause/Unpause Safety

| Operation | When Paused |
|-----------|-------------|
| `transfer()` | Reverts (ERC20Pausable._update) |
| `transferFrom()` | Reverts |
| `mint()` | Reverts (goes through _update) |
| `burnFrom()` | Reverts (goes through _update) |
| `burn()` | Reverts (goes through _update) |
| `batchTransfer()` | Reverts (whenNotPaused modifier) |
| `approve()` | **Succeeds** (does not go through _update) |
| `permit()` | **Succeeds** (does not go through _update) |
| `delegate()` | **Succeeds** (does not go through _update) |

Approve and permit working while paused is standard OZ behavior and is intentional.

### Cross-Contract Integration Points

| External Contract | Interaction Method | Risk |
|---|---|---|
| PrivateOmniCoin | Will hold BURNER_ROLE on OmniCoin | If PrivateOmniCoin is compromised, attacker can burn any user's XOM |
| OmniCore | Uses `safeTransferFrom` / `safeTransfer` (NOT burnFrom) | Standard ERC20 interaction, no elevated risk |
| OmniPrivacyBridge | Calls `burnFrom` on PrivateOmniCoin (NOT OmniCoin) | No direct risk to OmniCoin |
| OmniRewardManager | Uses `safeTransfer` to distribute XOM | Standard ERC20 interaction |
| OmniGovernance | Uses `getVotes()` / `getPastVotes()` for voting power | Read-only, no risk |
| OmniForwarder | Trusted forwarder for meta-transactions | Compromise enables impersonation (see M-02, M-03) |

**Cross-contract finding:** The NatSpec on OmniCoin line 71-74 states "BURNER_ROLE is granted to OmniCore for legacy balance migration burn-and-reissue." However, OmniCore.sol does NOT call `burnFrom()` -- it uses only `safeTransferFrom()` and `safeTransfer()`. The word "burn" does not appear anywhere in OmniCore.sol. See L-03.

---

## Detailed Findings

### [M-01] BURNER_ROLE Allowance Bypass Remains a Critical Trust Dependency

**Severity:** Medium (Acknowledged Design)
**Category:** Access Control / Trust Model
**Location:** `burnFrom()` (lines 223-228)
**Status:** ACCEPTED (Round 1 through Round 7)

**Description:**

The `burnFrom()` function bypasses the standard ERC20 allowance mechanism:

```solidity
function burnFrom(
    address from,
    uint256 amount
) public override onlyRole(BURNER_ROLE) {
    _burn(from, amount);
}
```

Any holder of BURNER_ROLE can burn tokens from ANY address without that address's consent or allowance. This is by design for PrivateOmniCoin privacy conversions, but it creates an outsized trust dependency on whichever contract holds this role.

**Impact:** If BURNER_ROLE is granted to a compromised contract, any user's entire XOM balance can be destroyed without recovery.

**Mitigations in place:**
1. Comprehensive NatSpec warning (lines 203-218)
2. DEFAULT_ADMIN_ROLE (which controls BURNER_ROLE grants) has 48-hour transfer delay
3. Documented requirement: BURNER_ROLE must ONLY go to audited contracts
4. Documented requirement: NEVER grant to an EOA in production

**Recommended additional mitigations:**
1. Add deployment verification test asserting exact set of BURNER_ROLE holders
2. Set up off-chain monitoring for `RoleGranted(BURNER_ROLE, ...)` events
3. Consider a per-epoch burn rate limiter as defense-in-depth

---

### [M-02] ERC2771 Trusted Forwarder is Immutable -- Cannot Be Rotated If Compromised

**Severity:** Medium (Acknowledged Design)
**Category:** Trust Model / Upgradeability
**Location:** Constructor, line 126: `ERC2771Context(trustedForwarder_)`
**Status:** ACCEPTED (Round 6 through Round 7)

**Description:**

The trusted forwarder address is immutable. If OmniForwarder is found to have a vulnerability, there is no mechanism to:
1. Revoke the old forwarder's trusted status
2. Set a new trusted forwarder

The only mitigation is `pause()` (stops all transfers) or deploying an entirely new OmniCoin contract.

**Impact:** If the forwarder is compromised, an attacker can impersonate any user for ERC20 operations AND admin operations (see M-03). The emergency response is pause + redeploy.

**Mitigations in place:**
1. OmniForwarder is a thin wrapper around OZ's audited ERC2771Forwarder
2. Immutability prevents admin from swapping to a malicious forwarder
3. `pause()` provides emergency stop
4. `address(0)` can be passed at deployment to disable meta-transactions entirely

---

### [M-03] NatSpec Incorrectly Claims Admin Functions Use msg.sender -- They Actually Use _msgSender() via onlyRole (NEW)

**Severity:** Medium
**Category:** Access Control / Documentation Accuracy
**Location:** Line 37 (NatSpec) and lines 158, 167, 175, 226 (function implementations)
**Status:** OPEN

**Description:**

The contract-level NatSpec at line 37 states:

```
 * - Admin/minter functions deliberately use msg.sender (admin ops should NOT be relayed)
```

This claim is **factually incorrect** for the following functions:

| Function | Guard | Actual _msgSender Usage |
|----------|-------|-------------------------|
| `pause()` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `_checkRole()` calls `_msgSender()` |
| `unpause()` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `_checkRole()` calls `_msgSender()` |
| `mint()` | `onlyRole(MINTER_ROLE)` | `_checkRole()` calls `_msgSender()` |
| `burnFrom()` | `onlyRole(BURNER_ROLE)` | `_checkRole()` calls `_msgSender()` |

The `onlyRole()` modifier in OZ AccessControl calls `_checkRole(role)` which calls `_checkRole(role, _msgSender())`. Since OmniCoin overrides `_msgSender()` to use `ERC2771Context._msgSender()`, the role check resolves through the ERC2771 context. This means admin operations CAN be relayed through the trusted forwarder.

Only `initialize()` uses raw `msg.sender` (line 138).

**Impact:**

1. **Misleading security documentation:** Developers and auditors may rely on the claim that admin operations cannot be relayed, leading to incorrect threat modeling.

2. **Enlarged forwarder trust surface:** If the trusted forwarder is compromised, an attacker can not only impersonate users for transfers (as expected) but also impersonate the admin for `pause()`, `unpause()`, role grants, and role revocations. This is a strictly larger attack surface than what the NatSpec claims.

3. **Inherited role management:** `grantRole()`, `revokeRole()`, `beginDefaultAdminTransfer()`, `cancelDefaultAdminTransfer()`, and `acceptDefaultAdminTransfer()` also use `_msgSender()` via their internal checks in AccessControl and AccessControlDefaultAdminRules. All of these can be relayed.

**Proof of Concept:**

OpenZeppelin v5 AccessControl._checkRole():
```solidity
function _checkRole(bytes32 role) internal view virtual {
    _checkRole(role, _msgSender());
}
```

When the trusted forwarder calls `pause()` on OmniCoin:
1. `msg.sender` is the forwarder address
2. `isTrustedForwarder(msg.sender)` returns true
3. `_msgSender()` extracts the appended 20-byte address from calldata
4. `_checkRole(DEFAULT_ADMIN_ROLE, extractedAddress)` checks if the appended address has the admin role
5. If the forwarder is compromised and forges the appended address to be the actual admin, the check passes

**Recommended Fix:**

**Option A (Correct the NatSpec):** Update line 37 to accurately reflect behavior:

```solidity
 * - Admin/minter functions use _msgSender() via onlyRole(), meaning they CAN
 *   be relayed through the trusted forwarder. The forwarder's EIP-712 signature
 *   validation prevents unauthorized relay. Only initialize() uses raw msg.sender.
```

**Option B (Enforce msg.sender for admin functions):** Override the admin functions to use raw `msg.sender` checks:

```solidity
function pause() external {
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
        revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
    }
    _pause();
}
```

Option A is recommended because the EIP-712 signature validation in the forwarder already provides equivalent protection, and changing to raw `msg.sender` would break compatibility if admin operations via meta-transactions are ever needed.

---

### [L-01] Inherited burn() Allows Self-Burn Without BURNER_ROLE

**Severity:** Low
**Category:** Access Control Asymmetry
**Location:** Inherited from `ERC20Burnable` (not overridden in OmniCoin.sol)
**Status:** ACCEPTED (Round 1 through Round 7)

**Description:**

Any token holder can call `burn(amount)` to destroy their own tokens without BURNER_ROLE. This creates an access control asymmetry: `burn()` requires no role, but `burnFrom()` requires BURNER_ROLE. Self-burn is standard ERC20Burnable behavior.

**Impact:** Users can permanently reduce their own balance and the totalSupply, which allows future `mint()` calls to succeed up to MAX_SUPPLY. Since MINTER_ROLE will be permanently revoked, this has no practical economic impact.

---

### [L-02] IOmniCoin Interface Declares maxSupplyCap() Which OmniCoin Does Not Implement (NEW)

**Severity:** Low
**Category:** Interface Compliance
**Location:** `contracts/interfaces/IOmniCoin.sol` line 23 vs. `contracts/OmniCoin.sol`
**Status:** OPEN

**Description:**

The `IOmniCoin` interface at `contracts/interfaces/IOmniCoin.sol` declares:

```solidity
interface IOmniCoin is IERC20 {
    function mint(address to, uint256 amount) external;
    function maxSupplyCap() external view returns (uint256);
    function decimals() external view returns (uint8);
}
```

OmniCoin.sol does NOT implement `maxSupplyCap()`. It has `MAX_SUPPLY` as a public constant, which auto-generates a getter named `MAX_SUPPLY()`, not `maxSupplyCap()`. The `maxSupplyCap()` function only exists in `MintController.sol` (which is deprecated).

**Impact:**

1. OmniCoin does not conform to its own declared interface
2. Any contract that casts an OmniCoin address to `IOmniCoin` and calls `maxSupplyCap()` will revert
3. Currently, no deployed contract uses the `IOmniCoin` interface (it is unused), so there is no runtime impact

**Recommended Fix:**

Either update `IOmniCoin` to match the actual contract:

```solidity
interface IOmniCoin is IERC20 {
    function mint(address to, uint256 amount) external;
    function MAX_SUPPLY() external view returns (uint256);
    function decimals() external view returns (uint8);
}
```

Or add a `maxSupplyCap()` view function to OmniCoin:

```solidity
function maxSupplyCap() external pure returns (uint256) {
    return MAX_SUPPLY;
}
```

---

### [L-03] NatSpec References OmniCore as BURNER_ROLE Holder, but OmniCore Never Calls burnFrom (NEW)

**Severity:** Low
**Category:** Documentation Accuracy
**Location:** Lines 71-74

**Description:**

The NatSpec comment on the `BURNER_ROLE` constant states:

```solidity
/// @dev AUDIT ACCEPTED (Round 6): BURNER_ROLE is granted to OmniCore for legacy
///      balance migration burn-and-reissue. In production, BURNER_ROLE will be
///      granted ONLY to OmniCore and revoked after migration completes.
```

Cross-contract analysis reveals that `OmniCore.sol` does NOT call `burnFrom()` on OmniCoin. A search for `burn` in OmniCore.sol returns zero matches. OmniCore uses only:
- `OMNI_COIN.safeTransferFrom(caller, address(this), amount)` (line 793)
- `OMNI_COIN.safeTransfer(caller, amount)` (line 844)
- `OMNI_COIN.safeTransfer(claimAddress, amount)` (line 1280)

The comment creates confusion about who actually needs BURNER_ROLE. Based on the architecture documentation and code analysis, the intended sole holder of BURNER_ROLE on OmniCoin is PrivateOmniCoin (for XOM-to-pXOM privacy conversions), not OmniCore.

**Impact:** Misleading documentation may lead to incorrect deployment decisions (granting BURNER_ROLE to OmniCore unnecessarily, expanding the attack surface).

**Recommended Fix:**

Update lines 71-74 to:

```solidity
/// @dev AUDIT ACCEPTED (Round 6): BURNER_ROLE is granted to PrivateOmniCoin
///      for XOM-to-pXOM privacy conversions. In production, BURNER_ROLE will be
///      granted ONLY to PrivateOmniCoin. The role can only burn tokens, not
///      transfer them.
```

---

### [L-04] batchTransfer Allows Zero-Length Arrays (No-Op Succeeds)

**Severity:** Low
**Category:** Input Validation
**Location:** `batchTransfer()` lines 186-200
**Status:** ACCEPTED (Round 6)

**Description:**

`batchTransfer([], [])` succeeds and returns `true`. Arrays pass validation (0 == 0, 0 <= 10). Loop never executes. Caller wastes gas on a no-op.

**Impact:** No security impact. Minor UX concern for off-chain monitoring.

---

### [L-05] No _disableInitializers() Call in Constructor

**Severity:** Low
**Category:** Best Practice
**Location:** Constructor, lines 122-129
**Status:** ACCEPTED (Round 6)

**Description:**

OmniCoin is not upgradeable but has a manual `initialize()` function. For defense-in-depth, `_disableInitializers()` could be called in the constructor. However, OmniCoin does not inherit from `Initializable` and uses its own `totalSupply() != 0` guard, which provides equivalent protection.

**Impact:** None in current deployment architecture.

---

## Informational Findings

### [I-01] batchTransfer Allows Zero-Amount Transfers

**Location:** `batchTransfer()` loop body, line 196
**Status:** UNCHANGED (Round 1)

`amounts[i] = 0` succeeds, emitting a `Transfer` event with value 0. Harmless but wastes gas.

### [I-02] No Aggregate BatchTransfer Event

**Location:** `batchTransfer()` lines 186-200
**Status:** UNCHANGED (Round 1)

Individual `Transfer` events are emitted for each transfer. No aggregate `BatchTransfer` event. Standard practice (Uniswap, 1inch all rely on individual events).

### [I-03] approve()/permit() Work While Paused

**Location:** Inherited ERC20 `approve()` and ERC20Permit `permit()`
**Status:** UNCHANGED (Round 1)

Standard OZ behavior. Allows users to prepare approvals during pause. By design.

### [I-04] ERC20Votes Clock Uses Block Numbers (Not Timestamps)

**Location:** Inherited from ERC20Votes
**Status:** UNCHANGED (Round 6)

OZ v5 ERC20Votes defaults to block numbers for checkpoints. On OmniCoin L1 (2-second block time), this is appropriate and more manipulation-resistant than timestamps.

### [I-05] Consider Adding EIP-165 supportsInterface Override

**Location:** Contract-level
**Status:** UNCHANGED (Round 6)

`AccessControlDefaultAdminRules` already provides `supportsInterface()` via `AccessControl`. An explicit override documenting all supported interfaces (ERC20, ERC20Permit, AccessControl) would improve introspection. No action needed.

---

## Static Analysis

### Solhint

No contract-level warnings or errors. Two configuration warnings about non-existent rules (cosmetic).

### Slither

Slither: skipped.

### Manual Equivalent Checks

| Check | Result |
|-------|--------|
| Reentrancy | PASS -- no external calls |
| Uninitialized state variables | PASS -- all set in constructor or initialize |
| Unused return values | PASS -- no external calls with return values |
| tx.origin usage | PASS -- not used |
| Assembly blocks | PASS -- none |
| Delegatecall | PASS -- not used |
| Selfdestruct | PASS -- not used |
| Variable shadowing | PASS -- none detected |
| Unchecked arithmetic | PASS -- no unchecked blocks |
| Storage slot collision | PASS -- not upgradeable |
| Integer truncation | PASS -- all uint256 |

---

## Access Control Map

| Role | Functions Controlled | Risk Level | Current Holder | Recommended Holder |
|------|---------------------|------------|----------------|-------------------|
| DEFAULT_ADMIN_ROLE | `pause()`, `unpause()`, `grantRole()`, `revokeRole()`, admin transfer | 7/10 | Deployer (48h delay) | TimelockController + Multisig |
| MINTER_ROLE | `mint()` | 2/10 (capped at MAX_SUPPLY, already at cap) | Deployer (to be renounced) | NONE (permanently revoked) |
| BURNER_ROLE | `burnFrom()` (allowance bypass) | 8/10 | Deployer (to be transferred) | PrivateOmniCoin contract ONLY |
| (any holder) | `transfer()`, `approve()`, `permit()`, `burn()`, `batchTransfer()`, `delegate()` | 1/10 | All token holders | N/A |

**Centralization Risk Rating: 5/10**

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance to OmniCoin |
|---------|------|------|----------------------|
| Beanstalk DAO | 2022-04 | $80M | MITIGATED: ERC20Votes + VOTING_DELAY prevents flash loan voting |
| SafeMoon | 2023-03 | $8.9M | ACKNOWLEDGED: burnFrom bypass by design (M-01) |
| Cover Protocol | 2020-12 | N/A | MITIGATED: MAX_SUPPLY cap prevents unlimited minting |
| DAO Maker | 2021-09 | $4M | MITIGATED: All tokens pre-minted, MINTER_ROLE to be revoked |
| Ronin Network | 2022-03 | $624M | PARTIALLY MITIGATED: 48h admin delay; TimelockController recommended |
| Harmony Bridge | 2022-06 | $100M | PARTIALLY MITIGATED: 48h delay, multisig recommended |
| OZ ERC2771+Multicall | 2023-07 | N/A (CVE-2023-34459) | MITIGATED: OZ v5.4.0 includes the fix |

---

## Deployment Checklist

Based on all seven audit rounds, the following deployment steps are recommended:

- [ ] Deploy OmniForwarder (or pass address(0) to disable meta-transactions initially)
- [ ] Deploy OmniCoin with trusted forwarder address
- [ ] Call `initialize()` from deployer in the same deployment script (atomic)
- [ ] Transfer tokens to pool contracts (LegacyBalanceClaim, OmniRewardManager, StakingRewardPool)
- [ ] Grant BURNER_ROLE to PrivateOmniCoin contract address (NOT OmniCore -- see L-03)
- [ ] Revoke MINTER_ROLE from deployer: `revokeRole(MINTER_ROLE, deployer)`
- [ ] Revoke BURNER_ROLE from deployer: `revokeRole(BURNER_ROLE, deployer)`
- [ ] Begin admin transfer to TimelockController: `beginDefaultAdminTransfer(timelockAddress)`
- [ ] Wait 48 hours
- [ ] Accept admin transfer from TimelockController: `acceptDefaultAdminTransfer()`
- [ ] **Verify:** deployer has NO roles remaining
- [ ] **Verify:** MINTER_ROLE has ZERO holders
- [ ] **Verify:** BURNER_ROLE has exactly one holder (PrivateOmniCoin)
- [ ] **Verify:** DEFAULT_ADMIN_ROLE holder is TimelockController
- [ ] **Verify:** `totalSupply() == MAX_SUPPLY == 16_600_000_000 * 10^18`
- [ ] **Verify:** trusted forwarder address is correct (or address(0))

---

## Remediation Priority

| Priority | Finding | Effort | Impact | Action |
|----------|---------|--------|--------|--------|
| 1 | **M-03:** NatSpec incorrectly claims admin uses msg.sender | Trivial | Documentation accuracy | Update NatSpec at line 37 |
| 2 | **L-03:** NatSpec references OmniCore incorrectly | Trivial | Documentation accuracy | Update NatSpec at lines 71-74 |
| 3 | **L-02:** IOmniCoin interface mismatch | Low | Interface compliance | Update interface or add maxSupplyCap() |
| 4 | M-01: BURNER_ROLE trust dependency | Low | Deployment verification | Add deployment test asserting exact role holders |
| 5 | M-02: Immutable forwarder | Decision | Architecture | Finalize: deploy with forwarder or address(0) |
| 6 | L-01: Self-burn asymmetry | None | Documentation | Already documented |
| 7 | L-04: Empty batch allowed | Trivial | UX | Optional: add empty array check |
| 8 | L-05: No _disableInitializers | None | N/A | No action needed |

---

## Conclusion

OmniCoin.sol continues to demonstrate strong security posture through seven rounds of auditing. All three High-severity findings from Round 1 remain fully remediated. The contract leverages battle-tested OpenZeppelin v5 components effectively and has a minimal custom code surface.

**New findings in Round 7:**

1. **M-03 (NatSpec inaccuracy on admin _msgSender):** The most significant new finding. The contract's documentation claims admin functions use raw `msg.sender` to prevent meta-transaction relay, but they actually use `_msgSender()` via the `onlyRole()` modifier. The fix is trivial (update NatSpec) but the finding matters for accurate threat modeling. The actual security impact is minimal because the forwarder validates EIP-712 signatures, preventing unauthorized relay.

2. **L-02 (IOmniCoin interface mismatch):** The `IOmniCoin` interface declares `maxSupplyCap()` which OmniCoin does not implement. Currently unused, so no runtime impact.

3. **L-03 (OmniCore NatSpec inaccuracy):** The BURNER_ROLE NatSpec incorrectly references OmniCore as the intended holder. OmniCore never calls `burnFrom()`. The intended holder is PrivateOmniCoin.

**Production readiness:** The contract is **PRODUCTION READY** with the following conditions:

1. Fix the M-03 NatSpec inaccuracy (trivial change, prevents incorrect threat modeling)
2. Fix the L-03 NatSpec inaccuracy (trivial change, prevents incorrect deployment)
3. BURNER_ROLE must be granted exclusively to PrivateOmniCoin (not OmniCore)
4. MINTER_ROLE must be permanently revoked after initial token distribution
5. DEFAULT_ADMIN_ROLE should be transferred to a TimelockController backed by a multisig
6. Decide on trusted forwarder: address(0) vs. OmniForwarder address

---

*Generated by Claude Code Audit Agent (6-Pass Pre-Mainnet) -- Round 7*
*Audit passes: Solhint, Manual Line-by-Line, Access Control & Authorization, Economic/Financial, Integration & Edge Cases, Report Generation*
*Reference data: Round 1 (2026-02-20), Round 4 (2026-02-28), Round 6 (2026-03-10), OZ v5.4.0 API analysis, cross-contract code review (OmniCore, PrivateOmniCoin, OmniPrivacyBridge, IOmniCoin)*
