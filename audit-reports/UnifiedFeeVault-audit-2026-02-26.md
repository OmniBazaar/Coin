# Security Audit Report: UnifiedFeeVault

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/UnifiedFeeVault.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 430
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (multi-token fee aggregation, 70/20/10 distribution)

## Executive Summary

UnifiedFeeVault is a UUPS upgradeable fee aggregation contract that replaces the deprecated RWAFeeCollector. It collects ERC-20 fees from whitelisted depositor contracts (MinimalEscrow, DEXSettlement, RWAAMM, OmniFeeRouter, OmniYieldFeeCollector, OmniPredictionRouter) and splits them according to the documented 70/20/10 schedule: 70% ODDAO (held in vault for periodic bridging to Optimism), 20% StakingRewardPool (immediate transfer), and 10% Protocol Treasury (immediate transfer).

The contract is well-designed and addresses many of the critical issues found in the deprecated RWAFeeCollector (H-01 dead accounting, H-02 stranded tokens, H-03 fee split mismatch). The design is intentionally minimal with a small attack surface. The audit found **0 Critical, 0 High, 4 Medium, 3 Low, and 5 Informational** findings. The most material issues are: (1) RWAAMM sends fees via direct `safeTransferFrom` bypassing the `deposit()` gate, creating a two-path intake that weakens the DEPOSITOR_ROLE whitelist intent; (2) the `setRecipients()` function has no timelock, allowing immediate diversion of 30% of all future distributions; (3) no emergency token rescue mechanism for accidentally sent non-fee tokens; and (4) the `distribute()` function is DoS-vulnerable if either recipient contract reverts.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 4 |
| Low | 3 |
| Informational | 5 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 72 |
| Passed | 63 |
| Failed | 3 |
| Partial | 6 |
| **Compliance Score** | **87.5%** |

Top 3 failed checks:
1. **SOL-CR-4** -- `setRecipients()` changes take effect immediately with no timelock
2. **SOL-AM-DOSA-2** -- `distribute()` DoS if either recipient contract reverts
3. **SOL-Defi-AS-9** -- No fee-on-transfer token handling in `distribute()`

---

## Design Review: Improvements Over RWAFeeCollector

Before detailing findings, it is worth documenting how UnifiedFeeVault explicitly addresses the three High findings from the deprecated RWAFeeCollector:

| RWAFeeCollector Finding | How UnifiedFeeVault Addresses It |
|---|---|
| **H-01**: AMM bypasses `collectFees()`, all accounting is dead code | UnifiedFeeVault uses `balanceOf()` for distributable calculation, not internal accounting. Direct transfers and `deposit()` calls both work correctly. No dead code. |
| **H-02**: Non-XOM tokens permanently stranded, no conversion | UnifiedFeeVault is UUPS upgradeable. A future upgrade can add token rescue or conversion. The `distribute()` function works per-token, so non-XOM tokens can be distributed to the same 70/20/10 recipients. |
| **H-03**: Fee split 66.67%/33.33% doesn't match documented 70/20/10 | UnifiedFeeVault correctly implements 70/20/10 with `ODDAO_BPS=7000`, `STAKING_BPS=2000`, remainder to protocol. Verified by test suite (11 mathematical correctness tests). |

---

## Medium Findings

### [M-01] RWAAMM Bypasses deposit() -- DEPOSITOR_ROLE Whitelist Partially Ineffective

**Severity:** Medium
**Category:** SC01 Access Control / SC02 Business Logic
**VP Reference:** VP-06 (Access Control Gap)
**Location:** `deposit()` (line 233-243), RWAAMM.sol (line 481-483)

**Description:**

The RWAAMM contract sends its fee portion (the 30% collector fee) directly to the UnifiedFeeVault via `safeTransferFrom(msg.sender, FEE_VAULT, collectorFee)`. This bypasses the `deposit()` function entirely, meaning:

1. The `DEPOSITOR_ROLE` whitelist does not gate RWAAMM fee inflows
2. No `FeesDeposited` event is emitted for RWAAMM-originated fees
3. Monitoring systems tracking `FeesDeposited` events will undercount total fee intake

However, the `distribute()` function uses `IERC20(token).balanceOf(address(this))` to calculate the distributable amount (line 263), so the 70/20/10 split still functions correctly for directly transferred tokens. This is a transparency and audit-trail issue, not a fund-loss issue.

The test suite explicitly validates this behavior in "Direct Token Transfer" tests (line 947-966), confirming it is a known and intentional design decision. The deployment script also grants DEPOSITOR_ROLE to RWAAMM (line 188-189) even though RWAAMM never calls `deposit()`.

**Impact:** Incomplete on-chain audit trail. Fee dashboard accuracy reduced for RWAAMM-sourced fees. DEPOSITOR_ROLE grant to RWAAMM is wasted gas.

**Recommendation:**

Option A (preferred): Modify RWAAMM to call `vault.deposit(token, amount)` instead of direct transfer. This requires RWAAMM to approve the vault first (two-step), which is architecturally heavier but provides complete audit trails.

Option B: Accept the dual-path design. Remove DEPOSITOR_ROLE grant for RWAAMM in the deployment script. Add documentation that RWAAMM fees arrive via direct transfer and are tracked by `Transfer` events rather than `FeesDeposited`.

Option C: Add a `receive()` or `notifyFees(token, amount)` function that emits `FeesDeposited` without pulling tokens, callable by anyone. RWAAMM calls this after its direct transfer.

---

### [M-02] setRecipients() Has No Timelock -- Immediate Diversion of 30% of Fee Flow

**Severity:** Medium
**Category:** SC01 Access Control / Centralization Risk
**VP Reference:** VP-06 (Missing Timelock)
**Location:** `setRecipients()` (lines 339-350)

**Description:**

The `setRecipients()` function allows `ADMIN_ROLE` to immediately change both `stakingPool` and `protocolTreasury` addresses. The next `distribute()` call will send 30% of all accumulated fees (20% staking + 10% protocol) to the new addresses. There is no timelock delay, no multi-sig requirement, and no two-step confirmation.

A compromised `ADMIN_ROLE` key can:
1. Call `setRecipients(attackerAddress1, attackerAddress2)`
2. Call `distribute(xomToken)` (permissionless, or wait for someone else to call it)
3. Receive 30% of all undistributed fees immediately

The remaining 70% (ODDAO share) stays in the vault, protected by `BRIDGE_ROLE`. So the maximum single-tx damage is 30% of the current undistributed balance, not the entire vault.

**Mitigating Factor:** The `transfer-admin-to-timelock.js` script handles transferring `ADMIN_ROLE` to a TimelockController for all AccessControl contracts. However, UnifiedFeeVault is **not listed** in the `accessControlContracts` array (lines 72-81), so the admin transfer will NOT include this contract unless the script is updated.

**Impact:** If deployed without adding UnifiedFeeVault to the timelock transfer script, a single compromised deployer key can redirect 30% of fee flow.

**Recommendation:**

1. Add UnifiedFeeVault to the `accessControlContracts` array in `scripts/transfer-admin-to-timelock.js`
2. Consider adding an internal two-step pattern to `setRecipients()`:

```solidity
address public pendingStakingPool;
address public pendingProtocolTreasury;
uint256 public recipientChangeTimestamp;
uint256 public constant RECIPIENT_CHANGE_DELAY = 48 hours;

function proposeRecipients(address _stakingPool, address _protocolTreasury)
    external onlyRole(ADMIN_ROLE) { ... }

function executeRecipientChange() external onlyRole(ADMIN_ROLE) {
    if (block.timestamp < recipientChangeTimestamp + RECIPIENT_CHANGE_DELAY)
        revert TooEarly();
    ...
}
```

---

### [M-03] DoS if StakingPool or ProtocolTreasury Reverts on Token Receive

**Severity:** Medium
**Category:** SC09 Denial of Service
**VP Reference:** VP-30 (DoS via Unexpected Revert)
**Location:** `distribute()` (lines 282-289)

**Description:**

The `distribute()` function transfers tokens to both `stakingPool` and `protocolTreasury` using `safeTransfer`. If either recipient is a contract that reverts on receiving the token (e.g., a paused pool, a contract that blacklists the vault's address, or a contract with a `receive()` that reverts), the entire `distribute()` call fails. No fees can be split until the blocking recipient is fixed.

Unlike the deprecated RWAFeeCollector (which used immutable recipient addresses), the UnifiedFeeVault has `setRecipients()` as an escape hatch. An admin can change the blocking address to a working one. However, if `ADMIN_ROLE` has been transferred to a timelock, the 48-72 hour delay (plus proposer/executor coordination) means fees accumulate undistributed during the incident, increasing the value at risk.

**Impact:** Temporary DoS on fee distribution. Undistributed fees accumulate in the vault, increasing the bridge-to-treasury attack surface proportionally.

**Recommendation:**

Implement a pull pattern or fallback quarantine:

```solidity
mapping(address => mapping(address => uint256)) public pendingClaims;

function distribute(address token) external nonReentrant whenNotPaused {
    // ... calculate shares ...

    pendingBridge[token] += oddaoShare;
    totalDistributed[token] += distributable;

    // Try push; quarantine on failure
    if (stakingShare > 0) {
        try IERC20(token).transfer(stakingPool, stakingShare) {
        } catch {
            pendingClaims[stakingPool][token] += stakingShare;
        }
    }
    // Similar for protocolShare
}

function claimPending(address token) external nonReentrant {
    uint256 amount = pendingClaims[msg.sender][token];
    if (amount == 0) revert NothingToClaim();
    pendingClaims[msg.sender][token] = 0;
    IERC20(token).safeTransfer(msg.sender, amount);
}
```

---

### [M-04] No Emergency Token Rescue Function

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-57 (Stuck Tokens)
**Location:** Contract-wide (absent feature)

**Description:**

The contract has no mechanism to recover tokens sent accidentally (wrong token, wrong amount, or tokens sent directly without a corresponding `deposit()` call from a non-DEPOSITOR address). While `distribute()` picks up directly transferred tokens for known fee tokens, there are scenarios where tokens become unrecoverable:

1. **Non-ERC20 tokens** (e.g., ERC-721 NFTs accidentally sent) are permanently locked.
2. **Tokens sent after ossification** where no upgrade path exists to add a rescue function.
3. **Fee tokens with `pendingBridge` accounting drift**: If a token's balance increases from an external source (airdrop, rebasing token) and that increase is included in the next `distribute()`, the 70% ODDAO share is overstated relative to actual fee revenue.

The deprecated RWAFeeCollector audit (M-04) specifically recommended against immutable contracts without rescue mechanisms. The UnifiedFeeVault is upgradeable, which mitigates this partially, but post-ossification there is no escape.

**Impact:** Tokens sent accidentally after ossification are permanently locked. Pre-ossification, an upgrade can add rescue, but this requires deploying a new implementation contract.

**Recommendation:**

Add a minimal rescue function restricted to `DEFAULT_ADMIN_ROLE`:

```solidity
error CannotRescuePendingToken(address token, uint256 pendingAmount);

function rescueToken(address token, uint256 amount, address recipient)
    external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
{
    if (token == address(0) || recipient == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    // Prevent rescuing tokens that have pending bridge obligations
    uint256 vaultBalance = IERC20(token).balanceOf(address(this));
    uint256 committed = pendingBridge[token];
    if (amount > vaultBalance - committed)
        revert CannotRescuePendingToken(token, committed);

    IERC20(token).safeTransfer(recipient, amount);
    emit TokensRescued(token, amount, recipient);
}
```

This is safer than the StakingRewardPool's `emergencyWithdraw()` (which could drain the reward token itself -- H-01 in that audit) because it enforces `amount <= balance - pendingBridge`, preventing withdrawal of committed ODDAO funds.

---

## Low Findings

### [L-01] Fee-on-Transfer Tokens Cause Balance Mismatch in deposit()

**Severity:** Low
**Category:** SC10 Token Integration
**VP Reference:** VP-46 (Fee-on-Transfer)
**Location:** `deposit()` (lines 233-243)

**Description:**

The `deposit()` function calls `safeTransferFrom(msg.sender, address(this), amount)` and emits `FeesDeposited(token, amount, depositor)` with the original `amount`, not the actual received amount. For fee-on-transfer (FOT) tokens, the vault receives fewer tokens than `amount`, causing the event to overstate the deposit.

The `distribute()` function is not affected because it uses `balanceOf()` directly. The discrepancy is limited to event data used by off-chain indexers.

**Impact:** Off-chain accounting discrepancy for FOT tokens. No on-chain fund loss.

**Recommendation:**

Either document that FOT tokens are not supported, or measure actual received:

```solidity
uint256 balBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balBefore;
emit FeesDeposited(token, actualReceived, msg.sender);
```

---

### [L-02] distribute() Vulnerable to Front-Running for MEV Extraction

**Severity:** Low
**Category:** SC02 Business Logic / MEV
**VP Reference:** VP-34 (Front-Running)
**Location:** `distribute()` (lines 258-292)

**Description:**

Because `distribute()` is permissionless, a bot can monitor the vault's token balance and front-run large deposits by calling `distribute()` immediately after a large fee deposit but before any other pending deposits arrive. This does not cause direct fund loss (the 70/20/10 split is deterministic), but it allows MEV bots to:

1. **Earn gas refunds** on Avalanche by being the transaction that clears accumulated fees
2. **Manipulate the timing** of staking pool funding (relevant if staking rewards have per-epoch accounting)

The permissionless design is intentional and documented in the NatSpec ("encourages timely fee processing without relying on a centralized caller"), and the MEV extraction is trivially small on Avalanche with 1-2 second block times.

**Impact:** Negligible. MEV value is limited to gas refunds. No fund loss.

**Recommendation:** Accept as a design trade-off. The permissionless design is the correct choice for a decentralized protocol. If timing of staking pool funding becomes sensitive, consider a minimum cooldown between `distribute()` calls.

---

### [L-03] Storage Gap Miscounted -- 47 Slots Reserved, Only 3 State Variables Used

**Severity:** Low
**Category:** SC10 Upgrade Safety
**VP Reference:** VP-42 (Upgrade Safety)
**Location:** `__gap` (line 111)

**Description:**

The contract has 3 explicit state variable slots:
- `stakingPool` (slot 1 -- address = 1 slot)
- `protocolTreasury` (slot 2 -- address = 1 slot)
- `pendingBridge` (slot 3 -- mapping = 1 slot)
- `totalDistributed` (slot 4 -- mapping = 1 slot)
- `totalBridged` (slot 5 -- mapping = 1 slot)
- `_ossified` (slot 6 -- bool = 1 slot, packed)
- `__gap` (47 slots)

Total: 6 explicit slots + 47 gap = 53 slots. The conventional target for upgradeable contracts is 50 slots total (to simplify cross-contract upgrades). This contract uses 53, which is not incorrect but deviates from the OpenZeppelin convention.

A more precise gap would be `uint256[44] private __gap` (6 + 44 = 50). However, since this is a standalone contract with no inheritance chain requiring slot alignment, the 47-slot gap is functionally safe and provides generous headroom.

**Impact:** No functional impact. Provides 47 slots for future state variables, which is ample.

**Recommendation:** Document the slot budget above `__gap`: "Reduce by N when adding N new state variables. Current usage: 6 slots."

---

## Informational Findings

### [I-01] FeesDistributed Event Missing protocolShare Parameter

**Location:** Event definition (lines 127-135), emission (line 291)

**Description:**

The `FeesDistributed` event includes `oddaoShare` and `stakingShare` but not `protocolShare`. While `protocolShare` can be derived (`distributable - oddaoShare - stakingShare`), off-chain indexers must know the `distributable` amount (from the preceding state or from block receipts) to compute it. Including `protocolShare` explicitly would simplify indexing.

Additionally, the event does not include the `distributable` total amount, making it harder for indexers to verify the split.

**Recommendation:**

```solidity
event FeesDistributed(
    address indexed token,
    uint256 oddaoShare,
    uint256 stakingShare,
    uint256 protocolShare
);
```

Note: changing event signatures is a breaking change for existing indexers. If the contract is not yet deployed, this is the right time to adjust.

---

### [I-02] ADMIN_ROLE Is Redundant with DEFAULT_ADMIN_ROLE for This Contract

**Location:** Lines 82-83, 214-215, 342, 356, 363

**Description:**

The contract defines `ADMIN_ROLE = keccak256("ADMIN_ROLE")` and grants it to the `admin` address during initialization alongside `DEFAULT_ADMIN_ROLE`. Both roles are assigned to the same address. The only functions gated by `ADMIN_ROLE` are `setRecipients()`, `pause()`, and `unpause()`. The functions gated by `DEFAULT_ADMIN_ROLE` are `ossify()` and `_authorizeUpgrade()`.

This two-role design is intentionally separation-of-concerns: `ADMIN_ROLE` for day-to-day operations vs `DEFAULT_ADMIN_ROLE` for irreversible actions (upgrade, ossification). However, `DEFAULT_ADMIN_ROLE` is the role-admin for all roles (including `ADMIN_ROLE`), so any holder of `DEFAULT_ADMIN_ROLE` can grant themselves `ADMIN_ROLE` at any time, making the separation advisory rather than binding.

**Recommendation:** Accept as a valid pattern. The separation serves a documentation purpose (which functions are "routine" vs "nuclear") even if it does not provide cryptographic separation. Ensure both roles are transferred to the timelock (see M-02).

---

### [I-03] Ossification Has No Confirmation Step

**Location:** `ossify()` (lines 372-375)

**Description:**

The `ossify()` function permanently and irreversibly disables all future upgrades in a single transaction. There is no two-step confirmation (propose/confirm), no timelock delay, and no "undo" period. An accidental or malicious call to `ossify()` permanently locks the contract at its current implementation, preventing:

1. Bug fixes
2. Addition of new features (e.g., token rescue, new fee recipients)
3. Migration to a new fee distribution model

This is an acknowledged design feature (documented in NatSpec: "Cannot be undone. Use only when the fee vault logic has been battle-tested"). However, given that the contract has never been deployed, premature ossification would be damaging.

**Recommendation:** Consider a two-step ossification:

```solidity
uint256 public ossificationRequestedAt;

function requestOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
    ossificationRequestedAt = block.timestamp;
    emit OssificationRequested(msg.sender);
}

function confirmOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (ossificationRequestedAt == 0) revert NoOssificationRequested();
    if (block.timestamp < ossificationRequestedAt + 7 days) revert TooEarly();
    _ossified = true;
    emit ContractOssified(msg.sender);
}

function cancelOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
    ossificationRequestedAt = 0;
    emit OssificationCancelled(msg.sender);
}
```

---

### [I-04] Constructor Silences Unused Variable Warning via Explicit Cast

**Location:** `_authorizeUpgrade()` (line 428)

**Description:**

```solidity
function _authorizeUpgrade(
    address newImplementation
) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_ossified) revert ContractIsOssified();
    (newImplementation); // silence unused variable warning
}
```

The `(newImplementation);` expression is a common Solidity pattern to suppress the "unused parameter" warning. However, OpenZeppelin's UUPS documentation recommends validating the new implementation address (e.g., checking it has code deployed):

```solidity
if (newImplementation.code.length == 0) revert InvalidImplementation();
```

This prevents upgrading to an address with no deployed code, which would brick the proxy.

**Recommendation:** Add a code-existence check on `newImplementation`, or use `require(newImplementation != address(0))` as a minimal guard.

---

### [I-05] Deployment Script Grants DEPOSITOR_ROLE to RWAFeeCollector (Deprecated)

**Location:** `scripts/deploy-unified-fee-vault.js` (lines 191-194)

**Description:**

The deployment script grants `DEPOSITOR_ROLE` to `contracts.rwa.RWAFeeCollector` if present in the deployment config. RWAFeeCollector is deprecated and superseded by UnifiedFeeVault itself. Granting DEPOSITOR_ROLE to the deprecated contract is unnecessary and creates a wider attack surface -- if the deprecated contract is compromised, it could call `deposit()` with arbitrary token/amount.

**Recommendation:** Remove `RWAFeeCollector` from the `feeContracts` list in the deployment script. It should not have DEPOSITOR_ROLE on the contract that replaces it.

---

## Static Analysis Summary

### Solhint

0 errors, 0 warnings.

The contract passes solhint cleanly with no findings. This is an improvement over the OmniFeeRouter (4 warnings) and RWAFeeCollector (12 warnings).

### Slither / Aderyn

Skipped -- full-project analysis exceeds timeout (>3 minutes for Slither) and Aderyn v0.6.8 is incompatible with solc v0.8.33 (compiler crash). Known limitation across all audits in this series.

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `ossify()`, `_authorizeUpgrade()`, `grantRole()`, `revokeRole()` | 9/10 |
| `ADMIN_ROLE` | `setRecipients()`, `pause()`, `unpause()` | 6/10 |
| `BRIDGE_ROLE` | `bridgeToTreasury()` | 5/10 |
| `DEPOSITOR_ROLE` | `deposit()` | 2/10 |
| Anyone | `distribute()`, `undistributed()`, `pendingForBridge()`, `isOssified()` | 1/10 |

---

## Centralization Risk Assessment

**Centralization Rating: 6/10 (Medium)**

**Single-key maximum damage (DEFAULT_ADMIN_ROLE):**
1. Upgrade contract to malicious implementation (steal all tokens)
2. Grant self ADMIN_ROLE, change recipients, call distribute (steal 30%)
3. Grant self BRIDGE_ROLE, bridge pending ODDAO funds to attacker (steal 70%)
4. Ossify contract prematurely (permanent lock-in)

**Single-key maximum damage (ADMIN_ROLE only):**
1. Change recipients to attacker addresses, wait for next distribute (steal 30%)
2. Pause/unpause to manipulate timing of distributions

**Single-key maximum damage (BRIDGE_ROLE only):**
1. Bridge pending ODDAO funds to an attacker-controlled bridge receiver (steal accumulated 70%)

**Mitigating Factors:**
- `BRIDGE_ROLE` can only withdraw up to `pendingBridge[token]`, not the entire balance
- `ADMIN_ROLE` cannot steal the 70% ODDAO share (requires BRIDGE_ROLE)
- Pausing blocks all operations including the admin's own ability to distribute
- UUPS upgrade requires `DEFAULT_ADMIN_ROLE` specifically, not `ADMIN_ROLE`
- Contract has ossification as permanent upgrade lock-in

**Time to exploit:** Immediate (no timelock). See M-02 for recommendation.

**Recommendation:** Transfer `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, and `BRIDGE_ROLE` to a TimelockController with minimum 48-hour delay. Add UnifiedFeeVault to the `accessControlContracts` array in `transfer-admin-to-timelock.js`. Use a multi-sig for the timelock proposer role.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Zunami Protocol | 2025-05 | $500K | Admin `withdrawStuckToken()` drains pool -- M-04 discusses the absence of rescue function |
| Popsicle Finance | 2021-08 | $20M | Fee distribution logic flaw in multi-token vault -- UnifiedFeeVault's per-token tracking is correct |
| Cream Finance v1 | 2021-10 | $130M | Token balance manipulation in lending pool -- distribute() uses balanceOf() but with pendingBridge guard |
| Balancer/STA | 2020 | ~$500K | Fee-on-transfer token broke pool accounting -- L-01 in this audit |

---

## Solodit Similar Findings

| Finding | Protocol | Severity | Relevance |
|---------|----------|----------|-----------|
| No timelock on admin parameter changes | Multiple Cyfrin audits | Medium | Exact match -- M-02 |
| DoS via reverting recipient | Pashov Resolv L-08 | Medium | Exact match -- M-03 |
| Fee-on-transfer token incompatibility | Foundry DeFi Stablecoin (CodeHawks 2023) | Medium | Analogous -- L-01 |
| Missing rescue function in upgradeable vault | Alchemix (CodeHawks 2024) | Low | Exact match -- M-04 |
| Event missing computed field | Multiple CodeHawks | Info | Analogous -- I-01 |

---

## Test Coverage Assessment

The existing test suite (`test/UnifiedFeeVault.test.js`, ~40 tests) provides excellent coverage:

| Area | Tests | Coverage |
|------|-------|----------|
| Initialization | 8 | Complete (roles, recipients, zero-address, double-init, BPS constants) |
| Deposit | 5 | Complete (access control, events, zero guards, multiple deposits) |
| Distribute | 8 | Complete (70/20/10 split, permissionless, events, totalDistributed, NothingToDistribute, pendingBridge exclusion, sequential, dust/rounding) |
| Bridge | 7 | Complete (transfer, pendingBridge reduction, totalBridged, events, partial, access control, overflow guard) |
| View Functions | 4 | Complete (undistributed, pendingForBridge, zero states) |
| Admin | 6 | Complete (setRecipients, events, access control, zero guards, distribution after change) |
| Pausable | 6 | Complete (pause/unpause, blocked operations, access control) |
| Ossification | 4 | Complete (ossify, events, access control, upgrade block) |
| Multi-token | 2 | Adequate (independent XOM/USDC tracking, independent bridging) |
| UUPS Upgrade | 3 | Complete (authorized upgrade, unauthorized revert, state preservation) |
| Math Correctness | 2 | Excellent (8 edge-case amounts including 1 wei and 3 wei rounding) |
| Direct Transfer | 1 | Adequate (bypass deposit(), distribute still works) |

**Missing test coverage:**
- Fee-on-transfer token behavior (L-01)
- Recipient contract that reverts on receive (M-03)
- Concurrent deposit + distribute race condition
- Ossification followed by rescue attempt (M-04)
- Rebasing token behavior

---

## Remediation Priority

| Priority | ID | Finding | Effort |
|----------|----|---------|--------|
| 1 | M-02 | setRecipients no timelock + missing from admin transfer script | Low (update script) |
| 2 | M-03 | DoS if recipient reverts | Medium (pull pattern) |
| 3 | M-04 | No emergency token rescue | Low (add function) |
| 4 | M-01 | RWAAMM bypasses deposit() | Low (documentation or RWAAMM update) |
| 5 | I-05 | Deployment script grants role to deprecated contract | Low (remove line) |
| 6 | I-01 | Event missing protocolShare | Low (add parameter) |
| 7 | I-04 | No code-existence check on upgrade target | Low (add check) |
| 8 | L-01 | FOT token mismatch in deposit() | Low (add balance check or document) |
| 9 | L-03 | Storage gap documentation | Low (add comment) |
| 10 | L-02 | distribute() MEV | None (accept trade-off) |
| 11 | I-02 | ADMIN_ROLE redundancy | None (accept pattern) |
| 12 | I-03 | Ossification no confirmation | Medium (add two-step) |

---

## Conclusion

UnifiedFeeVault is a well-architected replacement for the deprecated RWAFeeCollector. It correctly addresses all three High findings from the predecessor contract. The 70/20/10 fee split is mathematically verified across edge cases including dust amounts and 1-wei deposits. The DEPOSITOR_ROLE whitelist, pausability, reentrancy protection, and ossification support demonstrate security-conscious design.

The contract's primary risk is **centralization**: three roles (`DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `BRIDGE_ROLE`) are all granted to the same deployer address at initialization, with no timelock. The `transfer-admin-to-timelock.js` script does not yet include UnifiedFeeVault in its contract list, meaning role transfer to the timelock requires a manual update to the script. This is the highest priority remediation.

The absence of an emergency token rescue function (M-04) is notable given the ossification feature. Once ossified, any accidentally sent tokens are permanently locked. Adding a rescue function that respects `pendingBridge` commitments before ossification would provide a critical safety valve.

**Overall assessment:** The contract is suitable for deployment on testnet after addressing M-02 (add to timelock transfer script). For mainnet deployment, M-03 (DoS protection) and M-04 (rescue function) should also be resolved.

---

*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
