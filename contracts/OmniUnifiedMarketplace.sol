// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {IUnifiedNFTMarketplace} from "./interfaces/IUnifiedNFTMarketplace.sol";

/**
 * @title OmniUnifiedMarketplace
 * @author OmniBazaar Team
 * @notice Unified marketplace supporting both ERC-721 and ERC-1155 tokens
 * @dev Handles all NFT standards with dual-token payment support
 * 
 * Key Features:
 * - Unified interface for ERC-721 and ERC-1155
 * - Batch purchases for ERC-1155
 * - Dual-token support (XOM/pXOM)
 * - Escrow integration
 * - Fee management
 */
contract OmniUnifiedMarketplace is 
    IUnifiedNFTMarketplace,
    ReentrancyGuard,
    Pausable,
    AccessControl,
    RegistryAware,
    IERC721Receiver,
    IERC1155Receiver
{
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for marketplace operators
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /// @notice Marketplace fee in basis points (2.5%)
    uint256 public constant MARKETPLACE_FEE_BPS = 250;
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Counter for listing IDs
    uint256 private _listingIdCounter;
    
    /// @notice All marketplace listings
    mapping(uint256 => UnifiedListing) public listings;
    
    /// @notice Track NFTs in escrow (contract => tokenId => amount)
    mapping(address => mapping(uint256 => uint256)) public escrowedERC1155;
    
    /// @notice Accumulated fees per payment token
    mapping(address => uint256) public accumulatedFees;
    
    /// @notice Allowed NFT contracts
    mapping(address => bool) public allowedContracts;
    
    /// @notice User purchase limits (anti-bot)
    mapping(address => mapping(uint256 => uint256)) public userPurchases;
    
    // =============================================================================
    // EVENTS (Additional to interface)
    // =============================================================================
    
    event FeeCollected(
        uint256 indexed listingId,
        address indexed paymentToken,
        uint256 indexed feeAmount
    );
    
    event EscrowDeposited(
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint256 indexed amount
    );
    
    event ContractAllowlistUpdated(
        address indexed tokenContract,
        bool indexed allowed
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidTokenStandard();
    error InvalidTokenContract();
    error InvalidAmount();
    error InvalidPrice();
    error InsufficientBalance();
    error ListingNotActive();
    error UnauthorizedSeller();
    error PaymentFailed();
    error TransferFailed();
    error ExceedsAvailableAmount();
    error ContractNotAllowed();
    error ExceedsPurchaseLimit();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAllowedContract(address tokenContract) {
        if (!allowedContracts[tokenContract]) revert ContractNotAllowed();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(address _registry) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }
    
    // =============================================================================
    // LISTING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a unified listing for any NFT standard
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function createUnifiedListing(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        bool usePrivacy,
        ListingType listingType,
        uint256 duration
    ) 
        external 
        override 
        whenNotPaused 
        onlyAllowedContract(tokenContract)
        returns (uint256 listingId) 
    {
        if (pricePerUnit == 0) revert InvalidPrice();
        if (duration == 0) revert InvalidAmount();
        
        // Validate ownership and amount
        if (standard == TokenStandard.ERC721) {
            if (amount != 1) revert InvalidAmount();
            if (IERC721(tokenContract).ownerOf(tokenId) != msg.sender) {
                revert UnauthorizedSeller();
            }
            // Transfer to marketplace
            IERC721(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId);
        } else if (standard == TokenStandard.ERC1155) {
            if (amount == 0) revert InvalidAmount();
            uint256 balance = IERC1155(tokenContract).balanceOf(msg.sender, tokenId);
            if (balance < amount) revert InsufficientBalance();
            // Transfer to marketplace
            IERC1155(tokenContract).safeTransferFrom(
                msg.sender, 
                address(this), 
                tokenId, 
                amount, 
                ""
            );
            escrowedERC1155[tokenContract][tokenId] += amount;
        } else {
            revert InvalidTokenStandard();
        }
        
        // Create listing
        listingId = _listingIdCounter++;
        
        address paymentToken = usePrivacy ?
            _getContract(registry.PRIVATE_OMNICOIN()) :
            _getContract(registry.OMNICOIN());
        
        listings[listingId] = UnifiedListing({
            listingId: listingId,
            standard: standard,
            tokenContract: tokenContract,
            tokenId: tokenId,
            amount: amount,
            pricePerUnit: pricePerUnit,
            totalPrice: pricePerUnit * amount,
            seller: msg.sender,
            paymentToken: paymentToken,
            usePrivacy: usePrivacy,
            listingType: listingType,
            status: ListingStatus.ACTIVE,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            escrowEnabled: true,
            metadataURI: ""
        });
        
        emit UnifiedListingCreated(
            listingId,
            standard,
            tokenContract,
            tokenId,
            amount,
            pricePerUnit
        );
        
        emit EscrowDeposited(tokenContract, tokenId, amount);
    }
    
    /**
     * @notice Purchase from a unified listing
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function purchaseUnified(PurchaseParams calldata params) 
        external 
        payable 
        override 
        nonReentrant 
        whenNotPaused 
    {
        UnifiedListing storage listing = listings[params.listingId];
        
        // Validate listing
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (block.timestamp > listing.endTime) {
            listing.status = ListingStatus.EXPIRED;
            revert ListingNotActive();
        }
        if (params.amount == 0 || params.amount > listing.amount) {
            revert ExceedsAvailableAmount();
        }
        
        // Anti-bot check
        userPurchases[msg.sender][params.listingId] += params.amount;
        if (userPurchases[msg.sender][params.listingId] > 10) {
            revert ExceedsPurchaseLimit();
        }
        
        // Calculate payment
        uint256 totalPayment = listing.pricePerUnit * params.amount;
        uint256 marketplaceFee = (totalPayment * MARKETPLACE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 sellerPayment = totalPayment - marketplaceFee;
        
        // Process payment
        IERC20 paymentToken = IERC20(listing.paymentToken);
        if (!paymentToken.transferFrom(msg.sender, address(this), totalPayment)) {
            revert PaymentFailed();
        }
        
        // Distribute payments
        if (!paymentToken.transfer(listing.seller, sellerPayment)) {
            revert PaymentFailed();
        }
        
        accumulatedFees[listing.paymentToken] += marketplaceFee;
        
        // Transfer NFT(s)
        if (listing.standard == TokenStandard.ERC721) {
            IERC721(listing.tokenContract).safeTransferFrom(
                address(this),
                msg.sender,
                listing.tokenId
            );
            listing.amount = 0;
            listing.status = ListingStatus.SOLD;
        } else {
            IERC1155(listing.tokenContract).safeTransferFrom(
                address(this),
                msg.sender,
                listing.tokenId,
                params.amount,
                ""
            );
            listing.amount -= params.amount;
            escrowedERC1155[listing.tokenContract][listing.tokenId] -= params.amount;
            
            if (listing.amount == 0) {
                listing.status = ListingStatus.SOLD;
            }
        }
        
        emit UnifiedPurchase(
            params.listingId,
            msg.sender,
            params.amount,
            totalPayment
        );
        
        emit FeeCollected(
            params.listingId,
            listing.paymentToken,
            marketplaceFee
        );
    }
    
    /**
     * @notice Update listing price or amount
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function updateListing(
        uint256 listingId,
        uint256 newPricePerUnit,
        uint256 additionalAmount
    ) external override {
        UnifiedListing storage listing = listings[listingId];
        
        if (listing.seller != msg.sender) revert UnauthorizedSeller();
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        
        if (newPricePerUnit > 0) {
            listing.pricePerUnit = newPricePerUnit;
            listing.totalPrice = newPricePerUnit * listing.amount;
        }
        
        if (additionalAmount > 0 && listing.standard == TokenStandard.ERC1155) {
            // Transfer additional tokens
            IERC1155(listing.tokenContract).safeTransferFrom(
                msg.sender,
                address(this),
                listing.tokenId,
                additionalAmount,
                ""
            );
            listing.amount += additionalAmount;
            listing.totalPrice = listing.pricePerUnit * listing.amount;
            escrowedERC1155[listing.tokenContract][listing.tokenId] += additionalAmount;
            
            emit EscrowDeposited(listing.tokenContract, listing.tokenId, additionalAmount);
        }
        
        emit ListingUpdated(listingId, listing.pricePerUnit, listing.amount);
    }
    
    /**
     * @notice Cancel a listing
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function cancelListing(uint256 listingId) external override nonReentrant {
        UnifiedListing storage listing = listings[listingId];
        
        if (listing.seller != msg.sender && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedSeller();
        }
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        
        listing.status = ListingStatus.CANCELLED;
        
        // Return NFT(s) to seller
        if (listing.standard == TokenStandard.ERC721) {
            IERC721(listing.tokenContract).safeTransferFrom(
                address(this),
                listing.seller,
                listing.tokenId
            );
        } else {
            IERC1155(listing.tokenContract).safeTransferFrom(
                address(this),
                listing.seller,
                listing.tokenId,
                listing.amount,
                ""
            );
            escrowedERC1155[listing.tokenContract][listing.tokenId] -= listing.amount;
        }
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get listing details
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function getListing(uint256 listingId) 
        external 
        view 
        override 
        returns (UnifiedListing memory) 
    {
        return listings[listingId];
    }
    
    /**
     * @notice Check if a listing is still available
     * @inheritdoc IUnifiedNFTMarketplace
     */
    function isAvailable(uint256 listingId, uint256 amount) 
        external 
        view 
        override 
        returns (bool) 
    {
        UnifiedListing storage listing = listings[listingId];
        return listing.status == ListingStatus.ACTIVE && 
               listing.amount >= amount &&
               block.timestamp <= listing.endTime;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update contract allowlist
     * @param tokenContract Contract to update
     * @param allowed Whether to allow the contract
     */
    function updateContractAllowlist(address tokenContract, bool allowed) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        allowedContracts[tokenContract] = allowed;
        emit ContractAllowlistUpdated(tokenContract, allowed);
    }
    
    /**
     * @notice Withdraw accumulated fees
     * @param paymentToken Token to withdraw fees for
     */
    function withdrawFees(address paymentToken) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 amount = accumulatedFees[paymentToken];
        if (amount == 0) revert InvalidAmount();
        
        accumulatedFees[paymentToken] = 0;
        
        address treasury = _getContract(registry.OMNIBAZAAR_TREASURY());
        if (!IERC20(paymentToken).transfer(treasury, amount)) {
            revert TransferFailed();
        }
    }
    
    /**
     * @notice Pause marketplace operations
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause marketplace operations
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // RECEIVER FUNCTIONS
    // =============================================================================
    
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl, IERC165) 
        returns (bool) 
    {
        return 
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}