# OmniCoinReputationV2 Contract Split Plan

## Problem
- Current size: 31.895 KB (exceeds 24.576 KB limit by 7.319 KB)
- Need to reduce by ~30% minimum

## Split Strategy

### 1. OmniCoinIdentityVerification.sol (NEW)
**Responsibilities:**
- Identity verification tiers and management
- KYC integration
- Identity score calculations
- Privacy-preserving identity proofs

**Extracted from ReputationV2:**
- Identity verification structs and mappings
- verifyIdentity() and related functions
- Identity tier management
- Identity-related events

**Estimated size reduction:** ~15-20%

### 2. OmniCoinTrustSystem.sol (NEW)
**Responsibilities:**
- DPoS voting management
- COTI Proof of Trust integration
- Trust score calculations
- Vote delegation and tracking

**Extracted from ReputationV2:**
- Trust data structs and mappings
- castDPoSVote() and related functions
- Trust score calculations
- Trust-related events

**Estimated size reduction:** ~15-20%

### 3. OmniCoinReferralSystem.sol (NEW)
**Responsibilities:**
- Referral tracking and rewards
- Disseminator activity monitoring
- Referral score calculations
- Multi-level referral management

**Extracted from ReputationV2:**
- Referral data structs and mappings
- recordReferral() and related functions
- Referral reward calculations
- Referral-related events

**Estimated size reduction:** ~10-15%

### 4. OmniCoinReputationCore.sol (RENAME from V2)
**Remaining Responsibilities:**
- Core reputation score aggregation
- Component weighting system
- Reputation queries
- Integration with other reputation modules
- Tier calculations

**Size after split:** Should be ~50-60% of original

## Implementation Approach

1. Create abstract base contract for shared functionality
2. Use interfaces for module communication
3. Deploy as separate contracts but maintain single entry point
4. Use delegatecall or direct calls for module integration

## Benefits
- Each contract under size limit
- Easier to maintain and upgrade
- More modular architecture
- Can update components independently
- Better separation of concerns