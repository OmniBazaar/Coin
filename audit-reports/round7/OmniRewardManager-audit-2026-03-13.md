# Security Audit Report: OmniRewardManager (Round 7)

**Date:** 2026-03-13 14:14 UTC
**Audited by:** Claude Code Audit Agent (Round 7 -- Deep Security Review)
**Contract:** `Coin/contracts/OmniRewardManager.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 2,155
**Upgradeable:** Yes (UUPS with ossification capability)
**Handles Funds:** Yes (~6.38B XOM across 3 pre-minted pools)
**Previous Audits:**
- Round 1 (2026-02-20): 3 Critical, 5 High, 6 Medium, 3 Low, 2 Informational
- Round 6 (2026-03-10): 0 Critical, 1 High, 4 Medium, 3 Low, 2 Informational

---

## Executive Summary

This is a Round 7 deep security audit of OmniRewardManager, the highest-value user-facing contract in the OmniCoin ecosystem. The contract manages distribution of approximately 6.38 billion XOM across three pre-minted reward pools: Welcome Bonus (1.38B), Referral Bonus (2.99B), and First Sale Bonus (2.0B). Validator rewards have been moved to a separate OmniValidatorRewards contract since the Round 6 audit.

The contract has undergone substantial hardening across the prior 6 audit rounds. All 3 Critical findings, all 5 High findings, and all 6 Medium findings from Round 1 have been remediated. The Round 6 High finding (validator reward rate limiting) was resolved by removing validator reward functionality entirely from this contract.

This Round 7 audit identifies **0 Critical, 0 High, 3 Medium, 5 Low, and 4 Informational** findings. The most significant findings relate to: (1) a missing zero-address check in `claimFirstSaleBonusRelayed` allowing signature recovery against `address(0)`, (2) a missing event emission on `setMerkleRootsRequired` which reduces governance transparency, and (3) the `_distributeReferralRewards` function potentially stranding ODDAO tokens when `oddaoAddress` is unset (unlike the auto-referral path which correctly reverts). The contract is well-engineered and demonstrates defense-in-depth across all major attack surfaces.

**Overall Assessment: SUITABLE FOR MAINNET DEPLOYMENT** provided Medium findings are addressed.

| Severity | Count | Prior Round 6 | Change |
|----------|-------|---------------|--------|
| Critical | 0 | 0 | No change |
| High | 0 | 1 | -1 (fixed by removing validator rewards) |
| Medium | 3 | 4 | -4 fixed, +3 new |
| Low | 5 | 3 | -3 fixed, +5 new |
| Informational | 4 | 2 | -2 fixed, +4 new |
| **Total** | **12** | **10** | **Net +2** |

---

## Prior Audit Remediation Status

### Round 6 Findings: ALL RESOLVED

| ID | Severity | Finding | Status | Evidence |
|----|----------|---------|--------|----------|
| H-01 | High | No on-chain rate limiting for validator rewards | **RESOLVED** | `distributeValidatorReward()` and `VALIDATOR_REWARD_ROLE` removed entirely; validator rewards moved to OmniValidatorRewards contract. Storage gap preserved at line 155 (`__gap_removed_validatorPool`). |
| M-01 | Medium | Welcome bonus pool insufficient for tier structure | **FIXED** | `getWelcomeBonusPoolExhaustionEstimate()` added at line 1193 -- view function for on-chain depletion forecasting |
| M-02 | Medium | ERC-2771 trusted forwarder impersonation | **ACCEPTED** | Documented at line 538-542. Immutable forwarder is OZ standard practice. |
| M-03 | Medium | setPendingReferralBonus cannot cancel to zero | **FIXED** | Line 852: `if (amount == 0 && oldPending == 0) revert ZeroAmountNotAllowed()` -- allows setting to 0 when oldPending > 0 |
| M-04 | Medium | Merkle proof bypass when root is bytes32(0) | **FIXED** | `merkleRootsRequired` flag added at line 239; `setMerkleRootsRequired()` at line 886; enforced in `_verifyMerkleProof` (line 2097) and `_verifyReferralMerkleProof` (line 2003) |
| L-01 | Low | Shared nonce counter across claim types | **ACCEPTED** | Design choice; different typehashes prevent cross-type forgery |
| L-02 | Low | Validator reward deduplication | **RESOLVED** | Feature removed from contract |
| L-03 | Low | ODDAO share rounding asymmetry | **ACCEPTED** | Sub-wei impact at practical amounts |
| I-01 | Info | Validator pool 40-year sustainability | **RESOLVED** | Feature removed from contract |
| I-02 | Info | Storage gap size | **UNCHANGED** | Gap is `uint256[25]` at line 247 (reduced from 26 for epochReferralCount) |

### Round 1 Findings: ALL RESOLVED

All 3 Critical, 5 High, 6 Medium, 3 Low, 2 Informational findings from the initial audit are fully remediated or accepted with documented rationale. See Round 6 report for detailed evidence.

---

## Access Control Map

| Role | Functions | Privilege Level | Notes |
|------|-----------|----------------|-------|
| DEFAULT_ADMIN_ROLE | `setRegistrationContract`, `applyRegistrationContract`, `setOddaoAddress`, `setLegacyBonusClaimsCount`, `setPendingReferralBonus`, `setMerkleRootsRequired`, `reinitializeV2`, `grantRole`, `revokeRole` | High (7/10) | Timelock on registration changes; capped legacy claims; pool-accounted pending bonuses |
| BONUS_DISTRIBUTOR_ROLE | `claimWelcomeBonus`, `claimReferralBonus`, `claimFirstSaleBonus`, `updateMerkleRoot` | Medium (5/10) | Merkle-gated when `merkleRootsRequired` is true; pool-bounded |
| UPGRADER_ROLE | `_authorizeUpgrade`, `ossify` | High (8/10) | Can be permanently disabled via ossification |
| PAUSER_ROLE | `pause`, `unpause` | Low (2/10) | Emergency circuit breaker |
| (Permissionless) | `claimWelcomeBonus{Permissionless,Trustless,Relayed}`, `claimReferralBonus{Permissionless,Relayed}`, `claimFirstSaleBonus{Permissionless,Relayed}`, `getClaimNonce`, view functions | Low (2/10) | KYC-gated, rate-limited, one-time claims |

**Role Separation:** `_setupRoles()` (line 1760) grants ONLY `DEFAULT_ADMIN_ROLE`. Other roles must be explicitly granted to separate addresses. This correctly prevents single-key total compromise.

---

## New Findings

### [M-01] Missing Zero-Address Check in claimFirstSaleBonusRelayed

**Severity:** Medium
**Category:** Input Validation / Defensive Coding
**Location:** `claimFirstSaleBonusRelayed()` line 1408
**CWE:** CWE-20 (Improper Input Validation)

**Description:**

`claimFirstSaleBonusRelayed()` does NOT validate that `user != address(0)` before proceeding with signature verification. By contrast, both `claimWelcomeBonusRelayed()` (line 1088) and `claimReferralBonusRelayed()` (line 1280) include explicit `address(0)` checks.

While `ECDSA.recover()` from OpenZeppelin will not return `address(0)` for valid signatures (it reverts on invalid signatures and returns the signer for valid ones), the inconsistency creates a defensive gap. If `user == address(0)`:

1. `nonce != claimNonces[address(0)]` will pass (both are 0)
2. ECDSA.recover will return a non-zero signer from the signature
3. The `recoveredSigner != user` check (line 1437) will catch this because `recoveredSigner` will be the actual signer, not `address(0)`

So there is no direct exploit, but:
- The `claimNonces[address(0)]` nonce is incremented if someone crafts a valid signature for a zero-address struct (not practically achievable, but the nonce slot is touched on revert paths in other implementations)
- The inconsistency with the other two relayed functions suggests this check was accidentally omitted
- Best practice for financial contracts is to fail fast on invalid inputs before performing cryptographic operations

**Impact:** No direct financial impact due to ECDSA.recover behavior. However, the inconsistency violates the principle of uniform input validation across parallel code paths, and could become exploitable if the ECDSA library behavior changes in future OpenZeppelin versions.

**Recommendation:**

Add after line 1413:
```solidity
if (user == address(0)) revert ZeroAddressNotAllowed();
```

This matches the pattern at line 1088 (`claimWelcomeBonusRelayed`) and line 1280 (`claimReferralBonusRelayed`).

---

### [M-02] setMerkleRootsRequired Emits No Event

**Severity:** Medium
**Category:** Governance Transparency / Event Coverage
**Location:** `setMerkleRootsRequired()` lines 886-890
**CWE:** CWE-778 (Insufficient Logging)

**Description:**

The `setMerkleRootsRequired()` function modifies a security-critical state variable that controls whether role-based claims require merkle proof verification. When this flag transitions from `false` to `true`, it fundamentally changes the security posture of the `BONUS_DISTRIBUTOR_ROLE` -- making it impossible to claim arbitrary amounts even with the role. When it transitions from `true` to `false`, it weakens the defense-in-depth.

Neither transition emits an event. This means:
- Off-chain monitoring systems cannot detect when merkle enforcement changes
- Governance auditing tools cannot track the history of this security setting
- Incident response teams have no log trail to correlate with suspicious claims
- The change is invisible to block explorers and dashboards

Every other admin function in the contract (`setRegistrationContract`, `setOddaoAddress`, `setLegacyBonusClaimsCount`, `setPendingReferralBonus`, `updateMerkleRoot`) emits an event on state change.

**Impact:** Reduced governance transparency for a security-critical setting. If a compromised admin disables merkle root enforcement before performing unauthorized claims through `BONUS_DISTRIBUTOR_ROLE`, the disabling action would leave no on-chain trace.

**Recommendation:**

Add an event and emit it:
```solidity
/// @notice Emitted when merkle root enforcement is toggled
/// @param required Whether merkle roots are now required
/// @param changedBy Address that made the change
event MerkleRootsRequiredChanged(bool indexed required, address indexed changedBy);

function setMerkleRootsRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
    merkleRootsRequired = required;
    emit MerkleRootsRequiredChanged(required, msg.sender);
}
```

---

### [M-03] Role-Based _distributeReferralRewards Silently Skips ODDAO Transfer When oddaoAddress Is Zero

**Severity:** Medium
**Category:** Business Logic / Fund Stranding
**Location:** `_distributeReferralRewards()` lines 1738-1741
**CWE:** CWE-754 (Improper Check for Exceptional Conditions)

**Description:**

The role-based referral distribution function `_distributeReferralRewards()` (called from `claimReferralBonus()`) silently skips the ODDAO transfer when `oddaoAddress == address(0)` (line 1739: `if (oddaoShare != 0 && oddaoAddress != address(0))`). The ODDAO share is calculated and included in the pool deduction (the caller at line 663 calls `_updatePoolAfterDistribution(referralBonusPool, totalWithOddao)`), but the tokens are never transferred.

By contrast, the auto-referral path `_distributeAutoReferralBonus()` correctly reverts with `OddaoAddressNotSet()` at line 1863 when `oddaoAddress == address(0)`.

This creates an asymmetry:
- **Auto path (permissionless):** Reverts if ODDAO address is not set -- correct behavior
- **Role path (BONUS_DISTRIBUTOR_ROLE):** Silently skips ODDAO transfer -- ODDAO's share is deducted from pool accounting but remains in the contract, permanently stranded

The stranded tokens are not recoverable because:
1. There is no `recoverERC20` or `emergencyWithdraw` function
2. Pool accounting believes the tokens are distributed
3. The contract balance is higher than `sum(pool.remaining) + sum(pendingReferralBonuses)` by the stranded amount

**Impact:** ODDAO loses 10% (or 30% if no second-level referrer) of every role-based referral claim made while `oddaoAddress == address(0)`. These tokens become permanently locked in the contract. At a 2,500 XOM referral bonus, each claim strands 250-750 XOM for ODDAO.

**Mitigating Factor:** The ODDAO address would typically be set before any referral bonuses are claimed. However, the auto-referral path shows that the project considers this important enough to revert on.

**Recommendation:**

Add an ODDAO address check at the top of `_distributeReferralRewards()`:
```solidity
function _distributeReferralRewards(ReferralParams calldata params) internal {
    if (oddaoAddress == address(0)) revert OddaoAddressNotSet();
    // ... existing logic
}
```

Alternatively, add the check in `claimReferralBonus()` before calling the internal function.

---

### [L-01] updateMerkleRoot Missing whenNotPaused Guard

**Severity:** Low
**Category:** Emergency Controls / Consistency
**Location:** `updateMerkleRoot()` lines 706-713

**Description:**

The `updateMerkleRoot()` function is callable by `BONUS_DISTRIBUTOR_ROLE` even when the contract is paused. All other `BONUS_DISTRIBUTOR_ROLE` functions (`claimWelcomeBonus`, `claimReferralBonus`, `claimFirstSaleBonus`) include the `whenNotPaused` modifier.

While updating a merkle root during a pause is not directly dangerous (no tokens are transferred), it could undermine the purpose of pausing:
- If the contract is paused due to a suspected `BONUS_DISTRIBUTOR_ROLE` compromise, the attacker can still set arbitrary merkle roots
- When the contract is unpaused, the attacker's merkle roots would be active, enabling claims with fabricated proofs

**Mitigating Factor:** The root can be replaced by calling `updateMerkleRoot` again after the compromise is resolved. Additionally, `setMerkleRootsRequired(true)` means the roots are enforceable but also replaceable.

**Recommendation:**

Add `whenNotPaused`:
```solidity
function updateMerkleRoot(
    PoolType poolType,
    bytes32 newRoot
) external onlyRole(BONUS_DISTRIBUTOR_ROLE) whenNotPaused {
```

---

### [L-02] Nonce Increment Ordering Inconsistency in claimReferralBonusRelayed

**Severity:** Low
**Category:** Consistency / CEI Pattern
**Location:** `claimReferralBonusRelayed()` line 1321 vs other relayed functions

**Description:**

The nonce increment timing differs across the three relayed claim functions:

| Function | Nonce Increment | Position Relative to External Calls |
|----------|----------------|--------------------------------------|
| `claimWelcomeBonusRelayed` | Line 1113 (step 4) | Before registration contract calls (step 5) |
| `claimReferralBonusRelayed` | Line 1321 (step 6) | After registration contract calls (steps 3-4) |
| `claimFirstSaleBonusRelayed` | Line 1463 (step 8) | After registration contract calls (steps 5-6b) |

In `claimWelcomeBonusRelayed`, the nonce is incremented early (before any external calls to `registrationContract`), following the Checks-Effects-Interactions (CEI) pattern. In the other two relayed functions, the nonce is incremented after external calls to `registrationContract`.

While the `nonReentrant` guard prevents exploitation through reentrancy, the inconsistent ordering:
1. Violates the CEI best practice in 2 of 3 relayed functions
2. Creates unnecessary cognitive load for auditors verifying reentrancy safety
3. If `nonReentrant` were ever removed (e.g., in an upgrade), the late nonce increment could enable replay via reentrancy

**Impact:** No direct exploit due to `nonReentrant`. Consistency and defense-in-depth concern only.

**Recommendation:**

Move nonce increments to immediately after signature verification in all three relayed functions, matching the pattern in `claimWelcomeBonusRelayed`.

---

### [L-03] getWelcomeBonusPoolExhaustionEstimate May Run Out of Gas on Large Simulations

**Severity:** Low
**Category:** Denial of Service / Gas Efficiency
**Location:** `getWelcomeBonusPoolExhaustionEstimate()` lines 1193-1211

**Description:**

The function simulates individual claims in a `while` loop until the pool is exhausted or `effectiveClaims >= 10,000,000`. At the minimum bonus (625 XOM) with a 1.38B pool, this could iterate up to approximately 2.2 million times before the pool is exhausted. Each iteration performs a function call to `_calculateWelcomeBonus()` and arithmetic operations.

While this is a `view` function (no gas cost for off-chain calls), on-chain calls from other contracts would consume excessive gas. Additionally, some RPC providers impose execution time limits on `eth_call` that could cause this to time out.

**Impact:** The function may fail to return results when called via RPC nodes with strict execution limits, particularly when the pool is mostly full and many users remain to be simulated. No financial risk.

**Recommendation:**

Consider adding a `maxIterations` parameter to allow callers to limit computation:
```solidity
function getWelcomeBonusPoolExhaustionEstimate(uint256 maxIterations)
    external view returns (uint256 estimatedUsers, uint256 currentRemaining)
{
    // ... with `estimatedUsers < maxIterations` added to while condition
}
```

Or keep the existing function and add a comment noting the gas consideration for on-chain callers.

---

### [L-04] Referral Bonus Pool Accounting Gap: Pending Bonuses Not Tracked in Pool Remaining

**Severity:** Low
**Category:** Accounting Invariant / Transparency
**Location:** `_distributeAutoReferralBonus()` lines 1917-1924, `claimReferralBonusPermissionless()` lines 1246-1250

**Description:**

When `_distributeAutoReferralBonus()` runs, the full `referralAmount` is deducted from `referralBonusPool.remaining` at line 1918. However, only the ODDAO share is immediately transferred. The referrer and second-level referrer shares are accumulated in `pendingReferralBonuses` (lines 1921-1924).

When the referrer later calls `claimReferralBonusPermissionless()`, the pending amount is transferred directly from the contract's token balance (line 1250) WITHOUT any further pool accounting update. This is correct because the pool was already decremented when the bonus was accumulated.

However, the view function `getTotalUndistributed()` (line 1516) returns `sum(pool.remaining)` but does NOT account for pending referral bonuses. This means:

```
getTotalUndistributed() = pool.remaining  (what pools think is undistributed)
actualUndistributed = pool.remaining + sum(pendingReferralBonuses)  (what's actually not yet transferred)
```

The `getTotalUndistributed()` value will be LOWER than expected because pending bonuses have been deducted from pool.remaining but not yet transferred out. Conversely, `getTotalDistributed()` will be HIGHER than what has actually been transferred, because it counts pending bonuses as "distributed" even though they are still in the contract.

**Impact:** View functions report misleading values to dashboards, block explorers, and monitoring systems. No direct financial impact since all transfers are individually correct.

**Recommendation:**

Add a `getTotalPendingReferralBonuses()` view function, or update `getTotalUndistributed()` documentation to clarify that it excludes pending referral bonuses. Alternatively, provide a `getActualUndistributed()` function:

```solidity
/// @notice Get actual token balance that is not yet committed
/// @dev Includes pending referral bonuses as committed but untransferred
function getContractBalance() external view returns (uint256) {
    return omniCoin.balanceOf(address(this));
}
```

---

### [L-05] referralBonusesEarned Tracks Accumulated But Not Claimed Amounts

**Severity:** Low
**Category:** Accounting Accuracy
**Location:** `referralBonusesEarned` mapping, lines 1720, 1927-1929 vs `claimReferralBonusPermissionless()` line 1247

**Description:**

The `referralBonusesEarned` mapping is incremented in both `_distributeReferralRewards()` (line 1720) and `_distributeAutoReferralBonus()` (lines 1927-1929), tracking the total amount a referrer has earned. However, when a referrer claims their pending bonus via `claimReferralBonusPermissionless()`, the `referralBonusesEarned` counter is NOT decremented.

This means `referralBonusesEarned[referrer]` represents "total ever accumulated" rather than "total claimed" or "net balance." The naming suggests "earned" which is ambiguous -- it could mean "total lifetime earnings" or "current unclaimed earnings."

Additionally, for the role-based path (`_distributeReferralRewards`), tokens are immediately transferred (not accumulated), so `referralBonusesEarned` includes both immediately-transferred amounts and pending-but-unclaimed amounts. The value is not useful for determining how much a referrer can still claim.

**Impact:** Dashboard or frontend code that relies on `referralBonusesEarned` to display "available to claim" would show incorrect (inflated) values. The separate `pendingReferralBonuses` mapping correctly tracks claimable amounts.

**Recommendation:**

Rename the mapping or add NatSpec clarification:
```solidity
/// @notice Tracks TOTAL LIFETIME referral bonuses earned by each referrer (never decremented)
/// @dev For current claimable amount, use pendingReferralBonuses[address]
mapping(address => uint256) public referralBonusesEarned;
```

---

### [I-01] Constructor NatSpec Misaligned with Parameter Documentation

**Severity:** Informational
**Category:** Documentation
**Location:** Constructor, lines 534-548

**Description:**

The constructor has a NatSpec `@notice` comment ("Disables initializers for the implementation contract") but the `@param` tag is missing for the `trustedForwarder_` parameter. Solhint flags this at line 544:

```
544:5   warning  Missing @param tag in function '<anonymous>'   use-natspec
544:5   warning  Mismatch in @param names for function '<anonymous>'. Expected: [trustedForwarder_], Found: []   use-natspec
```

**Recommendation:**

Update the constructor NatSpec:
```solidity
/**
 * @notice Disables initializers for the implementation contract
 * @dev Required for UUPS proxy pattern security
 * @param trustedForwarder_ Address of the ERC-2771 trusted forwarder contract
 */
```

---

### [I-02] max-states-count Solhint Warning (28 State Declarations)

**Severity:** Informational
**Category:** Complexity / Maintainability
**Location:** Line 44 (contract declaration)

**Description:**

Solhint reports `Contract has 28 states declarations but allowed no more than 20`. This includes:
- 4 public state variables (`omniCoin`, 3 pool states)
- 5 private storage gap variables (`__gap_removed_*`)
- 8 public mappings
- 4 public scalars (`oddaoAddress`, `legacyBonusClaimsCount`, etc.)
- 2 pending registration contract variables
- 1 private `_ossified` flag
- 2 additional variables (`merkleRootsRequired`, `epochReferralCount`)
- 1 storage gap array (`__gap`)
- 1 `welcomeBonusClaimCount`

The high count is partially unavoidable due to:
1. Storage gap variables that MUST be preserved for UUPS upgrade safety (5 slots)
2. Per-pool-type counters required by the rate limiting design
3. Separate daily vs epoch counters for Sybil protection

**Recommendation:**

This is acceptable for a contract of this complexity. No action needed. The solhint `max-states-count` rule can be disabled at the contract level with a comment:
```solidity
/* solhint-disable max-states-count */
```

---

### [I-03] Unused Variable Warning in _authorizeUpgrade

**Severity:** Informational
**Category:** Code Quality
**Location:** `_authorizeUpgrade()` line 1967

**Description:**

Solhint reports: `Variable "newImplementation" is unused`. The UUPS `_authorizeUpgrade` override only checks the `_ossified` flag and role access, but does not use the `newImplementation` parameter. This is standard practice for UUPS contracts -- the function signature is dictated by the UUPS interface, and many implementations only use it for authorization checks.

**Recommendation:**

This is standard and expected. No code change needed. The warning can be silenced by adding a reference comment, though this is purely cosmetic.

---

### [I-04] Solhint gas-strict-inequalities Warnings Are Correct By Design

**Severity:** Informational
**Category:** False Positives / Solhint Configuration
**Location:** Multiple tier boundary checks in `_calculateWelcomeBonus`, `_calculateReferralBonus`, `_calculateFirstSaleBonus`, and daily rate limit checks

**Description:**

Solhint reports 15 `gas-strict-inequalities` warnings for `<=` comparisons in tier calculations (e.g., `registrationNumber <= 1000`) and `>=` comparisons in rate limit checks (e.g., `dailyWelcomeBonusCount[today] >= MAX_DAILY_WELCOME_BONUSES`).

All of these are CORRECT by specification:
- Tier boundaries use `<=` because user #1,000 is in Tier 1 (10,000 XOM), not Tier 2
- Rate limits use `>=` because the limit is inclusive (exactly MAX is the last allowed)

Changing `<=` to `<` would shift tier boundaries by 1 user, violating the tokenomics specification.

**Recommendation:**

These are false positives. No code changes needed. These are business-logic comparisons where strict inequalities would be incorrect.

---

## DeFi Exploit Vector Analysis

### 1. Sybil Attack on Welcome Bonuses

**Attack:** Register many fake identities to claim welcome bonuses.

**Defenses (6 layers):**
1. Unique phone hash per registration (`PhoneAlreadyUsed` in OmniRegistration)
2. Unique email hash per registration (`EmailAlreadyUsed` in OmniRegistration)
3. KYC Tier 1 required for ALL claim paths -- permissionless, trustless, and relayed
4. Daily rate limit: 1,000 welcome bonuses per day (`MAX_DAILY_WELCOME_BONUSES`)
5. One bonus per address (`welcomeBonusClaimed` mapping + registration contract tracking)
6. Unique social media verification per registration (OmniRegistration)

**Assessment:** Strong defense. The cost of a unique phone + email + social media account per Sybil identity makes the attack economically unprofitable at current bonus levels (5,000 XOM for Tier 2 users). The attack becomes profitable only if XOM appreciates significantly AND phone/social verification can be cheaply bypassed.

### 2. Sybil Attack on Referral Bonuses

**Attack:** Create many accounts referring each other to farm referral bonuses.

**Defenses (5 layers):**
1. Per-epoch referral limit: 50 referrals per 7-day epoch (`MAX_REFERRAL_BONUSES_PER_EPOCH`)
2. KYC Tier 1 required for referrer to receive bonus (line 1887)
3. KYC Tier 1 required for second-level referrer (line 1907-1909)
4. KYC Tier 1 required to claim accumulated bonuses (line 1230)
5. Welcome bonus claim is one-time per user (each referral triggers at most 1 bonus event)

**Assessment:** Strong defense. The epoch limit caps a single referrer at 50 referral bonuses per week. Combined with KYC requirements on all parties, the cost/benefit ratio makes farming unprofitable.

### 3. Flash Loan Interaction

**Assessment:** Not applicable. All bonus calculations depend on registration state, KYC status, and marketplace activity. None are influenced by token balances, liquidity pool states, or oracle prices. Flash loans have zero attack surface.

### 4. Front-Running Bonus Claims

**Attack:** Front-run a user's claim to push them to a lower bonus tier.

**Assessment:** Low risk. The front-runner gains nothing (they cannot steal the victim's bonus; they can only claim their own). The victim receives a lower-tier bonus, but the attacker expends their own one-time bonus to achieve this. Not economically rational.

### 5. ERC-2771 Forwarder Impersonation

**Attack:** Compromised forwarder triggers premature bonus claims on behalf of users.

**Assessment:** Accepted risk (documented in Round 6 M-02). The forwarder is immutable, tokens always go to the legitimate user (no redirect), and `ossify()` + `pause()` provide emergency protection. The relayed claim paths (which use EIP-712 user signatures) are NOT vulnerable.

### 6. Registration Contract Manipulation

**Attack:** Redirect registration queries to a malicious contract.

**Defenses:**
1. 48-hour timelock on registration contract changes (lines 748-766)
2. First-time setup is immediate but subsequent changes require timelock
3. `applyRegistrationContract()` requires `DEFAULT_ADMIN_ROLE`

**Assessment:** The 48-hour delay provides sufficient time for monitoring systems to detect and respond to a malicious change. The immediate first-time setup is acceptable because the contract cannot function without a registration contract.

### 7. Pool Exhaustion Griefing

**Attack:** Rapidly claim all bonuses to exhaust pools.

**Defenses:**
1. Daily rate limits per pool type (1,000 welcome, 2,000 referral manual, 2,000 referral auto, 500 first sale)
2. Separate daily counters for auto and manual referral claims
3. KYC requirements on all paths

**Assessment:** At maximum daily claim rates and highest bonus tiers, the welcome bonus pool would take ~1,383 days (3.8 years) to exhaust. Rate limiting is effective.

---

## Reentrancy Analysis

**All 11 external state-modifying functions** (excluding view functions and pure admin setters) use the `nonReentrant` modifier. Additionally:

1. **SafeERC20:** All token transfers use `safeTransfer()`, eliminating callback-based reentrancy from ERC-20 hooks.
2. **CEI Pattern:** State updates (`welcomeBonusClaimed`, pool accounting, nonce increments) occur before external calls (`safeTransfer`, `registrationContract.*`) in most functions.
3. **External Calls:** Calls to `registrationContract` (view and state functions) occur within the `nonReentrant` guard, preventing reentrancy through a malicious registration contract.

**Exception:** `updateMerkleRoot()` (line 706), `pause()` (line 719), `unpause()` (line 727), `setRegistrationContract()` (line 737), `applyRegistrationContract()` (line 762), `setOddaoAddress()` (line 780), `setLegacyBonusClaimsCount()` (line 802), `setPendingReferralBonus()` (line 842), `setMerkleRootsRequired()` (line 886), and `ossify()` (line 1947) do NOT have `nonReentrant`. These are all admin-only functions that make no external calls (except `setLegacyBonusClaimsCount` which calls `registrationContract.totalRegistrations()` -- a view function). No reentrancy risk.

**Assessment:** No reentrancy vulnerabilities identified. Defense-in-depth (nonReentrant + SafeERC20 + CEI) is comprehensive.

---

## Pool Accounting Invariant Analysis

**Primary Invariant:** For each pool: `pool.remaining + pool.distributed == pool.initial`

**Verification across all modification paths:**

| Path | Remaining | Distributed | Invariant |
|------|-----------|-------------|-----------|
| `_initializePool` | `= initial` | `= 0` | Holds |
| `_updatePoolAfterDistribution(amount)` | `-= amount` | `+= amount` | Preserved |
| `setPendingReferralBonus` (increase) | `-= increase` | `+= increase` | Preserved |
| `setPendingReferralBonus` (decrease) | `+= decrease` | `-= decrease` | Preserved |
| No other paths modify pool state | - | - | - |

**Secondary Invariant:** `omniCoin.balanceOf(address(this)) >= sum(pool.remaining) + sum(pendingReferralBonuses)`

**Analysis:** This invariant requires that:
- Every pool deduction is paired with either an immediate transfer or a pending accumulation
- Every pending claim transfers exactly the accumulated amount
- No external mechanism deposits additional tokens (which would make the invariant > instead of >=)

**Verification:**
1. `_distributeAutoReferralBonus`: Deducts `referralAmount` from pool. Distributes as: `referrerAmount` (pending), `secondLevelAmount` (pending), `oddaoAmount` (immediate transfer). Sum = `referralAmount`. CORRECT.
2. `claimReferralBonusPermissionless`: Transfers `pending` amount. Pool was already decremented when bonus was accumulated. No double-deduction. CORRECT.
3. All other claim paths: Pool is decremented, then immediate transfer of the same amount. CORRECT.

**Pool accounting is sound.** No discrepancies found.

---

## Centralization Risk Assessment

**Rating: 5/10 (Moderate) -- unchanged from Round 6**

**Strengths:**
- Role separation at initialization (only `DEFAULT_ADMIN_ROLE` granted)
- 48-hour timelock on registration contract changes
- Ossification capability for permanent upgrade disable
- Pool-accounted pending bonuses (prevents fabrication)
- `MAX_LEGACY_CLAIMS_COUNT` cap on tier manipulation
- Validator rewards removed to separate contract

**Remaining Centralization Vectors:**

| Vector | Admin Role | Max Impact | Mitigated By |
|--------|-----------|------------|-------------|
| Upgrade to malicious implementation | UPGRADER_ROLE | Full pool drain | Ossification, multisig |
| Set merkle roots to attacker-controlled values | BONUS_DISTRIBUTOR_ROLE | Arbitrary claims up to pool | Pool balance bounds, merkleRootsRequired |
| Set legacy claims count to manipulate tiers | DEFAULT_ADMIN_ROLE | Lower bonuses for new users | 10M cap, does not affect existing claims |
| Set pending referral bonus for attacker | DEFAULT_ADMIN_ROLE | Up to referral pool remaining | Pool accounting enforcement |
| Grant all roles to single address | DEFAULT_ADMIN_ROLE | Full system compromise | Off-chain multisig enforcement |

**Recommendation for mainnet:**
1. Deploy `DEFAULT_ADMIN_ROLE` to Gnosis Safe (3-of-5 minimum)
2. Place `UPGRADER_ROLE` behind TimelockController (48h minimum)
3. Ossify the contract once stable
4. Enable `merkleRootsRequired` after setting initial merkle roots
5. Document role holders in a public registry

---

## Static Analysis Summary

### Solhint

**0 errors, 58 warnings:**

| Category | Count | Status |
|----------|-------|--------|
| `gas-small-strings` (typehash keccak) | 6 | Unavoidable -- EIP-712 typehash strings must exceed 32 bytes |
| `gas-indexed-events` | 11 | Design choice -- only 3 indexed params per event; non-indexed params are intentional |
| `not-rely-on-time` | 10 | All justified for daily/epoch rate limiting |
| `gas-strict-inequalities` | 15 | All correct -- tier boundaries and rate limits require inclusive comparisons |
| `code-complexity` | 7 | Inherent to relayed claim validation (signature + registration + KYC + rate limit) |
| `ordering` | 1 | Constants after state variables (storage gap preservation constraint) |
| `max-states-count` | 1 | 28 states (high but justified -- see I-02) |
| `no-unused-vars` | 1 | `newImplementation` in `_authorizeUpgrade` -- standard UUPS pattern |
| `use-natspec` | 2 | Missing `@param` on constructor (see I-01) |

**No security-critical findings from solhint.**

### Compilation

Contract compiles successfully with `npx hardhat compile` (Solidity 0.8.24). No compiler warnings specific to OmniRewardManager.

---

## Cross-Contract Dependency Analysis

### OmniRegistration (Critical Dependency)

| Function Called | Type | Access Control in Registration | Risk |
|----------------|------|-------------------------------|------|
| `getRegistration(user)` | View | None (public view) | Low |
| `hasKycTier1(user)` | View | None (public view) | Low |
| `totalRegistrations()` | View | None (public view) | Low |
| `hasCompletedFirstSale(user)` | View | None (public view) | Low |
| `markWelcomeBonusClaimed(user)` | State | `msg.sender == omniRewardManagerAddress` | Properly secured |
| `markFirstSaleBonusClaimed(user)` | State | `msg.sender == omniRewardManagerAddress` | Properly secured |

**Assessment:** The critical C-01 finding from Round 1 (missing access control on mark functions) is fully fixed. OmniRegistration now restricts bonus marking to the OmniRewardManager contract address specifically (not a role, but a hardcoded address check via `omniRewardManagerAddress`).

### OmniCoin (Token Dependency)

All interactions use `SafeERC20.safeTransfer()`. The OmniCoin contract is a standard ERC-20 with no transfer hooks, fee-on-transfer, or rebasing mechanics that could interfere with the reward manager's accounting.

### OmniForwarder (ERC-2771 Dependency)

The forwarder address is immutable (set in constructor). The forwarder is a thin wrapper around OpenZeppelin's `ERC2771Forwarder` with no admin functions. The trust assumption is documented and accepted.

---

## Incomplete Code / Stubs / TODOs

**No instances found.** The contract contains no TODO comments, stub implementations, mock objects, or "in production" comments. All functions are fully implemented.

---

## Remediation Priority

| Priority | Finding | Action | Effort |
|----------|---------|--------|--------|
| 1 (BEFORE MAINNET) | M-01 | Add `address(0)` check to `claimFirstSaleBonusRelayed` | 1 line |
| 2 (BEFORE MAINNET) | M-02 | Add event emission to `setMerkleRootsRequired` | 5 lines |
| 3 (BEFORE MAINNET) | M-03 | Add `OddaoAddressNotSet` revert to `_distributeReferralRewards` | 1 line |
| 4 (STANDARD) | L-01 | Add `whenNotPaused` to `updateMerkleRoot` | 1 word |
| 5 (STANDARD) | L-02 | Move nonce increments earlier in relayed functions | Reorder ~5 lines each |
| 6 (LOW) | L-03 | Add `maxIterations` param to exhaustion estimate | Optional |
| 7 (LOW) | L-04 | Document or add `getTotalPendingReferralBonuses()` view | 5 lines |
| 8 (LOW) | L-05 | Clarify `referralBonusesEarned` NatSpec | NatSpec update |
| 9 (INFORMATIONAL) | I-01 | Add `@param` to constructor NatSpec | 1 line |
| 10 (INFORMATIONAL) | I-02 | Accept or suppress `max-states-count` | Comment |
| 11 (INFORMATIONAL) | I-03 | Accept unused variable warning | No change |
| 12 (INFORMATIONAL) | I-04 | Accept strict inequality warnings | No change |

---

## Summary of Contract Quality

The OmniRewardManager has reached a high level of engineering quality after 7 audit rounds. Key quality indicators:

**Strengths:**
- Pre-funded pools with no minting capability (eliminates infinite mint vectors)
- SafeERC20 on all 13 token transfer sites
- ReentrancyGuard on all 11 external state-modifying functions
- 6-layer Sybil defense (phone + email + social + KYC + rate limit + one-per-address)
- EIP-712 trustless relayed claims (3 functions)
- Dual-track referral rate limiting (daily global + per-epoch per-referrer)
- Pool accounting invariants mathematically verified
- Ossification capability for permanent immutability
- 48-hour timelock on registration contract changes
- Role separation enforced at initialization
- Storage gaps preserved for UUPS upgrade safety

**Weaknesses (all Low/Informational):**
- 58 solhint warnings (all acceptable, none security-critical)
- 7 functions exceed cyclomatic complexity limit of 7 (inherent to multi-step claim validation)
- 28 state declarations exceed recommended 20 (required for comprehensive rate limiting)
- View function accounting does not distinguish pending vs. distributed referral bonuses

**No Critical or High findings.** The 3 Medium findings are straightforward fixes (1 missing check, 1 missing event, 1 silent skip). The contract is suitable for mainnet deployment after addressing the Medium findings.

---

*Generated by Claude Code Audit Agent -- Round 7 Deep Security Review*
*Date: 2026-03-13 14:14 UTC*
*Contract: OmniRewardManager.sol (2,155 lines, Solidity 0.8.24)*
*Previous audits: Round 1 (2026-02-20, 19 findings), Round 6 (2026-03-10, 10 findings)*
*Static analysis: Solhint 0 errors, 58 warnings (all acceptable)*
*Compilation: Clean (no errors or warnings)*
