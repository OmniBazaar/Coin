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
    
    /// @notice Marketplace fee in basis points (1%)
    uint256 public constant MARKETPLACE_FEE_BPS = 100;
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // Fee split configuration (basis points)
    /// @notice Transaction fee portion (0.5% of total 1%)
    uint256 public constant TRANSACTION_FEE_BPS = 50;
    /// @notice Referral fee portion (0.25% of total 1%)
    uint256 public constant REFERRAL_FEE_BPS = 25;
    /// @notice Listing fee portion (0.25% of total 1%)
    uint256 public constant LISTING_FEE_BPS = 25;
    
    // Transaction fee splits (70/20/10)
    uint256 public constant TRANSACTION_ODDAO_SHARE = 7000;
    uint256 public constant TRANSACTION_VALIDATOR_SHARE = 2000;
    uint256 public constant TRANSACTION_STAKING_SHARE = 1000;
    
    // Referral fee splits (70/20/10)
    uint256 public constant REFERRAL_REFERRER_SHARE = 7000;
    uint256 public constant REFERRAL_PARENT_SHARE = 2000;
    uint256 public constant REFERRAL_ODDAO_SHARE = 1000;
    
    // Listing fee splits (70/20/10)
    uint256 public constant LISTING_NODE_SHARE = 7000;
    uint256 public constant LISTING_SELLING_NODE_SHARE = 2000;
    uint256 public constant LISTING_ODDAO_SHARE = 1000;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Counter for listing IDs
    uint256 private _listingIdCounter;
    
    /// @notice All marketplace listings
    mapping(uint256 => UnifiedListing) public listings;
    
    /// @notice Track NFTs in escrow (contract => tokenId => amount)
    mapping(address => mapping(uint256 => uint256)) public escrowedERC1155;
    
    /// @notice Accumulated fees per payment token (deprecated - kept for compatibility)
    mapping(address => uint256) public accumulatedFees;
    
    /// @notice Accumulated fees for ODDAO per payment token
    mapping(address => uint256) public oddaoFees;
    
    /// @notice Accumulated fees for validators per payment token
    mapping(address => uint256) public validatorFees;
    
    /// @notice Accumulated fees for staking pool per payment token
    mapping(address => uint256) public stakingPoolFees;
    
    /// @notice Accumulated fees for referrers (address => token => amount)
    mapping(address => mapping(address => uint256)) public referrerFees;
    
    /// @notice Accumulated fees for listing nodes (address => token => amount)
    mapping(address => mapping(address => uint256)) public listingNodeFees;
    
    /// @notice Accumulated fees for selling nodes (address => token => amount)
    mapping(address => mapping(address => uint256)) public sellingNodeFees;
    
    /// @notice Allowed NFT contracts
    mapping(address => bool) public allowedContracts;
    
    /// @notice User purchase limits (anti-bot)
    mapping(address => mapping(uint256 => uint256)) public userPurchases;
    
    /// @notice Referrer for each listing (listingId => referrer address)
    mapping(uint256 => address) public listingReferrers;
    
    /// @notice Parent referrer for each user (user => parent referrer)
    mapping(address => address) public userReferrers;
    
    /// @notice Listing node for each listing (listingId => node address)
    mapping(uint256 => address) public listingNodes;
    
    /// @notice Selling node for each listing (listingId => node address)
    mapping(uint256 => address) public sellingNodes;
    
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
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) :
            _getContract(REGISTRY.OMNICOIN());
        
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
        
        // Distribute marketplace fees
        _distributeFees(
            params.listingId,
            listing.paymentToken,
            marketplaceFee,
            msg.sender
        );
        
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
        
        address treasury = _getContract(REGISTRY.OMNIBAZAAR_TREASURY());
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
    
    /**
     * @notice Set referrer for a listing
     * @param listingId The listing ID
     * @param referrer The referrer address
     */
    function setListingReferrer(uint256 listingId, address referrer) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        listingReferrers[listingId] = referrer;
    }
    
    /**
     * @notice Set user's parent referrer
     * @param user The user address
     * @param parentReferrer The parent referrer address
     */
    function setUserReferrer(address user, address parentReferrer) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        userReferrers[user] = parentReferrer;
    }
    
    /**
     * @notice Set listing and selling nodes for a listing
     * @param listingId The listing ID
     * @param listingNode The listing node address
     * @param sellingNode The selling node address
     */
    function setListingNodes(
        uint256 listingId, 
        address listingNode, 
        address sellingNode
    ) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        listingNodes[listingId] = listingNode;
        sellingNodes[listingId] = sellingNode;
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
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Distribute marketplace fees according to the fee split configuration
     * @param listingId The listing ID for tracking purposes
     * @param paymentToken The token used for payment
     * @param totalFee The total marketplace fee (1% of transaction)
     * @param buyer The buyer address (for referrer tracking)
     */
    function _distributeFees(
        uint256 listingId,
        address paymentToken,
        uint256 totalFee,
        address buyer
    ) internal {
        // Calculate individual fee components
        uint256 transactionFee = (totalFee * TRANSACTION_FEE_BPS) / MARKETPLACE_FEE_BPS;
        uint256 referralFee = (totalFee * REFERRAL_FEE_BPS) / MARKETPLACE_FEE_BPS;
        uint256 listingFee = (totalFee * LISTING_FEE_BPS) / MARKETPLACE_FEE_BPS;
        
        // Distribute transaction fee (0.5%): 70/20/10 (ODDAO/Validator/Staking Pool)
        uint256 oddaoTransactionShare = (transactionFee * TRANSACTION_ODDAO_SHARE) / BPS_DENOMINATOR;
        uint256 validatorTransactionShare = (transactionFee * TRANSACTION_VALIDATOR_SHARE) / BPS_DENOMINATOR;
        uint256 stakingTransactionShare = transactionFee - oddaoTransactionShare - validatorTransactionShare;
        
        oddaoFees[paymentToken] += oddaoTransactionShare;
        validatorFees[paymentToken] += validatorTransactionShare;
        stakingPoolFees[paymentToken] += stakingTransactionShare;
        
        // Distribute referral fee (0.25%): 70/20/10 (Referrer/Parent Referrer/ODDAO)
        address referrer = listingReferrers[listingId];
        if (referrer == address(0)) {
            referrer = userReferrers[buyer];
        }
        
        if (referrer != address(0)) {
            uint256 referrerShare = (referralFee * REFERRAL_REFERRER_SHARE) / BPS_DENOMINATOR;
            uint256 parentReferrerShare = (referralFee * REFERRAL_PARENT_SHARE) / BPS_DENOMINATOR;
            uint256 oddaoReferralShare = referralFee - referrerShare - parentReferrerShare;
            
            referrerFees[referrer][paymentToken] += referrerShare;
            
            address parentReferrer = userReferrers[referrer];
            if (parentReferrer != address(0)) {
                referrerFees[parentReferrer][paymentToken] += parentReferrerShare;
            } else {
                oddaoFees[paymentToken] += parentReferrerShare;
            }
            
            oddaoFees[paymentToken] += oddaoReferralShare;
        } else {
            // No referrer - all referral fees go to ODDAO
            oddaoFees[paymentToken] += referralFee;
        }
        
        // Distribute listing fee (0.25%): 70/20/10 (Listing Node/Selling Node/ODDAO)
        address listingNode = listingNodes[listingId];
        address sellingNode = sellingNodes[listingId];
        
        if (listingNode != address(0)) {
            uint256 listingNodeShare = (listingFee * LISTING_NODE_SHARE) / BPS_DENOMINATOR;
            uint256 sellingNodeShare = (listingFee * LISTING_SELLING_NODE_SHARE) / BPS_DENOMINATOR;
            uint256 oddaoListingShare = listingFee - listingNodeShare - sellingNodeShare;
            
            listingNodeFees[listingNode][paymentToken] += listingNodeShare;
            
            if (sellingNode != address(0)) {
                sellingNodeFees[sellingNode][paymentToken] += sellingNodeShare;
            } else {
                oddaoFees[paymentToken] += sellingNodeShare;
            }
            
            oddaoFees[paymentToken] += oddaoListingShare;
        } else {
            // No listing node - all listing fees go to ODDAO
            oddaoFees[paymentToken] += listingFee;
        }
        
        emit FeeCollected(listingId, paymentToken, totalFee);
    }
    
    /**
     * @notice Withdraw specific fee type
     * @param paymentToken Token to withdraw
     * @param feeType Type of fee to withdraw (0=ODDAO, 1=Validator, 2=Staking, 3=Referrer, 4=ListingNode, 5=SellingNode)
     * @param recipient Recipient address (for referrer/node fees)
     */
    function withdrawSpecificFees(
        address paymentToken,
        uint8 feeType,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount;
        
        if (feeType == 0) {
            // ODDAO fees
            amount = oddaoFees[paymentToken];
            if (amount > 0) {
                oddaoFees[paymentToken] = 0;
                address oddaoTreasury = _getContract(REGISTRY.ODDAO_TREASURY());
                IERC20(paymentToken).transfer(oddaoTreasury, amount);
            }
        } else if (feeType == 1) {
            // Validator fees
            amount = validatorFees[paymentToken];
            if (amount > 0) {
                validatorFees[paymentToken] = 0;
                address validatorPool = _getContract(REGISTRY.VALIDATOR_POOL());
                IERC20(paymentToken).transfer(validatorPool, amount);
            }
        } else if (feeType == 2) {
            // Staking pool fees
            amount = stakingPoolFees[paymentToken];
            if (amount > 0) {
                stakingPoolFees[paymentToken] = 0;
                address stakingPool = _getContract(REGISTRY.STAKING_POOL());
                IERC20(paymentToken).transfer(stakingPool, amount);
            }
        } else if (feeType == 3 && recipient != address(0)) {
            // Referrer fees
            amount = referrerFees[recipient][paymentToken];
            if (amount > 0) {
                referrerFees[recipient][paymentToken] = 0;
                IERC20(paymentToken).transfer(recipient, amount);
            }
        } else if (feeType == 4 && recipient != address(0)) {
            // Listing node fees
            amount = listingNodeFees[recipient][paymentToken];
            if (amount > 0) {
                listingNodeFees[recipient][paymentToken] = 0;
                IERC20(paymentToken).transfer(recipient, amount);
            }
        } else if (feeType == 5 && recipient != address(0)) {
            // Selling node fees
            amount = sellingNodeFees[recipient][paymentToken];
            if (amount > 0) {
                sellingNodeFees[recipient][paymentToken] = 0;
                IERC20(paymentToken).transfer(recipient, amount);
            }
        }
    }
}