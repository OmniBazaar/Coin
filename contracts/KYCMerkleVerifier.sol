// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title KYCMerkleVerifier
 * @author OmniCoin Development Team
 * @notice Verifies KYC compliance data using merkle proofs
 * @dev Used by marketplace to verify off-chain KYC data maintained by validators
 * 
 * The validator maintains off-chain KYC data including:
 * - User tiers (0-3)
 * - Transaction limits
 * - Listing limits (count and price)
 * - Cumulative volumes
 * - Active listing counts
 * 
 * This data is aggregated into merkle trees with roots stored on-chain
 */
contract KYCMerkleVerifier {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /**
     * @notice KYC data for a user
     * @param userAddress User's wallet address
     * @param tier KYC tier (0-3)
     * @param cumulativeVolume Total transaction volume
     * @param dailyVolume Current daily volume
     * @param activeListings Current number of active listings
     */
    struct KYCData {
        address userAddress;
        uint8 tier;
        uint256 cumulativeVolume;
        uint256 dailyVolume;
        uint256 activeListings;
    }
    
    /**
     * @notice Listing limits by tier
     * @param maxListings Maximum number of active listings
     * @param maxPrice Maximum price per listing
     */
    struct ListingLimits {
        uint256 maxListings;
        uint256 maxPrice;
    }
    
    /**
     * @notice Transaction limits by tier
     * @param dailyLimit Daily transaction limit
     * @param complianceFeeRate Fee rate in basis points
     */
    struct TransactionLimits {
        uint256 dailyLimit;
        uint256 complianceFeeRate;
    }
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Listing limits by KYC tier
    mapping(uint8 => ListingLimits) public listingLimits;
    
    /// @notice Transaction limits by KYC tier  
    mapping(uint8 => TransactionLimits) public transactionLimits;
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidProof();
    error TierExceedsMaximum();
    error InvalidUserAddress();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize verifier with tier limits
     * @dev Sets up listing and transaction limits for each KYC tier
     */
    constructor() {
        // Tier 0: Phone verification only
        listingLimits[0] = ListingLimits({
            maxListings: 5,
            maxPrice: 100 * 1e18 // $100
        });
        transactionLimits[0] = TransactionLimits({
            dailyLimit: 500 * 1e18, // $500
            complianceFeeRate: 100 // 1%
        });
        
        // Tier 1: Basic KYC
        listingLimits[1] = ListingLimits({
            maxListings: 50,
            maxPrice: 1000 * 1e18 // $1,000
        });
        transactionLimits[1] = TransactionLimits({
            dailyLimit: 5000 * 1e18, // $5,000
            complianceFeeRate: 50 // 0.5%
        });
        
        // Tier 2: Enhanced KYC
        listingLimits[2] = ListingLimits({
            maxListings: 500,
            maxPrice: 10000 * 1e18 // $10,000
        });
        transactionLimits[2] = TransactionLimits({
            dailyLimit: 25000 * 1e18, // $25,000
            complianceFeeRate: 0 // 0%
        });
        
        // Tier 3: Institutional KYC (unlimited)
        listingLimits[3] = ListingLimits({
            maxListings: 0, // 0 = unlimited
            maxPrice: 0 // 0 = unlimited
        });
        transactionLimits[3] = TransactionLimits({
            dailyLimit: 100000 * 1e18, // $100,000
            complianceFeeRate: 0 // 0%
        });
    }
    
    // =============================================================================
    // PUBLIC FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Compute merkle leaf from KYC data
     * @param kycData User's KYC data
     * @return leaf Computed leaf hash
     */
    function computeLeaf(KYCData calldata kycData) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            kycData.userAddress,
            kycData.tier,
            kycData.cumulativeVolume,
            kycData.dailyVolume,
            kycData.activeListings
        ));
    }
    
    // =============================================================================
    // EXTERNAL VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if user can create listing
     * @param kycData User's KYC data
     * @param listingPrice Price of the listing
     * @param proof Merkle proof
     * @param root Current KYC merkle root
     * @return allowed Whether listing is allowed
     * @return reason Reason if not allowed
     */
    function checkListingCompliance(
        KYCData calldata kycData,
        uint256 listingPrice,
        bytes32[] calldata proof,
        bytes32 root
    ) external view returns (bool allowed, string memory reason) {
        // Verify merkle proof
        if (!verifyKYCData(kycData, proof, root)) {
            return (false, "Invalid KYC proof");
        }
        
        // Check tier validity
        if (kycData.tier > 3) {
            return (false, "Invalid KYC tier");
        }
        
        ListingLimits memory limits = listingLimits[kycData.tier];
        
        // Check listing count (0 = unlimited)
        if (limits.maxListings != 0 && kycData.activeListings > limits.maxListings - 1) {
            return (false, "Max listing limit reached");
        }
        
        // Check price limit (0 = unlimited)
        if (limits.maxPrice != 0 && listingPrice > limits.maxPrice) {
            return (false, "Price exceeds tier max");
        }
        
        return (true, "");
    }
    
    /**
     * @notice Check if user can make transaction
     * @param kycData User's KYC data
     * @param transactionAmount Transaction amount
     * @param proof Merkle proof
     * @param root Current KYC merkle root
     * @return allowed Whether transaction is allowed
     * @return complianceFee Required compliance fee
     * @return reason Reason if not allowed
     */
    function checkTransactionCompliance(
        KYCData calldata kycData,
        uint256 transactionAmount,
        bytes32[] calldata proof,
        bytes32 root
    ) external view returns (
        bool allowed,
        uint256 complianceFee,
        string memory reason
    ) {
        // Verify merkle proof
        if (!verifyKYCData(kycData, proof, root)) {
            return (false, 0, "Invalid KYC proof");
        }
        
        // Check tier validity
        if (kycData.tier > 3) {
            return (false, 0, "Invalid KYC tier");
        }
        
        TransactionLimits memory limits = transactionLimits[kycData.tier];
        
        // Check daily limit
        if (kycData.dailyVolume + transactionAmount > limits.dailyLimit) {
            return (false, 0, "Daily transaction limit exceeded");
        }
        
        // Calculate compliance fee
        complianceFee = (transactionAmount * limits.complianceFeeRate) / BASIS_POINTS;
        
        return (true, complianceFee, "");
    }
    
    
    /**
     * @notice Get listing limits for a tier
     * @param tier KYC tier (0-3)
     * @return maxListings Maximum number of listings
     * @return maxPrice Maximum price per listing
     */
    function getListingLimits(uint8 tier) external view returns (
        uint256 maxListings,
        uint256 maxPrice
    ) {
        if (tier > 3) revert TierExceedsMaximum();
        ListingLimits memory limits = listingLimits[tier];
        return (limits.maxListings, limits.maxPrice);
    }
    
    /**
     * @notice Get transaction limits for a tier
     * @param tier KYC tier (0-3)
     * @return dailyLimit Daily transaction limit
     * @return complianceFeeRate Fee rate in basis points
     */
    function getTransactionLimits(uint8 tier) external view returns (
        uint256 dailyLimit,
        uint256 complianceFeeRate
    ) {
        if (tier > 3) revert TierExceedsMaximum();
        TransactionLimits memory limits = transactionLimits[tier];
        return (limits.dailyLimit, limits.complianceFeeRate);
    }
    
    // =============================================================================
    // PUBLIC PURE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify KYC data using merkle proof
     * @param kycData User's KYC data
     * @param proof Merkle proof from validator
     * @param root Merkle root to verify against
     * @return valid Whether the proof is valid
     */
    function verifyKYCData(
        KYCData calldata kycData,
        bytes32[] calldata proof,
        bytes32 root
    ) public pure returns (bool valid) {
        bytes32 leaf = computeLeaf(kycData);
        return MerkleProof.verify(proof, root, leaf);
    }
}