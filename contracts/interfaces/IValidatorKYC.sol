// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IValidatorKYC
 * @author OmniCoin Development Team
 * @notice Interface for interacting with off-chain validator KYC services
 * @dev Defines the communication protocol between on-chain contracts and off-chain validators
 * 
 * The validator maintains comprehensive KYC data off-chain and provides:
 * - Merkle roots for on-chain verification
 * - KYC compliance checks for listings and transactions
 * - Volume tracking for progressive tier upgrades
 */
interface IValidatorKYC {
    
    // =============================================================================
    // ENUMS
    // =============================================================================
    
    /**
     * @notice KYC tier levels
     * @dev Each tier has different limits and fees
     */
    enum KYCTier {
        TIER_0, // Phone verification only
        TIER_1, // Basic KYC
        TIER_2, // Enhanced KYC
        TIER_3  // Institutional KYC
    }
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /**
     * @notice Listing compliance result
     * @param allowed Whether the listing is allowed
     * @param tier User's current KYC tier
     * @param activeListings Current number of active listings
     * @param maxListings Maximum allowed listings for the tier
     * @param maxPrice Maximum price allowed for the tier
     * @param reason Reason if not allowed
     */
    struct ListingComplianceResult {
        bool allowed;
        KYCTier tier;
        uint256 activeListings;
        uint256 maxListings;
        uint256 maxPrice;
        string reason;
    }
    
    /**
     * @notice Transaction compliance result
     * @param allowed Whether the transaction is allowed
     * @param tier User's current KYC tier
     * @param dailyVolume Current daily transaction volume
     * @param dailyLimit Daily transaction limit for the tier
     * @param complianceFee Required compliance fee
     * @param reason Reason if not allowed
     */
    struct TransactionComplianceResult {
        bool allowed;
        KYCTier tier;
        uint256 dailyVolume;
        uint256 dailyLimit;
        uint256 complianceFee;
        string reason;
    }
    
    /**
     * @notice Volume tracking result
     * @param success Whether the recording was successful
     * @param cumulativeVolume Total cumulative volume
     * @param currentTier Current KYC tier
     * @param nextTier Next tier (if eligible)
     * @param volumeToNextTier Volume needed for next tier
     */
    struct VolumeTrackingResult {
        bool success;
        uint256 cumulativeVolume;
        KYCTier currentTier;
        KYCTier nextTier;
        uint256 volumeToNextTier;
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when KYC merkle root is updated
     * @param newRoot New merkle root hash
     * @param blockHeight Block height of the update
     * @param timestamp Timestamp of the update
     */
    event KYCRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed blockHeight,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when a user's tier is upgraded
     * @param userAddress User's wallet address
     * @param oldTier Previous KYC tier
     * @param newTier New KYC tier
     * @param cumulativeVolume Volume that triggered upgrade
     */
    event TierUpgraded(
        address indexed userAddress,
        KYCTier indexed oldTier,
        KYCTier indexed newTier,
        uint256 cumulativeVolume
    );
    
    /**
     * @notice Emitted when listing is recorded
     * @param userAddress User creating the listing
     * @param listingId Unique listing identifier
     * @param price Listing price
     * @param activeListings New active listing count
     */
    event ListingRecorded(
        address indexed userAddress,
        string indexed listingId,
        uint256 indexed price,
        uint256 activeListings
    );
    
    /**
     * @notice Emitted when transaction volume is recorded
     * @param userAddress User address
     * @param amount Transaction amount
     * @param transactionType Type of transaction (buy/sell)
     * @param newCumulativeVolume Updated cumulative volume
     */
    event VolumeRecorded(
        address indexed userAddress,
        uint256 indexed amount,
        string indexed transactionType,
        uint256 newCumulativeVolume
    );
    
    // =============================================================================
    // FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update KYC merkle root (validator only)
     * @param newRoot New merkle root hash
     */
    function updateKYCRoot(bytes32 newRoot) external;
    
    /**
     * @notice Record a new listing
     * @param userAddress User creating the listing
     * @param listingId Unique listing identifier
     * @param price Listing price
     */
    function recordListing(
        address userAddress,
        string calldata listingId,
        uint256 price
    ) external;
    
    /**
     * @notice Update listing status
     * @param userAddress User who created the listing
     * @param listingId Listing identifier
     * @param status New status (sold, cancelled, expired)
     */
    function updateListingStatus(
        address userAddress,
        string calldata listingId,
        string calldata status
    ) external;
    
    /**
     * @notice Record transaction volume
     * @param userAddress User address
     * @param amount Transaction amount
     * @param transactionType Type of transaction (buy/sell)
     * @param complianceFee Fee collected
     * @return result Volume tracking result
     */
    function recordTransactionVolume(
        address userAddress,
        uint256 amount,
        string calldata transactionType,
        uint256 complianceFee
    ) external returns (VolumeTrackingResult memory result);
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get current KYC merkle root
     * @return root Current merkle root hash
     */
    function getKYCRoot() external view returns (bytes32 root);
    
    /**
     * @notice Check if user can create a listing
     * @param userAddress User's wallet address
     * @param listingPrice Price of the listing
     * @return result Compliance check result
     */
    function checkListingCompliance(
        address userAddress,
        uint256 listingPrice
    ) external view returns (ListingComplianceResult memory result);
    
    /**
     * @notice Check if user can make a transaction
     * @param userAddress User's wallet address
     * @param transactionAmount Transaction amount
     * @return result Compliance check result
     */
    function checkTransactionCompliance(
        address userAddress,
        uint256 transactionAmount
    ) external view returns (TransactionComplianceResult memory result);
    
    /**
     * @notice Get user's current KYC tier
     * @param userAddress User's wallet address
     * @return tier Current KYC tier
     */
    function getUserTier(address userAddress) external view returns (KYCTier tier);
    
    /**
     * @notice Get user's active listing count
     * @param userAddress User's wallet address
     * @return count Number of active listings
     */
    function getUserActiveListings(address userAddress) external view returns (uint256 count);
    
    /**
     * @notice Get user's cumulative volume
     * @param userAddress User's wallet address
     * @return volume Cumulative transaction volume
     */
    function getUserCumulativeVolume(address userAddress) external view returns (uint256 volume);
    
    /**
     * @notice Check if address is a validator
     * @param account Address to check
     * @return isValidator Whether address is a validator
     */
    function isValidator(address account) external view returns (bool isValidator);
}