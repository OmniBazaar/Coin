# OmniCoin Development Plan - Avalanche Migration + Simplification

**Last Updated:** 2025-07-30 18:07 UTC

## 🎯 NEW STRATEGY: Parallel Development
We're pursuing simultaneous development of:
1. **Radical Simplification** - Moving 80% of functionality off-chain
2. **Avalanche Subnet Migration** - For the public chain only

## Overview

OmniCoin is undergoing radical simplification to reduce complexity by 60-80% through aggressive state reduction and contract consolidation, while simultaneously migrating to Avalanche subnet for better performance and scalability.

### Why Parallel Development?
- **Validators need complete rewrite anyway** - Build for Avalanche from start
- **Privacy stays on COTI** - No complex integration needed
- **Saves 4-6 weeks** vs sequential approach
- **No throwaway work** - Design once, build once

## 🚀 WEEK 1 PRIORITIES (Immediate)

### Day 1-2: Avalanche Foundation
- [x] **Install Avalanche SDK**
  - `npm install --save-dev avalanche @avalabs/avalanchejs`
- [ ] **Study Avalanche Architecture**
  - Block structure differences
  - Event emission patterns
  - Consensus participation
  - Gas mechanics with custom token
- [ ] **Design Event Schema for Avalanche**
  - Optimize for fast blocks (1-2s)
  - Consider higher event throughput
  - Plan for efficient indexing

### Day 3-5: Begin Simplification
- [ ] **Remove User Arrays (First 10 contracts)**
  - Start with OmniCoinStaking.sol
  - Replace `address[] activeStakers` with events
  - Update tests to use event queries
  - Design with Avalanche's capabilities in mind
  
- [ ] **Convert History to Events**
  - Transaction history → Events
  - Price history → Events  
  - Design for Avalanche's fast finality

### Parallel: Validator Design
- [ ] **Study Avalanche Validator Requirements**
  - Consensus participation model
  - Block production mechanics
  - Subnet validator economics
- [ ] **Begin Validator Prototype**
  - Use Avalanche SDK from start
  - Design for subnet architecture
  - Plan merkle tree generation

## Contract Simplification (Avalanche-Optimized)

### Week 2: Contract Consolidation
- [ ] **Merge Reputation Contracts (5→1)**
  - Design events for Avalanche's throughput
  - Use Avalanche's fast finality for queries
  
- [ ] **Merge Payment Contracts (3→1)**
  - Optimize for Avalanche's transaction model
  - Consider cross-subnet capabilities

- [ ] **Merge NFT Contracts (3→1)**
  - Design for high-volume marketplace
  - Leverage Avalanche's performance

### Week 3-4: Avalanche Testing
- [ ] **Deploy to Fuji Testnet**
  - Test simplified contracts
  - Measure actual performance
  - Validate gas costs with XOM
  
- [ ] **Update Bridge Contracts**
  - Point to Avalanche instead of COTI public
  - Test OmniCoin ↔ PrivateOmniCoin flow

### Week 5-6: Integration
- [ ] **Configure Subnet Parameters**
  - XOM as native gas token
  - 2-second block time
  - Validator requirements
  
- [ ] **Full System Testing**
  - End-to-end transaction flow
  - Bridge functionality
  - Performance benchmarks

## Technical Decisions for Avalanche

### Event Architecture
```solidity
// Design for Avalanche's capabilities
event UserAction(
    address indexed user,
    uint256 indexed blockTime,  // Fast blocks = more granular time
    bytes32 indexed dataHash    // Efficient indexing
);
```

### Validator Architecture
```javascript
// Build for Avalanche from start
class AvalancheValidator {
    constructor() {
        this.avalanche = new Avalanche(...);
        // Native Avalanche SDK integration
    }
}
```

### Contract Design Principles
1. **Remove all arrays** - Use events
2. **Minimize storage** - Validators compute
3. **Optimize for Avalanche** - Fast blocks, high throughput
4. **Keep privacy separate** - COTI handles encryption

## Success Metrics

### Simplification Goals
- **Before:** 30+ contracts, ~50k storage slots
- **After:** 12 contracts, ~5k storage slots
- **Gas Reduction:** 60% lower costs

### Avalanche Performance Goals
- **Finality:** 1-2 seconds (vs 6 seconds)
- **TPS:** 4,500+ (vs ~1,000)
- **Validators:** Unlimited (vs restricted)

## Development Resources

### Avalanche Documentation
- [Architecture Overview](https://docs.avax.network/learn/avalanche/avalanche-platform)
- [Subnet Development](https://docs.avax.network/subnets)
- [SDK Reference](https://github.com/ava-labs/avalanchejs)

### Installed Packages
- `@avalabs/avalanchejs` - Core SDK
- `avalanche` - Legacy support

## Critical Path Items

### This Week
1. **Understand Avalanche deeply** before coding
2. **Start array removal** with Avalanche in mind
3. **Design validators** for Avalanche from day 1
4. **Document all decisions** in AVALANCHE_DECISIONS.md

### Next Week
1. **Continue simplification** (contract merging)
2. **Build validator prototype** with Avalanche SDK
3. **Prepare for testnet** deployment

## Important Notes

- **Privacy stays on COTI** - Don't complicate this
- **Build for Avalanche from start** - No retrofitting
- **Events are critical** - Design carefully
- **Test continuously** - Big changes need validation

## Next Development Session

1. Study Avalanche consensus mechanism
2. Remove arrays from OmniCoinStaking.sol
3. Design event schema document
4. Update validator architecture plans

The path forward: Simultaneous simplification and Avalanche migration for optimal efficiency.