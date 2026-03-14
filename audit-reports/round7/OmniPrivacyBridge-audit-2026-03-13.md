# Security Audit Report: OmniPrivacyBridge (Round 7)

**Date:** 2026-03-13 20:59 UTC
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/OmniPrivacyBridge.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 692
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (locks XOM, mints/burns pXOM, holds fee XOM)
**OpenZeppelin Version:** 5.x (contracts-upgradeable)
**Dependencies:** `IERC20`, `SafeERC20`, `AccessControlUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `UUPSUpgradeable`, `ERC2771ContextUpgradeable`
**Test Coverage:** `Coin/test/OmniPrivacyBridge.test.js` (39 test cases, all passing)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)

---

## Executive Summary

OmniPrivacyBridge is the sole entry/exit point for XOM/pXOM conversions. Users lock XOM in the bridge (0.5% fee), receive minted pXOM, and can later burn pXOM to redeem XOM 1:1 (fee-free reverse). The contract tracks solvency via `totalLocked` and `bridgeMintedPXOM`, has per-transaction and daily volume limits, role-based access control, UUPS upgradeability with ossification, and ERC-2771 meta-transaction support.

Round 7 is a full re-audit against the current code. All prior Critical and High findings from Rounds 1, 3, and 6 remain verified as fixed. This round identifies **0 Critical**, **0 High**, **1 Medium**, **4 Low**, and **4 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 4 |
| Informational | 4 |

---

## Solhint Results

```
  172:5   warning  GC: [oldLimit] on Event [MaxConversionLimitUpdated] could be Indexed  gas-indexed-events
  172:5   warning  GC: [newLimit] on Event [MaxConversionLimitUpdated] could be Indexed  gas-indexed-events
  178:5   warning  GC: [amount] on Event [EmergencyWithdrawal] could be Indexed          gas-indexed-events
  187:5   warning  GC: [amount] on Event [FeesWithdrawn] could be Indexed                gas-indexed-events
  195:5   warning  GC: [oldLimit] on Event [DailyVolumeLimitUpdated] could be Indexed    gas-indexed-events
  195:5   warning  GC: [newLimit] on Event [DailyVolumeLimitUpdated] could be Indexed    gas-indexed-events
  608:13  warning  GC: Non strict inequality found. Try converting to a strict one       gas-strict-inequalities
  614:19  warning  Avoid making time-based decisions in your business logic              not-rely-on-time

0 errors, 8 warnings
```

All 8 warnings are benign:
- **gas-indexed-events (6x):** uint256 event parameters are deliberately left non-indexed. Indexing uint256 amounts in events costs more gas (topic vs. data) and provides no bloom-filter benefit for most monitoring use cases. Correct design choice.
- **gas-strict-inequalities (1x):** Line 608 uses `>=` in `block.timestamp >= currentDayStart + 1 days`, which is the correct boundary check for daily period resets. Changing to `>` would leave a 1-second gap at the exact boundary.
- **not-rely-on-time (1x):** Line 614 uses `block.timestamp` for daily volume tracking. Time-based daily limits are inherently block-timestamp-dependent. Miner manipulation risk is negligible for this use case (validators would gain nothing by manipulating the bridge's daily volume window).

---

## Architecture Analysis

### Inheritance Chain

```
OmniPrivacyBridge
  -> Initializable
  -> AccessControlUpgradeable
  -> PausableUpgradeable
  -> ReentrancyGuardUpgradeable
  -> UUPSUpgradeable
  -> ERC2771ContextUpgradeable
```

No diamond inheritance conflicts. The `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` overrides (lines 654-691) correctly resolve the dual-inheritance conflict between `ContextUpgradeable` and `ERC2771ContextUpgradeable` by explicitly delegating to the ERC-2771 version.

### Storage Layout (Verified)

| Slot Offset | Variable | Type | Size |
|-------------|----------|------|------|
| 0 | omniCoin | IERC20 (address) | 20 bytes |
| 1 | privateOmniCoin | IPrivateOmniCoin (address) | 20 bytes |
| 2 | maxConversionLimit | uint256 | 32 bytes |
| 3 | totalLocked | uint256 | 32 bytes |
| 4 | totalConvertedToPrivate | uint256 | 32 bytes |
| 5 | totalConvertedToPublic | uint256 | 32 bytes |
| 6 | bridgeMintedPXOM | uint256 | 32 bytes |
| 7 | totalFeesCollected | uint256 | 32 bytes |
| 8 | dailyVolumeLimit | uint256 | 32 bytes |
| 9 | currentDayVolume | uint256 | 32 bytes |
| 10 | currentDayStart | uint256 | 32 bytes |
| 11 | _ossified | bool | 1 byte |
| 12-49 | __gap[38] | uint256[38] | 38 slots |

Total: 12 named variables + 38 gap = 50 slots. **Correct.** The NatSpec comment at lines 145-149 accurately documents this.

### Design Strengths (Verified from Prior Rounds)

1. **Solvency Invariant:** `totalLocked + totalFeesCollected <= XOM.balanceOf(bridge)` holds across all code paths.
2. **Single Fee Point:** 0.5% charged only in `convertXOMtoPXOM()`. PrivateOmniCoin charges 0%.
3. **Fee Separation:** `totalFeesCollected` tracked independently, withdrawable via `withdrawFees()`.
4. **Genesis Supply Protection:** `bridgeMintedPXOM` counter prevents the 1B genesis pXOM from draining bridge XOM.
5. **CEI Pattern:** State changes precede external calls in both conversion functions.
6. **Daily Volume Limits:** Fixed-period advancement prevents drift.
7. **Emergency Auto-Pause:** `emergencyWithdraw()` pauses bridge when XOM is extracted.
8. **Ossification:** Permanent UUPS upgrade lockdown available.

---

## Role and Modifier Map

### Roles

| Role | Holder (Expected) | Functions Gated |
|------|-------------------|-----------------|
| DEFAULT_ADMIN_ROLE | Deployer -> TimelockController (multi-sig) | `setMaxConversionLimit`, `setDailyVolumeLimit`, `pause`, `unpause`, `emergencyWithdraw`, `withdrawFees`, `ossify`, `_authorizeUpgrade` |

**Observation:** The contract uses a single role (DEFAULT_ADMIN_ROLE) for all admin operations. The Round 6 audit's access control map incorrectly listed `OPERATOR_ROLE` and `FEE_MANAGER_ROLE` -- those roles do not exist in the current contract code. All admin functions are gated by `onlyRole(DEFAULT_ADMIN_ROLE)`. See finding L-01.

### Modifiers

| Modifier | Applied To |
|----------|-----------|
| `nonReentrant` | `convertXOMtoPXOM`, `convertPXOMtoXOM` |
| `whenNotPaused` | `convertXOMtoPXOM`, `convertPXOMtoXOM` |
| `onlyRole(DEFAULT_ADMIN_ROLE)` | All 7 admin functions + `_authorizeUpgrade` |
| `initializer` | `initialize` |

### External Roles on Other Contracts

The bridge requires the following roles on PrivateOmniCoin:
- `MINTER_ROLE` -- for calling `privateOmniCoin.mint()` in `convertXOMtoPXOM()`
- `BURNER_ROLE` -- for calling `privateOmniCoin.burnFrom()` in `convertPXOMtoXOM()`

---

## Findings

### [M-01] All Admin Functions Use a Single Role -- No Separation of Privilege

**Severity:** Medium
**Category:** Access Control
**Lines:** 387, 403, 414, 422, 439, 481, 506
**Status:** New (corrects Round 6 access control map which incorrectly listed OPERATOR_ROLE and FEE_MANAGER_ROLE)

**Description:**

Every admin function in the contract -- including pause/unpause, fee withdrawal, emergency withdrawal, conversion limit changes, ossification, and upgrade authorization -- is gated solely by `DEFAULT_ADMIN_ROLE`. There is no `OPERATOR_ROLE` for operational tasks (pause/unpause) or `FEE_MANAGER_ROLE` for fee extraction.

This means a single key compromise grants the attacker full control: draining all XOM via `emergencyWithdraw()`, withdrawing all fees via `withdrawFees()`, upgrading to a malicious implementation, ossifying to prevent fix, and pausing/unpausing at will.

The Round 6 audit (lines 446-452 of the prior report) listed `OPERATOR_ROLE` and `FEE_MANAGER_ROLE` in its access control table, but **these roles do not exist** in the contract. This was an error in the Round 6 audit.

**Impact:** If the single `DEFAULT_ADMIN_ROLE` holder is compromised, maximum damage is achievable with no compartmentalization. With role separation, a compromised `OPERATOR_ROLE` could only pause/unpause (DoS, not fund theft), and a compromised `FEE_MANAGER_ROLE` could only extract accumulated fees (limited funds, not locked user XOM).

**Mitigating Factors:**
- If `DEFAULT_ADMIN_ROLE` is assigned to a TimelockController + multi-sig, the blast radius of any single key compromise is limited by the timelock delay.
- The contract can be ossified to eliminate the upgrade vector once stable.

**Recommendation:** Consider adding `OPERATOR_ROLE` for `pause()`/`unpause()` and `FEE_MANAGER_ROLE` for `withdrawFees()`. This can be done in an upgrade before ossification. At minimum, ensure the deployment checklist assigns `DEFAULT_ADMIN_ROLE` to a TimelockController behind a 3-of-5 multi-sig. Example:

```solidity
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

function pause() external onlyRole(OPERATOR_ROLE) { _pause(); }
function unpause() external onlyRole(OPERATOR_ROLE) { _unpause(); }
function withdrawFees(address recipient) external onlyRole(FEE_MANAGER_ROLE) { ... }
```

---

### [L-01] `PrivacyNotAvailable` Error and `privacyAvailable()` Interface Method Are Dead Code

**Severity:** Low
**Category:** Code Hygiene / Dead Code
**Lines:** 218, 37-40
**Status:** Carried forward from Round 6 L-01 (unfixed)

**Description:**

The `PrivacyNotAvailable` custom error (line 218) is defined but never referenced in any function body. The `IPrivateOmniCoin` interface includes `privacyAvailable()` (lines 37-40) but neither conversion function calls it. The bridge operates on the public ERC20 layer of pXOM regardless of MPC privacy availability.

**Impact:** ~4 bytes wasted bytecode for the unused error selector. No functional impact.

**Recommendation:** Remove `error PrivacyNotAvailable();` and remove `function privacyAvailable()` from the `IPrivateOmniCoin` interface. The interface should contain only `mint()` and `burnFrom()` -- the two functions the bridge actually calls.

---

### [L-02] `withdrawFees()` Does Not Enforce `whenNotPaused` -- Fees Extractable During Emergency

**Severity:** Low
**Category:** Access Control / Operational Safety
**Lines:** 481-492

**Description:**

When the bridge is paused (e.g., after an `emergencyWithdraw` of XOM), the `withdrawFees()` function is still callable because it does not use the `whenNotPaused` modifier. This means an admin can extract fee XOM even while the bridge is in emergency-paused state.

```solidity
function withdrawFees(
    address recipient
) external onlyRole(DEFAULT_ADMIN_ROLE) {   // <-- no whenNotPaused
    if (recipient == address(0)) revert ZeroAddress();
    uint256 fees = totalFeesCollected;
    if (fees == 0) revert ZeroAmount();
    totalFeesCollected = 0;
    omniCoin.safeTransfer(recipient, fees);
    emit FeesWithdrawn(recipient, fees);
}
```

**Impact:** In a scenario where `emergencyWithdraw()` was called to drain locked XOM (which auto-pauses the bridge), the admin could still call `withdrawFees()` to extract remaining fee XOM. If the emergency was triggered by a vulnerability, allowing further XOM extraction while paused could worsen the situation.

Counterargument: In a genuine emergency, the admin may legitimately need to extract all remaining value. Blocking fee withdrawal during pause could be counterproductive.

**Mitigating Factors:**
- Both `emergencyWithdraw()` and `withdrawFees()` are gated by `DEFAULT_ADMIN_ROLE`.
- If the admin triggered the emergency, they likely also want to secure the fees.

**Recommendation:** This is a design choice. If fee extraction during pause is intentional, add a NatSpec comment: `/// @dev Intentionally callable when paused to allow fee recovery during emergencies.` If it should be blocked, add `whenNotPaused`.

---

### [L-03] `convertPXOMtoXOM` Relies on PrivateOmniCoin.burnFrom() Not Checking Allowance

**Severity:** Low
**Category:** Integration / Coupling Risk
**Lines:** 366-367

**Description:**

The bridge's `convertPXOMtoXOM()` calls `privateOmniCoin.burnFrom(caller, amount)` at line 367. In the current PrivateOmniCoin implementation (line 871-876), `burnFrom` is overridden to require only `BURNER_ROLE` and does NOT check or consume ERC20 allowance:

```solidity
// PrivateOmniCoin.sol, lines 871-876
function burnFrom(address from, uint256 amount)
    public override onlyRole(BURNER_ROLE) {
    _burn(from, amount);   // <-- no _spendAllowance call
}
```

This means the bridge can burn any user's pXOM without the user granting an ERC20 approval to the bridge. The user merely needs to call `convertPXOMtoXOM(amount)` and the bridge burns their pXOM directly.

The existing test suite (line 199) approves pXOM to the bridge before calling `convertPXOMtoXOM`, but this approval is unnecessary and never consumed. This creates a false sense of security in the test -- if the PrivateOmniCoin.burnFrom were ever upgraded to check allowance (restoring standard ERC20Burnable behavior), the bridge's conversion function would break for users who didn't explicitly approve.

**Impact:** No security impact in the current deployment. However:
1. The tight coupling to PrivateOmniCoin's non-standard `burnFrom` behavior means a future PrivateOmniCoin upgrade that restores standard allowance checks would break the bridge.
2. The unnecessary approval in tests masks this coupling.

**Recommendation:**
1. Add a NatSpec comment on `convertPXOMtoXOM()` documenting the dependency: `/// @dev Requires that PrivateOmniCoin.burnFrom() is BURNER_ROLE-gated (not allowance-gated). User approval is NOT required for pXOM burn.`
2. Remove the unnecessary `privateOmniCoin.connect(user1).approve(...)` call in the test to accurately reflect the actual interaction.

---

### [L-04] No Event Emitted When Ossification Deadline Approaches or Admin Role Is Transferred

**Severity:** Low
**Category:** Monitoring / Operational Safety
**Lines:** 506-509

**Description:**

The `ossify()` function (line 506-509) irreversibly locks the contract against upgrades. Once called, the contract can never be patched. There is no timelock or delay mechanism on ossification itself -- it takes effect immediately in a single transaction.

The NatSpec at lines 496-504 correctly warns about this and recommends a two-step process (transfer admin to TimelockController, then propose via timelock). However, the contract itself does not enforce any delay.

If admin accidentally calls `ossify()` (or a malicious admin ossifies to prevent a critical security patch), there is no recovery.

**Impact:** Irreversible action with no on-chain delay enforcement. Relies entirely on off-chain governance discipline.

**Mitigating Factors:**
- The NatSpec documentation is thorough about the risk.
- If admin is behind a TimelockController, the timelock provides the missing delay.
- This is a common pattern in many UUPS contracts (OpenZeppelin does not provide a built-in ossification delay).

**Recommendation:** Accept as-is if admin is behind a timelock. If adding defense-in-depth, consider a two-step ossification pattern with a mandatory delay (similar to PrivateOmniCoin's `proposePrivacyDisable` / `executePrivacyDisable` pattern):

```solidity
uint256 public ossificationScheduledAt;
uint256 public constant OSSIFICATION_DELAY = 7 days;

function proposeOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
    ossificationScheduledAt = block.timestamp + OSSIFICATION_DELAY;
    emit OssificationProposed(ossificationScheduledAt);
}

function executeOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(ossificationScheduledAt != 0 && block.timestamp >= ossificationScheduledAt);
    _ossified = true;
    emit ContractOssified(address(this));
}
```

---

### [I-01] `bridgeMintedPXOM` Desynchronization on Direct pXOM Burns Remains Inherent

**Severity:** Informational
**Status:** Carried forward from Round 6 I-01 / Round 3 I-02

**Description:**

If a user burns pXOM directly via `privateOmniCoin.burn()` (bypassing the bridge), the bridge's `bridgeMintedPXOM` counter is not decremented. The burned pXOM is permanently "phantom" in bridge accounting, and the corresponding locked XOM becomes unredeemable by normal means. Only `emergencyWithdraw()` by admin can recover the stranded XOM.

**Impact:** User self-harm. Not exploitable by attackers. Admin can recover via emergency withdrawal.

**Recommendation:** Retained for documentation completeness. No code change required. UI should prominently warn users to convert pXOM-to-XOM only through the bridge.

---

### [I-02] Bidirectional Daily Volume Counter May Surprise Users

**Severity:** Informational
**Status:** Carried forward from Round 6 I-02

**Description:**

Both `convertXOMtoPXOM()` and `convertPXOMtoXOM()` increment the same `currentDayVolume` counter. A user who converts 40M XOM to pXOM (consuming 80% of the 50M daily limit) only has 10M of daily capacity remaining for either direction, including converting pXOM back to XOM.

**Impact:** User experience surprise. No security impact.

**Recommendation:** The `_checkAndUpdateDailyVolume()` NatSpec should document: "The daily volume limit applies bidirectionally -- both XOM-to-pXOM and pXOM-to-XOM conversions contribute to the same daily counter."

---

### [I-03] Fee Withdrawal Destination Is Unconstrained -- No UnifiedFeeVault Integration

**Severity:** Informational
**Category:** Fee Architecture / Integration
**Lines:** 481-492

**Description:**

The `withdrawFees()` function sends accumulated fee XOM to an arbitrary `recipient` address specified by the admin at call time. There is no on-chain enforcement that fees are routed to the `UnifiedFeeVault` (the project's canonical fee distribution contract). The `UnifiedFeeVault` contract (verified in `Coin/contracts/UnifiedFeeVault.sol`) is designed to receive fees and distribute them according to the 70/20/10 split (ODDAO/Staking Pool/Protocol Treasury).

Other contracts in the system (e.g., MinimalEscrow, DEXSettlement) send fees directly to UnifiedFeeVault via their respective fee routing mechanisms. The privacy bridge is the only fee-collecting contract that allows ad-hoc recipient specification.

**Impact:** No security impact. However, if the admin specifies the wrong recipient, fees bypass the canonical distribution. This is an operational risk, not a code vulnerability.

**Recommendation:** Consider hardcoding or configuring the fee recipient as UnifiedFeeVault:

```solidity
address public feeVault; // Set in initialize() or via admin setter

function withdrawFees() external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 fees = totalFeesCollected;
    if (fees == 0) revert ZeroAmount();
    totalFeesCollected = 0;
    omniCoin.safeTransfer(feeVault, fees);
    emit FeesWithdrawn(feeVault, fees);
}
```

Alternatively, accept the current design and rely on governance to ensure the admin calls `withdrawFees(unifiedFeeVaultAddress)`.

---

### [I-04] ERC-2771 Trusted Forwarder Set at Constructor Time -- Cannot Be Updated

**Severity:** Informational
**Category:** Upgradeability / Configuration
**Lines:** 245-249

**Description:**

The `trustedForwarder_` address is passed as a constructor argument and stored as an immutable in `ERC2771ContextUpgradeable`. This value is baked into the implementation bytecode and cannot be changed without deploying a new implementation and upgrading the proxy.

If the trusted forwarder contract needs to be rotated (e.g., due to a vulnerability in the forwarder), the bridge must be upgraded to a new implementation with the new forwarder address in its constructor. This upgrade path is blocked if the contract has been ossified.

**Impact:** If the forwarder is compromised after ossification, meta-transaction support cannot be fixed. A compromised forwarder could spoof `_msgSender()`, allowing the attacker to call `convertXOMtoPXOM()` or `convertPXOMtoXOM()` as any user -- though the user's XOM approval and pXOM balance still serve as guards.

**Mitigating Factors:**
- If the forwarder is `address(0)` (as in tests), ERC-2771 is effectively disabled and `_msgSender()` always returns `msg.sender`. No spoofing possible.
- Even with a compromised forwarder, the attacker can only trigger conversions for users who have pre-approved XOM to the bridge.
- The conversion functions have reentrancy guards and pause capability.

**Recommendation:** If meta-transactions are not needed at launch, deploy with `trustedForwarder_ = address(0)`. This eliminates the attack surface entirely. If meta-transactions are needed, ensure the forwarder contract itself is audited and has no known vulnerabilities before ossifying the bridge.

---

## Solvency Invariant Verification (Round 7)

**Invariant:** `XOM.balanceOf(bridge) >= totalLocked + totalFeesCollected`

Exhaustive proof by code path analysis:

| Code Path | XOM Balance Delta | totalLocked Delta | totalFeesCollected Delta | Invariant |
|-----------|-------------------|-------------------|--------------------------|-----------|
| `convertXOMtoPXOM(amount)` | +amount | +amountAfterFee | +fee | Preserved (amount = amountAfterFee + fee) |
| `convertPXOMtoXOM(amount)` | -amount | -amount | 0 | Preserved |
| `withdrawFees()` | -totalFeesCollected | 0 | -> 0 | Preserved |
| `emergencyWithdraw(omniCoin, to, amount)` where amount <= totalLocked | -amount | -amount | 0 | Preserved (+ bridge pauses) |
| `emergencyWithdraw(omniCoin, to, amount)` where amount > totalLocked | -amount | -> 0 | reduced by excess | Preserved (+ bridge pauses) |
| `emergencyWithdraw(otherToken, to, amount)` | 0 (XOM unaffected) | 0 | 0 | Preserved |

**Secondary invariant:** `bridgeMintedPXOM <= totalLocked`

| Code Path | totalLocked Delta | bridgeMintedPXOM Delta | Invariant |
|-----------|-------------------|-----------------------|-----------|
| `convertXOMtoPXOM(amount)` | +amountAfterFee | +amountAfterFee | Preserved (equality) |
| `convertPXOMtoXOM(amount)` | -amount | -amount | Preserved |
| `emergencyWithdraw` (XOM) | decreased or -> 0 | unchanged | May violate: bridgeMintedPXOM could exceed totalLocked. Bridge is paused, preventing redemptions. |

The emergency path can violate the secondary invariant, but the bridge is paused, making this safe.

---

## Cross-Contract Integration Analysis

### OmniPrivacyBridge <-> PrivateOmniCoin

- **mint():** Bridge calls `privateOmniCoin.mint(caller, amountAfterFee)`. Requires `MINTER_ROLE`. PrivateOmniCoin enforces `MAX_SUPPLY` of 16.6B XOM as defense-in-depth. Safe.
- **burnFrom():** Bridge calls `privateOmniCoin.burnFrom(caller, amount)`. Requires `BURNER_ROLE`. PrivateOmniCoin does NOT check allowance (see L-03). Safe in current design.
- **Role dependency:** Bridge deployment must be followed by `privateOmniCoin.grantRole(MINTER_ROLE, bridge)` and `grantRole(BURNER_ROLE, bridge)`.

### OmniPrivacyBridge <-> UnifiedFeeVault

- UnifiedFeeVault has a `convertPXOMAndBridge()` function that calls `OmniPrivacyBridge.convertPXOMtoXOM()`. The vault approves pXOM to the bridge, then calls conversion. However, per L-03 above, the approval is unnecessary since PrivateOmniCoin.burnFrom is role-gated, not allowance-gated.
- Fee XOM from the bridge should ultimately flow to UnifiedFeeVault for distribution. Currently this is an off-chain governance responsibility (see I-03).

### Flash Loan Attack Vector

An attacker with flash-loaned XOM could:
1. Approve and call `convertXOMtoPXOM(maxConversionLimit)` -- lock 10M XOM, receive ~9.95M pXOM.
2. Approve and call `convertPXOMtoXOM(9.95M)` -- burn pXOM, receive 9.95M XOM back.
3. Net loss: ~50K XOM in fees. Flash loan cost: flash loan premium.

This is not profitable for the attacker. The 0.5% fee makes round-trip conversion a losing proposition. **No flash loan exploit exists.**

---

## Reentrancy Analysis

Both conversion functions use `nonReentrant`:

**convertXOMtoPXOM (lines 296-331):**
1. State: Input validation, daily volume update, fee calculation.
2. External: `omniCoin.safeTransferFrom()` -- potential reentrancy hook if XOM is ERC-777 or has transfer hooks. However, `nonReentrant` guard prevents re-entry.
3. State: `totalLocked`, `totalFeesCollected`, `totalConvertedToPrivate`, `bridgeMintedPXOM` updated.
4. External: `privateOmniCoin.mint()` -- potential reentrancy, but guard active.

**Observation:** State updates happen BETWEEN the two external calls (lines 320-328 between `safeTransferFrom` at 315 and `mint` at 325). This is a partial CEI violation -- some state is updated after the first external call but before the second. However, `nonReentrant` makes this safe. If `nonReentrant` were removed, a reentrancy via the `safeTransferFrom` callback could exploit the fact that `totalLocked` is not yet updated.

**convertPXOMtoXOM (lines 342-373):**
1. State: Input validation, daily volume update, `bridgeMintedPXOM`/`totalLocked` checks.
2. State: `totalLocked`, `bridgeMintedPXOM`, `totalConvertedToPublic` updated (lines 362-364).
3. External: `privateOmniCoin.burnFrom()` (line 367).
4. External: `omniCoin.safeTransfer()` (line 370).

This follows CEI correctly -- all state changes (step 2) happen before both external calls (steps 3-4). Even without `nonReentrant`, this ordering is safe.

**Verdict:** No reentrancy vulnerabilities. The `nonReentrant` guard provides defense-in-depth.

---

## Access Control Map (Corrected)

| Role | Functions | Maximum Damage if Compromised |
|------|-----------|-------------------------------|
| DEFAULT_ADMIN_ROLE | `setMaxConversionLimit`, `setDailyVolumeLimit`, `pause`, `unpause`, `emergencyWithdraw`, `withdrawFees`, `ossify`, `_authorizeUpgrade` | Full: drain all XOM + fees, upgrade to malicious code, ossify to prevent patch |
| Any EOA | `convertXOMtoPXOM`, `convertPXOMtoXOM` | Limited: can only convert own tokens (bounded by limits) |
| View (no role) | `getBridgeStats`, `getConversionRate`, `previewConvertToPrivate`, `previewConvertToPublic`, `isOssified`, all public state vars | None |

**Note:** Unlike the Round 6 audit which listed OPERATOR_ROLE and FEE_MANAGER_ROLE, this contract has **only DEFAULT_ADMIN_ROLE**. See M-01.

---

## Centralization Risk Assessment

**Centralization Score: 7/10** (increased from Round 6's 6/10 due to corrected understanding of single-role architecture)

All administrative power is concentrated in `DEFAULT_ADMIN_ROLE`:
- Drain all funds (emergencyWithdraw)
- Extract all fees (withdrawFees)
- Upgrade to arbitrary implementation (until ossified)
- Permanently ossify (prevent future patches)
- Pause/unpause bridge (DoS or undo emergency stops)

**Pre-mainnet requirements (updated):**
1. Transfer `DEFAULT_ADMIN_ROLE` to a TimelockController (minimum 48-hour delay recommended)
2. TimelockController must be owned by a 3-of-5 multi-sig (Gnosis Safe)
3. Consider role separation upgrade before ossification (M-01)
4. Ossify only after 6-12 months of stable operation

---

## Prior Round Findings -- Status Verification

### Round 1 Findings (All Fixed)
- C-01 (emergencyWithdraw rug pull): Fixed -- auto-pauses on XOM withdrawal.
- C-02 (unbacked genesis pXOM): Fixed -- `bridgeMintedPXOM` counter.
- H-01 (uint64 max conversion): Fixed -- bridge operates on public layer.
- H-02 (double fee): Fixed -- single fee point in bridge.
- H-03 (fee accounting desync): Fixed -- separate `totalFeesCollected`.
- M-01 through M-04, L-01 through L-03, I-01, I-02: All addressed.

### Round 3 Findings (All Fixed/Documented)
- M-01 (emergencyWithdraw edge case): Fixed -- proportional fee zeroing.
- M-02 (daily volume reset drift): Fixed -- fixed-period advancement with `>=`.
- L-01 (fee constant mismatch): Fixed -- both contracts use 50 bps.
- All others: Fixed or documented.

### Round 6 Findings (Verification)
- M-01 (events emit plaintext amounts): **FIXED** -- events now emit only `(address indexed user)`.
- M-02 (fee truncation for small amounts): Protected by `MIN_CONVERSION_AMOUNT`. No change needed.
- L-01 (dead code PrivacyNotAvailable): **NOT FIXED** -- still present. Carried forward as L-01 in this round.
- L-02 (no role verification in initialize): Accepted as deployment concern.
- L-03 (daily limit below current volume): Documented in NatSpec.
- I-01 (bridgeMintedPXOM desync): Inherent limitation, documented.
- I-02 (bidirectional daily volume): Documented.
- I-03 (maxConversionLimit upper bound): Accepted design choice.

**Round 6 Access Control Map Error:** The Round 6 audit listed `OPERATOR_ROLE` (for pause/unpause, risk 5/10) and `FEE_MANAGER_ROLE` (for withdrawFees, risk 3/10) in the access control table. These roles do not exist in the contract. All functions use `DEFAULT_ADMIN_ROLE`. This Round 7 audit corrects this error.

---

## Remediation Priority

| Priority | ID | Severity | Finding | Effort | Action |
|----------|----|----------|---------|--------|--------|
| 1 | M-01 | Medium | Single-role architecture -- no privilege separation | Medium | Add OPERATOR_ROLE and FEE_MANAGER_ROLE in upgrade |
| 2 | L-03 | Low | burnFrom coupling -- no allowance check dependency | Trivial | Add NatSpec comment, fix test |
| 3 | L-02 | Low | withdrawFees callable when paused | Trivial | Add NatSpec or `whenNotPaused` |
| 4 | L-01 | Low | Dead code (PrivacyNotAvailable error) | Trivial | Remove unused error and interface method |
| 5 | L-04 | Low | No ossification delay | Medium | Add propose/execute pattern (optional) |
| 6 | I-03 | Info | Fee destination unconstrained | Low | Consider hardcoding UnifiedFeeVault |
| 7 | I-04 | Info | Immutable trusted forwarder | None | Deploy with address(0) if not needed |
| 8 | I-01 | Info | bridgeMintedPXOM desync on direct burn | None | Document in UI |
| 9 | I-02 | Info | Bidirectional daily volume | Trivial | Document in NatSpec |

---

## Pre-Mainnet Checklist

- [x] All Round 1 Critical/High findings verified fixed
- [x] All Round 3 findings verified fixed or documented
- [x] All Round 6 findings verified (except L-01 dead code -- trivial)
- [x] Fee constant synchronized (50 bps) across bridge and PrivateOmniCoin
- [x] Daily volume reset uses fixed-period advancement (no drift)
- [x] Solvency invariant verified across all code paths
- [x] Reentrancy protection verified on both conversion functions
- [x] Storage gap calculation verified (12 + 38 = 50)
- [x] ERC-2771 override resolution verified (no diamond conflicts)
- [ ] **Code:** Consider adding OPERATOR_ROLE and FEE_MANAGER_ROLE (M-01)
- [ ] **Code:** Remove dead `PrivacyNotAvailable` error (L-01)
- [ ] **Deployment:** Transfer DEFAULT_ADMIN_ROLE to TimelockController + multi-sig
- [ ] **Deployment:** Grant MINTER_ROLE and BURNER_ROLE on PrivateOmniCoin to bridge
- [ ] **Deployment:** Set conservative initial limits (1M per-tx, 10M daily) and increase gradually
- [ ] **Post-deployment:** Verify roles via on-chain queries
- [ ] **Post-deployment:** Run full XOM->pXOM->XOM cycle test with small amounts
- [ ] **Ossification:** Only after 6-12 months of stable operation and role separation upgrade

---

## Conclusion

OmniPrivacyBridge is a well-structured, thoroughly-audited contract that has matured significantly through seven audit rounds. The core economic logic is sound: the solvency invariant holds, fee separation is clean, genesis supply is protected, and rate limits prevent abuse.

The most significant finding in this round is M-01 (single-role architecture), which corrects an error in the Round 6 audit that incorrectly listed OPERATOR_ROLE and FEE_MANAGER_ROLE. The lack of privilege separation means a compromised DEFAULT_ADMIN_ROLE grants full access to all administrative operations. This is mitigable by placing the admin behind a TimelockController + multi-sig, but adding distinct roles would provide defense-in-depth.

The remaining findings are Low and Informational, involving dead code cleanup (L-01), NatSpec documentation gaps (L-02, L-03), ossification delay considerations (L-04), and integration/operational notes (I-01 through I-04). None require code changes before mainnet deployment, though addressing them would improve the contract's production readiness.

**Overall Assessment:** The contract is suitable for mainnet deployment after ensuring DEFAULT_ADMIN_ROLE is assigned to a properly-governed TimelockController with multi-sig ownership. Role separation (M-01) is recommended but not blocking. No code changes are strictly required.

---
*Generated by Claude Code Audit Agent -- Pre-Mainnet Security Audit (Round 7)*
*Contract version: 692 lines, UUPS-upgradeable, XOM/pXOM privacy conversion bridge*
*Prior audits: Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10) -- all Critical/High findings verified fixed*
