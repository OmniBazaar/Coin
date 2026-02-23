# Security Audit Report: RWAComplianceOracle

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/rwa/RWAComplianceOracle.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 565
**Upgradeable:** No (standard deployment)
**Handles Funds:** No (read-only compliance oracle)

## Executive Summary

RWAComplianceOracle is a non-upgradeable on-chain compliance verification contract for RWA tokens. It auto-detects token standards (ERC-3643, ERC-1400, ERC-4626, ERC-20) via ERC-165 and function probing, queries token compliance contracts (`canTransfer`/`canTransferByPartition`), caches results for 5 minutes, and provides batch compliance checking. A single `registrar` role manages token registration. The oracle is consumed by RWAAMM for swap compliance enforcement.

The audit found **no Critical vulnerabilities** (the contract holds no funds) but **4 High-severity issues**: (1) unregistered tokens default to COMPLIANT, defeating the compliance purpose; (2) wrong ERC-4626 interface ID (`0x7ecebe00` is actually EIP-2612 `nonces()`); (3) permissionless `refreshCompliance()` enables cache poisoning during compliance contract transitions; and (4) single registrar centralization with no multi-sig, timelock, or governance. Both agents independently identified the cache/view architecture mismatch and the unbounded array growth as significant issues.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 4 |
| Medium | 6 |
| Low | 3 |
| Informational | 2 |

## Findings

### [H-01] Unregistered Tokens Default to COMPLIANT — Compliance Bypass

**Severity:** High
**Lines:** 175-188
**Agent:** Agent B

**Description:**

When a token is not registered in the oracle, `checkCompliance()` returns `ComplianceStatus.COMPLIANT` with reason "Token not registered - no compliance required." This is a permissive default. In the RWAAMM, `_isComplianceRequired()` (line 737) only returns true for registered tokens, so unregistered tokens skip compliance entirely.

This creates multiple bypass vectors:
1. A new security token deployed after the oracle is tradeable without compliance checks until the registrar registers it.
2. A wrapper contract around a regulated token would not be registered and would bypass compliance.
3. Registrar omission (human error) permanently leaves a security token unregulated.
4. The RWAAMM's `createPool()` does not require that tokens are registered, so pools can be created for unregistered security tokens.

**Impact:** Non-KYC'd and non-accredited users can trade security tokens freely if the token is not registered. This creates direct regulatory liability for OmniBazaar.

**Recommendation:** Either:
1. Return `NON_COMPLIANT` for unregistered tokens (fail-closed default), or
2. Require token registration in the oracle before `RWAAMM.createPool()` can create a pool for it, or
3. Add a global `requireRegistration` flag that the registrar can toggle

---

### [H-02] Wrong ERC-4626 Interface ID — Collides with EIP-2612 nonces()

**Severity:** High
**Lines:** 45, 368
**Agent:** Agent B

**Description:**

The constant `ERC4626_INTERFACE = 0x7ecebe00` is incorrect. The selector `0x7ecebe00` corresponds to the `nonces(address)` function from EIP-2612 (permit), not ERC-4626. ERC-4626 does not have a standardized ERC-165 interface ID because it extends ERC-20 and most implementations do not implement `supportsInterface`.

This means:
- Any EIP-2612-compliant token (nearly every modern ERC-20 with permit) that happens to implement ERC-165 could be misclassified as ERC-4626
- Actual ERC-4626 vaults will NOT be detected as ERC-4626 and will fall through to the ERC-3643 `canTransfer` probe or default to ERC-20

**Impact:** Token standard misclassification. ERC-4626 vaults may receive wrong compliance treatment. EIP-2612 tokens could be incorrectly classified.

**Recommendation:** Either:
1. Remove ERC-4626 interface detection (ERC-4626 tokens don't need special compliance checks), or
2. Probe for `function asset() view returns (address)` via try/catch instead of using an incorrect interface ID

---

### [H-03] Cache Poisoning via Permissionless refreshCompliance()

**Severity:** High
**Lines:** 266-273
**Agent:** Agent B

**Description:**

`refreshCompliance()` is callable by **anyone** (no access control beyond `nonReentrant`). It calls `this.checkCompliance()` and stores the result in `_complianceCache` for 5 minutes. Attack scenario:

1. Attacker monitors a compliance contract for configuration changes (e.g., token issuer upgrading KYC rules).
2. During the brief window when the compliance contract is being reconfigured and `canTransfer()` temporarily reverts or is permissive, the attacker calls `refreshCompliance(targetUser, token)`.
3. The cache is populated with either `CHECK_FAILED` (blocking compliant users) or `COMPLIANT` (allowing non-compliant users) for 5 minutes.

Since `checkCompliance()` is a `view` function, it cannot update the cache itself — only `refreshCompliance()` can. A cached `COMPLIANT` result allows trading for the full TTL even after the compliance contract is reconfigured to block the user.

**Impact:** 5-minute window where non-compliant users can trade, or compliant users are blocked. For high-value RWA trades, this is significant.

**Recommendation:**
1. Restrict `refreshCompliance()` to the registrar or add an allowlist of authorized callers
2. Add `invalidateCache(address user, address token)` callable by the registrar for immediate cache clearing
3. Consider per-token configurable TTL (shorter for security tokens)

---

### [H-04] Registrar Centralization — Single Point of Compromise

**Severity:** High
**Lines:** 61, 110-113, 150-155
**Agent:** Agent B

**Description:**

A single `registrar` address has total control over:
1. Registering any token with any compliance configuration
2. Transferring the registrar role to any address (including a malicious one)
3. No timelock, no multi-sig, no DAO governance

Compare with RWAAMM which uses 5 immutable emergency signers with a 3-of-5 threshold (lines 161-167). The compliance oracle has no equivalent protection. A compromised registrar key enables:
- Registering a malicious token with `complianceEnabled = false`, making a security token appear unrestricted
- Setting a malicious `complianceContract` whose `canTransfer()` always returns `true`
- Transferring registrar to a burn address, permanently preventing new registrations

**Impact:** Complete compromise of the compliance system. All RWA trading on OmniBazaar would be at risk.

**Recommendation:** Use OpenZeppelin's `AccessControl` with role separation. Add a timelock on `registerToken()`. Require DAO governance approval for new token registrations.

---

### [M-01] checkCompliance is view But Cannot Write to Cache — Design Mismatch

**Severity:** Medium
**Lines:** 164-226, 266-273
**Agents:** Both

**Description:**

`checkCompliance()` is declared `view` and reads from `_complianceCache` (lines 169-173), but it can never write to the cache. The cache is only populated when someone explicitly calls `refreshCompliance()`. This means:
- Callers using `checkCompliance()` (the primary entry point) never benefit from cached results
- The cache read on line 169 will almost always miss
- Every `checkCompliance()` call makes fresh external calls to token contracts, wasting gas

**Impact:** The caching mechanism is effectively non-functional for the primary code path. Every on-chain consumer incurs full external call gas costs.

**Recommendation:** Refactor into an `internal _checkCompliance()` function used by both the external view function and a state-changing cache-updating wrapper.

---

### [M-02] ERC-3643 Self-Transfer Check Does Not Reflect Trade Compliance

**Severity:** Medium
**Lines:** 399
**Agent:** Agent B

**Description:**

The compliance check calls `canTransfer(user, user, 1)` — checking whether a user can transfer 1 token to themselves. This is a weak proxy for actual trade compliance:

1. Some T-REX implementations have special logic for `from == to` (self-transfers), treating them as no-ops that bypass compliance checks
2. Amount of 1 wei is not representative — compliance rules may include maximum holding limits
3. The actual AMM trade path involves user→pool and pool→user transfers, not self-transfers

**Impact:** Users who should be blocked from trading may pass the compliance check because self-transfers are treated differently by the token contract.

**Recommendation:** Check `canTransfer(user, oracleAddress, amount)` to test a third-party transfer. Pass the actual trade amount rather than hardcoding 1.

---

### [M-03] ERC-1400 Default Partition Invalid — reasonCode Ignored

**Severity:** Medium
**Lines:** 450-497
**Agents:** Both

**Description:**

Two issues in `_checkERC1400Compliance()`:

1. **bytes32(0) partition:** The check uses `defaultPartition = bytes32(0)`, but ERC-1400 does not define a default partition. Many implementations use named partitions (e.g., `bytes32("default")`). If the token doesn't have a `bytes32(0)` partition, the call reverts, returning `CHECK_FAILED` for all ERC-1400 tokens with named partitions.

2. **reasonCode ignored:** `canTransferByPartition` returns a `bytes1 reasonCode` where `0xA0-0xAF` indicate success and other values indicate failure. The current code assumes that if the call doesn't revert, the user is compliant — it ignores `reasonCode` entirely. A token returning `0x50` (transfer failure) without reverting would be misclassified as compliant.

**Impact:** ERC-1400 compliance checks produce either always-failing or false-positive results, depending on the token's partition implementation.

**Recommendation:** Query `partitionsOf(user)` for actual partitions. Check `reasonCode` against success range `0xA0-0xAF`. Allow registrar to specify the partition during token registration.

---

### [M-04] No Token Deregistration or Disabling Mechanism

**Severity:** Medium
**Lines:** 122-144
**Agents:** Both

**Description:**

Once registered, a token cannot be deregistered, disabled, or have its configuration updated. `TokenAlreadyRegistered` (line 127) prevents re-registration. If a compliance contract is compromised or deprecated, the oracle permanently points to it with no recourse except deploying a new oracle.

**Impact:** Inability to respond to compliance contract compromises. Registration errors are permanent.

**Recommendation:** Add `updateTokenConfig()` and `deregisterToken()` functions gated by `onlyRegistrar`. Add a `paused` flag per token for emergency situations.

---

### [M-05] Unbounded Arrays — _registeredTokens and batchCheckCompliance

**Severity:** Medium
**Lines:** 58, 141, 278-291, 331
**Agents:** Both

**Description:**

Two unbounded array issues:

1. `_registeredTokens` array grows without bound (line 141). `getRegisteredTokens()` (line 331) returns the entire array. No deregistration means defunct tokens accumulate indefinitely. Eventually exceeds gas limits for on-chain callers.

2. `batchCheckCompliance()` (line 278) accepts unbounded `users[]` and `tokens[]` arrays. Each entry triggers external calls to compliance contracts. No maximum batch size.

**Impact:** Progressive degradation of view function performance. Potential DoS on RPC endpoints for large batches or large registries.

**Recommendation:** Add `MAX_REGISTERED_TOKENS` cap. Add `MAX_BATCH_SIZE` (e.g., 50) for batch functions. Add pagination to `getRegisteredTokens()`.

---

### [M-06] MCP Server Uses Wrong ABI — Compliance Tools Non-Functional

**Severity:** Medium
**Lines:** N/A (Validator/mcp-server/src/tools/rwa.ts, lines 14-18)
**Agent:** Agent B

**Description:**

The MCP server's `COMPLIANCE_ABI` defines `isCompliant(address, address)` and `getComplianceStatus(address, address)` — neither function exists in the deployed contract. The actual function is `checkCompliance(address, address)` returning a `ComplianceResult` struct. All MCP compliance check tools will revert when called.

**Impact:** Off-chain compliance checking tools are non-functional.

**Recommendation:** Update MCP ABI to match the actual contract interface.

---

### [L-01] this.checkCompliance() Unnecessary External Self-Call

**Severity:** Low
**Lines:** 242, 246, 268, 289
**Agents:** Both

**Description:**

The contract calls `this.checkCompliance(...)` at four locations, using an external CALL instead of an internal function call. Each external self-call costs ~700 gas extra plus ABI encoding/decoding of the `ComplianceResult` struct (which contains a `string` — particularly expensive).

**Recommendation:** Refactor into `_checkCompliance()` internal function. Have the external function delegate to it.

---

### [L-02] _detectTokenStandard() Can Be Gamed by Malicious Tokens

**Severity:** Low
**Lines:** 352-383
**Agent:** Agent B

**Description:**

A malicious token can return `true` for any `supportsInterface()` call, making itself appear as ERC-3643, ERC-1400, or ERC-4626. The fallback `canTransfer(address(0), address(0), 0)` probe (line 375) could match non-ERC-3643 contracts with function selector collisions.

**Impact:** Token misclassification. Partially mitigated by the trust assumption in the registrar role.

**Recommendation:** Allow the registrar to explicitly specify the token standard during registration. Use auto-detection as advisory only.

---

### [L-03] 5-Minute Cache TTL Creates Stale Compliance Window

**Severity:** Low
**Lines:** 36
**Agent:** Agent B

**Description:**

`CACHE_TTL = 5 minutes` means compliance changes take up to 5 minutes to propagate. Combined with H-03 (permissionless `refreshCompliance()`), this creates an exploitable window. However, in practice the cache is rarely populated because `checkCompliance()` is `view` and cannot write to it — making this a lower-severity issue than it appears.

**Recommendation:** Reduce TTL for security tokens. Add per-token configurable TTL.

---

### [I-01] Floating Pragma

**Severity:** Informational
**Agent:** Agent A

**Description:** Uses `^0.8.20`. For deployed contracts, pin to a specific version.

---

### [I-02] addLiquidity/removeLiquidity in RWAAMM Bypass Compliance

**Severity:** Informational (cross-contract observation)
**Agent:** Agent B

**Description:**

RWAAMM's `addLiquidity()` and `removeLiquidity()` perform no compliance checks. Only `swap()` calls `_isComplianceRequired()`. A non-compliant user can provide liquidity for security tokens without any verification. This is an RWAAMM issue, not an oracle issue, but directly undermines the oracle's purpose.

**Recommendation:** Add compliance checks in RWAAMM's `addLiquidity()` and `removeLiquidity()` functions.

---

## Static Analysis Results

**Solhint:** 0 errors, 0 warnings
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 23 raw findings -> 15 unique)
- Pass 6: Report generation

## Conclusion

RWAComplianceOracle is a low-risk contract (no fund custody, non-upgradeable) with **no Critical vulnerabilities**, but has significant **design gaps that undermine its stated purpose**:

1. **Default-compliant for unregistered tokens (H-01)** — the most fundamental issue. The oracle's permissive default means compliance is opt-in rather than fail-safe. Any unregistered security token can be traded without checks.

2. **Wrong ERC-4626 interface ID (H-02)** — `0x7ecebe00` is EIP-2612's `nonces()`, not ERC-4626. Token standard detection is unreliable.

3. **Cache poisoning (H-03)** — anyone can call `refreshCompliance()` to populate the cache with stale or advantageous results during compliance contract transitions.

4. **Registrar centralization (H-04)** — a single compromised key can manipulate the entire compliance system with no multi-sig, timelock, or governance protection.

5. **ERC-1400 compliance is non-functional (M-03)** — the `bytes32(0)` partition doesn't exist on most tokens, and the `reasonCode` return value is ignored.

**Cross-contract note:** The oracle's utility is further diminished by the RWA stack's architectural issues: RWARouter bypasses RWAAMM (and thus the oracle) entirely (RWARouter C-01), and RWAAMM's `addLiquidity()`/`removeLiquidity()` skip compliance checks (I-02). Even a perfectly implemented oracle cannot enforce compliance if the contracts consuming it don't use it consistently.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
