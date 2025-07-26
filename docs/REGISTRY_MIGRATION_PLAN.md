# Registry Migration Plan

**Date:** 2025-07-26 08:45 UTC  
**Status:** PROPOSED

## Overview

Transition from Factory pattern to Registry pattern for OmniCoin deployment and management.

## Current State

### Factory Pattern (To Be Deprecated):
- OmniCoinFactory deploys all contracts at once
- Rigid deployment structure
- Difficult to upgrade individual contracts
- Tightly coupled components

### Registry Pattern (New Approach):
- OmniCoinRegistry as central address book
- RegistryAware base contract for integration
- Dynamic address lookup
- Easy individual contract upgrades

## Migration Steps

### Phase 1: Update Existing Contracts

1. **Add Registry Integration to Core Contracts**:
   ```solidity
   contract OmniCoinCore is RegistryAware {
       constructor(address _registry) RegistryAware(_registry) {
           // existing constructor logic
       }
   }
   ```

2. **Replace Hard-coded Addresses**:
   - Change from: `address public escrowContract;`
   - Change to: `address escrow = _getContract(ESCROW);`

3. **Contracts to Update**:
   - OmniCoinCore
   - OmniCoinEscrowV2
   - OmniCoinPaymentV2
   - OmniCoinStakingV2
   - OmniCoinArbitration
   - OmniCoinBridge
   - DEXSettlement
   - OmniNFTMarketplace
   - All other active contracts

### Phase 2: Convert Factories to Deployment Scripts

1. **Create Deployment Helpers**:
   ```solidity
   contract OmniCoinDeploymentHelper {
       function deployCoreContracts(address registry) external returns (
           address core,
           address config,
           address reputation
       ) {
           // Deploy contracts individually
           // Register each in the registry
       }
   }
   ```

2. **Benefits**:
   - Still have convenient deployment
   - But contracts aren't tightly coupled
   - Can deploy/upgrade individually

### Phase 3: Update Constructor Parameters

Since all contracts will need the registry address, update constructors:

```solidity
// Before
constructor(
    address _token,
    address _escrow,
    address _staking,
    address _admin
)

// After
constructor(
    address _registry,
    address _admin
)
```

### Phase 4: Privacy Fee Manager Integration

With the registry pattern, PrivacyFeeManager address can be:
1. Stored in the registry
2. Looked up dynamically by contracts
3. Updated without redeploying contracts

```solidity
function _getPrivacyFeeManager() internal returns (address) {
    return _getContract(PRIVACY_FEE_MANAGER);
}
```

## Deployment Process

### Old Way (Factory):
```javascript
// Deploy everything at once
const deployment = await OmniCoinFactory.deployFullEcosystem();
```

### New Way (Registry):
```javascript
// 1. Deploy Registry
const registry = await deployRegistry();

// 2. Deploy contracts individually
const core = await deployCore(registry.address);
const escrow = await deployEscrow(registry.address);
const payment = await deployPayment(registry.address);

// 3. Register contracts
await registry.registerContract(CORE, core.address);
await registry.registerContract(ESCROW, escrow.address);
await registry.registerContract(PAYMENT, payment.address);
```

## Advantages of Registry Pattern

1. **Flexibility**: Deploy and upgrade contracts individually
2. **Gas Efficiency**: Cached lookups reduce repeated calls
3. **Maintainability**: Single source of truth for addresses
4. **Upgradability**: Change contract addresses without redeploying others
5. **Emergency Response**: Can pause/replace problematic contracts
6. **Testing**: Easier to test individual components

## Migration Timeline

1. **Week 1**: Update core contracts with RegistryAware
2. **Week 2**: Update DeFi and marketplace contracts
3. **Week 3**: Convert factories to deployment helpers
4. **Week 4**: Testing and deployment scripts

## Backwards Compatibility

During transition:
1. Keep factory contracts for reference
2. Support both patterns temporarily
3. Gradually migrate existing deployments
4. Document migration path for users

## Next Steps

1. Start with updating OmniCoinCore to extend RegistryAware
2. Create deployment helper contracts
3. Update test suite for registry pattern
4. Create migration documentation