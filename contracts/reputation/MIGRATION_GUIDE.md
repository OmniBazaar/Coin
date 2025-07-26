# OmniCoin Reputation System Migration Guide

## Overview

The OmniCoin Reputation System has been refactored from a single monolithic contract (OmniCoinReputationV2.sol - 31.895 KB) into a modular architecture with multiple smaller contracts:

1. **OmniCoinReputationCore.sol** (Main coordinator)
2. **OmniCoinIdentityVerification.sol** (9.197 KB)
3. **OmniCoinTrustSystem.sol** (11.127 KB)
4. **OmniCoinReferralSystem.sol** (11.482 KB)

## Architecture Benefits

- **Deployable**: All contracts are under the 24.576 KB limit
- **Modular**: Each module can be upgraded independently
- **Maintainable**: Focused contracts with clear responsibilities
- **Extensible**: Easy to add new reputation components

## Deployment Order

Deploy contracts in this specific order:

```solidity
// 1. Deploy Core first (needs module addresses, can be zero initially)
OmniCoinReputationCore core = new OmniCoinReputationCore(
    adminAddress,
    configAddress,
    address(0), // identityModule - will set later
    address(0), // trustModule - will set later
    address(0)  // referralModule - will set later
);

// 2. Deploy modules with core address
OmniCoinIdentityVerification identity = new OmniCoinIdentityVerification(
    adminAddress,
    address(core)
);

OmniCoinTrustSystem trust = new OmniCoinTrustSystem(
    adminAddress,
    address(core)
);

OmniCoinReferralSystem referral = new OmniCoinReferralSystem(
    adminAddress,
    address(core)
);

// 3. Update core with module addresses
core.updateIdentityModule(address(identity));
core.updateTrustModule(address(trust));
core.updateReferralModule(address(referral));
```

## Integration Points

### For OmniCoin Main Contract

Replace references to single reputation contract:

```solidity
// Old:
OmniCoinReputationV2 public reputation;

// New:
OmniCoinReputationCore public reputationCore;
```

### For Reputation Queries

```solidity
// Check validator eligibility
bool eligible = reputationCore.isEligibleValidator(userAddress);

// Get public reputation tier
uint256 tier = reputationCore.getPublicReputationTier(userAddress);

// Check arbitrator eligibility
bool canArbitrate = reputationCore.isEligibleArbitrator(userAddress);
```

### For Module-Specific Operations

#### Identity Verification
```solidity
// Verify identity (requires IDENTITY_VERIFIER_ROLE)
identity.verifyIdentity(user, tier, proofHash, encryptedScore);

// Check identity status
uint8 tier = identity.getIdentityTier(user);
bool expired = identity.isIdentityExpired(user);
```

#### Trust System
```solidity
// Cast DPoS vote
trust.castDPoSVote(candidate, encryptedVotes);

// Update COTI PoT score (requires COTI_ORACLE_ROLE)
trust.updateCotiPoTScore(user, score);
```

#### Referral System
```solidity
// Record referral (requires REFERRAL_MANAGER_ROLE)
referral.recordReferral(referrer, referee, activityScore);

// Process referral rewards
referral.processReferralReward(referrer, rewardAmount);
```

## Access Control

Each module has its own roles:

- **Core**: ADMIN_ROLE, REPUTATION_UPDATER_ROLE, MODULE_ROLE
- **Identity**: IDENTITY_VERIFIER_ROLE, KYC_PROVIDER_ROLE
- **Trust**: TRUST_MANAGER_ROLE, COTI_ORACLE_ROLE
- **Referral**: REFERRAL_MANAGER_ROLE

Grant appropriate roles after deployment:

```solidity
// Grant verifier role to KYC oracle
identity.grantRole(identity.IDENTITY_VERIFIER_ROLE(), kycOracleAddress);

// Grant COTI oracle role
trust.grantRole(trust.COTI_ORACLE_ROLE(), cotiOracleAddress);

// Grant referral manager role
referral.grantRole(referral.REFERRAL_MANAGER_ROLE(), referralManagerAddress);
```

## Configuration

### Component Weights

Default weights (must sum to 10000):
- Transaction Success: 1500 (15%)
- Transaction Dispute: 500 (5%)
- Arbitration: 1000 (10%)
- Governance: 500 (5%)
- Validator: 1500 (15%)
- Marketplace: 1000 (10%)
- Community: 500 (5%)
- Uptime: 1000 (10%)
- Trust: 2000 (20%)
- Referral: 1000 (10%)
- Identity: 1500 (15%)

Update weights if needed:
```solidity
uint256[11] memory newWeights = [...];
core.batchUpdateWeights(newWeights);
```

### MPC Availability

Enable MPC when deploying to COTI testnet/mainnet:
```solidity
core.setMpcAvailability(true);
identity.setMpcAvailability(true);
trust.setMpcAvailability(true);
referral.setMpcAvailability(true);
```

## Testing

Test each module independently:
```bash
# Test core aggregation
npx hardhat test test/reputation/OmniCoinReputationCore.test.js

# Test identity module
npx hardhat test test/reputation/OmniCoinIdentityVerification.test.js

# Test trust module
npx hardhat test test/reputation/OmniCoinTrustSystem.test.js

# Test referral module
npx hardhat test test/reputation/OmniCoinReferralSystem.test.js

# Integration tests
npx hardhat test test/reputation/ReputationIntegration.test.js
```

## Migration Checklist

- [ ] Deploy OmniCoinReputationCore
- [ ] Deploy three module contracts
- [ ] Update core with module addresses
- [ ] Grant necessary roles to operators
- [ ] Configure component weights if needed
- [ ] Update OmniCoin main contract reference
- [ ] Update all reputation queries to use core
- [ ] Test validator/arbitrator eligibility
- [ ] Enable MPC for production deployment