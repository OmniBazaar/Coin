// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ReputationSystemBase.sol";
import "./base/RegistryAware.sol";

/**
 * @title ReputationSystem
 * @dev Concrete implementation of ReputationSystemBase with Registry integration
 */
contract ReputationSystem is ReputationSystemBase, RegistryAware {
    
    // State variables for reputation tracking
    mapping(address => uint256) public reputationScores;
    mapping(address => bool) public verifiedUsers;
    mapping(address => uint256) public userActivityCount;
    mapping(address => uint256) public lastActivityTimestamp;
    mapping(address => mapping(uint8 => uint256)) public componentScores;
    
    uint256 public constant DEFAULT_REPUTATION = 100;
    uint256 public constant MAX_REPUTATION = 1000;
    uint256 public constant MIN_REPUTATION = 0;
    
    // Events
    event ReputationUpdated(address indexed user, uint256 newScore, string reason);
    event UserVerified(address indexed user);
    event ComponentScoreUpdated(address indexed user, uint8 component, uint256 score);
    
    constructor(
        address _registry,
        address _admin
    ) ReputationSystemBase(_admin, address(this)) RegistryAware(_registry) {
        // Roles are already granted in base constructor
        _grantRole(REPUTATION_UPDATER_ROLE, _admin);
        
        // Set default component weights
        componentWeights[COMPONENT_TRANSACTION_SUCCESS] = 2000; // 20%
        componentWeights[COMPONENT_MARKETPLACE_BEHAVIOR] = 2000; // 20%
        componentWeights[COMPONENT_TRUST_SCORE] = 2000; // 20%
        componentWeights[COMPONENT_COMMUNITY_ENGAGEMENT] = 1000; // 10%
        componentWeights[COMPONENT_IDENTITY_VERIFICATION] = 3000; // 30%
    }
    
    /**
     * @dev Update reputation based on successful transaction
     * @param user User address
     * @param amount Transaction amount
     * @param success Whether transaction was successful
     */
    function updateReputationForTransaction(
        address user,
        uint256 amount,
        bool success
    ) external onlyRole(REPUTATION_UPDATER_ROLE) {
        if (success) {
            // Increase reputation for successful transaction
            uint256 points = calculateTransactionPoints(amount);
            _updateReputation(user, int256(points), "Successful transaction");
            _updateComponentScore(user, COMPONENT_TRANSACTION_SUCCESS, points);
        } else {
            // Slight decrease for failed transaction
            _updateReputation(user, -10, "Failed transaction");
        }
        
        userActivityCount[user]++;
        lastActivityTimestamp[user] = block.timestamp;
    }
    
    /**
     * @dev Update reputation for marketplace activity
     * @param user User address
     * @param activityType Type of activity (0=listing, 1=purchase, 2=review)
     * @param value Associated value
     */
    function updateReputationForActivity(
        address user,
        uint256 activityType,
        uint256 value
    ) external onlyRole(REPUTATION_UPDATER_ROLE) {
        int256 change;
        string memory reason;
        uint8 component = COMPONENT_MARKETPLACE_BEHAVIOR;
        
        if (activityType == 0) { // Listing
            change = 5;
            reason = "Created listing";
        } else if (activityType == 1) { // Purchase
            change = int256(calculateTransactionPoints(value));
            reason = "Completed purchase";
            component = COMPONENT_TRANSACTION_SUCCESS;
        } else if (activityType == 2) { // Review
            change = 3;
            reason = "Provided review";
            component = COMPONENT_COMMUNITY_ENGAGEMENT;
        } else {
            revert("Invalid activity type");
        }
        
        _updateReputation(user, change, reason);
        _updateComponentScore(user, component, uint256(change));
        userActivityCount[user]++;
        lastActivityTimestamp[user] = block.timestamp;
    }
    
    /**
     * @dev Internal function to update reputation
     * @param user User address
     * @param change Reputation change (positive or negative)
     * @param reason Reason for change
     */
    function _updateReputation(address user, int256 change, string memory reason) internal {
        uint256 currentScore = reputationScores[user];
        if (currentScore == 0) {
            currentScore = DEFAULT_REPUTATION;
        }
        
        int256 newScore = int256(currentScore) + change;
        
        // Bound the score
        if (newScore < int256(MIN_REPUTATION)) {
            newScore = int256(MIN_REPUTATION);
        } else if (newScore > int256(MAX_REPUTATION)) {
            newScore = int256(MAX_REPUTATION);
        }
        
        reputationScores[user] = uint256(newScore);
        emit ReputationUpdated(user, uint256(newScore), reason);
    }
    
    /**
     * @dev Update component score
     * @param user User address
     * @param component Component ID
     * @param points Points to add
     */
    function _updateComponentScore(address user, uint8 component, uint256 points) internal {
        componentScores[user][component] += points;
        emit ComponentScoreUpdated(user, component, componentScores[user][component]);
    }
    
    /**
     * @dev Calculate reputation points based on transaction amount
     * @param amount Transaction amount
     * @return points Reputation points to award
     */
    function calculateTransactionPoints(uint256 amount) public pure returns (uint256) {
        // Simple linear calculation, could be more complex
        // 1 point per 100 tokens, max 100 points
        uint256 points = amount / (100 * 10**6); // Assuming 6 decimals
        if (points > 100) {
            points = 100;
        }
        return points == 0 ? 1 : points; // Minimum 1 point
    }
    
    /**
     * @dev Check if user is considered active
     * @param user User address
     * @return isActive Whether user has been active recently
     */
    function isActiveUser(address user) external view returns (bool) {
        return lastActivityTimestamp[user] > block.timestamp - 30 days;
    }
    
    /**
     * @dev Get user reputation score
     * @param user User address
     * @return Reputation score
     */
    function getReputationScore(address user) external view returns (uint256) {
        uint256 score = reputationScores[user];
        return score == 0 ? DEFAULT_REPUTATION : score;
    }
    
    /**
     * @dev Verify a user (admin only)
     * @param user User to verify
     */
    function verifyUser(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifiedUsers[user] = true;
        _updateComponentScore(user, COMPONENT_IDENTITY_VERIFICATION, 100);
        _updateReputation(user, 50, "Identity verified");
        emit UserVerified(user);
    }
    
    /**
     * @dev Get comprehensive user stats
     * @param user User address
     * @return reputation Current reputation score
     * @return activityCount Total activities
     * @return lastActive Last activity timestamp
     * @return isVerified Verification status
     */
    function getUserStats(address user) external view returns (
        uint256 reputation,
        uint256 activityCount,
        uint256 lastActive,
        bool isVerified
    ) {
        reputation = reputationScores[user] == 0 ? DEFAULT_REPUTATION : reputationScores[user];
        activityCount = userActivityCount[user];
        lastActive = lastActivityTimestamp[user];
        isVerified = verifiedUsers[user];
    }
    
    /**
     * @dev Batch update reputations (for gas efficiency)
     * @param users Array of user addresses
     * @param changes Array of reputation changes
     * @param reasons Array of reasons
     */
    function batchUpdateReputation(
        address[] calldata users,
        int256[] calldata changes,
        string[] calldata reasons
    ) external onlyRole(REPUTATION_UPDATER_ROLE) {
        require(
            users.length == changes.length && changes.length == reasons.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < users.length; i++) {
            _updateReputation(users[i], changes[i], reasons[i]);
        }
    }
    
    /**
     * @dev Emergency reputation reset (admin only)
     * @param user User to reset
     */
    function emergencyResetReputation(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reputationScores[user] = DEFAULT_REPUTATION;
        verifiedUsers[user] = false;
        lastActivityTimestamp[user] = 0;
        userActivityCount[user] = 0;
        
        // Reset all component scores
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            componentScores[user][i] = 0;
        }
        
        emit ReputationUpdated(user, DEFAULT_REPUTATION, "Emergency reset");
    }
    
    /**
     * @dev Calculate weighted reputation score
     * @param user User address
     * @return Weighted reputation score
     */
    function getWeightedReputationScore(address user) external view returns (uint256) {
        uint256 totalWeight = 0;
        uint256 weightedScore = 0;
        
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            uint256 weight = componentWeights[i];
            if (weight > 0) {
                totalWeight += weight;
                weightedScore += componentScores[user][i] * weight;
            }
        }
        
        if (totalWeight == 0) {
            return reputationScores[user] == 0 ? DEFAULT_REPUTATION : reputationScores[user];
        }
        
        return weightedScore / totalWeight;
    }
    
    // setMpcAvailability is already implemented in base class
}