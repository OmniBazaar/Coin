// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeAttribution, FeeBeneficiaries} from "../interfaces/EscrowV2Types.sol";

/**
 * @title IFirstSaleRegistry
 * @notice The subset of OmniRegistration the escrow's first-sale bridge uses.
 * @dev Declared here (rather than imported) so the library depends on nothing
 *      but OpenZeppelin and ABI-compatible shapes.
 */
interface IFirstSaleRegistry {
    function hasCompletedFirstSale(address seller) external view returns (bool);

    function markFirstSaleCompleted(
        address seller,
        uint256 saleAmount,
        address buyer
    ) external;
}

/**
 * @title EscrowFeeRouter
 * @author OmniCoin Development Team
 * @notice External library that performs EscrowV2's per-chain marketplace-fee
 *         split and first-sale bonus bridge.
 * @dev Extracted from `EscrowV2` on 2026-10-20 to bring the contract under the
 *      24,576-byte EIP-170 limit (it was 27,290 bytes deployed). Solidity
 *      links `external` library functions via DELEGATECALL, so every function
 *      here executes inside the ESCROW's storage context: the mapping
 *      references passed in resolve to the escrow's slots, and the events
 *      emitted here are logged at the escrow's address. The library declares
 *      no state variables.

 *      DECOUPLED FROM THE FEE VAULT (2026-10-20, founder decision 3): the
 *      escrow now pays the whole 1% IN KIND, ON ITS OWN CHAIN, in the token it
 *      holds. There is no cross-chain `UnifiedFeeVault` call and no vault
 *      allowlist read; the nine slices land in the escrow's own pull-pattern
 *      `claimable` ledger (referrer, referrer2, listing node, selling node,
 *      ODDAO, staking pool, treasury). Every payment is a credit, never a
 *      transfer, so a token that blacklists or refuses a recipient can never
 *      block a release. Any change in this file is a money-path change and
 *      needs a full audit.
 */
library EscrowFeeRouter {
    /// @dev Mirrored from EscrowV2 — identical signatures, identical selectors,
    ///      so client-side error decoding is unchanged.
    error InvalidAddress();
    error TokenNotSupported();
    error CannotMixPrivacyModes();
    error BadAttribution();
    error BadReferrer();

    /// @notice Emitted when the marketplace fee is split in kind on release
    /// @param escrowId Escrow identifier
    /// @param token Token the fee was taken in (the escrow's own token)
    /// @param feeAmount Total fee split across the nine slices
    event MarketplaceFeeSplit(
        uint256 indexed escrowId,
        address indexed token,
        uint256 feeAmount
    );

    /// @notice Emitted when funds are credited to pull-based claimable balance
    /// @param user Address receiving the claimable credit
    /// @param token Token address credited
    /// @param amount Amount credited
    event FundsClaimable(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when dispute stake is returned
    /// @param escrowId Escrow identifier
    /// @param disputer Address receiving stake back
    /// @param amount Stake amount returned
    event DisputeStakeReturned(
        uint256 indexed escrowId,
        address indexed disputer,
        uint256 indexed amount
    );

    /// @notice Emitted when arbitration fee is deducted from a dispute
    /// @param escrowId Escrow identifier
    /// @param totalArbitrationFee Total arbitration fee collected
    /// @param arbitratorShare Amount credited to the resolving arbitrator
    event ArbitrationFeeCollected(
        uint256 indexed escrowId,
        uint256 totalArbitrationFee,
        uint256 arbitratorShare
    );

    /// @notice Basis-points denominator
    uint256 internal constant BPS = 10_000;

    /// @notice 70% slice (ODDAO of each component, primary of each pair)
    uint256 internal constant PRIMARY_BPS = 7_000;

    /// @notice 20% slice (secondary of each pair)
    uint256 internal constant SECONDARY_BPS = 2_000;

    /**
     * @notice Deduct the marketplace fee from a released escrow and split it
     *         in kind across the nine canonical recipients
     * @dev Canonical schedule (founder-ruled 2026-06-12), each component split
     *      70/20/10 with the 10% remainder and any rounding dust to ODDAO:
     *        transaction 25% of the fee → ODDAO / staking / treasury
     *        referral    50% of the fee → referrer / referrer2 / ODDAO
     *        listing     25% of the fee → listing node / selling node / ODDAO
     *      (the referral and listing 10% remainders are ODDAO's; the
     *      transaction 10% remainder is the protocol treasury's)
     *      A zero attribution address routes its slice to ODDAO. Slices are
     *      credited to the escrow's pull-pattern `claimable` ledger, so no
     *      recipient can block settlement and no token transfer is attempted
     *      here (the escrow already holds the fee).
     * @param claimable token => user => credited amount (escrow storage slot)
     * @param totalClaimable token => credited total (escrow storage slot)
     * @param totalMarketplaceFees token => lifetime fee total (escrow slot)
     * @param escrowId Escrow identifier (for events)
     * @param token Fee token — the escrow's own token
     * @param amount Gross escrow amount being released
     * @param feeBps Marketplace fee in basis points (pinned to 100 on chain)
     * @param attribution Referrers + nodes recorded for this escrow
     * @param beneficiaries ODDAO / staking / treasury addresses on this chain
     * @return sellerAmount Net amount owed to the seller (amount - fee)
     */
    function collectMarketplaceFee(
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalClaimable,
        mapping(address => uint256) storage totalMarketplaceFees,
        uint256 escrowId,
        address token,
        uint256 amount,
        uint256 feeBps,
        FeeAttribution memory attribution,
        FeeBeneficiaries memory beneficiaries
    ) external returns (uint256 sellerAmount) {
        uint256 feeAmount = (amount * feeBps) / BPS;
        sellerAmount = amount - feeAmount;
        if (feeAmount == 0) {
            return sellerAmount;
        }
        splitInKind(
            claimable,
            totalClaimable,
            totalMarketplaceFees,
            escrowId,
            token,
            feeAmount,
            attribution,
            beneficiaries
        );
    }

    /**
     * @notice Credit the nine canonical slices of an already-computed fee
     * @dev Shared by the public release path and the private (pXOM) release
     *      path, which lives in {EscrowPrivacyOps}. `internal`, so each caller
     *      inlines it — no extra linking hop.
     * @param claimable token => user => credited amount (escrow storage slot)
     * @param totalClaimable token => credited total (escrow storage slot)
     * @param totalMarketplaceFees token => lifetime fee total (escrow slot)
     * @param escrowId Escrow identifier (for events)
     * @param token Fee token
     * @param feeAmount The 1% fee to split (already computed, non-zero)
     * @param attribution Referrers + nodes recorded for this escrow
     * @param beneficiaries ODDAO / staking / treasury addresses on this chain
     */
    function splitInKind(
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalClaimable,
        mapping(address => uint256) storage totalMarketplaceFees,
        uint256 escrowId,
        address token,
        uint256 feeAmount,
        FeeAttribution memory attribution,
        FeeBeneficiaries memory beneficiaries
    ) internal {
        // Split 1 — transaction 25% of the fee: ODDAO / staking / treasury.
        uint256 txFee = feeAmount / 4;
        uint256 txOddao = (txFee * PRIMARY_BPS) / BPS;
        uint256 txStaking = (txFee * SECONDARY_BPS) / BPS;
        _credit(
            claimable, totalClaimable, token, beneficiaries.oddao, txOddao
        );
        _credit(
            claimable, totalClaimable, token, beneficiaries.stakingPool, txStaking
        );
        // Remainder (10% + dust) to the protocol treasury.
        _credit(
            claimable,
            totalClaimable,
            token,
            beneficiaries.treasury,
            txFee - txOddao - txStaking
        );

        // Split 2 — referral 50% of the fee: referrer / referrer2 / ODDAO.
        uint256 refFee = feeAmount / 2;
        uint256 refPrimary = (refFee * PRIMARY_BPS) / BPS;
        uint256 refSecondary = (refFee * SECONDARY_BPS) / BPS;
        _credit(
            claimable,
            totalClaimable,
            token,
            _or(attribution.referrer, beneficiaries.oddao),
            refPrimary
        );
        _credit(
            claimable,
            totalClaimable,
            token,
            _or(attribution.referrer2, beneficiaries.oddao),
            refSecondary
        );
        _credit(
            claimable,
            totalClaimable,
            token,
            beneficiaries.oddao,
            refFee - refPrimary - refSecondary
        );

        // Split 3 — listing 25% of the fee (remainder): node / node / ODDAO.
        uint256 listFee = feeAmount - txFee - refFee;
        uint256 listNode = (listFee * PRIMARY_BPS) / BPS;
        uint256 sellNode = (listFee * SECONDARY_BPS) / BPS;
        _credit(
            claimable,
            totalClaimable,
            token,
            _or(attribution.listingNode, beneficiaries.oddao),
            listNode
        );
        _credit(
            claimable,
            totalClaimable,
            token,
            _or(attribution.sellingNode, beneficiaries.oddao),
            sellNode
        );
        _credit(
            claimable,
            totalClaimable,
            token,
            beneficiaries.oddao,
            listFee - listNode - sellNode
        );

        totalMarketplaceFees[token] += feeAmount;
        emit MarketplaceFeeSplit(escrowId, token, feeAmount);
    }

    /**
     * @notice Best-effort, contract-to-contract bridge into OmniRegistration
     *         that records the seller's first completed sale
     * @dev `markFirstSaleCompleted` enforces anti-Sybil rules (minimum sale
     *      amount, account age, referrer divergence) and REVERTS for
     *      non-qualifying sales — which must never roll back a settled escrow —
     *      so both the eligibility read and the record call are wrapped in
     *      try/catch and skipped once the seller has a first sale on record.
     * @param registry OmniRegistration address
     * @param omniCoin XOM token address (the bonus is XOM-denominated)
     * @param seller The seller who just received escrow funds
     * @param token The escrow's settlement token
     * @param saleAmount The gross sale amount
     * @param buyer The buyer in this escrow
     */
    function recordFirstSale(
        address registry,
        address omniCoin,
        address seller,
        address token,
        uint256 saleAmount,
        address buyer
    ) external {
        // The bonus is denominated in XOM and the registry's anti-Sybil
        // minimum is an XOM figure. A sale in any other token carries its own
        // decimals (USDC is 6), so forwarding raw units would be read as a
        // near-zero XOM sale: sometimes silently ineligible, sometimes
        // mispriced. Record XOM sales only; other-token sales simply do not
        // earn the XOM-denominated bonus.
        if (token != omniCoin) {
            return;
        }
        // A high-level call to a codeless address reverts outside try/catch's
        // reach, so guard it.
        if (registry.code.length == 0) {
            return;
        }
        // solhint-disable-next-line no-empty-blocks
        try IFirstSaleRegistry(registry).hasCompletedFirstSale(seller) returns (
            bool alreadyDone
        ) {
            if (alreadyDone) {
                return;
            }
            // solhint-disable-next-line no-empty-blocks
            try
                IFirstSaleRegistry(registry).markFirstSaleCompleted(
                    seller,
                    saleAmount,
                    buyer
                )
            {
                // Recorded.
            } catch {
                // Non-qualifying sale (anti-Sybil) or recorder not authorized.
                // Never block settlement on the bonus side-effect.
            }
        } catch {
            // Registry view unavailable — ignore; settlement already succeeded.
        }
    }

    /**
     * @notice Deduct and distribute the arbitration fee from dispute stakes
     *         (charged 50/50 buyer/seller, capped at each stake)
     * @dev Distribution: `arbitratorShareBps` (70%) to `arbitratorRecipient`
     *      via the pull-pattern claimable balance, remainder to ODDAO by the
     *      same ledger (no token transfer, so no token can block a resolution).
     *      Passing `arbitratorRecipient = address(0)` routes 100% to ODDAO
     *      (used by the OmniArbitration-driven resolution path, where the
     *      resolving panel is paid by OmniArbitration's own fee).
     * @param disputeStakes escrowId => party => stake (escrow storage slot)
     * @param claimable token => user => amount (escrow storage slot)
     * @param totalEscrowed token => active principal (escrow storage slot)
     * @param totalClaimable token => claimable total (escrow storage slot)
     * @param escrowId Escrow identifier
     * @param stakeToken Token the stakes are denominated in
     * @param buyer Escrow buyer (first stake holder)
     * @param seller Escrow seller (second stake holder)
     * @param amount Disputed escrow principal the fee is computed on
     * @param feeBps Arbitration fee in basis points (500 = 5%)
     * @param arbitratorShareBps Share of the fee paid to the arbitrator (7000)
     * @param arbitratorRecipient Resolving arbitrator (zero → all to ODDAO)
     * @param oddao ODDAO address on this chain (receives the remainder)
     */
    function collectArbitrationFee(
        mapping(uint256 => mapping(address => uint256))
            storage disputeStakes,
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalEscrowed,
        mapping(address => uint256) storage totalClaimable,
        uint256 escrowId,
        address stakeToken,
        address buyer,
        address seller,
        uint256 amount,
        uint256 feeBps,
        uint256 arbitratorShareBps,
        address arbitratorRecipient,
        address oddao
    ) external {
        uint256 arbitrationFee = (amount * feeBps) / BPS;
        // Each party pays half from their dispute stake
        uint256 halfFee = arbitrationFee / 2;
        uint256 otherHalf = arbitrationFee - halfFee; // handles rounding

        // Deduct from buyer stake (capped at posted stake)
        uint256 buyerStake = disputeStakes[escrowId][buyer];
        uint256 buyerDeduction = halfFee > buyerStake ? buyerStake : halfFee;
        disputeStakes[escrowId][buyer] = buyerStake - buyerDeduction;

        // Deduct from seller stake (capped at posted stake)
        uint256 sellerStake = disputeStakes[escrowId][seller];
        uint256 sellerDeduction = otherHalf > sellerStake ? sellerStake : otherHalf;
        disputeStakes[escrowId][seller] = sellerStake - sellerDeduction;

        uint256 totalCollected = buyerDeduction + sellerDeduction;
        if (totalCollected == 0) {
            return;
        }

        // Stakes were counted in totalEscrowed; the collected fee leaves
        // that bucket and becomes claimable (arbitrator share) or ODDAO's.
        totalEscrowed[stakeToken] -= totalCollected;

        uint256 arbitratorShare = 0;
        if (arbitratorRecipient != address(0)) {
            arbitratorShare = (totalCollected * arbitratorShareBps) / BPS;
        }
        // ODDAO gets the remainder (absorbs rounding dust)
        uint256 oddaoShare = totalCollected - arbitratorShare;

        if (arbitratorShare > 0) {
            claimable[stakeToken][arbitratorRecipient] += arbitratorShare;
            totalClaimable[stakeToken] += arbitratorShare;
            emit FundsClaimable(
                arbitratorRecipient, stakeToken, arbitratorShare
            );
        }
        if (oddaoShare > 0) {
            claimable[stakeToken][oddao] += oddaoShare;
            totalClaimable[stakeToken] += oddaoShare;
            emit FundsClaimable(oddao, stakeToken, oddaoShare);
        }

        emit ArbitrationFeeCollected(escrowId, totalCollected, arbitratorShare);
    }

    /**
     * @notice Return a dispute stake to the pull-pattern claimable balance
     * @dev No-op when the party posted nothing.
     * @param disputeStakes escrowId => party => stake (escrow storage slot)
     * @param claimable token => user => amount (escrow storage slot)
     * @param totalEscrowed token => active principal (escrow storage slot)
     * @param totalClaimable token => claimable total (escrow storage slot)
     * @param escrowId Escrow identifier
     * @param stakeToken Token the stake is denominated in
     * @param party Buyer or seller
     */
    function returnDisputeStake(
        mapping(uint256 => mapping(address => uint256))
            storage disputeStakes,
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalEscrowed,
        mapping(address => uint256) storage totalClaimable,
        uint256 escrowId,
        address stakeToken,
        address party
    ) external {
        uint256 stakeAmount = disputeStakes[escrowId][party];
        if (stakeAmount > 0) {
            disputeStakes[escrowId][party] = 0;
            // M-01: Use pull pattern for stake returns
            totalEscrowed[stakeToken] -= stakeAmount;
            claimable[stakeToken][party] += stakeAmount;
            totalClaimable[stakeToken] += stakeAmount;
            emit FundsClaimable(party, stakeToken, stakeAmount);
            emit DisputeStakeReturned(escrowId, party, stakeAmount);
        }
    }

    /**
     * @notice Reject a token this chain's escrow will not settle
     * @dev Single source of truth is now the escrow's OWN allowlist (admin-set
     *      per chain, founder decision 3): a chain cannot read another chain's
     *      vault. The token must also have code — a plain address has no
     *      ERC-20 behaviour and every transfer against it would revert after
     *      the buyer had committed.
     * @param supported token => allowed (escrow storage slot)
     * @param token ERC-20 address supplied by the buyer
     * @param privateOmniCoin pXOM address (public escrows may not use it)
     * @param escrow Self address (a token pointing at the escrow is nonsense)
     */
    function requireSupportedToken(
        mapping(address => bool) storage supported,
        address token,
        address privateOmniCoin,
        address escrow
    ) external view returns (bool) {
        if (token == address(0) || token.code.length == 0) {
            revert InvalidAddress();
        }
        // pXOM enters only through the private create path, where the amount is
        // MPC-encrypted. A PUBLIC escrow of shielded coin would publish its
        // amount in EscrowCreated.
        if (token == privateOmniCoin || token == escrow) {
            revert CannotMixPrivacyModes();
        }
        if (!supported[token]) revert TokenNotSupported();
        return true;
    }

    /**
     * @notice Validate the fee-attribution nodes against the parties
     * @dev A node may not be the buyer, the seller, a referrer, or the other
     *      node (same anti-fee-wash rule as the referrer pair). Zero is
     *      allowed — the share routes to ODDAO.
     */
    function validateAttributionNodes(
        address buyer,
        address seller,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) external pure returns (bool) {
        if (listingNode != address(0)) {
            if (
                listingNode == buyer ||
                listingNode == seller ||
                listingNode == referrer ||
                listingNode == referrer2 ||
                listingNode == sellingNode
            ) {
                revert BadAttribution();
            }
        }
        if (sellingNode != address(0)) {
            if (
                sellingNode == buyer ||
                sellingNode == seller ||
                sellingNode == referrer ||
                sellingNode == referrer2
            ) {
                revert BadAttribution();
            }
        }
        return true;
    }

    /**
     * @notice Anti-fee-wash validation of the two referrer slots
     * @dev A non-zero referrer must not equal buyer or seller; a non-zero
     *      referrer2 must not equal buyer, seller, or referrer. Zero addresses
     *      are always allowed (their share routes to ODDAO at release).
     */
    function validateReferrerPair(
        address buyer,
        address seller,
        address referrer,
        address referrer2
    ) external pure returns (bool) {
        if (referrer != address(0)) {
            if (referrer == buyer || referrer == seller) revert BadReferrer();
        }
        if (referrer2 != address(0)) {
            if (
                referrer2 == buyer ||
                referrer2 == seller ||
                referrer2 == referrer
            ) {
                revert BadReferrer();
            }
        }
        return true;
    }

    /**
     * @notice Credit one fee slice to the pull-pattern ledger
     * @dev Zero slices are skipped so a tiny fee does not emit empty credits;
     *      the parent split's remainder slice absorbs the difference, keeping
     *      the credited total equal to the fee.
     */
    function _credit(
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalClaimable,
        address token,
        address user,
        uint256 amount
    ) private {
        if (amount == 0) {
            return;
        }
        claimable[token][user] += amount;
        totalClaimable[token] += amount;
        emit FundsClaimable(user, token, amount);
    }

    /**
     * @notice Resolve a zero attribution slot to the protocol sink
     */
    function _or(address recipient, address fallback_) private pure returns (address) {
        return recipient == address(0) ? fallback_ : recipient;
    }
}
