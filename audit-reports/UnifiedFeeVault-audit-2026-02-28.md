# Security Audit Report: UnifiedFeeVault

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/UnifiedFeeVault.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1258
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (all protocol fees)

## Executive Summary

UnifiedFeeVault is the central fee collection and distribution contract for all OmniBazaar markets. It aggregates fees from MinimalEscrow, DEXSettlement, RWAAMM, and other fee-generating contracts, splitting them 70/20/10 (ODDAO/Staking/Protocol). The audit identified 1 Critical, 3 High, 5 Medium, 4 Low, and 2 Informational findings. The most severe issues involve accounting errors where `pendingClaims` are not subtracted from distributable balance, and an admin rescue function that can drain user-claimable funds.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 4 |
| Informational | 2 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 128 |
| Passed | 108 |
| Failed | 7 |
| Partial | 13 |
| **Compliance Score** | **84.4%** |

**Top 5 Failed Checks:**
1. **SOL-AM-DA-1** — `distribute()` relies on `balanceOf` without subtracting `pendingClaims` (High)
2. **SOL-CR-3/SOL-AM-RP-1** — `rescueToken()` can drain `pendingClaims` funds (High)
3. **SOL-EC-12** — Raw low-level call to potentially non-existent token address (Medium)
4. **SOL-Basics-AC-4** — Single-step role transfer for critical roles (Medium)
5. **SOL-AM-ReentrancyAttack-1** — View function returns stale value during interactions (Medium)

---

## Critical Findings

### [C-01] `rescueToken()` Ignores `pendingClaims` — Admin Can Drain User-Claimable Funds

**Severity:** Critical
**Category:** SC02 Business Logic / Access Control
**VP Reference:** VP-07 (Missing Access Restriction), VP-34 (Logic Error)
**Location:** `rescueToken()` (lines 895–914)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (SOL-CR-3/SOL-AM-RP-1), Solodit
**Real-World Precedent:** Zunami Protocol (May 2025) — $500K loss; Y2K Finance (Code4rena) — Medium

**Description:**
The `rescueToken()` function only protects tokens committed in `pendingBridge[token]` but does NOT account for tokens owed via `pendingClaims`. The check at line 908:

```solidity
if (vaultBalance < committed + amount) {
    revert CannotRescueCommittedFunds(token, committed);
}
```

Only `committed = pendingBridge[token]` is used. Tokens credited to validators, referrers, listing nodes, and arbitrators via `depositMarketplaceFee()` and `depositArbitrationFee()` (stored in `pendingClaims`) are not protected.

**Exploit Scenario:**
1. Vault holds 1000 XOM: 500 in `pendingBridge`, 400 in various `pendingClaims`, 100 uncommitted
2. Admin calls `rescueToken(XOM, 500, adminAddr)` — passes check since `1000 >= 500 + 500`
3. Vault now holds 500 XOM but owes 500 (pendingBridge) + 400 (pendingClaims) = 900 XOM
4. Claim holders calling `claimPending()` will fail due to insufficient balance

**Recommendation:**
Track total `pendingClaims` per token and include it in the rescue check:

```solidity
// Add state variable:
mapping(address => uint256) public totalPendingClaims;

// Update _safePushOrQuarantine to increment totalPendingClaims
// Update claimPending to decrement totalPendingClaims

// Fix rescueToken:
uint256 committed = pendingBridge[token] + totalPendingClaims[token];
if (vaultBalance < committed + amount) {
    revert CannotRescueCommittedFunds(token, committed);
}
```

---

## High Findings

### [H-01] `distribute()` Double-Counts `pendingClaims` as Distributable

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error), VP-16 (Accounting Error)
**Location:** `distribute()` (lines 516–556)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-AM-DA-1), Solodit
**Real-World Precedent:** ERC-4626 donation/inflation attacks — multiple protocols; Virtuals Protocol (Code4rena)

**Description:**
When `depositMarketplaceFee()` or `depositArbitrationFee()` are called, they credit amounts to `pendingClaims` for validators, referrers, and nodes. These tokens remain in the vault's `balanceOf` but are already committed. A subsequent call to `distribute()` calculates:

```solidity
uint256 distributable = balance - pendingBridge[token];
```

This does NOT subtract `pendingClaims`, so quarantined/committed tokens are re-distributed.

**Exploit Scenario:**
1. `depositMarketplaceFee()` deposits 100 XOM, credits 20 XOM to `pendingClaims[validator]`
2. 70 XOM goes to `pendingBridge`, 10 XOM to staking, 20 XOM stays as `pendingClaims`
3. Someone calls `distribute(XOM)` — `distributable = balanceOf(20) - pendingBridge(0) = 20`
4. The 20 XOM in `pendingClaims` gets redistributed: 14 to pendingBridge, 4 to staking, 2 to protocol
5. Validator calls `claimPending()` for their 20 XOM but only ~6 XOM remains in vault

**Note:** This interaction specifically occurs when `distribute()` is called after `depositMarketplaceFee()`/`depositArbitrationFee()` have left `pendingClaims` in the vault. The two code paths use different accounting models.

**Recommendation:**
Track total `pendingClaims` per token and subtract it in `distribute()`:

```solidity
uint256 distributable = balance - pendingBridge[token] - totalPendingClaims[token];
```

---

### [H-02] `_safePushOrQuarantine()` Does Not Decode ERC20 Return Value

**Severity:** High
**Category:** SC06 Unchecked External Calls
**VP Reference:** VP-26 (Unchecked ERC20 Return)
**Location:** `_safePushOrQuarantine()` (lines 1171–1191)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-EC-12, SOL-Defi-General-9), Solodit (FDUSD, Juicebox, Cally)
**Real-World Precedent:** Cally (Code4rena) — High severity; FDUSD (Quantstamp) — Medium

**Description:**
The function uses a raw low-level `call` with `IERC20.transfer.selector`:

```solidity
(bool success, ) = address(token).call(
    abi.encodeWithSelector(
        IERC20.transfer.selector,
        recipient,
        amount
    )
);
```

The `success` boolean only indicates whether the call reverted. It does NOT decode the `bool` return value from ERC20 `transfer()`. This causes two problems:

1. **Tokens returning `false` (e.g., USDT, ZRX):** The call "succeeds" (`success = true`) but the transfer did not actually execute. Tokens are lost — not transferred AND not quarantined.
2. **Calls to non-existent addresses:** Low-level calls to addresses with no code return `success = true`. Tokens are "transferred" to nowhere.

**Recommendation:**
Decode the return data and check the boolean:

```solidity
(bool success, bytes memory returndata) = address(token).call(
    abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
);
// Check both call success AND return value
bool transferred = success
    && (returndata.length == 0 || abi.decode(returndata, (bool)));

if (!transferred) {
    pendingClaims[recipient][token] += amount;
    emit TransferQuarantined(recipient, token, amount);
}
```

This matches the logic in OpenZeppelin's `SafeERC20._callOptionalReturn()`.

---

### [H-03] `setSwapRouter()` and `setPrivacyBridge()` Lack Timelock

**Severity:** High
**Category:** SC01 Access Control
**VP Reference:** VP-07 (Missing Access Restriction)
**Location:** `setSwapRouter()` (line 967), `setPrivacyBridge()` (line 994)
**Sources:** Agent-C, Agent-D, Solodit
**Real-World Precedent:** Multiple admin key compromise incidents

**Description:**
The contract correctly implements a 48-hour timelock for recipient changes (`proposeRecipients()`/`applyRecipients()`), but `setSwapRouter()` and `setPrivacyBridge()` can be changed instantly by `ADMIN_ROLE`. The `swapAndBridge()` function then calls `forceApprove(swapRouter, amount)`, granting the new router unlimited allowance over the vault's tokens.

A compromised `ADMIN_ROLE` key can:
1. Call `setSwapRouter(maliciousRouter)` — instant, no delay
2. Call `swapAndBridge(token, pendingBridge[token], 0, attackerAddr)` — drains all ODDAO funds

**Recommendation:**
Apply the same propose/apply timelock pattern used for recipients:

```solidity
address public pendingSwapRouter;
uint256 public swapRouterChangeTimestamp;

function proposeSwapRouter(address _router) external onlyRole(ADMIN_ROLE) {
    pendingSwapRouter = _router;
    swapRouterChangeTimestamp = block.timestamp + RECIPIENT_CHANGE_DELAY;
}

function applySwapRouter() external onlyRole(ADMIN_ROLE) {
    require(block.timestamp >= swapRouterChangeTimestamp);
    swapRouter = pendingSwapRouter;
    // ... clear pending
}
```

---

## Medium Findings

### [M-01] `notifyDeposit()` Is Unrestricted — Fake Event Emission

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-07 (Missing Access Restriction)
**Location:** `notifyDeposit()` (lines 486–494)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Basics-AC-2)

**Description:**
Anyone can call `notifyDeposit()` with arbitrary token/amount values. While the function only emits a `FeesNotified` event and does not modify state, off-chain indexers that track fee inflows via events could be misled. The NatSpec says "Callable by anyone" by design, but this creates an audit trail pollution vector.

**Recommendation:**
Add `onlyRole(DEPOSITOR_ROLE)` or at minimum validate that `IERC20(token).balanceOf(address(this))` increased by at least `amount` since the last known balance.

---

### [M-02] `depositMarketplaceFee()` and `depositArbitrationFee()` Lack Fee-on-Transfer Checks

**Severity:** Medium
**Category:** SC10 Token Integration
**VP Reference:** VP-46 (Fee-on-Transfer Token)
**Location:** `depositMarketplaceFee()` (lines 619–621), `depositArbitrationFee()` (lines 696–698)
**Sources:** Agent-A, Agent-B, Agent-D, Solodit (Astaria, VeToken, Symm.io, Numoen, Notional)

**Description:**
The generic `deposit()` function at line 458 correctly uses the balance-before/after pattern to handle fee-on-transfer tokens. However, `depositMarketplaceFee()` and `depositArbitrationFee()` use `safeTransferFrom(msg.sender, address(this), totalFee)` and then split based on `totalFee` (the requested amount), not the actual received amount. For fee-on-transfer tokens, the vault would overcommit.

**Recommendation:**
Apply balance-before/after pattern:

```solidity
uint256 balBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), totalFee);
uint256 actualFee = IERC20(token).balanceOf(address(this)) - balBefore;
// Use actualFee instead of totalFee for splits
```

---

### [M-03] `swapAndBridge()` Missing Deadline Parameter

**Severity:** Medium
**Category:** SC08 Front-Running
**VP Reference:** VP-34 (Front-Running)
**Location:** `swapAndBridge()` (lines 1018–1058)
**Sources:** Agent-D, Solodit (Morpheus, Leveraged Vaults, Tapioca, WooFi)

**Description:**
`swapAndBridge()` calls `IFeeSwapRouter.swapExactInput()` with `minXOMOut` slippage protection but no deadline parameter. A pending transaction can be held in the mempool and executed later when prices are less favorable. While only `BRIDGE_ROLE` can call this (reducing MEV risk), the IFeeSwapRouter interface should support deadlines.

**Recommendation:**
Add a `deadline` parameter and pass it to the swap router:

```solidity
function swapAndBridge(
    address token, uint256 amount, uint256 minXOMOut,
    address bridgeReceiver, uint256 deadline
) external onlyRole(BRIDGE_ROLE) nonReentrant whenNotPaused {
    require(block.timestamp <= deadline, "Expired");
    // ...
}
```

---

### [M-04] `convertPXOMAndBridge()` Lacks `minXOMOut` Slippage Protection

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-55 (Missing Slippage Protection)
**Location:** `convertPXOMAndBridge()` (lines 1068–1101)
**Sources:** Agent-D, Solodit (AdapterFinance)

**Description:**
Unlike `swapAndBridge()` which has a `minXOMOut` parameter, `convertPXOMAndBridge()` only checks `if (xomReceived == 0) revert PXOMConversionFailed()`. It accepts any non-zero output. If the privacy bridge conversion rate is variable, the caller has no slippage protection.

**Recommendation:**
Add `minXOMOut` parameter:

```solidity
function convertPXOMAndBridge(
    uint256 amount, address bridgeReceiver, uint256 minXOMOut
) external onlyRole(BRIDGE_ROLE) nonReentrant whenNotPaused {
    // ...
    if (xomReceived < minXOMOut) {
        revert InsufficientSwapOutput(xomReceived, minXOMOut);
    }
}
```

---

### [M-05] Centralization Risk: Single Admin Key Controls Fee Flow

**Severity:** Medium
**Category:** Centralization
**VP Reference:** VP-07
**Location:** Contract-wide
**Sources:** Agent-C, Checklist, Solodit

**Description:**
`ADMIN_ROLE` can instantly: set swap router (H-03), set privacy bridge, set bridge mode, pause/unpause the contract. `DEFAULT_ADMIN_ROLE` can additionally: rescue tokens (C-01), ossify the contract, authorize UUPS upgrades. A single compromised key can redirect 100% of fee flow through the router change vector.

**Centralization Risk Rating: 8/10**

**Recommendation:**
- Require multi-sig for `DEFAULT_ADMIN_ROLE` operations
- Add timelock to all admin setter functions (not just recipients)
- Consider separating `ADMIN_ROLE` into finer-grained roles (e.g., `PAUSE_ROLE`, `CONFIG_ROLE`)

---

## Low Findings

### [L-01] `ossify()` Has No Timelock or Confirmation

**Severity:** Low
**Category:** SC01 Access Control
**Location:** `ossify()` (line 939)
**Sources:** Agent-C, Solodit

**Description:**
`ossify()` permanently and irreversibly freezes the contract against upgrades. A compromised `DEFAULT_ADMIN_ROLE` key could ossify the contract to prevent emergency bug fixes. There is no delay, no two-step confirmation, and no cancellation mechanism.

**Recommendation:**
Add a propose/confirm pattern with a timelock, or require multi-sig.

---

### [L-02] Single-Step Role Transfer for Critical Roles

**Severity:** Low
**Category:** SC01 Access Control
**Location:** Inherited from `AccessControlUpgradeable`
**Sources:** Agent-C, Checklist (SOL-Basics-AC-4)

**Description:**
OpenZeppelin's `AccessControl` uses `grantRole`/`revokeRole` as single-step operations. An admin could accidentally grant `DEFAULT_ADMIN_ROLE` to a wrong address and lose control. No two-step transfer mechanism exists for critical roles.

**Recommendation:**
Implement a two-step admin transfer pattern similar to `Ownable2Step`.

---

### [L-03] Dust Amounts Break 70/20/10 Fee Split

**Severity:** Low
**Category:** SC07 Arithmetic
**VP Reference:** VP-15 (Rounding Exploit)
**Location:** `distribute()` (lines 527–533), `depositMarketplaceFee()` (lines 614–667)
**Sources:** Agent-B, Agent-D, Checklist (SOL-AM-DOSA-2)

**Description:**
No minimum distributable amount is enforced. For low-decimal tokens (e.g., USDC with 6 decimals), distributing 1 unit would compute: `oddaoShare = 0`, `stakingShare = 0`, `protocolShare = 1`. The entire amount goes to protocol treasury, breaking the 70/20/10 invariant.

**Recommendation:**
Add minimum distributable thresholds or skip distribution when shares round to zero.

---

### [L-04] Blacklisted Claimants' Funds Are Permanently Stuck

**Severity:** Low
**Category:** SC09 Denial of Service
**VP Reference:** VP-29 (DoS via Revert)
**Location:** `claimPending()` (lines 565–575)
**Sources:** Agent-D, Checklist (SOL-AM-DOSA-3)

**Description:**
`claimPending()` uses `safeTransfer` to the caller. If the token blacklists the recipient (e.g., USDC), the claim permanently reverts with no recovery path. There is no admin mechanism to redirect quarantined claims to an alternative address.

**Recommendation:**
Add an admin-assisted claim redirect function for stuck claims.

---

## Informational Findings

### [I-01] `nonReentrant` Modifier Not First in Modifier Chain

**Severity:** Informational
**Location:** `deposit()`, `bridgeToTreasury()`, `depositMarketplaceFee()`, `depositArbitrationFee()`
**Sources:** Checklist (SOL-Heuristics-4)

**Description:**
On several functions, `nonReentrant` is placed after `onlyRole`. Best practice is to place `nonReentrant` first to lock reentrancy before executing any other modifier logic. In practice, `onlyRole` only reads state, so this is low risk.

---

### [I-02] Donation Attack Can Inflate Distributable Balance

**Severity:** Informational
**Location:** `distribute()` (lines 521–522)
**Sources:** Solodit (SOL-AM-DA-1)

**Description:**
Anyone can send tokens directly to the vault (bypassing `deposit()`), which inflates the distributable balance. The next `distribute()` call would include these "donated" tokens in the 70/20/10 split. While not exploitable for theft (the attacker loses tokens), it creates accounting discrepancies where `totalDistributed` exceeds actual fee deposits. This is partially by design — `notifyDeposit()` exists to track direct transfers.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Zunami Protocol | May 2025 | $500K | `withdrawStuckToken()` drained user funds — identical to C-01 |
| Y2K Finance (Code4rena) | Sep 2022 | Medium | `recoverERC20()` allowed draining reward tokens |
| Cally (Code4rena) | May 2022 | High | No-revert-on-transfer tokens drained — similar to H-02 |
| FDUSD (Quantstamp) | 2024 | Medium | Unhandled ERC20 return value — identical to H-02 |
| Astaria (Sherlock) | Oct 2022 | Medium | Fee-on-transfer accounting error — identical to M-02 |
| Symm.io (Sherlock) | Dec 2023 | Medium | Fee-on-transfer invariant break — identical to M-02 |
| Morpheus (CodeHawks) | Jan 2024 | Medium | Missing deadline on swaps — identical to M-03 |
| WooFi (Sherlock) | Mar 2024 | Medium | No deadline control — identical to M-03 |

## Solodit Similar Findings

- **SOL-AM-DA-1** (Donation Attack): `distribute()` uses `balanceOf()` without full internal accounting — well-documented anti-pattern
- **SOL-CR-3 / SOL-AM-RP-1** (Admin Drain): `rescueToken()` can extract `pendingClaims` — 50K+ findings in database for this pattern
- **SOL-EC-12** (Address Existence): Raw low-level call to potentially non-existent address returns `success = true`
- **SOL-Defi-General-9** (ERC20 Compatibility): Non-standard tokens (USDT-like) permanently quarantined even on successful transfer

## Static Analysis Summary

### Slither
Slither full-project analysis timed out (>5 minutes). Findings from targeted analysis filtered to UnifiedFeeVault were incorporated into LLM agent findings.

### Aderyn
Aderyn crashed with internal error on import resolution (v0.6.8). Noted and continued with LLM analysis.

### Solhint
**0 errors, 2 warnings:**
1. `code-complexity` — Complex function in `depositMarketplaceFee()`
2. `ordering` — Minor element ordering preference

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| DEFAULT_ADMIN_ROLE | `rescueToken()`, `ossify()`, `_authorizeUpgrade()`, `grantRole()`/`revokeRole()` | 9/10 |
| ADMIN_ROLE | `proposeRecipients()`, `applyRecipients()`, `cancelRecipientsChange()`, `pause()`, `unpause()`, `setTokenBridgeMode()`, `setSwapRouter()`, `setXomToken()`, `setPrivacyBridge()` | 8/10 |
| BRIDGE_ROLE | `bridgeToTreasury()`, `swapAndBridge()`, `convertPXOMAndBridge()` | 6/10 |
| DEPOSITOR_ROLE | `deposit()`, `depositMarketplaceFee()`, `depositArbitrationFee()` | 3/10 |
| FEE_MANAGER_ROLE | (defined but unused) | 0/10 |
| (any) | `distribute()`, `claimPending()`, `notifyDeposit()` | N/A |

## Centralization Risk Assessment

**Single-key maximum damage:** A compromised `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` holder can:
1. Set malicious swap router (instant) → drain all `pendingBridge` funds via `swapAndBridge()`
2. Rescue tokens including `pendingClaims` → drain user-claimable funds
3. Ossify the contract → prevent emergency fixes
4. Upgrade to malicious implementation → complete fund theft

**Maximum potential loss:** 100% of vault balance

**Recommendation:**
- Multi-sig (3-of-5 minimum) for `DEFAULT_ADMIN_ROLE`
- Timelock on ALL admin configuration changes (not just recipients)
- Consider separating `ADMIN_ROLE` into `PAUSE_ROLE` and `CONFIG_ROLE`
- Transfer `DEFAULT_ADMIN_ROLE` to OmniGovernance timelock controller post-launch

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
