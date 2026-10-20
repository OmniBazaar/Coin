// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64} from "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {Escrow, FeeAttribution, FeeBeneficiaries} from "../interfaces/EscrowV2Types.sol";
import {EscrowFeeRouter} from "./EscrowFeeRouter.sol";

/**
 * @title EscrowPrivacyOps
 * @author OmniCoin Development Team
 * @notice External library that performs EscrowV2's PRIVATE (pXOM) escrow
 *         creation, release and refund.
 * @dev Extracted from `EscrowV2` on 2026-10-20 together with the fee-routing
 *      library, to bring the contract under the 24,576-byte EIP-170 limit.
 *      Solidity links `external` library functions via DELEGATECALL, so every
 *      function here executes inside the ESCROW's storage context: the mapping
 *      references passed in resolve to the escrow's slots and the events are
 *      logged at the escrow's address with the same topics as before.
 *
 *      The library declares no state variables. `Escrow` is the shared
 *      {EscrowV2Types.Escrow} type, so the storage layout is the escrow's own.
 *
 *      Behaviour is intended to be IDENTICAL to the code it replaces. Any
 *      change here is a money-path change and needs a full audit.
 *
 *      The dispute vote + resolution half of the private path stays in
 *      `EscrowV2` because it shares the arbitration-fee and stake-return logic
 *      with the public path; only the three entry points below moved.
 */
library EscrowPrivacyOps {
    using SafeERC20 for IERC20;

    /// @dev Mirrored from EscrowV2 — identical signatures, identical selectors,
    ///      so client-side error decoding is unchanged.
    error InvalidAddress();
    error InvalidAmount();
    error TokenTransferMismatch();
    error InvalidDuration();
    error CannotMixPrivacyModes();
    error EscrowNotFound();
    error AlreadyResolved();
    error NotParticipant();

    event EscrowToken(uint256 indexed escrowId, address indexed token);
    event PrivateEscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 expiry
    );
    event PrivateEscrowResolved(uint256 indexed escrowId, address indexed recipient);
    event MarketplaceFeeSplit(
        uint256 indexed escrowId,
        address indexed token,
        uint256 feeAmount
    );
    event FundsClaimable(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    /**
     * @notice Open a private (pXOM) escrow whose amount stays encrypted
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param encryptedAmounts escrowId => ciphertext (escrow storage slot)
     * @param plainAmounts escrowId => internal plaintext (escrow storage slot)
     * @param isPrivate escrowId => private flag (escrow storage slot)
     * @param totalEscrowed token => active principal (escrow storage slot)
     * @param pXom Private OmniCoin (pXOM) token
     * @param minAmount Smallest escrow amount that still yields a fee
     * @param buyer Payer (already resolved from _msgSender by the escrow)
     * @param seller Counterparty
     * @param encryptedAmount MPC-encrypted escrow amount
     * @param duration Escrow lifetime in seconds
     * @param minDuration Minimum escrow lifetime (escrow's MIN_DURATION)
     * @param maxDuration Maximum escrow lifetime (escrow's MAX_DURATION)
     * @param escrowId Identifier already allocated by the escrow
     */
    function createEscrow(
        mapping(uint256 => Escrow) storage escrows,
        mapping(uint256 => ctUint64) storage encryptedAmounts,
        mapping(uint256 => uint256) storage plainAmounts,
        mapping(uint256 => bool) storage isPrivate,
        mapping(address => uint256) storage totalEscrowed,
        address pXom,
        uint256 minAmount,
        address buyer,
        address seller,
        gtUint64 encryptedAmount,
        uint256 duration,
        uint256 minDuration,
        uint256 maxDuration,
        uint256 escrowId
    ) external {
        if (seller == address(0) || seller == buyer) revert InvalidAddress();
        if (duration < minDuration || duration > maxDuration) revert InvalidDuration();

        // Decrypt amount for the token transfer (the pull needs a plain value)
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert InvalidAmount();

        if (seller == address(this)) revert InvalidAddress();
        if (uint256(plainAmount) < minAmount) revert InvalidAmount();

        // Transfer pXOM from the buyer to the escrow, requiring the exact delta
        // (a fee-on-transfer pXOM would otherwise make the escrow insolvent).
        IERC20 token = IERC20(pXom);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(buyer, address(this), uint256(plainAmount));
        if (token.balanceOf(address(this)) - before != uint256(plainAmount)) {
            revert TokenTransferMismatch();
        }
        totalEscrowed[pXom] += uint256(plainAmount);

        encryptedAmounts[escrowId] = MpcCore.offBoard(encryptedAmount);
        isPrivate[escrowId] = true;
        plainAmounts[escrowId] = uint256(plainAmount);

        uint256 expiry = block.timestamp + duration; // solhint-disable-line not-rely-on-time
        escrows[escrowId] = Escrow({
            buyer: buyer,
            seller: seller,
            arbitrator: address(0),
            amount: 0, // PRIV-H03: amount hidden for privacy; see getEncryptedAmount
            expiry: expiry,
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            releaseVotes: 0,
            refundVotes: 0,
            resolved: false,
            disputed: false,
            delivered: false,
            inspectionDeadline: 0,
            token: pXom,
            listingNode: address(0),
            sellingNode: address(0)
        });

        emit EscrowToken(escrowId, pXom);
        emit PrivateEscrowCreated(escrowId, buyer, seller, expiry);
    }

    /**
     * @notice Release a private escrow to the seller on the buyer's agreement
     * @dev Takes the 1% marketplace fee in pXOM and credits the seller through
     *      the pull-pattern claimable balance.
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param plainAmounts escrowId => internal plaintext (escrow storage slot)
     * @param totalEscrowed token => active principal (escrow storage slot)
     * @param totalMarketplaceFees token => fee total (escrow storage slot)
     * @param claimable token => user => claimable (escrow storage slot)
     * @param totalClaimable token => claimable total (escrow storage slot)
     * @param pXom Private OmniCoin (pXOM) token
     * @param feeBps Marketplace fee in basis points
     * @param beneficiaries ODDAO / staking / treasury on this chain
     * @param escrowId Private escrow to release
     * @param caller Address that called the escrow (already resolved)
     */
    function releaseFunds(
        mapping(uint256 => Escrow) storage escrows,
        mapping(uint256 => uint256) storage plainAmounts,
        mapping(address => uint256) storage totalEscrowed,
        mapping(address => uint256) storage totalMarketplaceFees,
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalClaimable,
        address pXom,
        uint256 feeBps,
        FeeBeneficiaries memory beneficiaries,
        uint256 escrowId,
        address caller
    ) external {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        // Simple 2-party agreement (buyer releases to seller)
        if (!escrow.disputed && caller == escrow.buyer) {
            escrow.resolved = true;
            // PRIV-H03: Read from the private mapping instead of escrow.amount
            uint256 amount = plainAmounts[escrowId];
            plainAmounts[escrowId] = 0;

            totalEscrowed[pXom] -= amount;

            // Deduct the marketplace fee before paying the seller. V4: the
            // fee is split in kind on THIS chain (nine pull-pattern credits),
            // never transferred to a cross-chain vault.
            uint256 feeAmount = (amount * feeBps) / 10_000;
            uint256 sellerAmount = amount - feeAmount;

            if (feeAmount > 0) {
                EscrowFeeRouter.splitInKind(
                    claimable,
                    totalClaimable,
                    totalMarketplaceFees,
                    escrowId,
                    pXom,
                    feeAmount,
                    FeeAttribution(address(0), address(0), address(0), address(0)),
                    beneficiaries
                );
            }
            // M-02 (Round 6): pull pattern for private escrow release
            claimable[pXom][escrow.seller] += sellerAmount;
            totalClaimable[pXom] += sellerAmount;
            emit FundsClaimable(escrow.seller, pXom, sellerAmount);
            emit PrivateEscrowResolved(escrowId, escrow.seller);
        }
    }

    /**
     * @notice Refund a private escrow to the buyer
     * @dev The seller may agree at any time; the buyer may claim after expiry,
     *      gated on the seller's dispute window and on not-delivered.
     * @param escrows escrowId => Escrow (escrow storage slot)
     * @param plainAmounts escrowId => internal plaintext (escrow storage slot)
     * @param totalEscrowed token => active principal (escrow storage slot)
     * @param claimable token => user => claimable (escrow storage slot)
     * @param totalClaimable token => claimable total (escrow storage slot)
     * @param pXom Private OmniCoin (pXOM) token
     * @param arbitratorDelay Delay before an unclaimed refund is allowed
     * @param escrowId Private escrow to refund
     * @param caller Address that called the escrow (already resolved)
     */
    function refundBuyer(
        mapping(uint256 => Escrow) storage escrows,
        mapping(uint256 => uint256) storage plainAmounts,
        mapping(address => uint256) storage totalEscrowed,
        mapping(address => mapping(address => uint256)) storage claimable,
        mapping(address => uint256) storage totalClaimable,
        address pXom,
        uint256 arbitratorDelay,
        uint256 escrowId,
        address caller
    ) external {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // M-04: only buyer or seller may trigger a refund (no third-party grief)
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        bool canRefund = false;

        // The seller agrees to refund.
        if (caller == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and undisputed: only the buyer may claim, and only once the
        // seller's dispute window has opened (so a sub-ARBITRATOR_DELAY
        // duration cannot let the buyer reclaim before the seller can commit a
        // dispute), and never after delivery (the buyer must then use
        // releaseFunds or open a dispute). See EscrowV2.refundBuyer.
        // solhint-disable-next-line not-rely-on-time
        if (
            caller == escrow.buyer &&
            !escrow.disputed &&
            !escrow.delivered &&
            block.timestamp > escrow.expiry &&
            block.timestamp >= escrow.createdAt + arbitratorDelay
        ) {
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            // PRIV-H03: Read from the private mapping instead of escrow.amount
            uint256 amount = plainAmounts[escrowId];
            plainAmounts[escrowId] = 0;

            totalEscrowed[pXom] -= amount;
            // M-02 (Round 6): pull pattern for private escrow refund
            claimable[pXom][escrow.buyer] += amount;
            totalClaimable[pXom] += amount;
            emit FundsClaimable(escrow.buyer, pXom, amount);
            emit PrivateEscrowResolved(escrowId, escrow.buyer);
        }
    }
}
