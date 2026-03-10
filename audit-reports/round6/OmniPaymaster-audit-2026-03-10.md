# Security Audit Report: OmniPaymaster.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniPaymaster.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 525
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds EntryPoint deposit for gas sponsorship; collects XOM from users; holds rescued tokens temporarily)
**Dependencies:** `Ownable` (OZ 5.x), `IERC20`/`SafeERC20` (OZ), `IPaymaster`, `IEntryPoint`, `UserOperation` (custom)
**Previous Audits:** Suite audit (2026-02-21), Round 3 (2026-02-26, 0C/2H/4M/3L/3I)

---

## Executive Summary

OmniPaymaster is an ERC-4337 paymaster that sponsors gas for OmniCoin L1 users through three modes: (1) free gas for new accounts (first N operations, with optional OmniRegistration sybil check), (2) XOM token payment (configurable micro-fee per operation), and (3) whitelisted/subsidized accounts (unlimited free gas). It includes a daily sponsorship budget, a kill switch, batch whitelist management, a token rescue function, and a configurable XOM fee.

This Round 6 audit reviews the contract after remediation of the Round 3 findings. The contract has grown from 392 lines to 525 lines, incorporating fixes for both High findings and all four Medium findings from the prior audit. The most critical fix is **H-01 (XOM fee free-riding via allowance revocation)**: XOM fees are now collected **during validation** (`validatePaymasterUserOp`, line 266) rather than during `postOp`, eliminating the TOCTOU attack vector.

**Remediation quality is HIGH.** All findings have been addressed with correct implementations.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | OmniRegistration staticcall fail-open design allows free gas when registration contract is unavailable | **FIXED** |

---

## Remediation Status from Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| R3 H-01: XOM fee collection failure grants free gas | High | **Fixed** | XOM fee collection moved from `postOp` to `validatePaymasterUserOp` (line 266). `safeTransferFrom` now executes during validation phase, before the user's callData runs. If the transfer fails, the entire validation reverts and the UserOp is rejected. The TOCTOU window (allowance revocation during execution) is eliminated. |
| R3 H-02: deposit()/withdrawDeposit() use unsafe low-level calls | High | **Fixed** | `deposit()` (line 349) now uses typed `entryPoint.depositTo{value: msg.value}(address(this))` via `IEntryPoint` interface for compile-time safety. `withdrawDeposit()` (lines 359-371) retains low-level call (because `IEntryPoint` does not expose `withdrawTo`) but now uses `EntryPointCallFailed` custom error and validates `to != address(0)`. |
| R3 M-01: Daily budget does not prevent per-account sybil amplification | Medium | **Fixed** | `_determineSponsorMode` (lines 489-523) now checks OmniRegistration contract (when set) before granting free ops. Only registered users receive `SponsorMode.free`. Unregistered users must pay in XOM or be whitelisted. `setRegistration()` admin function added (line 399). |
| R3 M-02: GasSponsored event emitted even on XOM fee failure | Medium | **Fixed** | `postOp` (lines 282-298) now only emits `GasSponsored` and increments counters when `mode == PostOpMode.opSucceeded`. XOM fee collection in `postOp` is eliminated entirely (moved to validation). |
| R3 M-03: lastBudgetReset timestamp drift | Medium | **Fixed** | `_checkDailyBudget` (lines 462-481) now uses calendar-day boundaries (`block.timestamp / 1 days`) instead of relative 24h windows. Comparison is `currentDay > lastResetDay`, ensuring consistent midnight-aligned budget periods. |
| R3 M-04: No mechanism to recover ERC-20 tokens | Medium | **Fixed** | `rescueTokens()` (lines 427-435) added. Owner-only, validates `to != address(0)`, uses `SafeERC20.safeTransfer`. Emits `TokensRescued` event. |
| R3 L-01: remainingFreeOps underflow when freeOpsLimit==0 | Low | **Fixed** | `remainingFreeOps` (lines 443-448) now checks `freeOpsLimit == 0` first: `if (freeOpsLimit == 0 || used > freeOpsLimit - 1) return 0;` |
| R3 L-02: XOM_GAS_FEE is hardcoded | Low | **Fixed** | XOM fee is now configurable: `xomGasFee` state variable (line 71) initialized to `DEFAULT_XOM_GAS_FEE` (1e15), adjustable via `setXomGasFee()` (lines 389-392). |
| R3 L-03: Whitelist lacks batch operations | Low | **Fixed** | `whitelistAccountBatch()` (lines 408-417) added. Validates each address and emits events. |
| R3 I-01: XOMGasPayment indexed amount | Info | **Acknowledged** | `indexed` retained on `xomAmount` (line 113). This is a style choice; no security impact. |
| R3 I-02: Unused maxCost/userOpHash parameters | Info | **Partially addressed** | `userOpHash` and `maxCost` are still silenced with `(userOpHash, maxCost);` (line 248). The paymaster does not verify its own EntryPoint deposit against `maxCost`. On OmniCoin L1 where gas is near-zero, this is acceptable. See I-01 below. |
| R3 I-03: Constructor does not validate owner_ | Info | **Mitigated** | OZ v5.x `Ownable(owner_)` reverts on `address(0)` with `OwnableInvalidOwner`. No additional check needed. |

---

## Detailed Code Review

### XOM Fee Collection Architecture (Key Change)

The most important architectural change since Round 3 is the relocation of XOM fee collection from `postOp` to `validatePaymasterUserOp`:

**Before (Round 3 -- vulnerable):**
```
validatePaymasterUserOp: checks balance + allowance [READ]
  -> UserOp executes (user can revoke allowance here)
postOp: calls safeTransferFrom [WRITE] -- may fail if allowance revoked
  -> retry with postOpReverted -- skips fee collection
  -> Result: free gas
```

**After (Round 6 -- fixed):**
```
validatePaymasterUserOp: calls safeTransferFrom [WRITE] -- collects fee immediately
  -> If transfer fails: entire validation reverts, UserOp rejected
  -> If transfer succeeds: fee is collected before user code runs
  -> UserOp executes (user cannot un-collect the fee)
postOp: only increments counters and emits events on opSucceeded
  -> No fee collection in postOp
  -> Result: fee always collected for xomPayment mode
```

This eliminates the TOCTOU (time-of-check-time-of-use) vulnerability entirely. The XOM fee is collected atomically during validation, before the user's callData can manipulate token state.

**Line 264-268:**
```solidity
if (mode == SponsorMode.xomPayment) {
    uint256 fee = xomGasFee;
    xomToken.safeTransferFrom(account, owner(), fee);
    emit XOMGasPayment(account, fee);
}
```

**Assessment:** Correct and robust. The `safeTransferFrom` during validation guarantees fee collection. If the account has revoked its allowance or has insufficient balance, the validation reverts and the UserOp is never executed.

### Registration-Based Sybil Resistance (New)

The `_determineSponsorMode` function (lines 489-523) now includes OmniRegistration integration:

```solidity
bool isRegistered = true;
if (registration != address(0)) {
    (bool ok, bytes memory result) = registration.staticcall(
        abi.encodeWithSignature("isRegistered(address)", account)
    );
    if (ok && result.length > 31) {
        isRegistered = abi.decode(result, (bool));
    }
}

if (isRegistered && sponsoredOpsCount[account] < freeOpsLimit) {
    return SponsorMode.free;
}
```

The implementation uses `staticcall` with graceful error handling:
- If `registration == address(0)`: all accounts are treated as registered (backward compatible)
- If `registration.staticcall` fails: `isRegistered` defaults to `true` (fail-open)
- If `result.length <= 31`: `isRegistered` defaults to `true` (fail-open)

The fail-open design is intentional -- if the registration contract is unavailable or misconfigured, users are not blocked from free gas. This prioritizes availability over sybil resistance.

**Assessment:** The fail-open design is a deliberate trade-off. See M-01 below for the security implication.

### Daily Budget System

The calendar-day boundary system (lines 462-481) is now correctly implemented:

```solidity
uint256 currentDay = block.timestamp / 1 days;
uint256 lastResetDay = lastBudgetReset / 1 days;

if (currentDay > lastResetDay) {
    dailySponsorshipUsed = 0;
    lastBudgetReset = block.timestamp;
}
```

This ensures consistent midnight-aligned budget windows regardless of when the first operation of the day arrives.

**Assessment:** Sound. Budget windows are predictable and do not drift.

### PostOp Logic

The `postOp` function (lines 282-298) is now clean:

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost
) external override onlyEntryPointCaller {
    (SponsorMode sponsorMode, address account) = abi.decode(
        context, (SponsorMode, address)
    );

    if (mode == PostOpMode.opSucceeded) {
        ++sponsoredOpsCount[account];
        ++totalOpsSponsored;
        totalGasSponsored += actualGasCost;
        emit GasSponsored(account, sponsorMode, actualGasCost);
    }
}
```

No fee collection. Counters only increment on success. Event only emits on success. The `sponsorMode` variable is unused except in the event emission.

**Assessment:** Sound.

---

## Medium Findings

### [M-01] OmniRegistration staticcall Fail-Open Design Allows Free Gas When Registration Contract Is Unavailable

**Severity:** Medium
**Lines:** 497-508 (`_determineSponsorMode`)
**Category:** Sybil Resistance / Availability Trade-off

**Description:**

The registration check uses `staticcall` with fail-open behavior:

```solidity
bool isRegistered = true;  // Default: treat as registered
if (registration != address(0)) {
    (bool ok, bytes memory result) = registration.staticcall(
        abi.encodeWithSignature("isRegistered(address)", account)
    );
    if (ok && result.length > 31) {
        isRegistered = abi.decode(result, (bool));
    }
    // If staticcall fails (ok==false) or returns short data:
    // isRegistered remains true -> account gets free ops
}
```

If the OmniRegistration contract:
1. Runs out of gas during the staticcall
2. Has a bug that causes a revert
3. Returns unexpected data (< 32 bytes)
4. Is paused or self-destructed

Then ALL accounts are treated as registered, and the daily budget is the only sybil protection. An attacker who can trigger a registration contract failure (e.g., via a carefully crafted gas limit in the bundler's transaction) could bypass registration checks.

More practically, if the registration contract is not yet deployed or is temporarily unavailable (upgrade, migration), the paymaster falls back to treating everyone as registered, which may not be the intended behavior.

**Impact:** When the registration contract is unavailable, sybil resistance degrades to the daily budget cap only. An attacker could time their sybil attack to coincide with registration contract downtime.

**Recommendation:**

Consider a configurable fail-open vs fail-closed policy:

```solidity
bool public registrationFailOpen; // Default: true for backward compatibility

// In _determineSponsorMode:
if (ok && result.length > 31) {
    isRegistered = abi.decode(result, (bool));
} else {
    isRegistered = registrationFailOpen;
}
```

This allows the admin to set `registrationFailOpen = false` once the registration contract is stable, ensuring that registration failures reject free ops rather than granting them.

Alternatively, add an event when the staticcall fails so off-chain monitoring can alert the admin:

```solidity
if (!ok) {
    emit RegistrationCheckFailed(account);
    isRegistered = true; // fail-open
}
```

---

## Low Findings

### [L-01] xomGasFee Can Be Set to Zero, Making XOM Payment Mode Non-Functional

**Severity:** Low
**Lines:** 389-392 (`setXomGasFee`)
**Category:** Configuration Validation

**Description:**

The `setXomGasFee` function allows setting the fee to any value, including 0:

```solidity
function setXomGasFee(uint256 newFee) external onlyOwner {
    xomGasFee = newFee;
    emit XomGasFeeUpdated(newFee);
}
```

If `xomGasFee` is set to 0, the `_determineSponsorMode` check at lines 514-521:

```solidity
uint256 fee = xomGasFee;
if (
    fee > 0
    && xomToken.balanceOf(account) > fee - 1
    && xomToken.allowance(account, address(this)) > fee - 1
) {
    return SponsorMode.xomPayment;
}
```

The condition `fee > 0` is false, so XOM payment mode is never triggered. This means accounts that have exhausted their free ops and are not whitelisted will always hit `revert NotSponsored()`, even if they have XOM and want to pay.

Additionally, if `xomGasFee == 0` and the code reaches the `safeTransferFrom` path (which it cannot due to the `fee > 0` guard, but hypothetically), a zero-amount transfer would succeed, effectively granting free gas.

**Impact:** Setting `xomGasFee = 0` disables the XOM payment fallback, potentially locking out non-whitelisted users who have exhausted free ops. This is a configuration error, not a vulnerability.

**Recommendation:** Add a minimum fee validation:

```solidity
function setXomGasFee(uint256 newFee) external onlyOwner {
    if (newFee == 0) revert InvalidAmount(); // Prevent disabling XOM payment
    xomGasFee = newFee;
    emit XomGasFeeUpdated(newFee);
}
```

Or document that setting `xomGasFee = 0` intentionally disables XOM payment mode.

---

### [L-02] rescueTokens Can Rescue XOM Tokens That Are Pending Collection

**Severity:** Low
**Lines:** 427-435 (`rescueTokens`)
**Category:** Fund Safety

**Description:**

The `rescueTokens` function allows the owner to transfer any ERC-20 token from the paymaster:

```solidity
function rescueTokens(
    IERC20 token,
    address to,
    uint256 amount
) external onlyOwner {
    if (to == address(0)) revert InvalidAddress();
    token.safeTransfer(to, amount);
    emit TokensRescued(address(token), to, amount);
}
```

There is no restriction on rescuing the XOM token itself. While XOM fees are collected directly by `safeTransferFrom(account, owner(), fee)` during validation (so XOM does not accumulate in the paymaster contract under normal operation), there could be edge cases where XOM is held by the paymaster:

1. A misconfigured fee collection that sends XOM to `address(this)` instead of `owner()`
2. Direct XOM transfers to the paymaster address
3. Future code changes that accumulate XOM in the contract

The risk is minimal because the current implementation sends XOM directly to `owner()`, not to the paymaster contract. The `rescueTokens` function is designed exactly for recovering accidentally sent tokens.

**Impact:** No current impact. The function correctly recovers tokens. Noted for defense-in-depth.

**Recommendation:** No code change needed. The current implementation is correct. The owner who can call `rescueTokens` is the same entity who receives XOM fees, so there is no privilege escalation.

---

## Informational Findings

### [I-01] maxCost Parameter Not Validated Against EntryPoint Deposit

**Severity:** Informational
**Lines:** 248 (`(userOpHash, maxCost);`)

**Description:**

The `validatePaymasterUserOp` function receives `maxCost` (the maximum gas cost the EntryPoint could charge) but does not verify that the paymaster's EntryPoint deposit is sufficient:

```solidity
// Silence unused parameter warnings
(userOpHash, maxCost);
```

On OmniCoin L1 where gas is near-zero, `maxCost` is typically negligible. However, the OmniEntryPoint now checks `_deposits[paymaster] < maxCost` in `_validatePaymaster` (line 436 of OmniEntryPoint), so the EntryPoint enforces this check regardless. The paymaster does not need to duplicate it.

**Assessment:** Acceptable. The EntryPoint provides the deposit sufficiency check.

---

### [I-02] sponsoredOpsCount Tracks Total Ops, Not Just Free Ops

**Severity:** Informational
**Lines:** 77 (`sponsoredOpsCount`), 293 (`++sponsoredOpsCount[account]`)

**Description:**

`sponsoredOpsCount` is incremented for ALL successful operations, regardless of mode (free, xomPayment, or subsidized). This means an account that has been whitelisted and processes 1000 subsidized operations will have `sponsoredOpsCount = 1000`. If the account is later removed from the whitelist, it will have already exceeded `freeOpsLimit`, so it will not receive any free ops.

This is arguably correct behavior -- the account has already been serviced 1000 times -- but it means `sponsoredOpsCount` does not accurately represent "free ops consumed." The `remainingFreeOps` view function would return 0 for such an account even though it never consumed any of its free allocation.

**Impact:** No security impact. Off-chain dashboards that display "remaining free ops" may show misleading values for previously whitelisted accounts.

**Recommendation:** Consider renaming `sponsoredOpsCount` to `totalOpsCount` for clarity, or use a separate counter for free ops only.

---

### [I-03] No Rate Limiting on setRegistration / setXomGasFee Admin Functions

**Severity:** Informational
**Lines:** 389-402

**Description:**

The admin can change `xomGasFee` and `registration` address at any time without restriction. Rapid changes could create inconsistent user experience:
- Changing `xomGasFee` mid-block could cause some users to pay more/less than others
- Changing `registration` to `address(0)` instantly disables sybil checks

These are standard admin privileges for an `Ownable` contract and are not security vulnerabilities. In production, these functions should be called through a TimelockController for governance transparency.

**Assessment:** Acceptable for the current deployment model. Document that these should be timelocked in production.

---

## Cross-Contract Interaction Analysis

### Paymaster <-> EntryPoint Flow (Post-Remediation)

```text
1. EntryPoint._validatePaymaster(op, hash, paymaster, maxCost):
   - Checks _deposits[paymaster] >= maxCost  [EntryPoint enforces]
   - Calls paymaster.validatePaymasterUserOp(op, hash, maxCost)
     |
     |-- Paymaster checks sponsorship eligibility
     |-- If xomPayment: collects XOM fee via safeTransferFrom NOW
     |-- If free/subsidized: checks daily budget
     |-- Returns (context, 0)
   - EntryPoint checks validationData == 0 (SIG_VALID)

2. EntryPoint executes op.callData on account
   (Paymaster is not involved -- XOM already collected)

3. EntryPoint._callPaymasterPostOp:
   - Calls paymaster.postOp(mode, context, actualGasCost)
     |
     |-- If opSucceeded: increment counters, emit GasSponsored
     |-- If opReverted/postOpReverted: no counter increment, no event

4. EntryPoint._deductGasCost:
   - Deducts actualGasCost from _deposits[paymaster]
```

**Key insight:** The XOM fee collection during step 1 (validation) means the user cannot manipulate token state before fee collection. The fee is collected or the UserOp is rejected -- no third option.

### Paymaster <-> XOM Token Flow

- **Validation:** `safeTransferFrom(account, owner(), xomGasFee)` -- atomic transfer
- **Precondition checks:** `balanceOf(account) >= xomGasFee` and `allowance(account, paymaster) >= xomGasFee` are checked in `_determineSponsorMode` before the transfer is attempted
- **Failure mode:** If the balance/allowance checks pass but `safeTransferFrom` still fails (e.g., token contract is paused, fee-on-transfer token), the entire validation reverts

**Assessment:** Sound. The precondition checks prevent unnecessary gas consumption on obvious failures.

### Paymaster Drain Attack Analysis

**Can a malicious UserOp drain the paymaster's EntryPoint deposit?**

1. The EntryPoint checks `_deposits[paymaster] >= maxCost` before calling `validatePaymasterUserOp`.
2. `maxCost = totalGas * maxFeePerGas` where `totalGas <= MAX_OP_GAS (10M)`.
3. On OmniCoin L1 with near-zero gas prices, `maxCost` is negligible.
4. The paymaster's deposit is deducted by `actualGasCost` (actual gas consumed), not `maxCost`.
5. The daily budget limits the number of free/subsidized operations to 1000/day.

**For XOM payment mode:** The paymaster's deposit is deducted by `actualGasCost`, but the paymaster collects `xomGasFee` in XOM tokens. On a zero-gas chain, `actualGasCost` is near-zero, so the XOM fee is pure revenue.

**For free/subsidized mode:** The paymaster absorbs the gas cost. With 1000 ops/day and near-zero gas, the daily cost is negligible.

**Assessment:** **No viable drain vector on OmniCoin L1.** On a chain with meaningful gas prices, the daily budget would need to be calibrated to prevent excessive deposit depletion.

---

## Summary of Recommendations

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | M-01 | Medium | Consider configurable fail-open/fail-closed policy for registration checks; add event on staticcall failure |
| 2 | L-01 | Low | Add minimum validation for `xomGasFee` or document that 0 disables XOM payment |
| 3 | L-02 | Low | No action needed; current design is correct |
| 4 | I-01 | Info | No action; EntryPoint enforces deposit check |
| 5 | I-02 | Info | Consider renaming `sponsoredOpsCount` for clarity |
| 6 | I-03 | Info | Document that admin functions should be timelocked in production |

---

## Conclusion

OmniPaymaster has been thoroughly remediated since the Round 3 audit. Both High findings and all four Medium findings have been properly addressed:

- **H-01 (XOM fee free-riding):** Eliminated by moving fee collection to validation phase. This is the correct architectural fix -- the TOCTOU window is completely closed.
- **H-02 (unsafe EntryPoint calls):** Fixed with typed `IEntryPoint` interface for `deposit()` and proper error types for `withdrawDeposit()`.
- **M-01 (sybil amplification):** Addressed with OmniRegistration integration for free ops eligibility.
- **M-02 (double event emission):** Fixed by gating counters and events on `opSucceeded`.
- **M-03 (timestamp drift):** Fixed with calendar-day boundary arithmetic.
- **M-04 (no token rescue):** Fixed with `rescueTokens()` function.
- **L-01/L-02/L-03:** All fixed (underflow guard, configurable fee, batch whitelist).

The single remaining Medium finding (M-01) is a design trade-off: the fail-open behavior of the registration check prioritizes availability over sybil resistance when the registration contract is unavailable. This is reasonable for a zero-gas L1 chain but should be reconsidered if gas pricing is enabled.

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1. The paymaster's gas sponsorship model is economically sound for a zero-gas chain, and the XOM payment mode provides a sustainable revenue mechanism for chains with meaningful gas costs.

---

*Report generated 2026-03-10*
*Methodology: 6-pass audit (static analysis, OWASP SC Top 10, ERC-4337 paymaster spec compliance, prior audit remediation verification, cross-contract interaction analysis, report generation)*
*Contract: OmniPaymaster.sol at 525 lines, Solidity 0.8.25*
