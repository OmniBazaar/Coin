# Security Audit Report: OmniYieldFeeCollector

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/yield/OmniYieldFeeCollector.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 175
**Upgradeable:** No
**Handles Funds:** Yes (transient — pulls yield tokens, splits fee, forwards net in single tx)
**Deployed At:** `0x1312eE58a794eb3aDa6D38cEbfcBD05f87e76511` (chain 131313)

## Executive Summary

OmniYieldFeeCollector is a minimal, trustless fee collector for DeFi yield earned through OmniBazaar. Users approve yield tokens, call `collectFeeAndForward()`, and the contract atomically splits the amount into a performance fee (sent to an immutable `feeCollector`) and net yield (returned to the user). The contract's immutable design (no admin keys, no upgrades, no configurable parameters) gives it an exceptionally low attack surface. The audit found **no critical or high vulnerabilities**. The primary concern is **fee-on-transfer token incompatibility** (Medium), which would cause reverts when processing tokens that deduct fees on transfer. A secondary design observation is that the single-recipient fee model does not implement OmniBazaar's standard 70/20/10 fee distribution pattern.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 4 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 52 |
| Passed | 46 |
| Failed | 2 |
| Partial | 4 |
| **Compliance Score** | **88.5%** |

**Top 5 Failed/Partial Checks:**

1. **SOL-Defi-General-9** (FAIL): Fee-on-transfer tokens cause accounting mismatch — contract assumes received amount equals requested amount
2. **SOL-Basics-Event-1** (FAIL): `rescueTokens()` does not emit an event when tokens are rescued
3. **SOL-AM-DOSA-2** (PARTIAL): No minimum yield amount — dust amounts round fee to zero
4. **SOL-AM-DOSA-3** (PARTIAL): If `feeCollector` is token-blacklisted, all fee collection for that token is permanently blocked
5. **SOL-AM-RP-1** (PARTIAL): `rescueTokens()` sends all rescued tokens to `feeCollector` — no option for alternative recipient

---

## Medium Findings

### [M-01] Fee-on-Transfer Token Incompatibility

**Severity:** Medium
**Category:** SC05 Input Validation / SC02 Business Logic
**VP Reference:** VP-46 (Fee-on-Transfer Tokens)
**Location:** `collectFeeAndForward()` (lines 128-143)
**Sources:** Agent-A, Agent-B, Agent-D, Checklist (SOL-Defi-General-9, SOL-Token-FE-6), Solodit (7+ matches)

**Description:**

The contract calculates `feeAmount` and `netAmount` based on the input `yieldAmount`, then pulls `yieldAmount` tokens via `safeTransferFrom`. If the token deducts a transfer fee (e.g., STA, PAXG, or certain rebasing tokens), the contract receives fewer tokens than `yieldAmount`, but then attempts to send out `feeAmount + netAmount = yieldAmount`. The second or third `safeTransfer` will revert due to insufficient balance.

```solidity
// Line 128-129: Calculated from input amount
uint256 feeAmount = (yieldAmount * performanceFeeBps) / BPS_DENOMINATOR;
uint256 netAmount = yieldAmount - feeAmount;

// Line 132: Pull — may receive less than yieldAmount for FoT tokens
IERC20(token).safeTransferFrom(msg.sender, address(this), yieldAmount);

// Lines 136, 142: Send out full amounts — will revert if balance < yieldAmount
IERC20(token).safeTransfer(feeCollector, feeAmount);
IERC20(token).safeTransfer(msg.sender, netAmount);
```

**Exploit Scenario:**

1. A user earns yield in a fee-on-transfer token (e.g., a token with 1% transfer fee).
2. User approves and calls `collectFeeAndForward(token, 1000)`.
3. The contract receives 990 tokens (1000 - 1% fee) but tries to send 50 (fee) + 950 (net) = 1000.
4. Transaction reverts on the second transfer. The function is permanently unusable for this token.

**Real-World Precedent:** Fee-on-transfer incompatibility is one of the most frequently reported findings in DeFi audits. Found in Astaria (CodeHawks), Cally Finance, veToken Finance, Sandclock (Sherlock), and 7+ other audited protocols on Solodit.

**Recommendation:**

Measure actual received balance instead of trusting input amount:

```solidity
uint256 balanceBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), yieldAmount);
uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balanceBefore;

uint256 feeAmount = (actualReceived * performanceFeeBps) / BPS_DENOMINATOR;
uint256 netAmount = actualReceived - feeAmount;
```

**Mitigating Factor:** The contract's NatSpec mentions Curve, Convex, Aave, and Pendle — these protocols generally distribute standard ERC20 yield tokens (CRV, CVX, AAVE, PENDLE) that do not have transfer fees. The risk materializes only if users process non-standard tokens.

---

### [M-02] Single-Recipient Fee Does Not Implement 70/20/10 Distribution

**Severity:** Medium
**Category:** SC02 Business Logic (Protocol Invariant)
**VP Reference:** N/A (Protocol Design)
**Location:** `collectFeeAndForward()` (line 136), constructor (lines 99-106)
**Sources:** Agent-B

**Description:**

OmniBazaar's standard fee distribution pattern is 70/20/10 (primary recipient / secondary recipient / ODDAO). This contract sends 100% of collected fees to a single immutable `feeCollector` address. While the `feeCollector` could be a splitter contract that implements the 70/20/10 split, this is not enforced or documented.

```solidity
// Line 136: 100% of fee to single address
IERC20(token).safeTransfer(feeCollector, feeAmount);
```

Per OmniBazaar protocol rules, yield performance fees should be distributed as:
- 70% to the primary recipient (yield protocol or ODDAO)
- 20% to the staking pool
- 10% to the processing validator

**Impact:** If `feeCollector` is an EOA, the entire fee goes to one entity, violating the protocol's decentralization principles. This is a design gap, not an exploitable vulnerability.

**Recommendation:**

Either:
1. Deploy a fee splitter contract as the `feeCollector` address (simplest — no contract changes needed)
2. Add on-chain split logic with three immutable recipient addresses
3. Document in NatSpec that `feeCollector` MUST be a splitter contract

---

## Low Findings

### [L-01] rescueTokens() Missing Event Emission

**Severity:** Low
**VP Reference:** N/A (Best Practice)
**Location:** `rescueTokens()` (lines 168-174)
**Sources:** Agent-B, Agent-C, Checklist (SOL-Basics-Event-1), Solodit (3+ matches)

The `rescueTokens()` function transfers tokens to `feeCollector` without emitting an event. This makes it difficult to track rescue operations on-chain and in monitoring dashboards.

**Recommendation:**

Add a `TokensRescued` event:

```solidity
event TokensRescued(address indexed token, uint256 amount);

function rescueTokens(address token) external nonReentrant {
    if (msg.sender != feeCollector) revert InvalidFeeCollector();
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(feeCollector, balance);
        emit TokensRescued(token, balance);
    }
}
```

---

### [L-02] Rebasing Token Incompatibility

**Severity:** Low
**VP Reference:** VP-46 (Token Integration)
**Location:** `collectFeeAndForward()` (lines 128-143)
**Sources:** Agent-B

The contract's NatSpec mentions Aave, which distributes yield via rebasing aTokens. If a user passes aTokens through this contract, the token balance could change between the `safeTransferFrom` and subsequent `safeTransfer` calls due to interest accrual. In practice, the accrual within a single transaction is negligible (sub-wei for most amounts), but the contract does not account for this pattern.

**Recommendation:** Document in NatSpec that rebasing tokens should be unwrapped to their underlying asset before processing through this contract. Aave's `withdraw()` function converts aTokens to the underlying asset.

---

### [L-03] Rounding to Zero on Dust Amounts

**Severity:** Low
**VP Reference:** VP-15 (Rounding Exploitation)
**Location:** `collectFeeAndForward()` (line 128)
**Sources:** Agent-A, Agent-B, Agent-D, Solodit (4+ matches)

When `yieldAmount * performanceFeeBps < BPS_DENOMINATOR`, the fee rounds down to zero. For a 5% fee (500 bps), this occurs when `yieldAmount < 20 wei`. The user receives the full yield with zero fee collected.

```solidity
// If yieldAmount = 19 and performanceFeeBps = 500:
// feeAmount = (19 * 500) / 10000 = 9500 / 10000 = 0
uint256 feeAmount = (yieldAmount * performanceFeeBps) / BPS_DENOMINATOR;
```

**Impact:** Negligible in practice — 20 wei of any token is worth effectively nothing. An attacker would need billions of transactions to extract meaningful value, costing far more in gas.

**Recommendation:** Add a minimum amount check if desired: `require(yieldAmount >= BPS_DENOMINATOR / performanceFeeBps, "Amount too small")`. However, the gas cost of the transaction already provides sufficient economic protection.

---

### [L-04] DoS if feeCollector is Token-Blacklisted

**Severity:** Low
**VP Reference:** VP-30 (DoS via Revert)
**Location:** `collectFeeAndForward()` (line 136), `feeCollector` immutable
**Sources:** Checklist (SOL-AM-DOSA-3), Solodit (3+ matches — SPARKN, Resolv, Strata)

If the immutable `feeCollector` address is blacklisted by a specific token (e.g., USDC, USDT have admin-controlled blacklists), the `safeTransfer` to `feeCollector` will revert, permanently blocking fee collection for that token. Since `feeCollector` is immutable, there is no recovery path.

**Mitigating Factor:** This is an intentional design tradeoff — immutability prevents admin key compromise but creates permanent DoS risk for blacklisted tokens. The `feeCollector` address would need to be OFAC-sanctioned or otherwise targeted, which is unlikely for a legitimate protocol treasury.

**Recommendation:** Accept as known risk. If desired, add a pull-based fee pattern where fees accumulate in the contract and the `feeCollector` withdraws them, so blacklisting only affects the withdrawal, not user operations.

---

## Informational Findings

### [I-01] Misleading Error Reuse in rescueTokens()

**Severity:** Informational
**Location:** `rescueTokens()` (line 169)
**Sources:** Agent-A

The `rescueTokens()` function reuses `InvalidFeeCollector()` as its access control error. This is semantically misleading — the check is verifying that `msg.sender == feeCollector`, not that the `feeCollector` address is invalid.

**Recommendation:** Add a dedicated `Unauthorized()` or `NotFeeCollector()` error.

---

### [I-02] No Minimum Yield Amount

**Severity:** Informational
**Location:** `collectFeeAndForward()` (line 125)
**Sources:** Checklist (SOL-AM-DOSA-2)

The contract checks `yieldAmount != 0` but does not enforce a meaningful minimum. Users can process dust amounts where the fee rounds to zero (see L-03). The gas cost of the transaction provides natural economic protection.

---

### [I-03] No OmniCore Integration

**Severity:** Informational
**Location:** Contract-wide
**Sources:** Agent-B

The contract operates as a standalone fee collector without integration to OmniCore (the central protocol hub). It does not verify that the caller is a registered OmniBazaar user, does not record fee collection in OmniCore's accounting, and does not participate in the protocol's staking or governance systems. This is an intentional design choice for simplicity and trustlessness.

---

### [I-04] Solhint Style Warnings

**Severity:** Informational
**Location:** Contract-wide
**Sources:** Solhint

Solhint reports 6 warnings (0 errors):
- 3x `gas-indexed-events`: `FeeCollected` event parameters `yieldAmount`, `feeAmount`, `netAmount` are not indexed (intentional — these are value fields, not lookup keys)
- 2x `immutable-vars-naming`: `feeCollector` and `performanceFeeBps` do not follow `UPPER_CASE` naming convention for immutables
- 1x `ordering`: Import ordering suggestion

---

## Known Exploit Cross-Reference

| Exploit Pattern | Source | Relevance |
|----------------|--------|-----------|
| Fee-on-transfer accounting mismatch | Solodit (7+ findings) | Direct — M-01 matches this pattern exactly |
| Token blacklist DoS | SPARKN, Resolv, Strata (Solodit) | Direct — immutable feeCollector cannot recover from blacklisting |
| Missing event in admin functions | CodeHawks, Shieldify audits | Direct — rescueTokens() has no event |
| Rounding exploitation via dust | Multiple Sherlock contests | Low relevance — gas cost prevents economic exploitation |

No DeFiHackLabs incidents match this contract's pattern — the contract is too simple and trustless to be a realistic exploit target. The immutable design prevents the most common DeFi exploit vector (admin key compromise).

## Solodit Similar Findings

- **Astaria (CodeHawks):** Fee-on-transfer token incompatibility in yield distribution — rated MEDIUM. Exact same pattern as M-01.
- **Cally Finance, veToken Finance:** FoT token accounting mismatch in deposit/withdraw flows — rated MEDIUM.
- **Sandclock (Sherlock):** Transfer fee not accounted for in yield vault — rated MEDIUM.
- **SPARKN (CodeHawks):** DoS via blacklisted fee recipient address — rated LOW.
- **Multiple contests:** Missing events on admin/rescue functions — rated LOW.

Confidence assessment: HIGH — all findings are well-supported by multiple sources and real-world precedent. The LOW severity profile is appropriate for this minimal contract.

## Static Analysis Summary

### Slither
Skipped — full-project scan exceeds timeout threshold. Slither analyzes all contracts in the Hardhat project simultaneously; individual contract targeting not supported.

### Aderyn
Skipped — Aderyn v0.6.8 incompatible with solc v0.8.33 (project compiler version). Returns compilation errors on all contracts.

### Solhint
**0 errors, 6 warnings:**
- 3x `gas-indexed-events`: Value parameters in FeeCollected event not indexed
- 2x `immutable-vars-naming`: Immutables use camelCase instead of UPPER_CASE
- 1x `ordering`: Import ordering suggestion

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| feeCollector (immutable) | `rescueTokens()` | 2/10 |
| Any address | `collectFeeAndForward()`, `calculateFee()` (view) | 1/10 |

## Centralization Risk Assessment

**Single-key maximum damage:** The `feeCollector` address can call `rescueTokens()` to sweep any tokens accidentally sent to the contract. However, the contract never holds user funds between transactions (atomic pull-split-forward), so there are no user funds to steal. The `feeCollector` cannot modify the fee percentage, change recipients, or pause the contract.

**Centralization Risk Rating:** 2/10

This is one of the most trustless contracts in the OmniBazaar ecosystem. Both the fee percentage and collector address are immutable — set at deployment and unchangeable. No admin keys, no upgrades, no pausing. The only privileged function (`rescueTokens`) can only send tokens to the same immutable `feeCollector` address that already receives all fees.

**Recommendation:** No changes needed. The immutable design is appropriate for this contract's scope.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
