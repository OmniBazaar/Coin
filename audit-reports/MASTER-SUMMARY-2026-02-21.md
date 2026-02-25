# Master Security Audit Summary: OmniBazaar Smart Contracts

**Date:** 2026-02-20 to 2026-02-21
**Remediation Verified:** 2026-02-24
**Audited by:** Claude Code Audit Agent (6-Pass Enhanced)
**Scope:** All 50+ Solidity contracts across 39 audit reports
**Methodology:** Static analysis (solhint) + dual-agent LLM semantic audit (OWASP SC Top 10 + Business Logic)

---

## Grand Total Findings

| Severity | Count | Fixed | Partial | Not Fixed | Unverified |
|----------|-------|-------|---------|-----------|------------|
| Critical | 34 | 31 | 2 | 1 | 0 |
| High | 121 | ~64 | ~5 | ~8 | ~44 |
| Medium | 178 | -- | -- | -- | 178 |
| Low | 152 | -- | -- | -- | 152 |
| Informational | 106 | -- | -- | -- | 106 |
| **TOTAL** | **591** | | | | |

*Remediation verified 2026-02-24. All 34 Critical findings verified. 77 of 121 High findings individually verified against current code. Medium/Low/Informational not yet individually verified.*

---

## Per-Contract Severity Matrix

| Contract | C | H | M | L | I | Total |
|----------|---|---|---|---|---|-------|
| OmniRewardManager | 3 | 5 | 6 | 3 | 2 | 19 |
| AccountAbstraction (4 contracts) | 4 | 4 | 5 | 4 | 1 | 18 |
| NFTSuite (7 contracts) | 2 | 5 | 7 | 3 | 1 | 18 |
| PrivateDEX | 3 | 4 | 4 | 3 | 2 | 16 |
| OmniValidatorRewards | 2 | 5 | 7 | 3 | 2 | 19 |
| DEXSettlement | 1 | 6 | 7 | 5 | 6 | 25 |
| StakingRewardPool | 0 | 7 | 7 | 5 | 4 | 23 |
| MinimalEscrow | 0 | 6 | 8 | 7 | 5 | 26 |
| OmniBridge | 2 | 5 | 4 | 3 | 2 | 16 |
| OmniPrivacyBridge | 2 | 3 | 4 | 3 | 2 | 14 |
| OmniSwapRouter | 2 | 3 | 3 | 4 | 4 | 16 |
| RWAComplianceOracle | 0 | 4 | 6 | 3 | 2 | 15 |
| RWAAMM | 1 | 3 | 5 | 2 | 2 | 13 |
| RWAPool | 1 | 3 | 3 | 4 | 2 | 13 |
| RWARouter | 1 | 3 | 4 | 3 | 2 | 13 |
| RWAFeeCollector | 0 | 3 | 4 | 3 | 2 | 12 |
| LiquidityBootstrappingPool | 1 | 2 | 5 | 4 | 3 | 15 |
| LiquidityMining | 1 | 2 | 5 | 4 | 3 | 15 |
| OmniBonding | 1 | 3 | 3 | 3 | 3 | 13 |
| OmniRegistration | 1 | 2 | 8 | 5 | 3 | 19 |
| OmniSybilGuard | 1 | 3 | 5 | 5 | 2 | 16 |
| OmniGovernance | 1 | 1 | 4 | 4 | 2 | 12 |
| OmniFeeRouter | 1 | 3 | 3 | 3 | 3 | 13 |
| OmniPredictionRouter | 1 | 3 | 4 | 4 | 3 | 15 |
| PrivateOmniCoin | 1 | 3 | 5 | 4 | 2 | 15 |
| LegacyBalanceClaim | 1 | 3 | 1 | 3 | 2 | 10 |
| OmniCoin | 0 | 3 | 3 | 3 | 4 | 13 |
| OmniCore | 0 | 2 | 5 | 5 | 4 | 16 |
| OmniParticipation | 0 | 2 | 7 | 4 | 2 | 15 |
| OmniFractionalNFT | 0 | 4 | 4 | 4 | 4 | 16 |
| OmniNFTStaking | 0 | 5 | 5 | 6 | 3 | 19 |
| OmniNFTLending | 0 | 3 | 5 | 4 | 4 | 16 |
| OmniNFTFactory | 0 | 2 | 4 | 4 | 3 | 13 |
| OmniNFTRoyalty | 0 | 2 | 2 | 6 | 3 | 13 |
| Bootstrap | 0 | 2 | 4 | 4 | 1 | 11 |
| MintController | 0 | 1 | 4 | 3 | 1 | 9 |
| UpdateRegistry | 0 | 1 | 4 | 4 | 2 | 11 |
| OmniYieldFeeCollector | 0 | 0 | 2 | 4 | 4 | 10 |
| ReputationCredential | 0 | 0 | 2 | 4 | 4 | 10 |

---

## All 34 Critical Findings — Remediation Status (Verified 2026-02-24)

### Tier 1: Fund Theft / Total Loss (Deploy Blockers)

| # | Contract | Finding | Impact | Status |
|---|----------|---------|--------|--------|
| 1 | OmniRewardManager | C-01: markWelcomeBonusClaimed/markFirstSaleBonusClaimed have NO access control | Anyone marks bonuses claimed, blocking legitimate users | **FIXED** — Functions removed; bonus claiming gated by `BONUS_DISTRIBUTOR_ROLE` |
| 2 | OmniRewardManager | C-02: Pool accounting bypass via setPendingReferralBonus + claimReferralBonusPermissionless | Unlimited drain of referral bonus pool | **FIXED** — `setPendingReferralBonus` properly deducts from pool; permissionless claim reads validated mapping |
| 3 | OmniRewardManager | C-03: Compromised admin can drain all 12.47B XOM | Total protocol fund loss | **FIXED** — No drain/withdraw/emergency function exists; all distributions role-protected with pool validation |
| 4 | PrivateDEX | C-01: MATCHER_ROLE can fabricate match amount — unlimited theft | Matcher role steals unlimited funds | **FIXED** — Overfill guards (`MpcCore.ge`) + minimum fill validation prevent exceeding order amounts |
| 5 | PrivateDEX | C-02: TOCTOU race in decoupled three-step matching | Order manipulation between steps | **FIXED** — Atomic execution within `executePrivateTrade()` + `nonReentrant` + status re-validation |
| 6 | PrivateDEX | C-03: Unchecked MPC arithmetic — silent overflow/underflow | Arithmetic corruption in encrypted operations | **FIXED** — COTI V2 MPC framework handles overflow/underflow in encrypted domain |
| 7 | OmniFeeRouter | C-01: Arbitrary external call enables persistent token approval drain | Approved tokens drained via malicious call target | **FIXED** — Router validation: must be contract, not self/zero/token; immutable fee collector + max fee cap |
| 8 | OmniPredictionRouter | C-01: Arbitrary external call — no platformTarget validation | Same arbitrary call pattern | **FIXED** — `approvedPlatforms` whitelist; must be contract, not self/zero/collateral; immutable fee cap |
| 9 | OmniSwapRouter | C-02: rescueTokens() unrestricted token sweep (VP-57) | Admin drains all router-held tokens | **FIXED** — Restricted to `feeRecipient` caller only, sends to feeRecipient only |
| 10 | OmniBridge | C-01: Missing origin sender validation in processWarpMessage() | Attacker mints unlimited bridged tokens | **FIXED** — `_validateWarpMessage()` checks `trustedBridges[sourceChainID]` against `originSenderAddress` |
| 11 | OmniBridge | C-02: recoverTokens() can drain all locked bridge funds | Admin drains bridge collateral | **FIXED** — XOM and pXOM explicitly excluded via `CannotRecoverBridgeTokens` revert |
| 12 | OmniPrivacyBridge | C-01: emergencyWithdraw breaks solvency invariant | Admin rug pull vector | **FIXED** — Deducts from `totalLocked` and calls `_pause()` to block further redemptions |
| 13 | OmniPrivacyBridge | C-02: 1 billion unbacked pXOM at genesis | Systemic insolvency from day 1 | **FIXED** — No genesis minting; pXOM only created via `convertXOMtoPXOM()` with locked XOM backing |
| 14 | OmniValidatorRewards | C-02: Admin has two independent fund-drain paths without timelock | Total validator reward theft | **PARTIAL** — `DEFAULT_ADMIN_ROLE` required but NO XOM token exclusion and NO timelock on `emergencyWithdraw()` |
| 15 | NFTSuite | C-01: FractionToken unrestricted burn() permanently locks NFTs | 1-token grief permanently locks NFT | **FIXED** — `burn()` and `burnFrom()` restricted to vault contract via `OnlyVault()` modifier |

### Tier 2: Broken Core Functionality (Deploy Blockers)

| # | Contract | Finding | Impact | Status |
|---|----------|---------|--------|--------|
| 16 | AccountAbstraction | C-01: Session key constraints never enforced during execution | Session keys have zero restrictions | **FIXED** — Enforced in `_validateSessionKeyCallData()`: target, value, function selector all checked |
| 17 | AccountAbstraction | C-02: Spending limits are dead code — never enforced | Users unprotected despite configuration | **FIXED** — `_checkAndUpdateSpendingLimit()` and `_checkERC20SpendingLimit()` called in `execute()` |
| 18 | AccountAbstraction | C-03: EntryPoint never deducts gas costs from deposits | ERC-4337 economics non-functional | **FIXED** — `_deductGasCost()` deducts from `_deposits[sender]` or `_deposits[paymaster]` |
| 19 | AccountAbstraction | C-04: Removed guardian approval persists — recovery bypass | Unauthorized account takeover | **PARTIAL** — `_clearRecovery()` clears current guardians only; removed guardian's approval persists during active recovery |
| 20 | OmniSwapRouter | C-01: Placeholder swap execution — no actual swap occurs | Router doesn't swap tokens | **FIXED** — Real execution via `_executeSwapPath()` calling registered `ISwapAdapter` adapters |
| 21 | OmniSybilGuard | C-01: Uses native ETH instead of XOM ERC-20 | Contract non-functional on OmniCoin L1 | **FIXED** — Rewritten to use `xomToken` (ERC-20); contract moved to `deprecated/` |
| 22 | PrivateOmniCoin | C-01: uint64 precision limit — max private balance ~18.4 XOM | Unusable for real amounts | **FIXED** — Scaling factor `1e12` (18→6 decimals); max ~18.4M XOM per conversion; documented limitation |
| 23 | LiquidityBootstrappingPool | C-01: AMM swap formula fundamentally wrong — ~45x overpayment | LBP completely broken | **FIXED** — Correct Balancer weighted constant product formula with fixed-point `exp(y * ln(x))` |
| 24 | LiquidityMining | C-01: _calculateVested() hardcodes DEFAULT_VESTING_PERIOD | Pool-specific vesting config ignored | **FIXED** — Reads `pools[poolId].vestingPeriod`; DEFAULT_VESTING_PERIOD only as fallback when 0 |

### Tier 3: Access Control / Compliance Bypass

| # | Contract | Finding | Impact | Status |
|---|----------|---------|--------|--------|
| 25 | RWAAMM/RWAPool | C-01: RWAPool.swap() unrestricted — bypass all fees/compliance/pause | 100% compliance infrastructure bypass | **FIXED** — `onlyFactory` modifier on `RWAPool.swap()`; only RWAAMM can call |
| 26 | RWAPool | C-01: No fee in K-value invariant — zero-fee direct pool access | All protocol fees evadable | **FIXED** — Fees deducted by RWAAMM before calling pool; K-invariant checked on net amounts |
| 27 | RWARouter | C-01: Router bypasses RWAAMM entirely | Compliance/fees/pause all bypassed | **FIXED** — Router routes ALL swaps through `AMM.swap()` |
| 28 | DEXSettlement | C-01: Fee split reversed from protocol specification | Fee recipients get wrong amounts | **FIXED** — `ODDAO_SHARE=7000` (70%), `STAKING_POOL_SHARE=2000` (20%), `VALIDATOR_SHARE=1000` (10%) |
| 29 | OmniRegistration | C-01: Missing access control on bonus marking functions | Anyone can block user bonuses | **FIXED** — `onlyRole(BONUS_MARKER_ROLE)` on `markWelcomeBonusClaimed` and `markFirstSaleBonusClaimed` |
| 30 | OmniGovernance | C-01: Flash loan governance attack — no balance snapshot | Governance captured via flash loan | **FIXED** — `VOTING_DELAY = 1 days` + `getPastVotes(account, snapshotBlock)` snapshot-based voting |
| 31 | LegacyBalanceClaim | C-01: Validator defaults to address(0) — ecrecover bypass | Signature verification bypassable | **FIXED** — Uses OpenZeppelin `ECDSA.recover` (reverts on invalid); validator cannot be address(0) |
| 32 | OmniBonding | C-01: Solvency check ignores outstanding obligations | Fractional reserve insolvency | **FIXED** — `totalXomOutstanding` tracked; withdrawals limited to excess above outstanding |
| 33 | OmniValidatorRewards | C-01: Epoch skipping grief attack — permanent reward destruction | Rewards permanently lost | **FIXED** — `processEpoch()` enforces `epoch == lastProcessedEpoch + 1`; `BLOCKCHAIN_ROLE` required |
| 34 | NFTSuite | C-02: Fee-on-transfer token accounting breaks lending | Lending DoS / fund loss | **NOT FIXED** — OmniNFTLending uses `safeTransferFrom` without balance delta; low practical risk (XOM/USDC have no transfer fees) |

---

## Systemic Patterns (Cross-Contract) — Updated 2026-02-24

### Pattern 1: Dead Code / Unconnected Features
~~Multiple contracts declare security features that are never enforced:~~
- ~~**AccountAbstraction**: Session key constraints, spending limits — complete implementations except the enforcement check~~ → **FIXED** — Session keys, spending limits, and gas deduction all enforced
- **RWAFeeCollector**: `collectFees()` never called by AMM; all internal accounting is dead code → **DEPRECATED** — Replaced by UnifiedFeeVault
- ~~**RWAAMM/RWAFeeCollector**: `FEE_LP_BPS = 7000` constant never referenced in any calculation~~ → **MOOT** — RWAFeeCollector deprecated
- **NFT Suite**: 70/20/10 fee split declared but zero fee collection implemented on-chain → **UNVERIFIED**
- ~~**OmniSwapRouter**: Swap function is a placeholder that doesn't actually execute swaps~~ → **FIXED** — Real execution via registered ISwapAdapter adapters

### Pattern 2: Admin Fund Drain / Rug Pull Vectors
~~Contracts that allow a single admin key to drain all funds:~~
- ~~**OmniRewardManager**: Admin drains 12.47B XOM reward pools~~ → **FIXED** — No drain function exists
- ~~**OmniPrivacyBridge**: emergencyWithdraw bypasses solvency~~ → **FIXED** — Deducts from totalLocked + pauses bridge
- **OmniValidatorRewards**: Two independent drain paths → **STILL OPEN** — emergencyWithdraw has no XOM exclusion or timelock
- ~~**OmniBridge**: recoverTokens() drains locked bridge funds~~ → **FIXED** — XOM/pXOM excluded via CannotRecoverBridgeTokens
- ~~**OmniSwapRouter**: rescueTokens() sweeps all holdings~~ → **FIXED** — Restricted to feeRecipient only
- **StakingRewardPool**: emergencyWithdraw drains entire reward pool → **UNVERIFIED** (header claims fixed)
- **OmniBonding**: Owner withdraws XOM backing active bonds → **FIXED** — totalXomOutstanding enforced; withdrawals limited to excess
- **LiquidityMining**: withdrawRewards() drains all including user-committed rewards → **UNVERIFIED**

**Remaining**: OmniValidatorRewards needs timelock + multi-sig + token exclusion on emergency functions.

### Pattern 3: Fee-on-Transfer Token Incompatibility
Contracts that record nominal transfer amounts instead of actual received amounts:
- NFTSuite (Lending, Staking, Fractional) → **NOT FIXED** (low practical risk — XOM/USDC have no transfer fees)
- ~~OmniFeeRouter~~ → **UNVERIFIED**
- ~~OmniSwapRouter~~ → **FIXED** — Balance-before/after pattern implemented
- RWAAMM → **UNVERIFIED**
- ~~OmniBridge~~ → **UNVERIFIED**

**Recommendation**: Use balance-before/after pattern or whitelist approved tokens.

### Pattern 4: 70/20/10 Fee Split Not Implemented
~~The core OmniBazaar fee distribution model is documented everywhere but rarely implemented correctly:~~
- ~~**DEXSettlement**: Split reversed (70% validator instead of 70% ODDAO)~~ → **FIXED** — ODDAO_SHARE=7000, STAKING=2000, VALIDATOR=1000
- **NFT Suite**: Zero fee collection on-chain → **UNVERIFIED**
- **OmniSwapRouter**: Single-recipient fee → **BY DESIGN** — Off-chain fee collector handles 70/20/10 split
- ~~**RWAFeeCollector**: 66.67/33.33 actual split, not 70/20/10~~ → **DEPRECATED** — Replaced by UnifiedFeeVault
- **MinimalEscrow**: Missing granular 70/20/10 distribution → **UNVERIFIED**

### Pattern 5: RWA Compliance Architecture Bypass
~~The entire RWA compliance infrastructure can be circumvented:~~
- ~~RWAPool has no access control → direct pool interaction bypasses everything~~ → **FIXED** — `onlyFactory` modifier added
- ~~RWARouter routes through pools directly, bypassing RWAAMM~~ → **FIXED** — Router routes ALL swaps through AMM.swap()
- RWAAMM's addLiquidity/removeLiquidity skip compliance checks → **UNVERIFIED**
- ComplianceOracle defaults unregistered tokens to COMPLIANT → **UNVERIFIED**

### Pattern 6: Missing Storage Gaps for UUPS Upgrades
Multiple upgradeable contracts lack `__gap` storage variables:
- OmniParticipation → **UNVERIFIED**
- ~~OmniRegistration~~ → **FIXED** — `uint256[49] private __gap` at line 2625
- OmniSybilGuard → **DEPRECATED** — Moved to `deprecated/`

### Pattern 7: Unbounded Array Growth
Multiple contracts grow arrays without bound or pruning:
- Bootstrap (node arrays) → **UNVERIFIED**
- OmniParticipation (score components) → **UNVERIFIED**
- RWAComplianceOracle (_registeredTokens) → **UNVERIFIED**
- ~~RWAFeeCollector (_feeTokens)~~ → **DEPRECATED**
- PrivateDEX (orderIds) → **PARTIALLY FIXED** — Array not pruned on cancel/fill; DoS risk at scale

---

## Contracts With Zero Critical/High Findings (Lowest Risk)

| Contract | Highest Severity | Notes |
|----------|-----------------|-------|
| OmniYieldFeeCollector | Medium | Well-structured fee distribution |
| ReputationCredential | Medium | Read-focused credential SBT |

---

## Priority Remediation Roadmap (Updated 2026-02-24)

### Immediate (3 Remaining Critical)
1. ~~Fix all 34 Critical findings~~ → **31 of 34 fixed.** Three remain:
   - **OmniValidatorRewards C-02:** Add timelock + multi-sig + XOM token exclusion to `emergencyWithdraw()`
   - **AccountAbstraction C-04:** Clear removed guardian's approval in `removeGuardian()`, not just in `_clearRecovery()`
   - **NFTSuite C-02:** Add balance-before/after to OmniNFTLending (or restrict to whitelisted tokens)
2. ~~Fix admin drain vectors (Pattern 2)~~ → **Mostly fixed.** OmniValidatorRewards still open.
3. ~~Fix RWA pool access control (Pattern 5)~~ → **Fixed.** `onlyFactory` modifier added.

### Before Mainnet (8 Verified Unfixed High + ~44 Unverified High)
4. Fix 8 verified unfixed High findings:
   - AccountAbstraction: session key time validation (H-01), unknown aggregator (H-02), paymaster XOM fees (H-03), sybil account creation (H-04)
   - MinimalEscrow: vote() on non-disputed escrows (H-03)
   - PrivateDEX: uint64 precision (H-04 — COTI V2 limitation, document + frontend guard)
   - OmniValidatorRewards: emergencyWithdraw XOM exclusion (overlaps C-02)
   - NFTSuite: OmniNFTLending fee-on-transfer (overlaps C-02)
5. Verify and remediate ~44 unverified High findings across 22 reports
6. Deploy EmergencyGuardian, OmniTimelockController, UnifiedFeeVault, MintController
7. Transfer admin roles to timelock on all contracts
8. Add storage gaps to remaining UUPS contracts (Pattern 6)
9. Add fee-on-transfer protection or token whitelists (Pattern 3)

### Pre-Launch Hardening
10. Address Medium findings (178 total — not yet individually verified)
11. Add event emission for all state changes (multiple contracts missing events)
12. Pin all floating pragmas to specific solc versions
13. External professional security audit

---

## Audit Coverage

### Audited (39 Reports)
All substantive Solidity contracts in `Coin/contracts/` have been audited, covering:
- Core protocol (OmniCore, OmniCoin, OmniRewardManager)
- DEX (DEXSettlement, OmniSwapRouter, OmniFeeRouter)
- RWA stack (RWAAMM, RWAPool, RWARouter, RWAFeeCollector, RWAComplianceOracle)
- Account Abstraction (OmniAccount, OmniEntryPoint, OmniPaymaster, OmniAccountFactory)
- NFT Suite (7 contracts: Collection, Factory, Royalty, Lending, FractionToken, FractionalNFT, Staking)
- Privacy (PrivateOmniCoin, PrivateDEX, OmniPrivacyBridge)
- Governance (OmniGovernance, OmniParticipation, OmniSybilGuard)
- Financial (StakingRewardPool, LiquidityMining, LiquidityBootstrappingPool, OmniBonding, OmniValidatorRewards)
- Infrastructure (MinimalEscrow, OmniBridge, Bootstrap, OmniRegistration, MintController, UpdateRegistry)
- Misc (LegacyBalanceClaim, ReputationCredential, OmniYieldFeeCollector, OmniPredictionRouter)

### Not Audited
- `contracts/privacy/MpcCore.sol` — COTI V2 interface stub (not OmniBazaar code)
- `contracts/privacy/MpcInterface.sol` — COTI V2 interface definition (not OmniBazaar code)
- Test contracts, mocks, and interfaces

---

## Static Analysis Notes

- **Slither/Aderyn**: Incompatible with solc 0.8.33 (project compiler version). Noted in all reports.
- **Solhint**: Successfully run on all contracts. Typical warnings: gas optimizations, NatSpec gaps, not-rely-on-time, ordering conventions.

---

*Generated by Claude Code Audit Agent v2 -- 6-Pass Enhanced*
*39 audit reports | 591 total findings | 50+ contracts audited*
*Audit period: 2026-02-20 to 2026-02-21*
*Remediation verified: 2026-02-24 — 31/34 Critical fixed, ~64/77 verified High fixed*
