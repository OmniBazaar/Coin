# Event Emission Standards for Avalanche Validator Integration

**Created:** 2025-07-31  
**Purpose:** Define standard event formats for Coin contracts to integrate with AvalancheValidator

## Overview

All OmniCoin smart contracts must emit events in a format compatible with the AvalancheValidator's event indexing system. The validator reconstructs state by indexing these events, so consistency and completeness are critical.

## Core Principles

1. **All state changes must emit events** - No silent state updates
2. **Events must include timestamp** - Required for temporal queries
3. **Use indexed parameters** - Maximum 3 per event for efficient filtering
4. **Include enough data for reconstruction** - Events should enable full state rebuild
5. **Consistent naming conventions** - Follow established patterns

## Standard Event Formats

### Staking Events

```solidity
// Expected by validator for staking operations
event Staked(
    address indexed staker,
    uint256 amount,
    uint256 duration,
    uint256 timestamp,
    uint256 tier
);

event Unstaked(
    address indexed staker,
    uint256 amount,
    uint256 timestamp
);

event StakeIncreased(
    address indexed staker,
    uint256 additionalAmount,
    uint256 newTotal,
    uint256 timestamp
);

event RewardsClaimed(
    address indexed staker,
    uint256 amount,
    uint256 timestamp
);

event BlockRewardsUpdated(
    uint256 newRewardRate,
    uint256 timestamp,
    address indexed updatedBy
);
```

### Fee Collection Events

```solidity
// Expected by validator for fee tracking
event FeeCollected(
    address indexed from,
    string feeType, // "transaction", "listing", "escrow", "arbitration", "chat"
    uint256 amount,
    uint256 timestamp
);

event FeeDistributed(
    uint256 indexed epoch,
    uint256 totalAmount,
    uint256 validatorShare,
    uint256 companyShare,
    uint256 developmentShare,
    uint256 timestamp
);
```

### Reputation Events

```solidity
// Expected by validator for reputation computation
event ReputationUpdated(
    address indexed user,
    uint256 score,
    bytes32 componentsHash, // Hash of reputation components
    uint256 timestamp
);

event ReputationRootUpdated(
    bytes32 indexed newRoot,
    uint256 blockNumber,
    uint256 timestamp
);
```

### User Activity Events

```solidity
event UserAdded(
    address indexed user,
    uint256 timestamp
);

event UserRemoved(
    address indexed user,
    uint256 timestamp
);
```

### Marketplace Events

```solidity
event ItemListed(
    uint256 indexed tokenId,
    address indexed seller,
    uint256 price,
    uint256 categoryId,
    string metadataIPFS,
    uint256 timestamp
);

event ItemPurchased(
    uint256 indexed tokenId,
    address indexed buyer,
    address indexed seller,
    uint256 price,
    uint256 timestamp
);

event ListingUpdated(
    uint256 indexed tokenId,
    uint256 newPrice,
    bool isActive,
    uint256 timestamp
);
```

### Escrow Events

```solidity
event EscrowCreated(
    bytes32 indexed escrowId,
    address indexed payer,
    address indexed payee,
    uint256 amount,
    uint256 timestamp
);

event EscrowCompleted(
    bytes32 indexed escrowId,
    uint256 timestamp
);

event EscrowCancelled(
    bytes32 indexed escrowId,
    uint256 timestamp
);

event DisputeResolved(
    bytes32 indexed escrowId,
    address winner,
    uint256 timestamp
);
```

### DEX Events

```solidity
event TradeExecuted(
    address indexed trader,
    string tokenPair,
    uint256 amount,
    uint256 price,
    string side, // "buy" or "sell"
    uint256 timestamp
);

event SwapExecuted(
    address indexed user,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint256 timestamp
);
```

### Validator Events

```solidity
event ValidatorRegistered(
    address indexed validator,
    uint256 stake,
    uint256 timestamp
);

event ValidatorUpdated(
    address indexed validator,
    bool isActive,
    uint256 stake,
    uint256 timestamp
);

event ValidatorSlashed(
    address indexed validator,
    uint256 amount,
    string reason,
    uint256 timestamp
);
```

### Transfer Events

```solidity
event Transfer(
    address indexed from,
    address indexed to,
    uint256 amount,
    uint256 timestamp
);
```

## Event Data Types

### Indexed Parameters
- Use `indexed` for addresses and IDs that will be filtered
- Maximum 3 indexed parameters per event
- Common indexed fields: addresses, token IDs, escrow IDs

### Non-indexed Data
- Include all data needed for state reconstruction
- Use structured data for complex information
- Ensure data types match validator expectations

### Timestamp Requirement
- All events MUST include a `timestamp` field
- Use `block.timestamp` for consistency
- Timestamp should be the last non-indexed parameter

## Implementation Guidelines

### 1. Replace Storage with Events

```solidity
// ❌ Old approach - storing arrays
address[] public activeStakers;
mapping(address => uint256) public stakerIndex;

// ✅ New approach - emit events only
event Staked(address indexed staker, uint256 amount, uint256 duration, uint256 timestamp, uint256 tier);
// Validator reconstructs activeStakers from events
```

### 2. Merkle Root Pattern

```solidity
// Store only merkle roots on-chain
bytes32 public stakingRoot;
uint256 public lastRootUpdate;

// Validator submits computed root
function updateStakingRoot(bytes32 newRoot) external onlyValidator {
    stakingRoot = newRoot;
    lastRootUpdate = block.number;
    emit StakingRootUpdated(newRoot, block.number, block.timestamp);
}
```

### 3. Event Completeness

```solidity
// Ensure events contain all necessary data
event StakeCreated(
    address indexed staker,
    uint256 amount,
    uint256 duration,
    uint256 timestamp,
    uint256 tier,
    uint256 expectedRewards, // Include computed values
    bool usePrivacy          // Include configuration
);
```

## Validator Query Patterns

The validator will query events using these patterns:

```sql
-- Get all staking events for a user
SELECT * FROM avalanche_events 
WHERE event_name IN ('Staked', 'Unstaked', 'StakeIncreased', 'RewardsClaimed')
AND event_data->>'staker' = $1
ORDER BY block_number DESC;

-- Get fee collections in a period
SELECT * FROM avalanche_events
WHERE event_name = 'FeeCollected'
AND timestamp >= $1 AND timestamp <= $2;

-- Reconstruct active stakes
SELECT DISTINCT ON (event_data->>'staker')
  event_data->>'staker' as staker,
  event_data->>'amount' as amount
FROM avalanche_events
WHERE event_name IN ('Staked', 'Unstaked')
ORDER BY event_data->>'staker', block_number DESC;
```

## Migration Checklist

For each contract:
- [ ] Identify all state changes
- [ ] Create corresponding events
- [ ] Add timestamp to all events
- [ ] Use indexed parameters for filterable fields
- [ ] Test event emission rates
- [ ] Verify validator can reconstruct state
- [ ] Remove unnecessary storage variables
- [ ] Implement merkle root pattern where applicable

## Testing Requirements

1. **Event Coverage**: Every state change must emit an event
2. **Data Completeness**: Events must contain all data for reconstruction
3. **Performance**: Test at 4,500 TPS event emission rate
4. **Indexing**: Verify validator indexes all events correctly
5. **Reconstruction**: Confirm state can be rebuilt from events only