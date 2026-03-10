# Security Audit Report: OmniEntryPoint.sol (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Opus 4.6, 6-Pass Enhanced)
**Contract:** `Coin/contracts/account-abstraction/OmniEntryPoint.sol`
**Solidity Version:** 0.8.25 (pinned)
**Lines of Code:** 749
**Upgradeable:** No (immutable deployment)
**Handles Funds:** Yes (native token deposits, gas accounting, beneficiary refunds)
**Dependencies:** `ReentrancyGuard` (OZ 5.x), `IEntryPoint`, `IAccount`, `IPaymaster` (custom)
**Previous Audits:** Round 3 (2026-02-26, 3C/3H/4M/4L/3I), Suite audit (2026-02-21)

---

## Executive Summary

OmniEntryPoint is the singleton ERC-4337 EntryPoint contract for the OmniCoin L1 chain. It processes batches of UserOperations submitted by bundlers, handling account deployment via initCode, nonce validation, account signature verification, paymaster sponsorship, operation execution, gas accounting, and beneficiary refunds.

This Round 6 audit reviews the contract after extensive remediation of Round 3 findings. The contract has grown from 494 lines to 749 lines, incorporating fixes for all three Critical findings and all three High findings from the prior audit.

**Remediation quality is HIGH.** All Critical and High findings from Round 3 have been addressed with correct implementations. One new Medium issue was introduced during remediation, and several Low/Informational items remain or are new.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | handleSingleOp external exposure allows direct invocation by attackers (mitigated but fragile) | **FIXED** |
| M-02 | Medium | Gas overhead is fixed at 40,000 but actual post-execution cost varies significantly | **FIXED** |

---

## Remediation Status from Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| R3 C-01: Deposit deduction underflow causes DoS | Critical | **Fixed** | `_deductGasCost` (lines 494-506) now uses underflow-safe deduction: deducts available amount, emits `GasDeficit` for shortfall instead of reverting. |
| R3 C-02: Beneficiary refund desynchronizes deposit ledger | Critical | **Fixed** | `_refundBeneficiary` (lines 553-569) now credits refund back to payer's deposit if ETH transfer to beneficiary fails (line 567). Uses `min(actualGasCost, address(this).balance)` as safety cap. |
| R3 C-03: Paymaster validationData silently discarded | Critical | **Fixed** | `_validatePaymaster` (lines 430-445) now captures `pmValidationData`, calls `_extractSigResult()` and reverts with `PaymasterValidationFailed` if invalid. |
| R3 H-01: withdrawTo lacks reentrancy protection | High | **Fixed** | Both `withdrawTo` (line 168) and `depositTo` (line 152) now have `nonReentrant` modifier. Calls from within `handleOps` will correctly revert. |
| R3 H-02: No verification account paid missingFunds | High | **Fixed** | `_validateAccountSig` (lines 396-418) now captures `depositBefore`, calls `validateUserOp`, and verifies `_deposits[op.sender] >= depositBefore + missingFunds`. |
| R3 H-03: Factory deployment not gas-limited | High | **Fixed** | `_deployAccount` (line 592) now passes `gas: op.verificationGasLimit` to the factory call. |
| R3 M-01: Code existence not verified after initCode deployment | Medium | **Fixed** | `_ensureAccountDeployed` (line 382) now checks `op.sender.code.length == 0` after `_deployAccount` and reverts with `AccountDeploymentFailed`. |
| R3 M-02: Gas accounting lacks overhead constant | Medium | **Fixed** | `GAS_OVERHEAD = 40_000` constant added (line 46). `_settleGas` (line 469) adds overhead: `(gasStart - gasleft()) + GAS_OVERHEAD`. |
| R3 M-03: handleOps does not isolate individual failures | Medium | **Fixed** | `handleOps` (lines 194-216) now wraps each op in `try this.handleSingleOp(...) catch`. `handleSingleOp` is external with `msg.sender == address(this)` check. |
| R3 M-04: _accountPrefund underflow when maxGasCost is 0 | Medium | **Fixed** | `_accountPrefund` (line 661) now explicitly handles `maxGasCost == 0` with early return. |
| R3 L-01: Paymaster deposit validation missing before execution | Low | **Fixed** | `_validatePaymaster` (line 436) now checks `_deposits[paymaster] < maxCost` before calling `validatePaymasterUserOp`. |
| R3 L-02: Nonce increment ordering | Low | **Acknowledged** | Documented in NatSpec (lines 617-631). Safe because all failures revert the entire `_handleSingleOp` call. |
| R3 L-03: No events for deposit/withdrawal | Low | **Fixed** | `Deposited` (lines 66-69), `Withdrawn` (lines 75-79), and `GasDeficit` (lines 84-87) events added and emitted. |
| R3 L-04: MAX_OP_GAS lacks maxFeePerGas relationship | Low | **Fixed** | `MAX_OP_COST = 100 ether` constant added (line 40). `_validateOp` (line 348) checks `maxCost > MAX_OP_COST`. |
| R3 I-01: getUserOpHash called twice (double hashing) | Info | **Fixed** | `_deployAccount` (line 584) now receives pre-computed `userOpHash` parameter. |
| R3 I-02: receive() vs depositTo() inconsistency | Info | **Improved** | `receive()` NatSpec (lines 131-134) now documents that direct ETH credits the sender's EOA, not a smart account. |
| R3 I-03: Missing ERC-165 support | Info | **Acknowledged** | Not implemented. Acceptable for private L1 with known bundlers. |

---

## Detailed Code Review

### Architecture (Post-Remediation)

The contract now follows a much closer approximation of the canonical ERC-4337 EntryPoint:

```text
handleOps(ops[], beneficiary)                [nonReentrant]
  |
  for each op:
    try this.handleSingleOp(op, beneficiary)  [msg.sender == address(this)]
      |
      _handleSingleOp(op, beneficiary)
        |
        Phase 1: _validateOp(op)
        |   |-- Gas limit checks (MAX_OP_GAS, MAX_OP_COST)
        |   |-- _ensureAccountDeployed(op, hash) [gas-limited factory call]
        |   |-- _validateNonce(sender, nonce)
        |   |-- _validateAccountSig(op, hash) [verifies prefund payment]
        |   |-- _validatePaymaster(op, hash, pm, maxCost) [checks deposit + validationData]
        |
        Phase 2: Execute op.callData via op.sender.call{gas: callGasLimit}
        |
        Phase 3: _settleGas(op, hash, gasStart, pm, ctx, success, beneficiary)
            |-- _deductGasCost(payer, actualGasCost) [underflow-safe]
            |-- _callPaymasterPostOp(pm, ctx, success, cost) [with retry]
            |-- emit UserOperationEvent
            |-- _refundBeneficiary(beneficiary, payer, cost) [credits payer on failure]
    catch:
      emit UserOperationRevertReason
```

### Strengths of Current Implementation

1. **Comprehensive reentrancy protection.** `handleOps`, `depositTo`, and `withdrawTo` all carry `nonReentrant`. A smart account executing a UserOp cannot call back into deposit/withdrawal functions during execution since `handleOps` holds the lock.

2. **Correct failure isolation.** Each UserOp is wrapped in try/catch via the external `handleSingleOp` self-call pattern. One failed op does not abort the batch.

3. **Proper prefund verification.** The deposit-before/deposit-after check in `_validateAccountSig` ensures the account actually pays `missingFunds`, closing the free-gas vector.

4. **Paymaster validationData fully processed.** `_extractSigResult` is called on both account and paymaster validation data, including time-range validation (`validUntil`, `validAfter`).

5. **Gas accounting with overhead.** The 40,000 gas overhead constant compensates for post-execution bookkeeping, reducing systematic bundler undercompensation.

6. **UserOpHash includes chain protection.** Hash construction at lines 271-281 includes `address(this)` and `block.chainid`, preventing cross-chain and cross-EntryPoint replay.

---

## Medium Findings

### [M-01] handleSingleOp External Exposure Allows Direct Invocation by Attackers (Mitigated but Fragile)

**Severity:** Medium
**Lines:** 226-235 (`handleSingleOp`)
**Category:** Access Control

**Description:**

The try/catch isolation pattern requires `handleSingleOp` to be `external` so it can be called via `this.handleSingleOp()`. The function includes a guard:

```solidity
function handleSingleOp(
    UserOperation calldata op,
    address payable beneficiary
) external {
    if (msg.sender != address(this)) {
        revert InvalidBeneficiary();
    }
    _handleSingleOp(op, beneficiary);
}
```

The `msg.sender != address(this)` check correctly prevents external callers from invoking this function directly. However:

1. **Error semantics are misleading.** The function reverts with `InvalidBeneficiary()` when the actual issue is unauthorized access. This makes debugging and monitoring more difficult.

2. **The function processes a single UserOp without the `nonReentrant` guard.** It relies on `handleOps` holding the reentrancy lock. If `handleSingleOp` were ever called from a context where `nonReentrant` is not held (e.g., a future function that delegates to it), the reentrancy protection would be bypassed.

3. **The function is visible in the ABI.** External tooling, bundlers, and indexers see `handleSingleOp` as a callable function. A bundler that mistakenly calls it directly (instead of `handleOps`) would get a confusing `InvalidBeneficiary` revert.

**Impact:** No direct security vulnerability exists today because the `msg.sender == address(this)` check is sound. The risks are: (a) misleading error on unauthorized access, and (b) fragile reentrancy protection that depends on the calling context.

**Recommendation:**

1. Use a dedicated error: `error OnlySelf();` instead of repurposing `InvalidBeneficiary()`.
2. Consider adding `nonReentrant` directly to `handleSingleOp` as defense-in-depth. Since `handleOps` already holds the lock, the modifier on `handleSingleOp` would revert if called from a non-self context that somehow bypasses the `msg.sender` check (belt-and-suspenders). Note: this means `handleSingleOp` called from `handleOps` would also need the lock -- but `nonReentrant` uses a single status variable, so a nested call from within a `nonReentrant` context would revert. The current pattern of `handleOps` (nonReentrant) calling `this.handleSingleOp` (not nonReentrant) is correct; adding `nonReentrant` to `handleSingleOp` would break it. Therefore, only fix (1) is recommended.

---

### [M-02] Gas Overhead Is Fixed at 40,000 but Actual Post-Execution Cost Varies Significantly

**Severity:** Medium
**Lines:** 46 (`GAS_OVERHEAD`), 469 (`actualGasUsed` computation)
**Category:** Gas Accounting

**Description:**

The `GAS_OVERHEAD` constant is set to 40,000 gas. The actual post-execution gas consumption varies depending on the code path:

| Operation | Gas Cost (Approximate) |
|-----------|----------------------|
| `_deductGasCost` (SSTORE cold) | 20,000 |
| `_deductGasCost` (SSTORE warm) | 5,000 |
| `_callPaymasterPostOp` (no paymaster) | 200 |
| `_callPaymasterPostOp` (success) | 2,100 + postOp gas |
| `_callPaymasterPostOp` (revert + retry) | 4,200 + 2x postOp gas |
| `emit UserOperationEvent` | 2,000-3,000 |
| `_refundBeneficiary` (success) | 2,100-9,000 |
| `_refundBeneficiary` (failure, credit back) | 5,000 |

**Scenario analysis:**
- **No paymaster, cold storage:** ~20,000 + 3,000 + 6,000 = ~29,000. Overhead of 40,000 is generous -- bundler overcompensated by ~11,000 gas.
- **With paymaster, postOp reverts + retry:** ~5,000 + 30,000 + 3,000 + 6,000 = ~44,000. Overhead of 40,000 is insufficient -- bundler undercompensated by ~4,000 gas.
- **With paymaster, postOp succeeds + large state changes:** Could exceed 40,000 if the paymaster's `postOp` is gas-intensive.

On OmniCoin L1 where gas is effectively free, the financial impact is negligible. However, the deposit ledger and ETH balance can still drift: if the overhead underestimates, the payer's deposit is under-deducted relative to the actual gas consumed. Over many operations, `sum(_deposits) > address(this).balance` becomes possible, meaning late withdrawers cannot withdraw fully.

**Impact:** On a zero-gas L1, the impact is minimal. If gas pricing is ever enabled (see CLAUDE.md mention of "adjust for OmniCoin L1 economics"), this becomes a solvency concern for the deposit system.

**Recommendation:**

1. Document that 40,000 is calibrated for the no-paymaster path and that paymaster postOp gas is not fully covered.
2. Consider making `GAS_OVERHEAD` a state variable configurable by the contract deployer, or computing it dynamically based on whether a paymaster is present:

```solidity
uint256 overhead = paymaster != address(0) ? 60_000 : 40_000;
uint256 actualGasUsed = (gasStart - gasleft()) + overhead;
```

3. For precise accounting, capture gas after the `_settleGas` function completes (difficult in the current architecture since the cost calculation is inside `_settleGas`).

---

## Low Findings

### [L-01] _extractSigResult Rejects All Non-Zero Aggregators but Error Is Silent

**Severity:** Low
**Lines:** 678-703 (`_extractSigResult`)
**Category:** ERC-4337 Compliance

**Description:**

The function correctly rejects unknown aggregators by returning `SIG_INVALID` for any non-zero address other than `address(1)`:

```solidity
address aggregator = address(uint160(validationData));
if (aggregator == address(1)) return SIG_INVALID;
if (aggregator != address(0)) return SIG_INVALID;
```

This is correct for a system that does not support aggregators. However, if a paymaster or account returns a non-zero aggregator address (indicating it wants aggregated validation), the rejection is silent -- the caller (`_validateAccountSig` or `_validatePaymaster`) sees `SIG_INVALID` and reverts with `AccountValidationFailed` or `PaymasterValidationFailed`, giving no indication that the real issue is an unsupported aggregator.

**Impact:** Debugging difficulty for developers implementing custom accounts or paymasters that attempt to use aggregation. No security impact.

**Recommendation:** Consider a dedicated error or log for the aggregator case to aid debugging:

```solidity
if (aggregator != address(0) && aggregator != address(1)) {
    // Could emit an event or use a specific error for unsupported aggregator
    return SIG_INVALID;
}
```

---

### [L-02] receive() Deposit Is Not Protected by nonReentrant

**Severity:** Low
**Lines:** 135-138 (`receive`)
**Category:** Reentrancy

**Description:**

The `receive()` function credits `msg.sender`'s deposit and emits an event but does not have the `nonReentrant` modifier:

```solidity
receive() external payable {
    _deposits[msg.sender] += msg.value;
    emit Deposited(msg.sender, _deposits[msg.sender]);
}
```

While `depositTo()` is protected by `nonReentrant`, the `receive()` function allows ETH deposits during `handleOps` execution. A smart account executing a UserOp could send ETH to the EntryPoint (via a call to the EntryPoint address with no calldata), triggering `receive()` and increasing its deposit mid-execution.

However, this is benign: the deposit increase occurs before `_settleGas`, which deducts gas costs from the updated deposit. The account is paying more into its deposit, not extracting. If anything, this helps the account avoid a `GasDeficit` event.

The `nonReentrant` modifier cannot be added to `receive()` because `handleOps` already holds the lock, and legitimate deposit payments during `validateUserOp` (when the account sends `missingFunds` to the EntryPoint) arrive through `receive()` or `depositTo()`. Since `depositTo()` has `nonReentrant`, accounts paying their prefund must use `receive()` (plain ETH transfer) rather than `depositTo()`.

**Impact:** No security impact. The `receive()` pathway is actually necessary for prefund payments from accounts during `handleOps`.

**Recommendation:** Add a NatSpec comment explaining why `receive()` intentionally lacks `nonReentrant`:

```solidity
/// @dev Does NOT use nonReentrant because accounts send prefund
///      payments via plain ETH transfer during validateUserOp,
///      which occurs inside handleOps (nonReentrant held).
receive() external payable {
```

---

### [L-03] MAX_OP_COST Set to 100 Ether May Be Too Generous

**Severity:** Low
**Lines:** 40 (`MAX_OP_COST`)
**Category:** Configuration

**Description:**

`MAX_OP_COST` is set to `100 ether`, which on OmniCoin L1 represents 100 native tokens. The comment says "adjust for OmniCoin L1 economics." If the native token on OmniCoin L1 has real monetary value (even if gas is near-zero), allowing a single UserOp to declare a `maxFeePerGas` that produces a 100-token cost obligation creates a large deposit requirement.

A paymaster with 100 native tokens deposited could have its entire deposit locked up by a single pending UserOp's `maxCost` check at `_validatePaymaster` line 436. While this is by design (the paymaster needs sufficient deposit), the 100-token cap may allow griefing where an attacker submits UserOps with inflated `maxFeePerGas` to force the paymaster to maintain very large deposits.

**Impact:** On a zero-gas chain, `maxFeePerGas` is typically set to very low values, making this largely theoretical. If gas pricing is enabled, the cap should be revisited.

**Recommendation:** Consider reducing `MAX_OP_COST` to a value aligned with OmniCoin L1 economics (e.g., `1 ether` or `10 ether`), or making it configurable.

---

## Informational Findings

### [I-01] UserOpHash Is Computed Before Account Deployment

**Severity:** Informational
**Lines:** 351 (`userOpHash = getUserOpHash(op)`) vs 352 (`_ensureAccountDeployed`)

**Description:**

The UserOp hash is computed at line 351, before `_ensureAccountDeployed` is called at line 352. This means the hash is computed regardless of whether the account will be successfully deployed. If deployment fails, the hash computation gas is wasted.

However, the hash is needed for the `AccountDeployed` event (emitted inside `_deployAccount` at line 606), so pre-computing it is correct and the `_deployAccount` function receives it as a parameter (fixing the R3 I-01 double-hashing issue).

**Impact:** None. The ordering is intentional and correct.

---

### [I-02] handleOps Has No Minimum Batch Size Check

**Severity:** Informational
**Lines:** 194-216

**Description:**

`handleOps` accepts an empty array (`ops.length == 0`), which causes the function to consume gas (nonReentrant lock acquisition) without processing any operations. This is a negligible griefing vector.

**Recommendation:** Consider adding `if (ops.length == 0) revert InvalidBeneficiary();` at the start, or accept this as harmless.

---

### [I-03] GasDeficit Event Could Enable Deposit Solvency Monitoring

**Severity:** Informational
**Lines:** 84-87 (`GasDeficit` event), 499-502

**Description:**

The `GasDeficit` event is emitted when a payer's deposit is insufficient to cover `actualGasCost`. This is a valuable addition for off-chain monitoring. However, when a deficit occurs:

1. `_deposits[payer]` is set to 0 (line 501).
2. The deficit amount (`actualGasCost - deposit`) is emitted but not tracked on-chain.
3. The beneficiary refund at `_refundBeneficiary` still attempts to send `actualGasCost` worth of ETH, capped by `address(this).balance`.

If the payer's deposit was insufficient, the ETH for the refund comes from other users' deposits (since `address(this).balance` is the sum of all deposits minus previous refunds). This means a deficit effectively socializes the loss across all depositors.

**Impact:** On a zero-gas chain, the amounts involved are negligible. The `GasDeficit` event enables off-chain detection and remediation. No code change needed, but validators should monitor for this event and blacklist accounts/paymasters that trigger it.

---

## Cross-Contract AA Attack Analysis

### Attack 1: Malicious UserOp That Drains Paymaster

**Scenario:** Attacker crafts a UserOp with a paymaster, sets extremely high `maxFeePerGas` to maximize `maxCost`, and provides a valid paymaster signature.

**Mitigations present:**
- `MAX_OP_COST = 100 ether` caps the cost obligation (line 348).
- `_validatePaymaster` checks `_deposits[paymaster] < maxCost` (line 436).
- The paymaster's `validatePaymasterUserOp` can reject the operation.
- Gas accounting deducts only `actualGasCost`, not `maxCost`.

**Assessment:** **Mitigated.** The paymaster's deposit is charged based on actual gas, not maximum. The paymaster can reject any UserOp in `validatePaymasterUserOp`.

### Attack 2: EntryPoint Reentrancy Through Account Execution

**Scenario:** During `op.sender.call(op.callData)` at line 309, the account calls back into `depositTo()`, `withdrawTo()`, or `handleOps()`.

**Mitigations present:**
- `handleOps` holds `nonReentrant` lock.
- `depositTo` and `withdrawTo` have `nonReentrant` -- will revert if called during `handleOps`.
- `receive()` does not have `nonReentrant` but only increases deposits (benign).

**Assessment:** **Mitigated.** The reentrancy guard prevents all meaningful reentrant calls. The only unguarded path (`receive()`) is beneficial, not harmful.

### Attack 3: Cross-Chain UserOp Replay

**Scenario:** Attacker takes a valid UserOp from OmniCoin L1 and submits it on another chain with the same EntryPoint deployment.

**Mitigations present:**
- `getUserOpHash` includes `block.chainid` (line 279).
- The hash also includes `address(this)` (line 278), which differs across deployments.

**Assessment:** **Mitigated.** Both chain ID and EntryPoint address are included in the hash.

### Attack 4: Malicious Bundler Stealing Funds

**Scenario:** A bundler sets `beneficiary` to their own address and submits UserOps that maximize gas consumption.

**Mitigations present:**
- The beneficiary only receives `actualGasCost` (the gas actually consumed), not `maxCost`.
- Gas is bounded by `MAX_OP_GAS` (10M) and `MAX_OP_COST` (100 ETH equivalent).
- The bundler pays the actual gas of the `handleOps` transaction; they only profit if `actualGasCost > transactionGasCost`.

**Assessment:** **By design.** The bundler is compensated for gas consumed, which is the correct ERC-4337 economic model. A malicious bundler cannot extract more than the actual gas cost from deposits.

---

## ERC-4337 Compliance Assessment (Post-Remediation)

| Requirement | Status | Notes |
|-------------|--------|-------|
| Batch UserOp processing | PASS | `handleOps` processes arrays |
| Individual op failure isolation | PASS | try/catch via `handleSingleOp` (R3 M-03 fix) |
| Nonce validation (key + sequential) | PASS | 192-bit key + 64-bit seq |
| UserOpHash (chain-scoped) | PASS | Includes chainid + EntryPoint address |
| Account signature validation | PASS | `validateUserOp` + sig result check |
| Paymaster validation + validationData | PASS | Now checks validationData (R3 C-03 fix) |
| Time-range validation (validUntil/validAfter) | PASS | `_extractSigResult` handles both |
| Account prefund verification | PASS | Deposit-before/after check (R3 H-02 fix) |
| Factory gas limiting | PASS | `verificationGasLimit` gas cap (R3 H-03 fix) |
| Factory code existence check | PASS | Post-deploy code length check (R3 M-01 fix) |
| Gas overhead accounting | PASS | 40,000 overhead constant (R3 M-02 fix) |
| Deposit/withdrawal events | PASS | Events added (R3 L-03 fix) |
| Aggregator support | N/A | Intentionally omitted (private L1) |
| Staking for paymasters/factories | N/A | Intentionally omitted (private L1) |
| simulateValidation / simulateHandleOp | N/A | Intentionally omitted (private L1) |
| ERC-165 supportsInterface | N/A | Intentionally omitted |

**Compliance score:** PASS on all applicable requirements. Non-applicable items (aggregator, staking, simulation, ERC-165) are documented omissions appropriate for a private L1 with known bundlers.

---

## Summary of Recommendations

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | M-01 | Medium | Use a dedicated `OnlySelf()` error instead of `InvalidBeneficiary()` in `handleSingleOp` |
| 2 | M-02 | Medium | Document that 40,000 overhead is calibrated for no-paymaster path; consider dynamic overhead based on paymaster presence |
| 3 | L-01 | Low | Consider logging or using a specific error for unsupported aggregator rejection |
| 4 | L-02 | Low | Add NatSpec explaining why `receive()` intentionally lacks `nonReentrant` |
| 5 | L-03 | Low | Consider reducing `MAX_OP_COST` for OmniCoin L1 economics |
| 6 | I-01 | Info | No action needed |
| 7 | I-02 | Info | Consider empty batch check |
| 8 | I-03 | Info | Monitor `GasDeficit` events for deposit solvency |

---

## Conclusion

OmniEntryPoint has been comprehensively remediated since the Round 3 audit. All three Critical findings (deposit underflow DoS, beneficiary refund desync, paymaster validationData bypass) and all three High findings (withdrawTo reentrancy, prefund verification, factory gas limit) have been properly fixed. The contract now correctly implements the core ERC-4337 EntryPoint responsibilities:

- **Proper failure isolation** via try/catch on each UserOp
- **Correct gas accounting** with overhead constant
- **Complete validation** of both account and paymaster signatures including time ranges
- **Reentrancy protection** on all deposit/withdrawal entry points
- **Prefund verification** ensuring accounts pay for their gas obligations

The remaining two Medium findings are: (1) a misleading error message in `handleSingleOp` (no security impact, just debugging friction), and (2) the fixed gas overhead not fully covering paymaster postOp scenarios (minimal impact on zero-gas chain).

**Overall Risk Assessment: LOW** -- suitable for mainnet deployment on OmniCoin L1. The contract has matured significantly from its initial version and now provides robust ERC-4337 compliance for a private L1 chain.

---

*Report generated 2026-03-10*
*Methodology: 6-pass audit (static analysis, OWASP SC Top 10, ERC-4337 spec compliance, prior audit remediation verification, cross-contract AA attack analysis, report generation)*
*Contract: OmniEntryPoint.sol at 749 lines, Solidity 0.8.25*
