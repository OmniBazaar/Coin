# OmniBridge.sol -- Adversarial Security Review (Round 8)

**Date:** 2026-03-14
**Reviewer:** Adversarial Agent A1
**Contract:** `Coin/contracts/OmniBridge.sol` (1,192 lines, Solidity 0.8.24)
**Methodology:** Concrete exploit construction across 7 focus areas
**Prior Audit:** Round 7 (2026-03-13) -- 0 Critical, 0 High, 2 Medium, 3 Low, 3 Informational
**Dependencies Reviewed:** OmniCore.sol (service registry, ADMIN_ROLE), IWarpMessenger (Avalanche precompile), OmniForwarder.sol (ERC2771Forwarder), OpenZeppelin v5.x (UUPS, AccessControl, ReentrancyGuard, Pausable, ERC2771Context)

---

## Executive Summary

This adversarial review constructs **concrete, step-by-step exploits** against OmniBridge.sol across seven attack categories. The review goes beyond the Round 7 analysis by tracing each attack path through actual code to determine whether existing defenses block the exploit or leave residual risk.

**Result:** One **High**-severity finding was identified: a transfer ID namespace collision between locally-initiated transfers and inbound cross-chain transfers causes the `transferStatus` check to incorrectly block legitimate operations. Two **Medium**-severity findings were identified: (1) the fee vault timelock lacks a cancellation mechanism, leaving the only defense against a compromised admin key as a race to pause the contract; (2) `ossify()` and `_authorizeUpgrade()` are relayable via the ERC-2771 forwarder, contradicting the deliberate `msg.sender` pattern used by all other admin functions. Three **Low**-severity findings address inbound rate limit bypass via chain reconfiguration, service registry indirection enabling `recoverTokens()` bypass, and a fee accounting inflation vector.

| # | Attack Name | Severity | Attacker Profile | Confidence |
|---|-------------|----------|------------------|------------|
| 1 | TransferID Namespace Collision -- Cross-Chain Denial of Service | High | Any bridge user on a bidirectional bridge | HIGH |
| 2 | Fee Vault Timelock Without Cancellation -- Delayed Fee Theft | Medium | Compromised admin key | MEDIUM |
| 3 | ERC-2771 Forwarder-Mediated Ossification and Upgrade | Medium | Compromised forwarder operator | MEDIUM |
| 4 | Inbound Rate Limit Bypass via Chain Reconfiguration | Low | Compromised admin key | LOW |
| 5 | Service Registry Indirection Enables recoverTokens() Bypass | Low | Compromised OmniCore admin key | LOW |
| 6 | Accumulated Fee Inflation via Direct Token Transfer | Low | Any user with tokens | LOW |

---

### 1. TransferID Namespace Collision -- Cross-Chain Denial of Service

**Severity:** High
**Confidence:** HIGH
**Attacker Profile:** Any bridge user on a bidirectional deployment (no special privilege required)

**Root Cause:**

The `transferStatus` mapping (line 263) is a flat `mapping(uint256 => TransferStatus)` keyed solely by `transferId`. The `transferId` is a monotonically increasing counter (`transferCount`, line 214) local to each chain's OmniBridge deployment. When `processWarpMessage()` processes an inbound transfer from a remote chain, it reads and writes `transferStatus[transferId]` using the **remote chain's transfer ID** in the **local chain's storage** (lines 603-609).

This means the same `transferStatus[N]` slot is used for:
- Local transfers initiated via `initiateTransfer()` on this chain (which increment the local `transferCount`), AND
- Inbound transfers decoded from Warp messages (which carry the remote chain's `transferId`)

Since both chains independently start their `transferCount` at 0 and increment by 1, transfer IDs will inevitably collide.

**Step-by-Step Exploit:**

Scenario: Bidirectional bridge between Chain A and Chain B, both running OmniBridge.

1. **Chain A:** User Alice calls `initiateTransfer()` to bridge 1,000 XOM to Chain B. This is `transferId=1` on Chain A. `transferStatus[1]` on Chain A = PENDING (default). A Warp message is emitted containing `transferId=1`.

2. **Chain B:** User Bob calls `initiateTransfer()` to bridge 500 XOM to Chain A. This is `transferId=1` on Chain B. `transferStatus[1]` on Chain B = PENDING (default). A Warp message is emitted containing `transferId=1`.

3. **Chain B:** Alice's Warp message arrives. `processWarpMessage()` is called:
   - Line 594-596: `messageHash = keccak256(ChainA_BlockchainID, 1)`. Not in `processedMessages`. **Passes.**
   - Line 603: `transferStatus[1]` on Chain B is PENDING (it was set by Bob's local `initiateTransfer()`). **Passes.**
   - Line 609: `transferStatus[1]` on Chain B is set to COMPLETED.
   - Tokens released to Alice. **Success.**

4. **Chain B:** Bob now waits 7 days and tries to call `refundTransfer(1)` on Chain B for his own transfer:
   - Line 839: `transferStatus[1]` on Chain B is now COMPLETED (set in step 3 by Alice's inbound transfer).
   - **REVERTS with `TransferAlreadyCompleted`.** Bob cannot refund his own transfer.

5. **Alternative attack (blocking inbound):** If Bob refunds first (before Alice's Warp arrives):
   - Bob calls `refundTransfer(1)` after 7 days. `transferStatus[1]` on Chain B = REFUNDED.
   - Alice's Warp message arrives. `processWarpMessage()` checks line 603: `transferStatus[1] == REFUNDED`. **REVERTS with `TransferAlreadyRefunded`.**
   - Alice's legitimate inbound transfer is permanently blocked on Chain B.

**Impact:**

- **Denial of Service:** In a bidirectional bridge, every transfer ID on one chain has a corresponding transfer ID on the other chain. Any local operation (refund, completion) on that shared ID blocks the corresponding remote operation.
- **Permanent fund lock:** If an inbound Warp message is blocked because the local transfer with the same ID was refunded, the recipient's tokens are permanently locked on the destination bridge (the tokens were already deducted on the source chain). The sender can only reclaim via the 7-day refund on the source chain, but if the source-chain transfer was already completed by the Warp message flowing the other direction, the sender is also blocked.
- **No attacker cost:** This happens naturally in any bidirectional bridge deployment. An attacker can weaponize it by deliberately initiating and refunding transfers to block specific inbound transfer IDs.
- **Severity justification:** This is not a theoretical cross-chain timing issue like M-01 from Round 7. This is a deterministic storage collision that will occur in every bidirectional bridge deployment once both sides process transfers. It does not require attacker coordination, compromised keys, or timing manipulation.

**Code References:**
- `transferCount` counter: line 214
- `transferStatus` mapping (flat, no chain discrimination): line 263
- `initiateTransfer()` sets `transferId = ++transferCount`: line 517
- `processWarpMessage()` reads/writes `transferStatus[transferId]` using the remote chain's ID: lines 603-609
- `refundTransfer()` reads/writes `transferStatus[transferId]` using the local chain's ID: lines 839-849
- `processedMessages` correctly uses `(sourceChainID, transferId)`: lines 594-598 -- but `transferStatus` does not

**Existing Defenses:**
- `processedMessages` prevents replay of the same Warp message. However, it does NOT prevent the `transferStatus` collision because `processedMessages` uses a composite key `(sourceChainID, transferId)` while `transferStatus` uses just `transferId`.
- The Round 7 audit (M-01) identified the cross-chain limitation of `transferStatus` but focused on the timing race between refund and completion across chains. **The namespace collision is a distinct and more severe issue** because it is deterministic, not timing-dependent.

**Recommendation:**

The `transferStatus` mapping must be keyed by a composite identifier that distinguishes local transfers from remote inbound transfers. Two options:

**Option A (minimal change):** Use separate mappings for local and inbound status:
```solidity
mapping(uint256 => TransferStatus) public localTransferStatus;   // for initiateTransfer/refundTransfer
mapping(bytes32 => TransferStatus) public inboundTransferStatus;  // keyed by messageHash
```
In `processWarpMessage()`, check and set `inboundTransferStatus[messageHash]` instead of `transferStatus[transferId]`. In `refundTransfer()`, check and set `localTransferStatus[transferId]`.

**Option B (unified):** Key the mapping by a composite of chain source and transfer ID:
```solidity
// For local transfers: key = keccak256(blockchainId, transferId)
// For inbound transfers: key = keccak256(sourceChainID, transferId)
mapping(bytes32 => TransferStatus) public transferStatus;
```

Option A is recommended because it is cleaner and avoids any confusion between local and remote namespaces. The `processedMessages` mapping already provides replay protection for inbound messages, so the `inboundTransferStatus` check in `processWarpMessage()` could be removed entirely if the only purpose was replay prevention. However, keeping it is valuable for the cross-chain refund race scenario (M-01 from Round 7).

---

### 2. Fee Vault Timelock Without Cancellation -- Delayed Fee Theft

**Severity:** Medium
**Confidence:** MEDIUM
**Attacker Profile:** Compromised admin key (single key compromise)

**Root Cause:**

The fee vault timelock (FE-H-01 remediation) implements a propose-then-accept pattern with a 48-hour delay. However, there is no `cancelFeeVault()` function. Once a fee vault change is proposed, the only way to prevent it from being accepted is to:
1. Pause the contract (which does NOT block `acceptFeeVault()` since it has no `whenNotPaused` modifier), or
2. Revoke the admin's `ADMIN_ROLE` in OmniCore before the 48 hours elapse.

**Step-by-Step Exploit:**

1. Attacker compromises the admin key (e.g., phishing, key theft, or insider).
2. Attacker calls `proposeFeeVault(attackerAddress)`. The `feeVaultChangeTimestamp` is set to `block.timestamp`. The `pendingFeeVault` is set to the attacker's address.
3. The `FeeVaultChangeProposed` event is emitted, giving monitoring systems 48 hours to detect and respond.
4. After 48 hours, the attacker calls `acceptFeeVault()`. The `feeVault` is now the attacker's address.
5. The attacker (or anyone, since `distributeFees()` is permissionless) calls `distributeFees(xomAddress)`. All accumulated fees are sent to the attacker.
6. Future fees will also flow to the attacker until the vault is changed again.

**Impact:**
- All accumulated bridge fees are stolen. For a bridge processing significant volume, this could be substantial.
- The 48-hour window provides detection time, but the response options are limited without a cancel mechanism.

**Existing Defenses:**
- 48-hour timelock provides detection window.
- `FeeVaultChangeProposed` event enables monitoring.
- If the compromised key is revoked from `ADMIN_ROLE` in OmniCore within 48 hours, the attacker can no longer call `acceptFeeVault()`.
- The bridge can be paused, but `acceptFeeVault()` is NOT gated by `whenNotPaused`.

**Why MEDIUM (not HIGH):**
- The 48-hour delay is a meaningful defense.
- Fee accumulation is bounded (it's a percentage of bridge volume, not the bridge reserves themselves).
- The `recoverTokens()` function explicitly blocks recovery of XOM/pXOM, so the bridge reserves are not at risk -- only the fees.
- Revoking the admin role in OmniCore within 48 hours is a viable operational response.

**Recommendation:**

1. **Add a `cancelFeeVault()` function:**
```solidity
function cancelFeeVault() external {
    if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
        revert InvalidRecipient();
    }
    if (pendingFeeVault == address(0)) {
        revert NoFeeVaultChangePending();
    }
    pendingFeeVault = address(0);
    feeVaultChangeTimestamp = 0;
    emit FeeVaultChangeCancelled(feeVault);
}
```

2. **Gate `acceptFeeVault()` with `whenNotPaused`:** This ensures that pausing the bridge also blocks pending fee vault changes, providing a faster emergency response than revoking admin roles.

3. **Consider requiring a DIFFERENT admin address to accept** (separation of propose and accept authority). This makes single-key compromise insufficient to redirect fees.

---

### 3. ERC-2771 Forwarder-Mediated Ossification and Upgrade

**Severity:** Medium
**Confidence:** MEDIUM
**Attacker Profile:** Compromised ERC-2771 forwarder operator, or attacker with a valid admin forwarder signature

**Root Cause:**

OmniBridge uses two different authorization patterns for admin functions:

1. **Explicit `msg.sender` check** (lines 650, 705, 772, 798, 875, 889, 902): `core.hasRole(core.ADMIN_ROLE(), msg.sender)`. This deliberately bypasses the ERC-2771 forwarder, preventing meta-transaction relay of admin operations. Applied to: `updateChainConfig`, `recoverTokens`, `proposeFeeVault`, `acceptFeeVault`, `setTrustedBridge`, `pause`, `unpause`.

2. **`onlyRole(DEFAULT_ADMIN_ROLE)` modifier** (lines 917, 1143): Uses `_msgSender()` which resolves through `ERC2771ContextUpgradeable._msgSender()`. Applied to: `ossify()` and `_authorizeUpgrade()`.

This means **the two most critical admin functions** -- permanent ossification and UUPS upgrade authorization -- are relayable through the trusted forwarder, while all other admin functions are NOT.

**Step-by-Step Exploit:**

1. The OmniForwarder (ERC2771Forwarder) requires a valid EIP-712 signature from the admin to relay a call. Under normal operation, this is safe because the signature binds to the specific calldata and nonce.

2. However, if the forwarder contract itself has a vulnerability (e.g., a future OpenZeppelin library bug, or a constructor deployment error that allows arbitrary sender impersonation), an attacker could:
   - Call `ossify()` via the forwarder, **permanently** disabling upgrades (irreversible -- no recovery possible)
   - Call `upgradeToAndCall()` via the forwarder, upgrading the bridge to a malicious implementation

3. **Asymmetric risk:** Ossification is irreversible. A standard admin key compromise can be recovered from (revoke the key, deploy a new proxy), but a compromised forwarder triggering `ossify()` permanently locks the contract in its current state. If the current state has a bug, the bug becomes permanent.

4. **Scenario: Griefing ossification attack:**
   - Attacker exploits a forwarder vulnerability to call `ossify()` as the admin.
   - The bridge is permanently frozen in its current implementation.
   - If any bugs are discovered later, there is NO remediation path.
   - Unlike a key compromise (where admin can be transferred), ossification is permanent.

**Code References:**
- `ossify()` uses `onlyRole(DEFAULT_ADMIN_ROLE)` which calls `_msgSender()`: line 917
- `_authorizeUpgrade()` uses `onlyRole(DEFAULT_ADMIN_ROLE)` which calls `_msgSender()`: line 1143
- All other admin functions use `msg.sender` directly: lines 650, 705, 772, 798, 875, 889, 902
- `_msgSender()` override returns forwarder-appended sender: lines 1098-1105

**Existing Defenses:**
- OmniForwarder extends OpenZeppelin's `ERC2771Forwarder` which requires valid EIP-712 signatures with per-address nonces and deadlines.
- The forwarder cannot forge signatures without the admin's private key under normal circumstances.
- If the forwarder is compromised, `pause()` is still accessible via `msg.sender` (not through the forwarder).

**Why MEDIUM (not HIGH):**
- Exploiting the forwarder requires a bug in OpenZeppelin's ERC2771Forwarder, which is well-audited.
- The admin's private key is still required for valid signatures under normal operation.
- The risk is additive: the forwarder is an unnecessary trust dependency for these two specific functions.

**Recommendation:**

Change `ossify()` and `_authorizeUpgrade()` to use explicit `msg.sender` checks instead of `onlyRole()`:

```solidity
function ossify() external {
    // Critical: uses msg.sender to prevent forwarder relay (consistent with other admin functions)
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
        revert InvalidRecipient();
    }
    _ossified = true;
    emit ContractOssified(address(this));
}

function _authorizeUpgrade(
    address newImplementation
) internal view override {
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
        revert InvalidRecipient();
    }
    if (_ossified) revert ContractIsOssified();
    (newImplementation);
}
```

This aligns the most critical admin functions with the explicit `msg.sender` pattern already used by all other admin functions, eliminating the forwarder as a trust dependency for irreversible operations.

---

### 4. Inbound Rate Limit Bypass via Chain Reconfiguration

**Severity:** Low
**Confidence:** LOW
**Attacker Profile:** Compromised admin key

**Root Cause:**

`_enforceInboundLimit()` (lines 1015-1030) reads `chainConfigs[sourceChainId].dailyLimit` to check whether the inbound volume exceeds the limit. However, `updateChainConfig()` (line 635) can modify the `dailyLimit` at any time. A compromised admin can temporarily raise the daily limit to allow a massive inbound transfer, then restore the original limit.

**Step-by-Step Exploit:**

1. Attacker compromises admin key.
2. Attacker calls `updateChainConfig(chainId, ..., dailyLimit: type(uint256).max, ...)`.
3. Attacker processes a Warp message (real or from a compromised source chain) for an amount exceeding the original daily limit.
4. Attacker restores the original daily limit.
5. The inbound volume tracking (`dailyInboundVolume`) now shows a large value for today, but the limit is back to normal, so no more transfers can come in for the rest of the day.

**Impact:** Enables bypassing inbound rate limits, which are the last defense against draining bridge liquidity via forged or replayed cross-chain messages.

**Existing Defenses:**
- Requires admin key compromise (which already enables more direct attacks like trusted bridge manipulation).
- `ChainConfigUpdated` event provides monitoring trail.
- Timelocked admin makes this a 48+ hour operation (if deployed behind a timelock as recommended).

**Why LOW:** This requires admin compromise, which is already a high-trust failure. The admin can already set trusted bridges to point at attacker-controlled addresses, which is a more direct attack. Rate limit bypass is additive damage, not a new attack vector.

**Recommendation:**

Consider making `dailyLimit` changes subject to a timelock similar to `proposeFeeVault()` / `acceptFeeVault()`. Alternatively, enforce that `dailyLimit` can only be decreased immediately but increases require a delay.

---

### 5. Service Registry Indirection Enables recoverTokens() Bypass

**Severity:** Low
**Confidence:** LOW
**Attacker Profile:** Compromised OmniCore admin key (not OmniBridge admin)

**Root Cause:**

`recoverTokens()` (lines 699-718) blocks recovery of XOM and pXOM by checking:
```solidity
address xom = core.getService(OMNICOIN_SERVICE);
address pxom = core.getService(PRIVATE_OMNICOIN_SERVICE);
if (token == xom || token == pxom) revert CannotRecoverBridgeTokens();
```

These addresses are resolved dynamically from OmniCore's service registry at call time. If OmniCore's admin changes the service registry entry (e.g., sets `OMNICOIN_SERVICE` to a different address), the `recoverTokens()` check would compare against the new (wrong) address, allowing the real XOM token to be recovered.

**Step-by-Step Exploit:**

1. Attacker compromises OmniCore admin key.
2. Attacker calls `core.setService(OMNICOIN_SERVICE, 0xDEAD)` -- pointing OMNICOIN_SERVICE to a dummy address.
3. Attacker calls `bridge.recoverTokens(realXOMAddress, bridge.balance)`.
4. `recoverTokens()` checks `realXOMAddress == 0xDEAD` (false) and `realXOMAddress == pxom` (false). Check passes.
5. All real XOM tokens are transferred to the attacker.
6. Attacker restores the service registry: `core.setService(OMNICOIN_SERVICE, realXOMAddress)`.

**Impact:** Complete drain of bridge-locked XOM and pXOM reserves. This is Critical impact but requires OmniCore admin compromise, which is why it is rated Low for the OmniBridge-specific review.

**Existing Defenses:**
- Requires OmniCore admin compromise, not OmniBridge admin.
- OmniCore admin should be behind TimelockController + multisig.
- `ServiceUpdated` event on OmniCore provides monitoring trail.
- The two admin keys (OmniCore ADMIN_ROLE and OmniBridge DEFAULT_ADMIN_ROLE) may be different entities, providing separation of concerns.

**Why LOW for OmniBridge:** The vulnerability is in the trust relationship with OmniCore, not in OmniBridge itself. OmniBridge's design intentionally delegates token resolution to OmniCore. The fix would need to be in OmniCore (e.g., making service registry changes timelocked).

**Recommendation:**

Cache the XOM and pXOM addresses at initialization time and use the cached values in `recoverTokens()`:

```solidity
address private immutable _cachedXOM;   // set in constructor or initialize
address private immutable _cachedPXOM;  // set in constructor or initialize

function recoverTokens(address token, uint256 amount) external nonReentrant {
    // ... admin check ...
    // Use cached addresses -- immune to service registry manipulation
    if (token == _cachedXOM || token == _cachedPXOM) {
        revert CannotRecoverBridgeTokens();
    }
    // ... transfer ...
}
```

Since OmniBridge is upgradeable (UUPS), `immutable` cannot be used directly. Instead, set these in `initialize()` and store as regular state variables:

```solidity
address private _protectedXOM;
address private _protectedPXOM;

function initialize(address _core, address admin) external initializer {
    // ... existing init ...
    _protectedXOM = OmniCore(_core).getService(OMNICOIN_SERVICE);
    _protectedPXOM = OmniCore(_core).getService(PRIVATE_OMNICOIN_SERVICE);
}
```

---

### 6. Accumulated Fee Inflation via Direct Token Transfer

**Severity:** Low
**Confidence:** LOW
**Attacker Profile:** Any user with tokens (no special privilege)

**Root Cause:**

The `distributeFees()` function (lines 729-757) calculates the maximum distributable fees using the contract's current token balance:

```solidity
uint256 tokenBalance = IERC20(token).balanceOf(address(this));
uint256 lockedAmount = tokenBalance > fees ? tokenBalance - fees : 0;
uint256 availableForFees = tokenBalance > lockedAmount ? tokenBalance - lockedAmount : 0;
```

Simplifying: `lockedAmount = tokenBalance - fees` and `availableForFees = tokenBalance - lockedAmount = fees`. So `availableForFees` always equals `min(fees, tokenBalance)`. This means **any tokens held by the contract in excess of the tracked fee amount are treated as "locked" bridge reserves**.

If a user directly transfers tokens to the bridge contract (e.g., via `token.transfer(bridge, 1000)` without going through `initiateTransfer()`), those tokens increase `tokenBalance` but do NOT increase `accumulatedFees`. They become phantom "locked" reserves.

**Step-by-Step Scenario:**

1. Bridge has 10,000 XOM locked for pending transfers. `accumulatedFees[XOM] = 100`.
2. User directly sends 5,000 XOM to the bridge address (not via `initiateTransfer()`).
3. `tokenBalance = 15,000`. `lockedAmount = 15,000 - 100 = 14,900`. `availableForFees = 15,000 - 14,900 = 100`.
4. Fee distribution works correctly -- the directly-sent tokens don't inflate distributable fees.
5. However, the 5,000 XOM are now permanently locked in the bridge. They are treated as "bridge reserves" but correspond to no pending transfer. They can never be recovered (since `recoverTokens()` blocks XOM recovery).

**Impact:**
- The directly-sent tokens are permanently locked. This is a user error (sending tokens to a contract without using the proper function), but it creates a "token graveyard" effect.
- The locked tokens DO increase the bridge's capacity to release tokens on the destination side, which is actually a minor benefit (more liquidity). But the sender loses their tokens.
- No exploit vector against existing bridge users or reserves.

**Existing Defenses:**
- The fee distribution math is correct and does not allow over-distribution.
- `_releaseTokens()` balance check prevents releasing more than available.

**Why LOW:** This is primarily a user-error scenario. The bridge does not accept native ETH/AVAX (no `receive()` or `fallback()` function visible), so only ERC20 tokens can be accidentally sent. The locked tokens contribute to bridge liquidity, which is a net positive for the system even though the sender loses funds.

**Recommendation:**

Consider adding a `recoverExcessTokens()` function that allows admin to recover the difference between the contract's token balance and the tracked obligations (sum of all pending transfer amounts + accumulated fees):

```solidity
function recoverExcessTokens(address token) external nonReentrant {
    if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) revert InvalidRecipient();
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 obligations = _calculateObligations(token) + accumulatedFees[token];
    if (balance <= obligations) revert InvalidAmount();
    uint256 excess = balance - obligations;
    IERC20(token).safeTransfer(msg.sender, excess);
}
```

This requires tracking total obligations, which is currently not done (there is no running total of pending transfer amounts). This would need a new state variable.

---

## Investigated but Defended

### 7. Warp Message Replay Attack (Focus Area 1)

**Investigation:** Can an attacker replay a previously-processed Warp message?

**Trace:**
1. First processing: `processWarpMessage(0)` reads `WARP_MESSENGER.getVerifiedWarpMessage(0)`. The Warp precompile validates the BLS aggregate signature from the source chain's validator set.
2. `messageHash = keccak256(sourceChainID, transferId)` is computed (line 594-595).
3. `processedMessages[messageHash]` is checked and set to `true` (lines 597-598).
4. Second processing attempt with the same message: `processedMessages[messageHash]` is `true`. **REVERTS with `AlreadyProcessed`.**

**Cross-chain replay (same message on multiple destination chains):**
- The payload includes `targetChainId` (line 578). Line 591 checks `targetChainId != block.chainid`. An attacker cannot process a message on a chain it was not intended for.

**Different message index, same transfer:**
- The `processedMessages` key is `(sourceChainID, transferId)`, not `messageIndex`. Processing the same transfer from a different message index would hit the same `processedMessages` entry.

**Verdict:** Warp message replay is fully defended by the `processedMessages` mapping and `targetChainId` check. **Defended.**

---

### 8. Inbound Rate Limit Bypass via Multiple Small Transfers (Focus Area 2)

**Investigation:** Can an attacker bypass the daily inbound limit by splitting into small transfers?

**Trace:**
1. `_enforceInboundLimit()` (lines 1015-1030) tracks `dailyInboundVolume[sourceChainId][today]`.
2. Each call to `processWarpMessage()` adds `amount` to the daily volume: `dailyInboundVolume[sourceChainId][today] = currentInbound + amount` (line 1028-1029).
3. The check at line 1025: `if (currentInbound + amount > config.dailyLimit)` uses the cumulative volume.
4. Splitting 100,000 XOM into 100 transfers of 1,000 XOM each: each transfer adds 1,000 to the cumulative volume. After 100 transfers, the volume is 100,000. The 101st transfer would be blocked.

**Day boundary manipulation:**
- `today = block.timestamp / 1 days` (line 1021). An attacker sending at 23:59:59 and again at 00:00:00 would span two "days", effectively getting 2x the daily limit. This is a known limitation of daily-reset rate limiting, not a bypass of the mechanism itself.

**Verdict:** Cumulative tracking prevents splitting bypass. Day boundary transition allows 2x limit in edge cases. **Defended (with known day-boundary edge case).**

---

### 9. Cross-Chain Message Forgery (Focus Area 4)

**Investigation:** Can an attacker craft a fake bridge message?

**Trace:**
1. `_validateWarpMessage()` (lines 1064-1086) calls `WARP_MESSENGER.getVerifiedWarpMessage(messageIndex)`.
2. The Warp precompile verifies that the message was signed by the source chain's validator set with a sufficient weight threshold (typically 67% of stake weight).
3. `trustedBridges[message.sourceChainID]` must match `message.originSenderAddress` (lines 1074-1080). Even if an attacker controls a validator on the source chain and can emit a Warp message, the `originSenderAddress` in the message is the contract that called `WARP_MESSENGER.sendWarpMessage()`. Only the trusted bridge contract address on the source chain can be the origin.
4. `blockchainToChainId[message.sourceChainID]` must be non-zero (line 1083).

**Forge scenarios:**
- **Fake precompile:** The Warp precompile is at a fixed address (`0x0200000000000000000000000000000000000005`). Cannot be impersonated on a real Avalanche subnet.
- **Fake source chain validator set:** Would require controlling 67%+ of the source chain's stake weight.
- **Spoofed `originSenderAddress`:** This is set by the precompile based on `msg.sender` of the `sendWarpMessage()` call. Cannot be forged from a different contract.

**Verdict:** Cross-chain message forgery requires compromising the source chain's validator quorum AND deploying a malicious contract at the trusted bridge address on the source chain. **Defended by AWM's cryptographic guarantees.**

---

### 10. Token Minting/Burning Imbalance (Focus Area 5)

**Investigation:** Can bridge operations create tokens from nothing?

**Trace:**
- The bridge uses a **lock-and-release** model, not a **mint-and-burn** model. `initiateTransfer()` calls `token.safeTransferFrom(caller, address(this), amount)` -- tokens are locked in the bridge. `_releaseTokens()` calls `token.safeTransfer(recipient, amount)` -- tokens are released from the bridge's holdings.
- No `mint()` or `burn()` calls exist in OmniBridge.
- The bridge can only release tokens it actually holds. `_releaseTokens()` checks `balance < amount` (line 1053) before transferring.
- **Over-release check:** If the bridge holds 10,000 XOM and a Warp message requests 20,000 XOM release, line 1053 reverts with `InvalidAmount()`. The bridge cannot release more than its balance.
- **Under-lock scenario:** `initiateTransfer()` uses `safeTransferFrom` which reverts if the caller doesn't have sufficient balance or allowance.

**Verdict:** Lock-and-release model with balance checks prevents creation of tokens from nothing. **Defended.**

---

### 11. Emergency Function Blast Radius (Focus Area 6)

**Investigation:** What is the maximum damage from a compromised admin key?

**Single-key maximum damage (OmniCore ADMIN_ROLE compromise):**

| Action | Function | Impact | Reversible? |
|--------|----------|--------|-------------|
| Poison trusted bridge | `setTrustedBridge()` | Accept fake inbound messages → drain bridge reserves | Yes (update entry) |
| Raise rate limits | `updateChainConfig()` | Allow massive inbound drain | Yes (lower limits) |
| Redirect fee vault | `proposeFeeVault()` + 48h + `acceptFeeVault()` | Steal accumulated fees | Yes (propose new vault) |
| Pause bridge | `pause()` | Freeze all transfers and refunds indefinitely | Yes (`unpause()`) |
| Recover tokens | `recoverTokens()` | Drain non-XOM/pXOM tokens only | N/A (irreversible transfer) |

**Single-key maximum damage (OmniBridge DEFAULT_ADMIN_ROLE compromise):**

| Action | Function | Impact | Reversible? |
|--------|----------|--------|-------------|
| Ossify | `ossify()` | Permanently disable upgrades | **No** (irreversible) |
| Malicious upgrade | `upgradeToAndCall()` | Complete control of contract | Yes (upgrade again) |

**Combined worst case (both roles compromised, or same key holds both):**
1. Set trusted bridge to attacker-controlled address on a registered chain
2. Craft and relay a fake Warp message (via compromised source chain) draining all XOM/pXOM reserves
3. Redirect fee vault and claim fees
4. Upgrade to malicious implementation or ossify to prevent remediation

**Maximum total loss:** All bridge reserves + all accumulated fees + all non-operational tokens.

**Existing Defenses:**
- TimelockController + multisig (operational requirement, not enforced in code)
- Fee vault 48-hour timelock
- `recoverTokens()` blocks XOM/pXOM
- Events for all state changes enable monitoring

**Verdict:** Admin compromise is high-impact but mitigated by operational controls. The most dangerous single action is `setTrustedBridge()` which can drain reserves immediately without a timelock. **Known centralization risk -- addressed by operational deployment requirements.**

---

## Round 7 Open Findings Status

| Round 7 Finding | Status in Round 8 | Notes |
|----------------|-------------------|-------|
| M-01: Cross-chain transferStatus limitation | **SUPERSEDED by Finding #1** | The namespace collision (Finding #1) is a more severe manifestation of this design issue. M-01 described a timing race; Finding #1 describes a deterministic collision. |
| M-02: Fee distribution vs. destination liquidity | **Open (Operational)** | Still valid. No code change needed; requires operational monitoring. |
| L-01: InvalidRecipient error reuse | **Open** | Still uses `InvalidRecipient()` for both recipient validation and authorization failures. |
| L-02: setFeeVault missing event | **SUPERSEDED** | The `setFeeVault()` function has been replaced by the `proposeFeeVault()`/`acceptFeeVault()` timelock pattern, which does emit events (`FeeVaultChangeProposed`, `FeeVaultChangeAccepted`). |
| L-03: Refund emits net amount | **Open** | `BridgeTransfer.amount` still stores net amount only. |
| I-01: InvalidAmount for Warp validation | **Open** | Line 1071 still uses `InvalidAmount()` for invalid Warp messages. |
| I-02: processWarpMessage() lacks integration tests | **Open** | Still untested in the automated suite. |
| I-03: Storage gap comment inconsistency | **Open** | Gap comment now says "42 - 2 = 40" (line 277), which is correct for the current layout. |

---

## Findings Prioritized by Remediation Value

| Priority | Finding | Severity | Effort | Blocks Mainnet? |
|----------|---------|----------|--------|-----------------|
| 1 | #1: TransferID namespace collision | High | Medium (new mapping or composite key) | **YES -- deterministic failure in bidirectional bridge** |
| 2 | #3: Forwarder-mediated ossify/upgrade | Medium | Low (change modifier to msg.sender check) | Recommended |
| 3 | #2: Fee vault timelock missing cancel | Medium | Low (add cancelFeeVault function) | Recommended |
| 4 | #5: Service registry indirection in recoverTokens | Low | Low (cache token addresses) | No |
| 5 | #4: Inbound rate limit bypass via reconfig | Low | Medium (timelock for limit increases) | No |
| 6 | #6: Fee inflation via direct transfer | Low | Medium (track obligations) | No |

---

## Conclusion

OmniBridge has been significantly hardened through eight rounds of auditing. However, this adversarial review uncovered a **High-severity deterministic bug** (Finding #1) that was not identified in prior rounds: the `transferStatus` mapping uses a flat `uint256` key (the `transferId`), creating a namespace collision between local transfers and inbound cross-chain transfers. In any bidirectional bridge deployment, local and remote transfer IDs will collide, causing legitimate operations to be incorrectly blocked. This is not a timing race or edge case -- it is a deterministic failure that will occur as soon as both bridge endpoints process transfers.

**This finding blocks mainnet deployment.** The `transferStatus` mapping must be rekeyed to distinguish local transfers from inbound transfers (e.g., separate mappings or composite keys).

The two Medium findings (fee vault timelock without cancellation, and forwarder-mediated ossification) represent meaningful improvements to operational security but are not blocking. The Low findings document cross-contract trust dependencies and edge cases.

**Risk Level: MEDIUM** (elevated from Round 7's LOW due to Finding #1)

---

*Generated by Adversarial Agent A1 (Claude Opus 4.6)*
*Scope: OmniBridge.sol (1,192 lines) + OmniCore.sol (service registry, ADMIN_ROLE) + IWarpMessenger (Avalanche precompile) + OmniForwarder.sol (ERC2771)*
*Prior reports: Round 1 (2026-02-20), Round 6 (2026-03-10), Round 7 (2026-03-13)*
*Date: 2026-03-14*
