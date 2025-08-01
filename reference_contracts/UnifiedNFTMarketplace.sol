// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title UnifiedNFTMarketplace
 * @author OmniCoin Development Team
 * @notice Consolidated NFT marketplace with minimal on-chain state
 * @dev Combines functionality from:
 * - ListingNFT (marketplace listings as NFTs)
 * - OmniNFTMarketplace (trading functionality)
 * - OmniERC1155 (multi-token support)
 * 
 * Uses event-based architecture for transaction history
 * Merkle tree verification for off-chain data
 */
contract UnifiedNFTMarketplace is 
    ERC721,
    ERC721URIStorage,
    AccessControl, 
    ReentrancyGuard, 
    Pausable, 
    RegistryAware 
{
    using SafeERC20 for IERC20;
    
    // =============================================================================
    // TYPES & CONSTANTS
    // =============================================================================
    
    enum ListingStatus {
        ACTIVE,
        SOLD,
        CANCELLED,
        EXPIRED
    }
    
    enum ListingType {
        PRODUCT,
        SERVICE,
        DIGITAL,
        SUBSCRIPTION
    }
    
    struct MinimalListing {
        uint256 price;
        address seller;
        ListingStatus status;
        ListingType listingType;
        bool acceptsPrivacy;
        uint32 expirationTime;
    }
    
    // Fee constants (basis points)
    uint256 public constant MARKETPLACE_FEE = 100; // 1%
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x for privacy
    uint256 public constant BASIS_POINTS = 10000;
    
    // Listing constraints
    uint256 public constant MIN_PRICE = 1e6; // 1 XOM (6 decimals)
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant DEFAULT_DURATION = 30 days;
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    
    // =============================================================================
    // STATE (Minimal)
    // =============================================================================
    
    // Next token ID
    uint256 private _nextTokenId;
    
    // Active listings only (required for trading)
    mapping(uint256 => MinimalListing) public listings;
    
    // Merkle roots for off-chain data
    bytes32 public listingMetadataRoot;
    bytes32 public transactionHistoryRoot;
    bytes32 public userActivityRoot;
    uint256 public lastRootUpdate;
    uint256 public currentEpoch;
    
    // Fee recipients
    address public treasuryAddress;
    address public validatorPoolAddress;
    address public liquidityPoolAddress;
    
    // Configuration
    bool public isMpcAvailable;
    string private _baseTokenURI;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    // Listing Events
    event ListingCreated(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        ListingType listingType,
        string metadataHash,
        uint256 timestamp
    );
    
    event ListingUpdated(
        uint256 indexed tokenId,
        uint256 newPrice,
        uint32 newExpiration,
        uint256 timestamp
    );
    
    event ListingCancelled(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 timestamp
    );
    
    event ListingExpired(
        uint256 indexed tokenId,
        uint256 timestamp
    );
    
    // Trading Events
    event ListingSold(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 feeAmount,
        bool usePrivacy,
        uint256 timestamp
    );
    
    event OfferMade(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerAmount,
        uint256 expiration,
        uint256 timestamp
    );
    
    event OfferAccepted(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 acceptedAmount,
        uint256 timestamp
    );
    
    event OfferRejected(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 timestamp
    );
    
    // Root Update Events
    event ListingRootUpdated(
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    event TransactionRootUpdated(
        bytes32 indexed newRoot,
        uint256 totalTransactions,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidPrice();
    error InvalidDuration();
    error ListingNotActive();
    error NotListingOwner();
    error InsufficientPayment();
    error TransferFailed();
    error NotAvalancheValidator();
    error ListingExpiredError();
    error CannotBuyOwnListing();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        require(
            hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) ||
            _isAvalancheValidator(msg.sender),
            "Only Avalanche validators"
        );
        _;
    }
    
    modifier validListing(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "Listing does not exist");
        require(listings[tokenId].status == ListingStatus.ACTIVE, "Listing not active");
        require(
            listings[tokenId].expirationTime == 0 || 
            block.timestamp < listings[tokenId].expirationTime,
            "Listing expired"
        );
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _admin,
        address _registry,
        address _treasury,
        address _validatorPool,
        address _liquidityPool
    ) 
        ERC721("OmniBazaar Listing", "OMNI")
        RegistryAware(_registry) 
    {
        require(_admin != address(0), "Invalid admin");
        require(_treasury != address(0), "Invalid treasury");
        require(_validatorPool != address(0), "Invalid validator pool");
        require(_liquidityPool != address(0), "Invalid liquidity pool");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MODERATOR_ROLE, _admin);
        _grantRole(URI_SETTER_ROLE, _admin);
        
        treasuryAddress = _treasury;
        validatorPoolAddress = _validatorPool;
        liquidityPoolAddress = _liquidityPool;
        
        _nextTokenId = 1; // Start at 1
        isMpcAvailable = false; // Default for testing
    }
    
    // =============================================================================
    // LISTING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create new listing
     * @dev Mints NFT and emits event for validator indexing
     */
    function createListing(
        uint256 price,
        ListingType listingType,
        string calldata metadataURI,
        string calldata metadataHash,
        uint256 duration,
        bool acceptsPrivacy
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        if (price < MIN_PRICE) revert InvalidPrice();
        if (duration > MAX_DURATION) revert InvalidDuration();
        
        tokenId = _nextTokenId++;
        uint32 expiration = duration > 0 ? 
            uint32(block.timestamp + duration) : 
            uint32(block.timestamp + DEFAULT_DURATION);
        
        // Mint NFT to seller
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, metadataURI);
        
        // Store minimal listing data
        listings[tokenId] = MinimalListing({
            price: price,
            seller: msg.sender,
            status: ListingStatus.ACTIVE,
            listingType: listingType,
            acceptsPrivacy: acceptsPrivacy,
            expirationTime: expiration
        });
        
        emit ListingCreated(
            tokenId,
            msg.sender,
            price,
            listingType,
            metadataHash,
            block.timestamp
        );
    }
    
    /**
     * @notice Update listing price or duration
     */
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        uint256 extensionDuration
    ) external nonReentrant whenNotPaused validListing(tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not listing owner");
        if (newPrice > 0 && newPrice < MIN_PRICE) revert InvalidPrice();
        
        MinimalListing storage listing = listings[tokenId];
        
        if (newPrice > 0) {
            listing.price = newPrice;
        }
        
        if (extensionDuration > 0) {
            require(extensionDuration <= MAX_DURATION, "Extension too long");
            listing.expirationTime = uint32(block.timestamp + extensionDuration);
        }
        
        emit ListingUpdated(
            tokenId,
            listing.price,
            listing.expirationTime,
            block.timestamp
        );
    }
    
    /**
     * @notice Cancel listing
     */
    function cancelListing(uint256 tokenId) 
        external 
        nonReentrant 
        whenNotPaused 
        validListing(tokenId) 
    {
        require(ownerOf(tokenId) == msg.sender, "Not listing owner");
        
        listings[tokenId].status = ListingStatus.CANCELLED;
        
        emit ListingCancelled(tokenId, msg.sender, block.timestamp);
    }
    
    // =============================================================================
    // TRADING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Buy listing
     * @dev Handles payment, fees, and NFT transfer
     */
    function buyListing(
        uint256 tokenId,
        bool usePrivacy
    ) external nonReentrant whenNotPaused validListing(tokenId) {
        MinimalListing storage listing = listings[tokenId];
        address seller = ownerOf(tokenId);
        
        require(seller != msg.sender, "Cannot buy own listing");
        require(!usePrivacy || listing.acceptsPrivacy, "Privacy not accepted");
        
        uint256 price = listing.price;
        uint256 feeAmount = _calculateFee(price, usePrivacy);
        uint256 totalAmount = price + feeAmount;
        
        // Transfer payment
        IERC20 token = IERC20(_getToken(usePrivacy));
        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        
        // Distribute fees
        _distributeFees(feeAmount, usePrivacy, token);
        
        // Pay seller
        token.safeTransfer(seller, price);
        
        // Transfer NFT
        _safeTransfer(seller, msg.sender, tokenId, "");
        
        // Update listing status
        listing.status = ListingStatus.SOLD;
        
        emit ListingSold(
            tokenId,
            msg.sender,
            seller,
            price,
            feeAmount,
            usePrivacy,
            block.timestamp
        );
    }
    
    /**
     * @notice Make offer on listing
     * @dev Only emits event, actual offer storage off-chain
     */
    function makeOffer(
        uint256 tokenId,
        uint256 offerAmount,
        uint256 expiration
    ) external nonReentrant whenNotPaused validListing(tokenId) {
        require(offerAmount >= MIN_PRICE, "Offer too low");
        require(ownerOf(tokenId) != msg.sender, "Cannot offer on own listing");
        
        emit OfferMade(
            tokenId,
            msg.sender,
            offerAmount,
            expiration,
            block.timestamp
        );
    }
    
    /**
     * @notice Accept offer (seller only)
     * @dev Requires merkle proof of valid offer
     */
    function acceptOffer(
        uint256 tokenId,
        address buyer,
        uint256 offerAmount,
        bool usePrivacy,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused validListing(tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not listing owner");
        
        // Verify offer via merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, buyer, offerAmount, currentEpoch));
        require(_verifyProof(proof, transactionHistoryRoot, leaf), "Invalid offer proof");
        
        MinimalListing storage listing = listings[tokenId];
        uint256 feeAmount = _calculateFee(offerAmount, usePrivacy);
        uint256 totalAmount = offerAmount + feeAmount;
        
        // Transfer payment
        IERC20 token = IERC20(_getToken(usePrivacy));
        token.safeTransferFrom(buyer, address(this), totalAmount);
        
        // Distribute fees
        _distributeFees(feeAmount, usePrivacy, token);
        
        // Pay seller
        token.safeTransfer(msg.sender, offerAmount);
        
        // Transfer NFT
        _safeTransfer(msg.sender, buyer, tokenId, "");
        
        // Update listing status
        listing.status = ListingStatus.SOLD;
        
        emit OfferAccepted(tokenId, buyer, offerAmount, block.timestamp);
        emit ListingSold(
            tokenId,
            buyer,
            msg.sender,
            offerAmount,
            feeAmount,
            usePrivacy,
            block.timestamp
        );
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES
    // =============================================================================
    
    /**
     * @notice Update listing metadata root
     */
    function updateListingRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        require(epoch == currentEpoch + 1, "Invalid epoch");
        
        listingMetadataRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit ListingRootUpdated(newRoot, epoch, block.number, block.timestamp);
    }
    
    /**
     * @notice Update transaction history root
     */
    function updateTransactionRoot(
        bytes32 newRoot,
        uint256 totalTransactions
    ) external onlyAvalancheValidator {
        transactionHistoryRoot = newRoot;
        emit TransactionRootUpdated(newRoot, totalTransactions, block.timestamp);
    }
    
    /**
     * @notice Update user activity root
     */
    function updateUserActivityRoot(bytes32 newRoot) external onlyAvalancheValidator {
        userActivityRoot = newRoot;
    }
    
    // =============================================================================
    // VERIFICATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify listing metadata
     */
    function verifyListingMetadata(
        uint256 tokenId,
        string calldata metadataHash,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, metadataHash, currentEpoch));
        return _verifyProof(proof, listingMetadataRoot, leaf);
    }
    
    /**
     * @notice Verify transaction history
     */
    function verifyTransaction(
        uint256 tokenId,
        address buyer,
        uint256 price,
        uint256 blockNumber,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, buyer, price, blockNumber));
        return _verifyProof(proof, transactionHistoryRoot, leaf);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get listing details
     */
    function getListing(uint256 tokenId) external view returns (
        uint256 price,
        address seller,
        ListingStatus status,
        ListingType listingType,
        bool acceptsPrivacy,
        uint32 expirationTime,
        bool isExpired
    ) {
        MinimalListing storage listing = listings[tokenId];
        bool expired = listing.expirationTime > 0 && block.timestamp >= listing.expirationTime;
        
        return (
            listing.price,
            listing.seller,
            expired ? ListingStatus.EXPIRED : listing.status,
            listing.listingType,
            listing.acceptsPrivacy,
            listing.expirationTime,
            expired
        );
    }
    
    /**
     * @notice Calculate total cost including fees
     */
    function calculateTotalCost(
        uint256 tokenId,
        bool usePrivacy
    ) external view validListing(tokenId) returns (uint256 total, uint256 fee) {
        uint256 price = listings[tokenId].price;
        fee = _calculateFee(price, usePrivacy);
        total = price + fee;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update fee recipients
     */
    function updateFeeRecipients(
        address _treasury,
        address _validatorPool,
        address _liquidityPool
    ) external onlyRole(ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        require(_validatorPool != address(0), "Invalid validator pool");
        require(_liquidityPool != address(0), "Invalid liquidity pool");
        
        treasuryAddress = _treasury;
        validatorPoolAddress = _validatorPool;
        liquidityPoolAddress = _liquidityPool;
    }
    
    /**
     * @notice Set base URI for token metadata
     */
    function setBaseURI(string calldata baseURI) external onlyRole(URI_SETTER_ROLE) {
        _baseTokenURI = baseURI;
    }
    
    /**
     * @notice Set MPC availability
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Remove expired listings (moderator function)
     */
    function cleanupExpiredListing(uint256 tokenId) external onlyRole(MODERATOR_ROLE) {
        MinimalListing storage listing = listings[tokenId];
        require(
            listing.expirationTime > 0 && 
            block.timestamp >= listing.expirationTime,
            "Listing not expired"
        );
        
        listing.status = ListingStatus.EXPIRED;
        emit ListingExpired(tokenId, block.timestamp);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    function _calculateFee(uint256 price, bool usePrivacy) internal pure returns (uint256) {
        uint256 fee = (price * MARKETPLACE_FEE) / BASIS_POINTS;
        if (usePrivacy) {
            fee *= PRIVACY_MULTIPLIER;
        }
        return fee;
    }
    
    function _distributeFees(
        uint256 feeAmount,
        bool usePrivacy,
        IERC20 token
    ) internal {
        if (feeAmount == 0) return;
        
        // Fee distribution: 70% validators, 20% treasury, 10% liquidity
        uint256 validatorShare = (feeAmount * 7000) / BASIS_POINTS;
        uint256 treasuryShare = (feeAmount * 2000) / BASIS_POINTS;
        uint256 liquidityShare = feeAmount - validatorShare - treasuryShare;
        
        if (validatorShare > 0) {
            token.safeTransfer(validatorPoolAddress, validatorShare);
        }
        if (treasuryShare > 0) {
            token.safeTransfer(treasuryAddress, treasuryShare);
        }
        if (liquidityShare > 0) {
            token.safeTransfer(liquidityPoolAddress, liquidityShare);
        }
    }
    
    function _getToken(bool usePrivacy) internal view returns (address) {
        if (usePrivacy && isMpcAvailable) {
            return registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        }
        return registry.getContract(keccak256("OMNICOIN"));
    }
    
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
    
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    // =============================================================================
    // OVERRIDES
    // =============================================================================
    
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override(ERC721, ERC721URIStorage) 
        returns (string memory) 
    {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    // Override _update to prevent transfers of active listings
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Allow minting and burning
        if (from == address(0) || to == address(0)) {
            return super._update(to, tokenId, auth);
        }
        
        // For transfers, check listing status
        MinimalListing storage listing = listings[tokenId];
        require(
            listing.status != ListingStatus.ACTIVE || 
            auth == address(this), // Allow marketplace contract transfers
            "Cannot transfer active listing"
        );
        
        return super._update(to, tokenId, auth);
    }
}