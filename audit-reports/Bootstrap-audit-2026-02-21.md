# Security Audit Report: Bootstrap

**Date:** 2026-02-21
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/Bootstrap.sol`
**Solidity Version:** ^0.8.20
**Lines of Code:** 796
**Upgradeable:** No (standard deployment)
**Handles Funds:** No (node registry only — no token custody)

## Executive Summary

Bootstrap is a non-upgradeable node registry contract deployed on Avalanche C-Chain. It provides self-registration for gateway validators and service nodes, tracks node metadata (multiaddr, endpoints, region, type), maintains activity timestamps via heartbeats, and exposes view functions for node discovery. The contract uses OpenZeppelin's AccessControl for admin operations (deactivation, type changes) and is designed for off-chain enforcement of stake/KYC/participation requirements.

The audit found **no Critical vulnerabilities** (the contract holds no funds) but **2 High-severity issues**: (1) unbounded `registeredNodes` array growth creates a DoS vector where view functions and `getAvalancheBootstrapPeers()` exceed block gas limits after sufficient registrations, and (2) the test suite is completely out of sync with the deployed contract (zero working tests). Additionally, **4 Medium-severity issues** were found: gateway re-registration bypasses peer-info validation, `activeNodeCounts` desynchronization on edge cases, no string length limits on registration inputs, and comma injection in the bootstrap peers output.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 4 |
| Informational | 1 |

## Findings

### [H-01] Unbounded Array Growth — DoS on View Functions and Bootstrap Peers

**Severity:** High
**Lines:** 78, 388, 430, 523, 601, 637
**Agents:** Both

**Description:**

The `registeredNodes` array (line 78) is append-only — nodes are pushed during registration but never removed, even when deactivated. Five view functions iterate the ENTIRE array:
- `getActiveNodes()` (line 388) — filters by type
- `getAllActiveNodes()` (line 430) — returns all active nodes
- `getActiveNodesWithinTime()` (line 523) — filters by recency
- `getActiveGatewayValidators()` (line 601) — filters gateways
- `getAvalancheBootstrapPeers()` (line 637) — builds comma-separated peer string

Additionally, `getAvalancheBootstrapPeers()` uses O(n²) `string.concat()` in a loop (line 658), which has quadratic gas cost due to string copying.

Since registration is permissionless (anyone can call `registerNode()`), an attacker can register thousands of nodes to inflate the array, eventually causing all view functions to exceed the block gas limit. While view functions don't consume on-chain gas when called via `eth_call`, they DO consume gas when called from other contracts, and the RPC node itself may timeout on large arrays.

**Exploit Scenario:**
```
1. Attacker calls registerNode() 10,000 times with different addresses (or same address re-registering)
2. registeredNodes array grows to 10,000+ entries
3. getAvalancheBootstrapPeers() with O(n²) string concat becomes prohibitively expensive
4. Any contract calling these view functions reverts
5. Off-chain services timeout waiting for RPC response
```

**Impact:** Node discovery becomes unavailable. Validators cannot bootstrap from the on-chain registry. The `getAvalancheBootstrapPeers()` function is particularly vulnerable due to quadratic complexity.

**Recommendation:**
1. Maintain a separate `activeNodes` array (or linked list) that only contains currently active nodes
2. Limit `registeredNodes` array to a maximum size (e.g., 1000)
3. Use pagination for view functions: `getActiveNodes(uint256 offset, uint256 limit)`
4. For `getAvalancheBootstrapPeers()`, use `bytes.concat()` with a final `string()` cast instead of repeated `string.concat()`

---

### [H-02] Test Suite Completely Out of Sync — Zero Functional Tests

**Severity:** High
**Lines:** N/A (test file)
**Agent:** Agent B

**Description:**

The test suite for Bootstrap.sol does not match the current contract interface. Function signatures, constructor parameters, and event names have diverged. No test currently passes, meaning:
- Registration logic is untested
- Heartbeat mechanics are untested
- Admin deactivation is untested
- activeNodeCounts tracking is untested
- Edge cases (re-registration, type changes) are untested

**Impact:** No automated verification of contract correctness. Bugs in the registration, heartbeat, and accounting logic would not be caught before deployment.

**Recommendation:** Rewrite the test suite to match the current contract. Priority test cases:
1. Registration + deactivation cycle
2. Re-registration after deactivation
3. Node type changes and activeNodeCounts accuracy
4. Heartbeat updates and `isActive()` checks
5. Array growth and gas consumption benchmarks

---

### [M-01] Gateway Re-Registration via registerNode() Bypasses Peer-Info Validation

**Severity:** Medium
**Lines:** 207-238, 240-290
**Agents:** Both

**Description:**

`registerGatewayNode()` (line 240) requires additional parameters (`nodeID`, `publicIP`, `stakingAddress`) validated for gateway nodes. However, a gateway node can also register via the generic `registerNode()` (line 207), which accepts `nodeType = 0` (gateway) without requiring or validating the gateway-specific fields.

A re-registering gateway that uses `registerNode()` instead of `registerGatewayNode()` bypasses the peer-info requirements. The `NodeInfo` struct stores these fields, but they remain at their default values (empty strings, address(0)).

**Impact:** Gateway nodes can register without complete peer information, making them undiscoverable by the Avalanche P-Chain peer system. `getAvalancheBootstrapPeers()` would include entries with empty node IDs and IPs.

**Recommendation:** In `registerNode()`, require that `nodeType != 0` (gateway), forcing all gateway registrations through `registerGatewayNode()`. Or, merge both functions with conditional validation.

---

### [M-02] activeNodeCounts Desynchronization on Edge Cases

**Severity:** Medium
**Lines:** 87, 216-220, 303-310
**Agents:** Both

**Description:**

`activeNodeCounts` is a `mapping(uint256 => uint256)` tracking the count of active nodes per type. It's manually incremented/decremented in several locations:
1. `registerNode()` — increments for new nodes, adjusts on type change
2. `adminDeactivateNode()` — decrements on deactivation
3. Re-registration after deactivation — increments again

The type-change logic (line 303-310) decrements the old type and increments the new type, but has no underflow guard. If `activeNodeCounts[oldType]` is already 0 (due to a previous bug or edge case), the decrement would underflow (reverts in Solidity 0.8+), permanently preventing the node from changing types.

Additionally, the `isNew` detection (line 216: `nodes[msg.sender].registeredAt == 0`) becomes unreliable after deactivation — a deactivated node still has `registeredAt != 0`, so re-registration takes the "existing node" path.

**Impact:** Node count inaccuracies. Potential permanent inability to change node type if counts desync. Re-registration behavior may differ from fresh registration in unexpected ways.

**Recommendation:** Add `if (activeNodeCounts[oldType] > 0)` guard before decrementing. Consider using a boolean `isRegistered` flag separate from `registeredAt` for cleaner state tracking.

---

### [M-03] No String Length Limits on Registration Inputs

**Severity:** Medium
**Lines:** 207, 240
**Agent:** Agent B

**Description:**

`registerNode()` and `registerGatewayNode()` accept arbitrary-length strings for `multiaddr`, `httpEndpoint`, `wsEndpoint`, `region`, `nodeID`, and `publicIP`. There are no length limits. A malicious registrant could store extremely long strings (e.g., 100KB per field), bloating contract storage and increasing the cost of view functions that return this data.

**Impact:** Storage bloat increases costs for all participants. View functions returning node info become more expensive. `getAvalancheBootstrapPeers()` (which concatenates endpoint strings) becomes even more vulnerable to gas exhaustion.

**Recommendation:** Add maximum length checks:
```solidity
if (bytes(multiaddr).length > 256) revert StringTooLong();
if (bytes(httpEndpoint).length > 256) revert StringTooLong();
```

---

### [M-04] Comma Injection in getAvalancheBootstrapPeers Output

**Severity:** Medium
**Lines:** 637-670
**Agent:** Agent B

**Description:**

`getAvalancheBootstrapPeers()` builds a comma-separated string of `nodeID@publicIP:9651` entries. If a malicious node registers with a `publicIP` containing commas (e.g., `"1.2.3.4:9651,evil-node@attacker.com:9651"`), the output string would contain injected entries that parsers would treat as additional valid peers.

Since registration is permissionless and `publicIP` has no format validation, an attacker can inject arbitrary peer entries into the bootstrap list.

**Impact:** Nodes parsing the bootstrap peers list could connect to attacker-controlled endpoints, enabling eclipse attacks or MITM.

**Recommendation:** Validate that `publicIP` matches an IP address format (no commas, colons, or `@` characters). Or use a structured return type (array of structs) instead of comma-separated strings.

---

### [L-01] Permissionless Registration Enables Spam

**Severity:** Low
**Lines:** 207, 240
**Agents:** Both

**Description:**

Any address can register as a node without staking, KYC, or participation score requirements. While this is documented as intentional (off-chain enforcement), it means the on-chain registry can be filled with spam nodes that never actually run validator software.

**Impact:** The on-chain registry's signal-to-noise ratio degrades. Clients must filter based on off-chain criteria.

**Recommendation:** Consider requiring a small registration deposit (refundable on deactivation) to deter spam, or add a `REGISTRAR_ROLE` that must approve registrations.

---

### [L-02] Admin Deactivation Trivially Bypassed via Re-Registration

**Severity:** Low
**Lines:** 349-365, 207
**Agents:** Both

**Description:**

`adminDeactivateNode()` sets `isActive = false`, but the deactivated node can immediately call `registerNode()` again, which sets `isActive = true`. Admin deactivation provides no lasting enforcement.

**Impact:** Admin moderation is ineffective. A deactivated node can re-register in the same block.

**Recommendation:** Add a `banned` mapping that `registerNode()` checks:
```solidity
mapping(address => bool) public banned;
if (banned[msg.sender]) revert NodeBanned();
```

---

### [L-03] nodeIndex Stored But Never Used

**Severity:** Low
**Lines:** 34, 215
**Agent:** Agent B

**Description:**

The `NodeInfo` struct includes `nodeIndex` (line 34), set during registration (line 215), but it is never read by any function. It occupies a storage slot per node.

**Impact:** Wasted storage gas. No functional impact.

**Recommendation:** Remove `nodeIndex` from the struct, or use it for efficient array access in view functions.

---

### [L-04] getActiveNodesWithinTime Underflow on Large timeWindowSeconds

**Severity:** Low
**Lines:** 523-530
**Agents:** Both

**Description:**

`getActiveNodesWithinTime()` computes `block.timestamp - timeWindowSeconds` without checking for underflow. If `timeWindowSeconds > block.timestamp`, this would underflow and revert in Solidity 0.8+. In practice, `block.timestamp` is always large enough (seconds since 1970), but the check is missing.

**Impact:** Theoretical revert with extremely large `timeWindowSeconds` values. No practical impact.

**Recommendation:** Add `if (timeWindowSeconds > block.timestamp) timeWindowSeconds = block.timestamp;`

---

### [I-01] No On-Chain Enforcement of Validator Requirements (By Design)

**Severity:** Informational
**Agents:** Both

**Description:**

The contract does not enforce stake minimums (1M XOM), KYC requirements (Tier 4), or participation scores (50+ points) on-chain. These are documented as off-chain enforcement by the validator network. This is a conscious design decision noted in the contract's NatSpec.

While this reduces on-chain complexity and gas costs, it means the registry is a trust-minimized phonebook, not a trust-enforced validator set. Clients must independently verify node qualifications.

**Recommendation:** Document this trust model prominently for integrators. Consider adding optional on-chain verification hooks for higher assurance.

---

## Static Analysis Results

**Solhint:** 0 errors, warnings consistent with non-upgradeable AccessControl contract
**Slither/Aderyn:** Not compatible with solc 0.8.33

## Methodology

- Pass 1: Static analysis (solhint)
- Pass 2A: OWASP Smart Contract Top 10 (agent)
- Pass 2B: Business Logic & Economic Analysis (agent)
- Pass 5: Triage & deduplication (manual — 16 raw findings -> 11 unique)
- Pass 6: Report generation

## Conclusion

Bootstrap is a low-risk contract (no fund custody, non-upgradeable) with **no Critical vulnerabilities** but significant operational concerns:

1. **Unbounded array growth (H-01)** is the most impactful issue — permissionless registration can inflate the `registeredNodes` array until view functions become prohibitively expensive, disrupting node discovery for the entire network.

2. **Zero working tests (H-02)** means the contract's correctness is unverified. The test suite must be rewritten before production deployment.

3. **Gateway bypass (M-01)** and **comma injection (M-04)** create vectors for malformed node entries in the bootstrap registry.

4. **Admin deactivation bypass (L-02)** renders moderation ineffective.

The contract's design philosophy (minimal on-chain enforcement, off-chain verification) is appropriate for a bootstrap registry, but the unbounded array and permissionless registration create a Sybil/DoS vector that should be addressed with pagination or registration caps.

---
*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
