// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ReputationSystemBase.sol";
import "./interfaces/IReputationSystem.sol";

/**
 * @title OmniCoinIdentityVerification
 * @dev Identity verification module for the reputation system
 * 
 * Features:
 * - Multi-tier identity verification system
 * - Privacy-preserving identity scores
 * - Integration with KYC providers
 * - Expiration and renewal management
 */
contract OmniCoinIdentityVerification is ReputationSystemBase, IIdentityVerification {
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    // Identity verification tiers
    uint8 public constant override IDENTITY_UNVERIFIED = 0;
    uint8 public constant override IDENTITY_EMAIL = 1;
    uint8 public constant override IDENTITY_PHONE = 2;
    uint8 public constant override IDENTITY_BASIC_ID = 3;
    uint8 public constant override IDENTITY_ENHANCED_ID = 4;
    uint8 public constant override IDENTITY_BIOMETRIC = 5;
    uint8 public constant override IDENTITY_PREMIUM_INDIVIDUAL = 6;
    uint8 public constant override IDENTITY_COMMERCIAL = 7;
    uint8 public constant override IDENTITY_CORPORATE = 8;
    
    uint8 public constant MAX_IDENTITY_TIERS = 9;
    
    // Identity scores by tier (basis points out of 10000)
    uint256[9] public tierScores = [
        0,      // UNVERIFIED
        1000,   // EMAIL
        2000,   // PHONE
        4000,   // BASIC_ID
        6000,   // ENHANCED_ID
        7500,   // BIOMETRIC
        9000,   // PREMIUM_INDIVIDUAL
        8500,   // COMMERCIAL
        9500    // CORPORATE
    ];
    
    // Expiration periods by tier (in seconds)
    uint256[9] public tierExpirationPeriods = [
        0,              // UNVERIFIED (never expires)
        180 days,       // EMAIL
        365 days,       // PHONE
        2 * 365 days,   // BASIC_ID
        3 * 365 days,   // ENHANCED_ID
        3 * 365 days,   // BIOMETRIC
        5 * 365 days,   // PREMIUM_INDIVIDUAL
        365 days,       // COMMERCIAL
        2 * 365 days    // CORPORATE
    ];
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    bytes32 public constant IDENTITY_VERIFIER_ROLE = keccak256("IDENTITY_VERIFIER_ROLE");
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct IdentityRecord {
        uint8 currentTier;                  // Current verification tier
        uint256 verificationTimestamp;      // When verified
        uint256 expirationTimestamp;        // When expires
        bytes32 proofHash;                  // Hash of verification proof
        gtUint64 encryptedScore;            // Private: identity score
        ctUint64 userEncryptedScore;        // Private: score for user
        bool isActive;                      // Whether identity is active
        uint256 previousTier;               // Previous tier (for downgrades)
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev User identity records
    mapping(address => IdentityRecord) public identityRecords;
    
    /// @dev Tier-specific user counts (for statistics)
    mapping(uint8 => uint256) public tierUserCounts;
    
    /// @dev Total verified users
    uint256 public totalVerifiedUsers;
    
    /// @dev KYC provider addresses
    mapping(address => bool) public kycProviders;
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _admin,
        address _reputationCore
    ) ReputationSystemBase(_admin, _reputationCore) {
        _grantRole(IDENTITY_VERIFIER_ROLE, _admin);
        
        // Set default weight for identity component
        componentWeights[COMPONENT_IDENTITY_VERIFICATION] = 1500; // 15%
    }
    
    // =============================================================================
    // IDENTITY VERIFICATION FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Verify user identity at specified tier
     * @param user User address
     * @param tier Identity tier
     * @param proofHash Hash of verification proof
     * @param score Encrypted identity score
     */
    function verifyIdentity(
        address user,
        uint8 tier,
        bytes32 proofHash,
        itUint64 calldata score
    ) external override whenNotPaused nonReentrant onlyRole(IDENTITY_VERIFIER_ROLE) {
        require(user != address(0), "IdentityVerification: Invalid user");
        require(tier > 0 && tier < MAX_IDENTITY_TIERS, "IdentityVerification: Invalid tier");
        require(proofHash != bytes32(0), "IdentityVerification: Invalid proof");
        
        IdentityRecord storage record = identityRecords[user];
        
        // Update tier counts
        if (record.isActive && record.currentTier > 0) {
            tierUserCounts[record.currentTier]--;
        } else if (!record.isActive) {
            totalVerifiedUsers++;
        }
        
        // Store previous tier
        record.previousTier = record.currentTier;
        
        // Update identity record
        record.currentTier = tier;
        record.verificationTimestamp = block.timestamp;
        record.expirationTimestamp = block.timestamp + tierExpirationPeriods[tier];
        record.proofHash = proofHash;
        record.isActive = true;
        
        // Handle encrypted score
        gtUint64 gtScore = _validateInput(score);
        record.encryptedScore = gtScore;
        
        // Encrypt score for user viewing
        if (isMpcAvailable) {
            record.userEncryptedScore = MpcCore.offBoardToUser(gtScore, user);
        } else {
            record.userEncryptedScore = ctUint64.wrap(uint64(gtUint64.unwrap(gtScore)));
        }
        
        // Update tier count
        tierUserCounts[tier]++;
        
        // Update reputation core with identity score
        _updateReputationInCore(user, COMPONENT_IDENTITY_VERIFICATION, score);
        
        emit IdentityVerified(user, tier, proofHash, block.timestamp);
    }
    
    /**
     * @dev Downgrade or revoke identity
     * @param user User address
     * @param reason Reason for downgrade
     */
    function downgradeIdentity(
        address user,
        string calldata reason
    ) external whenNotPaused onlyRole(IDENTITY_VERIFIER_ROLE) {
        IdentityRecord storage record = identityRecords[user];
        require(record.isActive, "IdentityVerification: Not verified");
        
        // Update tier counts
        if (record.currentTier > 0) {
            tierUserCounts[record.currentTier]--;
        }
        
        // Downgrade to previous tier or unverified
        record.currentTier = 0; // Set to unverified
        record.isActive = false;
        record.encryptedScore = _toEncrypted(0);
        
        if (isMpcAvailable) {
            record.userEncryptedScore = MpcCore.offBoardToUser(record.encryptedScore, user);
        } else {
            record.userEncryptedScore = ctUint64.wrap(0);
        }
        
        totalVerifiedUsers--;
        
        // Update reputation with zero score
        // Create a dummy zero score for testing
        itUint64 memory zeroScore = itUint64({
            ciphertext: ctUint64.wrap(0),
            signature: new bytes(32)
        });
        
        _updateReputationInCoreMemory(user, COMPONENT_IDENTITY_VERIFICATION, zeroScore);
        
        emit IdentityDowngraded(user, reason, block.timestamp);
    }
    
    /**
     * @dev Renew identity verification
     * @param user User address
     * @param proofHash New proof hash
     */
    function renewIdentity(
        address user,
        bytes32 proofHash
    ) external whenNotPaused onlyRole(IDENTITY_VERIFIER_ROLE) {
        IdentityRecord storage record = identityRecords[user];
        require(record.isActive, "IdentityVerification: Not verified");
        require(record.currentTier > 0, "IdentityVerification: Cannot renew unverified");
        
        record.verificationTimestamp = block.timestamp;
        record.expirationTimestamp = block.timestamp + tierExpirationPeriods[record.currentTier];
        record.proofHash = proofHash;
        
        emit IdentityRenewed(user, record.currentTier, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get user's identity tier
     */
    function getIdentityTier(address user) external view override returns (uint8) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive || block.timestamp > record.expirationTimestamp) {
            return 0; // Unverified or expired
        }
        return record.currentTier;
    }
    
    /**
     * @dev Get user's identity score (encrypted)
     */
    function getIdentityScore(address user) external override returns (gtUint64) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive || block.timestamp > record.expirationTimestamp) {
            // Return zero without calling _toEncrypted 
            return gtUint64.wrap(0);
        }
        return record.encryptedScore;
    }
    
    /**
     * @dev Check if identity is expired
     */
    function isIdentityExpired(address user) external view override returns (bool) {
        IdentityRecord storage record = identityRecords[user];
        return record.isActive && block.timestamp > record.expirationTimestamp;
    }
    
    /**
     * @dev Get identity details
     */
    function getIdentityDetails(address user) external view returns (
        uint8 tier,
        uint256 verificationTime,
        uint256 expirationTime,
        bool isActive,
        bool isExpired
    ) {
        IdentityRecord storage record = identityRecords[user];
        return (
            record.currentTier,
            record.verificationTimestamp,
            record.expirationTimestamp,
            record.isActive,
            record.isActive && block.timestamp > record.expirationTimestamp
        );
    }
    
    /**
     * @dev Get user's encrypted identity score (for user viewing)
     */
    function getUserEncryptedScore(address user) external view returns (ctUint64) {
        require(msg.sender == user, "IdentityVerification: Not authorized");
        return identityRecords[user].userEncryptedScore;
    }
    
    /**
     * @dev Get tier statistics
     */
    function getTierStatistics() external view returns (uint256[9] memory counts) {
        for (uint8 i = 0; i < MAX_IDENTITY_TIERS; i++) {
            counts[i] = tierUserCounts[i];
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update tier score
     */
    function updateTierScore(uint8 tier, uint256 score) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(tier < MAX_IDENTITY_TIERS, "IdentityVerification: Invalid tier");
        require(score <= BASIS_POINTS, "IdentityVerification: Score too high");
        tierScores[tier] = score;
        emit TierScoreUpdated(tier, score);
    }
    
    /**
     * @dev Update tier expiration period
     */
    function updateTierExpiration(uint8 tier, uint256 period) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(tier < MAX_IDENTITY_TIERS, "IdentityVerification: Invalid tier");
        tierExpirationPeriods[tier] = period;
        emit TierExpirationUpdated(tier, period);
    }
    
    /**
     * @dev Add KYC provider
     */
    function addKYCProvider(address provider) external onlyRole(ADMIN_ROLE) {
        require(provider != address(0), "IdentityVerification: Invalid provider");
        kycProviders[provider] = true;
        _grantRole(KYC_PROVIDER_ROLE, provider);
        emit KYCProviderAdded(provider);
    }
    
    /**
     * @dev Remove KYC provider
     */
    function removeKYCProvider(address provider) external onlyRole(ADMIN_ROLE) {
        kycProviders[provider] = false;
        _revokeRole(KYC_PROVIDER_ROLE, provider);
        emit KYCProviderRemoved(provider);
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event IdentityDowngraded(
        address indexed user,
        string reason,
        uint256 timestamp
    );
    
    event IdentityRenewed(
        address indexed user,
        uint8 tier,
        uint256 timestamp
    );
    
    event TierScoreUpdated(
        uint8 indexed tier,
        uint256 newScore
    );
    
    event TierExpirationUpdated(
        uint8 indexed tier,
        uint256 newPeriod
    );
    
    event KYCProviderAdded(address indexed provider);
    event KYCProviderRemoved(address indexed provider);
}