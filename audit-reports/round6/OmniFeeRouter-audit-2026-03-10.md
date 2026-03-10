# Security Audit Report: OmniFeeRouter (Round 6 -- Pre-Mainnet)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Round 6 Pre-Mainnet)
**Contract:** `Coin/contracts/dex/OmniFeeRouter.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 439
**Upgradeable:** No
**Handles Funds:** Yes (ERC-20 fee-collecting swap wrapper)
**Previous Audits:** Round 2 (2026-02-20) -- 1 Critical, 3 High, 3 Medium, 3 Low

---

## Executive Summary

OmniFeeRouter is a trustless fee-collecting wrapper for external DEX swaps
deployed per EVM chain. It pulls input tokens from the caller, deducts a capped
fee, forwards the remainder to a user-specified external DEX router via
low-level call, and sweeps output tokens back to the caller.

**All Critical and High findings from Round 2 have been remediated:**

| Round 2 Finding | Status |
|-----------------|--------|
| C-01: Arbitrary external call enabling approval drain | FIXED -- Router validation blocks token addresses, self-address, and EOAs |
| H-01: Same-token swap breaks accounting | FIXED -- `_validateTokens` rejects `inputToken == outputToken` |
| H-02: Fee-on-transfer token incompatibility | FIXED -- Balance-before/after accounting with proportional fee recalculation |
| H-03: Leftover input tokens not returned | FIXED -- Residual input sweep in `_executeRouterSwap` |
| M-01: No deadline parameter | FIXED -- `deadline` parameter with `DeadlineExpired` check |
| M-02: No code existence check on router | FIXED -- `routerAddress.code.length == 0` check |
| M-03: rescueTokens lacks event | FIXED -- `TokensRescued` event added |

This round identifies **zero Critical or High** issues. The contract has
matured significantly. The remaining findings are medium and low severity,
focused on residual attack surface from the arbitrary calldata design,
centralization risk from the mutable fee collector, and minor edge cases.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 3 |
| Informational | 4 |

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| M-01 | Medium | Arbitrary calldata to unwhitelisted routers -- residual attack surface | **FIXED** |
| M-02 | Medium | Mutable fee collector without timelock | **FIXED** |
| M-03 | Medium | Fee rounding allows zero-fee swaps on dust amounts | **FIXED** |

---

## Remediation Verification (Round 2 Fixes)

### C-01 Fix Verification: Router Validation

**Lines 337-351:** `_validateRouter()` now blocks:
- `routerAddress == address(0)` -- zero address
- `routerAddress == inputToken` -- prevents approval-via-token-call attack
- `routerAddress == outputToken` -- prevents output token manipulation
- `routerAddress == address(this)` -- prevents self-call reentrancy
- `routerAddress.code.length == 0` -- prevents silent success on EOA calls

**Verdict: FIXED.** The Transit Swap / LI.FI attack pattern (setting
`routerAddress = inputToken` to execute `approve(attacker, MAX)`) is fully
blocked. The fix covers the five specific attack vectors identified in Round 2.

**Residual consideration:** The router address is still user-controlled (any
contract with code is accepted), so the calldata is still arbitrary within that
scope. See M-01 below for remaining attack surface analysis.

### H-01 Fix Verification: Same-Token Swap

**Lines 380-387:** `_validateTokens()` rejects `inputToken == outputToken`.

**Verdict: FIXED.** Balance-delta double-counting is no longer possible.

### H-02 Fix Verification: Fee-on-Transfer Tokens

**Lines 188-200:** Balance-before/after pattern implemented. Fee and net
amounts are proportionally recalculated based on `actualReceived`:
```
actualFee = (actualReceived * feeAmount) / totalAmount
netAmount = actualReceived - actualFee
```

**Verdict: FIXED.** The proportional recalculation correctly handles
fee-on-transfer tokens. The contract never assumes it received `totalAmount`.

### H-03 Fix Verification: Residual Input Sweep

**Lines 316-320:** After the router call and approval reset, any remaining
input tokens are swept back to the caller.

**Verdict: FIXED.** Partial fills no longer strand tokens in the contract.

### M-01 Fix Verification: Deadline Parameter

**Line 181:** `if (block.timestamp > deadline) revert DeadlineExpired();`

**Verdict: FIXED.** Caller must provide a future-timestamp deadline. Note that
the caller provides the deadline, not `block.timestamp`, so it is a meaningful
check (unlike the prior FeeSwapAdapter issue).

### M-02 Fix Verification: Router Code Check

**Line 348:** `if (routerAddress.code.length == 0) revert InvalidRouterAddress();`

**Verdict: FIXED.**

### M-03 Fix Verification: Rescue Event

**Lines 81, 257:** `TokensRescued` event defined and emitted in `rescueTokens()`.

**Verdict: FIXED.**

---

## Medium Findings

### [M-01] Arbitrary Calldata to Unwhitelisted Routers -- Residual Attack Surface

**Severity:** Medium (downgraded from Round 2 Critical, because token-address
and EOA routers are now blocked)
**Category:** SC01 Access Control / SC06 Unchecked External Calls
**Location:** `swapWithFee()` lines 176, 303-308; `_validateRouter()` lines 337-351
**Precedent:** Transit Swap ($21M), SushiSwap RouteProcessor2 ($3.3M)

**Description:**

While the C-01 fix blocks the five most dangerous router targets (zero address,
inputToken, outputToken, self, EOA), the `routerAddress` and `routerCalldata`
remain fully user-controlled. Any deployed contract (except the blocked
addresses) can be called with arbitrary calldata.

Remaining attack vectors:
1. **Approval to third-party tokens:** If `routerAddress` is a contract that
   has its own `approve` function or delegates calls, an attacker could still
   create persistent approvals from OmniFeeRouter to arbitrary spenders via
   the router as a proxy. This requires finding a deployed contract that (a)
   has code, (b) is not inputToken/outputToken/self, and (c) contains an
   exploitable function. This is highly situational but not impossible.

2. **Return data bomb:** A malicious router contract can return extremely large
   return data, causing OOG during memory expansion in `bytes memory returnData`
   (line 303). The user's swap fails and gas is wasted, but no funds are lost
   because the entire transaction reverts.

3. **Router state manipulation:** The arbitrary call could change state in
   unrelated contracts if the target has fallback functions or misconfigured
   access control.

**Risk Assessment:** Medium. The C-01 fix eliminates the specific $42M+ exploit
pattern. The remaining vectors require finding specific deployed contracts with
exploitable interfaces, which is situational. The contract never holds user
funds between transactions (swept within the same call), limiting the damage
window.

**Recommendation:**

For the highest security posture, consider a router allowlist controlled by the
owner:
```solidity
mapping(address => bool) public allowedRouters;

function setRouterAllowed(address router, bool allowed) external onlyOwner {
    allowedRouters[router] = allowed;
}
```
This trades off permissionlessness for security. Given the Pioneer Phase
context, the current approach with validation is acceptable, but an allowlist
should be considered before handling significant TVL.

---

### [M-02] Mutable Fee Collector Without Timelock

**Severity:** Medium
**Category:** Centralization / Access Control
**Location:** `setFeeCollector()` lines 238-246
**VP Reference:** VP-06 (Access Control), SOL-CR-4, SOL-Timelock-1

**Description:**

The `feeCollector` is mutable via `setFeeCollector()`, callable by the owner
with no timelock. This is a design change from Round 2, where the fee collector
was noted as immutable (in the original contract). The current version allows
the owner to redirect all future fees instantly.

The NatSpec at line 235-236 acknowledges this: "Pioneer Phase: no timelock.
Will be replaced with timelocked version before multi-sig handoff."

**Single-key damage:** If the owner key is compromised, an attacker can redirect
all fee revenue to their own address. No existing fees are at risk (fees are
sent to the collector immediately during `swapWithFee`, not accumulated), but
all future fee revenue from swaps in progress or submitted would go to the
attacker's address.

**Recommendation:**

Implement a propose/apply timelock pattern matching the FeeSwapAdapter's
`proposeRouter`/`applyRouter` (24h delay), or at minimum document the timeline
for replacing this with a timelocked version. The comment says "before multi-sig
handoff" but no specific milestone is defined.

---

### [M-03] Fee Rounding Allows Zero-Fee Swaps on Dust Amounts

**Severity:** Medium (upgraded from Round 2 Low -- relevant for mainnet)
**Category:** SC07 Arithmetic / Business Logic
**Location:** `_validateFee()` lines 359-372
**VP Reference:** VP-12 (Arithmetic Precision)

**Description:**

The fee validation computes `maxAllowed = (totalAmount * maxFeeBps) / BPS_DENOMINATOR`.
With `maxFeeBps = 100` (1%):

- `totalAmount = 99 wei` --> `maxAllowed = (99 * 100) / 10000 = 0`
- A caller can set `feeAmount = 0` and pass the cap check, executing fee-free swaps.

On low-fee L2 chains (Arbitrum, Base, Polygon), where gas costs are sub-cent,
an attacker could execute thousands of zero-fee dust swaps per second via a
bot, avoiding paying any protocol fees. While each swap is individually
negligible, at scale this becomes meaningful fee evasion.

**Additionally:** The proportional fee recalculation for fee-on-transfer tokens
(line 199) can further reduce fees:
```
actualFee = (actualReceived * feeAmount) / totalAmount
```
If `actualReceived` is small enough, `actualFee` rounds to zero even for
non-zero `feeAmount`.

**Recommendation:**

Add a minimum total amount check:
```solidity
uint256 public constant MIN_SWAP_AMOUNT = 1e15; // 0.001 tokens (18 decimals)
if (totalAmount < MIN_SWAP_AMOUNT) revert AmountTooSmall();
```
Or enforce a minimum fee floor:
```solidity
if (feeAmount == 0 && totalAmount > 0) revert ZeroFeeNotAllowed();
```

---

## Low Findings

### [L-01] rescueTokens Sends to feeCollector, Not to Original Token Owner

**Severity:** Low
**Location:** `rescueTokens()` lines 253-259

**Description:**

When tokens are accidentally sent to the contract, `rescueTokens()` sends them
to `feeCollector`, not to the original sender. There is no way for the original
token owner to be identified on-chain, so this is a reasonable design choice.
However, since `feeCollector` is mutable (see M-02), a compromised owner could:
1. Change `feeCollector` to their address
2. Call `rescueTokens` to drain any stuck tokens

The `nonReentrant` modifier prevents this from being exploitable during active
swaps, and the contract should not hold tokens between transactions. But if the
rescue function is intended as a safety net, the destination should be more
carefully considered.

**Recommendation:**

Consider sending rescued tokens to the owner or to a fixed rescue destination,
or require that rescueTokens only be callable when the contract holds more
tokens than expected.

---

### [L-02] ERC2771 Trusted Forwarder Is Immutable and Cannot Be Rotated

**Severity:** Low
**Location:** Constructor line 139

**Description:**

The `trustedForwarder` is set in the constructor as an immutable value (via
`ERC2771Context`). If the forwarder contract is compromised or needs to be
upgraded, there is no way to update it without redeploying the entire
OmniFeeRouter contract.

A compromised forwarder could craft calls where `_msgSender()` returns any
arbitrary address, allowing the attacker to:
- Call `swapWithFee()` as any user (but the user must have approved the router)
- Trigger swaps with the forwarder-spoofed address as the fee payer

Since `swapWithFee` requires the caller to have approved the contract for
`totalAmount`, exploitation requires the victim to have an existing approval.
The forwarder trust boundary is well-defined but not upgradeable.

**Recommendation:**

Document the forwarder immutability in deployment documentation. Consider
deploying with `address(0)` as the forwarder if meta-transactions are not
needed initially, to eliminate this attack surface entirely during the Pioneer
Phase.

---

### [L-03] renounceOwnership Reuses InvalidFeeCollector Error

**Severity:** Low
**Location:** `renounceOwnership()` lines 266-268

**Description:**

`renounceOwnership()` reverts with `InvalidFeeCollector()`, which is
semantically incorrect. This error is about the fee collector address, not
about ownership renunciation. Compare with FeeSwapAdapter, which correctly
uses `OwnershipRenunciationDisabled()`.

```solidity
function renounceOwnership() public pure override {
    revert InvalidFeeCollector(); // Misleading error
}
```

**Recommendation:**

Add a dedicated error:
```solidity
error OwnershipRenunciationDisabled();

function renounceOwnership() public pure override {
    revert OwnershipRenunciationDisabled();
}
```

---

## Informational Findings

### [I-01] Constructor Allows trustedForwarder == address(0)

**Location:** Constructor line 136-139

The `trustedForwarder_` parameter is not validated against `address(0)`. While
`ERC2771Context(address(0))` is valid and simply disables meta-transaction
support, it might be worth documenting this explicitly. If `address(0)` is
passed, `_msgSender()` always returns `msg.sender` and `_contextSuffixLength()`
returns 0, which is safe behavior.

---

### [I-02] Event Emission Does Not Include minOutput or deadline

**Location:** `SwapExecuted` event, lines 68-76

The `SwapExecuted` event captures `totalAmount`, `feeAmount`, `netAmount`, and
`router`, but omits `minOutput` and `deadline`. These parameters are useful for
off-chain monitoring and forensic analysis of MEV attacks. If a swap was
sandwiched, the `minOutput` value helps determine whether the user's slippage
tolerance was exploited.

**Recommendation:** Consider adding `minOutput` and `deadline` to the event.

---

### [I-03] No Explicit receive() or fallback() -- Native Token Safety

**Location:** Entire contract

The contract has no `receive()` or `fallback()` function, which means native
ETH/AVAX sent to the contract will revert. This is correct behavior -- the
contract only handles ERC-20 tokens. However, if any external router returns
native tokens (e.g., unwrapping WETH), those would be lost. The contract's
documentation states it wraps ERC-20 swaps only, so this is acceptable.

---

### [I-04] Fee Proportional Recalculation Precision

**Location:** `swapWithFee()` line 199

```solidity
uint256 actualFee = (actualReceived * feeAmount) / totalAmount;
```

For fee-on-transfer tokens, this proportional calculation can lose precision
due to integer division. Example: `actualReceived = 97`, `feeAmount = 1`,
`totalAmount = 100` yields `actualFee = (97 * 1) / 100 = 0`. The fee is
lost to rounding. This is a benign edge case (the protocol collects slightly
less fee than intended) and favors the user, which is the safer direction.
No fix needed, but worth documenting.

---

## Cross-Contract Interaction Analysis

### OmniFeeRouter <-> FeeSwapAdapter

These contracts serve different purposes and do NOT directly call each other:
- **OmniFeeRouter:** User-facing swap wrapper for external DEX routers
  (Uniswap, SushiSwap, etc.) on any EVM chain. Collects fees before routing
  to the external DEX.
- **FeeSwapAdapter:** Internal adapter used by UnifiedFeeVault to convert
  non-XOM fee tokens to XOM via OmniSwapRouter.

**Indirect interaction:** A user could theoretically set `routerAddress` in
`OmniFeeRouter.swapWithFee()` to the FeeSwapAdapter address. The
`_validateRouter` checks would pass (FeeSwapAdapter has code, is not a token
address, and is not `address(this)`). The `routerCalldata` could then invoke
`FeeSwapAdapter.swapExactInput()`.

**Risk assessment:** Low. The FeeSwapAdapter's `swapExactInput` would:
1. Call `safeTransferFrom(msg.sender=OmniFeeRouter, ...)` -- this would fail
   unless OmniFeeRouter approved the FeeSwapAdapter, which it does via
   `forceApprove(routerAddress, netAmount)`.
2. The swap would execute through OmniSwapRouter.
3. Output tokens go to `recipient` (set in the FeeSwapAdapter call), not
   back to OmniFeeRouter.

This would result in the user's output tokens being sent to whatever
`recipient` was encoded in the calldata, not to the user. But the user
controls the calldata, so this is a self-inflicted loss, not an attack vector
against other users. The OmniFeeRouter's output sweep would find zero output
tokens, failing the `minOutput` check if set properly.

**Conclusion:** No exploitable cross-contract attack vector identified.

### OmniFeeRouter <-> UnifiedFeeVault

OmniFeeRouter could be registered as a DEPOSITOR_ROLE address on the
UnifiedFeeVault, sending collected fees to the vault. However, the current
implementation sends fees directly to `feeCollector` (line 204), not to the
vault. This means the fee distribution does not automatically go through the
70/20/10 split.

**Recommendation:** If OmniFeeRouter fees should participate in the 70/20/10
split, configure `feeCollector` to be the UnifiedFeeVault address, and grant
OmniFeeRouter the DEPOSITOR_ROLE. Alternatively, if fees are meant to go
directly to a specific recipient, the current design is correct.

---

## DeFi Exploit Analysis

### Flash Loan Attack on Fee Swap Rates

**Applicable:** No. OmniFeeRouter does not perform price-sensitive operations
itself. It wraps external DEX calls. A flash loan attack against the underlying
DEX pool would affect the swap rate, but:
1. The `minOutput` parameter protects the user from receiving too few output
   tokens.
2. The `deadline` parameter prevents stale transactions.
3. The fee is calculated on the input amount, not the output, so manipulating
   the pool price does not affect the fee calculation.

### Sandwich Attack on Fee Swaps

**Applicable:** Partially. A sandwich attacker can:
1. Front-run the user's `swapWithFee` call to move the pool price.
2. The user's swap executes at a worse rate.
3. The attacker back-runs to profit.

This is a standard DEX sandwich attack that affects the underlying router swap,
not the OmniFeeRouter's fee collection logic. The `minOutput` and `deadline`
parameters are the correct mitigations, and they are present.

### Fee Extraction Attack

**Applicable:** No. The fee is capped by the immutable `maxFeeBps` (max 5%,
enforced at construction). The fee is deducted from the user's input before
the swap, not from the output. There is no way for an attacker to inflate
the fee beyond the cap.

### Reentrancy in Fee Distribution

**Applicable:** No. The `nonReentrant` modifier on `swapWithFee` prevents
reentrancy. The `_executeRouterSwap` function is `private` and cannot be
called directly. ERC-777 token callbacks are blocked by the reentrancy guard.

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| Owner (Ownable2Step) | `setFeeCollector()`, `rescueTokens()`, `renounceOwnership()` (disabled) | 5/10 |
| Any caller | `swapWithFee()` | 3/10 (reduced from 9/10 after C-01 fix) |
| trustedForwarder (immutable) | Can spoof `_msgSender()` in `swapWithFee()` | 4/10 |

---

## Centralization Risk Assessment

**Single-key maximum damage:** 5/10

The owner can:
1. Change `feeCollector` to redirect future fees (M-02)
2. Rescue any stuck tokens to the current `feeCollector` (L-01)
3. Transfer ownership via Ownable2Step (requires acceptance)

The owner CANNOT:
- Pause the contract
- Upgrade the contract
- Modify the fee cap (`maxFeeBps` is immutable)
- Access user funds during swaps (reentrancy guard)
- Change the trusted forwarder (immutable)

**Recommendation:** The centralization risk is moderate. The mutable
`feeCollector` is the primary concern. Transfer ownership to a multi-sig
wallet before mainnet launch. Add a timelock to `setFeeCollector()` to match
the pattern used in FeeSwapAdapter.

---

## Gas Optimization Notes

- Immutable `maxFeeBps` saves SLOAD on every swap -- good.
- Custom errors save ~300 gas per revert vs. string messages -- good.
- `forceApprove` handles both standard and non-standard approval semantics
  without a separate reset step -- good.
- The `_validateRouter`, `_validateFee`, and `_validateTokens` are `private
  view` functions that the compiler will likely inline -- good.

---

## Conclusion

OmniFeeRouter has been substantially improved since Round 2. All Critical and
High findings have been properly remediated. The contract follows security best
practices including:
- Reentrancy protection on all external entry points
- SafeERC20 for all token transfers
- Balance-before/after accounting for fee-on-transfer compatibility
- Router validation to prevent the $42M+ arbitrary call exploit pattern
- Deadline parameter for MEV protection
- Residual token sweep for partial fills
- Ownable2Step for safe ownership transfer
- Disabled renounceOwnership

The remaining findings are medium and low severity, primarily related to:
- The inherent risk of accepting arbitrary calldata (mitigated but not eliminated)
- Missing timelock on fee collector changes
- Rounding-based fee evasion on dust amounts

**Pre-Mainnet Readiness: PASS with recommendations.**
Fix M-02 (add timelock to setFeeCollector) and M-03 (add minimum swap amount)
before processing significant volume. M-01 (router allowlist) is recommended
but not blocking for Pioneer Phase.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet*
*Contract version: 439 lines, Solidity 0.8.24*
*Prior audit: Round 2 (2026-02-20) -- all Critical/High findings remediated*
