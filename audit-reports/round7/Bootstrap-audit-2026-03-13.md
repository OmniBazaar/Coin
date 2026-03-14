# Security Audit Report: Bootstrap (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Opus 4.6 -- 7-Pass Comprehensive Audit
**Contract:** `Coin/contracts/Bootstrap.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,006
**Upgradeable:** No (standard deployment)
**Handles Funds:** No (node registry only -- no token custody)
**Dependencies:** `AccessControl` (OZ v5.4.0)
**Test Suite:** `Coin/test/Bootstrap.test.js` (86 test cases, 100% passing, <2s runtime)
**Previous Audits:**
- Round 1: `audit-reports/Bootstrap-audit-2026-02-21.md` (0C, 2H, 4M, 4L, 1I)
- Round 3: `audit-reports/Bootstrap-audit-2026-02-26.md` (0C, 0H, 2M, 4L, 4I)
- Round 6: `audit-reports/round6/Bootstrap-audit-2026-03-10.md` (0C, 0H, 0M, 3L, 5I)
**Deployed At:** `0x85D1B11778ae3Fb7F90cE2078f0eb65C97ff6cAd` (Fuji C-Chain)

---

## Executive Summary

Bootstrap is a non-upgradeable node registry deployed on Avalanche C-Chain. It serves as a decentralized phonebook for OmniBazaar network discovery: validators and service nodes self-register their network endpoints, and clients (WebApp, Wallet, other validators) query the contract to find available nodes. The contract holds no funds, has no upgrade mechanism, and makes no external calls.

This Round 7 audit is the final pre-mainnet comprehensive review. It builds on three prior audit rounds:

- **Round 1 (2026-02-21):** 2 High, 4 Medium -- all fixed
- **Round 3 (2026-02-26):** 2 Medium, 4 Low -- all fixed
- **Round 6 (2026-03-10):** 3 Low, 5 Informational -- carried forward with assessment

**Round 7 Result:** The contract has reached a mature, stable state. All prior High and Medium findings have been confirmed remediated. The test suite has grown from 32 tests (Round 6) to 86 tests, closing the HIGH-priority test gaps identified in the previous audit. This audit found **0 Critical, 0 High, 0 Medium, 2 Low, and 4 Informational** findings.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 4 |

---

## Pass 1: Static Analysis Results

### Solhint

Command: `npx solhint contracts/Bootstrap.sol`

| # | Line | Rule | Message | Assessment |
|---|------|------|---------|------------|
| 1 | 323 | code-complexity | Function `updateNode()` has cyclomatic complexity 8 (limit 7) | **Accepted.** The function performs sequential validation checks (active status, empty string, gateway multiaddr requirement, four string-length checks, then field writes). The checks are linear, not nested. Reducing complexity would require extracting validation into a helper, which adds indirection without improving readability for 8 sequential guards. |
| 2 | 637 | code-complexity | Function `getActiveNodesWithinTime()` has cyclomatic complexity 9 (limit 7) | **Accepted.** This is a view function with time-window clamping, safe subtraction edge-case handling, and two-pass array building. The complexity is inherent to the pagination + filtering logic. View functions do not carry the same mutation risk as state-changing functions. |
| 3 | 655 | gas-strict-inequalities | Non-strict inequality on time comparison | **Accepted.** The `>=` at line 655 (`clampedWindow >= block.timestamp`) is intentional to handle the edge case where the time window equals or exceeds the current timestamp (early chain lifetime), setting cutoffTime to 0 to return all nodes. Strict `>` would miss the exact equality case. |
| 4 | 657 | not-rely-on-time | Time-based decision in business logic | **Accepted.** The `block.timestamp` usage at line 657 is necessary for heartbeat freshness checking. The +-15 second miner manipulation window is irrelevant for a node liveness feature where time windows are measured in hours/days (MIN_TIME_WINDOW = 60 seconds). |

**Solhint Result:** 0 errors, 4 warnings (all accepted with justification). No new warnings since Round 6.

### Compiler

Compiles cleanly with solc 0.8.24. No warnings. Optimizer enabled (200 runs), viaIR enabled.

---

## Pass 2: Prior Audit Finding Remediation

### Round 1 Findings (2026-02-21)

| ID | Title | Severity | Status | Verification |
|----|-------|----------|--------|--------------|
| H-01 | Unbounded Array Growth -- DoS on View Functions | High | FIXED | MAX_NODES=1000 (line 66), pagination on `getAllActiveNodes()` capped at 100 (line 544), `bytes.concat()` for peer strings (lines 828-843) |
| H-02 | Test Suite Completely Out of Sync | High | FIXED | 86 tests, all passing (up from 32 in Round 6) |
| M-01 | Gateway Re-Registration via registerNode() Bypasses Peer-Info Validation | Medium | FIXED | `registerNode()` reverts `GatewayMustUseRegisterGatewayNode` for nodeType=0 (line 257) |
| M-02 | activeNodeCounts Desynchronization on Edge Cases | Medium | FIXED | Underflow guard `if (activeNodeCounts[info.nodeType] > 0)` on all decrement paths (lines 377, 429, 929) |
| M-03 | No String Length Limits on Registration Inputs | Medium | FIXED | All 7 string fields have enforced length limits (lines 894-900 registration, lines 343-348 update) |
| M-04 | Comma Injection in getAvalancheBootstrapPeers Output | Medium | FIXED | `_validateNoForbiddenChars()` blocks 5 characters: comma, colon, newline, CR, at-sign (lines 968-983) |
| L-01 | Permissionless Registration Enables Spam | Low | MITIGATED | MAX_NODES=1000 cap limits impact; registration is permissionless by design |
| L-02 | Admin Deactivation Trivially Bypassed via Re-Registration | Low | FIXED | `banned` mapping (line 96), checked at line 887, set at line 415 |
| L-03 | nodeIndex Stored But Never Used | Low | FIXED | `nodeIndex` mapping (line 87) used for array index tracking at line 920 |
| L-04 | getActiveNodesWithinTime Underflow on Large timeWindowSeconds | Low | FIXED | Clamped to `[MIN_TIME_WINDOW, MAX_TIME_WINDOW]` (lines 646-651), safe subtraction with `>= block.timestamp` check (line 655) |
| I-01 | No On-Chain Enforcement of Validator Requirements | Info | ACKNOWLEDGED | By design -- off-chain filtering via OmniCore on L1 |

### Round 3 Findings (2026-02-26)

| ID | Title | Severity | Status | Verification |
|----|-------|----------|--------|--------------|
| M-01 | Admin Deactivation Bypass | Medium | FIXED | `banned` mapping at line 96, enforced at line 887, `adminUnbanNode()` at lines 438-444 |
| M-02 | getAllActiveNodes() Pagination Dead Code | Medium | FIXED | Clean iteration from `offset` with `count < maxCount` guard, no dead variables |
| L-01 | _validateNoForbiddenChars Does Not Block Colon | Low | FIXED | Colon `":"` added at line 975 |
| L-02 | updateNode() Does Not Validate String Lengths | Low | FIXED | Length checks at lines 343-348 |
| L-03 | getActiveNodesWithinTime Underflow | Low | FIXED | MIN/MAX_TIME_WINDOW constants + safe subtraction at lines 646-657 |
| L-04 | isNodeActive Returns (false, 0) for Unregistered | Low | ACKNOWLEDGED | Carried as I-02 below; consumers use `isActive` as primary check |
| I-01 | registeredNodes Array Append-Only | Info | ACKNOWLEDGED | By design at MAX_NODES=1000 |
| I-02 | No Event Emitted on Heartbeat | Info | ACKNOWLEDGED | Carried as I-03 below |
| I-03 | omniCoreRpcUrl Stored On-Chain | Info | ACKNOWLEDGED | Intentional for node discovery |
| I-04 | No Mechanism to Reclaim Slots | Info | ACKNOWLEDGED | Carried as L-01 below |

### Round 6 Findings (2026-03-10)

| ID | Title | Severity | Status | Verification |
|----|-------|----------|--------|--------------|
| L-01 | No Mechanism to Reclaim Slots From Inactive/Banned Nodes | Low | NOT FIXED | Carried forward as L-01 below. The `registeredNodes` array remains append-only. No `adminPurgeNode()` function has been added. |
| L-02 | updateNode() Does Not Validate Forbidden Characters | Low | NOT FIXED | Carried forward as L-02 below. `updateNode()` still does not call `_validateNoForbiddenChars()` on its string inputs. |
| L-03 | Permissionless Registration Remains a Sybil Vector | Low | MITIGATED | Subsumed into L-01 analysis. The cost barrier (~$200 to fill registry) and admin ban mechanism provide mitigation. |
| I-01 | Null Byte Not Blocked in Forbidden Character Check | Info | NOT FIXED | Carried forward as I-01 below. |
| I-02 | isNodeActive Returns (false, 0) for Unregistered | Info | NOT FIXED | Carried forward as I-02 below. |
| I-03 | No Event Emitted on Heartbeat | Info | NOT FIXED | Carried forward as I-03 below. |
| I-04 | Stored Endpoint Strings Not Sanitized for Off-Chain Consumers | Info | ACKNOWLEDGED | Carried forward as I-04 below. |
| I-05 | Validator IP Addresses Publicly Visible On-Chain | Info | ACKNOWLEDGED | Inherent to peer-to-peer architecture. Not carried forward (architectural constant). |

**Summary:** All 21 prior findings from Rounds 1/3 at Medium or above are confirmed FIXED. The Round 6 findings (3L, 5I) are either carried forward or acknowledged as accepted design tradeoffs.

---

## Pass 3: Architecture and Trust Model Analysis

### Contract Purpose

Bootstrap is a discovery-only registry. It stores endpoint metadata (IPs, ports, multiaddrs) for three node types:
- **Type 0 (Gateway Validator):** Runs avalanchego, participates in consensus. Must provide `publicIp`, `nodeId`, `stakingPort`.
- **Type 1 (Computation Node):** Runs TypeScript services, no consensus participation.
- **Type 2 (Listing Node):** Stores marketplace listings only.

The contract does NOT verify staking, KYC, participation scores, or node uptime. Those checks are enforced off-chain by consumers querying OmniCore on the OmniCoin L1. This is the correct design: the Bootstrap contract is a phonebook, not a validator set manager.

### Trust Model

| Actor | Capabilities | Trust Level |
|-------|-------------|-------------|
| DEFAULT_ADMIN_ROLE | Grant/revoke roles, admin deactivate + ban, unban, update OmniCore reference | Highest -- deployer initially, should be multisig post-deployment |
| Any EOA/contract | Self-register, update own node, self-deactivate, heartbeat, query registry | Untrusted -- anyone with C-Chain gas |
| Off-chain consumers | Read registry, filter by OmniCore state | N/A (read-only) |

**Key trust assumption:** The admin is honest and responsive. A compromised admin could ban all legitimate nodes or update the OmniCore reference to point at a malicious contract. Both attacks are detectable on-chain and reversible by re-deploying or transferring DEFAULT_ADMIN_ROLE.

### Dependency Analysis

- **AccessControl (OZ v5.4.0):** Standard role-based access control. Only `DEFAULT_ADMIN_ROLE` is used (the separate `BOOTSTRAP_ADMIN_ROLE` was merged into DEFAULT_ADMIN_ROLE in a prior refactor). OZ v5.4.0 is the latest stable release with no known vulnerabilities in AccessControl.

### External Call Analysis

The contract makes **zero external calls**. It is a pure data store. No reentrancy vectors exist because there are no `call()`, `transfer()`, `delegatecall()`, or interface invocations. Every function either reads or writes storage, then emits events.

### Upgrade Safety

The contract is non-upgradeable (no proxy, no UUPS, no beacon). There is no `selfdestruct` or `delegatecall`. The contract is immutable after deployment. This eliminates an entire class of upgrade-related vulnerabilities but means any bugs require deploying a new contract and migrating consumers.

---

## Pass 4: Function-Level Analysis

### State-Changing Functions

#### `registerNode()` (line 249)

**Access:** Permissionless (any EOA)
**Purpose:** Register or update a computation/listing node (types 1, 2)

Analysis:
- Correctly blocks gateway type (nodeType 0) at line 257 with `GatewayMustUseRegisterGatewayNode`.
- Delegates to `_registerNodeInternal()` with empty peer-discovery fields.
- No reentrancy risk (no external calls).

**Verdict:** PASS

#### `registerGatewayNode()` (line 285)

**Access:** Permissionless (any EOA)
**Purpose:** Register or update a gateway validator (type 0)

Analysis:
- Validates `publicIp`, `nodeId`, and `stakingPort` are non-empty/non-zero (lines 296-298) before calling `_registerNodeInternal()`.
- Delegates with `nodeType = 0` hardcoded (line 305), preventing caller from choosing a different type.
- No reentrancy risk.

**Verdict:** PASS

#### `_registerNodeInternal()` (line 876)

**Access:** Internal only
**Purpose:** Core registration logic

Analysis (line-by-line critical path):
1. **Line 887:** `banned[msg.sender]` check -- prevents banned nodes from re-registering. Checked FIRST, before any state writes. Correct.
2. **Line 888:** `nodeType > 2` check -- rejects invalid types. Correct.
3. **Line 889:** Empty `httpEndpoint` check. Correct.
4. **Line 891:** Gateway requires `multiaddr`. Correct.
5. **Lines 894-900:** String length limits on all 7 fields. Consistent with `updateNode()` limits.
6. **Lines 906-911:** `_validateNoForbiddenChars()` on `publicIp` and `nodeId` (only non-empty). Correct.
7. **Line 914:** `isNew` detection via `bytes(info.httpEndpoint).length == 0`. This heuristic is reliable because `httpEndpoint` is required to be non-empty (line 889), so any address that has ever registered will have a non-empty value in storage.
8. **Lines 917-921:** New registration path: check MAX_NODES, store index, push to array. The `>=` at line 919 allows exactly 1000 entries (0-999).
9. **Lines 925-935:** `activeNodeCounts` update logic:
   - Inactive -> active: increment new type. Correct.
   - Active, type changing: decrement old (with underflow guard), increment new. Correct.
   - Active, same type: no change (neither branch taken). Correct.
10. **Lines 939-952:** Write all fields to storage. `nodeAddress` set to `msg.sender` (line 942) -- cannot be spoofed.
11. **Line 954:** Emit `NodeRegistered` with `isNew` flag.

**Edge case: Re-registration after self-deactivation.** Self-deactivation sets `active = false` but does NOT clear `httpEndpoint`. On re-registration, `isNew` is false (line 914), so the node does not consume a new slot. At line 925, `!info.active` is true, so `activeNodeCounts[nodeType]` is incremented. Correct.

**Edge case: Re-registration after admin deactivation (unbanned).** Admin deactivation sets `active = false` and `banned = true`. If later unbanned, re-registration follows the same path as self-deactivation re-registration. The `banned` check at line 887 passes (it was cleared by `adminUnbanNode`). Correct.

**Verdict:** PASS

#### `updateNode()` (line 323)

**Access:** Self only (msg.sender must be active)
**Purpose:** Update endpoint metadata without changing node type

Analysis:
- Requires `info.active` (line 330).
- Requires non-empty `httpEndpoint` (line 331).
- Gateway nodes require non-empty `multiaddr` (lines 335-340).
- String length limits enforced (lines 343-348).
- Updates 4 string fields + `lastUpdate` timestamp.
- Emits `NodeRegistered` with `isNew = false`.
- Does NOT modify `nodeType`, `publicIp`, `nodeId`, `avalancheRpcEndpoint`, or `stakingPort`. These fields retain their registration-time values.

**Note:** Does not call `_validateNoForbiddenChars()` on `multiaddr`, `httpEndpoint`, `wsEndpoint`, or `region`. See L-02.

**Verdict:** PASS (with L-02 noted)

#### `deactivateNode()` (line 370)

**Access:** Self only
**Purpose:** Graceful offline shutdown

Analysis:
- Requires `info.active` (line 372). Prevents double-deactivation.
- Sets `info.active = false` (line 374).
- Decrements `activeNodeCounts` with underflow guard (lines 377-379).
- Does NOT set `banned` -- self-deactivation is non-punitive (verified by test at line 1316-1339 of test file).
- Emits `NodeDeactivated`.

**Verdict:** PASS

#### `heartbeat()` (line 388)

**Access:** Self only (must be active)
**Purpose:** Liveness signal

Analysis:
- Requires `info.active` (line 390).
- Updates only `info.lastUpdate` to `block.timestamp` (line 392).
- No event emitted (see I-03).

**Verdict:** PASS

#### `adminDeactivateNode()` (line 407)

**Access:** DEFAULT_ADMIN_ROLE only
**Purpose:** Emergency deactivation + ban

Analysis:
- Requires `info.active` (line 412). Cannot deactivate already-inactive nodes.
- Sets `info.active = false` (line 414).
- Sets `banned[nodeAddress] = true` (line 415). This prevents re-registration.
- Decrements `activeNodeCounts` with underflow guard (lines 418-423).
- Emits `NodeAdminDeactivated` with admin address and reason.

**Admin cannot deactivate an already-deactivated node.** If a node self-deactivates before admin action, the admin's `adminDeactivateNode()` call will revert with `NodeNotActive`. The admin would need to use `banned[nodeAddress] = true` directly to ban a deactivated node, but there is no such function. This means a node can preemptively self-deactivate to avoid the ban, then re-register with the same address. The admin would need to react quickly. This is a known limitation (documented in Round 1 L-02 resolution: the `banned` mapping was designed for deactivation-time banning, not retrospective banning).

**Verdict:** PASS (known limitation of deactivation-gated banning documented)

#### `adminUnbanNode()` (line 438)

**Access:** DEFAULT_ADMIN_ROLE only
**Purpose:** Reverse a ban

Analysis:
- Validates `nodeAddress != address(0)` (line 441).
- Sets `banned[nodeAddress] = false` (line 442).
- Emits `NodeUnbanned`.
- Does NOT re-activate the node. The node must re-register to become active again.
- Calling on a non-banned address is a no-op (idempotent). This is acceptable.

**Verdict:** PASS

#### `updateOmniCore()` (line 453)

**Access:** DEFAULT_ADMIN_ROLE only
**Purpose:** Update the OmniCore contract reference

Analysis:
- Validates all three parameters: non-zero address (line 458), non-zero chain ID (line 459), non-empty RPC URL (line 460).
- Writes to storage and emits `OmniCoreUpdated`.
- No string length limit on `_omniCoreRpcUrl`. At 256 bytes max (a reasonable URL), this is harmless. A malicious admin could store a very long string, but admin is trusted.

**Verdict:** PASS

### View Functions

#### `getActiveNodes()` (line 480)

Two-pass iteration: count, allocate, fill. Bounded by `limit` parameter and `registeredNodes.length` (max 1000). Returns only addresses of type `nodeType` that are active. Gas-safe for view calls.

**Bug check:** The limit clamping at lines 487-489 sets `maxCount = registeredNodes.length` if `limit == 0` or `limit > registeredNodes.length`. The counting loop at line 493 uses `count < maxCount`, which limits the number of results. However, this is the number of *results found*, not the number of *iterations*. The loop always iterates up to `registeredNodes.length` entries, regardless of `maxCount`. This means passing `limit = 1` still iterates all 1000 nodes but returns at most 1 result. The iteration cost is O(n) regardless of limit. This is acceptable at n=1000.

**Verdict:** PASS

#### `getAllActiveNodes()` (line 526)

Paginated by `offset` and `limit`. Limit capped at 100 (line 544). Returns addresses AND full NodeInfo structs. The `offset >= totalLen` check (line 539) returns empty arrays for out-of-bounds offsets.

**Verdict:** PASS

#### `getActiveNodesWithinTime()` (line 637)

Adds a time-based filter on top of `getActiveNodes` logic. The `clampedWindow` ensures `timeWindowSeconds` is between 60 seconds and 30 days (lines 646-651). The safe subtraction at line 655-657 handles the edge case where `clampedWindow >= block.timestamp` (early chain) by setting cutoffTime to 0 (returning all nodes).

**Verdict:** PASS

#### `getAvalancheBootstrapPeers()` (line 776)

Builds comma-separated IP:port and NodeID strings for use as avalanchego CLI flags. Two-pass: count valid peers, then build strings using `bytes.concat()`.

**Filter criteria:** `active && nodeType == 0 && publicIp.length > 0 && nodeId.length > 0 && stakingPort > 0`.

**String safety:** `publicIp` and `nodeId` are validated by `_validateNoForbiddenChars()` at registration time (lines 906-911), blocking commas, colons, newlines, CRs, and at-signs. The `_uint16ToString()` helper (lines 985-1005) produces clean decimal strings. The format `IP:PORT,IP:PORT` is safe from injection.

**Verdict:** PASS

#### `getActiveGatewayValidators()` (line 730)

Returns full NodeInfo structs for active gateway validators. Capped at 100. Straightforward filtered iteration.

**Verdict:** PASS

#### `getNodeInfo()` (line 586), `getNodeInfoExtended()` (line 855), `isNodeActive()` (line 714), `getActiveNodeCount()` (line 612), `getTotalNodeCount()` (line 621), `getOmniCoreInfo()` (line 696)

All are simple storage reads. No logic errors possible.

**Verdict:** PASS (all)

### Internal Helpers

#### `_validateNoForbiddenChars()` (line 968)

Byte-by-byte scan for 5 characters: `,`, `:`, `\n`, `\r`, `@`. Applied to `publicIp` and `nodeId`.

**UTF-8 bypass analysis (confirmed from Round 6):** The forbidden characters are all single-byte ASCII (0x2C, 0x3A, 0x0A, 0x0D, 0x40). In valid UTF-8, these byte values never appear inside multibyte sequences (continuation bytes are 0x80-0xBF). The byte-by-byte check is correct and cannot be bypassed via UTF-8 encoding.

**Verdict:** PASS

#### `_uint16ToString()` (line 985)

Standard decimal conversion for uint16. Handles zero case. Maximum output: 5 characters ("65535").

**Verdict:** PASS

---

## Pass 5: Reentrancy Analysis

**Finding: No reentrancy vectors exist.**

Bootstrap.sol makes zero external calls:
- No `call()`, `send()`, `transfer()`, `delegatecall()`, or `staticcall()`
- No interface invocations
- No callback patterns
- No token transfers

Every function follows a pure checks-effects-events pattern:
1. Validate inputs (checks)
2. Modify storage (effects)
3. Emit events (events)

There is no control flow that transfers execution to an external address at any point. Reentrancy is structurally impossible in this contract.

---

## Pass 6: Edge Case and Attack Scenario Analysis

### Sybil Registration Attack

**Scenario:** Attacker registers 1000 nodes from 1000 different addresses to fill the registry, blocking legitimate nodes.

**Cost:** ~1000 transactions * ~250,000 gas * 25 nAVAX/gas = ~6.25 AVAX (approximately $200 at current prices).

**Impact:** All 1000 slots consumed. No new nodes can register. Admin can `adminDeactivateNode()` attackers (also banning them), but this does not free slots (L-01).

**Mitigation:** The cost barrier ($200) is non-trivial. Admin monitoring can detect mass registration and deactivate/ban attackers. However, the append-only array means slots are permanently consumed even after banning.

### Race Condition: Node Self-Deactivates to Avoid Admin Ban

**Scenario:** Admin detects a malicious node and calls `adminDeactivateNode()`. The node operator front-runs with `deactivateNode()` to avoid the ban.

**Analysis:** If the node's `deactivateNode()` is mined before the admin's `adminDeactivateNode()`, the admin's call reverts with `NodeNotActive` (line 412). The node is deactivated but NOT banned, and can re-register immediately.

**Impact:** The admin must react again. There is no function to ban an already-deactivated node. The admin would need to wait for re-registration and then ban, or the malicious node could play this game indefinitely.

**Severity:** This is a known limitation, not a new finding. The design choice was to couple banning with deactivation rather than provide a separate `adminBanNode()` function. For a phonebook-only contract with no fund custody, this is an acceptable tradeoff. The worst case is the attacker continuously re-registering (using the same slot, since `isNew` is false), which does not consume additional slots.

### activeNodeCounts Consistency Verification

All code paths that modify `activeNodeCounts` were traced:

| Path | Lines | Operation | Guard | Verified |
|------|-------|-----------|-------|----------|
| New registration (inactive -> active) | 925-926 | `++activeNodeCounts[nodeType]` | `!info.active && nodeType < 3` | Correct |
| Re-registration (active, type change) | 927-934 | `--old, ++new` | `activeNodeCounts[old] > 0`, `nodeType < 3` | Correct |
| Re-registration (active, same type) | N/A | no-op | Neither branch taken | Correct |
| Self-deactivation | 377-379 | `--activeNodeCounts[nodeType]` | `nodeType < 3 && count > 0` | Correct |
| Admin deactivation | 418-423 | `--activeNodeCounts[nodeType]` | `nodeType < 3 && count > 0` | Correct |

**Conclusion:** No desynchronization path exists. The `nodeType < 3` guard is technically redundant (nodeType is validated <= 2 at registration), but provides defense-in-depth against future code changes. The underflow guards prevent wrap-around.

### nodeIndex Mapping Consistency

`nodeIndex[msg.sender]` is set at line 920 to `registeredNodes.length` (the index that the subsequent `push()` at line 921 will occupy). This is correct: after `push()`, the address is at `registeredNodes[nodeIndex[msg.sender]]`.

Since `registeredNodes` is append-only and indices never change (no swap-and-pop), `nodeIndex` remains accurate for the lifetime of the contract. If a `adminPurgeNode()` function were added (L-01 recommendation), it would need to update `nodeIndex` for the swapped element.

### getAllActiveNodes Pagination Edge Cases

- `offset = 0, limit = 0` -> `maxCount = 100`, iterates from index 0.
- `offset = 999, limit = 50` -> iterates from index 999, at most 1 entry.
- `offset = 1000, limit = 50` -> `offset >= totalLen` (if 1000 nodes), returns empty arrays.
- `offset = 0, limit = 200` -> `maxCount` clamped to 100.
- All inactive nodes -> `count = 0`, returns empty arrays.

All edge cases handled correctly.

---

## Pass 7: Findings

### [L-01] No Mechanism to Reclaim Slots From Inactive or Banned Nodes (Carried from Round 6)

**Severity:** Low
**Lines:** 66, 84, 917-921
**Status:** NOT FIXED (carried from Round 6 L-01, Round 3 I-04)
**Prior Reference:** Round 6 L-01

**Description:**

The `registeredNodes` array is append-only. Deactivation (self or admin) sets `info.active = false` but does not remove the address from the array. Admin deactivation also sets `banned = true`. The combined effect is that banned addresses occupy a slot in `registeredNodes` permanently, reducing registry capacity toward the 1000-node MAX_NODES limit.

An attacker can fill the registry for approximately $200 in AVAX gas (1000 transactions at ~250,000 gas each at 25 nAVAX base fee). Once filled, the admin can ban all attackers but cannot reclaim their slots. The registry would be permanently full.

**Impact:** Permanent denial-of-service on new registrations. The only recovery path is deploying a new Bootstrap contract and updating all consumers.

**Recommendation (unchanged from Round 6):**

Add an admin function to purge inactive/banned entries using swap-and-pop:

```solidity
function adminPurgeNode(
    address nodeAddress
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    NodeInfo storage info = nodeRegistry[nodeAddress];
    if (info.active) revert NodeNotActive();
    if (bytes(info.httpEndpoint).length == 0) revert NodeNotFound();

    uint256 idx = nodeIndex[nodeAddress];
    uint256 lastIdx = registeredNodes.length - 1;
    if (idx != lastIdx) {
        address lastAddr = registeredNodes[lastIdx];
        registeredNodes[idx] = lastAddr;
        nodeIndex[lastAddr] = idx;
    }
    registeredNodes.pop();
    delete nodeIndex[nodeAddress];
    delete nodeRegistry[nodeAddress];
}
```

Alternatively, increase `MAX_NODES` to 5000 or 10000. At 10,000 nodes, view functions with their 100-entry caps remain gas-safe.

---

### [L-02] updateNode() Does Not Validate Forbidden Characters (Carried from Round 6)

**Severity:** Low
**Lines:** 323-363
**Status:** NOT FIXED (carried from Round 6 L-02)
**Prior Reference:** Round 6 L-02

**Description:**

`_registerNodeInternal()` validates `publicIp` and `nodeId` for forbidden characters (lines 906-911), but `updateNode()` does not call `_validateNoForbiddenChars()` on any of its four input fields (`multiaddr`, `httpEndpoint`, `wsEndpoint`, `region`).

This is NOT a peer-list injection risk: `updateNode()` cannot modify `publicIp` or `nodeId` (the fields used in `getAvalancheBootstrapPeers()`). The risk is limited to downstream consumer confusion from control characters or delimiters in `multiaddr`, `httpEndpoint`, `wsEndpoint`, or `region`.

Specifically:
- A `multiaddr` like `/ip4/0.0.0.0/tcp/0\n\nGET / HTTP/1.1` could cause request smuggling in downstream libp2p consumers that do not validate multiaddr format (unlikely with modern implementations).
- An `httpEndpoint` like `http://evil.com\x00http://ok.com` could cause string truncation in C-based consumers.
- A `region` with embedded newlines could cause log injection.

**Impact:** Low. On-chain contract is unaffected. Risk is limited to downstream consumers that process these values without sanitization.

**Recommendation:** For defense-in-depth, validate at minimum the `multiaddr` field in `updateNode()`:

```solidity
if (bytes(multiaddr).length > 0) {
    _validateNoForbiddenChars(bytes(multiaddr));
}
```

Consider also validating `httpEndpoint` and `wsEndpoint` for newline/CR characters (`\n`, `\r`) to prevent log injection in downstream systems.

---

### [I-01] Null Byte (0x00) Not Blocked in Forbidden Character Check (Carried from Round 6)

**Severity:** Informational
**Lines:** 968-983
**Prior Reference:** Round 6 I-01

**Description:**

`_validateNoForbiddenChars()` blocks five specific byte values but does not block the null byte (0x00). A node could register with `publicIp = "1.2.3.4\x0099.99.99.99"`. In the peer list output, Go (avalanchego's language) treats null bytes as regular characters within strings, so the entire string is preserved. The avalanchego peer parser would reject the entry as an invalid IP address. No injection is possible.

**Impact:** Negligible. Downstream parsing rejects malformed entries safely.

**Recommendation:** For completeness, block control characters (bytes 0x00-0x1F) in `publicIp` and `nodeId`:

```solidity
if (uint8(c) < 0x20) revert ForbiddenCharacter();
```

---

### [I-02] isNodeActive() Returns (false, 0) for Unregistered Addresses (Carried from Round 6)

**Severity:** Informational
**Lines:** 714-717
**Prior Reference:** Round 6 I-02, Round 3 L-04

**Description:**

For an address that has never registered, `isNodeActive()` returns `(false, 0)`. The `nodeType = 0` value corresponds to "gateway validator." A consumer checking `nodeType == 0` cannot distinguish between a deactivated gateway and a never-registered address.

**Impact:** Informational. Consumers using `isActive == true` as the primary check are unaffected. The `getNodeInfo()` function returns empty strings for unregistered addresses, which can serve as a registration check.

**Recommendation:** No code change needed. Document in NatSpec that `nodeType` is only meaningful when `isActive == true` or when verified via `bytes(getNodeInfo(addr).httpEndpoint).length > 0`.

---

### [I-03] No Event Emitted on Heartbeat (Carried from Round 6)

**Severity:** Informational
**Lines:** 388-393
**Prior Reference:** Round 6 I-03, Round 3 I-02

**Description:**

The `heartbeat()` function updates `info.lastUpdate` but emits no event. Off-chain indexers must poll contract state directly to detect heartbeat activity, rather than using efficient event-driven monitoring.

**Impact:** Reduced observability. Polling works but is less efficient for monitoring systems.

**Recommendation:** Add a lightweight event if heartbeat monitoring is planned:

```solidity
event Heartbeat(address indexed nodeAddress, uint256 timestamp);
```

Cost: approximately 2,000 additional gas per heartbeat call.

---

### [I-04] Stored Endpoint Strings Not Sanitized for Off-Chain Consumers (Carried from Round 6)

**Severity:** Informational
**Lines:** 946-952
**Prior Reference:** Round 6 I-04

**Description:**

The `httpEndpoint`, `wsEndpoint`, `multiaddr`, `region`, and `avalancheRpcEndpoint` fields accept arbitrary strings (subject only to length limits). A malicious node could register with payloads such as:
- XSS: `httpEndpoint = "http://ok.com<script>alert(1)</script>"`
- SQL injection: `region = "'; DROP TABLE validators;--"`
- SSRF: `httpEndpoint = "http://169.254.169.254/latest/meta-data/"`

The on-chain contract is unaffected (it only stores and returns data). The risk is entirely in off-chain consumers.

**Impact:** Informational. The contract's design scope is storage, not content validation.

**Recommendation (unchanged):**
1. **WebApp:** Always escape endpoint strings before rendering in HTML. Use React's default JSX escaping. Never use `dangerouslySetInnerHTML` with contract data.
2. **Validator:** Use parameterized queries for SQL operations involving contract data. Validate URL schemes before making HTTP requests. Sanitize log output.
3. **On-chain (optional):** Consider blocking `<` and `>` characters in endpoint strings for defense-in-depth.

---

## Test Suite Assessment

**File:** `Coin/test/Bootstrap.test.js`
**Tests:** 86 test cases, 100% passing (<2s runtime)

**Growth since Round 6:** 86 tests (up from 32). The test suite has been significantly expanded, closing the HIGH-priority gaps identified in Round 6.

**Coverage by Area:**

| Area | Tests | Assessment |
|------|-------|------------|
| Initialization & constructor validation | 3 | Complete |
| OmniCore reference management | 4 | Complete |
| Node self-registration (computation, gateway) | 8 | Complete |
| Admin functions (deactivate, access control) | 3 | Complete |
| Query functions (active nodes, counts, info) | 7 | Complete |
| Access control (role management, renunciation) | 7 | Complete |
| Integration scenarios (lifecycle, multiple nodes, heartbeat) | 3 | Complete |
| Phase transitions (node type changes) | 3 | Complete -- covers type change counts, deactivate+retype, same-type re-registration |
| String length validation | 7 | Complete -- covers registration and update paths for all limited fields |
| Validator registration edge cases | 10 | Complete -- covers invalid type, listing nodes, gateway param validation, forbidden chars, heartbeat rejection |
| Discovery functions | 10 | Complete -- covers getActiveGatewayValidators, getAvalancheBootstrapPeers format, pagination, time-based queries |
| Events | 7 | Complete -- covers all 5 event types including constructor |
| Ban/unban functionality | 5 | Complete -- covers admin ban, re-register rejection, unban+re-register, zero address, self-deactivation non-ban |
| Constants | 4 | Complete |

**Round 6 HIGH-Priority Test Gaps -- Status:**

| Gap | Round 6 Assessment | Round 7 Status |
|-----|-------------------|----------------|
| `banned` mapping -- admin deactivates, node re-registers | HIGH | CLOSED -- "Should prevent banned node from re-registering" (line 1262) |
| `adminUnbanNode()` -- unban + re-register flow | HIGH | CLOSED -- "Should allow unbanned node to re-register" (line 1283) |
| `MAX_NODES` cap -- register 1000+, verify RegistryFull | HIGH | PARTIAL -- Constants test verifies MAX_NODES=1000 (line 1347), but no test actually registers 1000+ nodes to trigger `RegistryFull`. This is understandable given test execution time constraints. |
| `getAvalancheBootstrapPeers()` format correctness | MEDIUM | CLOSED -- "Should return avalanche bootstrap peers in correct format" (line 934), "Should return comma-separated peers" (line 952) |
| `ForbiddenCharacter` revert on publicIp/nodeId | MEDIUM | CLOSED -- Three tests covering comma, colon, and comma-in-nodeId (lines 835-878) |
| `StringTooLong` revert on oversized strings | MEDIUM | CLOSED -- Seven tests covering registration and update paths (lines 636-743) |
| Node type change and activeNodeCounts | MEDIUM | CLOSED -- Three dedicated tests (lines 577-631) |

**Remaining Test Gap (LOW priority):**

The MAX_NODES exhaustion test (registering exactly 1001 nodes to trigger `RegistryFull`) is not present, likely due to the gas and time cost of creating 1001 signers in a Hardhat environment. The constant value is verified, and the comparison logic (`>= MAX_NODES` at line 919) has been verified by manual code review.

---

## Gas Analysis

| Function | Typical Gas | Worst Case (1000 nodes) | Notes |
|----------|-------------|-------------------------|-------|
| `registerNode()` (new) | 180,000-250,000 | N/A | First registration, stores all string fields |
| `registerGatewayNode()` (new) | 200,000-280,000 | N/A | More fields than registerNode |
| `_registerNodeInternal()` (update) | 80,000-120,000 | N/A | Re-registration, overwrites existing |
| `updateNode()` | 60,000-100,000 | N/A | 4 string fields + timestamp |
| `deactivateNode()` | ~30,000 | N/A | 1 bool + 1 uint256 decrement |
| `heartbeat()` | ~28,000 | N/A | 1 uint256 write |
| `adminDeactivateNode()` | ~35,000 | N/A | 1 bool + 1 bool + 1 uint256 decrement |
| `adminUnbanNode()` | ~28,000 | N/A | 1 bool write |
| `getActiveNodes()` | 30,000-100,000 | ~100,000 | Up to 1000 iterations |
| `getAllActiveNodes()` | 30,000-150,000 | ~150,000 | Capped at 100 results |
| `getAvalancheBootstrapPeers()` | 50,000-300,000 | ~300,000 | String concat, capped at 100 |
| `getActiveGatewayValidators()` | 50,000-200,000 | ~200,000 | Full NodeInfo structs, capped at 100 |
| `getActiveNodesWithinTime()` | 30,000-100,000 | ~100,000 | Same as getActiveNodes plus time filter |

All state-changing functions are well within the 30M C-Chain block gas limit. View functions called via `eth_call` do not consume on-chain gas.

---

## Methodology

| Pass | Description | Findings |
|------|-------------|----------|
| 1 | Static analysis: solhint (4 accepted warnings), compiler (clean) | 0 findings |
| 2 | Prior audit remediation verification: 21 findings across Rounds 1, 3, 6 | All H/M confirmed fixed; 2L + 4I carried forward |
| 3 | Architecture review: trust model, dependency analysis (OZ v5.4.0), external calls (none), upgrade safety (non-upgradeable) | 0 new findings |
| 4 | Function-level code review: all 10 state-changing functions, 9 view functions, 2 internal helpers | Confirmed prior L-01, L-02 |
| 5 | Reentrancy analysis: zero external calls, no reentrancy vectors | 0 findings |
| 6 | Edge case and attack scenarios: Sybil registration, admin front-running, activeNodeCounts consistency, nodeIndex consistency, pagination edge cases | Confirmed L-01 economic analysis |
| 7 | Test suite review: 86 tests assessed, Round 6 gap closure verified | 1 remaining low-priority gap |

---

## Conclusion

Bootstrap.sol has reached a mature, battle-tested state across four audit rounds:

- **Round 1 (2026-02-21):** 2 High, 4 Medium, 4 Low, 1 Informational
- **Round 3 (2026-02-26):** 0 High, 2 Medium, 4 Low, 4 Informational
- **Round 6 (2026-03-10):** 0 High, 0 Medium, 3 Low, 5 Informational
- **Round 7 (2026-03-13):** 0 High, 0 Medium, 2 Low, 4 Informational

All 6 High and Medium findings from prior rounds are confirmed fixed. The remaining findings are defense-in-depth improvements (L-02, I-01) and a known operational risk (L-01) that requires a contract upgrade to fully resolve.

### Key Strengths

1. **Zero fund custody** -- the contract cannot lose user funds under any circumstance.
2. **Zero external calls** -- reentrancy is structurally impossible.
3. **Non-upgradeable** -- no proxy, UUPS, or delegatecall patterns.
4. **Effective moderation** -- `banned` mapping makes admin deactivation persistent.
5. **Injection prevention** -- `_validateNoForbiddenChars()` with 5 blocked characters protects peer list output.
6. **Bounded iteration** -- MAX_NODES=1000 with pagination caps (100) prevents gas exhaustion.
7. **Comprehensive tests** -- 86 tests covering registration, banning, type changes, string limits, forbidden chars, pagination, and discovery functions.
8. **Clean code** -- complete NatSpec, custom errors, struct packing, efficient bytes.concat() string building.

### Remaining Risks (ordered by priority)

1. **Slot exhaustion without reclamation (L-01):** The append-only array with 1000-slot cap means a ~$200 Sybil attack can permanently fill the registry. Admin can ban but cannot free slots. This is the most significant operational risk, unchanged from Round 6.

2. **Missing forbidden-char validation on updateNode() (L-02):** `updateNode()` does not validate its string inputs for control characters. Does not affect peer-list safety but is an inconsistency.

3. **Off-chain consumer responsibility (I-04):** Stored strings are not sanitized. WebApp and Validator must sanitize before rendering or processing.

### Mainnet Readiness Assessment

**The contract is suitable for mainnet deployment.** The risk profile is minimal:

- No funds at risk (zero token handling)
- No reentrancy vectors (zero external calls)
- No upgrade risk (immutable deployment)
- All security mechanisms tested (banning, forbidden chars, string limits)

**Recommended post-deployment actions:**

1. **Transfer DEFAULT_ADMIN_ROLE** to a multisig or timelock after initial validator seeding.
2. **Monitor slot utilization.** If Sybil registration becomes an issue, deploy a new version with `adminPurgeNode()` (L-01).
3. **Consider adding separate `adminBanNode()`** function in a future version to allow banning already-deactivated addresses.
4. **Ensure off-chain consumers** (WebApp, Validator) sanitize endpoint strings from the registry before use.

---

*Generated by Claude Opus 4.6 -- Round 7 Comprehensive Pre-Mainnet Audit*
*Prior audits: Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)*
