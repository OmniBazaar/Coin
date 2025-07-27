// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReputationSystemBase} from "./ReputationSystemBase.sol";
import {IReferralSystem} from "./interfaces/IReputationSystem.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title OmniCoinReferralSystem
 * @dev Referral tracking and rewards module for the reputation system
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
    
    struct ReferralData {
        gtUint64 encryptedReferralScore;    // Private: calculated referral score
        ctUint64 userEncryptedScore;        // Private: score encrypted for user viewing
        uint256 directReferralCount;        // Public: number of direct referrals
        uint256 totalReferralCount;         // Public: total referrals (all levels)
        gtUint64 encryptedTotalRewards;     // Private: total rewards earned
        ctUint64 userEncryptedRewards;      // Private: rewards encrypted for user
        uint256 lastActivityTimestamp;      // Public: last referral activity
        bool isActiveReferrer;              // Public: whether user can refer others
    }
    
    struct ReferralRecord {
        address referrer;                   // Who referred this user
        uint256 timestamp;                  // When referred
        gtUint64 encryptedActivityScore;    // Private: activity score of referee
        uint8 level;                        // Referral level (1, 2, or 3)
        bool isActive;                      // Whether referral is still active
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant REFERRAL_MANAGER_ROLE = keccak256("REFERRAL_MANAGER_ROLE");
    
    uint256 public constant MIN_REFERRAL_SCORE = 100;      // Minimum score to be eligible referrer
    uint256 public constant REFERRAL_DECAY_PERIOD = 180 days; // Referrals decay after 6 months
    uint256 public constant MAX_REFERRAL_LEVELS = 3;       // Track up to 3 levels
    uint256 public constant BASE_REFERRAL_REWARD = 100;    // Base reward points
    
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
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    // Referral reward multipliers by level (basis points)
    uint256[3] public levelMultipliers = [
        10000,  // Level 1: 100%
        5000,   // Level 2: 50%
        2500    // Level 3: 25%
    ];
    
    /// @dev User referral data
    mapping(address => ReferralData) public referralData;
    
    /// @dev Referral records: referee => referral record
    mapping(address => ReferralRecord) public referralRecords;
    
    /// @dev Multi-level referral tracking: referrer => level => list of referees
    mapping(address => mapping(uint8 => address[])) public referralTree;
    
    /// @dev Reverse lookup: referee => referrer
    mapping(address => address) public referrerOf;
    
    /// @dev Total system referrals
    uint256 public totalSystemReferrals;
    
    /// @dev Quality metrics
    mapping(address => uint256) public referralQualityScore;
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
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
     * @dev Record a new referral
     * @param referrer Referrer address
     * @param referee Referee address
     * @param activityScore Initial activity score of referee
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
            timestamp: block.timestamp,
            encryptedActivityScore: gtActivityScore,
            level: 1,
            isActive: true
        });
        
        // Update referrer data
        ReferralData storage referrerData = referralData[referrer];
        referrerData.directReferralCount++;
        referrerData.totalReferralCount++;
        referrerData.lastActivityTimestamp = block.timestamp;
        referrerData.isActiveReferrer = true;
        
        // Add to referral tree
        referralTree[referrer][1].push(referee);
        referrerOf[referee] = referrer;
        
        // Update multi-level referrals
        _updateMultiLevelReferrals(referrer, referee);
        
        // Calculate and add referral reward
        _processReferralReward(referrer, 1, gtActivityScore);
        
        totalSystemReferrals++;
        
        emit ReferralRecorded(referrer, referee, block.timestamp);
    }
    
    /**
     * @dev Process referral reward
     * @param referrer Referrer address
     * @param rewardAmount Encrypted reward amount
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
        
        data.lastActivityTimestamp = block.timestamp;
        
        // Update reputation component
        _updateReputationInCore(referrer, COMPONENT_REFERRAL_ACTIVITY, rewardAmount);
        
        emit ReferralRewardProcessed(referrer, block.timestamp);
    }
    
    /**
     * @dev Deactivate referral (e.g., for fraud or abuse)
     * @param referee Referee address
     * @param reason Reason for deactivation
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
                referrerData.directReferralCount--;
            }
            if (referrerData.totalReferralCount > 0) {
                referrerData.totalReferralCount--;
            }
            
            // Update quality score
            if (referralQualityScore[referrer] > 0) {
                referralQualityScore[referrer]--;
            }
        }
        
        emit ReferralDeactivated(referee, referrer, reason, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get referral score
     */
    function getReferralScore(address user) external override returns (gtUint64) {
        ReferralData storage data = referralData[user];
        
        // Apply decay
        uint256 timeSinceActivity = block.timestamp - data.lastActivityTimestamp;
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
     * @dev Get referral count
     */
    function getReferralCount(address user) external view override returns (uint256) {
        return referralData[user].directReferralCount;
    }
    
    /**
     * @dev Get total referral rewards
     */
    function getTotalReferralRewards(address user) external override returns (gtUint64) {
        return referralData[user].encryptedTotalRewards;
    }
    
    /**
     * @dev Check if user is eligible referrer
     */
    function isEligibleReferrer(address user) external view override returns (bool) {
        ReferralData storage data = referralData[user];
        return data.isActiveReferrer && 
               (block.timestamp - data.lastActivityTimestamp) <= REFERRAL_DECAY_PERIOD;
    }
    
    /**
     * @dev Get user's encrypted referral data (for user viewing)
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
     * @dev Get referral tree for a user
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
     * @dev Get referral chain (up to 3 levels up)
     */
    function getReferralChain(address user) external view returns (
        address[] memory chain,
        uint8[] memory levels
    ) {
        chain = new address[](MAX_REFERRAL_LEVELS);
        levels = new uint8[](MAX_REFERRAL_LEVELS);
        
        address current = user;
        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            address referrer = referrerOf[current];
            if (referrer == address(0)) break;
            
            chain[i] = referrer;
            levels[i] = i + 1;
            current = referrer;
        }
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update multi-level referrals
     */
    function _updateMultiLevelReferrals(address directReferrer, address referee) internal {
        address level2Referrer = referrerOf[directReferrer];
        if (level2Referrer != address(0)) {
            referralTree[level2Referrer][2].push(referee);
            referralData[level2Referrer].totalReferralCount++;
            
            address level3Referrer = referrerOf[level2Referrer];
            if (level3Referrer != address(0)) {
                referralTree[level3Referrer][3].push(referee);
                referralData[level3Referrer].totalReferralCount++;
            }
        }
    }
    
    /**
     * @dev Process referral reward with level multiplier
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
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update level multipliers
     */
    function updateLevelMultipliers(uint256[3] calldata newMultipliers) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        for (uint256 i = 0; i < 3; i++) {
            if (newMultipliers[i] > BASIS_POINTS) revert InvalidReferralDepth();
        }
        levelMultipliers = newMultipliers;
        emit LevelMultipliersUpdated(newMultipliers);
    }
    
    /**
     * @dev Set referrer eligibility manually
     */
    function setReferrerEligibility(address user, bool eligible) 
        external 
        onlyRole(REFERRAL_MANAGER_ROLE) 
    {
        referralData[user].isActiveReferrer = eligible;
        emit ReferrerEligibilitySet(user, eligible);
    }
    
    /**
     * @dev Update quality score
     */
    function updateQualityScore(address referrer, uint256 score) 
        external 
        onlyRole(REFERRAL_MANAGER_ROLE) 
    {
        referralQualityScore[referrer] = score;
        emit QualityScoreUpdated(referrer, score);
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ReferralDeactivated(
        address indexed referee,
        address indexed referrer,
        string reason,
        uint256 timestamp
    );
    
    event LevelMultipliersUpdated(uint256[3] multipliers);
    event ReferrerEligibilitySet(address indexed user, bool eligible);
    event QualityScoreUpdated(address indexed referrer, uint256 score);
}