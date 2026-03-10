# Security Audit Report: OmniCore.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniCore.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,369
**Upgradeable:** Yes (UUPS via `UUPSUpgradeable`)
**Handles Funds:** Yes (staked XOM, DEX-deposited tokens, unclaimed legacy migration tokens)
**Previous Audits:** Round 1 (2026-02-20), Round 5 V2/V3 (2026-03-09)

---

## Executive Summary

OmniCore.sol is the central hub contract for the OmniBazaar protocol, consolidating service registry, validator management, staking with governance checkpoints, deprecated DEX settlement, fee distribution, and legacy user migration. This Round 6 audit is a comprehensive pre-mainnet security review covering all vulnerability classes.

The contract has matured significantly since the Round 1 audit. Most Round 1 findings (H-02 staking tier validation, M-01 signature malleability, M-02 abi.encodePacked, M-03 fee-on-transfer, M-04 pause, M-05 initializeV2 ACL) have been remediated. The Round 5 audit's M-05 (two-step admin transfer) has been partially addressed via `proposeAdminTransfer/acceptAdminTransfer`.

**This audit identifies one HIGH severity finding (acceptAdminTransfer does not revoke the old admin's roles), three MEDIUM findings, three LOW findings, and four INFORMATIONAL items.**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | acceptAdminTransfer() does not revoke old admin | **FIXED** — old admin roles revoked |
| M-01 | Medium | Legacy claim signatures have no on-chain replay protection | **FIXED** |
| M-02 | Medium | DEX settlement functions deprecated but still callable | **FIXED** |
| M-03 | Medium | ERC2771 _msgSender() vs msg.sender inconsistency | **FIXED** |

---

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |
| Informational | 4 |

---

## Remediation Status from Prior Audits

| Prior Finding | Status | Notes |
|---------------|--------|-------|
| R1 H-01: No timelock on admin | **Mitigated (operational)** | NatSpec documents TimelockController requirement (lines 24-28). Not enforced in-contract. |
| R1 H-02: Staking tier/duration not validated | **Fixed** | `_validateStakingTier()` (line 1270) and `_validateDuration()` (line 1293) added with correct thresholds. |
| R1 M-01: Signature malleability | **Fixed** | `_recoverSigner()` (line 1314) now uses `ECDSA.recover()` from OpenZeppelin. |
| R1 M-02: abi.encodePacked with dynamic types | **Fixed** | `_verifyClaimSignatures()` (line 1233) now uses `abi.encode`. |
| R1 M-03: Fee-on-transfer in depositToDEX | **Fixed** | Balance-before/after pattern at lines 949-951. |
| R1 M-04: No pause mechanism | **Fixed** | `PausableUpgradeable` integrated; `whenNotPaused` on stake/unlock/deposit/withdraw/claim. |
| R1 M-05: initializeV2 no ACL | **Fixed** | `onlyRole(ADMIN_ROLE)` added to `initializeV2()` (line 445) and `reinitializeV3()` (line 459). |
| R1 L-01: Nonce not tracked | **Acknowledged** | See L-01 below (unchanged, mitigated by one-time-claim design). |
| R1 L-02: Zero-amount legacy claim | **Fixed** | `if (amount == 0) revert InvalidAmount();` at line 1163. |
| R1 L-05: Partial struct clearing | **Fixed** | All five fields zeroed in `unlock()` (lines 721-725). |
| R5 M-05: No two-step admin transfer | **Partially Fixed** | Two-step transfer implemented (lines 511-554) but does not revoke old admin. See H-01 below. |

---

## High Findings

### [H-01] acceptAdminTransfer() Grants Roles to New Admin but Does Not Revoke from Old Admin

**Severity:** High
**Category:** Access Control
**Location:** `acceptAdminTransfer()` (lines 527-541)

**Description:**

The two-step admin transfer mechanism (V3 M-05 fix) implements `proposeAdminTransfer()` and `acceptAdminTransfer()` with a 48-hour delay. However, `acceptAdminTransfer()` only grants `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` to the new admin -- it never revokes these roles from the previous admin. After the transfer completes, **both the old admin and the new admin hold full admin privileges simultaneously**.

```solidity
function acceptAdminTransfer() external {
    if (msg.sender != pendingAdmin) revert NotPendingAdmin();
    if (block.timestamp < adminTransferEta) {
        revert AdminTransferNotReady();
    }

    address oldAdmin = pendingAdmin;  // BUG: this is the NEW admin, not old
    pendingAdmin = address(0);
    adminTransferEta = 0;

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(ADMIN_ROLE, msg.sender);
    // MISSING: _revokeRole(DEFAULT_ADMIN_ROLE, <old admin>);
    // MISSING: _revokeRole(ADMIN_ROLE, <old admin>);
    emit AdminTransferAccepted(oldAdmin, msg.sender);
}
```

There are two bugs here:

1. **Missing revocation:** The old admin retains both `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE` after the transfer. This defeats the purpose of an admin transfer. If the admin transfer was triggered because the old admin key was compromised, the attacker retains full control even after the transfer completes.

2. **Incorrect event emission:** `address oldAdmin = pendingAdmin;` captures the *new* admin's address, not the old admin's address. The `AdminTransferAccepted` event emits `oldAdmin` and `msg.sender`, which are the same address (both are the pending/new admin). The actual old admin address is not tracked anywhere in the function.

**Impact:**

- An admin key rotation triggered by a suspected compromise does not actually remove the compromised key's privileges.
- The contract can accumulate an unbounded number of admin-privileged addresses over successive transfers.
- The `DEFAULT_ADMIN_ROLE` holder can also grant admin to arbitrary addresses via `grantRole()`, so the old admin can re-grant itself if somehow removed through other means.

**Exploit Scenario:**
1. Admin key A is compromised. Team proposes transfer to new admin B.
2. After 48 hours, B calls `acceptAdminTransfer()`.
3. B believes it is now the sole admin.
4. Attacker still holds key A with full `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE`.
5. Attacker upgrades contract to a malicious implementation and drains all funds.

**Recommendation:**

Store the proposing admin's address at proposal time. In `acceptAdminTransfer()`, revoke both roles from the old admin after granting to the new admin:

```solidity
// Add state variable:
address public adminTransferProposer;

function proposeAdminTransfer(address newAdmin) external onlyRole(ADMIN_ROLE) {
    if (newAdmin == address(0)) revert InvalidAddress();
    uint256 eta = block.timestamp + ADMIN_TRANSFER_DELAY;
    pendingAdmin = newAdmin;
    adminTransferEta = eta;
    adminTransferProposer = msg.sender;  // Track who proposed
    emit AdminTransferProposed(msg.sender, newAdmin, eta);
}

function acceptAdminTransfer() external {
    if (msg.sender != pendingAdmin) revert NotPendingAdmin();
    if (block.timestamp < adminTransferEta) revert AdminTransferNotReady();

    address oldAdmin = adminTransferProposer;
    pendingAdmin = address(0);
    adminTransferEta = 0;
    adminTransferProposer = address(0);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(ADMIN_ROLE, msg.sender);
    _revokeRole(ADMIN_ROLE, oldAdmin);
    _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

    emit AdminTransferAccepted(oldAdmin, msg.sender);
}
```

**Note on storage gap impact:** Adding `adminTransferProposer` requires reducing `__gap` from 44 to 43. Alternatively, repurpose the existing `pendingAdmin` slot by using a struct.

---

## Medium Findings

### [M-01] Legacy Claim Signatures Have No On-Chain Replay Protection Beyond One-Time Claim

**Severity:** Medium
**Category:** Signature Replay / Cryptographic Safety
**Location:** `claimLegacyBalance()` (lines 1141-1176), `_verifyClaimSignatures()` (lines 1225-1261)

**Description:**

The `nonce` parameter is included in the signed message hash but is **never stored or checked against previous uses on-chain**. The contract has no `mapping(bytes32 => bool) usedNonces` or similar tracking.

Replay protection relies entirely on the `legacyClaimed[usernameHash] != address(0)` check at line 1154, which works because each legacy username can only be claimed once. However, this design has a subtle issue:

The signature verification at line 1253 checks `validators[signer]`, meaning the signer must be a **current** validator. If a validator is removed and re-added, or if the validator set changes, previously-signed messages could potentially be reused. In the current one-time-claim design, replay is blocked by the `legacyClaimed` check, but the nonce creates a misleading security expectation.

More importantly, the nonce is dead code. If a future upgrade adds any claim-like function that reuses the signature scheme, the lack of nonce tracking becomes exploitable.

**Impact:** Low in current design (mitigated by one-time-claim). Medium risk if the signature scheme is reused in upgrades.

**Recommendation:**
Either:
- Remove the `nonce` parameter to reduce gas costs and eliminate the false sense of security, OR
- Add proper nonce tracking: `mapping(bytes32 => bool) private _usedNonces;` with `if (_usedNonces[nonce]) revert InvalidSignature(); _usedNonces[nonce] = true;`

---

### [M-02] DEX Settlement Functions Are Deprecated but Still Callable

**Severity:** Medium
**Category:** Business Logic / Attack Surface
**Location:** `settleDEXTrade()` (line 757), `batchSettleDEX()` (line 788), `distributeDEXFees()` (line 825), `settlePrivateDEXTrade()` (line 864), `batchSettlePrivateDEX()` (line 897)

**Description:**

Five DEX settlement functions are marked as `@deprecated` in NatSpec comments but remain fully callable by any address holding `AVALANCHE_VALIDATOR_ROLE`. The deprecation comment at line 742 says to use `DEXSettlement.sol` instead, but the functions themselves have no guard preventing use.

A validator with `AVALANCHE_VALIDATOR_ROLE` can still:

1. **Settle fraudulent trades** via `settleDEXTrade()`: Move tokens between arbitrary `dexBalances` entries. If a user has DEX balance (from a prior `depositToDEX()` call), a rogue validator can transfer those balances to any address.

2. **Fabricate fee distributions** via `distributeDEXFees()`: Credit arbitrary amounts to `oddaoAddress`, `stakingPoolAddress`, and any `validator` address. These are internal accounting entries in `dexBalances`, not actual token transfers, so this inflates the accounting without corresponding real tokens -- causing insolvency for later withdrawers.

3. **Emit misleading settlement events** via `settlePrivateDEXTrade()`: This function only emits events (no state changes), but could be used to create false audit trails.

The `dexBalances` accounting is shared between the deprecated functions and the still-active `depositToDEX()`/`withdrawFromDEX()` pair. A validator calling `distributeDEXFees()` with a large `totalFee` can inflate `dexBalances[oddaoAddress][token]` beyond the actual token balance held by the contract. If `oddaoAddress` then calls `withdrawFromDEX()`, the withdrawal succeeds but may consume tokens that belong to other users' balances.

**Exploit Scenario:**
1. User deposits 10,000 XOM via `depositToDEX()`.
2. Rogue validator calls `distributeDEXFees(XOM, 10000e18, validator)` -- no real fee was collected.
3. `dexBalances[oddaoAddress][XOM]` increases by 7,000 XOM (70%).
4. `dexBalances[stakingPool][XOM]` increases by 2,000 XOM (20%).
5. `dexBalances[validator][XOM]` increases by 1,000 XOM (10%).
6. Validator calls `withdrawFromDEX(XOM, 1000e18)` and receives 1,000 real XOM.
7. User's 10,000 XOM deposit is now only backed by 9,000 real XOM in the contract.

**Recommendation:**
Since `DEXSettlement.sol` is the intended replacement:
- Add `whenNotPaused` to all five settlement functions (they currently have no pause guard), OR
- Add a dedicated `dexSettlementEnabled` boolean that admin can set to `false` to permanently disable these functions, OR
- Mark the functions as reverting (`revert("deprecated")`) in a V4 upgrade once all migration is complete.

---

### [M-03] ERC2771 _msgSender() vs msg.sender Inconsistency in Admin Functions

**Severity:** Medium
**Category:** Access Control / Meta-transaction Safety
**Location:** `proposeAdminTransfer()` (line 519), `acceptAdminTransfer()` (line 528), all `onlyRole()` functions

**Description:**

The contract inherits `ERC2771ContextUpgradeable` which overrides `_msgSender()` to support gasless meta-transactions via a trusted forwarder. User-facing functions (`stake`, `unlock`, `depositToDEX`, `withdrawFromDEX`) correctly use `_msgSender()` to identify the caller.

However, `onlyRole()` from `AccessControlUpgradeable` internally calls `_msgSender()` (via the overridden `_msgSender`), which means **admin functions are also accessible via the trusted forwarder**. This is intentional by design in OpenZeppelin, but creates a risk:

1. `proposeAdminTransfer()` emits `msg.sender` at line 519 instead of `_msgSender()`. If called through the forwarder, `msg.sender` would be the forwarder address, not the actual admin. The event log would misidentify the proposer.

2. More critically, `acceptAdminTransfer()` checks `msg.sender != pendingAdmin` at line 528. If the pending admin accepts via the trusted forwarder, `msg.sender` would be the forwarder address, causing the check to fail. The pending admin **cannot accept an admin transfer through the forwarder**.

3. If the trusted forwarder were compromised, all admin functions become accessible since `onlyRole()` would resolve `_msgSender()` to the appended address, not the actual `msg.sender`.

**Impact:**
- Inconsistent behavior between `msg.sender` and `_msgSender()` in the admin transfer flow.
- Forwarder compromise would expose all admin operations.
- `acceptAdminTransfer()` is effectively un-relayable (must be called directly).

**Recommendation:**

For admin functions (especially the admin transfer), use `msg.sender` explicitly rather than `_msgSender()` to ensure they cannot be relayed through the forwarder. This is consistent with the principle that admin operations should require direct signing:

```solidity
function acceptAdminTransfer() external {
    // Use msg.sender explicitly -- admin operations must not be relayed
    if (msg.sender != pendingAdmin) revert NotPendingAdmin();
    // ...
}
```

Since `onlyRole()` uses `_msgSender()` internally (inheriting the ERC2771 override), consider adding an explicit `require(msg.sender == _msgSender(), "No relay")` guard to critical admin functions, or deploying with `trustedForwarder_ = address(0)` if meta-transactions are not needed for admin operations.

---

## Low Findings

### [L-01] Legacy Claim Nonce Not Tracked On-Chain (Pre-existing, Unchanged)

**Severity:** Low
**Category:** Replay Protection
**Location:** `claimLegacyBalance()` (line 1143), `_verifyClaimSignatures()` (line 1236)

**Description:**
The `nonce` parameter is included in the signature hash but never tracked on-chain. This is dead code. The one-time-claim design (`legacyClaimed` mapping) provides adequate replay protection for the current use case.

**Status:** Pre-existing from Round 1 L-01. Mitigated by design. Included for completeness.

**Recommendation:** Remove the `nonce` parameter or add tracking (see M-01).

---

### [L-02] Unbounded Batch Settlement Arrays (Pre-existing)

**Severity:** Low
**Category:** Denial of Service
**Location:** `batchSettleDEX()` (line 788), `batchSettlePrivateDEX()` (line 897)

**Description:**
Both batch functions iterate over caller-provided arrays with no upper bound. `registerLegacyUsers()` correctly caps at 100 entries (line 1111) but batch settlement functions do not. A validator could submit an excessively large batch that exceeds the block gas limit, causing the transaction to revert.

**Impact:** Low -- only validators can call these functions, and they would only harm themselves by wasting gas. No funds at risk.

**Recommendation:** Add `if (length > 500) revert InvalidAmount();` to both functions.

---

### [L-03] Storage Gap Arithmetic Should Be Verified with Tooling

**Severity:** Low
**Category:** Upgradeable Safety
**Location:** `__gap[44]` (line 199)

**Description:**
The storage gap comment at line 198 says "Reduced from 47 to 44: bootstrapContract + pendingAdmin + adminTransferEta." This implies the original gap was 47 and three new variables were added in V3. The arithmetic (47 - 3 = 44) is correct.

However, manual gap counting across multiple upgrade versions is error-prone. The actual storage layout depends on:
- Inherited contracts' storage usage (AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable)
- The ADMIN_TRANSFER_DELAY constant at line 501 (declared after the gap, but constants do not occupy storage slots)
- Whether `ERC2771ContextUpgradeable` uses any storage slots (it stores the `trustedForwarder` as an immutable in bytecode, not in storage)

If the fix for H-01 adds `adminTransferProposer`, the gap must be reduced to 43.

**Recommendation:**
- Run `npx @openzeppelin/upgrades-core validate` before deployment to verify storage layout compatibility between V2 and V3.
- Alternatively, use `forge inspect OmniCore storageLayout` to dump the actual slot assignments.
- Add a comment listing each V3 variable and its expected slot number for future auditors.

---

## Informational Findings

### [I-01] Flash-Loan Governance Attack Mitigated by Checkpoint Design

**Severity:** Informational
**Category:** DeFi / Flash-Loan Protection
**Location:** `stake()` (lines 697-701), `getStakedAt()` (lines 1073-1080)

**Description:**
The `_stakeCheckpoints` mapping uses OpenZeppelin's `Checkpoints.Trace224` with `push(block.number, amount)` in `stake()` and `upperLookup(blockNumber)` in `getStakedAt()`. This is used by `OmniGovernance` for snapshot-based voting power.

`upperLookup(key)` returns the value at the smallest checkpoint key >= the query key. This means if an attacker stakes in block N and queries `getStakedAt(N)`, the checkpoint at block N is found and returned. A flash-loan attacker who stakes and queries in the **same block** would see their stake reflected.

However, governance proposals in `OmniGovernance` use a **past block number** as the snapshot (the block when the proposal was created). An attacker would need to:
1. Know in advance that a proposal will be created at block N.
2. Flash-loan stake at block N or earlier.
3. Vote at block N+1 or later using the snapshot at block N.

Since proposal creation is not predictable to the exact block, and the attacker's stake would be recorded at the proposal-creation block (not before it), the governance system provides adequate flash-loan protection. The attacker would need to maintain the stake across multiple blocks, which defeats the purpose of a flash-loan.

**Status:** Not a vulnerability. The checkpoint system works as intended for governance snapshots.

---

### [I-02] Staking Does Not Support Topping Up or Changing Tiers

**Severity:** Informational
**Category:** Business Logic / UX
**Location:** `stake()` (line 675)

**Description:**
The `if (stakes[caller].active) revert InvalidAmount();` check at line 675 prevents a user from modifying an existing stake. To change tiers (e.g., from Tier 1 to Tier 2), a user must `unlock()` their current stake (after the lock period), then `stake()` again with the new parameters.

This is a design decision, not a vulnerability. However, it means:
- Users cannot top up their stake to reach a higher tier without unstaking first.
- Users with long lock periods (730 days) are locked into their tier for 2 years.
- Re-staking requires two transactions and potentially loses the lock-period bonus if the user wanted to upgrade mid-lock.

**Status:** Documented design constraint. No security risk.

---

### [I-03] Ossification Is Irreversible and Permanent (Correct Behavior)

**Severity:** Informational
**Category:** Access Control
**Location:** `ossify()` (lines 469-472), `_authorizeUpgrade()` (line 493)

**Description:**
Once `ossify()` is called by the admin, the `_ossified` flag is set to `true` and the contract can never be upgraded again. There is no un-ossify function. This is the correct design -- ossification is a one-way security guarantee that the contract logic is final.

The `_ossified` flag is stored as a `bool private` (line 176), which means it cannot be read by external contracts. The `isOssified()` view function (line 478) provides public access.

**Status:** Correct behavior. The irreversibility is intentional and beneficial for long-term trust.

---

### [I-04] Fee Distribution Dust Rounding Favors Validator (Accepted)

**Severity:** Informational
**Category:** Arithmetic
**Location:** `distributeDEXFees()` (lines 833-835)

**Description:**
The remainder pattern `validatorFee = totalFee - oddaoFee - stakingFee` gives any rounding dust (up to 2 wei) to the validator. This is standard and acceptable. For a 1 wei `totalFee`, the ODDAO and staking fees round to 0, and the validator gets the full 1 wei.

**Status:** Accepted behavior. Documented in Round 1 I-03.

---

## DeFi-Specific Analysis

### Flash-Loan Attacks

| Vector | Status | Details |
|--------|--------|---------|
| Stake + getStakedAt same block | **Mitigated** | Governance uses past-block snapshots. See I-01. |
| Stake + unlock same block | **Mitigated** | `duration=0` allows immediate unlock, but no economic benefit from staking for zero time. Checkpoints record zero at unstake block. |
| Flash-loan for legacy claim | **N/A** | Legacy claims require validator signatures, not stake-based. |

### Front-Running Attacks

| Vector | Status | Details |
|--------|--------|---------|
| Front-run legacy claims | **Mitigated** | Claims require validator M-of-N signatures with specific `claimAddress`. Changing `claimAddress` would require new signatures. |
| Front-run admin transfer | **Low risk** | 48-hour delay provides observation period. `cancelAdminTransfer()` allows admin to cancel. |
| Front-run staking | **N/A** | No benefit from front-running another user's stake. |

### Reentrancy

| Function | Guard | External Calls | Status |
|----------|-------|----------------|--------|
| `stake()` | `nonReentrant` | `safeTransferFrom` | **Safe** |
| `unlock()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `depositToDEX()` | `nonReentrant` | `safeTransferFrom`, `balanceOf` | **Safe** |
| `withdrawFromDEX()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `claimLegacyBalance()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `settleDEXTrade()` | None | None (no external calls) | **Safe** (internal accounting only) |
| `distributeDEXFees()` | None | None | **Safe** (internal accounting only) |

### Fee-on-Transfer Tokens

| Function | Status | Details |
|----------|--------|---------|
| `depositToDEX()` | **Fixed** | Balance-before/after pattern (lines 949-951) correctly handles fee-on-transfer tokens. |
| `stake()` | **Acceptable** | Uses `safeTransferFrom` with face-value `amount`. If XOM has fee-on-transfer, the contract would receive less than `amount` but record `amount` as staked. However, XOM (OmniCoin) is the project's own token with no fee-on-transfer mechanism, so this is acceptable. |

---

## Access Control Map

| Role | Functions | Guards | Risk |
|------|-----------|--------|------|
| `DEFAULT_ADMIN_ROLE` | `grantRole()`, `revokeRole()` (inherited) | OpenZeppelin ACL | 9/10 |
| `ADMIN_ROLE` | `_authorizeUpgrade()`, `setService()`, `setValidator()`, `setRequiredSignatures()`, `setOddaoAddress()`, `setStakingPoolAddress()`, `registerLegacyUsers()`, `pause()`, `unpause()`, `ossify()`, `initializeV2()`, `reinitializeV3()`, `proposeAdminTransfer()`, `cancelAdminTransfer()` | `onlyRole(ADMIN_ROLE)` | 8/10 |
| `AVALANCHE_VALIDATOR_ROLE` | `settleDEXTrade()`, `batchSettleDEX()`, `distributeDEXFees()`, `settlePrivateDEXTrade()`, `batchSettlePrivateDEX()` | `onlyRole(AVALANCHE_VALIDATOR_ROLE)` | 5/10 |
| None (self-service) | `stake()`, `unlock()`, `depositToDEX()`, `withdrawFromDEX()`, `claimLegacyBalance()` | `nonReentrant`, `whenNotPaused` | 2/10 |
| None (permissionless) | `acceptAdminTransfer()` | `msg.sender == pendingAdmin` | 7/10 |

---

## Centralization Risk Assessment

**Single-key maximum damage:** 8/10 (High Risk)

A compromised `ADMIN_ROLE` key can:
1. Upgrade the contract to arbitrary logic via UUPS (steal all funds instantly)
2. Add rogue validators for fraudulent DEX settlements
3. Register fraudulent legacy users to drain migration tokens
4. Lower `requiredSignatures` to 1
5. Change `oddaoAddress`/`stakingPoolAddress` to attacker-controlled addresses
6. Propose admin transfer to attacker address (with 48h delay, but old admin retains access per H-01)

**Funds at risk:** All staked XOM (`totalStaked`), all DEX-deposited tokens (`dexBalances`), all unclaimed legacy migration tokens.

**Mitigation (operational, documented in NatSpec):** Deploy a `TimelockController` (48h minimum delay) controlled by a 3-of-5 multi-sig as the `ADMIN_ROLE` holder. **This must be done before mainnet.**

---

## Signature Verification Deep Dive

### `_verifyClaimSignatures()` (lines 1225-1261)

| Check | Status | Details |
|-------|--------|---------|
| EIP-191 prefix | **Correct** | Uses `\x19Ethereum Signed Message:\n32` (line 1241) |
| Hash construction | **Correct** | Uses `abi.encode` (not `abi.encodePacked`) with chain ID and contract address (line 1233-1238) |
| Signature malleability | **Fixed** | Uses OZ `ECDSA.recover()` which rejects high-s values (line 1318) |
| Duplicate signer detection | **Correct** | O(n^2) loop (lines 1256-1258) is acceptable for MAX_REQUIRED_SIGNATURES=5 |
| Validator status check | **Correct** | `validators[signer]` check at line 1253 ensures signer is active validator |
| Nonce tracking | **Missing** | See M-01 |
| Cross-chain replay | **Protected** | `block.chainid` and `address(this)` in hash (lines 1237-1238) |
| Validator lookup uses mapping not Bootstrap | **Note** | Line 1253 checks `validators[signer]` (the direct mapping), NOT `isValidator()` (which falls back to Bootstrap). This means Bootstrap-registered validators cannot sign legacy claims unless they are also in the `validators` mapping via `setValidator()`. This is likely intentional -- legacy claims should require explicitly-authorized validators, not any Bootstrap registrant. |

---

## Storage Layout Verification

### Slot Counting (Manual)

The following state variables occupy storage slots in the order declared:

| Slot | Variable | Type | Size |
|------|----------|------|------|
| (inherited) | AccessControlUpgradeable | ~2 slots | OZ internal |
| (inherited) | ReentrancyGuardUpgradeable | 1 slot | OZ internal |
| (inherited) | PausableUpgradeable | 1 slot | OZ internal |
| (inherited) | UUPSUpgradeable | 1 slot | OZ internal |
| 1 | `OMNI_COIN` | address (IERC20) | 1 slot |
| 2 | `services` | mapping | 1 slot |
| 3 | `validators` | mapping | 1 slot |
| 4 | `masterRoot` (deprecated) | bytes32 | 1 slot |
| 5 | `lastRootUpdate` (deprecated) | uint256 | 1 slot |
| 6 | `stakes` | mapping | 1 slot |
| 7 | `totalStaked` | uint256 | 1 slot |
| 8 | `dexBalances` | nested mapping | 1 slot |
| 9 | `oddaoAddress` | address | 1 slot |
| 10 | `stakingPoolAddress` | address | 1 slot |
| 11 | `legacyUsernames` | mapping | 1 slot |
| 12 | `legacyBalances` | mapping | 1 slot |
| 13 | `legacyClaimed` | mapping | 1 slot |
| 14 | `legacyAccounts` | mapping | 1 slot |
| 15 | `totalLegacySupply` | uint256 | 1 slot |
| 16 | `totalLegacyClaimed` | uint256 | 1 slot |
| 17 | `requiredSignatures` | uint256 | 1 slot |
| 18 | `_ossified` | bool | 1 slot |
| 19 | `_stakeCheckpoints` | mapping | 1 slot |
| 20 | `bootstrapContract` | address | 1 slot (V3) |
| 21 | `pendingAdmin` | address | 1 slot (V3) |
| 22 | `adminTransferEta` | uint256 | 1 slot (V3) |
| 23-66 | `__gap[44]` | uint256[44] | 44 slots |

Contract-declared variables: 22 + 44 gap = 66 slots (excluding inherited). If the original gap was 47, then 22 - 3 (V3 additions) = 19 original variables, and 19 + 47 = 66. The math is consistent.

**Note:** The `ADMIN_TRANSFER_DELAY` constant at line 501 is a `uint256 public constant` and does NOT occupy a storage slot (stored in bytecode). Its placement after the gap declaration does not affect storage layout.

**Verification:** The `.openzeppelin/unknown-88008.json` file should contain the validated storage layout. Run `npx @openzeppelin/upgrades-core validate` before deployment.

---

## Remediation Priority

| Priority | Finding | Effort | Blocking for Mainnet? |
|----------|---------|--------|-----------------------|
| 1 | H-01: acceptAdminTransfer missing revocation | Medium (add state var, modify 2 functions, reduce gap) | **Yes** |
| 2 | M-02: Deprecated DEX settlement still callable | Low (add `whenNotPaused` or disable flag) | Recommended |
| 3 | M-03: msg.sender vs _msgSender() in admin transfer | Low (use msg.sender explicitly) | Recommended |
| 4 | M-01: Nonce dead code in legacy claims | Low (remove or add tracking) | No |
| 5 | L-02: Unbounded batch arrays | Low (add length cap) | No |
| 6 | L-03: Verify storage gap with tooling | Low (run OZ validate) | **Yes** |

---

## Known Exploit Cross-Reference

| Exploit / Advisory | Relevance | Finding |
|-------------------|-----------|---------|
| Ronin Bridge (2022, $625M): Single admin key compromise | H-01: Admin transfer does not revoke old admin | H-01 |
| OpenZeppelin UUPS Advisory (2021, $10M bounty): Unprotected initializer | Fixed (onlyRole on initializeV2/V3) | Remediated |
| ZABU Finance ($200K): Fee-on-transfer accounting | Fixed (balance-before/after in depositToDEX) | Remediated |
| Zunami Protocol (2025, $500K): Overpowered admin | Timelock operational requirement documented in NatSpec | Operational |
| SWC-117: Signature malleability | Fixed (OZ ECDSA.recover) | Remediated |
| SWC-133: abi.encodePacked hash collision | Fixed (abi.encode) | Remediated |

---

## Static Analysis Summary

### Slither
Slither analysis was attempted but failed due to build artifact sync issues (`/tmp/slither-combined.json` reports "source code appears to be out of sync with build artifacts"). The slither results file does not contain valid findings. Manual code review compensates for this gap.

### Solhint
No new warnings introduced since Round 5. Pre-existing `not-rely-on-time` suppressions are documented with business justifications throughout the contract.

---

## Conclusion

OmniCore.sol has matured significantly across six audit rounds. All High and Medium findings from Round 1 have been remediated. The Round 5 M-05 (two-step admin transfer) has been implemented but contains a critical bug (H-01: old admin retains roles after transfer) that must be fixed before mainnet deployment.

The contract's security posture is strong for user-facing operations (staking, DEX deposit/withdraw, legacy claims) with proper reentrancy guards, pausability, input validation, and signature verification. The primary remaining risks are:

1. **H-01 (admin transfer bug)** -- Must fix. The two-step admin transfer defeats its own purpose without role revocation.
2. **Operational deployment** -- The ADMIN_ROLE holder must be a TimelockController behind a multi-sig before mainnet.
3. **Deprecated DEX functions** -- Should be disabled or removed to reduce attack surface.

Once H-01 is fixed and the TimelockController is deployed, this contract is suitable for mainnet deployment.

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- 6-Pass Enhanced*
*Audit scope: All 1,369 lines of OmniCore.sol*
*Reference data: Prior audit rounds (R1, R5), 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents*
*Date: 2026-03-10 00:59 UTC*
