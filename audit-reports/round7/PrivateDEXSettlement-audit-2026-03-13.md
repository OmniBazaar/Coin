# Security Audit Report: PrivateDEXSettlement (Round 7)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/privacy/PrivateDEXSettlement.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 1,130
**Upgradeable:** Yes (UUPS with two-step ossification, 7-day delay)
**Handles Funds:** Indirectly (tracks encrypted collateral and fee amounts; actual pXOM transfers handled off-chain by COTI bridge)
**OpenZeppelin Version:** 5.x (upgradeable contracts)
**Dependencies:** `MpcCore` (COTI V2 MPC garbled circuits), OZ `AccessControlUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `UUPSUpgradeable`, `ERC2771ContextUpgradeable`, `ECDSA`, `MessageHashUtils`
**Prior Audits:** Round 3 (2026-02-26), Round 6 (2026-03-10)

---

## Executive Summary

PrivateDEXSettlement is a UUPS-upgradeable privacy-preserving bilateral settlement contract for intent-based trading using COTI V2 MPC garbled circuits. Settlers (validators with `SETTLER_ROLE`) lock encrypted collateral on behalf of traders (who must provide an EIP-191 signature proving consent), execute settlements via MPC sufficiency verification, compute encrypted 70/20/10 fee splits entirely within MPC, and allow fee recipients to claim accumulated encrypted balances. The contract does NOT hold or transfer tokens directly -- it is an encrypted accounting layer whose state is consumed by the off-chain COTI bridge for actual pXOM disbursement.

This Round 7 audit finds the contract in mature condition. All Critical and High findings from prior rounds have been remediated. The one architectural High (phantom collateral / no on-chain token escrow) remains acknowledged as inherent to the privacy settlement design. Solhint reports zero errors and one gas optimization warning (non-indexed event parameter).

**Key new findings in Round 7:**

1. **M-01 (NEW):** Fee distribution split (70% ODDAO / 20% Staking Pool / 10% Protocol) diverges from the project-level specification for DEX trading fees (70% LP Pool / 20% ODDAO / 10% Protocol Treasury), and from the non-private DEXSettlement contract (70% LP / 30% UnifiedFeeVault).
2. **M-02 (Carried):** Solver has no on-chain consent mechanism -- settler designates solver unilaterally at settlement time.
3. **L-01 (NEW):** Trader signature commitment hash does not include `block.chainid`, leaving a theoretical cross-chain replay vector.
4. **L-02 (Carried):** Expired intents remain in LOCKED status permanently with no cleanup mechanism.
5. **L-03 (NEW):** `updateFeeRecipients` lacks `nonReentrant` guard while performing MPC precompile calls.

### Round 7 Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 5 |
| **Total** | **10** |

### Solhint Results

```
contracts/privacy/PrivateDEXSettlement.sol
  306:5  warning  GC: [protocolTreasury] on Event [FeeRecipientsUpdated] could be Indexed  gas-indexed-events

0 errors, 1 warning
```

The single warning is a gas optimization suggestion: adding `indexed` to `protocolTreasury` in the `FeeRecipientsUpdated` event (line 306). The event already indexes two of three parameters (`oddao` and `stakingPool`), hitting the maximum useful indexing for most EVM log queries. Adding a third `indexed` parameter would save marginal gas on topic-filtered queries but consumes an additional topic slot. This is a stylistic choice with negligible impact.

---

## Prior Finding Remediation Status

### Round 3 Findings (2026-02-26)

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| C-01 | Critical | Unchecked MPC arithmetic -- silent overflow/underflow | **FIXED** -- All arithmetic uses `checkedMul`/`checkedAdd`/`checkedSub` (lines 606, 615, 623, 629, 631, 997) |
| C-02 | Critical | `claimFees()` ge(x,0) tautology -- zero-balance claims succeed | **FIXED** -- Uses `MpcCore.gt(gtBalance, gtZero)` (line 730). Same fix applied to `settlePrivateIntent()` collateral checks (lines 588, 592) |
| H-01 | High | `updateFeeRecipients()` orphans accumulated fees | **FIXED** -- `_migrateFees()` helper (lines 1010-1031) transfers encrypted balances from old to new addresses |
| H-02 | High | No actual token escrow -- phantom collateral | **ACCEPTED** -- COTI MPC architectural constraint; encrypted balance tracking is the only mechanism available in garbled circuits; scaling factor design mitigates overflow risk |
| H-03 | High | Settler has unilateral control (no trader consent) | **FIXED** -- EIP-191 trader signature required in `lockPrivateCollateral()` (lines 496-504). Signature covers `intentId`, `trader`, `tokenIn`, `tokenOut`, `traderNonce`, `deadline`, `address(this)` |
| M-01 | Medium | uint64 precision limit | **ACCEPTED** -- COTI MPC uint64 constraint is fundamental; NatSpec documents the ~18.4M XOM per-trade limitation |
| M-02 | Medium | cancelPrivateIntent allows immediate cancellation | **FIXED** -- `MIN_LOCK_DURATION = 5 minutes` enforced at line 694 |
| M-03 | Medium | Redundant emergency stop mechanism | **FIXED** -- Only OpenZeppelin Pausable remains; `claimFees()` intentionally lacks `whenNotPaused` (documented in NatSpec lines 710-718) |
| M-04 | Medium | No validation that tokenIn != tokenOut | **FIXED** -- `SameTokenSwap()` error at line 484 |
| M-05 | Medium | Settlement hash lacks nonce, deadline | **FIXED** -- Hash includes `col.nonce`, `col.deadline` (lines 652-664) |
| L-01 | Low | `getAccumulatedFees()` exposes encrypted balances publicly | **FIXED** -- Restricted to `caller == recipient` or admin (lines 948-953) |
| L-02 | Low | `FeesClaimed` event lacks amount | **FIXED** -- Event includes `bytes32 encryptedAmount` (line 741) |
| L-03 | Low | Storage gap documentation incomplete | **FIXED** -- Comprehensive gap calculation (lines 237-253): 6 named sequential variables, gap = 50 - 6 = 44 |
| L-04 | Low | Deadline validation edge case | **FIXED** -- Uses `deadline <= block.timestamp` (line 486) |

### Round 6 Findings (2026-03-10)

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| H-01 | High | Phantom collateral -- no on-chain token escrow | **ACKNOWLEDGED** -- Architectural constraint; mitigated by trader signature + validator consensus + bridge verification |
| M-01 | Medium | `msg.sender` used instead of `_msgSender()` in `settleBatch()` | **FIXED** -- `settleBatch()` and `disputeSettlement()` appear to have been removed from the contract; all remaining functions use `_msgSender()` correctly |
| M-02 | Medium | Settler controls solver address -- no solver consent | **OPEN** -- Carried to Round 7 as M-02 (see below) |
| M-03 | Medium | `claimFees()` does not have `whenNotPaused` | **ACCEPTED** -- Intentional design; NatSpec at lines 710-718 documents the rationale explicitly |
| L-01 | Low | `cancelPrivateIntent()` does not check deadline expiry | **OPEN** -- Carried to Round 7 as L-02 (no `expireIntent` function added) |
| L-02 | Low | Nonce consumption during `lockPrivateCollateral()` can block legitimate settlements | **ACCEPTED** -- Standard nonce pattern; nonce only consumed after signature verification passes |
| L-03 | Low | ERC-2771 trusted forwarder immutable | **ACCEPTED** -- Standard ERC-2771 pattern; rotation requires implementation upgrade |
| I-01 | Info | `SCALING_FACTOR` defined but not used in logic | **ACCEPTED** -- Serves as off-chain reference; NatSpec documents this |
| I-02 | Info | Trading fee (0.2%) hardcoded as constant | **ACCEPTED** -- Change requires implementation upgrade (before ossification) |
| I-03 | Info | Storage gap calculation accurate | **CONFIRMED** -- Still accurate in Round 7 (recalculated below) |

---

## Round 7 Findings

### [M-01] Fee Distribution Split Diverges from Project Specification and Non-Private DEXSettlement (NEW)

**Severity:** Medium
**Lines:** 180-187 (constants), 147-149 (NatSpec), 611-645 (fee calculation)

**Description:**

The PrivateDEXSettlement contract implements the following fee split for DEX trading fees:

```solidity
uint64 public constant ODDAO_SHARE_BPS = 7000;          // 70% -> ODDAO
uint64 public constant STAKING_POOL_SHARE_BPS = 2000;    // 20% -> Staking Pool
uint64 public constant PROTOCOL_SHARE_BPS = 1000;        // 10% -> Protocol Treasury
```

This diverges from two authoritative sources:

1. **Project specification (CLAUDE.md, "DEX Trading Fees" section):**
   ```
   70% -> LP Pool (liquidity providers)
   20% -> ODDAO Treasury
   10% -> Protocol Treasury
   ```

2. **Non-private DEXSettlement contract (`contracts/dex/DEXSettlement.sol`):**
   ```
   70% -> Liquidity Pool (LP_SHARE = 7000)
   30% -> UnifiedFeeVault (which internally splits 70/20/10 = 21% ODDAO, 6% Staking, 3% Protocol)
   ```

The private version sends 70% to ODDAO instead of LP Pool, and 20% to Staking Pool instead of ODDAO. The fee recipients struct at line 163 names the 70% recipient "oddao" rather than "liquidityPool", reinforcing this divergence.

**Impact:** If this is unintentional, privacy-trade fee revenue bypasses LP providers entirely, undermining liquidity incentives for private trading. If this is intentional (e.g., because private trades use a different liquidity mechanism), it should be documented as a deliberate design decision.

**Recommendation:**
1. Clarify whether the fee split for privacy settlements is intentionally different from standard DEX settlements.
2. If it should match, update the constants and the `FeeRecipients` struct to include `liquidityPool` as the 70% recipient.
3. If intentionally different, add a NatSpec comment explaining why privacy settlements use a different fee distribution.

---

### [M-02] Settler Controls Solver Address at Settlement Time -- No Solver Consent (Carried from Round 6)

**Severity:** Medium
**Lines:** 555-557, 577

**Description:**

In `settlePrivateIntent()`, the `solver` address is provided by the settler (validator) at settlement time. The solver:
1. Does not sign or approve the settlement on-chain.
2. Is not known during collateral locking (set to `address(0)` at line 511).
3. Has no on-chain mechanism to reject being designated as a solver.

The trader now provides consent via EIP-191 signature (Round 3 H-03 fix), but the solver has no equivalent consent mechanism. A rogue settler could designate any address as the solver, and the `PrivateIntentSettled` event (line 667) would attribute the settlement to that address.

**Mitigating factors:**
- The off-chain COTI bridge should independently verify solver consent before disbursing tokens.
- In the intent-based model, solvers actively submit quotes off-chain and validators only submit settlements for solvers who accepted via the P2P gossip layer.
- The NatSpec at lines 543-550 explicitly documents this design decision.

**Impact:** A rogue settler could attribute settlements to arbitrary solver addresses, potentially affecting their off-chain state or bridge interactions. However, no on-chain fund movement occurs -- the bridge must verify independently.

**Recommendation:** Document in the bridge integration specification that solver consent must be verified off-chain before processing any settlement event. Consider adding an optional solver signature for high-value settlements (the NatSpec at lines 543-550 already discusses this trade-off).

---

### [L-01] Trader Signature Commitment Hash Does Not Include `block.chainid` (NEW -- Recommended in Round 6)

**Severity:** Low
**Lines:** 1057-1067

**Description:**

The trader's EIP-191 signature covers:
```solidity
bytes32 commitment = keccak256(
    abi.encode(
        intentId, trader, tokenIn, tokenOut,
        traderNonce, deadline, address(this)
    )
);
```

The `address(this)` inclusion prevents cross-contract replay on the same chain. However, `block.chainid` is not included. If the same contract is deployed at the same proxy address on multiple chains (technically possible with CREATE2 + deterministic proxy deployment), a trader's signature could be replayed cross-chain.

**Mitigating factors:**
- Same-address deployment on multiple chains requires identical deployer nonce or CREATE2 salt, which is unlikely in practice.
- The proxy pattern makes exact address matching even harder (proxy address depends on factory address and salt).
- Nonces are per-chain, so a replayed signature would need the trader's nonce to match on the other chain.

**Impact:** Very low probability, but the fix is trivial (add `block.chainid` to the `abi.encode`).

**Recommendation:** Add `block.chainid` to the commitment hash:
```solidity
bytes32 commitment = keccak256(
    abi.encode(
        intentId, trader, tokenIn, tokenOut,
        traderNonce, deadline, address(this),
        block.chainid
    )
);
```
This also requires updating the off-chain signature generation to include the chain ID.

---

### [L-02] Expired Intents Remain in LOCKED Status Permanently -- No Cleanup Mechanism (Carried from Round 6)

**Severity:** Low
**Lines:** 680-701

**Description:**

`cancelPrivateIntent()` allows only the trader to cancel. If:
1. The trader loses their key or becomes inactive, and
2. The deadline has passed (so settlement is impossible),

the intent remains in `LOCKED` status permanently. No one else can transition it to `CANCELLED`.

**Impact:** Expired intents accumulate in storage. No funds are at risk (the contract holds no tokens), but the state becomes cluttered with uncancellable, unsettleable records. Off-chain indexers must filter these out.

**Recommendation:** Add an `expireIntent()` function callable by anyone (or `SETTLER_ROLE`) for intents past their deadline:
```solidity
function expireIntent(bytes32 intentId) external {
    PrivateCollateral storage col = privateCollateral[intentId];
    if (col.status != SettlementStatus.LOCKED) revert CollateralNotLocked();
    if (block.timestamp <= col.deadline) revert DeadlineNotExpired();
    col.status = SettlementStatus.CANCELLED;
    emit PrivateIntentCancelled(intentId, col.trader);
}
```

---

### [L-03] `updateFeeRecipients` Lacks `nonReentrant` Guard While Performing MPC Precompile Calls (NEW)

**Severity:** Low
**Lines:** 759-784

**Description:**

The `updateFeeRecipients()` function calls `_migrateFees()` three times, each of which performs MPC precompile calls (`onBoard`, `checkedAdd`, `offBoard`, `setPublic64`). While standard MPC precompiles do not have callback mechanisms, the function lacks `nonReentrant` protection.

If a future MPC precompile upgrade introduces callback capability, or if the contract is deployed on a chain with non-standard precompile behavior, this could create a reentrancy vector where a mid-migration callback could exploit partially-updated fee recipient state.

**Mitigating factors:**
- COTI MPC precompiles are system-level contracts that do not perform external calls or callbacks.
- The function is restricted to `DEFAULT_ADMIN_ROLE`, limiting the attack surface.
- The `_migrateFees` function is deterministic and idempotent for same-address pairs (early return if `oldAddr == newAddr`).

**Impact:** No practical risk with current MPC precompile implementation. This is a defense-in-depth recommendation.

**Recommendation:** Add `nonReentrant` modifier to `updateFeeRecipients()` for defense in depth:
```solidity
function updateFeeRecipients(
    address oddao,
    address stakingPool,
    address protocolTreasury
) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
```

---

### [I-01] `SCALING_FACTOR` Constant Defined but Never Referenced in On-Chain Logic (Carried)

**Severity:** Informational
**Lines:** 205

**Description:**

```solidity
uint256 public constant SCALING_FACTOR = 1e12;
```

This constant is defined for documentation and off-chain integrator reference. It is never referenced in any on-chain function. Since amounts are encrypted before submission, the contract cannot validate scaling at runtime.

The NatSpec at lines 202-204 documents this correctly:
```
/// @notice Scaling factor from 18-decimal to 6-decimal precision
/// @dev Amounts MUST be divided by this factor before encryption.
```

**Status:** Acceptable. No change needed.

---

### [I-02] Trading Fee (0.2%) Is Hardcoded -- Requires Implementation Upgrade to Change (Carried)

**Severity:** Informational
**Lines:** 190

**Description:**

`TRADING_FEE_BPS = 20` (0.2%) is a compile-time constant. The project specification states DEX trading fees are "TBD (to be discussed)." Changing the fee requires deploying a new implementation and upgrading the proxy (only possible before ossification).

**Impact:** After ossification, the trading fee is permanently fixed at 0.2%.

**Recommendation:** If fee flexibility is desired long-term, convert `TRADING_FEE_BPS` to a state variable with an admin setter (bounded by a constant maximum) before ossifying the contract.

---

### [I-03] Storage Gap Calculation Verified Correct (Positive Finding)

**Severity:** Informational
**Lines:** 237-253

**Description:**

The storage gap calculation is accurate and well-documented:

| Variable | Type | Slots |
|----------|------|-------|
| `feeRecipients` | FeeRecipients (3 addresses) | 3 |
| `totalSettlements` | uint256 | 1 |
| `_ossified` | bool | 1 |
| `ossificationRequestTime` | uint256 | 1 |
| **Total sequential slots** | | **6** |
| **Gap** | uint256[44] | **44** |
| **Total reserved** | | **50** |

Mappings (`privateCollateral`, `feeRecords`, `accumulatedFees`, `nonces`) are correctly excluded from sequential slot count per OpenZeppelin convention (they use keccak256-derived slots).

**Verification:** 50 - 6 = 44. Correct.

---

### [I-04] Ossification Request Can Be Silently Reset (Informational)

**Severity:** Informational
**Lines:** 849-860

**Description:**

`requestOssification()` unconditionally sets `ossificationRequestTime = block.timestamp`. If called when an ossification request is already pending, it resets the 7-day timer without any event indicating the reset. This serves as an implicit "cancel and re-request" mechanism.

**Behavior:**
1. Admin calls `requestOssification()` -- timer starts.
2. Admin calls `requestOssification()` again 3 days later -- timer silently resets; the previous 3 days are lost.
3. `confirmOssification()` requires a full 7 days from the latest request.

**Impact:** No security risk. The admin can delay ossification indefinitely by repeatedly re-requesting. This is acceptable since the admin could also simply never call `confirmOssification()`.

**Recommendation:** Consider emitting a separate event (e.g., `OssificationReset`) when `ossificationRequestTime` is non-zero and being overwritten, to improve governance transparency. Alternatively, revert if an ossification request is already pending and require an explicit cancel first.

---

### [I-05] Convenience Role Management Functions Duplicate OpenZeppelin Inherited API (Informational)

**Severity:** Informational
**Lines:** 790-805

**Description:**

`grantSettlerRole()` and `revokeSettlerRole()` are thin wrappers around OpenZeppelin's `_grantRole()` and `_revokeRole()`. The inherited `grantRole(bytes32 role, address account)` and `revokeRole(bytes32 role, address account)` functions from `AccessControlUpgradeable` already provide the same functionality for any role.

The wrappers add value by:
1. Providing a zero-address check on `grantSettlerRole()` (line 793).
2. Making the API more discoverable for settler-specific management.

However, an admin can still bypass these wrappers by calling `grantRole(SETTLER_ROLE, address(0))` directly (though `_grantRole` in OZ v5 emits the event regardless). The zero-address check in `grantSettlerRole` prevents this only when using the wrapper.

**Impact:** Negligible. The wrappers are a valid API improvement. The zero-address bypass via inherited `grantRole` is unlikely in practice (admin would need to deliberately use the wrong function).

**Recommendation:** No change needed. If strict zero-address prevention is desired for SETTLER_ROLE, override the `_grantRole` function to add the check there. However, the `setSettlerRoleAdmin()` function (line 815-819) properly enables delegating SETTLER_ROLE management to a different admin role (e.g., ValidatorProvisioner), which mitigates the bypass.

---

## Architecture Analysis

### Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `updateFeeRecipients()`, `grantSettlerRole()`, `revokeSettlerRole()`, `setSettlerRoleAdmin()`, `pause()`, `unpause()`, `requestOssification()`, `confirmOssification()`, `_authorizeUpgrade()`, inherited `grantRole()`/`revokeRole()` | 7/10 |
| `SETTLER_ROLE` | `lockPrivateCollateral()`, `settlePrivateIntent()` | 6/10 (requires trader EIP-191 signature for locking) |
| Any address (self-restricted) | `cancelPrivateIntent()` (trader only, after MIN_LOCK_DURATION), `claimFees()` (own balance only), `getAccumulatedFees()` (own balance or admin) | 2/10 |
| Any address (unrestricted) | `getPrivateCollateral()`, `getFeeRecord()`, `getFeeRecipients()`, `getNonce()`, `isOssified()` | 1/10 |

### Role Assignment Chain

```
DEFAULT_ADMIN_ROLE (set in initialize)
  |-- grants/revokes SETTLER_ROLE (via grantSettlerRole/revokeSettlerRole)
  |-- can delegate SETTLER_ROLE admin (via setSettlerRoleAdmin)
  |-- controls pause/unpause
  |-- controls fee recipients
  |-- controls upgrades (until ossification)
  \-- controls ossification (irreversible)
```

### Modifier Coverage

| Function | Role Check | Pause Check | Reentrancy Guard |
|----------|-----------|-------------|-----------------|
| `lockPrivateCollateral` | SETTLER_ROLE | whenNotPaused | nonReentrant |
| `settlePrivateIntent` | SETTLER_ROLE | whenNotPaused | nonReentrant |
| `cancelPrivateIntent` | self (trader) | whenNotPaused | nonReentrant |
| `claimFees` | self (balance holder) | **NONE** (intentional) | nonReentrant |
| `updateFeeRecipients` | DEFAULT_ADMIN_ROLE | **NONE** | **NONE** (L-03) |
| `grantSettlerRole` | DEFAULT_ADMIN_ROLE | -- | -- |
| `revokeSettlerRole` | DEFAULT_ADMIN_ROLE | -- | -- |
| `setSettlerRoleAdmin` | DEFAULT_ADMIN_ROLE | -- | -- |
| `pause` | DEFAULT_ADMIN_ROLE | -- | -- |
| `unpause` | DEFAULT_ADMIN_ROLE | -- | -- |
| `requestOssification` | DEFAULT_ADMIN_ROLE | -- | -- |
| `confirmOssification` | DEFAULT_ADMIN_ROLE | -- | -- |

### MPC Operation Safety Audit

All MPC operations verified against COTI V2 MpcCore.sol library:

| Operation | Line(s) | Purpose | Safety |
|-----------|---------|---------|--------|
| `onBoard(ctUint64)` | 581, 582, 725, 992-993, 1017, 1020 | Convert ciphertext to computation type | No arithmetic risk |
| `offBoard(gtUint64)` | 635, 636, 637, 736, 998, 1026, 1030 | Convert computation type to ciphertext | No arithmetic risk |
| `setPublic64(uint64)` | 586, 602, 604, 613, 620, 729, 1029 | Convert plaintext to computation type | No arithmetic risk |
| `gt(gtUint64, gtUint64)` | 587, 592, 730 | Encrypted comparison | Reveals boolean only |
| `decrypt(gtBool)` | 588, 593, 731 | Decrypt boolean result | Reveals boolean only; access-controlled context |
| `checkedMul(gtUint64, gtUint64)` | 606, 615, 623 | Overflow-safe multiplication | Reverts on overflow |
| `checkedAdd(gtUint64, gtUint64)` | 629, 997, 1025 | Overflow-safe addition | Reverts on overflow |
| `checkedSub(gtUint64, gtUint64)` | 631 | Underflow-safe subtraction | Reverts on underflow |
| `div(gtUint64, gtUint64)` | 608, 617, 625 | Encrypted division | No overflow risk; division by zero behavior depends on MPC precompile |

**Division by zero analysis:** The divisor in all three `div` calls is `gtBasis = MpcCore.setPublic64(BASIS_POINTS_DIVISOR)` where `BASIS_POINTS_DIVISOR = 10000`. This is a non-zero constant, so division by zero cannot occur.

### Fee Calculation Correctness

```
totalFee    = (traderAmount * 20)   / 10000    // 0.2% trading fee
oddaoFee    = (totalFee * 7000)     / 10000    // 70% of fee
stakingFee  = (totalFee * 2000)     / 10000    // 20% of fee
protocolFee = totalFee - (oddaoFee + stakingFee)  // 10% remainder
```

**Invariant verification (plaintext examples):**

| Trade Amount | Total Fee | ODDAO (70%) | Staking (20%) | Protocol (10%) | Sum | Matches? |
|-------------|-----------|-------------|---------------|----------------|-----|----------|
| 1,000,000 | 2,000 | 1,400 | 400 | 200 | 2,000 | Yes |
| 500,000 | 100 | 70 | 20 | 10 | 100 | Yes |
| 1 | 0 | 0 | 0 | 0 | 0 | Yes (dust) |
| 3 | 0 | 0 | 0 | 0 | 0 | Yes (dust) |
| 50,000 | 100 | 70 | 20 | 10 | 100 | Yes |
| 7 | 0 | 0 | 0 | 0 | 0 | Yes (dust) |
| 500 | 1 | 0 | 0 | 1 | 1 | Yes (remainder to protocol) |

**Rounding analysis:** Integer division truncates, so `oddaoFee + stakingFee <= totalFee` always holds. The protocol treasury receives the rounding remainder (at most 2 micro-XOM per settlement). This is the correct "remainder goes to last recipient" pattern, preventing fee leakage.

**Overflow analysis at maximum uint64:**
- Maximum `traderAmount` (uint64): 18,446,744,073,709,551,615 (~1.84e19)
- `traderAmount * TRADING_FEE_BPS (20)`: ~3.69e20 -- EXCEEDS uint64 max
- `checkedMul` correctly reverts, providing fail-closed behavior
- At 6-decimal scaling (amounts divided by 1e12 before encryption), max practical amount = ~18.4M XOM, fee product = 18.4e6 * 1e6 * 20 = 3.68e14, well within uint64 range

### Privacy Analysis

**Encrypted (private) data:**
- Trader collateral amount, solver collateral amount
- Individual fee amounts (ODDAO, staking pool, protocol shares)
- Accumulated fee balances per recipient
- Claimed fee amounts (emitted as encrypted `bytes32` in events)

**Public (leaked) data:**
- Trader address, solver address, token pair (tokenIn/tokenOut)
- Intent IDs, trader nonces, deadlines, lock timestamps
- Settlement status transitions (EMPTY -> LOCKED -> SETTLED/CANCELLED)
- Settlement count (`totalSettlements`), settlement hashes
- Fee recipient addresses

**Deanonymization vectors (unchanged from Round 6):**
1. Event correlation: `PrivateCollateralLocked` and `PrivateIntentSettled` share `intentId`, linking lock/settle operations.
2. Timing analysis: `lockTimestamp` and settlement `block.timestamp` reveal lock-to-settle duration.
3. Nonce analysis: Monotonically increasing nonce per trader reveals total settlement count.
4. Token pair analysis: Public `tokenIn`/`tokenOut` reveals what assets are being swapped.
5. Fee claim frequency: `FeesClaimed` events reveal validator activity levels.

### ERC-2771 Integration Verification

The `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` overrides at lines 1087-1129 correctly resolve the diamond inheritance between `ContextUpgradeable` (inherited by AccessControl and Pausable) and `ERC2771ContextUpgradeable`. All three overrides delegate to `ERC2771ContextUpgradeable`, which is the correct resolution.

Functions using `_msgSender()`:
- `cancelPrivateIntent()` (line 683) -- correctly uses meta-tx sender
- `claimFees()` (line 721) -- correctly uses meta-tx sender
- `getAccumulatedFees()` (line 947) -- correctly uses meta-tx sender

Functions using `onlyRole()` (which internally calls `_msgSender()` via `_checkRole()`):
- All admin and settler functions -- correctly use meta-tx sender

### Upgrade Safety Verification

1. **Initializer protection:** Constructor calls `_disableInitializers()` (line 399), preventing direct initialization of the implementation contract.
2. **UUPS authorization:** `_authorizeUpgrade()` (lines 970-974) requires `DEFAULT_ADMIN_ROLE` and checks `_ossified`.
3. **Storage layout:** All new state variables added in future implementations must be placed before the `__gap` array, with the gap size reduced accordingly.
4. **Trusted forwarder:** Stored as immutable in implementation bytecode (safe for proxies because immutables live in the implementation contract's bytecode, not in proxy storage).
5. **Inheritance linearization:** `Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, ERC2771ContextUpgradeable` -- correct order for OpenZeppelin v5.

### Economic Invariants

1. **Fee conservation:** `oddaoFee + stakingFee + protocolFee == totalFee` -- enforced by using subtraction for the final component (`protocolFee = totalFee - oddaoFee - stakingFee`). The `checkedSub` ensures this never underflows.

2. **Nonce monotonicity:** `nonces[trader]` is only incremented (line 507) and never decremented. Each nonce value is consumed exactly once.

3. **Status finality:** Once `status == SETTLED` or `status == CANCELLED`, no function can transition the intent back to `LOCKED` or `EMPTY`. The status transitions are:
   - EMPTY -> LOCKED (via `lockPrivateCollateral`)
   - LOCKED -> SETTLED (via `settlePrivateIntent`)
   - LOCKED -> CANCELLED (via `cancelPrivateIntent`)

4. **Fee accumulation monotonicity:** Accumulated fees per recipient only increase (via `_accumulateFee` using `checkedAdd`). They reset to zero only via `claimFees()` (by the recipient themselves) or `_migrateFees()` (by admin, which transfers the balance rather than destroying it).

5. **Settlement count monotonicity:** `totalSettlements` is only incremented (line 649) and never decremented.

---

## Centralization Risk Assessment

**Single-key maximum damage (DEFAULT_ADMIN_ROLE):**
- Halt all settlements (pause)
- Redirect future fee revenue (with migration protecting accumulated balances)
- Grant SETTLER_ROLE to attacker-controlled addresses
- Upgrade to malicious implementation (before ossification)
- Permanently lock the contract (ossification)

**Single-key maximum damage (SETTLER_ROLE):**
- Create settlement records with trader consent (requires signature) but with potentially fabricated encrypted amounts
- Designate arbitrary solver addresses
- Generate settlement events that may trigger off-chain fund transfers via the bridge

**Centralization Risk Rating:** 6/10 (Moderate-High)

**Recommendations:**
1. Use a multi-sig wallet (e.g., Gnosis Safe) for `DEFAULT_ADMIN_ROLE`.
2. Deploy `ValidatorProvisioner` to manage `SETTLER_ROLE` programmatically via `setSettlerRoleAdmin()`.
3. The COTI bridge must independently verify encrypted amounts before disbursing tokens.

---

## Conclusion

The PrivateDEXSettlement contract is in mature, well-audited condition. All Critical and High findings from prior rounds have been fixed or acknowledged as architectural constraints. The contract demonstrates:

1. **Strong cryptographic controls:** EIP-191 trader signatures with nonce replay protection and contract-address binding.
2. **Safe MPC arithmetic:** All operations use checked variants that revert on overflow/underflow.
3. **Clean state machine:** Settlement status transitions are unidirectional and well-guarded.
4. **Fee continuity:** Fee migration during recipient changes prevents orphaning.
5. **Governance safety:** Two-step ossification with 7-day delay prevents accidental permanent lockout.

**Key remaining items for production readiness:**

| Priority | Item | Action |
|----------|------|--------|
| Medium | Fee split alignment (M-01) | Confirm whether 70% ODDAO vs 70% LP Pool is intentional for privacy settlements |
| Low | Chain ID in signature (L-01) | Add `block.chainid` to commitment hash |
| Low | Expired intent cleanup (L-02) | Add `expireIntent()` function |
| Low | Reentrancy on fee update (L-03) | Add `nonReentrant` to `updateFeeRecipients()` |
| Ops | Admin key management | Deploy with multi-sig admin |
| Ops | Bridge verification | Ensure COTI bridge independently validates settlement events |

**Overall Risk Rating:** Low (mature contract with well-documented constraints and minimal remaining attack surface).

---

*Generated by Claude Code Audit Agent (Opus 4.6) -- Round 7 Pre-Mainnet Security Audit*
*Methodology: Solhint static analysis, manual line-by-line review, prior audit remediation verification (Rounds 3 and 6), MPC operation safety audit against COTI V2 MpcCore.sol, fee calculation invariant verification, storage layout verification, access control mapping, privacy deanonymization assessment, ERC-2771 integration verification, cross-contract fee distribution consistency check*
