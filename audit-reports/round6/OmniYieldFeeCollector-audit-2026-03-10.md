# Security Audit Report: OmniYieldFeeCollector.sol

**Contract:** `contracts/yield/OmniYieldFeeCollector.sol`
**Lines:** 288
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-10
**Scope:** Yield fee collection, fee routing, accumulation, fee-on-transfer token handling
**Handles Funds:** Yes (collects performance fees from yield tokens and distributes them)

---

## Executive Summary

OmniYieldFeeCollector is a minimal, immutable contract that collects a performance fee on yield earned through OmniBazaar's DeFi integrations. The contract is well-designed with maximum immutability: all recipient addresses and the performance fee percentage are immutable (set at deployment). The contract uses balance-before/after to handle fee-on-transfer tokens. It is one of the cleanest contracts in this audit batch.

**Overall Risk Assessment: LOW**

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Architecture Review

- **Inheritance:** ReentrancyGuard only -- minimal attack surface
- **Upgradeability:** None (immutable deployment)
- **Fee cap:** Immutable `performanceFeeBps`, hard-capped at MAX_FEE_BPS (10% = 1000 bps)
- **Recipients:** All three recipients are immutable -- no post-deployment redirection
- **Token handling:** SafeERC20 with balance-before/after for fee-on-transfer support
- **Owner pattern:** No Ownable/AccessControl -- contract is fully autonomous after deployment

---

## Findings

### [LOW-01] Fee-on-Transfer Token Creates Rounding Dust Risk

**Severity:** Low
**Location:** Lines 186-198

```solidity
uint256 actualReceived =
    IERC20(token).balanceOf(address(this)) - balanceBefore;

uint256 totalFee =
    (actualReceived * performanceFeeBps) / BPS_DENOMINATOR;
uint256 netAmount = actualReceived - totalFee;
```

For fee-on-transfer (FoT) tokens, the contract correctly uses `actualReceived` for calculations. However, when distributing the fee to three recipients and the net amount back to the user, each `safeTransfer` may itself incur a transfer fee. This means:

1. `_distributeFee()` transfers `totalFee` split into 3 parts -- each part loses a fraction to the FoT tax
2. `safeTransfer(msg.sender, netAmount)` -- the user also receives less due to FoT tax

The total transferred out (primaryShare + oddaoShare + protocolShare + netAmount) should equal `actualReceived`. However, each of the 4 outgoing transfers incurs a FoT tax, so the contract will retain a small dust balance over time.

**Impact:** Negligible. The dust accumulation is tiny per transaction and can be recovered via `rescueTokens()`.

### [LOW-02] `rescueTokens()` Could Interfere with In-Flight Transactions

**Severity:** Low
**Location:** Lines 216-225

```solidity
function rescueTokens(address token) external nonReentrant {
    if (msg.sender != primaryRecipient) {
        revert NotPrimaryRecipient();
    }
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(primaryRecipient, balance);
        emit TokensRescued(token, balance);
    }
}
```

If `rescueTokens()` were called while `collectFeeAndForward()` is executing (for the same token), it could drain the contract's balance before the fee distribution completes. However, `nonReentrant` prevents this within a single transaction. In a multi-transaction scenario (two separate transactions in the same block), the `collectFeeAndForward()` transaction would either complete fully before `rescueTokens()` runs, or the balance check in `_distributeFee()` would cause a revert.

**Impact:** None in practice due to transaction atomicity and `nonReentrant`.

### [LOW-03] No ERC-2771/Meta-Transaction Support

**Severity:** Low / Design Observation
**Location:** Entire contract

Unlike other contracts in the OmniBazaar suite (OmniENS, OmniChatFee, OmniPredictionRouter), OmniYieldFeeCollector does not support ERC-2771 meta-transactions. The contract uses `msg.sender` directly (line 183, 202, 205) rather than `_msgSender()`.

**Impact:** Users cannot use gasless relay for yield fee collection. This is likely intentional since yield operations involve larger amounts where gas costs are proportionally insignificant.

**Recommendation:** No fix needed if gasless relay is not required for this contract.

### [LOW-04] Zero Fee Possible for Very Small Yield Amounts

**Severity:** Low
**Location:** Lines 190-191

```solidity
uint256 totalFee =
    (actualReceived * performanceFeeBps) / BPS_DENOMINATOR;
```

If `actualReceived * performanceFeeBps < BPS_DENOMINATOR`, the fee rounds to zero due to integer division. For example, with `performanceFeeBps = 500` (5%), any `actualReceived < 20` would result in zero fee.

In this case, `netAmount = actualReceived - 0 = actualReceived`, so the user gets back their full yield with no fee collected. The `if (totalFee > 0)` check on line 195 correctly skips fee distribution in this case.

**Impact:** Negligible. For real yield tokens (18 decimal places), the amount would need to be less than 20 wei for the fee to round to zero, which represents a negligible value.

### [INFO-01] Immutable Design is Excellent

**Status:** PASS

All critical parameters are immutable:
- `primaryRecipient` -- cannot be redirected
- `oddaoTreasury` -- cannot be redirected
- `protocolTreasury` -- cannot be redirected
- `performanceFeeBps` -- cannot be increased

This is the strongest possible trustless guarantee. Once deployed, the contract's behavior is fully deterministic and cannot be altered by any party.

### [INFO-02] Fee-on-Transfer Handling is Correct

**Status:** PASS

The balance-before/after pattern correctly handles FoT tokens:
```solidity
uint256 balanceBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), yieldAmount);
uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balanceBefore;
```

Fee and net calculations use `actualReceived`, not `yieldAmount`. This is correct.

### [INFO-03] Fee Distribution Arithmetic is Correct

**Status:** PASS

- Primary gets: `(totalFee * 7000) / 10000` = 70%
- ODDAO gets: `(totalFee * 2000) / 10000` = 20%
- Protocol gets: `totalFee - primaryShare - oddaoShare` = remainder (~10%)
- The remainder pattern avoids rounding dust loss
- All shares are guarded by `if > 0` checks before transfer

### [INFO-04] Constructor Validation is Thorough

**Status:** PASS

Constructor validates:
- All three recipient addresses are non-zero
- `performanceFeeBps` is non-zero (prevents useless deployment)
- `performanceFeeBps` does not exceed MAX_FEE_BPS (1000 = 10%)

---

## Access Control Review

| Function | Access | Assessment |
|----------|--------|------------|
| `collectFeeAndForward()` | Public + nonReentrant | Correct -- anyone can use |
| `rescueTokens()` | primaryRecipient only + nonReentrant | Correct |
| `calculateFee()` | Public view | Correct |

**Note:** The contract has no owner or admin. The only privileged function is `rescueTokens()`, restricted to `primaryRecipient`. This is a strong trustless design.

---

## Reentrancy Analysis

- `collectFeeAndForward()` uses `nonReentrant`
- `rescueTokens()` uses `nonReentrant`
- External calls:
  1. `safeTransferFrom` to pull yield tokens
  2. `safeTransfer` to distribute fees (3 calls) and forward net amount (1 call)
- All using SafeERC20

State modification (`totalFeesCollected += totalFee`) occurs between the pull and the distribution, but within the `nonReentrant` guard. CEI is not strictly followed (the pull occurs before the state update and distribution), but `nonReentrant` provides equivalent protection.

**Assessment:** No reentrancy risk.

---

## DeFi-Specific Analysis

### Yield Inflation Attack
- Not applicable. The contract does not custody funds between transactions or maintain share/vault accounting. It is a pure pass-through fee collector.

### Flash Loan Attack
- Not applicable. No price calculations, no collateral ratios, no lending/borrowing.

### Front-Running
- No meaningful front-running opportunity. Each user collects their own yield fees independently.

### Double-Spend / Re-Entrancy
- Protected by `nonReentrant` modifier.

---

## Comparison with Other Fee Contracts

| Feature | OmniYieldFeeCollector | OmniChatFee | OmniENS |
|---------|----------------------|-------------|---------|
| Recipients | Immutable | **Mutable** | Immutable |
| Fee Rate | Immutable | **Mutable** | **Mutable** (bounded) |
| Owner | None | Ownable2Step | Ownable2Step |
| FoT Support | Yes | No | No |
| ERC-2771 | No | Yes | Yes |
| Complexity | Low | Medium | Medium |

OmniYieldFeeCollector has the strongest trustless guarantees of the three fee-collecting contracts.

---

## Conclusion

OmniYieldFeeCollector is an exemplary minimalist contract. Its fully immutable design eliminates entire classes of attacks (admin key compromise, fee manipulation, recipient redirection). The balance-before/after pattern correctly handles fee-on-transfer tokens. The only findings are informational edge cases. The contract is ready for mainnet deployment without modifications.

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| LOW-01 | Low | FoT tokens create small dust accumulation | Negligible, rescueTokens available |
| LOW-02 | Low | rescueTokens could theoretically interfere | Protected by nonReentrant |
| LOW-03 | Low | No ERC-2771 meta-transaction support | Design Decision |
| LOW-04 | Low | Zero fee for sub-wei yield amounts | Negligible |
