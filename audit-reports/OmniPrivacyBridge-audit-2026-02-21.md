# Security Audit Report: OmniPrivacyBridge

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniPrivacyBridge.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 414
**Upgradeable:** Yes (UUPS)
**Handles Funds:** Yes (locks XOM, mints/burns pXOM)

## Executive Summary

OmniPrivacyBridge is a UUPS-upgradeable contract that enables XOM ↔ pXOM (private XOM) conversion via COTI V2 MPC. Users lock XOM to mint pXOM (0.3% fee) and burn pXOM to reclaim XOM (no fee). The contract tracks `totalLocked` for solvency accounting and integrates with both OmniCoin (XOM) and PrivateOmniCoin (pXOM).

The audit found **2 Critical vulnerabilities**: (1) `emergencyWithdraw()` drains locked XOM without updating `totalLocked`, breaking the solvency invariant and enabling admin rug pull, and (2) PrivateOmniCoin's `INITIAL_SUPPLY` of 1 billion pXOM is minted at genesis with no backing XOM in the bridge, creating systemic insolvency from deployment. Additionally, **3 High-severity issues** were found: the `MAX_CONVERSION_AMOUNT` of `type(uint64).max` limits conversions to ~18.4 XOM (making the bridge unusable for practical amounts), double fees totaling 0.6% on the XOM→pXOM path, and fee accounting that desynchronizes `totalLocked` from actual redeemable pXOM.

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 3 |
| Medium | 4 |
| Low | 3 |
| Informational | 2 |

## Findings

### [C-01] emergencyWithdraw Breaks Solvency Invariant — Admin Rug Pull Vector

**Severity:** Critical
**Lines:** 329-340
**Agents:** Both

**Description:**

`emergencyWithdraw()` transfers all locked XOM to an admin-specified recipient but does NOT update `totalLocked`. After the withdrawal:
- `totalLocked` still reports the pre-withdrawal value
- The contract holds zero XOM
- All outstanding pXOM holders cannot redeem (insufficient XOM balance)
- `getSolvencyStatus()` still reports the bridge as solvent (comparing stale `totalLocked` against pXOM supply)

The function is gated by `DEFAULT_ADMIN_ROLE`, but a single compromised admin key can drain all user funds with no timelock, multi-sig requirement, or recovery mechanism.

**Impact:** Complete loss of all locked XOM. All pXOM holders are left with unredeemable tokens. The solvency check becomes permanently misleading.

**Recommendation:** Either:
1. Set `totalLocked = 0` in `emergencyWithdraw()` and pause the contract, OR
2. Remove `emergencyWithdraw()` entirely (the `pause()` mechanism already prevents new conversions), OR
3. Add timelock + multi-sig requirement and emit a warning event days before execution

---

### [C-02] 1 Billion Unbacked pXOM at Genesis — Systemic Insolvency

**Severity:** Critical
**Lines:** PrivateOmniCoin.sol:59, OmniPrivacyBridge.sol:105
**Agent:** Agent B

**Description:**

PrivateOmniCoin's `initialize()` mints `INITIAL_SUPPLY = 1_000_000_000 * 10**18` pXOM to the deployer. These pXOM tokens exist without any corresponding XOM locked in the bridge. If any holder of genesis pXOM calls `convertPXOMtoXOM()`, they receive XOM that was locked by OTHER users, creating a first-come-first-served bank run.

The bridge's `totalLocked` starts at 0, while 1B pXOM already circulates. The solvency invariant (`totalLocked >= totalPXOMSupply`) is violated from block 0.

**Impact:** Bridge is insolvent from deployment. Genesis pXOM holders can drain XOM deposited by legitimate users. The `getSolvencyStatus()` function would report critical insolvency immediately.

**Recommendation:** Either:
1. Remove `INITIAL_SUPPLY` from PrivateOmniCoin (mint only via bridge), OR
2. Lock 1B XOM in the bridge at deployment to back the genesis supply, OR
3. Prevent genesis pXOM from being redeemed via the bridge (whitelist bridge-minted pXOM only)

---

### [H-01] MAX_CONVERSION_AMOUNT Limits Bridge to ~18.4 XOM — Unusable

**Severity:** High
**Lines:** 77, 160, 228
**Agents:** Both

**Description:**

`MAX_CONVERSION_AMOUNT = type(uint64).max` is approximately `18.446744 * 10^18` wei, which equals ~18.4 XOM at 18 decimals. Any conversion exceeding ~18.4 XOM reverts with `AmountExceedsMaxConversion`. This makes the bridge unusable for any meaningful transaction — staking alone requires 1M+ XOM.

The `maxConversionLimit` state variable (line 100) exists as an intended configurable limit, but `MAX_CONVERSION_AMOUNT` is checked FIRST (line 160), making `maxConversionLimit` dead code whenever it's set higher than ~18.4 XOM.

The uint64 limitation originates from COTI V2 MPC's `gtUint64` type, but the bridge should handle the uint256→uint64 conversion internally rather than rejecting large amounts.

**Impact:** Bridge is limited to trivial amounts (~18.4 XOM max per conversion). The privacy feature is effectively unavailable for any practical use case.

**Recommendation:** Remove the `MAX_CONVERSION_AMOUNT` check. If COTI MPC requires uint64, implement batching internally: split large conversions into multiple uint64-sized chunks within a single transaction.

---

### [H-02] Double Fee on XOM→pXOM Path — 0.6% Total Instead of 0.3%

**Severity:** High
**Lines:** 162-170, PrivateOmniCoin.sol:222-230
**Agents:** Both

**Description:**

When a user converts XOM to pXOM:
1. `OmniPrivacyBridge.convertXOMtoPXOM()` charges 0.3% fee (line 162-165), minting `amount - fee` pXOM
2. If the user then calls `PrivateOmniCoin.convertToPrivate()` to make the pXOM actually private, another 0.3% fee is charged (PrivateOmniCoin line 222-230)

Total fee: 0.6%, double the documented 0.3%. Users who want actual privacy (the stated purpose) pay twice.

**Impact:** Users are overcharged. The effective fee is 2x what the specification and NatSpec document. For large conversions, this is a significant economic penalty.

**Recommendation:** Charge the fee in only ONE location. Since the bridge is the entry point, charge 0.3% there and make PrivateOmniCoin's internal conversion fee-free (or vice versa). Alternatively, reduce each to 0.15% so the total is 0.3%.

---

### [H-03] Fee Accounting Desynchronizes totalLocked from Redeemable pXOM

**Severity:** High
**Lines:** 162-170, 228-250
**Agent:** Agent B

**Description:**

When converting XOM→pXOM, the fee is deducted from the minted pXOM, but the FULL `amount` (including fee) is added to `totalLocked`:
```solidity
totalLocked += amount;           // Full amount locked
pxomToken.mint(msg.sender, amount - fee);  // Less pXOM minted
```

The fee XOM remains locked in the contract but has no corresponding pXOM. Over time, `totalLocked` grows larger than the total pXOM supply. When converting pXOM→XOM:
```solidity
totalLocked -= amount;  // Deducts the pXOM amount, not the original XOM
```

This creates a growing discrepancy. The bridge accumulates XOM that can never be redeemed through normal operations. Combined with the fact that `FEE_MANAGER_ROLE` is defined but never used (no `withdrawFees()` function exists), these fees are permanently trapped.

**Impact:** Fee XOM is permanently locked. `totalLocked` becomes meaningless as a solvency metric. The `getSolvencyStatus()` function reports artificial health.

**Recommendation:** Track fees separately: `totalLocked += (amount - fee)` or maintain a `totalFees` counter. Add a `withdrawFees()` function gated by `FEE_MANAGER_ROLE`.

---

### [M-01] External pXOM Minting Allows Draining Bridge via Redemption

**Severity:** Medium
**Lines:** 228-250
**Agent:** Agent A

**Description:**

PrivateOmniCoin has `MINTER_ROLE` that allows minting pXOM outside the bridge. If ANY address with `MINTER_ROLE` mints pXOM directly (not through the bridge), those tokens can be redeemed via `convertPXOMtoXOM()`, draining XOM that was locked by legitimate bridge users.

The bridge does not verify that the pXOM being redeemed was originally minted through itself. Any pXOM, regardless of origin, can claim locked XOM.

**Impact:** Externally minted pXOM can drain bridge XOM. This is essentially the same vector as C-02 but through ongoing minting rather than genesis supply.

**Recommendation:** Track bridge-minted pXOM separately, or restrict pXOM minting exclusively to the bridge contract.

---

### [M-02] No Rate Limiting on Conversions — Flash Loan Arbitrage Vector

**Severity:** Medium
**Lines:** 147-195, 214-260
**Agents:** Both

**Description:**

There are no per-block, per-user, or per-period rate limits on conversions. An attacker could flash-loan XOM, convert to pXOM, perform private operations, and convert back within a single transaction. While this doesn't directly steal funds, it enables using the bridge as a free mixing service (minus fees) and could stress the COTI MPC network.

The `dailyVolume` and `weeklyVolume` tracking exists (lines 107-112) but is purely informational — no limits are enforced.

**Impact:** Bridge can be used as a high-throughput mixing service. Volume tracking is cosmetic only.

**Recommendation:** Enforce `maxConversionLimit` per transaction, add a daily volume cap, and consider per-block conversion limits.

---

### [M-03] Missing maxConversionLimit Check in convertPXOMtoXOM

**Severity:** Medium
**Lines:** 214-260
**Agent:** Agent A

**Description:**

`convertXOMtoPXOM()` checks both `MAX_CONVERSION_AMOUNT` and `maxConversionLimit` (line 160-161), but `convertPXOMtoXOM()` only checks `MAX_CONVERSION_AMOUNT` (line 228). A configurable limit set by admin is enforced in one direction but not the other.

**Impact:** Asymmetric limit enforcement. Even if admin sets a conversion cap, pXOM→XOM conversions bypass it.

**Recommendation:** Add `if (amount > maxConversionLimit) revert AmountExceedsMaxConversion();` to `convertPXOMtoXOM()`.

---

### [M-04] Fee Accumulation Permanently Trapped — No Withdrawal Function

**Severity:** Medium
**Lines:** 74, 162-170
**Agents:** Both

**Description:**

`FEE_MANAGER_ROLE` is defined at line 74 (`keccak256("FEE_MANAGER_ROLE")`) but is never assigned to any function via `onlyRole()`. There is no `withdrawFees()` or `claimFees()` function. Fee XOM collected during conversions is permanently locked in the contract with no extraction mechanism.

**Impact:** All conversion fees are permanently inaccessible. This represents ongoing economic loss to the protocol.

**Recommendation:** Implement `withdrawFees()` gated by `FEE_MANAGER_ROLE`:
```solidity
function withdrawFees(address recipient) external onlyRole(FEE_MANAGER_ROLE) {
    uint256 fees = xomToken.balanceOf(address(this)) - totalLocked;
    xomToken.safeTransfer(recipient, fees);
}
```

---

### [L-01] pXOM burnFrom Bypasses Allowance — Cross-Contract Trust Risk

**Severity:** Low
**Lines:** PrivateOmniCoin.sol:417
**Agent:** Agent B

**Description:**

PrivateOmniCoin's `burnFrom()` function bypasses the standard ERC20 allowance check, using `onlyRole(BURNER_ROLE)` instead. While the bridge holds `BURNER_ROLE` and this is documented as intentional, it means the bridge can burn ANY user's pXOM without their approval. A compromised bridge admin could burn user pXOM without corresponding XOM release.

**Impact:** Any `BURNER_ROLE` holder can destroy user pXOM unilaterally. This is by design but increases centralization risk.

**Recommendation:** Document this trust assumption prominently. Consider using standard `burn()` with prior `approve()` for the bridge.

---

### [L-02] Missing Zero-Address Checks on Constructor Parameters

**Severity:** Low
**Lines:** 126-142
**Agent:** Agent A

**Description:**

`initialize()` does not validate that `_xomToken` and `_pxomToken` are non-zero addresses. Deploying with `address(0)` for either token would create a non-functional bridge that can only be fixed via UUPS upgrade.

**Recommendation:** Add zero-address checks in `initialize()`.

---

### [L-03] Event Over-Indexing — Redundant Indexed Parameters

**Severity:** Low
**Lines:** Various event declarations
**Agent:** Agent A

**Description:**

Multiple events index the `amount` parameter (uint256). Indexing amounts is rarely useful for filtering (topics are hashed) and wastes gas compared to non-indexed event data. Addresses should be indexed; amounts generally should not.

**Recommendation:** Remove `indexed` from amount parameters in events.

---

### [I-01] Test Suite Does Not Test UUPS Proxy Path

**Severity:** Informational
**Agent:** Agent A

**Description:**

The test suite deploys the contract directly (not via proxy), meaning the UUPS upgrade path, initializer protection, and proxy-specific behavior are untested. The `_authorizeUpgrade()` access control and storage gap usage are not validated.

**Recommendation:** Add proxy-based deployment tests using `@openzeppelin/hardhat-upgrades`.

---

### [I-02] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:**

Uses `^0.8.20` which allows compilation with any 0.8.x version >= 0.8.20. For deployed contracts, a fixed pragma ensures reproducible builds.

**Recommendation:** Use `pragma solidity 0.8.20;` (or the specific version used for deployment).

---

## Static Analysis Results

**Solhint:** 0 errors, warnings not enumerated (consistent with other privacy contracts)
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 22 raw findings -> 14 unique)
- Pass 6: Report generation

## Conclusion

OmniPrivacyBridge has **two Critical vulnerabilities that make it fundamentally unsafe for production**:

1. **emergencyWithdraw rug pull (C-01)** — a single admin key can drain all locked XOM with no solvency accounting update, leaving all pXOM holders with worthless tokens.

2. **1B unbacked pXOM at genesis (C-02)** — PrivateOmniCoin mints 1 billion pXOM at deployment with no backing XOM. These can drain the bridge before legitimate users.

3. **~18.4 XOM conversion limit (H-01)** makes the bridge unusable for any practical amount.

4. **Double 0.6% fee (H-02)** overcharges users who want actual privacy.

5. **Fee accounting desync (H-03)** permanently traps fee XOM with no withdrawal mechanism.

The contract requires significant refactoring before deployment: remove or refactor `emergencyWithdraw()`, resolve the genesis pXOM insolvency, address the uint64 precision ceiling, fix the double-fee path, and implement proper fee withdrawal. These issues are shared across the entire COTI privacy stack (PrivateOmniCoin, PrivateDEX, OmniPrivacyBridge) and should be addressed holistically.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
