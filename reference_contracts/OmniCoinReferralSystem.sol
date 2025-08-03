// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReputationSystemBase} from "./ReputationSystemBase.sol";
import {IReferralSystem} from "./interfaces/IReputationSystem.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title OmniCoinReferralSystem
 * @author OmniBazaar Team
 * @notice Referral tracking and rewards module for the reputation system
 * @dev Implements multi-level referral tracking with privacy-preserving scores
 * 
 * Features:
 * - Multi-level referral tracking
 * - Privacy-preserving referral scores
 * - Disseminator activity rewards
 * - Referral quality metrics
 */
contract OmniCoinReferralSystem is ReputationSystemBase, IReferralSystem {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /// @notice Stores referral data for each user
    /// @dev Optimized for storage with proper packing
    struct ReferralData {
        gtUint64 encryptedReferralScore;    // Private: calculated referral score
        ctUint64 userEncryptedScore;        // Private: score encrypted for user viewing
        gtUint64 encryptedTotalRewards;     // Private: total rewards earned
        ctUint64 userEncryptedRewards;      // Private: rewards encrypted for user
        uint256 directReferralCount;        // Public: number of direct referrals
        uint256 totalReferralCount;         // Public: total referrals (all levels)
        uint256 lastActivityTimestamp;      // Public: last referral activity
        bool isActiveReferrer;              // Public: whether user can refer others
    }
    
    /// @notice Records individual referral relationships
    /// @dev Stores referrer information and activity metrics - optimized for storage
    /* solhint-disable-next-line gas-struct-packing */
    struct ReferralRecord {
        address referrer;                   // Who referred this user
        gtUint64 encryptedActivityScore;    // Private: activity score of referee
        uint256 timestamp;                  // When referred
        bool isActive;                      // Whether referral is still active
        uint8 level;                        // Referral level (1, 2, or 3)
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role identifier for referral managers
    bytes32 public constant REFERRAL_MANAGER_ROLE = keccak256("REFERRAL_MANAGER_ROLE");
    
    /// @notice Minimum score required to become an eligible referrer
    uint256 public constant MIN_REFERRAL_SCORE = 100;
    
    /// @notice Period after which referrals decay (6 months)
    uint256 public constant REFERRAL_DECAY_PERIOD = 180 days;
    
    /// @notice Maximum depth of referral tracking
    uint256 public constant MAX_REFERRAL_LEVELS = 3;
    
    /// @notice Base reward points for referrals
    uint256 public constant BASE_REFERRAL_REWARD = 100;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice User referral data storage
    mapping(address => ReferralData) public referralData;
    
    /// @notice Referral records by referee address
    mapping(address => ReferralRecord) public referralRecords;
    
    /// @notice Multi-level referral tracking tree
    /// @dev Maps referrer => level => list of referees
    mapping(address => mapping(uint8 => address[])) public referralTree;
    
    /// @notice Reverse lookup to find referrer of a user
    mapping(address => address) public referrerOf;
    
    /// @notice Quality score for each referrer
    mapping(address => uint256) public referralQualityScore;
    
    /// @notice Referral reward multipliers by level (basis points)
    /// @dev Level 1: 100%, Level 2: 50%, Level 3: 25%
    uint256[3] public levelMultipliers = [
        10000,  // Level 1: 100%
        5000,   // Level 2: 50%
        2500    // Level 3: 25%
    ];
    
    /// @notice Total number of referrals in the system
    uint256 public totalSystemReferrals;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidReferrer();
    error InvalidReferee();
    error CannotReferSelf();
    error AlreadyReferred();
    error ReferrerNotActiveReferrer();
    error InvalidReferralDepth();
    error UserNotActiveReferrer();
    error InvalidBatchSize();
    error ArrayLengthMismatch();
    error InvalidMultiplier();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initializes the referral system
     * @param _admin Admin address with full control
     * @param _reputationCore Address of the reputation core contract
     */
    constructor(
        address _admin,
        address _reputationCore
    ) ReputationSystemBase(_admin, _reputationCore) {
        _grantRole(REFERRAL_MANAGER_ROLE, _admin);
        
        // Set default weight for referral component
        componentWeights[COMPONENT_REFERRAL_ACTIVITY] = 1000; // 10%
    }
    
    // =============================================================================
    // REFERRAL MANAGEMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Records a new referral relationship
     * @dev Only callable by REFERRAL_MANAGER_ROLE
     * @param referrer Address of the user making the referral
     * @param referee Address of the user being referred
     * @param activityScore Initial encrypted activity score of referee
     */
    function recordReferral(
        address referrer,
        address referee,
        itUint64 calldata activityScore
    ) external override whenNotPaused nonReentrant onlyRole(REFERRAL_MANAGER_ROLE) {
        if (referrer == address(0)) revert InvalidReferrer();
        if (referee == address(0)) revert InvalidReferee();
        if (referrer == referee) revert CannotReferSelf();
        if (referrerOf[referee] != address(0)) revert AlreadyReferred();
        if (!referralData[referrer].isActiveReferrer && 
            referralData[referrer].directReferralCount != 0) revert ReferrerNotActiveReferrer();
        
        // Validate activity score
        gtUint64 gtActivityScore = _validateInput(activityScore);
        
        // Create referral record
        referralRecords[referee] = ReferralRecord({
            referrer: referrer,
            /* solhint-disable-next-line not-rely-on-time */
            timestamp: block.timestamp,
            encryptedActivityScore: gtActivityScore,
            level: 1,
            isActive: true
        });
        
        // Update referrer data
        ReferralData storage referrerData = referralData[referrer];
        ++referrerData.directReferralCount;
        ++referrerData.totalReferralCount;
        /* solhint-disable-next-line not-rely-on-time */
        referrerData.lastActivityTimestamp = block.timestamp;
        referrerData.isActiveReferrer = true;
        
        // Add to referral tree
        referralTree[referrer][1].push(referee);
        referrerOf[referee] = referrer;
        
        // Update multi-level referrals
        _updateMultiLevelReferrals(referrer, referee);
        
        // Calculate and add referral reward
        _processReferralReward(referrer, 1, gtActivityScore);
        
        ++totalSystemReferrals;
        
        /* solhint-disable-next-line not-rely-on-time */
        emit ReferralRecorded(referrer, referee, block.timestamp);
    }
    
    /**
     * @notice Processes and adds referral rewards
     * @dev Only callable by REFERRAL_MANAGER_ROLE
     * @param referrer Address of the referrer receiving rewards
     * @param rewardAmount Encrypted reward amount to add
     */
    function processReferralReward(
        address referrer,
        itUint64 calldata rewardAmount
    ) external override whenNotPaused onlyRole(REFERRAL_MANAGER_ROLE) {
        if (!referralData[referrer].isActiveReferrer) revert UserNotActiveReferrer();
        
        gtUint64 gtReward = _validateInput(rewardAmount);
        
        ReferralData storage data = referralData[referrer];
        
        // Add to total rewards
        if (isMpcAvailable) {
            data.encryptedTotalRewards = MpcCore.add(data.encryptedTotalRewards, gtReward);
            data.userEncryptedRewards = MpcCore.offBoardToUser(
                data.encryptedTotalRewards,
                referrer
            );
        } else {
            uint64 currentRewards = uint64(gtUint64.unwrap(data.encryptedTotalRewards));
            uint64 addReward = uint64(gtUint64.unwrap(gtReward));
            data.encryptedTotalRewards = gtUint64.wrap(currentRewards + addReward);
            data.userEncryptedRewards = ctUint64.wrap(currentRewards + addReward);
        }
        
        /* solhint-disable-next-line not-rely-on-time */
        data.lastActivityTimestamp = block.timestamp;
        
        // Update reputation component
        _updateReputationInCore(referrer, COMPONENT_REFERRAL_ACTIVITY, rewardAmount);
        
        /* solhint-disable-next-line not-rely-on-time */
        emit ReferralRewardProcessed(referrer, block.timestamp);
    }
    
    /**
     * @notice Deactivates a referral relationship
     * @dev Used for fraud prevention or abuse cases
     * @param referee Address of the referee to deactivate
     * @param reason String explaining the deactivation reason
     */
    function deactivateReferral(
        address referee,
        string calldata reason
    ) external whenNotPaused onlyRole(REFERRAL_MANAGER_ROLE) {
        ReferralRecord storage record = referralRecords[referee];
        if (!record.isActive) revert AlreadyReferred();
        
        record.isActive = false;
        
        // Reduce referrer's counts
        address referrer = record.referrer;
        if (referrer != address(0)) {
            ReferralData storage referrerData = referralData[referrer];
            if (referrerData.directReferralCount > 0) {
                --referrerData.directReferralCount;
            }
            if (referrerData.totalReferralCount > 0) {
                --referrerData.totalReferralCount;
            }
            
            // Update quality score
            if (referralQualityScore[referrer] > 0) {
                --referralQualityScore[referrer];
            }
        }
        
        /* solhint-disable-next-line not-rely-on-time */
        emit ReferralDeactivated(referee, referrer, reason, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Gets the current referral score for a user
     * @dev Applies decay based on time since last activity
     * @param user Address to query
     * @return Encrypted referral score with decay applied
     */
    function getReferralScore(address user) external override returns (gtUint64) {
        ReferralData storage data = referralData[user];
        
        // Apply decay
        /* solhint-disable not-rely-on-time */
        uint256 timeSinceActivity = block.timestamp - data.lastActivityTimestamp;
        /* solhint-enable not-rely-on-time */
        if (timeSinceActivity > REFERRAL_DECAY_PERIOD) {
            return gtUint64.wrap(0);
        }
        
        // Calculate score with decay
        if (isMpcAvailable && timeSinceActivity > 0) {
            uint64 decayFactor = uint64(
                (REFERRAL_DECAY_PERIOD - timeSinceActivity) * 10000 / REFERRAL_DECAY_PERIOD
            );
            gtUint64 factor = MpcCore.setPublic64(decayFactor);
            gtUint64 decayedScore = MpcCore.mul(data.encryptedReferralScore, factor);
            return MpcCore.div(decayedScore, MpcCore.setPublic64(10000));
        }
        
        return data.encryptedReferralScore;
    }
    
    /**
     * @notice Gets total referral rewards earned by a user
     * @param user Address to query
     * @return Encrypted total rewards
     */
    function getTotalReferralRewards(address user) external override returns (gtUint64) {
        return referralData[user].encryptedTotalRewards;
    }
    
    /**
     * @notice Gets the direct referral count for a user
     * @param user Address to query
     * @return Number of direct referrals
     */
    function getReferralCount(address user) external view override returns (uint256) {
        return referralData[user].directReferralCount;
    }
    
    /**
     * @notice Checks if a user is eligible to make referrals
     * @param user Address to check
     * @return True if user can make referrals
     */
    function isEligibleReferrer(address user) external view override returns (bool) {
        ReferralData storage data = referralData[user];
        return data.isActiveReferrer && 
               /* solhint-disable-next-line not-rely-on-time */
               (block.timestamp - data.lastActivityTimestamp) < REFERRAL_DECAY_PERIOD + 1;
    }
    
    /**
     * @notice Gets user's encrypted referral data
     * @dev Only the user can view their own encrypted data
     * @param user Address to query (must match msg.sender)
     * @return score Encrypted referral score
     * @return rewards Encrypted total rewards
     */
    function getUserEncryptedData(address user) external view returns (
        ctUint64 score,
        ctUint64 rewards
    ) {
        if (msg.sender != user) revert InvalidReferrer();
        ReferralData storage data = referralData[user];
        return (data.userEncryptedScore, data.userEncryptedRewards);
    }
    
    /**
     * @notice Gets referral tree at a specific level
     * @param referrer Address of the referrer
     * @param level Referral level to query (1-3)
     * @return Array of referee addresses at the specified level
     */
    function getReferralTree(address referrer, uint8 level) 
        external 
        view 
        returns (address[] memory) 
    {
        if (level == 0 || level > MAX_REFERRAL_LEVELS) revert InvalidReferralDepth();
        return referralTree[referrer][level];
    }
    
    /**
     * @notice Gets the referral chain up from a user
     * @dev Returns up to 3 levels of referrers
     * @param user Starting address
     * @return chain Array of referrer addresses
     * @return levels Array of corresponding levels
     */
    function getReferralChain(address user) external view returns (
        address[] memory chain,
        uint8[] memory levels
    ) {
        chain = new address[](MAX_REFERRAL_LEVELS);
        levels = new uint8[](MAX_REFERRAL_LEVELS);
        
        address current = user;
        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; ++i) {
            address referrer = referrerOf[current];
            if (referrer == address(0)) break;
            
            chain[i] = referrer;
            levels[i] = uint8(i + 1);
            current = referrer;
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Updates referral reward multipliers
     * @dev Only callable by ADMIN_ROLE
     * @param newMultipliers Array of 3 multipliers in basis points
     */
    function updateLevelMultipliers(uint256[3] calldata newMultipliers) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        for (uint256 i = 0; i < 3; ++i) {
            if (newMultipliers[i] > BASIS_POINTS) revert InvalidMultiplier();
        }
        levelMultipliers = newMultipliers;
        emit LevelMultipliersUpdated(newMultipliers);
    }
    
    /**
     * @notice Manually sets referrer eligibility
     * @dev Only callable by REFERRAL_MANAGER_ROLE
     * @param user User address to update
     * @param eligible Whether user should be eligible
     */
    function setReferrerEligibility(address user, bool eligible) 
        external 
        onlyRole(REFERRAL_MANAGER_ROLE) 
    {
        referralData[user].isActiveReferrer = eligible;
        emit ReferrerEligibilitySet(user, eligible);
    }
    
    /**
     * @notice Updates referral quality score
     * @dev Only callable by REFERRAL_MANAGER_ROLE
     * @param referrer Referrer address
     * @param score New quality score
     */
    function updateQualityScore(address referrer, uint256 score) 
        external 
        onlyRole(REFERRAL_MANAGER_ROLE) 
    {
        referralQualityScore[referrer] = score;
        emit QualityScoreUpdated(referrer, score);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Updates multi-level referral tracking
     * @dev Internal function to propagate referrals up the tree
     * @param directReferrer Direct referrer address
     * @param referee New referee address
     */
    function _updateMultiLevelReferrals(address directReferrer, address referee) internal {
        address level2Referrer = referrerOf[directReferrer];
        if (level2Referrer != address(0)) {
            referralTree[level2Referrer][2].push(referee);
            ++referralData[level2Referrer].totalReferralCount;
            
            address level3Referrer = referrerOf[level2Referrer];
            if (level3Referrer != address(0)) {
                referralTree[level3Referrer][3].push(referee);
                ++referralData[level3Referrer].totalReferralCount;
            }
        }
    }
    
    /**
     * @notice Processes referral rewards with level multipliers
     * @dev Internal recursive function for multi-level rewards
     * @param referrer Referrer to reward
     * @param level Current referral level
     * @param activityScore Activity score for reward calculation
     */
    function _processReferralReward(
        address referrer,
        uint8 level,
        gtUint64 activityScore
    ) internal {
        if (level == 0 || level > MAX_REFERRAL_LEVELS) revert InvalidReferralDepth();
        
        // Calculate reward based on activity and level
        gtUint64 baseReward;
        if (isMpcAvailable) {
            baseReward = MpcCore.setPublic64(uint64(BASE_REFERRAL_REWARD));
            
            // Apply level multiplier
            gtUint64 multiplier = MpcCore.setPublic64(uint64(levelMultipliers[level - 1]));
            gtUint64 levelReward = MpcCore.mul(baseReward, multiplier);
            levelReward = MpcCore.div(levelReward, MpcCore.setPublic64(10000));
            
            // Add activity bonus
            gtUint64 activityBonus = MpcCore.div(activityScore, MpcCore.setPublic64(1000));
            gtUint64 totalReward = MpcCore.add(levelReward, activityBonus);
            
            // Update referrer data
            ReferralData storage data = referralData[referrer];
            data.encryptedReferralScore = MpcCore.add(data.encryptedReferralScore, totalReward);
            data.userEncryptedScore = MpcCore.offBoardToUser(data.encryptedReferralScore, referrer);
            data.encryptedTotalRewards = MpcCore.add(data.encryptedTotalRewards, totalReward);
            data.userEncryptedRewards = MpcCore.offBoardToUser(data.encryptedTotalRewards, referrer);
        } else {
            // Fallback calculation
            uint64 base = uint64(BASE_REFERRAL_REWARD);
            uint64 multiplier = uint64(levelMultipliers[level - 1]);
            uint64 levelReward = (base * multiplier) / 10000;
            uint64 activityBonus = uint64(gtUint64.unwrap(activityScore)) / 1000;
            uint64 totalReward = levelReward + activityBonus;
            
            ReferralData storage data = referralData[referrer];
            uint64 currentScore = uint64(gtUint64.unwrap(data.encryptedReferralScore));
            uint64 currentRewards = uint64(gtUint64.unwrap(data.encryptedTotalRewards));
            
            data.encryptedReferralScore = gtUint64.wrap(currentScore + totalReward);
            data.userEncryptedScore = ctUint64.wrap(currentScore + totalReward);
            data.encryptedTotalRewards = gtUint64.wrap(currentRewards + totalReward);
            data.userEncryptedRewards = ctUint64.wrap(currentRewards + totalReward);
        }
        
        // Process rewards for upper levels
        if (level < MAX_REFERRAL_LEVELS) {
            address upperReferrer = referrerOf[referrer];
            if (upperReferrer != address(0)) {
                _processReferralReward(upperReferrer, level + 1, activityScore);
            }
        }
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when a referral is deactivated
    /// @param referee Address of the deactivated referee
    /// @param referrer Address of the original referrer
    /// @param reason Reason for deactivation
    /// @param timestamp When the deactivation occurred
    event ReferralDeactivated(
        address indexed referee,
        address indexed referrer,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when level multipliers are updated
    /// @param multipliers New multiplier values
    event LevelMultipliersUpdated(uint256[3] multipliers);
    
    /// @notice Emitted when referrer eligibility is manually set
    /// @param user User whose eligibility was updated
    /// @param eligible New eligibility status
    event ReferrerEligibilitySet(address indexed user, bool indexed eligible);
    
    /// @notice Emitted when a referrer's quality score is updated
    /// @param referrer Referrer whose score was updated
    /// @param score New quality score
    event QualityScoreUpdated(address indexed referrer, uint256 indexed score);
}