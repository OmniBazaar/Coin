# Coin Module - Current Status

**Last Updated:** 2026-02-24 19:25 UTC

---

## Summary

The Coin module contains 50+ Solidity smart contracts (20 core + interfaces, mocks, test helpers, sub-modules) providing the on-chain foundation for OmniBazaar. The architecture follows a **trustless-by-default** design where validators handle off-chain computation but cannot steal funds, forge transactions, or censor operations.

**Tests:** 952 passing (1 minute runtime)
**Audit:** 39 reports completed 2026-02-20/21, covering all 50+ contracts, 591 findings identified
**Deployment:** Live on Avalanche Fuji testnet (chain 131313), addresses in `deployments/fuji.json`

---

## Contract Inventory

### Core Protocol (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| OmniCoin (XOM) | `0x117defc430E143529a9067A7866A9e7Eb532203C` | Deployed |
| OmniCore (UUPS proxy) | `0x0Ef606683222747738C04b4b00052F5357AC6c8b` | Deployed, upgraded |
| OmniRegistration (UUPS) | `0x0E4E697317117B150481a827f1e5029864aAe781` | Deployed |
| OmniParticipation (UUPS) | `0x500436A6bd54A0C5260F961ff5941dDa1549b658` | Deployed |
| OmniRewardManager (UUPS) | `0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67` | Deployed |
| OmniValidatorRewards (UUPS) | `0x6136A40Ea03586aCA976FA2bbe9deC072EA75869` | Deployed |
| StakingRewardPool (UUPS) | `0x1A12040129c47B92fd10083d4969Fb392a9554Af` | Deployed |
| MinimalEscrow | `0xa0aF1B47C6B4c56E776c8c920dB677E394060bDD` | Deployed |
| OmniGovernance (V1) | `0x56E233DDE02E016AF83e352B9Dd191bc62e108B5` | Deployed |
| LegacyBalanceClaim | `0x1201b2f0e94B8722792FC4F515E64133c122CD39` | Deployed |
| PrivateOmniCoin (pXOM) | `0x09F99AE44bd024fD2c16ff6999959d053f0f32B5` | Deployed |
| MintController | -- | Contract exists, not yet deployed |
| EmergencyGuardian | -- | Contract exists, not yet deployed |
| OmniTimelockController | -- | Contract exists, not yet deployed |
| UnifiedFeeVault | -- | Contract exists, not yet deployed |

### DEX (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| DEXSettlement | `0xa1Fa0D36586859399b0e6c6E639A50063bBAa2Ce` | Deployed |
| OmniSwapRouter | `0x0DCef11B5aaBf8CeAd12Ea4BE2eC1fAb7Efa586B` | Deployed |
| OmniFeeRouter | `0x7e0C0c59E6D87B37920098D4000c3EfE586E6DC5` | Deployed |
| PrivateDEX | -- | Contract exists (COTI V2 required) |

### Cross-Chain & Privacy (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| OmniBridge | -- | Contract exists, AWM integration |
| OmniPrivacyBridge | -- | Contract exists (COTI V2 required) |

### RWA Suite (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| RWAComplianceOracle | `0xF6acBc80dd1Ba20F9e4e90e1A6fe145536C60bb5` | Deployed |
| RWAAMM | `0xb287f8CE22748a4b3f0fB570bc7FF7B67161cB8f` | Deployed |
| RWARouter | `0x88fF08e10ab7004ab375AD9e5201Ecad67865be2` | Deployed |
| RWAPool | `0x853CB0499b8fb159f48dE7696194Db852b305355` | Deployed |

### NFT Suite (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| OmniNFTCollection | `0x9FDeB42834Cbe4C83DEe2F318AAAB3C6EDf6C8B0` | Deployed |
| OmniNFTFactory | `0x13DFA910fD8D2d061e95C875F737bE89FF073475` | Deployed |
| OmniFractionalNFT | `0x9A59E976c6a9dC08062268e69467E431Eef554fC` | Deployed |
| OmniNFTLending | `0x2bc4165812b8f3028a4a2E52b2D4C67fE4DF675A` | Deployed |
| OmniNFTStaking | `0xD5AD7beD2Db6E05925b68a19CA645A3333726380` | Deployed |

### Account Abstraction (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| OmniEntryPoint | `0xDc3d2d1fC7d2354a56Ae9EF78bF4fB2A2c2712C4` | Deployed |
| OmniAccountFactory | `0xB4DA36E4346b702C0705b03883E8b87D3D061379` | Deployed |
| OmniPaymaster | `0x8F36f50C92b8c80835263695eda0227fb3968724` | Deployed |

### Liquidity & Bonding (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| LiquidityBootstrappingPool | `0x5C032b6F109B9d2f2Cf86A0fB70b7A419EeBA408` | Deployed |
| LiquidityMining | `0xCD2f28E7630d55aC1b10530c5EBA1564a84E4511` | Deployed |
| OmniBonding | `0x1F976D7F01a31Fd6A1afd3508BfC562D778404Dd` | Deployed |

### Misc (Deployed to Fuji)

| Contract | Address | Status |
|----------|---------|--------|
| OmniPredictionRouter | `0xBBD4C2dca354cfF43458b52c95173131E77443D9` | Deployed |
| OmniYieldFeeCollector | `0x1312eE58a794eb3aDa6D38cEbfcBD05f87e76511` | Deployed |
| ReputationCredential | `0x4f41a213a4eBa3e74Cc17b28695BCC3e8692be63` | Deployed |
| UpdateRegistry | `0x3A396c75573f1F3c2C45456600cc950605d8Fa02` | Deployed |
| TestUSDC | `0xFC866508bb2720054F9e346B286A08E7143423A7` | Deployed (testnet only) |

### Bootstrap (Deployed to C-Chain)

| Contract | Address | Status |
|----------|---------|--------|
| Bootstrap | `0x09F99AE44bd024fD2c16ff6999959d053f0f32B5` | Deployed on C-Chain (43113) |

### Deprecated

| Contract | Notes |
|----------|-------|
| OmniSybilGuard | Deployed but deprecated (uses native ETH instead of XOM) |
| RWAFeeCollector | Replaced by UnifiedFeeVault |
| OmniNFTRoyalty | Moved to deprecated/ |
| OmniGovernanceV1 | Replaced by OmniGovernance |
| OmniValidatorManager | Replaced by Avalanche PoS precompile |
| OmniCoreOld | Pre-cleanup version |

---

## Test Suite

**952 tests passing** across 24 test files:

| Test File | Tests | Notes |
|-----------|-------|-------|
| OmniCoin.test.ts | ~50 | ERC20, batchTransfer, governance |
| OmniCoin-simple.test.ts | ~30 | Basic token operations |
| OmniCore.test.js | ~60 | Staking, legacy migration, registry |
| MinimalEscrow.test.js | ~80 | 2-of-3 multisig, disputes, privacy |
| MinimalEscrowPrivacy.test.js | ~20 | COTI V2 private escrow |
| DEXSettlement.test.ts | ~90 | EIP-712 orders, MEV protection |
| OmniGovernance (UUPSGovernance.test.js) | ~100+ | Proposals, voting, timelock |
| OmniRegistration.test.ts | ~50 | Trustless registration, KYC |
| OmniParticipation.test.ts | ~40 | Scoring, dimensions |
| OmniRewardManager.test.ts | ~77 | Merkle claims, bonus pools |
| OmniValidatorRewards.test.ts | ~60 | Epoch rewards, participation |
| PrivateOmniCoin.test.js | ~50 | Privacy operations |
| OmniPrivacyBridge.test.js | ~30 | XOM/pXOM bridge |
| OmniBridge.test.js | ~80 | AWM, rate limits |
| UnifiedFeeVault.test.js | ~40 | Fee aggregation, distribution |
| Bootstrap.test.js | ~30 | Node registration, discovery |
| MintController.test.js | ~20 | Rate-limited minting |
| UpdateRegistry.test.js | ~20 | Version management |
| OmniCoinArbitration.test.ts | ~15 | Dispute resolution |
| wallet.test.ts | ~15 | Wallet integration |
| validator-blockchain-integration.test.ts | ~10 | Cross-module |
| OmniCoin-typescript.test.js | ~15 | TS-specific tests |

---

## Security Audit Status

**Completed:** 2026-02-20 to 2026-02-21
**Remediation verified:** 2026-02-24
**Methodology:** 6-pass enhanced (solhint static analysis + dual-agent LLM semantic audit)
**Reports:** 39 individual audit reports in `audit-reports/`
**Master Summary:** `audit-reports/MASTER-SUMMARY-2026-02-21.md`

### Findings Summary

| Severity | Found | Fixed | Partial | Not Fixed | N/A |
|----------|-------|-------|---------|-----------|-----|
| Critical | 34 | 31 | 2 | 1 | 0 |
| High | 121 | ~64 | ~5 | ~8 | 0 |
| Medium | 178 | -- | -- | -- | -- |
| Low | 152 | -- | -- | -- | -- |
| Informational | 106 | -- | -- | -- | -- |
| **Total** | **591** | | | | |

Note: High findings were verified for 17 of 39 audit reports (covering all contracts with Critical findings plus the highest-finding contracts). The remaining ~44 High findings across 22 lower-risk reports have not been individually verified against current code. Medium/Low/Informational have not been individually verified.

### Critical Findings - Detailed Remediation Status (34 total)

**FIXED (31 of 34):**

| # | Contract | Finding | Evidence |
|---|----------|---------|----------|
| 1 | OmniRewardManager | C-01: Bonus marking access control | Functions removed; bonus claiming gated by `BONUS_DISTRIBUTOR_ROLE` |
| 2 | OmniRewardManager | C-02: Pool accounting bypass | `setPendingReferralBonus` properly deducts from pool; `claimReferralBonusPermissionless` reads validated mapping |
| 3 | OmniRewardManager | C-03: Admin drain | No drain/withdraw/emergency function exists; all distributions role-protected with pool validation |
| 4 | PrivateDEX | C-01: MATCHER_ROLE fabricates amount | Overfill guards (`MpcCore.ge`) + minimum fill validation prevent exceeding order amounts |
| 5 | PrivateDEX | C-02: TOCTOU race | Atomic execution within `executePrivateTrade()` + `nonReentrant` + status re-validation |
| 6 | PrivateDEX | C-03: MPC arithmetic | COTI V2 MPC framework handles overflow/underflow in encrypted domain |
| 7 | OmniFeeRouter | C-01: Arbitrary external call | Router validation: must be contract, not self/zero/token; immutable fee collector + max fee cap |
| 8 | OmniPredictionRouter | C-01: Arbitrary external call | `approvedPlatforms` whitelist; must be contract, not self/zero/collateral; immutable fee cap |
| 9 | OmniSwapRouter | C-02: rescueTokens() sweep | Restricted to `feeRecipient` caller only, sends to feeRecipient only |
| 10 | OmniBridge | C-01: Missing origin validation | `_validateWarpMessage()` checks `trustedBridges[sourceChainID]` against `originSenderAddress` |
| 11 | OmniBridge | C-02: recoverTokens() drain | XOM and pXOM explicitly excluded via `CannotRecoverBridgeTokens` revert |
| 12 | OmniPrivacyBridge | C-01: emergencyWithdraw solvency | Deducts from `totalLocked` and calls `_pause()` to block further redemptions |
| 13 | OmniPrivacyBridge | C-02: Unbacked genesis pXOM | No genesis minting; pXOM only created via `convertXOMtoPXOM()` with locked XOM backing |
| 14 | OmniValidatorRewards | C-01: Epoch skipping | `processEpoch()` enforces `epoch == lastProcessedEpoch + 1`; `BLOCKCHAIN_ROLE` required |
| 15 | NFTSuite | C-01: Unrestricted burn() | `burn()` and `burnFrom()` restricted to vault contract via `OnlyVault()` modifier |
| 16 | AccountAbstraction | C-01: Session key constraints | Enforced in `_validateSessionKeyCallData()`: target, value, function selector all checked |
| 17 | AccountAbstraction | C-02: Spending limits dead code | `_checkAndUpdateSpendingLimit()` and `_checkERC20SpendingLimit()` called in `execute()` |
| 18 | AccountAbstraction | C-03: EntryPoint gas deduction | `_deductGasCost()` at line 284 deducts from `_deposits[sender]` or `_deposits[paymaster]` |
| 19 | OmniSwapRouter | C-01: Placeholder swaps | Real execution via `_executeSwapPath()` calling registered `ISwapAdapter` adapters |
| 20 | OmniSybilGuard | C-01: Uses native ETH | Rewritten to use `xomToken` (ERC-20) for all staking/rewards; moved to `deprecated/` |
| 21 | PrivateOmniCoin | C-01: uint64 precision | Scaling factor `1e12` (18→6 decimals); max ~18.4M XOM per conversion; documented limitation |
| 22 | LiquidityBootstrappingPool | C-01: Wrong AMM formula | Correct Balancer weighted constant product: `Bo * (1 - (Bi/(Bi+Ai))^(Wi/Wo))` with fixed-point math |
| 23 | LiquidityMining | C-01: Hardcoded vesting | `_calculateVested()` reads `pools[poolId].vestingPeriod`; `DEFAULT_VESTING_PERIOD` only as fallback |
| 24 | RWAAMM/RWAPool | C-01: Unrestricted swap() | `onlyFactory` modifier on `RWAPool.swap()`; RWAAMM is the only authorized caller |
| 25 | RWAPool | C-01: No fee in K-value | Fees deducted by RWAAMM before calling pool; pool K-invariant checked on net amounts |
| 26 | RWARouter | C-01: Bypasses RWAAMM | Router now routes ALL swaps through `AMM.swap()` (compliance + fees + pause enforced) |
| 27 | DEXSettlement | C-01: Fee split reversed | Constants: `ODDAO_SHARE=7000` (70%), `STAKING_POOL_SHARE=2000` (20%), `VALIDATOR_SHARE=1000` (10%) |
| 28 | OmniRegistration | C-01: Bonus marking access | `markWelcomeBonusClaimed` and `markFirstSaleBonusClaimed` gated by `BONUS_MARKER_ROLE` |
| 29 | OmniGovernance | C-01: Flash loan attack | `VOTING_DELAY = 1 days` + `getPastVotes(account, snapshotBlock)` snapshot-based voting |
| 30 | LegacyBalanceClaim | C-01: ecrecover address(0) | Uses OpenZeppelin `ECDSA.recover` (reverts on invalid); validator cannot be address(0) |
| 31 | OmniBonding | C-01: Solvency check | `totalXomOutstanding` tracked; new bonds checked against `balanceOf + xomOwed`; withdrawals limited to excess |

**PARTIALLY FIXED (2 of 34):**

| # | Contract | Finding | Status | What Remains |
|---|----------|---------|--------|--------------|
| 32 | OmniValidatorRewards | C-02: Admin fund drain paths | Partial | `emergencyWithdraw()` has `DEFAULT_ADMIN_ROLE` but NO token exclusion for XOM and NO timelock. Admin can still drain the entire reward pool. |
| 33 | AccountAbstraction | C-04: Removed guardian approval | Partial | `_clearRecovery()` clears approvals for current guardians only. A removed guardian's approval persists in the mapping during an active recovery until `_clearRecovery()` is called. |

**NOT FIXED (1 of 34):**

| # | Contract | Finding | Status | Notes |
|---|----------|---------|--------|-------|
| 34 | NFTSuite | C-02: Fee-on-transfer accounting | Not fixed | `OmniNFTLending` uses `safeTransferFrom` without balance-before/after. Low practical risk (OmniBazaar tokens don't have transfer fees) but remains a vulnerability for arbitrary ERC20 collateral. |

### High Findings - Verified Remediation Status (77 of 121 verified)

**Verified FIXED (64 of 77 verified):**

| Contract | Finding | Evidence |
|----------|---------|----------|
| OmniRewardManager | H-01: Missing KYC Tier 1 check | `hasKycTier1()` checked in all three bonus claim paths |
| OmniRewardManager | H-02: First sale without sale | `firstSaleCompleted` validation via OmniRegistration |
| OmniRewardManager | H-03: ODDAO tokens stranded | Reverts if `oddaoAddress == address(0)` before distribution |
| OmniRewardManager | H-04: reinitializeV2 access control | `onlyRole(DEFAULT_ADMIN_ROLE)` added |
| OmniRewardManager | H-05: Referral ODDAO distribution | ODDAO splits integrated into `_distributeReferralRewards()` |
| OmniBridge | H-01: transferUsePrivacy never set | Mapping written at line 446 after token transfer |
| OmniBridge | H-02: isMessageProcessed hash mismatch | Both functions use identical 2-field hash |
| OmniBridge | H-03: No pause mechanism | `whenNotPaused` on `initiateTransfer` and `processWarpMessage`; `pause()`/`unpause()` added |
| OmniBridge | H-04: No inbound rate limiting | `_enforceInboundLimit()` per source chain |
| OmniBridge | H-05: getService zero address | Zero-address check on service resolution |
| OmniRegistration | H-01: Incomplete adminUnregister | Comprehensive cleanup of ~12+ state variables |
| OmniRegistration | H-02: Missing __gap | `uint256[49] private __gap` at line 2625 |
| OmniGovernance | H-01: Staked XOM excluded | `getVotingPower()` sums delegated + staked XOM |
| OmniValidatorRewards | H-01: Flash-stake inflation | Rejects expired locks (`lockTime < block.timestamp + 1`) |
| OmniValidatorRewards | H-02: setContracts oracle manipulation | `onlyRole(DEFAULT_ADMIN_ROLE)` access control |
| OmniValidatorRewards | H-03: Unbounded iteration DoS | `MAX_BATCH_EPOCHS = 50` cap; single-pass iteration |
| OmniValidatorRewards | H-04: Removed validators forfeit | `claimRewards()` no longer requires `isValidator` |
| OmniValidatorRewards | H-05: Transaction count inflation | Per-epoch caps enforced |
| DEXSettlement | H-01: settleIntent() access control | Access control remediation confirmed in contract header |
| MinimalEscrow | H-01: Fee on buyer refunds | Fee only charged when `recipient == escrow.seller` |
| MinimalEscrow | H-02: Fee asymmetry | Unified fee logic for public and private escrow |
| PrivateDEX | H-02: No overfill guard | `_checkMinFill` + `MpcCore.ge` overfill protection |
| PrivateDEX | H-03: Order ID collision | Monotonic counter `totalTrades` prevents collisions |
| OmniSwapRouter | H-01: Fee-on-transfer | Balance-before/after pattern implemented |
| OmniSwapRouter | H-03: No adapter validation | `adapter.code.length == 0` check on registration |
| OmniPrivacyBridge | H-01: MAX_CONVERSION too small | `maxConversionLimit` set to 10M (reasonable) |
| OmniPrivacyBridge | H-02: Double fee | Single fee application; `amountAfterFee` tracked correctly |
| OmniPrivacyBridge | H-03: Fee accounting sync | Separate `totalFeesCollected`; `withdrawFees()` with `FEE_MANAGER_ROLE` |
| OmniCoin | H-01: INITIAL_SUPPLY mismatch | `4_130_000_000 * 10 ** 18` matches spec |
| OmniCoin | H-02: Missing ERC20Votes | Inherits `ERC20Votes` for checkpoint-based governance |
| OmniCoin | H-03: No supply cap | `MAX_SUPPLY = 16_600_000_000 * 10 ** 18` enforced in `mint()` |
| OmniCore | H-02: Tier/duration not validated | `MAX_TIER = 5`, `DURATION_COUNT = 4` with validation |
| NFTSuite | H-01: Interest not annualized | Annualized and pro-rated by loan duration (confirmed in header) |
| NFTSuite | H-02: Buyout min shareholding | `MIN_PROPOSER_SHARE_BPS = 2500` (25% minimum) |

**Verified PARTIALLY FIXED (5 of 77 verified):**

| Contract | Finding | What Remains |
|----------|---------|--------------|
| OmniSwapRouter | H-02: 70/20/10 fee split | On-chain single recipient by design; 70/20/10 split delegated to off-chain fee collector |
| OmniCore | H-01: No timelock on admin | Documented as deployment requirement (admin = TimelockController); not enforced in contract code |
| PrivateDEX | H-01: Unbounded orderIds array | Array grows without pruning; DoS vector for view functions at scale |
| StakingRewardPool | H-01: emergencyWithdraw drain | Header says "H-01: blocks XOM withdrawal" but full implementation needs re-verification |
| AccountAbstraction | C-04 (reclassified to High) | Guardian removal doesn't explicitly clear approval from pending recovery |

**Verified NOT FIXED (8 of 77 verified):**

| Contract | Finding | Impact | Notes |
|----------|---------|--------|-------|
| PrivateDEX | H-04: uint64 precision | Large trades impossible | COTI V2 fundamental limitation; no wider types available |
| AccountAbstraction | H-01: Session key time validation | EntryPoint doesn't validate `validUntil`/`validAfter` | Time ranges packed in return value but never checked |
| AccountAbstraction | H-02: Unknown aggregator accepted | Non-zero aggregator treated as valid | Pattern issue in OmniEntryPoint |
| AccountAbstraction | H-03: Paymaster XOM fee fails | XOM payment mode doesn't verify allowance | Users get free sponsorship |
| AccountAbstraction | H-04: Unlimited account creation | No global sponsorship budget | Sybil drain of free ops possible |
| MinimalEscrow | H-03: vote() on non-disputed | Buyer/seller can vote without dispute | Bypasses `releaseFunds()`/`refundBuyer()` flow |
| OmniValidatorRewards | C-02 (High aspect) | emergencyWithdraw has no XOM exclusion | Admin can drain entire reward pool |
| NFTSuite | C-02 (High aspect) | Fee-on-transfer token accounting | OmniNFTLending doesn't use balance delta pattern |

**Not Yet Verified (~44 High findings across 22 reports):**

The following contracts' High findings have not been individually checked against code. These are generally lower-risk contracts or contracts with findings that overlap with already-verified systemic patterns:

- OmniNFTLending (3 High), OmniFractionalNFT (4 High), OmniNFTFactory (2 High), OmniNFTStaking (5 High), OmniNFTRoyalty (2 High)
- RWAComplianceOracle (4 High), RWAAMM (3 High), RWAPool (3 High), RWARouter (3 High), RWAFeeCollector (3 High)
- LiquidityMining (2 High), LiquidityBootstrappingPool (2 High), OmniBonding (3 High)
- OmniFeeRouter (3 High), OmniPredictionRouter (3 High)
- OmniSybilGuard (3 High), PrivateOmniCoin (3 High), LegacyBalanceClaim (3 High)
- Bootstrap (2 High), MintController (1 High), UpdateRegistry (1 High)
- StakingRewardPool H-02 through H-07 (6 High)

### Systemic Patterns - Updated Status

| Pattern | Original Status | Current Status |
|---------|----------------|----------------|
| Admin drain vectors | Multiple contracts | **Mostly fixed.** OmniRewardManager (no drain), OmniBridge (token exclusion), OmniPrivacyBridge (solvency + pause). **OmniValidatorRewards emergencyWithdraw still vulnerable.** |
| Dead code / unconnected features | AccountAbstraction, RWAFeeCollector | **AccountAbstraction fixed** (session keys + spending limits enforced). **RWAFeeCollector deprecated** (replaced by UnifiedFeeVault). |
| Fee-on-transfer incompatibility | Multiple contracts | **OmniSwapRouter fixed** (balance delta). **OmniNFTLending not fixed.** Low practical risk for XOM/USDC. |
| 70/20/10 fee split inconsistencies | DEXSettlement, others | **DEXSettlement fixed** (70/20/10 correct). **OmniSwapRouter** delegates to off-chain collector (by design). |
| RWA compliance bypass | RWAPool directly accessible | **Fixed.** `onlyFactory` modifier on `RWAPool.swap()`; router routes through RWAAMM. |
| Missing UUPS storage gaps | OmniParticipation, OmniRegistration | **OmniRegistration fixed** (`__gap[49]`). OmniParticipation and OmniSybilGuard status unverified. |
| Unbounded array growth | Bootstrap, PrivateDEX, RWAComplianceOracle | **PrivateDEX partially fixed** (not fully pruned). Others unverified. |

---

## Recent Milestones

| Date | Milestone |
|------|-----------|
| 2026-02-24 | Audit remediation verified: 31/34 Critical fixed, ~64/77 verified High fixed |
| 2026-02-24 | README.md and CURRENT_STATUS.md updated with trustless architecture |
| 2026-02-21 | Security audit completed (39 reports, 591 findings) |
| 2026-02-20 | Security audit started |
| 2026-01-23 | Major deployment batch to Fuji (NFT, AA, DEX, RWA, Liquidity, Misc) |
| 2026-01-10 | OmniCore deprecated code removal, upgrade deployed |
| 2025-12-30 | RWA suite deployed to Fuji |
| 2025-12-07 | Trustless welcome bonus (77 OmniRewardManager tests) |

---

## Remaining Work

### Critical (3 Remaining — Deploy Blockers)

- [ ] **OmniValidatorRewards C-02:** Add timelock + multi-sig to `emergencyWithdraw()`; add XOM token exclusion (same pattern as OmniBridge `CannotRecoverBridgeTokens`)
- [ ] **AccountAbstraction C-04:** Clear removed guardian's approval in `removeGuardian()`, not just in `_clearRecovery()`
- [ ] **NFTSuite C-02:** Add balance-before/after pattern to OmniNFTLending token transfers (or restrict to whitelisted non-fee tokens)

### High Priority (Deploy Blockers — Infrastructure)

- [ ] Deploy EmergencyGuardian to Fuji
- [ ] Deploy OmniTimelockController to Fuji
- [ ] Deploy UnifiedFeeVault to Fuji
- [ ] Transfer admin roles to timelock on all contracts (currently documented requirement, not code-enforced)
- [ ] Deploy updated OmniGovernance (replace V1 on Fuji)
- [ ] Deploy MintController to Fuji

### High Priority (8 Verified Unfixed High Findings)

- [ ] **AccountAbstraction H-01:** EntryPoint must validate `validUntil`/`validAfter` time ranges from session keys
- [ ] **AccountAbstraction H-02:** Reject unknown aggregator addresses in EntryPoint
- [ ] **AccountAbstraction H-03:** Paymaster XOM fee collection must verify allowance before charging
- [ ] **AccountAbstraction H-04:** Add global sponsorship budget cap to prevent sybil drain
- [ ] **MinimalEscrow H-03:** Add `if (!escrow.disputed) revert NotDisputed()` check to `_validateVote()`
- [ ] **PrivateDEX H-04:** Document uint64 precision as known COTI V2 limitation; add max-amount guard in frontend
- [ ] **OmniValidatorRewards:** emergencyWithdraw XOM exclusion (overlaps with C-02 above)
- [ ] **NFTSuite:** OmniNFTLending fee-on-transfer (overlaps with C-02 above)

### High Priority (~44 Unverified High Findings)

- [ ] Verify and remediate remaining ~44 High findings across 22 audit reports (see individual reports in `audit-reports/`)
- [ ] Priority contracts: StakingRewardPool (7 High), OmniNFTStaking (5 High), OmniFractionalNFT (4 High), RWAComplianceOracle (4 High)

### Medium Priority

- [ ] Remediate 178 Medium audit findings (not yet individually verified)
- [ ] Pin all floating pragmas to specific solc versions
- [ ] Add event emission for all state changes
- [ ] External security audit (professional auditors)
- [ ] Performance benchmarking (4,500+ TPS target)
- [ ] COTI testnet deployment for privacy contracts (PrivateDEX, OmniPrivacyBridge)
- [ ] Verify UUPS storage gaps on OmniParticipation, OmniSybilGuard
- [ ] Verify unbounded array fixes on Bootstrap, RWAComplianceOracle

### Low Priority

- [ ] Address Low/Informational findings (258 total)
- [ ] Gas optimization pass
- [ ] Mainnet deployment preparation and rollback plan

---

## Build & Test Commands

```bash
cd /home/rickc/OmniBazaar/Coin

# Compile
npx hardhat compile

# Lint
npx solhint 'contracts/**/*.sol'

# Test (952 passing)
npx hardhat test

# Deploy
npx hardhat run scripts/deploy.js --network fuji

# Upgrade UUPS proxy
npx hardhat run scripts/upgrade-omnicore.ts --network fuji

# Sync addresses to all modules
cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh fuji
```

---

## Network Configuration

**OmniCoin L1 (Fuji Subnet):** Chain 131313, contracts in `deployments/fuji.json`
**Avalanche C-Chain (Fuji):** Chain 43113, Bootstrap in `deployments/fuji-c-chain.json`
**Deployer:** `0xf8C9057d9649daCB06F14A7763233618Cc280663`
