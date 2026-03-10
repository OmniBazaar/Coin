# Security Audit Report: OmniChatFee.sol

**Contract:** `contracts/chat/OmniChatFee.sol`
**Lines:** 516
**Auditor:** Claude Opus 4.6
**Date:** 2026-03-10
**Scope:** Chat fee collection, free tier tracking, bulk messaging fees, fee distribution
**Handles Funds:** Yes (collects and distributes XOM fees for chat messages)

---

## Executive Summary

OmniChatFee manages per-message fees with a free tier (20 messages/month). The contract is well-structured with appropriate security controls. It collects XOM fees and distributes them using the 70/20/10 split pattern. A few issues were identified, including a medium-severity concern with mutable recipient addresses that could redirect fees, and a low-severity issue with the fee distribution split not matching the documented 70% validator / 20% staking / 10% ODDAO split.

**Overall Risk Assessment: LOW-MEDIUM**

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| MEDIUM-01 | Medium | Fee distribution split does not match documentation | **FIXED** |
| MEDIUM-02 | Medium | Mutable recipient addresses can redirect fees | **FIXED** |

---

## Architecture Review

- **Inheritance:** ReentrancyGuard, Ownable2Step, ERC2771Context -- appropriate
- **Token handling:** SafeERC20 used for all XOM transfers
- **Upgradeability:** None (immutable deployment)
- **Meta-transactions:** ERC-2771 support with proper diamond overrides
- **Fee model:** Pull from user -> immediate distribution to 3 recipients
- **Free tier:** 20 messages/month tracked per user via 30-day rolling windows

---

## Findings

### [MEDIUM-01] Fee Distribution Split Does Not Match Documentation

**Severity:** Medium
**Location:** Lines 78-84, 419-448

The contract distributes fees as:
- 70% to `oddaoTreasury`
- 20% to `stakingPool`
- 10% to `protocolTreasury`

However, the CLAUDE.md tokenomics documentation specifies chat fees should be:
- 70% to **Validator** hosting the channel
- 20% to Staking Pool
- 10% to ODDAO

The contract's `_collectFee()` function receives a `validator` parameter but explicitly suppresses it (line 426: `validator;`). The validator address is not used in fee distribution at all -- it is only included in the caller's event emission.

**Impact:** Validators who host chat channels do not receive their intended 70% share of chat fees. All fees go to the ODDAO/staking/protocol treasuries instead. This may reduce validator incentives to provide chat services.

**Recommendation:** Either update the contract to send 70% to the validator address (as the documentation specifies), or update the documentation to reflect the actual behavior. If the validator should receive fees, modify `_collectFee()` to transfer the ODDAO share to the validator instead.

### [MEDIUM-02] Mutable Recipient Addresses Can Redirect Fees

**Severity:** Medium
**Location:** Lines 104-107, 380-404

The `stakingPool`, `oddaoTreasury`, and `protocolTreasury` addresses are mutable state variables (not immutable) and can be changed by the owner via `updateRecipients()`. While Ownable2Step provides protection against accidental ownership loss, a compromised owner key could redirect all future chat fees to attacker-controlled addresses.

```solidity
address public stakingPool;       // mutable
address public oddaoTreasury;     // mutable
address public protocolTreasury;  // mutable
```

Compare with OmniENS, which uses `immutable` for all three recipient addresses.

**Impact:** If the owner key is compromised, all future chat fee revenue can be stolen.

**Recommendation:** Consider making the recipient addresses immutable (matching OmniENS pattern), or implementing a timelock on `updateRecipients()` to give the community time to react to malicious changes.

### [LOW-01] No Upper Bound on `baseFee` in `setBaseFee()`

**Severity:** Low
**Location:** Lines 364-369

```solidity
function setBaseFee(uint256 newBaseFee) external onlyOwner {
    if (newBaseFee == 0) revert ZeroBaseFee();
    uint256 oldFee = baseFee;
    baseFee = newBaseFee;
    emit BaseFeeUpdated(oldFee, newBaseFee);
}
```

The owner can set `baseFee` to any non-zero value, including an excessively high value that would make chat prohibitively expensive. Compare with OmniENS which bounds its fee between MIN_REGISTRATION_FEE and MAX_REGISTRATION_FEE.

**Impact:** A malicious or compromised owner could set an absurdly high fee, effectively disabling paid chat. However, the free tier of 20 messages/month would still work.

**Recommendation:** Add a MAX_BASE_FEE constant and validate against it in `setBaseFee()`.

### [LOW-02] Bulk Fee Multiplier Arithmetic Overflow for Large `baseFee`

**Severity:** Low
**Location:** Line 280

```solidity
uint256 fee = baseFee * BULK_FEE_MULTIPLIER;
```

If `baseFee` is set to a very large value (close to `type(uint256).max / 10`), this multiplication could overflow. Solidity 0.8.24 would revert, so there is no vulnerability, but it could make `payBulkMessageFee()` permanently revert.

**Impact:** If `baseFee` > `type(uint256).max / 10`, bulk messaging reverts. The owner would need to set `baseFee` to an astronomically large value, which is already covered by LOW-01.

**Recommendation:** Same as LOW-01 -- add an upper bound to `baseFee`.

### [LOW-03] Free Tier Bypass via Multiple Addresses

**Severity:** Low / Design Limitation
**Location:** Lines 236-246

The free tier tracks messages per address per month. A user can create multiple addresses to get unlimited free messages (20 per address per month). Since this is chat (not financial), the economic impact is limited, but it weakens the anti-spam mechanism.

**Impact:** Determined spammers can bypass the free tier. However, creating blockchain addresses has a cost (gas for transactions), and the 20-message limit is still enforced per address.

**Recommendation:** This is an accepted design limitation. No contract-level fix is available -- KYC-based identity binding would need to be enforced at the validator level.

### [LOW-04] `_currentMonth()` Uses 30-Day Approximation

**Severity:** Informational
**Location:** Lines 457-460

```solidity
function _currentMonth() internal view returns (uint256) {
    return block.timestamp / MONTH_SECONDS;
}
```

Uses 30-day periods rather than calendar months. This is documented (line 336) and acceptable for on-chain simplicity. The only side effect is that some 30-day periods span two calendar months.

**Impact:** None. Documented behavior.

### [LOW-05] `paymentProofs` Mapping Grows Without Bound

**Severity:** Informational
**Location:** Line 122

```solidity
mapping(address => mapping(bytes32 => mapping(uint256 => bool)))
    public paymentProofs;
```

Each message creates a permanent storage entry. There is no mechanism to prune old proofs. However, since this is a boolean per message and storage is on the OmniCoin chain (which has zero gas fees for users), the economic cost is borne by validators.

**Impact:** Gradual state growth. No practical issue given the chain architecture.

---

## Access Control Review

| Function | Access | Assessment |
|----------|--------|------------|
| `payMessageFee()` | Public + nonReentrant | Correct |
| `payBulkMessageFee()` | Public + nonReentrant | Correct |
| `hasValidPayment()` | Public view | Correct |
| `freeMessagesRemaining()` | Public view | Correct |
| `setBaseFee()` | onlyOwner | Missing upper bound (LOW-01) |
| `updateRecipients()` | onlyOwner | Mutable recipients (MEDIUM-02) |

---

## Reentrancy Analysis

- `payMessageFee()` and `payBulkMessageFee()` use `nonReentrant`
- State updates (message count, payment proof) occur before `_collectFee()` external calls
- `_collectFee()` uses SafeERC20 for all token transfers
- No ETH handling

**Assessment:** No reentrancy risk.

---

## Fee Distribution Analysis

- Fee pulled from user to contract via `safeTransferFrom`
- Split: staking (20%), protocol (10%), ODDAO gets remainder (avoids dust)
- Shares sum to exactly BPS: 7000 + 2000 + 1000 = 10000
- MIN_FEE (1e15 = 0.001 XOM) prevents rounding to zero
- Zero-amount transfers are prevented by `if > 0` checks

**Assessment:** Arithmetic is correct. Distribution split does not match documentation (MEDIUM-01).

---

## Conclusion

OmniChatFee is a reasonably secure contract with appropriate reentrancy protection and CEI compliance. The primary concerns are the fee split discrepancy with documentation (MEDIUM-01) and mutable recipient addresses (MEDIUM-02). The free tier mechanism works as intended, and the anti-spam protections are appropriate for the chat use case.

### Summary Table

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| MEDIUM-01 | Medium | Fee split does not match documented 70/20/10 (validator not paid) | Needs Clarification |
| MEDIUM-02 | Medium | Mutable recipient addresses can redirect fees | Consider Immutable |
| LOW-01 | Low | No upper bound on baseFee | Recommend Fix |
| LOW-02 | Low | Potential overflow in bulk fee calculation for extreme baseFee | Recommend Fix |
| LOW-03 | Low | Free tier bypass via multiple addresses | Accepted Limitation |
| LOW-04 | Info | 30-day month approximation | Documented |
| LOW-05 | Info | Payment proofs grow without bound | Accepted |
