# OmniCoin Smart Contracts

Smart contract layer for OmniBazaar - a decentralized marketplace platform built on Avalanche with COTI V2 privacy integration.

- **Public Chain**: Avalanche Subnet-EVM with 1-2 second finality, 4,500+ TPS
- **Privacy**: COTI V2 MPC network for encrypted transactions (XOM / pXOM)
- **Token**: XOM (18 decimals), 16.6B max supply, ERC20Votes governance

## Security Status

**952 passing tests** | **39 audit reports** | **591 findings across 50+ contracts**

A comprehensive security audit was completed on 2026-02-20/21 using a 6-pass enhanced methodology (static analysis via solhint + dual-agent LLM semantic audit covering OWASP SC Top 10 and business logic). All 39 audit reports are available in `audit-reports/`. See `audit-reports/MASTER-SUMMARY-2026-02-21.md` for the full findings matrix.

Key audit outcomes:
- 34 Critical, 121 High, 178 Medium, 152 Low, 106 Informational findings identified
- Systemic patterns catalogued: admin drain vectors, dead code paths, fee-on-transfer incompatibilities, storage gap omissions, RWA compliance bypasses
- Remediation roadmap prioritized by deployment-blocking severity

## Trustless Architecture

OmniBazaar follows a **trustless-by-default** design: validators handle off-chain computation (order matching, listing storage, search) but **cannot steal user funds, fabricate transactions, or censor operations**. All settlement and financial state lives on-chain with cryptographic enforcement.

```
                         Users sign with EIP-712
                                  |
                    +-------------v--------------+
                    |     Off-Chain Validators    |
                    |  (computation, matching,    |
                    |   storage, indexing)         |
                    +-------------+--------------+
                                  |  Settlement batches
                    +-------------v--------------+
                    |    On-Chain Smart Contracts |
                    |  (20 core + 50+ total)      |
                    |  Verifies signatures,       |
                    |  enforces rules, holds funds |
                    +-------------+--------------+
                                  |
                    +-------------v--------------+
                    |  Avalanche Subnet-EVM       |
                    |  (consensus enforces all)   |
                    +----------------------------+
```

### Trustless Design Principles

**1. Cryptographic Enforcement** - No trust in validators required:
- EIP-712 typed signatures for DEX orders, bonus claims, and registration
- ECDSA recovery for multi-sig verification
- Merkle proofs for bonus eligibility (welcome, referral, first-sale)
- Voting power snapshots prevent flash-loan governance attacks

**2. User Sovereignty** - Users always control their own funds:
- Self-custody staking (users lock their own XOM in OmniCore)
- 2-of-3 multisig escrow (buyer + seller + arbitrator, any two agree)
- Direct EIP-712 signature authority on all orders and claims
- Immutable referrer assignment (cannot be gamed after registration)

**3. On-Chain Verification** - Contracts verify, not validators:
- DEXSettlement checks both buyer and seller signatures + matching logic
- Fee calculations are transparent and immutable (70/20/10 split)
- Staking reward APR computed on-chain from OmniCore stake data
- Participation scores derived from observable on-chain events

**4. Fail-Safe Controls**:
- EmergencyGuardian: 1-of-N pause (any guardian), 3-of-5 cancel (multi-sig)
- OmniTimelockController: 48-hour delay (routine), 7-day delay (critical changes)
- Ossification support: `ossify()` permanently disables future upgrades
- Rate limiting: 10K registrations/day, bridge rate limits per destination

## Contract Architecture

### Core Protocol

| Contract | Purpose |
|----------|---------|
| **OmniCoin.sol** | XOM ERC20 token, 18 decimals, 16.6B max supply, ERC20Votes governance, ERC20Permit gasless approvals, 48-hour admin transfer delay |
| **OmniCore.sol** | Staking registry (5-tier + duration bonuses), checkpointed voting power, legacy account migration with M-of-N validator signatures, UUPS upgradeable |
| **StakingRewardPool.sol** | On-chain APR computation (5-12%), per-second reward accrual, snapshot mechanism freezes rewards before unlock |
| **MintController.sol** | Authorized minting with rate limits and emission schedules |

### Marketplace & Escrow

| Contract | Purpose |
|----------|---------|
| **MinimalEscrow.sol** | 2-of-3 multisig escrow (buyer/seller/arbitrator), commit-reveal disputes, 0.1% dispute stake, 1-30 day duration, COTI V2 private escrow support |
| **UnifiedFeeVault.sol** | Single fee aggregation point, permissionless `distribute()`, 70/20/10 split (ODDAO/StakingPool/Protocol), multi-token support |

### DEX & Trading

| Contract | Purpose |
|----------|---------|
| **DEXSettlement.sol** | EIP-712 order settlement, dual-signature verification, commit-reveal MEV protection, fee attributed to matching validator (not submitter) |
| **OmniSwapRouter.sol** | Token swap routing across liquidity sources |
| **OmniFeeRouter.sol** | DEX fee collection and distribution |
| **PrivateDEX.sol** | COTI V2 MPC-encrypted order matching, encrypted amounts/prices, settlement on Avalanche |

### Governance & Security

| Contract | Purpose |
|----------|---------|
| **OmniGovernance.sol** | DAO governance, voting power = delegated XOM + staked XOM, routine (48h) and critical (7d) proposal types, EIP-712 gasless voting |
| **OmniTimelockController.sol** | Execution timelock, ossification support |
| **EmergencyGuardian.sol** | 1-of-N pause, 3-of-5 cancel, 8+ guardians (50% external), immutable contract |

### Registration & Identity

| Contract | Purpose |
|----------|---------|
| **OmniRegistration.sol** | EIP-712 trustless self-registration, phone/email hash uniqueness (sybil resistance), 3-of-5 KYC multi-attestation, immutable referrer assignment |
| **OmniParticipation.sol** | 100-point participation scoring (KYC, reputation, staking, referrals, activity, policing, reliability), drives validator selection and reward weighting |

### Rewards & Bonuses

| Contract | Purpose |
|----------|---------|
| **OmniRewardManager.sol** | Pre-minted reward pools (12.47B XOM total): welcome bonus (1.383B), referral bonus (2.995B), first-sale bonus (2B), validator rewards (6.089B). Merkle proof + EIP-712 claims |
| **OmniValidatorRewards.sol** | Per-epoch block rewards (15.602 XOM/block at 2s blocks), 1% reduction every ~2 years, weighted by participation score |

### Cross-Chain & Privacy

| Contract | Purpose |
|----------|---------|
| **OmniBridge.sol** | Avalanche Warp Messaging (AWM), rate limiting per destination, emergency circuit breakers |
| **OmniPrivacyBridge.sol** | XOM / pXOM conversions via COTI V2 MPC network, 0.3% conversion fee |
| **PrivateOmniCoin.sol** | pXOM privacy token, COTI V2 garbled circuits for encrypted balances and transfers |

### RWA (Real World Assets)

| Contract | Purpose |
|----------|---------|
| **RWAAMM.sol** | Automated market maker for RWA tokens with compliance enforcement |
| **RWAPool.sol** | Liquidity pools for RWA token pairs |
| **RWARouter.sol** | RWA swap routing with slippage protection |
| **RWAComplianceOracle.sol** | On-chain compliance checking for regulated assets |

### NFT Suite

| Contract | Purpose |
|----------|---------|
| **OmniNFTCollection.sol** | ERC721 collections with royalty support |
| **OmniNFTFactory.sol** | Permissionless collection deployment |
| **OmniFractionalNFT.sol** | NFT fractionalization into ERC20 tokens |
| **OmniNFTLending.sol** | NFT-collateralized lending |
| **OmniNFTStaking.sol** | NFT staking for rewards |

### Account Abstraction

| Contract | Purpose |
|----------|---------|
| **OmniAccount.sol** | ERC-4337 smart account with social recovery |
| **OmniEntryPoint.sol** | UserOperation processing |
| **OmniPaymaster.sol** | Gas sponsorship (gas-free UX) |
| **OmniAccountFactory.sol** | Deterministic account deployment |

### Additional Contracts

| Contract | Purpose |
|----------|---------|
| **Bootstrap.sol** | Node discovery registry (C-Chain), gateway + service node registration |
| **UpdateRegistry.sol** | On-chain software version registry for coordinated upgrades |
| **LegacyBalanceClaim.sol** | Migration claims for legacy OmniBazaar accounts (M-of-N validator signatures) |
| **LiquidityMining.sol** | LP reward distribution with vesting schedules |
| **LiquidityBootstrappingPool.sol** | Fair-launch token distribution via weighted AMM |
| **OmniBonding.sol** | Protocol-owned liquidity via bond sales |
| **ReputationCredential.sol** | Soulbound reputation tokens (non-transferable) |
| **OmniYieldFeeCollector.sol** | Yield protocol fee aggregation |
| **OmniPredictionRouter.sol** | Prediction market integration routing |

## Prerequisites

- Node.js v18+
- Hardhat
- Solidity 0.8.x compiler

## Installation

```bash
# From OmniBazaar root directory
cd /home/rickc/OmniBazaar
npm install

# Dependencies managed at root level in /home/rickc/OmniBazaar/node_modules
```

Create a `.env` file:

```bash
PRIVATE_KEY=your_private_key
INFURA_API_KEY=your_infura_api_key
ETHERSCAN_API_KEY=your_etherscan_api_key
GRAPH_API_KEY=your_graph_api_key
```

## Development

Start a local Hardhat node:

```bash
npx hardhat node
```

Deploy contracts:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

Run the full test suite:

```bash
npx hardhat test
```

Run the linter:

```bash
npx solhint 'contracts/**/*.sol'
```

## Testing

**952 tests passing** across 24 test files covering:

- Token operations and ERC20 compliance
- Staking mechanics and reward calculations
- DEX order settlement with EIP-712 signatures
- Escrow lifecycle (create, release, refund, dispute)
- Governance proposals, voting, and execution
- Registration, KYC attestation, and sybil resistance
- Cross-chain bridge operations
- Privacy features (COTI V2 MPC integration)
- Validator rewards and epoch processing
- Access control and reentrancy protection
- Emergency controls and circuit breakers

```bash
# Run all tests
npx hardhat test

# Run a specific test file
npx hardhat test test/DEXSettlement.test.ts

# Run with gas reporting
REPORT_GAS=true npx hardhat test
```

## Security Audit Reports

All 39 audit reports are in `audit-reports/`:

| Report | Contracts | Findings |
|--------|-----------|----------|
| `MASTER-SUMMARY-2026-02-21.md` | All 50+ contracts | 591 total |
| `OmniCoin-audit-2026-02-20.md` | OmniCoin | 13 |
| `OmniCore-audit-2026-02-20.md` | OmniCore | 16 |
| `DEXSettlement-audit-2026-02-20.md` | DEXSettlement | 25 |
| `MinimalEscrow-audit-2026-02-20.md` | MinimalEscrow | 26 |
| `OmniGovernance-audit-2026-02-21.md` | OmniGovernance | 12 |
| `StakingRewardPool-audit-2026-02-20.md` | StakingRewardPool | 23 |
| `OmniRegistration-audit-2026-02-21.md` | OmniRegistration | 19 |
| ... | See `audit-reports/` for all 39 | |

### Lowest-Risk Contracts (Zero Critical/High Findings)

- **OmniYieldFeeCollector** - highest severity: Medium
- **ReputationCredential** - highest severity: Medium
- **OmniCoin** - zero Critical findings
- **OmniCore** - zero Critical findings
- **OmniParticipation** - zero Critical findings

## Deployment

OmniCoin is deployed on Avalanche Fuji C-Chain (testnet). Contract addresses are maintained in `Validator/src/config/omnicoin-integration.ts` (single source of truth) and `deployments/fuji.json`.

```bash
# Deploy to Fuji testnet
npx hardhat run scripts/deploy.js --network fuji

# Deploy DEX Settlement
npx hardhat run scripts/deploy-dex-settlement.ts --network fuji

# Transfer admin to timelock (post-deployment hardening)
npx hardhat run scripts/transfer-admin-to-timelock.js --network fuji
```

## Integration

The Coin module integrates with the broader OmniBazaar stack:

- **Validator** reads contract state via ethers.js providers, submits settlement batches, indexes events
- **WebApp** interacts via Validator API endpoints (users never call contracts directly)
- **Wallet** signs EIP-712 messages for DEX orders, bonus claims, and registration
- **DEX** order matching happens off-chain in validators; settlement is on-chain via DEXSettlement

```bash
# Cross-module integration tests
cd /home/rickc/OmniBazaar
npm run test:integration
```

## Key Design Decisions

1. **Zero on-chain marketplace listings** - all listing data stored off-chain in IPFS via validators. Only settlement (escrow create/release/refund) touches the blockchain.

2. **Pre-minted reward pools** - all 12.47B XOM for bonuses and validator rewards are minted at genesis into OmniRewardManager, eliminating infinite-mint attack vectors.

3. **EIP-712 everywhere** - DEX orders, bonus claims, registration, and governance votes all use typed structured data signatures. Validators relay but cannot forge.

4. **UUPS upgradeability with ossification** - contracts are upgradeable via governance + timelock, but can be permanently frozen via `ossify()` once mature.

5. **COTI V2 privacy is opt-in** - public XOM is the default. Users explicitly convert to pXOM for privacy features. Privacy never adds friction to standard operations.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
