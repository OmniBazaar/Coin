# OmniCore.sol -- Adversarial Security Review (Round 8)

**Date:** 2026-03-14
**Reviewer:** Adversarial Agent A1
**Contract:** `Coin/contracts/OmniCore.sol` (1,438 lines, Solidity 0.8.24)
**Methodology:** Concrete exploit construction across 7 focus areas
**Prior Audit:** Round 7 (2026-03-13) -- 0 Critical, 0 High, 2 Medium, 4 Low, 5 Informational
**Dependencies Reviewed:** Bootstrap.sol, ValidatorProvisioner.sol, OmniForwarder.sol (ERC2771Forwarder), OpenZeppelin v5.4.0

---

## Executive Summary

This adversarial review attempts to construct **concrete, step-by-step exploits** against OmniCore.sol across seven attack categories identified in prior audits. The review goes beyond theoretical risk analysis by tracing each attack path through the actual code to determine whether existing defenses block the exploit or leave residual risk.

**Result:** No Critical or High-confidence exploits were found. The contract's defense-in-depth approach -- combining role-based access control, reentrancy guards, nonce tracking, ossification, pause capability, two-step admin transfer with 48-hour delay, and proper use of OpenZeppelin primitives -- closes all seven investigated attack paths. Two Medium-confidence findings were identified: (1) a trusted forwarder interaction with `onlyRole()` that allows meta-transaction relay of admin functions (by design, but increases attack surface if the forwarder is compromised), and (2) a DEX settlement disable bypass that is purely theoretical but worth documenting. Three Low-confidence findings relate to Bootstrap integration edge cases and staking checkpoint precision.

---

## Viable Exploits

| # | Attack Name | Severity | Attacker Profile | Confidence | Impact |
|---|-------------|----------|------------------|------------|--------|
| 1 | ERC-2771 Forwarder-Mediated Admin Relay | Medium | Compromised Forwarder Operator | MEDIUM | Admin function execution via forwarder |
| 2 | Bootstrap Stale-Data Validator Spoofing | Low | External contract / Malicious Bootstrap admin | LOW | Misleading `isValidator()` results |
| 3 | Legacy Claim Signature Grinding with Nonce Exhaustion | Info | Well-funded attacker with validator keys | LOW | Denial of service on legacy claims |

---

### 1. ERC-2771 Forwarder-Mediated Admin Relay

**Severity:** Medium
**Confidence:** MEDIUM
**Attacker Profile:** Compromised Forwarder contract or compromised admin key used through the forwarder relay

**Exploit Scenario:**

1. OmniCore inherits `ERC2771ContextUpgradeable` and overrides `_msgSender()` (line 1402-1408) to return the appended sender address when called through the trusted forwarder.

2. OpenZeppelin's `AccessControlUpgradeable._checkRole()` (used by the `onlyRole()` modifier) calls `_msgSender()` to determine the caller's identity. Since OmniCore overrides `_msgSender()` to use `ERC2771ContextUpgradeable._msgSender()`, **the trusted forwarder can relay calls to any `onlyRole(ADMIN_ROLE)` function** if it possesses a valid EIP-712 signature from the admin.

3. The following admin functions are callable via the forwarder:
   - `setService()` (line 636)
   - `setValidator()` (line 648)
   - `provisionValidator()` / `deprovisionValidator()` (lines 670, 686)
   - `setRequiredSignatures()` (line 700)
   - `setOddaoAddress()` / `setStakingPoolAddress()` / `setProtocolTreasuryAddress()` (lines 712, 725, 739)
   - `registerLegacyUsers()` (line 1168)
   - `pause()` / `unpause()` (lines 771, 779)
   - `ossify()` (line 521)
   - `disableDEXSettlement()` (line 761)
   - `_authorizeUpgrade()` / `upgradeToAndCall()` -- the UUPS upgrade path

4. **Attack vector:** If the OmniForwarder contract has a vulnerability (e.g., a bug in EIP-712 signature verification, or a future OZ library vulnerability), or if a validator relay service is compromised to replay/forge forwarder requests, an attacker could execute admin functions by submitting a meta-transaction that appears to come from the admin address.

5. The M-03 fix (using explicit `msg.sender` in `proposeAdminTransfer` and `acceptAdminTransfer`) only protects those two specific functions. All other admin functions rely on `onlyRole(ADMIN_ROLE)` which uses `_msgSender()`.

**Code References:**
- `_msgSender()` override: OmniCore.sol lines 1402-1408
- All `onlyRole(ADMIN_ROLE)` functions: lines 497, 511, 521, 636, 648, 700, 712, 725, 739, 761, 771, 779, 1168
- OmniForwarder.sol: line 42 (extends `ERC2771Forwarder`)
- AccessControlUpgradeable: `_checkRole()` calls `_msgSender()`

**Existing Defenses:**
- OmniForwarder extends OpenZeppelin's `ERC2771Forwarder` which requires a valid EIP-712 signature from the actual sender (the admin) with a per-address auto-incrementing nonce and deadline.
- A forwarder request can only be crafted if the attacker possesses the admin's private key, which is the same key needed to call admin functions directly.
- The forwarder is immutable and permissionless -- it has no admin functions that could be exploited.
- If the forwarder contract itself had a vulnerability, `pause()` and `ossify()` provide emergency mitigation.

**Why MEDIUM confidence (not HIGH):** The forwarder requires a valid admin signature, so this is not exploitable without the admin's private key *unless* the forwarder contract itself has a bug. The risk is that the forwarder adds an additional trust dependency to the admin's operational security. If the admin signs a forwarder request for a user-facing function (e.g., stake) and that request is intercepted, the relay infrastructure cannot pivot to call admin functions because the EIP-712 signature includes the target function calldata. However, this is one more system component in the trusted path.

**Recommendation:**
Consider adding explicit `msg.sender` checks (bypassing `_msgSender()`) to the most critical admin functions: `_authorizeUpgrade()`, `ossify()`, `setService()`, and `setValidator()`. This would harden these functions against forwarder compromise without affecting their usability, since admin operations should never be relayed through a forwarder anyway.

Example for `setService()`:
```solidity
function setService(bytes32 name, address serviceAddress) external {
    // M-03 pattern: admin functions must not be relayed
    if (!hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
    if (serviceAddress == address(0)) revert InvalidAddress();
    services[name] = serviceAddress;
    emit ServiceUpdated(name, serviceAddress, block.timestamp);
}
```

---

### 2. Bootstrap Stale-Data Validator Spoofing

**Severity:** Low
**Confidence:** LOW
**Attacker Profile:** Compromised Bootstrap admin, or a deactivated node operator

**Exploit Scenario:**

1. OmniCore's `isValidator()` (line 1057-1073) first checks `validators[validator]`, then falls back to Bootstrap.sol's `isNodeActive()`.

2. Bootstrap.sol allows **self-registration** (line 249: `registerNode()`, line 285: `registerGatewayNode()`). Any address can register as a gateway (type 0) or computation (type 1) node. There is no on-chain staking or qualification check in Bootstrap itself.

3. **Attack path A -- False positive:** An attacker self-registers as a gateway node in Bootstrap.sol. OmniCore's `isValidator()` would then return `true` for this address via the fallback path.

4. **Impact assessment:** The `isValidator()` function is a **view function**. It does NOT grant `AVALANCHE_VALIDATOR_ROLE`. The five deprecated DEX settlement functions (which are the only functions gated by `AVALANCHE_VALIDATOR_ROLE`) check `onlyRole(AVALANCHE_VALIDATOR_ROLE)`, not `isValidator()`. So a false positive in `isValidator()` cannot be leveraged to call any privileged OmniCore function.

5. However, external contracts that use `isValidator()` for authorization are affected:
   - `OmniValidatorRewards` (lines 906, 934, 972) uses `omniCore.isValidator(msg.sender)` and `omniCore.isValidator(validator)` for gate-keeping epoch processing and reward claims.
   - `OmniParticipation` (lines 709, 1193) uses `omniCore.isValidator(caller)` for service node and validator checks.
   - `OmniPriceOracle` (lines 558, 638) uses `omniCore.isValidator(msg.sender)` for oracle submission authorization.

6. **Concrete attack:** An attacker registers as a gateway node in Bootstrap (paying only gas). OmniPriceOracle's `submitPrice()` would then accept their price submissions, potentially manipulating oracle prices.

**Code References:**
- `isValidator()` fallback: OmniCore.sol lines 1057-1073
- Bootstrap self-registration: Bootstrap.sol lines 249-270, 285-311
- No qualification check in Bootstrap: `_registerNodeInternal()` (line 876) only checks `banned[msg.sender]`, `nodeType`, and string validations
- External consumers: OmniValidatorRewards.sol lines 906, 934, 972; OmniParticipation.sol lines 709, 1193; OmniPriceOracle.sol lines 558, 638

**Existing Defenses:**
- Bootstrap registration requires gas on C-Chain (cost barrier, but low).
- Bootstrap admin can ban nodes via `adminDeactivateNode()`.
- The `isValidator()` fallback is wrapped in a try/catch, so Bootstrap failures don't break OmniCore.
- OmniValidatorRewards has its own `MAX_VALIDATORS_PER_EPOCH` cap and epoch validation.
- The ValidatorProvisioner contract enforces real qualifications (KYC tier 4, 1M XOM stake, participation score >= 50) before granting AVALANCHE_VALIDATOR_ROLE through the direct mapping.

**Why LOW confidence:**
- The attack only works against external contracts that use `isValidator()` for authorization, not against OmniCore itself.
- The Bootstrap admin can quickly ban malicious registrations.
- For OmniPriceOracle, the oracle aggregation uses multiple price sources and TWAP windows, limiting single-submission manipulation.
- For OmniValidatorRewards, the reward distribution is based on `getActiveNodes()` which is bounded and processed per-epoch.

**Recommendation:**
External contracts that use `isValidator()` for write-access authorization should either:
1. Use `hasRole(AVALANCHE_VALIDATOR_ROLE, validator)` directly (checking the on-chain role, not the Bootstrap fallback), or
2. Add their own qualification checks beyond `isValidator()`.

Additionally, consider adding a minimum stake or registration fee to Bootstrap.sol to raise the cost of sybil registration.

---

### 3. Legacy Claim Signature Grinding with Nonce Exhaustion (Informational)

**Severity:** Informational
**Confidence:** LOW
**Attacker Profile:** Attacker with access to at least `requiredSignatures` validator keys

**Exploit Scenario:**

1. An attacker who controls `requiredSignatures` validator keys (which may be only 1 if `requiredSignatures` was set to 1 during initial deployment) can generate valid claim signatures for any legacy username.

2. The nonce is a `bytes32` value chosen by the submitter (line 1209). The `_usedClaimNonces` mapping (line 1216) tracks used nonces. There is no nonce ordering requirement -- any unused `bytes32` works.

3. **Attack path:** The attacker creates a valid claim for username "alice" to address X. The claim succeeds, and "alice"'s balance is transferred. The nonce is marked as used. However, `legacyClaimed[usernameHash]` is set to address X (line 1233), so a second claim for "alice" would fail at line 1223 (`legacyClaimed[usernameHash] != address(0)`).

4. **Defense verified:** The double-claim protection at line 1223 prevents replay even if different nonces are used. The nonce tracking at line 1216 prevents exact replay of the same signed message. Both defenses are needed and both are present.

5. **Residual risk:** The nonce is `bytes32` (2^256 possible values). There is no practical risk of exhaustion. However, if the contract were upgraded in the future to allow re-claiming (e.g., for balance corrections), the nonce tracking would still prevent signature replay.

**Code References:**
- Nonce check: OmniCore.sol line 1216
- Claim-once check: OmniCore.sol line 1223
- Signature verification: OmniCore.sol lines 1294-1330

**Existing Defenses:** Both `_usedClaimNonces` and `legacyClaimed` checks provide dual protection. The attack is fully defended.

**Recommendation:** No action needed. The dual-check pattern is correct and sufficient.

---

## Investigated but Defended

### 4. DEX Settlement Disable Bypass (Focus Area 4)

**Investigation:** Once `disableDEXSettlement()` is called (line 761), the `dexSettlementDisabled` flag is set to `true`. I investigated whether this could be reversed through:

- **UUPS upgrade:** An upgrade could theoretically reset `dexSettlementDisabled` to `false` by deploying a new implementation that either (a) modifies the storage slot directly, or (b) adds a new function to reset the flag. However, this requires `ADMIN_ROLE` and passes through `_authorizeUpgrade()`, which is the same trust level as calling `disableDEXSettlement()` in the first place. If the admin is behind a timelock/multisig (as required), this would be a 48-hour visible governance action.
- **Reinitialization:** The `reinitializer(N)` pattern prevents re-running initializers. A new `reinitializeV4()` or higher could be added in a future upgrade, but it would require a new implementation deployment (visible governance action).
- **Direct storage manipulation:** Not possible without an upgrade.

**Verdict:** The disable is irreversible within the current implementation. The only bypass is through a UUPS upgrade (which requires admin + timelock + multisig). This is the expected governance path for any contract change. **Defended by design.**

---

### 5. Service Registry Manipulation (Focus Area 5)

**Investigation:** `setService()` (line 636) allows `ADMIN_ROLE` to overwrite any service address. I investigated whether:

- A non-admin could call `setService()`: No -- `onlyRole(ADMIN_ROLE)` modifier.
- A provisioner could escalate: `PROVISIONER_ROLE` only has access to `provisionValidator()`/`deprovisionValidator()`, not `setService()`.
- A validator could escalate: `AVALANCHE_VALIDATOR_ROLE` only gates the deprecated settlement functions.
- The service registry could be used for self-referential privilege escalation: `services` is a simple `bytes32 => address` mapping used by external contracts for service discovery. OmniCore itself never reads from `services` internally. Overwriting a service address cannot affect OmniCore's own behavior.

**Verdict:** Service registry manipulation requires `ADMIN_ROLE`. There is no escalation path from lower roles. **Defended by role separation.**

---

### 6. Two-Step Admin Transfer Exploit (Focus Area 6)

**Investigation:** I attempted the following attacks on `proposeAdminTransfer()`/`acceptAdminTransfer()`:

- **Front-running `acceptAdminTransfer()`:** An attacker would need to call `acceptAdminTransfer()` as the `pendingAdmin`. Only the designated `pendingAdmin` address can call this function (line 592: `if (msg.sender != pendingAdmin)`). An attacker cannot front-run because they cannot become the `pendingAdmin` without the current admin calling `proposeAdminTransfer()` first.

- **Replay after cancellation:** If admin proposes transfer to X, then cancels, then proposes transfer to Y -- can X still accept? No. `cancelAdminTransfer()` (line 616-624) clears `pendingAdmin`, `adminTransferEta`, and `adminTransferProposer`. When admin proposes Y, `pendingAdmin` is set to Y. X calling `acceptAdminTransfer()` fails at line 592. **Defended.**

- **Multiple ADMIN_ROLE holders:** If both A and B hold `ADMIN_ROLE`, and A proposes transfer to X:
  - X accepts after 48h: A's roles are revoked (lines 605-606), X gets roles (lines 603-604). B retains ADMIN_ROLE.
  - This is correct behavior for multi-admin setups. The transfer only revokes from the proposer, not all admins.
  - B could cancel A's proposal using `cancelAdminTransfer()` (requires ADMIN_ROLE). This is a feature, not a bug.

- **48-hour delay bypass:** `block.timestamp < adminTransferEta` (line 594) cannot be bypassed. Block timestamps are set by consensus and cannot be manipulated by a single user.

- **`_msgSender()` vs `msg.sender` in accept:** `acceptAdminTransfer()` uses `msg.sender` explicitly (line 592), preventing forwarder relay. The new admin must call directly. **Defended by M-03 fix.**

**Verdict:** The two-step admin transfer is sound. All investigated attack paths are blocked. **Defended.**

---

### 7. UUPS Upgrade After Ossification (Focus Area 7)

**Investigation:** `ossify()` (line 521) sets `_ossified = true`. `_authorizeUpgrade()` (line 540-546) checks `if (_ossified) revert ContractIsOssified()`. In OpenZeppelin v5.4.0, `upgradeToAndCall()` calls `_authorizeUpgrade()` before performing the upgrade.

I investigated bypass paths:

- **Direct proxy manipulation:** The UUPS proxy's upgrade function is in the implementation, not the proxy. There is no admin-controllable proxy function that bypasses `_authorizeUpgrade()`.
- **Storage slot manipulation:** `_ossified` is a `bool private` at a specific storage slot. An attacker cannot modify it without an upgrade (which is blocked by the flag itself -- circular dependency).
- **Delegate call from another contract:** The UUPS `upgradeToAndCall` is called on the proxy, which delegates to the implementation's `_authorizeUpgrade`. No external contract can bypass this check.
- **`reinitializer()` does not bypass ossification:** Reinitializers only set state variables; they cannot modify the implementation address without going through `upgradeToAndCall`.

**Verdict:** Once `ossify()` is called, the contract is permanently non-upgradeable. There is no bypass path. **Defended.**

---

### 8. Staking Checkpoint Overflow (Focus Area 3)

**Investigation:** Staking checkpoints use `Checkpoints.Trace224` from OpenZeppelin:

- `SafeCast.toUint32(block.number)` (line 837): Reverts if `block.number > 2^32 - 1` (~4.29 billion). At 2-second blocks, this is ~272 years. Acceptable.
- `SafeCast.toUint224(amount)` (line 838): Reverts if `amount > 2^224 - 1` (~2.7e67). XOM total supply is 16.6 billion (1.66e28 in 18-decimal wei). No risk.
- `_stakeCheckpoints[caller].push()`: OpenZeppelin's `Trace224` uses a sorted array with binary search. The `push()` function requires that the new key (block number) is greater than or equal to the last key. Two stakes in the same block would work (the second overwrites the first). This is correct behavior.

**Tier boundary gaming:** I investigated whether an attacker could game tier boundaries:
- Tier 1: >= 1 XOM (1e18 wei). An attacker staking 999,999,999,999,999,999 wei (just under 1 XOM) with tier=1 would fail at `_validateStakingTier()` because `amount < tierMinimums[0]`.
- Tier 2 vs Tier 1: An attacker staking exactly 1,000,000 XOM with tier=1 would succeed (they meet the Tier 1 minimum). This is valid -- users can choose a lower tier even with higher amounts (they get a lower APR but also a lower participation score penalty on early withdrawal).
- **No enforcement that users must choose the highest applicable tier.** This is a business logic decision, not a security issue. The StakingRewardPool contract independently validates the tier via `_clampTier()`.

**Verdict:** No overflow or boundary gaming exploits. **Defended.**

---

### 9. Legacy Claim Replay with Different Nonces (Focus Area 2)

**Investigation:** Can `claimLegacyBalance()` be called twice for the same username with different nonces?

Step-by-step trace:
1. First call: `nonce = 0xaaa...`, signatures are valid.
   - Line 1216: `_usedClaimNonces[0xaaa...]` is `false`. Set to `true`.
   - Line 1222: `legacyUsernames[hash]` is `true` (registered).
   - Line 1223: `legacyClaimed[hash]` is `address(0)` (not yet claimed).
   - Line 1231-1233: `amount` is transferred, `legacyClaimed[hash] = claimAddress`.
   - **Claim succeeds.**

2. Second call: `nonce = 0xbbb...`, new valid signatures.
   - Line 1216: `_usedClaimNonces[0xbbb...]` is `false`. Set to `true`.
   - Line 1222: `legacyUsernames[hash]` is `true`.
   - Line 1223: `legacyClaimed[hash]` is `claimAddress` (NOT `address(0)`). **REVERTS with `InvalidAmount()`.**
   - **Second claim fails.**

**Verdict:** Double-claiming is prevented by the `legacyClaimed` check, independent of the nonce. **Defended.**

---

## Storage Gap Verification

Independent count of contract-declared state variables:

| Slot | Variable | Type |
|------|----------|------|
| 1 | `OMNI_COIN` | IERC20 (address, 20 bytes) |
| 2 | `services` | mapping(bytes32 => address) |
| 3 | `validators` | mapping(address => bool) |
| 4 | `masterRoot` (deprecated) | bytes32 |
| 5 | `lastRootUpdate` (deprecated) | uint256 |
| 6 | `stakes` | mapping(address => Stake) |
| 7 | `totalStaked` | uint256 |
| 8 | `dexBalances` | mapping(address => mapping(address => uint256)) |
| 9 | `oddaoAddress` | address |
| 10 | `stakingPoolAddress` | address |
| 11 | `legacyUsernames` | mapping(bytes32 => bool) |
| 12 | `legacyBalances` | mapping(bytes32 => uint256) |
| 13 | `legacyClaimed` | mapping(bytes32 => address) |
| 14 | `legacyAccounts` | mapping(bytes32 => bytes) |
| 15 | `totalLegacySupply` | uint256 |
| 16 | `totalLegacyClaimed` | uint256 |
| 17 | `requiredSignatures` | uint256 |
| 18 | `_ossified` | bool (private) |
| 19 | `_usedClaimNonces` | mapping(bytes32 => bool, private) |
| 20 | `_stakeCheckpoints` | mapping(address => Trace224, private) |
| 21 | `bootstrapContract` | address |
| 22 | `pendingAdmin` | address |
| 23 | `adminTransferEta` | uint256 |
| 24 | `adminTransferProposer` | address |
| 25 | `protocolTreasuryAddress` | address |
| 26 | `dexSettlementDisabled` | bool |
| 27-66 | `__gap[40]` | uint256[40] |

**Total: 26 variables + 40 gap = 66 slots.**

Note: The Round 7 audit (2026-03-13) counted 25 variables + 41 gap = 66 because `dexSettlementDisabled` was added after that audit. The comment on line 223 ("Reduced from 41 to 40: added dexSettlementDisabled") is correct.

---

## Cross-Contract Attack Surface Summary

| External Contract | OmniCore Interaction | Trust Level | Exploitable? |
|-------------------|---------------------|-------------|--------------|
| Bootstrap.sol | `isValidator()` fallback, `getActiveNodes()` | Read-only. Self-registration = low barrier. | **Low risk** -- see Finding #2. Bootstrap admin can ban bad actors. |
| OmniForwarder | `_msgSender()` override via ERC-2771 | Immutable. Signature-verified. | **Medium risk** -- see Finding #1. If forwarder is compromised, admin functions are exposed. |
| ValidatorProvisioner | `provisionValidator()` / `deprovisionValidator()` | PROVISIONER_ROLE gated. | **No** -- role is narrowly scoped. |
| OmniValidatorRewards | Reads `isValidator()`, `getActiveNodes()` | Read-only from OmniCore. | **Low risk** -- inherits Bootstrap spoofing risk. |
| OmniPriceOracle | Reads `isValidator()` for authorization | Uses `isValidator()` for write access. | **Low risk** -- inherits Bootstrap spoofing risk. |
| StakingRewardPool | Reads `getStake()` | Read-only from OmniCore. | **No** -- has independent tier validation. |
| OmniGovernance | Reads `getStakedAt()` | Read-only, snapshot-based. | **No** -- flash-loan protected by checkpoints. |

---

## Findings Prioritized by Remediation Value

| Priority | Finding | Severity | Effort | Blocks Mainnet? |
|----------|---------|----------|--------|-----------------|
| 1 | #1: Explicit `msg.sender` on critical admin functions | Medium | Low (pattern exists from M-03 fix) | Recommended |
| 2 | #2: Document Bootstrap `isValidator()` trust model for external consumers | Low | Trivial (NatSpec + docs) | No |
| 3 | #3: Legacy nonce exhaustion | Info | None needed | No |

---

## Conclusion

OmniCore.sol has been hardened through eight audit rounds. The adversarial review confirms that all seven primary attack vectors (bootstrap fallback manipulation, legacy claim replay, staking checkpoint overflow, DEX disable bypass, service registry manipulation, admin transfer exploits, and UUPS ossification bypass) are properly defended.

The two actionable findings are:

1. **ERC-2771 forwarder relay of admin functions** (Medium): While the current forwarder requires valid admin signatures (making this unexploitable without the admin key), adding explicit `msg.sender` checks on critical admin functions would eliminate the forwarder as a trust dependency for admin operations. This follows the same pattern already applied in the M-03 fix for `proposeAdminTransfer()` and `acceptAdminTransfer()`.

2. **Bootstrap self-registration as validator spoofing vector** (Low): External contracts (OmniValidatorRewards, OmniParticipation, OmniPriceOracle) that use `isValidator()` for write-access authorization inherit the Bootstrap self-registration risk. These contracts should consider using the direct `AVALANCHE_VALIDATOR_ROLE` check instead of the `isValidator()` view function.

The contract is suitable for mainnet deployment contingent on the operational requirements documented in prior audits (TimelockController + multi-sig behind ADMIN_ROLE).

---

*Generated by Adversarial Agent A1 (Claude Opus 4.6)*
*Scope: OmniCore.sol (1,438 lines) + Bootstrap.sol + ValidatorProvisioner.sol + OmniForwarder.sol*
*Cross-referenced: OmniValidatorRewards.sol, OmniParticipation.sol, OmniPriceOracle.sol, DEXSettlement.sol*
*Prior reports: Round 1 through Round 7 (2026-02-20 to 2026-03-13)*
*Date: 2026-03-14*
