# Security Audit Report: OmniPredictionRouter.sol

**Contract:** `contracts/predictions/OmniPredictionRouter.sol`
**Lines:** 625
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-10
**Scope:** Prediction market routing, fee collection, trade execution, sweep mechanics, platform allowlisting
**Handles Funds:** Yes (atomically routes collateral to prediction markets with fee extraction)
**Previous Audit Fixes Incorporated:** M-01 (FoT detection), M-02 (donation attack), M-03 (gas reserve), M-04 (code check)

---

## Executive Summary

OmniPredictionRouter is a trustless fee-collecting router for prediction market trades on Polymarket (Polygon) and Omen (Gnosis). The contract collects a capped fee atomically and forwards the net amount to the target platform. The contract is well-designed with comprehensive security measures including platform allowlisting, fee cap enforcement, fee-on-transfer detection, donation attack mitigation, and gas reserve for post-call operations. Previous audit fixes are correctly implemented.

**Overall Risk Assessment: LOW**

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Architecture Review

- **Inheritance:** Ownable2Step, ReentrancyGuard, ERC1155Holder, ERC2771Context
- **Token handling:** SafeERC20 for all ERC-20 transfers; ERC-1155 safe transfers for outcome tokens
- **Upgradeability:** None (immutable deployment)
- **Fee cap:** Immutable MAX_FEE_BPS set at deployment, hard-capped at 10% (1000 bps)
- **Platform security:** Allowlist-based with code existence check (M-04)
- **Ownership:** renounceOwnership() disabled -- correct for a fee-collecting router

---

## Findings

### [LOW-01] `feeCollector` Is Mutable Without Timelock

**Severity:** Low
**Location:** Lines 188-196

```solidity
function setFeeCollector(
    address feeCollector_
) external onlyOwner {
    if (feeCollector_ == address(0)) revert InvalidFeeCollector();
    address oldCollector = feeCollector;
    feeCollector = feeCollector_;
    emit FeeCollectorUpdated(oldCollector, feeCollector_);
}
```

The contract acknowledges this in comments (line 186: "Pioneer Phase: no timelock"). A compromised owner could redirect all collected fees to a malicious address. However, since fees are collected and forwarded atomically (never held between transactions), the impact is limited to redirecting fees from the point of change forward.

**Impact:** Low. Fees already collected are already distributed. Only future fees would be redirected.

**Recommendation:** Add a timelock before mainnet multi-sig handoff, as the comment suggests.

### [LOW-02] `rescueTokens()` Sends All Tokens to `feeCollector`

**Severity:** Low
**Location:** Lines 415-421

```solidity
function rescueTokens(address token) external nonReentrant onlyOwner {
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(feeCollector, balance);
        emit TokensRescued(token, balance);
    }
}
```

This only rescues ERC-20 tokens. If ERC-1155 tokens (Polymarket CTF outcome tokens) get stuck in the contract (e.g., due to a failed sweep), there is no rescue mechanism for them.

**Impact:** Low. The sweep mechanism (buyWithFeeAndSweepERC1155) should prevent tokens from getting stuck. An ERC-1155 rescue function could be added for completeness.

**Recommendation:** Consider adding an `rescueERC1155()` function for stuck ERC-1155 tokens.

### [LOW-03] Gas Reserve Subtraction Could Underflow

**Severity:** Low
**Location:** Line 492

```solidity
uint256 gasForCall = gasleft() - GAS_RESERVE;
```

If `gasleft()` is less than `GAS_RESERVE` (50,000), this subtraction underflows in Solidity 0.8.24 and reverts. This would happen if the transaction was sent with very low gas.

**Impact:** The transaction would revert, which is actually the correct behavior -- there would not be enough gas to complete the post-call operations anyway. The revert message would be an arithmetic underflow rather than a descriptive error, but the outcome is correct.

**Recommendation:** No fix strictly needed. For clarity, consider adding `require(gasleft() > GAS_RESERVE, "insufficient gas")` before the subtraction.

### [LOW-04] Platform Approval Does Not Check Code Length

**Severity:** Low
**Location:** Lines 205-212

```solidity
function setPlatformApproval(
    address platform,
    bool approved
) external onlyOwner {
    if (platform == address(0)) revert InvalidPlatformTarget();
    approvedPlatforms[platform] = approved;
    emit PlatformApprovalChanged(platform, approved);
}
```

`setPlatformApproval()` does not verify that the platform address has deployed code. However, `_validatePlatformTarget()` (line 525) performs the code length check at trade execution time, which provides adequate protection. The concern is that an EOA could be approved and then later have code deployed at that address (via CREATE2), but this is an unlikely attack vector and the approval is owner-controlled.

**Impact:** Negligible. Runtime validation in `_validatePlatformTarget()` provides adequate protection.

### [INFO-01] Fee-on-Transfer Detection Correctly Implemented

**Status:** PASS

The balance-before/after pattern in `_executeTrade()` (lines 473-481) correctly detects fee-on-transfer tokens and reverts with `FeeOnTransferNotSupported()`. This prevents the contract from under-collateralizing trades.

### [INFO-02] Donation Attack Mitigation Correctly Implemented

**Status:** PASS

Both `buyWithFeeAndSweep()` and `buyWithFeeAndSweepERC1155()` use balance-before/after to calculate `outcomeReceived` as a delta (M-02 fix). This prevents attackers from pre-loading the contract with outcome tokens to manipulate sweep amounts.

### [INFO-03] Platform Target Validation is Comprehensive

**Status:** PASS

`_validatePlatformTarget()` checks:
1. Not zero address
2. On approved platforms list
3. Not the collateral token itself
4. Not the router contract itself
5. Has deployed code (M-04)

This prevents all known attack vectors involving malicious platform targets.

### [INFO-04] Deadline Protection Present

**Status:** PASS

All three buy functions accept a `deadline` parameter that reverts if `block.timestamp > deadline`. This provides MEV protection by letting users control the transaction expiry window.

### [INFO-05] Approval Reset After Trade

**Status:** PASS

`_executeTrade()` resets the collateral token approval to zero after the platform call (line 500). This prevents lingering approvals that could be exploited in subsequent transactions.

---

## Access Control Review

| Function | Access | Assessment |
|----------|--------|------------|
| `buyWithFee()` | Public + nonReentrant | Correct |
| `buyWithFeeAndSweep()` | Public + nonReentrant | Correct |
| `buyWithFeeAndSweepERC1155()` | Public + nonReentrant | Correct |
| `setFeeCollector()` | onlyOwner | Correct (consider timelock) |
| `setPlatformApproval()` | onlyOwner | Correct |
| `rescueTokens()` | onlyOwner + nonReentrant | Correct |
| `renounceOwnership()` | Disabled (always reverts) | Correct |

---

## Reentrancy Analysis

- All three buy functions use `nonReentrant`
- `rescueTokens()` uses `nonReentrant`
- The contract makes external calls to:
  1. Collateral token (ERC-20) via SafeERC20 -- safe
  2. Platform target via low-level `call` -- protected by nonReentrant
  3. Outcome token (ERC-20 or ERC-1155) for sweep -- protected by nonReentrant
- The contract inherits ERC1155Holder which implements `onERC1155Received` -- this is a callback that could be triggered during ERC-1155 transfers, but nonReentrant prevents re-entry

**Assessment:** No reentrancy risk.

---

## DeFi-Specific Analysis

### Sandwich Attack Protection
- Deadline parameter prevents delayed execution
- Fee cap is immutable, preventing dynamic fee manipulation
- `minOutcome` parameter on sweep functions provides slippage protection

### Oracle Manipulation
- Not applicable (contract does not use price oracles)

### Flash Loan Attack
- Not applicable (contract does not custody funds between transactions)

### Front-Running
- Platform calls are user-initiated with user-specified parameters
- Fee amounts are calculated off-chain and validated on-chain against the immutable cap
- No meaningful front-running opportunity

---

## Conclusion

OmniPredictionRouter is a well-designed, security-conscious contract. The previous audit fixes (M-01 through M-04) are correctly implemented. The remaining findings are low-severity and mostly involve edge cases or future improvements (timelock, ERC-1155 rescue). The contract is suitable for mainnet deployment with the caveat that a timelock should be added to `setFeeCollector()` before multi-sig handoff.

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| LOW-01 | Low | `feeCollector` mutable without timelock | Planned Fix (Pioneer Phase) |
| LOW-02 | Low | No ERC-1155 rescue function | Recommend Addition |
| LOW-03 | Low | Gas reserve subtraction could show unhelpful error | Informational |
| LOW-04 | Low | Platform approval does not check code length | Runtime Check Sufficient |
