// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../OmniCoinCore.sol";
import "../OmniCoinEscrow.sol";
import "../ListingNFT.sol";

/**
 * @title OmniNFTMarketplace
 * @dev Enhanced NFT marketplace with comprehensive functionality for wallet integration
 * Supports fixed-price sales, auctions, offers, bundles, and advanced marketplace features
 */
contract OmniNFTMarketplace is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC721Receiver
{
    // Listing types
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

    // Core structures
    struct Listing {
        uint256 listingId;
        address seller;
        address nftContract;
        uint256 tokenId;
        ListingType listingType;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        ListingStatus status;
        bool escrowEnabled;
        address currency; // Token contract address (address(0) for ETH)
        string category;
        string[] tags;
        uint256 views;
        uint256 favorites;
    }

    struct Auction {
        uint256 listingId;
        uint256 highestBid;
        address highestBidder;
        uint256 reservePrice;
        uint256 bidIncrement;
        mapping(address => uint256) bids;
        address[] bidders;
        bool extended;
    }

    struct Offer {
        uint256 offerId;
        uint256 listingId;
        address buyer;
        uint256 amount;
        uint256 expiry;
        bool accepted;
        bool cancelled;
        address currency;
    }

    struct Bundle {
        uint256 bundleId;
        address seller;
        address[] nftContracts;
        uint256[] tokenIds;
        uint256 totalPrice;
        uint256 discount;
        bool active;
    }

    struct MarketplaceStats {
        uint256 totalListings;
        uint256 totalSales;
        uint256 totalVolume;
        uint256 activeListings;
        uint256 totalUsers;
    }

    // State variables
    OmniCoin public omniCoin;
    OmniCoinEscrow public escrowContract;
    ListingNFT public listingNFT;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Bundle) public bundles;
    mapping(address => uint256[]) public userListings;
    mapping(address => uint256[]) public userOffers;
    mapping(string => uint256[]) public categoryListings;
    mapping(address => bool) public verifiedCollections;
    mapping(address => uint256) public userStats; // Total sales volume per user

    uint256 public listingCounter;
    uint256 public offerCounter;
    uint256 public bundleCounter;
    uint256 public platformFee; // Basis points (100 = 1%)
    uint256 public maxAuctionDuration;
    uint256 public minAuctionDuration;
    address public feeRecipient;

    MarketplaceStats public stats;

    // Events
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price
    );
    event ListingCancelled(uint256 indexed listingId);
    event ItemSold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 price
    );
    event BidPlaced(
        uint256 indexed listingId,
        address indexed bidder,
        uint256 amount
    );
    event AuctionExtended(uint256 indexed listingId, uint256 newEndTime);
    event OfferMade(
        uint256 indexed offerId,
        uint256 indexed listingId,
        address indexed buyer,
        uint256 amount
    );
    event OfferAccepted(uint256 indexed offerId, uint256 indexed listingId);
    event BundleCreated(
        uint256 indexed bundleId,
        address indexed seller,
        uint256 totalPrice
    );
    event CollectionVerified(address indexed collection);
    event PlatformFeeUpdated(uint256 newFee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the marketplace
     */
    function initialize(
        address _omniCoin,
        address _escrowContract,
        address _listingNFT,
        uint256 _platformFee,
        address _feeRecipient
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        omniCoin = OmniCoin(_omniCoin);
        escrowContract = OmniCoinEscrow(_escrowContract);
        listingNFT = ListingNFT(_listingNFT);
        platformFee = _platformFee;
        feeRecipient = _feeRecipient;

        maxAuctionDuration = 30 days;
        minAuctionDuration = 1 hours;
        listingCounter = 0;
        offerCounter = 0;
        bundleCounter = 0;
    }

    /**
     * @dev Create a new listing
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
        require(
            IERC721(nftContract).ownerOf(tokenId) == msg.sender,
            "Not token owner"
        );
        require(price > 0, "Price must be greater than 0");

        if (listingType == ListingType.AUCTION) {
            require(
                duration >= minAuctionDuration &&
                    duration <= maxAuctionDuration,
                "Invalid auction duration"
            );
        }

        // Transfer NFT to marketplace
        IERC721(nftContract).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        listingId = ++listingCounter;
        uint256 endTime = listingType == ListingType.AUCTION
            ? block.timestamp + duration
            : 0;

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
            favorites: 0
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

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, price);
    }

    /**
     * @dev Buy item at fixed price
     */
    function buyItem(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(
            listing.listingType == ListingType.FIXED_PRICE,
            "Not a fixed price listing"
        );
        require(msg.sender != listing.seller, "Cannot buy own item");

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

        emit ItemSold(listingId, msg.sender, totalPrice);
    }

    /**
     * @dev Place bid on auction
     */
    function placeBid(
        uint256 listingId,
        uint256 bidAmount
    ) external nonReentrant {
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

        emit BidPlaced(listingId, msg.sender, bidAmount);
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
            uint256 totalPrice = auction.highestBid;
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
            stats.totalVolume += totalPrice;
            userStats[listing.seller] += totalPrice;

            emit ItemSold(listingId, auction.highestBidder, totalPrice);
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
     * @dev Make offer on item
     */
    function makeOffer(
        uint256 listingId,
        uint256 amount,
        uint256 expiry
    ) external nonReentrant returns (uint256 offerId) {
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
            currency: address(omniCoin)
        });

        userOffers[msg.sender].push(offerId);

        emit OfferMade(offerId, listingId, msg.sender, amount);
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

        uint256 fee = (offer.amount * platformFee) / 10000;
        uint256 sellerAmount = offer.amount - fee;

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
        stats.totalVolume += offer.amount;
        userStats[listing.seller] += offer.amount;

        emit OfferAccepted(offerId, offer.listingId);
        emit ItemSold(offer.listingId, offer.buyer, offer.amount);
    }

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
     * @dev Get marketplace statistics
     */
    function getMarketplaceStats()
        external
        view
        returns (MarketplaceStats memory)
    {
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
    function getUserListings(
        address user
    ) external view returns (uint256[] memory) {
        return userListings[user];
    }

    /**
     * @dev Get user's offers
     */
    function getUserOffers(
        address user
    ) external view returns (uint256[] memory) {
        return userOffers[user];
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
