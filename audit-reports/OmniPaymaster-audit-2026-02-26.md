# Security Audit Report: OmniPaymaster

**Date:** 2026-02-26
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniPaymaster.sol`
**Solidity Version:** 0.8.25
**Lines of Code:** 392
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds EntryPoint deposit for gas sponsorship; collects XOM from users)
**OpenZeppelin Version:** 5.x (SafeERC20, Ownable, IERC20)
**Dependencies:** `IPaymaster` (custom interface), `UserOperation` (custom struct), `Ownable` (OZ), `IERC20`/`SafeERC20` (OZ)
**Test Coverage:** `Coin/test/account-abstraction/AccountAbstraction.test.js` (Section 4, ~8 test cases)
**Priority:** HIGH -- gas sponsorship contract; incorrect validation enables deposit draining

---

## Executive Summary

OmniPaymaster is an ERC-4337 paymaster contract that provides three gas sponsorship modes for OmniCoin L1 users: (1) free gas for new accounts (first N operations), (2) XOM token payment (micro-fee per operation), and (3) whitelisted/subsidized accounts (unlimited free gas). It includes a daily sponsorship budget as sybil protection, an owner-controlled whitelist, and a kill switch for emergency disablement.

This is the **first dedicated audit** of OmniPaymaster. The previous suite-level audit (2026-02-21) covered this contract alongside OmniAccount, OmniEntryPoint, and OmniAccountFactory. Several critical findings from that audit (H-03 allowance check, M-05 failed-op counter increment, H-04 sybil drain via daily budget) have been addressed in the current version. This audit focuses on the remaining and newly introduced vulnerabilities specific to the paymaster.

The audit identified **0 Critical**, **2 High**, **4 Medium**, **3 Low**, and **3 Informational** findings. The most significant issues are: (1) the `postOp` XOM fee collection via `safeTransferFrom` can revert on the retry path, causing the EntryPoint to silently swallow the failure and grant free gas to XOM-payment users; and (2) the `deposit()` and `withdrawDeposit()` functions use raw low-level calls to the EntryPoint without verifying the return data, meaning a misconfigured EntryPoint address (valid contract, wrong interface) could silently fail.

**Previous Audit Remediation Status:**

| Previous Finding | Status | Notes |
|------------------|--------|-------|
| H-03: XOM fee collection always fails (no allowance check) | **FIXED** | Lines 220-223 now check both `balanceOf` and `allowance` against `XOM_GAS_FEE` |
| M-05: sponsoredOpsCount increments on failed ops | **FIXED** | Lines 255-259 only increment counters on `opSucceeded` |
| H-04: Unlimited sybil drain via factory | **PARTIALLY FIXED** | Daily budget system added (lines 82-88, 375-391); per-user sybil vector remains (see M-01) |

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 3 |
| Informational | 3 |

---

## Architecture Analysis

### Design Strengths

1. **Three-Mode Sponsorship Model:** Clean separation of free, XOM-payment, and subsidized modes with well-ordered priority (whitelist > free > XOM > reject). This correctly prioritizes subsidized accounts.

2. **Daily Budget Sybil Protection:** The `_checkDailyBudget()` mechanism (lines 375-391) limits the total number of free/subsidized operations per 24-hour window, directly addressing the previous H-04 sybil drain finding.

3. **Kill Switch:** `sponsorshipEnabled` provides an emergency mechanism to halt all sponsorship instantly (line 211).

4. **Counter-Only on Success:** `postOp` correctly gates counter increments on `PostOpMode.opSucceeded` (line 255), preventing failed operations from consuming free op allocations.

5. **Allowance + Balance Check:** XOM payment mode now validates both `balanceOf` and `allowance` (lines 220-223), fixing the previous H-03/L-03 findings.

6. **Clean Code Quality:** Pinned pragma (0.8.25), custom errors, indexed events, SafeERC20, clear NatSpec, proper ordering. No solhint warnings.

### Dependency Analysis

- **Ownable (OZ):** Standard single-owner pattern. Owner can whitelist, toggle sponsorship, set limits, manage deposits. Ownership transfer via `transferOwnership()` (inherited).
- **SafeERC20 (OZ):** Used for `safeTransferFrom` in XOM fee collection. Correctly wraps the token call.
- **IPaymaster:** Custom interface with `PostOpMode` enum. Compatible with the OmniEntryPoint implementation.
- **EntryPoint Interaction:** The paymaster interacts with the EntryPoint via `depositTo()` and `withdrawTo()` using raw low-level calls rather than importing the interface.

### Trust Model

- **Owner:** Full administrative control (whitelist, budget, limits, deposits, kill switch). Single point of failure.
- **EntryPoint:** Trusted to call `validatePaymasterUserOp` and `postOp` correctly and in sequence. The `onlyEntryPointCaller` modifier enforces this.
- **XOM Token:** Trusted to be a well-behaved ERC-20. `safeTransferFrom` provides revert-on-failure safety.

---

## Findings

### [H-01] XOM Fee Collection Failure Silently Grants Free Gas

**Severity:** High
**Lines:** 263-269 (postOp), OmniEntryPoint 317-328 (_callPaymasterPostOp)
**CVSS:** 7.5 (High)

**Description:**

When `sponsorMode == SponsorMode.xomPayment` and the UserOp succeeds, `postOp` calls `xomToken.safeTransferFrom(account, owner(), XOM_GAS_FEE)` (line 268). If this reverts (e.g., the account revoked its XOM approval between validation and execution, or the account's balance dropped below `XOM_GAS_FEE` after validation), the EntryPoint's `_callPaymasterPostOp` catches the revert and retries with `PostOpMode.postOpReverted` (OmniEntryPoint lines 321-327).

On the retry, `postOp` is called again with `mode = PostOpMode.postOpReverted`. The current logic at lines 263-266 checks:
```solidity
if (
    sponsorMode == SponsorMode.xomPayment
    && mode == PostOpMode.opSucceeded
) {
```

Since `mode` is now `postOpReverted` (not `opSucceeded`), the XOM fee collection is **skipped** on retry. The retry succeeds (no revert), and the user gets free gas despite being in XOM payment mode.

Meanwhile, lines 255-259 already incremented `sponsoredOpsCount` and `totalOpsSponsored` during the first (failed) `postOp` call. The `GasSponsored` event is emitted twice (once per call). The EntryPoint has already deducted `actualGasCost` from the paymaster's deposit (OmniEntryPoint line 290), so the paymaster absorbs the cost with no XOM compensation.

**Attack Scenario:**
1. Attacker creates a smart account with XOM balance and approval
2. Attacker submits a UserOp that, during execution, revokes the paymaster's XOM allowance (via `execute` calling `xomToken.approve(paymaster, 0)`)
3. `validatePaymasterUserOp` passes (allowance and balance are sufficient at validation time)
4. UserOp executes successfully (revokes allowance as part of its execution)
5. `postOp` tries `safeTransferFrom` -- reverts (allowance now 0)
6. Retry with `postOpReverted` -- skips fee collection -- succeeds
7. Result: free gas, paymaster deposit drained

**Impact:** Users in XOM payment mode can systematically obtain free gas by front-running the `postOp` fee collection with an allowance revocation. Repeated exploitation drains the paymaster's EntryPoint deposit.

**Recommendation:** Handle fee collection failure explicitly in the `postOpReverted` path. Either:

(A) Attempt fee collection regardless of PostOpMode:
```solidity
if (sponsorMode == SponsorMode.xomPayment) {
    // Try collecting fee on any mode (success or retry)
    xomToken.safeTransferFrom(account, owner(), XOM_GAS_FEE);
    emit XOMGasPayment(account, XOM_GAS_FEE);
}
```

(B) If fee collection is impossible on retry, revert to consume the paymaster's deposit (which it already has been charged) but at least prevent the operation from succeeding:
```solidity
if (sponsorMode == SponsorMode.xomPayment && mode == PostOpMode.postOpReverted) {
    revert NotSponsored(); // Force the EntryPoint to revert the entire UserOp
}
```

Note: Option (B) requires understanding that when `postOp` reverts on the `postOpReverted` retry, the EntryPoint's outer catch (line 327) silently ignores it. The proper fix is Option (A) -- but if the transfer still fails, the cost is already charged to the paymaster. The real defense is to collect XOM during **validation** (via `transferFrom` in `validatePaymasterUserOp`), not during `postOp`.

---

### [H-02] deposit() and withdrawDeposit() Use Unsafe Low-Level Calls

**Severity:** High
**Lines:** 322-328 (deposit), 335-341 (withdrawDeposit)

**Description:**

Both functions interact with the EntryPoint using raw `entryPoint.call{value:}(...)` with manually encoded selectors:

```solidity
// deposit()
(bool success,) = entryPoint.call{value: msg.value}(
    abi.encodeWithSignature("depositTo(address)", address(this))
);
if (!success) revert InvalidAddress();

// withdrawDeposit()
(bool success,) = entryPoint.call(
    abi.encodeWithSignature("withdrawTo(address,uint256)", to, amount)
);
if (!success) revert InvalidAddress();
```

There are two issues:

1. **Incorrect error type on failure:** Both functions revert with `InvalidAddress()` when the low-level call fails. This is semantically wrong -- the failure may be due to insufficient deposit, an incompatible EntryPoint, or any other reason. Using `InvalidAddress()` makes debugging extremely difficult.

2. **No return data verification:** Both functions discard the return data. If the EntryPoint's `withdrawTo` returns a boolean or data, it is ignored. While OmniEntryPoint's `withdrawTo` reverts on failure (which would cause `success = false`), relying on this behavior for all future EntryPoint implementations is fragile.

3. **`withdrawDeposit` has no zero-address check on `to`:** Unlike other admin functions, the recipient `to` is not validated. Withdrawing to `address(0)` would burn the funds if the EntryPoint's `withdrawTo` doesn't check.

**Impact:** Debugging operational issues with the paymaster deposit is hindered by incorrect error messages. The lack of a zero-address check on withdrawal recipients could result in irreversible fund loss.

**Recommendation:**

```solidity
error EntryPointCallFailed();

function deposit() external payable onlyOwner {
    IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
}

function withdrawDeposit(uint256 amount, address payable to) external onlyOwner {
    if (to == address(0)) revert InvalidAddress();
    // Use the interface for type-safe interaction
    (bool success,) = entryPoint.call(
        abi.encodeWithSignature("withdrawTo(address,uint256)", to, amount)
    );
    if (!success) revert EntryPointCallFailed();
}
```

Or better yet, import `IEntryPoint` and call methods directly for compile-time type safety.

---

### [M-01] Daily Budget Does Not Prevent Per-Account Sybil Amplification

**Severity:** Medium
**Lines:** 218, 375-391, 45

**Description:**

The daily budget (default 1000 ops/day) limits the total number of free/subsidized operations across ALL accounts. However, each new account deployed via `OmniAccountFactory` gets a fresh `sponsoredOpsCount` starting at 0, meaning a single attacker can create multiple accounts to consume the entire daily budget by cycling through them.

Consider: With `freeOpsLimit = 10` and `dailySponsorshipBudget = 1000`, an attacker needs 100 accounts to exhaust the daily budget. Account creation via the factory is permissionless and free (CREATE2 clones). The attacker:

1. Creates 100 accounts with different salts (each getting 10 free ops)
2. Submits 10 UserOps per account = 1000 free operations
3. Daily budget exhausted -- legitimate users are blocked for the rest of the day

The per-account `freeOpsLimit` creates a false sense of per-user restriction. The actual sybil cost is only the gas to create accounts (which on OmniCoin L1 is near zero).

**Impact:** An attacker can deny service to legitimate users by exhausting the daily sponsorship budget. The daily budget mitigates the deposit-drain severity but not the DoS vector.

**Recommendation:** Consider tying the free ops allocation to the OmniRegistration contract (which has sybil-resistant KYC). Only registered users should receive free operations:

```solidity
IOmniRegistration public immutable registration;

// In validatePaymasterUserOp:
} else if (
    registration.isRegistered(account)
    && sponsoredOpsCount[account] < freeOpsLimit
) {
    mode = SponsorMode.free;
}
```

This leverages the existing sybil protections (phone verification, device fingerprinting via `OmniSybilGuard.sol`).

---

### [M-02] GasSponsored Event Emitted Even When XOM Fee Collection Fails

**Severity:** Medium
**Lines:** 272

**Description:**

The `GasSponsored` event (line 272) is emitted unconditionally at the end of `postOp`, regardless of whether XOM fee collection succeeded. Combined with H-01, when `postOp` is retried with `postOpReverted` mode, the event is emitted **twice** for the same operation -- once during the failed first call and once during the successful retry.

For off-chain monitoring and accounting, this creates a misleading record:
- Two `GasSponsored` events for one operation
- The first event incorrectly suggests the operation's gas was sponsored (the XOM collection that followed it failed)
- The second event emits `SponsorMode.xomPayment` despite no XOM actually being collected

**Impact:** Off-chain accounting systems, dashboards, and analytics that rely on `GasSponsored` events will double-count sponsored operations and misattribute sponsorship modes. Financial reconciliation of XOM fee revenue versus gas costs will be incorrect.

**Recommendation:** Move the event emission inside the success-only block and emit a separate event for failed fee collection:

```solidity
if (mode == PostOpMode.opSucceeded) {
    ++sponsoredOpsCount[account];
    ++totalOpsSponsored;
    totalGasSponsored += actualGasCost;
    emit GasSponsored(account, sponsorMode, actualGasCost);
}
```

---

### [M-03] lastBudgetReset Timestamp Drift Causes Inconsistent Budget Windows

**Severity:** Medium
**Lines:** 380-384

**Description:**

The daily budget reset logic uses a relative 24-hour window from `lastBudgetReset`:

```solidity
if (block.timestamp > lastBudgetReset + 1 days - 1) {
    dailySponsorshipUsed = 0;
    lastBudgetReset = block.timestamp;
}
```

Setting `lastBudgetReset = block.timestamp` on each reset causes the reset boundary to drift forward. If the first operation after a 24-hour window arrives at `lastBudgetReset + 24h + 2h` (due to low activity), the next window starts at that later timestamp, not at midnight or a fixed interval.

Over time, this creates unpredictable budget windows:
- Day 1: Budget resets at 00:00, window is 00:00-24:00
- Day 2: First operation at 02:00, reset triggers, window becomes 02:00-26:00
- Day 3: First operation at 05:00, window becomes 05:00-29:00

This is inconsistent with the NatSpec comment "midnight UTC boundary" (line 88).

**Impact:** Budget windows are unpredictable and do not align with calendar days. During the gap between the nominal midnight and the actual first operation, the budget from the previous day may still be partially available.

**Recommendation:** Use fixed midnight boundaries:

```solidity
function _checkDailyBudget() internal {
    if (dailySponsorshipBudget == 0) return;

    uint256 currentDay = block.timestamp / 1 days;
    uint256 lastResetDay = lastBudgetReset / 1 days;

    if (currentDay > lastResetDay) {
        dailySponsorshipUsed = 0;
        lastBudgetReset = block.timestamp;
    }

    if (dailySponsorshipUsed > dailySponsorshipBudget - 1) {
        revert DailyBudgetExhausted();
    }

    ++dailySponsorshipUsed;
}
```

---

### [M-04] No Mechanism to Recover ERC-20 Tokens Sent to the Paymaster

**Severity:** Medium
**Lines:** (entire contract -- missing function)

**Description:**

The paymaster contract has no function to recover ERC-20 tokens accidentally sent to its address. While the XOM fee collection sends XOM to `owner()` (line 268), there is no mechanism to:

1. Recover XOM tokens directly transferred to the paymaster (not via `safeTransferFrom`)
2. Recover any other ERC-20 tokens sent to the paymaster by mistake
3. Recover native tokens sent directly to the contract (no `receive()` or `fallback()`)

Since the paymaster address is prominently used in `paymasterAndData` fields, users and bundlers may accidentally send tokens to it.

**Impact:** Any tokens sent directly to the paymaster contract are permanently locked.

**Recommendation:** Add an owner-callable rescue function:

```solidity
function rescueTokens(
    IERC20 token,
    address to,
    uint256 amount
) external onlyOwner {
    if (to == address(0)) revert InvalidAddress();
    token.safeTransfer(to, amount);
}
```

---

### [L-01] remainingFreeOps Underflow Guard Uses Subtraction Pattern

**Severity:** Low
**Lines:** 359-363

**Description:**

```solidity
function remainingFreeOps(address account) external view returns (uint256 remaining) {
    uint256 used = sponsoredOpsCount[account];
    if (used > freeOpsLimit - 1) return 0;
    return freeOpsLimit - used;
}
```

If `freeOpsLimit` is set to 0 by the owner (via `setFreeOpsLimit(0)`), the expression `freeOpsLimit - 1` underflows (wraps to `type(uint256).max` in the comparison, though not in an unchecked block -- in Solidity 0.8+, this subtraction is checked and would revert).

Actually, since Solidity 0.8+ has overflow/underflow protection, calling `remainingFreeOps()` when `freeOpsLimit == 0` would revert with a panic (arithmetic underflow on `freeOpsLimit - 1`).

**Impact:** View function reverts when `freeOpsLimit` is 0, which is a valid configuration (no free ops for anyone). This breaks any off-chain system that calls this function.

**Recommendation:**

```solidity
function remainingFreeOps(address account) external view returns (uint256 remaining) {
    uint256 used = sponsoredOpsCount[account];
    if (freeOpsLimit == 0 || used >= freeOpsLimit) return 0;
    return freeOpsLimit - used;
}
```

---

### [L-02] XOM_GAS_FEE is Hardcoded and Not Adjustable

**Severity:** Low
**Lines:** 51

**Description:**

The XOM gas fee is a constant `1e15` (0.001 XOM). This cannot be adjusted based on:
- XOM token price changes
- Network conditions
- Business model adjustments

If XOM appreciates significantly, 0.001 XOM per operation may become expensive. If XOM depreciates, the fee becomes negligible and may not cover the paymaster's actual gas costs.

**Impact:** The fee structure cannot adapt to market conditions without redeploying the entire paymaster contract.

**Recommendation:** Make the fee configurable by the owner:

```solidity
uint256 public xomGasFee;

constructor(...) {
    xomGasFee = 1e15; // Default: 0.001 XOM
}

function setXomGasFee(uint256 newFee) external onlyOwner {
    xomGasFee = newFee;
    emit XomGasFeeUpdated(newFee);
}
```

---

### [L-03] Whitelist Management Lacks Batch Operations

**Severity:** Low
**Lines:** 283-296

**Description:**

`whitelistAccount` and `unwhitelistAccount` operate on a single account per transaction. For onboarding validator sets, ODDAO members, or large partner organizations, this requires N separate transactions, consuming gas and time.

**Impact:** Administrative overhead scales linearly with the number of accounts to whitelist.

**Recommendation:** Add batch variants:

```solidity
function whitelistAccountBatch(address[] calldata accounts) external onlyOwner {
    uint256 len = accounts.length;
    for (uint256 i; i < len; ++i) {
        if (accounts[i] == address(0)) revert InvalidAddress();
        whitelisted[accounts[i]] = true;
        emit AccountWhitelisted(accounts[i]);
    }
}
```

---

### [I-01] XOMGasPayment Event Has Indexed Amount Parameter

**Severity:** Informational
**Lines:** 103

**Description:**

```solidity
event XOMGasPayment(address indexed account, uint256 indexed xomAmount);
```

The `xomAmount` parameter is declared `indexed`. Since the fee is currently a constant (`XOM_GAS_FEE = 1e15`), every emission has the same indexed topic value, making the index useless for filtering. Additionally, indexing numeric values that may change (if L-02 is implemented) adds gas cost without benefit -- `indexed` on `uint256` stores the raw value as a topic, which is equally searchable as non-indexed data for equality matches but loses value for event data readability in standard explorers.

**Recommendation:** Remove `indexed` from `xomAmount`:

```solidity
event XOMGasPayment(address indexed account, uint256 xomAmount);
```

---

### [I-02] Unused maxCost and userOpHash Parameters in validatePaymasterUserOp

**Severity:** Informational
**Lines:** 205-209

**Description:**

The `validatePaymasterUserOp` function receives `userOpHash` and `maxCost` but silences them with:

```solidity
(userOpHash, maxCost);
```

The `maxCost` parameter is the maximum gas cost the EntryPoint could charge. A production paymaster should validate that its EntryPoint deposit is sufficient to cover `maxCost`, ensuring it won't fail during execution:

```solidity
// Verify sufficient EntryPoint deposit
if (IEntryPoint(entryPoint).balanceOf(address(this)) < maxCost) {
    revert InsufficientDeposit();
}
```

On OmniCoin L1 where gas is near-zero, this is less critical, but it would protect against misconfiguration.

**Impact:** The paymaster may accept UserOps it cannot cover, leading to EntryPoint deposit underflow (arithmetic revert in `_deductGasCost`).

**Recommendation:** Add a deposit sufficiency check or document that this is intentionally omitted for the zero-gas OmniCoin L1 context.

---

### [I-03] Constructor Does Not Validate owner_ Parameter

**Severity:** Informational
**Lines:** 169-184

**Description:**

The constructor validates `entryPoint_` and `xomToken_` for zero addresses but does not validate `owner_`. The `Ownable(owner_)` base constructor from OpenZeppelin also does not revert on `address(0)` in all versions.

If deployed with `owner_ = address(0)`, all `onlyOwner` functions become permanently inaccessible, and the paymaster cannot be managed (no whitelist changes, no deposit, no kill switch).

**Impact:** Deployment with a zero owner address results in an unmanageable paymaster. While unlikely in practice (deployer would notice immediately), defense-in-depth warrants the check.

**Recommendation:** Add validation:

```solidity
if (owner_ == address(0)) revert InvalidAddress();
```

Note: OpenZeppelin's `Ownable` constructor in v5.x does revert on `address(0)` with `OwnableInvalidOwner(address(0))`, so this is informational only for v5.x. If the OZ version is < 5.0, this becomes Low severity.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings (clean)
**Compilation:** Clean (0 errors, 0 warnings with Solidity 0.8.25)

---

## Cross-Contract Interaction Analysis

### Paymaster <-> EntryPoint Flow

1. **Validation Phase:** EntryPoint calls `validatePaymasterUserOp()`. The paymaster checks sponsorship eligibility and returns context (sponsor mode + account address).

2. **Execution Phase:** EntryPoint executes the UserOp's calldata against the account. The paymaster is not involved.

3. **Post-Op Phase:** EntryPoint calls `postOp()`. The paymaster updates counters and collects XOM fees.

4. **Gas Accounting:** EntryPoint deducts `actualGasCost` from the paymaster's deposit via `_deductGasCost()` (OmniEntryPoint line 290).

**Key Risk:** The time gap between validation and post-op allows the user's account to change state (e.g., revoke XOM approval), creating the H-01 vulnerability.

### Paymaster <-> XOM Token Flow

- **Validation:** Reads `balanceOf` and `allowance` (view calls, no state changes)
- **Post-Op:** Calls `safeTransferFrom` to collect XOM fee

**Key Risk:** The state read during validation may not reflect state at post-op execution time.

### Paymaster <-> AccountFactory (Indirect)

- The factory allows unlimited account creation, each getting a fresh free ops counter
- The daily budget partially mitigates this but does not prevent DoS (M-01)

---

## Gas Analysis

| Function | Approximate Gas |
|----------|----------------|
| `validatePaymasterUserOp` (whitelist path) | ~5,000 |
| `validatePaymasterUserOp` (free path) | ~5,500 |
| `validatePaymasterUserOp` (XOM path) | ~8,000 (2 external calls) |
| `postOp` (free/subsidized, opSucceeded) | ~8,000 |
| `postOp` (XOM, opSucceeded) | ~30,000 (safeTransferFrom) |
| `whitelistAccount` | ~25,000 |
| `setFreeOpsLimit` | ~5,500 |
| `deposit` | ~30,000 (external call to EntryPoint) |

---

## Methodology

- **Pass 1:** Static analysis via solhint (clean result)
- **Pass 2A:** OWASP Smart Contract Top 10 review (access control, validation logic, reentrancy, arithmetic, gas griefing, front-running, oracle manipulation, denial of service)
- **Pass 2B:** ERC-4337 paymaster specification compliance review (validation/post-op lifecycle, context encoding, gas accounting, time-of-check-time-of-use gaps)
- **Pass 3:** Cross-contract interaction analysis (EntryPoint retry behavior, token state changes between validation and post-op)
- **Pass 4:** Previous audit remediation verification (H-03, H-04, M-05 from 2026-02-21 suite audit)
- **Pass 5:** Triage and deduplication
- **Pass 6:** Report generation

---

## Conclusion

OmniPaymaster has been significantly improved since the 2026-02-21 suite audit. The three most critical findings from that audit (missing allowance check, counter increment on failure, unlimited sybil drain) have all been addressed. The contract demonstrates clean code quality with proper NatSpec, custom errors, pinned pragma, and SafeERC20 usage.

The most significant remaining vulnerability is **H-01 (XOM fee collection failure grants free gas)**, which is inherent to the ERC-4337 validate-then-postOp architecture. The paymaster validates XOM balance/allowance during `validatePaymasterUserOp` but collects the fee in `postOp`. A malicious UserOp can revoke the approval during execution, causing the `postOp` fee collection to fail. The EntryPoint's retry mechanism with `postOpReverted` mode causes the retry to skip fee collection entirely.

The recommended fix is to collect the XOM fee **during validation** rather than during `postOp`, or to handle the `postOpReverted` mode explicitly by reverting (which still charges the paymaster's deposit but prevents the operation from succeeding silently).

**H-02** is a code quality issue with real operational consequences -- using raw low-level calls to interact with the EntryPoint (a known, well-typed contract) introduces unnecessary fragility and misleading error messages.

**Overall Assessment:** The contract is suitable for deployment on OmniCoin L1 where gas is near-zero, provided H-01 is addressed. On any chain with meaningful gas costs, H-01 becomes a direct deposit-drain vector. The daily budget (M-01) should also be paired with OmniRegistration integration for production sybil resistance.

---
*Generated by Claude Code Audit Agent -- 6-Pass Enhanced*
*Contract last modified: 2026-02-26*
*Audit report: OmniPaymaster-audit-2026-02-26.md*
