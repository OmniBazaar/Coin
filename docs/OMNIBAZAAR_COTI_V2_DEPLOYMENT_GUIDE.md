# OmniBazaar COTI V2 Deployment Guide

**Created:** 2025-07-26
**Author:** Development Team
**Status:** Ready for Implementation

## Executive Summary

This guide documents the complete path forward for deploying OmniBazaar on COTI V2 L2. With the discovery that COTI V2 is a fully-featured Ethereum Layer 2 (not just a privacy toolkit), we can deploy in 4-6 weeks rather than 6-12 months. This guide covers architecture, implementation steps, frontend-backend integration, and deployment procedures.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Development Environment Setup](#development-environment-setup)
3. [Frontend-Backend Integration](#frontend-backend-integration)
4. [Contract Deployment Process](#contract-deployment-process)
5. [Privacy Implementation](#privacy-implementation)
6. [Testing Strategy](#testing-strategy)
7. [Mainnet Deployment](#mainnet-deployment)
8. [Post-Deployment Operations](#post-deployment-operations)

## Architecture Overview

### System Architecture

```
┌─────────────────────────────────────────────────────┐
│                  User Interface                      │
│         (Browser Extension / Mobile App)             │
└─────────────────┬────────────────┬──────────────────┘
                  │                │
                  ▼                ▼
┌─────────────────────────┐ ┌──────────────────────────┐
│   Frontend SDK Layer    │ │    API Gateway           │
│ @coti-io/coti-sdk-      │ │  (OmniBazaar Validators) │
│    typescript           │ └──────────┬───────────────┘
└──────────┬──────────────┘            │
           │                           │
           ▼                           ▼
┌──────────────────────────────────────────────────────┐
│              COTI V2 L2 Blockchain                   │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
│  │ OmniCoinCore │  │ Marketplace  │  │    DEX     ││
│  │  & Registry  │  │  Contracts   │  │ Settlement ││
│  └──────────────┘  └──────────────┘  └────────────┘│
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
│  │   Privacy    │  │   Escrow &   │  │ Reputation ││
│  │ Fee Manager  │  │   Payment    │  │   System   ││
│  └──────────────┘  └──────────────┘  └────────────┘│
└─────────────────────┬────────────────────────────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │   Ethereum Mainnet     │
         │  (Periodic Settlement) │
         └────────────────────────┘
```

### Data Flow

1. **Public Transactions**: User → Frontend → COTI V2 → Instant confirmation
2. **Private Transactions**: User → Frontend → Privacy credit check → Encrypted processing → COTI V2
3. **Validator Operations**: Off-chain order matching → Submit to COTI V2 for settlement
4. **Cross-chain**: COTI Bridge handles ETH ↔ COTI V2 automatically

## Development Environment Setup

### Prerequisites

```bash
# Required versions
node >= 18.0.0
npm >= 9.0.0
git >= 2.30.0

# Install COTI tools
npm install -g @coti-io/hardhat-plugin
```

### Project Configuration

#### 1. Update hardhat.config.ts

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@coti-io/hardhat-plugin";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    cotiTestnet: {
      url: "https://testnet.coti.io",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 13068200
    },
    cotiMainnet: {
      url: "https://mainnet.coti.io",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 13068201
    }
  },
  coti: {
    deployerAddress: process.env.DEPLOYER_ADDRESS || "",
    deployerPrivateKey: process.env.PRIVATE_KEY || ""
  }
};

export default config;
```

#### 2. Environment Variables (.env)

```bash
# COTI Network Configuration
COTI_TESTNET_URL=https://testnet.coti.io
COTI_MAINNET_URL=https://mainnet.coti.io
PRIVATE_KEY=your_private_key_here
DEPLOYER_ADDRESS=your_deployer_address_here

# API Keys
COTI_API_KEY=your_coti_api_key
INFURA_KEY=your_infura_key

# Contract Addresses (populated after deployment)
OMNICOIN_CORE_ADDRESS=
REGISTRY_ADDRESS=
PRIVACY_FEE_MANAGER_ADDRESS=
MARKETPLACE_ADDRESS=
DEX_SETTLEMENT_ADDRESS=
```

## Frontend-Backend Integration

### Frontend SDK Integration

#### 1. Initialize COTI SDK

```typescript
// frontend/src/services/cotiService.ts
import { CotiSDK, NetworkConfig } from '@coti-io/coti-sdk-typescript';
import { ethers } from 'ethers';

export class CotiService {
  private sdk: CotiSDK;
  private provider: ethers.Provider;
  
  constructor(network: 'testnet' | 'mainnet') {
    const config: NetworkConfig = {
      network,
      apiKey: process.env.REACT_APP_COTI_API_KEY,
      rpcUrl: network === 'testnet' 
        ? process.env.REACT_APP_COTI_TESTNET_URL 
        : process.env.REACT_APP_COTI_MAINNET_URL
    };
    
    this.sdk = new CotiSDK(config);
    this.provider = this.sdk.getProvider();
  }
  
  // Connect wallet
  async connectWallet(): Promise<string> {
    const signer = await this.sdk.connectWallet();
    return await signer.getAddress();
  }
  
  // Handle privacy operations
  async executePrivateTransaction(
    contractAddress: string,
    abi: any[],
    method: string,
    params: any[],
    usePrivacy: boolean = false
  ) {
    const contract = this.sdk.getContract(contractAddress, abi);
    
    if (usePrivacy) {
      // Enable privacy for this transaction
      return await contract[method + 'WithPrivacy'](...params);
    } else {
      // Standard public transaction
      return await contract[method](...params);
    }
  }
}
```

#### 2. Privacy Toggle Component

```typescript
// frontend/src/components/PrivacyToggle.tsx
import React, { useState, useEffect } from 'react';
import { useWallet } from '../hooks/useWallet';
import { PrivacyFeeManager } from '../contracts/types';

interface PrivacyToggleProps {
  operationType: string;
  amount: bigint;
  onToggle: (enabled: boolean) => void;
}

export const PrivacyToggle: React.FC<PrivacyToggleProps> = ({
  operationType,
  amount,
  onToggle
}) => {
  const [isPrivate, setIsPrivate] = useState(false);
  const [privacyFee, setPrivacyFee] = useState<bigint>(0n);
  const [userCredits, setUserCredits] = useState<bigint>(0n);
  const { account, contracts } = useWallet();
  
  useEffect(() => {
    loadPrivacyInfo();
  }, [account, operationType, amount]);
  
  const loadPrivacyInfo = async () => {
    if (!contracts?.privacyFeeManager || !account) return;
    
    // Get fee for this operation
    const fee = await contracts.privacyFeeManager.calculatePrivacyFee(
      ethers.utils.id(operationType),
      amount
    );
    setPrivacyFee(fee);
    
    // Get user's privacy credits
    const credits = await contracts.privacyFeeManager.userPrivacyCredits(account);
    setUserCredits(credits);
  };
  
  const handleToggle = async () => {
    const newState = !isPrivate;
    setIsPrivate(newState);
    onToggle(newState);
    
    if (newState && userCredits < privacyFee) {
      // Prompt to deposit privacy credits
      alert(`You need ${ethers.utils.formatUnits(privacyFee - userCredits, 6)} more credits for privacy`);
    }
  };
  
  return (
    <div className="privacy-toggle">
      <label className="switch">
        <input 
          type="checkbox" 
          checked={isPrivate}
          onChange={handleToggle}
        />
        <span className="slider">
          {isPrivate ? '🔒 Private' : '🌐 Public'}
        </span>
      </label>
      
      {isPrivate && (
        <div className="privacy-info">
          <p>Privacy Fee: {ethers.utils.formatUnits(privacyFee, 6)} XOM</p>
          <p>Your Credits: {ethers.utils.formatUnits(userCredits, 6)} XOM</p>
        </div>
      )}
    </div>
  );
};
```

#### 3. Marketplace Integration

```typescript
// frontend/src/services/marketplaceService.ts
export class MarketplaceService {
  private cotiService: CotiService;
  private contracts: ContractInstances;
  
  async createListing(
    metadata: ListingMetadata,
    price: bigint,
    usePrivacy: boolean
  ): Promise<string> {
    // Upload to IPFS first
    const ipfsHash = await this.uploadToIPFS(metadata);
    
    // Create listing on-chain
    const tx = await this.cotiService.executePrivateTransaction(
      this.contracts.marketplace.address,
      MarketplaceABI,
      'createListing',
      [ipfsHash, price, metadata.category],
      usePrivacy
    );
    
    const receipt = await tx.wait();
    return this.extractListingId(receipt);
  }
  
  async purchaseItem(
    listingId: string,
    usePrivacy: boolean
  ): Promise<void> {
    const listing = await this.contracts.marketplace.getListing(listingId);
    
    if (usePrivacy) {
      // Ensure sufficient privacy credits
      await this.ensurePrivacyCredits(listing.price);
    }
    
    await this.cotiService.executePrivateTransaction(
      this.contracts.marketplace.address,
      MarketplaceABI,
      'purchaseItem',
      [listingId],
      usePrivacy
    );
  }
}
```

### Backend Validator Integration

#### 1. Order Matching Service

```typescript
// validator/src/services/orderMatchingService.ts
import { ethers } from '@coti-io/coti-ethers';

export class OrderMatchingService {
  private provider: ethers.Provider;
  private signer: ethers.Signer;
  private dexContract: ethers.Contract;
  
  async matchOrders(): Promise<void> {
    // Get pending orders from local database
    const buyOrders = await this.db.getPendingBuyOrders();
    const sellOrders = await this.db.getPendingSellOrders();
    
    // Run matching algorithm
    const matches = this.findMatches(buyOrders, sellOrders);
    
    // Batch submit to COTI V2
    for (const batch of this.batchMatches(matches, 50)) {
      const tx = await this.dexContract.settleBatch(
        batch.map(m => ({
          buyOrderId: m.buyOrder.id,
          sellOrderId: m.sellOrder.id,
          price: m.executionPrice,
          amount: m.amount
        }))
      );
      
      await tx.wait();
      
      // Update local database
      await this.db.markOrdersAsSettled(batch);
    }
  }
}
```

#### 2. Privacy Transaction Monitoring

```typescript
// validator/src/services/privacyMonitor.ts
export class PrivacyMonitor {
  async monitorPrivacyUsage(): Promise<PrivacyStats> {
    const filter = this.privacyFeeManager.filters.PrivacyCreditsUsed();
    const events = await this.privacyFeeManager.queryFilter(filter, -1000);
    
    return {
      totalTransactions: events.length,
      uniqueUsers: new Set(events.map(e => e.args.user)).size,
      totalFeesCollected: events.reduce(
        (sum, e) => sum + e.args.feeAmount, 
        0n
      ),
      byOperationType: this.groupByOperationType(events)
    };
  }
}
```

## Contract Deployment Process

### Phase 1: Core Infrastructure (Week 1)

```bash
# Deploy in this order
npx hardhat run scripts/deploy/1-deploy-core.ts --network cotiTestnet
```

```typescript
// scripts/deploy/1-deploy-core.ts
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  
  // 1. Deploy OmniCoinCore
  const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
  const omniCoin = await OmniCoinCore.deploy(
    "OmniCoin",
    "XOM",
    1000000000, // 1B tokens
    6 // decimals
  );
  await omniCoin.deployed();
  
  // 2. Deploy Registry
  const Registry = await ethers.getContractFactory("OmniCoinRegistry");
  const registry = await Registry.deploy(deployer.address);
  await registry.deployed();
  
  // 3. Deploy PrivacyFeeManager
  const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
  const privacyFeeManager = await PrivacyFeeManager.deploy(
    omniCoin.address,
    deployer.address
  );
  await privacyFeeManager.deployed();
  
  // 4. Update Registry
  await registry.setContract("OMNICOIN_CORE", omniCoin.address);
  await registry.setContract("PRIVACY_FEE_MANAGER", privacyFeeManager.address);
  
  console.log("Core deployed:");
  console.log("- OmniCoinCore:", omniCoin.address);
  console.log("- Registry:", registry.address);
  console.log("- PrivacyFeeManager:", privacyFeeManager.address);
  
  // Save addresses
  await saveDeploymentAddresses({
    OmniCoinCore: omniCoin.address,
    Registry: registry.address,
    PrivacyFeeManager: privacyFeeManager.address
  });
}
```

### Phase 2: Financial Contracts (Week 2)

```typescript
// scripts/deploy/2-deploy-financial.ts
async function main() {
  const addresses = await loadDeploymentAddresses();
  const helper = await deployFinancialHelper(addresses.Registry);
  
  const contracts = await helper.deployAll();
  
  // Update registry with all addresses
  const registry = await ethers.getContractAt("OmniCoinRegistry", addresses.Registry);
  await registry.setContract("ESCROW", contracts.escrow);
  await registry.setContract("PAYMENT", contracts.payment);
  await registry.setContract("STAKING", contracts.staking);
  await registry.setContract("BRIDGE", contracts.bridge);
}
```

### Phase 3: Marketplace & DEX (Week 3)

```typescript
// scripts/deploy/3-deploy-marketplace.ts
async function main() {
  const addresses = await loadDeploymentAddresses();
  const helper = await deployMarketplaceHelper(addresses.Registry);
  
  const contracts = await helper.deployAll();
  
  // Configure marketplace
  const marketplace = await ethers.getContractAt(
    "OmniNFTMarketplace", 
    contracts.marketplace
  );
  
  // Set listing NFT as approved minter
  const listingNFT = await ethers.getContractAt(
    "ListingNFT",
    contracts.listingNFT
  );
  await listingNFT.setApprovedMinter(marketplace.address, true);
}
```

## Privacy Implementation

### Privacy Credit System

The privacy credit system prevents timing correlation:

```typescript
// User deposits credits in advance
async function depositPrivacyCredits(amount: bigint) {
  // Approve tokens
  await omniCoin.approve(privacyFeeManager.address, amount);
  
  // Deposit credits
  await privacyFeeManager.depositPrivacyCredits(amount);
}

// Credits are deducted internally when using privacy
async function createPrivateListing(metadata: string, price: bigint) {
  // No visible fee transaction - credits deducted internally
  await marketplace.createListingWithPrivacy(metadata, price);
}
```

### Privacy Best Practices

1. **Batch Credit Deposits**: Encourage users to deposit credits in batches
2. **Privacy Pools**: Multiple users deposit at similar times
3. **Random Delays**: Add random delays between deposit and usage
4. **Minimum Balance**: Maintain minimum credit balance for regular users

## Testing Strategy

### Unit Tests

```typescript
// test/privacy/PrivacyFeeManager.test.ts
describe("PrivacyFeeManager", () => {
  it("should calculate correct privacy fees", async () => {
    const fee = await privacyFeeManager.calculatePrivacyFee(
      ethers.utils.id("TRANSFER"),
      ethers.utils.parseUnits("100", 6)
    );
    expect(fee).to.equal(ethers.utils.parseUnits("10", 6)); // 10x multiplier
  });
  
  it("should prevent timing correlation", async () => {
    // Deposit credits
    await privacyFeeManager.depositPrivacyCredits(PRIVACY_DEPOSIT);
    
    // Use privacy later - no visible transaction
    await escrow.createEscrowWithPrivacy(...params);
    
    // Verify credits were deducted
    const credits = await privacyFeeManager.userPrivacyCredits(user);
    expect(credits).to.be.lt(PRIVACY_DEPOSIT);
  });
});
```

### Integration Tests

```bash
# Run on COTI testnet
npm run test:integration:testnet

# Test privacy features
npm run test:privacy:testnet

# Load testing
npm run test:load:testnet
```

### Test Coverage Requirements

- Unit tests: 95% coverage minimum
- Integration tests: All user flows covered
- Privacy tests: All privacy operations tested
- Load tests: 40 TPS for privacy operations verified

## Mainnet Deployment

### Pre-Deployment Checklist

- [ ] All tests passing on testnet
- [ ] Security audit completed
- [ ] Gas optimization verified
- [ ] Privacy credit economics validated
- [ ] Frontend fully integrated
- [ ] Validator network ready
- [ ] Documentation complete
- [ ] Emergency procedures documented

### Deployment Steps

1. **Deploy Core Contracts**
   ```bash
   npm run deploy:mainnet:core
   ```

2. **Deploy Application Contracts**
   ```bash
   npm run deploy:mainnet:app
   ```

3. **Verify Contracts**
   ```bash
   npm run verify:mainnet
   ```

4. **Initialize Systems**
   ```bash
   npm run initialize:mainnet
   ```

### Post-Deployment Verification

```typescript
// scripts/verify-deployment.ts
async function verifyDeployment() {
  // Verify all contracts deployed
  await verifyContractAddresses();
  
  // Test basic operations
  await testTokenTransfer();
  await testPrivacyDeposit();
  await testMarketplaceListing();
  
  // Verify validator sync
  await verifyValidatorConnection();
  
  console.log("✅ Deployment verified successfully");
}
```

## Post-Deployment Operations

### Monitoring

```typescript
// monitoring/dashboard.ts
export class MonitoringDashboard {
  metrics = {
    totalTransactions: 0,
    privacyTransactions: 0,
    activeUsers: new Set(),
    gasUsed: 0n,
    systemHealth: 'healthy'
  };
  
  async updateMetrics() {
    // Monitor transaction volume
    const txCount = await this.provider.getBlockNumber();
    
    // Monitor privacy usage
    const privacyStats = await this.privacyMonitor.getStats();
    
    // Monitor gas prices
    const gasPrice = await this.provider.getGasPrice();
    
    // Alert if issues detected
    if (gasPrice > MAX_GAS_THRESHOLD) {
      await this.alert("High gas prices detected");
    }
  }
}
```

### Maintenance Procedures

1. **Weekly Tasks**
   - Review privacy credit usage patterns
   - Analyze gas consumption
   - Check validator synchronization
   - Review error logs

2. **Monthly Tasks**
   - Update privacy fee parameters if needed
   - Review and optimize gas usage
   - Audit privacy credit deposits vs usage
   - Generate usage reports

3. **Emergency Procedures**
   - Contract pause mechanism
   - Fund recovery procedures
   - Validator failover
   - Communication protocols

## Success Metrics

### Week 1-2 (Testnet)
- [ ] Core contracts deployed
- [ ] Basic operations working
- [ ] Privacy features tested

### Week 3-4 (Integration)
- [ ] Frontend fully integrated
- [ ] 40 TPS achieved for privacy ops
- [ ] All tests passing

### Week 5-6 (Mainnet Prep)
- [ ] Security audit complete
- [ ] Documentation finalized
- [ ] Team trained on operations

### Post-Launch (Ongoing)
- [ ] 1,000+ active users
- [ ] 10,000+ transactions/day
- [ ] <1% error rate
- [ ] 99.9% uptime

## Appendix A: Contract Addresses

### Testnet Addresses
```
OmniCoinCore: 0x...
Registry: 0x...
PrivacyFeeManager: 0x...
Marketplace: 0x...
DEXSettlement: 0x...
```

### Mainnet Addresses
```
[To be populated after deployment]
```

## Appendix B: Emergency Contacts

- Technical Lead: [Contact]
- Security Team: [Contact]
- COTI Support: support@coti.io
- Validator Network: [Contact]

## Appendix C: Useful Commands

```bash
# Deploy contracts
npm run deploy:[network]:[phase]

# Run tests
npm run test:[type]:[network]

# Monitor system
npm run monitor:[network]

# Emergency pause
npm run emergency:pause:[network]

# Generate reports
npm run report:[type]
```

## Conclusion

This guide provides a complete roadmap for deploying OmniBazaar on COTI V2 L2. The architecture leverages COTI's infrastructure while maintaining our unique value proposition through the validator network. With proper execution, we can launch in 4-6 weeks with enterprise-grade privacy features.

Key success factors:
1. Leverage COTI's complete L2 infrastructure
2. Focus on our unique business logic
3. Implement privacy as a premium feature
4. Ensure seamless frontend integration
5. Maintain operational excellence

For questions or clarifications, contact the development team.