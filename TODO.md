# OmniCoin Smart Contract Development Plan

**Last Updated:** 2025-07-26 19:05 UTC

## Overview

OmniCoin is being deployed on the COTI V2 platform with a dual-token architecture that provides both public and private transaction capabilities. This implementation leverages COTI V2's privacy features while maintaining public operations as the default for performance.

This document outlines the development plan, testing strategy, and implementation details.

## 🚨 CRITICAL UPDATE: Dual-Token Architecture (2025-07-26)

### Implemented Architecture
Based on session work, we've implemented a clean dual-token system:

1. **OmniCoin (XOM)** - Standard ERC20 for public transactions
   - No encryption overhead
   - Fast transactions (1000+ TPS)
   - Default for all operations
   - No privacy fees

2. **PrivateOmniCoin (pXOM)** - COTI PrivateERC20 for private transactions  
   - Fully encrypted operations
   - Limited supply (minted via bridge only)
   - 40 TPS on COTI V2
   - Premium feature

3. **OmniCoinPrivacyBridge** - Converts between public/private tokens
   - 1-2% conversion fee (per user requirements)
   - One-way or bidirectional based on configuration
   - Maintains total supply integrity
   - Privacy is opt-in, not forced

## 🔥 IMMEDIATE PRIORITIES (2025-07-26 Session)

### Compilation Fixes Required
1. **OmniCoinArbitration.sol** - MpcCore.div compilation error
   - Import statements were corrupted by VS Code
   - Fixed imports but still has compilation issues
   - Need to verify MpcCore library usage

### Testing Implementation
1. Write comprehensive tests for dual-token architecture
2. Test privacy bridge functionality
3. Ensure proper integration between all contracts
4. Validate on COTI testnet

### Contract Status Summary

#### ✅ Fixed (Solhint Errors Resolved)
- OmniCoinStaking.sol - Variable naming fixed
- DEXSettlement.sol - Variable naming fixed
- OmniCoinArbitration.sol - Variable naming fixed (but has compilation error)
- OmniCoinBridge.sol - Variable naming fixed + assembly annotation
- OmniCoinAccount.sol - Changed to use standard ERC20 methods
- OmniNFTMarketplace.sol - Variable naming fixed

#### 🔧 Needs Compilation Fix
- OmniCoinArbitration.sol - MpcCore.div error

#### 📝 Needs Testing
- All contracts need comprehensive test coverage
- Focus on dual-token architecture tests
- Privacy bridge functionality tests

## Technical Architecture

### Core Components

1. **Token Contracts**
   - `OmniCoin.sol` - Public ERC20 token
   - `PrivateOmniCoin.sol` - Private COTI PrivateERC20 token
   - `OmniCoinPrivacyBridge.sol` - Bridge between public/private

2. **Supporting Contracts**
   - `OmniCoinStaking.sol` - Staking with both token types
   - `OmniCoinEscrow.sol` - Escrow supporting both tokens
   - `OmniCoinPayment.sol` - Payments with privacy option
   - `DEXSettlement.sol` - DEX with privacy options

3. **Infrastructure**
   - `OmniCoinRegistry.sol` - Central registry for contracts
   - `PrivacyFeeManager.sol` - Manages privacy conversion fees
   - `ValidatorRegistry.sol` - Validator management

### Privacy Implementation Pattern

All contracts follow this pattern:
```solidity
function doSomethingWithPrivacy(params, bool usePrivacy) {
    if (usePrivacy && isMpcAvailable) {
        // User explicitly chose privacy
        // Collect privacy fee
        // Use private token operations
    } else {
        // Standard public operation (default)
        // Use public token
    }
}
```

## Development Environment Setup

### VS Code Configuration ✅
- Hardhat extension enabled
- Solidity by Juan Blanco installed
- Solhint configured (.solhint.json)
- Settings configured (.vscode/settings.json)

### Build Tools
- Hardhat for compilation and testing
- Solhint for linting
- OpenZeppelin contracts for base functionality
- COTI SDK for privacy features

## Testing Strategy

### Unit Tests
- Test each contract in isolation
- Focus on dual-token functionality
- Verify privacy fee calculations
- Test access controls

### Integration Tests  
- Test token bridge operations
- Verify cross-contract interactions
- Test privacy feature integration
- Validate fee distributions

### Testnet Deployment
- Deploy to COTI testnet first
- Validate privacy features work correctly
- Test gas costs and performance
- Verify dual-token architecture

## Deployment Plan

### Phase 1: Fix Compilation Issues
1. Fix OmniCoinArbitration.sol MpcCore.div error
2. Compile all contracts individually
3. Document any remaining issues

### Phase 2: Comprehensive Testing
1. Write unit tests for dual-token system
2. Test privacy bridge thoroughly
3. Integration tests for all contracts
4. Fix any failing tests

### Phase 3: Testnet Deployment
1. Deploy core token contracts
2. Deploy privacy bridge
3. Deploy supporting contracts
4. Verify all integrations

### Phase 4: Production Readiness
1. Security audit
2. Gas optimization
3. Documentation updates
4. Mainnet deployment

## Current Task List

### High Priority
- [ ] Fix OmniCoinArbitration.sol compilation error
- [ ] Compile each contract individually
- [ ] Write tests for dual-token architecture
- [ ] Test privacy bridge functionality

### Medium Priority
- [ ] Fix any stubbed/mocked functions
- [ ] Optimize gas usage
- [ ] Complete integration tests
- [ ] Deploy to testnet

### Low Priority
- [ ] Fix remaining solhint warnings
- [ ] Update documentation
- [ ] Create deployment scripts
- [ ] Plan mainnet deployment

## Notes

- Privacy is always opt-in, never forced
- Public operations are the default for performance
- Bridge fee is 1-2% for privacy conversion
- All contracts must support both token types
- Maintain backwards compatibility where possible