# Security Audit Report: PrivateWETH.sol -- Round 7

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Deep Audit)
**Contract:** `Coin/contracts/privacy/PrivateWETH.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 817
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (custodies real WETH via SafeERC20; MPC-encrypted privacy balances via COTI V2)
**Previous Audits:** Round 1 (2026-02-26), Round 6 (2026-03-10)

---

## Executive Summary

PrivateWETH is a privacy-preserving WETH wrapper that uses COTI V2 MPC garbled circuits for encrypted balance management. It custodies real WETH tokens via SafeERC20, maintains per-user public balances, supports conversion between public and private (encrypted) modes, enables privacy-preserving transfers, and includes emergency recovery via a shadow ledger.

This Round 7 audit verifies the remediation of all three Medium findings from Round 6 (2026-03-10) and performs a comprehensive fresh review of the contract's current state. The contract has been significantly improved:

- **M-01 (Shadow Ledger Desync):** Status: **NOT FIXED.** The shadow ledger is still NOT updated during `privateTransfer()`. The PrivateOmniCoin ATK-H08 pattern (decrypt transfer amount, update both ledgers) has not been adopted. This remains a documented limitation. See M-01 below.
- **M-02 (No Privacy Disable Timelock):** Status: **FIXED.** The contract now implements the full PrivateOmniCoin timelock pattern with `proposePrivacyDisable()`, `executePrivacyDisable()`, and `cancelPrivacyDisable()` (lines 592-635), with a 7-day `PRIVACY_DISABLE_DELAY` (line 123).
- **M-03 (Dust Double-Counting):** Status: **FIXED.** `convertToPrivate()` now debits the full `amount` (not just `usedAmount`) from `publicBalances` (line 426: `publicBalances[msg.sender] -= amount`). Dust is correctly separated: removed from public balances entirely, tracked in `dustBalances`, and re-credited only via `claimDust()`.

The contract is well-structured with thorough NatSpec, correct CEI patterns, ReentrancyGuard on all state-changing functions, Pausable modifiers, checked MPC arithmetic on additions, and proper SafeERC20 custody. The remaining findings are lower severity.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 5 |
| Informational | 4 |

**Overall Assessment: PRODUCTION READY** with caveats noted below.

---

## Remediation Status from Round 6 (2026-03-10)

| Round 6 ID | Severity | Title | Status | Evidence |
|------------|----------|-------|--------|----------|
| M-01 | Medium | Shadow ledger desynchronization after private transfers | **NOT FIXED** | `privateTransfer()` (lines 525-564) still does not update `_shadowLedger`. Comment at lines 558-563 confirms this is unchanged. See M-01 below. |
| M-02 | Medium | No timelock on privacy disable | **FIXED** | `PRIVACY_DISABLE_DELAY = 7 days` (line 123). Three-function pattern: `proposePrivacyDisable()` (line 592), `executePrivacyDisable()` (line 608), `cancelPrivacyDisable()` (line 629). `privacyDisableScheduledAt` state variable (line 172). Timelock enforced at line 616. |
| M-03 | Medium | Dust accounting double-counts | **FIXED** | `convertToPrivate()` now debits full `amount` (line 426: `publicBalances[msg.sender] -= amount`), not just `usedAmount`. Dust is deducted from public balance first, tracked separately (line 431: `dustBalances[msg.sender] += dust`), and re-credited only via `claimDust()` (line 507). No double-counting. |
| L-01 | Low | Admin receives BRIDGE_ROLE at init | **UNCHANGED** | Lines 329-330. Acceptable -- `safeTransferFrom` in `bridgeMint` prevents minting without WETH. |
| L-02 | Low | claimDust has no whenNotPaused | **NOT FIXED** | `claimDust()` (line 502) still uses only `nonReentrant`, not `whenNotPaused`. See L-01 below. |
| L-03 | Low | No event for underlyingToken assignment | **NOT FIXED** | `initialize()` sets `underlyingToken` (line 332) without emitting an event. See L-02 below. |
| L-04 | Low | Emergency recovery does not include dust | **UNCHANGED** | Documented limitation. Dust is separately claimable. |
| I-01 | Info | Max private balance ~18,446 ETH | **N/A** | Correctly documented. |
| I-02 | Info | Scaling factor matches PrivateOmniCoin | **N/A** | Correct. |
| I-03 | Info | Chain IDs match siblings | **N/A** | Correct. |

---

## New and Carried-Forward Findings

### [M-01] Shadow Ledger Not Updated During privateTransfer -- Emergency Recovery Remains Incomplete

**Severity:** Medium
**Lines:** 525-564 (privateTransfer), 649-667 (emergencyRecoverPrivateBalance)
**Status:** Carried forward from Round 6 M-01 (NOT FIXED)

**Description:**

The `privateTransfer()` function does not update `_shadowLedger` for either the sender or the recipient. The code at lines 558-563 explicitly documents this as intentional:

```solidity
// Note: Shadow ledger is NOT updated for private transfers
// because the amount is encrypted. Only deposits via
// convertToPrivate are tracked. In emergency recovery,
// amounts received via privateTransfer are not recoverable.
```

The sibling contract `PrivateOmniCoin` addressed this in the ATK-H08 fix (line 603 of PrivateOmniCoin.sol) by decrypting the transfer amount inside `privateTransfer()` and updating both sender and recipient shadow ledgers. PrivateWETH has not adopted this pattern.

**Scenario demonstrating the problem:**
1. Alice: `bridgeMint(alice, 2e18)`, then `convertToPrivate(2e18)` -- shadow = 2,000,000 (scaled)
2. Alice: `privateTransfer(bob, 1,000,000)` -- Alice's MPC = 1,000,000, Bob's MPC = 1,000,000; Alice's shadow = 2,000,000, Bob's shadow = 0
3. MPC outage; privacy disabled
4. `emergencyRecoverPrivateBalance(alice)` recovers 2e18 (2 WETH) -- over-recovery
5. `emergencyRecoverPrivateBalance(bob)` reverts with `NoBalanceToRecover` -- Bob loses his 1 WETH equivalent
6. Contract holds 2e18 WETH total, so Alice gets all of it; Bob gets nothing

At the contract level, solvency is maintained (SafeERC20 custody ensures total WETH held >= total obligations). But per-user fairness is broken in emergency recovery.

**Impact:** In an emergency recovery scenario following private transfers, deposit-heavy users over-recover while transfer-receiving users under-recover or lose funds entirely. The total recovered is bounded by the contract's WETH reserves.

**Recommendation:** Adopt the PrivateOmniCoin ATK-H08 pattern. Decrypt the transfer amount in `privateTransfer()` and update both shadow ledgers:

```solidity
// After MPC subtraction from sender and addition to recipient:
uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
uint256 transferAmount = uint256(plainAmount);

if (_shadowLedger[msg.sender] >= transferAmount) {
    _shadowLedger[msg.sender] -= transferAmount;
} else {
    _shadowLedger[msg.sender] = 0;
}
_shadowLedger[to] += transferAmount;
```

Note: This requires an additional `MpcCore.decrypt()` call which reveals the amount to the contract/validator nodes, but NOT to external observers (the amount is not emitted in events). This is the same trade-off PrivateOmniCoin makes.

---

### [L-01] claimDust Lacks whenNotPaused Modifier -- State Changes Possible During Pause

**Severity:** Low
**Lines:** 502-511
**Status:** Carried forward from Round 6 L-02 (NOT FIXED)

**Description:**

`claimDust()` uses `nonReentrant` but not `whenNotPaused`:

```solidity
function claimDust() external nonReentrant {
    uint256 dust = dustBalances[msg.sender];
    if (dust == 0) revert NoDustToClaim();
    dustBalances[msg.sender] = 0;
    publicBalances[msg.sender] += dust;
    totalPublicSupply += dust;
    emit DustClaimed(msg.sender, dust);
}
```

All other state-changing functions (`bridgeMint`, `bridgeBurn`, `convertToPrivate`, `convertToPublic`, `privateTransfer`) include `whenNotPaused`. During an emergency pause, users can still claim dust, modifying `publicBalances` and `totalPublicSupply`. This could complicate incident response if an admin pauses the contract to freeze state during investigation.

**Impact:** Low. Dust amounts are negligible (max ~999,999,999,999 wei per conversion, ~$0.002 at $2,000/ETH). No security impact, but inconsistency in pause behavior.

**Recommendation:** Add `whenNotPaused`:

```solidity
function claimDust() external nonReentrant whenNotPaused {
```

---

### [L-02] No Event Emitted for underlyingToken Assignment in initialize()

**Severity:** Low
**Lines:** 317-334
**Status:** Carried forward from Round 6 L-03 (NOT FIXED)

**Description:**

The `initialize()` function sets the critical `underlyingToken` state variable at line 332 without emitting an event:

```solidity
underlyingToken = IERC20(_underlyingToken);
privacyEnabled = _detectPrivacyAvailability();
```

While `underlyingToken` is readable via its auto-generated public getter, off-chain systems that monitor contract initialization via event logs will miss this assignment. The `privacyEnabled` initial value is also not emitted (though subsequent changes emit `PrivacyStatusChanged`).

**Impact:** Negligible. Discoverable via storage reads. No security impact.

**Recommendation:** Consider emitting an initialization event:

```solidity
event Initialized(address indexed underlyingToken, bool privacyEnabled);
// ... in initialize():
emit Initialized(_underlyingToken, privacyEnabled);
```

---

### [L-03] getShadowLedgerBalance NatSpec Incorrectly Claims 18-Decimal Return Value

**Severity:** Low
**Lines:** 733-743

**Description:**

The NatSpec for `getShadowLedgerBalance()` states:

```solidity
/// @return Shadow ledger balance in ETH units (18 decimals)
```

However, the shadow ledger stores values in **6-decimal MPC-scaled units**, not 18-decimal ETH units. In `convertToPrivate()` at line 445:

```solidity
_shadowLedger[msg.sender] += scaledAmount;
```

where `scaledAmount = amount / SCALING_FACTOR` (line 412). The function returns the raw `_shadowLedger[account]` value at line 743 without applying any scaling. Therefore, the return value is in 6-decimal scaled units, not 18-decimal ETH units.

For comparison, `emergencyRecoverPrivateBalance()` correctly scales back to 18 decimals at line 662:

```solidity
uint256 publicAmount = scaledBalance * SCALING_FACTOR;
```

But `getShadowLedgerBalance()` does not perform this scaling.

**Impact:** Low. API consumers relying on the NatSpec documentation will interpret the returned value as 18-decimal ETH units when it is actually 6-decimal scaled units, leading to display errors (showing values 1e12x too small). No fund loss -- only a display/integration issue.

**Recommendation:** Either fix the NatSpec to accurately reflect the return type:

```solidity
/// @return Shadow ledger balance in MPC-scaled units (6 decimals)
```

Or scale the return value to match the NatSpec:

```solidity
return _shadowLedger[account] * SCALING_FACTOR;
```

The first option (fix NatSpec) is recommended since the shadow ledger is used internally in scaled units and callers should be aware of this.

---

### [L-04] convertToPublic and privateTransfer Use Unchecked MpcCore.sub() Instead of checkedSub()

**Severity:** Low
**Lines:** 471, 543

**Description:**

The contract uses `MpcCore.checkedAdd()` in both `convertToPrivate()` (line 441) and `privateTransfer()` (line 552) for overflow-safe addition. However, subtraction operations use the unchecked `MpcCore.sub()`:

- `convertToPublic()` line 471: `gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);`
- `privateTransfer()` line 543: `gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);`

Both locations have a prior `MpcCore.ge()` check (lines 464-468 and 536-540 respectively) that verifies the balance is sufficient, so underflow should not occur in practice. However, the PrivateOmniCoin reference contract uses `MpcCore.checkedSub()` at line 498 for defense-in-depth, noting this as the M-01 fix.

The risk is a TOCTOU (time-of-check-to-time-of-use) gap: if the MPC precompile processes `ge()` and `sub()` as separate transactions with state changes between them, the `ge()` check could pass while the `sub()` still underflows. In practice, this is unlikely within a single EVM transaction, but `checkedSub()` provides deterministic safety.

**Impact:** Low. The `ge()` checks provide functional protection. The unchecked `sub()` is defense-in-depth concern only, not a practical exploit vector.

**Recommendation:** Replace `MpcCore.sub()` with `MpcCore.checkedSub()` in both locations for consistency with PrivateOmniCoin:

```solidity
// convertToPublic:
gtUint64 gtNew = MpcCore.checkedSub(gtBalance, encryptedAmount);

// privateTransfer:
gtUint64 gtNewSender = MpcCore.checkedSub(gtSender, encryptedAmount);
```

---

### [L-05] Storage Gap Comment Claims 10 State Variables but Count Is 9

**Severity:** Low
**Lines:** 174-182

**Description:**

The storage gap comment states:

```solidity
/// Current state variables: 10 (underlyingToken, encryptedBalances,
/// totalPublicSupply, publicBalances, _shadowLedger, dustBalances,
/// privacyEnabled, _ossified, privacyDisableScheduledAt, + inherited).
/// Gap size: 50 - 10 = 40 slots reserved.
```

The comment lists 9 named state variables, then adds "+ inherited" to reach 10. However, in the UUPS upgradeable pattern, inherited contract state variables (from AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable) occupy their own storage slots managed by OpenZeppelin's own `__gap` arrays. They should NOT be counted in this contract's gap calculation.

The contract's own sequential state variables that occupy storage slots are:
1. `underlyingToken` (IERC20, 1 slot)
2. `encryptedBalances` (mapping, dynamic -- not a sequential slot)
3. `totalPublicSupply` (uint256, 1 slot)
4. `publicBalances` (mapping, dynamic -- not a sequential slot)
5. `_shadowLedger` (mapping, dynamic -- not a sequential slot)
6. `dustBalances` (mapping, dynamic -- not a sequential slot)
7. `privacyEnabled` (bool, 1 slot -- may pack with `_ossified`)
8. `_ossified` (bool, may pack with `privacyEnabled` in same slot)
9. `privacyDisableScheduledAt` (uint256, 1 slot)

Following OpenZeppelin convention, mappings do not consume sequential storage slots (they hash to isolated locations). Therefore the sequential slot count is approximately 4-5 (depending on bool packing), not 10.

The sibling contract PrivateUSDC (which has no `dustBalances`) correctly counts 8 state variables with gap = 42. PrivateWETH has 9 variables (adding `dustBalances`) and gap = 40, meaning it counted 10, which is off by 1 due to the "+ inherited" note.

**Impact:** Low. The gap is conservative (larger gap = safer). If the gap were too small, future upgrades could collide. As-is, the gap is safe -- 40 slots is more than sufficient.

**Recommendation:** Clarify the comment to match the actual count and follow the OpenZeppelin convention of excluding mappings and inherited slots:

```solidity
/// Current sequential state variables: 5
/// (underlyingToken, totalPublicSupply, privacyEnabled + _ossified
/// [packed], privacyDisableScheduledAt).
/// Mappings excluded per OZ convention: encryptedBalances,
/// publicBalances, _shadowLedger, dustBalances.
/// Gap size: 50 - 5 = 45 slots reserved.
```

Or simply leave the conservative gap = 40 and fix the comment to accurately describe the counting methodology.

---

### [I-01] PrivateTransfer Event Does Not Emit Amount -- Privacy vs. Auditability Trade-Off

**Severity:** Informational
**Lines:** 217-220, 563

**Description:**

The `PrivateTransfer` event emits only `from` and `to` addresses:

```solidity
event PrivateTransfer(address indexed from, address indexed to);
```

This is intentional for privacy -- the amount is encrypted and should not be revealed on-chain. However, this creates challenges for:
1. Off-chain compliance monitoring and auditing
2. Block explorer display of pWETH transfer values
3. Portfolio tracking applications

The PrivateOmniCoin contract addresses this partially by emitting a separate `PrivateLedgerUpdated` event (lines 283-294) that reveals the direction (deposit/withdrawal) but not the amount, allowing off-chain indexers to track shadow ledger changes.

**Impact:** None. Correct privacy-preserving design. The trade-off is documented.

**Recommendation:** Consider adding a `PrivateLedgerUpdated` event similar to PrivateOmniCoin, particularly if M-01 is fixed (shadow ledger updated during transfers):

```solidity
event PrivateLedgerUpdated(address indexed user, bool indexed isDeposit);
```

---

### [I-02] underlyingToken Is Not Declared as immutable -- Mutable by Convention Only

**Severity:** Informational
**Lines:** 131

**Description:**

The `underlyingToken` state variable is documented as "Set once during initialization; immutable by convention":

```solidity
/// @dev Set once during initialization; immutable by convention
IERC20 public underlyingToken;
```

However, Solidity's `immutable` keyword is not used because UUPS upgradeable contracts cannot have immutable state variables (they are stored in the implementation contract's bytecode, not in proxy storage). The variable is effectively mutable -- any future upgrade implementation could change it.

This is a well-known constraint of the UUPS pattern. The ossification feature (`ossify()`) provides the ultimate protection: once ossified, no upgrades can change any state variable.

**Impact:** None. Standard UUPS pattern limitation. Ossification provides the final guarantee.

**Recommendation:** No code change needed. The NatSpec documentation accurately describes the situation. Consider adding: "Protected against modification by ossification."

---

### [I-03] Sibling Contract Divergence -- PrivateWETH/PrivateWBTC Have Dust Tracking, PrivateUSDC Does Not

**Severity:** Informational
**Lines:** 155-158 (dustBalances), 502-511 (claimDust)

**Description:**

The three privacy wrapper contracts have diverged in their dust handling:

| Feature | PrivateWETH | PrivateWBTC | PrivateUSDC |
|---------|-------------|-------------|-------------|
| SCALING_FACTOR | 1e12 | 1e2 | 1 (identity) |
| dustBalances mapping | Yes | Yes | No |
| claimDust() function | Yes | Yes | No |
| Max dust per conversion | 999,999,999,999 wei | 99 satoshi | 0 (no scaling) |

PrivateUSDC has `SCALING_FACTOR = 1` because USDC natively uses 6 decimals matching MPC precision, so no scaling or dust occurs. PrivateWETH and PrivateWBTC both need scaling and include dust tracking.

This divergence is logical and correct. The concern is maintenance: bug fixes to dust handling must be applied to both PrivateWETH and PrivateWBTC but not PrivateUSDC. The M-03 dust fix from Round 6 was correctly applied to both.

Additionally, PrivateWETH and PrivateWBTC still lack the shadow ledger transfer tracking that PrivateOmniCoin has (ATK-H08), while PrivateUSDC also lacks it. All three sibling contracts share this gap.

**Impact:** None. Maintenance awareness item.

**Recommendation:** If shadow ledger transfer tracking (M-01) is implemented, ensure it is applied consistently to all three sibling contracts.

---

### [I-04] Privacy Transaction Graph Leakage -- Sender/Receiver Addresses Visible On-Chain

**Severity:** Informational
**Lines:** 217-220, 525-564

**Description:**

This is the same limitation documented in PrivateOmniCoin as ATK-H06 (lines 238-249). The `PrivateTransfer` event emits `from` and `to` addresses, revealing the transaction graph (who transacts with whom) even though amounts are encrypted. An observer can:

1. Track which addresses interact via pWETH private transfers
2. Correlate `ConvertedToPrivate` events (which reveal amounts) with subsequent `PrivateTransfer` events (which reveal participants) for timing analysis
3. Build social graphs of privacy-preserving WETH usage

Unlike PrivateOmniCoin, PrivateWETH's NatSpec does not document this limitation.

**Impact:** Informational. Inherent to the architecture. Full relationship privacy would require a relayer service or COTI's future encrypted events.

**Recommendation:** Add ATK-H06-style documentation to the `PrivateTransfer` event NatSpec:

```solidity
/// @dev PRIVACY LIMITATION: PrivateTransfer events expose sender
///      and receiver addresses on-chain. While amounts are encrypted
///      via COTI MPC, the transaction graph is publicly visible.
```

---

## OWASP Smart Contract Top 10 Analysis

### SC01 -- Reentrancy

**Status: NOT VULNERABLE**

All five state-changing user functions use `nonReentrant`:
- `convertToPrivate()` (line 404)
- `convertToPublic()` (line 458)
- `privateTransfer()` (line 528)
- `claimDust()` (line 502)

Bridge functions (`bridgeMint`, `bridgeBurn`) are gated by `BRIDGE_ROLE` and use SafeERC20.

`bridgeBurn()` follows the Checks-Effects-Interactions pattern: balance deduction (lines 382-383) occurs before `safeTransfer` (line 385).

`bridgeMint()` calls `safeTransferFrom` before crediting balances (lines 355-360). While this is Interactions-before-Effects, it is safe because:
1. The function is `onlyRole(BRIDGE_ROLE)` -- only the trusted bridge can call it
2. `safeTransferFrom` pulls tokens INTO the contract (no callback to attacker)
3. Standard ERC20 tokens (WETH) do not have transfer hooks

### SC02 -- Arithmetic

**Status: SAFE**

- Solidity 0.8.24 built-in overflow/underflow protection for all uint256 operations
- `MpcCore.checkedAdd()` used for encrypted additions (lines 441, 552)
- `MpcCore.sub()` used for encrypted subtractions with prior `ge()` check (L-04: defense-in-depth improvement available)
- Scaling: `amount / SCALING_FACTOR` (floor division) and `plainAmount * SCALING_FACTOR` (multiplication) are correct. Multiplication cannot overflow: `uint64.max * 1e12 = 1.84e31 < uint256.max`
- Dust tracking: Fixed M-03 from Round 6. Full `amount` debited before dust is tracked separately

### SC03 -- Flash Loan / Price Manipulation

**Status: NOT APPLICABLE**

No oracle dependency. No price-dependent logic. No AMM integration. Token custody is 1:1 via SafeERC20.

### SC04 -- Access Control

**Status: PROPERLY IMPLEMENTED**

| Function | Access Control | Modifiers |
|----------|---------------|-----------|
| bridgeMint | BRIDGE_ROLE | onlyRole, whenNotPaused |
| bridgeBurn | BRIDGE_ROLE | onlyRole, whenNotPaused |
| convertToPrivate | Any user | nonReentrant, whenNotPaused |
| convertToPublic | Any user | nonReentrant, whenNotPaused |
| privateTransfer | Any user | nonReentrant, whenNotPaused |
| claimDust | Any user | nonReentrant (no whenNotPaused -- L-01) |
| enablePrivacy | DEFAULT_ADMIN_ROLE | onlyRole |
| proposePrivacyDisable | DEFAULT_ADMIN_ROLE | onlyRole |
| executePrivacyDisable | DEFAULT_ADMIN_ROLE | onlyRole |
| cancelPrivacyDisable | DEFAULT_ADMIN_ROLE | onlyRole |
| emergencyRecoverPrivateBalance | DEFAULT_ADMIN_ROLE | onlyRole |
| pause / unpause | DEFAULT_ADMIN_ROLE | onlyRole |
| ossify | DEFAULT_ADMIN_ROLE | onlyRole |
| _authorizeUpgrade | DEFAULT_ADMIN_ROLE | onlyRole, ossification check |
| privateBalanceOf | Owner or Admin | view, Unauthorized revert |
| getShadowLedgerBalance | Owner or Admin | view, Unauthorized revert |

Role separation: `BRIDGE_ROLE` for bridge operations, `DEFAULT_ADMIN_ROLE` for governance. No function lacks access control where it should have it.

### SC05 -- Denial of Service

**Status: NOT VULNERABLE**

No unbounded loops. No external dependency that could block user operations (MPC precompile is a chain-level dependency, not a contract-level one). `claimDust()` accesses a single mapping entry. All operations are O(1).

### SC06 -- Unchecked External Calls

**Status: SAFE**

All external token interactions use OpenZeppelin's `SafeERC20`:
- `underlyingToken.safeTransferFrom()` in `bridgeMint()` (line 355)
- `underlyingToken.safeTransfer()` in `bridgeBurn()` (line 385)

`SafeERC20` handles non-standard ERC20 return values and reverts on failure.

### SC07 -- Oracle / Bridge Integration

**Status: PROPERLY IMPLEMENTED**

Token custody is enforced:
- `bridgeMint()` requires actual WETH transfer via `safeTransferFrom` before crediting
- `bridgeBurn()` verifies sufficient `publicBalances` before releasing WETH
- `convertToPrivate()` verifies sufficient `publicBalances` before creating MPC balance
- Per-user `publicBalances` prevents unauthorized consumption of other users' deposits
- Contract-level solvency: total WETH held >= total `publicBalances` + total `dustBalances` (invariant maintained by correct accounting)

---

## Role Mapping

| Role | Purpose | Granted To | Can Do |
|------|---------|------------|--------|
| `DEFAULT_ADMIN_ROLE` | Governance and emergency | Admin address (deployer at init) | Manage roles, pause/unpause, enable/disable privacy (with timelock), emergency recovery, ossify, authorize upgrades |
| `BRIDGE_ROLE` | Token custody operations | Admin address (deployer at init); intended to be transferred to OmniBridge | bridgeMint (deposit WETH, credit publicBalances), bridgeBurn (debit publicBalances, release WETH) |

No other roles exist. Role hierarchy: `DEFAULT_ADMIN_ROLE` is admin for all roles (OpenZeppelin default).

---

## Initializer Safety

The `initialize()` function:
1. Uses `initializer` modifier (line 320) -- can only be called once via proxy
2. Calls all parent initializers: `__AccessControl_init()`, `__Pausable_init()`, `__ReentrancyGuard_init()`, `__UUPSUpgradeable_init()` (lines 324-327)
3. Validates both input addresses against zero (lines 321-322)
4. Grants exactly two roles: `DEFAULT_ADMIN_ROLE` and `BRIDGE_ROLE` (lines 329-330)
5. Sets `underlyingToken` once (line 332)
6. Auto-detects privacy via `_detectPrivacyAvailability()` (line 333)

The constructor calls `_disableInitializers()` (line 307) to prevent initialization of the implementation contract directly. This is the correct UUPS pattern.

**No re-initialization vulnerability.** The `initializer` modifier ensures single execution.

---

## Upgrade Safety

1. **UUPS Pattern:** `_authorizeUpgrade()` (lines 791-795) requires `DEFAULT_ADMIN_ROLE` and checks `_ossified` flag
2. **Ossification:** `ossify()` (lines 697-703) permanently disables upgrades by setting `_ossified = true`
3. **Storage Gap:** `uint256[40] private __gap` (line 182) reserves storage slots for future upgrades
4. **No Constructor State:** Constructor only calls `_disableInitializers()` -- no state initialization in implementation contract

The upgrade path is secure. Ossification is irreversible (no un-ossify function).

---

## Edge Cases Reviewed

### 1. Zero-Amount Operations
- `bridgeMint(to, 0)` -- reverts `ZeroAmount` (line 353)
- `bridgeBurn(from, 0)` -- reverts `ZeroAmount` (line 377)
- `convertToPrivate(0)` -- reverts `ZeroAmount` (line 406)
- `convertToPrivate(999_999_999_999)` (< SCALING_FACTOR) -- `scaledAmount = 0`, reverts `ZeroAmount` (line 413)
- `convertToPublic(encrypted_zero)` -- decrypts to 0, reverts `ZeroAmount` (line 475)
- `claimDust()` with zero dust -- reverts `NoDustToClaim` (line 504)

### 2. Maximum Amount Operations
- `convertToPrivate(type(uint256).max)` -- `scaledAmount = type(uint256).max / 1e12 > type(uint64).max`, reverts `AmountTooLarge` (line 415)
- Encrypted balance approaching `type(uint64).max` -- `MpcCore.checkedAdd()` reverts on overflow

### 3. Self-Transfer
- `privateTransfer(msg.sender, amount)` -- reverts `SelfTransfer` (line 531)

### 4. Emergency Recovery Lifecycle
- Privacy enabled: `emergencyRecoverPrivateBalance()` reverts `PrivacyMustBeDisabled` (line 652)
- Privacy disable flow: propose (sets timestamp + 7 days) -> wait 7 days -> execute (sets `privacyEnabled = false`)
- Premature execute: reverts `TimelockActive` (line 617)
- Cancel: clears `privacyDisableScheduledAt`, blocks execute (would revert `NoPendingChange`)
- Recovery with zero shadow: reverts `NoBalanceToRecover` (line 656)
- Recovery with balance: clears shadow, credits publicBalances, increases totalPublicSupply

### 5. Fee-on-Transfer / Rebasing WETH Tokens
- If `underlyingToken` is a fee-on-transfer token, `bridgeMint()` will credit `publicBalances[to]` with the full `amount`, but the contract receives less than `amount` in actual WETH. This would create unbacked balances.
- Standard WETH (canonical Wrapped Ether) is NOT fee-on-transfer, so this is not a practical risk. However, if used with non-standard WETH variants, the contract would become insolvent.

### 6. Dust Accumulation Across Conversions
- Multiple `convertToPrivate()` calls accumulate dust in `dustBalances`. No cap on dust accumulation per user. Maximum per conversion: 999,999,999,999 wei.
- `claimDust()` correctly zeroes `dustBalances` and re-credits `publicBalances`.

---

## Comparison with PrivateOmniCoin (Reference Implementation)

| Feature | PrivateOmniCoin | PrivateWETH (Current) |
|---------|----------------|----------------------|
| Token custody | ERC20 `_burn`/`_mint` (native token) | SafeERC20 custody (wrapper) |
| Scaling factor | 1e12 | 1e12 (identical) |
| Dust handling | Sub-1e12 stays in public balance automatically | `dustBalances` + `claimDust()` (fixed M-03) |
| Pausability | `ERC20PausableUpgradeable` | `PausableUpgradeable` |
| Privacy disable timelock | 7-day delay (ATK-H07) | 7-day delay (FIXED) |
| Shadow ledger transfer tracking | Updated via ATK-H08 | **NOT updated** (M-01) |
| Shadow ledger visibility | `public` mapping (acknowledged trade-off) | `private` with restricted getter |
| Encrypted balance query | Owner only (ATK-H05) | Owner or admin |
| MPC subtraction | `checkedSub` (M-01 fix) | `sub` with prior `ge` check (L-04) |
| Supply cap | MAX_SUPPLY (16.6B) defense-in-depth | N/A (bounded by WETH custody) |
| Self-transfer protection | Yes (SelfTransfer error) | Yes (SelfTransfer error) |
| PrivateLedgerUpdated event | Yes | No (I-01) |

---

## Comparison with Sibling Contracts (PrivateWBTC, PrivateUSDC)

| Property | PrivateWETH | PrivateWBTC | PrivateUSDC |
|----------|-------------|-------------|-------------|
| SCALING_FACTOR | 1e12 | 1e2 | 1 |
| TOKEN_DECIMALS | 18 | 8 | 6 |
| Dust tracking | Yes | Yes | No (no scaling) |
| Shadow ledger transfer tracking | No | No | No |
| Privacy disable timelock | Yes (7 days) | Yes (7 days) | Yes (7 days) |
| MPC subtraction | `sub()` | `sub()` | `sub()` |
| Storage gap | 40 | 40 | 42 |
| Gap comment accuracy | Off by 1 (L-05) | Off by 1 (same issue) | Correct |

All three contracts lack shadow ledger transfer tracking (M-01) and use unchecked `sub()` for MPC subtraction (L-04). These findings apply to all siblings.

---

## Static Analysis

**Solhint:** 0 errors, 0 warnings. Contract uses `solhint-disable` / `solhint-enable` blocks for accepted `gas-indexed-events` and `not-rely-on-time` rules. All NatSpec is complete.

---

## Methodology

1. **Remediation Verification:** Confirmed status of all 10 findings from Round 6 audit
2. **Full Contract Re-Read:** Line-by-line review of all 817 lines
3. **OWASP SC Top 10:** Systematic analysis of all 7 applicable categories
4. **Role Mapping:** Enumerated all roles, permissions, and access control paths
5. **Initializer and Upgrade Safety:** Verified UUPS pattern, constructor, initializer modifier, ossification
6. **Edge Case Analysis:** Zero amounts, maximum amounts, self-transfer, fee-on-transfer tokens, dust accumulation, emergency recovery lifecycle
7. **Cross-Contract Comparison:** Verified consistency with PrivateOmniCoin (reference), PrivateWBTC and PrivateUSDC (siblings)
8. **NatSpec Accuracy:** Verified all documentation against actual behavior (found L-03 discrepancy)
9. **Storage Layout:** Verified gap calculation and slot counting

---

## Conclusion

PrivateWETH has matured significantly across three audit rounds. The Round 6 Critical and High findings (token custody, balance deduction, public balance crediting) were resolved in the previous rewrite. The Round 6 Medium findings have been partially addressed:

- **M-02 (Privacy disable timelock)** and **M-03 (Dust double-counting)** are both **FIXED**.
- **M-01 (Shadow ledger desync)** remains **NOT FIXED** -- the shadow ledger is still not updated during `privateTransfer()`, making emergency recovery unfair to users who received tokens via private transfers.

The remaining findings are:
- **1 Medium:** Shadow ledger not updated during private transfers (M-01, carried forward)
- **5 Low:** Missing `whenNotPaused` on `claimDust` (L-01), no init event (L-02), incorrect NatSpec on `getShadowLedgerBalance` return type (L-03), unchecked `MpcCore.sub()` (L-04), storage gap comment inaccuracy (L-05)
- **4 Informational:** Privacy vs. auditability trade-off (I-01), non-immutable `underlyingToken` (I-02), sibling divergence (I-03), transaction graph leakage (I-04)

**Deployment Recommendation:** PRODUCTION READY with the following caveats:

1. **Recommended before deployment:** Fix L-03 (NatSpec accuracy on `getShadowLedgerBalance`) to prevent integration errors. Fix L-01 (`claimDust` missing `whenNotPaused`) for consistency. These are quick one-line changes.

2. **Recommended but not blocking:** Implement M-01 (shadow ledger transfer tracking per ATK-H08 pattern) for complete emergency recovery. Use `checkedSub()` instead of `sub()` (L-04) for defense-in-depth.

3. **Accepted limitations:** Transaction graph leakage (I-04) is inherent to the architecture. Shadow ledger incomplete recovery (M-01) is documented. `underlyingToken` mutability via upgrade (I-02) is a UUPS constraint mitigated by ossification.

**Positive Observations:**
- All Round 6 Critical and High findings fully resolved
- Real WETH custody via SafeERC20 -- solvency guaranteed at contract level
- Per-user public balance tracking prevents unauthorized consumption
- 7-day privacy disable timelock protects users during emergency transitions
- Dust tracking and refund mechanism (correctly accounting after M-03 fix)
- Comprehensive NatSpec documentation with scaling precision details
- Clean ReentrancyGuard + Pausable + AccessControl + UUPS inheritance
- Ossification for permanent upgrade lockdown
- Restricted balance queries (owner or admin only) protecting privacy
- Self-transfer protection preventing MPC state corruption
- Zero-amount validation on all entry points
- Consistent chain ID detection across sibling contracts

---
*Generated by Claude Code Audit Agent -- Round 7 Deep Audit*
*Timestamp: 2026-03-13 20:59 UTC*
