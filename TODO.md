# OmniCoin Smart Contract Development Plan

**Last Updated:** 2025-07-26 07:45 UTC

## Overview

OmniCoin is being migrated from the Graphene blockchain to a new smart contract-based implementation on the COTI V2 platform. This implementation specifically leverages COTI V2's privacy features and integrates with all OmniBazaar components.

This document outlines the development plan, testing strategy, and implementation details.

## CRITICAL UPDATE: COTI V2 Native Feature Integration (2025-07-23)

### Discovered COTI V2 Native Features to Leverage

After reviewing COTI V2 documentation and SDK, we've identified that OmniBazaar is currently reimplementing several features that COTI V2 already provides natively. This presents an opportunity to reduce complexity and improve security by leveraging battle-tested COTI implementations.

#### Native COTI V2 Features Currently Being Underutilized

1. **Reputation System** - COTI has native reputation mechanisms we should use instead of `OmniCoinReputation.sol`
2. **Arbitration** - COTI provides native dispute resolution we should leverage instead of `OmniCoinArbitration.sol`
3. **Governance** - COTI has native governance features to replace our custom `OmniCoinGovernor.sol`
4. **Treasury** - COTI's native treasury can handle fee distribution instead of custom implementation
5. **Cross-Chain Bridge** - COTI may have native cross-chain capabilities to explore

#### Currently Well-Utilized COTI V2 Features

1. **Privacy Layer (Garbled Circuits/MPC)** - We're correctly using COTI's privacy features
2. **MPC Precompile** - Leveraging native blockchain precompile at address `0x64`
3. **Encrypted Types** - Using `ctUint64`, `gtUint64`, `itUint64` for private operations
4. **Private ERC20** - Implementing confidential transfers with COTI's PrivateERC20

### Updated Architecture: Hybrid L2.5 Implementation

Based on our analysis, OmniCoin operates as:
- **Layer 2.5 blockchain** with its own validators processing public transactions
- **Optional privacy** via COTI MPC for users who pay premium fees (10-50x standard)
- **Fee abstraction** - users always pay in OMNI, we handle COTI conversion
- **Public by default** - privacy is opt-in, not mandatory
- **All contracts default to `isMpcAvailable = false`** for production use

## 🚨 CRITICAL UPDATE: Privacy Logic Pattern (2025-01-27)

### Issue Discovered:
User identified critical flaw: Setting `isMpcAvailable = false` on COTI would disable existing MPC functionality.

### Solution Implemented:
**Separate technical capability from business logic:**
- `isMpcAvailable`: Whether MPC is technically available (true on COTI, false in Hardhat)
- `privacyEnabledByDefault`: Business decision (always false - privacy is opt-in)
- New functions: `transferWithPrivacy()`, `transferFromWithPrivacy()`, etc.

### Pattern to Apply to ALL Contracts:
```solidity
// OLD (WRONG):
if (isMpcAvailable) {
    // Always use privacy when MPC is available
}

// NEW (CORRECT):
function doSomethingWithPrivacy(params, bool usePrivacy) {
    if (usePrivacy && isMpcAvailable) {
        // User explicitly chose privacy
        require(privacyFeeManager != address(0), "Privacy fee manager not set");
        IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("OPERATION_TYPE"),
            amount
        );
        // Use MPC for private operation
    } else {
        // Standard public operation (default)
    }
}
```

## 🚨 PLATFORM DECISION UPDATE (2025-07-26)

### Decision: STAY WITH COTI
After thorough analysis, we're staying with COTI for its unique MPC privacy capabilities. Migration to Polygon would require 6-10 months and lose 80% of our privacy features.

### Immediate Optimization Priorities:
1. **Convert all storage to events** - 90% cost reduction
2. **Implement batch processing** - Single tx for multiple operations  
3. **Move evaluator logic to validators** - Off-chain computation
4. **Use state commitments** - Only merkle roots on-chain

See `COTI_TO_POLYGON_MIGRATION_ANALYSIS.md` for full analysis.

### Implementation Priority (Updated 2025-07-26)

#### 🔥 IMMEDIATE PRIORITY: Apply Privacy Logic Pattern to All Contracts

1. **OmniCoinEscrowV2.sol** - Has isMpcAvailable ✅, needs privacy choice functions
   - [ ] Add `createEscrowWithPrivacy()` function
   - [ ] Add `releaseEscrowWithPrivacy()` function
   - [ ] Integrate PrivacyFeeManager
   - [ ] Default to public escrows

2. **OmniCoinPaymentV2.sol** - Has isMpcAvailable ✅, needs privacy choice functions
   - [ ] Add `createPaymentWithPrivacy()` function
   - [ ] Add `processPaymentWithPrivacy()` function
   - [ ] Integrate PrivacyFeeManager
   - [ ] Default to public payments

3. **OmniCoinStakingV2.sol** - Has isMpcAvailable ✅, needs privacy choice functions
   - [ ] Add `stakeWithPrivacy()` function
   - [ ] Add `unstakeWithPrivacy()` function
   - [ ] Integrate PrivacyFeeManager
   - [ ] Default to public staking

4. **OmniCoinArbitration.sol** - Has isMpcAvailable ✅, needs privacy choice functions
   - [ ] Add `createDisputeWithPrivacy()` function
   - [ ] Add `submitEvidenceWithPrivacy()` function
   - [ ] Integrate PrivacyFeeManager
   - [ ] Some disputes may be public

5. **OmniCoinBridge.sol** - Needs full privacy logic implementation
   - [ ] Add `isMpcAvailable` flag
   - [ ] Add `bridgeWithPrivacy()` function
   - [ ] Integrate PrivacyFeeManager
   - [ ] Default to public transfers

### Implementation Priority (Updated 2025-01-23)

#### Phase 1: Core Smart Contracts on COTI V2 ✅ MAJOR PROGRESS
- [x] Document Hybrid L2.5 Architecture in BLOCKCHAIN_ARCHITECTURE_ANALYSIS.md
- [x] **✅ COMPLETED:** Create `OmniCoinCore.sol` - Privacy-enabled ERC20 using COTI's MPC
  - Inherits from COTI's PrivateERC20
  - Dual-layer validation (COTI + Validator operations)
  - Privacy preferences and encrypted transfers
  - **✅ FIXED:** Separated isMpcAvailable from privacyEnabledByDefault
  - **✅ NEW:** transferWithPrivacy() and transferFromWithPrivacy() functions
  - **✅ INTEGRATED:** PrivacyFeeManager for fee collection
  - **35/35 tests passing**
- [x] **✅ COMPLETED:** Create `OmniCoinStakingV2.sol` - Staking with encrypted balances
  - Hybrid privacy approach (encrypted amounts + public PoP data)
  - Integration with participation scores for consensus
  - Private reward calculations with encrypted distribution
- [ ] **🔄 IN PROGRESS:** Deploy `OmniCoinReputation.sol` - Our own reputation system
- [ ] Deploy `OmniCoinArbitration.sol` - Our own arbitration system  
- [ ] Deploy `OmniCoinGovernance.sol` - Our own governance system
- [ ] Create `OmniCoinTreasury.sol` - Our own fee distribution (70/20/10)

#### Phase 2: Validator Network Implementation
- [ ] Launch OmniCoin validator nodes with PoP consensus
- [ ] Implement 23 marketplace evaluators in validator layer
- [ ] Create bridge between on-chain and off-chain operations
- [ ] Integrate IPFS, Chat, Faucet, Explorer services

## 🔥 COMPREHENSIVE SMART CONTRACT MIGRATION ANALYSIS

### ✅ COMPLETED CONTRACTS

#### 1. **OmniCoinCore.sol** - Main Token Contract ✅ DONE
**Migration Status**: ✅ **FULLY COMPLETED**
- [x] **Inherit from COTI's PrivateERC20**: Complete integration with MPC types
- [x] **Privacy-enabled transfers**: transferPrivate(), transferGarbled()
- [x] **Dual-layer validation**: COTI transactions + Validator operations
- [x] **Bridge operations**: submitToValidators() for L2.5 architecture
- [x] **Role-based access**: Minter, Burner, Pauser, Validator, Bridge roles
- [x] **Emergency functions**: Pause, emergency execute operations
- [x] **Comprehensive testing**: 35/35 tests passing
- **File**: `/contracts/OmniCoinCore.sol`
- **Tests**: `/test/OmniCoinCore.test.js`

#### 2. **OmniCoinStakingV2.sol** - Privacy-Enabled Staking ✅ DONE
**Migration Status**: ✅ **FULLY COMPLETED** with hybrid privacy approach
- [x] **Encrypted stake amounts**: Using gtUint64, ctUint64, itUint64
- [x] **Public tier levels**: For PoP consensus calculations
- [x] **Public participation scores**: For validator weight calculations
- [x] **Private reward distribution**: Encrypted reward calculations
- [x] **Staking functions**: stakePrivate(), stakeGarbled(), unstakePrivate()
- [x] **Penalty calculations**: Early unstaking penalties with privacy
- [x] **Integration testing**: Contract compiles and tests structure validated
- **File**: `/contracts/OmniCoinStakingV2.sol`
- **Tests**: `/test/OmniCoinStakingV2.test.js`

### 🔴 **CRITICAL PRIORITY CONTRACTS** (Need Major Overhaul)

#### 3. **OmniCoinReputationV2.sol** - Reputation System ✅ DONE
**Migration Status**: ✅ **FULLY COMPLETED** with comprehensive features
- [x] **Private reputation scoring**: Full MPC integration for encrypted calculations
- [x] **Public tier data**: 5 default tiers for validator selection
- [x] **Flexible weighting**: 11 components with updateable weights (no hard forks)
- [x] **Identity verification**: 9 tiers from unverified to corporate
- [x] **DPoS trust voting**: Encrypted vote tracking and COTI PoT ready
- [x] **Referral tracking**: Disseminator activity with quality metrics
- [x] **Privacy preferences**: User-controlled reputation visibility
- [x] **Hardhat testing**: Structure and logic validated
- **File**: `/contracts/OmniCoinReputationV2.sol`
- **Tests**: `/test/OmniCoinReputationV2.test.js`

#### 4. **OmniCoinArbitration.sol** - Dispute Resolution
**Current Status**: Has bugs (line 236) + needs privacy
**Key Changes Required**:
- [ ] **Fix existing bugs**: Critical issue at line 236 in arbitration logic
- [ ] **Confidential disputes**: Encrypt evidence and voting
- [ ] **Private arbitrator selection**: Use encrypted reputation scores
- [ ] **Encrypted voting**: Arbitrators vote privately using MPC
- [ ] **Public resolution**: Results are public but process is private
**Timeline**: 2-3 weeks

#### 5. **FeeDistribution.sol** - Validator Rewards
**Current Status**: Well-implemented but needs privacy
**Key Changes Required**:
- [ ] **Private validator rewards**: Encrypt reward calculations
- [ ] **70/20/10 distribution**: Implement with MPC operations
- [ ] **Encrypted fee collection**: Private fee accumulation
- [ ] **Public statistics**: Maintain public metrics for transparency
**Timeline**: 1-2 weeks

### 🟡 **HIGH PRIORITY CONTRACTS** (Need Significant Updates)

#### 6. **OmniCoinGovernor.sol** - Governance System
**Current Status**: Needs private voting and proposal privacy
**Key Changes Required**:
- [ ] **Private voting**: Encrypt votes using MPC
- [ ] **Confidential proposals**: Optional private proposal details
- [ ] **Encrypted vote counting**: Use garbled circuits for tallying
- [ ] **Public results**: Final outcomes remain transparent
**Timeline**: 2-3 weeks

#### 7. **ValidatorBlockchainService** - Validator Integration
**Current Status**: Needs COTI V2 integration updates
**Key Changes Required**:
- [ ] **COTI RPC integration**: Connect to COTI V2 nodes
- [ ] **MPC operation handling**: Process encrypted transactions
- [ ] **Privacy preference management**: Handle user privacy settings
- [ ] **Bridge operations**: Implement L2.5 dual-layer processing
**Timeline**: 2-3 weeks

### 🟢 **MEDIUM PRIORITY CONTRACTS** (Minor Updates Needed)

#### 8. **OmniCoinEscrow.sol** - Marketplace Escrow
**Current Status**: Basic functionality works, needs privacy enhancements
**Key Changes Required**:
- [ ] **Private escrow amounts**: Encrypt deposited amounts
- [ ] **Confidential disputes**: Private dispute resolution integration
- [ ] **Public milestones**: Maintain public escrow status
**Timeline**: 1-2 weeks

### 🔵 **SUPPORTING CONTRACTS** (Enhancement Opportunities)

#### 9. **OmniCoinBridge.sol** - Cross-Chain Bridge
**Current Status**: Good foundation, can add privacy features
**Key Changes Required**:
- [ ] **Private cross-chain transfers**: Encrypt bridge amounts
- [ ] **Public verification**: Maintain transparent bridge operations
**Timeline**: 1 week

#### 10. **OmniCoinMultisig.sol** - Multi-Signature Wallet
**Current Status**: Well-implemented, minimal changes needed
**Key Changes Required**:
- [ ] **Private signature collection**: Optional signature privacy
- [ ] **Public execution**: Maintain transparent multi-sig operations
**Timeline**: 1 week

### 📊 **IMPLEMENTATION TIMELINE (5 WEEKS REMAINING)**

**Week 1-2**: OmniCoinReputation.sol (private scoring)
**Week 3**: FeeDistribution.sol (private rewards) + OmniCoinEscrow.sol (private escrow)
**Week 4-5**: OmniCoinArbitration.sol (fix bugs + privacy) + OmniCoinGovernor.sol (private voting)

**Parallel**: ValidatorBlockchainService updates + Bridge/Multisig enhancements

#### Phase 3: Privacy Integration
- [ ] Implement private transfers using COTI's garbled circuits
- [ ] Add encrypted staking amounts using `ctUint64`
- [ ] Create private fee distribution mechanisms
- [ ] Implement selective disclosure for compliance

### Technical Architecture

1. **Dual-Layer Validation:**
   - COTI V2: Handles token transfers and on-chain operations
   - OmniCoin Validators: Process marketplace business logic

2. **Smart Contract Distribution:**
   - On COTI V2: Core token, staking, reputation, arbitration, governance, treasury
   - Off-chain: 23 marketplace evaluators running on validators

3. **Privacy Features:**
   - Use COTI's MPC precompile at address `0x64`
   - Implement encrypted types (`ctUint64`, `gtUint64`, `itUint64`)
   - Leverage garbled circuits for 100x performance vs ZK proofs

## Phase 1: Smart Contract Development (Weeks 1-4)

### 1.1 Core Token Features

- [x] Token Implementation
  - [x] Create ERC-20 compatible contract
  - [x] Implement token economics
  - [x] Add supply management
  - [x] Create transfer functions
  - [x] Implement approval system
  - [x] Add multi-chain support for Wallet integration
  - [x] Implement cross-chain bridge interfaces
  - [x] Add DEX-specific token functions

### 1.2 Staking System

- [x] Staking Features
  - [x] Create staking contract
  - [x] Implement rewards
  - [x] Add lock periods
  - [x] Create unstaking
  - [x] Add emergency withdrawal
  - [x] Implement DEX-specific staking rewards
  - [x] Add validator node staking
  - [x] Create storage node staking

## Phase 2: Privacy Features (Weeks 5-8)

### 2.1 COTI V2 Privacy Integration

- [x] Privacy Implementation
  - [x] Integrate COTI V2 privacy layer
  - [x] Implement zero-knowledge proofs
  - [x] Add private transfers
  - [x] Create shielded balances
  - [x] Implement mixing service
  - [x] Add DEX-specific privacy features
  - [x] Implement Wallet privacy controls
  - [x] Create Chat privacy integration

### 2.2 Privacy Controls

- [x] User Controls
  - [x] Add privacy levels
  - [x] Create opt-in features
  - [x] Implement defaults
  - [x] Add user preferences
  - [x] Create documentation
  - [x] Add Wallet privacy settings
  - [x] Implement DEX privacy options
  - [x] Create Chat privacy settings

## Phase 3: Reputation System (Weeks 9-12)

### 3.1 Reputation Features

- [ ] Core Features
  - [ ] Create reputation contract
  - [ ] Implement scoring
  - [ ] Add verification
  - [ ] Create history
  - [ ] Implement updates
  - [ ] Add multi-chain reputation tracking
  - [ ] Create cross-chain reputation sync
  - [ ] Implement privacy-preserving reputation

### 3.2 Reputation Management

- [ ] Management Tools
  - [ ] Add dispute resolution
  - [ ] Create appeals
  - [ ] Implement penalties
  - [ ] Add rewards
  - [ ] Create reporting
  - [ ] Add reputation recovery
  - [ ] Implement reputation protection
  - [ ] Create reputation migration

## Phase 4: Arbitration System (Weeks 13-16)

### 4.1 Arbitration Features

- [ ] Core Features
  - [ ] Create arbitration contract
  - [ ] Implement voting
  - [ ] Add evidence
  - [ ] Create decisions
  - [ ] Implement enforcement
  - [ ] Add cross-chain arbitration
  - [ ] Create privacy-preserving arbitration
  - [ ] Implement automated resolution

### 4.2 Arbitration Management

- [ ] Management Tools
  - [ ] Add arbitrator selection
  - [ ] Create case management
  - [ ] Implement fees
  - [ ] Add appeals
  - [ ] Create documentation
  - [ ] Add emergency procedures
  - [ ] Implement automated monitoring
  - [ ] Create performance tracking

## Phase 5: Integration Features (Weeks 17-20)

### 5.1 Wallet Integration

- [ ] Wallet Features
  - [ ] Create wallet interface contract
  - [ ] Implement key management
  - [ ] Add multi-sig support
  - [ ] Create backup/restore system
  - [ ] Implement hardware wallet support
  - [ ] Add biometric authentication
  - [ ] Create session management

### 5.2 DEX Integration

- [ ] DEX Features
  - [ ] Create DEX interface contract
  - [ ] Implement order management
  - [ ] Add liquidity pool integration
  - [ ] Create trading pair management
  - [ ] Implement price feeds
  - [ ] Add order book integration
  - [ ] Create matching engine interface

### 5.3 Storage Integration

- [ ] Storage Features
  - [ ] Create storage interface contract
  - [ ] Implement file management
  - [ ] Add IPFS integration
  - [ ] Create access control
  - [ ] Implement encryption
  - [ ] Add backup system
  - [ ] Create recovery system

### 5.4 Validator Integration

- [ ] Validator Features
  - [ ] Create validator interface contract
  - [ ] Implement node management
  - [ ] Add consensus mechanism
  - [ ] Create reward distribution
  - [ ] Implement slashing conditions
  - [ ] Add monitoring system
  - [ ] Create reporting system

## Phase 6: Cross-Chain Features (Weeks 21-24)

### 6.1 Bridge Implementation

- [x] Bridge Features
  - [x] Create bridge contract
  - [x] Implement transfers
  - [x] Add verification
  - [x] Create security
  - [x] Implement monitoring
  - [x] Add multi-chain support
  - [x] Create liquidity management
  - [x] Implement fee system

### 6.2 Bridge Management

- [x] Management Tools
  - [x] Add liquidity pools
  - [x] Create fees
  - [x] Implement limits
  - [x] Add monitoring
  - [x] Create documentation
  - [x] Implement security measures
  - [x] Add emergency controls

## Phase 7: Testing and Security (Weeks 25-28)

### 7.1 Testing

- [x] Test Implementation
  - [x] Create unit tests
  - [x] Add integration tests
  - [x] Implement stress tests
  - [x] Create security tests
  - [x] Add performance tests
  - [x] Test cross-chain features
  - [x] Test privacy features
  - [x] Test integration with all components
  - [ ] Test reputation system
  - [ ] Test arbitration system

### 7.2 Security

- [x] Security Features
  - [x] Add audits
  - [x] Create monitoring
  - [x] Implement emergency stops
  - [x] Add recovery
  - [x] Create documentation
  - [x] Implement multi-sig controls
  - [x] Add time-locks
  - [x] Create circuit breakers
  - [x] Add reputation protection
  - [x] Implement arbitration security

## Phase 8: Documentation and Launch (Weeks 29-32)

### 8.1 Documentation

- [x] Documentation Creation
  - [x] Create user guides
  - [x] Add API documentation
  - [x] Implement examples
  - [x] Create tutorials
  - [x] Add troubleshooting
  - [x] Document integration points
  - [x] Create security guidelines
  - [x] Add privacy documentation
  - [ ] Document reputation system
  - [ ] Create arbitration guides

### 8.2 Launch

- [ ] Launch Preparation
  - [ ] Add monitoring
  - [ ] Create support
  - [ ] Implement updates
  - [ ] Add marketing
  - [ ] Create community
  - [ ] Set up governance
  - [ ] Create upgrade mechanism
  - [ ] Implement feedback system
  - [ ] Set up reputation monitoring
  - [ ] Create arbitration support

## Technical Requirements

### Smart Contracts

- [x] Solidity ^0.8.0
- [x] OpenZeppelin contracts
- [x] COTI V2 SDK
- [x] Hardhat
- [x] dYdX V4 contracts (for DEX integration)
- [x] IPFS integration (for Storage)
- [x] Multi-chain support libraries
- [ ] Reputation system contracts
- [ ] Arbitration system contracts

### Testing

- [x] Hardhat testing
- [x] Jest
- [x] Security scanning
- [x] Performance testing
- [x] Cross-chain testing
- [x] Privacy testing
- [x] Integration testing
- [ ] Reputation system testing
- [ ] Arbitration system testing

## Dependencies

- [x] Node.js >= 16
- [x] npm >= 8
- [x] Hardhat
- [x] TypeScript
- [x] OpenZeppelin
- [x] COTI V2 SDK
- [x] dYdX V4 SDK
- [x] IPFS SDK
- [x] Multi-chain bridge SDKs
- [ ] Reputation system SDK
- [ ] Arbitration system SDK

## Notes

- [x] All code must be thoroughly documented
- [x] Follow Solidity best practices
- [x] Implement comprehensive error handling
- [x] Maintain high test coverage
- [x] Regular security audits
- [x] Performance optimization throughout development
- [x] Privacy features must be thoroughly tested and audited
- [x] All integrations must be thoroughly tested
- [x] Cross-chain features must be secure and reliable
- [x] Regular updates and maintenance required
- [x] Community feedback and governance important
- [x] Regular security audits required
- [x] Performance monitoring essential
- [x] Privacy features must be user-friendly
- [x] All components must be upgradeable
- [x] Emergency procedures must be in place
- [x] Regular backups required
- [x] Monitoring and alerting essential
- [x] Documentation must be comprehensive
- [x] Support system must be robust
- [ ] Reputation system must be fair and transparent
- [ ] Arbitration system must be efficient and reliable
- [ ] Both reputation and arbitration must be privacy-preserving
- [ ] Cross-chain reputation must be consistent
- [ ] Arbitration must work across all chains