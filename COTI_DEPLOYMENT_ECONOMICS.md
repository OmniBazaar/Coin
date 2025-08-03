# COTI V2 Layer 2.5 Deployment and Economics Guide

## Overview
This document explains the deployment logistics, costs, and payment mechanisms for running OmniCoin as a Layer 2.5 solution on top of COTI V2 network.

## Architecture Overview

### Layer 2.5 Design
OmniCoin operates as an independent blockchain with its own validator network that:
- Processes ALL OmniCoin transactions independently
- Maintains the complete OmniCoin state
- Periodically commits state roots/checkpoints to COTI for security
- Leverages COTI's MPC for privacy features when needed

### What Gets Deployed to COTI

1. **Rollup/Checkpoint Contracts** (on COTI):
   - OmniCoinRollupVerifier (verifies state transitions)
   - OmniCoinStateCommitment (stores periodic state roots)
   - OmniCoinBridge (for COTI ↔ OmniCoin asset transfers)
   - OmniCoinMPCInterface (access COTI's privacy features)

2. **OmniCoin Validator Network** (separate infrastructure):
   - Full OmniCoin blockchain with all features
   - Marketplace, escrow, payments, governance, etc.
   - Validators run OmniCoin nodes, NOT COTI nodes

### Deployment Costs

#### Testnet Deployment
- **Cost**: FREE (COTI provides test tokens)
- **Network**: COTI V2 Testnet
- **Purpose**: Testing bridge and MPC integration

#### Mainnet Deployment (COTI Contracts Only)
- **Payment Token**: COTI tokens
- **Contracts to Deploy**: 3-4 rollup/bridge contracts
- **Estimated Cost per Contract**: 1-2 COTI
- **Total Deployment Cost**: ~4-8 COTI
- **Current COTI Price**: ~$0.10-0.15 USD
- **Total USD Cost**: ~$0.50-1.50

## Transaction Flow and Economics

### Layer 2.5 Transaction Processing

1. **OmniCoin Network Transactions**:
   - Users pay fees in OmniCoins
   - Fees go directly to OmniCoin validators
   - NO COTI required for users
   - Instant finality within OmniCoin network

2. **Checkpoint/Rollup Operations**:
   - OmniCoin validators periodically submit state roots to COTI
   - Frequency: Every 1-24 hours (configurable)
   - Cost: ~10-50 COTI per checkpoint
   - Paid from validator treasury (funded by OmniCoin fees)

### OmniCoin Validator Economics

#### Revenue for OmniCoin Validators

```text
Assumptions (Conservative):
- 1,000 active users
- 5 transactions per user per day
- Total: 5,000 transactions/day

Fee Structure (paid in OmniCoins):
- Simple transfer: 0.01 OMNI
- Marketplace listing: 0.05 OMNI
- Escrow creation: 0.1 OMNI
- Average fee: ~0.03 OMNI per transaction

Daily Validator Revenue: 5,000 × 0.03 = 150 OMNI/day
Split among 100 validators: 1.5 OMNI/validator/day
```

#### COTI Checkpoint Costs

```text
Checkpoint Frequency: Every 4 hours (6 per day)
Cost per Checkpoint: ~20 COTI
Daily COTI Cost: 6 × 20 = 120 COTI (~$12-18)
Monthly COTI Cost: 3,600 COTI (~$360-540)

This is paid from validator treasury, NOT by users
```

#### High Volume Scenario

```text
Assumptions (Growth):
- 50,000 active users
- 10 transactions per user per day
- Total: 500,000 transactions/day

Daily Validator Revenue: 500,000 × 0.03 = 15,000 OMNI/day
Checkpoint Frequency: Every hour (24 per day)
Daily COTI Cost: 24 × 20 = 480 COTI (~$48-72)

Net validator profit: 15,000 OMNI - equivalent of 480 COTI
```

## Layer 2.5 Payment Architecture

### User Experience
1. **Users ONLY need OmniCoins**:
   - Pay all fees in OmniCoins
   - No COTI required for normal operations
   - Seamless experience within OmniCoin ecosystem

2. **Validator Responsibilities**:
   - Collect fees in OmniCoins
   - Maintain small COTI reserve for checkpoints
   - Convert portion of OMNI fees to COTI as needed

### Validator Treasury Management

```solidity
contract ValidatorTreasury {
    // Manages validator fee collection and COTI reserves
    
    uint256 public omniCoinReserve;
    uint256 public cotiReserve;
    uint256 public targetCotiReserve = 1000 * 10**18; // 1000 COTI
    
    // Validators deposit their share of fees
    function depositValidatorFees(uint256 omniAmount) external onlyValidator;
    
    // Convert OMNI to COTI when reserves are low
    function rebalanceReserves() external {
        if (cotiReserve < targetCotiReserve / 2) {
            // Trigger OMNI → COTI swap via bridge/DEX
        }
    }
    
    // Pay for checkpoint submission
    function fundCheckpoint() external returns (uint256 cotiAmount);
}
```

## Economic Sustainability Model

### Revenue Streams (All in OmniCoins)
1. **Transaction Fees**: Base fee + percentage
2. **Marketplace Fees**: Listing + sale commission
3. **Escrow Fees**: Creation + completion fees
4. **Premium Services**: Priority processing, enhanced features
5. **Bridge Fees**: For COTI ↔ OmniCoin transfers

### OmniCoin Validator Fee Distribution

```solidity
contract ValidatorFeeDistribution {
    uint256 constant BASIS_POINTS = 10000;
    
    // Fee allocation (total = 10000 basis points)
    uint256 public validatorShareBps = 7000;     // 70% to validators
    uint256 public treasuryShareBps = 2000;      // 20% to treasury (for COTI costs)
    uint256 public developmentShareBps = 1000;   // 10% to development
    
    function distributeFees(uint256 totalFees) internal {
        uint256 validatorAmount = (totalFees * validatorShareBps) / BASIS_POINTS;
        uint256 treasuryAmount = (totalFees * treasuryShareBps) / BASIS_POINTS;
        uint256 developmentAmount = (totalFees * developmentShareBps) / BASIS_POINTS;
        
        // Distribute to active validators proportionally
        distributeToValidators(validatorAmount);
        
        // Treasury funds COTI operations
        fundTreasury(treasuryAmount);
        
        // Development fund
        fundDevelopment(developmentAmount);
    }
}
```

### Break-Even Analysis

```text
Daily COTI Cost for Checkpoints: 120 COTI (~$15)
Required OmniCoin Revenue: ~500 OMNI/day (at 20% to treasury)

At 5,000 transactions/day:
Minimum average fee: 0.1 OMNI per transaction
This is easily achievable with the fee structure

Validator Income (100 validators):
- Gross: 1.5 OMNI/day each
- After COTI costs: ~1.4 OMNI/day each
- Annual: ~500 OMNI per validator
```

## Implementation Recommendations

### Phase 1: Testnet Launch
1. **Deploy to OmniCoin Validator Network**:
   - Launch validator nodes
   - Deploy all OmniCoin contracts
   - Test full functionality

2. **Deploy to COTI Testnet**:
   - Deploy rollup verifier contract
   - Deploy state commitment contract
   - Test checkpoint submissions

3. **Bridge Testing**:
   - Deploy bridge contracts
   - Test OMNI ↔ COTI transfers
   - Verify MPC privacy features

### Phase 2: Mainnet Preparation
1. **Validator Network**:
   - Recruit initial validators
   - Set up validator treasury
   - Establish OMNI/COTI liquidity

2. **COTI Deployment**:
   - Deploy minimal contracts to COTI
   - Set checkpoint frequency
   - Fund initial COTI reserves

### Phase 3: Production Launch
1. **User Onboarding**:
   - Users need ONLY OmniCoins
   - Simple wallet integration
   - No COTI complexity

2. **Validator Operations**:
   - Automated checkpoint submissions
   - Treasury rebalancing
   - Fee distribution

## Rollup Contract Architecture

### State Commitment Contract (on COTI)

```solidity
contract OmniCoinStateCommitment {
    struct StateRoot {
        bytes32 root;
        uint256 blockNumber;
        uint256 timestamp;
        address validator;
    }
    
    mapping(uint256 => StateRoot) public stateRoots;
    uint256 public latestCheckpoint;
    
    // Only authorized validators can submit
    function submitStateRoot(
        bytes32 _root,
        uint256 _blockNumber,
        bytes calldata _proof
    ) external onlyValidator {
        // Verify proof
        // Store state root
        // Emit event for bridges/watchers
    }
}
```

### MPC Privacy Bridge (on COTI)

```solidity
contract OmniCoinMPCBridge {
    // Allows OmniCoin users to access COTI MPC features
    
    function requestPrivateComputation(
        bytes calldata data,
        uint256 omniCoinFee
    ) external returns (bytes32 requestId) {
        // Queue MPC request
        // Lock OMNI fee
        // Return request ID
    }
}
```

## Key Advantages of Layer 2.5 Design

1. **User Simplicity**: Only need OmniCoins, no COTI
2. **Scalability**: Process millions of transactions without COTI limits
3. **Cost Efficiency**: Minimal COTI usage (only checkpoints)
4. **Validator Income**: Earn in OmniCoins, not dependent on COTI
5. **Privacy Options**: Can still use COTI MPC when needed
6. **Security**: Inherits COTI security via checkpoints

## Conclusion

The Layer 2.5 architecture provides the best of both worlds:
- Independence and scalability of OmniCoin network
- Security and privacy features of COTI when needed
- Sustainable economics with validators earning OmniCoins
- Minimal COTI costs (< $20/day even at scale)