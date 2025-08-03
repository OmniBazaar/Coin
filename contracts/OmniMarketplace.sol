// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OmniCore} from "./OmniCore.sol";

/**
 * @title OmniMarketplace
 * @author OmniCoin Development Team
 * @notice Ultra-minimal marketplace with all logic moved off-chain
 * @dev Only stores critical hashes and emits events for validator indexing
 * 
 * Architecture:
 * - All listing data stored off-chain in validator nodes
 * - Only listing hashes and critical flags stored on-chain
 * - Escrow handled by separate MinimalEscrow contract
 * - Search, filtering, categorization all off-chain
 */
contract OmniMarketplace {
    // =============================================================================
    // Type Declarations
    // =============================================================================
    
    /**
     * @notice Minimal on-chain listing data
     * @dev Full listing details stored off-chain
     */
    struct ListingCore {
        address seller;       // 20 bytes
        bool isActive;        // 1 byte
        bool isPrivate;       // 1 byte
        // 10 bytes padding
        bytes32 dataHash;     // 32 bytes - Hash of off-chain data
        uint256 timestamp;    // 32 bytes - Creation time
    }
    
    // =============================================================================
    // Constants
    // =============================================================================
    
    /// @notice Core contract reference
    OmniCore public immutable CORE;
    
    // =============================================================================
    // State Variables
    // =============================================================================
    
    /// @notice Listing counter
    uint256 public listingCount;
    
    /// @notice Minimal listing data by ID
    mapping(uint256 => ListingCore) public listings;
    
    /// @notice Active listings per seller (for limits)
    mapping(address => uint256) public activeListingsCount;
    
    // =============================================================================
    // Events
    // =============================================================================
    
    /**
     * @notice Emitted when listing is created
     * @param listingId Unique listing identifier
     * @param seller Seller address
     * @param dataHash Hash of off-chain listing data
     * @param isPrivate Whether listing uses privacy features
     */
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        bytes32 indexed dataHash,
        bool isPrivate
    );
    
    /**
     * @notice Emitted when listing is updated
     * @param listingId Listing identifier
     * @param newDataHash New hash of off-chain data
     */
    event ListingUpdated(
        uint256 indexed listingId,
        bytes32 indexed newDataHash
    );
    
    /**
     * @notice Emitted when listing is deactivated
     * @param listingId Listing identifier
     */
    event ListingDeactivated(
        uint256 indexed listingId
    );
    
    /**
     * @notice Emitted when purchase is initiated
     * @param listingId Listing identifier
     * @param buyer Buyer address
     * @param escrowId Escrow contract ID
     */
    event PurchaseInitiated(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 indexed escrowId
    );
    
    // =============================================================================
    // Custom Errors
    // =============================================================================
    
    error Unauthorized();
    error ListingNotActive();
    error InvalidDataHash();
    error ListingLimitExceeded();
    
    // =============================================================================
    // Constructor
    // =============================================================================
    
    /**
     * @notice Initialize marketplace
     * @param _core OmniCore contract address
     */
    constructor(address _core) {
        CORE = OmniCore(_core);
    }
    
    // =============================================================================
    // External Functions
    // =============================================================================
    
    /**
     * @notice Create new listing
     * @dev All listing details stored off-chain, only hash stored
     * @param dataHash Hash of off-chain listing data
     * @param isPrivate Whether listing uses privacy features
     * @return listingId Unique listing identifier
     */
    function createListing(
        bytes32 dataHash,
        bool isPrivate
    ) external returns (uint256 listingId) {
        if (dataHash == bytes32(0)) revert InvalidDataHash();
        
        // Check listing limits from master merkle root
        // In production, validator would check against merkle proof
        uint256 currentActive = activeListingsCount[msg.sender];
        if (currentActive > 999) revert ListingLimitExceeded(); // Reasonable default
        
        listingId = ++listingCount;
        
        listings[listingId] = ListingCore({
            seller: msg.sender,
            isActive: true,
            isPrivate: isPrivate,
            dataHash: dataHash,
            timestamp: block.timestamp // solhint-disable-line not-rely-on-time
        });
        
        activeListingsCount[msg.sender] = currentActive + 1;
        
        emit ListingCreated(listingId, msg.sender, dataHash, isPrivate);
    }
    
    /**
     * @notice Update listing data
     * @dev Only updates hash, actual data changes happen off-chain
     * @param listingId Listing to update
     * @param newDataHash New hash of off-chain data
     */
    function updateListing(
        uint256 listingId,
        bytes32 newDataHash
    ) external {
        ListingCore storage listing = listings[listingId];
        
        if (listing.seller != msg.sender) revert Unauthorized();
        if (!listing.isActive) revert ListingNotActive();
        if (newDataHash == bytes32(0)) revert InvalidDataHash();
        
        listing.dataHash = newDataHash;
        
        emit ListingUpdated(listingId, newDataHash);
    }
    
    /**
     * @notice Deactivate listing
     * @param listingId Listing to deactivate
     */
    function deactivateListing(uint256 listingId) external {
        ListingCore storage listing = listings[listingId];
        
        if (listing.seller != msg.sender) revert Unauthorized();
        if (!listing.isActive) revert ListingNotActive();
        
        listing.isActive = false;
        --activeListingsCount[msg.sender];
        
        emit ListingDeactivated(listingId);
    }
    
    /**
     * @notice Record purchase initiation
     * @dev Actual purchase logic handled by escrow contract
     * @param listingId Listing being purchased
     * @param escrowId Associated escrow contract
     */
    function recordPurchase(
        uint256 listingId,
        uint256 escrowId
    ) external {
        ListingCore storage listing = listings[listingId];
        
        if (!listing.isActive) revert ListingNotActive();
        
        // Only escrow contract or buyer can record
        // In production, would verify caller is escrow contract
        
        emit PurchaseInitiated(listingId, msg.sender, escrowId);
    }
    
    /**
     * @notice Get listing core data
     * @param listingId Listing identifier
     * @return seller Seller address
     * @return isActive Whether listing is active
     * @return isPrivate Whether listing uses privacy
     * @return dataHash Hash of off-chain data
     * @return timestamp Creation timestamp
     */
    function getListing(uint256 listingId) external view returns (
        address seller,
        bool isActive,
        bool isPrivate,
        bytes32 dataHash,
        uint256 timestamp
    ) {
        ListingCore storage listing = listings[listingId];
        return (
            listing.seller,
            listing.isActive,
            listing.isPrivate,
            listing.dataHash,
            listing.timestamp
        );
    }
    
    /**
     * @notice Check if listing is active
     * @param listingId Listing to check
     * @return Whether listing is active
     */
    function isListingActive(uint256 listingId) external view returns (bool) {
        return listings[listingId].isActive;
    }
    
    /**
     * @notice Get seller's active listing count
     * @param seller Seller address
     * @return Number of active listings
     */
    function getActiveListingCount(address seller) external view returns (uint256) {
        return activeListingsCount[seller];
    }
}