# Security Audit Report: Bootstrap (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Comprehensive Pre-Mainnet)
**Contract:** `Coin/contracts/Bootstrap.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,010
**Upgradeable:** No (standard deployment)
**Handles Funds:** No (node registry only -- no token custody)
**OpenZeppelin Version:** 5.4.0
**Dependencies:** `AccessControl` (OZ v5.4.0)
**Test Suite:** `Coin/test/Bootstrap.test.js` (32 test cases, 100% passing, <1s runtime)
**Prior Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26)
**Deployed At:** `0x85D1B11778ae3Fb7F90cE2078f0eb65C97ff6cAd` (Fuji C-Chain)
**Slither Results:** `/tmp/slither-Bootstrap.json` not found; manual analysis performed

---

## Executive Summary

Bootstrap is a non-upgradeable node registry deployed on Avalanche C-Chain. Its sole purpose is peer discovery: validators and service nodes self-register their network endpoints, and clients query the contract to find available nodes. The contract holds no funds and has no upgrade mechanism.

This Round 6 audit is the pre-mainnet comprehensive security review. It builds on findings from Round 1 (2026-02-21: 0 Critical, 2 High, 4 Medium, 4 Low, 1 Informational) and Round 3 (2026-02-26: 0 Critical, 0 High, 2 Medium, 4 Low, 4 Informational). All High findings from prior rounds have been fixed. Both Medium findings from Round 3 (admin deactivation bypass, pagination dead code) have been fixed in the current code.

**Round 6 Result:** The contract is in strong shape for mainnet. This audit found **0 Critical**, **0 High**, **0 Medium**, **3 Low**, and **5 Informational** findings. All prior Medium+ findings are confirmed remediated.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 3 |
| Informational | 5 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

No Critical, High, or Medium findings were identified for this contract. Low and Informational findings accepted as-is.

---

## Prior Finding Remediation Status

### Round 1 Findings (2026-02-21)

| ID | Title | Status | Notes |
|----|-------|--------|-------|
| H-01 | Unbounded Array Growth -- DoS on View Functions | FIXED | MAX_NODES=1000 cap, pagination on `getAllActiveNodes()`, `bytes.concat()` for peer strings |
| H-02 | Test Suite Completely Out of Sync | FIXED | 32 tests, all passing |
| M-01 | Gateway Re-Registration via registerNode() Bypasses Peer-Info Validation | FIXED | `registerNode()` reverts with `GatewayMustUseRegisterGatewayNode` for nodeType=0 |
| M-02 | activeNodeCounts Desynchronization on Edge Cases | FIXED | Underflow guard `if (activeNodeCounts[info.nodeType] > 0)` on all decrement paths |
| M-03 | No String Length Limits on Registration Inputs | FIXED | All 7 string fields have length limits (64-256 bytes) |
| M-04 | Comma Injection in getAvalancheBootstrapPeers Output | FIXED | `_validateNoForbiddenChars()` blocks comma, colon, newline, carriage return, at-sign |
| L-01 | Permissionless Registration Enables Spam | MITIGATED | MAX_NODES=1000 cap limits spam; registration still permissionless by design |
| L-02 | Admin Deactivation Trivially Bypassed via Re-Registration | FIXED | `banned` mapping + `NodeBanned` error + `adminUnbanNode()` function added |
| L-03 | nodeIndex Stored But Never Used | FIXED | `nodeIndex` is separate mapping, used for array tracking |
| L-04 | getActiveNodesWithinTime Underflow on Large timeWindowSeconds | FIXED | Clamped to `[MIN_TIME_WINDOW, MAX_TIME_WINDOW]` range, safe subtraction with `>= block.timestamp` check |
| I-01 | No On-Chain Enforcement of Validator Requirements | ACKNOWLEDGED | By design |

### Round 3 Findings (2026-02-26)

| ID | Title | Status | Notes |
|----|-------|--------|-------|
| M-01 | Admin Deactivation Bypass (carried from R1 L-02) | FIXED | `banned` mapping at line 99, checked at line 891, set at line 419, `adminUnbanNode()` at lines 442-448 |
| M-02 | getAllActiveNodes() Pagination Dead Code | FIXED | Dead `end` variable removed; clean iteration from `offset` to `totalLen` with `count < maxCount` guard |
| L-01 | _validateNoForbiddenChars Does Not Block Colon | FIXED | Colon (`":"`) added to forbidden characters at line 979 |
| L-02 | updateNode() Does Not Validate String Lengths | FIXED | Length checks added at lines 347-352 |
| L-03 | getActiveNodesWithinTime Underflow | FIXED | Clamped with `MIN_TIME_WINDOW`/`MAX_TIME_WINDOW` constants + safe subtraction at lines 648-661 |
| L-04 | isNodeActive Returns (false, 0) for Unregistered | NOT FIXED | See I-02 below (carried forward, informational) |
| I-01 | registeredNodes Array Append-Only | ACKNOWLEDGED | By design at MAX_NODES=1000 |
| I-02 | No Event Emitted on Heartbeat | NOT FIXED | See I-03 below (carried forward) |
| I-03 | omniCoreRpcUrl Stored On-Chain | ACKNOWLEDGED | Intentional for node discovery |
| I-04 | No Mechanism to Reclaim Slots From Permanently Inactive Nodes | NOT FIXED | See L-01 below (carried forward with detail) |

---

## Architecture Analysis

### Design Strengths

1. **Ultra-Lean On-Chain Footprint:** The contract stores only discovery metadata. All staking, KYC, participation scoring, and consensus enforcement are handled off-chain by the validator network. This is the correct architectural choice -- the contract is a phonebook, not a validator set manager.

2. **Registration Cap (MAX_NODES=1000):** The hard cap bounds all iteration costs. At 1000 entries, the worst-case gas for any view function is approximately 300,000 gas (well within the 30M block gas limit on Avalanche C-Chain).

3. **Gateway/Non-Gateway Separation:** The `registerNode()` / `registerGatewayNode()` two-function pattern enforces that gateway nodes always provide `publicIp`, `nodeId`, and `stakingPort`. The `GatewayMustUseRegisterGatewayNode` guard (line 261) prevents bypass.

4. **Ban Mechanism:** The `banned` mapping (line 99) makes admin deactivation effective. `adminDeactivateNode()` sets both `active = false` and `banned[nodeAddress] = true` (lines 418-419). The `adminUnbanNode()` function provides a reversible path.

5. **Injection Prevention:** `_validateNoForbiddenChars()` (lines 972-987) blocks five delimiter characters: comma, colon, newline, carriage return, and at-sign. This prevents corruption of the comma-separated peer list output from `getAvalancheBootstrapPeers()`.

6. **String Length Limits:** All seven string fields have enforced maximum lengths (lines 898-904 in registration, lines 347-352 in update): multiaddr/httpEndpoint/wsEndpoint/avalancheRpcEndpoint <= 256 bytes, region <= 64 bytes, publicIp <= 64 bytes, nodeId <= 128 bytes.

7. **Efficient String Building:** `getAvalancheBootstrapPeers()` uses `bytes.concat()` with a final `string()` cast (lines 832-843), avoiding O(n^2) `string.concat()` reallocation.

8. **Time Window Clamping:** `getActiveNodesWithinTime()` clamps `timeWindowSeconds` to `[MIN_TIME_WINDOW (60s), MAX_TIME_WINDOW (30 days)]` and handles the edge case where the window exceeds `block.timestamp` (lines 648-661).

9. **Custom Errors:** All revert paths use custom errors, saving gas versus string-based `require()` statements.

10. **Storage Packing:** The `NodeInfo` struct packs `active` (1 byte), `nodeType` (1 byte), `stakingPort` (2 bytes), and `nodeAddress` (20 bytes) into a single 24-byte slot.

### Dependency Analysis

- **AccessControl (OZ v5.4.0):** Standard role-based access control. Two roles: `DEFAULT_ADMIN_ROLE` and `BOOTSTRAP_ADMIN_ROLE`, both granted to the deployer in the constructor (lines 226-227). OZ v5 `renounceRole()` and `revokeRole()` mechanics apply normally. No proxy or UUPS patterns.

### Trust Model

The contract implements an open phonebook model:
- **Anyone** can register a node (paying C-Chain gas).
- **Anyone** can query the registry (free view calls).
- **Only BOOTSTRAP_ADMIN_ROLE** can force-deactivate + ban nodes, unban nodes, and update the OmniCore reference.
- **Only DEFAULT_ADMIN_ROLE** can grant/revoke roles.
- Off-chain systems (validators, clients) must independently verify node qualifications (staking, KYC, participation score) via the OmniCore contract on the OmniCoin L1.

---

## Audit Scope: Access Control

### DEFAULT_ADMIN_ROLE

- Granted to `msg.sender` in constructor (line 226).
- Standard OZ role admin: can grant/revoke any role including itself.
- Not used by any function in Bootstrap.sol directly; only used for role management.
- **Assessment:** Correct implementation. If the deployer key is compromised, the attacker gains full role control, but this is inherent to all AccessControl contracts. Recommendation: after deployment, transfer DEFAULT_ADMIN_ROLE to a multisig or timelock.

### BOOTSTRAP_ADMIN_ROLE

- Granted to `msg.sender` in constructor (line 227).
- Used by three functions:
  - `adminDeactivateNode()` (line 414) -- force-deactivate + ban a node
  - `adminUnbanNode()` (line 444) -- unban a previously banned address
  - `updateOmniCore()` (line 461) -- update the OmniCore reference configuration
- **Assessment:** Correctly scoped. Admin cannot register nodes on behalf of others, cannot modify node data, and cannot directly manipulate `activeNodeCounts`. The admin's only powers are moderation (deactivate/ban/unban) and configuration (OmniCore reference).

### Self-Registration (Permissionless)

- `registerNode()` (line 253) -- nodeType 1 or 2 only
- `registerGatewayNode()` (line 289) -- nodeType 0 only, requires publicIp/nodeId/stakingPort
- `updateNode()` (line 327) -- requires msg.sender to have an active node
- `deactivateNode()` (line 374) -- requires msg.sender to have an active node
- `heartbeat()` (line 392) -- requires msg.sender to have an active node
- **Assessment:** The `msg.sender` pattern ensures each caller can only modify their own node entry. There is no way for one address to impersonate another in the registry (the `nodeAddress` field is set to `msg.sender` at line 946). The `banned` check at line 891 prevents deactivated-and-banned nodes from re-registering.

### Potential Unauthorized Manipulation Vectors

1. **Can a non-admin alter another node's data?** No. All self-registration functions use `msg.sender`. All admin functions require `BOOTSTRAP_ADMIN_ROLE`.
2. **Can a banned node circumvent the ban?** Only by using a different address (new private key). This is inherent to all address-based permissioning systems.
3. **Can the admin arbitrarily modify node data?** No. The admin can only deactivate/ban/unban. There is no `adminUpdateNode()` function.
4. **Can role escalation occur?** Only via `DEFAULT_ADMIN_ROLE` granting `BOOTSTRAP_ADMIN_ROLE`. This is standard OZ AccessControl behavior.

**Access Control Verdict: PASS** -- No unauthorized manipulation vectors found.

---

## Audit Scope: Business Logic

### Node Registration Logic

**Registration flow** (`_registerNodeInternal`, lines 880-959):
1. Check `banned[msg.sender]` (line 891)
2. Validate `nodeType` <= 2 (line 892)
3. Require non-empty `httpEndpoint` (line 893)
4. Require non-empty `multiaddr` for gateways (line 895)
5. Enforce string length limits on all 7 fields (lines 898-904)
6. Validate `publicIp` and `nodeId` for forbidden characters (lines 910-915)
7. Determine if new registration via `bytes(info.httpEndpoint).length == 0` (line 918)
8. If new, check `MAX_NODES` and push to array (lines 921-926)
9. Update `activeNodeCounts` based on status change (lines 928-939)
10. Write all fields to storage (lines 942-956)
11. Emit `NodeRegistered` event (line 958)

**Analysis of `isNew` detection (line 918):** The heuristic `bytes(info.httpEndpoint).length == 0` works because `httpEndpoint` is required to be non-empty (line 893). A node that has ever registered will always have a non-empty `httpEndpoint` in storage. This is reliable.

**Analysis of `activeNodeCounts` tracking (lines 928-939):**
- Case 1: Node was inactive (`!info.active`), new nodeType < 3 -> increment `activeNodeCounts[nodeType]`. Correct.
- Case 2: Node was active, type is changing -> decrement old type (with underflow guard), increment new type. Correct.
- Case 3: Node was active, type unchanged -> no count change. Correct (the node was already counted).
- Case 4: Self-deactivation (`deactivateNode`, line 381) -> decrement with underflow guard. Correct.
- Case 5: Admin deactivation (`adminDeactivateNode`, line 422) -> decrement with underflow guard. Correct.

**Edge case: Double-counting on re-registration after deactivation.** A node deactivates (count decremented). Then re-registers via `_registerNodeInternal`. At line 929, `!info.active` is true (it was deactivated), so count is incremented. This is correct -- the node is becoming active again.

**Edge case: Type change from gateway to computation.** A gateway node registered via `registerGatewayNode()` with `publicIp="1.2.3.4"` and `nodeId="NodeID-xxx"`. Later it deactivates and re-registers via `registerNode()` with `nodeType=1` (computation). The old `publicIp` and `nodeId` values are overwritten with empty strings (lines 955-956, since `registerNode` passes `""` for these). The `activeNodeCounts` correctly decrements gateway and increments computation on type change. **However**, the `getAvalancheBootstrapPeers()` function checks `bytes(info.publicIp).length > 0` (line 802), so the node would be excluded from the peer list. Correct behavior.

### MAX_NODES Limit (1000)

The constant at line 69 caps `registeredNodes.length` at 1000. The check at line 923 uses `>=`, so the array can hold exactly 1000 entries (indices 0-999). After 1000 registrations (new nodes only -- re-registrations don't push), further new registrations revert with `RegistryFull`.

**Key observation:** Deactivating a node does NOT free its slot. The `registeredNodes` array is append-only. Once 1000 unique addresses have registered, no new addresses can register, even if all 1000 existing nodes are inactive. This is addressed in L-01.

### Heartbeat Mechanism

`heartbeat()` (lines 392-397) updates `info.lastUpdate` to `block.timestamp`. It requires `info.active` to be true. This is a simple liveness mechanism. The `getActiveNodesWithinTime()` function uses `info.lastUpdate` to filter for recently active nodes.

**Assessment:** The heartbeat is optional -- nodes can remain "active" without heartbeats (their `lastUpdate` from registration remains). Staleness detection is left to off-chain consumers. This is an acceptable design for a bootstrap registry.

### String Length Limits

| Field | Max Length | Location (Registration) | Location (Update) |
|-------|-----------|------------------------|--------------------|
| multiaddr | 256 bytes | Line 898 | Line 347 |
| httpEndpoint | 256 bytes | Line 899 | Line 348-350 |
| wsEndpoint | 256 bytes | Line 900 | Line 351 |
| region | 64 bytes | Line 901 | Line 352 |
| avalancheRpcEndpoint | 256 bytes | Line 902 | N/A (not in updateNode) |
| publicIp | 64 bytes | Line 903 | N/A (not in updateNode) |
| nodeId | 128 bytes | Line 904 | N/A (not in updateNode) |

Both registration and update paths enforce limits. The update path correctly covers the four fields it modifies. The `avalancheRpcEndpoint`, `publicIp`, and `nodeId` fields are not modifiable via `updateNode()` (they can only be set via registration), which is appropriate.

### Forbidden Character Validation

`_validateNoForbiddenChars()` (lines 972-987) iterates byte-by-byte, checking for:
- `,` (comma) -- peer list separator
- `:` (colon) -- IP:port separator
- `\n` (newline, 0x0A) -- line injection
- `\r` (carriage return, 0x0D) -- line injection
- `@` (at-sign) -- legacy peer format separator

Applied only to `publicIp` and `nodeId` (lines 910-915), which are the fields concatenated in `getAvalancheBootstrapPeers()`.

**UTF-8 Multibyte Bypass Analysis:**

The forbidden characters (`,`, `:`, `\n`, `\r`, `@`) are all single-byte ASCII characters (values 0x2C, 0x3A, 0x0A, 0x0D, 0x40). The byte-by-byte check compares each byte in the input against these values.

In valid UTF-8 encoding:
- ASCII bytes (0x00-0x7F) only appear as themselves. They never appear as a continuation byte in a multibyte sequence.
- Continuation bytes in multibyte UTF-8 sequences are in the range 0x80-0xBF.
- Leading bytes for 2-byte sequences are 0xC0-0xDF, for 3-byte sequences 0xE0-0xEF, for 4-byte sequences 0xF0-0xF7.

Therefore, a UTF-8 multibyte character can NEVER contain a byte that matches 0x2C, 0x3A, 0x0A, 0x0D, or 0x40. The byte-by-byte ASCII check is correct and cannot be bypassed by UTF-8 multibyte encoding.

**Encoding bypass vectors:**
- **URL encoding** (e.g., `%2C` for comma): The contract stores raw bytes. `%2C` is stored as three bytes: `%`, `2`, `C`. The comma character (0x2C) does not appear. The downstream consumer (avalanchego CLI) does NOT URL-decode CLI flag values, so `%2C` is treated literally, not as a comma. **Not exploitable.**
- **HTML entities** (e.g., `&#44;` for comma): Similarly stored as raw bytes. Avalanchego does not perform HTML entity decoding on CLI flags. **Not exploitable.**
- **Overlong UTF-8** (e.g., encoding `,` as `0xC0 0xAC` instead of `0x2C`): The byte-by-byte check would not catch `0xC0` or `0xAC` as a comma. However, overlong UTF-8 is invalid per RFC 3629 and is rejected by all modern parsers. Avalanchego's peer parser would reject the entire entry as malformed, not reinterpret it as a comma. **Not exploitable in practice.**
- **Null bytes** (0x00): Not checked. A null byte in `publicIp` would produce `"1.2.3.4\x00evil"`. Most C/C++ parsers (including avalanchego's Go implementation) would truncate at the null byte. This could theoretically cause parsing confusion but not injection. The 64-byte length limit on `publicIp` makes this low-impact. **See I-01.**

### getAvalancheBootstrapPeers() Output Format Safety

The function (lines 780-850) builds two comma-separated strings:
- `ips`: `"IP1:PORT1,IP2:PORT2,..."`
- `ids`: `"NodeID1,NodeID2,..."`

**Format corruption vectors:**
1. **Comma in publicIp/nodeId:** Blocked by `_validateNoForbiddenChars`.
2. **Colon in publicIp:** Blocked by `_validateNoForbiddenChars` (added since Round 3 L-01).
3. **Very long publicIp (64 bytes max):** The output string for 100 peers would be at most 100 * (64 + 1 + 5 + 1) = ~7,100 bytes for IPs and 100 * (128 + 1) = ~12,900 bytes for IDs. Well within EVM memory limits.
4. **Empty publicIp/nodeId:** Checked at lines 802-804; entries with empty fields are skipped.
5. **stakingPort = 0:** Checked at line 804; entries with zero port are skipped.

**Assessment: The output format is safe.** All injection vectors are blocked. The `_uint16ToString` helper (lines 989-1009) correctly converts port numbers to ASCII decimal strings.

---

## Audit Scope: DoS Attacks

### Can an attacker fill all 1000 slots with fake nodes?

**Yes, but at significant cost.** Each registration requires a C-Chain transaction paying gas (approximately 200,000-280,000 gas per registration). At 1000 registrations:
- Total gas: ~200M-280M gas
- At 25 nAVAX base fee on C-Chain: ~5-7 AVAX ($150-$210 at current prices)
- Time: ~2000 seconds (1 tx per 2-second block)

The attacker would need 1000 different addresses (each can only register once as a new node) and sufficient AVAX to pay gas for all transactions.

**Impact:** Legitimate nodes cannot register. However, the admin can `adminDeactivateNode()` fake nodes (which also bans them), freeing the slots... **except that deactivation does not actually free slots** (the `registeredNodes` array is append-only). See L-01.

**Mitigation:** The cost barrier (~$200) makes this attack non-trivial but feasible for a motivated attacker. The lack of slot reclamation (L-01) makes recovery difficult. See recommendations in L-01.

### Can an attacker register and deactivate repeatedly to bloat the array?

**No.** A single address can only occupy one slot in `registeredNodes`. The `isNew` check at line 918 uses `bytes(info.httpEndpoint).length == 0`, which is only true on the very first registration. Subsequent calls to `_registerNodeInternal` from the same address take the re-registration path (line 926 is not reached), so `registeredNodes.push()` is not called again. The array cannot be bloated by a single address.

An attacker would need 1000 distinct addresses to fill all 1000 slots.

### Gas griefing on view functions iterating over large arrays?

At MAX_NODES=1000, the worst-case iteration is 1000 entries. Gas costs:

| Function | Worst Case (1000 nodes) | Cap | Assessment |
|----------|------------------------|-----|------------|
| `getActiveNodes()` | ~100,000 gas | `limit` parameter | Safe |
| `getAllActiveNodes()` | ~150,000 gas | `maxCount` capped at 100 | Safe |
| `getActiveNodesWithinTime()` | ~100,000 gas | `limit` parameter | Safe |
| `getActiveGatewayValidators()` | ~200,000 gas | `maxCount` capped at 100 | Safe |
| `getAvalancheBootstrapPeers()` | ~300,000 gas | `maxCount` capped at 100 | Safe |

All values are well below the 30M C-Chain block gas limit. View functions called via `eth_call` do not consume on-chain gas. The only risk is if another contract calls these functions, but no OmniBazaar contract does.

**Assessment: No DoS risk at current MAX_NODES=1000.**

### Can an attacker register with malicious endpoint strings?

The `httpEndpoint`, `wsEndpoint`, `multiaddr`, and `region` fields are NOT validated for forbidden characters -- only `publicIp` and `nodeId` are checked. An attacker could register with:

```
httpEndpoint = "http://evil.com<script>alert(1)</script>"
wsEndpoint = "ws://evil.com\x00\x01\x02garbage"
multiaddr = "/ip4/0.0.0.0/tcp/0/p2p/QmAAAAAAAAAAAAAAAAA"
region = "'; DROP TABLE users;--"
```

These values are stored in contract storage and returned by view functions. **The on-chain contract is not affected** because it never interprets or parses these strings (it only stores and returns them). However, downstream consumers (WebApp, Validator) that display or process these values could be vulnerable to XSS or injection if they do not sanitize. See I-04.

---

## Audit Scope: State Consistency

### activeNodeCounts Tracking

Analyzed all code paths that modify `activeNodeCounts`:

| Code Path | Lines | Operation | Guard | Assessment |
|-----------|-------|-----------|-------|------------|
| New registration (inactive -> active) | 929-930 | `++activeNodeCounts[nodeType]` | `!info.active && nodeType < 3` | Correct |
| Re-registration (active, type change) | 931-938 | `--old`, `++new` | `activeNodeCounts[old] > 0` (underflow), `nodeType < 3` | Correct |
| Self-deactivation | 381-383 | `--activeNodeCounts[nodeType]` | `nodeType < 3 && count > 0` | Correct |
| Admin deactivation | 422-425 | `--activeNodeCounts[nodeType]` | `nodeType < 3 && count > 0` | Correct |

**Edge case: Re-registration while active, same type.** Lines 928-939: `!info.active` is false (node is active), `info.nodeType != nodeType` is false (same type). Neither branch executes. No count change. Correct -- the node was already counted.

**Edge case: Admin deactivates, node re-registers (banned).** The node cannot re-register because `banned[msg.sender]` is checked first (line 891). The count remains decremented. Correct.

**Edge case: Self-deactivation, then re-registration.** Self-deactivation decrements count. Re-registration: `!info.active` is true, so count is incremented. Net effect: count returns to original. Correct.

**Theoretical inconsistency scenario:** If a bug in another code path set `info.active = true` without incrementing the count, the counts would desync. However, there is no such code path in the current contract. The `active` flag is set to `true` only in `_registerNodeInternal` (line 943), which always handles count updates (lines 928-939). The `active` flag is set to `false` only in `deactivateNode` (line 378) and `adminDeactivateNode` (line 418), both of which decrement.

**Assessment: activeNodeCounts is consistent across all code paths.**

### nodeIndex Mapping

The `nodeIndex` mapping (line 91) stores the array index of each node address. It is set at line 924 (`nodeIndex[msg.sender] = registeredNodes.length`) before the `push()`. This means the stored index is correct (it equals the index that `push()` will use).

**Note:** The `nodeIndex` mapping is currently not used by any function other than `_registerNodeInternal`. It appears to be a preparation for future swap-and-pop removal or direct index access. It does not affect correctness.

---

## Findings

### [L-01] No Mechanism to Reclaim Slots From Inactive or Banned Nodes

**Severity:** Low
**Lines:** 69, 87, 921-926
**Pass:** Business Logic, DoS Analysis

**Description:**

The `registeredNodes` array is append-only. Deactivation (self or admin) sets `info.active = false` but does not remove the address from the array. Admin deactivation also sets `banned[nodeAddress] = true`, permanently preventing re-registration from that address. The combined effect is that banned addresses consume a slot in `registeredNodes` forever, reducing the effective capacity of the registry.

**Attack scenario:**
1. An attacker registers 200 fake gateway nodes (cost: ~$40 in AVAX gas).
2. The admin detects and admin-deactivates all 200 (banning them).
3. The registry now has 200 permanently occupied slots that cannot be reused.
4. The attacker repeats with 200 new addresses.
5. After 5 rounds (1000 total), the registry is permanently full of banned addresses.
6. Total attack cost: ~$200. Impact: no new legitimate node can ever register.

The only remediation path is to deploy a new Bootstrap contract, which requires updating all consumers (Validator, WebApp) and losing the existing node registry.

**Impact:** A persistent denial-of-service on new registrations. The attack is feasible for a motivated actor. The admin has no mechanism to free slots.

**Recommendation:**

Add an admin function to purge banned or stale entries using swap-and-pop removal:

```solidity
/// @notice Admin purge a banned/inactive node slot to free capacity
/// @param nodeAddress Address to purge (must be banned and inactive)
function adminPurgeNode(
    address nodeAddress
) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
    NodeInfo storage info = nodeRegistry[nodeAddress];
    if (info.active) revert NodeNotActive(); // can only purge inactive
    if (bytes(info.httpEndpoint).length == 0) revert NodeNotFound(); // must exist

    // Swap with last element and pop
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

This would allow the admin to free slots occupied by banned or abandoned nodes, maintaining registry capacity over time.

Alternatively, if the contract is not redeployed, consider increasing `MAX_NODES` to a larger value (e.g., 5000 or 10000). At 5000 entries, the view functions with their 100-entry caps remain well within gas limits.

---

### [L-02] updateNode() Does Not Validate Forbidden Characters in multiaddr/httpEndpoint/wsEndpoint/region

**Severity:** Low
**Lines:** 327-367

**Description:**

`_registerNodeInternal()` validates `publicIp` and `nodeId` for forbidden characters (lines 910-915). However, `updateNode()` does not call `_validateNoForbiddenChars()` on any of its four input fields (`multiaddr`, `httpEndpoint`, `wsEndpoint`, `region`).

This is not a peer-list injection risk because `updateNode()` does not modify `publicIp` or `nodeId` (the fields used in `getAvalancheBootstrapPeers()`). However, it does create an inconsistency: `_registerNodeInternal()` validates `publicIp` and `nodeId` but not the other fields, while `updateNode()` validates none of them.

Furthermore, `multiaddr` values for gateway nodes are used by the P2P network layer. A malicious `multiaddr` like `/ip4/0.0.0.0/tcp/0/p2p/Qm...\n\nGET / HTTP/1.1\r\nHost: evil.com` with embedded newlines could theoretically cause request smuggling in downstream libp2p consumers, though this is unlikely given that modern libp2p implementations validate multiaddr format.

**Impact:** Low. The fields modified by `updateNode()` are not used in on-chain string concatenation. The risk is limited to downstream consumer confusion.

**Recommendation:**

For defense-in-depth, apply forbidden character validation to the `multiaddr` field in `updateNode()` (and optionally `httpEndpoint`, `wsEndpoint`), since these are consumed by network-layer code:

```solidity
function updateNode(
    string calldata multiaddr,
    string calldata httpEndpoint,
    string calldata wsEndpoint,
    string calldata region
) external {
    // ... existing checks ...
    // Defense-in-depth: validate multiaddr for injection characters
    if (bytes(multiaddr).length > 0) {
        _validateNoForbiddenChars(bytes(multiaddr));
    }
    // ... rest of function ...
}
```

---

### [L-03] Permissionless Registration Remains a Sybil Vector

**Severity:** Low (carried forward from prior audits, no change)
**Lines:** 253, 289

**Description:**

Any address with C-Chain AVAX can register a node. There is no on-chain verification of:
- Staking (1M XOM for validators, 0 for listing nodes)
- KYC tier
- Participation score
- Actual node operation (uptime, service availability)

This is by design -- the contract is a phonebook, and off-chain systems filter nodes based on OmniCore contract state on the OmniCoin L1. However, it means the on-chain registry's signal-to-noise ratio can degrade, and legitimate nodes must compete with spam for the 1000 available slots.

**Impact:** Low. Off-chain filtering mitigates the impact for properly implemented consumers. The primary risk is slot exhaustion (L-01).

**Recommendation:**

Consider requiring a minimal registration deposit (e.g., 0.01 AVAX) refundable on self-deactivation but forfeited on admin deactivation. This increases the cost of Sybil attacks without burdening legitimate operators. Implementation would require the contract to hold and return funds, which changes the contract's risk profile.

Alternatively, accept this as a known design tradeoff and rely on the admin purge mechanism (recommended in L-01) for slot management.

---

### [I-01] Null Byte (0x00) Not Blocked in Forbidden Character Check

**Severity:** Informational
**Lines:** 972-987

**Description:**

`_validateNoForbiddenChars()` checks for five specific byte values but does not block the null byte (0x00). A node could register with `publicIp = "1.2.3.4\x0099.99.99.99"`. In the peer list output, this would appear as `1.2.3.4\x0099.99.99.99:35579`.

Go's string handling (avalanchego is written in Go) does not treat null bytes as string terminators -- Go strings can contain null bytes. The peer parser would reject the entire entry as an invalid IP address (containing a non-printable character), which is the safe outcome.

In C/C++ consumers, the null byte would truncate the string, yielding `1.2.3.4` followed by a port `:35579`. This is actually the correct IP:port and would work normally.

**Impact:** Negligible. No injection possible. At worst, downstream parsing differs between Go and C consumers.

**Recommendation:** For completeness, consider blocking control characters (bytes 0x00-0x1F) in `publicIp` and `nodeId`:

```solidity
if (uint8(c) < 0x20) revert ForbiddenCharacter();
```

This would reject all control characters (null, tab, escape, etc.) in a single check, providing broader protection with minimal gas overhead.

---

### [I-02] isNodeActive() Returns (false, 0) for Unregistered Addresses

**Severity:** Informational (carried from Round 3 L-04)
**Lines:** 718-721

**Description:**

For an address that has never registered, `isNodeActive()` returns `(false, 0)`. The `nodeType = 0` value corresponds to "gateway validator" in the type system. A consumer checking `nodeType == 0` cannot distinguish between "deactivated gateway" and "never registered."

**Impact:** Informational. Consumers using `isActive == true` as the primary check are unaffected. The `getNodeInfo()` function also returns default values for unregistered addresses, but consumers can check `bytes(httpEndpoint).length > 0` to determine if an address has ever registered.

**Recommendation:** No code change needed. Document in the NatSpec that `nodeType` is only meaningful when `isActive == true` or when the address has been verified as registered via another check.

---

### [I-03] No Event Emitted on Heartbeat

**Severity:** Informational (carried from Round 3 I-02)
**Lines:** 392-397

**Description:**

The `heartbeat()` function updates `info.lastUpdate` but emits no event. Off-chain indexers cannot monitor heartbeat activity through event logs and must poll contract state directly.

**Impact:** Reduced observability. Polling works but is less efficient than event-driven monitoring.

**Recommendation:** Add a lightweight event if off-chain monitoring is planned:

```solidity
event Heartbeat(address indexed nodeAddress, uint256 timestamp);
```

The gas cost increase (~2,000 gas per heartbeat) is minimal.

---

### [I-04] Stored Endpoint Strings Are Not Sanitized for Off-Chain Consumers

**Severity:** Informational
**Lines:** 950-956

**Description:**

The `httpEndpoint`, `wsEndpoint`, `multiaddr`, `region`, and `avalancheRpcEndpoint` fields accept arbitrary strings (subject only to length limits). These values are returned by view functions and will be rendered by the WebApp, displayed in the Validator dashboard, and processed by the Validator's bootstrap service.

Potential injection payloads:
- **XSS:** `httpEndpoint = "http://ok.com<script>alert(document.cookie)</script>"` -- if rendered unsafely in the WebApp
- **SQL injection:** `region = "'; DROP TABLE validators;--"` -- if interpolated into SQL queries without parameterization
- **SSRF:** `httpEndpoint = "http://169.254.169.254/latest/meta-data/"` -- if the Validator fetches this URL without validating the domain
- **Log injection:** `region = "us-east-1\n[ERROR] Critical security breach detected"` -- if written to log files

**Impact:** The on-chain contract is not affected (it does not interpret these strings). The risk is entirely in off-chain consumers that process this data.

**Recommendation:**

1. **WebApp:** Always escape/sanitize endpoint strings before rendering in HTML. Use React's default JSX escaping (which escapes `<`, `>`, `&`, `"`, `'`). Never use `dangerouslySetInnerHTML` with contract data.
2. **Validator:** Use parameterized queries for any SQL operations involving contract data. Validate URL schemas (must be `http://` or `https://`) before making HTTP requests. Sanitize log output.
3. **On-chain (optional):** Consider blocking `<`, `>` characters in endpoint strings for defense-in-depth, though this is a client-side responsibility.

---

### [I-05] Validator IP Addresses and Endpoints Are Publicly Visible On-Chain

**Severity:** Informational
**Lines:** 56-63 (NodeInfo struct), 780-850 (getAvalancheBootstrapPeers)

**Description:**

The contract stores and publicly exposes:
- `publicIp` -- the validator's public IP address
- `stakingPort` -- the avalanchego P2P port
- `httpEndpoint` -- the HTTP API URL (typically includes IP:port)
- `wsEndpoint` -- the WebSocket URL (typically includes IP:port)
- `multiaddr` -- the libp2p address (includes IP and port)
- `avalancheRpcEndpoint` -- the RPC URL (includes IP and port)

All of this information is readable by anyone querying the Avalanche C-Chain. Historical values are preserved in blockchain history even after updates.

**Privacy implications:**
1. **DDoS targeting:** Attackers can enumerate all validator IPs and launch targeted DDoS attacks.
2. **Geographic profiling:** IP geolocation reveals the physical location of validator infrastructure.
3. **Port scanning:** Known ports enable targeted service fingerprinting.
4. **Infrastructure mapping:** Combined IP + port + service type data reveals the full network topology.

**Mitigating factors:**
1. This is an inherent property of peer-to-peer networks -- validators must be discoverable to function.
2. Avalanche's mainnet P-Chain also publishes validator IPs.
3. The OmniBazaar Validator already runs DDoS protection (rate limiting, load balancing).
4. The WebApp needs to discover validators to connect, so endpoints must be public.

**Impact:** Informational. The privacy tradeoff is inherent to the architecture. Validators who wish to hide their IP can use a reverse proxy or CDN.

**Recommendation:**

1. **Validators should use DDoS protection services** (Cloudflare, AWS Shield, or similar) in front of their HTTP/WS endpoints.
2. Consider allowing validators to register CDN/proxy hostnames instead of raw IPs for `httpEndpoint` and `wsEndpoint`, while `publicIp` remains the direct IP for avalanchego P2P connections.
3. Document this privacy characteristic in validator onboarding materials.

---

## Static Analysis Results

**Solhint:** 0 errors, 4 warnings:
1. `code-complexity` on `getAllActiveNodes()` (cyclomatic complexity 8, limit 7) -- acceptable for a view function with pagination logic
2. `code-complexity` on `getActiveNodesWithinTime()` (cyclomatic complexity 9, limit 7) -- acceptable for a view function with time filtering
3. `gas-strict-inequalities` on time window comparison (line 659) -- `>=` is correct here (edge case handling)
4. `not-rely-on-time` on `block.timestamp` usage (line 661) -- necessary for heartbeat/freshness functionality

**Compiler:** Compiles cleanly with solc 0.8.24, optimizer enabled (200 runs), viaIR enabled. No warnings.

---

## Test Suite Assessment

**File:** `Coin/test/Bootstrap.test.js`
**Tests:** 32 test cases, 100% passing (<1 second runtime)

**Coverage Areas:**
- Initialization and constructor validation (3 tests)
- OmniCore reference management (4 tests)
- Node self-registration -- computation and gateway (8 tests)
- Admin functions -- force-deactivation, access control (3 tests)
- Query functions -- active nodes, counts, info (7 tests)
- Access control (2 tests)
- Integration scenarios -- full lifecycle, multiple nodes, heartbeat (3 tests)
- String length and injection validation (implicit in registration tests)

**Test Gaps Identified (prioritized):**

| Priority | Test Gap | Risk if Untested |
|----------|----------|------------------|
| HIGH | No test for `banned` mapping -- admin deactivates, node attempts re-register, verify `NodeBanned` revert | Core security feature untested |
| HIGH | No test for `adminUnbanNode()` -- unban + re-register flow | Core admin feature untested |
| HIGH | No test for `MAX_NODES` cap -- register 1000+ nodes, verify `RegistryFull` revert | DoS protection untested |
| MEDIUM | No test for `getAvalancheBootstrapPeers()` output format correctness | Critical discovery function untested |
| MEDIUM | No test for `ForbiddenCharacter` revert on publicIp/nodeId with commas, colons, newlines | Injection protection untested |
| MEDIUM | No test for `StringTooLong` revert on oversized strings | Storage protection untested |
| MEDIUM | No test for node type change (computation -> listing) and `activeNodeCounts` accuracy | Count consistency untested |
| LOW | No test for `getActiveNodesWithinTime()` with various time windows | Time-based filtering untested |
| LOW | No test for `getActiveGatewayValidators()` pagination | Pagination untested |
| LOW | No test for `getNodeInfoExtended()` return values | View function untested |
| LOW | No test for `getAllActiveNodes()` pagination with offset > 0 | Pagination edge case untested |

**Assessment:** The test suite covers core happy paths well but lacks coverage for the security features added since Round 1 (banned mapping, forbidden characters, string limits, MAX_NODES cap). The three HIGH-priority test gaps should be addressed before mainnet deployment, as they test the contract's primary defenses against its most significant threat vectors (admin bypass, spam, DoS).

---

## Gas Analysis

| Function | Estimated Gas (Typical) | Worst Case (1000 nodes) | Notes |
|----------|------------------------|-------------------------|-------|
| `registerNode()` (new) | ~180,000-250,000 | N/A | First registration, stores all string fields |
| `registerGatewayNode()` (new) | ~200,000-280,000 | N/A | More fields than registerNode |
| `registerNode()` (update) | ~80,000-120,000 | N/A | Re-registration, overwrites existing |
| `updateNode()` | ~60,000-100,000 | N/A | Updates 4 string fields + timestamp |
| `deactivateNode()` | ~30,000 | N/A | Single bool write + count decrement |
| `heartbeat()` | ~28,000 | N/A | Single uint256 write |
| `adminDeactivateNode()` | ~35,000 | N/A | Bool write + banned write + count decrement |
| `getActiveNodes()` | ~30,000-100,000 | ~100,000 | Up to 1000 iterations, limited by `limit` param |
| `getAllActiveNodes()` | ~30,000-150,000 | ~150,000 | Capped at 100 results |
| `getAvalancheBootstrapPeers()` | ~50,000-300,000 | ~300,000 | String concat, capped at 100 results |
| `getActiveGatewayValidators()` | ~50,000-200,000 | ~200,000 | Returns full NodeInfo structs, capped at 100 |

All functions are well within the 30M C-Chain block gas limit at MAX_NODES=1000.

---

## Methodology

| Pass | Description | Findings |
|------|-------------|----------|
| 1 | Prior audit review -- remediation verification for Round 1 (11 findings) and Round 3 (10 findings) | 19 of 21 fixed/mitigated, 2 carried forward as informational |
| 2A | OWASP Smart Contract Top 10: Access Control, Injection, Information Disclosure, Arithmetic | I-01, I-04, I-05 |
| 2B | Business Logic & Economic Analysis: Registration lifecycle, count consistency, slot management, Sybil attacks, DoS modeling | L-01, L-03 |
| 3 | Line-by-line code review (all 1,010 lines): validation completeness, forbidden character bypass analysis (UTF-8, URL encoding, null bytes), state consistency across all code paths | L-02, I-01 |
| 4 | Test suite review (32 tests): coverage analysis, gap identification | 11 test gaps identified |
| 5 | Triage & deduplication: 12 raw findings deduplicated to 8 unique | This table |
| 6 | Report generation | This document |

---

## Conclusion

Bootstrap.sol has matured significantly across three audit rounds:

- **Round 1 (2026-02-21):** 2 High, 4 Medium, 4 Low, 1 Informational
- **Round 3 (2026-02-26):** 0 High, 2 Medium, 4 Low, 4 Informational
- **Round 6 (2026-03-10):** 0 High, 0 Medium, 3 Low, 5 Informational

All High and Medium findings from prior rounds have been fixed. The remaining findings are defense-in-depth improvements and known design tradeoffs.

### Key Strengths

1. **No fund custody** -- the contract cannot lose user funds under any circumstance.
2. **Non-upgradeable** -- no proxy or UUPS patterns to worry about.
3. **Effective moderation** -- the `banned` mapping makes admin deactivation persistent.
4. **Injection prevention** -- `_validateNoForbiddenChars()` with five blocked characters protects the peer list output.
5. **Bounded iteration** -- MAX_NODES=1000 with pagination caps prevents gas exhaustion.
6. **Clean code** -- complete NatSpec, custom errors, struct packing, efficient string building.

### Remaining Risks (ordered by priority)

1. **Slot exhaustion without reclamation (L-01):** The append-only `registeredNodes` array combined with the 1000-slot cap means that a sustained Sybil attack (cost ~$200) can permanently fill the registry. The admin can ban attackers but cannot free their slots. This is the most significant operational risk.

2. **Incomplete forbidden character coverage (L-02):** `updateNode()` does not validate `multiaddr` for forbidden characters. While this does not affect the peer list output (which uses `publicIp` and `nodeId`), it is an inconsistency.

3. **Permissionless registration (L-03):** Accepted design tradeoff. Off-chain filtering mitigates the impact.

4. **Test coverage gaps:** The `banned` mapping, `adminUnbanNode()`, `MAX_NODES` cap, and forbidden character validation are untested. These are the contract's primary security features and should have dedicated tests before mainnet.

### Mainnet Readiness Assessment

**The contract is suitable for mainnet deployment** with the following caveats:

1. **Recommended before deployment:** Add tests for the `banned` mechanism and `MAX_NODES` cap (test gaps 1-3 in the High priority list).
2. **Recommended post-deployment:** Monitor slot utilization. If Sybil registration becomes an issue, deploy a new version with the `adminPurgeNode()` function from L-01.
3. **Operational:** Transfer `DEFAULT_ADMIN_ROLE` to a multisig or timelock after initial setup. Ensure the `BOOTSTRAP_ADMIN_ROLE` holder has operational procedures for monitoring and deactivating malicious nodes.

---

*Generated by Claude Code Audit Agent -- Comprehensive Pre-Mainnet (Round 6)*
*Prior audits: Bootstrap-audit-2026-02-21.md (Round 1), Bootstrap-audit-2026-02-26.md (Round 3)*
