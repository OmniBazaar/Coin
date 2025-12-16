// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOmniParticipation
 * @author OmniBazaar Team
 * @notice Interface for OmniParticipation contract
 * @dev Trustless participation scoring for OmniBazaar platform
 *
 * Score Components (0-100 max):
 * - KYC Trust (0-20): Queried from OmniRegistration
 * - Marketplace Reputation (-10 to +10): From verified reviews
 * - Staking Score (2-36): Queried from OmniCore
 * - Referral Activity (0-10): Queried from OmniRegistration
 * - Publisher Activity (0-4): Service node heartbeat
 * - Marketplace Activity (0-5): Verified transaction claims
 * - Community Policing (0-5): Validated reports
 * - Forum Activity (0-5): Verified contributions
 * - Reliability (-5 to +5): Validator heartbeat tracking
 */
interface IOmniParticipation {
    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Individual participation score components
    struct ParticipationComponents {
        int8 marketplaceReputation;      // -10 to +10 (from reviews)
        uint8 publisherActivity;         // 0-4 (operational status)
        uint8 marketplaceActivity;       // 0-5 (transaction claims)
        uint8 communityPolicing;         // 0-5 (validated reports)
        uint8 forumActivity;             // 0-5 (forum/docs claims)
        int8 reliability;                // -5 to +5 (heartbeat-based)
        uint256 lastUpdate;              // Timestamp of last update
    }

    /// @notice Review data structure
    struct Review {
        address reviewer;
        address reviewed;
        uint8 stars;                     // 1-5
        uint256 timestamp;
        bytes32 transactionHash;         // Proof of transaction
        bool verified;                   // Admin verified transaction occurred
    }

    /// @notice Transaction claim tracking
    struct TransactionClaim {
        bytes32 transactionHash;
        uint256 timestamp;
        bool verified;
    }

    /// @notice Report data structure
    struct Report {
        address reporter;
        bytes32 listingHash;             // IPFS or database hash
        string reason;
        uint256 timestamp;
        bool validated;
        bool isValid;                    // True if report was accurate
    }

    /// @notice Forum contribution tracking
    struct ForumContribution {
        string contributionType;         // "thread", "reply", "documentation", "support"
        bytes32 contentHash;             // Hash of contribution content
        uint256 timestamp;
        bool verified;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a review is submitted
    /// @param reviewer Address of reviewer
    /// @param reviewed Address being reviewed
    /// @param stars Star rating (1-5)
    /// @param transactionHash Transaction proof hash
    event ReviewSubmitted(
        address indexed reviewer,
        address indexed reviewed,
        uint8 stars,
        bytes32 transactionHash
    );

    /// @notice Emitted when a review is verified
    /// @param reviewed Address who was reviewed
    /// @param reviewIndex Index in review history
    event ReviewVerified(address indexed reviewed, uint256 reviewIndex);

    /// @notice Emitted when reputation is updated
    /// @param user Address whose reputation changed
    /// @param newReputation New reputation score
    event ReputationUpdated(address indexed user, int8 newReputation);

    /// @notice Emitted when service node submits heartbeat
    /// @param serviceNode Service node address
    /// @param timestamp Heartbeat timestamp
    event ServiceNodeHeartbeat(address indexed serviceNode, uint256 timestamp);

    /// @notice Emitted when transactions are claimed
    /// @param user Address claiming transactions
    /// @param count Number of transactions claimed
    event TransactionsClaimed(address indexed user, uint256 count);

    /// @notice Emitted when transaction claim is verified
    /// @param user Address whose claim was verified
    /// @param claimIndex Index of verified claim
    event TransactionClaimVerified(address indexed user, uint256 claimIndex);

    /// @notice Emitted when report is submitted
    /// @param reporter Address submitting report
    /// @param listingHash Hash of problematic listing
    /// @param reason Description of violation
    event ReportSubmitted(
        address indexed reporter,
        bytes32 indexed listingHash,
        string reason
    );

    /// @notice Emitted when report is validated
    /// @param reporter Address who submitted report
    /// @param reportIndex Index in report history
    /// @param isValid Whether report was accurate
    event ReportValidated(
        address indexed reporter,
        uint256 reportIndex,
        bool isValid
    );

    /// @notice Emitted when forum contribution is claimed
    /// @param user Address claiming contribution
    /// @param contributionType Type of contribution
    /// @param contentHash Hash of contribution content
    event ForumContributionClaimed(
        address indexed user,
        string contributionType,
        bytes32 contentHash
    );

    /// @notice Emitted when forum contribution is verified
    /// @param user Address whose contribution was verified
    /// @param contributionIndex Index of verified contribution
    event ForumContributionVerified(address indexed user, uint256 contributionIndex);

    /// @notice Emitted when validator submits heartbeat
    /// @param validator Validator address
    /// @param timestamp Heartbeat timestamp
    event ValidatorHeartbeat(address indexed validator, uint256 timestamp);

    /// @notice Emitted when contract references are updated
    /// @param registration New OmniRegistration address
    /// @param omniCore New OmniCore address
    event ContractsUpdated(address registration, address omniCore);

    // ═══════════════════════════════════════════════════════════════════════
    //                         MARKETPLACE REPUTATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Submit a marketplace review
    /// @param reviewed Address being reviewed
    /// @param stars Star rating (1-5)
    /// @param transactionHash Hash proving transaction occurred
    function submitReview(
        address reviewed,
        uint8 stars,
        bytes32 transactionHash
    ) external;

    /// @notice Verify a review's transaction actually occurred
    /// @param reviewed Address who was reviewed
    /// @param reviewIndex Index in their review history
    function verifyReview(address reviewed, uint256 reviewIndex) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         PUBLISHER ACTIVITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Service node submits heartbeat
    function submitServiceNodeHeartbeat() external;

    /// @notice Check if service node is currently operational
    /// @param serviceNode Address to check
    /// @return True if heartbeat within timeout
    function isServiceNodeOperational(address serviceNode) external view returns (bool);

    /// @notice Update publisher activity based on operational status
    /// @param user Address to update
    function updatePublisherActivity(address user) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         MARKETPLACE ACTIVITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim marketplace transactions for activity points
    /// @param transactionHashes Array of transaction hashes to claim
    function claimMarketplaceTransactions(bytes32[] calldata transactionHashes) external;

    /// @notice Verify transaction claims
    /// @param user Address who claimed transactions
    /// @param claimIndex Index of claim to verify
    function verifyTransactionClaim(address user, uint256 claimIndex) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         COMMUNITY POLICING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Submit community policing report
    /// @param listingHash Hash of problematic listing
    /// @param reason Description of violation
    function submitReport(bytes32 listingHash, string calldata reason) external;

    /// @notice Validate report
    /// @param reporter Address who submitted report
    /// @param reportIndex Index in their report history
    /// @param isValid Whether report was accurate
    function validateReport(address reporter, uint256 reportIndex, bool isValid) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         FORUM ACTIVITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim forum activity contribution
    /// @param contributionType Type: "thread", "reply", "documentation", "support"
    /// @param contentHash Hash proving contribution exists
    function claimForumContribution(
        string calldata contributionType,
        bytes32 contentHash
    ) external;

    /// @notice Verify forum contribution
    /// @param user Address who claimed contribution
    /// @param contributionIndex Index of contribution
    function verifyForumContribution(address user, uint256 contributionIndex) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         VALIDATOR RELIABILITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Validator submits heartbeat
    function submitValidatorHeartbeat() external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         SCORE CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get complete participation score breakdown
    /// @param user Address to check
    /// @return totalScore Total score (0-100)
    /// @return kycTrust KYC trust points (0-20)
    /// @return marketplaceReputation Marketplace reputation (-10 to +10)
    /// @return stakingScore Staking score (0-36)
    /// @return referralActivity Referral activity (0-10)
    /// @return publisherActivity Publisher activity (0-4)
    /// @return marketplaceActivity Marketplace activity (0-5)
    /// @return communityPolicing Community policing (0-5)
    /// @return forumActivity Forum activity (0-5)
    /// @return reliability Reliability (-5 to +5)
    function getScore(address user) external view returns (
        uint256 totalScore,
        uint8 kycTrust,
        int8 marketplaceReputation,
        uint8 stakingScore,
        uint8 referralActivity,
        uint8 publisherActivity,
        uint8 marketplaceActivity,
        uint8 communityPolicing,
        uint8 forumActivity,
        int8 reliability
    );

    /// @notice Get just the total score (gas-efficient)
    /// @param user Address to check
    /// @return Total score (0-100)
    function getTotalScore(address user) external view returns (uint256);

    // ═══════════════════════════════════════════════════════════════════════
    //                         QUALIFICATION CHECKS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check if user can be a validator
    /// @param user Address to check
    /// @return True if score >= 50 AND has KYC Tier 4
    function canBeValidator(address user) external view returns (bool);

    /// @notice Check if user can be a listing node
    /// @param user Address to check
    /// @return True if score >= 25
    function canBeListingNode(address user) external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get participation components for a user
    /// @param user Address to check
    /// @return ParticipationComponents struct
    function components(address user) external view returns (ParticipationComponents memory);

    /// @notice Get review history length for a user
    /// @param user Address to check
    /// @return Length of review history
    function getReviewHistoryLength(address user) external view returns (uint256);

    /// @notice Get transaction claims length for a user
    /// @param user Address to check
    /// @return Length of transaction claims
    function getTransactionClaimsLength(address user) external view returns (uint256);

    /// @notice Get report history length for a user
    /// @param user Address to check
    /// @return Length of report history
    function getReportHistoryLength(address user) external view returns (uint256);

    /// @notice Get forum contributions length for a user
    /// @param user Address to check
    /// @return Length of forum contributions
    function getForumContributionsLength(address user) external view returns (uint256);
}
