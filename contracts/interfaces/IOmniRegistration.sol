// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOmniRegistration
 * @author OmniBazaar Team
 * @notice Interface for OmniRegistration contract
 * @dev Defines the public API for user registration and KYC management
 */
interface IOmniRegistration {
    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice User registration data structure
     * @param timestamp When the user registered
     * @param referrer Address of the user who referred this user
     * @param registeredBy Validator address who processed registration
     * @param phoneHash Hash of verified phone number
     * @param emailHash Hash of verified email address
     * @param kycTier KYC verification level (0-4)
     * @param depositRefunded Whether registration deposit was refunded
     * @param welcomeBonusClaimed Whether welcome bonus was claimed
     * @param firstSaleBonusClaimed Whether first sale bonus was claimed
     */
    struct Registration {
        uint256 timestamp;
        address referrer;
        address registeredBy;
        bytes32 phoneHash;
        bytes32 emailHash;
        uint8 kycTier;
        bool depositRefunded;
        bool welcomeBonusClaimed;
        bool firstSaleBonusClaimed;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new user is registered
     * @param user The registered user's address
     * @param referrer The referrer's address
     * @param registeredBy The validator who processed registration
     * @param timestamp Block timestamp of registration
     */
    event UserRegistered(
        address indexed user,
        address indexed referrer,
        address indexed registeredBy,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a validator attests to user's KYC
     * @param user The user being attested
     * @param tier The KYC tier being attested
     * @param attestor The validator providing attestation
     * @param attestationCount Current number of attestations
     */
    event KYCAttested(
        address indexed user,
        uint8 tier,
        address indexed attestor,
        uint256 attestationCount
    );

    /**
     * @notice Emitted when a user's KYC tier is upgraded
     * @param user The user whose KYC was upgraded
     * @param oldTier Previous KYC tier
     * @param newTier New KYC tier
     */
    event KYCUpgraded(address indexed user, uint8 oldTier, uint8 newTier);

    /**
     * @notice Emitted when a user's deposit is refunded
     * @param user The user receiving refund
     * @param amount Amount refunded
     */
    event DepositRefunded(address indexed user, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice User is already registered
    error AlreadyRegistered();

    /// @notice Phone number hash has already been used
    error PhoneAlreadyUsed();

    /// @notice Email hash has already been used
    error EmailAlreadyUsed();

    /// @notice Provided referrer is not a registered user
    error InvalidReferrer();

    /// @notice User cannot refer themselves
    error SelfReferralNotAllowed();

    /// @notice Validator cannot be referrer for registration they process
    error ValidatorCannotBeReferrer();

    /// @notice Daily registration limit exceeded
    error DailyLimitExceeded();

    /// @notice Insufficient deposit sent
    error InsufficientDeposit();

    /// @notice User is not registered
    error NotRegistered();

    /// @notice Cooling period has not elapsed
    error CoolingPeriodActive();

    /// @notice Validator has already attested
    error AlreadyAttested();

    /// @notice Invalid KYC tier specified
    error InvalidKYCTier();

    /// @notice Deposit already refunded
    error DepositAlreadyRefunded();

    /// @notice KYC required for this action
    error KYCRequired();

    /// @notice Bonus already claimed
    error BonusAlreadyClaimed();

    // ═══════════════════════════════════════════════════════════════════════
    //                              FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a new user with on-chain record
     * @param user The user's wallet address to register
     * @param referrer The referrer's address (address(0) for none)
     * @param phoneHash Hash of verified phone number
     * @param emailHash Hash of verified email address
     */
    function registerUser(
        address user,
        address referrer,
        bytes32 phoneHash,
        bytes32 emailHash
    ) external payable;

    /**
     * @notice Attest to a user's KYC verification
     * @param user The user being attested
     * @param tier The KYC tier being attested (2, 3, or 4)
     */
    function attestKYC(address user, uint8 tier) external;

    /**
     * @notice Refund registration deposit after KYC Tier 2+
     */
    function refundDeposit() external;

    /**
     * @notice Mark welcome bonus as claimed
     * @param user The user who claimed
     */
    function markWelcomeBonusClaimed(address user) external;

    /**
     * @notice Mark first sale bonus as claimed
     * @param user The user who claimed
     */
    function markFirstSaleBonusClaimed(address user) external;

    /**
     * @notice Get full registration data for a user
     * @param user The user address
     * @return Registration struct
     */
    function getRegistration(
        address user
    ) external view returns (Registration memory);

    /**
     * @notice Check if user is registered
     * @param user The user address
     * @return True if registered
     */
    function isRegistered(address user) external view returns (bool);

    /**
     * @notice Check if user can claim welcome bonus
     * @param user The user address
     * @return True if eligible
     */
    function canClaimWelcomeBonus(address user) external view returns (bool);

    /**
     * @notice Check if user can claim first sale bonus
     * @param user The user address
     * @return True if eligible
     */
    function canClaimFirstSaleBonus(address user) external view returns (bool);

    /**
     * @notice Get KYC attestation count for user at tier
     * @param user The user address
     * @param tier The KYC tier
     * @return Number of attestations
     */
    function getKYCAttestationCount(
        address user,
        uint8 tier
    ) external view returns (uint256);

    /**
     * @notice Get referrer for a user
     * @param user The user address
     * @return Referrer address
     */
    function getReferrer(address user) external view returns (address);

    /**
     * @notice Get total registrations
     * @return Total count
     */
    function totalRegistrations() external view returns (uint256);

    /**
     * @notice Get registration deposit amount
     * @return Deposit in wei
     */
    function REGISTRATION_DEPOSIT() external view returns (uint256);

    /**
     * @notice Get cooling period duration
     * @return Duration in seconds
     */
    function COOLING_PERIOD() external view returns (uint256);

    /**
     * @notice Get KYC attestation threshold
     * @return Number required
     */
    function KYC_ATTESTATION_THRESHOLD() external view returns (uint256);
}
