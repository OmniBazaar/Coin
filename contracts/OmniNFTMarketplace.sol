// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinEscrow.sol";
import "./ListingNFT.sol";
import "./PrivacyFeeManager.sol";

/**
 * @title OmniNFTMarketplace
 * @dev Enhanced NFT marketplace with privacy options
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
        address seller;
        address nftContract;
        uint256 tokenId;
        ListingType listingType;
        uint256 price;          // Public price (0 if private)
        uint256 startTime;
        uint256 endTime;
        ListingStatus status;
        bool escrowEnabled;
        address currency;
        string category;
        string[] tags;
        uint256 views;
        uint256 favorites;
        bool isPrivate;         // Privacy flag
        ctUint64 encryptedPrice; // Encrypted price for private listings
    }

    struct Auction {
        uint256 listingId;
        uint256 highestBid;          // Public (0 if private)
        address highestBidder;
        uint256 reservePrice;        // Public (0 if private)
        uint256 bidIncrement;
        mapping(address => uint256) bids;     // Public bids
        mapping(address => ctUint64) privateBids; // Encrypted bids
        address[] bidders;
        bool extended;
        ctUint64 encryptedHighestBid;    // For private auctions
        ctUint64 encryptedReservePrice;  // For private auctions
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
        address seller;
        address[] nftContracts;
        uint256[] tokenIds;
        uint256 totalPrice;      // Public (0 if private)
        uint256 discount;
        bool active;
        bool isPrivate;          // Privacy flag
        ctUint64 encryptedTotalPrice; // Encrypted bundle price
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
    // STATE VARIABLES
    // =============================================================================
    
    OmniCoin public omniCoin;
    OmniCoinEscrow public escrowContract;
    ListingNFT public listingNFT;
    address public privacyFeeManager;
    bool public isMpcAvailable;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Bundle) public bundles;
    mapping(address => uint256[]) public userListings;
    mapping(address => uint256[]) public userOffers;
    mapping(string => uint256[]) public categoryListings;
    mapping(address => bool) public verifiedCollections;
    mapping(address => uint256) public userStats;

    uint256 public listingCounter;
    uint256 public offerCounter;
    uint256 public bundleCounter;
    uint256 public platformFee; // Basis points (100 = 1%)
    uint256 public maxAuctionDuration;
    uint256 public minAuctionDuration;
    address public feeRecipient;
    
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy

    MarketplaceStats public stats;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price,
        bool isPrivate
    );
    event ListingCancelled(uint256 indexed listingId);
    event ItemSold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 price,
        bool isPrivate
    );
    event BidPlaced(
        uint256 indexed listingId,
        address indexed bidder,
        uint256 amount,
        bool isPrivate
    );
    event AuctionExtended(uint256 indexed listingId, uint256 newEndTime);
    event OfferMade(
        uint256 indexed offerId,
        uint256 indexed listingId,
        address indexed buyer,
        uint256 amount,
        bool isPrivate
    );
    event OfferAccepted(uint256 indexed offerId, uint256 indexed listingId);
    event BundleCreated(
        uint256 indexed bundleId,
        address indexed seller,
        uint256 totalPrice,
        bool isPrivate
    );
    event CollectionVerified(address indexed collection);
    event PlatformFeeUpdated(uint256 newFee);

    // =============================================================================
    // CONSTRUCTOR & INITIALIZER
    // =============================================================================
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _omniCoin,
        address _escrowContract,
        address _listingNFT,
        address _privacyFeeManager,
        uint256 _platformFee,
        address _feeRecipient
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        omniCoin = OmniCoin(_omniCoin);
        escrowContract = OmniCoinEscrow(_escrowContract);
        listingNFT = ListingNFT(_listingNFT);
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

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Set MPC availability (admin only)
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        require(_privacyFeeManager != address(0), "Invalid address");
        privacyFeeManager = _privacyFeeManager;
    }

    // =============================================================================
    // PUBLIC LISTING FUNCTIONS (DEFAULT, NO PRIVACY FEES)
    // =============================================================================
    
    /**
     * @dev Create a public listing (default)
     */
    function createListing(
        address nftContract,
        uint256 tokenId,
        ListingType listingType,
        uint256 price,
        uint256 duration,
        bool escrowEnabled,
        string memory category,
        string[] memory tags
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
     * @dev Buy item at fixed price (public)
     */
    function buyItem(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(listing.listingType == ListingType.FIXED_PRICE, "Not fixed price");
        require(msg.sender != listing.seller, "Cannot buy own item");
        require(!listing.isPrivate, "Use buyItemWithPrivacy for private listings");

        uint256 totalPrice = listing.price;
        uint256 fee = (totalPrice * platformFee) / 10000;
        uint256 sellerAmount = totalPrice - fee;

        // Transfer payment
        require(
            omniCoin.transferFrom(msg.sender, listing.seller, sellerAmount),
            "Payment failed"
        );
        if (fee > 0) {
            require(
                omniCoin.transferFrom(msg.sender, feeRecipient, fee),
                "Fee payment failed"
            );
        }

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        listing.status = ListingStatus.SOLD;
        stats.activeListings--;
        stats.totalSales++;
        stats.totalVolume += totalPrice;
        userStats[listing.seller] += totalPrice;

        emit ItemSold(listingId, msg.sender, totalPrice, false);
    }

    /**
     * @dev Place public bid on auction
     */
    function placeBid(uint256 listingId, uint256 bidAmount) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(!listing.isPrivate, "Use placeBidWithPrivacy for private auctions");
        _placeBidInternal(listingId, bidAmount, false);
    }

    /**
     * @dev Make public offer on item
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
     * @dev Create a private listing with encrypted price
     */
    function createListingWithPrivacy(
        address nftContract,
        uint256 tokenId,
        ListingType listingType,
        itUint64 calldata price,
        uint256 duration,
        bool escrowEnabled,
        string memory category,
        string[] memory tags,
        bool usePrivacy
    ) external nonReentrant returns (uint256 listingId) {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        require(privacyFeeManager != address(0), "Privacy fee manager not set");
        
        require(
            IERC721(nftContract).ownerOf(tokenId) == msg.sender,
            "Not token owner"
        );
        
        // Validate encrypted price
        gtUint64 gtPrice = MpcCore.validateCiphertext(price);
        
        if (listingType == ListingType.AUCTION) {
            require(
                duration >= minAuctionDuration && duration <= maxAuctionDuration,
                "Invalid auction duration"
            );
        }

        // Collect privacy fee for listing creation
        uint256 CREATE_FEE_RATE = 5; // 0.05% of listing price
        uint256 BASIS_POINTS = 10000;
        uint64 priceDecrypted = MpcCore.decrypt(gtPrice);
        uint256 privacyFee = (uint256(priceDecrypted) * CREATE_FEE_RATE * PRIVACY_MULTIPLIER) / BASIS_POINTS;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("NFT_CREATE_LISTING"),
            privacyFee
        );

        // Transfer NFT to marketplace
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        listingId = ++listingCounter;
        uint256 endTime = listingType == ListingType.AUCTION ? block.timestamp + duration : 0;

        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            listingType: listingType,
            price: 0, // Hidden for privacy
            startTime: block.timestamp,
            endTime: endTime,
            status: ListingStatus.ACTIVE,
            escrowEnabled: escrowEnabled,
            currency: address(omniCoin),
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
            gtUint64 gtIncrement = MpcCore.div(gtPrice, MpcCore.setPublic64(20));
            auction.bidIncrement = 0; // Hidden for privacy
        }

        stats.totalListings++;
        stats.activeListings++;
        stats.privateListings++;

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, 0, true);
        
        return listingId;
    }
    
    /**
     * @dev Buy private listing item
     */
    function buyItemWithPrivacy(
        uint256 listingId,
        bool usePrivacy
    ) external nonReentrant {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(listing.listingType == ListingType.FIXED_PRICE, "Not fixed price");
        require(msg.sender != listing.seller, "Cannot buy own item");
        require(listing.isPrivate, "Use buyItem for public listings");

        // Get encrypted price
        gtUint64 gtPrice = MpcCore.onBoard(listing.encryptedPrice);
        uint64 priceDecrypted = MpcCore.decrypt(gtPrice);
        
        // Calculate fees
        uint256 totalPrice = uint256(priceDecrypted);
        uint256 fee = (totalPrice * platformFee) / 10000;
        uint256 sellerAmount = totalPrice - fee;
        
        // Collect privacy fee (0.2% of sale price)
        uint256 SALE_FEE_RATE = 20; // 0.2% in basis points
        uint256 BASIS_POINTS = 10000;
        uint256 privacyFee = (totalPrice * SALE_FEE_RATE * PRIVACY_MULTIPLIER) / BASIS_POINTS;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("NFT_PURCHASE"),
            privacyFee
        );

        // Transfer payment
        require(
            omniCoin.transferFrom(msg.sender, listing.seller, sellerAmount),
            "Payment failed"
        );
        if (fee > 0) {
            require(
                omniCoin.transferFrom(msg.sender, feeRecipient, fee),
                "Fee payment failed"
            );
        }

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        listing.status = ListingStatus.SOLD;
        stats.activeListings--;
        stats.totalSales++;
        stats.privateSales++;
        stats.totalVolume += totalPrice;
        userStats[listing.seller] += totalPrice;

        emit ItemSold(listingId, msg.sender, 0, true); // Price hidden
    }
    
    /**
     * @dev Place private bid on auction
     */
    function placeBidWithPrivacy(
        uint256 listingId,
        itUint64 calldata bidAmount,
        bool usePrivacy
    ) external nonReentrant {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        Listing storage listing = listings[listingId];
        require(listing.isPrivate, "Use placeBid for public auctions");
        
        // Validate encrypted bid
        gtUint64 gtBidAmount = MpcCore.validateCiphertext(bidAmount);
        
        // Decrypt for validation only
        uint64 bidDecrypted = MpcCore.decrypt(gtBidAmount);
        
        // Collect privacy fee (0.1% of bid)
        uint256 BID_FEE_RATE = 10; // 0.1% in basis points
        uint256 BASIS_POINTS = 10000;
        uint256 privacyFee = (uint256(bidDecrypted) * BID_FEE_RATE * PRIVACY_MULTIPLIER) / BASIS_POINTS;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("NFT_BID"),
            privacyFee
        );
        
        _placeBidPrivateInternal(listingId, gtBidAmount, bidDecrypted);
    }
    
    /**
     * @dev Make private offer
     */
    function makeOfferWithPrivacy(
        uint256 listingId,
        itUint64 calldata amount,
        uint256 expiry,
        bool usePrivacy
    ) external nonReentrant returns (uint256 offerId) {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        
        // Validate encrypted amount
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        uint64 amountDecrypted = MpcCore.decrypt(gtAmount);
        
        // Collect privacy fee (0.1% of offer)
        uint256 OFFER_FEE_RATE = 10; // 0.1% in basis points
        uint256 BASIS_POINTS = 10000;
        uint256 privacyFee = (uint256(amountDecrypted) * OFFER_FEE_RATE * PRIVACY_MULTIPLIER) / BASIS_POINTS;
        
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("NFT_OFFER"),
            privacyFee
        );
        
        return _makeOfferPrivateInternal(listingId, gtAmount, amountDecrypted, expiry);
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
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
        require(
            IERC721(nftContract).ownerOf(tokenId) == msg.sender,
            "Not token owner"
        );
        require(price > 0, "Price must be greater than 0");

        if (listingType == ListingType.AUCTION) {
            require(
                duration >= minAuctionDuration && duration <= maxAuctionDuration,
                "Invalid auction duration"
            );
        }

        // Transfer NFT to marketplace
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        listingId = ++listingCounter;
        uint256 endTime = listingType == ListingType.AUCTION ? block.timestamp + duration : 0;

        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            listingType: listingType,
            price: price,
            startTime: block.timestamp,
            endTime: endTime,
            status: ListingStatus.ACTIVE,
            escrowEnabled: escrowEnabled,
            currency: address(omniCoin),
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

        stats.totalListings++;
        stats.activeListings++;

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, price, false);
    }
    
    function _placeBidInternal(
        uint256 listingId,
        uint256 bidAmount,
        bool isPrivate
    ) internal {
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(listing.listingType == ListingType.AUCTION, "Not an auction");
        require(block.timestamp <= listing.endTime, "Auction ended");
        require(msg.sender != listing.seller, "Cannot bid on own auction");
        require(bidAmount >= auction.reservePrice, "Bid below reserve");
        require(
            bidAmount >= auction.highestBid + auction.bidIncrement,
            "Bid too low"
        );

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            require(
                omniCoin.transfer(auction.highestBidder, auction.highestBid),
                "Refund failed"
            );
        }

        // Transfer new bid amount
        require(
            omniCoin.transferFrom(msg.sender, address(this), bidAmount),
            "Bid transfer failed"
        );

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        auction.bids[msg.sender] = bidAmount;

        // Add to bidders array if first bid
        bool isNewBidder = true;
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            if (auction.bidders[i] == msg.sender) {
                isNewBidder = false;
                break;
            }
        }
        if (isNewBidder) {
            auction.bidders.push(msg.sender);
        }

        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp < 600 && !auction.extended) {
            listing.endTime += 600; // Add 10 minutes
            auction.extended = true;
            emit AuctionExtended(listingId, listing.endTime);
        }

        emit BidPlaced(listingId, msg.sender, bidAmount, false);
    }
    
    function _placeBidPrivateInternal(
        uint256 listingId,
        gtUint64 bidAmount,
        uint64 bidDecrypted
    ) internal {
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(listing.listingType == ListingType.AUCTION, "Not an auction");
        require(block.timestamp <= listing.endTime, "Auction ended");
        require(msg.sender != listing.seller, "Cannot bid on own auction");

        // Check reserve price
        gtUint64 gtReserve = MpcCore.onBoard(auction.encryptedReservePrice);
        gtBool meetsReserve = MpcCore.ge(bidAmount, gtReserve);
        require(MpcCore.decrypt(meetsReserve), "Bid below reserve");

        // Check bid increment
        if (auction.highestBidder != address(0)) {
            gtUint64 gtHighest = MpcCore.onBoard(auction.encryptedHighestBid);
            gtUint64 gtIncrement = MpcCore.div(gtHighest, MpcCore.setPublic64(20)); // 5%
            gtUint64 minBid = MpcCore.add(gtHighest, gtIncrement);
            gtBool validBid = MpcCore.ge(bidAmount, minBid);
            require(MpcCore.decrypt(validBid), "Bid too low");
            
            // Refund previous bidder
            uint64 previousBid = MpcCore.decrypt(gtHighest);
            require(
                omniCoin.transfer(auction.highestBidder, uint256(previousBid)),
                "Refund failed"
            );
        }

        // Transfer new bid amount
        require(
            omniCoin.transferFrom(msg.sender, address(this), uint256(bidDecrypted)),
            "Bid transfer failed"
        );

        // Update auction state
        auction.encryptedHighestBid = MpcCore.offBoard(bidAmount);
        auction.highestBidder = msg.sender;
        auction.privateBids[msg.sender] = MpcCore.offBoard(bidAmount);

        // Add to bidders array if first bid
        bool isNewBidder = true;
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            if (auction.bidders[i] == msg.sender) {
                isNewBidder = false;
                break;
            }
        }
        if (isNewBidder) {
            auction.bidders.push(msg.sender);
        }

        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp < 600 && !auction.extended) {
            listing.endTime += 600;
            auction.extended = true;
            emit AuctionExtended(listingId, listing.endTime);
        }

        emit BidPlaced(listingId, msg.sender, 0, true); // Amount hidden
    }

    function _makeOfferInternal(
        uint256 listingId,
        uint256 amount,
        uint256 expiry,
        bool isPrivate
    ) internal returns (uint256 offerId) {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(msg.sender != listing.seller, "Cannot offer on own item");
        require(amount > 0, "Invalid offer amount");
        require(expiry > block.timestamp, "Invalid expiry");

        // Transfer offer amount to escrow
        require(
            omniCoin.transferFrom(msg.sender, address(this), amount),
            "Offer transfer failed"
        );

        offerId = ++offerCounter;
        offers[offerId] = Offer({
            offerId: offerId,
            listingId: listingId,
            buyer: msg.sender,
            amount: amount,
            expiry: expiry,
            accepted: false,
            cancelled: false,
            currency: address(omniCoin),
            isPrivate: false,
            encryptedAmount: ctUint64.wrap(0)
        });

        userOffers[msg.sender].push(offerId);

        emit OfferMade(offerId, listingId, msg.sender, amount, false);
    }
    
    function _makeOfferPrivateInternal(
        uint256 listingId,
        gtUint64 amount,
        uint64 amountDecrypted,
        uint256 expiry
    ) internal returns (uint256 offerId) {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(msg.sender != listing.seller, "Cannot offer on own item");
        require(amountDecrypted > 0, "Invalid offer amount");
        require(expiry > block.timestamp, "Invalid expiry");

        // Transfer offer amount to escrow
        require(
            omniCoin.transferFrom(msg.sender, address(this), uint256(amountDecrypted)),
            "Offer transfer failed"
        );

        offerId = ++offerCounter;
        offers[offerId] = Offer({
            offerId: offerId,
            listingId: listingId,
            buyer: msg.sender,
            amount: 0, // Hidden
            expiry: expiry,
            accepted: false,
            cancelled: false,
            currency: address(omniCoin),
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
     * @dev Cancel listing
     */
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(msg.sender == listing.seller, "Only seller can cancel");
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");

        if (listing.listingType == ListingType.AUCTION) {
            Auction storage auction = auctions[listingId];
            require(
                auction.highestBidder == address(0),
                "Cannot cancel auction with bids"
            );
        }

        // Return NFT to seller
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            listing.seller,
            listing.tokenId
        );

        listing.status = ListingStatus.CANCELLED;
        stats.activeListings--;

        emit ListingCancelled(listingId);
    }

    /**
     * @dev Finalize auction
     */
    function finalizeAuction(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        Auction storage auction = auctions[listingId];

        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(listing.listingType == ListingType.AUCTION, "Not an auction");
        require(block.timestamp > listing.endTime, "Auction still active");

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
            require(
                omniCoin.transfer(listing.seller, sellerAmount),
                "Payment failed"
            );
            if (fee > 0) {
                require(
                    omniCoin.transfer(feeRecipient, fee),
                    "Fee payment failed"
                );
            }

            // Transfer NFT to winner
            IERC721(listing.nftContract).safeTransferFrom(
                address(this),
                auction.highestBidder,
                listing.tokenId
            );

            listing.status = ListingStatus.SOLD;
            stats.totalSales++;
            if (listing.isPrivate) {
                stats.privateSales++;
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

        stats.activeListings--;
    }

    /**
     * @dev Accept offer
     */
    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        Listing storage listing = listings[offer.listingId];

        require(msg.sender == listing.seller, "Only seller can accept");
        require(!offer.accepted && !offer.cancelled, "Offer not available");
        require(block.timestamp <= offer.expiry, "Offer expired");
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");

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
        require(
            omniCoin.transfer(listing.seller, sellerAmount),
            "Payment failed"
        );
        if (fee > 0) {
            require(omniCoin.transfer(feeRecipient, fee), "Fee payment failed");
        }

        // Transfer NFT
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            offer.buyer,
            listing.tokenId
        );

        offer.accepted = true;
        listing.status = ListingStatus.SOLD;
        stats.activeListings--;
        stats.totalSales++;
        if (offer.isPrivate || listing.isPrivate) {
            stats.privateSales++;
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
     * @dev Get marketplace statistics
     */
    function getMarketplaceStats() external view returns (MarketplaceStats memory) {
        return stats;
    }

    /**
     * @dev Get listings by category
     */
    function getListingsByCategory(
        string memory category
    ) external view returns (uint256[] memory) {
        return categoryListings[category];
    }

    /**
     * @dev Get user's listings
     */
    function getUserListings(address user) external view returns (uint256[] memory) {
        return userListings[user];
    }

    /**
     * @dev Get user's offers
     */
    function getUserOffers(address user) external view returns (uint256[] memory) {
        return userOffers[user];
    }
    
    /**
     * @dev Get encrypted listing price (only for authorized parties)
     */
    function getPrivateListingPrice(uint256 listingId) external view returns (ctUint64) {
        Listing storage listing = listings[listingId];
        require(listing.isPrivate, "Not a private listing");
        require(
            msg.sender == listing.seller || 
            msg.sender == owner(),
            "Not authorized"
        );
        return listing.encryptedPrice;
    }
    
    /**
     * @dev Get encrypted offer amount (only for authorized parties)
     */
    function getPrivateOfferAmount(uint256 offerId) external view returns (ctUint64) {
        Offer storage offer = offers[offerId];
        Listing storage listing = listings[offer.listingId];
        require(offer.isPrivate, "Not a private offer");
        require(
            msg.sender == offer.buyer || 
            msg.sender == listing.seller || 
            msg.sender == owner(),
            "Not authorized"
        );
        return offer.encryptedAmount;
    }

    /**
     * @dev Increment listing views
     */
    function incrementViews(uint256 listingId) external {
        listings[listingId].views++;
    }

    /**
     * @dev Verify collection
     */
    function verifyCollection(address collection) external onlyOwner {
        verifiedCollections[collection] = true;
        emit CollectionVerified(collection);
    }

    /**
     * @dev Update platform fee
     */
    function updatePlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= 1000, "Fee too high"); // Max 10%
        platformFee = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    /**
     * @dev IERC721Receiver implementation
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
     * @dev Emergency withdrawal (owner only)
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = omniCoin.balanceOf(address(this));
        require(omniCoin.transfer(owner(), balance), "Withdrawal failed");
    }
}