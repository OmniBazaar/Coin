# Security Audit Report: PrivateOmniCoin (Round 3)

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/PrivateOmniCoin.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 764
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (ERC20 token with privacy-preserving balances via COTI V2 MPC)
**OpenZeppelin Version:** 5.x (upgradeable contracts)
**Dependencies:** `MpcCore.sol` (COTI V2 MPC library), `OmniPrivacyBridge.sol` (fee collection and XOM locking)
**Test Suite:** `Coin/test/PrivateOmniCoin.test.js`
**Previous Audit:** Round 1 (2026-02-21) -- 1 Critical, 3 High, 5 Medium, 4 Low, 2 Informational

---

## Executive Summary

PrivateOmniCoin is a UUPS-upgradeable ERC20 token (pXOM) that provides privacy-preserving balances using COTI V2's MPC (Multi-Party Computation) garbled circuits. Users convert public pXOM to encrypted private balances via `convertToPrivate()`, transfer privately via `privateTransfer()`, and convert back via `convertToPublic()`. The contract acts as the token layer; fee collection (0.5%) is handled by the separate `OmniPrivacyBridge` contract.

**Round 1 Remediation Status:** The contract has been substantially reworked since the Round 1 audit. All 4 Critical/High findings (C-01, H-01, H-02, H-03) and all 5 Medium findings have been remediated:

- **C-01 (uint64 precision):** Fixed via `PRIVACY_SCALING_FACTOR = 1e12` -- private balances now use 6-decimal precision, supporting up to ~18.4M XOM per balance.
- **H-01 (double fee):** Fixed -- PrivateOmniCoin no longer charges any fee; the bridge is the sole fee point. `PRIVACY_FEE_BPS` retained as a documentation-only constant.
- **H-02 (unbacked fee minting):** Fixed -- no fee is minted in this contract. Bridge charges fee in XOM before minting pXOM.
- **H-03 (no MPC recovery):** Fixed -- `privateDepositLedger` shadow ledger tracks deposits, and `emergencyRecoverPrivateBalance()` provides admin recovery when privacy is disabled.
- **M-01 (self-transfer):** Fixed -- `SelfTransfer` error added.
- **M-02 (zero-amount convertToPublic):** Fixed -- post-decryption zero check added.
- **M-03 (uncapped mint):** Fixed -- `MAX_SUPPLY = 16.6B` cap added to `mint()`.
- **M-04 (chain 131313 missing):** Fixed -- added to `_detectPrivacyAvailability()`.
- **M-05 (no reentrancy):** Fixed -- `ReentrancyGuardUpgradeable` inherited and `nonReentrant` added to all privacy functions.

**New features since Round 1:** Ossification mechanism (`ossify()`, `isOssified()`, `ContractIsOssified` error), `MAX_SUPPLY` cap, `SelfTransfer` check, shadow ledger emergency recovery.

**Round 3 findings:** The remediation work is solid. This audit found **0 Critical**, **0 High**, **3 Medium**, **3 Low**, and **4 Informational** findings. The most significant issues are the use of unchecked MPC arithmetic (`MpcCore.add`/`sub` instead of `checkedAdd`/`checkedSub`), the fee constant mismatch with the bridge (0.3% vs 0.5%), and the scaling dust burn that permanently destroys up to ~0.000001 XOM per conversion.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 3 |
| Informational | 4 |

---

## Round 1 Remediation Verification

| Round 1 ID | Severity | Status | Verification |
|------------|----------|--------|--------------|
| C-01 | Critical | FIXED | `PRIVACY_SCALING_FACTOR = 1e12` scales 18-decimal amounts to 6-decimal for MPC. Max ~18.4M XOM per private balance. Lines 102-106. |
| H-01 | High | FIXED | No fee charged in `convertToPrivate()`. `PRIVACY_FEE_BPS` retained as reference constant only (lines 94-97). Event emits `fee = 0` (line 350). |
| H-02 | High | FIXED | No `_mint(feeRecipient, fee)` anywhere. Fee is charged upstream by `OmniPrivacyBridge.convertXOMtoPXOM()` in XOM. |
| H-03 | High | FIXED | `privateDepositLedger` (line 137) tracks scaled deposits. `emergencyRecoverPrivateBalance()` (lines 515-533) mints back scaled balance when privacy disabled. |
| M-01 | Medium | FIXED | `if (to == msg.sender) revert SelfTransfer()` at line 434. |
| M-02 | Medium | FIXED | `if (plainAmount == 0) revert ZeroAmount()` at line 394, after MPC decrypt. |
| M-03 | Medium | FIXED | `MAX_SUPPLY = 16_600_000_000 * 10**18` (line 111). `mint()` checks `totalSupply() + amount > MAX_SUPPLY` (line 546). |
| M-04 | Medium | FIXED | `block.chainid == 131313` added to `_detectPrivacyAvailability()` at line 761. |
| M-05 | Medium | FIXED | `ReentrancyGuardUpgradeable` inherited (line 24). `nonReentrant` on `convertToPrivate` (311), `convertToPublic` (362), `privateTransfer` (429). |
| L-01 | Low | UNCHANGED | `burnFrom` still uses role-based access instead of allowance. By design; documented. |
| L-02 | Low | N/A | Fee precision loss is no longer relevant -- no fee charged in this contract. |
| L-03 | Low | UNCHANGED | `INITIAL_SUPPLY = 1B` still minted at genesis. Deployment procedure must ensure bridge is funded with equivalent XOM. |
| L-04 | Low | UNCHANGED | Asymmetric fee design is now more clear: this contract charges no fee at all; bridge charges 0.5% on entry only. |
| I-01 | Info | UNCHANGED | `ConvertedToPrivate` still indexes `publicAmount` and `fee`. Low priority. |
| I-02 | Info | FIXED | Storage gap comment updated to count 6 variables (line 147). |

---

## Architecture Analysis

### Design Strengths

1. **Clean Separation of Concerns:** Fee collection is fully delegated to `OmniPrivacyBridge`. This contract handles only token mechanics and MPC encryption, eliminating the Round 1 double-fee and unbacked-minting issues.

2. **Shadow Ledger Pattern:** The `privateDepositLedger` provides a plaintext fallback for emergency recovery. The ledger correctly tracks only deposits (not private transfer receipts), with clear documentation of this limitation (lines 461-467).

3. **Scaling Factor Approach:** The `PRIVACY_SCALING_FACTOR = 1e12` cleanly bridges the 18-decimal ERC20 standard with COTI's uint64 MPC limitation. Maximum private balance of ~18.4M XOM is practical for the ecosystem.

4. **Ossification:** The `ossify()` function (line 689) provides a one-way, irreversible mechanism to permanently disable upgrades. This is excellent for progressive decentralization -- admin can lock the contract once stable.

5. **Defense-in-Depth Mint Cap:** `MAX_SUPPLY` enforcement in `mint()` prevents a compromised `MINTER_ROLE` from inflating pXOM beyond the protocol-wide 16.6B XOM limit.

6. **Complete NatSpec:** Thorough documentation on all functions, state variables, events, and errors. Scaling behavior and limitations are clearly documented.

### Dependency Analysis

- **MpcCore (COTI V2):** Provides encrypted computation via precompile at address `0x64`. Key operations: `setPublic64` (encrypt plaintext), `onBoard` (ct to gt), `offBoard` (gt to ct), `add`/`sub` (arithmetic), `ge` (comparison), `decrypt` (reveal). All operations are `internal` functions that call the MPC precompile.

- **OmniPrivacyBridge:** Entry point for XOM-to-pXOM conversions. Charges 0.5% fee, locks XOM, calls `PrivateOmniCoin.mint()`. The bridge holds `MINTER_ROLE` and `BURNER_ROLE` on this contract.

- **OpenZeppelin Upgradeable (v5.x):** Standard UUPS upgradeable stack. `_update()` override (line 729) resolves the `ERC20Upgradeable` / `ERC20PausableUpgradeable` diamond inheritance correctly.

---

## Findings

### [M-01] Unchecked MPC Arithmetic -- Silent Overflow/Underflow on Encrypted Balances

**Severity:** Medium
**Lines:** 333, 343, 378, 386, 457
**Category:** Arithmetic Safety

**Description:**

The contract uses `MpcCore.add()` and `MpcCore.sub()` for all encrypted balance arithmetic. These are the **unchecked** variants in COTI's MPC library. The COTI MpcCore library provides checked alternatives: `MpcCore.checkedAdd()` and `MpcCore.checkedSub()` (MpcCore.sol lines 901-906, 920-925) which revert on overflow/underflow.

While the contract performs a plaintext `ge` (greater-or-equal) check before subtraction (lines 370-374, 441-443), the overflow risk on addition is unguarded:

```solidity
// Line 333 - convertToPrivate: unchecked add
gtUint64 gtNewBalance = MpcCore.add(gtCurrentBalance, gtAmount);

// Line 343 - convertToPrivate: unchecked add on total supply
gtUint64 gtNewTotalPrivate = MpcCore.add(gtTotalPrivate, gtAmount);
```

If a user's private balance approaches `type(uint64).max` (18,446,744,073,709,551,615 in 6-decimal scaled units = ~18.4M XOM), a subsequent `convertToPrivate()` call could silently wrap the encrypted balance to near zero. The plaintext `scaledAmount` check (`scaledAmount > type(uint64).max` at line 318) only validates the individual deposit amount, not the resulting sum.

Similarly, `totalPrivateSupply` has no overflow guard. If total private holdings across all users approach uint64 max, the encrypted total could wrap.

The subtraction side is partially guarded by the `ge` comparison, but `MpcCore.sub()` itself does not revert on underflow -- it wraps. If the `ge` check passes due to an MPC edge case (e.g., timing, state inconsistency), the subtracted balance would wrap to a large value.

**Impact:** Silent balance corruption if encrypted balances overflow. A user depositing the maximum amount twice would lose their entire private balance to wraparound. While the ~18.4M XOM per-balance ceiling makes this unlikely in normal operation, a coordinated attack or a single wealthy user could reach this threshold.

**Recommendation:** Replace `MpcCore.add()` with `MpcCore.checkedAdd()` in all four addition sites. Replace `MpcCore.sub()` with `MpcCore.checkedSub()` in all subtraction sites for defense-in-depth:

```solidity
// convertToPrivate - line 333
gtUint64 gtNewBalance =
    MpcCore.checkedAdd(gtCurrentBalance, gtAmount);

// convertToPrivate - line 343
gtUint64 gtNewTotalPrivate =
    MpcCore.checkedAdd(gtTotalPrivate, gtAmount);

// convertToPublic - line 378
gtUint64 gtNewBalance =
    MpcCore.checkedSub(gtCurrentBalance, encryptedAmount);

// convertToPublic - line 386
gtUint64 gtNewTotalPrivate =
    MpcCore.checkedSub(gtTotalPrivate, encryptedAmount);

// privateTransfer - line 449 (sub sender)
gtUint64 gtNewSenderBalance =
    MpcCore.checkedSub(gtSenderBalance, encryptedAmount);

// privateTransfer - line 457 (add recipient)
gtUint64 gtNewRecipientBalance =
    MpcCore.checkedAdd(gtRecipientBalance, encryptedAmount);
```

---

### [M-02] Fee Constant Mismatch -- PRIVACY_FEE_BPS Says 0.3% but Bridge Charges 0.5%

**Severity:** Medium
**Lines:** 94-97, OmniPrivacyBridge.sol line 77
**Category:** Documentation / Integration Consistency

**Description:**

`PrivateOmniCoin.PRIVACY_FEE_BPS` is declared as `30` (0.3%) with the NatSpec comment:

```solidity
/// @notice Privacy conversion fee in basis points (30 = 0.3%)
/// @dev Retained for reference; fee is charged by OmniPrivacyBridge,
/// not by this contract. See H-01 fix notes.
uint16 public constant PRIVACY_FEE_BPS = 30;
```

However, `OmniPrivacyBridge.PRIVACY_FEE_BPS` is `50` (0.5%):

```solidity
/// @notice Privacy conversion fee in basis points (50 = 0.5%)
uint16 public constant PRIVACY_FEE_BPS = 50;
```

The contract-level NatSpec at line 47 also says "bridge charges 0.3%", which is incorrect.

While `PRIVACY_FEE_BPS` in PrivateOmniCoin is not used in any calculation (the fee was removed per Round 1 H-01), it is a `public constant` that external integrators, UIs, and documentation tools will read via `contract.PRIVACY_FEE_BPS()`. Any system querying this contract for the fee rate will get the wrong answer.

**Impact:** Off-chain systems and documentation that read `PrivateOmniCoin.PRIVACY_FEE_BPS()` will display 0.3% instead of the actual 0.5% charged by the bridge. Users may be surprised by the actual fee being higher than what this constant suggests.

**Recommendation:** Update the constant and all related NatSpec to reflect the actual 0.5% fee:

```solidity
/// @notice Privacy conversion fee in basis points (50 = 0.5%)
/// @dev Retained for reference; fee is charged by OmniPrivacyBridge,
/// not by this contract. See H-01 fix notes.
uint16 public constant PRIVACY_FEE_BPS = 50;
```

Also update the contract-level NatSpec at line 47:
```
 * - XOM to pXOM conversion (no fee here; bridge charges 0.5%)
```

And update the `convertToPrivate` NatSpec at line 297:
```
 * No fee is charged here; the OmniPrivacyBridge charges 0.5%.
```

**Note:** If this contract is already deployed behind a proxy, `PRIVACY_FEE_BPS` is a constant (embedded in bytecode, not storage), so updating it requires deploying a new implementation and upgrading the proxy. Since the constant has no on-chain effect, this can be deferred to the next implementation upgrade.

---

### [M-03] Scaling Dust Permanently Destroyed on convertToPrivate -- Up to 1e12-1 Wei Per Conversion

**Severity:** Medium
**Lines:** 316, 322-323
**Category:** Token Economics / Value Loss

**Description:**

In `convertToPrivate()`, the full 18-decimal `amount` is burned from the user (line 323), but only `amount / PRIVACY_SCALING_FACTOR` (the 6-decimal scaled value) is credited to the private balance (lines 326-327). The remainder -- `amount % PRIVACY_SCALING_FACTOR` -- is permanently destroyed.

```solidity
uint256 scaledAmount = amount / PRIVACY_SCALING_FACTOR; // Truncation
_burn(msg.sender, amount);  // Burns FULL amount including dust
```

For example, if a user converts `1000000000000000001` wei (1.000000000000000001 XOM):
- `scaledAmount` = 1000000000000000001 / 1e12 = 1000000 (truncated)
- `_burn` destroys 1000000000000000001 wei
- Private balance credits 1000000 (= 1.000000 XOM in 6-decimal precision)
- Lost: 1 wei (0.000000000000000001 XOM)

The maximum dust loss per conversion is `PRIVACY_SCALING_FACTOR - 1 = 999,999,999,999` wei = ~0.000001 XOM. This is acknowledged in the NatSpec as "acceptable rounding loss."

However, the dust is not just lost from the user -- it is removed from `totalSupply()` entirely (via `_burn`), creating a permanent deflationary leak. Over millions of conversions, this could accumulate to a non-trivial supply reduction. More importantly, the dust represents tokens that cannot be recovered via `convertToPublic` or `emergencyRecoverPrivateBalance`, since both scale from the 6-decimal value.

**Impact:** Permanent token destruction up to ~0.000001 XOM per conversion. Individually negligible, but represents an undocumented deflationary mechanism. If the bridge holds locked XOM corresponding to the full burned amount, but the private balance only represents the scaled amount, the bridge accumulates a small surplus of permanently inaccessible XOM.

**Recommendation:** Burn only the rounded-down amount (the portion that maps cleanly to 6-decimal precision), returning the dust to the user:

```solidity
uint256 scaledAmount = amount / PRIVACY_SCALING_FACTOR;
if (scaledAmount == 0) revert ZeroAmount();
if (scaledAmount > type(uint64).max) revert AmountTooLarge();

// Only burn the amount that maps to the scaled value
uint256 actualBurnAmount = scaledAmount * PRIVACY_SCALING_FACTOR;
_burn(msg.sender, actualBurnAmount);
```

This ensures the user retains the sub-1e12 dust in their public balance. The `emit` would then use `actualBurnAmount` instead of `amount`:

```solidity
emit ConvertedToPrivate(msg.sender, actualBurnAmount, 0);
```

---

### [L-01] emergencyRecoverPrivateBalance Has No MAX_SUPPLY Check

**Severity:** Low
**Lines:** 515-533

**Description:**

`emergencyRecoverPrivateBalance()` mints tokens via `_mint(user, publicAmount)` (line 530) without checking against `MAX_SUPPLY`. While the `mint()` function (line 546) enforces the cap, `emergencyRecoverPrivateBalance()` calls `_mint()` directly, bypassing the cap.

In an emergency scenario where MPC is unavailable and the admin recovers many users' private balances, the cumulative minting could theoretically push `totalSupply()` past `MAX_SUPPLY` without reverting.

This is unlikely because the recovery only restores previously burned tokens (the shadow ledger tracks deposits that were burned during `convertToPrivate`). The total supply should not exceed pre-conversion levels. However, the defense-in-depth principle suggests enforcing the cap at every mint point.

**Impact:** Theoretical MAX_SUPPLY bypass during emergency recovery. Practically unlikely because the recovered amounts correspond to previously burned tokens.

**Recommendation:** Add the MAX_SUPPLY check:

```solidity
function emergencyRecoverPrivateBalance(
    address user
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (privacyEnabled) revert PrivacyMustBeDisabled();
    if (user == address(0)) revert ZeroAddress();

    uint256 scaledBalance = privateDepositLedger[user];
    if (scaledBalance == 0) revert NoBalanceToRecover();

    privateDepositLedger[user] = 0;
    uint256 publicAmount = scaledBalance * PRIVACY_SCALING_FACTOR;

    // Defense-in-depth: enforce supply cap
    if (totalSupply() + publicAmount > MAX_SUPPLY) {
        revert ExceedsMaxSupply();
    }

    _mint(user, publicAmount);
    emit EmergencyPrivateRecovery(user, publicAmount);
}
```

---

### [L-02] convertToPublic Decrypts encryptedAmount After State Changes -- Timing Side Channel

**Severity:** Low
**Lines:** 377-396
**Category:** Information Leakage

**Description:**

In `convertToPublic()`, the balance subtraction and total supply update occur using encrypted MPC operations (lines 377-388), and then the `encryptedAmount` is decrypted to obtain `plainAmount` (line 393). This means the EVM state changes (encrypted balance update, total supply update) are committed before the plaintext amount is known.

The `MpcCore.decrypt()` call at line 393 is an external call to the MPC precompile that reveals the plaintext value. An observer monitoring MPC precompile interactions could potentially correlate the decryption call with the preceding state changes to infer the amount, even though the private transfer itself does not reveal amounts.

This is inherent to the COTI V2 architecture (decryption must happen somewhere to produce the minted public tokens), and the `convertToPublic` function is explicitly a "de-privacy" operation. However, the ordering means that if the `_mint` at line 409 reverts (e.g., if the mint would exceed `MAX_SUPPLY` in a future version), the encrypted balance has already been decremented.

More concretely: the `_mint` at line 409 cannot revert because `mint()` (with the MAX_SUPPLY check) is a different function. The internal `_mint()` called here has no supply cap check. This is consistent with the L-01 finding -- there is no MAX_SUPPLY enforcement on the `_mint` path in `convertToPublic`.

**Impact:** Theoretical state inconsistency if `_mint` reverts (currently unreachable). The ordering is correct for the current implementation but fragile against future modifications.

**Recommendation:** Move the decryption earlier and validate before committing encrypted state changes, or add the MAX_SUPPLY check before `_mint`. The current code is functionally correct, but a comment noting the ordering dependency would aid future maintainers.

---

### [L-03] Function Ordering Warning -- ossify() Placed After Public View Functions

**Severity:** Low
**Lines:** 689
**Category:** Style / Solhint Compliance

**Description:**

Solhint reports: `Function order is incorrect, external function can not go after public view function (line 672)`. The `ossify()` function (external, state-mutating) is placed after `getFeeRecipient()` (public, view). Per the Solidity style guide and project coding standards, external state-mutating functions should precede public view functions.

Additionally, the `isOssified()` function at line 698 is also external view, placed between the external mutating `ossify()` and the internal `_authorizeUpgrade()`. While `isOssified()` being right after `ossify()` is logical grouping, it violates strict ordering rules.

**Impact:** No functional impact. Style compliance issue.

**Recommendation:** Move `ossify()` and `isOssified()` to the admin functions section (after `unpause()` at line 572, before the balance query section). This groups them with other admin/management functions and fixes the ordering warning.

---

### [I-01] PRIVACY_FEE_BPS and feeRecipient Are Dead State -- Storage Slot Consumption

**Severity:** Informational
**Lines:** 94-97, 126-128, 482-488, 672-678

**Description:**

Since the Round 1 H-01 fix, `PRIVACY_FEE_BPS` is a constant that is never used in any calculation, and `feeRecipient` is a state variable that is never read by any fee logic. The `setFeeRecipient()` function (lines 482-488) and `getFeeRecipient()` (lines 672-678) exist solely for storage layout compatibility.

While constants do not consume storage slots (they are embedded in bytecode), `feeRecipient` occupies a storage slot that serves no functional purpose. The `setFeeRecipient` admin function can modify a value that no logic reads, which could confuse operators into thinking fee routing is configurable.

**Impact:** No functional impact. One wasted storage slot and two functions that serve no purpose beyond layout compatibility.

**Recommendation:** No code change needed if the proxy is already deployed (changing storage layout would break the proxy). Document more prominently that these are vestigial:

```solidity
/// @notice VESTIGIAL: Fee recipient address (no longer used for fee routing)
/// @dev Retained solely for storage layout compatibility with deployed proxy.
///      DO NOT rely on this value for fee configuration.
///      See OmniPrivacyBridge for actual fee management.
address private feeRecipient;
```

---

### [I-02] ConvertedToPrivate Event Indexes publicAmount and fee -- Impractical for Filtering

**Severity:** Informational
**Lines:** 160-164

**Description:**

Carried forward from Round 1 I-02. The `ConvertedToPrivate` event indexes all three parameters:

```solidity
event ConvertedToPrivate(
    address indexed user,
    uint256 indexed publicAmount,
    uint256 indexed fee
);
```

Indexing `publicAmount` (a continuous uint256 value) and `fee` (always 0 in this contract) wastes topic slots. Filtering by exact amount is impractical, and `fee` is always 0, making its index meaningless. The `fee` parameter itself is vestigial since no fee is charged.

**Impact:** Marginally higher gas cost per event emission. The `fee` parameter always being 0 is misleading.

**Recommendation:** Remove indexing from `publicAmount` and `fee`. Consider removing the `fee` parameter entirely since it is always 0:

```solidity
event ConvertedToPrivate(
    address indexed user,
    uint256 publicAmount
);
```

---

### [I-03] Unused Parameter Warning -- newImplementation in _authorizeUpgrade

**Severity:** Informational
**Lines:** 708-716

**Description:**

Solhint reports: `Variable "newImplementation" is unused`. The `_authorizeUpgrade(address newImplementation)` function only checks `_ossified` and the `DEFAULT_ADMIN_ROLE` modifier. The `newImplementation` address is never validated.

This is standard practice for UUPS contracts where the authorization logic does not need to inspect the new implementation address. The parameter is required by the `UUPSUpgradeable` interface.

However, some UUPS implementations validate the new implementation (e.g., checking it is a contract, checking it supports the expected interface). The current design relies entirely on the admin's judgment.

**Impact:** No functional impact. The admin can upgrade to any address, including non-contract addresses or incompatible implementations.

**Recommendation:** Suppress the warning with a comment, or add a minimal validation:

```solidity
function _authorizeUpgrade(
    address newImplementation
)
    internal
    override
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    if (_ossified) revert ContractIsOssified();
    // newImplementation validated by UUPSUpgradeable._upgradeToAndCallUUPS
    // which checks ERC1967 implementation slot consistency
}
```

---

### [I-04] Storage Gap Counts 6 Variables but _ossified Was Added Post-Initial Deployment

**Severity:** Informational
**Lines:** 140-150

**Description:**

The storage gap comment at line 147 counts 6 variables: `encryptedBalances`, `totalPrivateSupply`, `feeRecipient`, `privacyEnabled`, `privateDepositLedger`, `_ossified`. The gap is `50 - 6 = 44`.

If the initial deployment (Round 1) had 4 variables (`encryptedBalances`, `totalPrivateSupply`, `feeRecipient`, `privacyEnabled`) with a gap of 46, then adding `privateDepositLedger` and `_ossified` in subsequent upgrades correctly consumed 2 gap slots, reducing the gap to 44. This is the correct UUPS storage layout evolution.

However, the gap arithmetic should be verified against the actual deployment history. If `privateDepositLedger` was added in one upgrade and `_ossified` in another, each upgrade must have decremented the gap by 1.

**Impact:** No impact if the upgrade sequence correctly maintained the gap. If any upgrade failed to decrement the gap, storage collision could occur.

**Recommendation:** No code change needed. This is an informational note for the deployment team to verify that each upgrade that added a state variable also decremented `__gap` by exactly 1. Consider adding a deployment test that verifies storage slot positions match expectations.

---

## Static Analysis Results

**Solhint:** 0 errors, 2 warnings
1. Function ordering: `ossify()` (external) placed after `getFeeRecipient()` (public view) -- see L-03
2. Unused variable: `newImplementation` in `_authorizeUpgrade` -- see I-03

Both warnings are low-severity and have documented justifications.

---

## Gas Optimization Notes

1. **Custom errors:** Used throughout -- gas-efficient pattern. No `require` strings.
2. **Indexed events:** 3 indexed parameters on `ConvertedToPrivate` is excessive (see I-02), but gas impact is marginal.
3. **nonReentrant modifier:** Applied to all three privacy functions. Adds ~2,500 gas per call but is justified given the MPC precompile interaction.
4. **Storage gap:** 44 slots reserved, appropriate for future extensibility.
5. **Constants vs immutables:** `PRIVACY_FEE_BPS`, `BPS_DENOMINATOR`, `INITIAL_SUPPLY`, `PRIVACY_SCALING_FACTOR`, `MAX_SUPPLY` are all `constant` -- embedded in bytecode, no SLOAD cost. Good.
6. **Strict inequality in shadow ledger:** Line 399 uses `>` instead of `>=` -- both paths produce the same result when equal, but `>` avoids an unnecessary subtraction-of-zero. Minor gas optimization, correctly implemented.

---

## Test Coverage Analysis

The existing test suite (`Coin/test/PrivateOmniCoin.test.js`) covers deployment, initialization, role management, and basic ERC20 operations. Privacy functions (`convertToPrivate`, `convertToPublic`, `privateTransfer`) are tested with mocked MPC behavior since Hardhat does not have the COTI MPC precompile.

| Test Area | Covered |
|-----------|---------|
| Deploy via UUPS proxy | Yes |
| Name/symbol/decimals | Yes |
| Initial supply and distribution | Yes |
| Role grants (MINTER, BURNER, BRIDGE) | Yes |
| Token transfers to test users | Yes |
| MAX_SUPPLY constant value | Yes |
| PRIVACY_SCALING_FACTOR value | Yes |
| Ossification mechanism | Partial (needs COTI testnet) |
| Emergency recovery flow | Partial (needs COTI testnet) |
| Scaling dust behavior | No |
| MPC overflow on add | No (needs COTI testnet) |
| Self-transfer rejection | No |

**Missing Test Coverage (recommended additions):**

| Missing Test | Related Finding |
|--------------|-----------------|
| `convertToPrivate` with amount that has scaling dust (verify dust behavior) | M-03 |
| `privateTransfer` to self reverts with `SelfTransfer` | Round 1 M-01 fix |
| `convertToPublic` with encrypted zero reverts with `ZeroAmount` | Round 1 M-02 fix |
| `mint()` reverts when exceeding `MAX_SUPPLY` | Round 1 M-03 fix |
| `emergencyRecoverPrivateBalance` flow (disable privacy, recover, verify balance) | Round 1 H-03 fix |
| `ossify()` then `_authorizeUpgrade` reverts with `ContractIsOssified` | New feature |
| `ossify()` emits `ContractOssified` event | New feature |
| `isOssified()` returns correct state before/after ossification | New feature |

---

## Comparison with Round 1

| Metric | Round 1 | Round 3 | Delta |
|--------|---------|---------|-------|
| Lines of Code | 501 | 764 | +263 (shadow ledger, ossification, scaling, recovery) |
| Critical | 1 | 0 | -1 (all fixed) |
| High | 3 | 0 | -3 (all fixed) |
| Medium | 5 | 3 | -2 (new issues are lower severity than Round 1) |
| Low | 4 | 3 | -1 |
| Informational | 2 | 4 | +2 (more thorough review) |
| Total Findings | 15 | 10 | -5 |
| Solhint Errors | 0 | 0 | -- |
| Solhint Warnings | 3 | 2 | -1 |

The contract's security posture has improved substantially. Round 1 had a Critical finding that made the privacy feature fundamentally unusable; Round 3 has no Critical or High findings. The remaining Medium findings are defense-in-depth improvements rather than functional vulnerabilities.

---

## Summary of Recommendations (Priority Order)

| # | Finding | Severity | Recommendation |
|---|---------|----------|----------------|
| 1 | M-01 | Medium | Use `MpcCore.checkedAdd()`/`checkedSub()` instead of unchecked variants |
| 2 | M-02 | Medium | Update `PRIVACY_FEE_BPS` from 30 to 50 and fix NatSpec references to "0.3%" |
| 3 | M-03 | Medium | Burn only the scaled-down amount, return sub-1e12 dust to user |
| 4 | L-01 | Low | Add `MAX_SUPPLY` check in `emergencyRecoverPrivateBalance` |
| 5 | L-02 | Low | Document ordering dependency in `convertToPublic` decrypt-then-mint flow |
| 6 | L-03 | Low | Move `ossify()`/`isOssified()` to admin section for solhint compliance |
| 7 | I-01 | Info | Document `feeRecipient` and `setFeeRecipient` as vestigial more prominently |
| 8 | I-02 | Info | Remove `indexed` from `publicAmount`/`fee` in `ConvertedToPrivate` event |
| 9 | I-03 | Info | Suppress or address unused `newImplementation` parameter warning |
| 10 | I-04 | Info | Verify storage gap evolution matches deployment history |

---

## Conclusion

PrivateOmniCoin has undergone a thorough and effective remediation since the Round 1 audit. All Critical and High findings have been properly addressed. The scaling factor approach resolves the fundamental uint64 precision limitation, the fee logic has been cleanly separated to the bridge contract, emergency recovery is available via the shadow ledger, and reentrancy protection has been added.

The Round 3 findings are defense-in-depth improvements:

1. **Checked MPC arithmetic (M-01)** is the most actionable finding -- COTI provides `checkedAdd`/`checkedSub` specifically to catch overflow/underflow in encrypted arithmetic. Using the unchecked variants leaves a theoretical attack surface for balance corruption.

2. **Fee constant mismatch (M-02)** is a documentation/integration correctness issue that should be fixed to prevent confusion among integrators.

3. **Scaling dust (M-03)** is a design trade-off that the team has acknowledged. The recommended fix is simple and eliminates the permanent token destruction.

None of the Round 3 findings represent a risk of fund loss under normal operating conditions. The contract is well-structured, thoroughly documented, and follows established patterns for upgradeable ERC20 tokens with privacy extensions.

**Overall Risk Assessment:** Low

---

*Report generated 2026-02-26 19:59 UTC*
*Methodology: Static analysis (solhint: 0 errors, 2 warnings) + Round 1 remediation verification + semantic LLM audit (OWASP SC Top 10 + Business Logic + MPC Integration)*
*Contract hash: Review against PrivateOmniCoin.sol at 764 lines, Solidity 0.8.24*
