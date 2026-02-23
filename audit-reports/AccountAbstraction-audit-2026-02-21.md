# Security Audit Report: Account Abstraction Suite

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contracts:**
- `Coin/contracts/account-abstraction/OmniAccount.sol` (652 lines)
- `Coin/contracts/account-abstraction/OmniEntryPoint.sol` (418 lines)
- `Coin/contracts/account-abstraction/OmniPaymaster.sol` (323 lines)
- `Coin/contracts/account-abstraction/OmniAccountFactory.sol` (134 lines)
**Solidity Version:** ^0.8.20
**Upgradeable:** OmniAccount uses Initializable (clone pattern); others are standard
**Handles Funds:** Yes (smart wallets hold user funds; EntryPoint manages deposits)

## Executive Summary

The Account Abstraction suite implements ERC-4337 smart wallets with session keys, social recovery, spending limits, and gas sponsorship. OmniAccount is the smart wallet (deployed as ERC-1167 clones), OmniEntryPoint is the singleton UserOp processor, OmniPaymaster sponsors gas (free/XOM/whitelisted modes), and OmniAccountFactory creates deterministic wallet instances.

The audit found **4 Critical vulnerabilities**: (1) session key target/value constraints are never enforced during execution — any session key can call any target with any value; (2) spending limits are entirely dead code — never checked during transfers; (3) the EntryPoint never deducts gas costs from account/paymaster deposits, breaking ERC-4337 economics; and (4) removed guardian approvals persist and count toward recovery thresholds. Both agents independently identified the session key and spending limit enforcement gaps as the top priorities.

| Severity | Count |
|----------|-------|
| Critical | 4 |
| High | 4 |
| Medium | 5 |
| Low | 4 |
| Informational | 1 |

## Findings

### [C-01] Session Key Constraints Never Enforced During Execution

**Severity:** Critical
**Lines:** OmniAccount 303-333 (validateUserOp), 347-357 (execute)
**Agents:** Both

**Description:**

`validateUserOp` validates session key ECDSA signatures and returns time-based validity, but never checks `allowedTarget` or `maxValue` constraints. Once validation succeeds, the EntryPoint calls `execute()` which is gated by `onlyOwnerOrEntryPoint` — a modifier that passes for ANY UserOp routed through the EntryPoint regardless of whether the signer was the owner or a session key.

A session key created with `allowedTarget = 0xDEX` and `maxValue = 0` can call `execute(attackerAddress, 10 ether, "")` because the target and value are never checked against the session key's constraints.

**Impact:** Session keys have no restrictions beyond requiring a valid ECDSA signature and the `active` flag. The `allowedTarget` and `maxValue` fields are decorative.

**Recommendation:** Decode `userOp.callData` in `validateUserOp` to extract the target and value, then validate against the session key's constraints before returning success.

---

### [C-02] Spending Limits Are Dead Code — Never Enforced

**Severity:** Critical
**Lines:** OmniAccount 109 (mapping), 592-597 (setter), 347-380 (execute/executeBatch)
**Agents:** Both

**Description:**

The contract implements `SpendingLimit` structs, `setSpendingLimit()`, `remainingSpendingLimit()` view, and `_nextMidnight()` helper. However, neither `execute()` nor `executeBatch()` ever checks or updates spending limits. There is no code path that increments `spentToday` or compares against `dailyLimit`.

**Impact:** Users who configure spending limits believing they provide compromise protection are unprotected. A compromised key can drain the entire wallet balance in a single transaction.

**Recommendation:** Add `_checkAndUpdateSpendingLimit(address token, uint256 amount)` called from `execute()` for native transfers and with ERC20 selector decoding for token transfers.

---

### [C-03] EntryPoint Never Deducts Gas Costs from Deposits

**Severity:** Critical
**Lines:** OmniEntryPoint 197-287 (_handleSingleOp), 339-348 (_accountPrefund)
**Agents:** Both

**Description:**

`_accountPrefund()` reads `_deposits[op.sender]` but never writes to it. After computing `actualGasCost` (line 250), the EntryPoint sends the refund to the beneficiary from `address(this).balance` but never decrements `_deposits[sender]` or `_deposits[paymaster]`.

This means:
1. Accounts can submit unlimited operations without deposits being consumed
2. Paymaster deposits are never charged for sponsored operations
3. The deposit system is decorative — deposited once, never decremented

Additionally, OmniAccount's prefund transfer result is silently ignored (line 311-313), and the account sends funds to the EntryPoint's `receive()` which credits `_deposits[msg.sender]` (the account), not the expected accounting path.

**Impact:** Broken ERC-4337 gas economics. On any chain with real gas costs, accounts and paymasters can operate indefinitely without sufficient deposits.

**Recommendation:** After computing `actualGasCost`, deduct from the responsible party:
```solidity
if (paymaster != address(0)) {
    _deposits[paymaster] -= actualGasCost;
} else {
    _deposits[op.sender] -= actualGasCost;
}
```

---

### [C-04] Removed Guardian Approval Persists — Recovery Threshold Bypass

**Severity:** Critical
**Lines:** OmniAccount 418-433 (removeGuardian), 626-635 (_clearRecovery)
**Agents:** Both

**Description:**

When a guardian is removed during an active recovery, `removeGuardian()` sets `isGuardian[guardian] = false` but does NOT decrement `recoveryRequest.approvalCount` or clear `recoveryRequest.approvals[guardian]`. The `_clearRecovery()` function only iterates the current `guardians` array — removed guardians' approvals are never cleared.

Scenario: 3 guardians (A, B, C), threshold = 2. Guardian A initiates recovery (approvalCount = 1). Owner removes A. Now 2 guardians (B, C), threshold = 2. But approvalCount is still 1. Guardian B approves → approvalCount = 2 ≥ threshold. Recovery executes with a removed guardian's vote counted.

**Impact:** A compromised owner who removes a malicious guardian believing the recovery is neutralized is wrong. The removed guardian's vote persists and can complete the recovery.

**Recommendation:** In `removeGuardian()`, if recovery is pending, decrement `approvalCount` and clear the removed guardian's approval. Alternatively, cancel any pending recovery when guardians are modified.

---

### [H-01] EntryPoint Never Validates validUntil/validAfter Time Ranges

**Severity:** High
**Lines:** OmniEntryPoint 375-384 (_extractSigResult), OmniAccount 329
**Agents:** Both

**Description:**

When validating a session key, OmniAccount returns `uint256(sk.validUntil) << 160` (line 329). Per ERC-4337, the EntryPoint must parse `validUntil` (bits 160-207) and reject operations where `block.timestamp > validUntil`. However, `_extractSigResult()` only reads the lower 160 bits (aggregator address) and completely ignores the time range fields.

Since `validUntil << 160` places all data above bit 160, the lower 160 bits are 0, which maps to `SIG_VALID`. Expired session keys pass validation indefinitely.

**Impact:** Session key time-based expiration is not enforced. An attacker with an expired session key can use it as long as `sk.active` is true.

**Recommendation:** Add time validation in the EntryPoint:
```solidity
uint48 validUntil = uint48(validationData >> 160);
if (validUntil != 0 && block.timestamp > validUntil) revert SignatureExpired();
```

---

### [H-02] Unknown Aggregator Treated as Valid Signature

**Severity:** High
**Lines:** OmniEntryPoint 375-384 (_extractSigResult)
**Agent:** Agent A

**Description:**

`_extractSigResult` returns `SIG_VALID` for `address(0)` and `SIG_INVALID` for `address(1)`. For any other non-zero address, it returns `SIG_VALID` with the comment "aggregated signature (not supported, treat as valid)." If the EntryPoint doesn't support aggregators, non-zero aggregator addresses should be rejected, not accepted.

**Impact:** A buggy or malicious account contract could return arbitrary validation data with a non-zero aggregator, and the EntryPoint would accept it as valid.

**Recommendation:** Change fallback to `SIG_INVALID` for any non-zero address.

---

### [H-03] Paymaster XOM Fee Collection Always Fails — Free Sponsorship

**Severity:** High
**Lines:** OmniPaymaster 237 (safeTransferFrom), 198 (validation)
**Agent:** Agent B

**Description:**

In `xomPayment` mode, `postOp` calls `xomToken.safeTransferFrom(account, owner(), xomFee)`. This requires the smart account to have approved the paymaster for XOM spending. However:
1. No setup mechanism creates this approval
2. `validatePaymasterUserOp` checks `balanceOf` but not `allowance`
3. `safeTransferFrom` reverts → EntryPoint catches → retries with `postOpReverted` mode → same revert → silently proceeds

Net result: XOM payment mode gives free sponsorship. Users holding any XOM (without approval) get unlimited free operations.

**Impact:** The XOM payment business model is non-functional. The paymaster deposit is drained without compensation.

**Recommendation:** Check allowance during validation: `xomToken.allowance(account, address(this)) >= xomFee`.

---

### [H-04] Unlimited Account Creation Enables Sybil Drain of Free Ops

**Severity:** High
**Lines:** OmniPaymaster 196, OmniAccountFactory 80-100
**Agent:** Agent B

**Description:**

The paymaster grants `freeOpsLimit` (default 10) free operations per account. The factory allows unlimited account creation with different salts. Each new account gets a fresh counter. A single EOA can create thousands of accounts, each with 10 free operations, draining the paymaster's deposit.

**Impact:** Unbounded paymaster deposit drain. No per-user or global sponsorship cap.

**Recommendation:** Add a global daily sponsorship budget, or tie free ops to registered OmniRegistration users (which has sybil protections).

---

### [M-01] Owner Can Block Recovery by Removing Guardians

**Severity:** Medium
**Lines:** OmniAccount 418-433 (removeGuardian)
**Agent:** Agent A

**Description:**

During an active recovery, the compromised owner can front-run `executeRecovery()` with `removeGuardian()` calls, reducing the guardian count until the threshold can never be met. The owner can also remove all guardians, permanently preventing future recovery.

**Impact:** Social recovery is defeatable by the compromised key it's designed to protect against.

**Recommendation:** Freeze guardian management during active recovery.

---

### [M-02] No Reentrancy Guard on execute/executeBatch

**Severity:** Medium
**Lines:** OmniAccount 347-357, 366-380
**Agents:** Both

**Description:**

Both functions make arbitrary external calls via `.call{value:}()` without `ReentrancyGuard`. While `onlyOwnerOrEntryPoint` prevents most re-entry paths, defense-in-depth is warranted for a contract holding user funds.

**Recommendation:** Add `nonReentrant` modifier from OpenZeppelin.

---

### [M-03] EntryPoint Does Not Verify Account Exists Before Validation

**Severity:** Medium
**Lines:** OmniEntryPoint 216
**Agent:** Agent B

**Description:**

If `initCode` is empty and `op.sender` has no deployed code, calling `validateUserOp` on an EOA returns success with empty return data, which decodes as 0 (`SIG_VALID`). Operations targeting non-existent accounts pass validation.

**Recommendation:** Add `if (op.sender.code.length == 0) revert AccountDeploymentFailed(address(0));`

---

### [M-04] MAX_OP_GAS Constant Defined But Never Enforced

**Severity:** Medium
**Lines:** OmniEntryPoint 35 (constant), 81 (error)
**Agents:** Both

**Description:**

`MAX_OP_GAS = 10_000_000` and `GasLimitExceeded()` error are defined but never used. No validation on `callGasLimit`, `verificationGasLimit`, or `preVerificationGas`. Extreme values can cause overflow in `_maxOperationCost` (reverted by Solidity 0.8+ overflow checks, but DoS-ing the entire batch).

**Recommendation:** Enforce `totalGas = callGasLimit + verificationGasLimit + preVerificationGas <= MAX_OP_GAS`.

---

### [M-05] sponsoredOpsCount Increments Even on Failed Operations

**Severity:** Medium
**Lines:** OmniPaymaster 224
**Agent:** Agent B

**Description:**

`++sponsoredOpsCount[account]` increments regardless of `PostOpMode`. Failed operations (`opReverted`) consume the user's free ops allocation.

**Recommendation:** Only increment on `PostOpMode.opSucceeded`.

---

### [L-01] Stale Guardian Approvals Persist Across Recovery Rounds

**Severity:** Low
**Lines:** OmniAccount 626-635
**Agent:** Agent A

**Description:**

`_clearRecovery()` only clears current guardians' approvals. Removed guardians' stale `approvals[guardian] = true` persists. If re-added, `approveRecovery()` reverts with `AlreadyApproved()`, preventing participation.

**Recommendation:** Use a `recoveryNonce` to key approvals by round.

---

### [L-02] onlyOwner Allows address(this) — Self-Call Pattern

**Severity:** Low
**Lines:** OmniAccount 251-256
**Agents:** Both

**Description:**

`onlyOwner` allows `msg.sender == address(this)` for self-call composability via `execute()`. This is intentional for ERC-4337 but should be explicitly documented as a design decision.

**Recommendation:** Document the design intent. Consider whether all `onlyOwner` functions should be callable via self-call.

---

### [L-03] Paymaster XOM Balance Check Without Allowance Verification

**Severity:** Low
**Lines:** OmniPaymaster 198
**Agent:** Agent A

**Description:**

`validatePaymasterUserOp` checks `xomToken.balanceOf(account) > 0` for XOM payment mode but doesn't verify allowance. Combined with H-03, users get free sponsorship by holding any XOM.

**Recommendation:** Check both `balanceOf >= xomFee` and `allowance(account, address(this)) >= xomFee`.

---

### [L-04] Missing Event for approveRecovery

**Severity:** Low
**Lines:** OmniAccount 478-484
**Agent:** Agent B

**Description:**

`approveRecovery()` modifies state but emits no event. Off-chain monitoring cannot track recovery progress.

**Recommendation:** Add `event RecoveryApproved(address indexed guardian, uint256 approvalCount)`.

---

### [I-01] Floating Pragma

**Severity:** Informational

All 4 contracts use `^0.8.20`. Pin to a specific version for deployment.

---

## Static Analysis Results

**Solhint:** 0 errors, 24 warnings (immutable naming, gas optimizations, ordering)
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & ERC-4337 compliance (agent)
- Pass 5: Triage & deduplication (manual — 28 raw findings -> 18 unique)
- Pass 6: Report generation

## Conclusion

The Account Abstraction suite has **four critical gaps where security features are declared but not enforced**:

1. **Session key constraints (C-01)** — `allowedTarget` and `maxValue` are stored but never checked during execution. Session keys are effectively unrestricted.

2. **Spending limits (C-02)** — the entire spending limit system (structs, setter, view function, midnight reset) is dead code. Never consulted during transfers.

3. **Gas accounting (C-03)** — the EntryPoint never deducts gas costs from deposits. The ERC-4337 economic model is non-functional.

4. **Guardian removal during recovery (C-04)** — removed guardians' approvals persist and count toward the recovery threshold, enabling unauthorized account takeover.

**Root cause:** The contract architecture is well-designed with correct data structures and management functions, but the **enforcement hooks in the execution path are missing**. The session key and spending limit features have complete implementations except for the single most important part: checking them when `execute()` is called.

**Cross-contract note:** The EntryPoint's broken time validation (H-01) compounds C-01 — even if session key constraints were enforced, expired keys would still work. The Paymaster's XOM payment failure (H-03) and sybil vulnerability (H-04) mean the gas sponsorship model is exploitable.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
