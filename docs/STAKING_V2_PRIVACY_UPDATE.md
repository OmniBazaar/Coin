# OmniCoinStakingV2 Privacy Logic Update

**Date:** 2025-07-26 08:22 UTC  
**Status:** COMPLETED ✅

## Summary

Successfully updated OmniCoinStakingV2.sol to implement the proper privacy logic pattern where:
- **Default**: Public staking operations (no privacy fees)
- **Optional**: Private staking operations (10x fees via PrivacyFeeManager)

## Key Changes

### 1. Added Privacy Fee Configuration
```solidity
uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
address public privacyFeeManager;
```

### 2. Updated Constructor
```solidity
constructor(
    address _config,
    address _token,
    address _admin,
    address _privacyFeeManager
)
```

### 3. Created Dual Functions

#### Public Functions (Default - No Privacy Fees):
- `stake()` - Standard staking with public amounts
- `unstake()` - Standard unstaking with public amounts
- `claimRewards()` - Claims rewards (already existing)

#### Privacy Functions (Optional - Premium Fees):
- `stakeWithPrivacy()` - Private staking with encrypted amounts
- `unstakeWithPrivacy()` - Private unstaking with encrypted amounts

### 4. Fixed Token Transfer Methods
Updated to use OmniCoinCore's actual methods:
- `transferFromPublic()` for public stake operations
- `transferPublic()` for public unstake/reward operations
- `transferFrom()` and `transferGarbled()` for private operations

### 5. Privacy Fee Collection
Each privacy function collects fees via PrivacyFeeManager:
```solidity
PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
    msg.sender,
    keccak256("STAKING"),
    privacyFee
);
```

### 6. Staking Fee Calculation
- Base staking fee: 0.2% (20 basis points)
- Privacy multiplier: 10x
- Total privacy fee: 2% of staked amount

## Operation Types for Fee Collection
- `STAKING` - Both staking and unstaking operations

## Key Pattern Applied
```solidity
function operationWithPrivacy(...params, bool usePrivacy) {
    require(usePrivacy && isMpcAvailable, "Privacy not available");
    require(privacyFeeManager != address(0), "Privacy fee manager not set");
    
    // Collect privacy fee (10x normal fee)
    uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
    PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(...);
    
    // Private logic using MPC...
}
```

## Features Preserved
- Proof of Participation (PoP) calculations
- Tiered staking system
- Participation scores
- Lock periods and penalties
- Reward calculations and distribution
- Active staker tracking

## Architecture Note
This implementation continues the pattern where:
- Users choose between public (cheap) and private (premium) operations
- Privacy is never forced - always opt-in
- All fees collected in OMNI, conversion to COTI handled by PrivacyFeeManager
- Critical stake amounts remain encrypted for privacy
- Public tier information maintained for PoP consensus

## Next Steps
1. Create tests for the new privacy functions
2. Apply similar pattern to OmniCoinArbitration.sol
3. Continue with other contracts requiring privacy logic