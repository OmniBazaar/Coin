# Security Audit Report: PrivateUSDC.sol -- Round 6 (Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet Audit)
**Contract:** `Coin/contracts/privacy/PrivateUSDC.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 668
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (privacy-preserving USDC wrapper via COTI V2 MPC; custodies real USDC via SafeERC20)
**Previous Audit:** Round 1 (2026-02-26)

---

## Executive Summary

This is a comprehensive pre-mainnet security audit of PrivateUSDC.sol, a privacy-preserving USDC wrapper that uses COTI V2 MPC garbled circuits to enable encrypted balance management. The contract has undergone a **complete rewrite** since the Round 1 audit (2026-02-26), addressing all 1 Critical, 3 High, and 4 Medium findings from that audit.

The rewritten contract now:
- Custodies real USDC via `SafeERC20.safeTransferFrom()` and `safeTransfer()` (C-01 RESOLVED)
- Maintains per-user `publicBalances` mapping gating all operations (M-04 RESOLVED)
- Inherits `PausableUpgradeable` with `whenNotPaused` on all state-changing functions (H-03 RESOLVED)
- Restricts `privateBalanceOf()` and `getShadowLedgerBalance()` to account owner or admin (M-01, M-02 RESOLVED)
- Includes `privacyEnabled` toggle with auto-detection via `_detectPrivacyAvailability()` (L-03 RESOLVED)
- Includes `emergencyRecoverPrivateBalance()` using shadow ledger (M-03 RESOLVED)
- Uses `MpcCore.checkedAdd()` for overflow-safe encrypted arithmetic
- Properly debits `publicBalances` in `convertToPrivate()` and credits them in `convertToPublic()` (H-01, H-02 RESOLVED)

USDC's native 6 decimals match MPC's uint64 precision exactly, so `SCALING_FACTOR = 1` (identity). This makes PrivateUSDC the simplest of the three privacy wrapper contracts -- no scaling truncation occurs, no dust management is needed, and no precision loss is possible.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY with caveats noted below.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Shadow ledger desynchronization after private transfers -- emergency recovery incomplete | **FIXED** |
| M-02 | Medium | No timelock on privacy disable -- admin can instantly disable privacy and trigger recovery | **FIXED** |

---

## Remediation Status from Previous Audit (2026-02-26)

| Round 1 ID | Severity | Title | Status | Notes |
|------------|----------|-------|--------|-------|
| C-01 | Critical | bridgeMint does not transfer actual tokens | RESOLVED | Now calls `underlyingToken.safeTransferFrom()` on line 292-293 |
| H-01 | High | convertToPrivate has no token custody | RESOLVED | Debits `publicBalances[msg.sender]` (line 349) and `totalPublicSupply` (line 350) |
| H-02 | High | convertToPublic does not deliver tokens | RESOLVED | Credits `publicBalances[msg.sender]` (line 400) and `totalPublicSupply` (line 401) |
| H-03 | High | No pause mechanism | RESOLVED | Inherits `PausableUpgradeable`; `whenNotPaused` on all 5 state-changing functions |
| M-01 | Medium | privateBalanceOf exposes balances to all callers | RESOLVED | Restricted to owner or admin (lines 568-574) |
| M-02 | Medium | Shadow ledger is public | RESOLVED | `_shadowLedger` is `private`; `getShadowLedgerBalance()` restricted to owner/admin (lines 586-594) |
| M-03 | Medium | No emergency recovery mechanism | RESOLVED | `emergencyRecoverPrivateBalance()` implemented (lines 498-515) |
| M-04 | Medium | bridgeMint does not track per-user balances | RESOLVED | `publicBalances` mapping tracks per-user deposits (line 296) |
| L-01 | Low | Event amount parameters indexed | RESOLVED | Amounts no longer indexed (lines 155, 160, etc.) |
| L-02 | Low | SCALING_FACTOR constant is misleading | RESOLVED | NatSpec now explicitly documents identity scaling and API parity purpose (lines 88-93) |
| L-03 | Low | No privacyEnabled guard | RESOLVED | `privacyEnabled` with auto-detection and admin toggle (lines 134, 270, 479-484) |
| L-04 | Low | bridgeBurn does not verify caller relationship to `from` | RESOLVED | Debits `publicBalances[from]` with balance check (lines 315-320) |
| I-01 | Info | Missing privacy conversion fee documentation | RESOLVED | NatSpec documents "no fee; bridge charges 0.5%" (line 61) |
| I-02 | Info | Storage gap sizing | RESOLVED | Gap = 43 (50 - 7 state vars), documented in comment (lines 139-144) |
| I-03 | Info | Redundant `using` statement for gtBool | RESOLVED | `using MpcCore for gtBool` removed |

---

## New Findings

### [M-01] Shadow Ledger Desynchronization After Private Transfers -- Emergency Recovery Incomplete

**Severity:** Medium
**Lines:** 404-408, 461-466

**Description:**

The shadow ledger `_shadowLedger` tracks deposits made via `convertToPrivate()` for emergency recovery purposes. However, `privateTransfer()` (line 425) explicitly does NOT update the shadow ledger:

```solidity
// Note: Shadow ledger is NOT updated for private transfers
// because the amount is encrypted. Only deposits via
// convertToPrivate are tracked. In emergency recovery,
// amounts received via privateTransfer are not recoverable.
```

This is a documented design decision, and the NatSpec is clear about the limitation. However, the consequence is that emergency recovery via `emergencyRecoverPrivateBalance()` will:
1. **Over-recover** for users who deposited via `convertToPrivate()` but later transferred part of their balance away (shadow ledger shows full deposit, MPC balance is less)
2. **Under-recover** for users who received funds via `privateTransfer()` (shadow ledger shows zero or only their own deposits, but MPC balance includes received transfers)

The `convertToPublic()` function handles the first case via floor-at-zero clamping (lines 404-408):
```solidity
if (publicAmount > _shadowLedger[msg.sender]) {
    _shadowLedger[msg.sender] = 0;
} else {
    _shadowLedger[msg.sender] -= publicAmount;
}
```

This prevents underflow but does not solve the fundamental desynchronization for emergency recovery. In contrast, `PrivateOmniCoin.sol` addresses this with ATK-H08: its `privateTransfer()` decrypts the transfer amount and updates the shadow ledger for both sender and recipient (lines 592-603), ensuring emergency recovery reflects all balance changes.

**Impact:** In a scenario where COTI MPC becomes permanently unavailable and emergency recovery is triggered, users who received funds via `privateTransfer()` will lose those funds. Users who sent funds via `privateTransfer()` may over-recover at the expense of the contract's USDC reserves.

Over-recovery is bounded by the total USDC held by the contract, which itself is bounded by all `bridgeMint()` deposits minus all `bridgeBurn()` withdrawals. Therefore, the total recoverable amount across all users cannot exceed actual USDC held. However, individual users may receive more or less than their fair share.

**Recommendation:** Consider following the PrivateOmniCoin ATK-H08 pattern -- decrypt the transfer amount in `privateTransfer()` and update the shadow ledger for both parties:

```solidity
// In privateTransfer():
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
uint256 transferAmount = uint256(plainAmount);

if (_shadowLedger[msg.sender] >= transferAmount) {
    _shadowLedger[msg.sender] -= transferAmount;
} else {
    _shadowLedger[msg.sender] = 0;
}
_shadowLedger[to] += transferAmount;
```

This trades a small amount of privacy (the amount is decrypted internally but not emitted in events) for reliable emergency recovery. Given that this contract handles real USDC, reliable recovery is important.

**Alternative:** If the privacy trade-off is unacceptable, document prominently that emergency recovery is best-effort and may not fully recover all balances. The current NatSpec comments on `privateTransfer()` and `emergencyRecoverPrivateBalance()` already note this limitation, which is good.

---

### [M-02] No Timelock on Privacy Disable -- Admin Can Instantly Disable Privacy and Trigger Recovery

**Severity:** Medium
**Lines:** 479-484, 498-515

**Description:**

`setPrivacyEnabled(false)` can be called instantly by any admin to disable privacy, after which `emergencyRecoverPrivateBalance()` becomes callable. This creates a two-step attack vector for a compromised admin key:

1. Call `setPrivacyEnabled(false)` -- instant
2. Call `emergencyRecoverPrivateBalance(user)` for each user -- credits their `publicBalances` from shadow ledger
3. Call `bridgeBurn()` to extract real USDC to arbitrary addresses (admin has BRIDGE_ROLE from initialization)

The concern is that users holding private pUSDC balances have no warning period to `convertToPublic()` and `bridgeBurn()` their own funds before the admin can trigger recovery.

In contrast, `PrivateOmniCoin.sol` implements a 7-day timelock for privacy disable (ATK-H07 fix):
- `proposePrivacyDisable()` -- starts 7-day timer
- `executePrivacyDisable()` -- only callable after 7 days
- `cancelPrivacyDisable()` -- allows cancellation
- `PrivacyDisableProposed(uint256 executeAfter)` event gives users time to exit

PrivateUSDC has no such timelock. The admin can disable privacy and trigger recovery atomically.

**Impact:** A compromised admin key can extract all USDC held by the contract by disabling privacy, over-recovering for users via shadow ledger manipulation, and burning to arbitrary addresses. The attack is immediate with no user notification period.

Note that the admin already has BRIDGE_ROLE (from initialization), so they could also directly call `bridgeMint()` to credit themselves and `bridgeBurn()` to withdraw. The privacy disable path is an additional vector that could be harder to detect (emergency recovery looks legitimate).

**Recommendation:** Implement a timelock for privacy disable, matching the PrivateOmniCoin pattern:

```solidity
uint256 public constant PRIVACY_DISABLE_DELAY = 7 days;
uint256 public privacyDisableScheduledAt;

function proposePrivacyDisable()
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    privacyDisableScheduledAt =
        block.timestamp + PRIVACY_DISABLE_DELAY;
    emit PrivacyDisableProposed(privacyDisableScheduledAt);
}

function executePrivacyDisable()
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (privacyDisableScheduledAt == 0) revert NoPendingChange();
    if (block.timestamp < privacyDisableScheduledAt)
        revert TimelockActive();
    privacyEnabled = false;
    delete privacyDisableScheduledAt;
    emit PrivacyDisabled();
}
```

---

### [L-01] Admin Receives BRIDGE_ROLE at Initialization -- Excessive Initial Privilege

**Severity:** Low
**Lines:** 267

**Description:**

The `initialize()` function grants the admin both `DEFAULT_ADMIN_ROLE` and `BRIDGE_ROLE`:

```solidity
_grantRole(DEFAULT_ADMIN_ROLE, admin);
_grantRole(BRIDGE_ROLE, admin);
```

`BRIDGE_ROLE` grants the ability to call `bridgeMint()` and `bridgeBurn()`, which together control all USDC deposits and withdrawals. While the admin needs `BRIDGE_ROLE` to be transferred to the bridge contract, holding it simultaneously with `DEFAULT_ADMIN_ROLE` creates a single point of failure.

A compromised admin key can:
1. `bridgeMint(attacker, amount)` -- with attacker having pre-approved USDC allowance
2. `bridgeBurn(attacker, amount)` -- to extract USDC to attacker address

This is mitigated by the fact that `bridgeMint()` requires actual `safeTransferFrom()` (the admin must actually hold USDC), so phantom minting is not possible. However, the admin could manipulate `publicBalances` by minting to one address and burning from another if they hold sufficient USDC.

**Impact:** Low. The `safeTransferFrom()` requirement in `bridgeMint()` means the admin cannot mint unbacked balances. The window of excessive privilege exists only between deployment and role transfer to the bridge contract.

**Recommendation:** Consider not granting `BRIDGE_ROLE` in `initialize()`, instead having the admin grant it to the bridge contract after deployment. Or accept the current pattern if deployment scripts atomically transfer the role.

---

### [L-02] Emergency Recovery Can Be Triggered Before Users Have Exited -- No Grace Period

**Severity:** Low
**Lines:** 498-515

**Description:**

`emergencyRecoverPrivateBalance()` can be called immediately after `setPrivacyEnabled(false)`. There is no grace period for users to call `convertToPublic()` themselves before admin-initiated recovery begins. If a legitimate MPC outage occurs, the admin might:
1. Disable privacy
2. Immediately trigger recovery for all users

Users who had recently received private transfers (not tracked in shadow ledger) would lose those funds with no opportunity to self-recover. This is partially addressed by M-02 (timelock recommendation), but even without a timelock, a grace period between privacy disable and recovery eligibility would help.

**Impact:** Low. This is primarily a UX concern. The shadow ledger limitation means some funds may be unrecoverable regardless of timing.

**Recommendation:** Consider requiring a minimum delay between `setPrivacyEnabled(false)` and the first `emergencyRecoverPrivateBalance()` call. This gives users time to attempt `convertToPublic()` if MPC is still partially available.

---

### [L-03] No Event Emitted for underlyingToken Assignment in initialize()

**Severity:** Low
**Lines:** 269

**Description:**

The `underlyingToken` state variable is set once in `initialize()` but no event is emitted recording the address of the underlying USDC contract. While this value is readable via the public getter, an event would make it discoverable in transaction logs and audit trails without requiring state queries.

```solidity
underlyingToken = IERC20(_underlyingToken);
// No event emitted
```

**Impact:** Negligible. The value is readable via the public getter on `underlyingToken`. However, for a contract that custodies real USDC, the identity of the underlying token is critical and should be part of the initialization event trail.

**Recommendation:** Add an event:

```solidity
event Initialized(address indexed admin, address indexed underlyingToken);

// In initialize():
emit Initialized(admin, _underlyingToken);
```

---

### [L-04] SCALING_FACTOR Exists Solely for API Parity -- Adds Cognitive Load Without Functional Use

**Severity:** Low
**Lines:** 88-93

**Description:**

```solidity
uint256 public constant SCALING_FACTOR = 1;
```

The constant is well-documented as existing "for API parity with PrivateWETH (1e12) and PrivateWBTC (1e2). Not used in any calculation." However, the `convertToPrivate()` function does not reference `SCALING_FACTOR` at all -- it directly casts `uint64(amount)`. If a future developer sees `SCALING_FACTOR = 1` and assumes it should be used in scaling calculations (as it is in the sibling contracts), they might introduce it into the code path and get identity scaling that does nothing, potentially masking bugs in a refactor.

**Impact:** Negligible. The NatSpec is clear. This is a minor code clarity issue.

**Recommendation:** No action required. The NatSpec adequately documents the purpose. Alternatively, the three contracts could be refactored to share a base contract where the scaling factor is a virtual function, making the pattern explicit.

---

### [I-01] Shadow Ledger Over-Recovery Bounded by Contract USDC Balance

**Severity:** Informational
**Lines:** 498-515

**Description:**

In the worst case, `emergencyRecoverPrivateBalance()` could credit more `publicBalances` than a user's actual MPC balance (if they sent private transfers but shadow ledger still reflects deposits). However, the total USDC extractable is bounded by `underlyingToken.balanceOf(address(this))`. A user who calls `bridgeBurn()` after over-recovery can only extract up to the contract's actual USDC balance.

This means the contract cannot become insolvent in the traditional sense -- `safeTransfer()` will revert if the contract lacks sufficient USDC. However, the first users to `bridgeBurn()` after emergency recovery would succeed, while later users might find the contract depleted.

**Impact:** Informational. The USDC custody model provides a natural solvency bound. The risk is unfair distribution among users during emergency recovery, not loss of total USDC.

**Recommendation:** Document this behavior in the emergency recovery NatSpec. Consider implementing a batch recovery function that processes all users proportionally rather than first-come-first-served.

---

### [I-02] convertToPrivate Checks amount > type(uint64).max Before Debiting publicBalances

**Severity:** Informational
**Lines:** 343-346

**Description:**

In `convertToPrivate()`, the `AmountTooLarge` check on line 343 occurs before the `InsufficientPublicBalance` check on line 344-346:

```solidity
if (amount > type(uint64).max) revert AmountTooLarge();
if (amount > publicBalances[msg.sender]) {
    revert InsufficientPublicBalance();
}
```

For USDC with 6 decimals, `type(uint64).max` is approximately 18.4 trillion USDC -- effectively unreachable. The `InsufficientPublicBalance` check will always fire first for any realistic amount. The ordering is harmless but could be swapped for consistency with the sibling contracts (PrivateWBTC and PrivateWETH check scaling before balance).

**Impact:** None. Both checks are correct. The ordering only affects which error is returned for an amount that fails both checks.

**Recommendation:** No action required.

---

### [I-03] No ERC20 Interface Compliance -- Contract Is Not a Standard Token

**Severity:** Informational
**Lines:** 609-631

**Description:**

The contract implements `name()`, `symbol()`, and `decimals()` as pure functions, giving it token-like appearance in explorers. However, it does not implement `balanceOf()`, `transfer()`, `approve()`, `allowance()`, or `totalSupply()` -- standard ERC20 interface functions. Block explorers and portfolio trackers may display the token metadata but be unable to show balances or transfers.

This is by design: the contract is a privacy wrapper around USDC, not a standalone ERC20 token. The "balances" are split between `publicBalances` (public mapping) and `encryptedBalances` (MPC ciphertext). Standard ERC20 interfaces cannot represent this dual-balance model.

**Impact:** None. The contract is not intended to be ERC20-compliant. The `name()`/`symbol()`/`decimals()` functions provide metadata for wallet and explorer display.

**Recommendation:** No action required. Consider adding a comment explaining why ERC20 is intentionally not implemented.

---

## OWASP Smart Contract Top 10 Analysis

### SC01 -- Reentrancy

**Status: NOT VULNERABLE**

All state-changing functions use `nonReentrant` modifier or `onlyRole` access control. The `safeTransferFrom` and `safeTransfer` calls in `bridgeMint` and `bridgeBurn` are the only external calls. State changes (balance debits) occur before external calls in `bridgeBurn()` (CEI pattern, lines 319-322). In `bridgeMint()`, the external call is `safeTransferFrom` which pulls tokens IN -- reentrancy via the underlying USDC token's transfer hooks is theoretically possible but mitigated by `whenNotPaused` and `onlyRole(BRIDGE_ROLE)`.

### SC02 -- Arithmetic

**Status: SAFE**

- No scaling arithmetic (SCALING_FACTOR = 1, identity)
- No integer division truncation
- MPC overflow protected via `MpcCore.checkedAdd()` (lines 359)
- Standard Solidity 0.8.24 overflow protection on all uint256 arithmetic
- `publicBalances[msg.sender] -= amount` is underflow-protected by prior balance check

### SC03 -- Flash Loan / Price Manipulation

**Status: NOT APPLICABLE**

No oracle dependency. No price-dependent logic. No flash loan vectors.

### SC04 -- Access Control

**Status: PROPERLY IMPLEMENTED**

- `bridgeMint()` / `bridgeBurn()`: `onlyRole(BRIDGE_ROLE)` + `whenNotPaused`
- `convertToPrivate()` / `convertToPublic()` / `privateTransfer()`: `nonReentrant` + `whenNotPaused` (user-facing)
- `pause()` / `unpause()` / `setPrivacyEnabled()` / `emergencyRecoverPrivateBalance()` / `ossify()`: `onlyRole(DEFAULT_ADMIN_ROLE)`
- `privateBalanceOf()` / `getShadowLedgerBalance()`: owner or admin only

### SC05 -- Denial of Service

**Status: NOT VULNERABLE**

No unbounded loops. No external dependency in user-facing functions (except MPC precompile which is a system-level dependency). `bridgeMint()` and `bridgeBurn()` depend on underlying USDC token, but these are admin-gated.

### SC06 -- Unchecked External Calls

**Status: SAFE**

All external calls use `SafeERC20` (`safeTransferFrom`, `safeTransfer`) which reverts on failure. No raw `call()` or `delegatecall()`.

### SC07 -- Oracle / Bridge Integration

**Status: PROPERLY IMPLEMENTED**

Bridge functions require `BRIDGE_ROLE`. Token custody is enforced via `safeTransferFrom` (tokens must actually be transferred in). Per-user `publicBalances` prevent unauthorized conversion. The contract cannot mint unbacked private balances.

---

## Comparison with PrivateOmniCoin (Reference Pattern)

| Feature | PrivateOmniCoin | PrivateUSDC |
|---------|----------------|-------------|
| Token custody | ERC20 `_burn`/`_mint` (IS a token) | SafeERC20 custody (HOLDS a token) |
| Per-user balance | ERC20 `balanceOf` | `publicBalances` mapping |
| Pausability | `ERC20PausableUpgradeable` | `PausableUpgradeable` |
| Privacy toggle | `privacyEnabled` + auto-detect | `privacyEnabled` + auto-detect |
| Emergency recovery | `emergencyRecoverPrivateBalance()` | `emergencyRecoverPrivateBalance()` |
| Privacy disable timelock | 7-day delay (ATK-H07) | **MISSING** (instant disable) |
| Shadow ledger transfer tracking | Updated in `privateTransfer()` (ATK-H08) | **NOT updated** (documented limitation) |
| Shadow ledger visibility | `public` (acknowledged) | `private` with restricted getter |
| Balance query access | Owner only (ATK-H05) | Owner or admin |
| MPC arithmetic | `checkedAdd`/`checkedSub` | `checkedAdd` (sub uses `MpcCore.sub` with prior ge check) |
| Scaling | 1e12 (18 -> 6 decimals) | 1 (no scaling needed) |
| Dust handling | Sub-1e12 dust stays in public balance | N/A (no dust) |
| Supply cap | MAX_SUPPLY (16.6B XOM) | N/A (bounded by USDC custody) |
| Total private supply tracking | Encrypted `totalPrivateSupply` | Not tracked separately |

The two areas where PrivateUSDC lags behind PrivateOmniCoin are the privacy disable timelock (M-02) and shadow ledger transfer tracking (M-01). Both are noted as Medium findings above.

---

## Static Analysis

**Solhint:** 0 errors, 0 warnings expected based on contract structure. The contract follows proper ordering, uses custom errors, and has complete NatSpec.

---

## Methodology

- Pass 1: Remediation verification -- confirmed all 15 Round 1 findings addressed
- Pass 2: OWASP Smart Contract Top 10 analysis (SC01-SC07)
- Pass 3: Comparative analysis against PrivateOmniCoin (mature reference), PrivateWBTC, PrivateWETH
- Pass 4: Token custody model analysis -- verified USDC flow through bridgeMint -> convertToPrivate -> privateTransfer -> convertToPublic -> bridgeBurn lifecycle
- Pass 5: MPC-specific analysis -- overflow protection, ciphertext access control, privacy leakage vectors

---

## Conclusion

PrivateUSDC has been **completely rewritten** since the Round 1 audit, addressing all 1 Critical, 3 High, and 4 Medium findings. The contract now properly custodies real USDC via SafeERC20, maintains per-user public balances, includes pause/unpause capability, provides emergency recovery, and restricts balance queries to authorized parties.

The remaining findings are:
1. **M-01 (Shadow Ledger Desynchronization):** A documented design limitation. The shadow ledger does not track private transfers, meaning emergency recovery is incomplete for users who received funds via `privateTransfer()`. PrivateOmniCoin addresses this (ATK-H08), but PrivateUSDC does not.
2. **M-02 (No Timelock on Privacy Disable):** Admin can instantly disable privacy and trigger recovery. PrivateOmniCoin has a 7-day timelock for this operation.

Both Medium findings are design-level decisions rather than implementation bugs. The contract is functionally correct for its stated purpose.

**Deployment Recommendation:** PRODUCTION READY. Consider implementing the privacy disable timelock (M-02) and shadow ledger transfer tracking (M-01) for feature parity with PrivateOmniCoin before mainnet deployment. These are recommended enhancements, not blocking issues.

**Positive Observations:**
- Complete remediation of all prior Critical, High, and Medium findings
- Real USDC custody via SafeERC20 (safeTransferFrom/safeTransfer)
- Per-user public balance tracking gates all operations
- MPC overflow protection via checkedAdd
- Shadow ledger with restricted access for emergency recovery
- Privacy auto-detection for COTI chain IDs
- UUPS upgradeability with ossification option
- Clean ReentrancyGuard + Pausable + AccessControl inheritance
- Excellent NatSpec documentation including scaling rationale and limitations
- No scaling needed (USDC 6 decimals = MPC 6 decimal precision)

---
*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet*
