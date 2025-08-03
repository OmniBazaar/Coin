# OmniBazaar Design Questions

Last Updated: 2025-07-30 18:16 UTC

This document contains ongoing design questions that require discussion and clarification.

## 1. Consensus Mechanism - Now Using Avalanche

**UPDATE**: We have decided to use Avalanche Snowman consensus instead of Tendermint-style BFT.

**Resolved**:
- Avalanche subnet provides 1-2 second finality
- Unlimited validators supported
- Stake requirement: 1M XOM minimum

**Still to Determine**:
- How is additional PoP score calculated beyond staking?
- Should we add transaction validation history scoring?
- Community participation metrics?
- Validator performance scoring for rewards?

## 2. Validator Limit - Resolved by Avalanche

**UPDATE**: Avalanche subnets support unlimited validators, making this constraint unnecessary.

**Resolved**:
- No artificial validator limit needed
- Network can scale with demand
- Natural economics (1M XOM stake) provides appropriate barrier

**Archived**: This question is no longer relevant with Avalanche architecture.

## 3. Listing Nodes and Validator Network

**Question**: How do listing nodes interact with the validator network?

**Context from Design Doc**:
- Listing nodes receive 70% of listing fees (0.175% of transaction)
- Selling nodes receive 20% of listing fees (0.05% of transaction)

**Discussion Points**:
- Are listing nodes separate from validators?
- How are listing/selling nodes selected and registered?
- Do they require staking like validators?
- How is the node that "helped" with a sale determined?
- Should nodes run special software or just be addresses?

## 4. ODDAO Governance Structure

**Question**: What is the governance structure and membership model for ODDAO?

**Context from Design Doc**:
- ODDAO receives significant fee portions:
  - 10% of escrow fees
  - 70% of transaction fees from marketplace
  - 10% of listing fees
  - 10% of referral fees
  - 10% of block rewards

**Discussion Points**:
- Is ODDAO a smart contract or off-chain entity?
- Membership requirements?
- Voting mechanism?
- Treasury management?
- Proposal system?
- Should it be a DAO token or stake-based voting?

## 5. Block Time - Achieved with Avalanche

**UPDATE**: Avalanche subnets natively support 1-2 second finality.

**Resolved**:
- Avalanche provides proven 1-2 second finality
- Handles 4,500+ TPS with ease
- Excellent geographic distribution support
- State growth managed through our simplification

**Archived**: This question is resolved by Avalanche adoption.

## 6. DEX Fee Structure

**Question**: What should the DEX fee structure be?

**Context from Design Doc**:
- DEX module mentioned but no fee structure specified
- Marketplace has 1% fee with complex distribution

**Discussion Points**:
- Standard swap fee (0.3% like Uniswap?)
- Should fees follow similar 70/20/10 split?
- Liquidity provider rewards?
- Fee tiers based on volume?
- Integration with XOM staking benefits?

## 7. Liquidity Mining Concerns

**Question**: How should liquidity mining be implemented to avoid mercenary capital?

**Context from Design Doc**:
- Concern about "liquidity locusts"
- Want sustainable liquidity

**Discussion Points**:
- Vesting schedules for LP rewards?
- Lock-up requirements?
- Reward reduction over time?
- Focus on XOM pairs only?
- Integration with staking tiers?
- Alternative incentive models (protocol-owned liquidity?)

## 8. Gas-Free Transaction Implementation

**Question**: How exactly should gas-free transactions work?

**Current Status**:
- Design doc states "no gas fees for users"
- Validators absorb computation costs

**Discussion Points**:
- Meta-transaction implementation?
- Validator compensation mechanism?
- Spam prevention without gas?
- Priority/ordering without gas prices?
- Integration with existing Ethereum tooling?

## 9. Block Rewards Distribution Details

**Question**: How should block rewards be distributed given the emission schedule?

**Context from Design Doc**:
- 10% to ODDAO
- Remainder split between validators and stakers
- No specific ratio given for validator/staker split

**Discussion Points**:
- Validator vs staker percentage?
- Distribution mechanism (per block vs epoch)?
- Relationship to PoP scores?
- Integration with duration bonuses?

## 10. Integration Points

**Question**: How should the bonus system integrate with other contracts?

**Current Implementation**:
- OmniBonusSystem created but not integrated
- Need triggers for:
  - User registration (welcome bonus)
  - First purchase by referee (referral bonus)
  - First sale (seller bonus)

**Discussion Points**:
- Where is user registration handled?
- Should marketplace directly call bonus system?
- Oracle-based vs direct integration?
- Gas considerations for bonus distribution?

## Next Steps

1. Review each question with the team
2. Document decisions in design specification
3. Update contracts based on decisions
4. Create integration plan for bonus system
5. Design meta-transaction system for gas-free usage

## 11. Avalanche Subnet Migration - APPROVED

**DECISION MADE**: We are migrating to Avalanche subnet for the public chain.

**Key Insight**: Privacy (PrivateOmniCoin) already runs separately on COTI and needs no changes.

**Approved Strategy**:
- Public chain moves to Avalanche subnet
- Privacy remains on COTI unchanged
- Bridge connects both systems
- 6-week parallel development with simplification
- Build validators for Avalanche from day 1

**Benefits Confirmed**:
- 1-2 second finality (vs 6 seconds)
- 4,500+ TPS capacity (vs ~1,000)
- Unlimited validators (vs restricted)
- XOM as native gas token
- Same development timeline (6 weeks)

## Notes

- Some design decisions may require prototyping to validate feasibility
- Consider phased implementation for complex features
- Ensure all decisions align with the core principle of user-friendly, fee-minimal design
- Avalanche migration would be a major architectural shift but offers significant benefits