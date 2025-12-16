// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @title IOmniRegistration
 * @author OmniBazaar Team
 * @notice Interface for OmniRegistration contract
 * @dev Queries KYC tiers and referral counts
 */
interface IOmniRegistration {
    /// @notice Check if user is registered
    /// @param user Address to check
    /// @return True if registered
    function isRegistered(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 1
    /// @param user Address to check
    /// @return True if has Tier 1
    function hasKycTier1(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 2
    /// @param user Address to check
    /// @return True if has Tier 2
    function hasKycTier2(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 3
    /// @param user Address to check
    /// @return True if has Tier 3
    function hasKycTier3(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 4
    /// @param user Address to check
    /// @return True if has Tier 4
    function hasKycTier4(address user) external view returns (bool);

    /// @notice Get user's referral count
    /// @param user Address to check
    /// @return Number of referrals
    function getReferralCount(address user) external view returns (uint256);
}

/**
 * @title IOmniCore
 * @author OmniBazaar Team
 * @notice Interface for OmniCore contract
 * @dev Queries staking information and validator status
 */
interface IOmniCore {
    /// @notice Stake information structure
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Get user's stake information
    /// @param user Address to check
    /// @return Stake struct with staking details
    function getStake(address user) external view returns (Stake memory);

    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if validator
    function isValidator(address validator) external view returns (bool);
}

/**
 * @title OmniParticipation
 * @author OmniBazaar Team
 * @notice Trustless participation scoring for OmniBazaar platform
 * @dev Reputation accumulated on-chain through user actions
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
contract OmniParticipation is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for verifying claims (admin or automated system)
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @notice Minimum score to be a validator (50 points)
    uint256 public constant MIN_VALIDATOR_SCORE = 50;

    /// @notice Minimum score to be a listing node (25 points)
    uint256 public constant MIN_LISTING_NODE_SCORE = 25;

    /// @notice Service node heartbeat timeout (5 minutes)
    uint256 public constant SERVICE_NODE_TIMEOUT = 300;

    /// @notice Validator heartbeat timeout (30 seconds)
    uint256 public constant VALIDATOR_TIMEOUT = 30;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
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

    /// @notice Participation components by address
    mapping(address => ParticipationComponents) public components;

    /// @notice Reference to OmniRegistration contract
    IOmniRegistration public registration;

    /// @notice Reference to OmniCore contract
    IOmniCore public omniCore;

    // ═══════════════════════════════════════════════════════════════════════
    //                    MARKETPLACE REPUTATION (Reviews)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Review data structure
    struct Review {
        address reviewer;
        address reviewed;
        uint8 stars;                     // 1-5
        uint256 timestamp;
        bytes32 transactionHash;         // Proof of transaction
        bool verified;                   // Admin verified transaction occurred
    }

    /// @notice Reviews submitted by users
    mapping(address => Review[]) public reviewHistory;

    /// @notice Track used transactions to prevent duplicates
    mapping(bytes32 => bool) public usedTransactions;

    // ═══════════════════════════════════════════════════════════════════════
    //                    PUBLISHER ACTIVITY (Service Nodes)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Track operational service nodes
    mapping(address => bool) public operationalServiceNodes;

    /// @notice Last heartbeat timestamp per service node
    mapping(address => uint256) public lastServiceNodeHeartbeat;

    // ═══════════════════════════════════════════════════════════════════════
    //                    MARKETPLACE ACTIVITY (Transactions)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Transaction claim tracking
    struct TransactionClaim {
        bytes32 transactionHash;
        uint256 timestamp;
        bool verified;
    }

    /// @notice Transaction claims by address
    mapping(address => TransactionClaim[]) public transactionClaims;

    // ═══════════════════════════════════════════════════════════════════════
    //                    COMMUNITY POLICING (Reports)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Report data structure
    struct Report {
        address reporter;
        bytes32 listingHash;             // IPFS or database hash
        string reason;
        uint256 timestamp;
        bool validated;
        bool isValid;                    // True if report was accurate
    }

    /// @notice Reports by reporter address
    mapping(address => Report[]) public reportHistory;

    // ═══════════════════════════════════════════════════════════════════════
    //                    FORUM ACTIVITY (Contributions)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Forum contribution tracking
    struct ForumContribution {
        string contributionType;         // "thread", "reply", "documentation", "support"
        bytes32 contentHash;             // Hash of contribution content
        uint256 timestamp;
        bool verified;
    }

    /// @notice Forum contributions by address
    mapping(address => ForumContribution[]) public forumContributions;

    // ═══════════════════════════════════════════════════════════════════════
    //                    VALIDATOR RELIABILITY (Heartbeats)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Last validator heartbeat timestamp
    mapping(address => uint256) public lastValidatorHeartbeat;

    /// @notice Uptime tracking (blocks online vs total)
    mapping(address => uint256) public uptimeBlocks;

    /// @notice Total blocks tracked
    mapping(address => uint256) public totalBlocks;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event ReviewSubmitted(
        address indexed reviewer,
        address indexed reviewed,
        uint8 stars,
        bytes32 transactionHash
    );
    event ReviewVerified(address indexed reviewed, uint256 reviewIndex);
    event ReputationUpdated(address indexed user, int8 newReputation);
    event ServiceNodeHeartbeat(address indexed serviceNode, uint256 timestamp);
    event TransactionsClaimed(address indexed user, uint256 count);
    event TransactionClaimVerified(address indexed user, uint256 claimIndex);
    event ReportSubmitted(
        address indexed reporter,
        bytes32 indexed listingHash,
        string reason
    );
    event ReportValidated(
        address indexed reporter,
        uint256 reportIndex,
        bool isValid
    );
    event ForumContributionClaimed(
        address indexed user,
        string contributionType,
        bytes32 contentHash
    );
    event ForumContributionVerified(address indexed user, uint256 contributionIndex);
    event ValidatorHeartbeat(address indexed validator, uint256 timestamp);
    event ContractsUpdated(address registration, address omniCore);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Invalid star rating (must be 1-5)
    error InvalidStars();

    /// @notice Transaction already used for review/claim
    error TransactionAlreadyUsed();

    /// @notice User is not registered
    error NotRegistered();

    /// @notice Invalid review index
    error InvalidReviewIndex();

    /// @notice Review already verified
    error AlreadyVerified();

    /// @notice Report reason too short
    error ReasonTooShort();

    /// @notice Invalid contribution type
    error InvalidContributionType();

    /// @notice Invalid contribution index
    error InvalidContributionIndex();

    /// @notice Invalid report index
    error InvalidReportIndex();

    /// @notice Report already validated
    error AlreadyValidated();

    /// @notice Invalid claim index
    error InvalidClaimIndex();

    /// @notice Caller is not a validator
    error NotValidator();

    /// @notice Contract address cannot be zero
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param registrationAddr Address of OmniRegistration contract
     * @param omniCoreAddr Address of OmniCore contract
     */
    function initialize(
        address registrationAddr,
        address omniCoreAddr
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);

        if (registrationAddr == address(0)) revert ZeroAddress();
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        registration = IOmniRegistration(registrationAddr);
        omniCore = IOmniCore(omniCoreAddr);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    MARKETPLACE REPUTATION (Reviews)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit a marketplace review (updates reputation)
     * @param reviewed Address being reviewed
     * @param stars Star rating (1-5)
     * @param transactionHash Hash proving transaction occurred
     * @dev This IS a reputation claim - submitting review updates scores
     */
    function submitReview(
        address reviewed,
        uint8 stars,
        bytes32 transactionHash
    ) external nonReentrant {
        if (stars < 1 || stars > 5) revert InvalidStars();
        if (usedTransactions[transactionHash]) revert TransactionAlreadyUsed();
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();
        if (!registration.isRegistered(reviewed)) revert NotRegistered();

        // Mark as used
        usedTransactions[transactionHash] = true;

        // Record review
        reviewHistory[reviewed].push(Review({
            reviewer: msg.sender,
            reviewed: reviewed,
            stars: stars,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            transactionHash: transactionHash,
            verified: false
        }));

        // Recalculate reputation (only from verified reviews)
        _updateMarketplaceReputation(reviewed);

        emit ReviewSubmitted(msg.sender, reviewed, stars, transactionHash);
    }

    /**
     * @notice Verify a review's transaction actually occurred
     * @param reviewed Address who was reviewed
     * @param reviewIndex Index in their review history
     */
    function verifyReview(
        address reviewed,
        uint256 reviewIndex
    ) external onlyRole(VERIFIER_ROLE) {
        if (reviewIndex >= reviewHistory[reviewed].length) revert InvalidReviewIndex();

        Review storage review = reviewHistory[reviewed][reviewIndex];
        if (review.verified) revert AlreadyVerified();

        review.verified = true;

        // Recalculate reputation with newly verified review
        _updateMarketplaceReputation(reviewed);

        emit ReviewVerified(reviewed, reviewIndex);
    }

    /**
     * @notice Calculate marketplace reputation from verified reviews
     * @param user Address to calculate for
     */
    function _updateMarketplaceReputation(address user) internal {
        Review[] storage reviews = reviewHistory[user];

        // Count only verified reviews
        uint256 totalStars = 0;
        uint256 verifiedCount = 0;

        uint256 reviewLen = reviews.length;
        for (uint256 i = 0; i < reviewLen;) {
            if (reviews[i].verified) {
                totalStars += reviews[i].stars;
                ++verifiedCount;
            }
            unchecked { ++i; }
        }

        if (verifiedCount == 0) {
            components[user].marketplaceReputation = 0;
            components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
            return;
        }

        // Calculate average star rating
        uint256 avgStars = totalStars / verifiedCount;

        // Convert to -10 to +10 scale
        // 1 star = -10, 2 stars = -5, 3 stars = 0, 4 stars = +5, 5 stars = +10
        int8 newReputation;
        if (avgStars == 1) newReputation = -10;
        else if (avgStars == 2) newReputation = -5;
        else if (avgStars == 3) newReputation = 0;
        else if (avgStars == 4) newReputation = 5;
        else newReputation = 10;

        components[user].marketplaceReputation = newReputation;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time

        emit ReputationUpdated(user, newReputation);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    PUBLISHER ACTIVITY (Service Nodes)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Service node submits heartbeat (proves it's operational)
     * @dev Service nodes call this regularly to prove they're serving listings
     */
    function submitServiceNodeHeartbeat() external {
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();

        lastServiceNodeHeartbeat[msg.sender] = block.timestamp; // solhint-disable-line not-rely-on-time

        // Mark as operational if heartbeat within timeout
        operationalServiceNodes[msg.sender] = true;

        // Award full 4 points for being operational
        components[msg.sender].publisherActivity = 4;
        components[msg.sender].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time

        emit ServiceNodeHeartbeat(msg.sender, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Check if service node is currently operational
     * @param serviceNode Address to check
     * @return True if heartbeat within timeout
     */
    function isServiceNodeOperational(address serviceNode) public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - lastServiceNodeHeartbeat[serviceNode]) <= SERVICE_NODE_TIMEOUT;
    }

    /**
     * @notice Update publisher activity based on operational status
     * @param user Address to update
     * @dev Called periodically or when calculating score
     */
    function updatePublisherActivity(address user) public {
        if (isServiceNodeOperational(user)) {
            components[user].publisherActivity = 4;
        } else {
            components[user].publisherActivity = 0;
        }
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    MARKETPLACE ACTIVITY (Transactions)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim marketplace transactions for activity points
     * @param transactionHashes Array of transaction hashes to claim
     * @dev User initiates claim, admin verifies later
     */
    function claimMarketplaceTransactions(
        bytes32[] calldata transactionHashes
    ) external {
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();

        uint256 hashLen = transactionHashes.length;
        for (uint256 i = 0; i < hashLen;) {
            if (usedTransactions[transactionHashes[i]]) revert TransactionAlreadyUsed();
            usedTransactions[transactionHashes[i]] = true;

            transactionClaims[msg.sender].push(TransactionClaim({
                transactionHash: transactionHashes[i],
                timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
                verified: false
            }));

            unchecked { ++i; }
        }

        // Update activity (will only count verified claims)
        _updateMarketplaceActivity(msg.sender);

        emit TransactionsClaimed(msg.sender, hashLen);
    }

    /**
     * @notice Verify transaction claims
     * @param user Address who claimed transactions
     * @param claimIndex Index of claim to verify
     */
    function verifyTransactionClaim(
        address user,
        uint256 claimIndex
    ) external onlyRole(VERIFIER_ROLE) {
        if (claimIndex >= transactionClaims[user].length) revert InvalidClaimIndex();

        TransactionClaim storage claim = transactionClaims[user][claimIndex];
        if (claim.verified) revert AlreadyVerified();

        claim.verified = true;

        _updateMarketplaceActivity(user);

        emit TransactionClaimVerified(user, claimIndex);
    }

    /**
     * @notice Update marketplace activity based on verified transaction claims
     * @param user Address to update
     */
    function _updateMarketplaceActivity(address user) internal {
        TransactionClaim[] storage claims = transactionClaims[user];

        // Count verified claims
        uint256 verifiedCount = 0;
        uint256 claimLen = claims.length;
        for (uint256 i = 0; i < claimLen;) {
            if (claims[i].verified) ++verifiedCount;
            unchecked { ++i; }
        }

        // Update activity (0-5 scale based on transaction count)
        // 5 txs = 1 point, 10 = 2, 20 = 3, 50 = 4, 100+ = 5
        uint8 newActivity;
        if (verifiedCount >= 100) newActivity = 5;
        else if (verifiedCount >= 50) newActivity = 4;
        else if (verifiedCount >= 20) newActivity = 3;
        else if (verifiedCount >= 10) newActivity = 2;
        else if (verifiedCount >= 5) newActivity = 1;
        else newActivity = 0;

        components[user].marketplaceActivity = newActivity;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    COMMUNITY POLICING (Reports)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit community policing report
     * @param listingHash Hash of problematic listing
     * @param reason Description of violation
     * @dev This IS a reputation claim - reporting increases policing score
     */
    function submitReport(
        bytes32 listingHash,
        string calldata reason
    ) external {
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();
        if (bytes(reason).length < 10) revert ReasonTooShort();

        reportHistory[msg.sender].push(Report({
            reporter: msg.sender,
            listingHash: listingHash,
            reason: reason,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            validated: false,
            isValid: false
        }));

        emit ReportSubmitted(msg.sender, listingHash, reason);
    }

    /**
     * @notice Validate report
     * @param reporter Address who submitted report
     * @param reportIndex Index in their report history
     * @param isValid Whether report was accurate
     */
    function validateReport(
        address reporter,
        uint256 reportIndex,
        bool isValid
    ) external onlyRole(VERIFIER_ROLE) {
        if (reportIndex >= reportHistory[reporter].length) revert InvalidReportIndex();

        Report storage report = reportHistory[reporter][reportIndex];
        if (report.validated) revert AlreadyValidated();

        report.validated = true;
        report.isValid = isValid;

        _updateCommunityPolicing(reporter);

        emit ReportValidated(reporter, reportIndex, isValid);
    }

    /**
     * @notice Update community policing score based on validated reports
     * @param user Address to update
     */
    function _updateCommunityPolicing(address user) internal {
        Report[] storage reports = reportHistory[user];

        // Count valid reports
        uint256 validCount = 0;
        uint256 reportLen = reports.length;
        for (uint256 i = 0; i < reportLen;) {
            if (reports[i].validated && reports[i].isValid) {
                ++validCount;
            }
            unchecked { ++i; }
        }

        // Update policing score (0-5 scale)
        // 1 valid = 1 point, 5 = 2, 10 = 3, 20 = 4, 50+ = 5
        uint8 newPolicing;
        if (validCount >= 50) newPolicing = 5;
        else if (validCount >= 20) newPolicing = 4;
        else if (validCount >= 10) newPolicing = 3;
        else if (validCount >= 5) newPolicing = 2;
        else if (validCount >= 1) newPolicing = 1;
        else newPolicing = 0;

        components[user].communityPolicing = newPolicing;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    FORUM ACTIVITY (Contributions)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim forum activity contribution
     * @param contributionType Type: "thread", "reply", "documentation", "support"
     * @param contentHash Hash proving contribution exists
     * @dev Points use exponential decay formula
     */
    function claimForumContribution(
        string calldata contributionType,
        bytes32 contentHash
    ) external {
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();

        bytes32 typeHash = keccak256(bytes(contributionType));
        if (
            typeHash != keccak256("thread") &&
            typeHash != keccak256("reply") &&
            typeHash != keccak256("documentation") &&
            typeHash != keccak256("support")
        ) {
            revert InvalidContributionType();
        }

        forumContributions[msg.sender].push(ForumContribution({
            contributionType: contributionType,
            contentHash: contentHash,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            verified: false
        }));

        emit ForumContributionClaimed(msg.sender, contributionType, contentHash);
    }

    /**
     * @notice Verify forum contribution
     * @param user Address who claimed contribution
     * @param contributionIndex Index of contribution
     */
    function verifyForumContribution(
        address user,
        uint256 contributionIndex
    ) external onlyRole(VERIFIER_ROLE) {
        if (contributionIndex >= forumContributions[user].length) {
            revert InvalidContributionIndex();
        }

        ForumContribution storage contribution = forumContributions[user][contributionIndex];
        if (contribution.verified) revert AlreadyVerified();

        contribution.verified = true;

        _updateForumActivity(user);

        emit ForumContributionVerified(user, contributionIndex);
    }

    /**
     * @notice Update forum activity using exponential decay formula
     * @param user Address to update
     * @dev Formula approximation: points = 5 * (1 - 1/(1 + count/20))
     */
    function _updateForumActivity(address user) internal {
        ForumContribution[] storage contributions = forumContributions[user];

        // Count verified contributions
        uint256 verifiedCount = 0;
        uint256 contribLen = contributions.length;
        for (uint256 i = 0; i < contribLen;) {
            if (contributions[i].verified) ++verifiedCount;
            unchecked { ++i; }
        }

        // Simplified exponential decay approximation
        // 1-5 contributions = 1 point
        // 6-15 contributions = 2 points
        // 16-30 contributions = 3 points
        // 31-50 contributions = 4 points
        // 51+ contributions = 5 points
        uint8 score;
        if (verifiedCount >= 51) score = 5;
        else if (verifiedCount >= 31) score = 4;
        else if (verifiedCount >= 16) score = 3;
        else if (verifiedCount >= 6) score = 2;
        else if (verifiedCount >= 1) score = 1;
        else score = 0;

        components[user].forumActivity = score;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    VALIDATOR RELIABILITY (Heartbeats)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Validator submits heartbeat
     * @dev Should be called every ~10 epochs (20 seconds)
     */
    function submitValidatorHeartbeat() external {
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();

        uint256 lastBeat = lastValidatorHeartbeat[msg.sender];
        lastValidatorHeartbeat[msg.sender] = block.timestamp; // solhint-disable-line not-rely-on-time

        // Update uptime tracking
        if (lastBeat > 0) {
            // solhint-disable-next-line not-rely-on-time
            uint256 elapsedBlocks = (block.timestamp - lastBeat) / 2; // 2 second blocks
            totalBlocks[msg.sender] += elapsedBlocks;

            // Assume online if heartbeat within expected window
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp - lastBeat <= VALIDATOR_TIMEOUT) {
                uptimeBlocks[msg.sender] += elapsedBlocks;
            }
        }

        _updateReliability(msg.sender);

        emit ValidatorHeartbeat(msg.sender, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Update reliability score based on uptime
     * @param user Address to update
     * @dev Score: 100% = +5, 95%+ = +3, 90%+ = +1, 80%+ = 0, 70%+ = -2, <70% = -5
     */
    function _updateReliability(address user) internal {
        uint256 total = totalBlocks[user];
        if (total == 0) {
            components[user].reliability = 0;
            return;
        }

        uint256 uptime = uptimeBlocks[user];
        uint256 uptimePercent = (uptime * 100) / total;

        int8 newReliability;
        if (uptimePercent >= 100) newReliability = 5;
        else if (uptimePercent >= 95) newReliability = 3;
        else if (uptimePercent >= 90) newReliability = 1;
        else if (uptimePercent >= 80) newReliability = 0;
        else if (uptimePercent >= 70) newReliability = -2;
        else newReliability = -5;

        components[user].reliability = newReliability;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    SCORE CALCULATION (Queries + Stored)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get complete participation score breakdown
     * @param user Address to check
     * @return totalScore Total score and component breakdown
     * @return kycTrust KYC trust points (0-20)
     * @return marketplaceReputation Marketplace reputation (-10 to +10)
     * @return stakingScore Staking score (0-36)
     * @return referralActivity Referral activity (0-10)
     * @return publisherActivity Publisher activity (0-4)
     * @return marketplaceActivity Marketplace activity (0-5)
     * @return communityPolicing Community policing (0-5)
     * @return forumActivity Forum activity (0-5)
     * @return reliability Reliability (-5 to +5)
     */
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
    ) {
        ParticipationComponents memory comp = components[user];

        // Query on-chain components
        kycTrust = _getKYCTrust(user);
        stakingScore = _getStakingScore(user);
        referralActivity = _getReferralActivity(user);

        // Get stored components
        marketplaceReputation = comp.marketplaceReputation;
        publisherActivity = comp.publisherActivity;
        marketplaceActivity = comp.marketplaceActivity;
        communityPolicing = comp.communityPolicing;
        forumActivity = comp.forumActivity;
        reliability = comp.reliability;

        // Sum all components
        int256 total = int256(uint256(kycTrust)) +
                       int256(marketplaceReputation) +
                       int256(uint256(stakingScore)) +
                       int256(uint256(referralActivity)) +
                       int256(uint256(publisherActivity)) +
                       int256(uint256(marketplaceActivity)) +
                       int256(uint256(communityPolicing)) +
                       int256(uint256(forumActivity)) +
                       int256(reliability);

        // Clamp to 0-100 range
        if (total < 0) totalScore = 0;
        else if (total > 100) totalScore = 100;
        else totalScore = uint256(total);
    }

    /**
     * @notice Get just the total score (gas-efficient)
     * @param user Address to check
     * @return Total score (0-100)
     */
    function getTotalScore(address user) external view returns (uint256) {
        (uint256 total,,,,,,,,,) = this.getScore(user);
        return total;
    }

    /**
     * @notice Query KYC trust from registration contract
     * @param user Address to check
     * @return KYC trust points (0-20)
     */
    function _getKYCTrust(address user) internal view returns (uint8) {
        // Check tier 4 first (highest)
        if (registration.hasKycTier4(user)) return 20;
        if (registration.hasKycTier3(user)) return 20;
        if (registration.hasKycTier2(user)) return 10;
        if (registration.hasKycTier1(user)) return 5;
        return 0;
    }

    /**
     * @notice Query staking score from OmniCore
     * @param user Address to check
     * @return Staking score (0-36)
     */
    function _getStakingScore(address user) internal view returns (uint8) {
        IOmniCore.Stake memory stake = omniCore.getStake(user);

        if (!stake.active || stake.amount == 0) return 0;

        // Calculate staking tier (1-5) using 18 decimals
        uint8 tier = 0;
        if (stake.amount >= 1_000_000_000 ether) tier = 5;       // 1B+ XOM
        else if (stake.amount >= 100_000_000 ether) tier = 4;    // 100M+ XOM
        else if (stake.amount >= 10_000_000 ether) tier = 3;     // 10M+ XOM
        else if (stake.amount >= 1_000_000 ether) tier = 2;      // 1M+ XOM
        else if (stake.amount >= 1 ether) tier = 1;              // 1+ XOM

        // Calculate duration tier (0-3) - duration is in seconds
        uint8 durationTier = 0;
        uint256 durationDays = stake.duration / 1 days;
        if (durationDays >= 730) durationTier = 3;               // 2 years
        else if (durationDays >= 180) durationTier = 2;          // 6 months
        else if (durationDays >= 30) durationTier = 1;           // 1 month

        // Formula: (tier * 3) + (durationTier * 3)
        return (tier * 3) + (durationTier * 3);
    }

    /**
     * @notice Query referral activity from registration contract
     * @param user Address to check
     * @return Referral points (0-10, capped)
     */
    function _getReferralActivity(address user) internal view returns (uint8) {
        uint256 referralCount = registration.getReferralCount(user);
        if (referralCount > 10) return 10;
        return uint8(referralCount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    QUALIFICATION CHECKS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if user can be a validator
     * @param user Address to check
     * @return True if score >= 50 AND has KYC Tier 4
     */
    function canBeValidator(address user) external view returns (bool) {
        (uint256 score,,,,,,,,,) = this.getScore(user);
        bool hasRequiredKYC = registration.hasKycTier4(user);
        return score >= MIN_VALIDATOR_SCORE && hasRequiredKYC;
    }

    /**
     * @notice Check if user can be a listing node
     * @param user Address to check
     * @return True if score >= 25
     */
    function canBeListingNode(address user) external view returns (bool) {
        (uint256 score,,,,,,,,,) = this.getScore(user);
        return score >= MIN_LISTING_NODE_SCORE;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update contract references
     * @param registrationAddr New OmniRegistration address
     * @param omniCoreAddr New OmniCore address
     */
    function setContracts(
        address registrationAddr,
        address omniCoreAddr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registrationAddr == address(0)) revert ZeroAddress();
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        registration = IOmniRegistration(registrationAddr);
        omniCore = IOmniCore(omniCoreAddr);

        emit ContractsUpdated(registrationAddr, omniCoreAddr);
    }

    /**
     * @notice Get review history length for a user
     * @param user Address to check
     * @return Length of review history
     */
    function getReviewHistoryLength(address user) external view returns (uint256) {
        return reviewHistory[user].length;
    }

    /**
     * @notice Get transaction claims length for a user
     * @param user Address to check
     * @return Length of transaction claims
     */
    function getTransactionClaimsLength(address user) external view returns (uint256) {
        return transactionClaims[user].length;
    }

    /**
     * @notice Get report history length for a user
     * @param user Address to check
     * @return Length of report history
     */
    function getReportHistoryLength(address user) external view returns (uint256) {
        return reportHistory[user].length;
    }

    /**
     * @notice Get forum contributions length for a user
     * @param user Address to check
     * @return Length of forum contributions
     */
    function getForumContributionsLength(address user) external view returns (uint256) {
        return forumContributions[user].length;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
