# Cross-System Adversarial Review: Sybil Attack Vectors

**Audit Type:** Cross-System Adversarial Review
**Focus:** Sybil Attack Vectors Across the OmniBazaar Smart Contract Ecosystem
**Date:** 2026-03-13 21:09 UTC
**Auditor:** Claude Opus 4.6 (Round 7)
**Scope:** OmniRewardManager, OmniRegistration, OmniParticipation, Bootstrap, OmniCore, OmniValidatorRewards, LegacyBalanceClaim, ReputationCredential

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Attack Vector 1: Welcome Bonus Gaming](#attack-vector-1-welcome-bonus-gaming)
3. [Attack Vector 2: Referral Abuse](#attack-vector-2-referral-abuse)
4. [Attack Vector 3: KYC Bypass](#attack-vector-3-kyc-bypass)
5. [Attack Vector 4: Participation Score Manipulation](#attack-vector-4-participation-score-manipulation)
6. [Attack Vector 5: Validator Qualification Gaming](#attack-vector-5-validator-qualification-gaming)
7. [Attack Vector 6: Legacy Claim Double-Dipping](#attack-vector-6-legacy-claim-double-dipping)
8. [Cross-System Compound Attack Scenarios](#cross-system-compound-attack-scenarios)
9. [Summary of Findings](#summary-of-findings)
10. [Recommendations](#recommendations)

---

## Executive Summary

This review systematically analyzes Sybil attack vectors across the OmniBazaar smart contract ecosystem. The contracts implement a multi-layered defense-in-depth approach to Sybil resistance:

**Primary Defense Layers:**
- Phone hash uniqueness (OmniRegistration)
- Email hash uniqueness (OmniRegistration)
- Social media hash uniqueness (OmniRegistration)
- KYC Tier 1 requirement for bonuses (OmniRewardManager + OmniRegistration)
- Daily rate limits across all bonus types
- Per-referrer per-epoch rate limits (SYBIL-AP-02)
- Trusted verification key signatures (EIP-712)

**Critical Findings:** 2 High, 3 Medium, 4 Low, 2 Informational

The system has strong on-chain Sybil protections in place from prior audit rounds (SYBIL-H02, SYBIL-H05, SYBIL-AP-02). However, several cross-system attack vectors remain that could be exploited by sophisticated attackers operating at the boundaries between contracts.

---

## Attack Vector 1: Welcome Bonus Gaming

### 1.1 Can Multiple Wallets Claim Welcome Bonuses?

**On-Chain Protections (Strong):**

| Protection | Contract | Location | Effectiveness |
|---|---|---|---|
| `welcomeBonusClaimed[user]` mapping | OmniRewardManager | Line 158 | Prevents same address re-claiming |
| `reg.welcomeBonusClaimed` in Registration | OmniRegistration | Line 123 | Dual-tracked claim flag |
| KYC Tier 1 required | OmniRewardManager | Lines 926, 1011 | Requires phone + social verification |
| `usedPhoneHashes` uniqueness | OmniRegistration | Line 131 | Each phone can only register once |
| `usedSocialHashes` uniqueness | OmniRegistration | Line 173 | Each social account can only register once |
| `usedEmailHashes` uniqueness | OmniRegistration | Line 134 | Each email can only register once |
| Daily rate limit (1000/day) | OmniRewardManager | Line 106 | Global throughput limit |

**Attack Scenario: Multi-Phone Sybil Farm**

An attacker with access to many phone numbers (e.g., SIM farm, VoIP services) could:

1. Create N wallet addresses
2. Obtain N unique phone numbers (VoIP/SIM farm)
3. Obtain N unique social media accounts
4. Obtain N unique email addresses
5. Register each wallet via `selfRegisterTrustless()` with unique email
6. Submit phone verification via `submitPhoneVerification()` with unique phone
7. Submit social verification via `submitSocialVerification()` with unique social
8. Claim welcome bonus for each wallet

**Cost-Benefit Analysis:**

At current tier (position ~3997+, Tier 2), each welcome bonus is **5,000 XOM**.

- **Cost per Sybil identity:** Phone number (~$0.50-5), social media account (~$0.10-2), email (~$0)
- **Revenue per identity:** 5,000 XOM
- **Break-even:** Only profitable if XOM > ~$0.001 per token
- **Rate limited to:** 1,000 per day globally

**Severity:** MEDIUM (M-01)

**Assessment:** The on-chain uniqueness constraints (phone, social, email) are the primary defense. The weakness is that these are verified off-chain by the `trustedVerificationKey`. If the verification service has weak phone verification (e.g., accepting VoIP numbers), Sybil accounts become cheap to create. The contract has no mechanism to distinguish VoIP from real mobile numbers.

**Existing Mitigation:** The daily rate limit of 1,000 welcome bonuses caps the extraction rate. The KYC Tier 1 requirement adds friction. However, at 1,000/day for 5,000 XOM each, an attacker could extract 5,000,000 XOM per day.

**Recommendation:**
- The off-chain verification service MUST reject VoIP numbers and enforce carrier-grade phone verification
- Consider adding a minimum account age before welcome bonus eligibility (e.g., 7 days post-KYC-Tier-1)
- Consider reducing `MAX_DAILY_WELCOME_BONUSES` from 1,000 to 100 in early deployment


### 1.2 Trustless Registration Creates KYC Tier 0 Accounts

**Finding:** INFORMATIONAL (I-01)

`selfRegisterTrustless()` correctly sets `kycTier: 0` (OmniRegistration line 1038), requiring separate phone and social verification before KYC Tier 1. This is a proper defense -- email-only registration does NOT qualify for bonuses.

The attack surface is properly segmented: registration is cheap, but bonus claiming requires completing the full KYC Tier 1 flow.

---

## Attack Vector 2: Referral Abuse

### 2.1 Self-Referral Chains

**On-Chain Protections (Strong):**

| Protection | Contract | Location | Effectiveness |
|---|---|---|---|
| `SelfReferralNotAllowed` | OmniRegistration | Lines 818, 1018 | Cannot refer yourself |
| `ValidatorCannotBeReferrer` | OmniRegistration | Line 822 | Validator processing registration cannot self-deal |
| Referrer must be registered | OmniRegistration | Line 825 | Cannot use unregistered addresses |
| SYBIL-H02: Referrer must have KYC Tier 1 | OmniRegistration | Line 828 | Referrer must be verified |
| SYBIL-AP-02: 50 referrals per 7-day epoch | OmniRewardManager | Lines 116-119 | Per-referrer rate limit |
| Referrer KYC Tier 1 required for bonus accumulation | OmniRewardManager | Lines 1887-1890 | Both referrer and L2 referrer must have Tier 1 |
| Daily auto-referral limit (2000/day) | OmniRewardManager | Lines 1868-1872 | Global throughput limit |

**Attack Scenario: Two-Account Referral Loop**

An attacker creates two verified identities (A and B):

1. Account A registers, completes KYC Tier 1
2. Account B registers with A as referrer, completes KYC Tier 1
3. Attacker creates Sybil accounts C1...C50 each week, all referring A
4. Each Sybil claims welcome bonus, triggering referral bonus accumulation for A
5. A claims accumulated referral bonuses

**Revenue per Sybil referral:**
- At Tier 2 (position 3997+): referral bonus = 2,500 XOM
- 70% to primary referrer (A) = 1,750 XOM
- 10% to ODDAO = 250 XOM
- 20% to second-level referrer (or ODDAO if none) = 500 XOM

**Per-epoch cap:** 50 referrals * 1,750 XOM = 87,500 XOM per referrer per 7-day epoch

**Severity:** MEDIUM (M-02)

**Assessment:** The SYBIL-AP-02 per-referrer epoch limit (50 per 7 days) is a good defense but may be too generous. At 50 referrals per week, a single referrer can extract 87,500 XOM/week. The key weakness is that this limit only applies per-referrer. An attacker with M verified referrer accounts can multiply this by M.

**The Real Bottleneck:** Each Sybil account still needs KYC Tier 1 (unique phone, social, email). So the per-referrer limit is secondary to the cost of creating verified Sybil identities.

**Recommendation:**
- Consider reducing `MAX_REFERRAL_BONUSES_PER_EPOCH` from 50 to 20 for early deployment
- Add cross-referrer analysis: if accounts C1...C50 all have suspiciously similar registration patterns (same day, sequential nonces), flag for review
- Consider a "warm-up" period: referrers must have been KYC Tier 1 for at least 30 days before earning referral bonuses


### 2.2 Circular Referral Chains for L2 Bonus Extraction

**Attack Scenario:**

1. Attacker creates accounts A, B, C (all KYC Tier 1)
2. A refers B, B refers C
3. Attacker creates Sybils D1...Dn all referring C
4. Each D claims welcome bonus -> C gets L1 referral (70%), B gets L2 referral (20%)
5. Attacker creates Sybils E1...En all referring B
6. Each E claims welcome bonus -> B gets L1 referral, A gets L2 referral

**Revenue multiplication:** Same Sybil cost, but extracts both L1 and L2 referral bonuses across different "generations" of the referral tree.

**Severity:** LOW (L-01)

**Assessment:** The per-referrer epoch limit (50/week) applies to the L1 referrer but NOT to the L2 referrer independently. When `_distributeAutoReferralBonus()` (line 1855) is called, it checks `epochReferralCount[referrer][epoch]` for the primary referrer only. The L2 referrer accumulation (line 1923) has no independent epoch counter.

However, the L2 bonus is inherently rate-limited by the L1 rate limit: if the L1 referrer can only earn from 50 referrals/epoch, the L2 referrer above them also only accumulates from those same 50 events. This is a natural cascade limit.

**Recommendation:** The current design is acceptable but could be strengthened by adding an independent epoch counter for L2 referrer accumulations.


### 2.3 Admin setPendingReferralBonus Migration Abuse

**Finding:** LOW (L-02)

The `setPendingReferralBonus()` function (OmniRewardManager line 842) allows `DEFAULT_ADMIN_ROLE` to set arbitrary pending referral bonuses for any address. While this is intended for one-time migration from the legacy database, it creates a trust surface:

- A compromised admin could set large pending bonuses for attacker addresses
- The function properly deducts from `referralBonusPool.remaining`, so it cannot exceed pool balance
- However, there is no maximum per-user cap on migrated amounts

**Existing Mitigation:** Requires `DEFAULT_ADMIN_ROLE` (should be a multisig with timelock). Pool balance enforcement prevents over-distribution.

**Recommendation:** After migration is complete, consider revoking the admin's ability to call this function (or use the ossification mechanism).

---

## Attack Vector 3: KYC Bypass

### 3.1 Can KYC Tiers Be Spoofed?

**On-Chain Protections:**

| Protection | Contract | Location | Effectiveness |
|---|---|---|---|
| EIP-712 signed proofs | OmniRegistration | Lines 1303-1318 | All verifications require trusted key signature |
| `trustedVerificationKey` | OmniRegistration | Line 157 | Single point of trust for phone/social/email |
| Sequential tier progression (H-01) | OmniRegistration | Lines 1087-1093 | Cannot skip tiers |
| `usedIDHashes` uniqueness | OmniRegistration | Line 229 | Each government ID can only be used once |
| `usedAddressHashes` uniqueness | OmniRegistration | Line 240 | Each proof-of-address can only be used once |
| Selfie similarity >= 85% | OmniRegistration | Line 1490 | Face match required |
| Trusted KYC provider for Tier 4 | OmniRegistration | Line 1335 | Third-party KYC signature |

**Attack Scenario: Compromised trustedVerificationKey**

**Severity:** HIGH (H-01)

If the `trustedVerificationKey` is compromised, an attacker can:

1. Sign arbitrary phone verification proofs for any address
2. Sign arbitrary social verification proofs for any address
3. Sign arbitrary email verification proofs
4. Grant KYC Tier 1 to unlimited Sybil accounts
5. All these accounts can then claim welcome bonuses + generate referral bonuses

**Single Point of Failure:** The entire KYC Tier 1 system (and by extension, the welcome bonus and referral bonus systems) depends on the security of ONE private key -- the `trustedVerificationKey`.

**Impact:** Total compromise of welcome bonus pool (1.38B XOM) and referral bonus pool (2.99B XOM) at the rate of 1,000 welcome bonuses per day + 2,000 referral bonuses per day.

**Existing Mitigations:**
- The key can be rotated via `setTrustedVerificationKey()` (admin only)
- Contract can be paused via `PAUSER_ROLE`
- Daily rate limits cap extraction to ~5M XOM/day for welcome bonuses

**Recommendations:**
- Use an HSM (Hardware Security Module) for the trustedVerificationKey
- Implement key rotation schedule (monthly)
- Add multi-sig requirement for verification proofs (require 2-of-3 verification keys, not just 1)
- Add a per-epoch global welcome bonus cap in addition to the daily cap
- Monitor for anomalous verification proof submission patterns


### 3.2 KYC Tier Sharing Across Sybil Accounts

**Finding:** LOW (L-03)

Each on-chain uniqueness check (phone hash, email hash, social hash, ID hash, address hash) prevents the SAME credential from being used by two different addresses. However, an attacker controlling multiple real people (e.g., family members, paid participants) can create legitimate-looking accounts that share no on-chain identifiers.

This is an inherent limitation of any KYC system -- it protects against digital duplication but not against colluding real humans.

**Assessment:** The contract-level protections are correct and complete. The remaining risk is in the verification service's ability to detect organized human Sybil farms.


### 3.3 KYC Attestation Collusion (Tier 2-4)

**Finding:** LOW (L-04)

KYC Tiers 2-4 can be upgraded via multi-attestation (3-of-5 `KYC_ATTESTOR_ROLE` holders, OmniRegistration line 1118). If 3 colluding attestors coordinate:

- They cannot skip tiers (H-01 fix, line 1087-1093)
- They cannot attest for users they registered (line 1096)
- But they CAN push a user from Tier 1 -> 2 -> 3 -> 4 if each tier is attested sequentially

**Existing Mitigation:** Sequential tier progression and registration-attestor separation reduce the attack surface. The trustless verification path (Tiers 2-3 via EIP-712 signed proofs) provides an alternative that does not depend on attestor collusion.

---

## Attack Vector 4: Participation Score Manipulation

### 4.1 Sybil Inflation of Participation Scores

**On-Chain Protections:**

| Protection | Contract | Location | Effectiveness |
|---|---|---|---|
| `MAX_VERIFIER_CHANGES_PER_DAY` (50) | OmniParticipation | Line 193 | Per-verifier daily cap |
| `MAX_GLOBAL_CHANGES_PER_DAY` (200) | OmniParticipation | Line 197 | Cross-verifier global cap |
| `MAX_LISTING_COUNT_DELTA` (1000) | OmniParticipation | Line 201 | Publisher activity manipulation cap |
| `MAX_SCORE_INCREASE_PER_EPOCH` (20) | OmniParticipation | Line 224 | Per-user 7-day score increase cap |
| `SCORE_EPOCH_DURATION` (7 days) | OmniParticipation | Line 227 | Epoch duration for rate limiting |
| Array caps (reviews, claims, reports) | OmniParticipation | Lines 205-217 | Prevent unbounded state bloat |
| Content hash dedup (M-07) | OmniParticipation | Line 288 | Prevent duplicate forum contributions |
| Report dedup per reporter | OmniParticipation | Line 291 | Prevent duplicate reports |
| Score decay (90 days) | OmniParticipation | Line 313 | Inactive scores decay |

**Attack Scenario: Fabricated Transaction Claims**

A Sybil account submits fabricated `transactionHash` values via `claimTransactions()`:

1. The contract only checks `usedTransactions[hash]` for dedup (line 246)
2. A `VERIFIER_ROLE` holder must later verify each claim
3. But if the VERIFIER_ROLE is compromised or colluding, fabricated transactions get verified
4. Each verified transaction increments `verifiedTransactionCount`, increasing marketplace activity score

**Severity:** MEDIUM (M-03)

**Assessment:** The `MAX_SCORE_INCREASE_PER_EPOCH` (20 points per 7 days) is the key defense. Even with a compromised verifier, a single user can only gain 20 score points per week. Combined with `MAX_VERIFIER_CHANGES_PER_DAY` (50) and `MAX_GLOBAL_CHANGES_PER_DAY` (200), the damage is bounded.

However, the comment at ATK-M23 (line 105) acknowledges this limitation: "Documented limitation (fabricated tx hashes require off-chain proof)". The contract inherently trusts the VERIFIER_ROLE for transaction verification.

**Existing Mitigation:** Rate limits cap the maximum score inflation. The ATK-M23 limitation is documented and accepted.

**Recommendation:**
- Ensure VERIFIER_ROLE is granted to automated systems (not manual operators) with on-chain proof verification
- Add a cooldown between verified transactions for the same user (minimum 1 hour between verifications)


### 4.2 Sybil Review Farming

**Attack Scenario:**

1. Attacker creates accounts A and B (both registered)
2. A submits a review for B with 5 stars and a fabricated `transactionHash`
3. B submits a review for A with 5 stars and a different fabricated hash
4. If VERIFIER_ROLE verifies both, both accounts gain marketplace reputation

**Protection:** `CannotReviewSelf` (line 474) prevents self-review. But mutual-review between Sybil accounts is not prevented on-chain.

**Severity:** LOW (L-05)

**Assessment:** The `MAX_SCORE_INCREASE_PER_EPOCH` limits the damage to 20 points per user per week. The VERIFIER_ROLE should detect fabricated transaction hashes off-chain. The marketplace reputation component is capped at -10 to +10 points, so even complete gaming only yields 10 points.

---

## Attack Vector 5: Validator Qualification Gaming

### 5.1 Can Sybil Accounts Qualify as Validators?

**Validator Requirements (OmniParticipation):**

1. Participation score >= 50 (MIN_VALIDATOR_SCORE, line 177)
2. KYC Tier 3 (line 1365) -- requires Persona verification + AML clearance
3. Minimum stake of 1,000,000 XOM (from OmniCore)
4. Must register in Bootstrap contract

**Score Breakdown to Reach 50:**

| Component | Max Points | Sybil-Achievable? |
|---|---|---|
| KYC Trust (Tier 3) | 15 | Requires real ID + video + AML |
| Staking (Tier 2 + 6mo) | 12 | Requires 1M XOM capital |
| Referral Activity | 10 | Requires 10 real referrals |
| Publisher Activity | 4 | Requires verifier collusion |
| Marketplace Activity | 5 | Requires verifier collusion |
| Community Policing | 5 | Requires verifier collusion |
| Forum Activity | 5 | Requires verifier collusion |
| Marketplace Reputation | 10 | Requires verified reviews |
| Reliability | 5 | Requires active heartbeats |

**Minimum path to 50 points:**
- KYC Tier 3: 15 points (requires REAL identity -- Persona + AML)
- Staking 1M XOM for 6 months: 12 points (requires capital)
- 10 referrals: 10 points (needs real or Sybil accounts)
- Reviews + marketplace: 13 points (needs verifier cooperation)

**Severity:** LOW (L-06)

**Assessment:** Validator qualification is well-protected because:

1. **KYC Tier 3 is hard to Sybil:** Requires government ID (usedIDHashes dedup), address verification (usedAddressHashes dedup), selfie with 85% face match, Persona identity verification, AND AML clearance. Creating multiple fake identities at this level is extremely expensive.

2. **1,000,000 XOM stake requirement:** Capital-intensive, making Sybil validators economically costly.

3. **KYC Tier 3 requirement is checked in `canBeValidator()`** (OmniParticipation line 1365), not just the score.

**Residual Risk:** A nation-state actor or well-funded criminal organization with access to multiple real identities and significant capital could theoretically create Sybil validators. But this is outside the reasonable threat model for a marketplace platform.


### 5.2 Bootstrap Registry Sybil Nodes

**Finding:** INFORMATIONAL (I-02)

The Bootstrap contract allows self-registration of nodes (line 249). Any address can call `registerNode()` to appear in the node registry. There is no on-chain stake or KYC check.

**Existing Mitigation:**
- `MAX_NODES` cap of 1,000 (line 66)
- Admin can `adminDeactivateNode()` and ban misbehaving nodes
- The Bootstrap contract is for **discovery** only -- it does NOT grant consensus participation or reward eligibility
- Actual validator rewards (OmniValidatorRewards) check `omniCore.isValidator()` and `participation.canBeValidator()` for eligibility

**Assessment:** The Bootstrap registry is a permissionless directory. Sybil nodes in Bootstrap waste gas but cannot earn rewards or participate in consensus without meeting the full validator requirements.

---

## Attack Vector 6: Legacy Claim Double-Dipping

### 6.1 Can the Same Legacy Balance Be Claimed Multiple Times?

**On-Chain Protections (Strong):**

| Protection | Contract | Location | Effectiveness |
|---|---|---|---|
| `claimedBy[usernameHash]` != address(0) | LegacyBalanceClaim | Line 127 | One claim per username |
| `legacyBalances[usernameHash] = 0` after claim | LegacyBalanceClaim | Line 459 | Balance zeroed after claim |
| M-of-N multi-sig validation | LegacyBalanceClaim | Lines 102-108 | Multiple validators must sign |
| Per-address nonce | LegacyBalanceClaim | Line 121 | Replay protection |
| `MAX_MIGRATION_SUPPLY` cap | LegacyBalanceClaim | Line 81 | Hard cap at 4.13B XOM |
| `totalDistributed` tracking | LegacyBalanceClaim | Line 150 | Running total enforced |

**Attack Scenario: Username Hash Collision**

The `usernameHash` is computed as `keccak256(abi.encodePacked(username))`. For this to have a collision:
- Two different username strings would need to hash to the same bytes32
- Probability: ~1/2^256 (cryptographically infeasible)

**Attack Scenario: Multiple Addresses Claiming Same Username**

1. Username "alice" has a legacy balance of 10,000 XOM
2. Attacker obtains validator proofs for "alice" -> ethAddress1
3. Claims successfully, `claimedBy["alice_hash"] = ethAddress1`, balance zeroed
4. Attacker tries to claim "alice" -> ethAddress2
5. **BLOCKED:** `legacyBalances[usernameHash]` is now 0, reverts with `NoLegacyBalance`

**Severity:** NONE -- properly protected

**Assessment:** The legacy claim system has robust double-dip protection:
- Username-to-balance is one-time (zeroed after claim)
- `claimedBy` mapping records the claiming address
- M-of-N multi-sig requires multiple validators to collude for a fraudulent proof
- Supply cap prevents total distribution exceeding 4.13B XOM even if balances are maliciously loaded


### 6.2 Legacy Claim + Welcome Bonus Double-Dip

**Finding:** INFORMATIONAL (I-03)

A legacy user who claims their V1 balance can also register as a new user and claim the welcome bonus. These are separate systems:

- LegacyBalanceClaim: keyed by `usernameHash` (legacy identity)
- OmniRewardManager: keyed by `address` (new identity)

A user could claim their legacy balance to address A, then register address A as a new user and claim the welcome bonus.

**Assessment:** This is by design. Legacy users migrating to V2 should be able to participate in the new platform incentives. The welcome bonus is a platform incentive, not related to legacy migration. No issue.

---

## Cross-System Compound Attack Scenarios

### Compound Attack 1: Full Sybil Pipeline (H-02)

**Severity:** HIGH

**Description:** An attacker with resources to create verified identities at scale could execute a full pipeline attack across all bonus types.

**Attack Flow:**
1. **Identity Acquisition:** Obtain N phone numbers, N social accounts, N email addresses
2. **Registration:** Create N accounts via `selfRegisterTrustless()`, each with a different referrer from a small set of "farm" accounts
3. **KYC Tier 1:** Submit phone + social verification for each account
4. **Welcome Bonus:** Each account claims ~5,000 XOM (at current tier)
5. **Referral Bonus:** Farm accounts accumulate referral bonuses (1,750 XOM per referral)
6. **First Sale Bonus:** Create wash trades between Sybil accounts to trigger first sale bonuses

**Extraction per Sybil Identity:**
- Welcome bonus: 5,000 XOM
- Referral bonus (to farm account): 1,750 XOM (L1) + 500 XOM (L2)
- First sale bonus: 500 XOM (if wash trade succeeds)
- **Total per identity: ~7,750 XOM**

**Rate Limits:**
- Welcome: 1,000/day
- Referral: 2,000/day auto + 2,000/day manual
- First sale: 500/day
- Per-referrer: 50/week
- Per-user score increase: 20 points/week

**Maximum Daily Extraction:**
- Welcome: 1,000 * 5,000 = 5,000,000 XOM
- Referral: (auto-limited by welcome count) ~1,000 * 2,500 = 2,500,000 XOM
- First sale: 500 * 500 = 250,000 XOM
- **Total: ~7,750,000 XOM per day**

**Defenses That Limit This:**
1. Each identity needs a unique phone + social + email (primary bottleneck)
2. First sale requires MIN_FIRST_SALE_AMOUNT (100 XOM), MIN_FIRST_SALE_AGE (7 days), and buyer/seller cannot share the same referrer (SYBIL-H05)
3. Daily rate limits cap throughput
4. All bonuses are drawn from pre-funded, finite pools

**Remaining Weakness:** The SYBIL-H05 wash trade detection (OmniRegistration line 1907-1917) only checks if buyer and seller share the same referrer. Sybil accounts with DIFFERENT referrers can still wash trade. A more robust check would detect:
- Buyer and seller registered on the same day
- Buyer and seller registered from the same email domain
- Transaction amount exactly equals MIN_FIRST_SALE_AMOUNT (suspiciously precise)

**Recommendation:**
- Add minimum sale amount randomization check: reject sales at exactly MIN_FIRST_SALE_AMOUNT as suspicious
- Add "buyer registered for at least MIN_FIRST_SALE_AGE" requirement too (not just seller)
- Consider requiring KYC Tier 1 for buyers in first-sale-qualifying transactions


### Compound Attack 2: Verification Key + Admin Collusion

**Severity:** HIGH (Theoretical -- requires two independent key compromises)

If BOTH the `trustedVerificationKey` and a `DEFAULT_ADMIN_ROLE` holder are compromised:

1. Attacker creates unlimited Sybil registrations with fake phone/social proofs
2. Admin sets `legacyBonusClaimsCount = 0` to maximize welcome bonus tier (10,000 XOM)
3. Admin sets `pendingReferralBonus` for attacker addresses
4. Admin updates `registrationContract` to a malicious contract that always returns true for `hasKycTier1()`

**Mitigation:**
- Registration contract change requires 48-hour timelock (M-03, OmniRewardManager line 752)
- `legacyBonusClaimsCount` has `MAX_LEGACY_CLAIMS_COUNT` cap of 10,000,000 (line 211)
- Pre-funded pools have finite balances

**Assessment:** This requires compromising two independent security boundaries. The 48-hour timelock on registration contract changes provides a window for detection and intervention.

---

## Summary of Findings

### High Severity (2)

| ID | Title | Contracts Affected | Description |
|---|---|---|---|
| H-01 | trustedVerificationKey Single Point of Failure | OmniRegistration | All KYC Tier 1 verifications depend on one key. Compromise enables unlimited Sybil identity creation. |
| H-02 | Full Sybil Pipeline Extraction (~7.75M XOM/day) | OmniRewardManager, OmniRegistration | Cross-system compound attack can extract ~7.75M XOM/day with sufficient Sybil identities, limited only by identity acquisition cost and daily rate limits. |

### Medium Severity (3)

| ID | Title | Contracts Affected | Description |
|---|---|---|---|
| M-01 | VoIP Phone Numbers Bypass Sybil Protection | OmniRegistration (off-chain verification) | Phone hash uniqueness is only as strong as the verification service's ability to reject VoIP/virtual numbers. |
| M-02 | Referral Epoch Limit May Be Too Generous | OmniRewardManager | 50 referrals per 7-day epoch allows 87,500 XOM extraction per referrer per week. |
| M-03 | Fabricated Transaction Claims (ATK-M23 Acknowledged) | OmniParticipation | Transaction claims rely on VERIFIER_ROLE for validation. Fabricated hashes accepted if verifier is compromised. Bounded by MAX_SCORE_INCREASE_PER_EPOCH. |

### Low Severity (4)

| ID | Title | Contracts Affected | Description |
|---|---|---|---|
| L-01 | L2 Referrer Has No Independent Epoch Counter | OmniRewardManager | Second-level referrer accumulation is only indirectly rate-limited by L1 referrer's epoch cap. |
| L-02 | setPendingReferralBonus No Per-User Cap | OmniRewardManager | Admin migration function has no per-user maximum on pending bonuses. Pool balance is the only cap. |
| L-03 | KYC Cannot Prevent Colluding Real Humans | OmniRegistration | Inherent limitation: real humans coordinating Sybil participation bypass all digital uniqueness checks. |
| L-04 | KYC Attestation Collusion (3 of 5) | OmniRegistration | Three colluding KYC_ATTESTOR_ROLE holders can escalate tiers, mitigated by sequential progression requirement. |
| L-05 | Mutual Sybil Review Farming | OmniParticipation | Sybil accounts can exchange 5-star reviews. Bounded by per-epoch score increase cap and verifier rate limit. |
| L-06 | Validator Qualification Well-Protected | OmniParticipation, OmniCore | Requires KYC Tier 3 + 1M XOM stake + 50 PoP score. Sybil validators are economically prohibitive. |

### Informational (2)

| ID | Title | Contracts Affected | Description |
|---|---|---|---|
| I-01 | Trustless Registration Correctly Sets Tier 0 | OmniRegistration | Email-only registration does not qualify for bonuses. Properly designed. |
| I-02 | Bootstrap Registry Is Permissionless | Bootstrap | Discovery-only registry. Sybil nodes cannot earn rewards without full validator qualification. |

---

## Recommendations

### Priority 1: Critical Infrastructure Security

1. **Use HSM for trustedVerificationKey** (H-01): The single verification key is the most important Sybil defense. Store it in a hardware security module with audit logging.

2. **Implement Multi-Key Verification** (H-01): Require 2-of-3 verification key signatures for phone/social proofs instead of 1-of-1. This eliminates the single point of failure. Would require modifying `_verifyAttestation()` in OmniRegistration.

3. **Carrier-Grade Phone Verification** (M-01): The off-chain verification service must reject VoIP, virtual, and disposable phone numbers. Consider integrating with carrier APIs (Twilio Lookup, Telesign) for carrier detection.

### Priority 2: Rate Limit Tuning

4. **Reduce MAX_DAILY_WELCOME_BONUSES to 100** for initial deployment. Can be increased later via upgrade as organic demand grows.

5. **Reduce MAX_REFERRAL_BONUSES_PER_EPOCH to 20** (M-02). 50 per week is generous for early deployment.

6. **Add minimum account age for welcome bonus**: Require 7 days between KYC Tier 1 completion and welcome bonus eligibility. This adds friction for Sybil farmers without significantly impacting legitimate users.

### Priority 3: Cross-System Detection

7. **First Sale Wash Trade Detection** (H-02): Strengthen SYBIL-H05 checks:
   - Require buyer to also have MIN_FIRST_SALE_AGE account age
   - Require buyer to have KYC Tier 1
   - Reject sales at exactly MIN_FIRST_SALE_AMOUNT (suspicious precision)
   - Check if buyer and seller registered on the same day

8. **Referrer Warm-Up Period**: Require referrers to have been KYC Tier 1 for at least 30 days before their referral bonuses begin accumulating. This prevents rapid referrer-Sybil-claim cycles.

### Priority 4: Post-Deployment

9. **Monitor extraction rates**: Set up on-chain event monitoring for unusual patterns in WelcomeBonusClaimed, ReferralBonusAccumulated, and FirstSaleBonusClaimed events.

10. **Ossify contracts after tuning**: Once rate limits are tuned based on real deployment data, use the ossification mechanisms to permanently lock contract parameters.

---

## Contracts Reviewed

| Contract | Path | Lines |
|---|---|---|
| OmniRewardManager | `contracts/OmniRewardManager.sol` | ~2155 |
| OmniRegistration | `contracts/OmniRegistration.sol` | ~2750+ |
| OmniParticipation | `contracts/OmniParticipation.sol` | ~1740+ |
| Bootstrap | `contracts/Bootstrap.sol` | ~600+ |
| OmniCore | `contracts/OmniCore.sol` | ~1200+ |
| OmniValidatorRewards | `contracts/OmniValidatorRewards.sol` | ~1500+ |
| LegacyBalanceClaim | `contracts/LegacyBalanceClaim.sol` | ~700+ |
| ReputationCredential | `contracts/reputation/ReputationCredential.sol` | ~406 |
| OmniSybilGuard (deprecated) | `contracts/deprecated/OmniSybilGuard.sol` | ~100 (reviewed header only) |

---

*Report generated 2026-03-13 21:09 UTC by Claude Opus 4.6*
