# Security Audit Report: OmniFeeRouter (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/dex/OmniFeeRouter.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 540
**Upgradeable:** No
**Handles Funds:** Yes (ERC-20 fee-collecting swap wrapper)
**Previous Audits:** Round 2 (2026-02-20), Round 6 (2026-03-10)
**Test Suite:** 74 tests, all passing (2s)
**Slither:** Skipped

---

## Executive Summary

OmniFeeRouter is a trustless fee-collecting wrapper for external DEX swaps
deployed per EVM chain. It pulls input tokens from the caller, deducts a capped
fee, forwards the remainder to an allowlisted external DEX router via low-level
call, and sweeps output tokens back to the caller.

**Round 6 remediation status:**

All three Medium findings from Round 6 have been properly remediated:

| Round 6 Finding | Status |
|-----------------|--------|
| M-01: Arbitrary calldata to unwhitelisted routers | **FIXED** -- Router allowlist (`allowedRouters` mapping) with `setRouterAllowed()` |
| M-02: Mutable fee collector without timelock | **FIXED** -- `proposeFeeCollector()` / `applyFeeCollector()` with 24-hour timelock |
| M-03: Fee rounding allows zero-fee swaps on dust | **FIXED** -- `MIN_SWAP_AMOUNT = 1e15` enforced in `_validateFee()` |

**Round 7 findings:**

This round identifies **zero Critical or High** issues. The contract has reached
production quality. The remaining findings are Medium, Low, and Informational
severity, focused on operational gaps in the timelock/allowlist mechanisms,
minor accounting concerns, and carried-over low-severity items from Round 6.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Findings Summary Table

| ID | Severity | Title | Location | Status |
|----|----------|-------|----------|--------|
| M-01 | Medium | Router allowlist changes have no timelock -- instant malicious router injection | `setRouterAllowed()` L334-342 | NEW |
| M-02 | Medium | No pause mechanism for emergency response | Entire contract | NEW |
| L-01 | Low | No cancellation function for pending fee collector proposals | `proposeFeeCollector()` / `applyFeeCollector()` L295-326 | NEW |
| L-02 | Low | `totalFeesCollected` mixes token units across different ERC-20 decimals | `swapWithFee()` L259 | NEW |
| L-03 | Low | `renounceOwnership()` reuses `InvalidFeeCollector` error (carried from R6) | `renounceOwnership()` L362-364 | CARRIED |
| I-01 | Info | `proposeFeeCollector` does not reject `feeCollector == address(this)` | `proposeFeeCollector()` L296-304 | NEW |
| I-02 | Info | Event does not include `minOutput` or `deadline` parameters (carried from R6) | `SwapExecuted` event L94-102 | CARRIED |
| I-03 | Info | ERC2771 trusted forwarder is immutable and cannot be rotated (carried from R6) | Constructor L193 | CARRIED |

---

## Round 6 Remediation Verification

### M-01 Fix: Router Allowlist

**Location:** Lines 67-70 (`allowedRouters` mapping), Lines 334-342
(`setRouterAllowed()`), Lines 497-500 (enforcement in `_validateRouter()`)

**Implementation:**
```solidity
mapping(address => bool) public allowedRouters;

function setRouterAllowed(address router, bool allowed) external onlyOwner {
    if (router == address(0)) revert InvalidRouterAddress();
    allowedRouters[router] = allowed;
    emit RouterAllowlistUpdated(router, allowed);
}
```

Enforcement in `_validateRouter()`:
```solidity
if (!allowedRouters[routerAddress]) {
    revert RouterNotAllowed();
}
```

**Verdict: FIXED.** The allowlist eliminates the residual arbitrary-calldata
attack surface from Round 6. Only owner-approved routers can be called. The
validation order is correct: address-based checks (zero, token, self, EOA)
run before the allowlist check, so invalid addresses are rejected early without
hitting the mapping SLOAD.

**Residual concern:** The allowlist itself has no timelock (see M-01 below).

---

### M-02 Fix: Fee Collector Timelock

**Location:** Lines 50-51 (`FEE_COLLECTOR_DELAY`), Lines 76-80 (pending state
variables), Lines 295-326 (`proposeFeeCollector()` / `applyFeeCollector()`)

**Implementation:**
```solidity
uint256 public constant FEE_COLLECTOR_DELAY = 24 hours;

function proposeFeeCollector(address _feeCollector) external onlyOwner {
    if (_feeCollector == address(0)) revert InvalidFeeCollector();
    pendingFeeCollector = _feeCollector;
    feeCollectorChangeTime = block.timestamp + FEE_COLLECTOR_DELAY;
    emit FeeCollectorProposed(_feeCollector, feeCollectorChangeTime);
}

function applyFeeCollector() external onlyOwner {
    if (pendingFeeCollector == address(0)) revert NoPendingChange();
    if (block.timestamp < feeCollectorChangeTime) revert TimelockNotExpired();
    // ... applies change, clears pending state
}
```

**Verdict: FIXED.** The 24-hour timelock matches the FeeSwapAdapter pattern.
The implementation correctly:
- Requires `onlyOwner` for both propose and apply
- Validates proposed address is not zero
- Enforces minimum 24-hour delay
- Clears pending state after application via `delete`
- Emits events for both proposal and application

**Residual concerns:** No explicit cancellation function (see L-01), and
overwriting a pending proposal resets the timer (acceptable behavior, but
worth documenting).

---

### M-03 Fix: Minimum Swap Amount

**Location:** Lines 53-55 (`MIN_SWAP_AMOUNT`), Line 515 (enforcement in
`_validateFee()`)

**Implementation:**
```solidity
uint256 public constant MIN_SWAP_AMOUNT = 1e15;

function _validateFee(...) private view {
    if (totalAmount == 0) revert ZeroAmount();
    if (totalAmount < MIN_SWAP_AMOUNT) revert AmountTooSmall();
    // ...
}
```

**Verdict: FIXED.** The `1e15` minimum (0.001 tokens with 18 decimals) prevents
dust swaps that would result in zero fees due to integer division rounding.
At `maxFeeBps = 100` (1%), the minimum fee on a `1e15` swap is
`1e15 * 100 / 10000 = 1e13`, which is non-zero.

**Note:** Zero-fee swaps (`feeAmount = 0`) are still allowed when
`totalAmount >= MIN_SWAP_AMOUNT`. This is by design -- the fee amount is set
by the caller (typically the front-end), and the contract only enforces an
upper cap, not a lower floor.

---

## Medium Findings

### [M-01] Router Allowlist Changes Have No Timelock

**Severity:** Medium
**Category:** Access Control / Centralization
**Location:** `setRouterAllowed()` lines 334-342
**VP Reference:** VP-06, SOL-Timelock-1

**Description:**

The `setRouterAllowed()` function immediately adds or removes routers from the
allowlist with no timelock or delay. While `proposeFeeCollector()` correctly
implements a 24-hour timelock (remediation of R6 M-02), the router allowlist
does not receive the same treatment.

**Attack scenario (compromised owner key):**

1. Attacker gains access to the owner private key.
2. Attacker deploys a malicious router contract that, when called, approves
   the attacker for all tokens held by OmniFeeRouter.
3. Attacker calls `setRouterAllowed(maliciousRouter, true)`.
4. Attacker calls `swapWithFee()` with the malicious router. The contract
   calls `forceApprove(routerAddress, netAmount)`, giving the malicious
   router an approval. The malicious router can then transfer tokens.
5. However, `_executeRouterSwap` resets the approval to zero after the call
   and sweeps residual tokens, limiting the damage window to the single
   transaction.

**Revised risk assessment:** The single-transaction attack window is narrow
because:
- The approval is reset to zero after the call (line 457)
- Residual tokens are swept (lines 462-466)
- The contract does not hold tokens between transactions

The actual risk is that the attacker could add a router that silently
re-routes swap output to the attacker's address instead of back to the
contract. The `minOutput` check would catch this if set properly, but many
users set `minOutput = 0`.

A timelock on router additions would give users and monitoring systems time
to react to unexpected changes.

**Recommendation:**

Apply the same propose/apply timelock pattern used for fee collector changes:
```solidity
struct PendingRouter {
    address router;
    bool allowed;
    uint256 effectiveTime;
}

PendingRouter public pendingRouterChange;

function proposeRouterChange(address router, bool allowed) external onlyOwner {
    pendingRouterChange = PendingRouter(router, allowed, block.timestamp + 24 hours);
}

function applyRouterChange() external onlyOwner {
    require(block.timestamp >= pendingRouterChange.effectiveTime);
    allowedRouters[pendingRouterChange.router] = pendingRouterChange.allowed;
    delete pendingRouterChange;
}
```

Alternatively, accept the current design for Pioneer Phase and document that
router allowlist changes are instant, requiring extra care with the owner key.

---

### [M-02] No Pause Mechanism for Emergency Response

**Severity:** Medium
**Category:** Operational Security / Emergency Response
**Location:** Entire contract
**VP Reference:** VP-13 (Emergency Procedures)

**Description:**

The contract has no pause mechanism. If a vulnerability is discovered in an
allowlisted external router, or if a broader DeFi exploit affects the
underlying DEX pools, the owner cannot pause the contract to prevent user
losses.

The only mitigation available is to remove all routers from the allowlist
via individual `setRouterAllowed(router, false)` calls. If there are many
allowlisted routers, this requires multiple transactions and cannot be done
atomically.

**Comparison with other OmniBazaar contracts:**
- UnifiedFeeVault: Has Pausable
- FeeSwapAdapter: Has Pausable
- OmniFeeRouter: No Pausable

**Risk assessment:** Medium. While the contract does not hold user funds between
transactions (limiting the damage window), an active exploit against an
allowlisted router could drain tokens during in-flight swaps. The lack of a
single-transaction emergency stop increases response time during incidents.

**Recommendation:**

Add `Pausable` from OpenZeppelin with the `whenNotPaused` modifier on
`swapWithFee()`:

```solidity
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OmniFeeRouter is Ownable2Step, ReentrancyGuard, ERC2771Context, Pausable {
    function swapWithFee(...) external nonReentrant whenNotPaused { ... }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

This provides a single-transaction emergency stop that complements the
router allowlist approach.

---

## Low Findings

### [L-01] No Cancellation Function for Pending Fee Collector Proposals

**Severity:** Low
**Category:** Operational / Access Control
**Location:** `proposeFeeCollector()` / `applyFeeCollector()` lines 295-326

**Description:**

Once a fee collector change is proposed via `proposeFeeCollector()`, there is
no explicit way to cancel it. The owner has two options:

1. **Wait and do nothing** -- the pending change remains in state indefinitely
   after the timelock expires, executable at any time by the owner.
2. **Overwrite** -- call `proposeFeeCollector()` with the current
   `feeCollector` address to effectively reset the pending change (but this
   starts a new 24-hour timer).

The lack of an explicit cancel is a minor operational gap. If the owner
proposes a change and later decides not to apply it, the pending proposal
remains in state forever, which could be confusing for monitoring tools or
governance participants.

More critically, a pending proposal never expires. If the owner proposes a
change to address `X`, decides against it, and months later a different
person gains access to the owner key (e.g., after ownership transfer), they
can apply the stale proposal if they are unaware of it.

**Recommendation:**

Add a `cancelFeeCollectorChange()` function:
```solidity
function cancelFeeCollectorChange() external onlyOwner {
    if (pendingFeeCollector == address(0)) revert NoPendingChange();
    delete pendingFeeCollector;
    delete feeCollectorChangeTime;
    emit FeeCollectorChangeCancelled();
}
```

Or add an expiration window (e.g., pending proposals expire after 7 days):
```solidity
if (block.timestamp > feeCollectorChangeTime + 7 days) revert ProposalExpired();
```

---

### [L-02] `totalFeesCollected` Mixes Token Units Across Different ERC-20 Decimals

**Severity:** Low
**Category:** Accounting / Monitoring
**Location:** `swapWithFee()` line 259

**Description:**

The `totalFeesCollected` state variable accumulates fee amounts across all
swaps, regardless of which token the fee was collected in:

```solidity
totalFeesCollected += actualFee;
```

If the contract processes swaps with USDC (6 decimals), WETH (18 decimals),
and WBTC (8 decimals), the counter mixes these incompatible units into a
single sum. The resulting value is meaningless for financial reporting.

This is not a security vulnerability -- no funds are at risk. However, it
could mislead off-chain monitoring systems, dashboards, or auditors who
interpret the counter as a single-token amount.

**Recommendation:**

Either:
1. **Remove the counter** if it is not used by other contracts or monitoring.
2. **Use a per-token mapping** for accurate accounting:
   ```solidity
   mapping(address => uint256) public feesCollectedByToken;
   ```
3. **Document** that `totalFeesCollected` is an approximate counter for
   monitoring purposes only and should not be used for financial calculations.

---

### [L-03] `renounceOwnership()` Reuses `InvalidFeeCollector` Error (Carried from R6 L-03)

**Severity:** Low
**Location:** `renounceOwnership()` lines 362-364
**Status:** Carried from Round 6, unfixed

**Description:**

The `renounceOwnership()` override reverts with `InvalidFeeCollector()`, which
is semantically incorrect. This error describes a fee collector validation
failure, not an ownership renunciation refusal.

```solidity
function renounceOwnership() public pure override {
    revert InvalidFeeCollector(); // Misleading
}
```

Off-chain tools, block explorers, and error decoders will display
"InvalidFeeCollector" when a user attempts to renounce ownership, which is
confusing.

**Recommendation:**

Add a dedicated custom error:
```solidity
error OwnershipRenunciationDisabled();

function renounceOwnership() public pure override {
    revert OwnershipRenunciationDisabled();
}
```

---

## Informational Findings

### [I-01] `proposeFeeCollector` Does Not Reject `feeCollector == address(this)`

**Location:** `proposeFeeCollector()` lines 296-304

If the owner proposes `address(this)` (the OmniFeeRouter contract itself) as
the fee collector, fees collected during swaps would be transferred to the
contract. The `rescueTokens()` function sends tokens to `feeCollector`,
creating a no-op loop where rescued tokens are sent back to the contract.

This is an unlikely operator error, not an exploit. The owner controls both
`proposeFeeCollector` and `rescueTokens`, so they can correct the mistake.
No funds are lost -- they just accumulate in the contract until the fee
collector is changed.

**Recommendation:** Consider adding a check:
```solidity
if (_feeCollector == address(this)) revert InvalidFeeCollector();
```

---

### [I-02] Event Does Not Include `minOutput` or `deadline` Parameters (Carried from R6 I-02)

**Location:** `SwapExecuted` event, lines 94-102

The `SwapExecuted` event captures `totalAmount`, `feeAmount`, `netAmount`, and
`router`, but omits `minOutput` and `deadline`. These parameters are useful
for off-chain forensic analysis of MEV attacks and slippage monitoring.

---

### [I-03] ERC2771 Trusted Forwarder Is Immutable and Cannot Be Rotated (Carried from R6 L-02)

**Location:** Constructor line 193

The `trustedForwarder` is set immutably via `ERC2771Context`. If the forwarder
is compromised, there is no way to update it without redeploying the entire
contract. A compromised forwarder could spoof `_msgSender()` for any user who
has approved the OmniFeeRouter. Deploying with `address(0)` as the forwarder
eliminates this attack surface if meta-transactions are not needed during
Pioneer Phase.

---

## Access Control Map

| Role | Functions | Modifiers | Risk Level |
|------|-----------|-----------|------------|
| Owner (Ownable2Step) | `proposeFeeCollector()`, `applyFeeCollector()`, `setRouterAllowed()`, `rescueTokens()`, `transferOwnership()` | `onlyOwner` | 5/10 |
| Any caller | `swapWithFee()` | `nonReentrant` | 2/10 (reduced from 3/10 after R6 M-01 fix) |
| Pending owner | `acceptOwnership()` | Inherited check | 1/10 |
| Trusted forwarder (immutable) | Can spoof `_msgSender()` in `swapWithFee()` | N/A | 4/10 |

---

## Centralization Risk Assessment

**Single-key maximum damage: 5/10** (unchanged from Round 6)

**The owner CAN:**
1. Instantly add/remove routers from the allowlist (M-01)
2. Propose a new fee collector (24-hour timelock before application)
3. Rescue stuck tokens to the current fee collector
4. Transfer ownership via Ownable2Step (requires acceptance)

**The owner CANNOT:**
- Pause the contract (no pause mechanism)
- Upgrade the contract (not upgradeable)
- Modify the fee cap (`maxFeeBps` is immutable)
- Access user funds mid-swap (reentrancy guard, no persistent token holdings)
- Change the trusted forwarder (immutable)
- Lower `MIN_SWAP_AMOUNT` (constant)
- Lower `FEE_COLLECTOR_DELAY` (constant)

**Recommendation:** Transfer ownership to a multi-sig wallet before processing
significant volume. The instant router allowlist changes (M-01) are the
primary remaining centralization vector.

---

## DeFi Exploit Analysis

### Flash Loan Attack
**Not applicable.** OmniFeeRouter does not perform price-sensitive operations.
The `minOutput` parameter protects users from manipulated pool prices.

### Sandwich Attack
**Partially applicable.** Standard DEX sandwich attacks affect the underlying
router swap, not OmniFeeRouter's fee logic. The `deadline` and `minOutput`
parameters are present as mitigations.

### Fee Extraction Attack
**Not applicable.** Fee cap is immutable. No way to inflate fees beyond `maxFeeBps`.

### Reentrancy
**Not applicable.** `nonReentrant` on `swapWithFee()` and `rescueTokens()`.
ERC-777 callbacks are blocked.

### Approval Drain (Transit Swap Pattern)
**Not applicable.** Router allowlist + address validation eliminates the
arbitrary-call-to-token attack vector. The approval is reset to zero after
every swap call.

---

## Gas Optimization Notes

- Immutable `maxFeeBps` saves SLOAD per swap -- good.
- Custom errors save ~300 gas per revert vs. string messages -- good.
- `forceApprove` handles non-standard tokens without separate reset -- good.
- Private `view` functions are likely inlined by the optimizer -- good.
- `delete` on pending state variables provides gas refund -- good.
- Allowlist check (`mapping(address => bool)`) is O(1) SLOAD -- good.
- `totalFeesCollected` adds one unnecessary SLOAD + SSTORE per fee-paying
  swap (~5,000 gas). Consider removing if the counter is not consumed
  on-chain (see L-02).

---

## Round-over-Round Progress

| Finding | R2 | R6 | R7 |
|---------|----|----|-----|
| Arbitrary call drain (C-01) | CRITICAL | FIXED | Verified |
| Same-token accounting (H-01) | HIGH | FIXED | Verified |
| Fee-on-transfer (H-02) | HIGH | FIXED | Verified |
| Leftover tokens (H-03) | HIGH | FIXED | Verified |
| No deadline (M-01) | MEDIUM | FIXED | Verified |
| No code check (M-02) | MEDIUM | FIXED | Verified |
| No rescue event (M-03) | MEDIUM | FIXED | Verified |
| Unwhitelisted routers (R6 M-01) | -- | MEDIUM | **FIXED** |
| No fee collector timelock (R6 M-02) | -- | MEDIUM | **FIXED** |
| Dust fee evasion (R6 M-03) | -- | MEDIUM | **FIXED** |
| Rescue destination (R6 L-01) | -- | LOW | Acknowledged (by design) |
| Immutable forwarder (R6 L-02) | -- | LOW | **CARRIED** (I-03) |
| Wrong error in renounce (R6 L-03) | -- | LOW | **CARRIED** (L-03) |
| Router allowlist no timelock | -- | -- | **NEW** (M-01) |
| No pause mechanism | -- | -- | **NEW** (M-02) |
| No cancel for pending proposal | -- | -- | **NEW** (L-01) |
| Mixed-unit fee counter | -- | -- | **NEW** (L-02) |
| Self-address as fee collector | -- | -- | **NEW** (I-01) |

---

## Test Coverage Assessment

The test suite (74 tests, all passing) provides excellent coverage:

**Well-covered areas:**
- Constructor validation (zero address, fee cap bounds)
- All revert conditions in `swapWithFee()`
- Router address validation (zero, inputToken, outputToken, self, EOA)
- Router allowlist management (add, remove, access control, swap rejection)
- Fee collector timelock (propose, apply, timing, access control, events)
- Ownership (Ownable2Step transfer, accept, renounce disabled)
- Event emissions (SwapExecuted, TokensRescued, FeeCollectorUpdated, etc.)
- Successful swap flows (zero fee, with fee, multi-token, residual sweep)
- Cumulative fee accounting
- Minimum swap amount enforcement

**Areas with limited coverage:**
- Fee-on-transfer token behavior (not tested with actual deflationary token)
- ERC2771 meta-transaction flow (forwarder integration)
- Edge case: `feeCollector == address(this)`
- Edge case: overwriting a pending fee collector proposal
- Edge case: `minOutput = 0` with malicious router

---

## Conclusion

OmniFeeRouter has matured significantly over three audit rounds. All Critical
and High findings from Round 2 are verified fixed. All Medium findings from
Round 6 are verified fixed with proper implementations (router allowlist,
fee collector timelock, minimum swap amount).

The contract follows security best practices:
- Reentrancy protection on all external entry points
- SafeERC20 for all token transfers
- Balance-before/after accounting for fee-on-transfer compatibility
- Router allowlist restricting arbitrary external calls
- Immutable fee cap preventing fee manipulation
- 24-hour timelock on fee collector changes
- Minimum swap amount preventing dust fee evasion
- Ownable2Step for safe ownership transfer
- Disabled `renounceOwnership`
- Residual token sweep for partial fills
- Deadline parameter for MEV protection

The remaining findings are Medium and Low severity:
- **M-01:** Router allowlist changes lack a timelock (instant add/remove)
- **M-02:** No emergency pause mechanism
- **L-01/L-02/L-03:** Operational and cosmetic issues

**Pre-Mainnet Readiness: PASS**

The contract is suitable for Pioneer Phase deployment with the following
recommendations before scaling to significant volume:
1. Transfer ownership to a multi-sig wallet
2. Consider adding a timelock to `setRouterAllowed()` (M-01)
3. Consider adding Pausable for emergency response (M-02)
4. Fix the `renounceOwnership` error name (L-03) -- trivial change

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet*
*Contract version: 540 lines, Solidity 0.8.24*
*Prior audits: Round 2 (2026-02-20), Round 6 (2026-03-10) -- all Critical/High/Medium findings remediated*
*Test suite: 74 tests passing (2s)*
