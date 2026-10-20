// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Escrow} from "../interfaces/EscrowV2Types.sol";

/**
 * @title IFeeVaultMarketplaceDeposit
 * @notice Minimal interface to UnifiedFeeVault's referral-aware
 *         marketplace-fee deposit entry point
 * @dev The calling escrow must hold DEPOSITOR_ROLE on the vault and approve
 *      the vault for exactly 1% of `saleAmount` before calling.
 */
interface IFeeVaultMarketplaceDeposit {
    /**
     * @notice Deposit and distribute a 1% marketplace fee with attribution
     * @param token Fee token (the escrow's own token)
     * @param saleAmount Gross sale amount (vault pulls saleAmount / 100)
     * @param referrer Primary referrer (zero routes share to ODDAO)
     * @param referrerL2 Second-level referrer (zero routes share to ODDAO)
     * @param listingNode Listing node (zero routes share to ODDAO)
     * @param sellingNode Selling node (zero routes share to ODDAO)
     */
    function depositMarketplaceFee(
        address token,
        uint256 saleAmount,
        address referrer,
        address referrerL2,
        address listingNode,
        address sellingNode
    ) external;
}

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
 * @notice External library that performs EscrowV2's marketplace-fee routing
 *         and first-sale bonus bridge.
 * @dev Extracted from `EscrowV2` on 2026-10-20 to bring the contract under the
 *      24,576-byte EIP-170 limit (it was 27,290 bytes deployed). Solidity
 *      links `external` library functions via DELEGATECALL, so every function
 *      here executes inside the ESCROW's storage context: the mapping
 *      references passed in resolve to the escrow's slots, and the events
 *      emitted here are logged at the escrow's address with the exact same
 *      topics as before the move. The library declares no state variables.

 *      Behaviour is intended to be IDENTICAL to the code it replaces. Any
 *      change in this file is a money-path change and needs a full audit.
 */
/**
 * @title IFeeVaultTokenAllowlist
 * @notice The subset of UnifiedFeeVault's payment-token allowlist the escrow uses.
 */
interface IFeeVaultTokenAllowlist {
    function supportedPaymentTokens(address token) external view returns (bool);
}

library EscrowFeeRouter {
    using SafeERC20 for IERC20;

    /// @dev Mirrored from EscrowV2 — identical signatures, identical selectors,
    ///      so client-side error decoding is unchanged.
    error InvalidAddress();
    error TokenNotSupported();
    error AllowlistUnavailable();
    error CannotMixPrivacyModes();
    error BadAttribution();
    error BadReferrer();

    /// @notice Emitted when marketplace fee is collected on escrow release
    /// @param escrowId Escrow identifier
    /// @param feeCollector Address receiving the fee
    /// @param feeAmount Fee amount collected
    event MarketplaceFeeCollected(
        uint256 indexed escrowId,
        address indexed feeCollector,
        uint256 indexed feeAmount
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

    /// @notice Emitted when a fee transfer was refused and retained as surplus
    /// @param token Token that refused the transfer
    /// @param amount Amount left in the contract
    event FeeTransferDeferred(address indexed token, uint256 indexed amount);


    /// @notice Emitted when a marketplace fee transfer is waived. Settlement is
    ///         never blocked by fee routing; the protocol forgoes the fee
    ///         (which stays in the contract as surplus) rather than the sale.
    /// @param escrowId Escrow identifier
    /// @param token Escrow token whose fee could not be transferred
    /// @param feeAmount Fee that was waived (retained as protocol surplus)
    event MarketplaceFeeWaived(
        uint256 indexed escrowId,
        address indexed token,
        uint256 indexed feeAmount
    );

    /**
     * @notice Deduct the marketplace fee from a released escrow and route it to
     *         the fee vault, referral-aware when possible
     * @dev Prefers `UnifiedFeeVault.depositMarketplaceFee` so the canonical
     *      9-way split runs (referral / listing-node / selling-node slices).
     *      Falls back to a plain transfer to the vault when the call cannot
     *      succeed (no DEPOSITOR_ROLE, vault paused, sub-minimum sale), and
     *      waives the fee (keeping it as surplus) when the token itself
     *      refuses the transfer. A release is therefore never blocked by fee
     *      routing.
     * @param totalMarketplaceFees Running per-token total (escrow storage slot)
     * @param escrowId Escrow identifier (for referral lookup + events)
     * @param token Fee token — the escrow's own token
     * @param amount Gross escrow amount being released
     * @param feeBps Marketplace fee in basis points (pinned to 100 on chain)
     * @param feeVault UnifiedFeeVault address
     * @param referrer Primary referrer for this escrow (zero → ODDAO)
     * @param referrer2 Second-level referrer (zero → ODDAO)
     * @param listingNode Node that hosted the listing (zero → ODDAO)
     * @param sellingNode Node that served the sale (zero → ODDAO)
     * @return sellerAmount Net amount owed to the seller (amount - fee)
     */
    function collectMarketplaceFee(
        mapping(address => uint256) storage totalMarketplaceFees,
        uint256 escrowId,
        address token,
        uint256 amount,
        uint256 feeBps,
        address feeVault,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) external returns (uint256 sellerAmount) {
        uint256 feeAmount = (amount * feeBps) / 10_000;
        sellerAmount = amount - feeAmount;
        if (feeAmount == 0) {
            return sellerAmount;
        }

        IERC20 feeToken = IERC20(token);

        // Referral-aware vault split — only when the escrow fee matches the
        // vault's hardcoded 1% pull exactly (always true at the production
        // fee of 100 bps). The codeless-vault guard matters: a high-level call
        // to a codeless address reverts in the CALLER, outside try/catch's
        // reach (same gotcha as {recordFirstSale}), which would brick
        // releases instead of falling back.
        if (feeAmount == amount / 100 && feeVault.code.length != 0) {
            feeToken.forceApprove(feeVault, feeAmount);
            try
                IFeeVaultMarketplaceDeposit(feeVault).depositMarketplaceFee(
                    token,
                    amount,
                    referrer,
                    referrer2,
                    listingNode,
                    sellingNode
                )
            {
                totalMarketplaceFees[token] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, feeVault, feeAmount);
                return sellerAmount;
            } catch {
                // Clear the unconsumed allowance before falling back.
                feeToken.forceApprove(feeVault, 0);
            }
        }

        // Fallback: v1 behavior — full fee direct to the vault. If the token
        // itself refuses the transfer (paused token, blacklisted vault,
        // insufficient balance), the sale must still settle: waive the fee and
        // pay the seller their NET amount (the fee stays as surplus) rather
        // than freezing their principal.
        //
        // Low-level on purpose: SafeERC20's helper is an internal library call,
        // which Solidity cannot wrap in try/catch, and a reverting transfer here
        // would otherwise block the seller's payout. The return value is checked
        // exactly as SafeERC20 would (empty return = success for a contract).
        (bool ok, bytes memory ret) = address(feeToken).call(
            abi.encodeCall(IERC20.transfer, (feeVault, feeAmount))
        );
        // Empty returndata is success for a contract (SafeERC20's rule). A
        // non-32-byte return is NOT decoded — decoding it would revert and
        // block the release, which is the opposite of this branch's purpose.
        bool moved =
            ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
        if (!moved) {
            // The fee stays in the contract as surplus: the seller is paid the
            // NET amount, exactly as if the fee had been taken, and nothing is
            // recorded as collected. Paying the gross here would hand the
            // seller the protocol's 1%.
            emit MarketplaceFeeWaived(escrowId, token, feeAmount);
            return sellerAmount;
        }
        totalMarketplaceFees[token] += feeAmount;
        emit MarketplaceFeeCollected(escrowId, feeVault, feeAmount);
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
     *      via the pull-pattern claimable balance (arbitrators are arbitrary
     *      addresses — pull prevents transfer-revert griefing), remainder to
     *      the fee vault by direct best-effort transfer. Passing
     *      `arbitratorRecipient = address(0)` routes 100% to the vault (used
     *      by the OmniArbitration-driven resolution path, where the resolving
     *      panel is paid by OmniArbitration's own fee).
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
     * @param arbitratorRecipient Resolving arbitrator (zero → all to vault)
     * @param feeVault Fee vault address
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
        address feeVault
    ) external {
        uint256 arbitrationFee = (amount * feeBps) / 10_000;
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
        // that bucket (vault share exits the contract, arbitrator share
        // moves to totalClaimable).
        totalEscrowed[stakeToken] -= totalCollected;

        uint256 arbitratorShare = 0;
        if (arbitratorRecipient != address(0)) {
            arbitratorShare = (totalCollected * arbitratorShareBps) / 10_000;
        }
        // Vault gets the remainder (absorbs rounding dust)
        uint256 vaultShare = totalCollected - arbitratorShare;

        if (arbitratorShare > 0) {
            claimable[stakeToken][arbitratorRecipient] += arbitratorShare;
            totalClaimable[stakeToken] += arbitratorShare;
            emit FundsClaimable(
                arbitratorRecipient, stakeToken, arbitratorShare
            );
        }
        if (vaultShare > 0) {
            // Best-effort, like the marketplace fee: a token that refuses the
            // vault must not make the dispute unresolvable. The amount stays in
            // the contract as protocol surplus (recoverable by the admin).
            (bool ok, bytes memory ret) = address(stakeToken).call(
                abi.encodeCall(IERC20.transfer, (feeVault, vaultShare))
            );
            bool moved =
                ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
            if (!moved) {
                emit FeeTransferDeferred(stakeToken, vaultShare);
            }
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
     * @notice Reject a token the fee vault will not settle
     * @dev Single source of truth: the vault's own allowlist. A token must
     *      also have code — a plain address has no ERC-20 behaviour and every
     *      transfer against it would revert after the buyer had committed.
     * @param feeVault UnifiedFeeVault address (owns the allowlist)
     * @param token ERC-20 address supplied by the buyer
     * @param privateOmniCoin pXOM address (public escrows may not use it)
     * @param escrow Self address (a token pointing at the escrow is nonsense)
     */
    function requireSupportedToken(
        address feeVault,
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
        try IFeeVaultTokenAllowlist(feeVault).supportedPaymentTokens(token) returns (
            bool allowed
        ) {
            if (!allowed) revert TokenNotSupported();
        } catch {
            // The vault getter is unreachable (upgrade/rename/paused proxy).
            // Distinguish our outage from the seller's token choice.
            revert AllowlistUnavailable();
        }
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

    // ========================================================================
    // Read helpers
    // ========================================================================

    /**
     * @notice Read an escrow as a memory struct
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param escrowId Escrow identifier
     * @return The escrow record (zeroed when it does not exist)
     */
    function getEscrow(
        mapping(uint256 => Escrow) storage escrows,
        uint256 escrowId
    ) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    /**
     * @notice Read the buyer of an escrow
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param escrowId Escrow identifier
     * @return Buyer address (address(0) if the escrow does not exist)
     */
    function getBuyer(
        mapping(uint256 => Escrow) storage escrows,
        uint256 escrowId
    ) external view returns (address) {
        return escrows[escrowId].buyer;
    }

    /**
     * @notice Read the seller of an escrow
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param escrowId Escrow identifier
     * @return Seller address (address(0) if the escrow does not exist)
     */
    function getSeller(
        mapping(uint256 => Escrow) storage escrows,
        uint256 escrowId
    ) external view returns (address) {
        return escrows[escrowId].seller;
    }

    /**
     * @notice Read the ERC-20 an escrow holds
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param escrowId Escrow identifier
     * @return Token address (address(0) if the escrow does not exist)
     */
    function getToken(
        mapping(uint256 => Escrow) storage escrows,
        uint256 escrowId
    ) external view returns (address) {
        return escrows[escrowId].token;
    }

    /**
     * @notice Read the escrowed amount (the escrow token's smallest unit)
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param escrowId Escrow identifier
     * @return Amount (0 if absent, resolved, or a private escrow)
     */
    function getAmount(
        mapping(uint256 => Escrow) storage escrows,
        uint256 escrowId
    ) external view returns (uint256) {
        return escrows[escrowId].amount;
    }
}
