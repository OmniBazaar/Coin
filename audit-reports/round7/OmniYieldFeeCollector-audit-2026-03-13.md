# Security Audit Report: OmniYieldFeeCollector (Round 7 -- Pre-Mainnet)

**Date:** 2026-03-13
**Audited by:** Claude Code Audit Agent (Round 7 Pre-Mainnet)
**Contract:** `Coin/contracts/yield/OmniYieldFeeCollector.sol`
**Solidity Version:** 0.8.24
**Lines of Code:** 251
**Upgradeable:** No
**Handles Funds:** Yes (transient -- pulls yield tokens, deducts fee, forwards in single tx)
**Previous Audits:** Round 1 (2026-02-20), Round 6 (2026-03-10)
**Slither:** Skipped (per audit rules)
**Tests:** 40 passing (`test/yield/OmniYieldFeeCollector.test.js`)

---

## Executive Summary

OmniYieldFeeCollector is a minimal, fully immutable contract that collects a
performance fee on DeFi yield earned through OmniBazaar. Users approve their
yield tokens, call `collectFeeAndForward()`, and the contract atomically
deducts a fee (forwarded to the immutable `feeVault` address, which is the
UnifiedFeeVault) and returns the net yield to the user.

Since Round 6, the contract has been simplified from a three-recipient
70/20/10 split to a single-recipient model that delegates 100% of collected
fees to the UnifiedFeeVault. The vault handles the protocol-standard 70/20/10
distribution internally. This is a sound architectural decision that reduces
this contract's complexity and attack surface, consolidating all fee
distribution logic in a single upgradeable contract (UnifiedFeeVault).

The contract has no admin, no owner, no upgradeability, and no mutable
parameters. Both `feeVault` and `performanceFeeBps` are immutable. The only
privileged function is `rescueTokens()`, restricted to `feeVault`. This is one
of the most trustless contracts in the OmniBazaar protocol.

**Overall Risk Assessment: LOW**

### Solhint Results

```
0 errors, 0 warnings
```

Clean pass. No lint issues.

### Severity Summary

| Severity       | Count |
|----------------|-------|
| Critical       | 0     |
| High           | 0     |
| Medium         | 0     |
| Low            | 3     |
| Informational  | 5     |
| **Total**      | **8** |

### Previous Findings Status

| Round | ID     | Severity | Finding | Status |
|-------|--------|----------|---------|--------|
| R1 | M-01 | Medium | Fee-on-transfer token incompatibility | **FIXED** (balance-before/after pattern, lines 164-173) |
| R1 | M-02 | Medium | Single-recipient fee does not implement 70/20/10 | **FIXED** (delegates to UnifiedFeeVault, which handles 70/20/10 internally) |
| R1 | L-01 | Low | `rescueTokens()` missing event emission | **FIXED** (`TokensRescued` event, line 209) |
| R1 | L-02 | Low | Rebasing token incompatibility | **ACCEPTED** (documented in NatSpec as a limitation) |
| R1 | L-03 | Low | Rounding to zero on dust amounts | **ACCEPTED** (gas cost provides natural protection) |
| R1 | L-04 | Low | DoS if `feeCollector` is token-blacklisted | **MITIGATED** (renamed to `feeVault`; the vault is a contract, not an EOA, so blacklisting is far less likely) |
| R1 | I-01 | Info | Misleading error reuse in `rescueTokens()` | **FIXED** (dedicated `NotFeeVault()` error, line 107) |
| R1 | I-02 | Info | No minimum yield amount | **ACCEPTED** (gas cost is sufficient deterrent) |
| R1 | I-03 | Info | No OmniCore integration | **ACCEPTED** (standalone by design) |
| R1 | I-04 | Info | Solhint style warnings | **FIXED** (0 warnings now) |
| R6 | LOW-01 | Low | FoT tokens create rounding dust risk | **ACCEPTED** (dust recoverable via `rescueTokens()`) |
| R6 | LOW-02 | Low | `rescueTokens()` could interfere with in-flight tx | **N/A** (`nonReentrant` prevents this) |
| R6 | LOW-03 | Low | No ERC-2771/meta-transaction support | **ACCEPTED** (design decision) |
| R6 | LOW-04 | Low | Zero fee possible for very small yield amounts | **ACCEPTED** (same as R1 L-03) |

All prior Critical, High, and Medium findings are resolved or accepted.

---

## Round 7 Findings

### Low Findings

#### [L-01] `FeeCollected` Event Indexes `actualReceived` as Third Indexed Parameter -- Poor Indexing Strategy

**Severity:** Low
**Location:** Lines 72-78

```solidity
event FeeCollected(
    address indexed user,
    address indexed token,
    uint256 indexed actualReceived,  // <-- indexed uint256
    uint256 totalFee,
    uint256 netAmount
);
```

The `actualReceived` parameter is `indexed`, which means it is stored as a
topic hash rather than in the event data. For `uint256` values, indexing is
only useful when callers need to filter by exact value matches. Yield amounts
are highly variable and would almost never be used as a filter criterion. In
contrast, `user` and `token` are correctly indexed because callers commonly
filter events by user address or token address.

Indexing `actualReceived` consumes an event topic slot (max 3 indexed
parameters for non-anonymous events) and makes off-chain log parsing
marginally less convenient, since the raw value is available in topics but not
in the `data` field.

**Impact:** Minor off-chain inconvenience. No on-chain impact. Slightly
higher gas cost for event emission (negligible).

**Recommendation:** Move `indexed` from `actualReceived` to neither of the
remaining fields (they are value fields), or leave all three `uint256` fields
unindexed. This is a best-practice suggestion; no security risk.

---

#### [L-02] `rescueTokens()` Has No Token Address Validation

**Severity:** Low
**Location:** Lines 202-211

```solidity
function rescueTokens(address token) external nonReentrant {
    if (msg.sender != feeVault) {
        revert NotFeeVault();
    }
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
        IERC20(token).safeTransfer(feeVault, balance);
        emit TokensRescued(token, balance);
    }
}
```

If `token` is `address(0)`, the low-level call to `balanceOf` on the zero
address will revert with an opaque error (no contract code at address 0).
While this is not exploitable (it simply reverts), adding an explicit
`if (token == address(0)) revert InvalidTokenAddress()` guard would provide
a clearer error message and consistency with `collectFeeAndForward()` which
already performs this check.

**Impact:** None. The call reverts either way. This is a UX/clarity
improvement.

**Recommendation:** Add `if (token == address(0)) revert InvalidTokenAddress();`
at the start of `rescueTokens()`.

---

#### [L-03] No ERC-2771 Meta-Transaction Support (Repeat from R6)

**Severity:** Low
**Location:** Entire contract (uses `msg.sender` directly)

The contract uses `msg.sender` on lines 167 (in `safeTransferFrom`), 188
(in `safeTransfer` back to user), and 191 (in `FeeCollected` event). Unlike
other OmniBazaar fee contracts that inherit from `ERC2771Context`, this
contract does not support gasless meta-transactions.

The UnifiedFeeVault (the downstream contract) supports ERC-2771. If a gasless
relay is used, the user's actual address is extracted by the vault via
`_msgSender()`. However, the OmniYieldFeeCollector would receive the
forwarder's address as `msg.sender`, not the user's. This means the fee is
pulled from the forwarder (which must hold the approval), and the net yield
is returned to the forwarder.

**Impact:** Users cannot use gasless relay for yield fee collection through
this contract. Yield operations typically involve larger amounts where gas
cost is proportionally insignificant, so this is likely intentional.

**Recommendation:** Accept as design decision. If gasless support is needed
in the future, a new deployment with `ERC2771Context` would be required.

---

### Informational Findings

#### [I-01] Contract Does Not Validate That `feeVault` Is a Contract Address

**Severity:** Informational
**Location:** Constructor, line 127

The constructor checks that `_feeVault != address(0)` but does not verify
that the address contains deployed code (e.g., `_feeVault.code.length > 0`).
If an EOA address is provided as `feeVault`, the contract functions correctly
(fees are transferred to the EOA), but the 70/20/10 distribution that the
UnifiedFeeVault provides would not occur.

Since the fee vault is immutable and set at deployment time, an incorrect
address cannot be corrected. However, deployment scripts and testing should
verify the vault address, and this check is typically considered a deployment
concern rather than a contract concern.

**Impact:** None if deployment is correct. Immutability means a deployment
mistake is permanent.

---

#### [I-02] `totalFeesCollected` Mapping Uses Token Address as Key -- Not Aggregated

**Severity:** Informational
**Location:** Line 59, Line 183

```solidity
mapping(address => uint256) public totalFeesCollected;
```

The `totalFeesCollected` mapping tracks fees per token, which is correct for
multi-token transparency. However, the UnifiedFeeVault additionally tracks a
single `totalFeesCollected` (uint256) aggregated across all tokens (added in
Round 6 FEE-AP-10 fix). The OmniYieldFeeCollector does not provide an
aggregated view.

This is not a vulnerability. Off-chain indexers can aggregate per-token
values. Noting for completeness.

---

#### [I-03] No Minimum Yield Amount Enforcement (Repeat)

**Severity:** Informational
**Location:** Line 160

```solidity
if (yieldAmount == 0) revert ZeroAmount();
```

The contract accepts any non-zero `yieldAmount`, including amounts below the
fee threshold (e.g., 19 wei at 5% fee = 0 fee). The user would pay gas to
collect yield with zero fee deducted. This is not exploitable -- the gas cost
far exceeds any benefit from bypassing fees on dust amounts.

**Recommendation:** Accept as-is. Gas cost provides natural protection.

---

#### [I-04] State Modification Before All External Calls (Partial CEI)

**Severity:** Informational
**Location:** Lines 180-193

```solidity
// Forward entire fee to UnifiedFeeVault
if (totalFee > 0) {
    _distributeFee(token, totalFee);       // External call (safeTransfer)
    totalFeesCollected[token] += totalFee; // State update AFTER external call
}

// Forward net yield to user
if (netAmount > 0) {
    IERC20(token).safeTransfer(msg.sender, netAmount);
}
```

The `totalFeesCollected` state update on line 183 occurs after the external
`_distributeFee()` call on line 182. Strictly speaking, CEI (Checks-Effects-
Interactions) would require all state updates before any external calls.

However, this is fully protected by the `nonReentrant` modifier on the
function. Even if the `feeVault` were a malicious contract that attempted
reentry, the reentrancy guard would block it. Additionally,
`totalFeesCollected` is a tracking variable only (not used in any access
control or balance calculation), so manipulating it has no exploitable effect.

**Impact:** None. The `nonReentrant` guard provides equivalent protection.

---

#### [I-05] Immutable Design is Excellent -- No Changes Needed

**Severity:** Informational (Positive)

All critical parameters are immutable:

- `feeVault` -- cannot be redirected post-deployment
- `performanceFeeBps` -- cannot be increased post-deployment
- No owner, no admin, no access-controlled configuration
- No upgradeability (not UUPS, not transparent proxy)

The only mutable state is `totalFeesCollected`, which is an accounting
variable with no security impact. The `rescueTokens()` function can only
send tokens to the immutable `feeVault` address, preventing rescue theft.

This is the strongest possible trustless guarantee. The contract's behavior
is fully deterministic and cannot be altered by any party after deployment.

---

## Access Control Map

| Function | Access | Modifier | Risk |
|----------|--------|----------|------|
| `collectFeeAndForward()` | Anyone (permissionless) | `nonReentrant` | 1/10 |
| `calculateFee()` | Anyone (view) | None | 0/10 |
| `rescueTokens()` | `feeVault` only | `nonReentrant` | 2/10 |
| `totalFeesCollected()` | Anyone (view) | None | 0/10 |
| `feeVault()` | Anyone (view) | None | 0/10 |
| `performanceFeeBps()` | Anyone (view) | None | 0/10 |

**Roles:**

| Role | Address | Privileges | Risk |
|------|---------|------------|------|
| `feeVault` (immutable) | UnifiedFeeVault contract | Can call `rescueTokens()` to sweep accidentally sent tokens to itself | 2/10 |
| Any user | Any EOA/contract | Can call `collectFeeAndForward()` with their own tokens | 1/10 |

**Single-key maximum damage:** The `feeVault` address can call
`rescueTokens()` to sweep tokens accidentally sent to the contract. However,
the contract never holds user funds between transactions (atomic
pull-deduct-forward), so there are no user funds at risk. The vault cannot
modify the fee percentage, change recipients, or pause the contract.

**Centralization Risk Rating: 1/10** -- effectively trustless.

---

## Reentrancy Analysis

Both external functions (`collectFeeAndForward`, `rescueTokens`) are protected
by the `nonReentrant` modifier from OpenZeppelin's ReentrancyGuard.

**External calls in `collectFeeAndForward()`:**

1. `IERC20(token).balanceOf(address(this))` -- view call (line 164)
2. `IERC20(token).safeTransferFrom(msg.sender, address(this), yieldAmount)` -- pull (line 167)
3. `IERC20(token).balanceOf(address(this))` -- view call (line 173)
4. `IERC20(token).safeTransfer(feeVault, totalFee)` -- fee forward (line 249, via `_distributeFee`)
5. `IERC20(token).safeTransfer(msg.sender, netAmount)` -- net forward (line 188)

All calls use SafeERC20. The `nonReentrant` modifier prevents any reentry
regardless of token behavior. Even if the token has a callback (e.g., ERC-777
`tokensReceived` hook), the reentrancy guard blocks re-invocation.

**Assessment: No reentrancy risk.**

---

## Fee Collection and Distribution Logic Review

### Flow Analysis

1. User approves `yieldAmount` to the collector contract.
2. User calls `collectFeeAndForward(token, yieldAmount)`.
3. Contract measures `balanceBefore` via `balanceOf`.
4. Contract pulls `yieldAmount` via `safeTransferFrom`.
5. Contract measures `actualReceived = balanceOf - balanceBefore`.
6. Fee: `totalFee = (actualReceived * performanceFeeBps) / BPS_DENOMINATOR`.
7. Net: `netAmount = actualReceived - totalFee`.
8. If `totalFee > 0`: transfer fee to `feeVault`, increment `totalFeesCollected`.
9. If `netAmount > 0`: transfer net to user.
10. Emit `FeeCollected`.

### Correctness Verification

**Invariant: `totalFee + netAmount == actualReceived`**

```
totalFee = (actualReceived * performanceFeeBps) / BPS_DENOMINATOR
netAmount = actualReceived - totalFee
=> totalFee + netAmount = totalFee + actualReceived - totalFee = actualReceived
```

The invariant holds for all inputs. No rounding dust is lost -- the user
absorbs any rounding in their favor (fee rounds down, net rounds up).

**Fee-on-Transfer handling:** Correct. The balance-before/after pattern
ensures `actualReceived` reflects the true amount available, regardless of
any transfer tax.

**Overflow safety:** Solidity 0.8.24 has built-in overflow checks. The
maximum `actualReceived * performanceFeeBps` is `type(uint256).max * 1000`,
which would overflow. However, in practice, no ERC20 token has a supply
approaching `type(uint256).max / 1000`, so overflow is not a realistic
concern. For completeness, the maximum safe `actualReceived` is
`type(uint256).max / 10000 = 1.15e73`, far exceeding any real token amount.

### Integration with UnifiedFeeVault

The collector forwards 100% of fees to the UnifiedFeeVault via a simple
`safeTransfer`. The vault does NOT require the collector to have
`DEPOSITOR_ROLE` for this transfer -- the tokens arrive as a direct ERC20
transfer, not through the vault's `deposit()` function.

This means the vault's `distribute()` function will pick up these tokens in
its next call (they appear as undistributed balance). Alternatively, the
collector could be granted `DEPOSITOR_ROLE` and use `deposit()` for better
accounting traceability. The current approach works correctly but relies on
the vault's permissionless `distribute()` being called periodically.

---

## Edge Cases and Attack Vectors

### 1. Zero Fee Bypass

If `actualReceived * performanceFeeBps < BPS_DENOMINATOR`, the fee rounds to
zero. At 500 bps (5%), this occurs for `actualReceived < 20 wei`. The user
gets their full yield with no fee. The gas cost of the transaction (~21,000+
gas minimum) makes this economically irrational to exploit.

### 2. Token Blacklisting of `feeVault`

If the `feeVault` address is blacklisted by a specific token (e.g., USDC's
admin blacklist), the `safeTransfer` to `feeVault` will revert, permanently
blocking fee collection for that token. Since `feeVault` is immutable, there
is no recovery path for that specific token.

**Mitigation:** The `feeVault` is the UnifiedFeeVault contract (not an EOA).
Contract addresses are rarely targeted by token blacklists. Additionally,
the contract would need to be deployed at a new address for the affected
token, which is possible since the collector is non-upgradeable and has no
accumulated state worth preserving (only `totalFeesCollected`, a tracking
variable).

### 3. Malicious Token Attack

If `token` is a malicious contract, the `balanceOf` calls could return
manipulated values. For example, a token could return different values for
`balanceOf` before and after `safeTransferFrom`, inflating `actualReceived`.
However, this would only affect the fee calculation on the malicious token
itself -- no cross-token contamination is possible. Additionally, the
`safeTransfer` calls would fail if the contract does not actually hold the
reported balance.

### 4. ERC-777 Hook Reentrancy

If the yield token is an ERC-777 token (which has `tokensReceived` callbacks),
the `safeTransferFrom` and `safeTransfer` calls could trigger reentrancy.
The `nonReentrant` modifier prevents this.

### 5. Donation Attack / Balance Inflation

An attacker could send tokens directly to the contract (without using
`collectFeeAndForward`) to inflate the `balanceBefore` value. This would NOT
affect `actualReceived` because:

```
actualReceived = balanceAfterTransfer - balanceBefore
```

The donated tokens are included in both `balanceBefore` and
`balanceAfterTransfer`, canceling out. Donated tokens can only be recovered
via `rescueTokens()` (by the `feeVault`).

### 6. Front-Running

No meaningful front-running opportunity exists. Each user processes their own
yield independently. There is no shared state (like a pool or AMM) that would
allow a front-runner to extract value.

### 7. Flash Loan Attack

Not applicable. The contract does not use price oracles, does not have
collateral ratios, and does not perform lending/borrowing. Flash loans provide
no advantage to an attacker.

---

## Upgrade Safety

Not applicable. The contract is not upgradeable. It inherits only from
OpenZeppelin's `ReentrancyGuard` (non-upgradeable version). No proxy pattern
is used. The contract's behavior is permanently fixed at deployment.

If a bug is discovered, a new contract must be deployed. Users simply approve
the new contract and use it instead. No migration is needed because the
contract holds no persistent user state.

---

## Gas Optimization Notes

The contract is already gas-efficient:

- Uses `immutable` for `feeVault` and `performanceFeeBps` (SLOAD replaced by PUSH at runtime)
- Uses custom errors instead of `require` strings
- Uses `SafeERC20` (standard, no unnecessary overhead)
- Minimal storage writes (only `totalFeesCollected` mapping per collection)

No further gas optimizations are recommended.

---

## Test Coverage Assessment

The test suite (`test/yield/OmniYieldFeeCollector.test.js`) contains 40
passing tests covering:

- Constructor validation (zero address, zero fee, fee cap)
- Boundary values (1 bps, 1000 bps, 1001 bps)
- Fee calculation correctness (standard, dust, large amounts)
- Fee collection and forwarding (correct balances, event emission)
- Multi-token independence
- Access control (`rescueTokens` restricted to `feeVault`)
- Precision invariants (`fee + net == actualReceived`)
- Sequential multi-user operation
- Insufficient allowance / balance reverts

**Missing test coverage (suggestions):**

1. Fee-on-transfer token simulation (use a mock FoT token)
2. Reentrancy attempt via ERC-777-like callback
3. `rescueTokens` with `address(0)` as token
4. Very large yield amounts near `type(uint256).max / BPS_DENOMINATOR`

These are edge cases that do not represent security gaps in the contract,
but would strengthen confidence.

---

## Conclusion

OmniYieldFeeCollector is a well-designed, minimal contract with the strongest
possible trustless guarantees in the OmniBazaar ecosystem. Its fully
immutable design eliminates admin key compromise, fee manipulation, and
recipient redirection as attack vectors. All prior Medium findings have been
remediated. The remaining findings are Low and Informational, relating to
event indexing strategy, missing zero-address validation in `rescueTokens()`,
and the absence of meta-transaction support.

The contract is ready for mainnet deployment without modifications.

### Final Summary Table

| ID    | Severity      | Title | Status |
|-------|---------------|-------|--------|
| L-01  | Low           | `FeeCollected` indexes `actualReceived` (poor indexing strategy) | New |
| L-02  | Low           | `rescueTokens()` has no token address validation | New |
| L-03  | Low           | No ERC-2771 meta-transaction support | Repeat from R6, Accepted |
| I-01  | Informational | Constructor does not validate `feeVault` has code | New |
| I-02  | Informational | `totalFeesCollected` is per-token, not aggregated | New |
| I-03  | Informational | No minimum yield amount enforcement | Repeat, Accepted |
| I-04  | Informational | Partial CEI (state update after external call) | New |
| I-05  | Informational | Immutable design is excellent | Positive |

---

*Generated by Claude Code Audit Agent -- Round 7 Pre-Mainnet*
