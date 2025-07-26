# OmniCoin Testing Gaps Documentation

**Last Updated:** 2025-07-25

## Overview

This document clearly outlines what CANNOT be tested in a local Hardhat environment due to COTI's MPC (Multi-Party Computation) infrastructure requirements. These features require deployment to COTI testnet or mainnet for proper testing.

## Critical Testing Limitations

### 1. MPC Type System
The following COTI-specific types cannot be properly tested locally:
- `itUint64` - Input types (encrypted user inputs)
- `gtUint64` - Garbled types (computation within MPC)
- `ctUint64` - Ciphertext types (storage of encrypted values)
- `gtBool` - Encrypted boolean results

**Impact:** All privacy features rely on these types working correctly.

### 2. Token Transfer Operations

#### What We CANNOT Test:
- **PrivateERC20.transfer()** with encrypted amounts
- **PrivateERC20.transferFrom()** returning gtBool
- **transferGarbled()** for private transfers
- **Actual token movements** with privacy preservation
- **Balance updates** in encrypted form

#### What We CAN Test:
- Access control (who can initiate transfers)
- State transitions (marking escrows as released)
- Event emissions
- Business logic flow

### 3. Arithmetic Operations

#### What We CANNOT Test:
- **MpcCore.add()** - Adding encrypted values
- **MpcCore.sub()** - Subtracting encrypted values
- **MpcCore.mul()** - Multiplying encrypted values
- **MpcCore.div()** - Dividing encrypted values
- **MpcCore.mod()** - Modulo operations

**Examples of Untested Features:**
- Fee calculations: `fee = (amount * FEE_RATE) / BASIS_POINTS`
- Stream calculations: `withdrawable = (totalAmount * elapsed) / duration`
- Stake rewards: Complex APY calculations
- Payment splits in disputes

### 4. Comparison Operations

#### What We CANNOT Test:
- **MpcCore.gt()** - Greater than comparisons
- **MpcCore.ge()** - Greater than or equal
- **MpcCore.lt()** - Less than
- **MpcCore.le()** - Less than or equal
- **MpcCore.eq()** - Equality checks
- **MpcCore.ne()** - Not equal checks

**Examples of Untested Validations:**
- Minimum amount checks: `amount >= minEscrowAmount`
- Maximum fee validation: `fee <= maxPrivacyFee`
- Stake requirements: `stakeAmount >= minStakeAmount`
- Zero amount validation: `amount > 0`

### 5. Encryption/Decryption

#### What We CANNOT Test:
- **MpcCore.validateCiphertext()** - Input validation and encryption
- **MpcCore.offBoard()** - Converting computation results to storage
- **MpcCore.offBoardToUser()** - User-specific encryption
- **MpcCore.onBoard()** - Loading encrypted values for computation
- **MpcCore.decrypt()** - Decrypting values (requires MPC nodes)
- **MpcCore.setPublic64()** - Converting public values to MPC types

### 6. Conditional Logic with Encrypted Data

#### What We CANNOT Test:
- **Conditional transfers based on encrypted comparisons**
  - Example: Only transfer fee if `fee > 0`
- **Different execution paths based on encrypted values**
  - Example: Different tier benefits based on stake amount
- **Privacy-preserving dispute resolution**
  - Example: Validate `buyerRefund + sellerPayout == escrowAmount`

## Contract-Specific Gaps

### OmniCoinEscrowV2

**Cannot Test:**
1. Actual escrow amount encryption and storage
2. Fee calculation with privacy (0.5% of encrypted amount)
3. Token transfers on release/refund with privacy
4. Dispute resolution amount validation
5. Minimum escrow amount enforcement
6. Treasury fee distribution

**Can Test:**
1. Escrow creation flow and state changes
2. Access control for release/refund/dispute
3. Time-based refund eligibility
4. Role-based permissions

### OmniCoinPaymentV2

**Cannot Test:**
1. Private payment amount validation
2. Privacy fee calculation (0.1% with max cap)
3. Staking integration with encrypted amounts
4. Payment statistics accumulation
5. Stream withdrawal calculations
6. Stream cancellation refunds

**Can Test:**
1. Payment creation and metadata storage
2. Stream duration validation
3. Access control for streams
4. Pause/unpause functionality

### OmniCoinStakingV2

**Cannot Test:**
1. Encrypted stake amounts and rewards
2. APY calculations with compound interest
3. Tier-based reward multipliers
4. Slashing penalty calculations
5. Reward distribution mechanics

### OmniCoinReputationV2

**Cannot Test:**
1. Private reputation score calculations
2. Weighted scoring with encrypted values
3. Confidential identity verification
4. Private DPoS voting

## Testing Strategy

### 1. Local Testing (Hardhat)
Focus on:
- Business logic and state machines
- Access control and permissions
- Event emissions and logging
- Error conditions and reverts
- Non-privacy features

### 2. COTI Testnet Testing
Required for:
- All privacy features
- Encrypted calculations
- Token transfers with privacy
- MPC-specific functionality
- End-to-end integration

### 3. Mock Limitations
Our mocks:
- Use simplified types (uint256 instead of encrypted types)
- Skip MPC operations entirely
- Cannot validate privacy properties
- May hide integration issues

## Risks of Current Testing Approach

1. **False Confidence**: Tests pass locally but may fail on COTI
2. **Hidden Bugs**: Privacy-related bugs are invisible in local tests
3. **Integration Issues**: MPC type conversions not tested
4. **Performance**: MPC operations have different gas costs
5. **Security**: Privacy guarantees cannot be validated locally

## Recommendations

1. **Clearly Mark Partial Tests**: Use ⚠️ and ❌ symbols to indicate limitations
2. **Skip Untestable Features**: Use `this.skip()` for honest reporting
3. **Document Assumptions**: Be explicit about what mocks simulate
4. **Plan Testnet Testing**: Create separate test suite for COTI deployment
5. **Monitor Gas Usage**: MPC operations cost more gas than local mocks

## Next Steps

1. Complete local testing for what we can test
2. Deploy to COTI testnet
3. Create comprehensive testnet test suite
4. Validate all privacy features
5. Performance and gas optimization
6. Security audit focusing on MPC integration

---

**Remember**: Local tests are necessary but NOT sufficient for validating OmniCoin's privacy features.