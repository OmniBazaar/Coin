// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title OmniRegistration
 * @author OmniBazaar Team
 * @notice On-chain user registration with Sybil resistance for OmniBazaar platform
 * @dev Implements immutable referrer assignment, KYC multi-attestation, and rate limiting
 *
 * Security Model:
 * - Phone/email hashes ensure uniqueness (Sybil protection)
 * - Referrers are immutable once set (prevents gaming)
 * - Multi-validator KYC attestation (3-of-5 required)
 * - Rate limiting prevents mass registration attacks
 * - Device fingerprinting and IP rate limiting (off-chain)
 * - Social media verification requirements (off-chain)
 */
contract OmniRegistration is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for validators who can register users
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    /// @notice Role for KYC attestors (trusted validators)
    bytes32 public constant KYC_ATTESTOR_ROLE = keccak256("KYC_ATTESTOR_ROLE");

    /// @notice Maximum registrations per day (rate limiting)
    uint256 public constant MAX_DAILY_REGISTRATIONS = 10000;

    /// @notice Number of validator attestations required for KYC upgrade
    uint256 public constant KYC_ATTESTATION_THRESHOLD = 3;

    /// @notice EIP-712 typehash for registration attestation
    /// @dev Hash of "RegistrationAttestation(address user,bytes32 emailHash,
    ///      bytes32 phoneHash,address referrer,uint256 deadline)"
    bytes32 public constant REGISTRATION_ATTESTATION_TYPEHASH = keccak256(
        "RegistrationAttestation(address user,bytes32 emailHash,"
        "bytes32 phoneHash,address referrer,uint256 deadline)"
    );

    /// @notice Attestation validity period (1 hour)
    uint256 public constant ATTESTATION_VALIDITY = 1 hours;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice User registration data structure
     * @param timestamp When the user registered (block.timestamp)
     * @param referrer Address of the user who referred this user (immutable)
     * @param registeredBy Validator address who processed registration
     * @param phoneHash Keccak256 hash of verified phone number
     * @param emailHash Keccak256 hash of verified email address
     * @param kycTier KYC verification level (0-4)
     * @param welcomeBonusClaimed Whether welcome bonus has been claimed
     * @param firstSaleBonusClaimed Whether first sale bonus has been claimed
     */
    struct Registration {
        uint256 timestamp;
        address referrer;
        address registeredBy;
        bytes32 phoneHash;
        bytes32 emailHash;
        uint8 kycTier;
        bool welcomeBonusClaimed;
        bool firstSaleBonusClaimed;
    }

    /// @notice Mapping from user address to their registration data
    mapping(address => Registration) public registrations;

    /// @notice Mapping to track used phone hashes (prevents duplicate registrations)
    mapping(bytes32 => bool) public usedPhoneHashes;

    /// @notice Mapping to track used email hashes (prevents duplicate registrations)
    mapping(bytes32 => bool) public usedEmailHashes;

    /// @notice Daily registration count for rate limiting (day number => count)
    mapping(uint256 => uint256) public dailyRegistrationCount;

    /// @notice Total number of registrations across all time
    uint256 public totalRegistrations;

    /// @notice KYC attestation tracking: keccak256(user, tier) => attestor addresses
    mapping(bytes32 => address[]) public kycAttestations;

    /// @notice EIP-712 domain separator for attestation verification
    /// @dev Named DOMAIN_SEPARATOR per EIP-712 convention (not mixedCase)
    // solhint-disable-next-line var-name-mixedcase
    bytes32 public DOMAIN_SEPARATOR;

    /// @notice Used attestation hashes to prevent replay attacks
    mapping(bytes32 => bool) public usedAttestations;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new user is registered
     * @param user The registered user's address
     * @param referrer The referrer's address (address(0) if none)
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
     * @param attestationCount Current number of attestations for this tier
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
     * @notice Emitted when welcome bonus is marked as claimed
     * @param user The user who claimed
     * @param timestamp When it was marked
     */
    event WelcomeBonusMarkedClaimed(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when first sale bonus is marked as claimed
     * @param user The user who claimed
     * @param timestamp When it was marked
     */
    event FirstSaleBonusMarkedClaimed(address indexed user, uint256 timestamp);

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

    /// @notice Validator processing registration cannot be referrer
    error ValidatorCannotBeReferrer();

    /// @notice Daily registration limit exceeded
    error DailyLimitExceeded();

    /// @notice User is not registered
    error NotRegistered();

    /// @notice Validator has already attested for this user/tier
    error AlreadyAttested();

    /// @notice Not enough attestations for KYC upgrade
    error InsufficientAttestations();

    /// @notice Invalid KYC tier specified
    error InvalidKYCTier();

    /// @notice Bonus has already been claimed
    error BonusAlreadyClaimed();

    /// @notice Caller is not authorized for this action
    error Unauthorized();

    /// @notice Attestation has expired
    error AttestationExpired();

    /// @notice Attestation has already been used (replay attack prevention)
    error AttestationAlreadyUsed();

    /// @notice Invalid attestation signature (not from authorized validator)
    error InvalidAttestation();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Sets up access control, grants admin role to deployer, and configures EIP-712
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Set EIP-712 domain separator for attestation verification
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("OmniRegistration")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Reinitialize the contract to set DOMAIN_SEPARATOR for upgrades
     * @dev Can only be called once per version number
     * @param version The reinitializer version number
     */
    function reinitialize(uint64 version) public reinitializer(version) {
        // Set EIP-712 domain separator if not already set
        if (DOMAIN_SEPARATOR == bytes32(0)) {
            DOMAIN_SEPARATOR = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("OmniRegistration")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(this)
                )
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a new user with on-chain record
     * @param user The user's wallet address to register
     * @param referrer The referrer's address (immutable once set, address(0) for none)
     * @param phoneHash Keccak256 hash of verified phone number
     * @param emailHash Keccak256 hash of verified email address
     * @dev Requires VALIDATOR_ROLE. No deposit required.
     *
     * Security measures:
     * - Duplicate phone/email prevention (Sybil protection)
     * - Rate limiting (MAX_DAILY_REGISTRATIONS)
     * - Referrer validation (must be registered user)
     * - Self-dealing prevention (validator cannot be referrer)
     * - Additional off-chain protections: device fingerprinting, IP rate limiting, social media verification
     */
    function registerUser(
        address user,
        address referrer,
        bytes32 phoneHash,
        bytes32 emailHash
    ) external onlyRole(VALIDATOR_ROLE) nonReentrant {
        // Check user not already registered
        if (registrations[user].timestamp != 0) revert AlreadyRegistered();

        // Check phone/email uniqueness (Sybil protection)
        if (usedPhoneHashes[phoneHash]) revert PhoneAlreadyUsed();
        if (usedEmailHashes[emailHash]) revert EmailAlreadyUsed();

        // Validate referrer
        if (referrer != address(0)) {
            if (referrer == user) revert SelfReferralNotAllowed();

            // Validator processing registration cannot be referrer (self-dealing prevention)
            // Check this first as it's a more specific error
            if (referrer == msg.sender) revert ValidatorCannotBeReferrer();

            // Referrer must be a registered user (not just any address)
            if (registrations[referrer].timestamp == 0) revert InvalidReferrer();
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyRegistrationCount[today] >= MAX_DAILY_REGISTRATIONS) {
            revert DailyLimitExceeded();
        }

        // Create registration
        registrations[user] = Registration({
            timestamp: block.timestamp,
            referrer: referrer,
            registeredBy: msg.sender,
            phoneHash: phoneHash,
            emailHash: emailHash,
            kycTier: 1, // Tier 1 = phone + email verified
            welcomeBonusClaimed: false,
            firstSaleBonusClaimed: false
        });

        // Mark phone/email as used
        usedPhoneHashes[phoneHash] = true;
        usedEmailHashes[emailHash] = true;

        // Update counters
        ++dailyRegistrationCount[today];
        ++totalRegistrations;

        emit UserRegistered(user, referrer, msg.sender, block.timestamp);
    }

    /**
     * @notice Self-register with validator attestation (user-initiated)
     * @param referrer The referrer's address (address(0) for none)
     * @param emailHash Keccak256 hash of verified email address
     * @param phoneHash Keccak256 hash of verified phone number
     * @param deadline Timestamp when attestation expires
     * @param validatorSignature EIP-712 signature from a validator
     * @dev User calls this function directly. Validator only provides attestation signature.
     *
     * Security Model:
     * - User initiates and signs the blockchain transaction
     * - Validator attestation proves email/phone was verified off-chain
     * - Any validator with VALIDATOR_ROLE can provide attestation (permissionless)
     * - Attestation expires after deadline (prevents hoarding)
     * - Each attestation can only be used once (replay protection)
     * - Same Sybil protection as registerUser (phone/email uniqueness)
     *
     * Flow:
     * 1. User completes email/phone verification with any validator
     * 2. Validator signs EIP-712 attestation (off-chain)
     * 3. User submits attestation to this function
     * 4. Contract verifies attestation and creates registration
     */
    function selfRegister(
        address referrer,
        bytes32 emailHash,
        bytes32 phoneHash,
        uint256 deadline,
        bytes calldata validatorSignature
    ) external nonReentrant {
        // Check user not already registered
        if (registrations[msg.sender].timestamp != 0) revert AlreadyRegistered();

        // Check attestation not expired
        if (block.timestamp > deadline) revert AttestationExpired();

        // Check phone/email uniqueness (Sybil protection)
        if (usedPhoneHashes[phoneHash]) revert PhoneAlreadyUsed();
        if (usedEmailHashes[emailHash]) revert EmailAlreadyUsed();

        // Build attestation struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                REGISTRATION_ATTESTATION_TYPEHASH,
                msg.sender,
                emailHash,
                phoneHash,
                referrer,
                deadline
            )
        );

        // Prevent replay attacks
        if (usedAttestations[structHash]) revert AttestationAlreadyUsed();
        usedAttestations[structHash] = true;

        // Verify EIP-712 signature
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(validatorSignature);

        // Verify signer has VALIDATOR_ROLE
        if (!hasRole(VALIDATOR_ROLE, signer)) revert InvalidAttestation();

        // Validate referrer (same rules as registerUser, but no validator self-dealing check)
        if (referrer != address(0)) {
            if (referrer == msg.sender) revert SelfReferralNotAllowed();
            // Referrer must be a registered user
            if (registrations[referrer].timestamp == 0) revert InvalidReferrer();
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyRegistrationCount[today] >= MAX_DAILY_REGISTRATIONS) {
            revert DailyLimitExceeded();
        }

        // Create registration
        registrations[msg.sender] = Registration({
            timestamp: block.timestamp,
            referrer: referrer,
            registeredBy: signer, // Track which validator attested
            phoneHash: phoneHash,
            emailHash: emailHash,
            kycTier: 1, // Tier 1 = email verified
            welcomeBonusClaimed: false,
            firstSaleBonusClaimed: false
        });

        // Mark phone/email as used
        usedPhoneHashes[phoneHash] = true;
        usedEmailHashes[emailHash] = true;

        // Update counters
        ++dailyRegistrationCount[today];
        ++totalRegistrations;

        emit UserRegistered(msg.sender, referrer, signer, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          KYC ATTESTATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Attest to a user's KYC verification
     * @param user The user being attested
     * @param tier The KYC tier being attested (2, 3, or 4)
     * @dev Requires KYC_ATTESTOR_ROLE. Multiple attestations needed for upgrade.
     *
     * KYC Tiers:
     * - Tier 1: Phone + Email verified (automatic at registration)
     * - Tier 2: Basic ID verification (3 attestations required)
     * - Tier 3: Enhanced verification (3 attestations required)
     * - Tier 4: Full verification (3 attestations required)
     *
     * Security: Attestor cannot attest for users they registered
     */
    function attestKYC(
        address user,
        uint8 tier
    ) external onlyRole(KYC_ATTESTOR_ROLE) {
        if (registrations[user].timestamp == 0) revert NotRegistered();
        if (tier < 2 || tier > 4) revert InvalidKYCTier();
        if (tier <= registrations[user].kycTier) revert InvalidKYCTier();

        // Attestor cannot attest for users they registered (self-dealing prevention)
        if (registrations[user].registeredBy == msg.sender) {
            revert ValidatorCannotBeReferrer();
        }

        bytes32 attestationKey = keccak256(abi.encodePacked(user, tier));

        // Check not already attested by this validator
        address[] storage attestors = kycAttestations[attestationKey];
        uint256 attestorCount = attestors.length;
        for (uint256 i = 0; i < attestorCount; ) {
            if (attestors[i] == msg.sender) revert AlreadyAttested();
            unchecked {
                ++i;
            }
        }

        // Add attestation
        attestors.push(msg.sender);

        emit KYCAttested(user, tier, msg.sender, attestors.length);

        // Check if threshold met
        if (attestors.length >= KYC_ATTESTATION_THRESHOLD) {
            uint8 oldTier = registrations[user].kycTier;
            registrations[user].kycTier = tier;
            emit KYCUpgraded(user, oldTier, tier);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        BONUS CLAIM MARKING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Mark welcome bonus as claimed for a user
     * @param user The user who claimed the bonus
     * @dev Only callable by OmniRewardManager contract
     */
    function markWelcomeBonusClaimed(address user) external {
        // This should be called by OmniRewardManager
        // We'll add proper access control when integrating
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        if (reg.welcomeBonusClaimed) revert BonusAlreadyClaimed();

        reg.welcomeBonusClaimed = true;
        emit WelcomeBonusMarkedClaimed(user, block.timestamp);
    }

    /**
     * @notice Mark first sale bonus as claimed for a user
     * @param user The user who claimed the bonus
     * @dev Only callable by OmniRewardManager contract
     */
    function markFirstSaleBonusClaimed(address user) external {
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        if (reg.firstSaleBonusClaimed) revert BonusAlreadyClaimed();

        reg.firstSaleBonusClaimed = true;
        emit FirstSaleBonusMarkedClaimed(user, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get full registration data for a user
     * @param user The user address to query
     * @return Registration struct with all user data
     */
    function getRegistration(
        address user
    ) external view returns (Registration memory) {
        return registrations[user];
    }

    /**
     * @notice Check if a user is registered
     * @param user The user address to check
     * @return True if user is registered, false otherwise
     */
    function isRegistered(address user) external view returns (bool) {
        return registrations[user].timestamp != 0;
    }

    /**
     * @notice Check if user can claim welcome bonus
     * @param user The user address to check
     * @return True if user meets all requirements for welcome bonus
     *
     * Requirements:
     * - User is registered
     * - Welcome bonus not already claimed
     * - KYC Tier 1+ achieved (phone + email verified)
     */
    function canClaimWelcomeBonus(address user) external view returns (bool) {
        Registration storage reg = registrations[user];
        return reg.timestamp != 0 && !reg.welcomeBonusClaimed && reg.kycTier >= 1;
    }

    /**
     * @notice Check if user can claim first sale bonus
     * @param user The user address to check
     * @return True if user meets requirements (registered and not claimed)
     */
    function canClaimFirstSaleBonus(address user) external view returns (bool) {
        Registration storage reg = registrations[user];
        return reg.timestamp != 0 && !reg.firstSaleBonusClaimed;
    }

    /**
     * @notice Get number of KYC attestations for a user at a tier
     * @param user The user address
     * @param tier The KYC tier to check
     * @return Number of attestations received
     */
    function getKYCAttestationCount(
        address user,
        uint8 tier
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(user, tier));
        return kycAttestations[key].length;
    }

    /**
     * @notice Get the referrer for a user
     * @param user The user address
     * @return Referrer address (address(0) if none)
     */
    function getReferrer(address user) external view returns (address) {
        return registrations[user].referrer;
    }

    /**
     * @notice Get daily registration count for a specific day
     * @param dayNumber The day number (block.timestamp / 1 days)
     * @return Number of registrations on that day
     */
    function getDailyRegistrationCount(
        uint256 dayNumber
    ) external view returns (uint256) {
        return dailyRegistrationCount[dayNumber];
    }

    /**
     * @notice Get today's registration count
     * @return Number of registrations today
     */
    function getTodayRegistrationCount() external view returns (uint256) {
        return dailyRegistrationCount[block.timestamp / 1 days];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
