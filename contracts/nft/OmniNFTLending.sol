// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OmniNFTLending
 * @author OmniBazaar Development Team
 * @notice P2P NFT lending: lenders post offers, borrowers accept with NFT collateral.
 * @dev Uses escrow pattern — NFT held by contract during active loan, principal
 *      deposited by lender on offer creation and released to borrower on acceptance.
 *      Platform fee (10 % of interest) collected on repayment, split off-chain per
 *      OmniBazaar 70/20/10 model.
 */
contract OmniNFTLending is ERC721Holder, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Offer does not exist.
    error OfferNotFound();
    /// @dev Offer is not in the expected status.
    error OfferNotActive();
    /// @dev Loan does not exist.
    error LoanNotFound();
    /// @dev Loan is not in the expected status.
    error LoanNotActive();
    /// @dev Caller is not the lender for this offer.
    error NotLender();
    /// @dev Caller is not the borrower for this loan.
    error NotBorrower();
    /// @dev Collection is not accepted by this offer.
    error CollectionNotAccepted();
    /// @dev Loan is not yet past its due time.
    error LoanNotExpired();
    /// @dev Interest rate exceeds maximum (50 %).
    error InterestTooHigh();
    /// @dev Duration is zero or exceeds maximum (365 days).
    error InvalidDuration();
    /// @dev Principal is zero.
    error ZeroPrincipal();
    /// @dev No accepted collections provided.
    error NoCollections();
    /// @dev Platform fee basis points exceed maximum.
    error FeeTooHigh();

    // ── Events ───────────────────────────────────────────────────────────
    /// @notice Emitted when a lending offer is created.
    /// @param offerId Unique offer identifier.
    /// @param lender Address of the lender.
    /// @param principal Amount of currency offered.
    /// @param interestBps Annual interest in basis points.
    /// @param durationDays Loan duration in days.
    event OfferCreated(
        uint256 indexed offerId,
        address indexed lender,
        uint256 principal,
        uint16 interestBps,
        uint16 durationDays
    );

    /// @notice Emitted when a loan begins.
    /// @param loanId Unique loan identifier.
    /// @param offerId Associated offer.
    /// @param borrower Address of the borrower.
    /// @param collection NFT collection address.
    /// @param tokenId NFT token ID used as collateral.
    event LoanStarted(
        uint256 indexed loanId,
        uint256 indexed offerId,
        address indexed borrower,
        address collection,
        uint256 tokenId
    );

    /// @notice Emitted when a loan is repaid.
    /// @param loanId Loan that was repaid.
    /// @param borrower Address of the borrower.
    /// @param totalRepaid Principal plus interest.
    /// @param platformFee Fee collected by platform.
    event LoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 totalRepaid,
        uint256 platformFee
    );

    /// @notice Emitted when a defaulted loan is liquidated.
    /// @param loanId Loan that was liquidated.
    /// @param lender Lender who received the NFT.
    event LoanLiquidated(uint256 indexed loanId, address indexed lender);

    /// @notice Emitted when an offer is cancelled.
    /// @param offerId Cancelled offer.
    /// @param lender Lender who cancelled.
    event OfferCancelled(uint256 indexed offerId, address indexed lender);

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice 100 % in basis points.
    uint16 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum interest rate: 50 % (5000 bps).
    uint16 public constant MAX_INTEREST_BPS = 5000;
    /// @notice Maximum loan duration: 365 days.
    uint16 public constant MAX_DURATION_DAYS = 365;
    /// @notice Maximum platform fee: 20 % of interest (2000 bps).
    uint16 public constant MAX_PLATFORM_FEE_BPS = 2000;

    // ── Structs ──────────────────────────────────────────────────────────
    /// @notice On-chain lending offer.
    struct Offer {
        address lender;
        address currency;
        uint256 principal;
        uint16 interestBps;
        uint16 durationDays;
        bool active;
    }

    /// @notice Active loan backed by an NFT.
    struct Loan {
        uint256 offerId;
        address borrower;
        address lender;
        address collection;
        uint256 tokenId;
        address currency;
        uint256 principal;
        uint256 interest;
        uint64 startTime;
        uint64 dueTime;
        bool repaid;
        bool liquidated;
    }

    // ── Storage ──────────────────────────────────────────────────────────
    /// @notice Platform fee in basis points of interest (default 10 % = 1000 bps).
    uint16 public platformFeeBps;
    /// @notice Address receiving platform fees.
    address public feeRecipient;
    /// @notice Next offer ID.
    uint256 public nextOfferId;
    /// @notice Next loan ID.
    uint256 public nextLoanId;
    /// @notice Offer by ID.
    mapping(uint256 => Offer) public offers;
    /// @notice Accepted collections per offer (offerId => collection => accepted).
    mapping(uint256 => mapping(address => bool)) public offerCollections;
    /// @notice Loan by ID.
    mapping(uint256 => Loan) public loans;

    // ── Constructor ──────────────────────────────────────────────────────
    /**
     * @notice Deploy the lending contract.
     * @param initialFeeRecipient Address that receives platform fees.
     * @param initialFeeBps Platform fee in bps of interest (e.g. 1000 = 10 %).
     */
    constructor(
        address initialFeeRecipient,
        uint16 initialFeeBps
    ) Ownable(msg.sender) {
        if (initialFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        feeRecipient = initialFeeRecipient;
        platformFeeBps = initialFeeBps;
    }

    // ── External functions ───────────────────────────────────────────────

    /**
     * @notice Create a lending offer. Lender deposits principal into contract.
     * @param collections Accepted NFT collection addresses.
     * @param currency ERC-20 token used for the loan.
     * @param principal Loan amount in currency wei.
     * @param interestBps Interest rate in basis points.
     * @param durationDays Loan duration in days.
     * @return offerId The newly created offer ID.
     */
    function createOffer(
        address[] calldata collections,
        address currency,
        uint256 principal,
        uint16 interestBps,
        uint16 durationDays
    ) external nonReentrant returns (uint256 offerId) {
        if (collections.length == 0) revert NoCollections();
        if (principal == 0) revert ZeroPrincipal();
        if (interestBps > MAX_INTEREST_BPS) revert InterestTooHigh();
        if (durationDays == 0 || durationDays > MAX_DURATION_DAYS) {
            revert InvalidDuration();
        }

        offerId = nextOfferId++;

        offers[offerId] = Offer({
            lender: msg.sender,
            currency: currency,
            principal: principal,
            interestBps: interestBps,
            durationDays: durationDays,
            active: true
        });

        for (uint256 i = 0; i < collections.length; i++) {
            offerCollections[offerId][collections[i]] = true;
        }

        // Transfer principal from lender to contract
        IERC20(currency).safeTransferFrom(msg.sender, address(this), principal);

        emit OfferCreated(offerId, msg.sender, principal, interestBps, durationDays);
    }

    /**
     * @notice Accept an offer by providing an NFT as collateral.
     * @param offerId The offer to accept.
     * @param collection NFT collection address.
     * @param tokenId Token ID to use as collateral.
     * @return loanId The newly created loan ID.
     */
    function acceptOffer(
        uint256 offerId,
        address collection,
        uint256 tokenId
    ) external nonReentrant returns (uint256 loanId) {
        Offer storage offer = offers[offerId];
        if (offer.lender == address(0)) revert OfferNotFound();
        if (!offer.active) revert OfferNotActive();
        if (!offerCollections[offerId][collection]) {
            revert CollectionNotAccepted();
        }

        offer.active = false;

        uint256 interest = (offer.principal * offer.interestBps) /
            BPS_DENOMINATOR;
        uint64 dueTime = uint64(
            block.timestamp + (uint256(offer.durationDays) * 1 days)
        );

        loanId = nextLoanId++;

        loans[loanId] = Loan({
            offerId: offerId,
            borrower: msg.sender,
            lender: offer.lender,
            collection: collection,
            tokenId: tokenId,
            currency: offer.currency,
            principal: offer.principal,
            interest: interest,
            startTime: uint64(block.timestamp),
            dueTime: dueTime,
            repaid: false,
            liquidated: false
        });

        // Transfer NFT from borrower to contract
        IERC721(collection).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
        // Transfer principal from contract to borrower
        IERC20(offer.currency).safeTransfer(msg.sender, offer.principal);

        emit LoanStarted(loanId, offerId, msg.sender, collection, tokenId);
    }

    /**
     * @notice Repay a loan. Borrower pays principal + interest, gets NFT back.
     * @param loanId The loan to repay.
     */
    function repay(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.liquidated) revert LoanNotActive();
        if (msg.sender != loan.borrower) revert NotBorrower();

        loan.repaid = true;

        uint256 platformFee = (loan.interest * platformFeeBps) /
            BPS_DENOMINATOR;
        uint256 lenderAmount = loan.principal + loan.interest - platformFee;
        uint256 totalFromBorrower = loan.principal + loan.interest;

        // Borrower pays principal + interest
        IERC20(loan.currency).safeTransferFrom(
            msg.sender,
            address(this),
            totalFromBorrower
        );
        // Lender receives principal + interest - platform fee
        IERC20(loan.currency).safeTransfer(loan.lender, lenderAmount);
        // Platform fee to fee recipient
        if (platformFee > 0) {
            IERC20(loan.currency).safeTransfer(feeRecipient, platformFee);
        }
        // Return NFT to borrower
        IERC721(loan.collection).safeTransferFrom(
            address(this),
            msg.sender,
            loan.tokenId
        );

        emit LoanRepaid(loanId, msg.sender, totalFromBorrower, platformFee);
    }

    /**
     * @notice Liquidate a defaulted loan. Lender claims the NFT.
     * @param loanId The loan to liquidate.
     */
    function liquidate(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.liquidated) revert LoanNotActive();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < loan.dueTime) revert LoanNotExpired();
        if (msg.sender != loan.lender) revert NotLender();

        loan.liquidated = true;

        // Transfer NFT to lender
        IERC721(loan.collection).safeTransferFrom(
            address(this),
            loan.lender,
            loan.tokenId
        );

        emit LoanLiquidated(loanId, loan.lender);
    }

    /**
     * @notice Cancel an unfilled offer. Lender gets principal back.
     * @param offerId The offer to cancel.
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.lender == address(0)) revert OfferNotFound();
        if (!offer.active) revert OfferNotActive();
        if (msg.sender != offer.lender) revert NotLender();

        offer.active = false;

        IERC20(offer.currency).safeTransfer(msg.sender, offer.principal);

        emit OfferCancelled(offerId, msg.sender);
    }

    // ── Admin functions ──────────────────────────────────────────────────

    /**
     * @notice Update the platform fee percentage.
     * @param newFeeBps New fee in basis points of interest.
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = newFeeBps;
    }

    /**
     * @notice Update the fee recipient address.
     * @param newRecipient New fee recipient.
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
    }

    // ── View functions ───────────────────────────────────────────────────

    /**
     * @notice Get full offer details.
     * @param offerId The offer to query.
     * @return lender Lender address.
     * @return currency Currency address.
     * @return principal Loan amount.
     * @return interestBps Interest in bps.
     * @return durationDays Duration.
     * @return active Whether the offer is active.
     */
    function getOffer(uint256 offerId)
        external
        view
        returns (
            address lender,
            address currency,
            uint256 principal,
            uint16 interestBps,
            uint16 durationDays,
            bool active
        )
    {
        Offer storage o = offers[offerId];
        return (
            o.lender,
            o.currency,
            o.principal,
            o.interestBps,
            o.durationDays,
            o.active
        );
    }

    /**
     * @notice Check if a collection is accepted by an offer.
     * @param offerId The offer to check.
     * @param collection The collection address.
     * @return accepted True if collection is accepted.
     */
    function isCollectionAccepted(
        uint256 offerId,
        address collection
    ) external view returns (bool accepted) {
        return offerCollections[offerId][collection];
    }

    /**
     * @notice Get full loan details.
     * @param loanId The loan to query.
     * @return borrower Borrower address.
     * @return lender Lender address.
     * @return collection NFT collection.
     * @return tokenId Token ID.
     * @return principal Principal amount.
     * @return interest Interest amount.
     * @return dueTime Loan due timestamp.
     * @return repaid Whether the loan is repaid.
     * @return liquidated Whether the loan is liquidated.
     */
    function getLoan(uint256 loanId)
        external
        view
        returns (
            address borrower,
            address lender,
            address collection,
            uint256 tokenId,
            uint256 principal,
            uint256 interest,
            uint64 dueTime,
            bool repaid,
            bool liquidated
        )
    {
        Loan storage l = loans[loanId];
        return (
            l.borrower,
            l.lender,
            l.collection,
            l.tokenId,
            l.principal,
            l.interest,
            l.dueTime,
            l.repaid,
            l.liquidated
        );
    }
}
