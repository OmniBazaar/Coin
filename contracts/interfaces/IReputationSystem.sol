// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {gtUint64, itUint64} from "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title IReputationSystem
 * @author OmniCoin Development Team
 * @notice Common interface for all reputation system components
 * @dev Defines core reputation functionality and component constants
 */
interface IReputationSystem {
    
    // Component IDs
    /// @notice Component ID for transaction success tracking
    /// @return The component ID for transaction success
    function COMPONENT_TRANSACTION_SUCCESS() external view returns (uint8);
    /// @notice Component ID for transaction dispute tracking
    /// @return The component ID for transaction disputes
    function COMPONENT_TRANSACTION_DISPUTE() external view returns (uint8);
    /// @notice Component ID for arbitration performance tracking
    /// @return The component ID for arbitration performance
    function COMPONENT_ARBITRATION_PERFORMANCE() external view returns (uint8);
    /// @notice Component ID for governance participation tracking
    /// @return The component ID for governance participation
    function COMPONENT_GOVERNANCE_PARTICIPATION() external view returns (uint8);
    /// @notice Component ID for validator performance tracking
    /// @return The component ID for validator performance
    function COMPONENT_VALIDATOR_PERFORMANCE() external view returns (uint8);
    /// @notice Component ID for marketplace behavior tracking
    /// @return The component ID for marketplace behavior
    function COMPONENT_MARKETPLACE_BEHAVIOR() external view returns (uint8);
    /// @notice Component ID for community engagement tracking
    /// @return The component ID for community engagement
    function COMPONENT_COMMUNITY_ENGAGEMENT() external view returns (uint8);
    /// @notice Component ID for uptime reliability tracking
    /// @return The component ID for uptime reliability
    function COMPONENT_UPTIME_RELIABILITY() external view returns (uint8);
    /// @notice Component ID for trust score tracking
    /// @return The component ID for trust score
    function COMPONENT_TRUST_SCORE() external view returns (uint8);
    /// @notice Component ID for referral activity tracking
    /// @return The component ID for referral activity
    function COMPONENT_REFERRAL_ACTIVITY() external view returns (uint8);
    /// @notice Component ID for identity verification tracking
    /// @return The component ID for identity verification
    function COMPONENT_IDENTITY_VERIFICATION() external view returns (uint8);
    
    // External functions
    /// @notice Set MPC availability status
    /// @param _available Whether MPC should be available
    function setMpcAvailability(bool _available) external;
    /// @notice Set the weight of a reputation component
    /// @param componentId The component ID to update
    /// @param weight The new weight value
    function setComponentWeight(uint8 componentId, uint256 weight) external;
    
    // View functions
    /// @notice Check if MPC functionality is available
    /// @return True if MPC is available, false otherwise
    function isMpcAvailable() external view returns (bool);
    /// @notice Get the weight of a reputation component
    /// @param componentId The component ID to query
    /// @return The weight value for the component
    function getComponentWeight(uint8 componentId) external view returns (uint256);
    
    // Events
    /// @notice Emitted when a user's reputation component is updated
    /// @param user The user whose reputation was updated
    /// @param component The component that was updated
    /// @param timestamp When the update occurred
    event ReputationUpdated(
        address indexed user,
        uint8 indexed component,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a component weight is changed
    /// @param componentId The component whose weight was updated
    /// @param newWeight The new weight value
    /// @param timestamp When the weight was updated
    event ComponentWeightUpdated(
        uint8 indexed componentId,
        uint256 indexed newWeight,
        uint256 indexed timestamp
    );
}

/**
 * @title IReputationCore
 * @author OmniCoin Development Team
 * @notice Interface for core reputation functionality
 * @dev Provides methods for reputation calculation and privacy management
 */
interface IReputationCore is IReputationSystem {
    
    // Reputation queries
    /// @notice Get the public reputation tier for a user
    /// @param user Address of the user to query
    /// @return The reputation tier value
    function getPublicReputationTier(address user) external view returns (uint256);
    /// @notice Check if a user is eligible to be a validator
    /// @param user Address of the user to check
    /// @return True if eligible, false otherwise
    function isEligibleValidator(address user) external view returns (bool);
    /// @notice Check if a user is eligible to be an arbitrator
    /// @param user Address of the user to check
    /// @return True if eligible, false otherwise
    function isEligibleArbitrator(address user) external view returns (bool);
    /// @notice Get the total number of interactions for a user
    /// @param user Address of the user to query
    /// @return Total interaction count
    function getTotalInteractions(address user) external view returns (uint256);
    
    // External functions
    /// @notice Enable or disable privacy mode for a user
    /// @param user Address of the user
    /// @param enabled Whether privacy should be enabled
    function setPrivacyEnabled(address user, bool enabled) external;
    /// @notice Update a specific reputation component for a user
    /// @param user Address of the user to update
    /// @param componentId The component ID to update
    /// @param value The new encrypted value for the component
    function updateReputationComponent(
        address user,
        uint8 componentId,
        itUint64 calldata value
    ) external;
    
    // View functions
    /// @notice Check if privacy mode is enabled for a user
    /// @param user Address of the user to check
    /// @return True if privacy is enabled, false otherwise
    function isPrivacyEnabled(address user) external view returns (bool);
    
    // Reputation calculation
    /// @notice Calculate the total reputation score for a user
    /// @param user Address of the user to calculate reputation for
    /// @return The encrypted total reputation score
    function calculateTotalReputation(address user) external returns (gtUint64);
}

/**
 * @title IIdentityVerification
 * @author OmniCoin Development Team
 * @notice Interface for identity verification module
 * @dev Handles different tiers of identity verification and scoring
 */
interface IIdentityVerification is IReputationSystem {
    
    // Identity tiers
    /// @notice Identity tier for unverified users
    /// @return The tier ID for unverified identity
    function IDENTITY_UNVERIFIED() external view returns (uint8);
    /// @notice Identity tier for email-verified users
    /// @return The tier ID for email verification
    function IDENTITY_EMAIL() external view returns (uint8);
    /// @notice Identity tier for phone-verified users
    /// @return The tier ID for phone verification
    function IDENTITY_PHONE() external view returns (uint8);
    /// @notice Identity tier for basic ID verification
    /// @return The tier ID for basic ID verification
    function IDENTITY_BASIC_ID() external view returns (uint8);
    /// @notice Identity tier for enhanced ID verification
    /// @return The tier ID for enhanced ID verification
    function IDENTITY_ENHANCED_ID() external view returns (uint8);
    /// @notice Identity tier for biometric verification
    /// @return The tier ID for biometric verification
    function IDENTITY_BIOMETRIC() external view returns (uint8);
    /// @notice Identity tier for premium individual verification
    /// @return The tier ID for premium individual verification
    function IDENTITY_PREMIUM_INDIVIDUAL() external view returns (uint8);
    /// @notice Identity tier for commercial entity verification
    /// @return The tier ID for commercial verification
    function IDENTITY_COMMERCIAL() external view returns (uint8);
    /// @notice Identity tier for corporate entity verification
    /// @return The tier ID for corporate verification
    function IDENTITY_CORPORATE() external view returns (uint8);
    
    // Identity verification
    /// @notice Verify a user's identity at a specific tier
    /// @param user Address of the user to verify
    /// @param tier The identity tier being verified
    /// @param proofHash Hash of the verification proof
    /// @param score Encrypted identity score
    function verifyIdentity(
        address user,
        uint8 tier,
        bytes32 proofHash,
        itUint64 calldata score
    ) external;
    
    /// @notice Get the current identity tier for a user
    /// @param user Address of the user to query
    /// @return The current identity tier
    function getIdentityTier(address user) external view returns (uint8);
    /// @notice Get the encrypted identity score for a user
    /// @param user Address of the user to query
    /// @return The encrypted identity score
    function getIdentityScore(address user) external returns (gtUint64);
    /// @notice Check if a user's identity verification has expired
    /// @param user Address of the user to check
    /// @return True if expired, false otherwise
    function isIdentityExpired(address user) external view returns (bool);
    
    // Events
    /// @notice Emitted when a user's identity is verified
    /// @param user The user whose identity was verified
    /// @param tier The verification tier achieved
    /// @param proofHash Hash of the verification proof
    /// @param timestamp When the verification occurred
    event IdentityVerified(
        address indexed user,
        uint8 indexed tier,
        bytes32 proofHash,
        uint256 indexed timestamp
    );
}

/**
 * @title ITrustSystem
 * @author OmniCoin Development Team
 * @notice Interface for trust system (DPoS/COTI PoT)
 * @dev Manages delegated proof of stake voting and COTI proof of trust integration
 */
interface ITrustSystem is IReputationSystem {
    
    // DPoS voting
    /// @notice Cast a delegated proof of stake vote for a candidate
    /// @param candidate Address of the candidate to vote for
    /// @param votes Encrypted number of votes to cast
    function castDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external;
    
    /// @notice Withdraw delegated proof of stake votes from a candidate
    /// @param candidate Address of the candidate to withdraw votes from
    /// @param votes Encrypted number of votes to withdraw
    function withdrawDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external;
    
    // Trust queries
    /// @notice Get the encrypted trust score for a user
    /// @param user Address of the user to query
    /// @return The encrypted trust score
    function getTrustScore(address user) external returns (gtUint64);
    /// @notice Get the number of voters who have voted for a user
    /// @param user Address of the user to query
    /// @return The total number of voters
    function getVoterCount(address user) external view returns (uint256);
    /// @notice Get the COTI proof of trust score for a user
    /// @param user Address of the user to query
    /// @return The COTI PoT score
    function getCotiProofOfTrustScore(address user) external view returns (uint256);
    
    // COTI PoT integration
    /// @notice Update a user's COTI proof of trust score
    /// @param user Address of the user to update
    /// @param score The new COTI PoT score
    function updateCotiPoTScore(address user, uint256 score) external;
    /// @notice Set whether a user wants to use COTI proof of trust
    /// @param user Address of the user
    /// @param useCoti Whether to use COTI PoT scoring
    function setUseCotiPoT(address user, bool useCoti) external;
    
    // Events
    /// @notice Emitted when a DPoS vote is cast
    /// @param voter Address of the voter
    /// @param candidate Address of the candidate voted for
    /// @param timestamp When the vote was cast
    event DPoSVoteCast(
        address indexed voter,
        address indexed candidate,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a user's trust score is updated
    /// @param user Address of the user whose trust score was updated
    /// @param timestamp When the trust score was updated
    event TrustScoreUpdated(
        address indexed user,
        uint256 indexed timestamp
    );
}

/**
 * @title IReferralSystem
 * @author OmniCoin Development Team
 * @notice Interface for referral system
 * @dev Manages referral tracking, scoring, and reward distribution
 */
interface IReferralSystem is IReputationSystem {
    
    // Referral management
    /// @notice Record a new referral relationship
    /// @param referrer Address of the user making the referral
    /// @param referee Address of the user being referred
    /// @param activityScore Encrypted activity score for the referral
    function recordReferral(
        address referrer,
        address referee,
        itUint64 calldata activityScore
    ) external;
    
    /// @notice Process a referral reward for a referrer
    /// @param referrer Address of the referrer to reward
    /// @param rewardAmount Encrypted amount of the reward
    function processReferralReward(
        address referrer,
        itUint64 calldata rewardAmount
    ) external;
    
    // Referral queries
    /// @notice Get the encrypted referral score for a user
    /// @param user Address of the user to query
    /// @return The encrypted referral score
    function getReferralScore(address user) external returns (gtUint64);
    /// @notice Get the total number of referrals made by a user
    /// @param user Address of the user to query
    /// @return The total referral count
    function getReferralCount(address user) external view returns (uint256);
    /// @notice Get the total referral rewards earned by a user
    /// @param user Address of the user to query
    /// @return The encrypted total rewards
    function getTotalReferralRewards(address user) external returns (gtUint64);
    /// @notice Check if a user is eligible to make referrals
    /// @param user Address of the user to check
    /// @return True if eligible, false otherwise
    function isEligibleReferrer(address user) external view returns (bool);
    
    // Events
    /// @notice Emitted when a new referral is recorded
    /// @param referrer Address of the user making the referral
    /// @param referee Address of the user being referred
    /// @param timestamp When the referral was recorded
    event ReferralRecorded(
        address indexed referrer,
        address indexed referee,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a referral reward is processed
    /// @param referrer Address of the referrer receiving the reward
    /// @param timestamp When the reward was processed
    event ReferralRewardProcessed(
        address indexed referrer,
        uint256 indexed timestamp
    );
}