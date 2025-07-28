# OmniCoin Test Suite Guide

## Overview

This comprehensive test suite covers all OmniCoin contracts including the new ERC-1155 support. Tests are organized by functionality and can be run individually or as a complete suite.

## Test Categories

### 1. Core Contracts
- `OmniCoin.test.js` - Basic token functionality
- `OmniCoinRegistry.test.js` - Contract registry and discovery
- `DualTokenArchitecture.test.js` - Public/private token integration
- `DualTokenIntegration.test.js` - Cross-contract token flows

### 2. ERC-1155 Support (NEW)
- `OmniERC1155.test.js` - Multi-token standard implementation
- `OmniUnifiedMarketplace.test.js` - Unified NFT marketplace for ERC-721/1155
- `OmniERC1155Bridge.test.js` - Import/export bridge for external tokens

### 3. Business Logic
- `OmniCoinEscrowV2.business-logic.test.js` - Escrow operations
- `OmniCoinPaymentV2.business-logic.test.js` - Payment processing
- `OmniCoinStakingV2.test.js` - Staking mechanisms
- `OmniCoinArbitration.test.js` - Dispute resolution

### 4. Privacy Features
- Tests for privacy-enabled operations
- MPC integration (COTI-specific)
- Privacy fee verification

### 5. Security & Integration
- Security vulnerability tests
- Cross-contract integration tests

## Running Tests

### Prerequisites
```bash
npm install
npx hardhat compile
```

### Run All Tests
```bash
node test/runAllTests.js
```

### Run Category Tests
```bash
# Core contracts only
npx hardhat test test/OmniCoin*.test.js

# ERC-1155 tests only
npx hardhat test test/OmniERC1155*.test.js

# Privacy tests
node test/privacy/runAllPrivacyTests.js
```

### Run Individual Test
```bash
npx hardhat test test/OmniERC1155.test.js
```

### Run with Coverage
```bash
npx hardhat coverage
```

## Test Environment Setup

### 1. Local Hardhat Network
Default for most tests. Privacy/MPC features will be mocked.

```bash
npx hardhat node
```

### 2. COTI Testnet
Required for full privacy functionality testing.

Create `.env` file:
```
COTI_TESTNET_RPC=https://testnet.coti.io
PRIVATE_KEY=your_private_key
MPC_ENABLED=true
```

## Writing New Tests

### Test Structure Template
```javascript
describe("ContractName", function () {
    let contract, owner, user1, user2;
    
    beforeEach(async function () {
        // Setup code
    });
    
    describe("Feature Category", function () {
        it("Should perform specific action", async function () {
            // Test implementation
        });
    });
});
```

### Key Testing Patterns

#### 1. Dual-Token Testing
```javascript
// Test both public and private token paths
for (const usePrivacy of [false, true]) {
    it(`Should handle transfers (privacy: ${usePrivacy})`, async function () {
        // Test logic
    });
}
```

#### 2. Registry Integration
```javascript
// Always use registry for contract discovery
const tokenAddress = usePrivacy ? 
    await registry.getContract(registry.PRIVATE_OMNICOIN()) :
    await registry.getContract(registry.OMNICOIN());
```

#### 3. ERC-1155 Testing
```javascript
// Test different token types
const TokenType = {
    FUNGIBLE: 0,
    NON_FUNGIBLE: 1,
    SEMI_FUNGIBLE: 2,
    SERVICE: 3
};
```

## Common Issues & Solutions

### 1. "MPC not available"
- **Issue**: Privacy tests failing in Hardhat
- **Solution**: Expected behavior. Run on COTI testnet for full testing

### 2. "Contract not found in registry"
- **Issue**: Registry not properly initialized
- **Solution**: Ensure all contracts are registered in beforeEach

### 3. "Insufficient balance"
- **Issue**: Test accounts not funded
- **Solution**: Fund test accounts in beforeEach

### 4. Gas Estimation Errors
- **Issue**: Complex operations failing
- **Solution**: Increase gas limit in hardhat.config.js

## Test Coverage Goals

### Minimum Coverage Requirements
- Unit Tests: 90% line coverage
- Integration Tests: Key user flows
- Edge Cases: All identified scenarios

### Priority Areas
1. Token transfers (public/private)
2. Registry operations
3. ERC-1155 minting and transfers
4. Marketplace transactions
5. Bridge imports/exports
6. Fee calculations
7. Access control

## Debugging Tests

### Enable Detailed Logging
```javascript
const { ethers } = require("hardhat");
ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.DEBUG);
```

### Gas Usage Analysis
```javascript
const tx = await contract.someMethod();
const receipt = await tx.wait();
console.log("Gas used:", receipt.gasUsed.toString());
```

### Event Verification
```javascript
await expect(contract.someMethod())
    .to.emit(contract, "EventName")
    .withArgs(arg1, arg2, arg3);
```

## Continuous Integration

### GitHub Actions Configuration
```yaml
name: Test Suite
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: actions/setup-node@v2
      - run: npm install
      - run: npx hardhat compile
      - run: node test/runAllTests.js
```

## Performance Benchmarks

### Expected Test Duration
- Unit Tests: < 30 seconds
- Integration Tests: < 2 minutes
- Full Suite: < 5 minutes

### Optimization Tips
1. Use `beforeEach` efficiently
2. Batch similar tests
3. Minimize contract deployments
4. Use test fixtures

## Next Steps

1. **Complete Test Coverage**
   - Add missing unit tests
   - Expand integration scenarios
   - Add stress tests

2. **COTI Testnet Testing**
   - Deploy contracts to testnet
   - Run privacy tests with real MPC
   - Verify gas costs

3. **Security Audit Preparation**
   - Document all test scenarios
   - Create attack vector tests
   - Prepare for external audit