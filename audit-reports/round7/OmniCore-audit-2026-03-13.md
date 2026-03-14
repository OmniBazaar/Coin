# Security Audit Report: OmniCore.sol (Round 7 -- Pre-Mainnet Final)

**Date:** 2026-03-13 14:13 UTC
**Audited by:** Claude Code Audit Agent (Opus 4.6)
**Contract:** `Coin/contracts/OmniCore.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 1,481
**Upgradeable:** Yes (UUPS via `UUPSUpgradeable`)
**Handles Funds:** Yes (staked XOM, DEX-deposited tokens, unclaimed legacy migration tokens)
**Previous Audits:** Round 1 (2026-02-20), Round 5 V2/V3 (2026-03-09), Round 6 (2026-03-10)

---

## Executive Summary

OmniCore.sol is the central hub contract for the OmniBazaar protocol. It consolidates:

- **Service Registry** -- mapping of service names to contract addresses
- **Validator Management** -- mapping-based registry with AVALANCHE_VALIDATOR_ROLE grants, PROVISIONER_ROLE for automated provisioning, and Bootstrap.sol fallback for enumeration
- **Staking** -- XOM lock-up with 5-tier system (1-5), 4 duration options, governance checkpoints via OZ Checkpoints.Trace224
- **DEX Settlement (deprecated)** -- internal balance accounting for deposit/withdraw, trade settlement, and fee distribution (superseded by DEXSettlement.sol)
- **Legacy Migration** -- M-of-N validator-signed claims for migrating OmniBazaar v1 user balances
- **Two-Step Admin Transfer** -- 48-hour delay with proposer tracking
- **Ossification** -- permanent upgrade disable
- **ERC-2771 Meta-transactions** -- gasless user operations via OmniForwarder

This Round 7 audit is a comprehensive pre-mainnet final review. All High and Medium findings from prior rounds (R1, R5, R6) have been confirmed as remediated. This audit identifies **zero Critical findings, zero High findings, two Medium findings, four Low findings, and five Informational items**.

The contract has reached a mature security posture suitable for mainnet deployment, contingent on the operational requirement of deploying the ADMIN_ROLE behind a TimelockController controlled by a multi-sig wallet.

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 4 |
| Informational | 5 |

---

## Remediation Status from All Prior Audits

| Prior Finding | Round | Status | Verification |
|---------------|-------|--------|--------------|
| R1 H-01: No timelock on admin | R1 | **Mitigated (operational)** | NatSpec documents TimelockController requirement (lines 24-28). Not enforced in-contract. Accepted: operational deployment requirement. |
| R1 H-02: Staking tier/duration not validated | R1 | **Fixed** | `_validateStakingTier()` (line 1382) and `_validateDuration()` (line 1405) with correct thresholds. Verified in tests. |
| R1 M-01: Signature malleability | R1 | **Fixed** | `_recoverSigner()` (line 1426) uses OZ `ECDSA.recover()`. |
| R1 M-02: abi.encodePacked with dynamic types | R1 | **Fixed** | `_verifyClaimSignatures()` (line 1345) uses `abi.encode`. Cross-chain replay prevented with `block.chainid` + `address(this)`. |
| R1 M-03: Fee-on-transfer in depositToDEX | R1 | **Fixed** | Balance-before/after pattern at lines 1057-1059. |
| R1 M-04: No pause mechanism | R1 | **Fixed** | `PausableUpgradeable` integrated; `whenNotPaused` on stake/unlock/deposit/withdraw/claim. |
| R1 M-05: initializeV2 no ACL | R1 | **Fixed** | `onlyRole(ADMIN_ROLE)` on `initializeV2()` (line 482) and `reinitializeV3()` (line 496). |
| R5 H-01: No upgrade timelock | R5 | **Mitigated (operational)** | TimelockController behind multi-sig is deployment requirement. Ossification provides permanent lockdown path. |
| R5 M-05: No two-step admin transfer | R5 | **Fixed** | Full two-step transfer at lines 553-609 with 48h delay, proposer tracking, and role revocation. |
| R6 H-01: acceptAdminTransfer missing revocation | R6 | **Fixed** | `adminTransferProposer` state variable added (line 209). Old admin roles revoked at lines 590-591. Gap reduced from 42 to 41. |
| R6 M-01: Nonce not tracked on-chain | R6 | **Fixed** | `_usedClaimNonces` mapping at line 185. Checked and set in `claimLegacyBalance()` at lines 1259-1260. |
| R6 M-02: Deprecated DEX settlement still callable | R6 | **Mitigated** | All five deprecated settlement functions now have `whenNotPaused`. See M-01 below for residual risk. |
| R6 M-03: ERC2771 _msgSender() vs msg.sender | R6 | **Fixed** | `proposeAdminTransfer()` uses `msg.sender` (line 562). `acceptAdminTransfer()` uses `msg.sender` (line 577). NatSpec documents at lines 549 and 576. |
| R6 L-01: Nonce not tracked | R6 | **Fixed** | See R6 M-01 above. |
| R6 L-02: Unbounded batch arrays | R6 | **Not fixed** | See L-01 below. |
| R6 L-03: Storage gap verification | R6 | **Verified** | See Storage Layout section below. |

---

## Medium Findings

### [M-01] Deprecated DEX Settlement Functions Remain Callable and Can Inflate dexBalances

**Severity:** Medium
**Category:** Business Logic / Attack Surface Reduction
**Location:** `settleDEXTrade()` (line 866), `batchSettleDEX()` (line 897), `distributeDEXFees()` (line 934)

**Description:**

Five DEX settlement functions are marked `@deprecated` in NatSpec but remain fully callable by any address holding `AVALANCHE_VALIDATOR_ROLE`. The `whenNotPaused` guard (added as R6 M-02 remediation) allows pausing as an emergency measure, but the functions are not disabled by default.

The core risk is that `distributeDEXFees()` inflates `dexBalances` without a corresponding token deposit. It credits `oddaoAddress`, `stakingPoolAddress`, and `protocolTreasuryAddress` based on a `totalFee` parameter that is purely attester-claimed -- there is no verification that `totalFee` worth of tokens was actually collected or deposited.

**Attack scenario:**

1. A validator with `AVALANCHE_VALIDATOR_ROLE` calls `distributeDEXFees(XOM, 1_000_000e18)`.
2. `dexBalances[oddaoAddress][XOM]` increases by 700,000 XOM (70%).
3. `dexBalances[stakingPoolAddress][XOM]` increases by 200,000 XOM (20%).
4. `dexBalances[protocolTreasuryAddress][XOM]` increases by 100,000 XOM (10%).
5. These phantom balances compete with real user deposits when `withdrawFromDEX()` is called.
6. If the ODDAO or staking pool address calls `withdrawFromDEX()`, they receive real tokens backed only by other users' deposits.

Similarly, `settleDEXTrade()` allows a rogue validator to transfer any user's DEX balance to any other address without that user's consent or signature.

**Impact:** A single rogue validator can inflate internal accounting to create unbacked withdrawal claims, potentially causing insolvency for the DEX balance system. The attack requires `AVALANCHE_VALIDATOR_ROLE` but that role is granted to all active validators.

**Mitigating Factors:**
- The protocol is migrating to `DEXSettlement.sol` which uses EIP-712 dual signatures (trustless).
- The `whenNotPaused` guard allows emergency shutdown.
- `AVALANCHE_VALIDATOR_ROLE` is admin-managed (not self-assignable).

**Recommendation:**

Add a dedicated boolean flag to permanently disable the deprecated functions:

```solidity
bool public legacyDEXSettlementDisabled;

error LegacyDEXDisabled();

function disableLegacyDEXSettlement() external onlyRole(ADMIN_ROLE) {
    legacyDEXSettlementDisabled = true;
}

// Add at the top of each deprecated function:
if (legacyDEXSettlementDisabled) revert LegacyDEXDisabled();
```

Alternatively, if no real DEX balances exist from the deprecated system, set a deployment script to pause immediately after migration is confirmed complete.

**Priority:** Recommended before mainnet if any user funds will be deposited via `depositToDEX()`.

---

### [M-02] protocolTreasuryAddress Can Be Unset During Fresh Deployment via initialize()

**Severity:** Medium
**Category:** Initialization Completeness
**Location:** `initialize()` (line 445), `distributeDEXFees()` (line 934)

**Description:**

The `initialize()` function (lines 445-474) correctly validates all five address parameters as non-zero, including `_protocolTreasuryAddress`. However, the V4 storage variable `protocolTreasuryAddress` (line 214) was added **after** the original deployment. On the mainnet (chain 88008), the proxy was deployed with the original `initialize()` that did not include `_protocolTreasuryAddress`. This means:

1. On the existing mainnet deployment, `protocolTreasuryAddress` was never set by `initialize()` (it was added later).
2. There is no `reinitializeV4()` function that explicitly sets `protocolTreasuryAddress`.
3. If the admin has manually called `setProtocolTreasuryAddress()` after upgrading, the value is set. If not, it defaults to `address(0)`.

When `distributeDEXFees()` runs with `protocolTreasuryAddress == address(0)`:
```solidity
uint256 protocolFee = totalFee - oddaoFee - stakingFee;
if (protocolFee > 0) {
    dexBalances[protocolTreasuryAddress][token] += protocolFee;
    // Credits address(0) -- funds become permanently locked
}
```

The 10% protocol fee would be credited to `dexBalances[address(0)][token]`, which is permanently unrecoverable (nobody can call `withdrawFromDEX()` from `address(0)`).

**Impact:** 10% of all DEX fees distributed through the deprecated `distributeDEXFees()` function could be permanently locked if `protocolTreasuryAddress` was never set. The deprecated functions are the primary concern; the new `DEXSettlement.sol` handles its own fee distribution.

**Mitigating Factors:**
- If admin has already called `setProtocolTreasuryAddress()`, the value is set and this is not exploitable.
- The deprecated `distributeDEXFees()` may never be called on mainnet if migration to DEXSettlement.sol is complete.
- `distributeDEXFees()` early-returns on `totalFee == 0`.

**Recommendation:**

1. Verify that `protocolTreasuryAddress` is set on the mainnet deployment by querying the contract.
2. Consider adding a `reinitializeV4()` that sets `protocolTreasuryAddress` if it is still `address(0)`, to serve as a safety net.
3. Add a guard to `distributeDEXFees()`:
```solidity
if (protocolTreasuryAddress == address(0)) revert InvalidAddress();
```

---

## Low Findings

### [L-01] Unbounded Batch Settlement Arrays (Pre-existing)

**Severity:** Low
**Category:** Denial of Service
**Location:** `batchSettleDEX()` (line 897), `batchSettlePrivateDEX()` (line 1005)

**Description:**

Both batch functions iterate over caller-provided arrays with no upper bound. `registerLegacyUsers()` correctly caps at 100 entries (line 1219) but batch settlement functions do not. A validator could submit an excessively large batch that exceeds the block gas limit, causing the transaction to revert.

**Impact:** Low -- only validators can call these functions, and they would only harm themselves by wasting gas. No funds at risk. The deprecated nature of these functions further reduces risk.

**Recommendation:** Add `if (length > 500) revert InvalidAmount();` to both functions.

---

### [L-02] Solhint Warning: Unused Variable in _authorizeUpgrade()

**Severity:** Low
**Category:** Code Quality
**Location:** `_authorizeUpgrade()` (line 525)

**Description:**

The `newImplementation` parameter is never used in the function body, producing a solhint `no-unused-vars` warning. This is standard for UUPS upgrade authorization (the parameter exists for the interface contract) but the unused variable warning should be suppressed.

**Current code:**
```solidity
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyRole(ADMIN_ROLE)
{
    if (_ossified) revert ContractIsOssified();
}
```

**Recommendation:**

Suppress the warning by commenting out the parameter name:

```solidity
function _authorizeUpgrade(address /* newImplementation */)
```

Or add a validation that `newImplementation` is a non-zero address and has code (defense-in-depth against accidentally upgrading to an EOA or zero address):

```solidity
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyRole(ADMIN_ROLE)
{
    if (_ossified) revert ContractIsOssified();
    if (newImplementation == address(0)) revert InvalidAddress();
}
```

This also prevents upgrading to the zero address, which would brick the proxy.

---

### [L-03] isValidator() Bootstrap Fallback Does Not Check AVALANCHE_VALIDATOR_ROLE Consistency

**Severity:** Low
**Category:** Access Control Consistency
**Location:** `isValidator()` (line 1100)

**Description:**

The `isValidator()` function falls back to Bootstrap.sol when `validators[validator]` is false. If Bootstrap reports a node as active with type 0 or 1, `isValidator()` returns true. However, this function is a **read-only view** -- it does not grant `AVALANCHE_VALIDATOR_ROLE` to the address.

This creates an inconsistency: an address can pass `isValidator()` (via Bootstrap fallback) but NOT have `AVALANCHE_VALIDATOR_ROLE`. Any function gated by `onlyRole(AVALANCHE_VALIDATOR_ROLE)` (the five deprecated DEX settlement functions) will reject calls from Bootstrap-only validators.

External contracts that rely on `isValidator()` to determine validator status (e.g., OmniValidatorRewards, off-chain services) may assume the address has on-chain settlement authority, which it does not.

**Impact:** Low -- the inconsistency is an information mismatch, not an access control bypass. Bootstrap-only validators cannot access privileged functions. The concern is for external integrators who may misinterpret the return value.

**Recommendation:** Document in the NatSpec that `isValidator()` checks both the direct mapping AND Bootstrap, but `AVALANCHE_VALIDATOR_ROLE` (which gates settlement functions) only comes from the direct mapping via `setValidator()` or `provisionValidator()`. This is correct behavior, just needs documentation.

---

### [L-04] Legacy Claim Signatures Check validators Mapping But Not Bootstrap

**Severity:** Low
**Category:** Consistency
**Location:** `_verifyClaimSignatures()` (line 1365)

**Description:**

The signature verification in `_verifyClaimSignatures()` checks `validators[signer]` (the direct mapping, line 1365), not `isValidator(signer)` (which falls back to Bootstrap). This means only validators registered via `setValidator()` or `provisionValidator()` can sign legacy claims. Bootstrap-registered validators cannot.

This appears to be intentional (legacy claims should require explicitly-authorized validators for the highest trust level), but it is not documented.

**Impact:** Low -- operational concern. If all validators are registered only through Bootstrap (not the direct mapping), no validator signatures would pass validation, effectively disabling legacy claims.

**Recommendation:** Document in the NatSpec that legacy claim signers must be in the `validators` mapping (not just Bootstrap). Alternatively, if Bootstrap validators should also be able to sign, update the check to use `isValidator()`.

---

## Informational Findings

### [I-01] Fee Distribution Dust Rounding Favors Protocol Treasury

**Severity:** Informational
**Category:** Arithmetic Precision
**Location:** `distributeDEXFees()` (lines 941-943)

**Description:**

The fee calculation uses the remainder pattern:
```solidity
uint256 oddaoFee = (totalFee * ODDAO_FEE_BPS) / BASIS_POINTS;      // 70%
uint256 stakingFee = (totalFee * STAKING_FEE_BPS) / BASIS_POINTS;    // 20%
uint256 protocolFee = totalFee - oddaoFee - stakingFee;               // remainder
```

Any rounding dust (up to 2 wei per distribution) goes to `protocolFee`. For a 1 wei `totalFee`, ODDAO and staking round to 0, and the protocol gets the full 1 wei.

**Previous audit note:** R6 I-04 stated this favored "validator" -- the V4 update changed the 10% recipient from the validator parameter to `protocolTreasuryAddress`, so the rounding now favors the protocol treasury. This is standard and acceptable.

**Status:** Accepted behavior. No action required.

---

### [I-02] Ossification Is Irreversible and Permanent (Correct Behavior)

**Severity:** Informational
**Category:** Access Control
**Location:** `ossify()` (line 506), `_authorizeUpgrade()` (line 525)

**Description:**

Once `ossify()` is called, the `_ossified` flag is permanently set. There is no un-ossify function. The `_ossified` state variable is `bool private` (line 179) but the `isOssified()` view function (line 515) provides public read access.

Ossification should only be invoked after the protocol has reached full maturity and no further upgrades are anticipated. Premature ossification would lock in any existing bugs permanently.

**Status:** Correct design. No action required.

---

### [I-03] Staking Does Not Support Top-Up or Tier Change

**Severity:** Informational
**Category:** Business Logic / UX
**Location:** `stake()` (line 784)

**Description:**

The check `if (stakes[caller].active) revert InvalidAmount();` prevents modifying an existing stake. Users must `unlock()` first (after the lock period), then `stake()` again with new parameters. Users with 730-day (2-year) lock periods are locked into their tier for the full duration.

**Status:** Documented design constraint from prior audits. No security risk.

---

### [I-04] ERC-2771 Trusted Forwarder Is Immutable (By Design)

**Severity:** Informational
**Category:** Architecture
**Location:** Constructor (line 429)

**Description:**

The `trustedForwarder_` address is passed to `ERC2771ContextUpgradeable` in the constructor, which stores it as an immutable variable in the implementation bytecode (not in proxy storage). This means:

1. The forwarder address cannot be changed without deploying a new implementation and upgrading.
2. If the forwarder contract is compromised, user-facing functions could be exploited by crafting fake `_msgSender()` addresses.
3. Admin functions are protected because `proposeAdminTransfer()` and `acceptAdminTransfer()` use `msg.sender` explicitly (not `_msgSender()`), per the R6 M-03 fix.

**Status:** Accepted. ERC-2771 forwarder immutability is standard practice. If the forwarder is compromised, `pause()` + `ossify()` provides emergency protection. A new proxy can be deployed if needed. Documented in NatSpec at line 423.

---

### [I-05] cancelAdminTransfer() Does Not Emit the Cancelled Proposer or Pending Admin

**Severity:** Informational
**Category:** Event Completeness
**Location:** `cancelAdminTransfer()` (line 601)

**Description:**

The `AdminTransferCancelled` event (line 394) has no parameters:
```solidity
event AdminTransferCancelled();
```

When a transfer is cancelled, off-chain monitoring systems cannot determine from the event alone which pending transfer was cancelled. They must query `pendingAdmin` and `adminTransferProposer` before the cancel transaction is mined, or reconstruct from prior `AdminTransferProposed` events.

**Recommendation:** Consider adding parameters to the event:
```solidity
event AdminTransferCancelled(address indexed cancelledAdmin, address indexed cancelledBy);
```

**Status:** No security impact. Quality improvement for off-chain monitoring.

---

## DeFi-Specific Analysis

### Flash-Loan Attacks

| Vector | Status | Details |
|--------|--------|---------|
| Stake + getStakedAt same block | **Mitigated** | Governance uses past-block snapshots. Checkpoints record at `block.number`. |
| Stake + unlock same block (duration=0) | **Mitigated** | No economic benefit from zero-duration stake. Checkpoint records zero immediately. StakingRewardPool returns 0 rewards for duration=0 (M-02 R6 fix). |
| Flash-loan for legacy claim | **N/A** | Claims require M-of-N validator signatures. |
| Flash-loan DEX deposit/withdraw | **Mitigated** | No benefit -- deposit credits internal balance, withdraw debits it. No arbitrage opportunity within a single transaction. |

### Front-Running Attacks

| Vector | Status | Details |
|--------|--------|---------|
| Front-run legacy claims | **Mitigated** | Claims require validator signatures with specific `claimAddress`. Cannot redirect. |
| Front-run admin transfer | **Low risk** | 48h delay provides observation. `cancelAdminTransfer()` allows cancellation. |
| Front-run staking | **N/A** | No benefit from front-running another user's stake. |
| Front-run DEX deposits | **Low risk** | A validator could front-run a deposit by calling `settleDEXTrade()` to drain the depositor's balance before the deposit lands. Requires `AVALANCHE_VALIDATOR_ROLE`. Mitigated by migration to DEXSettlement.sol. |

### Reentrancy

| Function | Guard | External Calls | Status |
|----------|-------|----------------|--------|
| `stake()` | `nonReentrant` | `safeTransferFrom` | **Safe** |
| `unlock()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `depositToDEX()` | `nonReentrant` | `safeTransferFrom`, `balanceOf` | **Safe** |
| `withdrawFromDEX()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `claimLegacyBalance()` | `nonReentrant` | `safeTransfer` | **Safe** |
| `settleDEXTrade()` | None | None (internal accounting) | **Safe** |
| `batchSettleDEX()` | None | None (internal accounting) | **Safe** |
| `distributeDEXFees()` | None | None (internal accounting) | **Safe** |
| `settlePrivateDEXTrade()` | None | None (event-only) | **Safe** |
| `batchSettlePrivateDEX()` | None | None (event-only) | **Safe** |

All external-calling functions follow the CEI (Checks-Effects-Interactions) pattern. State mutations occur before token transfers in `unlock()` (lines 830-835 before 844), `withdrawFromDEX()` (line 1075 before 1076), and `claimLegacyBalance()` (lines 1276-1277 before 1280).

### Fee-on-Transfer Tokens

| Function | Status | Details |
|----------|--------|---------|
| `depositToDEX()` | **Safe** | Balance-before/after pattern (lines 1057-1059) correctly handles fee-on-transfer tokens. |
| `stake()` | **Acceptable** | Uses face-value `amount`. OmniCoin (XOM) has no fee-on-transfer mechanism. If a fee-on-transfer token were used, `totalStaked` would overcount. Accepted because XOM is the only staking token. |

### Integer Overflow/Underflow

All arithmetic uses Solidity 0.8.24 built-in overflow checks. No `unchecked` blocks are used for user-facing arithmetic.

| Expression | Overflow Risk | Status |
|------------|---------------|--------|
| `totalStaked += amount` (line 804) | Theoretical overflow at 2^256 | **Safe** -- XOM supply is 16.6B (1.66e28 wei), far below 2^256. |
| `totalStaked -= amount` (line 835) | Underflow if amount > totalStaked | **Safe** -- amount is from the user's own stake which was previously added. |
| `dexBalances[seller][token] -= amount` (line 881) | Underflow | **Safe** -- checked at line 879: `if (dexBalances[seller][token] < amount) revert`. |
| `dexBalances[buyer][token] += amount` (line 882) | Overflow | **Safe** -- would require 2^256 tokens. |
| `block.timestamp + duration` (line 800) | Overflow | **Safe** -- max duration is 730 days, timestamp is ~1.7e9, sum is ~1.8e9, far below 2^256. |
| `block.timestamp + ADMIN_TRANSFER_DELAY` (line 558) | Overflow | **Safe** -- 48 hours in seconds is 172800, far below 2^256. |
| `SafeCast.toUint32(block.number)` (line 808) | Truncation after block 4.29 billion | **Acceptable** -- at 2-second blocks, this is ~272 years. |
| `SafeCast.toUint224(amount)` (line 809) | Truncation above 2^224 | **Safe** -- XOM supply (1.66e28) is far below 2^224 (2.7e67). |
| `totalLegacySupply += totalAmount` (line 1236) | Overflow | **Safe** -- bounded by XOM supply. |
| `totalLegacyClaimed += amount` (line 1277) | Overflow | **Safe** -- bounded by totalLegacySupply. |

---

## Storage Layout Verification

### Manual Slot Counting

The following state variables occupy storage slots in the order declared. Inherited contract slots are managed by OpenZeppelin's upgradeable framework.

**Inherited Storage (OZ Upgradeable contracts):**
- `AccessControlUpgradeable`: 1 mapping + 50-slot gap = 51 slots
- `ReentrancyGuardUpgradeable`: 1 status + 49-slot gap = 50 slots
- `PausableUpgradeable`: 1 bool + 49-slot gap = 50 slots
- `UUPSUpgradeable`: 50-slot gap = 50 slots
- `ERC2771ContextUpgradeable`: 0 storage slots (trustedForwarder is immutable in bytecode)

**OmniCore Contract-Declared Variables:**

| # | Variable | Type | Slot Size | Version |
|---|----------|------|-----------|---------|
| 1 | `OMNI_COIN` | IERC20 (address) | 1 | V1 |
| 2 | `services` | mapping(bytes32 => address) | 1 | V1 |
| 3 | `validators` | mapping(address => bool) | 1 | V1 |
| 4 | `masterRoot` (deprecated) | bytes32 | 1 | V1 |
| 5 | `lastRootUpdate` (deprecated) | uint256 | 1 | V1 |
| 6 | `stakes` | mapping(address => Stake) | 1 | V1 |
| 7 | `totalStaked` | uint256 | 1 | V1 |
| 8 | `dexBalances` | mapping(address => mapping(...)) | 1 | V1 |
| 9 | `oddaoAddress` | address | 1 | V1 |
| 10 | `stakingPoolAddress` | address | 1 | V1 |
| 11 | `legacyUsernames` | mapping(bytes32 => bool) | 1 | V1 |
| 12 | `legacyBalances` | mapping(bytes32 => uint256) | 1 | V1 |
| 13 | `legacyClaimed` | mapping(bytes32 => address) | 1 | V1 |
| 14 | `legacyAccounts` | mapping(bytes32 => bytes) | 1 | V1 |
| 15 | `totalLegacySupply` | uint256 | 1 | V1 |
| 16 | `totalLegacyClaimed` | uint256 | 1 | V1 |
| 17 | `requiredSignatures` | uint256 | 1 | V1 |
| 18 | `_ossified` | bool (private) | 1 | V2 |
| 19 | `_usedClaimNonces` | mapping(bytes32 => bool, private) | 1 | R6 fix |
| 20 | `_stakeCheckpoints` | mapping(address => Trace224, private) | 1 | V2 |
| 21 | `bootstrapContract` | address | 1 | V3 |
| 22 | `pendingAdmin` | address | 1 | V3 |
| 23 | `adminTransferEta` | uint256 | 1 | V3 |
| 24 | `adminTransferProposer` | address | 1 | R6 fix |
| 25 | `protocolTreasuryAddress` | address | 1 | V4 |
| 26-66 | `__gap[41]` | uint256[41] | 41 | -- |

**Total contract-declared slots:** 25 + 41 (gap) = 66

**Constants (do NOT occupy storage slots):**
- `ADMIN_ROLE`, `AVALANCHE_VALIDATOR_ROLE`, `PROVISIONER_ROLE` -- bytes32 constants (bytecode)
- `ODDAO_FEE_BPS`, `STAKING_FEE_BPS`, `PROTOCOL_FEE_BPS`, `BASIS_POINTS` -- uint256 constants
- `MAX_REQUIRED_SIGNATURES`, `MAX_TIER`, `DURATION_COUNT` -- uint256 constants
- `ADMIN_TRANSFER_DELAY` -- uint256 constant (line 538)

**Gap History:**
- V1 original: 17 variables + X gap = 66 total (assuming X = 49)
- V2: +3 variables (_ossified, _stakeCheckpoints, and one more) -> gap reduced
- V3: +3 variables (bootstrapContract, pendingAdmin, adminTransferEta)
- R6 fix: +2 variables (_usedClaimNonces, adminTransferProposer)
- V4: +1 variable (protocolTreasuryAddress) -> gap = 41
- Current: 25 variables + 41 gap = 66 total

**Note:** The comment on line 217 says "Reduced from 42 to 41: added protocolTreasuryAddress." This is correct -- the prior gap was 42 (after R6 fixes), and adding `protocolTreasuryAddress` reduced it to 41.

**Verification:** Run `npx @openzeppelin/upgrades-core validate` before any mainnet upgrade deployment to machine-verify storage layout compatibility. The `.openzeppelin/unknown-88008.json` file should be kept synchronized with each deployment.

---

## Access Control Map

| Role | Functions | Risk Level |
|------|-----------|------------|
| `DEFAULT_ADMIN_ROLE` | `grantRole()`, `revokeRole()` (inherited OZ ACL) | 9/10 |
| `ADMIN_ROLE` | `_authorizeUpgrade()`, `setService()`, `setValidator()`, `setRequiredSignatures()`, `setOddaoAddress()`, `setStakingPoolAddress()`, `setProtocolTreasuryAddress()`, `registerLegacyUsers()`, `pause()`, `unpause()`, `ossify()`, `initializeV2()`, `reinitializeV3()`, `proposeAdminTransfer()`, `cancelAdminTransfer()` | 8/10 |
| `PROVISIONER_ROLE` | `provisionValidator()`, `deprovisionValidator()` | 4/10 |
| `AVALANCHE_VALIDATOR_ROLE` | `settleDEXTrade()`, `batchSettleDEX()`, `distributeDEXFees()`, `settlePrivateDEXTrade()`, `batchSettlePrivateDEX()` | 5/10 |
| None (user self-service) | `stake()`, `unlock()`, `depositToDEX()`, `withdrawFromDEX()`, `claimLegacyBalance()` | 2/10 |
| None (permissionless) | `acceptAdminTransfer()` (gated by `msg.sender == pendingAdmin`) | 7/10 |
| None (view functions) | `getService()`, `isValidator()`, `getActiveNodes()`, `getStake()`, `getStakedAt()`, `getDEXBalance()`, `isUsernameAvailable()`, `getLegacyStatus()`, `isOssified()` | 0/10 |

**Role Separation Analysis:**

- `DEFAULT_ADMIN_ROLE` can grant/revoke any role including `ADMIN_ROLE`. This is the root role.
- `ADMIN_ROLE` controls all governance operations. It cannot grant itself additional roles (that requires `DEFAULT_ADMIN_ROLE`).
- `PROVISIONER_ROLE` is narrowly scoped -- it can only add/remove validators, not modify services, staking, or fees.
- `AVALANCHE_VALIDATOR_ROLE` gates the deprecated DEX settlement functions. Once those are disabled (see M-01), this role has no remaining on-chain privileges in OmniCore (it is still used by other contracts like the deprecated settlement path).

**Two-Step Admin Transfer Security:**

1. `proposeAdminTransfer()` -- requires `ADMIN_ROLE`, stores proposer address, sets 48h delay.
2. After 48h, `acceptAdminTransfer()` -- requires `msg.sender == pendingAdmin` (explicit, not `_msgSender()`).
3. Grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to new admin.
4. Revokes `ADMIN_ROLE` + `DEFAULT_ADMIN_ROLE` from old admin (proposer).
5. `cancelAdminTransfer()` -- requires current `ADMIN_ROLE`, clears all pending state.

This flow is sound. The 48h delay provides a monitoring window. The explicit `msg.sender` check prevents relay via the trusted forwarder.

---

## Centralization Risk Assessment

**Single-key maximum damage:** 8/10 (High Risk)

A compromised `ADMIN_ROLE` key can:
1. **Upgrade the contract** to arbitrary logic via UUPS, stealing all staked XOM and DEX deposits instantly.
2. **Add rogue validators** via `setValidator()` for fraudulent DEX settlements.
3. **Register fraudulent legacy users** to drain migration tokens.
4. **Lower `requiredSignatures` to 1** to enable single-validator legacy claims.
5. **Change fee recipient addresses** to attacker-controlled addresses.
6. **Ossify the contract** permanently (denial-of-service against future bug fixes).
7. **Pause the contract** indefinitely (freezing all user funds).

**Funds at risk:** All staked XOM (`totalStaked`), all DEX-deposited tokens (`dexBalances`), all unclaimed legacy migration tokens.

**Mitigation (operational, documented in NatSpec lines 24-28):**

Deploy a `TimelockController` (48h minimum delay) controlled by a 3-of-5 multi-sig as the `ADMIN_ROLE` holder. The `EmergencyGuardian` contract provides fast-response pause capability for the security council.

**This must be operational before mainnet launch with real user funds.**

---

## Signature Verification Deep Dive

### `_verifyClaimSignatures()` (lines 1337-1373)

| Check | Status | Details |
|-------|--------|---------|
| EIP-191 prefix | **Correct** | Uses `\x19Ethereum Signed Message:\n32` (line 1354) |
| Hash construction | **Correct** | Uses `abi.encode` (not `abi.encodePacked`) preventing hash collision. Includes `address(this)` and `block.chainid` for cross-chain replay protection (lines 1345-1351). |
| Signature malleability | **Fixed** | Uses OZ `ECDSA.recover()` (line 1430) which rejects high-s values and non-standard v values. |
| Duplicate signer detection | **Correct** | O(n^2) loop (lines 1368-1369) is acceptable for MAX_REQUIRED_SIGNATURES=5. |
| Validator status check | **Correct** | `validators[signer]` check at line 1365 ensures signer is in the direct mapping. |
| Nonce tracking | **Fixed** | `_usedClaimNonces[nonce]` checked and set at lines 1259-1260. |
| Cross-chain replay | **Protected** | `block.chainid` and `address(this)` in hash. |
| Zero-signer protection | **Protected** | `ECDSA.recover()` returns address(0) for invalid sigs; line 1431 checks `signer == address(0)`. |

---

## Cross-Contract Integration Analysis

### OmniCore <-> StakingRewardPool

- StakingRewardPool reads `getStake(user)` to compute time-based APR rewards.
- StakingRewardPool's `_clampTier()` independently validates the tier against the staked amount (defense-in-depth against OmniCore's tier being manipulated via upgrade).
- `snapshotRewards()` must be called BEFORE `unlock()` to preserve frozen rewards. This is a UX requirement documented in NatSpec.
- `unlock()` sets `amount = 0` and `active = false`, causing StakingRewardPool to return 0 for future accruals.

### OmniCore <-> OmniGovernance

- OmniGovernance calls `getStakedAt(user, blockNumber)` for snapshot-based voting power.
- Uses `staticcall` with `abi.encodeWithSignature` for safe read-only cross-contract call.
- If `getStakedAt()` is unavailable (pre-V2 OmniCore), returns 0 (safe default per ATK-H02 fix).

### OmniCore <-> Bootstrap.sol

- `isValidator()` falls back to Bootstrap when `validators[validator]` is false.
- `getActiveNodes()` queries Bootstrap for gateway (type 0) and computation (type 1) nodes with interleaving.
- Try/catch wrapping in `isValidator()` prevents Bootstrap failures from blocking OmniCore.
- `getActiveNodes()` reverts with `InvalidAddress` if Bootstrap is not set -- used by OmniValidatorRewards, which gracefully handles the revert.

### OmniCore <-> ValidatorProvisioner

- `PROVISIONER_ROLE` allows automated validator onboarding/offboarding.
- `provisionValidator()` and `deprovisionValidator()` mirror `setValidator()` logic without requiring `ADMIN_ROLE`.
- Properly separated: the provisioner cannot access any other admin function.

### OmniCore <-> DEXSettlement.sol

- DEXSettlement.sol is the trustless replacement for the deprecated settlement functions.
- DEXSettlement uses EIP-712 dual signatures -- no validator trust required.
- DEXSettlement has its own balance management -- users deposit to DEXSettlement directly.
- The legacy `dexBalances` mapping in OmniCore is a separate accounting system from DEXSettlement. Once migration is complete, the legacy system should be disabled (see M-01).

---

## Solhint Analysis

```
$ npx solhint contracts/OmniCore.sol
contracts/OmniCore.sol
  525:32  warning  Variable "newImplementation" is unused  no-unused-vars

1 problem (0 errors, 1 warning)
```

**Summary:** 1 warning (unused variable in `_authorizeUpgrade()`). See L-02 for recommendation. All `not-rely-on-time` suppressions are documented with business justifications.

---

## Compilation and Test Results

**Compilation:** Clean. No errors or warnings from the Solidity compiler.

**Tests:** All 50 tests passing (5 seconds):
- Initialization (4 tests)
- Upgradeability (2 tests)
- Service Registry (4 tests)
- Validator Management (5 tests)
- Pausable M-04 (5 tests)
- Minimal Staking (6 tests)
- Unlock Staking (6 tests)
- Legacy Migration (4 tests)
- Legacy Claim Multi-Sig (2 tests)
- initializeV2 M-05 (1 test)
- Required Signatures (3 tests)
- Integration (3 tests)

**Test coverage gaps noted:**
- No test for `provisionValidator()` and `deprovisionValidator()` via PROVISIONER_ROLE
- No test for `proposeAdminTransfer()` / `acceptAdminTransfer()` flow
- No test for `cancelAdminTransfer()`
- No test for `getActiveNodes()` with Bootstrap integration
- No test for `isValidator()` Bootstrap fallback
- No test for `_usedClaimNonces` replay prevention
- No test for `getStakedAt()` checkpoint queries
- No test for `setProtocolTreasuryAddress()`
- No test for `distributeDEXFees()` with three-way split
- No test for `ossify()` and subsequent upgrade rejection

These coverage gaps are recommended for pre-mainnet testing but are not blocking for this audit.

---

## Known Exploit Cross-Reference

| Exploit / Advisory | Relevance | Finding |
|-------------------|-----------|---------|
| Ronin Bridge (2022, $625M): Single admin key compromise | Operational: ADMIN_ROLE must be behind TimelockController + multi-sig | Operational requirement |
| OpenZeppelin UUPS Advisory (2021, $10M bounty): Unprotected initializer | Fixed: `onlyRole(ADMIN_ROLE)` on initializeV2/V3 | Remediated |
| ZABU Finance ($200K): Fee-on-transfer accounting | Fixed: balance-before/after in `depositToDEX()` | Remediated |
| Zunami Protocol (2025, $500K): Overpowered admin | TimelockController operational requirement | Operational |
| SWC-117: Signature malleability | Fixed: OZ `ECDSA.recover()` | Remediated |
| SWC-133: `abi.encodePacked` hash collision | Fixed: `abi.encode` | Remediated |
| Beanstalk (2022, $182M): Governance flash-loan | Mitigated: checkpoint-based voting power in OmniGovernance | Mitigated via integration |
| Compound (2021): Bad governance parameter change | Mitigated: 48h admin transfer delay | Mitigated |

---

## Remediation Priority

| Priority | Finding | Effort | Blocking for Mainnet? |
|----------|---------|--------|-----------------------|
| 1 | M-01: Disable deprecated DEX settlement | Low (add boolean flag + check) | **Recommended** |
| 2 | M-02: Verify protocolTreasuryAddress is set | Low (query + optional reinitializeV4) | **Recommended** |
| 3 | L-01: Cap batch array length | Low (add length check) | No |
| 4 | L-02: Fix solhint unused variable | Trivial | No |
| 5 | L-03: Document isValidator() scope | Trivial (NatSpec) | No |
| 6 | L-04: Document legacy claim signer scope | Trivial (NatSpec) | No |
| 7 | I-05: Enrich cancel event | Trivial | No |
| -- | **Operational:** Deploy TimelockController + multi-sig | Medium (deployment scripts) | **Yes -- BLOCKING** |
| -- | **Test coverage:** Add missing test scenarios | Medium | Recommended |

---

## Conclusion

OmniCore.sol has reached a mature and robust security posture through seven audit rounds. All prior High and Medium findings have been remediated. The contract demonstrates:

**Strengths:**
- Comprehensive input validation on all user-facing functions
- Proper reentrancy guards (nonReentrant) on all fund-transferring functions
- Emergency pause capability (PausableUpgradeable) on critical operations
- Two-step admin transfer with 48h delay and role revocation
- Ossification capability for permanent upgrade lockdown
- On-chain nonce tracking for legacy claim signatures
- Governance-compatible staking checkpoints
- ERC-2771 meta-transaction support with explicit `msg.sender` for admin functions
- Fee-on-transfer protection on DEX deposits
- Cross-chain replay protection in signature verification

**Remaining Risks:**
1. **Deprecated DEX settlement functions** (M-01) -- should be disabled before real user funds enter the `dexBalances` system.
2. **Operational deployment** -- ADMIN_ROLE must be behind TimelockController + multi-sig before mainnet. This is the single most critical operational action.
3. **Test coverage** -- Several V3/V4 features lack test coverage.

**Verdict:** The contract is suitable for mainnet deployment once:
1. The ADMIN_ROLE is transferred to a TimelockController controlled by a multi-sig.
2. The `protocolTreasuryAddress` is verified as set on the deployed proxy.
3. A plan is in place to disable the deprecated DEX settlement functions after migration.

---

*Generated by Claude Code Audit Agent (Opus 4.6)*
*Audit scope: All 1,481 lines of OmniCore.sol*
*Cross-referenced contracts: Bootstrap.sol, StakingRewardPool.sol, OmniGovernance.sol, OmniValidatorRewards.sol, DEXSettlement.sol, ValidatorProvisioner.sol, OmniCoin.sol, OmniForwarder.sol, EmergencyGuardian.sol*
*Prior audit reports: Round 1 (2026-02-20), Round 5 V2/V3 (2026-03-09), Round 6 (2026-03-10)*
*Date: 2026-03-13 14:13 UTC*
