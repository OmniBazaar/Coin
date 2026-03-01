// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
 * Score Components (-15 to 88 raw, clamped to 0-100):
 * - KYC Trust (0-20): Queried from OmniRegistration
 * - Marketplace Reputation (-10 to +10): From verified reviews
 * - Staking Score (0-24): (tier*3)+(durationTier*3), OmniCore
 * - Referral Activity (0-10): Queried from OmniRegistration
 * - Publisher Activity (0-4): Listing count thresholds
 * - Marketplace Activity (0-5): Verified transaction claims
 * - Community Policing (0-5): Validated reports (with decay)
 * - Forum Activity (0-5): Verified contributions (with decay)
 * - Reliability (-5 to +5): Validator heartbeat tracking
 *
 * Attacker Review Fixes (2026-02-28):
 * - ATK-H04: Verifier daily rate limit (50/day) + listing delta cap (1000)
 * - ATK-H12/K01: Per-user array caps on reviews, claims, reports, contributions
 * - ATK-M22: Service node heartbeat requires validator status
 * - ATK-M23: Documented limitation (fabricated tx hashes require off-chain proof)
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract OmniParticipation is // solhint-disable-line max-states-count
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ═══════════════════════════════════════════════════════════════════════
    //                          TYPE DECLARATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Individual participation score components
    /// @dev Packed into a single storage slot where possible.
    ///      Fields are ordered by descending size for optimal slot packing.
    struct ParticipationComponents {
        uint256 lastUpdate;              // Timestamp of last update
        int8 marketplaceReputation;      // -10 to +10 (from reviews)
        uint8 publisherActivity;         // 0-4 (operational status)
        uint8 marketplaceActivity;       // 0-5 (transaction claims)
        uint8 communityPolicing;         // 0-5 (validated reports)
        uint8 forumActivity;             // 0-5 (forum/docs claims)
        int8 reliability;                // -5 to +5 (heartbeat-based)
    }

    /// @notice Review data structure for marketplace reputation tracking
    /// @dev Fields ordered for optimal struct packing.
    struct Review {
        address reviewer;
        uint8 stars;                     // 1-5
        bool verified;                   // Admin verified transaction occurred
        address reviewed;
        uint256 timestamp;
        bytes32 transactionHash;         // Proof of transaction
    }

    /// @notice Transaction claim tracking structure
    struct TransactionClaim {
        bytes32 transactionHash;
        uint256 timestamp;
        bool verified;
    }

    /// @notice Report data structure for community policing
    /// @dev Fields ordered for optimal struct packing.
    struct Report {
        address reporter;
        bool validated;
        bool isValid;                    // True if report was accurate
        bytes32 listingHash;             // IPFS or database hash
        uint256 timestamp;
        string reason;
    }

    /// @notice Forum contribution tracking structure
    struct ForumContribution {
        bytes32 contentHash;             // Hash of contribution content
        uint256 timestamp;
        bool verified;
        string contributionType;         // "thread", "reply", "documentation", "support"
    }

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

    /// @notice Maximum number of items in a batch operation
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice ATK-H04: Maximum score changes a verifier can make per day
    /// @dev Prevents a compromised verifier from mass-inflating sybil scores
    uint256 public constant MAX_VERIFIER_CHANGES_PER_DAY = 50;

    /// @notice ATK-H04: Maximum delta for listing count per call
    /// @dev Prevents a verifier from instantly setting 100K listings
    uint256 public constant MAX_LISTING_COUNT_DELTA = 1000;

    /// @notice ATK-H12/K01: Maximum reviews per user (array cap)
    /// @dev Prevents unbounded state bloat from fabricated reviews
    uint256 public constant MAX_REVIEWS_PER_USER = 1000;

    /// @notice ATK-H12/K01: Maximum transaction claims per user
    /// @dev Prevents unbounded state bloat from mass claims
    uint256 public constant MAX_CLAIMS_PER_USER = 1000;

    /// @notice ATK-H12/K01: Maximum reports per user
    /// @dev Prevents unbounded state bloat from report flooding
    uint256 public constant MAX_REPORTS_PER_USER = 500;

    /// @notice ATK-H12/K01: Maximum forum contributions per user
    /// @dev Prevents unbounded state bloat from contribution spam
    uint256 public constant MAX_FORUM_CONTRIBUTIONS_PER_USER = 500;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Participation components by address
    mapping(address => ParticipationComponents) public components;

    /// @notice Reference to OmniRegistration contract
    IOmniRegistration public registration;

    /// @notice Reference to OmniCore contract
    IOmniCore public omniCore;

    /// @notice Reviews submitted by users
    mapping(address => Review[]) public reviewHistory;

    /// @notice Track used transactions to prevent duplicates
    mapping(bytes32 => bool) public usedTransactions;

    /// @notice Track operational service nodes
    mapping(address => bool) public operationalServiceNodes;

    /// @notice Last heartbeat timestamp per service node
    mapping(address => uint256) public lastServiceNodeHeartbeat;

    /// @notice Transaction claims by address
    mapping(address => TransactionClaim[]) public transactionClaims;

    /// @notice Reports by reporter address
    mapping(address => Report[]) public reportHistory;

    /// @notice Forum contributions by address
    mapping(address => ForumContribution[]) public forumContributions;

    /// @notice Last validator heartbeat timestamp
    mapping(address => uint256) public lastValidatorHeartbeat;

    /// @notice Uptime tracking (blocks online vs total)
    mapping(address => uint256) public uptimeBlocks;

    /// @notice Total blocks tracked
    mapping(address => uint256) public totalBlocks;

    /// @notice Verified review counter per user (replaces O(n) array scan)
    mapping(address => uint256) public verifiedReviewCount;

    /// @notice Sum of stars from verified reviews (for average calculation)
    mapping(address => uint256) public verifiedStarSum;

    /// @notice Verified transaction counter per user
    mapping(address => uint256) public verifiedTransactionCount;

    /// @notice Validated report counter per user (accurate reports only)
    mapping(address => uint256) public validatedReportCount;

    /// @notice Verified forum contribution counter per user
    mapping(address => uint256) public verifiedForumCount;

    /// @notice Track used content hashes for forum contribution dedup (M-07)
    mapping(bytes32 => bool) public usedContentHashes;

    /// @notice Track used listing hashes per reporter for report dedup (M-07)
    mapping(address => mapping(bytes32 => bool)) public usedReportHashes;

    /// @notice Publisher listing count set by VERIFIER_ROLE (M-04)
    mapping(address => uint256) public publisherListingCount;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    /// @dev M-01: Declared with other storage variables (not at end of file)
    ///      to prevent future developers from accidentally shifting storage slots.
    bool private _ossified;

    /// @notice ATK-H04: Daily change counter per verifier
    /// @dev Maps verifier address => day number => changes made that day.
    ///      Day number = block.timestamp / 1 days (86400 seconds).
    mapping(address => mapping(uint256 => uint256))
        private _verifierDailyChanges;

    /// @notice Score decay period (90 days of inactivity = 1 point decay)
    uint256 public constant DECAY_PERIOD = 90 days;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a marketplace review is submitted
    /// @param reviewer Address of the reviewer
    /// @param reviewed Address of the user being reviewed
    /// @param stars Star rating (1-5)
    /// @param transactionHash Hash of the associated transaction
    event ReviewSubmitted(
        address indexed reviewer,
        address indexed reviewed,
        uint8 indexed stars,
        bytes32 transactionHash
    );

    /// @notice Emitted when a review is verified by an admin
    /// @param reviewed Address of the reviewed user
    /// @param reviewIndex Index of the verified review
    event ReviewVerified(address indexed reviewed, uint256 indexed reviewIndex);

    /// @notice Emitted when a user's reputation score is updated
    /// @param user Address of the user whose reputation changed
    /// @param newReputation The new reputation value (-10 to +10)
    event ReputationUpdated(address indexed user, int8 indexed newReputation);

    /// @notice Emitted when a service node sends a heartbeat
    /// @param serviceNode Address of the service node
    /// @param timestamp Block timestamp of the heartbeat
    event ServiceNodeHeartbeat(address indexed serviceNode, uint256 indexed timestamp);

    /// @notice Emitted when a user claims marketplace transactions
    /// @param user Address of the claiming user
    /// @param count Number of transactions claimed
    event TransactionsClaimed(address indexed user, uint256 indexed count);

    /// @notice Emitted when a transaction claim is verified by an admin
    /// @param user Address of the user whose claim was verified
    /// @param claimIndex Index of the verified claim
    event TransactionClaimVerified(address indexed user, uint256 indexed claimIndex);

    /// @notice Emitted when a listing report is submitted
    /// @param reporter Address of the reporter
    /// @param listingHash Hash of the reported listing
    /// @param reason Reason for the report
    event ReportSubmitted(
        address indexed reporter,
        bytes32 indexed listingHash,
        string reason
    );

    /// @notice Emitted when a report is validated by an admin
    /// @param reporter Address of the reporter
    /// @param reportIndex Index of the validated report
    /// @param isValid Whether the report was deemed valid
    event ReportValidated(
        address indexed reporter,
        uint256 indexed reportIndex,
        bool indexed isValid
    );

    /// @notice Emitted when a user claims a forum contribution
    /// @param user Address of the contributing user
    /// @param contributionType Type of forum contribution
    /// @param contentHash Hash of the contributed content
    event ForumContributionClaimed(
        address indexed user,
        string contributionType,
        bytes32 contentHash
    );

    /// @notice Emitted when a forum contribution is verified by an admin
    /// @param user Address of the user whose contribution was verified
    /// @param contributionIndex Index of the verified contribution
    event ForumContributionVerified(address indexed user, uint256 indexed contributionIndex);

    /// @notice Emitted when a validator sends a heartbeat
    /// @param validator Address of the validator
    /// @param timestamp Block timestamp of the heartbeat
    event ValidatorHeartbeat(address indexed validator, uint256 indexed timestamp);

    /// @notice Emitted when external contract references are updated
    /// @param registration New registration contract address
    /// @param omniCore New OmniCore contract address
    event ContractsUpdated(address indexed registration, address indexed omniCore);

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice L-04: Emitted when a score component is updated
    /// @param user Address whose score component changed
    /// @param component Name of the component that changed
    /// @param newValue New value of the component (cast to int256)
    event ScoreComponentUpdated(
        address indexed user,
        string component,
        int256 newValue
    );

    /// @notice ATK-H04: Emitted when publisher listing count is changed
    /// @param user Address whose listing count was updated
    /// @param oldCount Previous listing count
    /// @param newCount New listing count
    /// @param verifier Address of the verifier who made the change
    event PublisherListingCountUpdated(
        address indexed user,
        uint256 indexed oldCount,
        uint256 indexed newCount,
        address verifier
    );

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

    /// @dev Batch size is zero or exceeds MAX_BATCH_SIZE.
    error InvalidBatchSize();

    /// @notice Reviewer cannot review themselves
    error CannotReviewSelf();

    /// @notice Content hash already submitted (duplicate)
    error ContentHashAlreadyUsed();

    /// @notice Report listing hash already submitted by this reporter
    error ReportAlreadySubmitted();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice ATK-H04: Verifier exceeded daily score change limit
    error DailyVerifierLimitExceeded();

    /// @notice ATK-H04: Listing count change exceeds max delta per call
    /// @param delta The attempted change amount
    /// @param maxDelta The maximum allowed delta
    error ListingCountDeltaTooLarge(
        uint256 delta,
        uint256 maxDelta
    );

    /// @notice ATK-H12/K01: Per-user array has reached its maximum size
    /// @param current Current array length
    /// @param maximum Maximum allowed length
    error ArrayCapExceeded(uint256 current, uint256 maximum);

    /// @notice ATK-M22: Caller is not a service node (not a validator)
    error NotServiceNode();

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
    ) external initializer {
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
     * @dev This IS a reputation claim - submitting review updates scores.
     *      ATK-H12/K01: Enforces MAX_REVIEWS_PER_USER array cap.
     */
    function submitReview( // solhint-disable-line code-complexity
        address reviewed,
        uint8 stars,
        bytes32 transactionHash
    ) external nonReentrant {
        if (stars < 1 || stars > 5) revert InvalidStars();
        if (msg.sender == reviewed) revert CannotReviewSelf();        // M-03
        if (reviewed == address(0)) revert ZeroAddress();
        if (usedTransactions[transactionHash]) revert TransactionAlreadyUsed();
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();
        if (!registration.isRegistered(reviewed)) revert NotRegistered();

        // ATK-H12/K01: Enforce per-user array cap
        uint256 currentLen = reviewHistory[reviewed].length;
        // solhint-disable-next-line gas-strict-inequalities
        if (currentLen >= MAX_REVIEWS_PER_USER) {
            revert ArrayCapExceeded(
                currentLen, MAX_REVIEWS_PER_USER
            );
        }

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
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        // solhint-disable-next-line gas-strict-inequalities
        if (reviewIndex >= reviewHistory[reviewed].length) revert InvalidReviewIndex();

        Review storage review = reviewHistory[reviewed][reviewIndex];
        if (review.verified) revert AlreadyVerified();

        review.verified = true;

        // Update incremental counters (O(1) instead of O(n) array scan)
        ++verifiedReviewCount[reviewed];
        verifiedStarSum[reviewed] += review.stars;

        // Recalculate reputation using counters
        _updateMarketplaceReputation(reviewed);

        emit ReviewVerified(reviewed, reviewIndex);
    }

    /**
     * @notice Calculate marketplace reputation from incremental counters
     * @dev Uses O(1) counters instead of iterating the full review array.
     *      Counters are maintained by verifyReview().
     * @param user Address to calculate for
     */
    function _updateMarketplaceReputation(address user) internal {
        uint256 vCount = verifiedReviewCount[user];

        if (vCount == 0) {
            components[user].marketplaceReputation = 0;
            components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
            return;
        }

        // Calculate average star rating from counters
        uint256 avgStars = verifiedStarSum[user] / vCount;

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
        emit ScoreComponentUpdated(
            user,
            "marketplaceReputation",
            int256(newReputation)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    PUBLISHER ACTIVITY (Service Nodes)
    // ═══════════════════════════════════════════════════════════════════════

    /* solhint-disable ordering */
    /**
     * @notice Service node submits heartbeat (proves it's operational)
     * @dev Service nodes call this regularly to prove they're serving listings.
     *      Grouped with publisher activity functions for readability.
     *      M-02: Uses graduated scoring based on publisherListingCount
     *      instead of awarding flat 4 points. Thresholds match
     *      updatePublisherActivity(): 100/1K/10K/100K listings.
     */
    function submitServiceNodeHeartbeat() external {
        if (!registration.isRegistered(msg.sender)) revert NotRegistered();
        // ATK-M22: Only validators can submit service node heartbeats.
        // Prevents any registered user from inflating publisher score.
        if (!omniCore.isValidator(msg.sender)) revert NotServiceNode();

        lastServiceNodeHeartbeat[msg.sender] = block.timestamp; // solhint-disable-line not-rely-on-time

        // Mark as operational if heartbeat within timeout
        operationalServiceNodes[msg.sender] = true;

        // M-02: Graduated scoring based on listing count (not flat 4)
        uint256 listings = publisherListingCount[msg.sender];
        // solhint-disable gas-strict-inequalities
        uint8 score;
        if (listings >= 100_000) score = 4;
        else if (listings >= 10_000) score = 3;
        else if (listings >= 1_000) score = 2;
        else if (listings >= 100) score = 1;
        else score = 0;
        // solhint-enable gas-strict-inequalities

        components[msg.sender].publisherActivity = score;
        components[msg.sender].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time

        emit ServiceNodeHeartbeat(msg.sender, block.timestamp); // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            msg.sender,
            "publisherActivity",
            int256(uint256(score))
        );
    }
    /* solhint-enable ordering */

    /**
     * @notice Check if service node is currently operational
     * @param serviceNode Address to check
     * @return True if heartbeat within timeout
     */
    function isServiceNodeOperational(address serviceNode) public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time,gas-strict-inequalities
        return (block.timestamp - lastServiceNodeHeartbeat[serviceNode]) <= SERVICE_NODE_TIMEOUT;
    }

    /**
     * @notice Update publisher activity based on listing count and operational status
     * @param user Address to update
     * @dev M-04: Graduated scoring per spec. M-06: Restricted to VERIFIER_ROLE.
     *      100 listings = 1pt, 1000 = 2pt, 10000 = 3pt, 100000 = 4pt.
     *      Service node must also be operational.
     */
    function updatePublisherActivity(address user) public onlyRole(VERIFIER_ROLE) {
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        if (!isServiceNodeOperational(user)) {
            components[user].publisherActivity = 0;
            components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
            emit ScoreComponentUpdated(user, "publisherActivity", 0);
            return;
        }

        // M-04: Graduated scoring based on listing count thresholds
        uint256 listings = publisherListingCount[user];
        // solhint-disable gas-strict-inequalities
        uint8 score;
        if (listings >= 100_000) score = 4;
        else if (listings >= 10_000) score = 3;
        else if (listings >= 1_000) score = 2;
        else if (listings >= 100) score = 1;
        else score = 0;
        // solhint-enable gas-strict-inequalities

        components[user].publisherActivity = score;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            user,
            "publisherActivity",
            int256(uint256(score))
        );
    }

    /**
     * @notice Set a user's publisher listing count (off-chain data)
     * @param user Address to update
     * @param count Number of listings served
     * @dev Only callable by VERIFIER_ROLE. Used for M-04 graduated scoring.
     *      ATK-H04: Enforces maximum delta per call (MAX_LISTING_COUNT_DELTA)
     *      and daily rate limit to prevent instant score inflation.
     *      Emits PublisherListingCountUpdated for audit trail.
     */
    function setPublisherListingCount(
        address user,
        uint256 count
    ) external onlyRole(VERIFIER_ROLE) {
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        // ATK-H04: Enforce maximum delta per call
        uint256 currentCount = publisherListingCount[user];
        uint256 delta = count > currentCount
            ? count - currentCount
            : currentCount - count;
        if (delta > MAX_LISTING_COUNT_DELTA) {
            revert ListingCountDeltaTooLarge(
                delta, MAX_LISTING_COUNT_DELTA
            );
        }

        publisherListingCount[user] = count;

        emit PublisherListingCountUpdated(
            user, currentCount, count, msg.sender
        );
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
        if (hashLen == 0 || hashLen > MAX_BATCH_SIZE) revert InvalidBatchSize();

        // ATK-H12/K01: Enforce per-user array cap
        uint256 currentLen = transactionClaims[msg.sender].length;
        if (currentLen + hashLen > MAX_CLAIMS_PER_USER) {
            revert ArrayCapExceeded(
                currentLen + hashLen, MAX_CLAIMS_PER_USER
            );
        }

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
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        // solhint-disable-next-line gas-strict-inequalities
        if (claimIndex >= transactionClaims[user].length) revert InvalidClaimIndex();

        TransactionClaim storage claim = transactionClaims[user][claimIndex];
        if (claim.verified) revert AlreadyVerified();

        claim.verified = true;

        // Update incremental counter (O(1) instead of O(n) array scan)
        ++verifiedTransactionCount[user];

        _updateMarketplaceActivity(user);

        emit TransactionClaimVerified(user, claimIndex);
    }

    /**
     * @notice Update marketplace activity based on incremental counter
     * @dev Uses O(1) counter instead of iterating the full claims array.
     *      Counter is maintained by verifyTransactionClaim().
     *      M-05: Applies time decay for inactivity.
     * @param user Address to update
     */
    // solhint-disable-next-line code-complexity
    function _updateMarketplaceActivity(address user) internal {
        uint256 vCount = verifiedTransactionCount[user];

        // Update activity (0-5 scale based on transaction count)
        // 5 txs = 1 point, 10 = 2, 20 = 3, 50 = 4, 100+ = 5
        // solhint-disable gas-strict-inequalities
        uint8 newActivity;
        if (vCount >= 100) newActivity = 5;
        else if (vCount >= 50) newActivity = 4;
        else if (vCount >= 20) newActivity = 3;
        else if (vCount >= 10) newActivity = 2;
        else if (vCount >= 5) newActivity = 1;
        else newActivity = 0;
        // solhint-enable gas-strict-inequalities

        // M-05: Apply time decay (1 point per DECAY_PERIOD of inactivity)
        newActivity = _applyDecay(newActivity, components[user].lastUpdate);

        components[user].marketplaceActivity = newActivity;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            user,
            "marketplaceActivity",
            int256(uint256(newActivity))
        );
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

        // M-07: Prevent duplicate report submissions per reporter
        if (usedReportHashes[msg.sender][listingHash]) revert ReportAlreadySubmitted();
        usedReportHashes[msg.sender][listingHash] = true;

        // ATK-H12/K01: Enforce per-user array cap
        uint256 currentLen = reportHistory[msg.sender].length;
        // solhint-disable-next-line gas-strict-inequalities
        if (currentLen >= MAX_REPORTS_PER_USER) {
            revert ArrayCapExceeded(
                currentLen, MAX_REPORTS_PER_USER
            );
        }

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
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        // solhint-disable-next-line gas-strict-inequalities
        if (reportIndex >= reportHistory[reporter].length) revert InvalidReportIndex();

        Report storage report = reportHistory[reporter][reportIndex];
        if (report.validated) revert AlreadyValidated();

        report.validated = true;
        report.isValid = isValid;

        // Update incremental counter for valid reports only
        if (isValid) {
            ++validatedReportCount[reporter];
        }

        _updateCommunityPolicing(reporter);

        emit ReportValidated(reporter, reportIndex, isValid);
    }

    /**
     * @notice Update community policing score based on incremental counter
     * @dev Uses O(1) counter instead of iterating the full report array.
     *      Counter is maintained by validateReport().
     *      M-05: Applies time decay for inactivity.
     * @param user Address to update
     */
    function _updateCommunityPolicing(address user) internal {
        uint256 vCount = validatedReportCount[user];

        // Update policing score (0-5 scale)
        // 1 valid = 1 point, 5 = 2, 10 = 3, 20 = 4, 50+ = 5
        // solhint-disable gas-strict-inequalities
        uint8 newPolicing;
        if (vCount >= 50) newPolicing = 5;
        else if (vCount >= 20) newPolicing = 4;
        else if (vCount >= 10) newPolicing = 3;
        else if (vCount >= 5) newPolicing = 2;
        else if (vCount >= 1) newPolicing = 1;
        else newPolicing = 0;
        // solhint-enable gas-strict-inequalities

        // M-05: Apply time decay (1 point per DECAY_PERIOD of inactivity)
        newPolicing = _applyDecay(newPolicing, components[user].lastUpdate);

        components[user].communityPolicing = newPolicing;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            user,
            "communityPolicing",
            int256(uint256(newPolicing))
        );
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

        // M-07: Prevent duplicate content hash submissions
        if (usedContentHashes[contentHash]) revert ContentHashAlreadyUsed();
        usedContentHashes[contentHash] = true;

        bytes32 typeHash = keccak256(bytes(contributionType));
        if (
            typeHash != keccak256("thread") &&
            typeHash != keccak256("reply") &&
            typeHash != keccak256("documentation") &&
            typeHash != keccak256("support")
        ) {
            revert InvalidContributionType();
        }

        // ATK-H12/K01: Enforce per-user array cap
        uint256 currentLen =
            forumContributions[msg.sender].length;
        // solhint-disable-next-line gas-strict-inequalities
        if (currentLen >= MAX_FORUM_CONTRIBUTIONS_PER_USER) {
            revert ArrayCapExceeded(
                currentLen,
                MAX_FORUM_CONTRIBUTIONS_PER_USER
            );
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
        // ATK-H04: Enforce daily rate limit for verifier
        _enforceVerifierRateLimit();

        // solhint-disable-next-line gas-strict-inequalities
        if (contributionIndex >= forumContributions[user].length) {
            revert InvalidContributionIndex();
        }

        ForumContribution storage contribution = forumContributions[user][contributionIndex];
        if (contribution.verified) revert AlreadyVerified();

        contribution.verified = true;

        // Update incremental counter (O(1) instead of O(n) array scan)
        ++verifiedForumCount[user];

        _updateForumActivity(user);

        emit ForumContributionVerified(user, contributionIndex);
    }

    /**
     * @notice Update forum activity using incremental counter
     * @dev Uses O(1) counter instead of iterating the full contributions array.
     *      Counter is maintained by verifyForumContribution().
     *      M-05: Applies time decay for inactivity.
     * @param user Address to update
     */
    function _updateForumActivity(address user) internal {
        uint256 vCount = verifiedForumCount[user];

        // Simplified exponential decay approximation
        // 1-5 contributions = 1 point
        // 6-15 contributions = 2 points
        // 16-30 contributions = 3 points
        // 31-50 contributions = 4 points
        // 51+ contributions = 5 points
        // solhint-disable gas-strict-inequalities
        uint8 score;
        if (vCount >= 51) score = 5;
        else if (vCount >= 31) score = 4;
        else if (vCount >= 16) score = 3;
        else if (vCount >= 6) score = 2;
        else if (vCount >= 1) score = 1;
        else score = 0;
        // solhint-enable gas-strict-inequalities

        // M-05: Apply time decay (1 point per DECAY_PERIOD of inactivity)
        score = _applyDecay(score, components[user].lastUpdate);

        components[user].forumActivity = score;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            user,
            "forumActivity",
            int256(uint256(score))
        );
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
            // solhint-disable-next-line not-rely-on-time,gas-strict-inequalities
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

        // solhint-disable gas-strict-inequalities
        int8 newReliability;
        if (uptimePercent >= 100) newReliability = 5;
        else if (uptimePercent >= 95) newReliability = 3;
        else if (uptimePercent >= 90) newReliability = 1;
        else if (uptimePercent >= 80) newReliability = 0;
        else if (uptimePercent >= 70) newReliability = -2;
        else newReliability = -5;
        // solhint-enable gas-strict-inequalities

        components[user].reliability = newReliability;
        components[user].lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        emit ScoreComponentUpdated(
            user,
            "reliability",
            int256(newReliability)
        );
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
     * @return stakingScore Staking score (0-24)
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
        return _calculateScore(user);
    }

    /**
     * @notice Get just the total score (gas-efficient)
     * @dev L-01: Uses internal _calculateScore() instead of external
     *      self-call, saving ~2,600 gas per invocation.
     * @param user Address to check
     * @return Total score (0-100)
     */
    function getTotalScore(address user) external view returns (uint256) {
        (uint256 total,,,,,,,,,) = _calculateScore(user);
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
        if (registration.hasKycTier3(user)) return 15;   // M-01: was 20, spec says 15
        if (registration.hasKycTier2(user)) return 10;
        if (registration.hasKycTier1(user)) return 5;
        return 0;
    }

    /**
     * @notice Query staking score from OmniCore
     * @param user Address to check
     * @return Staking score (0-24)
     */
    // solhint-disable-next-line code-complexity
    function _getStakingScore(address user) internal view returns (uint8) {
        IOmniCore.Stake memory stake = omniCore.getStake(user);

        if (!stake.active || stake.amount == 0) return 0;

        // solhint-disable gas-strict-inequalities
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
        // solhint-enable gas-strict-inequalities

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
     * @dev L-01: Uses internal _calculateScore() for gas efficiency.
     *      Requires both minimum score (50) and KYC Tier 4.
     * @param user Address to check
     * @return True if score >= 50 AND has KYC Tier 4
     */
    function canBeValidator(address user) external view returns (bool) {
        (uint256 score,,,,,,,,,) = _calculateScore(user);
        bool hasRequiredKYC = registration.hasKycTier4(user);
        // solhint-disable-next-line gas-strict-inequalities
        return score >= MIN_VALIDATOR_SCORE && hasRequiredKYC;
    }

    /**
     * @notice Check if user can be a listing node
     * @dev L-01: Uses internal _calculateScore() for gas efficiency.
     *      No KYC requirement -- only minimum score (25).
     * @param user Address to check
     * @return True if score >= 25
     */
    function canBeListingNode(address user) external view returns (bool) {
        (uint256 score,,,,,,,,,) = _calculateScore(user);
        // solhint-disable-next-line gas-strict-inequalities
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
     * @notice Enforce per-verifier daily rate limit on score changes
     * @dev ATK-H04: Prevents a compromised VERIFIER_ROLE holder from
     *      mass-inflating sybil accounts' scores in a single day.
     *      Tracks changes per verifier per calendar day (UTC).
     *      Reverts with DailyVerifierLimitExceeded if limit reached.
     */
    function _enforceVerifierRateLimit() internal {
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        uint256 dailyCount =
            _verifierDailyChanges[msg.sender][today];
        // solhint-disable-next-line gas-strict-inequalities
        if (dailyCount >= MAX_VERIFIER_CHANGES_PER_DAY) {
            revert DailyVerifierLimitExceeded();
        }
        _verifierDailyChanges[msg.sender][today] =
            dailyCount + 1;
    }

    /**
     * @notice Calculate complete score breakdown for a user
     * @dev L-01: Internal view function shared by getScore(),
     *      getTotalScore(), canBeValidator(), and canBeListingNode().
     *      Eliminates external self-call overhead (~2,600 gas savings).
     *
     *      L-02: Score components and their ranges:
     *      - KYC Trust (0-20): Queried live from OmniRegistration
     *        Tier 0=0, Tier 1=5, Tier 2=10, Tier 3=15, Tier 4=20
     *      - Marketplace Reputation (-10 to +10): From verified reviews
     *        Average stars mapped: 1=-10, 2=-5, 3=0, 4=+5, 5=+10
     *      - Staking Score (0-24): Queried live from OmniCore
     *        Formula: (stakingTier * 3) + (durationTier * 3)
     *      - Referral Activity (0-10): Queried live from OmniRegistration
     *        One point per referral, capped at 10
     *      - Publisher Activity (0-4): Graduated listing count thresholds
     *        100=1pt, 1K=2pt, 10K=3pt, 100K=4pt
     *      - Marketplace Activity (0-5): Verified transaction count
     *        5=1pt, 10=2pt, 20=3pt, 50=4pt, 100+=5pt (with decay)
     *      - Community Policing (0-5): Validated accurate reports
     *        1=1pt, 5=2pt, 10=3pt, 20=4pt, 50+=5pt (with decay)
     *      - Forum Activity (0-5): Verified forum contributions
     *        1=1pt, 6=2pt, 16=3pt, 31=4pt, 51+=5pt (with decay)
     *      - Reliability (-5 to +5): Validator uptime percentage
     *        100%=+5, 95%+=+3, 90%+=+1, 80%+=0, 70%+=-2, <70%=-5
     *
     *      Raw range: -15 to 88. Clamped to 0-100.
     *
     * @param user Address to calculate score for
     * @return totalScore Total score clamped to 0-100
     * @return kycTrust KYC trust points (0-20)
     * @return marketplaceReputation Marketplace reputation (-10 to +10)
     * @return stakingScore Staking score (0-24)
     * @return referralActivity Referral activity (0-10)
     * @return publisherActivity Publisher activity (0-4)
     * @return marketplaceActivity Marketplace activity (0-5)
     * @return communityPolicing Community policing (0-5)
     * @return forumActivity Forum activity (0-5)
     * @return reliability Reliability (-5 to +5)
     */
    function _calculateScore(
        address user
    ) internal view returns (
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

        // Query on-chain components (live from external contracts)
        kycTrust = _getKYCTrust(user);
        stakingScore = _getStakingScore(user);
        referralActivity = _getReferralActivity(user);

        // Get stored components (M-03: apply decay at read time)
        marketplaceReputation = comp.marketplaceReputation;
        publisherActivity = comp.publisherActivity;
        marketplaceActivity = _applyDecay(
            comp.marketplaceActivity,
            comp.lastUpdate
        );
        communityPolicing = _applyDecay(
            comp.communityPolicing,
            comp.lastUpdate
        );
        forumActivity = _applyDecay(
            comp.forumActivity,
            comp.lastUpdate
        );
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
     * @notice Apply time-based decay to a score component
     * @dev M-05: Reduces score by 1 point per DECAY_PERIOD of inactivity.
     *      Score floors at 0. If lastUpdate is 0 (never set), no decay is applied.
     * @param score Current score value
     * @param lastUpdate Timestamp of the user's last activity update
     * @return Decayed score (>= 0)
     */
    function _applyDecay(
        uint8 score,
        uint256 lastUpdate
    ) internal view returns (uint8) {
        if (score == 0 || lastUpdate == 0) return score;

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed < DECAY_PERIOD) return score;

        uint256 decayPoints = elapsed / DECAY_PERIOD;
        // solhint-disable-next-line gas-strict-inequalities
        if (decayPoints >= score) return 0;
        return score - uint8(decayPoints);
    }

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev L-03: CRITICAL -- This action is IRREVERSIBLE. Once ossified,
     *      this contract can never be upgraded again. All future
     *      `upgradeTo()` / `upgradeToAndCall()` calls will revert.
     *
     *      Recommended deployment pattern (two-step with timelock):
     *      1. Deploy behind OpenZeppelin TimelockController (48h+ delay)
     *      2. Grant DEFAULT_ADMIN_ROLE to the timelock controller
     *      3. Schedule ossify() via timelock -- this triggers the delay
     *      4. After delay, execute ossify() to finalize
     *
     *      Pre-ossification checklist:
     *      - Run `hardhat-upgrades validateUpgrade()` to confirm no
     *        storage layout issues in the current implementation
     *      - Verify all scoring thresholds and decay parameters are final
     *      - Confirm external contract references (registration, omniCore)
     *        point to their intended permanent addresses
     *      - Ensure all VERIFIER_ROLE grants are finalized
     *
     *      I-02: Guard against double-ossification to prevent misleading
     *      duplicate events and wasted gas.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation contract
     * @dev Reverts if contract is ossified or new implementation is zero.
     *      L-03: Should be called through a TimelockController with
     *      a minimum 48-hour delay for production deployments.
     *      I-01: Validates newImplementation is not address(0).
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        UPGRADE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Reserved storage gap for future upgrades.
     * @dev Prevents storage collisions when new state variables are
     *      added in future implementations. Follows the OpenZeppelin
     *      upgradeable contract pattern.
     *      Reduced from 50 to 48 to accommodate:
     *      - _ossified (bool, 1 slot)
     *      - _verifierDailyChanges (mapping, 1 slot) [ATK-H04]
     */
    uint256[48] private __gap;
}
