# Security Audit Report: OmniPaymaster.sol (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniPaymaster.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 563
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (holds EntryPoint deposit for gas sponsorship; collects XOM from users; holds rescued tokens temporarily)
**Dependencies:** `Ownable` (OZ 5.x), `IERC20`/`SafeERC20` (OZ), `IPaymaster`, `IEntryPoint`, `UserOperation` (custom)
**Previous Audits:** Suite audit (2026-02-21), Round 3 (2026-02-26, 0C/2H/4M/3L/3I), Round 6 (2026-03-10, 0C/0H/1M/2L/3I)

---

## Executive Summary

OmniPaymaster is an ERC-4337 paymaster that sponsors gas for OmniCoin L1 users through three modes: (1) free gas for new registered accounts (first N operations, with OmniRegistration sybil check), (2) XOM token payment (configurable micro-fee per operation), and (3) whitelisted/subsidized accounts (unlimited free gas). It includes a daily sponsorship budget, a kill switch, batch whitelist management, a token rescue function, configurable XOM fee, and configurable fail-open/fail-closed registration behavior.

This Round 7 audit reviews the contract after complete remediation of all findings from Rounds 3 and 6, including the Round 6 M-01 finding (fail-open registration check). The contract has grown from 525 lines (Round 6) to 563 lines, incorporating:

- **R6 M-01 fix:** Configurable `registrationFailOpen` boolean with `setRegistrationFailOpen()` admin function and `RegistrationCheckFailed` event for off-chain monitoring.
- All prior High, Medium, and Low findings remain properly remediated.

**Remediation quality is EXCELLENT.** All findings from all prior rounds have been addressed with correct, robust implementations. The contract is mature and well-hardened.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 4 |

---

## Remediation Status from All Prior Audits

### Round 3 Findings (2026-02-26)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| R3 H-01 | High | XOM fee collection failure grants free gas (TOCTOU) | **Fixed (R6)** -- Fee collected in `validatePaymasterUserOp` (line 285) before user code runs |
| R3 H-02 | High | deposit()/withdrawDeposit() use unsafe low-level calls | **Fixed (R6)** -- `deposit()` uses typed `IEntryPoint.depositTo`; `withdrawDeposit()` uses custom error |
| R3 M-01 | Medium | Daily budget does not prevent per-account sybil amplification | **Fixed (R6)** -- OmniRegistration check gates free ops |
| R3 M-02 | Medium | GasSponsored event emitted even on op failure | **Fixed (R6)** -- Gated on `PostOpMode.opSucceeded` |
| R3 M-03 | Medium | lastBudgetReset timestamp drift | **Fixed (R6)** -- Calendar-day boundaries (`block.timestamp / 1 days`) |
| R3 M-04 | Medium | No mechanism to recover ERC-20 tokens | **Fixed (R6)** -- `rescueTokens()` added |
| R3 L-01 | Low | remainingFreeOps underflow when freeOpsLimit==0 | **Fixed (R6)** -- Explicit zero check |
| R3 L-02 | Low | XOM_GAS_FEE is hardcoded | **Fixed (R6)** -- Configurable `xomGasFee` with `setXomGasFee()` |
| R3 L-03 | Low | Whitelist lacks batch operations | **Fixed (R6)** -- `whitelistAccountBatch()` added |
| R3 I-01 | Info | XOMGasPayment indexed amount | **Acknowledged** -- Style choice, no impact |
| R3 I-02 | Info | Unused maxCost/userOpHash parameters | **Accepted** -- EntryPoint enforces deposit check |
| R3 I-03 | Info | Constructor does not validate owner_ | **Mitigated** -- OZ v5.x `Ownable` reverts on zero |

### Round 6 Findings (2026-03-10)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| R6 M-01 | Medium | OmniRegistration staticcall fail-open design | **Fixed (R7)** -- See Remediation Verification below |
| R6 L-01 | Low | xomGasFee can be set to zero | **Acknowledged** -- See L-01 below (carried forward as design decision) |
| R6 L-02 | Low | rescueTokens can rescue XOM | **Acknowledged** -- Correct by design (owner == fee recipient) |
| R6 I-01 | Info | maxCost not validated against deposit | **Accepted** -- EntryPoint enforces |
| R6 I-02 | Info | sponsoredOpsCount tracks total ops, not just free | **Acknowledged** -- See I-02 below |
| R6 I-03 | Info | No rate limiting on admin functions | **Acknowledged** -- Timelock recommended for production |

---

## Round 6 M-01 Remediation Verification

The Round 6 M-01 finding recommended a configurable fail-open/fail-closed policy for the registration staticcall. The remediation is **correct and thorough**:

**Changes implemented (lines 69-75, 430-433, 523-545):**

```solidity
// State variable (line 75)
bool public registrationFailOpen;

// Constructor (line 231)
registrationFailOpen = true;  // Backward-compatible default

// Admin function (lines 430-433)
function setRegistrationFailOpen(bool failOpen) external onlyOwner {
    registrationFailOpen = failOpen;
    emit RegistrationFailOpenUpdated(failOpen);
}

// In _determineSponsorMode (lines 532-545)
bool isRegistered = registrationFailOpen;  // Default to policy
if (registration != address(0)) {
    (bool ok, bytes memory result) = registration.staticcall(
        abi.encodeWithSignature("isRegistered(address)", account)
    );
    if (ok && result.length > 31) {
        isRegistered = abi.decode(result, (bool));
    } else {
        emit RegistrationCheckFailed(account);  // Off-chain monitoring
    }
}
```

**Assessment:**

1. The `registrationFailOpen` state variable correctly defaults to `true` (backward-compatible, fail-open).
2. When the staticcall fails, `isRegistered` retains the `registrationFailOpen` value -- if `false`, unregistered users are denied free ops.
3. The `RegistrationCheckFailed` event (line 544) enables off-chain monitoring to detect registration contract unavailability.
4. The `setRegistrationFailOpen()` function is owner-only and emits an event for tracking.
5. Both the event declaration (lines 151-155) and the `RegistrationFailOpenUpdated` event (lines 157-159) have complete NatSpec.

**Verdict:** The R6 M-01 finding is fully and correctly remediated. The admin can tighten security by calling `setRegistrationFailOpen(false)` once the OmniRegistration contract is stable.

---

## Detailed Code Review

### 1. Access Control Analysis

| Function | Access | Modifier | Assessment |
|----------|--------|----------|------------|
| `validatePaymasterUserOp` | EntryPoint only | `onlyEntryPointCaller` | Correct -- only EntryPoint should call |
| `postOp` | EntryPoint only | `onlyEntryPointCaller` | Correct -- only EntryPoint should call |
| `whitelistAccount` | Owner | `onlyOwner` | Correct |
| `unwhitelistAccount` | Owner | `onlyOwner` | Correct |
| `setFreeOpsLimit` | Owner | `onlyOwner` | Correct -- bounded by `MAX_FREE_OPS` |
| `setSponsorshipEnabled` | Owner | `onlyOwner` | Correct -- emergency kill switch |
| `deposit` | Owner | `onlyOwner` | Correct -- owner funds the paymaster |
| `withdrawDeposit` | Owner | `onlyOwner` | Correct -- validates `to != address(0)` |
| `setDailySponsorshipBudget` | Owner | `onlyOwner` | Correct |
| `setXomGasFee` | Owner | `onlyOwner` | Correct -- see L-01 |
| `setRegistration` | Owner | `onlyOwner` | Correct -- can set to `address(0)` to disable |
| `setRegistrationFailOpen` | Owner | `onlyOwner` | Correct |
| `whitelistAccountBatch` | Owner | `onlyOwner` | Correct -- validates each address |
| `rescueTokens` | Owner | `onlyOwner` | Correct -- validates `to != address(0)` |
| `remainingFreeOps` | Public | `view` | Correct -- no state modification |

**Centralization risk:** The `Ownable` pattern gives a single address full control over sponsorship configuration, whitelist, fee settings, registration policy, and fund management. This is appropriate for an L1 chain where the owner is expected to be a multisig or DAO. In production, admin functions should be behind a TimelockController for governance transparency. No code change needed -- this is a deployment concern.

### 2. Reentrancy Analysis

| External Call | Location | Risk | Protection |
|---------------|----------|------|------------|
| `xomToken.safeTransferFrom` | Line 285 | Low | Called during validation phase; EntryPoint serializes UserOp processing |
| `entryPoint.depositTo` | Line 368 | None | Owner-only; sends ETH to trusted EntryPoint |
| `entryPoint.call(withdrawTo)` | Line 384 | None | Owner-only; pulls ETH from EntryPoint |
| `token.safeTransfer` | Line 464 | Low | Owner-only; rescue function |
| `registration.staticcall` | Line 535 | None | `staticcall` cannot modify state |

**Assessment:** No reentrancy vulnerabilities. The contract has no unprotected state modifications after external calls. The `validatePaymasterUserOp` function modifies no state before the `safeTransferFrom` call (the `_determineSponsorMode` function is the only state reader, and the actual XOM transfer happens after mode determination). The `postOp` function only increments counters after being called by the EntryPoint, which serializes execution. The `onlyEntryPointCaller` modifier prevents any external call from re-entering the paymaster's EntryPoint-facing functions.

### 3. Gas Sponsorship Logic Review

**Mode Determination Priority (lines 523-562):**

```
1. whitelisted[account] == true  --> SponsorMode.subsidized (always sponsor)
2. isRegistered AND sponsoredOpsCount < freeOpsLimit  --> SponsorMode.free
3. xomGasFee > 0 AND balance >= fee AND allowance >= fee  --> SponsorMode.xomPayment
4. None of the above  --> revert NotSponsored()
```

**Assessment:** The priority ordering is correct. Whitelisted accounts bypass all checks. Free ops require both registration and budget availability. XOM payment is the fallback for non-whitelisted, non-free accounts. The revert at the end is the correct rejection path.

**XOM Fee Collection (lines 283-287):**

```solidity
if (mode == SponsorMode.xomPayment) {
    uint256 fee = xomGasFee;
    xomToken.safeTransferFrom(account, owner(), fee);
    emit XOMGasPayment(account, fee);
}
```

**Assessment:** The fee is collected during validation, before the UserOp's callData executes. This eliminates the TOCTOU attack vector from R3 H-01. The `safeTransferFrom` will revert if:
- Account has insufficient balance (despite the pre-check in `_determineSponsorMode`, this is a defense-in-depth measure against race conditions)
- Account has insufficient allowance
- XOM token contract is paused or otherwise restricts transfers
- XOM token has a fee-on-transfer that makes the actual transfer amount less than expected

In all failure cases, the entire `validatePaymasterUserOp` reverts, and the UserOp is rejected by the EntryPoint. This is the correct behavior.

### 4. Daily Budget System Review (lines 493-512)

```solidity
function _checkDailyBudget() internal {
    if (dailySponsorshipBudget == 0) return; // Unlimited

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

**Assessment:**

- Calendar-day boundaries prevent drift (R3 M-03 fix verified).
- The `dailySponsorshipBudget - 1` comparison is equivalent to `dailySponsorshipUsed >= dailySponsorshipBudget` and avoids underflow because the early return handles `dailySponsorshipBudget == 0`.
- Budget is only enforced for free and subsidized modes (not XOM payment), which is correct -- XOM payment users pay their own way.
- The `lastBudgetReset = block.timestamp` on reset stores the raw timestamp rather than the day boundary. This is acceptable because the comparison uses `/1 days` truncation on both sides. A future optimization could store `currentDay * 1 days` for consistency, but there is no functional difference.

### 5. Registration Check Review (lines 523-562)

The `_determineSponsorMode` function performs a registration check using `staticcall`:

```solidity
bool isRegistered = registrationFailOpen;
if (registration != address(0)) {
    (bool ok, bytes memory result) = registration.staticcall(
        abi.encodeWithSignature("isRegistered(address)", account)
    );
    if (ok && result.length > 31) {
        isRegistered = abi.decode(result, (bool));
    } else {
        emit RegistrationCheckFailed(account);
    }
}
```

**Assessment:**

- **Selector encoding:** `abi.encodeWithSignature("isRegistered(address)", account)` correctly encodes the function selector. The IOmniRegistration interface confirms `isRegistered(address)` returns `bool`.
- **Return data validation:** `result.length > 31` ensures at least 32 bytes for a valid ABI-encoded `bool`. This prevents decoding garbage data.
- **Fail-open/fail-closed:** Configurable via `registrationFailOpen` (R6 M-01 fix). Default is `true` (fail-open) for backward compatibility.
- **Event emission:** `RegistrationCheckFailed` is emitted on every staticcall failure, enabling off-chain alerting.
- **Gas limit:** The `staticcall` does not explicitly limit gas. On a zero-gas L1, this is not a concern. On chains with meaningful gas prices, a malicious registration contract could consume excessive gas within the `staticcall`. However, the EntryPoint limits the total gas for validation via `verificationGasLimit`, so the blast radius is bounded. See I-01.

### 6. PostOp Logic Review (lines 301-317)

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

**Assessment:**

- Counters and events are gated on `opSucceeded` (R3 M-02 fix verified).
- No fee collection occurs in `postOp` (R3 H-01 fix verified).
- The `abi.decode` of `context` is safe because the context was encoded by `validatePaymasterUserOp` in the same transaction.
- `totalGasSponsored` accumulates without overflow protection. At 2^256 - 1, this would require ~10^77 gas units, which is physically impossible. No risk.
- The `sponsorMode` parameter from context is only used in the event emission. It accurately reflects the mode determined during validation.

### 7. Token Payment Security

**XOM as ERC-20:**
- The contract uses `SafeERC20` for all token operations (`safeTransferFrom`, `safeTransfer`), protecting against non-standard ERC-20 implementations.
- The `owner()` function from OZ Ownable is used as the fee recipient. This is the paymaster deployer/admin.
- The fee amount is a flat per-operation fee (`xomGasFee`), not proportional to gas used. On a zero-gas L1, this is appropriate. On chains with meaningful gas prices, the flat fee may not cover actual gas costs -- but this is a business decision, not a security issue.

**Fee-on-transfer tokens:** If XOM has a transfer tax (unlikely given it is the project's own token), the `safeTransferFrom` would succeed but the `owner()` would receive less than `xomGasFee`. This does not create a vulnerability because the paymaster does not depend on the received amount for any computation.

### 8. ERC-4337 Compliance

| Requirement | Status |
|-------------|--------|
| `validatePaymasterUserOp` returns `(bytes context, uint256 validationData)` | Compliant |
| `postOp` accepts `(PostOpMode, bytes, uint256)` | Compliant |
| `validationData = 0` means valid, no time restriction | Compliant |
| Context is opaque bytes passed from validation to postOp | Compliant |
| Paymaster cannot cause EntryPoint to revert on postOp failure | Compliant -- EntryPoint retries with `postOpReverted` |
| Paymaster must have sufficient deposit at EntryPoint | Enforced by EntryPoint (line 451 of OmniEntryPoint) |

**Assessment:** Fully ERC-4337 compliant for the v0.6 UserOperation format.

---

## Low Findings

### [L-01] xomGasFee Can Be Set to Zero, Disabling XOM Payment Mode (Carried from R6)

**Severity:** Low
**Lines:** 408-411 (`setXomGasFee`)
**Category:** Configuration Validation
**Prior:** R6 L-01 (acknowledged, carried forward)

**Description:**

The `setXomGasFee` function allows setting the fee to any value including zero:

```solidity
function setXomGasFee(uint256 newFee) external onlyOwner {
    xomGasFee = newFee;
    emit XomGasFeeUpdated(newFee);
}
```

When `xomGasFee == 0`, the condition `fee > 0` at line 553 is false, so XOM payment mode is never entered. Accounts that have exhausted their free ops and are not whitelisted will always revert with `NotSponsored()`, even if they hold XOM and have approved the paymaster.

This was acknowledged in R6 as a configuration issue. While the `fee > 0` guard correctly prevents zero-amount transfers (which would grant free gas), the inability to reach XOM payment mode when the fee is zero could lock out users unexpectedly.

**Impact:** Setting `xomGasFee = 0` unintentionally disables the XOM payment fallback. This is an admin configuration error, not an exploitable vulnerability.

**Recommendation:** Either add a minimum fee validation or document the behavior explicitly:

```solidity
// Option A: Prevent zero fee
error FeeCannotBeZero();

function setXomGasFee(uint256 newFee) external onlyOwner {
    if (newFee == 0) revert FeeCannotBeZero();
    xomGasFee = newFee;
    emit XomGasFeeUpdated(newFee);
}

// Option B: Document in NatSpec
/// @dev Setting newFee to 0 disables XOM payment mode entirely.
///      Only whitelisted accounts and those under freeOpsLimit will
///      be sponsored. All other accounts will be rejected.
```

---

### [L-02] whitelistAccountBatch Has No Array Length Limit

**Severity:** Low
**Lines:** 439-448 (`whitelistAccountBatch`)
**Category:** Gas / DoS

**Description:**

The `whitelistAccountBatch` function iterates over an unbounded array:

```solidity
function whitelistAccountBatch(
    address[] calldata accounts
) external onlyOwner {
    uint256 len = accounts.length;
    for (uint256 i; i < len; ++i) {
        if (accounts[i] == address(0)) revert InvalidAddress();
        whitelisted[accounts[i]] = true;
        emit AccountWhitelisted(accounts[i]);
    }
}
```

An extremely large array could exceed the block gas limit, causing the transaction to revert. On OmniCoin L1 with near-zero gas, this is less concerning than on Ethereum mainnet, but the function could still hit EVM execution limits or cause significant delays.

**Impact:** An owner who submits an excessively large batch could waste gas on a reverted transaction. There is no exploitability since only the owner can call this function.

**Recommendation:** Add a reasonable maximum batch size constant:

```solidity
uint256 public constant MAX_BATCH_SIZE = 200;
error BatchTooLarge();

function whitelistAccountBatch(address[] calldata accounts) external onlyOwner {
    uint256 len = accounts.length;
    if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
    // ...
}
```

---

## Informational Findings

### [I-01] Registration staticcall Does Not Limit Gas

**Severity:** Informational
**Lines:** 535-539

**Description:**

The `staticcall` to the registration contract does not include an explicit gas limit:

```solidity
(bool ok, bytes memory result) = registration.staticcall(
    abi.encodeWithSignature("isRegistered(address)", account)
);
```

On OmniCoin L1 with near-zero gas prices, this is not a concern. On chains with meaningful gas prices, a registration contract that consumes excessive gas (e.g., iterating over a large data structure) could inflate the gas cost of `validatePaymasterUserOp`. However, the EntryPoint already bounds the total validation gas via `verificationGasLimit` (checked at OmniEntryPoint line 361), so the blast radius is contained.

Additionally, `staticcall` cannot modify state, so a malicious registration contract cannot perform harmful side effects.

**Assessment:** Acceptable for OmniCoin L1. No code change needed. If the paymaster is ever deployed on a chain with meaningful gas prices, consider adding an explicit gas limit to the staticcall (e.g., 50,000 gas).

---

### [I-02] sponsoredOpsCount Tracks All Modes, Not Just Free Ops (Carried from R6)

**Severity:** Informational
**Lines:** 85, 312
**Prior:** R6 I-02

**Description:**

`sponsoredOpsCount[account]` is incremented for ALL successful operations regardless of mode (free, xomPayment, subsidized). This means:

1. A whitelisted account that processes 1000 subsidized operations will have `sponsoredOpsCount = 1000`.
2. If later unwhitelisted, it will have exceeded `freeOpsLimit` and will not receive any free ops.
3. An account paying in XOM also has its counter incremented, consuming its "free ops" allocation for paid operations.

The `remainingFreeOps` view function would show 0 remaining for accounts that paid for all their operations.

**Impact:** No security impact. Off-chain dashboards may display misleading "remaining free ops" values.

**Recommendation:** Consider using a separate counter for free ops, or rename `sponsoredOpsCount` to `totalOpsCount` for semantic accuracy. Alternatively, only increment `sponsoredOpsCount` when `sponsorMode == SponsorMode.free`:

```solidity
// In postOp, only count free ops toward the limit:
if (mode == PostOpMode.opSucceeded) {
    if (sponsorMode == SponsorMode.free) {
        ++sponsoredOpsCount[account];
    }
    ++totalOpsSponsored;
    totalGasSponsored += actualGasCost;
    emit GasSponsored(account, sponsorMode, actualGasCost);
}
```

---

### [I-03] XOMGasPayment Event Has Indexed xomAmount

**Severity:** Informational
**Lines:** 121
**Prior:** R3 I-01

**Description:**

The `XOMGasPayment` event indexes `xomAmount`:

```solidity
event XOMGasPayment(address indexed account, uint256 indexed xomAmount);
```

Indexing a `uint256` means the raw value is stored as a topic rather than in event data. For filtering purposes, this is only useful if consumers search for exact fee amounts (e.g., "show me all payments of exactly 1e15"). In practice, `xomGasFee` is the same for all XOM payments at any given time, so indexing it provides little benefit. Conversely, if the fee changes frequently, the indexed topic hashing prevents range queries.

**Impact:** No security impact. Minor inefficiency in event data organization.

**Assessment:** Acknowledged. No change recommended -- this is a style preference.

---

### [I-04] Constructor Sets dailySponsorshipBudget to Hardcoded 1000

**Severity:** Informational
**Lines:** 232

**Description:**

The constructor hardcodes `dailySponsorshipBudget = 1000`:

```solidity
constructor(
    address entryPoint_,
    address xomToken_,
    address owner_
) Ownable(owner_) {
    // ...
    dailySponsorshipBudget = 1000;
    // ...
}
```

This value may not be appropriate for all deployment scenarios. If the paymaster is deployed on a high-traffic chain or during a promotional period, 1000 daily sponsored ops may be insufficient. Conversely, on a low-traffic chain, 1000 may be too generous.

The value is immediately adjustable via `setDailySponsorshipBudget()`, so this is not a functional issue. However, passing it as a constructor parameter would make deployment more explicit.

**Impact:** None. The value is adjustable post-deployment.

**Recommendation:** Consider accepting `dailySponsorshipBudget` as a constructor parameter for deployment flexibility, or document the default value in deployment scripts.

---

## Cross-Contract Interaction Analysis

### Paymaster <-> EntryPoint Flow (Current)

```text
1. EntryPoint._validatePaymaster(op, hash, paymaster, maxCost):
   - Checks _deposits[paymaster] >= maxCost  [EntryPoint enforces]
   - Calls paymaster.validatePaymasterUserOp(op, hash, maxCost)
     |
     |-- Paymaster checks sponsorshipEnabled (kill switch)
     |-- Paymaster calls _determineSponsorMode(account):
     |     |-- If whitelisted -> SponsorMode.subsidized
     |     |-- If registered + under limit -> SponsorMode.free
     |     |-- If XOM balance + allowance sufficient -> SponsorMode.xomPayment
     |     |-- Otherwise -> revert NotSponsored()
     |-- If free/subsidized: _checkDailyBudget()
     |-- If xomPayment: safeTransferFrom(account, owner(), fee)
     |-- Returns (abi.encode(mode, account), 0)
   - EntryPoint checks validationData == 0 (SIG_VALID)

2. EntryPoint executes op.callData on account
   (Paymaster is not involved -- XOM already collected if applicable)

3. EntryPoint._callPaymasterPostOp:
   - Calls paymaster.postOp(mode, context, actualGasCost)
     |
     |-- Decodes (sponsorMode, account) from context
     |-- If opSucceeded: increment counters, emit GasSponsored
     |-- If opReverted/postOpReverted: no action

4. EntryPoint._deductGasCost:
   - Deducts actualGasCost from _deposits[paymaster]
```

**Assessment:** The flow is sound. XOM collection during validation (step 1) is the key security property. No state changes in the paymaster can be reverted by the user's callData because the fee transfer is atomic within validation.

### Paymaster <-> OmniRegistration Flow

```text
1. _determineSponsorMode(account):
   - Set isRegistered = registrationFailOpen (default policy)
   - If registration != address(0):
     - staticcall registration.isRegistered(account)
     - If ok && result >= 32 bytes: decode bool
     - If failed: emit RegistrationCheckFailed, keep default
   - Use isRegistered to gate free ops
```

**Assessment:** Sound. The staticcall prevents the registration contract from modifying paymaster state. The configurable fail-open/fail-closed policy provides operational flexibility. The event emission enables monitoring.

### Paymaster Drain Analysis

**Can an attacker drain the paymaster's EntryPoint deposit?**

| Attack Vector | Feasibility | Mitigation |
|---------------|-------------|------------|
| Spam free ops | Low | Daily budget (1000/day), registration check, per-account limit (10 ops) |
| Spam XOM payment ops | None | User pays XOM per op; paymaster deposit deduction is near-zero on L1 |
| Spam whitelisted ops | None | Only owner can whitelist; whitelisted accounts are trusted |
| Front-run budget reset at midnight | Low | Attacker gets at most 1 day's budget (1000 ops); on zero-gas chain, cost is negligible |
| Deploy many accounts via factory | Low | Factory rate limiting + registration requirement for free ops |
| Manipulate registration contract | Medium | If registration contract is compromised, attacker could bypass sybil checks; mitigated by daily budget cap |

**Worst-case scenario:** An attacker compromises the registration contract (or it becomes unavailable with `registrationFailOpen = true`), creates 1000 accounts via the factory, and each account consumes 10 free ops = 10,000 total ops. On a zero-gas chain, the total deposit deduction is near-zero. On a chain with $0.001/op gas, this costs the paymaster ~$10/day. The `dailySponsorshipBudget` limits this to 1000 ops/day, not 10,000.

**Assessment:** No viable economic drain vector on OmniCoin L1. On chains with meaningful gas prices, the daily budget should be calibrated carefully.

---

## Edge Case Analysis

### 1. Registration Contract Self-Destructs

If the registration contract `SELFDESTRUCT`s, subsequent `staticcall`s return `ok = true` with empty return data (`result.length == 0`). The `result.length > 31` check fails, so `isRegistered` defaults to `registrationFailOpen`. The `RegistrationCheckFailed` event is emitted. This is correct behavior.

### 2. Registration Contract Returns Non-Boolean

If the registration contract returns data that is not a valid ABI-encoded `bool` (e.g., a `uint256` or a string), `abi.decode(result, (bool))` will succeed as long as the data is 32 bytes. In Solidity, `abi.decode` interprets any non-zero value as `true` and zero as `false`. This is acceptable because the registration contract's `isRegistered` function is expected to return a `bool`.

### 3. Concurrent UserOps in Same Bundle

Multiple UserOps from different accounts in the same bundle each independently check the daily budget. The budget counter `dailySponsorshipUsed` is incremented sequentially within the same transaction (the EntryPoint processes ops sequentially in `handleOps`). There is no race condition because all ops execute in a single transaction.

### 4. freeOpsLimit Changed Mid-Operation

If the owner calls `setFreeOpsLimit` between a user's `validatePaymasterUserOp` and `postOp`, the `sponsoredOpsCount` increment in `postOp` uses the updated counter but does not re-check the limit. This is harmless because the mode was already determined during validation. The next operation will use the new limit.

### 5. Owner Transfer During Active Operation

If ownership is transferred via `Ownable.transferOwnership()` between validation and postOp, XOM fees from the validation phase were already sent to the previous owner. The new owner receives fees from subsequent operations. This is correct behavior -- the fee was collected at a point in time when the previous owner was the owner.

---

## Solhint Compliance

The contract passes solhint with zero findings (only two non-existent rule warnings from the config: `contract-name-camelcase` and `event-name-camelcase`). All `not-rely-on-time` usages are properly annotated with `solhint-disable-line` comments where business logic genuinely requires `block.timestamp` (daily budget resets, constructor initialization). The `avoid-low-level-calls` suppression for `withdrawDeposit` is appropriate since `IEntryPoint` does not expose `withdrawTo`.

---

## Gas Optimization Notes

The contract is already well-optimized:

1. Custom errors throughout (cheaper than `require` strings).
2. `++i` prefix increment in loops.
3. `calldata` for array parameters.
4. `immutable` for `entryPoint` and `xomToken`.
5. Constants for `DEFAULT_FREE_OPS`, `MAX_FREE_OPS`, `DEFAULT_XOM_GAS_FEE`.
6. Local variable caching (`uint256 fee = xomGasFee`, `uint256 len = accounts.length`).

No further gas optimizations recommended.

---

## Summary of Findings

| # | ID | Severity | Finding | Recommendation |
|---|-----|----------|---------|----------------|
| 1 | L-01 | Low | `xomGasFee` can be set to zero, disabling XOM payment mode | Add minimum validation or document the behavior |
| 2 | L-02 | Low | `whitelistAccountBatch` has no array length limit | Add `MAX_BATCH_SIZE` constant |
| 3 | I-01 | Info | Registration staticcall does not limit gas | Acceptable on L1; add gas limit if deployed on gas-priced chains |
| 4 | I-02 | Info | `sponsoredOpsCount` tracks all modes, not just free ops | Consider separate counter or rename for clarity |
| 5 | I-03 | Info | `XOMGasPayment` indexed `xomAmount` | Style preference; no change needed |
| 6 | I-04 | Info | Constructor hardcodes `dailySponsorshipBudget = 1000` | Consider constructor parameter for deployment flexibility |

---

## Conclusion

OmniPaymaster is in excellent condition after seven rounds of progressive hardening. All Critical, High, and Medium findings from prior audits have been fully remediated:

- **R3 H-01 (TOCTOU fee free-riding):** Eliminated by moving XOM fee collection to validation phase.
- **R3 H-02 (unsafe EntryPoint calls):** Fixed with typed interface and custom errors.
- **R3 M-01 through M-04:** All fixed (registration check, event gating, timestamp drift, token rescue).
- **R6 M-01 (fail-open registration):** Fixed with configurable `registrationFailOpen` policy and `RegistrationCheckFailed` event.
- **All Low findings from R3:** Fixed (underflow guard, configurable fee, batch whitelist).

The two remaining Low findings (zero-fee configuration, unbounded batch) are minor configuration concerns with no exploitability. The four Informational findings are style/documentation items.

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1.

The contract demonstrates mature security practices:
- Defense-in-depth (pre-checks before `safeTransferFrom`, even though the transfer itself validates)
- Configurable fail-open/fail-closed for external dependencies
- Off-chain monitoring hooks (`RegistrationCheckFailed` event)
- Clean separation of concerns (validation collects fees, postOp only tracks stats)
- Comprehensive NatSpec documentation with audit finding cross-references

**Deployment Recommendations:**
1. Set `registrationFailOpen = false` once OmniRegistration is stable and battle-tested.
2. Place owner behind a TimelockController or multisig for governance transparency.
3. Monitor `RegistrationCheckFailed` events to detect registration contract issues.
4. Calibrate `dailySponsorshipBudget` based on expected user traffic.
5. Ensure the paymaster's EntryPoint deposit is funded before enabling sponsorship.

---

*Report generated 2026-03-13*
*Methodology: 6-pass audit (solhint static analysis, access control mapping, reentrancy analysis, ERC-4337 compliance check, cross-contract interaction tracing, edge case enumeration)*
*Contract: OmniPaymaster.sol at 563 lines, Solidity 0.8.25*
*Prior audit history: Suite (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)*
