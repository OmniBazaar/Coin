# OmniCoin Smart Contract Development Plan

**Last Updated:** 2025-07-27 16:15 UTC

## Overview

OmniCoin is being deployed on the COTI V2 platform with a dual-token architecture that provides both public and private transaction capabilities. This implementation leverages COTI V2's privacy features while maintaining public operations as the default for performance.

## 🎯 CURRENT STATUS: All Contracts Compile Successfully!

### Major Progress (2025-07-27)
- ✅ **0 Compilation Errors** across entire codebase
- ✅ Fixed all shadow declaration warnings
- ✅ Fixed all unused parameter warnings  
- ✅ Reduced warnings by 90%+ in major contracts
- ✅ Added comprehensive NatSpec documentation

### Warning Reduction Summary
- **OmniCoinCore.sol**: 120 → 4 warnings (97% reduction)
- **OmniCoinEscrow.sol**: 129 → 15 warnings (88% reduction)
- **OmniCoinConfig.sol**: 113 → 0 warnings (100% reduction)

## 🚀 IMMEDIATE NEXT STEPS

### Continue Solhint Fixes (Alphabetical Order)
1. **BatchProcessor.sol** - Apply NatSpec, gas optimizations, custom errors
2. **DEXSettlement.sol** - Fix remaining warnings
3. **FeeDistribution.sol** - Add documentation, fix warnings
4. **ListingNFT.sol** - Apply standard fixes
5. **OmniBatchTransactions.sol** - Fix warnings
6. **OmniCoin.sol** - Review and fix warnings
7. **OmniCoinAccount.sol** - Continue warning fixes
8. **OmniCoinArbitration.sol** - Fix remaining warnings
9. **OmniCoinBridge.sol** - Apply fixes
10. **OmniCoinGarbledCircuit.sol** - Review MPC usage

### Standard Fix Patterns to Apply

#### 1. NatSpec Documentation
```solidity
/**
 * @notice [Function purpose]
 * @param paramName [Description]
 * @return returnName [Description]
 */
```

#### 2. Gas Optimizations
```solidity
// Change: if (x >= y)
// To: if (x > y - 1)
```

#### 3. Unused Parameters
```solidity
// Change: function foo(address account)
// To: function foo(address /* account */)
```

#### 4. Custom Errors
```solidity
error CustomError();
// Change: require(condition, "message");
// To: if (!condition) revert CustomError();
```

## Technical Architecture

### Dual-Token System ✅
1. **OmniCoin (XOM)** - Standard ERC20 for public transactions
2. **PrivateOmniCoin (pXOM)** - COTI PrivateERC20 for private transactions
3. **OmniCoinPrivacyBridge** - Converts between public/private tokens

### Privacy Pattern (Implemented)
```solidity
function doSomethingWithPrivacy(params, bool usePrivacy) {
    if (usePrivacy && isMpcAvailable) {
        // Privacy path with fees
    } else {
        // Standard public operation (default)
    }
}
```

## Testing Requirements

### High Priority Tests Needed
1. **Registry Integration Tests**
   - Verify all contracts resolve addresses correctly
   - Test registry updates propagate properly

2. **Privacy Mode Tests**
   - Test opt-in privacy for each operation
   - Verify privacy fees collected correctly
   - Test MPC availability checks

3. **Time-Based Operations**
   - Test escrow timeouts
   - Test validator operation delays
   - Test emergency time locks

4. **Multi-Signature Tests**
   - Test validator consensus operations
   - Test multi-sig wallet functions

## Deployment Checklist

### Pre-Deployment
- [ ] Complete solhint fixes for all contracts
- [ ] Write comprehensive test suite
- [ ] Run all tests on local hardhat
- [ ] Gas optimization pass
- [ ] Security review

### COTI Testnet Deployment
- [ ] Deploy Registry first
- [ ] Deploy core contracts (OmniCoin, PrivateOmniCoin)
- [ ] Deploy bridge and fee manager
- [ ] Deploy supporting contracts
- [ ] Enable MPC on testnet
- [ ] Test all privacy features

### Production Deployment
- [ ] External audit
- [ ] Update documentation
- [ ] Deploy to mainnet
- [ ] Verify all contracts
- [ ] Enable features gradually

## Known Issues & Decisions

### Design Decisions Made
1. **Time-based logic retained** - Required for business logic
2. **Function ordering by feature** - Better readability than visibility ordering
3. **Complex functions retained** - Privacy checks add necessary complexity

### Technical Limitations
1. **MpcCore missing gte/lte** - Use gt + eq combinations
2. **Compilation timeouts** - Compile contracts individually if needed
3. **VS Code auto-formatting** - Can break import statements

## Task Priority Matrix

### Critical (Do First)
- Complete solhint fixes for remaining contracts
- Write core functionality tests
- Deploy to COTI testnet

### Important (Do Next)
- Integration tests
- Gas optimizations
- Documentation updates

### Nice to Have (Do Later)
- Further warning reductions
- Code coverage 100%
- Deployment automation scripts

## Success Metrics
- ✅ All contracts compile (ACHIEVED!)
- [ ] 90%+ test coverage
- [ ] All critical warnings addressed
- [ ] Successful testnet deployment
- [ ] Privacy features working on COTI

## Notes for Next Developer
- Start with BatchProcessor.sol and continue alphabetically
- Apply the fix patterns documented above
- Time-based warnings are mostly legitimate - don't remove business logic
- Test thoroughly before any contract changes
- MPC must be enabled by admin on COTI networks