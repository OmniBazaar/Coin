# Security Audit Report: LegacyBalanceClaim.sol (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/LegacyBalanceClaim.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 991
**Upgradeable:** No (standard deployment with Ownable)
**Handles Funds:** Yes (pre-funded XOM pool for legacy balance distribution via safeTransfer)
**Previous Audits:** Round 1 (2026-02-21), Round 3 (2026-02-26), Round 6 (2026-03-10)

---

## Executive Summary

LegacyBalanceClaim is a non-upgradeable migration contract that allows 4,735 legacy OmniCoin V1 users to claim their balances in V2. The contract is pre-funded with up to 4.13 billion XOM (MAX_MIGRATION_SUPPLY) by the deployer. Claims are fulfilled via `SafeERC20.safeTransfer()` from the contract's token balance, not via minting. Backend validators independently verify legacy credentials off-chain and produce ECDSA signatures. The contract requires M-of-N multi-sig validation proofs to authorize each claim. After a 2-year migration period (730 days), unclaimed balances can be finalized to a specified recipient.

**Round 7 Assessment:** This fourth audit pass confirms that all Critical and High findings from prior rounds remain properly remediated. The Round 6 Medium finding (M-01, nonce per-address) has been addressed through comprehensive NatSpec documentation (lines 113-120) that explicitly documents the constraint and recommended usage pattern. The test suite identified as missing in Round 6 L-02 has been created with comprehensive coverage (1,755 lines, 63+ test cases). The contract is mature, well-documented, and follows established security patterns throughout.

**This Round 7 audit finds zero Critical, zero High, zero Medium, two Low, and three Informational findings.**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 3 |

---

## Remediation Status from All Prior Audits

| Prior Finding | Severity | Status | Notes |
|---------------|----------|--------|-------|
| R1 C-01: ecrecover bypass (address(0) return) | Critical | **FIXED** | OpenZeppelin `ECDSA.recover()` reverts on invalid signatures (line 776). Constructor validates all validator addresses non-zero (line 979). |
| R1 H-01: Missing chainId in signature | High | **FIXED** | `block.chainid` and `address(this)` included in signed message (lines 759-760). |
| R1/R3 H-02: Single validator trust | High | **FIXED** | M-of-N multi-sig with bitmap-based duplicate detection. Up to 20 validators. `validators[]` array, `isValidator` mapping, `requiredSignatures` threshold (lines 102-108, 740-798). |
| R1 H-03: No finalization timelock | High | **FIXED** | `DEPLOYED_AT + MIGRATION_DURATION` (730 days) enforced at line 486-493. |
| R1/R3 M-01: Unbounded minting / No pause | Medium | **FIXED** | `MAX_MIGRATION_SUPPLY = 4_130_000_000e18` enforced at `initialize()` (line 364), `addLegacyUsers()` (line 396), `claim()` (line 450), and `finalizeMigration()` (line 502). `Pausable` integrated with `whenNotPaused` on `claim()` (line 431). |
| R3 M-02: abi.encodePacked with dynamic string | Medium | **FIXED** | `abi.encode` used at line 755. NatSpec documents rationale (lines 53-54, 733). |
| R3 L-01: Missing nonce in signature | Low | **FIXED** | Per-user nonce via `claimNonces[ethAddress]` (line 121). Included in signed message (line 758). Consumed at line 463. |
| R3 L-02: initialize/addLegacyUsers ordering | Low | **FIXED** | Boolean `initialized` flag (line 111). `initialize()` sets it (line 357). `addLegacyUsers()` requires it (line 388). |
| R6 M-01: Nonce per-address not per-username | Medium | **DOCUMENTED** | NatSpec at lines 113-120 now explicitly documents the constraint and usage recommendation. See I-01 below for residual note. |
| R6 L-01: No caller check on claim() | Low | **ACCEPTED BY DESIGN** | Permissionless claim submission is intentional; multi-sig proofs serve as authorization. |
| R6 L-02: No test coverage | Low | **FIXED** | Test file `test/LegacyBalanceClaim.test.js` created with 63+ test cases (1,755 lines), covering constructor, initialize, addLegacyUsers, claim lifecycle, signature verification, finalization, validator set updates, pause/unpause, view functions, edge cases, and constants. |
| R6 I-01: finalizeMigration accounting vs balance | Info | **OPEN** | Retained as I-02 below. |
| R6 I-02: Indexed string event parameter | Info | **OPEN** | Retained as I-03 below. |
| R6 I-03: Validator set downgrade to 1-of-1 | Info | **OPEN** | Retained as L-02 below. |

---

## Low Findings

### [L-01] `claim()` Does Not Verify `_msgSender()` Matches `ethAddress` -- ERC-2771 Integration Unused for Claims

**Severity:** Low
**Category:** Authorization / ERC-2771
**Location:** `claim()` (lines 426-471)

**Description:**

The `claim()` function accepts an `ethAddress` parameter specifying the token recipient but does not verify that the caller (`msg.sender` or `_msgSender()` via ERC-2771) matches `ethAddress`. Any address can submit a claim for any `ethAddress`, provided valid multi-sig proofs are supplied.

The contract inherits `ERC2771Context` and overrides `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` (lines 832-877). However, the `claim()` function never calls `_msgSender()`. The ERC-2771 integration only affects `onlyOwner` functions (via `Ownable` which internally calls `_msgSender()`). This means:

1. **Meta-transaction support for claims is not utilized.** If a trusted forwarder is configured, users cannot benefit from gasless claim submissions since `claim()` does not check `_msgSender()`.

2. **Gas griefing via front-running.** Anyone who obtains valid proofs (which are deterministic given the same inputs) could front-run the intended submitter. Tokens always go to the correct `ethAddress`, so no funds are at risk, but the original submitter wastes gas on a reverted transaction.

3. **Trusted forwarder risk on admin functions.** The trusted forwarder is immutable (`ERC2771Context` stores it as immutable). If the forwarder contract is compromised or has vulnerabilities, it can impersonate the owner for all `onlyOwner` functions: `initialize()`, `addLegacyUsers()`, `finalizeMigration()`, `updateValidatorSet()`, `pause()`, `unpause()`. This is a meaningful attack surface if the forwarder is not `address(0)`.

**Impact:** Gas griefing on claim submission (no fund loss). Unused ERC-2771 complexity. Potential admin impersonation via compromised forwarder.

**Recommendation:**

If the intended operational model is validator-submitted claims (not user-submitted), the permissionless design is correct. Document this explicitly.

If meta-transactions are not needed for this contract, deploy with `trustedForwarder_ = address(0)` to eliminate the forwarder attack surface entirely. The constructor already supports this (line 311).

If meta-transactions ARE needed, add `_msgSender()` usage in `claim()`:
```solidity
// Option: require meta-tx sender matches ethAddress
if (_msgSender() != ethAddress) revert Unauthorized();
```

---

### [L-02] Owner Can Downgrade Validator Set to 1-of-1 After Deployment

**Severity:** Low
**Category:** Centralization Risk / Governance
**Location:** `updateValidatorSet()` (lines 529-552), `_validateValidatorSet()` (lines 954-990)

**Description:**

The `_validateValidatorSet()` function validates `_requiredSigs >= 1` and `_requiredSigs <= _validators.length` (lines 967-975). This allows the owner to call `updateValidatorSet()` with a single validator and `requiredSignatures = 1`, effectively reverting to the single-validator trust model that was identified as a High finding in Rounds 1 and 3.

For a contract managing up to 4.13 billion XOM, a 1-of-1 validator set means:
- A single compromised validator key enables draining all unclaimed balances via fabricated claims.
- The owner could set themselves as the sole validator, combining owner and validator power into a single key.

There is no minimum threshold enforced by the contract itself. The security guarantee relies entirely on the owner's operational discipline.

**Impact:** Owner can unilaterally reduce the multi-sig security guarantee. Governance concern, not a code bug.

**Recommendation:**

Consider enforcing a minimum threshold:
```solidity
uint256 public constant MIN_REQUIRED_SIGNATURES = 2;
```
And in `_validateValidatorSet()`:
```solidity
if (_requiredSigs < MIN_REQUIRED_SIGNATURES) {
    revert InvalidValidatorSet(_requiredSigs, _validators.length);
}
```

Alternatively, if 1-of-1 is needed for bootstrapping or testing, document that the production deployment MUST maintain at least a 3-of-5 threshold and consider making the owner a Gnosis Safe or TimelockController.

---

## Informational Findings

### [I-01] Nonce Per-Address Design Requires Strict Claim Ordering When Consolidating to Single Address

**Severity:** Informational
**Category:** Business Logic / Usability
**Location:** `claimNonces` mapping (line 121), NatSpec documentation (lines 113-120)

**Description:**

The Round 6 M-01 finding (nonce keyed to `ethAddress` rather than `usernameHash`) has been addressed through NatSpec documentation at lines 113-120:

```solidity
/// @dev R6 M-01: The nonce is keyed to ethAddress, NOT usernameHash.
///      This means if multiple legacy usernames target the SAME ethAddress,
///      claims must be submitted strictly in the order their nonces were
///      signed. An out-of-order submission invalidates all subsequent
///      pre-signed proofs for that address. For best results, each legacy
///      username should claim to a unique ethAddress. If consolidation is
///      needed, use different addresses for each claim, then transfer.
```

The documentation is thorough and the recommended workaround (unique addresses per claim) is practical. The test suite also validates this behavior with dedicated test cases ("should handle multiple usernames claiming to the same ethAddress with sequential nonces" and "should reject out-of-order nonce for same ethAddress").

This is retained as Informational to ensure the operational team is aware of the constraint when building the claim frontend/backend workflow.

**Impact:** Operational awareness. No code change needed.

**Recommendation:** Ensure the validator backend signing service enforces sequential nonce ordering when a user requests multiple claims to the same address. Consider adding a UI warning when a user attempts to consolidate multiple legacy accounts to a single address.

---

### [I-02] `finalizeMigration()` Accounting May Not Match Actual Token Balance

**Severity:** Informational
**Category:** Accounting / Edge Case
**Location:** `finalizeMigration()` (line 495)

**Description:**

The unclaimed amount is computed from internal accounting:
```solidity
uint256 unclaimed = totalReserved - totalClaimed;
```

This does not reference the actual token balance (`OMNI_COIN.balanceOf(address(this))`). The two can diverge in these scenarios:

1. **Under-funding:** If the deployer transfers fewer tokens than `totalReserved`, `finalizeMigration()` will attempt to transfer more than available, causing a `SafeERC20` revert. Individual claims would also fail as the balance depletes.

2. **Over-funding:** If the deployer transfers more tokens than `totalReserved`, excess tokens are permanently locked. No sweep function exists.

3. **Accidental transfers:** XOM sent directly to the contract by any party is permanently locked.

The absence of a sweep function is actually a security benefit -- it prevents the owner from draining the claim pool. However, after finalization, any remaining tokens (from over-funding or rounding) are irrecoverable.

**Impact:** Operational risk during deployment. No security vulnerability. `SafeERC20` provides a hard revert safety net against under-funding.

**Recommendation:**

Add a view function for deployment verification:
```solidity
function getFundingStatus() external view returns (
    uint256 contractBalance,
    uint256 requiredBalance,
    bool adequatelyFunded
) {
    contractBalance = OMNI_COIN.balanceOf(address(this));
    requiredBalance = totalReserved - totalClaimed;
    adequatelyFunded = contractBalance >= requiredBalance;
}
```

Consider adding a post-finalization sweep for excess tokens:
```solidity
function sweepExcessTokens(address recipient) external onlyOwner {
    if (!migrationFinalized) revert MigrationNotFinalized();
    uint256 excess = OMNI_COIN.balanceOf(address(this));
    if (excess > 0) OMNI_COIN.safeTransfer(recipient, excess);
}
```

---

### [I-03] Indexed String Event Parameter Stores Hash, Not Plaintext

**Severity:** Informational
**Category:** Usability / Event Design
**Location:** `BalanceClaimed` event (lines 160-164)

**Description:**

```solidity
event BalanceClaimed(
    string indexed username,     // Stored as keccak256(username) in topic
    address indexed ethAddress,
    uint256 indexed amount       // Rarely useful as exact-match topic filter
);
```

Indexed dynamic types (`string`, `bytes`) store only their `keccak256` hash in the event topic. Callers cannot filter events by plaintext username without pre-computing the hash. Additionally, `amount` is indexed when it would be more useful as unindexed data (amounts are rarely used as exact-match filters).

A more ergonomic signature would be:
```solidity
event BalanceClaimed(
    bytes32 indexed usernameHash,
    address indexed ethAddress,
    uint256 amount,
    string username
);
```

**Impact:** Developer ergonomics for off-chain indexing. No security impact.

**Recommendation:** This is a known design trade-off from Round 3. Changing the event signature is a breaking change for any off-chain indexers that may already be coded against the current signature. Accept as-is unless a breaking change window is planned.

---

## Vulnerability Pattern Scan (VP-01 through VP-58)

| VP | Pattern | Status | Notes |
|----|---------|--------|-------|
| VP-01 | Classic Reentrancy | **SAFE** | `nonReentrant` modifier on `claim()` (line 431). CEI pattern followed: state updates at lines 458-463 precede `safeTransfer` at line 466. |
| VP-02 | Cross-Function Reentrancy | **SAFE** | All state modifications complete before the single external call in `claim()`. |
| VP-03 | Read-Only Reentrancy | **N/A** | View functions are not relied upon during state-changing operations. |
| VP-04 | Cross-Contract Reentrancy | **SAFE** | Only external call is `OMNI_COIN.safeTransfer()` to a trusted ERC20. No callback hooks. |
| VP-05 | ERC777 Callback Reentrancy | **N/A** | OmniCoin is ERC20, not ERC777. No transfer hooks. |
| VP-06 | Missing Access Control | **SAFE** | `onlyOwner` on `initialize()`, `addLegacyUsers()`, `finalizeMigration()`, `updateValidatorSet()`, `pause()`, `unpause()`. Multi-sig proofs required for `claim()`. |
| VP-07 | tx.origin Usage | **N/A** | Not used anywhere. |
| VP-08 | Unsafe delegatecall | **N/A** | Not used. |
| VP-09 | Unprotected Critical Function | **SAFE** | All state-changing functions have appropriate modifiers. |
| VP-10 | Unprotected Initializer | **SAFE** | `onlyOwner` + `initialized` boolean flag prevents re-initialization. |
| VP-11 | Default Visibility | **SAFE** | All functions and state variables have explicit visibility. |
| VP-12 | Unchecked Overflow/Underflow | **SAFE** | Solidity 0.8.24 checked arithmetic. No `unchecked` blocks. `totalReserved - totalClaimed` in `finalizeMigration()` (line 495) and `getStats()` (line 639) is safe because `totalClaimed` can never exceed `totalReserved` (each claim only processes amounts previously added to `totalReserved`, and the one-time-claim guard prevents double-counting). |
| VP-13 | Division Before Multiply | **N/A** | Only division is in `getStats()` view function (line 641). |
| VP-14 | Unsafe Downcast | **N/A** | No type downcasts. |
| VP-15 | Rounding Exploitation | **N/A** | No share/price calculations. |
| VP-16 | Precision Loss | **N/A** | All amounts in Wei (18 decimals). No conversions. |
| VP-17 | Spot Price Manipulation | **N/A** | No price feeds. |
| VP-18 | Stale Oracle Data | **N/A** | No oracles. |
| VP-19 | Short TWAP Window | **N/A** | No TWAP. |
| VP-20 | Flash Loan Price Manipulation | **N/A** | No price dependencies. |
| VP-21 | Sandwich Attack | **N/A** | No swaps or price-dependent operations. |
| VP-22 | Zero Address Validation | **SAFE** | Checked in constructor (line 320), `_validateClaim()` (line 711), `finalizeMigration()` (line 484), `_validateValidatorSet()` (line 979). |
| VP-23 | Zero Amount Validation | **SAFE** | Checked in `_storeLegacyUser()` (line 914). |
| VP-24 | Array Length Mismatch | **SAFE** | Checked in `_validateBatchInputs()` (line 937). |
| VP-25 | msg.value in Loop | **N/A** | No payable functions. |
| VP-26 | Unchecked ERC20 Transfer | **SAFE** | Uses `SafeERC20.safeTransfer()` at lines 466 and 511. |
| VP-27 | Unchecked Low-Level Call | **N/A** | No low-level calls. |
| VP-28 | Unchecked Create/Create2 | **N/A** | No create operations. |
| VP-29 | Unbounded Loop DoS | **BOUNDED** | `_loadLegacyBatch()` iterates input array (bounded by calldata gas limits). `_verifyMultiSigProof()` iterates proofs (bounded by MAX_VALIDATORS=20). `_getValidatorIndex()` iterates validators (bounded by 20). `updateValidatorSet()` iterates old and new validators (each bounded by 20). |
| VP-30 | DoS via Revert in Loop | **SAFE** | Pull pattern: users initiate claims individually. |
| VP-31 | Selfdestruct/Force-Send ETH | **N/A** | No receive/fallback functions. No ETH accounting. Force-sent ETH would be locked but causes no accounting errors. |
| VP-32 | Gas Griefing via Return Data | **SAFE** | External call is `safeTransfer()` to a trusted ERC20 contract. |
| VP-33 | Unbounded Return Data Copy | **N/A** | No arbitrary external calls. |
| VP-34 | Front-Running | **LOW RISK** | Claim front-running wastes the original submitter's gas but tokens always go to the correct `ethAddress` (embedded in signed proof). No fund loss. |
| VP-35 | Timestamp Dependence | **SAFE** | `block.timestamp` used only for the 2-year migration deadline (line 488). A 730-day tolerance makes miner timestamp manipulation irrelevant. Appropriately marked with `solhint-disable-line not-rely-on-time`. |
| VP-36 | Signature Replay (Same Chain) | **SAFE** | Per-user nonce `claimNonces[ethAddress]` consumed after each claim (line 463). One-time-claim guard via `claimedBy[usernameHash]` (line 718). |
| VP-37 | Cross-Chain Signature Replay | **SAFE** | `block.chainid` included in signed message (line 760). |
| VP-38 | Hash Collision (abi.encodePacked) | **SAFE** | Uses `abi.encode` (line 755), not `abi.encodePacked`. Prevents collision between different-length string inputs. |
| VP-39 | Storage Collision (Proxy) | **N/A** | Not upgradeable. |
| VP-40 | Weak Randomness | **N/A** | No randomness used. |
| VP-41 | Missing Event Emission | **SAFE** | All state changes emit events: `BalanceClaimed` (line 468), `MigrationFinalized` (line 514), `ValidatorSetUpdated` (line 333, 548), `LegacyInitialized` (line 373), `LegacyUsersAdded` (line 405). |
| VP-42 | Uninitialized Implementation | **N/A** | Not upgradeable. |
| VP-43 | Storage Layout Mismatch | **N/A** | Not upgradeable. |
| VP-44 | Reinitializer Gap | **N/A** | Not upgradeable. |
| VP-45 | Function Selector Clash | **N/A** | Not a proxy. |
| VP-46 | Fee-on-Transfer Token | **N/A** | OmniCoin is a standard ERC20 without transfer fees. Contract transfers from self to user. |
| VP-47 | Rebasing Token Interaction | **N/A** | OmniCoin is not rebasing. |
| VP-48 | Missing Return Bool on ERC20 | **SAFE** | Uses `SafeERC20` which handles non-standard ERC20 return values. |
| VP-49 | Approval Race Condition | **N/A** | No approval operations. |
| VP-50 | ERC777 Operator Hooks | **N/A** | OmniCoin is ERC20. |
| VP-51 | Self-Transfer | **N/A** | Transfers to user address, not to self. |
| VP-52 | Flash Loan Governance Attack | **N/A** | No governance voting. |
| VP-53 | Collateral Manipulation | **N/A** | No collateral system. |
| VP-54 | Missing Flash Loan Initiator Check | **N/A** | No flash loan callbacks. |
| VP-55 | Missing Slippage Protection | **N/A** | No swaps. |
| VP-56 | ERC4626 Share Inflation | **N/A** | No vault/share mechanics. |
| VP-57 | recoverERC20 Backdoor | **N/A** | No token recovery function. Excess tokens locked by design (prevents owner drain). See I-02 for post-finalization sweep recommendation. |
| VP-58 | Transient Storage Misuse | **N/A** | No transient storage. |

---

## Reentrancy Analysis (Deep Dive)

The `claim()` function is the only state-changing function that makes an external call. Analysis:

**State Updates Before External Call (CEI Pattern, lines 458-466):**
```solidity
// Update state before external call (CEI pattern)
claimedBy[usernameHash] = ethAddress;     // line 458 - marks claim as taken
legacyBalances[usernameHash] = 0;          // line 459 - zeros balance (gas refund)
totalClaimed += amount;                     // line 460
totalDistributed = newTotalDistributed;     // line 461
++uniqueClaimants;                          // line 462
++claimNonces[ethAddress];                  // line 463

// External call AFTER all state updates
OMNI_COIN.safeTransfer(ethAddress, amount); // line 466
```

Even if OmniCoin were replaced with a token that has transfer hooks (it is not), reentrancy is blocked by:
1. **CEI pattern:** All state updates complete before the external call.
2. **`nonReentrant` modifier:** OpenZeppelin ReentrancyGuard on `claim()`.
3. **One-time-claim guard:** `claimedBy[usernameHash]` is set before the external call. A reentrant call would fail at `_validateClaim()` line 715 (`legacyBalances[usernameHash] == 0` after line 459 zeroes it) or line 718 (`claimedBy[usernameHash] != address(0)` after line 458 sets it).

**Verdict:** Triple-layered reentrancy protection. No vulnerability.

---

## Access Control Map

| Role | Functions | Risk Level | Privilege Description |
|------|-----------|------------|----------------------|
| `owner` (Ownable) | `initialize()`, `addLegacyUsers()`, `finalizeMigration()`, `updateValidatorSet()`, `pause()`, `unpause()` | 6/10 | Can load balances (capped at MAX_MIGRATION_SUPPLY), rotate validators, pause/unpause claims, finalize after 2-year timelock. Cannot directly transfer tokens from the pool. |
| M-of-N validators | Authorize `claim()` via ECDSA signatures | 7/10 | Threshold compromise enables draining all unclaimed balances via fabricated claims. Each validator independently signs; compromise requires `requiredSignatures` distinct keys. |
| Public (any caller) | `claim()` (with valid proofs), all `view` functions | 2/10 | Claims require valid multi-sig proofs; tokens go to signed `ethAddress`. View functions are read-only. |
| Trusted Forwarder (ERC-2771, immutable) | `_msgSender()` override for `onlyOwner` functions | 5/10 | Can impersonate owner for all admin functions if forwarder contract is compromised. Set at deployment, immutable thereafter. Risk eliminated if `address(0)`. |

---

## Centralization Risk Assessment

**Single-Key Maximum Damage Scenarios:**

| Compromised Key | Impact | Severity | Mitigation |
|-----------------|--------|----------|------------|
| Owner key alone | Can rotate validators to attacker-controlled set, then fabricate claims to drain pool. Can pause claims (DoS). Can load inflated balances (capped by MAX_MIGRATION_SUPPLY). Cannot finalize before 2-year deadline. | 7/10 | Owner should be a multi-sig wallet or TimelockController. |
| Threshold validator keys (M keys simultaneously) | Can fabricate claims for all unclaimed balances, draining the pool. Cannot affect admin functions. | 8/10 | Distribute validator keys across independent infrastructure and jurisdictions. |
| Owner + threshold validators | Full control over migration funds. Can rotate validators and drain immediately. | 9/10 | Mitigated only by MAX_MIGRATION_SUPPLY cap. |
| Trusted forwarder contract | Equivalent to owner key compromise (can call all `onlyOwner` functions). | 6/10 | Deploy with `address(0)` or use a well-audited forwarder. |

**Production Recommendations:**
1. Owner MUST be a multi-sig wallet (e.g., Gnosis Safe) or OmniTimelockController.
2. Validator set MUST be at least 3-of-5 (never 1-of-1 in production).
3. Trusted forwarder SHOULD be `address(0)` unless meta-transactions are required for admin operations.
4. Validator private keys SHOULD be stored in HSMs (Hardware Security Modules) on separate infrastructure.

---

## Edge Case Analysis

### 1. Multiple Claims to Same ETH Address

**Scenario:** Legacy users "alice" and "bob" both want to claim to address `0xA`.

**Behavior:** Claims must be submitted sequentially with incrementing nonces (0, 1, 2, ...). Out-of-order submission causes `InvalidProof` revert because pre-signed proofs include the nonce. This is documented at lines 113-120 and tested in the test suite.

**Risk:** Pre-signed proofs become invalid if claims are submitted out of order. Requires re-signing by validators.

**Recommendation:** Validator backend should coordinate nonce assignment when multiple claims target the same address. Alternatively, instruct users to claim to unique addresses and consolidate after.

### 2. Large Batch Initialization Gas Limits

**Scenario:** Loading all 4,735 legacy users in a single `initialize()` call.

**Behavior:** Could exceed block gas limits depending on the chain. The `addLegacyUsers()` function exists precisely for batch loading after initialization.

**Risk:** Deployment operational risk, not a contract bug.

**Recommendation:** Use the `populate-legacy-contract.ts` script which processes in batches of 100 users.

### 3. Contract Under-Funding

**Scenario:** Deployer transfers fewer tokens than `totalReserved`.

**Behavior:** Claims succeed until the token balance is exhausted. Subsequent claims revert via `SafeERC20` (insufficient balance). `finalizeMigration()` also reverts if unclaimed amount exceeds remaining balance.

**Risk:** Claims become impossible until the contract is topped up with additional tokens.

**Recommendation:** Add a `getFundingStatus()` view function (see I-02). Verify adequate funding before opening claims.

### 4. Migration Period Boundary

**Scenario:** A claim transaction is submitted just before the 2-year deadline, and the owner calls `finalizeMigration()` in the same block or immediately after.

**Behavior:** Both can succeed. `claim()` does not check the migration deadline -- it only checks `migrationFinalized`. `finalizeMigration()` checks `block.timestamp >= deadline`. If both transactions are in the same block, the claim executes first (if ordered first), then finalization succeeds. If finalization executes first, the claim reverts with `MigrationAlreadyFinalized`.

**Risk:** Race condition at deadline boundary. No fund loss -- worst case is a claim narrowly failing.

**Recommendation:** Acceptable behavior. Users should claim well before the deadline.

### 5. Empty String Username Hash Collision

**Scenario:** Two different empty-looking usernames (e.g., whitespace variants) that hash to different values.

**Behavior:** The contract checks `bytes(username).length == 0` (line 710, 913) which only catches truly empty strings. Whitespace-only usernames like `" "` would pass validation.

**Risk:** Extremely low. Legacy usernames presumably do not consist of only whitespace. The off-chain validator backend should enforce username format rules.

**Recommendation:** No contract change needed. Enforce username format validation in the off-chain validator.

### 6. Stale Script: `set-legacy-validator.ts`

**Scenario:** The script at `scripts/set-legacy-validator.ts` references a `validator()` getter and `setValidator()` function.

**Behavior:** These functions do not exist in the current `LegacyBalanceClaim.sol` contract. The script is stale and would fail at runtime.

**Risk:** No security risk. Operational confusion if someone tries to run the script.

**Recommendation:** Update or delete `scripts/set-legacy-validator.ts` to use `updateValidatorSet()` instead.

---

## Signature Verification Security (Deep Dive)

The multi-sig verification in `_verifyMultiSigProof()` (lines 740-798) is well-designed:

**Message Construction (lines 754-764):**
```solidity
bytes32 message = keccak256(
    abi.encode(
        username,       // Dynamic string - abi.encode prevents collision
        ethAddress,     // Claim recipient
        nonce,          // Per-user replay protection
        address(this),  // Cross-contract replay protection
        block.chainid   // Cross-chain replay protection
    )
);
bytes32 ethSignedMessage = MessageHashUtils.toEthSignedMessageHash(message);
```

**Security properties verified:**
- `abi.encode` (not `abi.encodePacked`): Prevents hash collision between different-length string inputs.
- `address(this)`: Prevents replay across different contract deployments.
- `block.chainid`: Prevents replay across chains (e.g., mainnet vs testnet).
- `nonce`: Prevents replay of the same claim on the same chain/contract.
- `toEthSignedMessageHash()`: Applies EIP-191 prefix (`\x19Ethereum Signed Message:\n32`), preventing raw hash confusion.
- `ECDSA.recover()`: OpenZeppelin 5.x implementation that reverts on invalid signatures and enforces canonical `s`-values (low-S), preventing signature malleability.

**Duplicate Detection (lines 768-790):**
```solidity
uint256 seenBitmap = 0;
// ...
uint256 idx = _getValidatorIndex(signer);
uint256 bit = 1 << idx;
if ((seenBitmap & bit) != 0) continue;  // Skip duplicate
seenBitmap |= bit;
```

Bitmap supports up to 256 validators (uint256), well above MAX_VALIDATORS (20). Duplicate signatures from the same validator are silently skipped and do not count toward the threshold.

**Non-validator rejection (line 778-779):**
```solidity
if (!isValidator[signer]) {
    revert InvalidSigner(signer);
}
```

Any proof that recovers to a non-validator address causes an immediate revert (not a skip). This is a strict security choice -- it prevents attackers from padding proofs with garbage signatures.

**Verdict:** The signature verification is cryptographically sound. No weaknesses identified.

---

## Test Coverage Assessment

The test suite at `test/LegacyBalanceClaim.test.js` (1,755 lines) provides comprehensive coverage:

| Category | Tests | Coverage Quality |
|----------|-------|-----------------|
| Constructor | 7 tests | Zero-address rejection, validator set validation, duplicates, event emission |
| initialize() | 9 tests | Happy path, double-init, access control, empty arrays, duplicates, supply cap |
| addLegacyUsers() | 6 tests | Cumulative totals, not-initialized guard, post-finalization guard, supply cap |
| claim() lifecycle | 11 tests | Happy path, events, state updates, nonce increment, double-claim, wrong nonce, post-finalization, empty username, zero address, unknown user, permissionless submission |
| Signature verification | 6 tests | M-of-N validation, >M signatures, insufficient signatures, non-validator, duplicates, wrong username/address/chainId/contract |
| finalizeMigration() | 6 tests | Happy path after 2 years, partial claims, all claimed, before deadline, double finalization, zero address, non-owner |
| updateValidatorSet() | 7 tests | Replacement, events, old validators rejected, new validators accepted, duplicates, zero address, threshold validation |
| pause/unpause | 4 tests | Blocked when paused, resumed after unpause, access control |
| View functions | 10 tests | getUnclaimedBalance, isReserved, getClaimed, getStats, getFinalizationDeadline, getValidators, getClaimNonce |
| Edge cases | 6 tests | Sequential nonces to same address, out-of-order nonces, independent addresses, 1-of-1 config, MAX_MIGRATION_SUPPLY enforcement, totalDistributed tracking, reserved persistence |
| Constants | 3 tests | MIGRATION_DURATION, MAX_MIGRATION_SUPPLY, MAX_VALIDATORS |

**Total:** 63+ test cases covering all public/external functions and major edge cases.

**Gaps identified:**
- No tests for ERC-2771 meta-transaction behavior (trusted forwarder flow).
- No tests for `updateValidatorSet()` after a claim has been made (verifying old proofs fail with new validators mid-migration).
- No fuzz testing for boundary values or randomized inputs.
- No gas profiling tests for large batch operations (e.g., 100+ users in `initialize()`).

**Verdict:** Test coverage is strong and addresses the Round 6 L-02 finding. The identified gaps are minor and do not represent security risks.

---

## Solhint Results

```
[solhint] Warning: Rule 'contract-name-camelcase' doesn't exist
[solhint] Warning: Rule 'event-name-camelcase' doesn't exist
```

Zero contract-level warnings or errors. The two warnings are from the solhint configuration referencing non-existent rules, not from the contract itself.

---

## Code Quality Assessment

| Category | Rating | Notes |
|----------|--------|-------|
| **NatSpec Documentation** | Excellent | Every function, event, error, state variable has complete NatSpec. Architecture and security rationale documented in contract header (lines 22-60). Prior audit findings documented inline (lines 113-120). |
| **Error Handling** | Excellent | 13 custom errors with descriptive parameters. No bare `require` or `revert` strings. Every failure mode has a specific error type. |
| **Access Control** | Strong | `onlyOwner` on all admin functions. M-of-N multi-sig on claims. `Pausable` emergency brake. `initialized` flag prevents re-initialization. |
| **Reentrancy Protection** | Excellent | Triple protection: CEI pattern + `nonReentrant` + one-time-claim guard. |
| **Input Validation** | Strong | Zero address, empty array, empty string, zero balance, length mismatch, duplicate username, duplicate validator all validated. |
| **Event Emission** | Good | All state changes emit events. Minor indexed string issue (I-03). |
| **Gas Optimization** | Good | `++i` prefix increment, `calldata` parameter types, balance zeroed for gas refund (SSTORE 0), bitmap for duplicate detection, immutable variables for OMNI_COIN and DEPLOYED_AT. |
| **Code Organization** | Excellent | Clear section headers with unicode separators. Logical ordering: constants, immutables, state, events, errors, constructor, external, view, internal, overrides, private. |
| **Testing** | Good | 63+ tests with comprehensive coverage. Minor gaps in ERC-2771 and fuzz testing. |
| **Solhint Compliance** | Clean | Zero warnings or errors from the contract. |

---

## Conclusion

LegacyBalanceClaim.sol is a well-engineered migration contract that has been progressively hardened across four audit rounds. All Critical and High findings from prior rounds are fully remediated. The Round 6 M-01 finding (nonce per-address) has been addressed through NatSpec documentation. The test suite requested in Round 6 L-02 has been implemented with 63+ test cases.

**Remaining findings are low severity:**

1. **L-01:** `claim()` does not use `_msgSender()`, making ERC-2771 integration inert for claims. Deploy with `trustedForwarder_ = address(0)` if meta-transactions are not needed.
2. **L-02:** Owner can downgrade validator set to 1-of-1. Consider enforcing a minimum threshold constant.
3. **I-01:** Nonce per-address design documented but requires operational awareness.
4. **I-02:** Accounting vs actual balance mismatch possible; add `getFundingStatus()` view.
5. **I-03:** Indexed string stores hash in event topic; accepted design trade-off.

**Operational note:** The script `scripts/set-legacy-validator.ts` references functions (`validator()`, `setValidator()`) that do not exist in the current contract. Update or remove this script before deployment.

**Overall Risk Rating: LOW.** The contract is suitable for production deployment. The security architecture provides defense-in-depth through M-of-N multi-sig, per-user nonces, chain/contract domain separation, EIP-191 signing, supply cap enforcement, 2-year finalization timelock, emergency pause, CEI pattern, and reentrancy guards.

---
*Generated by Claude Code Audit Agent (Opus 4.6)*
*Round 7 pre-mainnet audit (prior: Round 1 on 2026-02-21, Round 3 on 2026-02-26, Round 6 on 2026-03-10)*
*Reference data: 58 vulnerability patterns, Cyfrin checklist, DeFiHackLabs incident database, Solodit findings*
