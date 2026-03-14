# Security Audit Report: OmniEntryPoint.sol (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/account-abstraction/OmniEntryPoint.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 770
**Upgradeable:** No (immutable singleton deployment)
**Handles Funds:** Yes (native token deposits, gas accounting, beneficiary refunds)
**Dependencies:** `ReentrancyGuard` (OpenZeppelin 5.x), `IEntryPoint`, `IAccount`, `IPaymaster` (custom)
**Previous Audits:** Round 3 (2026-02-26, 3C/3H/4M/4L/3I), Round 6 (2026-03-10, 0C/0H/2M/3L/3I)

---

## Executive Summary

OmniEntryPoint is the singleton ERC-4337 EntryPoint contract for the OmniCoin L1 chain. It processes batches of UserOperations submitted by bundlers, handling account deployment via initCode, nonce validation, account signature verification, paymaster sponsorship, execution, gas accounting, and beneficiary refunds.

This Round 7 audit reviews the contract after all Round 3 Critical/High findings and all Round 6 Medium findings were remediated. The contract is at 770 lines -- a significant maturation from 494 lines (initial) and 749 lines (Round 6). The code quality is high: NatSpec is thorough, custom errors are used throughout, and the architecture follows the canonical ERC-4337 flow closely.

**All prior Critical, High, and Medium findings are verified as remediated.** This audit identified no new Critical or High issues. Two new Low findings and three Informational findings were identified.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 3 |

---

## Remediation Status from All Prior Audits

### Round 3 (2026-02-26) -- All Remediated

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| R3 C-01 | Critical | Deposit deduction underflow causes DoS | **FIXED** -- `_deductGasCost` (lines 515-527) uses underflow-safe deduction with `GasDeficit` event |
| R3 C-02 | Critical | Beneficiary refund desynchronizes deposit ledger | **FIXED** -- `_refundBeneficiary` (lines 574-590) credits refund back to payer if ETH transfer fails |
| R3 C-03 | Critical | Paymaster validationData silently discarded | **FIXED** -- `_validatePaymaster` (lines 445-460) captures and validates `pmValidationData` via `_extractSigResult` |
| R3 H-01 | High | withdrawTo lacks reentrancy protection | **FIXED** -- `withdrawTo` (line 181) and `depositTo` (line 165) both carry `nonReentrant` |
| R3 H-02 | High | No verification account paid missingFunds | **FIXED** -- `_validateAccountSig` (lines 411-433) captures deposit-before, verifies deposit-after >= deposit-before + missingFunds |
| R3 H-03 | High | Factory deployment not gas-limited | **FIXED** -- `_deployAccount` (line 613) uses `gas: op.verificationGasLimit` |
| R3 M-01 | Medium | Code existence not verified after initCode deployment | **FIXED** -- `_ensureAccountDeployed` (line 397) checks `op.sender.code.length == 0` post-deploy |
| R3 M-02 | Medium | Gas accounting lacks overhead constant | **FIXED** -- `GAS_OVERHEAD = 40_000` (line 46), `GAS_OVERHEAD_WITH_PAYMASTER = 60_000` (line 52) |
| R3 M-03 | Medium | handleOps does not isolate individual failures | **FIXED** -- try/catch via external `handleSingleOp` self-call (lines 218-228) |
| R3 M-04 | Medium | _accountPrefund underflow when maxGasCost is 0 | **FIXED** -- Explicit `maxGasCost == 0` early return (line 682) |
| R3 L-01 | Low | Paymaster deposit validation missing | **FIXED** -- `_validatePaymaster` checks `_deposits[paymaster] < maxCost` (line 451) |
| R3 L-02 | Low | Nonce increment ordering | **Acknowledged** -- Documented in NatSpec (lines 636-651) |
| R3 L-03 | Low | No events for deposit/withdrawal | **FIXED** -- `Deposited`, `Withdrawn`, `GasDeficit` events added and emitted |
| R3 L-04 | Low | MAX_OP_GAS lacks maxFeePerGas relationship | **FIXED** -- `MAX_OP_COST = 100 ether` (line 40), checked at line 363 |
| R3 I-01 | Info | Double hash computation in _deployAccount | **FIXED** -- Pre-computed `userOpHash` passed as parameter (line 367) |
| R3 I-02 | Info | receive() vs depositTo() inconsistency | **FIXED** -- NatSpec updated (lines 141-147) |
| R3 I-03 | Info | Missing ERC-165 support | **Acknowledged** -- Acceptable for private L1 |

### Round 6 (2026-03-10) -- All Remediated

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| R6 M-01 | Medium | handleSingleOp uses misleading `InvalidBeneficiary` error | **FIXED** -- Dedicated `OnlySelf()` error (line 128), used at line 247 |
| R6 M-02 | Medium | Fixed gas overhead for paymaster vs non-paymaster paths | **FIXED** -- Dynamic overhead: `GAS_OVERHEAD_WITH_PAYMASTER = 60_000` for paymaster path, `GAS_OVERHEAD = 40_000` for non-paymaster path (lines 46-52, 487-489) |
| R6 L-01 | Low | Silent aggregator rejection in _extractSigResult | **Acknowledged** -- Returns `SIG_INVALID`; no dedicated error needed on private L1 |
| R6 L-02 | Low | receive() lacks nonReentrant | **FIXED** -- NatSpec (lines 141-147) documents why receive() intentionally lacks nonReentrant (accounts send prefund via plain ETH transfer during validateUserOp inside handleOps) |
| R6 L-03 | Low | MAX_OP_COST set to 100 ether may be too generous | **Acknowledged** -- Appropriate for L1 with near-zero gas economics |

---

## Detailed Code Review

### Contract Architecture

```text
handleOps(ops[], beneficiary)                    [nonReentrant]
  |
  for each op:
    try this.handleSingleOp(op, beneficiary)      [msg.sender == address(this)]
      |
      _handleSingleOp(op, beneficiary)
        |
        Phase 1: _validateOp(op)
        |   |-- Gas limit checks (MAX_OP_GAS, MAX_OP_COST)
        |   |-- getUserOpHash(op)
        |   |-- _ensureAccountDeployed(op, hash) [gas-limited factory, code existence]
        |   |-- _validateNonce(sender, nonce) [key + sequential]
        |   |-- _validateAccountSig(op, hash) [verifies prefund via deposit delta]
        |   |-- _validatePaymaster(op, hash, pm, maxCost) [deposit check + validationData]
        |
        Phase 2: op.sender.call{gas: callGasLimit}(op.callData)
        |
        Phase 3: _settleGas(op, hash, gasStart, pm, ctx, success, beneficiary)
            |-- _deductGasCost(payer, actualGasCost) [underflow-safe, GasDeficit event]
            |-- _callPaymasterPostOp(pm, ctx, success, cost) [with revert + retry]
            |-- emit UserOperationEvent
            |-- _refundBeneficiary(beneficiary, payer, cost) [credits payer on refund failure]
    catch:
      emit UserOperationRevertReason
```

### Role and Privilege Map

| Role | Capabilities | Enforcement |
|------|-------------|-------------|
| **Bundler** (any EOA) | Call `handleOps` with arbitrary UserOps; designate a `beneficiary` to receive gas refunds | No access control -- any address can call `handleOps` |
| **Account** (smart contract at `op.sender`) | Validate UserOps via `validateUserOp`; execute arbitrary callData; pay prefund to EntryPoint | Validated via `_validateAccountSig`; must have code at `op.sender` |
| **Paymaster** (smart contract at `paymasterAndData[:20]`) | Sponsor gas for UserOps; run post-op accounting | Validated via `_validatePaymaster`; must have deposit >= `maxCost` |
| **Factory** (smart contract at `initCode[:20]`) | Deploy new accounts via CREATE2 | Gas-limited to `verificationGasLimit`; deployed address verified |
| **Depositors** (any address) | Deposit via `depositTo()` or `receive()`; withdraw via `withdrawTo()` | CEI pattern; `nonReentrant` on `depositTo` and `withdrawTo` |
| **Beneficiary** (any address) | Receive gas refunds | Set by bundler; validated as non-zero |

**No admin role, no owner, no upgradeability.** The contract is a fully permissionless singleton.

---

### Reentrancy Analysis

The reentrancy model is well-designed and correctly handles all relevant paths:

| Entry Point | nonReentrant | Can Be Called During handleOps? | Security Impact |
|-------------|-------------|-------------------------------|-----------------|
| `handleOps` | Yes | No (revert) | Prevents batch nesting |
| `depositTo` | Yes | No (revert) | Prevents deposit manipulation during execution |
| `withdrawTo` | Yes | No (revert) | Prevents deposit drain during execution |
| `receive()` | No | **Yes** (by design) | Benign -- only increases deposits; required for account prefund payments |
| `handleSingleOp` | No | Only by `address(this)` | Guarded by `OnlySelf()` check at line 246 |
| `balanceOf` | N/A (view) | Yes | No state changes |
| `getNonce` | N/A (view) | Yes | No state changes |
| `getUserOpHash` | N/A (view) | Yes | No state changes |

**Assessment:** The reentrancy model is correct. The intentional omission of `nonReentrant` on `receive()` is properly documented (lines 141-147) and necessary for the prefund payment flow. All state-mutating external functions that could be exploited during `handleOps` execution are protected.

### Access Control Analysis

| Function | Access Control | Correctness |
|----------|---------------|-------------|
| `handleOps` | None (permissionless) | Correct -- bundlers are untrusted; security comes from per-op validation |
| `handleSingleOp` | `msg.sender == address(this)` | Correct -- only callable via self-call from `handleOps` try/catch |
| `depositTo` | None (permissionless) + `nonReentrant` | Correct -- anyone can deposit for anyone |
| `withdrawTo` | `msg.sender` based deposit check + `nonReentrant` | Correct -- can only withdraw own deposit |
| `receive()` | None (permissionless) | Correct -- credits sender |
| `balanceOf` | None (view) | Correct |
| `getNonce` | None (view) | Correct |
| `getUserOpHash` | None (view) | Correct |

**Assessment:** Access control is correct. The contract is permissionless by design, with security enforcement delegated to the account/paymaster validation layer.

### ERC-4337 UserOp Validation Flow Audit

**Step 0 -- Gas limit checks (lines 358-363):**
- `totalGas = callGasLimit + verificationGasLimit + preVerificationGas` checked against `MAX_OP_GAS = 10_000_000`. Correct.
- `maxCost = totalGas * maxFeePerGas` checked against `MAX_OP_COST = 100 ether`. Correct.
- No overflow risk: `totalGas` capped at 10M, `maxFeePerGas` is a uint256 but the multiplication cannot realistically overflow with 10M gas (would need `maxFeePerGas > 2^256 / 10^7`). Safe.

**Step 1 -- Account deployment (lines 366-367, 390-403):**
- Hash is pre-computed and passed to `_deployAccount` (avoids double hashing). Correct.
- `_ensureAccountDeployed` handles both initCode-present and initCode-absent cases. Correct.
- Factory call gas-limited to `verificationGasLimit` (line 613). Correct.
- Return data decoded to verify deployed address matches `op.sender` (lines 619-624). Correct.
- Post-deployment code existence check (lines 396-399). Correct.
- Post-existence check for non-initCode ops (lines 400-402). Correct.

**Step 2 -- Nonce validation (line 370):**
- Key extracted from upper 192 bits, seq from lower 64 bits (lines 656-657). Correct.
- Sequential nonce enforced per (sender, key) pair. Correct.
- Nonce incremented before account validation; safe because all failures revert the entire `_handleSingleOp` call. Documented in NatSpec (lines 636-651).

**Step 3 -- Account signature validation (line 373):**
- `missingFunds` computed via `_accountPrefund` (lines 674-687). Correct.
- `depositBefore` captured (line 416). Correct.
- `validateUserOp` called (line 417). Correct.
- `validationData` passed through `_extractSigResult` with SIG_VALID/SIG_INVALID check (line 420). Correct.
- Post-call deposit delta verified: `_deposits[op.sender] >= depositBefore + missingFunds` (lines 424-432). Correct.
- `_accountPrefund` correctly returns 0 when paymaster is present (line 678). Correct.
- `_accountPrefund` handles `maxGasCost == 0` explicitly (line 682). Correct.

**Step 4 -- Paymaster validation (lines 376-381):**
- Paymaster address extracted from `paymasterAndData[:20]` (lines 741-743). Correct.
- Paymaster deposit checked against `maxCost` (line 451). Correct.
- `validatePaymasterUserOp` called (lines 455-456). Correct.
- `pmValidationData` validated via `_extractSigResult` (lines 457-459). Correct.

**Execution phase (lines 324-332):**
- Call to `op.sender` with `callGasLimit` gas cap (lines 324-326). Correct.
- Revert reason emitted on failure (lines 328-332). Correct.

**Gas settlement (lines 335-338, 475-504):**
- `gasStart` captured at beginning of `_handleSingleOp` (line 313). Correct.
- Dynamic overhead based on paymaster presence: 60,000 with paymaster, 40,000 without (lines 487-489). Correct.
- `actualGasCost = actualGasUsed * tx.gasprice` (line 491). Correct.
- Payer determined: paymaster if present, else sender (lines 492-494). Correct.
- `_deductGasCost` is underflow-safe (lines 515-527). Correct.
- `_callPaymasterPostOp` has retry logic with `postOpReverted` mode (lines 538-562). Correct per ERC-4337 spec.
- `_refundBeneficiary` credits payer on transfer failure (lines 574-590). Correct.

### _extractSigResult Validation Data Parsing (lines 699-724)

```solidity
address aggregator = address(uint160(validationData));
if (aggregator == address(1)) return SIG_INVALID;
if (aggregator != address(0)) return SIG_INVALID;

uint48 validUntil = uint48(validationData >> 160);
uint48 validAfter = uint48(validationData >> 208);

if (validUntil != 0 && block.timestamp > validUntil) return SIG_INVALID;
if (validAfter != 0 && block.timestamp < validAfter) return SIG_INVALID;

return SIG_VALID;
```

**Analysis:**
- Aggregator extraction: lower 160 bits via `address(uint160(...))`. Correct ERC-4337 packing.
- `address(1)` = SIG_INVALID sentinel. Correct.
- Any other non-zero aggregator rejected. Correct for a system without aggregator support.
- `validUntil` extraction: bits 160-207 via `uint48(validationData >> 160)`. Correct.
- `validAfter` extraction: bits 208-255 via `uint48(validationData >> 208)`. Correct.
- Time-range validation: `validUntil` of 0 means no expiry (correct), `validAfter` of 0 means immediately valid (correct).
- `block.timestamp` usage: appropriate for time-range validation; `not-rely-on-time` warnings suppressed with solhint comments.

**Edge case:** If `validUntil == validAfter` and both are non-zero and equal to `block.timestamp`, then `block.timestamp > validUntil` is false (not expired) and `block.timestamp < validAfter` is false (already active). The operation is valid for a single block. This is correct behavior.

### UserOpHash Construction (lines 286-296, 751-768)

```solidity
function getUserOpHash(UserOperation calldata userOp) public view returns (bytes32) {
    return keccak256(abi.encode(
        _hashUserOpFields(userOp),
        address(this),
        block.chainid
    ));
}
```

**Replay protection analysis:**
- Includes `address(this)`: prevents replay across different EntryPoint deployments on the same chain. Correct.
- Includes `block.chainid`: prevents cross-chain replay. Correct.
- `_hashUserOpFields` encodes all UserOp fields including `keccak256(initCode)`, `keccak256(callData)`, `keccak256(paymasterAndData)`. Correct -- dynamic-length fields are hashed before encoding to prevent ABI encoding ambiguity.
- `signature` field is NOT included in the hash (correct per ERC-4337 -- the signature IS the authorization of the hash).
- `nonce` is included, providing replay protection within the same (chain, EntryPoint) context.

**Assessment:** Hash construction is correct and complete per ERC-4337 specification.

### Nonce Key System Edge Cases

The nonce system supports 2^192 parallel nonce sequences per account. Key analysis:

1. **Key = 0 (default):** Standard sequential nonce. Works correctly.
2. **Key overflow:** A uint192 key cannot overflow because it is derived from the upper bits of the full nonce via casting. The `uint192(fullNonce >> 64)` extraction is safe.
3. **Sequential counter overflow:** The counter is a uint256 (from `_nonceSequences` mapping) but only 64 bits are meaningful. After 2^64 operations on a single key, `seq` wraps to 0 while `currentSeq` is 2^64, causing all subsequent ops on that key to fail. However, 2^64 operations is unreachable in practice. Not a concern.
4. **Concurrent sequences:** Different keys maintain independent counters. A failure on key=0 does not affect key=1. Correct.

---

## Findings

### [L-01] Paymaster PostOp Gas Not Bounded -- Malicious Paymaster Can Consume Arbitrary Gas in PostOp

**Severity:** Low
**Lines:** 550-561 (`_callPaymasterPostOp`)
**Category:** Gas Accounting / Griefing

**Description:**

The `_callPaymasterPostOp` function calls `IPaymaster(paymaster).postOp(...)` without a gas limit:

```solidity
try IPaymaster(paymaster).postOp(
    mode, paymasterContext, actualGasCost
) {
    // PostOp succeeded
} catch {
    // PostOp reverted - retry with postOpReverted mode
    try IPaymaster(paymaster).postOp(
        IPaymaster.PostOpMode.postOpReverted,
        paymasterContext,
        actualGasCost
    ) {} catch {}
}
```

Unlike the factory call (which is gas-limited to `verificationGasLimit`) and the execution call (which is gas-limited to `callGasLimit`), the postOp call has no gas cap. A malicious or buggy paymaster can consume arbitrary gas during postOp, which is charged to the bundler but only partially compensated via the `GAS_OVERHEAD_WITH_PAYMASTER` constant (60,000 gas).

In the worst case (postOp reverts, retry also consumes significant gas), the bundler bears the cost of two unbounded external calls. The `actualGasCost` was already computed before `_callPaymasterPostOp` is called (line 491), so this additional gas consumption is not deducted from the paymaster's deposit.

On OmniCoin L1 where gas is near-zero, the financial impact is negligible. However, a malicious paymaster could use this to slow down batch processing and consume block gas limits, degrading throughput for other UserOps in the batch.

**Mitigating factors:**
- The paymaster voluntarily opted into processing this UserOp via `validatePaymasterUserOp`.
- On a private L1 with known paymasters, rogue paymaster behavior is unlikely.
- The canonical eth-infinitism EntryPoint also does not gas-limit postOp calls (by design, since postOp gas is included in `verificationGasLimit` budget in the canonical implementation, but the gas metering approach is different).

**Impact:** Low. On a zero-gas chain, the economic impact is negligible. A rogue paymaster can slow batch processing but cannot extract funds.

**Recommendation:** Document that postOp gas is not bounded and is not fully covered by the 60,000 overhead. If precise gas accounting is ever needed, consider gas-limiting postOp to `verificationGasLimit - gasUsedInValidation` or tracking postOp gas consumption as part of `actualGasCost`.

---

### [L-02] Beneficiary Refund Uses address(this).balance Which Includes All User Deposits

**Severity:** Low
**Lines:** 579-583 (`_refundBeneficiary`)
**Category:** Gas Accounting / Deposit Isolation

**Description:**

The `_refundBeneficiary` function computes the refund amount as:

```solidity
uint256 refund = actualGasCost < address(this).balance
    ? actualGasCost
    : address(this).balance;
```

The `min(actualGasCost, address(this).balance)` cap is a safety measure to prevent sending more ETH than the contract holds. However, `address(this).balance` includes ALL user deposits, not just the gas cost for the current operation. In normal operation this is not an issue because `actualGasCost` should always be much less than `address(this).balance`.

The scenario where `actualGasCost > address(this).balance` can occur if:
1. The `_deductGasCost` deficit path triggers (payer has insufficient deposit), deducting less than `actualGasCost` from the ledger.
2. The contract's actual balance has been drained by previous refunds below the total deposit obligations.

When this happens, `address(this).balance` is used as the refund cap, meaning the beneficiary receives ETH that belongs to other depositors. This socializes the gas deficit across all depositors rather than isolating it to the underfunded payer.

However, this is mitigated by the comprehensive prefund verification (deposit-before/deposit-after check in `_validateAccountSig`, deposit-minimum check in `_validatePaymaster`). For the deficit to occur, the actual gas consumed must exceed the pre-validated deposit, which requires the post-execution overhead (settle, postOp, refund) to exceed the payer's remaining deposit after execution. Given the validation checks, this gap should be small.

**Impact:** Low. The deposit isolation concern is theoretical given the comprehensive validation checks. On a zero-gas chain, deposit amounts and gas costs are both near-zero.

**Recommendation:** No code change required. The existing design is acceptable as a defense-in-depth measure. If strict deposit isolation is desired, consider tracking the exact amount deducted in `_deductGasCost` and using that as the refund cap instead of `address(this).balance`.

---

### [I-01] handleOps Accepts Empty Batch

**Severity:** Informational
**Lines:** 207-229 (`handleOps`)

**Description:**

`handleOps` accepts `ops.length == 0`, consuming gas for the `nonReentrant` lock acquisition and beneficiary validation without processing any operations. This is a negligible griefing vector since the bundler pays for the wasted gas.

The canonical eth-infinitism EntryPoint does not enforce a minimum batch size either, so this is consistent.

**Impact:** None. Bundler pays for wasted gas on empty batches.

**Recommendation:** No change required. Optionally, add `require(ops.length > 0)` for cleanliness.

---

### [I-02] _accountPrefund Uses Greater-Than Comparison Instead of Greater-Than-or-Equal

**Severity:** Informational
**Lines:** 685 (`_accountPrefund`)

**Description:**

```solidity
if (currentDeposit > maxGasCost - 1) return 0;
return maxGasCost - currentDeposit;
```

The pattern `currentDeposit > maxGasCost - 1` is equivalent to `currentDeposit >= maxGasCost` (for non-zero `maxGasCost`, which is guaranteed by the preceding `maxGasCost == 0` check). While the result is identical, the `>= maxGasCost` form is more immediately readable.

**Impact:** None. The logic is correct.

**Recommendation:** Consider using the more conventional form for clarity:
```solidity
if (currentDeposit >= maxGasCost) return 0;
```

---

### [I-03] Event Indexed Parameters May Exceed Three Per Event

**Severity:** Informational
**Lines:** 72-75 (`Deposited`), 81-85 (`Withdrawn`), 90-93 (`GasDeficit`)

**Description:**

The Solidity compiler enforces a maximum of 3 indexed parameters per event. Current events:

- `Deposited(address indexed, uint256 indexed)` -- 2 indexed. Fine.
- `Withdrawn(address indexed, address indexed, uint256 indexed)` -- 3 indexed. Fine.
- `GasDeficit(address indexed, uint256 indexed)` -- 2 indexed. Fine.
- `UserOperationEvent` (from IEntryPoint) -- 3 indexed (`userOpHash`, `sender`, `paymaster`). Fine.
- `AccountDeployed` (from IEntryPoint) -- 3 indexed (`userOpHash`, `sender`, `factory`). Fine.
- `UserOperationRevertReason` (from IEntryPoint) -- 3 indexed (`userOpHash`, `sender`, `nonce`). Fine.

All events are within the 3-indexed-parameter limit. However, `Withdrawn` uses all 3 indexed slots for value types, which means no non-indexed parameters remain for filtering. The `amount` field being indexed is unusual -- `indexed` on `uint256` values creates individual topic entries rather than enabling range queries. Typically, `amount` would be non-indexed to allow inclusion in the event data for efficient retrieval.

**Impact:** None. All events compile correctly. The indexing choices may slightly affect off-chain indexing performance but have no on-chain impact.

**Recommendation:** Consider making `amount` in `Withdrawn` non-indexed for more conventional event design:
```solidity
event Withdrawn(address indexed account, address indexed withdrawAddress, uint256 amount);
```

---

## Cross-Contract Interaction Analysis

### OmniEntryPoint <-> OmniAccount Interaction

| Interaction | Direction | Safety |
|-------------|-----------|--------|
| `validateUserOp(op, hash, missingFunds)` | EntryPoint -> Account | Safe: deposit-before/after check verifies prefund payment |
| `op.sender.call{gas: callGasLimit}(callData)` | EntryPoint -> Account | Safe: gas-limited; account uses `nonReentrant` and `onlyOwnerOrEntryPoint` |
| Account sends ETH to EntryPoint (prefund) | Account -> EntryPoint | Safe: arrives via `receive()`, credits account's deposit |
| Account calls `depositTo` during execution | Account -> EntryPoint | **Blocked**: `nonReentrant` on `depositTo` reverts during `handleOps` |
| Account calls `withdrawTo` during execution | Account -> EntryPoint | **Blocked**: `nonReentrant` on `withdrawTo` reverts during `handleOps` |

**Assessment:** All interaction paths are safe. The reentrancy guard correctly prevents deposit manipulation during execution, while allowing legitimate prefund payments via `receive()`.

### OmniEntryPoint <-> OmniPaymaster Interaction

| Interaction | Direction | Safety |
|-------------|-----------|--------|
| `validatePaymasterUserOp(op, hash, maxCost)` | EntryPoint -> Paymaster | Safe: paymaster deposit checked beforehand; validationData validated |
| `postOp(mode, context, actualGasCost)` | EntryPoint -> Paymaster | Safe: wrapped in try/catch with retry; gas unlimited (see L-01) |
| Paymaster calls `depositTo` on EntryPoint | Paymaster -> EntryPoint | **Blocked during handleOps**: `nonReentrant` on `depositTo` |

**Assessment:** Interaction is safe. The paymaster cannot manipulate its deposit during `handleOps` execution.

### OmniEntryPoint <-> OmniAccountFactory Interaction

| Interaction | Direction | Safety |
|-------------|-----------|--------|
| `factory.call{gas: verificationGasLimit}(factoryData)` | EntryPoint -> Factory | Safe: gas-limited; return address verified; code existence checked |

**Assessment:** Factory interaction is properly sandboxed.

---

## ERC-4337 Compliance Assessment

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Batch UserOp processing | PASS | `handleOps` at lines 207-229 |
| Individual op failure isolation | PASS | try/catch via `handleSingleOp` at lines 218-228 |
| Nonce validation (key + sequential) | PASS | `_validateNonce` at lines 655-664 |
| UserOpHash (chain-scoped) | PASS | `getUserOpHash` includes `chainid` + `address(this)` at lines 286-296 |
| Account signature validation | PASS | `_validateAccountSig` with `_extractSigResult` at lines 411-433 |
| Paymaster validation + validationData | PASS | `_validatePaymaster` captures and checks `pmValidationData` at lines 445-460 |
| Time-range validation (validUntil/validAfter) | PASS | `_extractSigResult` at lines 699-724 |
| Account prefund verification | PASS | Deposit-before/after delta check at lines 424-432 |
| Factory gas limiting | PASS | `gas: op.verificationGasLimit` at line 613 |
| Factory code existence check | PASS | Post-deploy `code.length` check at lines 396-399 |
| Gas overhead accounting | PASS | Dynamic overhead (40k/60k) at lines 487-491 |
| Deposit/withdrawal events | PASS | `Deposited`, `Withdrawn`, `GasDeficit` events |
| Paymaster postOp with retry | PASS | `_callPaymasterPostOp` with `postOpReverted` mode at lines 538-562 |
| Aggregator support | N/A | Intentionally omitted (private L1, ECDSA/passkey only) |
| Staking for paymasters/factories | N/A | Intentionally omitted (private L1, known bundlers) |
| simulateValidation / simulateHandleOp | N/A | Intentionally omitted (private L1) |
| ERC-165 supportsInterface | N/A | Intentionally omitted |

**Compliance:** PASS on all applicable ERC-4337 v0.6 requirements. Non-applicable items are documented omissions appropriate for a private L1.

---

## Gas Optimization Notes

1. **Custom errors throughout:** Correct, gas-efficient.
2. **`++i` prefix increment:** Used in all loops. Correct.
3. **`calldata` parameters:** All UserOperation parameters use `calldata`. Correct.
4. **Cached array length:** `ops.length` cached in `opsLength` at line 213. Correct.
5. **Pre-computed hash passed to _deployAccount:** Eliminates double hashing. Correct.
6. **`_maxOperationCost` called twice:** Once in `_validateOp` (line 362) and once in `_accountPrefund` (line 680). The second call could reuse a cached value, saving ~200 gas per non-paymaster UserOp. This is a micro-optimization with negligible impact.
7. **Dynamic overhead selection:** Uses ternary (line 487-489) instead of an if-else, which is slightly more gas-efficient.

---

## Upgrade Safety

The contract is **not upgradeable** by design. There is:
- No proxy pattern
- No `Initializable` inheritance
- No owner or admin role
- No `selfdestruct`
- No `delegatecall` (except within OZ's ReentrancyGuard, which is safe)

The contract is intended as a permanent singleton. If a bug is discovered post-deployment, a new EntryPoint must be deployed and all accounts/paymasters must migrate. This is the standard ERC-4337 approach and is the correct design for an EntryPoint.

---

## Summary of Findings

| # | ID | Severity | Finding | Recommendation |
|---|-----|----------|---------|----------------|
| 1 | L-01 | Low | Paymaster postOp gas not bounded | Document; consider gas-limiting if precise accounting needed |
| 2 | L-02 | Low | Beneficiary refund uses `address(this).balance` (all deposits) as cap | Acceptable; theoretical concern mitigated by validation checks |
| 3 | I-01 | Info | handleOps accepts empty batch | Optional: add `require(ops.length > 0)` |
| 4 | I-02 | Info | `> maxGasCost - 1` vs `>= maxGasCost` readability | Optional: use conventional `>=` form |
| 5 | I-03 | Info | `Withdrawn` event uses all 3 indexed slots | Optional: make `amount` non-indexed |

---

## Conclusion

OmniEntryPoint has reached production quality for mainnet deployment on OmniCoin L1. Across three audit rounds:

- **Round 3** identified 3 Critical, 3 High, 4 Medium, 4 Low, and 3 Informational findings.
- **Round 6** confirmed all Critical, High, and prior Medium findings were remediated, and identified 2 new Medium findings.
- **Round 7** (this audit) confirms all prior Medium findings are also remediated, and identifies no new Critical, High, or Medium issues.

The contract now correctly implements all applicable ERC-4337 EntryPoint responsibilities:

1. **Reentrancy protection** on all state-mutating deposit/withdrawal functions, with `receive()` intentionally unguarded for prefund payments.
2. **Complete validation** of account and paymaster signatures including time-range enforcement.
3. **Prefund verification** via deposit-before/deposit-after delta checks.
4. **Failure isolation** via try/catch on each UserOp within the batch.
5. **Gas accounting** with dynamic overhead constants (40k no-paymaster, 60k with paymaster).
6. **Underflow-safe deposit deduction** with `GasDeficit` event for monitoring.
7. **Failed refund handling** that credits the payer rather than silently losing funds.
8. **Factory sandboxing** with gas limits and post-deployment code verification.
9. **Cross-chain/cross-EntryPoint replay prevention** via chainid and address in hash.

The two remaining Low findings are theoretical edge cases with negligible impact on a zero-gas chain. The three Informational findings are style/convention observations with no security implications.

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1.

---

*Report generated 2026-03-13 21:00 UTC*
*Methodology: Manual code review (reentrancy, access control, ERC-4337 spec compliance, gas accounting, cross-contract interaction analysis, upgrade safety, prior audit remediation verification)*
*Tool: solhint (zero findings)*
*Contract: OmniEntryPoint.sol at 770 lines, Solidity 0.8.25*
