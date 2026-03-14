# Security Audit Report: OmniPredictionRouter (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/predictions/OmniPredictionRouter.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 627
**Upgradeable:** No
**Handles Funds:** Yes (atomic fee-collecting router for prediction market trades)
**Previous Audits:** Round 2 (2026-02-20), Round 6 (2026-03-10)
**Test Suite:** 81 tests, all passing (2s)
**Slither:** Skipped per instruction
**Solhint:** 0 errors, 0 warnings

---

## Executive Summary

OmniPredictionRouter is a trustless, non-upgradeable fee-collecting router for
prediction market trades on Polymarket (Polygon) and Omen (Gnosis Chain). It
atomically pulls collateral from the user, deducts a capped fee for the
UnifiedFeeVault, and forwards the remainder to an allowlisted platform contract.
Outcome tokens (ERC-20 or ERC-1155) are swept back to the caller via dedicated
functions.

**Round 2 -> Round 6 remediation status:**

All Critical, High, and Medium findings from Rounds 2 and 6 have been addressed
and verified in the current codebase:

| Round 2 Finding | Status |
|-----------------|--------|
| C-01: Arbitrary external call -- no platformTarget validation | **FIXED** -- `approvedPlatforms` allowlist + `_validatePlatformTarget()` |
| H-01: ERC-1155 incompatibility with outcome tokens | **FIXED** -- `buyWithFeeAndSweepERC1155()` + `ERC1155Holder` inheritance |
| H-02: `buyWithFee()` missing outcome token sweep | **FIXED** -- NatSpec corrected with WARNING; separate sweep functions provided |
| H-03: Missing slippage and deadline protection | **FIXED** -- `deadline` on all 3 buy functions; `minOutcome` on sweep functions |
| M-01: Fee-on-transfer token accounting mismatch | **FIXED** -- Balance-before/after in `_executeTrade()` with `FeeOnTransferNotSupported` revert |
| M-02: Donation attack on outcome token sweep | **FIXED** -- Delta-based sweep (balance-before/after) in both sweep functions |
| M-03: Gas griefing via unbounded external call | **FIXED** -- `gasleft() - GAS_RESERVE` caps forwarded gas |
| M-04: No contract existence check on platformTarget | **FIXED** -- `platformTarget.code.length > 0` in `_validatePlatformTarget()` |

| Round 6 Finding | Status |
|-----------------|--------|
| LOW-01: `feeCollector` mutable without timelock | **OPEN** (now `feeVault` -- still no timelock; see M-01 below) |
| LOW-02: No ERC-1155 rescue function | **OPEN** (see L-01 below) |
| LOW-03: Gas reserve subtraction could show unhelpful error | **OPEN** (accepted risk; see I-03 below) |
| LOW-04: Platform approval does not check code length | **ACCEPTED** -- Runtime check in `_validatePlatformTarget()` is sufficient |

**Round 7 findings:**

This round identifies **zero Critical or High** issues. The contract has matured
significantly across three audit rounds. The remaining findings are Medium, Low,
and Informational severity, focused on operational gaps (missing timelock,
missing pause, missing ERC-1155 rescue) and minor consistency issues with
sibling contracts.

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 5 |

---

## Findings Summary Table

| ID | Severity | Title | Location | Status |
|----|----------|-------|----------|--------|
| M-01 | Medium | `feeVault` is mutable without timelock -- instant fee redirection | `setFeeVault()` L190-198 | NEW (carried from R6 LOW-01, upgraded) |
| M-02 | Medium | No pause mechanism for emergency response | Entire contract | NEW |
| L-01 | Low | No rescue function for stuck ERC-1155 tokens | `rescueTokens()` L417-423 | CARRIED (R6 LOW-02) |
| L-02 | Low | `renounceOwnership()` reuses `InvalidFeeVault` error | `renounceOwnership()` L442-444 | NEW |
| L-03 | Low | `platformData` can encode self-approvals via approved platform contracts | `_executeTrade()` L552-554 | NEW |
| L-04 | Low | No minimum trade amount -- dust trades yield zero fees | `_validateTradeParams()` L600-626 | NEW |
| I-01 | Info | `setFeeVault()` accepts `address(this)` as new vault | `setFeeVault()` L190-198 | NEW |
| I-02 | Info | `setPlatformApproval()` does not check code length at approval time | `setPlatformApproval()` L207-214 | CARRIED (R6 LOW-04, downgraded) |
| I-03 | Info | Gas reserve underflow produces unhelpful error message | `_executeTrade()` L550 | CARRIED (R6 LOW-03) |
| I-04 | Info | Fee cap inconsistency with OmniFeeRouter (10% vs 5%) | Constructor L171-174 | CARRIED (R2 I-01) |
| I-05 | Info | `TradeExecuted` event missing deadline and minOutcome parameters | Events L81-88 | NEW |

---

## Architecture Review

### Inheritance Chain

```
OmniPredictionRouter
  +-- Ownable2Step (via Ownable)   -- Two-step ownership transfer
  +-- ReentrancyGuard              -- Reentrancy protection on all entry points
  +-- ERC1155Holder                -- Receive ERC-1155 outcome tokens
  +-- ERC2771Context               -- Meta-transaction / gasless relay support
```

### State Variables

| Variable | Mutability | Access | Purpose |
|----------|------------|--------|---------|
| `MAX_FEE_BPS` | Immutable | Public | Fee cap in basis points (hard-capped at 1000 = 10%) |
| `BPS_DENOMINATOR` | Constant | Private | 10,000 |
| `GAS_RESERVE` | Constant | Private | 50,000 gas reserved for post-call operations |
| `feeVault` | Mutable | Public | UnifiedFeeVault address (owner-changeable) |
| `approvedPlatforms` | Mutable | Public | Mapping of allowlisted platform addresses |

### External Call Surface

1. **Collateral token** (ERC-20): `safeTransferFrom`, `balanceOf`, `safeTransfer`, `forceApprove` -- all via SafeERC20
2. **Platform target** (arbitrary contract): Low-level `.call{gas: gasForCall}(platformData)` -- protected by allowlist, code check, nonReentrant
3. **Outcome token ERC-20**: `balanceOf`, `safeTransfer` -- in `buyWithFeeAndSweep()`
4. **Outcome token ERC-1155**: `balanceOf`, `safeTransferFrom` -- in `buyWithFeeAndSweepERC1155()`

### Token Flow Diagram

```
User                  Router                  FeeVault        Platform
  |                     |                        |               |
  |-- totalAmount ----->|                        |               |
  |                     |-- feeAmount ---------->|               |
  |                     |-- approve(netAmount) ----------------->|
  |                     |-- call(platformData) ----------------->|
  |                     |-- forceApprove(0) -------------------->|
  |                     |                        |               |
  |<-- outcome tokens --|  (sweep delta)         |               |
```

---

## Detailed Findings

### [M-01] `feeVault` Is Mutable Without Timelock -- Instant Fee Redirection

**Severity:** Medium
**Location:** Lines 190-198
**Prior Reference:** Round 6 LOW-01 (upgraded to Medium for pre-mainnet)

```solidity
function setFeeVault(
    address feeVault_
) external onlyOwner {
    if (feeVault_ == address(0)) revert InvalidFeeVault();
    address oldVault = feeVault;
    feeVault = feeVault_;
    emit FeeVaultUpdated(oldVault, feeVault_);
}
```

**Description:**

A compromised or malicious owner can instantly redirect all future fees to an
arbitrary address with a single transaction. While the contract's NatSpec
acknowledges this ("Pioneer Phase: no timelock"), the sibling contract
`OmniFeeRouter` has already implemented a 24-hour timelock via
`proposeFeeCollector()` / `applyFeeCollector()` (added in Round 6). The
prediction router lags behind this security improvement.

Since fees are forwarded atomically (never held between transactions), the
blast radius is limited to fees collected after the malicious change. However,
if the router processes significant volume, even a brief redirection window
could cause material loss.

**Impact:** Medium. A compromised owner key can steal all fees from the point
of change forward. No retroactive impact on previously collected fees.

**Recommendation:**

Implement a timelock pattern matching OmniFeeRouter:

```solidity
uint256 public constant FEE_VAULT_DELAY = 24 hours;
address public pendingFeeVault;
uint256 public feeVaultChangeTime;

function proposeFeeVault(address newVault) external onlyOwner {
    if (newVault == address(0)) revert InvalidFeeVault();
    pendingFeeVault = newVault;
    feeVaultChangeTime = block.timestamp + FEE_VAULT_DELAY;
    emit FeeVaultProposed(newVault, feeVaultChangeTime);
}

function applyFeeVault() external onlyOwner {
    if (block.timestamp < feeVaultChangeTime) revert TimelockNotExpired();
    if (pendingFeeVault == address(0)) revert NoPendingChange();
    address old = feeVault;
    feeVault = pendingFeeVault;
    pendingFeeVault = address(0);
    emit FeeVaultUpdated(old, feeVault);
}
```

---

### [M-02] No Pause Mechanism for Emergency Response

**Severity:** Medium
**Location:** Entire contract

**Description:**

The contract has no pause mechanism. If a vulnerability is discovered in an
approved platform, or if the fee vault is compromised, there is no way to
halt trading through the router while a fix is prepared. The only mitigation
is to revoke all platform approvals one by one, which is slow and
gas-expensive if many platforms are approved.

The sibling contract `UnifiedFeeVault` inherits `PausableUpgradeable`, and
`OmniFeeRouter` was flagged for the same missing pause in its Round 7 audit
(M-02). Consistency across the fee infrastructure is important.

**Impact:** Medium. During an active exploit, the inability to pause all
operations with a single transaction extends the attack window.

**Recommendation:**

Add `Pausable` from OpenZeppelin and apply `whenNotPaused` to all three
buy functions:

```solidity
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OmniPredictionRouter is Ownable2Step, ReentrancyGuard,
    ERC1155Holder, ERC2771Context, Pausable {

    function buyWithFee(...) external nonReentrant whenNotPaused { ... }
    function buyWithFeeAndSweep(...) external nonReentrant whenNotPaused { ... }
    function buyWithFeeAndSweepERC1155(...) external nonReentrant whenNotPaused { ... }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

---

### [L-01] No Rescue Function for Stuck ERC-1155 Tokens

**Severity:** Low
**Location:** Lines 417-423
**Prior Reference:** Round 6 LOW-02

```solidity
function rescueTokens(address token) external nonReentrant onlyOwner {
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(feeVault, balance);
        emit TokensRescued(token, balance);
    }
}
```

**Description:**

`rescueTokens()` only handles ERC-20 tokens. If ERC-1155 outcome tokens
(Polymarket CTF, Omen ConditionalTokens) become stuck in the contract --
for example due to a failed sweep where the transaction still succeeds on
the platform side but the sweep reverts in a try/catch (not currently used,
but possible in future modifications) -- there is no mechanism to recover
them.

The contract inherits `ERC1155Holder` and can receive ERC-1155 tokens via
direct `safeTransferFrom` calls from any address. While unlikely in normal
operation, a misdirected transfer could permanently lock ERC-1155 tokens.

**Impact:** Low. The sweep mechanism should prevent tokens from getting stuck
in normal operation. Only edge cases or misdirected transfers are affected.

**Recommendation:**

Add an ERC-1155 rescue function:

```solidity
function rescueERC1155(
    address token,
    uint256 tokenId
) external nonReentrant onlyOwner {
    uint256 balance = IERC1155(token).balanceOf(address(this), tokenId);
    if (balance > 0) {
        IERC1155(token).safeTransferFrom(
            address(this), feeVault, tokenId, balance, ""
        );
        emit TokensRescued(token, balance); // Consider a separate event
    }
}
```

---

### [L-02] `renounceOwnership()` Reuses `InvalidFeeVault` Error

**Severity:** Low
**Location:** Lines 442-444

```solidity
function renounceOwnership() public pure override {
    revert InvalidFeeVault();
}
```

**Description:**

The `renounceOwnership()` function correctly always reverts to prevent
accidental ownership loss, but it reuses the `InvalidFeeVault` error which
is semantically unrelated. Callers and monitoring tools will see a confusing
error message when attempting to renounce ownership.

The sibling contract `OmniFeeRouter` has the same issue (Round 7 L-03 on
that contract), using `InvalidFeeCollector` instead of a dedicated error.

**Impact:** Low. Functional behavior is correct (always reverts). Only the
error message is misleading.

**Recommendation:**

Add a dedicated error:

```solidity
error OwnershipRenouncementDisabled();

function renounceOwnership() public pure override {
    revert OwnershipRenouncementDisabled();
}
```

---

### [L-03] `platformData` Can Encode Self-Approvals via Approved Platform Contracts

**Severity:** Low
**Location:** Lines 552-554

```solidity
(bool success, bytes memory returnData) = platformTarget.call{
    gas: gasForCall
}(platformData);
```

**Description:**

While the contract correctly prevents calling the collateral token directly
as a platform target (line 576-578) and prevents calling itself (line 579-581),
the `platformData` is entirely user-controlled. If an approved platform contract
has a generic `execute()` or `multicall()` function that itself makes arbitrary
external calls, an attacker could construct `platformData` that instructs the
approved platform to call the collateral token's `approve()` function, granting
the attacker an allowance on the router's balance.

This is a second-order attack that requires:
1. An approved platform with a generic execution capability
2. The platform not having its own validation on nested calls
3. The router holding a collateral balance (normally zero between transactions)

The `forceApprove(platformTarget, 0)` reset on line 558 only resets the
router's approval TO the platform, not any approvals the platform may have
granted on the router's behalf via delegated calls.

**Impact:** Low. The attack requires a vulnerable approved platform and the
router to hold funds (which it does not between transactions). The platform
allowlist, combined with the router's transient balance, makes exploitation
highly unlikely.

**Recommendation:**

Document this trust assumption in the NatSpec: approved platforms must not
expose generic execution/multicall capabilities that could be abused to
redirect the router's collateral token approvals. Platform vetting should
include this check during the approval process.

---

### [L-04] No Minimum Trade Amount -- Dust Trades Yield Zero Fees

**Severity:** Low
**Location:** Lines 600-626

**Description:**

There is no minimum `totalAmount` enforced. For very small trade amounts
(e.g., 1 wei with `MAX_FEE_BPS = 200`), the fee cap calculation
`(1 * 200) / 10000 = 0` truncates to zero, allowing zero-fee trades. While
not exploitable for profit (the user still pays gas), it could be used to
bypass fee collection on tiny trades or for gas-griefing the platform.

The sibling contract `OmniFeeRouter` enforces `MIN_SWAP_AMOUNT = 1e15` (added
in Round 6 M-03). OmniPredictionRouter lacks this minimum.

**Impact:** Low. Zero-fee dust trades waste gas but do not extract value.
The concern is consistency with OmniFeeRouter's approach.

**Recommendation:**

Add a minimum trade amount:

```solidity
uint256 public constant MIN_TRADE_AMOUNT = 1e15;

// In _validateTradeParams:
if (totalAmount < MIN_TRADE_AMOUNT) revert ZeroAmount(); // or new error
```

---

### [I-01] `setFeeVault()` Accepts `address(this)` as New Vault

**Severity:** Informational
**Location:** Lines 190-198

**Description:**

`setFeeVault()` validates against `address(0)` but does not prevent setting
the fee vault to the router's own address. If set, fees would accumulate in
the router and could only be extracted via `rescueTokens()`. While not
harmful (it is a reversible owner action), it could cause confusion.

**Recommendation:**

Consider adding: `if (feeVault_ == address(this)) revert InvalidFeeVault();`

---

### [I-02] `setPlatformApproval()` Does Not Check Code Length at Approval Time

**Severity:** Informational
**Location:** Lines 207-214
**Prior Reference:** Round 6 LOW-04 (downgraded)

**Description:**

An EOA can be added to the `approvedPlatforms` mapping. However, this is
fully mitigated by the runtime check in `_validatePlatformTarget()` (line
583: `platformTarget.code.length == 0` triggers `PlatformNotContract`).
No trade can execute against a codeless address.

The only residual concern is a CREATE2-based attack where an attacker
pre-computes an address, gets it approved while it has no code, then deploys
a malicious contract to that address. However, since `setPlatformApproval()`
is `onlyOwner`, this requires a compromised owner key.

**Recommendation:** Accepted as-is. Runtime validation is sufficient.

---

### [I-03] Gas Reserve Underflow Produces Unhelpful Error Message

**Severity:** Informational
**Location:** Line 550
**Prior Reference:** Round 6 LOW-03

```solidity
uint256 gasForCall = gasleft() - GAS_RESERVE;
```

**Description:**

If `gasleft() < GAS_RESERVE` (50,000), the subtraction reverts due to
Solidity 0.8.24 checked arithmetic. The revert reason is a generic
`Arithmetic operation underflowed or overflowed` rather than a descriptive
error. However, the outcome is correct -- the transaction would not have
enough gas to complete anyway.

**Recommendation:** Accepted as-is. The correct outcome (revert) occurs.
For improved UX, consider:

```solidity
if (gasleft() <= GAS_RESERVE) revert InsufficientGas();
```

---

### [I-04] Fee Cap Inconsistency with OmniFeeRouter (10% vs 5%)

**Severity:** Informational
**Location:** Constructor lines 171-174
**Prior Reference:** Round 2 I-01

**Description:**

OmniPredictionRouter hard-caps `maxFeeBps` at 1000 (10%), while OmniFeeRouter
hard-caps at 500 (5%). This inconsistency across the OmniBazaar fee router
family may confuse integrators. Both contracts allow the deployer to set any
value below the hard cap, so the actual fee cap can be aligned at deployment
time.

**Recommendation:** Consider aligning hard caps or documenting the rationale
for the difference (prediction markets may warrant higher maximum fees).

---

### [I-05] `TradeExecuted` Event Missing Deadline and minOutcome Parameters

**Severity:** Informational
**Location:** Lines 74-88

```solidity
event TradeExecuted(
    address indexed user,
    address indexed collateral,
    uint256 totalAmount,
    uint256 feeAmount,
    uint256 netAmount,
    address indexed platform
);
```

**Description:**

The `TradeExecuted` event does not include `deadline` or `minOutcome`
parameters. Off-chain monitoring systems cannot determine what slippage or
deadline protection the user requested for a given trade. The OmniFeeRouter
has the same gap (Round 7 I-02 on that contract).

Adding these fields would consume marginal additional gas but improve
auditability and analytics.

**Recommendation:** Consider extending the event or adding a separate
`TradeParameters` event:

```solidity
event TradeExecuted(
    address indexed user,
    address indexed collateral,
    uint256 totalAmount,
    uint256 feeAmount,
    uint256 netAmount,
    address indexed platform,
    uint256 deadline       // NEW
);
```

---

## Access Control Map

| Function | Modifier | Who Can Call | Risk |
|----------|----------|-------------|------|
| `buyWithFee()` | `nonReentrant` | Any address | Low (allowlisted platforms only) |
| `buyWithFeeAndSweep()` | `nonReentrant` | Any address | Low (allowlisted platforms only) |
| `buyWithFeeAndSweepERC1155()` | `nonReentrant` | Any address | Low (allowlisted platforms only) |
| `setFeeVault()` | `onlyOwner` | Owner only | Medium (no timelock) |
| `setPlatformApproval()` | `onlyOwner` | Owner only | Medium (no timelock) |
| `rescueTokens()` | `onlyOwner` + `nonReentrant` | Owner only | Low |
| `renounceOwnership()` | None (pure) | N/A (always reverts) | None |
| `transferOwnership()` | `onlyOwner` | Owner only | Low (two-step) |
| `acceptOwnership()` | Pending owner check | Pending owner only | Low |
| `supportsInterface()` | None (view) | Any address | None |

### Single-Key Maximum Damage Analysis

If the owner key is compromised, the attacker can:

1. **Redirect fees** via `setFeeVault()` -- all future fees go to attacker (M-01)
2. **Approve malicious platforms** via `setPlatformApproval()` -- users who
   trust the router may interact with malicious platform contracts
3. **Steal rescued tokens** via `rescueTokens()` after changing fee vault

**Cannot:**
- Steal funds in transit (atomic execution, no funds held between txs)
- Modify the fee cap (immutable)
- Mint or burn tokens
- Upgrade the contract (not upgradeable)

**Centralization Risk Rating:** 4/10

The owner has meaningful power over fee direction and platform approval.
The immutable fee cap and non-upgradeable design limit the blast radius.
Adding timelocks (M-01) would reduce this to 2/10.

---

## Reentrancy Analysis

| Entry Point | Guard | External Calls After State Changes | Safe? |
|-------------|-------|------------------------------------|-------|
| `buyWithFee()` | `nonReentrant` | Platform `.call()`, `forceApprove(0)` | Yes |
| `buyWithFeeAndSweep()` | `nonReentrant` | Platform `.call()`, outcome `balanceOf`, `safeTransfer` | Yes |
| `buyWithFeeAndSweepERC1155()` | `nonReentrant` | Platform `.call()`, outcome `balanceOf`, `safeTransferFrom` | Yes |
| `rescueTokens()` | `nonReentrant` | `safeTransfer` to feeVault | Yes |
| `onERC1155Received()` | None (inherited) | None (just returns selector) | Yes |
| `onERC1155BatchReceived()` | None (inherited) | None (just returns selector) | Yes |

The `nonReentrant` guard on all user-facing functions prevents cross-function
reentrancy. The ERC-1155 callback functions (`onERC1155Received`,
`onERC1155BatchReceived`) inherited from `ERC1155Holder` simply return the
selector bytes and do not modify state, so they are safe without reentrancy
guards.

**Assessment:** No reentrancy risk identified.

---

## DeFi-Specific Analysis

### Sandwich / MEV Attack Protection

- **Deadline parameter:** All three buy functions accept a `deadline` parameter
  that reverts if `block.timestamp > deadline`. This prevents stale transactions
  from executing at unfavorable prices.
- **Slippage protection:** `buyWithFeeAndSweep()` and
  `buyWithFeeAndSweepERC1155()` accept `minOutcome` for minimum output
  enforcement. `buyWithFee()` relies on the underlying platform's slippage
  protection encoded in `platformData`.
- **Fee cap immutability:** The fee percentage cannot be dynamically manipulated.

**Assessment:** Adequate MEV protection for a routing contract.

### Oracle Manipulation

Not applicable. The contract does not use price oracles. All amounts are
user-specified and validated against an immutable cap.

### Flash Loan Attack

Not applicable. The contract does not custody funds between transactions.
There is no flash-loan-exploitable state.

### Front-Running

- Platform calls use user-specified `platformData`. A front-runner who sees the
  mempool transaction can sandwich the underlying platform trade (e.g., buy
  before, sell after on Polymarket). This is a property of the underlying
  prediction market, not the router.
- The `deadline` parameter limits the front-running window.
- Fee amounts are calculated off-chain and validated on-chain -- no
  front-running opportunity on the fee itself.

**Assessment:** The router does not introduce additional front-running risk
beyond what exists on the underlying platforms.

### Donation Attack

- **ERC-20 outcome tokens:** `buyWithFeeAndSweep()` uses balance-before/after
  delta (lines 310-321). Pre-donated tokens are excluded from the sweep.
- **ERC-1155 outcome tokens:** `buyWithFeeAndSweepERC1155()` uses the same
  delta pattern (lines 378-394).
- **Collateral tokens:** `_executeTrade()` uses balance-before/after to detect
  fee-on-transfer tokens (lines 531-539). Pre-donated collateral is not
  accessible to callers.

**Assessment:** Donation attacks are fully mitigated via delta-based accounting.

### Fee-on-Transfer Tokens

The balance-before/after check in `_executeTrade()` (lines 531-539) explicitly
detects and reverts on fee-on-transfer tokens with `FeeOnTransferNotSupported`.
This prevents under-collateralized trades.

**Assessment:** Correctly handled.

---

## ERC-2771 (Meta-Transaction) Analysis

The contract inherits `ERC2771Context` for gasless relay support. The
`_msgSender()`, `_msgData()`, and `_contextSuffixLength()` overrides correctly
resolve the diamond inheritance conflict between `Context` (via `Ownable`) and
`ERC2771Context`.

**Key considerations:**

1. **Trusted forwarder is immutable:** Set at deployment via constructor
   parameter. Cannot be changed post-deployment, which prevents the owner from
   swapping in a malicious forwarder. Setting `address(0)` disables relay.

2. **Owner functions use `_msgSender()`:** `setFeeVault()` and
   `setPlatformApproval()` use the `onlyOwner` modifier from `Ownable2Step`,
   which checks `_msgSender()` (the ERC-2771 resolved sender). This means the
   owner can perform admin functions via relay, which is the expected behavior.

3. **User functions use `_msgSender()`:** `buyWithFee()` and sweep variants
   correctly use `_msgSender()` to identify the actual user, allowing gasless
   prediction market trades.

**Assessment:** ERC-2771 integration is correct and secure.

---

## Platform Target Validation Review

`_validatePlatformTarget()` (lines 568-586) performs five checks:

| Check | Purpose | Bypass Risk |
|-------|---------|-------------|
| `!= address(0)` | Prevent null target | None |
| `approvedPlatforms[target]` | Allowlist enforcement | Owner compromise |
| `!= collateralToken` | Prevent token self-calls | None |
| `!= address(this)` | Prevent self-reentrancy | None |
| `code.length > 0` | Prevent EOA calls | CREATE2 (owner compromise needed) |

**Missing check:** `platformTarget != feeVault` is not validated. If the
feeVault address is also an approved platform, a user could craft
`platformData` to call functions on the feeVault. However, since feeVault
approval is owner-controlled and the feeVault (UnifiedFeeVault) is a separate
contract with its own access controls, this is not exploitable in practice.

**Assessment:** Platform target validation is comprehensive and sufficient.

---

## Approval Management Review

### Token Approvals

1. **Pre-call:** `forceApprove(platformTarget, netAmount)` (line 547)
2. **Post-call:** `forceApprove(platformTarget, 0)` (line 558)

The use of `forceApprove()` (OpenZeppelin SafeERC20) correctly handles tokens
like USDT that require approval to be set to zero before setting a new value.
The post-call reset to zero prevents lingering approvals.

**Edge case:** If the platform call reverts, the entire transaction reverts
(including the approval), so no lingering approval is left. If the platform
call succeeds but consumes only a portion of the approval, the post-call
reset handles the remainder.

**Assessment:** Approval management is correct.

---

## Gas Analysis

| Operation | Estimated Gas | Notes |
|-----------|--------------|-------|
| `buyWithFee()` (typical) | ~80,000-120,000 | Depends on platform call |
| `buyWithFeeAndSweep()` (typical) | ~100,000-150,000 | Additional balanceOf + transfer |
| `buyWithFeeAndSweepERC1155()` (typical) | ~110,000-160,000 | ERC-1155 balanceOf + safeTransferFrom |
| `setFeeVault()` | ~30,000 | Storage write + event |
| `setPlatformApproval()` | ~28,000 | Storage write + event |
| `rescueTokens()` | ~40,000 | BalanceOf + transfer + event |

The `GAS_RESERVE` of 50,000 is adequate for post-call operations:
- `forceApprove(0)`: ~5,000-7,000 gas
- `balanceOf`: ~2,600 gas
- `safeTransfer` / `safeTransferFrom`: ~10,000-35,000 gas
- Event emission: ~3,000-5,000 gas
- Total: ~20,600-49,600 gas

The reserve is tight for ERC-1155 sweeps but should be sufficient given that
`safeTransferFrom` with a warm storage slot is on the lower end.

**Assessment:** Gas usage is reasonable. The GAS_RESERVE is marginally
sufficient.

---

## Test Coverage Assessment

The test suite covers 81 tests across the following categories:

| Category | Tests | Coverage |
|----------|-------|----------|
| Constructor validation | 4 | Complete |
| Constructor boundary values | 4 | Complete |
| Immutable getters | 2 | Complete |
| `setPlatformApproval()` | 6 | Complete |
| Platform approval edge cases | 5 | Complete |
| `buyWithFee()` input validation | 8 | Complete |
| `buyWithFee()` successful execution | 4 | Complete |
| `buyWithFee()` platform call failure | 2 | Complete |
| `buyWithFeeAndSweep()` | 5 | Complete |
| `buyWithFeeAndSweepERC1155()` | 4 | Complete |
| `setFeeVault()` | 6 | Complete |
| Ownership (Ownable2Step) | 4 | Complete |
| `rescueTokens()` | 8 | Complete |
| ERC-1155 receiver support | 3 | Complete |
| Fee cap boundary tests | 3 | Complete |
| Deadline edge cases | 4 | Complete |
| PlatformNotContract (M-04) | 1 | Complete |
| Fee-on-transfer rejection (M-01) | 1 | Complete |
| Multiple trades by different users | 2 | Complete |
| **Subtotal** | **81** | **All passing** |

**Missing test coverage:**

1. ERC-2771 meta-transaction flow (gasless relay via trusted forwarder)
2. `supportsInterface()` for non-supported interface IDs (returns false)
3. Concurrent trades from the same user (allowance exhaustion)
4. Donation attack prevention (pre-loading outcome tokens before sweep)
5. Gas reserve boundary (transaction with barely enough gas)

---

## Comparison with OmniFeeRouter

Both contracts serve as fee-collecting routers and should maintain consistent
security posture. Current gaps:

| Feature | OmniFeeRouter | OmniPredictionRouter | Delta |
|---------|--------------|---------------------|-------|
| Fee vault timelock | 24h timelock | None (instant) | **Gap** |
| Pause mechanism | No | No | Consistent |
| Router/platform allowlist | Yes (`allowedRouters`) | Yes (`approvedPlatforms`) | Consistent |
| Minimum trade amount | `1e15` | None | **Gap** |
| Fee counter | `totalFeesCollected` | None | Minor gap |
| Code existence check | Yes | Yes | Consistent |
| FoT detection | Yes | Yes | Consistent |
| Gas reserve | No | Yes (50k) | Prediction is better |
| ERC-1155 support | N/A | Yes | N/A |
| Hard fee cap | 500 (5%) | 1000 (10%) | Inconsistent |

---

## Conclusion

OmniPredictionRouter has matured significantly across three audit rounds. All
Critical, High, and Medium findings from Rounds 2 and 6 have been properly
remediated. The contract demonstrates solid security practices including
platform allowlisting, immutable fee caps, fee-on-transfer detection,
donation attack mitigation, gas reserve protection, and comprehensive input
validation.

The two Medium findings (missing timelock on `setFeeVault`, missing pause
mechanism) represent operational gaps that should be addressed before
multi-sig handoff but are acceptable for the Pioneer Phase. The Low and
Informational findings are minor consistency and usability improvements.

**Overall Risk Assessment: LOW**

The contract is suitable for Pioneer Phase deployment. Before multi-sig
handoff and full mainnet operation, the timelock (M-01) and pause mechanism
(M-02) should be implemented.

### Remediation Priority

| Priority | Finding | Effort |
|----------|---------|--------|
| 1 | M-01: Add timelock to `setFeeVault()` | ~30 lines |
| 2 | M-02: Add `Pausable` to all buy functions | ~10 lines |
| 3 | L-01: Add `rescueERC1155()` function | ~15 lines |
| 4 | L-02: Add dedicated `OwnershipRenouncementDisabled` error | ~3 lines |
| 5 | L-04: Add `MIN_TRADE_AMOUNT` constant | ~5 lines |
| 6 | L-03: Document platform vetting requirements | NatSpec only |

---

*Generated by Claude Code Audit Agent (Round 7 Pre-Mainnet)*
*Contract: OmniPredictionRouter.sol | 627 lines | 81 tests passing*
*Previous audits: Round 2 (2026-02-20), Round 6 (2026-03-10)*
