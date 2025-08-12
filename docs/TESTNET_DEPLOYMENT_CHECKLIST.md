# COTI V2 Testnet Deployment Checklist

## Pre-Deployment Verification

### Code Review
- [ ] All contracts compile without errors or warnings
- [ ] Dual-token architecture is properly implemented
  - [ ] OmniCoin.sol - Standard ERC20 for public transactions
  - [ ] PrivateOmniCoin.sol - COTI PrivateERC20 for private transactions
  - [ ] OmniCoinPrivacyBridge.sol - Bridge between tokens
- [ ] PrivacyFeeManager correctly handles both token types
- [ ] All tests pass (100% pass rate)
- [ ] Security audit completed (if applicable)

### COTI V2 Compatibility
- [ ] Contracts use Solidity 0.8.19 (COTI requirement)
- [ ] All private operations use COTI's MPC types (gtUint64, ctUint64)
- [ ] Decimals set to 6 for COTI compatibility
- [ ] No incompatible features or opcodes

### Documentation
- [ ] Contract documentation is complete
- [ ] Deployment instructions are clear
- [ ] Integration guide for wallet/UI is ready

## Deployment Preparation

### Accounts & Keys
- [ ] Create deployment account on COTI V2 testnet
- [ ] Fund account with test COTI tokens
- [ ] Secure private keys
- [ ] Set up multisig for admin roles (optional for testnet)

### Configuration
- [ ] Update .env with testnet RPC URL
- [ ] Set appropriate gas limits
- [ ] Configure deployment parameters:
  - [ ] Initial supply: 100M XOM
  - [ ] Bridge fee: 1% (100 basis points)
  - [ ] Treasury address
  - [ ] Admin addresses

### Deployment Scripts
- [ ] `deploy-registry.js` - Deploy registry first
- [ ] `deploy-dual-token.js` - Deploy token system
- [ ] `deploy-defi-contracts.js` - Deploy DeFi components
- [ ] `configure-permissions.js` - Set up roles

## Deployment Process

### Phase 1: Core Infrastructure
1. [ ] Deploy OmniCoinRegistry
2. [ ] Verify registry deployment
3. [ ] Record registry address

### Phase 2: Token Contracts
1. [ ] Deploy OmniCoin (XOM)
   - [ ] Verify initial supply minted
   - [ ] Verify decimals = 6
2. [ ] Deploy PrivateOmniCoin (pXOM)
   - [ ] Verify MPC mode disabled for testing
   - [ ] Verify decimals = 6
3. [ ] Deploy PrivacyFeeManager
   - [ ] Verify treasury address set
   - [ ] Verify fee structure initialized
4. [ ] Deploy OmniCoinPrivacyBridge
   - [ ] Verify bridge fee = 1%
   - [ ] Verify connections to both tokens

### Phase 3: Registry Configuration
1. [ ] Register all contracts in registry:
   - [ ] OMNICOIN → OmniCoin address
   - [ ] PRIVATE_OMNICOIN → PrivateOmniCoin address
   - [ ] OMNICOIN_BRIDGE → Bridge address
   - [ ] FEE_MANAGER → FeeManager address
2. [ ] Verify registry queries work correctly

### Phase 4: Permissions Setup
1. [ ] Grant roles on PrivateOmniCoin:
   - [ ] BRIDGE_ROLE → Bridge contract
   - [ ] PAUSER_ROLE → Admin account
2. [ ] Grant roles on OmniCoin:
   - [ ] BRIDGE_ROLE → Bridge contract
   - [ ] MINTER_ROLE → Appropriate contracts
   - [ ] PAUSER_ROLE → Admin account
3. [ ] Grant roles on FeeManager:
   - [ ] FEE_MANAGER_ROLE → Bridge and DeFi contracts
4. [ ] Verify all role assignments

### Phase 5: DeFi Contracts (Optional for initial test)
1. [ ] Deploy supporting contracts:
   - [ ] OmniCoinEscrowV2
   - [ ] OmniCoinPaymentV2
   - [ ] OmniCoinStakingV2
   - [ ] DEXSettlement
2. [ ] Register in registry
3. [ ] Configure permissions

## Post-Deployment Testing

### Basic Functionality
1. [ ] Test public token transfers (XOM)
2. [ ] Test bridge conversion: XOM → pXOM
   - [ ] Verify 1% fee deducted
   - [ ] Verify pXOM minted
3. [ ] Test bridge conversion: pXOM → XOM
   - [ ] Verify no fee
   - [ ] Verify XOM returned
4. [ ] Test fee collection and treasury

### Privacy Features
1. [ ] Enable MPC mode if available
2. [ ] Test encrypted transfers
3. [ ] Verify privacy guarantees

### Integration Testing
1. [ ] Test with OmniWallet interface
2. [ ] Test marketplace integration
3. [ ] Test DEX functionality

## Monitoring & Maintenance

### Setup Monitoring
- [ ] Deploy monitoring contracts
- [ ] Set up event listeners
- [ ] Configure alerts for:
  - [ ] Large transfers
  - [ ] Bridge usage
  - [ ] Error events

### Documentation Updates
- [ ] Record all deployed addresses
- [ ] Update integration documentation
- [ ] Create user guides

## Rollback Plan

### Emergency Procedures
- [ ] Document pause procedures
- [ ] Test emergency pause functionality
- [ ] Prepare rollback scripts
- [ ] Document recovery procedures

### Contact Information
- [ ] COTI support channels
- [ ] Team emergency contacts
- [ ] External audit contacts

## Sign-off

- [ ] Technical Lead approval
- [ ] Security review complete
- [ ] Documentation complete
- [ ] Deployment authorized

**Deployment Date**: _________________
**Deployed By**: _________________
**Version**: 1.0.0-testnet