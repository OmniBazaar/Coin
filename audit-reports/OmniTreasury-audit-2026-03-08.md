# Security Audit Report: OmniTreasury

**Date:** 2026-03-08
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Contract:** `Coin/contracts/OmniTreasury.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 569
**Upgradeable:** No
**Handles Funds:** Yes (native XOM, ERC-20, ERC-721, ERC-1155)

## Executive Summary

OmniTreasury is a well-designed, non-upgradeable Protocol-Owned Liquidity (POL) wallet. The contract uses OpenZeppelin's AccessControl, ReentrancyGuard, and Pausable correctly. No Critical or High severity vulnerabilities were found. The primary risks are centralization during Pioneer Phase (intentional/documented) and minor CEI ordering inconsistencies. The contract is production-ready with the recommended mitigations below.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 5 |
| Low | 6 |
| Informational | 3 |

## Cyfrin Checklist Compliance

| Metric | Value |
|--------|-------|
| Applicable Checks | 72 |
| Passed | 63 |
| Failed | 4 |
| Partial | 5 |
| **Compliance Score** | **87.5%** |

**Top 5 Failed/Partial Checks:**
1. SOL-CR-4: No timelock on governance actions (FAIL)
2. SOL-CR-6: Single-step admin role transfer, no AccessControlDefaultAdminRules (FAIL)
3. ~~SOL-AM-DOSA-6: No batch size limit in executeBatch()~~ — **FIXED** (MAX_BATCH_SIZE=64)
4. SOL-CR-CENT-1: Single key can drain all funds during Pioneer Phase (FAIL)
5. ~~SOL-AA-AUTH-3: Same role for pause and unpause~~ — **FIXED** (unpause requires DEFAULT_ADMIN_ROLE)

---

## Medium Findings

### [M-01] Centralization: Single Key Can Drain Treasury During Pioneer Phase

**Severity:** Medium
**Category:** SC01 — Access Control / Centralization
**VP Reference:** VP-06 (Missing Access Control)
**Location:** `constructor()` (line 155)
**Sources:** Agent C, Cyfrin Checklist SOL-CR-CENT-1, Solodit
**Real-World Precedent:** Wintermute (2022-09-20) — $160M compromised admin key; Ronin Bridge (2022-03-23) — $624M compromised validators

**Description:**
During the Pioneer Phase the deployer address holds `DEFAULT_ADMIN_ROLE`, `GOVERNANCE_ROLE`, and `GUARDIAN_ROLE`. A single compromised key can call `transferNative()`, `transferToken()`, or `execute()` to drain all treasury assets. Additionally, a compromised key can `pause()` and then self-revoke `GUARDIAN_ROLE` to permanently brick the contract.

**Exploit Scenario:**
1. Attacker obtains deployer private key
2. Calls `transferNative(attackerAddress, address(this).balance)` to drain native XOM
3. Calls `transferToken(erc20, attackerAddress, balance)` for each ERC-20 held
4. Or calls `execute(token, 0, abi.encodeWithSignature("transfer(address,uint256)", attacker, balance))` to bypass dedicated functions

**Recommendation:**
This is documented as intentional for Pioneer Phase. Mitigate by:
- Transitioning to OmniTimelockController + EmergencyGuardian as soon as possible
- Using a hardware wallet or multi-sig for the deployer key during Pioneer Phase
- Separating GUARDIAN_ROLE from GOVERNANCE_ROLE to different keys immediately

---

### [M-02] No Timelock on Governance Actions

**Severity:** Medium
**Category:** SC01 — Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** All governance functions (lines 182-374)
**Sources:** Cyfrin Checklist SOL-CR-4, Agent C

**Description:**
All governance functions (`transferToken`, `transferNative`, `approveToken`, `transferNFT`, `transferERC1155`, `execute`, `executeBatch`) execute immediately upon invocation by `GOVERNANCE_ROLE`. There is no timelock delay allowing stakeholders to review and potentially veto large outflows.

**Exploit Scenario:**
A compromised GOVERNANCE_ROLE key can drain the treasury instantly with no delay for detection or intervention.

**Recommendation:**
After Pioneer Phase, grant `GOVERNANCE_ROLE` to `OmniTimelockController` (already planned). The timelock enforces a mandatory delay (e.g., 48 hours) on all governance actions, giving guardians time to pause if a malicious proposal is detected.

---

### [M-03] Persistent Allowances After Role Revocation

**Severity:** Medium
**Category:** SC02 — Business Logic
**VP Reference:** VP-49 (Approval Race Condition)
**Location:** `approveToken()` (line 233)
**Sources:** Agent C

**Description:**
`approveToken()` sets ERC-20 allowances that persist indefinitely. If `GOVERNANCE_ROLE` approves a spender for a large amount and then the governance key is rotated (role revoked from old address, granted to new), the old approval remains active. The approved spender can still transfer tokens from the treasury.

**Exploit Scenario:**
1. Governance calls `approveToken(USDC, spenderContract, type(uint256).max)`
2. Later, governance changes (role revoked, granted to timelock)
3. `spenderContract` is compromised and calls `transferFrom(treasury, attacker, fullBalance)`
4. The old approval still works because it was never revoked

**Recommendation:**
- Before revoking `GOVERNANCE_ROLE` from any address, explicitly call `approveToken(token, spender, 0)` for all outstanding allowances
- Document this requirement in the role-transfer runbook
- Consider adding a `revokeAllApprovals(address[] tokens, address[] spenders)` convenience function

---

### [M-04] Same Role for Pause and Unpause — **FIXED**

**Severity:** Medium
**Category:** SC01 — Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** `pause()` / `unpause()` (lines 388-410)
**Sources:** Agent C, Cyfrin Checklist SOL-AA-AUTH-3

**Description:**
Originally both `pause()` and `unpause()` required `GUARDIAN_ROLE`. A compromised guardian could both pause and unpause at will.

**Fix Applied:**
Changed `unpause()` to require `DEFAULT_ADMIN_ROLE` instead of `GUARDIAN_ROLE`. Now only the admin can resume operations after a guardian pause, preventing a compromised guardian from undoing emergency halts. NatSpec updated to document the separation.

---

### [M-05] No Spending Limits or Rate Limiting

**Severity:** Medium
**Category:** SC02 — Business Logic
**VP Reference:** VP-34 (Front-running / Missing Safeguards)
**Location:** All transfer functions
**Sources:** Agent C

**Description:**
There are no per-transaction or per-epoch spending limits. A single governance call can drain the entire treasury balance in one transaction.

**Recommendation:**
Consider implementing:
- Maximum withdrawal amount per transaction
- Cooldown period between large withdrawals
- Or rely on OmniTimelockController's delay (planned post-Pioneer Phase) as the rate-limiting mechanism

---

## Low Findings

### [L-01] transferNative() Emits Event Before External Call — **FIXED**

**Severity:** Low
**Category:** SC08 — Reentrancy / CEI Pattern
**VP Reference:** VP-01 (Classic Reentrancy)
**Location:** `transferNative()` (lines 222-229)
**Sources:** Agent A, Agent B, Agent C

**Fix Applied:**
Moved `emit NativeTransferred(to, amount)` to after the success check, following proper CEI ordering.

---

### [L-02] Missing Zero-Address Check on Token Parameter — **FIXED**

**Severity:** Low
**Category:** SC05 — Input Validation
**VP Reference:** VP-22 (Missing Zero-Address Check)
**Location:** `transferToken()` (line 199), `approveToken()` (line 251)
**Sources:** Agent A

**Fix Applied:**
Added `if (address(token) == address(0)) revert ZeroAddress();` to both `transferToken()` and `approveToken()`.

---

### [L-03] No Batch Size Limit in executeBatch() — **FIXED**

**Severity:** Low
**Category:** SC09 — Denial of Service
**VP Reference:** VP-29 (Unbounded Loop)
**Location:** `executeBatch()` (lines 355-384)
**Sources:** Agent A, Agent B, Cyfrin Checklist SOL-AM-DOSA-6

**Fix Applied:**
Added `uint256 public constant MAX_BATCH_SIZE = 64;`, `error BatchTooLarge();`, and `if (len > MAX_BATCH_SIZE) revert BatchTooLarge();` check at the start of `executeBatch()`.

---

### [L-04] Unbounded Return Data from External Calls

**Severity:** Low
**Category:** SC09 — Denial of Service
**VP Reference:** VP-33 (Unbounded Return Data)
**Location:** `execute()` (line 332), `executeBatch()` (line 368)
**Sources:** Agent A

**Description:**
`execute()` returns `bytes memory returnData` from the external call. A malicious target contract could return an extremely large byte array, consuming excessive gas for memory allocation. In `executeBatch()`, return data from each call is stored in memory (for error reporting) but discarded if the call succeeds.

**Recommendation:**
For `execute()`, this is by design (callers may need return data). For `executeBatch()`, the return data is only used in the error path. The risk is minimal since governance controls which targets are called.

---

### [L-05] Single-Step Admin Role Transfer — **MITIGATED**

**Severity:** Low
**Category:** SC01 — Access Control
**VP Reference:** VP-08 (Unsafe Role Management)
**Location:** Inherited from `AccessControl`
**Sources:** Cyfrin Checklist SOL-CR-6

**Description:**
The contract uses OpenZeppelin's standard `AccessControl` which allows single-step admin role transfer via `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` + `revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin)`. If the new admin address is incorrect (typo), admin access is permanently lost.

**Mitigation Applied:**
Added `transitionGovernance()` — an atomic function that grants all roles to new addresses before revoking the caller's roles. This eliminates misordered renouncement risk. Additionally, `_revokeRole` override prevents removing the last admin while paused, avoiding permanent contract lockout. The residual risk (typo in new admin address) remains but is acceptable given the atomic nature of the transition.

---

### [L-06] View Functions Return Stale Values During Callbacks

**Severity:** Low
**Category:** SC08 — Reentrancy (Read-Only)
**VP Reference:** VP-05 (Read-Only Reentrancy)
**Location:** `tokenBalance()` (line 407), `nativeBalance()` (line 417)
**Sources:** Cyfrin Checklist

**Description:**
During a reentrancy callback (e.g., in `transferNative()`'s external call), `nativeBalance()` returns the post-transfer balance while the `nonReentrant` guard is still active. Any external contract reading this view function during a callback sees potentially inconsistent state. This is mitigated by `nonReentrant` on all state-changing functions.

**Recommendation:**
No code change needed. The `nonReentrant` modifier prevents any exploitable reentrancy. Document that view functions should not be relied upon for invariant checks during callbacks.

---

## Informational Findings

### [I-01] execute() and executeBatch() Bypass Dedicated Function Guards

**Severity:** Informational
**Category:** SC02 — Business Logic
**Location:** `execute()` (line 316), `executeBatch()` (line 346)
**Sources:** Agent A, Agent B

**Description:**
The `execute()` function can perform ERC-20 transfers, NFT transfers, or native XOM transfers by encoding the appropriate calldata, bypassing the dedicated `transferToken()`, `transferNFT()`, etc. functions and their specific input validations (zero-amount checks, per-function events). This is by design for future-proofing, but means that `execute()` can transfer tokens without emitting `TokenTransferred` events.

**Recommendation:**
No code change needed. This is an intentional design trade-off. The `Executed` event captures all data (target, value, calldata) needed for off-chain tracking. Governance should prefer dedicated functions for better event transparency.

---

### [I-02] No fallback() Function

**Severity:** Informational
**Category:** SC02 — Business Logic
**Location:** Contract level
**Sources:** Agent B

**Description:**
The contract has `receive()` but no `fallback()`. Any call with non-empty calldata that doesn't match a function selector will revert. This is intentional — the treasury should only accept plain XOM transfers via `receive()` and explicit function calls.

**Recommendation:**
No change needed. This is correct behavior.

---

### [I-03] Self-Call Prevention on execute() But Not on Role Management

**Severity:** Informational
**Category:** SC01 — Access Control
**VP Reference:** VP-06
**Location:** `execute()` (line 328)
**Sources:** Agent A

**Description:**
`execute()` and `executeBatch()` correctly prevent `target == address(this)` to block self-call exploits. However, governance can still call `grantRole()` / `revokeRole()` directly (inherited from AccessControl). This is expected and correct — role management must be callable.

**Recommendation:**
No change needed. The self-call prevention is specifically for the `execute()` escape hatch. Direct AccessControl role management functions are properly protected by `DEFAULT_ADMIN_ROLE`.

---

## Known Exploit Cross-Reference

| Exploit | Date | Loss | Relevance |
|---------|------|------|-----------|
| Ronin Bridge | 2022-03-23 | $624M | Compromised admin keys — same risk during Pioneer Phase (M-01) |
| Wintermute | 2022-09-20 | $160M | Compromised hot wallet — single-key treasury risk (M-01) |
| Parity Multisig | 2017-11-06 | $150M | Accidental self-destruct on library — no selfdestruct risk here |
| Wormhole | 2022-02-02 | $326M | Uninitialized implementation — N/A (not upgradeable) |
| Beanstalk | 2022-04-17 | $181M | Flash-loan governance — N/A (no token-weighted voting) |

No exploit patterns from the DeFi Exploit Index directly apply to OmniTreasury's architecture. The primary real-world risk is admin key compromise (M-01), which is mitigated by the planned transition to OmniTimelockController.

## Solodit Similar Findings

Cross-reference with Solodit's 50,000+ audit findings revealed common treasury/vault patterns:

1. **Treasury contracts with uncapped execute()** — Multiple audits flag arbitrary execution as a centralization risk. Mitigated here by planned timelock transition.
2. **Missing spending limits on treasury withdrawals** — Common finding in DAO treasury audits. See M-05.
3. **Approval persistence after admin rotation** — Found in several governance treasury audits. See M-03.
4. **Single-step admin transfer** — Commonly flagged; AccessControlDefaultAdminRules recommended. See L-05.

## Static Analysis Summary

### Slither
Not installed on this system. Skipped.

### Aderyn
Not installed on this system. Skipped.

### Solhint
**Result:** 0 errors, 0 warnings (clean)
All `gas-indexed-events` warnings were fixed prior to audit by adding `indexed` to event parameters.

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `grantRole()`, `revokeRole()`, `renounceRole()`, `unpause()`, `transitionGovernance()` | 9/10 — Can grant all other roles and resume operations |
| `GOVERNANCE_ROLE` | `transferToken()`, `transferNative()`, `approveToken()`, `transferNFT()`, `transferERC1155()`, `execute()`, `executeBatch()` | 9/10 — Full control over all assets |
| `GUARDIAN_ROLE` | `pause()` | 3/10 — Can halt operations only (cannot resume) |

## Centralization Risk Assessment

**Single-key maximum damage:** During Pioneer Phase, the deployer key can drain 100% of all treasury assets (native XOM, ERC-20, ERC-721, ERC-1155) in a single transaction. The contract can no longer be permanently bricked — `_revokeRole` prevents removing the last admin while paused.

**Risk Rating:** 8/10 during Pioneer Phase, dropping to 3/10 after timelock + guardian transition.

**Recommendation:**
1. Immediately use a hardware wallet for the deployer key
2. Call `transitionGovernance(timelockAddr, guardianAddr, timelockAddr)` to atomically hand off all roles
3. The deployer loses all three roles in a single transaction — no misordering risk

## Test Coverage

| Category | Tests | Status |
|----------|-------|--------|
| Deployment | 4 | All Pass |
| Native XOM Reception | 2 | All Pass |
| ERC-20 Transfers | 5 | All Pass |
| Native XOM Transfers | 3 | All Pass |
| Token Approvals | 4 | All Pass |
| NFT Transfers (ERC-721) | 3 | All Pass |
| ERC-1155 Transfers | 4 | All Pass |
| Execute | 6 | All Pass |
| ExecuteBatch | 6 | All Pass |
| Access Control | 9 | All Pass |
| Pause/Unpause | 8 | All Pass |
| Reentrancy Protection | 1 | All Pass |
| supportsInterface | 5 | All Pass |
| View Functions | 4 | All Pass |
| transitionGovernance | 9 | All Pass |
| Last Admin Protection | 4 | All Pass |
| **Total** | **80** | **All Pass** |

**Post-audit fixes verified:** L-01, L-02, L-03, M-04, L-05 (mitigated), G3, C4 all tested and passing.

---

*Generated by Claude Code Audit Agent v2 — 6-Pass Enhanced with exploit database cross-referencing*
*Reference data: 56 vulnerability patterns, 288 Cyfrin checks, 640+ DeFiHackLabs incidents, Solodit 50K+ findings*
*Static tools: Solhint (clean), Slither (not installed), Aderyn (not installed)*
