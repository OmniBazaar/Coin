# OmniCoin Implementation Guide

## Overview

This guide provides detailed instructions for building and setting up a testnet for the OmniCoin smart contract ecosystem. The implementation can be deployed locally using Hardhat or on the COTI V2 testnet for more realistic testing conditions.

## Prerequisites

### System Requirements
- **Node.js**: Version 18.x or later
- **npm**: Version 8.x or later
- **Git**: Latest version
- **Hardware**: Minimum 8GB RAM, 100GB storage

### Development Tools

```bash
# Install global dependencies
npm install -g hardhat
npm install -g @openzeppelin/cli
npm install -g @coti-io/coti-cli
```

## Environment Setup

### 1. Clone and Setup Repository

```bash
# Clone the repository
git clone https://github.com/your-org/OmniBazaar.git
cd OmniBazaar/Coin

# Install dependencies
npm install

# Install missing OpenZeppelin contracts
npm install @openzeppelin/contracts@^5.0.0
npm install @openzeppelin/contracts-upgradeable@^5.0.0
npm install @openzeppelin/hardhat-upgrades@^3.0.0
```

### 2. Environment Configuration

Create a `.env` file in the `Coin` directory:

```bash
# .env file
# Private Keys (DO NOT use in production)
PRIVATE_KEY=your_private_key_here
DEPLOYER_PRIVATE_KEY=your_deployer_private_key_here

# Network Configuration
MAINNET_RPC_URL=https://mainnet.infura.io/v3/your_infura_key
TESTNET_RPC_URL=https://testnet.coti.io
LOCALHOST_RPC_URL=http://127.0.0.1:8545

# API Keys
ETHERSCAN_API_KEY=your_etherscan_api_key
COTI_API_KEY=your_coti_api_key

# Contract Configuration
INITIAL_SUPPLY=1000000000000000000000000000  # 1 billion tokens
MAX_VALIDATORS=100
MIN_STAKE_AMOUNT=1000000000000000000000      # 1000 tokens
STAKING_REWARD_RATE=500                      # 5% APR
```

### 3. Update Package.json

Update the `package.json` file to include all necessary dependencies:

```json
{
  "name": "omnicoin-contracts",
  "version": "2.0.0",
  "description": "OmniCoin Smart Contract Ecosystem",
  "main": "index.js",
  "scripts": {
    "compile": "hardhat compile",
    "test": "hardhat test",
    "test:security": "hardhat test test/security/",
    "test:integration": "hardhat test test/integration/",
    "test:gas": "hardhat test --gas-reporter",
    "deploy:local": "hardhat run scripts/deploy.js --network localhost",
    "deploy:coti-testnet": "hardhat run scripts/deploy.js --network cotiTestnet",
    "deploy:mainnet": "hardhat run scripts/deploy.js --network mainnet",
    "verify": "hardhat verify --network",
    "lint": "solhint contracts/*.sol",
    "security-check": "slither contracts/",
    "coverage": "hardhat coverage"
  },
  "dependencies": {
    "@coti-io/coti-contracts": "^1.0.9",
    "@coti-io/coti-ethers": "^1.0.5",
    "@openzeppelin/contracts": "^5.0.0",
    "@openzeppelin/contracts-upgradeable": "^5.0.0",
    "dotenv": "^16.4.5"
  },
  "devDependencies": {
    "@nomicfoundation/hardhat-toolbox": "^5.0.0",
    "@openzeppelin/hardhat-upgrades": "^3.0.0",
    "hardhat": "^2.22.15",
    "hardhat-gas-reporter": "^1.0.9",
    "solidity-coverage": "^0.8.5",
    "slither-analyzer": "^0.10.0",
    "solhint": "^4.0.0"
  }
}
```

## Local Testnet Setup

### 1. Start Local Hardhat Network

```bash
# Terminal 1 - Start local blockchain
npx hardhat node

# The local network will be available at http://127.0.0.1:8545
# Default accounts and private keys will be displayed
```

### 2. Deploy Contracts Locally

```bash
# Terminal 2 - Deploy contracts
npm run deploy:local

# This will deploy all contracts and display their addresses
```

### 3. Configure Hardhat Network

Update `hardhat.config.js` for comprehensive network support:

```javascript
require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true
    }
  },
  networks: {
    hardhat: {
      chainId: 1337,
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
        count: 20,
        accountsBalance: "10000000000000000000000" // 10000 ETH
      }
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      accounts: [process.env.PRIVATE_KEY]
    },
    cotiTestnet: {
      url: process.env.TESTNET_RPC_URL || "https://testnet.coti.io",
      chainId: 13068200,
      accounts: [process.env.PRIVATE_KEY],
      gasPrice: 1000000000, // 1 gwei
      gas: 8000000
    },
    cotiMainnet: {
      url: process.env.MAINNET_RPC_URL || "https://mainnet.coti.io",
      chainId: 7,
      accounts: [process.env.PRIVATE_KEY],
      gasPrice: 1000000000
    }
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 20,
    showTimeSpent: true,
    showMethodSig: true
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY
  },
  mocha: {
    timeout: 40000
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};
```

## COTI Testnet Deployment

### 1. COTI Testnet Configuration

```bash
# Get COTI testnet tokens
curl -X POST "https://faucet.testnet.coti.io/api/faucet" \
  -H "Content-Type: application/json" \
  -d '{"address": "YOUR_WALLET_ADDRESS"}'

# Check your balance
npx hardhat run scripts/checkBalance.js --network cotiTestnet
```

### 2. Deploy to COTI Testnet

```bash
# Deploy all contracts to COTI testnet
npm run deploy:coti-testnet

# Verify contracts on COTI explorer
npm run verify cotiTestnet
```

### 3. COTI-Specific Configuration

Create `scripts/coti-setup.js`:

```javascript
const { ethers, upgrades } = require("hardhat");
const { getCotiSDK } = require("@coti-io/coti-ethers");

async function setupCotiFeatures() {
  // Initialize COTI SDK
  const cotiSDK = await getCotiSDK();
  
  // Deploy with COTI garbled circuits privacy features
  const OmniCoinCoti = await ethers.getContractFactory("omnicoin-erc20-coti");
  const omniCoin = await upgrades.deployProxy(OmniCoinCoti, [], {
    initializer: "initialize",
    kind: "uups"
  });
  
  await omniCoin.deployed();
  console.log("OmniCoin deployed to:", omniCoin.address);
  
  // Configure COTI garbled circuits privacy features
  await omniCoin.enablePrivacy(true);
  console.log("Garbled circuits privacy features enabled");
  
  return omniCoin;
}

module.exports = { setupCotiFeatures };
```

## Contract Deployment Scripts

### 1. Main Deployment Script

Create `scripts/deploy.js`:

```javascript
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  
  const deploymentAddresses = {};
  
  // 1. Deploy Configuration Contract
  console.log("Deploying OmniCoinConfig...");
  const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
  const config = await OmniCoinConfig.deploy();
  await config.deployed();
  deploymentAddresses.config = config.address;
  console.log("OmniCoinConfig deployed to:", config.address);
  
  // 2. Deploy Reputation Contract
  console.log("Deploying OmniCoinReputation...");
  const OmniCoinReputation = await ethers.getContractFactory("OmniCoinReputation");
  const reputation = await OmniCoinReputation.deploy();
  await reputation.deployed();
  deploymentAddresses.reputation = reputation.address;
  console.log("OmniCoinReputation deployed to:", reputation.address);
  
  // 3. Deploy Staking Contract
  console.log("Deploying OmniCoinStaking...");
  const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
  const staking = await OmniCoinStaking.deploy();
  await staking.deployed();
  deploymentAddresses.staking = staking.address;
  console.log("OmniCoinStaking deployed to:", staking.address);
  
  // 4. Deploy Validator Contract
  console.log("Deploying OmniCoinValidator...");
  const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
  const validator = await OmniCoinValidator.deploy(staking.address);
  await validator.deployed();
  deploymentAddresses.validator = validator.address;
  console.log("OmniCoinValidator deployed to:", validator.address);
  
  // 5. Deploy ValidatorRegistry Contract
  console.log("Deploying ValidatorRegistry...");
  const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
  const validatorRegistry = await ValidatorRegistry.deploy();
  await validatorRegistry.deployed();
  deploymentAddresses.validatorRegistry = validatorRegistry.address;
  console.log("ValidatorRegistry deployed to:", validatorRegistry.address);
  
  // 6. Deploy Multisig Contract
  console.log("Deploying OmniCoinMultisig...");
  const OmniCoinMultisig = await ethers.getContractFactory("OmniCoinMultisig");
  const multisig = await OmniCoinMultisig.deploy();
  await multisig.deployed();
  deploymentAddresses.multisig = multisig.address;
  console.log("OmniCoinMultisig deployed to:", multisig.address);
  
  // 7. Deploy Privacy Contract
  console.log("Deploying OmniCoinPrivacy...");
  const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
  const privacy = await OmniCoinPrivacy.deploy(ethers.constants.AddressZero); // Will be updated after token deployment
  await privacy.deployed();
  deploymentAddresses.privacy = privacy.address;
  console.log("OmniCoinPrivacy deployed to:", privacy.address);
  
  // 8. Deploy Garbled Circuit Contract
  console.log("Deploying OmniCoinGarbledCircuit...");
  const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
  const garbledCircuit = await OmniCoinGarbledCircuit.deploy();
  await garbledCircuit.deployed();
  deploymentAddresses.garbledCircuit = garbledCircuit.address;
  console.log("OmniCoinGarbledCircuit deployed to:", garbledCircuit.address);
  
  // 9. Deploy Governor Contract
  console.log("Deploying OmniCoinGovernor...");
  const OmniCoinGovernor = await ethers.getContractFactory("OmniCoinGovernor");
  const governor = await OmniCoinGovernor.deploy(ethers.constants.AddressZero); // Will be updated after token deployment
  await governor.deployed();
  deploymentAddresses.governor = governor.address;
  console.log("OmniCoinGovernor deployed to:", governor.address);
  
  // 10. Deploy Escrow Contract
  console.log("Deploying OmniCoinEscrow...");
  const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
  const escrow = await OmniCoinEscrow.deploy(ethers.constants.AddressZero); // Will be updated after token deployment
  await escrow.deployed();
  deploymentAddresses.escrow = escrow.address;
  console.log("OmniCoinEscrow deployed to:", escrow.address);
  
  // 11. Deploy Bridge Contract
  console.log("Deploying OmniCoinBridge...");
  const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
  const bridge = await OmniCoinBridge.deploy(ethers.constants.AddressZero); // Will be updated after token deployment
  await bridge.deployed();
  deploymentAddresses.bridge = bridge.address;
  console.log("OmniCoinBridge deployed to:", bridge.address);
  
  // 12. Deploy Main Token Contract
  console.log("Deploying OmniCoin...");
  const OmniCoin = await ethers.getContractFactory("OmniCoin");
  const omniCoin = await OmniCoin.deploy(
    config.address,
    reputation.address,
    staking.address,
    validator.address,
    multisig.address,
    privacy.address,
    garbledCircuit.address,
    governor.address,
    escrow.address,
    bridge.address
  );
  await omniCoin.deployed();
  deploymentAddresses.omniCoin = omniCoin.address;
  console.log("OmniCoin deployed to:", omniCoin.address);
  
  // 13. Deploy COTI Integration Contract
  console.log("Deploying OmniCoin COTI Integration...");
  const OmniCoinCoti = await ethers.getContractFactory("OmniCoin");
  const omniCoinCoti = await upgrades.deployProxy(OmniCoinCoti, [], {
    initializer: "initialize",
    kind: "uups"
  });
  await omniCoinCoti.deployed();
  deploymentAddresses.omniCoinCoti = omniCoinCoti.address;
  console.log("OmniCoin COTI Integration deployed to:", omniCoinCoti.address);
  
  // 14. Deploy Wallet Integration Contracts
  console.log("Deploying OmniWalletProvider...");
  const OmniWalletProvider = await ethers.getContractFactory("OmniWalletProvider");
  const walletProvider = await upgrades.deployProxy(OmniWalletProvider, [
    omniCoinCoti.address,
    ethers.constants.AddressZero, // Account manager
    ethers.constants.AddressZero, // Payment processor
    escrow.address,
    privacy.address,
    bridge.address,
    ethers.constants.AddressZero  // NFT manager
  ]);
  await walletProvider.deployed();
  deploymentAddresses.walletProvider = walletProvider.address;
  console.log("OmniWalletProvider deployed to:", walletProvider.address);
  
  // 15. Deploy Batch Transactions
  console.log("Deploying OmniBatchTransactions...");
  const OmniBatchTransactions = await ethers.getContractFactory("OmniBatchTransactions");
  const batchTransactions = await upgrades.deployProxy(OmniBatchTransactions, [
    omniCoinCoti.address
  ]);
  await batchTransactions.deployed();
  deploymentAddresses.batchTransactions = batchTransactions.address;
  console.log("OmniBatchTransactions deployed to:", batchTransactions.address);
  
  // 16. Deploy Fee Distribution
  console.log("Deploying FeeDistribution...");
  const FeeDistribution = await ethers.getContractFactory("FeeDistribution");
  const feeDistribution = await FeeDistribution.deploy();
  await feeDistribution.deployed();
  deploymentAddresses.feeDistribution = feeDistribution.address;
  console.log("FeeDistribution deployed to:", feeDistribution.address);
  
  // Update contract references
  console.log("Updating contract references...");
  await privacy.transferOwnership(omniCoin.address);
  await governor.transferOwnership(omniCoin.address);
  await escrow.transferOwnership(omniCoin.address);
  await bridge.transferOwnership(omniCoin.address);
  
  // Initial configuration
  console.log("Initial configuration...");
  await omniCoin.mint(deployer.address, ethers.utils.parseEther("1000000")); // 1M tokens for testing
  await validatorRegistry.setMinStake(ethers.utils.parseEther("1000"));
  await validatorRegistry.setMaxValidators(100);
  
  // Save deployment addresses
  const deploymentsPath = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsPath)) {
    fs.mkdirSync(deploymentsPath);
  }
  
  fs.writeFileSync(
    path.join(deploymentsPath, `${network.name}.json`),
    JSON.stringify(deploymentAddresses, null, 2)
  );
  
  console.log("Deployment completed successfully!");
  console.log("Deployment addresses saved to:", path.join(deploymentsPath, `${network.name}.json`));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
```

### 2. Validator Setup Script

Create `scripts/setup-validators.js`:

```javascript
const { ethers } = require("hardhat");
const deployments = require("../deployments/localhost.json");

async function setupValidators() {
  const [deployer, validator1, validator2, validator3] = await ethers.getSigners();
  
  // Get contract instances
  const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
  const validatorRegistry = ValidatorRegistry.attach(deployments.validatorRegistry);
  
  const OmniCoin = await ethers.getContractFactory("OmniCoin");
  const omniCoin = OmniCoin.attach(deployments.omniCoin);
  
  // Setup validators
  const stakeAmount = ethers.utils.parseEther("10000"); // 10K tokens
  
  // Transfer tokens to validators
  await omniCoin.transfer(validator1.address, stakeAmount);
  await omniCoin.transfer(validator2.address, stakeAmount);
  await omniCoin.transfer(validator3.address, stakeAmount);
  
  // Approve staking
  await omniCoin.connect(validator1).approve(validatorRegistry.address, stakeAmount);
  await omniCoin.connect(validator2).approve(validatorRegistry.address, stakeAmount);
  await omniCoin.connect(validator3).approve(validatorRegistry.address, stakeAmount);
  
  // Register validators
  await validatorRegistry.connect(validator1).registerValidator(
    "validator1",
    "QmValidator1Hash",
    { cpu: 8, memory: 16, storage: 500 }
  );
  
  await validatorRegistry.connect(validator2).registerValidator(
    "validator2", 
    "QmValidator2Hash",
    { cpu: 8, memory: 16, storage: 500 }
  );
  
  await validatorRegistry.connect(validator3).registerValidator(
    "validator3",
    "QmValidator3Hash", 
    { cpu: 8, memory: 16, storage: 500 }
  );
  
  // Stake tokens
  await validatorRegistry.connect(validator1).stake(stakeAmount);
  await validatorRegistry.connect(validator2).stake(stakeAmount);
  await validatorRegistry.connect(validator3).stake(stakeAmount);
  
  console.log("Validators setup completed!");
  console.log("Validator 1:", validator1.address);
  console.log("Validator 2:", validator2.address);
  console.log("Validator 3:", validator3.address);
}

setupValidators()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
```

## Testing Framework

### 1. Comprehensive Test Suite

Create `test/OmniCoin.integration.test.js`:

```javascript
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("OmniCoin Integration Tests", function () {
  let deployer, user1, user2, user3;
  let omniCoin, validatorRegistry, feeDistribution;
  
  beforeEach(async function () {
    [deployer, user1, user2, user3] = await ethers.getSigners();
    
    // Deploy contracts (simplified for testing)
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoin.deploy(/* constructor params */);
    
    const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
    validatorRegistry = await ValidatorRegistry.deploy();
    
    const FeeDistribution = await ethers.getContractFactory("FeeDistribution");
    feeDistribution = await FeeDistribution.deploy();
    
    // Initial setup
    await omniCoin.mint(deployer.address, ethers.utils.parseEther("1000000"));
  });
  
  describe("Validator Network", function () {
    it("Should register validators and distribute rewards", async function () {
      // Register validator
      await validatorRegistry.connect(user1).registerValidator(
        "validator1",
        "QmHash1",
        { cpu: 8, memory: 16, storage: 500 }
      );
      
      // Stake tokens
      const stakeAmount = ethers.utils.parseEther("10000");
      await omniCoin.transfer(user1.address, stakeAmount);
      await omniCoin.connect(user1).approve(validatorRegistry.address, stakeAmount);
      await validatorRegistry.connect(user1).stake(stakeAmount);
      
      // Check validator status
      const validator = await validatorRegistry.validators(user1.address);
      expect(validator.isActive).to.be.true;
      expect(validator.stakedAmount).to.equal(stakeAmount);
    });
  });
  
  describe("Fee Distribution", function () {
    it("Should distribute fees correctly", async function () {
      // Setup fee distribution
      await feeDistribution.collectFees(
        omniCoin.address,
        ethers.utils.parseEther("1000"),
        0 // TRADING
      );
      
      // Distribute fees
      await feeDistribution.distributeFees();
      
      // Check distribution
      const distribution = await feeDistribution.getLatestDistribution();
      expect(distribution.totalAmount).to.equal(ethers.utils.parseEther("1000"));
    });
  });
  
  describe("Cross-Chain Operations", function () {
    it("Should handle bridge transfers", async function () {
      // Test bridge functionality
      const bridgeAmount = ethers.utils.parseEther("100");
      await omniCoin.transfer(user1.address, bridgeAmount);
      
      // Initiate bridge transfer
      await omniCoin.connect(user1).approve(bridge.address, bridgeAmount);
      await bridge.connect(user1).initiateTransfer(
        137, // Polygon chainId
        user1.address,
        bridgeAmount
      );
      
      // Verify bridge state
      const transfer = await bridge.getTransfer(1);
      expect(transfer.amount).to.equal(bridgeAmount);
    });
  });
});
```

### 2. Security Tests

Create `test/security/OmniCoin.security.test.js`:

```javascript
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoin Security Tests", function () {
  let omniCoin, attacker, user;
  
  beforeEach(async function () {
    [deployer, attacker, user] = await ethers.getSigners();
    
    // Deploy contracts
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoin.deploy(/* params */);
  });
  
  describe("Access Control", function () {
    it("Should prevent unauthorized minting", async function () {
      await expect(
        omniCoin.connect(attacker).mint(attacker.address, ethers.utils.parseEther("1000"))
      ).to.be.revertedWith("AccessControl: account");
    });
    
    it("Should prevent unauthorized pausing", async function () {
      await expect(
        omniCoin.connect(attacker).pause()
      ).to.be.revertedWith("AccessControl: account");
    });
  });
  
  describe("Reentrancy Protection", function () {
    it("Should prevent reentrancy attacks", async function () {
      // Deploy malicious contract
      const MaliciousContract = await ethers.getContractFactory("MaliciousContract");
      const malicious = await MaliciousContract.deploy(omniCoin.address);
      
      // Attempt reentrancy attack
      await expect(
        malicious.attack()
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });
  });
});
```

## Monitoring and Maintenance

### 1. Monitoring Setup

Create `scripts/monitoring.js`:

```javascript
const { ethers } = require("hardhat");
const deployments = require("../deployments/localhost.json");

async function setupMonitoring() {
  const omniCoin = await ethers.getContractAt("OmniCoin", deployments.omniCoin);
  const validatorRegistry = await ethers.getContractAt("ValidatorRegistry", deployments.validatorRegistry);
  
  // Monitor large transfers
  omniCoin.on("Transfer", (from, to, amount) => {
    const threshold = ethers.utils.parseEther("1000000"); // 1M tokens
    if (amount.gt(threshold)) {
      console.log(`Large transfer detected: ${ethers.utils.formatEther(amount)} tokens from ${from} to ${to}`);
    }
  });
  
  // Monitor validator events
  validatorRegistry.on("ValidatorSlashed", (validator, amount, reason) => {
    console.log(`Validator ${validator} slashed: ${ethers.utils.formatEther(amount)} tokens - ${reason}`);
  });
  
  // Monitor validator registration
  validatorRegistry.on("ValidatorRegistered", (validator, stake, nodeId) => {
    console.log(`New validator registered: ${validator} with ${ethers.utils.formatEther(stake)} tokens`);
  });
  
  console.log("Monitoring setup completed");
}

setupMonitoring();
```

### 2. Health Check Script

Create `scripts/health-check.js`:

```javascript
const { ethers } = require("hardhat");
const deployments = require("../deployments/localhost.json");

async function healthCheck() {
  try {
    // Check contract deployment
    const omniCoin = await ethers.getContractAt("OmniCoin", deployments.omniCoin);
    const totalSupply = await omniCoin.totalSupply();
    console.log(`✅ OmniCoin total supply: ${ethers.utils.formatEther(totalSupply)}`);
    
    // Check validator registry
    const validatorRegistry = await ethers.getContractAt("ValidatorRegistry", deployments.validatorRegistry);
    const activeValidators = await validatorRegistry.getActiveValidators();
    console.log(`✅ Active validators: ${activeValidators.length}`);
    
    // Check fee distribution
    const feeDistribution = await ethers.getContractAt("FeeDistribution", deployments.feeDistribution);
    const totalFees = await feeDistribution.getTotalCollectedFees();
    console.log(`✅ Total fees collected: ${ethers.utils.formatEther(totalFees)}`);
    
    console.log("✅ All systems operational");
  } catch (error) {
    console.error("❌ Health check failed:", error.message);
    process.exit(1);
  }
}

healthCheck();
```

## Testing Procedures

### 1. Unit Testing

```bash
# Run all tests
npm test

# Run specific test suites
npm run test:security
npm run test:integration

# Run with gas reporting
npm run test:gas

# Run with coverage
npm run coverage
```

### 2. Security Testing

```bash
# Static analysis
npm run security-check

# Linting
npm run lint

# Mythril analysis (if installed)
myth analyze contracts/OmniCoin.sol
```

### 3. Integration Testing

```bash
# Deploy to local network
npm run deploy:local

# Setup validators
npx hardhat run scripts/setup-validators.js --network localhost

# Run health check
npx hardhat run scripts/health-check.js --network localhost

# Start monitoring
npx hardhat run scripts/monitoring.js --network localhost
```

## Mainnet Deployment Checklist

### Pre-deployment
- [ ] All tests passing with >95% coverage
- [ ] Security audit completed and issues resolved
- [ ] Gas optimization completed
- [ ] Multi-signature wallet setup for admin functions
- [ ] Timelock contracts configured
- [ ] Emergency procedures documented

### Deployment
- [ ] Deploy to testnet first
- [ ] Verify contract source code
- [ ] Test all critical functions
- [ ] Setup monitoring and alerting
- [ ] Configure multi-signature permissions
- [ ] Transfer ownership to governance

### Post-deployment
- [ ] Monitor for 24 hours
- [ ] Community announcement
- [ ] Documentation updates
- [ ] Bug bounty program activation

## Troubleshooting

### Common Issues

1. **Deployment Fails**
   - Check gas limits and prices
   - Verify private key and network configuration
   - Ensure sufficient balance for deployment

2. **Tests Fail**
   - Check OpenZeppelin version compatibility
   - Verify contract compilation
   - Review test environment setup

3. **Gas Estimation Issues**
   - Increase gas limits in hardhat.config.js
   - Use via-IR compilation option
   - Optimize contract code

### Support Resources

- **Documentation**: [OmniCoin Docs](https://docs.omnicoin.io)
- **Community**: [Discord](https://discord.gg/omnicoin)
- **GitHub**: [Issues](https://github.com/omnicoin/issues)
- **Security**: [security@omnicoin.io](mailto:security@omnicoin.io)

## Conclusion

This implementation guide provides a comprehensive framework for building and deploying the OmniCoin testnet. The modular architecture allows for flexible deployment scenarios while maintaining security best practices. Follow the security audit plan alongside this implementation guide to ensure a robust and secure deployment.

Regular monitoring and maintenance are essential for long-term success. The provided scripts and procedures will help maintain system health and security post-deployment.