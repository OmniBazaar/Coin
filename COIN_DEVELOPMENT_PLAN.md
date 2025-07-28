# OmniCoin Development Plan
# Comprehensive Development Strategy for COTI V2 Integration

**Created**: 2025-07-24  
**Last Updated**: 2025-07-28 08:03 UTC  
**Status**: Master Development Plan - Phase 1 Complete  
**Integration**: EVALUATOR_FUNCTIONS.md + BLOCKCHAIN_ARCHITECTURE_ANALYSIS.md

---

## 🎯 Executive Summary

OmniCoin will implement a **Hybrid L2.5 Architecture** with:
- **DEFAULT**: Public transactions processed by OmniCoin validators (cheap/free)
- **OPTIONAL**: Private transactions using COTI V2 MPC (premium pricing)
- **FEE ABSTRACTION**: Users always pay in OmniCoins

This plan ensures seamless migration with 12.45 billion XOM (76.2% of original allocation) remaining for new chain distribution.

### Key Objectives
1. **Preserve Legacy Functionality**: All 23 evaluator functions operational
2. **Public-First Design**: Standard transactions are fast and cheap
3. **Optional Privacy**: Premium feature using COTI MPC when needed
4. **Maintain Token Economics**: Exact remaining token allocations preserved
5. **User Simplicity**: Pay all fees in OmniCoins, no COTI complexity

---

## 📊 Token Allocation Foundation (Blockchain Verified)

### Legacy Distribution Analysis
| Bonus Type | Original Allocation | Distributed (Legacy) | **Remaining for New Chain** |
|------------|-------------------|---------------------|----------------------------|
| Welcome | 1,405,000,000 | 21,542,500 | **1,383,457,500** |
| Referral | 3,000,000,000 | 4,598,750 | **2,995,401,250** |
| Sale | 2,000,000,000 | 22,000 | **1,999,978,000** |
| Witness | 7,413,000,000 | 1,339,642,900 | **6,073,357,100** |
| Founder | 2,522,880,000 | 2,522,880,000 | **0** ✅ Exhausted |
| **TOTAL** | **16,340,880,000** | **3,888,686,150** | **12,452,193,850** |

**Critical Insight**: 76.2% of original allocation remains available for new OmniCoin distribution

---

## 🏗️ Architecture Overview

### Hybrid L2.5 Design
```text
┌─────────────────────────────────────────────────────────────┐
│                    OmniBazaar Users                         │
└────────────────────┬───────────────────────────────────────┘
                     │
┌────────────────────▼───────────────────────────────────────┐
│           OmniCoin Business Logic Layer                     │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  OmniCoin Validators (Proof of Participation)       │  │
│  │  • 23 Legacy Evaluators (off-chain validation)     │  │
│  │  • Business logic consensus                         │  │
│  │  • Bonus distribution (Welcome/Referral/Sale)      │  │
│  │  • Fee distribution (70/20/10 split)               │  │
│  │  • IPFS/Chat/Faucet/Explorer services             │  │
│  └─────────────────────┬───────────────────────────────┘  │
└────────────────────────┼───────────────────────────────────┘
                         │
┌────────────────────────▼───────────────────────────────────┐
│              OmniCoin Transaction Layer                     │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Smart Contracts on COTI V2                         │  │
│  │  • OmniCoinCore.sol (privacy-enabled ERC20)        │  │
│  │  • OmniCoinStaking.sol (encrypted amounts)         │  │
│  │  • OmniCoinReputation.sol (marketplace scoring)    │  │
│  │  • OmniCoinArbitration.sol (confidential disputes) │  │
│  │  • OmniCoinGovernance.sol (XOM token voting)       │  │
│  │  • OmniCoinTreasury.sol (fee collection)           │  │
│  │  • BonusDistribution.sol (automated rewards)       │  │
│  │  • ValidatorRewards.sol (witness compensation)     │  │
│  └─────────────────────────────────────────────────────┘  │
└────────────────────────┬───────────────────────────────────┘
                         │
┌────────────────────────▼───────────────────────────────────┐
│                    COTI V2 Layer 2                          │
│  • OPTIONAL privacy via garbled circuits (premium fee)     │
│  • MPC precompile at address 0x64 (proprietary tech)       │
│  • Ethereum security inheritance                           │
│  • Used only when users opt-in to privacy features         │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Development Phases

## Phase 1: Core Token Infrastructure (Weeks 1-4)
**Priority**: Critical Foundation

### 1.1 OmniCoinCore.sol Enhancement
**Status**: ✅ COMPLETED - Deprecated in favor of dual-token architecture  
**Implementation**: OmniCoin.sol and PrivateOmniCoin.sol with registry pattern

```solidity
// Integration with legacy bonus allocations
contract OmniCoinCore {
    // Token allocation tracking
    uint256 public constant WELCOME_BONUS_ALLOCATION = 1383457500 * 10**18;
    uint256 public constant REFERRAL_BONUS_ALLOCATION = 2995401250 * 10**18;
    uint256 public constant SALE_BONUS_ALLOCATION = 1999978000 * 10**18;
    uint256 public constant WITNESS_BONUS_ALLOCATION = 6073357100 * 10**18;
    
    // Privacy-enabled bonus distribution tracking
    mapping(address => ctUint64) private welcomeBonusReceived;
    mapping(address => ctUint64) private referralBonusReceived;
    
    // Integration with COTI V2 MPC
    function transferPrivate(address to, ctUint64 amount) external;
    function balanceOfPrivate(address account) external view returns (ctUint64);
}
```

**Deliverables**:
- [x] Integrated dual-token architecture (OmniCoin/PrivateOmniCoin)
- [x] Implemented registry pattern for dynamic contract discovery
- [x] Added privacy-enabled operations through PrivateOmniCoin
- [ ] Comprehensive test suite (Next priority)

### 1.2 BonusDistribution.sol
**Status**: ✅ COMPLETED  
**Purpose**: Automated distribution of welcome, referral, and sale bonuses

```solidity
contract BonusDistribution {
    // Welcome bonus tiers (from legacy analysis)
    uint256 private constant TIER_1_BONUS = 10000 * 10**18; // First 1,000 users
    uint256 private constant TIER_2_BONUS = 5000 * 10**18;  // Next 9,000 users
    uint256 private constant TIER_3_BONUS = 2500 * 10**18;  // Next 90,000 users
    uint256 private constant TIER_4_BONUS = 1250 * 10**18;  // Next 900,000 users
    uint256 private constant TIER_5_BONUS = 625 * 10**18;   // Remaining users
    
    // Referral bonus tiers (from legacy analysis)
    mapping(uint256 => uint256) private referralBonusTiers;
    
    // Hardware ID tracking (prevent duplicate welcome bonuses)
    mapping(bytes32 => bool) private hardwareIdUsed;
    
    // Privacy-enabled bonus distribution
    function distributeWelcomeBonus(address user, bytes32 hardwareId) external;
    function distributeReferralBonus(address referrer, address referred) external;
    function distributeSaleBonus(address seller, address buyer) external;
}
```

**Deliverables**:
- [x] Implemented tiered bonus calculation logic
- [x] Hardware ID validation system  
- [x] Privacy-enabled distribution functions
- [x] Integration with dual-token architecture

### 1.3 ValidatorRewards.sol
**Status**: ✅ COMPLETED (as OmniCoinValidator.sol)  
**Purpose**: Witness/validator compensation with block time adjustment

```solidity
contract ValidatorRewards {
    // Adjusted for 10x faster blocks (legacy: ~100 XOM/block, new: ~10 XOM/block)
    uint256 private constant PHASE_1_REWARD = 10 * 10**18;  // Years 0-12
    uint256 private constant PHASE_2_REWARD = 5 * 10**18;   // Years 12-16
    uint256 private constant PHASE_3_REWARD = 2.5 * 10**18; // Years 16+
    
    // Phase transition tracking
    uint256 public genesisTimestamp;
    uint256 private constant PHASE_1_DURATION = 12 * 365 days;
    uint256 private constant PHASE_2_DURATION = 4 * 365 days;
    
    // Privacy-enabled reward distribution
    function distributeBlockReward(address validator) external returns (ctUint64);
    function getCurrentPhaseReward() public view returns (uint256);
}
```

**Deliverables**:
- [x] Implemented validator registration and staking
- [x] Reward calculation and distribution
- [x] Dual-token support (validators can choose XOM or pXOM)
- [x] Integration with registry pattern

---

## Phase 2: Legacy Evaluator Integration (Weeks 5-8)
**Priority**: Critical for OmniBazaar Compatibility

### 2.1 On-Chain Evaluators (13 Core Functions)
**Location**: Smart contracts on COTI V2

#### Foundation Evaluators
1. **AccountEvaluator.sol**
   - Account creation and management
   - Hardware ID validation
   - Privacy-enabled account data

2. **AssetEvaluator.sol**
   - XOM token operations
   - Balance management with MPC
   - Transfer validation

3. **StakingEvaluator.sol** ✅ COMPLETED (OmniCoinStaking.sol)
   - Dual-token staking support (XOM and pXOM)
   - Privacy-enabled stake amounts
   - Reward distribution with compound interest

#### Governance Evaluators
4. **ProposalEvaluator.sol**
   - Governance proposal creation
   - Privacy-enabled voting
   - Proposal execution

5. **CommitteeMemberEvaluator.sol**
   - Committee management
   - Member selection
   - Confidential operations

6. **WitnessEvaluator.sol**
   - Validator registration
   - Performance tracking
   - Reward calculation

#### Transaction Evaluators
7. **TransferEvaluator.sol**
   - Standard XOM transfers
   - Privacy-enabled transactions
   - Fee calculation

8. **VestingBalanceEvaluator.sol**
   - Vesting balance management
   - Time-locked distributions
   - Fee vesting logic

9. **WithdrawPermissionEvaluator.sol**
   - Withdrawal authorization
   - Permission management
   - Security validation

#### Advanced Evaluators
10. **ConfidentialEvaluator.sol**
    - Privacy operation validation
    - MPC computation verification
    - Garbled circuit integration

11. **AssertEvaluator.sol**
    - Blockchain state assertions
    - Validation logic
    - Error handling

12. **WorkerEvaluator.sol**
    - Worker proposal management
    - Budget allocation
    - Performance tracking

13. **BalanceEvaluator.sol**
    - Genesis balance claims
    - Legacy migration support
    - Balance verification

### 2.2 Off-Chain Evaluators (10 Marketplace Functions)
**Location**: OmniCoin Validator Network (Business Logic Layer)

#### Marketplace Core
14. **ListingEvaluator**
    - Marketplace listing validation
    - Fee calculation (0.25% publisher fee)
    - Priority system (0.5%-2% based on priority)

15. **EscrowEvaluator**
    - Transaction escrow management
    - Multi-party dispute resolution
    - Fee distribution (0.5% escrow agent, 0.5%-2% OmniBazaar)

16. **ExchangeEvaluator**
    - Cryptocurrency exchange operations
    - KYC requirement validation
    - No percentage fees (fixed fees only)

#### Bonus Distribution
17. **WelcomeBonusEvaluator**
    - New user bonus distribution
    - Hardware ID validation
    - Tiered bonus calculation

18. **ReferralBonusEvaluator**
    - Referral bonus distribution
    - Referrer-referred pair tracking
    - Anti-gaming protection

19. **SaleBonusEvaluator**
    - First sale bonus distribution
    - Buyer-seller pair tracking
    - Unique transaction validation

20. **FounderBonusEvaluator**
    - Founder reward distribution (EXHAUSTED)
    - Historical tracking only
    - Migration support

21. **WitnessBonusEvaluator**
    - Block production rewards
    - Phase-based distribution
    - Performance-based allocation

#### Marketplace Features
22. **VerificationEvaluator**
    - Account verification status
    - KYC integration
    - Trust score management

23. **MultisigTransferEvaluator**
    - Multi-signature transaction support
    - Enhanced security for large transfers
    - Business account support

### Implementation Strategy for Evaluators

```solidity
// Base evaluator interface
interface IEvaluator {
    struct EvaluatorContext {
        address initiator;
        uint256 timestamp;
        bytes32 transactionHash;
        ctUint64 amount; // Privacy-enabled amount
    }
    
    function validate(EvaluatorContext memory context) external returns (bool);
    function execute(EvaluatorContext memory context) external returns (bytes memory);
    function getRequiredFee(EvaluatorContext memory context) external view returns (uint256);
}

// Evaluator registry for dynamic dispatch
contract EvaluatorRegistry {
    mapping(bytes32 => address) private evaluators;
    mapping(address => bool) private authorizedEvaluators;
    
    function registerEvaluator(bytes32 evaluatorId, address evaluatorAddress) external;
    function executeEvaluator(bytes32 evaluatorId, bytes memory data) external;
}
```

---

## Phase 3: Advanced Features (Weeks 9-12)
**Priority**: Enhanced Functionality

### 3.1 OmniCoinArbitration.sol Enhancement
**Status**: ✅ Upgrade required for confidential disputes

```solidity
contract OmniCoinArbitration {
    struct ConfidentialDispute {
        ctUint64 amount;           // Private dispute amount
        ctUint64 escrowBalance;    // Private escrow balance
        bytes32 evidenceHash;     // Public evidence hash
        address[] arbitrators;    // Public arbitrator list
        ctBool resolved;          // Private resolution status
    }
    
    // Privacy-enabled dispute resolution
    function createConfidentialDispute(
        ctUint64 amount,
        bytes32 evidenceHash,
        address[] memory arbitrators
    ) external returns (uint256 disputeId);
    
    function resolveDispute(
        uint256 disputeId,
        ctUint64 buyerPayout,
        ctUint64 sellerPayout
    ) external;
}
```

### 3.2 FeeDistribution.sol Enhancement  
**Status**: ✅ Update required for private validator rewards

```solidity
contract FeeDistribution {
    // 70/20/10 split for fee distribution
    uint256 private constant VALIDATOR_PERCENTAGE = 70;
    uint256 private constant OMNIBAZAAR_PERCENTAGE = 20;
    uint256 private constant STAKER_PERCENTAGE = 10;
    
    // Privacy-enabled fee distribution
    struct PrivateFeeDistribution {
        ctUint64 totalFees;
        ctUint64 validatorRewards;
        ctUint64 omnibazaarTreasury;
        ctUint64 stakerRewards;
    }
    
    function distributeFees(ctUint64 totalFees) external returns (PrivateFeeDistribution memory);
    function claimValidatorRewards(address validator) external returns (ctUint64);
}
```

### 3.3 OmniCoinGovernance.sol
**Purpose**: XOM token governance with privacy features

```solidity
contract OmniCoinGovernance {
    struct PrivateProposal {
        string title;
        string description;
        ctUint64 votesFor;        // Private vote counts
        ctUint64 votesAgainst;    // Private vote counts
        ctUint64 quorumRequired;  // Private quorum threshold
        bool executed;
    }
    
    // Privacy-enabled voting
    function createProposal(string memory title, string memory description) external returns (uint256);
    function votePrivate(uint256 proposalId, bool support, ctUint64 votingPower) external;
    function executeProposal(uint256 proposalId) external;
}
```

---

## Phase 4: Integration & Testing (Weeks 13-16)
**Priority**: Production Readiness

### 4.1 Factory Contract Pattern
**Purpose**: Bundle contracts for efficient deployment

```solidity
contract OmniCoinFactory {
    address public omniCoinCore;
    address public bonusDistribution;
    address public validatorRewards;
    address public arbitration;
    address public feeDistribution;
    address public governance;
    
    constructor() {
        // Deploy all contracts in single transaction
        omniCoinCore = address(new OmniCoinCore());
        bonusDistribution = address(new BonusDistribution());
        validatorRewards = address(new ValidatorRewards());
        // ... deploy all contracts
    }
    
    function initializeContracts() external {
        // Cross-link all contracts
        // Set permissions and roles
        // Initialize token allocations
    }
}
```

### 4.2 Migration Contract
**Purpose**: Migrate from legacy OmniCoin to new chain

```solidity
contract LegacyMigration {
    // Legacy balance verification
    struct LegacyBalance {
        address account;
        uint256 balance;
        bytes32 proof;
    }
    
    // Verified remaining allocations from blockchain scan
    uint256 public constant REMAINING_WELCOME_BONUS = 1383457500 * 10**18;
    uint256 public constant REMAINING_REFERRAL_BONUS = 2995401250 * 10**18;
    uint256 public constant REMAINING_SALE_BONUS = 1999978000 * 10**18;
    uint256 public constant REMAINING_WITNESS_BONUS = 6073357100 * 10**18;
    
    function migrateBalance(LegacyBalance memory legacyBalance) external;
    function claimRemainingBonus(bytes32 bonusType) external;
}
```

### 4.3 Testing Strategy

#### Unit Tests
- [ ] Each evaluator function (23 total)
- [ ] Privacy operations with MPC
- [ ] Token allocation verification
- [ ] Bonus distribution logic

#### Integration Tests
- [ ] Cross-contract interactions
- [ ] COTI V2 MPC integration
- [ ] Legacy migration scenarios
- [ ] Validator network integration

#### Performance Tests
- [ ] Transaction throughput (target: 10K+ TPS)
- [ ] Privacy operation speed
- [ ] Memory usage optimization
- [ ] Gas efficiency

#### Security Tests
- [ ] Smart contract audits
- [ ] Privacy leakage tests
- [ ] Economic attack vectors
- [ ] Validator consensus security

---

## 🔧 Implementation Details

### COTI V2 Integration Specifics

#### MPC Types Usage
```solidity
// Privacy-enabled data types
ctUint64 private balance;      // Encrypted balance
ctBool private isEligible;     // Encrypted boolean
gtUint64 private gasAmount;    // Garbled circuit input
itUint64 private inputAmount;  // Signed input amount

// MPC precompile usage
function encryptValue(uint64 value) internal returns (ctUint64) {
    return MPC.encrypt(value);
}

function decryptValue(ctUint64 encryptedValue) internal returns (uint64) {
    return MPC.decrypt(encryptedValue);
}
```

#### Privacy Features Implementation
- **Encrypted Balances**: All XOM balances use ctUint64
- **Private Staking**: Stake amounts hidden from competitors
- **Confidential Voting**: Governance votes encrypted until reveal
- **Selective Disclosure**: KYC compliance without full transparency

### Proof of Participation (PoP) Implementation

#### Scoring Algorithm
```javascript
function calculatePoPScore(validatorData) {
    const legacyFactors = {
        trust: validatorData.trustScore * 0.10,
        reliability: validatorData.uptime * 0.10,
        performance: validatorData.responseTime * 0.10,
        uptime: validatorData.availability * 0.10
    };
    
    const newFactors = {
        staking: validatorData.stakedAmount * 0.20,
        kyc: validatorData.kycVerified ? 0.15 : 0,
        marketplaceActivity: validatorData.transactionVolume * 0.15,
        storageContribution: validatorData.ipfsStorage * 0.10
    };
    
    return Object.values(legacyFactors).reduce((a, b) => a + b) +
           Object.values(newFactors).reduce((a, b) => a + b);
}
```

#### Validator Selection
- Top N validators by PoP score process transactions
- Dynamic adjustment based on network load
- Penalty system for poor performance
- Reward distribution based on contribution

---

## 📈 Performance Targets

### Transaction Processing
- **Target TPS**: 10,000+ (business logic limited, not blockchain)
- **Finality**: Sub-1 second confirmation
- **Privacy Operations**: 100x faster than ZK proofs
- **Storage**: 250x smaller than FHE

### Network Economics
- **Zero Gas Fees**: Users pay no transaction fees
- **Validator Compensation**: XOM rewards based on contribution
- **Fee Distribution**: 70% validators, 20% OmniBazaar, 10% stakers

### Scalability Metrics
- **Validator Network**: 100+ active validators
- **Marketplace Capacity**: 1M+ concurrent listings
- **User Base**: 10M+ registered users
- **Transaction Volume**: $1B+ monthly GMV

---

## 🚀 Deployment Strategy

### Phase 1: COTI Testnet Deployment
1. Deploy factory contracts
2. Initialize token allocations
3. Configure privacy settings
4. Test evaluator functions

### Phase 2: Validator Network Launch
1. Deploy validator nodes
2. Initialize PoP consensus
3. Connect to COTI V2 contracts
4. Test marketplace operations

### Phase 3: Limited Mainnet Launch
1. Deploy to COTI V2 mainnet
2. Migrate key legacy users
3. Enable basic marketplace functions
4. Monitor performance metrics

### Current Progress (2025-07-28)

#### ✅ Completed:
1. **Dual-Token Architecture**: Implemented OmniCoin (XOM) and PrivateOmniCoin (pXOM)
2. **Registry Pattern**: All contracts now use OmniCoinRegistry for dynamic discovery
3. **Core Contracts Updated**:
   - OmniCoinAccount, OmniCoinBridge, OmniCoinConfig
   - OmniCoinDividends, OmniCoinEscrow, OmniCoinFactory
   - OmniCoinMultisig, OmniCoinPayment, OmniCoinPrivacy
   - OmniCoinStaking, OmniCoinValidator, OmniWalletProvider
   - PrivacyFeeManager, SecureSend, ValidatorRegistry
4. **Privacy Features**: Integrated COTI MPC types throughout
5. **Decimal Standardization**: Fixed to 6 decimals across all contracts

#### 🚧 In Progress:
1. **ERC-1155 Support**: Next priority for NFT marketplace
2. **Test Suite Development**: Comprehensive testing for all contracts
3. **OmniNFTMarketplace**: Needs completion of dual-token integration

### Phase 4: Full Production Launch
1. Complete legacy migration
2. Enable all evaluator functions
3. Launch marketing campaign
4. Scale validator network

---

## 🔍 Success Metrics

### Technical Metrics
- [ ] All 23 evaluators operational
- [ ] 10K+ TPS sustained throughput
- [ ] <1 second transaction finality
- [ ] 99.9% validator uptime

### Business Metrics
- [ ] 12.45B XOM tokens properly allocated
- [ ] Legacy user migration success rate >95%
- [ ] Zero-fee transactions maintained
- [ ] Marketplace GMV growth >100% YoY

### Security Metrics
- [ ] Zero critical vulnerabilities
- [ ] Successful privacy audit
- [ ] No economic attacks
- [ ] Validator consensus stability

---

## 🎯 Next Immediate Actions

### Next Immediate Priorities
1. **Add ERC-1155 Support** for multi-token NFT marketplace (IN PROGRESS)
2. **Create Comprehensive Test Suite** for all contracts
3. **Complete OmniNFTMarketplace** dual-token integration
4. **Develop Post-Deployment Test Regimen** for testnet

---

## 🎮 NFT Standards Implementation Strategy

### Why ERC-1155 is Critical for OmniBazaar

#### 1. **Cross-Chain Asset Import**
- Gaming assets from other blockchains (weapons, skins, characters)
- Collectible card games and trading cards
- Metaverse items and virtual real estate
- Existing ERC-1155 collections migration

#### 2. **Repeatable Product/Service Listings**
- **Physical Goods**: Handmade crafts, farm products, manufactured items
- **Digital Services**: Design work, consulting hours, API credits
- **Subscriptions**: Membership tokens, access passes, time-based services
- **Consumables**: In-game items, vouchers, tickets

#### 3. **Batch Operations Efficiency**
- Mint 1000 identical items in one transaction
- Transfer multiple different items to multiple recipients
- Significant gas savings for merchants
- Better UX for buyers purchasing multiple items

#### 4. **Gaming & Virtual Assets**
- **Fungible**: Game currencies, resources, materials
- **Non-Fungible**: Unique weapons, characters, land parcels
- **Semi-Fungible**: Limited editions, seasonal items
- **Dynamic**: Items that change state (used/unused, upgraded)

#### 5. **Local P2P Crypto Sales**
- Fractional ownership tokens for high-value assets
- Bulk crypto vouchers for local exchanges
- Redeemable tokens for physical crypto ATMs
- Community currency implementations

### NFT Standards Comparison

| Standard | Use Case | OmniBazaar Priority | Implementation Status |
|----------|----------|-------------------|---------------------|
| **ERC-721** | Unique items, art, collectibles | ✅ High | ✅ Implemented (ListingNFT.sol) |
| **ERC-1155** | Multi-token, gaming, bulk items | ✅ Critical | 🚧 Starting Now |
| **ERC-6551** | Token-bound accounts (NFT wallets) | 🟡 Medium | 📋 Future |
| **ERC-4907** | Rentable NFTs | 🟡 Medium | 📋 Future |
| **ERC-5192** | Soulbound tokens (non-transferable) | 🟢 Low | 📋 Consider |
| **ERC-998** | Composable NFTs (NFTs owning NFTs) | 🟢 Low | 📋 Consider |

### Implementation Architecture

```solidity
// OmniERC1155.sol - Base implementation
contract OmniERC1155 is ERC1155, RegistryAware {
    // Support for both XOM and pXOM payments
    mapping(uint256 => bool) public tokenUsePrivacy;
    mapping(uint256 => uint256) public tokenPrices;
    mapping(uint256 => address) public tokenCreators;
    
    // Marketplace integration
    mapping(uint256 => MarketplaceData) public marketplaceInfo;
    
    struct MarketplaceData {
        bool isForSale;
        uint256 supply;         // Total supply available
        uint256 maxPerPurchase; // Max units per transaction
        string metadataURI;     // Extended metadata
        uint256 royaltyBps;     // Creator royalty in basis points
    }
}

// OmniNFTMarketplace.sol - Unified marketplace
contract OmniNFTMarketplace {
    // Support both ERC-721 and ERC-1155
    enum TokenType { ERC721, ERC1155 }
    
    struct UnifiedListing {
        TokenType tokenType;
        address tokenContract;
        uint256 tokenId;
        uint256 amount;      // 1 for ERC-721, variable for ERC-1155
        uint256 pricePerUnit;
        bool usePrivacy;     // XOM or pXOM payment
    }
}
```

### Development Phases for ERC-1155

#### Phase 1: Core Implementation (Week 1)
- [x] Document requirements and use cases
- [ ] Create OmniERC1155.sol base contract
- [ ] Implement dual-token payment support
- [ ] Add registry integration
- [ ] Basic minting and transfer functions

#### Phase 2: Marketplace Integration (Week 2)
- [ ] Update OmniNFTMarketplace for ERC-1155
- [ ] Implement unified listing structure
- [ ] Add batch purchase functions
- [ ] Create price-per-unit mechanisms

#### Phase 3: Advanced Features (Week 3)
- [ ] Implement royalty system
- [ ] Add metadata standards
- [ ] Create import bridge for external ERC-1155
- [ ] Build creator tools and APIs

#### Phase 4: Testing & Optimization (Week 4)
- [ ] Comprehensive test suite
- [ ] Gas optimization for batch operations
- [ ] Security audit preparation
- [ ] Documentation and examples

### Use Case Examples

#### 1. **Farmer's Market Vendor**
```solidity
// Create 1000 units of organic tomatoes (fungible)
tokenId = mint(1000, "Organic Tomatoes", 5 * 10**6); // 5 XOM each
// Buyers can purchase 1-50 units per transaction
setMaxPerPurchase(tokenId, 50);
```

#### 2. **Digital Artist**
```solidity
// Create limited edition prints (semi-fungible)
tokenId = mint(100, "Limited Print #1", 50 * 10**6); // 50 XOM each
// Set 10% royalty on secondary sales
setRoyalty(tokenId, 1000); // 10%
```

#### 3. **Game Developer**
```solidity
// Create game assets with different rarities
uint256[] memory ids = [1, 2, 3]; // [common, rare, legendary]
uint256[] memory amounts = [10000, 100, 10];
mintBatch(ids, amounts, gameMetadata);
```

#### 4. **Service Provider**
```solidity
// Create consulting hour tokens (fungible)
tokenId = mint(40, "1-Hour Consultation", 100 * 10**6); // 100 XOM per hour
// Redeemable for actual service
setRedeemable(tokenId, true);
```

### Future NFT Standards Consideration

#### Medium Priority (6-12 months)
1. **ERC-6551 (Token Bound Accounts)**
   - NFTs that can own other assets
   - Perfect for game characters with inventory
   - Virtual businesses as NFTs

2. **ERC-4907 (Rentable NFTs)**
   - Temporary usage rights
   - Subscription services
   - Equipment/tool rentals

#### Low Priority (12+ months)
1. **ERC-5192 (Soulbound Tokens)**
   - Reputation badges
   - KYC/verification tokens
   - Achievement certificates

2. **ERC-998 (Composable NFTs)**
   - Bundle products together
   - Complex asset structures
   - Parent-child relationships

### Development Process
1. Implement features incrementally
2. Test each component thoroughly
3. Integrate with existing COTI contracts
4. Validate against legacy behavior
5. Document all changes

### Quality Assurance
- Lint all code before commits
- Run comprehensive test suites
- Validate MPC operations
- Verify token allocation accuracy

---

## 🔧 COTI Deployment Optimization Strategy

### Cost Reduction Techniques
Based on our platform analysis decision to stay with COTI, these optimizations are critical:

#### 1. Hybrid Storage Architecture (90% cost reduction)

**Storage Strategy Clarification**:
- **COTI On-chain**: Only critical state (balances, stakes, ownership)
- **Validator Databases**: Business data (listings, orders, messages)
- **Events**: State changes for validator indexing
- **IPFS**: Large files and permanent storage

**BEFORE: Everything on COTI**
```solidity
contract OmniCoinMarketplace {
    struct Listing {
        address seller;
        string title;        // Expensive COTI storage!
        string description;  // Very expensive!
        uint256 price;
        string imageUrl;     // Expensive!
    }
    mapping(uint256 => Listing) public listings; // All on COTI
}
```

**AFTER: Hybrid approach**
```solidity
contract OmniCoinMarketplace {
    // Only ownership on-chain
    mapping(uint256 => address) public listingOwners;
    
    // Event for validator indexing
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        uint256 price,
        bytes32 dataHash  // Validators store full data
    );
    
    // Validators maintain the actual listing data
    // in their distributed database
}
```

#### 2. Validator-Centric Processing (80% cost reduction)

**BEFORE: Everything processed on COTI**
```solidity
// Each operation = expensive COTI computation
function processOrder(Order memory order) {
    validateOrder(order);      // On COTI
    matchOrder(order);         // On COTI
    settleOrder(order);        // On COTI
    updateOrderBook(order);    // On COTI
}
```

**AFTER: Validator processing with COTI settlement**
```solidity
function settleOrders(bytes32 merkleRoot, uint256 totalValue) {
    // Validators process orders off-chain
    // Only settlement on COTI
    require(validators[msg.sender], "Only validators");
    emit OrdersBatchSettled(merkleRoot, totalValue);
    // Actual order data in validator database
}
```

#### 3. Strategic On-Chain Storage (70% reduction)

**Storage Decision Framework**:
```solidity
// ON COTI: Only what requires blockchain guarantees
contract OmniCoinCore {
    mapping(address => uint256) balances;        // Must be on-chain
    mapping(address => uint256) stakes;          // Must be on-chain
    mapping(uint256 => address) nftOwners;       // Must be on-chain
}

// IN VALIDATOR DB: Business logic data
contract OmniCoinDEX {
    event OrderPlaced(address trader, bytes32 orderHash);
    // Order details in validator database
    // Only emit events for state changes
}

// HYBRID: Critical data on-chain, details off-chain
contract OmniCoinEscrow {
    mapping(uint256 => EscrowState) escrowStates; // On-chain
    event EscrowDetailsUpdated(uint256 id, bytes32 detailsHash);
    // Full escrow terms in validator DB
}
```

#### 4. Validator Database Integration

**What stays on COTI**:
- Token balances and transfers
- Staking amounts and rewards  
- NFT ownership records
- Critical escrow states
- Governance votes (encrypted)
- Reputation scores (encrypted)

**What moves to Validator DB**:
- Marketplace listings and metadata
- DEX order books and trade history
- Chat messages and room data
- KYC attestations (hashed references)
- User profiles and preferences
- Transaction history and analytics

**Synchronization Pattern**:
```solidity
contract ValidatorSync {
    mapping(bytes32 => uint256) public stateRoots;
    
    function updateStateRoot(bytes32 newRoot) external {
        require(validators[msg.sender], "Only validators");
        require(consensusReached(newRoot), "Need consensus");
        stateRoots[block.number] = newRoot;
        emit StateRootUpdated(block.number, newRoot);
    }
}
```

#### 5. Batch Processing Infrastructure
```solidity
contract BatchProcessor {
    struct BatchOperation {
        address target;
        bytes data;
        uint256 value;
    }
    
    // Process multiple operations in single transaction
    function processBatch(BatchOperation[] calldata ops) external {
        require(validators[msg.sender], "Only validators");
        for(uint i = 0; i < ops.length; i++) {
            (bool success,) = ops[i].target.call{value: ops[i].value}(ops[i].data);
            require(success, "Batch operation failed");
        }
        emit BatchProcessed(ops.length, block.timestamp);
    }
}
```

### Implementation Timeline
1. **Week 1**: Identify data for validator DB vs on-chain
2. **Week 2**: Implement validator consensus for DB updates
3. **Week 3**: Create batch processing infrastructure
4. **Week 4**: Optimize remaining on-chain storage

### Expected Savings
- **Transaction costs**: 70-90% reduction
- **Storage costs**: 60-80% reduction
- **Deployment costs**: 50% reduction through batching
- **Daily operations**: From $1000s to $100s

---

## Implementation Timeline Update (2025-07-28)

### Completed ✅
- Dual-token architecture (XOM/pXOM)
- Registry pattern integration
- Core contract updates (38 contracts)
- Decimal standardization (6 decimals)

### In Progress 🚧
- ERC-1155 implementation
- Test suite development
- OmniNFTMarketplace completion

### Next Sprint 📋
- Gaming asset import bridge
- Service token templates
- Batch operation optimization
- Cross-standard compatibility

---

This development plan ensures OmniCoin preserves all legacy functionality while leveraging COTI V2's advanced privacy and performance capabilities. The phased approach allows for systematic implementation, testing, and deployment while maintaining the exact token economics derived from the blockchain analysis. The optimization strategies ensure cost-effective operations while maintaining our unique MPC privacy advantages.