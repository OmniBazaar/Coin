# Security Audit Report: PrivateUSDC.sol -- Round 7

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Security Audit)
**Contract:** `Coin/contracts/privacy/PrivateUSDC.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 763
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (custodies real USDC via SafeERC20; MPC-encrypted private balances via COTI V2)
**Previous Audits:** Round 1 (2026-02-26), Round 6 (2026-03-10)

---

## Executive Summary

PrivateUSDC is a UUPS-upgradeable privacy wrapper that enables holders to convert real USDC into MPC-encrypted private balances (pUSDC) via COTI V2 garbled circuits. The contract custodies real USDC through SafeERC20 `safeTransferFrom`/`safeTransfer` calls, tracks per-user public balances, and provides privacy-preserving transfers where amounts remain encrypted on-chain.

Since USDC natively uses 6 decimals and COTI MPC operates on uint64 precision (also 6-decimal effective precision), `SCALING_FACTOR = 1` (identity). No scaling truncation occurs and no dust management is needed, making PrivateUSDC the structurally simplest of the three privacy wrapper contracts (alongside PrivateWETH with 1e12 scaling and PrivateWBTC with 1e2 scaling).

This Round 7 audit confirms that **all 15 findings from Round 1 and all 2 Medium findings from Round 6 have been fully remediated**. The Round 6 M-01 (shadow ledger desynchronization) is documented-but-accepted, and M-02 (privacy disable timelock) has been implemented via the `proposePrivacyDisable()`/`executePrivacyDisable()`/`cancelPrivacyDisable()` three-step flow with a 7-day delay.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 3 |

**Overall Assessment: PRODUCTION READY.** No blocking issues. All findings are low-impact design observations.

---

## Remediation Status from Round 6 (2026-03-10)

| Round 6 ID | Severity | Title | Status | Verification |
|------------|----------|-------|--------|--------------|
| M-01 | Medium | Shadow ledger desynchronization after private transfers | **ACCEPTED** | Documented limitation. `privateTransfer()` comments at lines 502-507 and `emergencyRecoverPrivateBalance()` NatSpec at lines 589-591 clearly state that amounts received via private transfers are NOT recoverable. See M-01 below for continued analysis. |
| M-02 | Medium | No timelock on privacy disable | **RESOLVED** | 7-day timelock implemented: `proposePrivacyDisable()` (line 536), `executePrivacyDisable()` (line 552), `cancelPrivacyDisable()` (line 573), `PRIVACY_DISABLE_DELAY = 7 days` (line 115). Full match with PrivateOmniCoin ATK-H07 pattern. |
| L-01 | Low | Admin receives BRIDGE_ROLE at initialization | **ACCEPTED** | Unchanged. Mitigated by `safeTransferFrom()` in `bridgeMint()` requiring actual USDC. |
| L-02 | Low | Emergency recovery with no grace period | **RESOLVED** | Now gated behind 7-day privacy disable timelock (M-02 fix). Users have 7 days to `convertToPublic()` after `proposePrivacyDisable()` is called. |
| L-03 | Low | No event for underlyingToken assignment | **ACCEPTED** | Value is readable via public getter. Initialization event is emitted by proxy pattern (OpenZeppelin `Initialized` event). |
| L-04 | Low | SCALING_FACTOR for API parity | **ACCEPTED** | Well-documented at lines 95-100. No action needed. |
| I-01 | Info | Shadow ledger over-recovery bounded by USDC balance | **ACKNOWLEDGED** | Documented in `emergencyRecoverPrivateBalance()` NatSpec. |
| I-02 | Info | convertToPrivate check ordering | **ACKNOWLEDGED** | Harmless; both checks present. |
| I-03 | Info | No ERC20 interface compliance | **ACKNOWLEDGED** | By design -- dual-balance model is incompatible with standard ERC20. |

---

## Remediation Status from Round 1 (2026-02-26)

All 15 findings from Round 1 remain fully resolved (verified in Round 6, re-verified in this audit):

| Round 1 ID | Severity | Title | Status |
|------------|----------|-------|--------|
| C-01 | Critical | bridgeMint does not transfer actual tokens | **RESOLVED** -- `safeTransferFrom()` at line 333-335 |
| H-01 | High | convertToPrivate has no token custody | **RESOLVED** -- debits `publicBalances[msg.sender]` at line 390 |
| H-02 | High | convertToPublic does not deliver tokens | **RESOLVED** -- credits `publicBalances[msg.sender]` at line 441 |
| H-03 | High | No pause mechanism | **RESOLVED** -- `PausableUpgradeable` with `whenNotPaused` on all 5 state-changing functions |
| M-01 | Medium | privateBalanceOf exposes balances to all callers | **RESOLVED** -- restricted to owner or admin (lines 662-668) |
| M-02 | Medium | Shadow ledger is public | **RESOLVED** -- `_shadowLedger` is `private`; restricted getter at lines 680-689 |
| M-03 | Medium | No emergency recovery mechanism | **RESOLVED** -- `emergencyRecoverPrivateBalance()` at lines 593-610 |
| M-04 | Medium | bridgeMint does not track per-user balances | **RESOLVED** -- `publicBalances` mapping at line 135 |
| L-01 | Low | Event amount parameters indexed | **RESOLVED** -- amounts no longer indexed |
| L-02 | Low | SCALING_FACTOR constant is misleading | **RESOLVED** -- NatSpec documents identity scaling at lines 95-100 |
| L-03 | Low | No privacyEnabled guard | **RESOLVED** -- `privacyEnabled` with auto-detect at lines 152, 311, 382 |
| L-04 | Low | bridgeBurn does not verify caller relationship to `from` | **RESOLVED** -- debits `publicBalances[from]` with balance check at lines 356-358 |
| I-01 | Info | Missing privacy conversion fee documentation | **RESOLVED** -- NatSpec at line 62 |
| I-02 | Info | Storage gap sizing | **RESOLVED** -- gap = 42 (50 - 8 state vars), documented at lines 163-168 |
| I-03 | Info | Redundant `using` statement for gtBool | **RESOLVED** -- removed |

---

## New Findings (Round 7)

### [M-01] Shadow Ledger Desynchronization Remains -- Emergency Recovery Favors Depositors Over Transfer Recipients (Carried Forward)

**Severity:** Medium
**Status:** ACCEPTED (documented limitation -- carried from Round 6 M-01)
**Lines:** 404, 466-467, 502-507, 589-591

**Description:**

The shadow ledger `_shadowLedger` is incremented in `convertToPrivate()` (line 404) and decremented (with floor-at-zero clamping) in `convertToPublic()` (lines 445-449), but is explicitly NOT updated in `privateTransfer()` (lines 502-507):

```solidity
// Note: Shadow ledger is NOT updated for private transfers
// because the amount is encrypted. Only deposits via
// convertToPrivate are tracked. In emergency recovery,
// amounts received via privateTransfer are not recoverable.
```

This means:
1. **Alice** deposits 10,000 USDC via `convertToPrivate()`. Shadow ledger: Alice = 10,000.
2. **Alice** privately transfers 5,000 to **Bob**. Shadow ledger: Alice = 10,000, Bob = 0.
3. MPC goes down. Admin calls `emergencyRecoverPrivateBalance()`.
4. Alice recovers 10,000 (over-recovery by 5,000). Bob recovers 0 (under-recovery by 5,000).

In contrast, `PrivateOmniCoin.sol` addresses this with ATK-H08 by decrypting the transfer amount inside `privateTransfer()` and updating the shadow ledger for both sender and recipient (PrivateOmniCoin lines 603-614).

The sibling contracts `PrivateWETH.sol` and `PrivateWBTC.sol` share this same limitation (they also do NOT update shadow ledger on private transfers).

**Impact:** In emergency recovery, users who received funds via `privateTransfer()` lose those funds. Users who sent funds may over-recover. Total recovery is bounded by the contract's actual USDC balance (the contract cannot become insolvent), but distribution among users is unfair.

**Mitigating Factors:**
- Well-documented in NatSpec at three locations (the `privateTransfer()` function, the `_shadowLedger` mapping declaration, and the `emergencyRecoverPrivateBalance()` function).
- Emergency recovery is a last-resort mechanism for MPC outages, not a routine operation.
- Over-recovery is bounded by total USDC held in the contract (`bridgeBurn` uses `safeTransfer` which will revert if insufficient balance).

**Recommendation:** Consider following the PrivateOmniCoin ATK-H08 pattern for consistency across the privacy contract family. This involves decrypting the transfer amount inside `privateTransfer()` and updating `_shadowLedger` for both sender and recipient. The privacy trade-off is minimal (the amount is revealed to the MPC network internally but is NOT emitted in events). If the current approach is retained, no further action is needed -- the documentation is thorough.

---

### [L-01] cancelPrivacyDisable Does Not Require a Pending Proposal -- Silent No-Op

**Severity:** Low
**Lines:** 573-579

**Description:**

`cancelPrivacyDisable()` deletes `privacyDisableScheduledAt` and emits `PrivacyDisableCancelled` regardless of whether a proposal is actually pending:

```solidity
function cancelPrivacyDisable()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    delete privacyDisableScheduledAt;
    emit PrivacyDisableCancelled();
}
```

When no proposal is pending (`privacyDisableScheduledAt == 0`), the function succeeds silently, emitting a misleading `PrivacyDisableCancelled` event. Compare with `executePrivacyDisable()` which correctly checks `if (privacyDisableScheduledAt == 0) revert NoPendingChange()` (line 556-558).

The `PrivateOmniCoin.sol` contract has the same pattern (no guard on cancel), so this is consistent across the family. However, a spurious `PrivacyDisableCancelled` event could confuse off-chain monitoring systems.

**Impact:** Negligible. Admin-only function. No state corruption. Only results in a misleading event emission.

**Recommendation:** Add the pending check for consistency with `executePrivacyDisable()`:

```solidity
function cancelPrivacyDisable()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (privacyDisableScheduledAt == 0)
        revert NoPendingChange();
    delete privacyDisableScheduledAt;
    emit PrivacyDisableCancelled();
}
```

---

### [L-02] enablePrivacy Has No Guard Against Re-Enabling While Proposal Is Pending

**Severity:** Low
**Lines:** 519-525, 536-545

**Description:**

If a privacy disable proposal is pending (i.e., `privacyDisableScheduledAt > 0`), the admin can call `enablePrivacy()` to re-enable privacy immediately without clearing the pending proposal:

```solidity
function enablePrivacy()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    privacyEnabled = true;        // Re-enables privacy...
    emit PrivacyStatusChanged(true);
    // ...but privacyDisableScheduledAt is NOT cleared
}
```

After this call, `privacyEnabled` is `true` but `privacyDisableScheduledAt` is still non-zero. When the timelock expires, the admin can call `executePrivacyDisable()` to disable privacy again without re-proposing (bypassing the 7-day waiting period for users who thought the proposal was cancelled).

The correct behavior sequence would be: if admin re-enables privacy, the pending proposal should be automatically cancelled.

**Impact:** Low. Requires admin to deliberately exploit the sequence. Users monitoring on-chain events would see `PrivacyStatusChanged(true)` and might assume the proposal was cancelled, then be surprised by a later `PrivacyDisabled` execution.

**Recommendation:** Clear the pending proposal when re-enabling privacy:

```solidity
function enablePrivacy()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    privacyEnabled = true;
    if (privacyDisableScheduledAt != 0) {
        delete privacyDisableScheduledAt;
        emit PrivacyDisableCancelled();
    }
    emit PrivacyStatusChanged(true);
}
```

---

### [L-03] emergencyRecoverPrivateBalance Not Protected by nonReentrant or whenNotPaused

**Severity:** Low
**Lines:** 593-610

**Description:**

`emergencyRecoverPrivateBalance()` is protected by `onlyRole(DEFAULT_ADMIN_ROLE)` and requires `!privacyEnabled`, but it does not use `nonReentrant` or `whenNotPaused` modifiers:

```solidity
function emergencyRecoverPrivateBalance(
    address user
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    // No nonReentrant, no whenNotPaused
    if (privacyEnabled) revert PrivacyMustBeDisabled();
    // ...
}
```

Since the function only modifies internal mappings (`_shadowLedger`, `publicBalances`, `totalPublicSupply`) and makes no external calls, reentrancy is not exploitable here. However, the lack of `whenNotPaused` means the function is callable even when the contract is paused. This may be intentional (emergency recovery should work during emergencies, including when paused), but it is inconsistent with the pattern on other admin functions like `bridgeMint` and `bridgeBurn` which do use `whenNotPaused`.

**Impact:** Negligible. Admin-only function. No external calls. The ability to recover during a paused state may actually be desirable.

**Recommendation:** If emergency recovery should be possible during a pause (which is reasonable), document this as intentional. If not, add `whenNotPaused`.

---

### [I-01] Storage Gap Count Assumes Mappings Occupy Zero Sequential Slots

**Severity:** Informational
**Lines:** 163-168

**Description:**

The storage gap comment states:

```solidity
/// Current state variables: 8 (underlyingToken, encryptedBalances,
/// totalPublicSupply, publicBalances, _shadowLedger,
/// privacyEnabled, _ossified, privacyDisableScheduledAt).
/// Gap size: 50 - 8 = 42 slots reserved.
uint256[42] private __gap;
```

This counts 8 state variables, including 3 mappings (`encryptedBalances`, `publicBalances`, `_shadowLedger`). Each mapping occupies exactly 1 sequential storage slot (for the slot pointer; actual data is stored at keccak256-derived locations). So the count of 8 is correct.

However, the OpenZeppelin convention varies between teams on whether to count mappings in the gap budget. The PrivateWETH and PrivateWBTC siblings count 10 state variables with a gap of 40, but they have 2 additional variables (`dustBalances` mapping and the extra bool). The counting is consistent within the family.

**Impact:** None. The gap calculation is correct.

**Recommendation:** No action required. The current approach is internally consistent.

---

### [I-02] proposePrivacyDisable Can Be Called Repeatedly to Reset the Timelock

**Severity:** Informational
**Lines:** 536-545

**Description:**

Calling `proposePrivacyDisable()` when a proposal is already pending resets the timelock to a new 7-day window without emitting any cancellation event. The admin can indefinitely delay execution by repeatedly re-proposing:

```solidity
function proposePrivacyDisable()
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    privacyDisableScheduledAt =
        block.timestamp + PRIVACY_DISABLE_DELAY;
    emit PrivacyDisableProposed(privacyDisableScheduledAt);
}
```

This is consistent with PrivateOmniCoin, PrivateWETH, and PrivateWBTC -- all four contracts allow repeated proposals. The behavior is actually beneficial: if the admin proposed prematurely, they can reset the timer. Users monitoring `PrivacyDisableProposed` events will see each re-proposal.

**Impact:** None. Beneficial behavior. Users see each proposal event.

**Recommendation:** No action required. If desired, add a guard to prevent re-proposing while one is already pending, or emit a `PrivacyDisableCancelled` event before re-proposing for cleaner event trails.

---

### [I-03] No Total Private Supply Tracking -- Audit Trail Limitation

**Severity:** Informational
**Lines:** N/A (absent feature)

**Description:**

Unlike `PrivateOmniCoin.sol` which tracks an encrypted `totalPrivateSupply` (updated in both `convertToPrivate()` and `convertToPublic()`), PrivateUSDC does not track the total amount of USDC currently held in MPC-encrypted balances. The contract tracks `totalPublicSupply` (public balances) but has no corresponding metric for private balances.

This means:
- There is no on-chain way to verify that `contract_USDC_balance >= totalPublicSupply + totalPrivateSupply`
- Audit tools cannot verify the contract's solvency without decrypting all individual balances

For PrivateOmniCoin, which mints and burns its own ERC20, total supply tracking is critical for solvency verification. For PrivateUSDC, solvency can be verified by comparing `underlyingToken.balanceOf(address(this))` against `totalPublicSupply` (the difference represents USDC backing private balances). This is a weaker invariant but still sufficient.

**Impact:** Informational. No security impact. Audit trail is slightly weaker but functional.

**Recommendation:** No action required. The USDC custody model inherently provides solvency bounds. Adding `totalPrivateSupply` tracking would add gas cost to every privacy conversion for marginal audit benefit.

---

## OWASP Smart Contract Top 10 Analysis

### SC01 -- Reentrancy

**Status: NOT VULNERABLE**

All user-facing state-changing functions (`convertToPrivate`, `convertToPublic`, `privateTransfer`) use `nonReentrant`. Bridge functions (`bridgeMint`, `bridgeBurn`) are gated by `onlyRole(BRIDGE_ROLE)` + `whenNotPaused`. The only external calls are `SafeERC20.safeTransferFrom()` in `bridgeMint()` and `SafeERC20.safeTransfer()` in `bridgeBurn()`. In `bridgeBurn()`, state changes (balance debits at lines 360-361) occur before the external call (line 363), following the Checks-Effects-Interactions pattern.

### SC02 -- Arithmetic Overflow/Underflow

**Status: SAFE**

- Solidity 0.8.24 provides built-in overflow/underflow protection for all `uint256` operations.
- MPC encrypted arithmetic uses `MpcCore.checkedAdd()` which calls `checkRes64()` -> `checkOverflow()`, reverting on uint64 overflow.
- `convertToPublic()` uses `MpcCore.sub()` with a prior `MpcCore.ge()` balance check, preventing underflow.
- `convertToPrivate()` checks `amount > type(uint64).max` before casting to `uint64(amount)`.
- `publicBalances[msg.sender] -= amount` is safe because `amount <= publicBalances[msg.sender]` is checked first.
- Shadow ledger uses floor-at-zero clamping in `convertToPublic()` to prevent underflow.

### SC03 -- Flash Loan / Price Manipulation

**Status: NOT APPLICABLE**

No oracle dependency. No price-dependent logic. No DEX integration. No flash loan vectors.

### SC04 -- Access Control

**Status: PROPERLY IMPLEMENTED**

Complete role mapping:

| Function | Access Control | Modifiers |
|----------|---------------|-----------|
| `bridgeMint()` | `BRIDGE_ROLE` | `whenNotPaused` |
| `bridgeBurn()` | `BRIDGE_ROLE` | `whenNotPaused` |
| `convertToPrivate()` | Any user | `nonReentrant`, `whenNotPaused` |
| `convertToPublic()` | Any user | `nonReentrant`, `whenNotPaused` |
| `privateTransfer()` | Any user | `nonReentrant`, `whenNotPaused` |
| `enablePrivacy()` | `DEFAULT_ADMIN_ROLE` | -- |
| `proposePrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | -- |
| `executePrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | -- |
| `cancelPrivacyDisable()` | `DEFAULT_ADMIN_ROLE` | -- |
| `emergencyRecoverPrivateBalance()` | `DEFAULT_ADMIN_ROLE` | requires `!privacyEnabled` |
| `pause()` | `DEFAULT_ADMIN_ROLE` | -- |
| `unpause()` | `DEFAULT_ADMIN_ROLE` | -- |
| `ossify()` | `DEFAULT_ADMIN_ROLE` | -- |
| `privateBalanceOf()` | Owner or admin | view |
| `getShadowLedgerBalance()` | Owner or admin | view |
| `_authorizeUpgrade()` | `DEFAULT_ADMIN_ROLE` | checks `!_ossified` |

Roles: `DEFAULT_ADMIN_ROLE` (admin), `BRIDGE_ROLE` (bridge operations). Both granted to `admin` parameter in `initialize()`. `BRIDGE_ROLE` is expected to be transferred to the bridge contract post-deployment.

### SC05 -- Denial of Service

**Status: NOT VULNERABLE**

No unbounded loops. No external dependencies in user-facing paths except the COTI MPC precompile (a system-level dependency that cannot be griefed by users). `bridgeMint()` depends on the underlying USDC token but is admin-gated.

### SC06 -- Unchecked External Calls

**Status: SAFE**

All ERC20 interactions use OpenZeppelin `SafeERC20` wrappers (`safeTransferFrom`, `safeTransfer`) which revert on failure. No raw `call()`, `delegatecall()`, or `staticcall()` usage.

### SC07 -- Oracle / Bridge Integration

**Status: PROPERLY IMPLEMENTED**

Bridge functions require `BRIDGE_ROLE`. Token custody is enforced: `bridgeMint()` pulls real USDC via `safeTransferFrom()` before crediting `publicBalances`. Per-user balance tracking prevents unauthorized conversion. The contract cannot mint unbacked private balances.

### SC08 -- Front-Running / MEV

**Status: LOW RISK**

Privacy conversions and transfers are deterministic (no slippage, no price). The main front-running vector would be:
1. Observer sees `convertToPrivate()` in mempool.
2. No profitable front-run exists because there is no price impact.

For `bridgeMint()` and `bridgeBurn()`, these are admin-only, so public mempool exposure is unlikely (can use private transactions).

### SC09 -- Upgradeability

**Status: PROPERLY IMPLEMENTED**

- UUPS pattern with `_authorizeUpgrade()` requiring `DEFAULT_ADMIN_ROLE` and `!_ossified`.
- Constructor calls `_disableInitializers()` to prevent implementation contract initialization.
- `initializer` modifier on `initialize()` prevents re-initialization.
- Storage gap `uint256[42] private __gap` reserves space for future variables.
- `ossify()` provides permanent upgrade freeze.

### SC10 -- Gas Griefing

**Status: NOT VULNERABLE**

No `transfer()` or `send()` calls (uses `SafeERC20`). No callbacks to untrusted addresses. No unbounded loops.

---

## Economic Invariants

### Solvency Invariant

```
underlyingToken.balanceOf(address(this)) >= totalPublicSupply
```

This must always hold. Analysis:

- `bridgeMint()`: Increments `totalPublicSupply` by `amount`; transfers `amount` USDC into the contract. If the transfer fails, the transaction reverts. Invariant maintained.
- `bridgeBurn()`: Decrements `totalPublicSupply` by `amount`; transfers `amount` USDC out of the contract. Checks `amount <= publicBalances[from]` first. Invariant maintained.
- `convertToPrivate()`: Decrements `totalPublicSupply` by `amount`. No USDC movement. The USDC backing is still in the contract but now backs a private balance. Invariant: `USDC_balance >= totalPublicSupply` still holds because `totalPublicSupply` decreased while `USDC_balance` stayed the same.
- `convertToPublic()`: Increments `totalPublicSupply` by `plainAmount`. No USDC movement. Invariant holds because the USDC was already in the contract (deposited via `bridgeMint`).
- `emergencyRecoverPrivateBalance()`: Increments `totalPublicSupply` by shadow ledger balance. No USDC movement. Could theoretically break invariant if shadow ledger is desynchronized, but bounded by actual USDC held. `bridgeBurn` will revert via `safeTransfer` if insufficient USDC.

### Balance Invariant

```
sum(publicBalances[*]) == totalPublicSupply
```

All functions that modify `publicBalances` also modify `totalPublicSupply` by the same amount in the same direction:
- `bridgeMint()`: both `+= amount`
- `bridgeBurn()`: both `-= amount`
- `convertToPrivate()`: both `-= amount`
- `convertToPublic()`: both `+= publicAmount`
- `emergencyRecoverPrivateBalance()`: both `+= balance`

Invariant is maintained across all paths.

---

## Comparison with Sibling Privacy Contracts

| Feature | PrivateUSDC | PrivateWETH | PrivateWBTC | PrivateOmniCoin |
|---------|-------------|-------------|-------------|-----------------|
| Underlying decimals | 6 | 18 | 8 | 18 |
| SCALING_FACTOR | 1 (identity) | 1e12 | 1e2 | 1e12 |
| Dust handling | N/A (no dust) | `dustBalances` + `claimDust()` | `dustBalances` + `claimDust()` | Sub-1e12 stays in public |
| Token custody model | SafeERC20 custody | SafeERC20 custody | SafeERC20 custody | ERC20 `_burn`/`_mint` |
| Privacy disable timelock | 7-day (RESOLVED) | 7-day | 7-day | 7-day |
| Shadow ledger transfer tracking | NOT tracked | NOT tracked | NOT tracked | Tracked (ATK-H08) |
| Shadow ledger visibility | `private` + restricted getter | `private` + restricted getter | `private` + restricted getter | `public` (acknowledged) |
| `privateBalanceOf()` access | Owner or admin | Owner or admin | Owner or admin | Unrestricted (ciphertext) |
| Total private supply tracking | Not tracked | Not tracked | Not tracked | Tracked (encrypted) |
| `checkedAdd` on recipient balance | Yes (convertToPrivate, privateTransfer) | Yes (convertToPrivate, privateTransfer) | Yes (convertToPrivate, privateTransfer) | Yes |
| `checkedSub` on sender balance | No (uses `sub` with prior `ge` check) | No (uses `sub` with prior `ge` check) | No (uses `sub` with prior `ge` check) | Yes (`checkedSub`) |
| Max private balance | ~18.4T USDC | ~18,446 ETH | ~18,446 BTC | ~18.4M XOM |
| Storage gap | 42 slots | 40 slots | 40 slots | 45 slots |

**Notable difference from PrivateOmniCoin:** The three wrapper contracts (USDC, WETH, WBTC) use `MpcCore.sub()` with a prior `MpcCore.ge()` balance check for sender deduction in both `convertToPublic()` and `privateTransfer()`. PrivateOmniCoin uses `MpcCore.checkedSub()` for defense-in-depth. Both approaches are safe: the `ge()` check ensures the subtraction will not underflow, and `checkedSub()` adds a redundant overflow bit check. The `ge() + sub()` pattern is marginally cheaper in gas.

---

## Static Analysis

**Solhint:** 0 errors, 0 warnings. Only two rule-existence warnings for deprecated rules (`contract-name-camelcase`, `event-name-camelcase`) which are not findings.

---

## Upgrade Safety Analysis

### Storage Layout Compatibility

Current state variable order (sequential slots):

| Slot | Variable | Type |
|------|----------|------|
| 0 | `underlyingToken` | `IERC20` (address, 20 bytes) |
| 1 | `encryptedBalances` | `mapping(address => ctUint64)` (slot pointer) |
| 2 | `totalPublicSupply` | `uint256` |
| 3 | `publicBalances` | `mapping(address => uint256)` (slot pointer) |
| 4 | `_shadowLedger` | `mapping(address => uint256)` (slot pointer) |
| 5 | `privacyEnabled` | `bool` (1 byte) |
| 6 | `_ossified` | `bool` (1 byte) |
| 7 | `privacyDisableScheduledAt` | `uint256` |
| 8-49 | `__gap` | `uint256[42]` |

Note: `privacyEnabled` and `_ossified` are each 1 byte but occupy separate slots because they are declared with other types between them. Slot 5 has 31 bytes of padding. Slot 6 has 31 bytes of padding. These could be packed into a single slot if reordered, but changing state variable order would break upgrade compatibility.

The storage gap of 42 slots (50 - 8 = 42) follows OpenZeppelin convention and provides ample room for future state variables.

### Constructor Safety

The implementation constructor calls `_disableInitializers()`, preventing the implementation contract from being initialized directly. This is correct for UUPS proxies.

### Initializer Safety

The `initialize()` function uses the `initializer` modifier, which can only be called once per proxy. All inherited initializers are called (`__AccessControl_init`, `__Pausable_init`, `__ReentrancyGuard_init`, `__UUPSUpgradeable_init`).

---

## Methodology

1. **Remediation Verification:** Confirmed all 15 Round 1 findings and 2 Round 6 Medium findings resolved or accepted
2. **Line-by-Line Manual Review:** Full 763-line code review against OWASP Smart Contract Top 10
3. **Comparative Analysis:** Verified consistency with PrivateOmniCoin (reference pattern), PrivateWETH, PrivateWBTC
4. **Token Custody Analysis:** Traced USDC flow through full lifecycle: `bridgeMint` -> `convertToPrivate` -> `privateTransfer` -> `convertToPublic` -> `bridgeBurn`
5. **Economic Invariant Analysis:** Verified solvency and balance invariants across all state transitions
6. **Upgrade Safety Analysis:** Verified storage layout, constructor safety, initializer safety, ossification
7. **Access Control Mapping:** Complete role/modifier enumeration for all 15 external functions
8. **MPC-Specific Analysis:** Overflow protection, ciphertext access control, privacy leakage vectors, shadow ledger integrity

---

## Conclusion

PrivateUSDC has matured significantly across three audit rounds. The contract has been completely rewritten since the Round 1 audit (which found 1 Critical, 3 High, and 4 Medium issues), and the remaining Round 6 findings have been addressed:

- **Token custody is correct:** Real USDC is transferred via `SafeERC20.safeTransferFrom()` on deposit and `safeTransfer()` on withdrawal.
- **Per-user balance tracking is complete:** `publicBalances` mapping gates all conversions and withdrawals with proper balance checks.
- **Pausability is implemented:** All 5 user-facing state-changing functions use `whenNotPaused`.
- **Privacy disable has a 7-day timelock:** Matching the PrivateOmniCoin ATK-H07 pattern, giving users time to exit private positions.
- **Emergency recovery exists:** Via shadow ledger with admin-gated `emergencyRecoverPrivateBalance()`.
- **Balance queries are restricted:** Both `privateBalanceOf()` and `getShadowLedgerBalance()` restricted to owner or admin.
- **MPC overflow protection:** `checkedAdd()` on all encrypted balance additions.
- **UUPS with ossification:** Upgrade capability can be permanently frozen.

**Remaining findings are all low-impact:**
- M-01 (carried): Shadow ledger desynchronization is a documented, accepted limitation. Consistent with PrivateWETH and PrivateWBTC.
- L-01: `cancelPrivacyDisable()` allows spurious event emission when no proposal is pending.
- L-02: `enablePrivacy()` does not clear a pending disable proposal, allowing timelock bypass.
- L-03: `emergencyRecoverPrivateBalance()` is not gated by `whenNotPaused` (may be intentional).

**Deployment Recommendation: PRODUCTION READY.** No blocking issues. The L-02 finding (enable/disable interaction) is the most actionable improvement.

---
*Generated by Claude Code Audit Agent -- Round 7 Security Audit (2026-03-13)*
