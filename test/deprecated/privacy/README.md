# OmniCoin Privacy Test Suite

This directory contains comprehensive tests for the privacy functionality of OmniCoin contracts.

## Overview

OmniCoin implements a dual-mode system where users can choose between:
- **Public operations** (default): No privacy, no extra fees
- **Private operations** (optional): Enhanced privacy using COTI MPC, 10x fees

## Test Structure

### Core Contract Tests
- `OmniCoinCore.privacy.test.js` - Token transfer privacy functions
- `OmniCoinEscrow.privacy.test.js` - Private escrow operations
- `OmniCoinPayment.privacy.test.js` - Private payment processing
- `OmniCoinStaking.privacy.test.js` - Private staking functionality
- `OmniCoinArbitration.privacy.test.js` - Private dispute resolution
- `OmniCoinBridge.privacy.test.js` - Private cross-chain transfers
- `DEXSettlement.privacy.test.js` - Private DEX trading
- `OmniNFTMarketplace.privacy.test.js` - Private NFT transactions

### Test Categories

Each test file covers:

1. **Public Operations (No Privacy)**
   - Standard operations without privacy fees
   - Default behavior verification
   - Gas efficiency checks

2. **Private Operations (With Privacy)**
   - Privacy preference requirements
   - Privacy fee collection (10x multiplier)
   - MPC integration tests (COTI-specific)

3. **Edge Cases and Security**
   - Zero amount handling
   - Pause functionality
   - Permission checks
   - Re-entrancy protection

## Running Tests

### Individual Test
```bash
npx hardhat test test/privacy/OmniCoinCore.privacy.test.js
```

### All Privacy Tests
```bash
node test/privacy/runAllPrivacyTests.js
```

## Environment Considerations

### Hardhat (Local Testing)
- MPC functionality is **not available**
- Privacy tests that require MPC will be **skipped**
- Tests verify contract logic and fee structures

### COTI Testnet/Mainnet
- Full MPC functionality available
- All privacy tests can run
- Actual encrypted computations occur

## Key Testing Patterns

### 1. Privacy Preference Check
```javascript
// User must enable privacy preference first
await omniCoin.connect(user).setPrivacyPreference(true);
```

### 2. Privacy Fee Verification
```javascript
// Privacy operations cost 10x base fee
const baseFee = ethers.parseUnits("0.1", 6);
const expectedPrivacyFee = baseFee * 10n;
```

### 3. MPC Availability
```javascript
// Admin sets MPC availability on COTI deployment
await contract.setMpcAvailability(true);
```

### 4. Dual Function Pattern
```javascript
// Public function (no fees)
await contract.transfer(to, amount);

// Private function (with fees)
await contract.transferWithPrivacy(to, amount, true);
```

## Test Data

### Standard Test Amounts
- Small: 100 OMNI
- Medium: 1,000 OMNI  
- Large: 10,000 OMNI

### Time Periods
- Lock period: 86400 seconds (1 day)
- Deadline: current + 86400
- Reward period: 30 days

### Fee Structure
- Base fee: Variable per operation
- Privacy multiplier: 10x
- Distribution: 70% validators, 20% company, 10% development

## Debugging Failed Tests

1. **"MPC not available"**
   - Expected in Hardhat environment
   - Deploy to COTI testnet for full testing

2. **"Enable privacy preference first"**
   - User must call `setPrivacyPreference(true)`
   - Check user has enabled privacy mode

3. **"Insufficient balance for privacy fee"**
   - Privacy operations require 10x fees
   - Ensure user has enough tokens

## Future Enhancements

1. **Gas Usage Comparison**
   - Measure gas difference between public/private operations
   - Optimize privacy functions

2. **Performance Testing**
   - Batch operation tests
   - Stress testing with many users

3. **Integration Tests**
   - Cross-contract privacy flows
   - End-to-end user scenarios

## Contributing

When adding new privacy tests:

1. Follow the existing test structure
2. Test both public and private paths
3. Include edge cases
4. Document COTI-specific requirements
5. Update this README

## Security Considerations

- Privacy fees prevent spam attacks
- MPC ensures computation privacy
- Validator consensus adds security layer
- Regular audits recommended