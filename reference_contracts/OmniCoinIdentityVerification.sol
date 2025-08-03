// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReputationSystemBase} from "./ReputationSystemBase.sol";
import {IIdentityVerification} from "./interfaces/IReputationSystem.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title OmniCoinIdentityVerification
 * @author OmniCoin Development Team
 * @notice Identity verification module for the reputation system
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
    /// @notice Unverified identity tier
    uint8 public constant override IDENTITY_UNVERIFIED = 0;
    /// @notice Email verified tier
    uint8 public constant override IDENTITY_EMAIL = 1;
    /// @notice Phone verified tier
    uint8 public constant override IDENTITY_PHONE = 2;
    /// @notice Basic ID verified tier
    uint8 public constant override IDENTITY_BASIC_ID = 3;
    /// @notice Enhanced ID verified tier
    uint8 public constant override IDENTITY_ENHANCED_ID = 4;
    /// @notice Biometric verified tier
    uint8 public constant override IDENTITY_BIOMETRIC = 5;
    /// @notice Premium individual verified tier
    uint8 public constant override IDENTITY_PREMIUM_INDIVIDUAL = 6;
    /// @notice Commercial entity verified tier
    uint8 public constant override IDENTITY_COMMERCIAL = 7;
    /// @notice Corporate entity verified tier
    uint8 public constant override IDENTITY_CORPORATE = 8;
    
    /// @notice Maximum number of identity tiers
    uint8 public constant MAX_IDENTITY_TIERS = 9;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Identity scores by tier (basis points out of 10000)
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
    
    /// @notice Expiration periods by tier (in seconds)
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
    
    /// @notice Role for identity verifiers
    bytes32 public constant IDENTITY_VERIFIER_ROLE = keccak256("IDENTITY_VERIFIER_ROLE");
    /// @notice Role for KYC providers
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct IdentityRecord {
        uint8 currentTier;                  // Current verification tier
        bool isActive;                      // Whether identity is active
        uint256 verificationTimestamp;      // When verified
        uint256 expirationTimestamp;        // When expires
        uint256 previousTier;               // Previous tier (for downgrades)
        bytes32 proofHash;                  // Hash of verification proof
        gtUint64 encryptedScore;            // Private: identity score
        ctUint64 userEncryptedScore;        // Private: score for user
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice User identity records
    mapping(address => IdentityRecord) public identityRecords;
    
    /// @notice Tier-specific user counts (for statistics)
    mapping(uint8 => uint256) public tierUserCounts;
    
    /// @notice Total verified users
    uint256 public totalVerifiedUsers;
    
    /// @notice KYC provider addresses
    mapping(address => bool) public kycProviders;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error NotVerified();
    error InvalidTier();
    error InvalidUser();
    error InvalidProof();
    error InvalidScore();
    error ProviderExists();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the identity verification contract
     * @param _admin Admin address
     * @param _reputationCore Reputation core contract address
     */
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
     * @notice Verify user identity at specified tier
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
        if (user == address(0)) revert InvalidUser();
        if (tier == 0 || tier > MAX_IDENTITY_TIERS - 1) revert InvalidTier();
        if (proofHash == bytes32(0)) revert InvalidProof();
        
        IdentityRecord storage record = identityRecords[user];
        
        // Update tier counts
        if (record.isActive && record.currentTier > 0) {
            --tierUserCounts[record.currentTier];
        } else if (!record.isActive) {
            ++totalVerifiedUsers;
        }
        
        // Store previous tier
        record.previousTier = record.currentTier;
        
        // Update identity record
        record.currentTier = tier;
        record.verificationTimestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        // solhint-disable-next-line not-rely-on-time
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
        ++tierUserCounts[tier];
        
        // Update reputation core with identity score
        _updateReputationInCore(user, COMPONENT_IDENTITY_VERIFICATION, score);
        
        emit IdentityVerified(user, tier, proofHash, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Downgrade or revoke identity
     * @param user User address
     * @param reason Reason for downgrade
     */
    function downgradeIdentity(
        address user,
        string calldata reason
    ) external whenNotPaused onlyRole(IDENTITY_VERIFIER_ROLE) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive) revert NotVerified();
        
        // Update tier counts
        if (record.currentTier > 0) {
            --tierUserCounts[record.currentTier];
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
        
        --totalVerifiedUsers;
        
        // Update reputation with zero score
        // Create a dummy zero score for testing
        itUint64 memory zeroScore = itUint64({
            ciphertext: ctUint64.wrap(0),
            signature: new bytes(32)
        });
        
        _updateReputationInCoreMemory(user, COMPONENT_IDENTITY_VERIFICATION, zeroScore);
        
        emit IdentityDowngraded(user, reason, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Renew identity verification
     * @param user User address
     * @param proofHash New proof hash
     */
    function renewIdentity(
        address user,
        bytes32 proofHash
    ) external whenNotPaused onlyRole(IDENTITY_VERIFIER_ROLE) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive) revert NotVerified();
        if (record.currentTier == 0) revert InvalidTier();
        
        record.verificationTimestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        // solhint-disable-next-line not-rely-on-time
        record.expirationTimestamp = block.timestamp + tierExpirationPeriods[record.currentTier];
        record.proofHash = proofHash;
        
        emit IdentityRenewed(user, record.currentTier, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get user's identity tier
     * @param user User address
     * @return The user's current identity tier
     */
    function getIdentityTier(address user) external view override returns (uint8) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive || block.timestamp > record.expirationTimestamp) { // solhint-disable-line not-rely-on-time
            return 0; // Unverified or expired
        }
        return record.currentTier;
    }
    
    /**
     * @notice Get user's identity score (encrypted)
     * @param user User address
     * @return The user's encrypted identity score
     */
    function getIdentityScore(address user) external override returns (gtUint64) {
        IdentityRecord storage record = identityRecords[user];
        if (!record.isActive || block.timestamp > record.expirationTimestamp) { // solhint-disable-line not-rely-on-time
            // Return zero without calling _toEncrypted 
            return gtUint64.wrap(0);
        }
        return record.encryptedScore;
    }
    
    /**
     * @notice Check if identity is expired
     * @param user User address
     * @return Whether the identity is expired
     */
    function isIdentityExpired(address user) external view override returns (bool) {
        IdentityRecord storage record = identityRecords[user];
        return record.isActive && block.timestamp > record.expirationTimestamp; // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Get identity details
     * @param user User address
     * @return tier Current identity tier
     * @return verificationTime Timestamp of verification
     * @return expirationTime Timestamp of expiration
     * @return isActive Whether identity is active
     * @return isExpired Whether identity is expired
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
            record.isActive && block.timestamp > record.expirationTimestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Get user's encrypted identity score (for user viewing)
     * @param user User address
     * @return The user's encrypted score
     */
    function getUserEncryptedScore(address user) external view returns (ctUint64) {
        if (msg.sender != user) revert InvalidUser();
        return identityRecords[user].userEncryptedScore;
    }
    
    /**
     * @notice Get tier statistics
     * @return counts Array of user counts per tier
     */
    function getTierStatistics() external view returns (uint256[9] memory counts) {
        for (uint8 i = 0; i < MAX_IDENTITY_TIERS; ++i) {
            counts[i] = tierUserCounts[i];
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update tier score
     * @param tier Identity tier
     * @param score New score value
     */
    function updateTierScore(uint8 tier, uint256 score) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (tier > MAX_IDENTITY_TIERS - 1) revert InvalidTier();
        if (score > BASIS_POINTS) revert InvalidScore();
        tierScores[tier] = score;
        emit TierScoreUpdated(tier, score);
    }
    
    /**
     * @notice Update tier expiration period
     * @param tier Identity tier
     * @param period New expiration period in seconds
     */
    function updateTierExpiration(uint8 tier, uint256 period) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (tier > MAX_IDENTITY_TIERS - 1) revert InvalidTier();
        tierExpirationPeriods[tier] = period;
        emit TierExpirationUpdated(tier, period);
    }
    
    /**
     * @notice Add KYC provider
     * @param provider Provider address
     */
    function addKYCProvider(address provider) external onlyRole(ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidUser();
        kycProviders[provider] = true;
        _grantRole(KYC_PROVIDER_ROLE, provider);
        emit KYCProviderAdded(provider);
    }
    
    /**
     * @notice Remove KYC provider
     * @param provider Provider address
     */
    function removeKYCProvider(address provider) external onlyRole(ADMIN_ROLE) {
        kycProviders[provider] = false;
        _revokeRole(KYC_PROVIDER_ROLE, provider);
        emit KYCProviderRemoved(provider);
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when identity is downgraded
     * @param user User address
     * @param reason Reason for downgrade
     * @param timestamp When downgraded
     */
    event IdentityDowngraded(
        address indexed user,
        string reason,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when identity is renewed
     * @param user User address
     * @param tier Identity tier
     * @param timestamp When renewed
     */
    event IdentityRenewed(
        address indexed user,
        uint8 indexed tier,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when tier score is updated
     * @param tier Identity tier
     * @param newScore New score value
     */
    event TierScoreUpdated(
        uint8 indexed tier,
        uint256 indexed newScore
    );
    
    /**
     * @notice Emitted when tier expiration is updated
     * @param tier Identity tier
     * @param newPeriod New expiration period
     */
    event TierExpirationUpdated(
        uint8 indexed tier,
        uint256 indexed newPeriod
    );
    
    /**
     * @notice Emitted when KYC provider is added
     * @param provider Provider address
     */
    event KYCProviderAdded(address indexed provider);
    
    /**
     * @notice Emitted when KYC provider is removed
     * @param provider Provider address
     */
    event KYCProviderRemoved(address indexed provider);
}