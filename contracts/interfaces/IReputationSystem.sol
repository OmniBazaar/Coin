// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title IReputationSystem
 * @dev Common interface for all reputation system components
 */
interface IReputationSystem {
    
    // Component IDs
    function COMPONENT_TRANSACTION_SUCCESS() external view returns (uint8);
    function COMPONENT_TRANSACTION_DISPUTE() external view returns (uint8);
    function COMPONENT_ARBITRATION_PERFORMANCE() external view returns (uint8);
    function COMPONENT_GOVERNANCE_PARTICIPATION() external view returns (uint8);
    function COMPONENT_VALIDATOR_PERFORMANCE() external view returns (uint8);
    function COMPONENT_MARKETPLACE_BEHAVIOR() external view returns (uint8);
    function COMPONENT_COMMUNITY_ENGAGEMENT() external view returns (uint8);
    function COMPONENT_UPTIME_RELIABILITY() external view returns (uint8);
    function COMPONENT_TRUST_SCORE() external view returns (uint8);
    function COMPONENT_REFERRAL_ACTIVITY() external view returns (uint8);
    function COMPONENT_IDENTITY_VERIFICATION() external view returns (uint8);
    
    // MPC availability
    function isMpcAvailable() external view returns (bool);
    function setMpcAvailability(bool _available) external;
    
    // Component weight management
    function getComponentWeight(uint8 componentId) external view returns (uint256);
    function setComponentWeight(uint8 componentId, uint256 weight) external;
    
    // Events
    event ReputationUpdated(
        address indexed user,
        uint8 indexed component,
        uint256 timestamp
    );
    
    event ComponentWeightUpdated(
        uint8 indexed componentId,
        uint256 newWeight,
        uint256 timestamp
    );
}

/**
 * @title IReputationCore
 * @dev Interface for core reputation functionality
 */
interface IReputationCore is IReputationSystem {
    
    // Reputation queries
    function getPublicReputationTier(address user) external view returns (uint256);
    function isEligibleValidator(address user) external view returns (bool);
    function isEligibleArbitrator(address user) external view returns (bool);
    function getTotalInteractions(address user) external view returns (uint256);
    
    // Privacy settings
    function setPrivacyEnabled(address user, bool enabled) external;
    function isPrivacyEnabled(address user) external view returns (bool);
    
    // Component updates (called by other modules)
    function updateReputationComponent(
        address user,
        uint8 componentId,
        itUint64 calldata value
    ) external;
    
    // Reputation calculation
    function calculateTotalReputation(address user) external returns (gtUint64);
}

/**
 * @title IIdentityVerification
 * @dev Interface for identity verification module
 */
interface IIdentityVerification is IReputationSystem {
    
    // Identity tiers
    function IDENTITY_UNVERIFIED() external view returns (uint8);
    function IDENTITY_EMAIL() external view returns (uint8);
    function IDENTITY_PHONE() external view returns (uint8);
    function IDENTITY_BASIC_ID() external view returns (uint8);
    function IDENTITY_ENHANCED_ID() external view returns (uint8);
    function IDENTITY_BIOMETRIC() external view returns (uint8);
    function IDENTITY_PREMIUM_INDIVIDUAL() external view returns (uint8);
    function IDENTITY_COMMERCIAL() external view returns (uint8);
    function IDENTITY_CORPORATE() external view returns (uint8);
    
    // Identity verification
    function verifyIdentity(
        address user,
        uint8 tier,
        bytes32 proofHash,
        itUint64 calldata score
    ) external;
    
    function getIdentityTier(address user) external view returns (uint8);
    function getIdentityScore(address user) external returns (gtUint64);
    function isIdentityExpired(address user) external view returns (bool);
    
    // Events
    event IdentityVerified(
        address indexed user,
        uint8 tier,
        bytes32 proofHash,
        uint256 timestamp
    );
}

/**
 * @title ITrustSystem
 * @dev Interface for trust system (DPoS/COTI PoT)
 */
interface ITrustSystem is IReputationSystem {
    
    // DPoS voting
    function castDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external;
    
    function withdrawDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external;
    
    // Trust queries
    function getTrustScore(address user) external returns (gtUint64);
    function getVoterCount(address user) external view returns (uint256);
    function getCotiProofOfTrustScore(address user) external view returns (uint256);
    
    // COTI PoT integration
    function updateCotiPoTScore(address user, uint256 score) external;
    function setUseCotiPoT(address user, bool useCoti) external;
    
    // Events
    event DPoSVoteCast(
        address indexed voter,
        address indexed candidate,
        uint256 timestamp
    );
    
    event TrustScoreUpdated(
        address indexed user,
        uint256 timestamp
    );
}

/**
 * @title IReferralSystem
 * @dev Interface for referral system
 */
interface IReferralSystem is IReputationSystem {
    
    // Referral management
    function recordReferral(
        address referrer,
        address referee,
        itUint64 calldata activityScore
    ) external;
    
    function processReferralReward(
        address referrer,
        itUint64 calldata rewardAmount
    ) external;
    
    // Referral queries
    function getReferralScore(address user) external returns (gtUint64);
    function getReferralCount(address user) external view returns (uint256);
    function getTotalReferralRewards(address user) external returns (gtUint64);
    function isEligibleReferrer(address user) external view returns (bool);
    
    // Events
    event ReferralRecorded(
        address indexed referrer,
        address indexed referee,
        uint256 timestamp
    );
    
    event ReferralRewardProcessed(
        address indexed referrer,
        uint256 timestamp
    );
}