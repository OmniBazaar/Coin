// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IUnifiedNFTMarketplace
 * @author OmniBazaar Team
 * @notice Interface for unified NFT marketplace supporting both ERC-721 and ERC-1155
 * @dev Defines the standard interface for cross-standard NFT trading
 */
interface IUnifiedNFTMarketplace {
    // =============================================================================
    // ENUMS
    // =============================================================================
    
    enum TokenStandard {
        ERC721,
        ERC1155
    }
    
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
    
    struct UnifiedListing {
        uint256 listingId;
        TokenStandard standard;
        address tokenContract;
        uint256 tokenId;
        uint256 amount;           // 1 for ERC-721, variable for ERC-1155
        uint256 pricePerUnit;     // Price per token
        uint256 totalPrice;       // pricePerUnit * amount
        address seller;
        address paymentToken;     // XOM or pXOM address
        bool usePrivacy;          // Whether using private token
        ListingType listingType;
        ListingStatus status;
        uint256 startTime;
        uint256 endTime;
        bool escrowEnabled;
        string metadataURI;
    }
    
    struct PurchaseParams {
        uint256 listingId;
        uint256 amount;           // Number of units to purchase
        bytes32 commitment;       // For privacy purchases
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event UnifiedListingCreated(
        uint256 indexed listingId,
        TokenStandard indexed standard,
        address indexed tokenContract,
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit
    );
    
    event UnifiedPurchase(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 indexed amount,
        uint256 totalPrice
    );
    
    event ListingUpdated(
        uint256 indexed listingId,
        uint256 newPricePerUnit,
        uint256 newAmount
    );
    
    // =============================================================================
    // FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a unified listing for any NFT standard
     * @param standard The token standard (ERC721 or ERC1155)
     * @param tokenContract Address of the NFT contract
     * @param tokenId ID of the token
     * @param amount Number of tokens (1 for ERC721)
     * @param pricePerUnit Price per token unit
     * @param usePrivacy Whether to use private payments
     * @param listingType Type of listing
     * @param duration Listing duration in seconds
     * @return listingId The created listing ID
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
    ) external returns (uint256 listingId);
    
    /**
     * @notice Purchase from a unified listing
     * @param params Purchase parameters
     */
    function purchaseUnified(PurchaseParams calldata params) external payable;
    
    /**
     * @notice Update listing price or amount
     * @param listingId Listing to update
     * @param newPricePerUnit New price per unit
     * @param additionalAmount Additional tokens to add (ERC1155 only)
     */
    function updateListing(
        uint256 listingId,
        uint256 newPricePerUnit,
        uint256 additionalAmount
    ) external;
    
    /**
     * @notice Cancel a listing
     * @param listingId Listing to cancel
     */
    function cancelListing(uint256 listingId) external;
    
    /**
     * @notice Get listing details
     * @param listingId Listing to query
     * @return listing The unified listing struct
     */
    function getListing(uint256 listingId) 
        external 
        view 
        returns (UnifiedListing memory listing);
    
    /**
     * @notice Check if a listing is still available
     * @param listingId Listing to check
     * @param amount Amount wanting to purchase
     * @return available Whether the amount is available
     */
    function isAvailable(uint256 listingId, uint256 amount) 
        external 
        view 
        returns (bool available);
}