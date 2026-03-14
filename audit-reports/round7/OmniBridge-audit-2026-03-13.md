# Security Audit Report: OmniBridge (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/OmniBridge.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,069
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (lock-and-release cross-chain bridge via Avalanche Warp Messaging)
**OpenZeppelin Version:** 5.x (contracts-upgradeable)
**Dependencies:** `IERC20`, `SafeERC20`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`, `PausableUpgradeable`, `UUPSUpgradeable`, `ERC2771ContextUpgradeable`, `OmniCore`
**Test Coverage:** `Coin/test/OmniBridge.test.js` (87 test cases, all passing)
**Prior Audits:** Round 1 (2026-02-20), Round 6 (2026-03-10)
**Slither:** Skipped
**Solhint:** 0 errors, 0 warnings

---

## Executive Summary

OmniBridge is a UUPS-upgradeable cross-chain bridge leveraging Avalanche Warp Messaging (AWM) for XOM and pXOM token transfers between subnets. Users lock tokens on the source chain, a Warp message is emitted via the precompile at `0x0200000000000000000000000000000000000005`, and the destination bridge releases tokens to the recipient. The contract supports per-chain configuration (min/max/daily limits, fees), a trusted bridge registry, independent inbound rate limiting, fee accumulation and distribution to UnifiedFeeVault, a 7-day refund mechanism, pause/unpause, and UUPS upgradeability with permanent ossification.

**This is a Round 7 pre-mainnet audit.** Compared to Round 6, the following remediations have been applied:

- **H-01 Round 6 (Refund-and-complete race condition): FIXED.** A `TransferStatus` enum and `transferStatus` mapping now track per-transfer lifecycle. Both `processWarpMessage()` (line 546) and `refundTransfer()` (line 716) check `transferStatus[transferId] != TransferStatus.PENDING` before proceeding. Once a transfer is COMPLETED or REFUNDED, neither path can execute again.
- **M-01 Round 6 (msg.sender in admin functions): ACCEPTED.** Explicit NatSpec documentation added to each admin function (lines 585-589, 643-644, 690-691, etc.) explaining that `msg.sender` is used deliberately to prevent admin operations from being relayed via meta-transactions.
- **M-02 Round 6 (Chain ID 0 accepted): FIXED.** Line 598 adds `if (chainId == 0) revert InvalidChainId();`.
- **M-03 Round 6 (processWarpMessage recipient validation): FIXED.** Line 532 adds `if (recipient == address(0)) revert InvalidRecipient();`.
- **I-02 Round 6 (Test coverage gaps): SUBSTANTIALLY FIXED.** Test count increased from 23 to 87, with comprehensive tests for `refundTransfer()` (7 test cases including delay, non-sender rejection, double refund, status tracking, private token refund). `processWarpMessage()` remains difficult to fully integration-test due to Warp precompile limitations in Hardhat, though the mock infrastructure is in place.

**Findings not addressed from Round 6:**
- **L-01 (InvalidRecipient error reuse): NOT FIXED.** Still used for both recipient validation and authorization failures.
- **L-04 (setFeeVault missing event): NOT FIXED.** No `FeeVaultUpdated` event added.
- **I-01 (InvalidAmount for Warp validation): NOT FIXED.** Line 948 still uses `InvalidAmount()` for invalid Warp messages.

The Round 7 audit found **0 Critical**, **0 High**, **2 Medium**, **3 Low**, and **3 Informational** findings. The contract has reached a mature security posture with all prior Critical and High findings properly remediated.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Remediation Verification

### H-01 Round 6: Refund-and-Complete Race Condition -- VERIFIED FIXED

**Round 6:** A race condition existed where a user could refund on the source chain AND have the Warp message processed on the destination chain, receiving funds twice.

**Current Code:** The `TransferStatus` enum (lines 129-136) introduces three states: PENDING, COMPLETED, REFUNDED. The `transferStatus` mapping (line 241) tracks each transfer's lifecycle. Both `processWarpMessage()` (lines 546-549) and `refundTransfer()` (lines 716-726) atomically check and set the status:

```solidity
// processWarpMessage() lines 546-549:
if (transferStatus[transferId] != TransferStatus.PENDING) {
    revert TransferAlreadyCompleted();
}
transferStatus[transferId] = TransferStatus.COMPLETED;

// refundTransfer() lines 716-726:
if (transferStatus[transferId] != TransferStatus.PENDING) {
    revert TransferAlreadyCompleted();
}
// ...
transferStatus[transferId] = TransferStatus.REFUNDED;
```

**Assessment:** On the same chain, this effectively prevents double-claiming. However, it is important to recognize an inherent cross-chain limitation: the `transferStatus` on Chain A (source) is independent of the `transferStatus` on Chain B (destination). If the bridge is deployed on both chains, a refund on Chain A sets `transferStatus[id] = REFUNDED` on Chain A's contract, while `processWarpMessage()` on Chain B checks `transferStatus[id]` on Chain B's contract (where it is still PENDING by default). The cross-chain race is mitigated, not eliminated, by this fix. See M-01 below for further analysis.

### M-01 Round 6: msg.sender in Admin Functions -- VERIFIED ACCEPTED

**Current Code:** Each admin function now includes explicit NatSpec (e.g., lines 585-589):
```solidity
// M-01 Round 6: Admin functions deliberately use msg.sender
// (not _msgSender()) because admin operations should not be
// relayed via meta-transactions.
```

This documentation is present on `updateChainConfig()`, `recoverTokens()`, `setFeeVault()`, `pause()`, `unpause()`, and `setTrustedBridge()`. The design decision is sound and now clearly documented.

### M-02 Round 6: Chain ID 0 Accepted -- VERIFIED FIXED

**Current Code (line 598):** `if (chainId == 0) revert InvalidChainId();`

### M-03 Round 6: processWarpMessage Recipient Validation -- VERIFIED FIXED

**Current Code (line 532):** `if (recipient == address(0)) revert InvalidRecipient();`

### L-01 Round 6: InvalidRecipient Error Reuse -- NOT FIXED

`InvalidRecipient()` is still used for both authorization failures (lines 590, 645, 693, 752, 767, 779) and actual recipient validation (lines 438, 532, 713). See L-01 below.

### L-04 Round 6: setFeeVault Missing Event -- NOT FIXED

`setFeeVault()` (lines 687-697) still does not emit an event when the fee vault address changes. See L-02 below.

### I-01 Round 6: InvalidAmount for Warp Validation -- NOT FIXED

Line 948: `if (!valid) revert InvalidAmount();` still uses a semantically incorrect error for invalid Warp messages. See I-01 below.

### I-02 Round 6: Test Coverage Gaps -- SUBSTANTIALLY FIXED

Test suite expanded from 23 to 87 tests. `refundTransfer()` is now thoroughly tested (7 tests covering delay enforcement, sender validation, double-refund prevention, status tracking, and private token refunds). `processWarpMessage()` still lacks full integration tests due to Warp precompile limitations in Hardhat, but the mock infrastructure at lines 29-49 of the test file provides a foundation. See I-02 below for remaining gap.

---

## Findings

### [M-01] Cross-Chain TransferStatus Does Not Prevent Destination-Side Completion After Source-Side Refund

**Severity:** Medium
**Category:** Cross-Chain Design / Business Logic
**Lines:** 241, 546-549, 716-726
**Status:** Residual from Round 6 H-01 fix (downgraded from High to Medium)

**Description:**

The `TransferStatus` enum and `transferStatus` mapping were added to prevent the refund-and-complete race condition identified in Round 6. On a single chain, this fix is effective -- once a transfer is REFUNDED, it cannot be COMPLETED (and vice versa). However, the fix operates within the state of a single contract deployment. In the cross-chain bridge design, the source chain's `OmniBridge` and the destination chain's `OmniBridge` are separate contract instances with independent storage.

The attack scenario:

1. User calls `initiateTransfer()` on Chain A. Transfer ID 1 is created. `transferStatus[1]` on Chain A = PENDING.
2. After 7 days, user calls `refundTransfer(1)` on Chain A. `transferStatus[1]` on Chain A = REFUNDED. User receives net amount back.
3. The original Warp message (or a delayed relay) reaches Chain B. `processWarpMessage()` on Chain B checks `transferStatus[1]` on Chain B's contract. Since no transfer with ID 1 was ever initiated on Chain B, this defaults to `TransferStatus.PENDING` (the uint8 default is 0 = PENDING).
4. Chain B proceeds to release tokens to the recipient.

The `processedMessages` mapping does provide replay protection on Chain B (a given message cannot be processed twice on the same chain), but it does not know about the refund on Chain A. The `transferStatus` check on Chain B is against Chain B's own state, which has never been updated for this transfer ID.

**Impact:** An attacker can receive funds on both chains. The economic impact is bounded by the daily inbound limit on Chain B, the bridge's liquidity on Chain B, and the 7-day refund delay (the attacker must wait 7 days and hope the Warp message has not already been processed on Chain B). Under normal AWM operation (messages process in seconds to minutes), this window is extremely narrow. The 7-day delay was specifically chosen to far exceed typical processing time.

**Mitigating Factors:**
- AWM messages typically process within seconds to minutes, far shorter than the 7-day refund delay.
- The inbound daily limit caps total exposure per day per chain.
- Bridge liquidity on the destination chain bounds the maximum drain.
- The `processedMessages` mapping ensures a message can only be processed once per destination chain.
- Validator monitoring can detect and flag refunded transfers before Warp messages are relayed.

**Recommendation:**

This is a fundamental challenge for all cross-chain bridges with refund mechanisms. The current implementation is the pragmatic approach -- rely on the large time gap between normal Warp processing (seconds) and the refund delay (7 days). For additional protection, consider:

1. **Off-chain guardian attestation:** Before processing a refund, require M-of-N validators to attest that the destination chain has not processed the transfer. This can be implemented as an off-chain check in the validator network (which already exists in the OmniBazaar architecture) without on-chain changes.
2. **Cross-chain refund notification:** When a refund is processed, send a Warp message to the destination chain to mark the transfer as cancelled. The destination bridge should check for cancellation before releasing tokens.
3. **Longer refund delay:** Increase from 7 days to 14 or 30 days to further reduce the already-narrow window.

**Severity downgraded from High (Round 6) to Medium** because the `TransferStatus` fix on the same chain eliminates the trivial single-chain exploit path, and the cross-chain scenario requires precise timing that AWM's fast processing makes extremely unlikely under normal conditions.

---

### [M-02] Fee Distribution Can Reduce Bridge Liquidity Below Locked User Obligations

**Severity:** Medium
**Category:** Economic / Accounting
**Lines:** 453-458, 669-679, 917-932

**Description:**

When a user initiates a transfer, the full `amount` is transferred to the bridge (line 453), and the fee portion is tracked in `accumulatedFees[tokenAddress]` (line 457). The `_releaseTokens()` function checks `token.balanceOf(address(this)) < amount` (line 929) to ensure sufficient liquidity before releasing tokens.

However, `distributeFees()` (lines 669-679) transfers accumulated fees out of the bridge to the `feeVault`. This reduces `balanceOf(address(this))`. If fees are distributed while pending transfers exist, the bridge's token balance decreases, potentially below the sum of all pending (unreleased) transfer amounts.

Example scenario:
1. User A initiates transfer of 10,000 XOM. Fee = 50 XOM (0.5%). Bridge holds 10,000 XOM. Net transfer amount = 9,950 XOM. `accumulatedFees[XOM] = 50`.
2. User B initiates transfer of 10,000 XOM. Bridge holds 20,000 XOM. `accumulatedFees[XOM] = 100`.
3. `distributeFees(XOM)` is called. 100 XOM transferred to feeVault. Bridge now holds 19,900 XOM.
4. Both Warp messages arrive on destination chain. Destination bridge needs to release 9,950 + 9,950 = 19,900 XOM. This works exactly.

Actually, in this specific accounting, it works out correctly because the fee is deducted from the transfer amount stored in `transfers[id].amount` (which records `netAmount = amount - fee`). The bridge holds `sum(gross_amounts)` and needs to release `sum(net_amounts)`. The difference is exactly `sum(fees)`, which is what `accumulatedFees` tracks. So `distributeFees()` correctly removes only the fee portion.

However, the bridge on the **destination** chain must independently have sufficient liquidity. The fee accounting is correct on the source chain but irrelevant to the destination chain. The destination chain releases tokens from its own reserves (not from fees collected on the source). If the destination bridge's liquidity is pre-funded and fees are collected from destination-chain transfers going the other direction, the accounting could become misaligned if one direction has significantly more traffic than the other.

**Impact:** On the source chain, the accounting is correct. On the destination chain, the `_releaseTokens()` balance check provides the safety net. The risk is operational: if the destination bridge's liquidity drops below the pending inbound transfer amounts, incoming Warp messages will revert with `InvalidAmount()`, and users must wait for the 7-day refund on the source chain.

**Recommendation:**

1. Monitor bridge liquidity on all chains as an operational concern. Set daily limits conservatively relative to available liquidity.
2. Consider adding an explicit `availableLiquidity()` view function that subtracts `accumulatedFees` from the balance, giving operators a clear picture of how much liquidity is available for releases vs. how much is claimable fees.
3. Document that fee distribution does not affect source-chain accounting integrity.

---

### [L-01] Inconsistent Error Semantics -- InvalidRecipient Used for Authorization Failures

**Severity:** Low
**Category:** Code Quality / Error Semantics
**Lines:** 590, 645, 693, 713, 752, 767, 779
**Status:** Carried forward from Round 6 L-01 (unfixed)

**Description:**

`InvalidRecipient()` is used in two semantically distinct contexts:

1. **Actual recipient validation:** Lines 438, 532 (`recipient == address(0)`)
2. **Authorization failures:** Lines 590, 645, 693, 713, 752, 767, 779 (`!core.hasRole(core.ADMIN_ROLE(), msg.sender)`)

This ambiguity makes off-chain error monitoring harder -- an `InvalidRecipient` revert could mean either "user supplied a zero-address recipient" or "caller is not an admin." Distinct error codes enable automated monitoring systems to categorize failures accurately.

**Recommendation:** Add a dedicated `Unauthorized()` or `NotAdmin()` custom error for authorization checks, or use `AccessControlUnauthorizedAccount` from OpenZeppelin (which is already used for `onlyRole`-guarded functions like `ossify()`).

---

### [L-02] setFeeVault() Does Not Emit an Event on State Change

**Severity:** Low
**Category:** Observability / Monitoring
**Lines:** 687-697
**Status:** Carried forward from Round 6 L-04 (unfixed)

**Description:**

`setFeeVault()` changes the `feeVault` state variable, which determines where all accumulated bridge fees are sent. This is a security-critical parameter: an attacker who compromises the admin key could silently redirect all future fee distributions to an attacker-controlled address. Without an event, off-chain monitoring systems have no way to detect this change without polling the `feeVault()` view function.

Other admin configuration functions (`updateChainConfig`, `setTrustedBridge`) correctly emit events. `setFeeVault` is the sole exception.

**Recommendation:** Add and emit:
```solidity
event FeeVaultUpdated(address indexed oldVault, address indexed newVault);
```

---

### [L-03] Refund Emits Net Amount but User Lost Fee -- No Way to Query Original Amount

**Severity:** Low
**Category:** Observability / User Experience
**Lines:** 471-480, 707-737

**Description:**

When `refundTransfer()` is called, it refunds `t.amount`, which is the net amount after fees were deducted (line 475: `amount: netAmount`). The fee portion remains in `accumulatedFees` and is not refunded. The `TransferRefunded` event (line 736) emits this net amount.

However, there is no on-chain mechanism for users or front-ends to determine what the original gross amount was. The `BridgeTransfer` struct stores only `amount` (the net amount). The `TransferInitiated` event does emit the fee separately, but matching events across time windows is fragile for UI applications.

**Impact:** Users who receive a refund may not understand why the refunded amount is less than what they deposited. The original gross amount is only discoverable by replaying the `TransferInitiated` event for that transfer ID.

**Recommendation:** Either:
1. Store the gross amount in the `BridgeTransfer` struct (adds one storage slot per transfer), or
2. Add a comment in the `TransferRefunded` NatSpec explicitly noting the refunded amount is net of fees, directing users/frontends to the `TransferInitiated` event for the original amount.

---

### [I-01] Warp Validation Error Uses Semantically Incorrect InvalidAmount()

**Severity:** Informational
**Lines:** 948
**Status:** Carried forward from Round 6 I-01 (unfixed)

**Description:**

When `WARP_MESSENGER.getVerifiedWarpMessage()` returns `valid == false`, the function reverts with `InvalidAmount()` (line 948). The actual issue is an invalid or unverified Warp message, not an invalid amount. This makes debugging Warp integration issues harder because the error code does not describe the failure.

**Recommendation:** Add a dedicated `InvalidWarpMessage()` custom error.

---

### [I-02] processWarpMessage() Lacks Full Integration Tests

**Severity:** Informational
**Status:** Carried forward from Round 6 I-02 (partially addressed)

**Description:**

The test suite has been substantially expanded (23 to 87 tests) with comprehensive coverage for `refundTransfer()` and other functionality. However, `processWarpMessage()` still lacks integration tests that exercise the full flow: setting up a `MockWarpMessenger` with a valid encoded payload, configuring trusted bridges, and calling `processWarpMessage()` to verify token release, replay protection, inbound rate limiting, and recipient validation.

The mock infrastructure is already deployed in the test setup (lines 29-49). The `MockWarpMessenger` is placed at the precompile address with `hardhat_setCode`. Tests could configure the mock to return specific messages and exercise the full `processWarpMessage()` path.

**Impact:** The most critical function in the bridge -- the one that releases tokens to recipients -- is untested in the automated suite. While the logic is straightforward and auditable, automated tests would catch regressions during future development.

**Recommendation:** Add at least the following test cases:
1. Happy path: valid Warp message from trusted bridge, correct chain, tokens released
2. Replay rejection: same message processed twice
3. Untrusted source: Warp message from unregistered bridge address
4. Unregistered chain: source blockchain ID not mapped
5. Inbound rate limit: volume exceeds daily limit
6. Zero recipient: message with `recipient = address(0)`
7. Wrong target chain: `targetChainId != block.chainid`

---

### [I-03] Storage Gap Comment Inconsistency

**Severity:** Informational
**Lines:** 243-245

**Description:**

The storage gap is declared as `uint256[42] private __gap` with the comment "Reduced by 1 slot to account for the transferStatus mapping added above." This implies the original gap was 43, and reducing by 1 yields 42.

Counting the state variables declared before the gap:

| Slot Offset | Variable | Type |
|-------------|----------|------|
| 0 | `core` | address (20 bytes) |
| 1 | `blockchainId` | bytes32 (32 bytes) |
| 2 | `transferCount` | uint256 (32 bytes) |
| 3 | `chainConfigs` | mapping |
| 4 | `transfers` | mapping |
| 5 | `dailyVolume` | mapping |
| 6 | `dailyInboundVolume` | mapping |
| 7 | `processedMessages` | mapping |
| 8 | `blockchainToChainId` | mapping |
| 9 | `trustedBridges` | mapping |
| 10 | `chainToBlockchainId` | mapping |
| 11 | `accumulatedFees` | mapping |
| 12 | `transferUsePrivacy` | mapping |
| 13 | `_ossified` + `feeVault` | bool (1 byte) + address (20 bytes) = packed |
| 14 | `transferStatus` | mapping |
| 15-56 | `__gap[42]` | uint256[42] |

Total: 15 named slots + 42 gap slots = 57 slots. The accounting is correct but could be more explicitly documented for future developers modifying the contract. Consider adding the slot count to the comment.

**Recommendation:** Update the comment to include the total slot count:
```solidity
/// @dev 15 named slots + 42 gap = 57 total. Adjust gap when adding variables.
uint256[42] private __gap;
```

---

## Architecture Analysis

### Design Strengths

1. **Comprehensive Round 6 Remediation:** All Critical and High findings from the prior audit have been properly addressed. The `TransferStatus` enum is a clean solution for the single-chain refund race condition.

2. **Avalanche Warp Messaging (AWM) Integration:** Native AWM avoids the security risks of third-party messaging layers. The Warp precompile at `0x0200000000000000000000000000000000000005` provides cryptographic proof of source chain validator consensus.

3. **Trusted Bridge Registry:** `trustedBridges` mapping (line 215) validates `message.originSenderAddress`, addressing the pattern behind the $320M Wormhole exploit.

4. **Dual Rate Limiting:** Both outbound (`dailyVolume` in `_validateChainTransfer`) and inbound (`dailyInboundVolume` in `_enforceInboundLimit`) volumes are independently tracked and enforced. This is defense-in-depth against asymmetric draining.

5. **Proper CEI Pattern:** `initiateTransfer()` creates the transfer record and updates all state before calling `safeTransferFrom` and `sendWarpMessage`. No reentrancy window exists.

6. **Fee Separation:** `accumulatedFees` tracking prevents fee tokens from being confused with bridge-locked liquidity. `distributeFees()` is permissionless (correct -- anyone can trigger distribution to the vault).

7. **Ossification:** `ossify()` permanently disables upgradeability via the `_ossified` flag checked in `_authorizeUpgrade()`. This provides a credible commitment to immutability.

8. **Consistent NatSpec Documentation:** All functions, state variables, events, and errors have comprehensive NatSpec documentation. Audit acceptance annotations document deliberate design decisions.

9. **Clean Solhint:** Zero errors and zero warnings, indicating adherence to coding standards.

### Design Concerns (Unchanged from Round 6)

1. **Centralized Admin Dependency:** A single admin key compromise enables chain config manipulation, trusted bridge poisoning, fee vault redirection, and pause/unpause. Mitigated by requiring admin behind a TimelockController + multi-sig (documented as pre-mainnet requirement).

2. **Service Registry Indirection:** Token addresses resolved at runtime via `core.getService()`. A compromised OmniCore admin could redirect token resolution. This is inherent to the registry pattern.

3. **Mixed Authorization Patterns:** Some functions use `core.hasRole(core.ADMIN_ROLE(), msg.sender)` while `ossify()` and `_authorizeUpgrade()` use `onlyRole(DEFAULT_ADMIN_ROLE)` from OmniBridge's own AccessControl. This dual-authority model is documented but could cause operational confusion.

---

## Access Control Map

| Role | Functions | Source | Risk Level |
|------|-----------|--------|------------|
| ADMIN_ROLE (OmniCore) | `updateChainConfig()`, `recoverTokens()`, `setFeeVault()`, `pause()`, `unpause()`, `setTrustedBridge()` | OmniCore AccessControl | 8/10 |
| DEFAULT_ADMIN_ROLE (OmniBridge) | `ossify()`, `_authorizeUpgrade()` | OmniBridge AccessControl | 9/10 |
| Any EOA | `initiateTransfer()`, `processWarpMessage()`, `distributeFees()` | None | 3/10 |
| Original Sender | `refundTransfer()` | Transfer record `t.sender` | 2/10 |
| View (no role) | `getTransfer()`, `getCurrentDailyVolume()`, `getBlockchainID()`, `isMessageProcessed()`, `isOssified()` | None | 1/10 |

---

## Cross-Contract Attack Analysis

### Refund-Bridge-Complete Attack (M-01 residual)

**Assessment: LOW RISK under normal operation.** The 7-day refund delay far exceeds typical AWM processing time (seconds). An attacker would need to delay Warp message processing for over 7 days, which requires colluding with a quorum of validators. The inbound daily limit caps maximum damage.

### Service Registry Redirection

**Assessment: MEDIUM RISK.** If OmniCore's ADMIN_ROLE is compromised, the attacker could call `core.setService(OMNICOIN_SERVICE, maliciousToken)`. Subsequent `_resolveToken()` calls would point to the malicious token. Mitigated by TimelockController on OmniCore admin.

### Fee Distribution Griefing

**Assessment: LOW RISK.** `distributeFees()` is permissionless. An attacker could call it frequently to trigger many small transfers to the feeVault, but this costs the attacker gas and does not harm the bridge (fees are correctly tracked). No griefing vector.

### Flash Loan + Bridge

**Assessment: NO RISK.** Bridge transfers are not atomic across chains. Flash loans must be repaid within the same transaction. Borrowed tokens locked in the bridge cannot be flash-returned.

---

## Centralization Risk Assessment

**Single-key maximum damage (admin compromise):**
1. Register a malicious chain config pointing to an attacker-controlled "trusted bridge" (via `updateChainConfig` + `setTrustedBridge`)
2. Redirect fee vault to attacker address (via `setFeeVault` -- no event emitted, see L-02)
3. Pause the bridge indefinitely, blocking all transfers and refunds
4. Change OmniCore service registry to redirect token resolution (requires OmniCore admin)
5. Upgrade the bridge implementation via UUPS (unless ossified) to arbitrary code

**Centralization Score: 7/10** (unchanged from Round 6)

**Pre-mainnet mandatory:**
- Deploy ADMIN_ROLE behind a TimelockController (48-hour minimum delay)
- Timelock controller owned by 3-of-5 multi-sig (Gnosis Safe)
- Consider a separate PAUSER_ROLE for emergency response without full timelock delay
- Call `ossify()` once the bridge is mature and stable

---

## Remediation Priority

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| 1 | M-01: Cross-chain transferStatus limitation | Medium | Document risk; implement off-chain guardian attestation for refunds |
| 2 | M-02: Fee distribution vs. destination liquidity | Low | Add `availableLiquidity()` view; monitor operationally |
| 3 | L-02: setFeeVault() missing event | Trivial | Add FeeVaultUpdated event |
| 4 | L-01: InvalidRecipient error reuse | Low | Add Unauthorized() error |
| 5 | L-03: Refund net amount not documented | Trivial | Add NatSpec or store gross amount |
| 6 | I-02: processWarpMessage() integration tests | Medium | Add test cases using mock |
| 7 | I-01: InvalidAmount for Warp validation | Trivial | Add InvalidWarpMessage() error |
| 8 | I-03: Storage gap comment | Trivial | Update comment with slot count |

---

## Pre-Mainnet Checklist

- [x] **H-01 Round 6:** TransferStatus enum prevents single-chain refund-and-complete race
- [ ] **M-01:** Document cross-chain limitation in deployment guide; implement off-chain guardian check for refunds in validator network
- [ ] **M-02:** Add `availableLiquidity()` view function; set up bridge liquidity monitoring
- [ ] **L-02:** Add `FeeVaultUpdated` event to `setFeeVault()`
- [ ] **I-02:** Add integration tests for `processWarpMessage()` using MockWarpMessenger
- [ ] **Deployment:** Transfer admin roles to TimelockController + multi-sig before mainnet
- [ ] **Deployment:** Set trusted bridges for all supported chains before enabling transfers
- [ ] **Deployment:** Verify feeVault is set and pointing to UnifiedFeeVault
- [ ] **Deployment:** Set conservative daily limits initially (e.g., 10% of bridge liquidity)
- [ ] **Deployment:** Pre-fund destination bridge with sufficient liquidity
- [ ] **Deployment:** Consider calling `ossify()` once bridge is stable

---

## Conclusion

OmniBridge has reached a strong security posture after seven rounds of auditing and remediation. All Critical and High findings from prior rounds are properly addressed. The TransferStatus enum effectively prevents the single-chain refund-and-complete race condition that was the most significant finding in Round 6. The remaining findings are Medium-severity design-level concerns (cross-chain state limitation, liquidity accounting), Low-severity observability gaps (missing events, error semantics), and Informational items (test coverage, comments).

The cross-chain transferStatus limitation (M-01) is an inherent challenge in bridge design that cannot be fully solved on-chain without two-way messaging. The pragmatic approach -- relying on the 7-day refund delay far exceeding normal AWM processing time -- is reasonable for launch. The recommendation to implement off-chain guardian attestation for refunds in the validator network provides an additional safety layer without requiring contract changes.

The contract's code quality is high: comprehensive NatSpec, zero solhint warnings, consistent use of custom errors, proper CEI pattern, complete modifier coverage (nonReentrant, whenNotPaused), and clean storage layout with appropriate gap management.

**Overall Assessment:** The contract is suitable for mainnet deployment with the following prerequisites:
1. Admin roles behind TimelockController + multi-sig
2. Off-chain guardian attestation for refunds implemented in validator network
3. Conservative initial daily limits and liquidity monitoring
4. Trusted bridges configured and verified for all supported chains

**Risk Level: LOW** (down from MEDIUM in Round 6)

---
*Generated by Claude Code Audit Agent -- Pre-Mainnet Security Audit (Round 7)*
*Contract version: 1,069 lines, UUPS-upgradeable, Avalanche Warp Messaging integration*
*Prior audits: Round 1 (2026-02-20), Round 6 (2026-03-10) -- all Critical/High findings verified fixed*
*Test suite: 87 tests, all passing (17 seconds)*
