# OmniCoin Smart Contract Development Plan

**Last Updated:** 2025-07-28 15:49 UTC

## Overview

OmniCoin is being deployed on the COTI V2 platform with a dual-token architecture that provides both public and private transaction capabilities. This implementation leverages COTI V2's privacy features while maintaining public operations as the default for performance.

## 🎯 CURRENT STATUS: Test Mocking Removed, Compilation Fixed!

### Major Progress Update (2025-07-28 Afternoon)
- ✅ **ALL Mock Contracts Removed from Tests** - 23 test files updated
- ✅ **Compilation Errors Fixed** - Contracts now compile successfully
- ✅ **Registry Pattern Fully Implemented** - All tests use real contracts
- ✅ **New Test Files Created** - ValidatorSync and OmniNFTMarketplace
- 🔄 **324 Solhint Warnings Remaining** - Style and documentation issues

### Architecture Implementation Summary
- **Public Token**: OmniCoin.sol (XOM) - Standard ERC20
- **Private Token**: PrivateOmniCoin.sol (pXOM) - COTI PrivateERC20
- **Registry**: OmniCoinRegistry.sol - Central contract discovery
- **Bridge**: OmniCoinPrivacyBridge.sol - XOM ↔ pXOM conversion
- **Multi-Token NFT**: OmniERC1155.sol - Fungible/Non-fungible support
- **Unified Marketplace**: OmniUnifiedMarketplace.sol - ERC-721 & ERC-1155

## 🚀 IMMEDIATE NEXT STEPS

### 1. Fix Remaining Solhint Warnings (Priority: Critical)
- [ ] **NatSpec Documentation** (~100 warnings)
  - [ ] Add @notice tags to all contracts
  - [ ] Add @param tags to all functions
  - [ ] Add @return tags where needed
  - [ ] Add @dev tags for complex logic

- [ ] **Code Quality Issues** (~150 warnings)
  - [ ] Fix function ordering violations
  - [ ] Address line length issues (>120 chars)
  - [ ] Comment out unused parameters
  - [ ] Fix variable shadowing

- [ ] **Gas Optimizations** (~50 warnings)
  - [ ] Use ++i instead of i++
  - [ ] Use custom errors instead of require
  - [ ] Optimize string lengths
  - [ ] Pack structs efficiently

- [ ] **Time-Based Logic** (~24 warnings)
  - [ ] Review each not-rely-on-time warning
  - [ ] Add solhint-disable-line where business logic requires
  - [ ] Document why time is needed

### 2. Run Full Test Suite (Priority: Critical) 
- [x] **Test Environment Setup** ✅
  - [x] All tests use actual contracts
  - [x] OmniCoinRegistry pattern established
  - [x] StandardERC20Test for PrivateOmniCoin
  - [x] Ethers.js v6 syntax updated

- [ ] **Execute Tests**
  - [ ] Run `npm test` after warnings fixed
  - [ ] Document any failures
  - [ ] Debug failing tests
  - [ ] Ensure 100% pass rate

- [ ] **Test Coverage Analysis**
  - [ ] Run coverage report
  - [ ] Identify gaps
  - [ ] Add missing tests
  - [ ] Achieve 90%+ coverage

### 3. Prepare for Testnet Deployment (Priority: High)
- [ ] **Pre-Deployment Checklist**
  - [ ] All tests passing
  - [ ] All warnings resolved
  - [ ] Gas optimization complete
  - [ ] Security review done

- [ ] **Deployment Scripts**
  - [ ] Create deployment order script
  - [ ] Set up registry initialization
  - [ ] Configure contract permissions
  - [ ] Test deployment locally

### 4. Complete Remaining Features (Priority: Medium)
- [ ] **OmniNFTMarketplace Enhancement**
  - [ ] Add batch listing support
  - [ ] Implement royalty distribution
  - [ ] Add collection offers
  - [ ] Test with ERC-1155 tokens

- [ ] **ValidatorSync Enhancement**
  - [ ] Add slashing conditions
  - [ ] Implement reward distribution
  - [ ] Add performance metrics
  - [ ] Test consensus mechanisms

## Test Suite Status

### Tests Updated (Mock Removal Complete) ✅
1. All core contract tests (23 files)
2. Reputation system tests (3 files)
3. Security tests (2 files)
4. New comprehensive tests (2 files)

### Test Patterns Established
- Deploy OmniCoinRegistry first
- Deploy contracts with registry reference
- Set up registry mappings
- Use StandardERC20Test for privacy token testing
- All Ethers.js v6 syntax

## Technical Decisions Made

### Today's Session
1. **No More Mocking** - All tests use real contracts for deployment readiness
2. **Registry-First Pattern** - Every test deploys and configures registry
3. **StandardERC20Test Usage** - Consistent stand-in for PrivateOmniCoin
4. **Function State Fixes** - Properly handle _getContract state modifications

### Previous Decisions
1. **6 Decimal Places** - Standardized across all tokens
2. **Dual-Token Default** - Users choose privacy level
3. **Backward Compatibility** - Helper functions for legacy code

### 4. Complete OmniNFTMarketplace (Priority: High)
- [ ] Finish dual-token payment integration
- [ ] Implement payment splitting for multiple tokens
- [ ] Add auction support for both XOM and pXOM
- [ ] Test all marketplace functions

### 5. Post-Deployment Test Regimen (Priority: High)
- [ ] **Testnet Monitoring Scripts**
  - [ ] Transaction volume tracking
  - [ ] Gas usage analysis
  - [ ] Privacy feature usage metrics
  - [ ] Contract interaction patterns

- [ ] **Admin Tools**
  - [ ] Registry management interface
  - [ ] Emergency pause controls
  - [ ] Fee adjustment mechanisms
  - [ ] MPC availability toggles

- [ ] **User Testing Procedures**
  - [ ] Wallet integration tests
  - [ ] Cross-contract operation tests
  - [ ] Privacy feature validation
  - [ ] Performance benchmarks

## Technical Architecture

### Dual-Token System ✅ IMPLEMENTED
1. **OmniCoin (XOM)** - Standard ERC20 for public transactions
2. **PrivateOmniCoin (pXOM)** - COTI PrivateERC20 for private transactions
3. **OmniCoinPrivacyBridge** - Converts between public/private tokens

### Registry Pattern ✅ IMPLEMENTED
```solidity
// All contracts now use:
contract Example is RegistryAware {
    function getToken(bool usePrivacy) internal view returns (address) {
        return usePrivacy ? 
            _getContract(registry.PRIVATE_OMNICOIN()) : 
            _getContract(registry.OMNICOIN());
    }
}
```

## Testing Requirements

### Critical Test Coverage Needed
1. **Registry Tests**
   - Contract registration and updates
   - Emergency fallback mechanisms
   - Version management
   - Access control

2. **Dual-Token Tests**
   - Token selection logic
   - Privacy mode operations
   - Fee collection in both tokens
   - Balance tracking

3. **Integration Tests**
   - Cross-contract calls
   - Multi-signature operations
   - Time-based functions
   - Emergency procedures

4. **Gas Optimization Tests**
   - Transaction cost analysis
   - Batch operation efficiency
   - Storage optimization verification

## Deployment Checklist

### Pre-Deployment
- [x] Implement dual-token architecture
- [x] Integrate registry pattern
- [ ] Write comprehensive test suite
- [ ] Run all tests on local hardhat
- [ ] Gas optimization pass
- [ ] Security review

### COTI Testnet Deployment
- [ ] Deploy OmniCoinRegistry first
- [ ] Deploy token contracts (OmniCoin, PrivateOmniCoin)
- [ ] Deploy OmniCoinPrivacyBridge
- [ ] Deploy all supporting contracts
- [ ] Register all contracts in registry
- [ ] Initialize cross-contract permissions
- [ ] Enable MPC on testnet
- [ ] Run integration test suite

### Production Deployment
- [ ] External security audit
- [ ] Update all documentation
- [ ] Deploy contracts in correct order
- [ ] Verify all contracts on explorer
- [ ] Initialize with production parameters
- [ ] Enable features gradually
- [ ] Monitor initial transactions

## Contract Deployment Order
1. OmniCoinRegistry
2. OmniCoin
3. PrivateOmniCoin
4. OmniCoinConfig
5. OmniCoinPrivacyBridge
6. OmniCoinStaking
7. OmniCoinValidator
8. OmniCoinEscrow
9. OmniCoinPayment
10. [Other contracts...]

## Known Issues & Next Priorities

### To Be Completed
1. **OmniNFTMarketplace** - Finish dual-token payment functions
2. **ERC-1155 Support** - Multi-token standard for NFTs
3. **Test Coverage** - No tests written for new architecture
4. **Gas Optimization** - Needs analysis after testing

### Technical Decisions Made
1. **6 Decimal Places** - Standardized across all tokens
2. **Registry Pattern** - Dynamic contract discovery
3. **Dual-Token Default** - Users choose privacy level
4. **Backward Compatibility** - Helper functions for legacy code

## Success Metrics
- ✅ All contracts compile
- ✅ Dual-token architecture implemented
- ✅ Registry pattern integrated
- [ ] 90%+ test coverage
- [ ] Successful testnet deployment
- [ ] Gas costs optimized
- [ ] Security audit passed

## Notes for Next Developer
- Start with ERC-1155 implementation for NFT marketplace
- Write tests as you go - don't defer testing
- Use existing test patterns from coti-contracts where applicable
- Ensure all privacy features are properly tested
- Document any new patterns or architectural decisions
- Keep CURRENT_STATUS.md updated with progress