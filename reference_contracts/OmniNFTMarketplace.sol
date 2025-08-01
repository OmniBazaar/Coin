// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MpcCore, gtUint64, gtBool, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinEscrow} from "./OmniCoinEscrow.sol";
import {ListingNFT} from "./ListingNFT.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";
import {OmniCoinRegistry} from "./OmniCoinRegistry.sol";

/**
 * @title OmniNFTMarketplace
 * @author OmniBazaar Team
 * @notice Enhanced NFT marketplace with privacy options for secure trading
 * @dev This contract provides public and private NFT trading functionality
 * 
 * Features:
 * - Default: Public listings with transparent prices
 * - Optional: Private sales with encrypted prices (10x fees)
 * - Support for fixed-price sales, auctions, offers, and bundles
 * - Privacy-enabled auctions and offers
 * - Comprehensive wallet integration
 */
contract OmniNFTMarketplace is
    Initializable,
    OwnableUpgradeable,  
    ReentrancyGuardUpgradeable,
    IERC721Receiver
{
    // =============================================================================
    // ENUMS
    // =============================================================================
    
    enum ListingType {
        FIXED_PRICE,
        AUCTION,
        OFFER_ONLY,
        BUNDLE
    }

    enum ListingStatus {
        ACTIVE,
        SOLD,
        CANCELLED,
        EXPIRED
    }

    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct Listing {
        uint256 listingId;
        uint256 tokenId;
        uint256 price;          // Public price (0 if private)
        uint256 startTime;
        uint256 endTime;
        uint256 views;
        uint256 favorites;
        address seller;
        address nftContract;
        address currency;
        ListingType listingType;
        ListingStatus status;
        bool escrowEnabled;
        bool isPrivate;         // Privacy flag
        ctUint64 encryptedPrice; // Encrypted price for private listings
        string category;
        string[] tags;
    }

    struct Auction {
        uint256 listingId;
        uint256 highestBid;          // Public (0 if private)
        uint256 reservePrice;        // Public (0 if private)
        uint256 bidIncrement;
        address highestBidder;
        bool extended;
        ctUint64 encryptedHighestBid;    // For private auctions
        ctUint64 encryptedReservePrice;  // For private auctions
        mapping(address => uint256) bids;     // Public bids
        mapping(address => ctUint64) privateBids; // Encrypted bids
        address[] bidders;
    }

    struct Offer {
        uint256 offerId;
        uint256 listingId;
        address buyer;
        uint256 amount;          // Public (0 if private)
        uint256 expiry;
        bool accepted;
        bool cancelled;
        address currency;
        bool isPrivate;          // Privacy flag
        ctUint64 encryptedAmount; // Encrypted offer amount
    }

    struct Bundle {
        uint256 bundleId;
        uint256 totalPrice;      // Public (0 if private)
        uint256 discount;
        address seller;
        bool active;
        bool isPrivate;          // Privacy flag
        ctUint64 encryptedTotalPrice; // Encrypted bundle price
        address[] nftContracts;
        uint256[] tokenIds;
    }

    struct MarketplaceStats {
        uint256 totalListings;
        uint256 totalSales;
        uint256 totalVolume;
        uint256 activeListings;
        uint256 totalUsers;
        uint256 privateListings;
        uint256 privateSales;
    }

    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Multiplier for privacy-enabled features (10x standard fees)
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    
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
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error ListingNotActive();
    error NotFixedPrice();
    error CannotBuyOwnItem();
    error UsePrivacyFunction();
    error PaymentFailed();
    error FeePaymentFailed();
    error PrivacyNotAvailable();
    error PrivacyFeeManagerNotSet();
    error NotTokenOwner();
    error InvalidAuctionDuration();
    error InvalidPrice();
    error NotAuction();
    error AuctionEnded();
    error AuctionStillActive();
    error CannotBidOwnAuction();
    error BidBelowReserve();
    error BidTooLow();
    error RefundFailed();
    error BidTransferFailed();
    error CannotOfferOwnItem();
    error InvalidOfferAmount();
    error InvalidExpiry();
    error OfferTransferFailed();
    error OnlySellerCanCancel();
    error CannotCancelWithBids();
    error OnlySellerCanAccept();
    error OfferNotAvailable();
    error OfferExpired();
    error NotPrivateListing();
    error NotAuthorized();
    error NotPrivateOffer();
    error FeeTooHigh();
    error WithdrawalFailed();

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Escrow contract for secure transactions (deprecated, use registry)
    OmniCoinEscrow public escrowContract;
    /// @notice NFT contract for listing representations (deprecated, use registry)
    ListingNFT public listingNFT;
    /// @notice Address of the privacy fee manager contract
    address public privacyFeeManager;
    /// @notice Flag indicating if MPC privacy features are available
    bool public isMpcAvailable;

    /// @notice Mapping of listing ID to listing details
    mapping(uint256 => Listing) public listings;
    /// @notice Mapping of listing ID to auction details
    mapping(uint256 => Auction) public auctions;
    /// @notice Mapping of offer ID to offer details
    mapping(uint256 => Offer) public offers;
    /// @notice Mapping of bundle ID to bundle details
    mapping(uint256 => Bundle) public bundles;
    /// @notice Mapping of user address to their listing IDs
    mapping(address => uint256[]) public userListings;
    /// @notice Mapping of user address to their offer IDs
    mapping(address => uint256[]) public userOffers;
    /// @notice Mapping of category name to listing IDs in that category
    mapping(string => uint256[]) public categoryListings;
    /// @notice Mapping of collection address to verification status
    mapping(address => bool) public verifiedCollections;
    /// @notice Mapping of user address to their total sales volume
    mapping(address => uint256) public userStats;

    /// @notice Counter for generating unique listing IDs
    uint256 public listingCounter;
    /// @notice Counter for generating unique offer IDs
    uint256 public offerCounter;
    /// @notice Counter for generating unique bundle IDs
    uint256 public bundleCounter;
    /// @notice Platform fee percentage in basis points (100 = 1%)
    uint256 public platformFee;
    /// @notice Maximum allowed duration for auctions
    uint256 public maxAuctionDuration;
    /// @notice Minimum required duration for auctions
    uint256 public minAuctionDuration;
    /// @notice Address that receives platform fees (deprecated - kept for compatibility)
    address public feeRecipient;

    /// @notice Global marketplace statistics
    MarketplaceStats public stats;
    
    /// @notice Registry contract reference
    OmniCoinRegistry public registry;
    
    // Fee accumulation mappings
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
    
    // Referral and node tracking
    /// @notice Referrer for each listing (listingId => referrer address)
    mapping(uint256 => address) public listingReferrers;
    
    /// @notice Parent referrer for each user (user => parent referrer)
    mapping(address => address) public userReferrers;
    
    /// @notice Listing node for each listing (listingId => node address)
    mapping(uint256 => address) public listingNodes;
    
    /// @notice Selling node for each listing (listingId => node address)
    mapping(uint256 => address) public sellingNodes;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a new listing is created
     * @param listingId Unique identifier for the listing
     * @param seller Address of the NFT seller
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT being listed
     * @param price Listed price (0 if private)
     * @param isPrivate Whether the listing uses privacy features
     */
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price,
        bool isPrivate
    );
    /**
     * @notice Emitted when a listing is cancelled
     * @param listingId Unique identifier for the cancelled listing
     */
    event ListingCancelled(uint256 indexed listingId);
    /**
     * @notice Emitted when an item is sold
     * @param listingId Unique identifier for the listing
     * @param buyer Address of the NFT buyer
     * @param price Sale price (0 if private)
     * @param isPrivate Whether the sale used privacy features
     */
    event ItemSold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 indexed price,
        bool isPrivate
    );
    /**
     * @notice Emitted when a bid is placed on an auction
     * @param listingId Unique identifier for the auction listing
     * @param bidder Address of the bidder
     * @param amount Bid amount (0 if private)
     * @param isPrivate Whether the bid uses privacy features
     */
    event BidPlaced(
        uint256 indexed listingId,
        address indexed bidder,
        uint256 indexed amount,
        bool isPrivate
    );
    /**
     * @notice Emitted when an auction is extended due to last-minute bidding
     * @param listingId Unique identifier for the auction listing
     * @param newEndTime New auction end timestamp
     */
    event AuctionExtended(uint256 indexed listingId, uint256 indexed newEndTime);
    /**
     * @notice Emitted when an offer is made on a listing
     * @param offerId Unique identifier for the offer
     * @param listingId Unique identifier for the listing
     * @param buyer Address of the offer maker
     * @param amount Offer amount (0 if private)
     * @param isPrivate Whether the offer uses privacy features
     */
    event OfferMade(
        uint256 indexed offerId,
        uint256 indexed listingId,
        address indexed buyer,
        uint256 amount,
        bool isPrivate
    );
    /**
     * @notice Emitted when an offer is accepted by the seller
     * @param offerId Unique identifier for the accepted offer
     * @param listingId Unique identifier for the listing
     */
    event OfferAccepted(uint256 indexed offerId, uint256 indexed listingId);
    /**
     * @notice Emitted when a bundle of NFTs is created
     * @param bundleId Unique identifier for the bundle
     * @param seller Address of the bundle creator
     * @param totalPrice Total bundle price (0 if private)
     * @param isPrivate Whether the bundle uses privacy features
     */
    event BundleCreated(
        uint256 indexed bundleId,
        address indexed seller,
        uint256 indexed totalPrice,
        bool isPrivate
    );
    /**
     * @notice Emitted when a collection is verified by the admin
     * @param collection Address of the verified NFT collection
     */
    event CollectionVerified(address indexed collection);
    /**
     * @notice Emitted when the platform fee is updated
     * @param newFee New platform fee in basis points
     */
    event PlatformFeeUpdated(uint256 indexed newFee);

    // =============================================================================
    // CONSTRUCTOR & INITIALIZER
    // =============================================================================
    
    /**
     * @notice Constructor disabled for upgradeable contract
     * @dev Disables initializers to prevent implementation contract initialization
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the marketplace contract
     * @param _registry Address of the registry contract
     * @param _escrowContract Address of the escrow contract (deprecated, use registry)
     * @param _listingNFT Address of the ListingNFT contract (deprecated, use registry)
     * @param _privacyFeeManager Address of the privacy fee manager
     * @param _platformFee Platform fee in basis points
     * @param _feeRecipient Address to receive platform fees
     */
    function initialize(
        address _registry,
        address _escrowContract,
        address _listingNFT,
        address _privacyFeeManager,
        uint256 _platformFee,
        address _feeRecipient
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        // Store registry reference directly
        registry = OmniCoinRegistry(_registry);

        // Keep for backwards compatibility
        if (_escrowContract != address(0)) {
            escrowContract = OmniCoinEscrow(_escrowContract);
        }
        if (_listingNFT != address(0)) {
            listingNFT = ListingNFT(_listingNFT);
        }
        privacyFeeManager = _privacyFeeManager;
        platformFee = _platformFee;
        feeRecipient = _feeRecipient;

        maxAuctionDuration = 30 days;
        minAuctionDuration = 1 hours;
        listingCounter = 0;
        offerCounter = 0;
        bundleCounter = 0;
        isMpcAvailable = false; // Default to false, set by admin when on COTI
    }
    
    /**
     * @notice Get contract address from registry
     * @param identifier The contract identifier
     * @return The contract address
     */
    function _getContract(bytes32 identifier) internal view returns (address) {
        return registry.getContract(identifier);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Sets the availability of MPC privacy features
     * @dev Admin only function to enable/disable privacy features
     * @param _available Whether MPC privacy features should be available
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Sets the privacy fee manager contract address
     * @dev Admin only function to update privacy fee manager
     * @param _privacyFeeManager New privacy fee manager address
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        if (_privacyFeeManager == address(0)) revert InvalidAddress();
        privacyFeeManager = _privacyFeeManager;
    }

    // =============================================================================
    // INTERNAL HELPERS
    // =============================================================================
    
    /**
     * @notice Get token contract based on privacy preference
     * @dev Helper to get appropriate token contract
     * @param usePrivacy Whether to use private token
     * @return Token contract address
     */
    function _getTokenContract(bool usePrivacy) internal view returns (address) {
        if (usePrivacy) {
            return _getContract(registry.PRIVATE_OMNICOIN());
        } else {
            return _getContract(registry.OMNICOIN());
        }
    }
    
    // =============================================================================
    // PUBLIC LISTING FUNCTIONS (DEFAULT, NO PRIVACY FEES)
    // =============================================================================
    
    /**
     * @notice Creates a public listing for an NFT
     * @dev Creates standard listing without privacy features
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT to list
     * @param listingType Type of listing (fixed price, auction, etc.)
     * @param price Listing price in wei
     * @param duration Auction duration in seconds (0 for non-auctions)
     * @param escrowEnabled Whether to use escrow for the transaction
     * @param category Listing category for organization
     * @param tags Array of tags for search and discovery
     * @return listingId Unique identifier for the created listing
     */
    function createListing(
        address nftContract,
        uint256 tokenId,
        ListingType listingType,
        uint256 price,
        uint256 duration,
        bool escrowEnabled,
        string calldata category,
        string[] calldata tags
    ) external nonReentrant returns (uint256 listingId) {
        return _createListingInternal(
            nftContract,
            tokenId,
            listingType,
            price,
            duration,
            escrowEnabled,
            category,
            tags,
            false // Not private
        );
    }
    
    /**
     * @notice Purchases an NFT at fixed price (public listings only)
     * @dev Transfers payment and NFT ownership
     * @param listingId Unique identifier of the listing to purchase
     */
    function buyItem(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (listing.listingType != ListingType.FIXED_PRICE) revert NotFixedPrice();
        if (msg.sender == listing.seller) revert CannotBuyOwnItem();
        if (listing.isPrivate) revert UsePrivacyFunction();

        uint256 totalPrice = listing.price;
        uint256 fee = (totalPrice * platformFee) / 10000;
        uint256 sellerAmount = totalPrice - fee;

        // Transfer payment using OmniCoin (public listings use public token)
        address omniCoin = _getTokenContract(false);
        if (!IERC20(omniCoin).transferFrom(msg.sender, address(this), totalPrice)) 
            revert PaymentFailed();
        
        // Transfer to seller
        if (!IERC20(omniCoin).transfer(listing.seller, sellerAmount)) 
            revert PaymentFailed();
            
        // Distribute fees
        if (fee > 0) {
            _distributeFees(listingId, omniCoin, fee, msg.sender);
        }

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        listing.status = ListingStatus.SOLD;
        unchecked { --stats.activeListings; }
        unchecked { ++stats.totalSales; }
        stats.totalVolume += totalPrice;
        userStats[listing.seller] += totalPrice;

        emit ItemSold(listingId, msg.sender, totalPrice, false);
    }

    /**
     * @notice Places a bid on a public auction
     * @dev Handles bid validation and refund of previous highest bidder
     * @param listingId Unique identifier of the auction listing
     * @param bidAmount Amount to bid in wei
     */
    function placeBid(uint256 listingId, uint256 bidAmount) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (listing.isPrivate) revert UsePrivacyFunction();
        _placeBidInternal(listingId, bidAmount, false);
    }

    /**
     * @notice Makes a public offer on any listing
     * @dev Creates an offer that the seller can accept or reject
     * @param listingId Unique identifier of the listing
     * @param amount Offer amount in wei
     * @param expiry Unix timestamp when the offer expires
     * @return offerId Unique identifier for the created offer
     */
    function makeOffer(
        uint256 listingId,
        uint256 amount,
        uint256 expiry
    ) external nonReentrant returns (uint256 offerId) {
        return _makeOfferInternal(listingId, amount, expiry, false);
    }

    // =============================================================================
    // PRIVATE LISTING FUNCTIONS (PREMIUM, 10X FEES)
    // =============================================================================
    
    /**
     * @notice Creates a private listing with encrypted price
     * @dev Uses MPC to encrypt price information, charges 10x fees
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT to list
     * @param listingType Type of listing (fixed price, auction, etc.)
     * @param price Encrypted price data
     * @param duration Auction duration in seconds (0 for non-auctions)
     * @param escrowEnabled Whether to use escrow for the transaction
     * @param category Listing category for organization
     * @param tags Array of tags for search and discovery
     * @param usePrivacy Must be true to use privacy features
     * @return listingId Unique identifier for the created listing
     */
    function createListingWithPrivacy(
        address nftContract,
        uint256 tokenId,
        ListingType listingType,
        itUint64 calldata price,
        uint256 duration,
        bool escrowEnabled,
        string calldata category,
        string[] calldata tags,
        bool usePrivacy
    ) external nonReentrant returns (uint256 listingId) {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        if (privacyFeeManager == address(0)) revert PrivacyFeeManagerNotSet();
        
        if (IERC721(nftContract).ownerOf(tokenId) != msg.sender)
            revert NotTokenOwner();
        
        // Validate encrypted price
        gtUint64 gtPrice = MpcCore.validateCiphertext(price);
        
        if (listingType == ListingType.AUCTION) {
            if (duration < minAuctionDuration || duration > maxAuctionDuration)
                revert InvalidAuctionDuration();
        }

        // Collect privacy fee for listing creation
        uint256 createFeeRate = 5; // 0.05% of listing price
        uint256 basisPoints = 10000;
        uint64 priceDecrypted = MpcCore.decrypt(gtPrice);
        uint256 privacyFee = (uint256(priceDecrypted) * createFeeRate * PRIVACY_MULTIPLIER) / basisPoints;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("NFT_CREATE_LISTING"),
            privacyFee
        );

        // Transfer NFT to marketplace
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        unchecked { ++listingCounter; }
        listingId = listingCounter;
        uint256 endTime = listingType == ListingType.AUCTION 
            ? block.timestamp + duration // solhint-disable-line not-rely-on-time
            : 0;

        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            listingType: listingType,
            price: 0, // Hidden for privacy
            startTime: block.timestamp, // solhint-disable-line not-rely-on-time
            endTime: endTime,
            status: ListingStatus.ACTIVE,
            escrowEnabled: escrowEnabled,
            currency: _getTokenContract(false),
            category: category,
            tags: tags,
            views: 0,
            favorites: 0,
            isPrivate: true,
            encryptedPrice: MpcCore.offBoard(gtPrice)
        });

        userListings[msg.sender].push(listingId);
        categoryListings[category].push(listingId);

        if (listingType == ListingType.AUCTION) {
            Auction storage auction = auctions[listingId];
            auction.listingId = listingId;
            auction.encryptedReservePrice = MpcCore.offBoard(gtPrice);
            
            // Set encrypted bid increment (5% of price)
            // gtUint64 gtIncrement = MpcCore.div(gtPrice, MpcCore.setPublic64(20));
            auction.bidIncrement = 0; // Hidden for privacy
        }

        unchecked { ++stats.totalListings; }
        unchecked { ++stats.activeListings; }
        unchecked { ++stats.privateListings; }

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, 0, true);
        
        return listingId;
    }
    
    /**
     * @notice Purchases an NFT from a private listing
     * @dev Decrypts price for payment processing, charges 10x fees
     * @param listingId Unique identifier of the private listing
     * @param usePrivacy Must be true to purchase private listings
     */
    function buyItemWithPrivacy(
        uint256 listingId,
        bool usePrivacy
    ) external nonReentrant {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (listing.listingType != ListingType.FIXED_PRICE) revert NotFixedPrice();
        if (msg.sender == listing.seller) revert CannotBuyOwnItem();
        if (!listing.isPrivate) revert UsePrivacyFunction();

        // Get encrypted price
        gtUint64 gtPrice = MpcCore.onBoard(listing.encryptedPrice);
        uint64 priceDecrypted = MpcCore.decrypt(gtPrice);
        
        // Calculate fees
        uint256 totalPrice = uint256(priceDecrypted);
        uint256 fee = (totalPrice * platformFee) / 10000;
        uint256 sellerAmount = totalPrice - fee;
        
        // Collect privacy fee (0.2% of sale price)
        uint256 saleFeeRate = 20; // 0.2% in basis points
        uint256 basisPoints = 10000;
        uint256 privacyFee = (totalPrice * saleFeeRate * PRIVACY_MULTIPLIER) / basisPoints;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("NFT_PURCHASE"),
            privacyFee
        );

        // Transfer payment using PrivateOmniCoin (private listings use private token)
        address privateToken = _getTokenContract(true);
        if (!IERC20(privateToken).transferFrom(msg.sender, listing.seller, sellerAmount)) 
            revert PaymentFailed();
        
        // Distribute fees using complex split logic
        _distributeFees(listingId, privateToken, fee, msg.sender);

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        listing.status = ListingStatus.SOLD;
        unchecked { --stats.activeListings; }
        unchecked { ++stats.totalSales; }
        unchecked { ++stats.privateSales; }
        stats.totalVolume += totalPrice;
        userStats[listing.seller] += totalPrice;

        emit ItemSold(listingId, msg.sender, 0, true); // Price hidden
    }
    
    /**
     * @notice Places an encrypted bid on a private auction
     * @dev Uses MPC for bid comparison, charges 10x fees
     * @param listingId Unique identifier of the private auction
     * @param bidAmount Encrypted bid amount
     * @param usePrivacy Must be true to bid on private auctions
     */
    function placeBidWithPrivacy(
        uint256 listingId,
        itUint64 calldata bidAmount,
        bool usePrivacy
    ) external nonReentrant {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        Listing storage listing = listings[listingId];
        if (!listing.isPrivate) revert UsePrivacyFunction();
        
        // Validate encrypted bid
        gtUint64 gtBidAmount = MpcCore.validateCiphertext(bidAmount);
        
        // Decrypt for validation only
        uint64 bidDecrypted = MpcCore.decrypt(gtBidAmount);
        
        // Collect privacy fee (0.1% of bid)
        uint256 bidFeeRate = 10; // 0.1% in basis points
        uint256 basisPoints = 10000;
        uint256 privacyFee = (uint256(bidDecrypted) * bidFeeRate * PRIVACY_MULTIPLIER) / basisPoints;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("NFT_BID"),
            privacyFee
        );
        
        _placeBidPrivateInternal(listingId, gtBidAmount, bidDecrypted);
    }
    
    /**
     * @notice Makes an encrypted offer on any listing
     * @dev Uses MPC to encrypt offer amount, charges 10x fees
     * @param listingId Unique identifier of the listing
     * @param amount Encrypted offer amount
     * @param expiry Unix timestamp when the offer expires
     * @param usePrivacy Must be true to use privacy features
     * @return offerId Unique identifier for the created offer
     */
    function makeOfferWithPrivacy(
        uint256 listingId,
        itUint64 calldata amount,
        uint256 expiry,
        bool usePrivacy
    ) external nonReentrant returns (uint256 offerId) {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        
        // Validate encrypted amount
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        uint64 amountDecrypted = MpcCore.decrypt(gtAmount);
        
        // Collect privacy fee (0.1% of offer)
        uint256 offerFeeRate = 10; // 0.1% in basis points
        uint256 basisPoints = 10000;
        uint256 privacyFee = (uint256(amountDecrypted) * offerFeeRate * PRIVACY_MULTIPLIER) / basisPoints;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("NFT_OFFER"),
            privacyFee
        );
        
        return _makeOfferPrivateInternal(listingId, gtAmount, amountDecrypted, expiry);
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Internal function to create a listing
     * @dev Handles common listing creation logic for both public and private listings
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT to list
     * @param listingType Type of listing (fixed price, auction, etc.)
     * @param price Listing price in wei
     * @param duration Auction duration in seconds (0 for non-auctions)
     * @param escrowEnabled Whether to use escrow for the transaction
     * @param category Listing category for organization
     * @param tags Array of tags for search and discovery
     * @param isPrivate Whether the listing uses privacy features
     * @return listingId Unique identifier for the created listing
     */
    function _createListingInternal(
        address nftContract,
        uint256 tokenId,
        ListingType listingType,
        uint256 price,
        uint256 duration,
        bool escrowEnabled,
        string memory category,
        string[] memory tags,
        bool isPrivate
    ) internal returns (uint256 listingId) {
        if (IERC721(nftContract).ownerOf(tokenId) != msg.sender)
            revert NotTokenOwner();
        if (price == 0) revert InvalidPrice();

        if (listingType == ListingType.AUCTION) {
            if (duration < minAuctionDuration || duration > maxAuctionDuration)
                revert InvalidAuctionDuration();
        }

        // Transfer NFT to marketplace
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        unchecked { ++listingCounter; }
        listingId = listingCounter;
        uint256 endTime = listingType == ListingType.AUCTION 
            ? block.timestamp + duration // solhint-disable-line not-rely-on-time
            : 0;

        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            listingType: listingType,
            price: price,
            startTime: block.timestamp, // solhint-disable-line not-rely-on-time
            endTime: endTime,
            status: ListingStatus.ACTIVE,
            escrowEnabled: escrowEnabled,
            currency: _getTokenContract(false),
            category: category,
            tags: tags,
            views: 0,
            favorites: 0,
            isPrivate: false,
            encryptedPrice: ctUint64.wrap(0)
        });

        userListings[msg.sender].push(listingId);
        categoryListings[category].push(listingId);

        if (listingType == ListingType.AUCTION) {
            auctions[listingId].listingId = listingId;
            auctions[listingId].reservePrice = price;
            auctions[listingId].bidIncrement = price / 20; // 5% minimum increment
        }

        unchecked { ++stats.totalListings; }
        unchecked { ++stats.activeListings; }

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, price, false);
    }
    
    /**
     * @notice Internal function to place a public bid
     * @dev Handles bid validation, refunds, and state updates
     * @param listingId Unique identifier of the auction listing
     * @param bidAmount Amount to bid in wei
     */
    function _placeBidInternal(
        uint256 listingId,
        uint256 bidAmount,
        bool // isPrivate
    ) internal {
        address publicToken = _getContract(registry.OMNICOIN());
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (listing.listingType != ListingType.AUCTION) revert NotAuction();
        if (block.timestamp > listing.endTime) revert AuctionEnded(); // solhint-disable-line not-rely-on-time
        if (msg.sender == listing.seller) revert CannotBidOwnAuction();
        if (bidAmount < auction.reservePrice) revert BidBelowReserve();
        if (bidAmount < auction.highestBid + auction.bidIncrement)
            revert BidTooLow();

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            if (!IERC20(publicToken).transfer(auction.highestBidder, auction.highestBid))
                revert RefundFailed();
        }

        // Transfer new bid amount
        if (!IERC20(publicToken).transferFrom(msg.sender, address(this), bidAmount))
            revert BidTransferFailed();

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        auction.bids[msg.sender] = bidAmount;

        // Add to bidders array if first bid
        bool isNewBidder = true;
        for (uint256 i = 0; i < auction.bidders.length;) {
            if (auction.bidders[i] == msg.sender) {
                isNewBidder = false;
                break;
            }
            unchecked { ++i; }
        }
        if (isNewBidder) {
            auction.bidders.push(msg.sender);
        }

        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp < 600 && !auction.extended) { // solhint-disable-line not-rely-on-time
            listing.endTime += 600; // Add 10 minutes
            auction.extended = true;
            emit AuctionExtended(listingId, listing.endTime);
        }

        emit BidPlaced(listingId, msg.sender, bidAmount, false);
    }
    
    /**
     * @notice Internal function to place a private bid
     * @dev Handles encrypted bid validation and comparison
     * @param listingId Unique identifier of the private auction
     * @param bidAmount Encrypted bid amount
     * @param bidDecrypted Decrypted bid amount for payment processing
     */
    function _placeBidPrivateInternal(
        uint256 listingId,
        gtUint64 bidAmount,
        uint64 bidDecrypted
    ) internal {
        address publicToken = _getContract(registry.OMNICOIN());
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (listing.listingType != ListingType.AUCTION) revert NotAuction();
        if (block.timestamp > listing.endTime) revert AuctionEnded(); // solhint-disable-line not-rely-on-time
        if (msg.sender == listing.seller) revert CannotBidOwnAuction();

        // Check reserve price
        gtUint64 gtReserve = MpcCore.onBoard(auction.encryptedReservePrice);
        gtBool meetsReserve = MpcCore.ge(bidAmount, gtReserve);
        if (!MpcCore.decrypt(meetsReserve)) revert BidBelowReserve();

        // Check bid increment
        if (auction.highestBidder != address(0)) {
            gtUint64 gtHighest = MpcCore.onBoard(auction.encryptedHighestBid);
            gtUint64 gtIncrement = MpcCore.div(gtHighest, MpcCore.setPublic64(20)); // 5%
            gtUint64 minBid = MpcCore.add(gtHighest, gtIncrement);
            gtBool validBid = MpcCore.ge(bidAmount, minBid);
            if (!MpcCore.decrypt(validBid)) revert BidTooLow();
            
            // Refund previous bidder
            uint64 previousBid = MpcCore.decrypt(gtHighest);
            if (!IERC20(publicToken).transfer(auction.highestBidder, uint256(previousBid)))
                revert RefundFailed();
        }

        // Transfer new bid amount
        if (!IERC20(publicToken).transferFrom(msg.sender, address(this), uint256(bidDecrypted)))
            revert BidTransferFailed();

        // Update auction state
        auction.encryptedHighestBid = MpcCore.offBoard(bidAmount);
        auction.highestBidder = msg.sender;
        auction.privateBids[msg.sender] = MpcCore.offBoard(bidAmount);

        // Add to bidders array if first bid
        bool isNewBidder = true;
        for (uint256 i = 0; i < auction.bidders.length;) {
            if (auction.bidders[i] == msg.sender) {
                isNewBidder = false;
                break;
            }
            unchecked { ++i; }
        }
        if (isNewBidder) {
            auction.bidders.push(msg.sender);
        }

        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp < 600 && !auction.extended) { // solhint-disable-line not-rely-on-time
            listing.endTime += 600;
            auction.extended = true;
            emit AuctionExtended(listingId, listing.endTime);
        }

        emit BidPlaced(listingId, msg.sender, 0, true); // Amount hidden
    }

    /**
     * @notice Internal function to make a public offer
     * @dev Creates offer and transfers funds to escrow
     * @param listingId Unique identifier of the listing
     * @param amount Offer amount in wei
     * @param expiry Unix timestamp when the offer expires
     * @param isPrivate Whether the offer uses privacy features
     * @return offerId Unique identifier for the created offer
     */
    function _makeOfferInternal(
        uint256 listingId,
        uint256 amount,
        uint256 expiry,
        bool isPrivate
    ) internal returns (uint256 offerId) {
        address publicToken = _getContract(registry.OMNICOIN());
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (msg.sender == listing.seller) revert CannotOfferOwnItem();
        if (amount == 0) revert InvalidOfferAmount();
        if (expiry < block.timestamp + 1) revert InvalidExpiry(); // solhint-disable-line not-rely-on-time

        // Transfer offer amount to escrow
        if (!IERC20(publicToken).transferFrom(msg.sender, address(this), amount))
            revert OfferTransferFailed();

        unchecked { ++offerCounter; }
        offerId = offerCounter;
        offers[offerId] = Offer({
            offerId: offerId,
            listingId: listingId,
            buyer: msg.sender,
            amount: amount,
            expiry: expiry,
            accepted: false,
            cancelled: false,
            currency: _getTokenContract(false),
            isPrivate: false,
            encryptedAmount: ctUint64.wrap(0)
        });

        userOffers[msg.sender].push(offerId);

        emit OfferMade(offerId, listingId, msg.sender, amount, false);
    }
    
    /**
     * @notice Internal function to make a private offer
     * @dev Creates encrypted offer and transfers funds to escrow
     * @param listingId Unique identifier of the listing
     * @param amount Encrypted offer amount
     * @param amountDecrypted Decrypted amount for payment processing
     * @param expiry Unix timestamp when the offer expires
     * @return offerId Unique identifier for the created offer
     */
    function _makeOfferPrivateInternal(
        uint256 listingId,
        gtUint64 amount,
        uint64 amountDecrypted,
        uint256 expiry
    ) internal returns (uint256 offerId) {
        address publicToken = _getContract(registry.OMNICOIN());
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (msg.sender == listing.seller) revert CannotOfferOwnItem();
        if (amountDecrypted == 0) revert InvalidOfferAmount();
        if (expiry < block.timestamp + 1) revert InvalidExpiry(); // solhint-disable-line not-rely-on-time

        // Transfer offer amount to escrow
        if (!IERC20(publicToken).transferFrom(msg.sender, address(this), uint256(amountDecrypted)))
            revert OfferTransferFailed();

        unchecked { ++offerCounter; }
        offerId = offerCounter;
        offers[offerId] = Offer({
            offerId: offerId,
            listingId: listingId,
            buyer: msg.sender,
            amount: 0, // Hidden
            expiry: expiry,
            accepted: false,
            cancelled: false,
            currency: _getTokenContract(false),
            isPrivate: true,
            encryptedAmount: MpcCore.offBoard(amount)
        });

        userOffers[msg.sender].push(offerId);

        emit OfferMade(offerId, listingId, msg.sender, 0, true); // Amount hidden
    }

    // =============================================================================
    // OTHER MARKETPLACE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Cancels an active listing and returns NFT to seller
     * @dev Only the seller can cancel, cannot cancel auctions with bids
     * @param listingId Unique identifier of the listing to cancel
     */
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (msg.sender != listing.seller) revert OnlySellerCanCancel();
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();

        if (listing.listingType == ListingType.AUCTION) {
            Auction storage auction = auctions[listingId];
            if (auction.highestBidder != address(0))
                revert CannotCancelWithBids();
        }

        // Return NFT to seller
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            listing.seller,
            listing.tokenId
        );

        listing.status = ListingStatus.CANCELLED;
        unchecked { --stats.activeListings; }

        emit ListingCancelled(listingId);
    }

    /**
     * @notice Finalizes an ended auction, transferring NFT and funds
     * @dev Can be called by anyone after auction ends
     * @param listingId Unique identifier of the auction to finalize
     */
    function finalizeAuction(uint256 listingId) external nonReentrant {
        address publicToken = _getContract(registry.OMNICOIN());
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();
        if (listing.listingType != ListingType.AUCTION) revert NotAuction();
        if (block.timestamp < listing.endTime + 1) revert AuctionStillActive(); // solhint-disable-line not-rely-on-time

        if (auction.highestBidder != address(0)) {
            uint256 totalPrice;
            
            if (listing.isPrivate) {
                gtUint64 gtHighest = MpcCore.onBoard(auction.encryptedHighestBid);
                totalPrice = uint256(MpcCore.decrypt(gtHighest));
            } else {
                totalPrice = auction.highestBid;
            }
            
            uint256 fee = (totalPrice * platformFee) / 10000;
            uint256 sellerAmount = totalPrice - fee;

            // Transfer payment to seller
            if (!IERC20(publicToken).transfer(listing.seller, sellerAmount))
                revert PaymentFailed();
            
            // Distribute fees using complex split logic
            _distributeFees(listingId, publicToken, fee, auction.highestBidder);

            // Transfer NFT to winner
            IERC721(listing.nftContract).safeTransferFrom(
                address(this),
                auction.highestBidder,
                listing.tokenId
            );

            listing.status = ListingStatus.SOLD;
            unchecked { ++stats.totalSales; }
            if (listing.isPrivate) {
                unchecked { ++stats.privateSales; }
            }
            stats.totalVolume += totalPrice;
            userStats[listing.seller] += totalPrice;

            emit ItemSold(listingId, auction.highestBidder, listing.isPrivate ? 0 : totalPrice, listing.isPrivate);
        } else {
            // No bids, return NFT to seller
            IERC721(listing.nftContract).safeTransferFrom(
                address(this),
                listing.seller,
                listing.tokenId
            );
            listing.status = ListingStatus.EXPIRED;
        }

        unchecked { --stats.activeListings; }
    }

    /**
     * @notice Accepts an offer and completes the sale
     * @dev Only the seller can accept offers
     * @param offerId Unique identifier of the offer to accept
     */
    function acceptOffer(uint256 offerId) external nonReentrant {
        address publicToken = _getContract(registry.OMNICOIN());
        Offer storage offer = offers[offerId];
        Listing storage listing = listings[offer.listingId];

        if (msg.sender != listing.seller) revert OnlySellerCanAccept();
        if (offer.accepted || offer.cancelled) revert OfferNotAvailable();
        if (block.timestamp > offer.expiry) revert OfferExpired(); // solhint-disable-line not-rely-on-time
        if (listing.status != ListingStatus.ACTIVE) revert ListingNotActive();

        uint256 amount;
        if (offer.isPrivate) {
            gtUint64 gtAmount = MpcCore.onBoard(offer.encryptedAmount);
            amount = uint256(MpcCore.decrypt(gtAmount));
        } else {
            amount = offer.amount;
        }

        uint256 fee = (amount * platformFee) / 10000;
        uint256 sellerAmount = amount - fee;

        // Transfer payment
        if (!IERC20(publicToken).transfer(listing.seller, sellerAmount))
            revert PaymentFailed();
        
        // Distribute fees using complex split logic
        _distributeFees(offer.listingId, publicToken, fee, offer.buyer);

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            offer.buyer,
            listing.tokenId
        );

        offer.accepted = true;
        listing.status = ListingStatus.SOLD;
        unchecked { --stats.activeListings; }
        unchecked { ++stats.totalSales; }
        if (offer.isPrivate || listing.isPrivate) {
            unchecked { ++stats.privateSales; }
        }
        stats.totalVolume += amount;
        userStats[listing.seller] += amount;

        emit OfferAccepted(offerId, offer.listingId);
        emit ItemSold(offer.listingId, offer.buyer, offer.isPrivate ? 0 : amount, offer.isPrivate);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Retrieves global marketplace statistics
     * @dev Returns aggregate data about listings, sales, and volume
     * @return MarketplaceStats struct containing all statistics
     */
    function getMarketplaceStats() external view returns (MarketplaceStats memory) {
        return stats;
    }

    /**
     * @notice Gets all listing IDs in a specific category
     * @dev Used for category-based browsing and filtering
     * @param category The category name to filter by
     * @return Array of listing IDs in the specified category
     */
    function getListingsByCategory(
        string calldata category
    ) external view returns (uint256[] memory) {
        return categoryListings[category];
    }

    /**
     * @notice Gets all listing IDs created by a specific user
     * @dev Used for user profile and management features
     * @param user Address of the user
     * @return Array of listing IDs created by the user
     */
    function getUserListings(address user) external view returns (uint256[] memory) {
        return userListings[user];
    }

    /**
     * @notice Gets all offer IDs made by a specific user
     * @dev Used for user profile and offer management
     * @param user Address of the user
     * @return Array of offer IDs made by the user
     */
    function getUserOffers(address user) external view returns (uint256[] memory) {
        return userOffers[user];
    }
    
    /**
     * @notice Gets the encrypted price of a private listing
     * @dev Only accessible by seller or contract owner
     * @param listingId Unique identifier of the private listing
     * @return Encrypted price data
     */
    function getPrivateListingPrice(uint256 listingId) external view returns (ctUint64) {
        Listing storage listing = listings[listingId];
        if (!listing.isPrivate) revert NotPrivateListing();
        if (msg.sender != listing.seller && msg.sender != owner())
            revert NotAuthorized();
        return listing.encryptedPrice;
    }
    
    /**
     * @notice Gets the encrypted amount of a private offer
     * @dev Only accessible by offer maker, listing seller, or contract owner
     * @param offerId Unique identifier of the private offer
     * @return Encrypted offer amount
     */
    function getPrivateOfferAmount(uint256 offerId) external view returns (ctUint64) {
        Offer storage offer = offers[offerId];
        Listing storage listing = listings[offer.listingId];
        if (!offer.isPrivate) revert NotPrivateOffer();
        if (msg.sender != offer.buyer && 
            msg.sender != listing.seller && 
            msg.sender != owner())
            revert NotAuthorized();
        return offer.encryptedAmount;
    }

    /**
     * @notice Increments the view count for a listing
     * @dev Used for tracking listing popularity
     * @param listingId Unique identifier of the listing
     */
    function incrementViews(uint256 listingId) external {
        unchecked { ++listings[listingId].views; }
    }

    /**
     * @notice Marks an NFT collection as verified
     * @dev Admin only function for collection verification
     * @param collection Address of the NFT collection to verify
     */
    function verifyCollection(address collection) external onlyOwner {
        verifiedCollections[collection] = true;
        emit CollectionVerified(collection);
    }

    /**
     * @notice Updates the platform fee percentage
     * @dev Admin only function, fee capped at 10%
     * @param newFee New fee in basis points (100 = 1%)
     */
    function updatePlatformFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) revert FeeTooHigh(); // Max 10%
        platformFee = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    /**
     * @notice Handles receipt of NFTs sent to this contract
     * @dev IERC721Receiver implementation
     * @return bytes4 selector confirming token transfer acceptance
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Emergency function to withdraw all contract funds
     * @dev Admin only function for emergency situations
     */
    function emergencyWithdraw() external onlyOwner {
        address publicToken = _getContract(registry.OMNICOIN());
        uint256 balance = IERC20(publicToken).balanceOf(address(this));
        if (!IERC20(publicToken).transfer(owner(), balance)) revert WithdrawalFailed();
    }
    
    // =============================================================================
    // FEE DISTRIBUTION FUNCTIONS
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
        uint256 transactionFee = (totalFee * TRANSACTION_FEE_BPS) / 100; // 50% of total fee
        uint256 referralFee = (totalFee * REFERRAL_FEE_BPS) / 100; // 25% of total fee
        uint256 listingFee = (totalFee * LISTING_FEE_BPS) / 100; // 25% of total fee
        
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
    }
    
    /**
     * @notice Set referrer for a listing
     * @param listingId The listing ID
     * @param referrer The referrer address
     */
    function setListingReferrer(uint256 listingId, address referrer) external onlyOwner {
        listingReferrers[listingId] = referrer;
    }
    
    /**
     * @notice Set user's parent referrer
     * @param user The user address
     * @param parentReferrer The parent referrer address
     */
    function setUserReferrer(address user, address parentReferrer) external onlyOwner {
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
    ) external onlyOwner {
        listingNodes[listingId] = listingNode;
        sellingNodes[listingId] = sellingNode;
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
    ) external onlyOwner {
        uint256 amount;
        
        if (feeType == 0) {
            // ODDAO fees
            amount = oddaoFees[paymentToken];
            if (amount > 0) {
                oddaoFees[paymentToken] = 0;
                address oddaoTreasury = _getContract(registry.ODDAO_TREASURY());
                IERC20(paymentToken).transfer(oddaoTreasury, amount);
            }
        } else if (feeType == 1) {
            // Validator fees
            amount = validatorFees[paymentToken];
            if (amount > 0) {
                validatorFees[paymentToken] = 0;
                address validatorPool = _getContract(registry.VALIDATOR_POOL());
                IERC20(paymentToken).transfer(validatorPool, amount);
            }
        } else if (feeType == 2) {
            // Staking pool fees
            amount = stakingPoolFees[paymentToken];
            if (amount > 0) {
                stakingPoolFees[paymentToken] = 0;
                address stakingPool = _getContract(registry.STAKING_POOL());
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