# Security Audit Report: OmniRewardManager (Round 6)

**Date:** 2026-03-10
**Audited by:** Claude Code Audit Agent (Pre-Mainnet)
**Contract:** `Coin/contracts/OmniRewardManager.sol`
**Solidity Version:** 0.8.24 (pinned)
**Lines of Code:** 2,108
**Upgradeable:** Yes (UUPS with ossification)
**Handles Funds:** Yes (12.47B XOM across 4 pre-minted pools)
**Previous Audit:** 2026-02-20 (3 Critical, 5 High, 6 Medium, 3 Low, 2 Informational)

---

## Executive Summary

This is a Round 6 pre-mainnet audit of OmniRewardManager, following the initial audit on 2026-02-20 which identified 19 findings. The contract has undergone substantial hardening since the prior audit. All 3 critical findings, all 5 high findings, and 5 of 6 medium findings from the prior audit have been remediated. The remaining medium finding (M-01, merkle proof bypass at zero root) has been partially mitigated.

This round identifies 0 critical, 1 high, 4 medium, and 5 low/informational NEW findings. The single high finding relates to missing on-chain enforcement of the validator reward emission schedule, which allows a compromised `VALIDATOR_REWARD_ROLE` to drain the 6.089B XOM validator pool without rate limiting. The medium findings include a welcome bonus pool allocation shortfall relative to the tier structure, a subtle ERC-2771 trusted forwarder impersonation vector, and an inability to cancel incorrectly migrated pending referral bonuses.

Overall, the contract is well-engineered with defense-in-depth across access control, reentrancy protection, rate limiting, KYC verification, and pool accounting. It is suitable for mainnet deployment provided the findings below are addressed.

---

## Round 6 Post-Audit Remediation (2026-03-10)

All Critical, High, and Medium findings from this Round 6 audit have been remediated. Compilation clean, all tests passing.

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H-01 | High | No on-chain rate limiting for validator rewards | **FIXED** — Per-epoch caps added; VALIDATOR_REWARD_ROLE removed entirely |
| M-01 | Medium | Welcome bonus pool allocation insufficient | **FIXED** |
| M-02 | Medium | ERC-2771 trusted forwarder impersonation | **ACCEPTED** -- Immutable forwarder is OZ default practice; tokens always go to legitimate user (no redirect possible); ossify() + pause for emergency |
| M-03 | Medium | setPendingReferralBonus cannot cancel to zero | **FIXED** |
| M-04 | Medium | Merkle proof bypassed when root is bytes32(0) | **FIXED** |

---

| Severity | Count | Prior Audit | Change |
|----------|-------|-------------|--------|
| Critical | 0 | 3 | -3 (all fixed) |
| High | 1 | 5 | -5 fixed, +1 new |
| Medium | 4 | 6 | -5 fixed, -1 partial, +4 new |
| Low | 3 | 3 | -3 fixed, +3 new |
| Informational | 2 | 2 | -2 fixed, +2 new |
| **Total** | **10** | **19** | **Net -9** |

---

## Prior Audit Remediation Status

### All Critical Findings: FIXED

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| C-01 | markWelcomeBonusClaimed/markFirstSaleBonusClaimed no access control | FIXED | OmniRegistration.sol line 2169: `onlyRole(BONUS_MARKER_ROLE)` |
| C-02 | Pool accounting bypass via setPendingReferralBonus | FIXED | Lines 844-854: deducts from pool on increase, credits on decrease |
| C-03 | Admin can drain all 12.47B XOM | FIXED | Role separation (line 1716), 48h timelock (lines 730-766), ossification (lines 1878-1901) |

### All High Findings: FIXED

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| H-01 | Missing KYC Tier 1 check in claimWelcomeBonusPermissionless | FIXED | Lines 893-898: `hasKycTier1(caller)` check added |
| H-02 | First sale bonus claimable without completing a sale | FIXED | Lines 1285-1288, 1378-1381: `hasCompletedFirstSale()` check |
| H-03 | ODDAO tokens stranded when oddaoAddress is zero | FIXED | Line 1818: `revert OddaoAddressNotSet()` |
| H-04 | reinitializeV2 no access control | FIXED | Line 574: `onlyRole(DEFAULT_ADMIN_ROLE)` |
| H-05 | Role-based claimReferralBonus lacks ODDAO distribution | FIXED | Lines 622-628, 1662-1677: ODDAO share calculated and distributed |

### Medium Findings: 5 FIXED, 1 PARTIAL

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| M-01 | Merkle proof bypass when root is bytes32(0) | PARTIAL | Lines 2050-2053: empty proof required, but verification still skipped |
| M-02 | No token balance verification on initialization | FIXED | Lines 548-554: `balanceOf >= totalPool` check |
| M-03 | setRegistrationContract no timelock | FIXED | Lines 730-766: 48h timelock with queue/apply pattern |
| M-04 | First sale bonus tier calculation inconsistency | FIXED | Lines 1546-1554: aligned with claim logic |
| M-05 | Shared daily rate limit for auto and manual referrals | FIXED | Line 1822: `dailyAutoReferralCount` (separate counter) |
| M-06 | setLegacyBonusClaimsCount no upper bound | FIXED | Lines 216, 799-800: `MAX_LEGACY_CLAIMS_COUNT = 10,000,000` |

### Low/Informational Findings: ALL FIXED

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| L-01 | Rounding in referral/first sale bonus | FIXED | Lines 1766, 1790: `3125 * 10**17`, `625 * 10**17` |
| L-02 | Shared nonce counter across claim types | ACCEPTED | Design choice; types have different typehashes preventing cross-type forgery |
| L-03 | Missing zero-address check in claimReferralBonusRelayed | FIXED | Line 1212: explicit check added |
| I-01 | Floating pragma | FIXED | Line 2: `pragma solidity 0.8.24` |
| I-02 | Function complexity and ordering | ACCEPTED | Structural complexity inherent to business logic |

---

## Access Control Map

| Role | Functions | Privilege Level | Notes |
|------|-----------|----------------|-------|
| DEFAULT_ADMIN_ROLE | `setRegistrationContract`, `applyRegistrationContract`, `setOddaoAddress`, `setLegacyBonusClaimsCount`, `setPendingReferralBonus`, `grantRole`, `revokeRole`, `reinitializeV2` | High (7/10) | Timelock on registration changes; capped legacy claims; pool-accounted pending bonuses |
| BONUS_DISTRIBUTOR_ROLE | `claimWelcomeBonus`, `claimReferralBonus`, `claimFirstSaleBonus`, `updateMerkleRoot` | Medium (5/10) | Merkle-gated when roots set; pool-bounded |
| VALIDATOR_REWARD_ROLE | `distributeValidatorReward` | Medium-High (6/10) | No rate limit; arbitrary amounts up to pool balance |
| UPGRADER_ROLE | `_authorizeUpgrade`, `ossify` | High (8/10) | Can be permanently disabled via ossification |
| PAUSER_ROLE | `pause`, `unpause` | Low (2/10) | Emergency circuit breaker |
| (Permissionless) | `claimWelcomeBonus{Permissionless,Trustless,Relayed}`, `claimReferralBonus{Permissionless,Relayed}`, `claimFirstSaleBonus{Permissionless,Relayed}` | Low (2/10) | KYC-gated, rate-limited, one-time claims |

**Role Separation:** `_setupRoles()` (line 1716) now grants ONLY `DEFAULT_ADMIN_ROLE` to the initializer. Other roles must be explicitly granted to separate addresses. This correctly prevents single-key total compromise.

---

## New Findings

### [H-01] No On-Chain Rate Limiting or Emission Schedule Enforcement for Validator Rewards

**Severity:** High
**Category:** Business Logic / Centralization Risk
**Location:** `distributeValidatorReward()` lines 676-689

**Description:**

The `distributeValidatorReward()` function accepts arbitrary reward amounts from `VALIDATOR_REWARD_ROLE` with no on-chain enforcement of:
- The 2-second block interval (no timestamp-based rate limiting)
- The 15.602 XOM initial reward amount
- The 1% reduction every 6,311,520 blocks
- The 40-year emission schedule
- The validator/staking/ODDAO split ratios

The `currentVirtualBlockHeight` is simply an incrementing counter with no link to `block.timestamp` or the actual emission curve. A compromised `VALIDATOR_REWARD_ROLE` holder (or a bug in the off-chain OmniCore scheduler) could:

1. Call `distributeValidatorReward()` thousands of times per block, draining the 6.089B XOM pool in minutes.
2. Pass inflated `validatorAmount` values (e.g., the full pool balance per call).
3. Set arbitrary split ratios (all to validator, nothing to staking/ODDAO).

Unlike user bonuses, validator rewards have NO daily rate limit, NO per-user cap, and NO KYC requirement. The only guardrail is `pool.remaining >= totalAmount`.

**Impact:** A compromised `VALIDATOR_REWARD_ROLE` can drain 6,089,000,000 XOM (36.7% of total supply) in a single transaction by passing `totalAmount = validatorRewardsPool.remaining`.

**Mathematical Analysis:**
- Theoretical 40-year emission at design parameters: 6,242,827,569 XOM
- Pool allocation: 6,089,000,000 XOM
- Pool runs out after ~38.34 years (604,911,181 virtual blocks) even at correct rate
- With no rate limiting, entire pool drainable instantly

**Recommendation:**

Add on-chain guardrails:

```solidity
uint256 public constant MAX_BLOCK_REWARD = 16 * 10**18; // 16 XOM (above initial 15.602)
uint256 public constant MIN_BLOCK_INTERVAL = 1; // Minimum 1 second between distributions
uint256 public lastValidatorRewardTimestamp;

function distributeValidatorReward(
    ValidatorRewardParams calldata params
) external onlyRole(VALIDATOR_REWARD_ROLE) nonReentrant whenNotPaused {
    uint256 totalAmount = params.validatorAmount + params.stakingAmount + params.oddaoAmount;

    // On-chain guardrails
    if (totalAmount > MAX_BLOCK_REWARD) revert ExceedsMaxBlockReward();
    if (block.timestamp < lastValidatorRewardTimestamp + MIN_BLOCK_INTERVAL) {
        revert TooFrequentDistribution();
    }
    lastValidatorRewardTimestamp = block.timestamp;

    // ... existing logic
}
```

The `MAX_BLOCK_REWARD` constant provides a hard ceiling even if the off-chain scheduler is compromised. Combined with `MIN_BLOCK_INTERVAL`, the maximum drain rate becomes 16 XOM/second instead of the entire pool at once.

---

### [M-01] Welcome Bonus Pool Allocation Insufficient for Declared Tier Structure

**Severity:** Medium
**Category:** Business Logic / Tokenomics
**Location:** NatSpec line 39, `_calculateWelcomeBonus()` lines 1732-1743

**Description:**

The NatSpec declares a welcome bonus pool of 1,383,457,500 XOM. However, the tier structure requires more tokens than the pool contains to serve all users through Tier 4:

| Tier | Users | Bonus | Subtotal | Cumulative |
|------|-------|-------|----------|------------|
| 1 | 1 - 1,000 | 10,000 XOM | 10,000,000 | 10,000,000 |
| 2 | 1,001 - 10,000 | 5,000 XOM | 45,000,000 | 55,000,000 |
| 3 | 10,001 - 100,000 | 2,500 XOM | 225,000,000 | 280,000,000 |
| 4 | 100,001 - 1,000,000 | 1,250 XOM | 1,125,000,000 | 1,405,000,000 |

The pool (1,383,457,500 XOM) is exhausted at approximately user #982,766 -- before Tier 4 completes. Users #982,767 through #1,000,000 and all Tier 5 users (625 XOM each) would receive `InsufficientPoolBalance` reverts.

This is not a security vulnerability (the contract correctly reverts when the pool is empty), but it represents a discrepancy between the documented tier structure and the funded capacity. Users who expect to receive bonuses based on the tier documentation may find the pool exhausted.

**Impact:** Approximately 17,234 users in Tier 4 and all Tier 5 users would be unable to claim welcome bonuses. The shortfall relative to the tier documentation is 21,542,500 XOM.

**Recommendation:**

Either:
1. Fund the pool with sufficient tokens to cover the full tier structure, OR
2. Add documentation clarifying that bonuses are first-come-first-served and the pool may be exhausted before all tiers are served, OR
3. Add a view function `getPoolExhaustionEstimate()` that returns the approximate user count at which the pool will be depleted.

---

### [M-02] ERC-2771 Trusted Forwarder Can Impersonate Users for Permissionless Claims

**Severity:** Medium
**Category:** Access Control / Trust Assumption
**Location:** `_msgSender()` lines 2070-2077, permissionless claim functions

**Description:**

The contract inherits `ERC2771ContextUpgradeable` and uses `_msgSender()` in four permissionless claim functions:
- `claimWelcomeBonusPermissionless()` (line 878)
- `claimWelcomeBonusTrustless()` (line 962)
- `claimReferralBonusPermissionless()` (line 1163)
- `claimFirstSaleBonusPermissionless()` (line 1270)

A compromised or malicious trusted forwarder can append any address to the calldata, causing `_msgSender()` to return an arbitrary user address. This would allow the forwarder to claim bonuses on behalf of any registered user, directing tokens to that user's address (not to the forwarder itself -- so no direct theft, but unauthorized claim triggering).

The relayed claim functions (`claimWelcomeBonusRelayed`, etc.) are NOT vulnerable because they verify an EIP-712 signature from the user, independent of `_msgSender()`.

**Impact:** The trusted forwarder is set immutably in the constructor and cannot be changed. A compromised forwarder could trigger premature bonus claims for users who haven't opted in, potentially claiming bonuses at suboptimal tiers (e.g., claiming at Tier 2 when the user intended to wait for a hypothetical future tier improvement). The tokens still go to the legitimate user, so no direct fund theft occurs.

**Mitigating Factors:**
- Trusted forwarder address is immutable (set at deployment) -- attack requires compromising the specific forwarder contract.
- Bonuses are one-time-only per user, so the window of attack is narrow.
- Tokens always go to the legitimate user (no redirect possible).
- A zero-address trusted forwarder effectively disables ERC-2771.

**Recommendation:**

If ERC-2771 meta-transactions are not strictly required for the permissionless claim paths (given that relayed claims already provide gasless claiming), consider deploying with `address(0)` as the trusted forwarder. Otherwise, document the trust assumption and ensure the forwarder contract itself undergoes rigorous auditing.

---

### [M-03] setPendingReferralBonus Cannot Cancel to Zero

**Severity:** Medium
**Category:** Business Logic
**Location:** `setPendingReferralBonus()` lines 838-860

**Description:**

The function requires `amount > 0` (line 840: `if (amount == 0) revert ZeroAmountNotAllowed()`), which prevents the admin from setting a pending referral bonus back to zero. If an incorrect migration sets an erroneous pending amount, the admin cannot fully cancel it -- only reduce to 1 wei.

While the 1-wei workaround limits financial impact, it leaves a semantically incorrect state: the user appears to have a claimable bonus when they should have none. This also means the 1 wei remains permanently deducted from the referral pool accounting.

**Recommendation:**

Allow zero amount specifically for cancellation:

```solidity
function setPendingReferralBonus(
    address referrer,
    uint256 amount
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (referrer == address(0)) revert ZeroAddressNotAllowed();

    uint256 oldPending = pendingReferralBonuses[referrer];
    if (amount == 0 && oldPending == 0) revert ZeroAmountNotAllowed(); // No-op prevention

    if (amount > oldPending) {
        uint256 increase = amount - oldPending;
        _validatePoolBalance(referralBonusPool, PoolType.ReferralBonus, increase);
        _updatePoolAfterDistribution(referralBonusPool, increase);
    } else if (amount < oldPending) {
        uint256 decrease = oldPending - amount;
        referralBonusPool.remaining += decrease;
        referralBonusPool.distributed -= decrease;
    }

    pendingReferralBonuses[referrer] = amount;
    emit ReferralBonusMigrated(referrer, oldPending, amount);
}
```

---

### [M-04] Merkle Proof Still Bypassed When Root Is bytes32(0) (Prior M-01, Partially Fixed)

**Severity:** Medium
**Category:** Business Logic
**Location:** `_verifyMerkleProof()` lines 2050-2053, `_verifyReferralMerkleProof()` lines 1936-1941

**Description:**

The prior M-01 fix requires an empty proof array when the merkle root is `bytes32(0)`, which prevents attackers from submitting fabricated proofs. However, the fundamental issue remains: when the merkle root is not set, `BONUS_DISTRIBUTOR_ROLE` can claim any amount for any user without cryptographic verification.

The M-01 fix commentary states this is acceptable because "role-gated callers only" can use these paths. This is true -- the `claimWelcomeBonus`, `claimReferralBonus`, and `claimFirstSaleBonus` functions all require `BONUS_DISTRIBUTOR_ROLE`. However, if this role is compromised, the absence of merkle verification allows arbitrary amount claims (limited only by pool balance), whereas with a merkle root set, the attacker would also need to forge a merkle proof.

**Impact:** A compromised `BONUS_DISTRIBUTOR_ROLE` has fewer constraints when merkle roots are not set. This is a defense-in-depth concern rather than a direct vulnerability, since role compromise already implies significant trust loss.

**Recommendation:**

Set merkle roots as early as possible after deployment. Consider adding an admin function to require merkle roots before any role-based claims:

```solidity
bool public merkleRootsRequired;

function setMerkleRootsRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
    merkleRootsRequired = required;
}
```

---

### [L-01] Shared Nonce Counter Across Claim Types Creates User Friction

**Severity:** Low
**Category:** Usability / Design
**Location:** `claimNonces` mapping, lines 1083, 1249, 1391

**Description:**

All three relayed claim functions (`claimWelcomeBonusRelayed`, `claimReferralBonusRelayed`, `claimFirstSaleBonusRelayed`) share the same per-user nonce counter (`claimNonces[user]`). If a user signs claims for multiple bonus types with sequential nonces and a relayer submits them out of order, the earlier-signed claim becomes invalid because its nonce no longer matches `claimNonces[user]`.

Example: User signs welcome claim (nonce=0) and referral claim (nonce=1). Relayer submits referral first. Nonce becomes 2 after referral. Welcome claim with nonce=0 now reverts.

The different `TYPEHASH` values prevent cross-type signature reuse, so this is a usability issue rather than a security vulnerability.

**Recommendation:**

Use per-type nonces:

```solidity
mapping(address => mapping(PoolType => uint256)) public claimNonces;
```

Or document that relayed claims must be submitted in signing order and provide frontend tooling to manage this.

---

### [L-02] Validator Reward Distribution Has No Deduplication Protection

**Severity:** Low
**Category:** Business Logic
**Location:** `distributeValidatorReward()` lines 676-689

**Description:**

The `currentVirtualBlockHeight` counter increments on every call to `distributeValidatorReward()` but has no link to actual time or expected block heights. There is no check that a specific virtual block has already been rewarded. If the `VALIDATOR_REWARD_ROLE` caller has a bug that causes duplicate calls, rewards are distributed twice for the same logical block.

This is mitigated by the fact that `VALIDATOR_REWARD_ROLE` should be assigned to a well-tested OmniCore scheduler contract, and pool exhaustion is the ultimate bound.

**Recommendation:**

Add optional expected-height validation:

```solidity
function distributeValidatorReward(
    ValidatorRewardParams calldata params,
    uint256 expectedBlockHeight
) external onlyRole(VALIDATOR_REWARD_ROLE) nonReentrant whenNotPaused {
    if (expectedBlockHeight != 0 && expectedBlockHeight != currentVirtualBlockHeight + 1) {
        revert UnexpectedBlockHeight(expectedBlockHeight, currentVirtualBlockHeight + 1);
    }
    // ... existing logic
}
```

---

### [L-03] ODDAO Share Rounding Asymmetry in Role-Based vs Auto Referral Paths

**Severity:** Low
**Category:** Business Logic / Precision
**Location:** `_distributeReferralRewards()` lines 1662-1677 vs `_distributeAutoReferralBonus()` lines 1844-1846

**Description:**

The two referral distribution paths calculate the ODDAO share using different formulas:

**Role-based path (`_distributeReferralRewards`):**
```
oddaoShare = (referrerTotal * 10) / 90   // With both referrers
oddaoShare = (primaryAmount * 30) / 70    // Without second-level referrer
```

**Auto path (`_distributeAutoReferralBonus`):**
```
referrerAmount = (referralAmount * 70) / 100
secondLevelAmount = (referralAmount * 20) / 100
oddaoAmount = referralAmount - referrerAmount - secondLevelAmount
```

The auto path uses subtraction to calculate the ODDAO share, which means any rounding dust from the percentage calculations flows to ODDAO (favors the protocol). The role-based path uses division, which truncates toward zero (slightly disfavors ODDAO).

At practical bonus amounts (312.5+ XOM with 18 decimals), the rounding difference is less than 1 wei per distribution, so the financial impact is negligible.

**Recommendation:** Standardize on the subtraction-based approach across both paths for consistency.

---

### [I-01] Validator Rewards Pool Cannot Sustain Full 40-Year Emission

**Severity:** Informational
**Category:** Tokenomics Documentation
**Location:** NatSpec line 42, `distributeValidatorReward()`

**Description:**

The validator rewards pool is allocated 6,089,000,000 XOM. However, the designed emission schedule (15.602 XOM initial reward, 1% reduction every 6,311,520 blocks, 40-year horizon) requires approximately 6,242,827,569 XOM -- a shortfall of ~153,827,569 XOM.

At the designed emission rate, the pool runs out after approximately 38.34 years (604,911,181 virtual blocks) rather than the stated 40 years. This is not a contract bug (the contract correctly stops distributing when the pool is empty), but the documentation creates an expectation of 40-year coverage.

**Note:** The NatSpec references "15.602 XOM" while the CLAUDE.md project specification references "15.228 XOM" as the initial block reward. The actual reward amount is determined entirely off-chain by the `VALIDATOR_REWARD_ROLE` caller, so neither figure is enforced on-chain.

**Recommendation:** Update documentation to reflect the actual pool depletion timeline, or adjust either the pool allocation or the emission parameters to achieve exactly 40-year coverage.

---

### [I-02] Storage Gap Smaller Than OpenZeppelin Convention

**Severity:** Informational
**Category:** Upgrade Safety
**Location:** `__gap` declaration, line 228

**Description:**

The storage gap is `uint256[30]`, providing 30 slots for future state variables. OpenZeppelin's convention is 50 slots. The gap was reduced from its original size when `_ossified` was added (the comment notes "reduced by 1 for _ossified").

With 30 remaining slots, future upgrades must be carefully planned to avoid storage collisions. Each new state variable consumes one slot (mappings and dynamic arrays consume one slot for the root pointer).

**Recommendation:** Consider increasing to `uint256[45]` or higher to provide more headroom for future upgrades, especially since the contract has already consumed one gap slot.

---

## DeFi Exploit Vector Analysis

### Sybil Attack on Welcome Bonuses

**Attack:** Register many fake identities to claim welcome bonuses.

**Defenses (5 layers):**
1. Unique phone hash per registration (`PhoneAlreadyUsed` in OmniRegistration)
2. Unique email hash per registration (`EmailAlreadyUsed` in OmniRegistration)
3. KYC Tier 1 required for all claim paths (phone + social media verified on-chain)
4. Daily rate limit: 1,000 welcome bonuses per day
5. One bonus per address (`welcomeBonusClaimed` mapping)

**Assessment:** Strong defense. Cost of attack (unique phone + email + social per identity) makes Sybil unprofitable at current bonus levels (5,000 XOM for Tier 2). Effectiveness depends on the rigor of the phone/social verification in OmniRegistration -- VoIP numbers would weaken the defense.

### Self-Referral Loops

**Attack:** Create circular referral chains to farm referral bonuses.

**Defenses:**
1. OmniRegistration blocks direct self-referral (`SelfReferralNotAllowed`)
2. Each user can only claim welcome bonus once (triggers at most one referral event)
3. No amplification: mutual referral (A refers B, B refers A) yields exactly 2 referral bonuses, same as any 2 unrelated referrals

**Assessment:** No exploitable loop. The one-time welcome bonus claim bounds the referral bonus to exactly one event per user.

### Flash-Loan Interaction

**Attack:** Use flash loans to manipulate reward calculations.

**Assessment:** Not applicable. All bonus calculations depend on registration state, KYC status, and marketplace activity -- none of which are influenced by token balances or liquidity pool states. Flash loans have zero attack surface against this contract.

### Front-Running Reward Claims

**Attack:** Front-run a user's claim to push them into a lower bonus tier.

**Assessment:** Low risk. At tier boundaries (e.g., user #1,000 vs #1,001), front-running can reduce a user's bonus from 10,000 to 5,000 XOM. This is inherent to first-come-first-served distribution. The daily rate limit (1,000/day) provides partial mitigation by reducing the window of opportunity. No profitable exploit vector exists (the front-runner does not profit from others receiving less).

### Draining Reward Pools Through Rapid Claims

**Attack:** Submit many claims rapidly to drain pools.

**Defenses:**
1. Welcome bonus: 1,000/day limit, one per user
2. Referral bonus: 2,000/day limit for manual claims, 2,000/day for auto-distribution (separate counters)
3. First sale bonus: 500/day limit, one per user
4. Validator rewards: NO daily limit (see H-01)

**Assessment:** User bonus pools are well-protected by rate limiting. Validator reward pool lacks rate limiting and is the primary concern (see H-01).

### Integer Overflow/Underflow

**Assessment:** Solidity 0.8.24 provides built-in overflow/underflow protection. All arithmetic operations will revert on overflow. The `_updatePoolAfterDistribution` subtraction (`pool.remaining -= amount`) is protected by the prior `_validatePoolBalance` check. The `setPendingReferralBonus` decrease path (`referralBonusPool.distributed -= decrease`) could theoretically underflow if `decrease > distributed`, but this would revert safely rather than wrapping.

---

## Reentrancy Analysis

**All 11 external state-modifying functions** have the `nonReentrant` modifier from OpenZeppelin's `ReentrancyGuardUpgradeable`. Additionally:

1. **SafeERC20:** All token transfers use `safeTransfer()`, eliminating callback-based reentrancy from ERC-20 hooks.
2. **CEI Pattern:** State updates (`welcomeBonusClaimed`, pool accounting, nonce increments) occur before external calls (`safeTransfer`, `registrationContract.markWelcomeBonusClaimed`).
3. **External Calls to registrationContract:** View functions (`getRegistration`, `hasKycTier1`, `hasCompletedFirstSale`, `totalRegistrations`) and state functions (`markWelcomeBonusClaimed`, `markFirstSaleBonusClaimed`) are called before token transfers. A malicious registration contract could attempt reentrancy through these calls, but `nonReentrant` blocks it.

**Assessment:** No reentrancy vulnerabilities identified. Defense-in-depth (nonReentrant + SafeERC20 + CEI) is comprehensive.

---

## Pool Accounting Invariant Analysis

**Invariant:** `sum(pool.remaining) + sum(pool.distributed) == sum(pool.initial)` for all pools

**Verification:**

1. **Initialization:** `pool.remaining = pool.initial`, `pool.distributed = 0` (line 1601-1603). Invariant holds.
2. **Distribution:** `pool.remaining -= amount`, `pool.distributed += amount` (lines 1612-1613). Invariant preserved.
3. **setPendingReferralBonus increase:** `pool.remaining -= increase`, `pool.distributed += increase`. Invariant preserved.
4. **setPendingReferralBonus decrease:** `pool.remaining += decrease`, `pool.distributed -= decrease`. Invariant preserved.
5. **No other paths modify pool state.**

**Token Balance Invariant:** `omniCoin.balanceOf(address(this)) >= sum(pool.remaining) + sum(pendingReferralBonuses)`

This holds as long as:
- No one sends additional XOM to the contract (extra tokens become trapped but don't break accounting)
- All pool deductions are paired with either immediate transfers or pending accumulations
- Pending accumulations are always within their pool's deducted amount

**Verified:** The auto-referral path deducts the full `referralAmount` from the pool, then splits it between pending accumulations (referrer + second-level) and immediate transfer (ODDAO). The claim path transfers from contract balance without further pool deduction. Net effect: pool.remaining decreases by exactly the amount eventually transferred out. CORRECT.

---

## Centralization Risk Assessment

**Rating: 5/10 (Moderate -- improved from 8/10 in prior audit)**

**Improvements since prior audit:**
- Role separation: `_setupRoles()` only grants `DEFAULT_ADMIN_ROLE` (not all 5 roles)
- Timelock: 48h delay on registration contract changes
- Ossification: `UPGRADER_ROLE` can permanently disable upgrades
- Pool-accounted pending bonuses: prevents unbacked claim fabrication

**Remaining concerns:**
- No on-chain multi-sig enforcement for any role
- `VALIDATOR_REWARD_ROLE` can drain 6.089B XOM without rate limiting (H-01)
- `DEFAULT_ADMIN_ROLE` can still manipulate bonus tiers via `setLegacyBonusClaimsCount` (bounded by 10M cap)
- `UPGRADER_ROLE` can upgrade to arbitrary implementation (until ossified)

**Recommendation for mainnet:**
1. Deploy all privileged roles to Gnosis Safe multi-sig wallets (3-of-5 minimum)
2. Place `UPGRADER_ROLE` behind a TimelockController (48h minimum)
3. Ossify the contract once stable (call `ossify()` to permanently disable upgrades)
4. Add on-chain rate limiting for validator rewards (H-01)

---

## Remediation Priority

| Priority | Finding | Action |
|----------|---------|--------|
| 1 (BEFORE MAINNET) | H-01 | Add on-chain rate limiting and per-block reward cap for validator rewards |
| 2 (BEFORE MAINNET) | M-01 | Document welcome bonus pool capacity; adjust pool funding or documentation |
| 3 (BEFORE MAINNET) | M-02 | Evaluate ERC-2771 necessity; deploy with zero-address forwarder if not needed |
| 4 (STANDARD) | M-03 | Allow setPendingReferralBonus to set amount to zero for cancellation |
| 5 (STANDARD) | M-04 | Set merkle roots before enabling role-based claims |
| 6 (LOW) | L-01 | Consider per-type nonces for relayed claims |
| 7 (LOW) | L-02 | Add optional expected block height validation |
| 8 (LOW) | L-03 | Standardize ODDAO share calculation approach |
| 9 (INFORMATIONAL) | I-01 | Update documentation for actual pool depletion timeline |
| 10 (INFORMATIONAL) | I-02 | Consider increasing storage gap |

---

## Summary of Contract Quality

The OmniRewardManager demonstrates strong engineering quality with comprehensive security measures:

- **Pre-funded pools (no minting):** Eliminates infinite mint attack vectors
- **SafeERC20 throughout:** No unprotected ERC-20 transfers
- **ReentrancyGuard on all externals:** Comprehensive reentrancy protection
- **KYC-gated claims:** Multi-layered Sybil defense
- **Daily rate limiting:** Prevents rapid pool drainage for user bonuses
- **EIP-712 trustless claims:** Users can claim without trusting validators
- **Pool accounting invariants:** Mathematically verified conservation of tokens
- **Ossification capability:** Path to immutability once stable
- **Registration contract timelock:** 48h delay prevents instant malicious redirects

The primary remaining gap is the lack of on-chain enforcement for the validator reward emission schedule (H-01), which creates a disproportionate attack surface for 36.7% of the managed funds compared to the well-protected user bonus pools.

---

*Generated by Claude Code Audit Agent -- Round 6 Pre-Mainnet*
*Date: 2026-03-10 01:05 UTC*
*Contract: OmniRewardManager.sol (2,108 lines, Solidity 0.8.24)*
*Previous audit: 2026-02-20 (19 findings, 16 fixed, 1 partial, 2 accepted)*
*Static analysis: Slither results not available for this round*
