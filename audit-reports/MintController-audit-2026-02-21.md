# Security Audit Report: MintController

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/MintController.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 161
**Upgradeable:** No
**Handles Funds:** Yes (controls all future XOM token minting)

## Executive Summary

MintController wraps OmniCoin's `mint()` function with an immutable `MAX_SUPPLY` check of 16.6 billion XOM. It uses OpenZeppelin `AccessControl` with `MINTER_ROLE` for authorization. The contract is intentionally minimal — it serves as a chokepoint to enforce the tokenomics supply cap. However, the audit found a **High-severity TOCTOU race condition** where the supply cap check reads `totalSupply()` before the mint but does not verify post-mint supply, allowing concurrent minters to collectively exceed `MAX_SUPPLY`. Additionally, the contract uses a **fragile low-level call** instead of a typed interface, has **no emergency pause**, **no rate limiting**, and **no timelock** on admin operations. For a contract governing ~12.47 billion XOM in future emissions over 40 years, these defense-in-depth gaps are significant.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 4 |
| Low | 3 |
| Informational | 1 |

## Findings

### [H-01] TOCTOU Race Condition on `totalSupply()` — Supply Cap Can Be Exceeded

**Severity:** High
**Lines:** 110-127
**Agents:** 2A, 2B (confirmed independently)

**Description:**

The `mint()` function reads `TOKEN.totalSupply()` at line 110, checks `amount > remaining` at line 115, then executes the actual mint via low-level call at line 121. No post-mint verification occurs:

```solidity
uint256 currentSupply = TOKEN.totalSupply();          // READ
uint256 remaining = MAX_SUPPLY > currentSupply ? MAX_SUPPLY - currentSupply : 0;
if (amount > remaining) { revert MaxSupplyExceeded(amount, remaining); }

(bool success, bytes memory returnData) = address(TOKEN).call(   // MINT (state changes here)
    abi.encodeWithSignature("mint(address,uint256)", to, amount)
);
require(success, string(returnData));

emit ControlledMint(to, amount, currentSupply + amount);  // Uses STALE value
```

If multiple addresses hold `MINTER_ROLE`, two concurrent mint transactions in the same block can both pass the supply check (reading the same pre-mint `totalSupply()`) and collectively exceed `MAX_SUPPLY`. While EVM executes transactions sequentially within a block, the safety depends entirely on OmniCoin's own `mint()` function having a redundant cap check — which MintController cannot guarantee.

**Impact:** The 16.6 billion XOM hard cap — the foundation of the entire tokenomics model — can be exceeded. This would undermine staking APR calculations, block reward schedules, and market confidence.

**Recommendation:**

Add a post-mint assertion:

```solidity
// After the low-level call:
uint256 postSupply = TOKEN.totalSupply();
require(postSupply <= MAX_SUPPLY, "Supply cap violated post-mint");
emit ControlledMint(to, amount, postSupply);
```

Also add `ReentrancyGuard` as defense-in-depth against callback-based reentrancy.

---

### [M-01] Unsafe Low-Level Call with Untyped Interface

**Severity:** Medium
**Lines:** 121-125
**Agents:** 2A, 2B

**Description:**

The mint uses `address(TOKEN).call(abi.encodeWithSignature("mint(address,uint256)", ...))` instead of a typed interface. This introduces three issues:

1. **Selector mismatch invisible at compile time** — if OmniCoin's `mint` signature changes, this call silently fails at runtime.
2. **`string(returnData)` produces garbled output** — revert data contains ABI-encoded error selectors, not UTF-8 strings.
3. **No contract existence check** — a `.call()` to an address with no code returns `success = true`.

**Impact:** Silent failures, garbled error messages, and potential phantom mints.

**Recommendation:**

Define a proper interface:
```solidity
interface IOmniCoinMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}
```
Use `IOmniCoinMintable(address(TOKEN)).mint(to, amount)` for compile-time safety.

---

### [M-02] No Emergency Pause Mechanism

**Severity:** Medium
**Lines:** N/A (missing feature)
**Agents:** 2A, 2B

**Description:**

If a vulnerability is discovered or `MINTER_ROLE` keys are compromised, there is no way to halt all minting instantly. The only option is revoking `MINTER_ROLE` from each holder individually — a per-account operation that can be front-run by an attacker's mint.

**Impact:** During a security incident, a compromised minter can mint the entire remaining supply (~12.47B XOM) in one transaction before admin can react.

**Recommendation:**

Add `Pausable` with a separate `PAUSER_ROLE` (hot wallet for fast response):
```solidity
function mint(...) external onlyRole(MINTER_ROLE) whenNotPaused { ... }
function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
```

---

### [M-03] No Rate Limiting on Minting

**Severity:** Medium
**Lines:** 106-128
**Agents:** 2B

**Description:**

A single `mint()` call can mint the entire remaining supply (~12.47B XOM) in one transaction. The tokenomics specifies a 40-year emission schedule, but MintController enforces no temporal constraints. Block rewards (~15.6 XOM/block) and bonuses (up to 10K XOM) suggest no legitimate single mint should exceed a few million XOM.

**Impact:** A compromised minter key causes catastrophic, irreversible inflation in a single transaction.

**Recommendation:**

Add per-epoch rate limiting:
```solidity
uint256 public constant MAX_MINT_PER_EPOCH = 50_000_000e18; // 50M XOM/week
mapping(uint256 => uint256) public epochMinted;
```

---

### [M-04] No Timelock on Admin Role Management

**Severity:** Medium
**Lines:** 83-90
**Agents:** 2A, 2B

**Description:**

`DEFAULT_ADMIN_ROLE` can grant `MINTER_ROLE` to any address instantly with no timelock, multi-sig, or delay. A compromised admin key can grant MINTER_ROLE to an attacker and mint the full remaining supply in the same block.

**Impact:** Single point of failure — admin key compromise leads to complete supply cap bypass.

**Recommendation:**

Transfer `DEFAULT_ADMIN_ROLE` to a TimelockController or multi-sig wallet. Consider adding an in-contract timelock for role grants.

---

### [L-01] Event Emits Calculated Supply Instead of Actual Post-Mint Supply

**Severity:** Low
**Lines:** 127

**Description:**

`emit ControlledMint(to, amount, currentSupply + amount)` uses the pre-mint `currentSupply` value. If concurrent mints land in the same block, or if OmniCoin has any supply-affecting side effects, the emitted value is inaccurate.

**Impact:** Off-chain indexers (block explorer, analytics, staking calculations) display incorrect supply data.

**Recommendation:** Read `TOKEN.totalSupply()` after the mint and emit the actual value.

---

### [L-02] No Batch Minting Capability

**Severity:** Low
**Lines:** N/A (missing feature)

**Description:**

Block reward distribution requires ~3 mint calls per block (staking pool, ODDAO, block producer) at 2-second intervals — ~129,600 transactions/day. Each call pays full overhead (role check, supply read, encoding, event). No batch function exists.

**Impact:** Higher gas costs for validators, reduced block production profitability.

**Recommendation:** Add `batchMint(address[] calldata, uint256[] calldata)` with aggregate supply check.

---

### [L-03] Immutable TOKEN Address — No Migration Path

**Severity:** Low
**Lines:** 39

**Description:**

`TOKEN` is `immutable`. Over the planned 40-year lifetime, if OmniCoin needs to be migrated, MintController becomes permanently useless. A new MintController must be deployed and roles re-configured, creating another deployment race condition window.

**Impact:** Operational inflexibility over a multi-decade timeline.

**Recommendation:** Accept as intentional design decision and ensure deployment tooling can atomically deploy replacement contracts. Alternatively, use an upgradeable proxy for MintController.

---

### [I-01] MAX_SUPPLY Not Verified Against Token Contract

**Severity:** Informational
**Lines:** 32

**Description:**

MintController defines `MAX_SUPPLY = 16_600_000_000e18` as a hardcoded constant. There is no on-chain verification that this matches OmniCoin's own supply cap (if any). Mismatched caps could cause confusing failures.

**Recommendation:** Add a constructor-time check:
```solidity
(bool ok, bytes memory d) = token_.staticcall(abi.encodeWithSignature("MAX_SUPPLY()"));
if (ok && d.length >= 32) require(abi.decode(d, (uint256)) == MAX_SUPPLY, "Cap mismatch");
```

---

## Static Analysis Results

**Solhint:** 0 errors, 4 warnings
- Ordering (func-order)
- Gas optimizations (indexed events, strict inequalities)

**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual)
- Pass 6: Report generation

## Conclusion

MintController is a simple, focused contract that achieves its core goal of supply cap enforcement. However, the **TOCTOU race condition (H-01)** is a genuine vulnerability that should be fixed before deployment by adding a post-mint `totalSupply()` assertion. The **low-level call pattern (M-01)** should be replaced with a typed interface. For a contract governing ~12.47 billion XOM over 40 years, the missing **Pausable (M-02)**, **rate limiting (M-03)**, and **timelock (M-04)** represent defense-in-depth gaps that should be addressed before production deployment.
