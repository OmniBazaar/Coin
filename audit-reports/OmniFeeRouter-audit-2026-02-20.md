# Security Audit Report: OmniFeeRouter

**Date:** 2026-02-20
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/dex/OmniFeeRouter.sol`
**Solidity Version:** ^0.8.19
**Lines of Code:** 215
**Upgradeable:** No
**Handles Funds:** Yes (ERC-20 token routing with fee collection)

## Executive Summary

OmniFeeRouter is a trustless fee-collecting wrapper for external DEX swaps. It pulls input tokens, collects a capped fee, and forwards the remainder to a user-specified DEX router via arbitrary external call. The contract contains **one Critical vulnerability** — unrestricted arbitrary external calls that enable persistent token approval attacks — a pattern responsible for **$42M+ in real-world losses** across Transit Swap, SushiSwap, LI.FI, 1inch, Dexible, and Rubic. Three High-severity findings address same-token swaps, fee-on-transfer incompatibility, and leftover token stranding.

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 3 |
| Low | 3 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 74 |
| Passed | 56 |
| Failed | 11 |
| Partial | 7 |
| **Compliance Score** | **75.7%** |

Top 5 failed checks:
1. **SOL-Basics-Function-6** — Arbitrary user input in low-level call (Critical)
2. **SOL-EC-5** — Called address not whitelisted (Critical)
3. **SOL-Defi-AS-6** — Arbitrary calls from user input (Critical)
4. **SOL-Heuristics-3** — Unexpected behavior when src==dst (High)
5. **SOL-Defi-AS-9** — No fee-on-transfer token support (High)

---

## Critical Findings

### [C-01] Arbitrary External Call Enables Persistent Token Approval Drain

**Severity:** Critical
**Category:** SC01 Access Control / SC06 Unchecked External Calls
**VP Reference:** VP-06 (Missing Access Control), VP-26 (Unchecked External Call)
**Location:** `swapWithFee()` (lines 142-143, 168, 175)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (FAIL-1/2/6), Solodit
**Real-World Precedent:** Transit Swap ($21M, Oct 2022), SushiSwap RouteProcessor2 ($3.3M, Apr 2023), LI.FI GasZipFacet ($11.6M, Jul 2024), Dexible ($2M, Feb 2023), 1inch ($4.5M, 2023), Rubic ($1.4M, 2022) — **$42M+ cumulative losses**

**Description:**

Both `routerAddress` and `routerCalldata` are fully user-controlled with no whitelist or validation beyond a zero-address check. The contract:
1. Approves `netAmount` of `inputToken` to `routerAddress` (line 168)
2. Executes `routerAddress.call(routerCalldata)` (line 175)
3. Resets approval to `routerAddress` to zero (line 179)

An attacker sets `routerAddress = inputToken` and `routerCalldata = abi.encodeCall(IERC20.approve, (attackerAddress, type(uint256).max))`. This executes `inputToken.approve(attackerAddress, MAX_UINT)` where `msg.sender` is the OmniFeeRouter contract. The post-call `forceApprove(routerAddress, 0)` on line 179 resets the approval to `routerAddress` (which is `inputToken` itself) — NOT to `attackerAddress`.

The persistent approval allows the attacker to call `inputToken.transferFrom(OmniFeeRouter, attacker, balance)` at any future time to drain tokens that pass through the contract from other users' swaps.

**Exploit Scenario:**

```
1. Attacker calls swapWithFee(USDC, WETH, 100, 0, USDC, approve(attacker, MAX), 0)
2. Contract pulls 100 USDC from attacker
3. Contract approves 100 USDC to USDC contract (routerAddress = USDC)
4. Contract calls USDC.approve(attacker, MAX_UINT) — attacker now has unlimited approval
5. Contract resets approval to USDC contract to 0 — but attacker's approval persists
6. Victim calls swapWithFee(USDC, WETH, 10000, 100, UniswapRouter, ..., ...)
7. Contract holds 9900 USDC momentarily during the swap
8. Attacker front-runs or monitors: USDC.transferFrom(OmniFeeRouter, attacker, 9900)
9. Victim's swap fails or produces zero output
```

**Recommendation:**

Add a router allowlist, or at minimum:
```solidity
if (routerAddress == inputToken) revert InvalidRouterAddress();
if (routerAddress == outputToken) revert InvalidRouterAddress();
if (routerAddress == address(this)) revert InvalidRouterAddress();
```

Strongest fix: immutable or governance-controlled allowlist of approved router addresses.

---

## High Findings

### [H-01] Same-Token Swap Breaks Balance-Delta Accounting

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error)
**Location:** `swapWithFee()` (lines 147-149, 171-183)
**Sources:** Agent-A, Agent-B, Agent-C, Agent-D, Checklist (FAIL-3)

**Description:**

No check prevents `inputToken == outputToken`. When they are the same token:

1. The contract pulls `totalAmount` from the user (line 160)
2. Sends `feeAmount` to feeCollector (line 164)
3. Snapshots `outputBefore = balanceOf(this)` — which includes the remaining `netAmount` (line 171)
4. Executes the router call (line 175)
5. Snapshots `outputAfter` and computes `outputReceived = outputAfter - outputBefore` (lines 182-183)

If `routerCalldata` encodes a no-op or identity swap, `outputAfter == outputBefore` (the `netAmount` is still sitting in the contract from the approval that wasn't consumed). The computed `outputReceived = 0`, and if `minOutput = 0`, the user loses their tokens. Alternatively, if the router returns `netAmount` back to the contract, the balance delta double-counts it.

**Exploit Scenario:**

Attacker sets `inputToken = outputToken = USDC`, `routerCalldata` = no-op that succeeds. User loses `netAmount` of USDC (stuck in contract). Or: an attacker constructs calldata that returns the same tokens, extracting the fee "for free."

**Recommendation:**

```solidity
if (inputToken == outputToken) revert InvalidTokenAddress();
```

---

### [H-02] Fee-on-Transfer Tokens Cause Balance Mismatch

**Severity:** High
**Category:** SC02 Business Logic / SC10 Token Integration
**VP Reference:** VP-46 (Fee-on-Transfer)
**Location:** `swapWithFee()` (lines 157-168)
**Sources:** Agent-C, Agent-D, Checklist (FAIL-5), Solodit (CodeHawks #1053, Balancer/STA exploit)

**Description:**

For fee-on-transfer (FOT) input tokens, `safeTransferFrom(msg.sender, address(this), totalAmount)` on line 160 delivers fewer tokens than `totalAmount` to the contract. However, the contract computes `netAmount = totalAmount - feeAmount` (line 157) and proceeds to:
- Transfer `feeAmount` to feeCollector (line 164)
- Approve `netAmount` to the router (line 168)

The sum `feeAmount + netAmount = totalAmount > actual_balance`, causing either:
- The fee transfer to fail (if insufficient balance)
- The router swap to fail (if fee transfer succeeds but leaves insufficient tokens)
- Or, in worst case, draining pre-existing contract balance of that token

**Recommendation:**

Measure actual received balance:
```solidity
uint256 balBefore = IERC20(inputToken).balanceOf(address(this));
IERC20(inputToken).safeTransferFrom(msg.sender, address(this), totalAmount);
uint256 actualReceived = IERC20(inputToken).balanceOf(address(this)) - balBefore;
// Use actualReceived instead of totalAmount for subsequent calculations
```

Or explicitly document and revert for FOT tokens.

---

### [H-03] Leftover Input Tokens Not Returned After Partial Fills

**Severity:** High
**Category:** SC02 Business Logic
**VP Reference:** VP-58 (DeFi-Specific)
**Location:** `swapWithFee()` (lines 178-189)
**Sources:** Agent-A, Agent-B, Checklist (FAIL-9), Solodit (Sudoswap Cyfrin 2023)
**Real-World Precedent:** Sudoswap VeryFastRouter — funds permanently locked from partial fills (Cyfrin, Jun 2023)

**Description:**

If the external DEX router only partially consumes `netAmount` (partial fill), the unused input tokens remain stranded in the OmniFeeRouter contract. The contract:
1. Resets approval to zero (line 179) — correct
2. Sweeps `outputToken` balance delta to user (lines 182-189) — correct
3. Does **NOT** sweep residual `inputToken` back to user — **missing**

The only recovery path is `rescueTokens()` (lines 208-214), callable only by `feeCollector`, which sends tokens to `feeCollector` — not to the original user.

**Recommendation:**

After the approval reset, sweep residual input tokens back to the caller:
```solidity
uint256 inputRemaining = IERC20(inputToken).balanceOf(address(this));
if (inputRemaining > 0) {
    IERC20(inputToken).safeTransfer(msg.sender, inputRemaining);
}
```

---

## Medium Findings

### [M-01] No Deadline Parameter for MEV Protection

**Severity:** Medium
**Category:** SC02 Business Logic
**VP Reference:** VP-34 (Logic Error — Temporal Staleness)
**Location:** `swapWithFee()` (lines 137-145)
**Sources:** Agent-C, Agent-D, Checklist (FAIL-4, FAIL-8), Solodit (CodeHawks Morpheus #49)

**Description:**

The function lacks a `deadline` parameter. While `minOutput` provides slippage protection for output amounts, it does not protect against temporal staleness. A transaction sitting in the mempool can be executed at any future time when market conditions differ from the user's intent. Miners/validators can hold the transaction and execute it when `minOutput` is easily satisfiable at a worse-than-intended rate.

**Recommendation:**

Add a `deadline` parameter:
```solidity
function swapWithFee(
    ...
    uint256 deadline
) external nonReentrant {
    if (block.timestamp > deadline) revert DeadlineExpired();
    ...
}
```

---

### [M-02] No Code Existence Check on Router Address

**Severity:** Medium
**Category:** SC06 Unchecked External Calls
**VP Reference:** VP-26 (Unchecked External Call)
**Location:** `swapWithFee()` (lines 150, 175-176)
**Sources:** Checklist (FAIL-10), Solodit (Cyfrin Glossary)

**Description:**

The `routerAddress` is only validated as non-zero (line 150). A low-level `call()` to an address with no deployed code returns `success = true` with empty `returnData` — this is documented EVM behavior. If `minOutput = 0`, the swap "succeeds" with zero output, and the user loses their input tokens (approved to a codeless address, fee sent to feeCollector, no output received).

**Recommendation:**

```solidity
if (routerAddress.code.length == 0) revert InvalidRouterAddress();
```

---

### [M-03] rescueTokens() Lacks Event Emission and Has Weak Constraints

**Severity:** Medium
**Category:** SC01 Access Control
**VP Reference:** VP-06 (Access Control)
**Location:** `rescueTokens()` (lines 208-214)
**Sources:** Agent-C, Checklist (FAIL-11, PARTIAL-7)

**Description:**

The `rescueTokens()` function allows `feeCollector` to withdraw the entire balance of any ERC-20 token from the contract without emitting an event. While the `feeCollector` is immutable and the function has a reentrancy guard, there is:
1. No event emission — making admin withdrawals unauditable on-chain
2. No internal distinction between "stuck tokens" and "in-flight swap tokens" (though reentrancy guard prevents concurrent exploitation)
3. No time-delay or multi-sig requirement

**Recommendation:**

Add an event:
```solidity
event TokensRescued(address indexed token, uint256 amount);
```
Emit it in `rescueTokens()`.

---

## Low Findings

### [L-01] Zero-Fee Bypass via Dust Amounts

**Severity:** Low
**Category:** SC07 Arithmetic
**VP Reference:** VP-12 (Arithmetic Precision)
**Location:** `swapWithFee()` (lines 153-155)
**Sources:** Agent-B, Checklist (FAIL-7)

**Description:**

For small `totalAmount` values, the fee cap check rounds to zero: `maxAllowed = (totalAmount * maxFeeBps) / BPS_DENOMINATOR`. With `maxFeeBps = 100` and `totalAmount = 99`, `maxAllowed = (99 * 100) / 10000 = 0`. A caller can set `feeAmount = 0` and pass the cap check, executing zero-fee swaps. While individually trivial, high-frequency dust trades could aggregate into meaningful volume without paying fees.

**Recommendation:**

Consider a minimum `totalAmount` threshold or a minimum fee floor.

---

### [L-02] Cyclomatic Complexity Exceeds Threshold

**Severity:** Low
**Category:** Informational / Code Quality
**Location:** `swapWithFee()` function
**Sources:** Solhint

**Description:**

`swapWithFee()` has cyclomatic complexity of 11, above the recommended threshold of 7. This increases maintenance difficulty and makes the function harder to reason about for security.

**Recommendation:**

Consider extracting validation into a separate internal function.

---

### [L-03] Immutable Variable Naming Convention

**Severity:** Low
**Category:** Informational / Style
**Location:** `feeCollector` (line 92), `maxFeeBps` (line 95)
**Sources:** Solhint

**Description:**

Immutable variables conventionally use `UPPER_CASE` naming (e.g., `FEE_COLLECTOR`, `MAX_FEE_BPS`) to distinguish them from regular state variables.

**Recommendation:**

Rename to follow convention, or suppress with `// solhint-disable-next-line immutable-vars-naming`.

---

## Informational Findings

### [I-01] Function Ordering

**Location:** Constructor at line 109, external functions at line 137
**Sources:** Solhint

The contract follows a reasonable ordering but Solhint flags constructor positioning. Minor style issue.

---

### [I-02] Return Data Bomb Potential

**Location:** `swapWithFee()` line 175
**Sources:** Solodit (additional patterns)

A malicious `routerAddress` could return an extremely large `bytes memory returnData`, causing out-of-gas during memory expansion. This is a griefing attack vector — the swap fails and the user's tokens are returned (due to revert), but gas is wasted.

**Recommendation:**

Consider limiting return data size or using assembly-level call with bounded returndatasize.

---

### [I-03] ERC-777 Callback via Output Token Sweep

**Location:** `swapWithFee()` line 188
**Sources:** Solodit (additional patterns)

If `outputToken` is an ERC-777 token, the `safeTransfer` to `msg.sender` triggers the `tokensReceived` callback. While the `nonReentrant` guard prevents re-entry into `swapWithFee`, the callback could interact with other contracts in unexpected ways. Mitigated by the reentrancy guard but worth noting.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Transit Swap | Oct 2022 | $21M | Exact pattern: user-supplied router + calldata with no validation; attacker drained via approve |
| SushiSwap RouteProcessor2 | Apr 2023 | $3.3M | Unvalidated pool address in swap router; attacker passed malicious contract |
| Dexible selfSwap | Feb 2023 | $2M | Arbitrary router + calldata in self-swap; attacker routed through token contracts |
| LI.FI GasZipFacet | Jul 2024 | $11.6M | Missing whitelist on call targets; attacker crafted transferFrom calls |
| 1inch | 2023 | $4.5M | Router approval exploit via arbitrary calldata |
| Rubic | 2022 | $1.4M | Cross-chain router with arbitrary call vulnerability |
| Balancer/STA | 2020 | ~$500K | Fee-on-transfer token broke pool accounting (analogous to H-02) |
| Sudoswap | 2023 | N/A (audit) | Partial fills left funds permanently locked in router (analogous to H-03) |

---

## Solodit Similar Findings

| Finding | Protocol | Severity | Relevance |
|---------|----------|----------|-----------|
| Arbitrary external call enables token drain | Transit Swap, Dexible, LI.FI | Critical | Exact match — C-01 |
| Unlimited token approvals not revoked | Alchemix (CodeHawks 2024) | Low | Analogous — approval persists to unintended addresses |
| Fee-on-transfer token incompatibility | Foundry DeFi Stablecoin (CodeHawks 2023) | Medium | Exact match — H-02 |
| Leftover funds locked in router | Sudoswap (Cyfrin 2023) | High | Exact match — H-03 |
| Missing deadline parameter | Morpheus (CodeHawks 2024) | Medium | Exact match — M-01 |
| Use forceApprove for non-standard tokens | Strata (Cyfrin 2025) | Low | Already implemented (positive) |

---

## Static Analysis Summary

### Slither

Skipped — full-project analysis exceeds timeout (>3 minutes). Known limitation across all audits in this series.

### Aderyn

Skipped — v0.6.8 incompatible with solc v0.8.33 (compiler crash). Known limitation.

### Solhint

4 warnings, 0 errors:
1. **ordering** — Function order does not follow Solidity style guide
2. **immutable-vars-naming** — `feeCollector` should be UPPER_CASE (x2)
3. **function-max-lines** — Cyclomatic complexity 11 (threshold: 7)

No security-relevant findings from Solhint.

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| feeCollector (immutable) | `rescueTokens()` | 3/10 |
| Any caller | `swapWithFee()` | 9/10 (due to arbitrary call) |

---

## Centralization Risk Assessment

**Single-key maximum damage:** The `feeCollector` can only call `rescueTokens()`, which sweeps token balances when no swap is active (reentrancy guard). Since `feeCollector` is immutable (cannot be changed after deployment), the centralization risk is **low (3/10)**. The feeCollector cannot modify fees, pause the contract, upgrade it, or interfere with active swaps.

**However:** The arbitrary external call vulnerability (C-01) means ANY user can cause far more damage than the admin — an unusual inversion where the real risk comes from the permissionless attack surface, not from privileged roles.

**Recommendation:** Fix C-01 (router whitelist) before deployment. No additional multi-sig or timelock needed for the feeCollector role given its limited scope.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
