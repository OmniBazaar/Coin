# Adversarial Attacker Review Report — Round 4

**Date:** 2026-02-28
**Audited by:** Claude Code Audit Agent (3-Agent Parallel Adversarial Review)
**Scope:** ALL 52+ active OmniBazaar smart contracts
**Methodology:** 12 attack categories (A-L) across 3 parallel agents

## Executive Summary

This adversarial review examined all OmniBazaar smart contracts from an attacker's perspective, organized into 12 attack categories spanning reentrancy, flash loans, reward inflation, fee evasion, oracle manipulation, governance attacks, access control, escrow gaming, privacy attacks, DoS/griefing, precision loss, and cross-contract call graph analysis.

**13 HIGH-severity findings** were identified across all categories. The most critical attack vectors involve: flash-stake reward extraction (B-3), governance vote inflation via staking snapshot fallback (F-01), privacy system metadata leakage (J-02), admin ability to drain quarantined fees (D-07), and arbitrator stake withdrawal during active disputes (I-02).

| Severity | Count | New (vs Phase 1) |
|----------|-------|-------------------|
| Critical | 0 | 0 |
| High | 13 | 10 |
| Medium | 24 | 17 |
| Low | 10 | 5 |
| **Total** | **47** | **32** |

*"New" = findings not previously identified in Phase 1 individual contract audits*

---

## Deduplication Notes

The following Phase 2 findings overlap with Phase 1 audit findings and are consolidated:

| Phase 2 ID | Phase 1 Report | Phase 1 ID | Disposition |
|------------|----------------|------------|-------------|
| E-01 | OmniPriceOracle | C-01/C-02 | Duplicate — already tracked |
| D-05 | FeeSwapAdapter | M-01 | Duplicate — already tracked |
| D-06 | FeeSwapAdapter | M-02 | Duplicate — already tracked |
| D-03 | OmniChatFee | L-04 | Elevated from Low to Medium (attacker perspective) |
| C-3 | OmniValidatorRewards | M-03 | Duplicate — already tracked |
| G-5 | OmniValidatorRewards | M-01 | Duplicate — already tracked |

Findings below exclude pure duplicates and only include NEW or elevated findings.

---

## HIGH Findings

### [ATK-H01] StakingRewardPool Flash Stake With Zero Duration Earns Rewards
**Agent:** 1 (Category B — Flash Loans)
**Contract:** `StakingRewardPool.sol`
**Attack Vector:** Flash-borrow XOM -> stake with `duration=0` -> wait 1 block (2 seconds) -> claim rewards -> unlock -> repay

**Description:**
`OmniCore.stake()` allows `duration=0` (Tier 0 — "no commitment"). The StakingRewardPool accrues rewards from the moment of staking. An attacker can stake 1B XOM with zero duration, wait one block (2 seconds), claim approximately 7,610 XOM in rewards (at 12% APR on 1B XOM), then unlock and repay the flash loan. Repeat every block for continuous extraction.

**Impact:** Drains the staking reward pool at ~7,610 XOM per block (~$3.3M/day at scale).

**Fix:** Reject `duration=0` in `OmniCore._validateDuration()` or add `if (stakeData.duration == 0) return 0;` in `StakingRewardPool._computeAccrued()`.

---

### [ATK-H02] OmniGovernance Staking Snapshot Fallback Enables Vote Inflation
**Agent:** 3 (Category F — Governance)
**Contract:** `OmniGovernance.sol`
**Function:** `_getStakedAmountAt()` (lines 966-986)
**Attack Vector:** Stake XOM AFTER proposal snapshot block, exploit fallback to current balance

**Description:**
When `omniCore.getStakedAt(account, blockNumber)` reverts or returns empty data, the function falls back to `_getStakedAmount(account)` which returns the CURRENT staked balance. An attacker can stake a large amount after the snapshot block and have it counted at full weight for governance voting.

**Impact:** Governance takeover — attacker can swing votes on any proposal by flash-staking after the snapshot.

**Fix:** Remove the fallback. If `getStakedAt()` fails, return 0 for the staking component.

---

### [ATK-H03] OmniCoin burnFrom() Bypasses Allowance — BURNER_ROLE is God Mode
**Agent:** 3 (Category H — Access Control)
**Contract:** `OmniCoin.sol`
**Function:** `burnFrom()` (lines 174-179)
**Attack Vector:** Compromised BURNER_ROLE holder burns tokens from any address without approval

**Description:**
`burnFrom()` is overridden to skip `_spendAllowance`. Any holder of `BURNER_ROLE` can burn tokens from ANY address without that address's approval. Currently granted to PrivateOmniCoin. If BURNER_ROLE is ever granted to a compromised or malicious contract, it enables destruction of any user's balance.

**Impact:** Total token destruction for any user. This is by design (documented in NatSpec) but represents extreme centralization of a privileged role.

**Fix:** Maintain strict whitelist. Add on-chain registry check. Require BURNER_ROLE grants to go through CRITICAL governance proposals with 7-day timelock.

---

### [ATK-H04] VERIFIER_ROLE Has Unchecked Power Over Participation Scores
**Agent:** 3 (Category H — Access Control)
**Contract:** `OmniParticipation.sol`
**Functions:** `setPublisherListingCount()`, `verifyReview()`, `verifyTransactionClaim()`, `validateReport()`, `verifyForumContribution()`
**Attack Vector:** Compromised VERIFIER inflates sybil accounts' scores to validator threshold

**Description:**
VERIFIER_ROLE can call `setPublisherListingCount(user, 100000)` to instantly give maximum publisher score. Can selectively verify/deny reviews, transaction claims, and reports. A compromised verifier can manufacture validators by inflating sybil accounts above the 50-point minimum, or decommission legitimate validators by refusing verification.

**Impact:** Validator set manipulation. Compromised verifier can install colluding validators that steal block rewards, manipulate DEX settlements, or corrupt consensus.

**Fix:** Multi-validator attestation for score changes. Rate limits on per-user component changes. Maximum delta checks per call.

---

### [ATK-H05] Admin Can Decrypt Any User's Private Balance
**Agent:** 3 (Category J — Privacy)
**Contract:** `PrivateOmniCoin.sol`
**Function:** `decryptedPrivateBalanceOf()` (lines 683-700)
**Attack Vector:** Admin calls `decryptedPrivateBalanceOf(anyUser)` to surveil balances

**Description:**
`DEFAULT_ADMIN_ROLE` bypasses the owner check on `decryptedPrivateBalanceOf()`, allowing any admin to decrypt and view any user's private pXOM balance via COTI MPC. No audit trail or user notification.

**Impact:** Complete destruction of privacy guarantee for all pXOM holders.

**Fix:** Remove admin override. Only account owner should decrypt their own balance.

---

### [ATK-H06] PrivateTransfer Events Leak Sender and Receiver Addresses
**Agent:** 3 (Category J — Privacy)
**Contract:** `PrivateOmniCoin.sol`
**Attack Vector:** On-chain event monitoring reveals transaction graph

**Description:**
`PrivateTransfer(from, to)` events expose both addresses. While amounts are encrypted, the who-transacts-with-whom metadata is fully visible. Combined with known deposit/withdrawal amounts at the bridge, flow analysis can estimate private transfer amounts.

**Impact:** Privacy system provides amount privacy but NOT relationship privacy. Transaction patterns, counterparties, and frequencies are all publicly visible.

**Fix:** Implement relayer/mixer intermediary so from/to are not directly linked. Use COTI's MPC for encrypted events. Document limitation clearly.

---

### [ATK-H07] Admin Can Disable Privacy and Force-Recover All Private Balances
**Agent:** 3 (Category J — Privacy)
**Contract:** `PrivateOmniCoin.sol`
**Functions:** `setPrivacyEnabled()` (lines 571-576), `emergencyRecoverPrivateBalance()` (lines 595-618)
**Attack Vector:** Admin disables privacy, then force-recovers balances revealing deposit amounts

**Description:**
Single admin call `setPrivacyEnabled(false)` disables all privacy. Admin then calls `emergencyRecoverPrivateBalance(user)` which mints the deposit-equivalent publicly, revealing what each user deposited. Funds received via `privateTransfer` are NOT recoverable (shadow ledger doesn't track them), leading to fund loss.

**Impact:** Complete privacy loss + potential fund loss for transfer recipients.

**Fix:** Require CRITICAL governance proposal with 7-day timelock for privacy disable. Update shadow ledger to track all balance changes.

---

### [ATK-H08] Shadow Ledger Missing Transfers Causes Fund Loss on Recovery
**Agent:** 3 (Category J — Privacy)
**Contract:** `PrivateOmniCoin.sol`
**Function:** `emergencyRecoverPrivateBalance()` (lines 595-618)
**Attack Vector:** MPC failure triggers recovery; transfer recipients lose funds, senders get double

**Description:**
`privateDepositLedger[user]` only tracks `convertToPrivate` deposits and `convertToPublic` withdrawals. Private transfers between users do NOT update the ledger. In emergency recovery: senders recover their FULL original deposit (even after transferring), and receivers get NOTHING for received transfers. This is effective double-spending.

**Impact:** In MPC failure scenario, total fund loss equals the volume of all private transfers.

**Fix:** Update shadow ledger during `privateTransfer()` by decrementing sender and incrementing receiver.

---

### [ATK-H09] UnifiedFeeVault rescueToken Ignores pendingClaims — Admin Can Steal
**Agent:** 2 (Category D — Fee Theft)
**Contract:** `UnifiedFeeVault.sol`
**Function:** `rescueToken` (line 895)
**Attack Vector:** Admin calls rescueToken after distribute() quarantines fees to pendingClaims

**Description:**
`rescueToken()` only checks `vaultBalance >= committed + amount` where `committed = pendingBridge[token]`. It does NOT subtract `pendingClaims` (quarantined fees owed to validators, referrers, listing nodes). Admin can rescue tokens that are committed to pending claims.

**Impact:** Admin can drain all quarantined fees and unclaimed marketplace fee shares.

**Fix:** Track `totalPendingClaims[token]` aggregate. Subtract both `pendingBridge` and `totalPendingClaims` in `rescueToken()`.

---

### [ATK-H10] OmniArbitration Arbitrators Can Withdraw Stake While Assigned to Active Disputes
**Agent:** 2 (Category I — Escrow)
**Contract:** `OmniArbitration.sol`
**Function:** `withdrawArbitratorStake` (line 450)
**Attack Vector:** Arbitrator assigned to dispute withdraws stake, votes dishonestly with zero risk

**Description:**
`withdrawArbitratorStake()` only checks `arbitratorStakes[msg.sender] < amount`. It does not check whether the arbitrator has active dispute assignments. An arbitrator can withdraw their entire 10,000 XOM stake before voting, eliminating the slashing risk that incentivizes honest behavior.

**Impact:** Entire arbitration incentive mechanism is undermined. Arbitrators can collude without financial risk.

**Fix:** Track active dispute assignments per arbitrator. Block withdrawal while assigned to unresolved disputes.

---

### [ATK-H11] UnifiedFeeVault _safePushOrQuarantine Raw Call Doesn't Verify Return Data
**Agent:** 2 (Category D — Fee Theft)
**Contract:** `UnifiedFeeVault.sol`
**Function:** `_safePushOrQuarantine` (line 1171)
**Attack Vector:** Non-standard ERC20 token returns success=true but doesn't transfer

**Description:**
Uses raw `call` with `IERC20.transfer.selector` instead of SafeERC20. A token that returns `success=true` but doesn't actually transfer creates a permanent deficit — amount is neither in `pendingClaims` nor actually transferred.

**Impact:** Staking pool and protocol treasury silently lose their 20% and 10% shares over time.

**Fix:** Replace raw `call` with proper return data verification matching OpenZeppelin SafeERC20.

---

### [ATK-H12] Unbounded Storage Arrays in OmniParticipation Enable State Bloat
**Agent:** 3 (Category K — DoS)
**Contract:** `OmniParticipation.sol`
**Functions:** `submitReview()`, `submitReport()`, `claimTransactions()`
**Attack Vector:** Attacker submits thousands of reviews/reports with fabricated hashes

**Description:**
Four per-user arrays grow without bound: `reviewHistory`, `reportHistory`, `transactionClaims`, `forumContributions`. An attacker registers (free) and submits thousands of reviews with fabricated transaction hashes. Each Review struct consumes ~4 storage slots. Future iteration or migration becomes impossible.

**Impact:** Permanent state bloat. Future view functions or contract upgrades that iterate arrays hit block gas limit.

**Fix:** Add per-user array caps (e.g., `MAX_REVIEWS_PER_USER = 1000`). Move full history off-chain; store only verified counts on-chain.

---

### [ATK-H13] OmniPriceOracle updateParameters() Instant Change Enables Manipulation
**Agent:** 2 (Category E — Oracle)
**Contract:** `OmniPriceOracle.sol`
**Function:** `updateParameters` (line 650)
**Attack Vector:** Admin sets minValidators=1, consensusTolerance=100%, single compromised validator submits any price

**Description:**
Admin can instantly change `minValidators`, `consensusTolerance`, `stalenessThreshold`, and `circuitBreakerThreshold`. Setting `minValidators=1` + `circuitBreakerThreshold=10000` allows a single validator to submit any price as consensus.

**Impact:** Malicious price propagates to all downstream consumers (RWAAMM, DEXSettlement), enabling AMM pool drains and favorable settlements.

**Fix:** Add 48-hour timelock. Add sanity bounds (e.g., `minValidators >= 3`, `circuitBreakerThreshold <= 5000`).

*Note: Overlaps with Phase 1 OmniPriceOracle audit findings C-01/C-02 but elevated here for the cross-contract attack scenario.*

---

## MEDIUM Findings

### [ATK-M01] OmniCore Legacy Balance CEI Violation
**Agent:** 1 (Category A)
**Contract:** `OmniCore.sol` — `claimLegacyBalance()` line 875
**Description:** Legacy balance not zeroed before external transfer. Mitigated by `nonReentrant`.

### [ATK-M02] OmniCore Same-Block Checkpoint Manipulation via Zero-Duration Stake
**Agent:** 1 (Category B)
**Contract:** `OmniCore.sol`
**Description:** Staking and unstaking in the same block creates a checkpoint at the same block number. The `upperLookup` in governance returns the post-unstake (zero) value.

### [ATK-M03] OmniCoin Flash Loan Voting Power via ERC20Votes delegate()
**Agent:** 1 (Category B)
**Contract:** `OmniCoin.sol`
**Description:** Flash-borrowed XOM can be delegated to inflate voting power. Mitigated by 1-day VOTING_DELAY between proposal creation and vote start.

### [ATK-M04] OmniValidatorRewards Epoch Backlog Uses Current State for Past Rewards
**Agent:** 1 (Category C)
**Description:** When processing multiple epochs in batch, uses current validator state for historical epochs. Staleness bounded to 100 seconds.

### [ATK-M05] OmniValidatorRewards Multiplier Stacking Enables Admin Reward Redirection
**Agent:** 1 (Category G)
**Description:** `roleMultiplier` (up to 2.0x) combined with base `rewardMultiplier` enables admin to concentrate rewards to favored validators.

### [ATK-M06] OmniChatFee Owner Can Instantly Change Fee Recipients
**Agent:** 2 (Category D)
**Contract:** `OmniChatFee.sol` — `updateRecipients()` line 336
**Description:** No timelock on fee recipient changes, unlike UnifiedFeeVault (48h) and DEXSettlement (48h). Compromised owner can redirect chat fee revenue. *Elevated from Phase 1 Low.*

### [ATK-M07] FeeSwapAdapter block.timestamp Deadline = Zero MEV Protection
**Agent:** 2 (Category D)
**Contract:** `FeeSwapAdapter.sol` — line 188
**Description:** `deadline: block.timestamp` always passes. Pending transactions vulnerable to sandwich attacks. *Duplicate of Phase 1 finding.*

### [ATK-M08] Private Escrow Resolution Skips Marketplace and Arbitration Fees
**Agent:** 2 (Category D)
**Contract:** `MinimalEscrow.sol` — `_resolvePrivateEscrow()` line 1011
**Description:** Private escrow resolution sends full amount without deducting marketplace fee (1%) or arbitration fee (5%). Users can route through private escrow to evade all fees.

### [ATK-M09] Circuit Breaker Bypass via Incremental Price Walking
**Agent:** 2 (Category E)
**Contract:** `OmniPriceOracle.sol` — `submitPrice()` line 368
**Description:** Price can be walked +9.9% per round. After 20 rounds (40 seconds at 2s blocks), price increases 547%. Needs multi-round cumulative limit.

### [ATK-M10] Stale Price Returns Non-Zero Without Revert Protection
**Agent:** 2 (Category E)
**Contract:** `OmniPriceOracle.sol`
**Description:** `latestConsensusPrice[token]` returns stale prices without revert. Downstream contracts must manually check `isStale()`. No enforcing `getValidatedPrice()` exists.

### [ATK-M11] TWAP Buffer Floodable by Validator Cartel
**Agent:** 2 (Category E)
**Contract:** `OmniPriceOracle.sol` — `_addTWAPObservation()` line 756
**Description:** 3 colluding validators can finalize 1800 rounds in 1 hour, completely filling the TWAP buffer with controlled prices.

### [ATK-M12] setOmniCore() Allows Instant Validator Registry Replacement
**Agent:** 2 (Category E)
**Contract:** `OmniPriceOracle.sol` — `setOmniCore()` line 672
**Description:** Admin can instantly point to a contract returning `isValidator() = true` for any address.

### [ATK-M13] MinimalEscrow Arbitrator Selection Has Predictable Entropy
**Agent:** 2 (Category I)
**Contract:** `MinimalEscrow.sol` — `selectArbitrator()` line 652
**Description:** Seed uses `arbitratorSeed` (readable from storage) + sequential `escrowId`. Disputer can grind nonce values offline to select a colluding arbitrator.

### [ATK-M14] DEXSettlement Commit-Reveal Not Enforced in Settlement
**Agent:** 2 (Category I)
**Contract:** `DEXSettlement.sol` — `settleTrade()` line 696
**Description:** `commitOrder()`/`revealOrder()` exist but `settleTrade()` never checks commitments. MEV protection is advisory only.

### [ATK-M15] DEXSettlement Intent Settlement Charges Zero Fees
**Agent:** 2 (Category I)
**Contract:** `DEXSettlement.sol` — `settleIntent()` line 1087
**Description:** Regular trades charge 0.1%/0.2% maker/taker fees. Intent-based settlements charge ZERO fees. Traders can route through intents to evade all DEX fees.

### [ATK-M16] RWAAMM No Fee-on-Transfer Token Verification
**Agent:** 2 (Category I)
**Contract:** `RWAAMM.sol` — `swap()` line 458
**Description:** Despite documentation warning, no balance-before/after check. Fee-on-transfer token would break K-invariant.

### [ATK-M17] StakingRewardPool and OmniCore Lack Atomicity
**Agent:** 2 (Category L)
**Contract:** `OmniCore.sol` + `StakingRewardPool.sol`
**Description:** Claim rewards and unlock are non-atomic two-step process. Edge case timing around lock expiry.

### [ATK-M18] MinimalEscrow and OmniArbitration Have Parallel Disconnected Dispute Systems
**Agent:** 2 (Category L)
**Contract:** `MinimalEscrow.sol` + `OmniArbitration.sol`
**Description:** MinimalEscrow uses simple 2-of-3 with admin-added arbitrators (no stake, no qualification). OmniArbitration has robust qualification/staking/appeals but is never invoked for marketplace disputes.

### [ATK-M19] ADMIN_ROLE Can Cancel Any Governance Proposal Unilaterally
**Agent:** 3 (Category F)
**Contract:** `OmniGovernance.sol` — `cancel()` lines 571-603
**Description:** ADMIN_ROLE bypasses proposer check to cancel any queued proposal. Does not require Emergency Guardian consensus.

### [ATK-M20] OmniValidatorRewards Independent Upgrade Path Bypasses Governance
**Agent:** 3 (Category F)
**Contract:** `OmniValidatorRewards.sol`
**Description:** Custom 48h upgrade timelock separate from governance. DEFAULT_ADMIN_ROLE can upgrade without governance vote. 48h < 7-day CRITICAL delay.

### [ATK-M21] OmniRegistration reinitialize() Accepts Arbitrary Version Numbers
**Agent:** 3 (Category H)
**Contract:** `OmniRegistration.sol` — `reinitialize()` line 648
**Description:** Admin can pass `version=255`, permanently exhausting reinitializer version space and bricking future upgrade initializations.

### [ATK-M22] submitServiceNodeHeartbeat() No Validator Status Check
**Agent:** 3 (Category H)
**Contract:** `OmniParticipation.sol` — line 563
**Description:** Any registered user (not just service nodes) can submit heartbeats, inflating publisher activity score.

### [ATK-M23] submitReview() Accepts Fabricated Transaction Hashes
**Agent:** 3 (Category H)
**Contract:** `OmniParticipation.sol` — line 462
**Description:** No on-chain verification that transaction hash corresponds to a real transaction. Colluding users can fabricate reviews.

### [ATK-M24] OmniPrivacyBridge Daily Volume Exhaustible by Single User
**Agent:** 3 (Category K)
**Contract:** `OmniPrivacyBridge.sol`
**Description:** Global 50M daily limit shared across all users. A single whale can exhaust it with 5 conversions at 10M each, blocking all other privacy conversions for the day.

---

## LOW Findings

### [ATK-L01] OmniValidatorRewards Solvency Not Tracked
**Agent:** 1 (Category C) — No aggregate `totalOutstandingRewards` vs pool balance check.

### [ATK-L02] StakingRewardPool Underflow Risk on Excessive Claim
**Agent:** 1 (Category C) — If rewards exceed pool balance, claim could revert blocking all claims.

### [ATK-L03] OmniValidatorRewards Dust Trapping in Epoch Distribution
**Agent:** 1 (Category G) — Truncation in `(epochReward * weight) / totalWeight` accumulates dust.

### [ATK-L04] UnifiedFeeVault distribute() Allows Donation Inflation
**Agent:** 2 (Category D) — Direct token transfers inflate distributable amount.

### [ATK-L05] OmniENS Fee Can Be Set to Zero
**Agent:** 2 (Category D) — No min/max bounds on registration fee.

### [ATK-L06] MinimalEscrow FEE_COLLECTOR Immutable, Cannot Upgrade
**Agent:** 2 (Category L) — Fee routing permanently locked to deploy-time address.

### [ATK-L07] RWAAMM Not Connected to OmniPriceOracle
**Agent:** 2 (Category L) — No oracle-backed price sanity check on swaps.

### [ATK-L08] OmniGovernance No Execution Expiry After Timelock
**Agent:** 3 (Category F) — Stale proposals remain executable indefinitely.

### [ATK-L09] OmniRegistration KYC Attestation O(n) Duplicate Check
**Agent:** 3 (Category K) — Attestation array grows past threshold.

### [ATK-L10] OmniPrivacyBridge Conversion Amounts Publicly Visible
**Agent:** 3 (Category J) — Events reveal exact deposit/withdrawal amounts and addresses.

---

## Positive Security Observations

The following security patterns are well-implemented:

1. **UUPS `_authorizeUpgrade` gating:** All 7 UUPS contracts properly gate with admin roles and ossification checks
2. **ReentrancyGuard:** Used consistently on all state-changing functions with external calls
3. **Pausable:** All critical contracts implement the Pausable pattern
4. **EmergencyGuardian design:** Epoch-based signature invalidation prevents stale signatures
5. **OmniTimelockController:** Dual-delay system (48h routine, 7d critical) with hardcoded critical selectors
6. **OmniCoin AccessControlDefaultAdminRules:** 48-hour admin transfer delay
7. **Flash loan protection in governance:** 1-day VOTING_DELAY prevents basic flash loan voting attacks
8. **Balance-before/after pattern:** `OmniCore.depositToDEX()` correctly handles fee-on-transfer tokens
9. **Ossification mechanism:** OmniValidatorRewards can permanently freeze admin functions

---

## Priority Remediation Matrix

### Immediate (Before Mainnet)

| ID | Contract | Finding | Risk |
|----|----------|---------|------|
| ATK-H01 | StakingRewardPool | Flash stake zero-duration reward extraction | Fund drain |
| ATK-H02 | OmniGovernance | Staking snapshot fallback vote inflation | Governance takeover |
| ATK-H08 | PrivateOmniCoin | Shadow ledger missing transfers = fund loss | User fund loss |
| ATK-H09 | UnifiedFeeVault | rescueToken ignores pendingClaims | Admin theft |
| ATK-H10 | OmniArbitration | Arbitrator stake withdrawal during disputes | Incentive failure |
| ATK-H12 | OmniParticipation | Unbounded storage arrays | DoS |
| ATK-H13 | OmniPriceOracle | Instant parameter changes | Oracle manipulation |
| ATK-M08 | MinimalEscrow | Private escrow skips all fees | Fee evasion |
| ATK-M15 | DEXSettlement | Intent settlement zero fees | Fee evasion |

### High Priority (First 30 Days)

| ID | Contract | Finding |
|----|----------|---------|
| ATK-H03 | OmniCoin | burnFrom() bypass governance |
| ATK-H04 | OmniParticipation | VERIFIER_ROLE unchecked power |
| ATK-H05 | PrivateOmniCoin | Admin decrypt any balance |
| ATK-H06 | PrivateOmniCoin | PrivateTransfer address leakage |
| ATK-H07 | PrivateOmniCoin | Admin disable privacy |
| ATK-H11 | UnifiedFeeVault | Raw call return data not verified |
| ATK-M09 | OmniPriceOracle | Circuit breaker bypass via price walking |
| ATK-M14 | DEXSettlement | Commit-reveal not enforced |
| ATK-M18 | MinimalEscrow+OmniArbitration | Disconnected dispute systems |

### Normal Priority (First 90 Days)

All remaining Medium and Low findings.

---

## Attack Surface Summary by Contract

| Contract | Highs | Mediums | Lows | Primary Risk |
|----------|-------|---------|------|--------------|
| PrivateOmniCoin | 4 | 0 | 1 | Privacy destruction, fund loss |
| OmniParticipation | 2 | 2 | 0 | Score manipulation, state bloat |
| UnifiedFeeVault | 2 | 0 | 1 | Admin fee theft |
| OmniPriceOracle | 1 | 4 | 0 | Price manipulation |
| OmniGovernance | 1 | 1 | 1 | Vote inflation, proposal cancel |
| StakingRewardPool | 1 | 0 | 1 | Flash stake extraction |
| OmniArbitration | 1 | 0 | 0 | Stake withdrawal exploit |
| OmniCoin | 1 | 1 | 0 | burnFrom bypass, flash voting |
| DEXSettlement | 0 | 2 | 0 | Fee evasion, MEV exposure |
| MinimalEscrow | 0 | 3 | 1 | Fee evasion, arbitrator gaming |
| OmniCore | 0 | 2 | 0 | CEI violation, checkpoint manip |
| OmniValidatorRewards | 0 | 2 | 1 | Multiplier abuse, epoch staleness |
| OmniRegistration | 0 | 1 | 1 | Reinitializer exhaustion |
| OmniChatFee | 0 | 1 | 0 | Instant recipient change |
| OmniENS | 0 | 0 | 1 | Fee bounds missing |
| RWAAMM | 0 | 1 | 1 | Fee-on-transfer, no oracle link |
| FeeSwapAdapter | 0 | 1 | 0 | MEV via deadline |
| OmniPrivacyBridge | 0 | 1 | 0 | Daily volume exhaustion |
| Bootstrap | 0 | 0 | 0 | (Covered in K-03 Phase 1) |

---

*Generated by Claude Code Audit Agent v2 — 3-Agent Parallel Adversarial Review*
*Scope: 52+ contracts, 12 attack categories, ~30,000 lines of Solidity*
