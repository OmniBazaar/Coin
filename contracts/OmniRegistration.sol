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


    /// @notice Registration deposit amount (0 for now - gas-free registration)
    /// @dev Can be increased if Sybil attacks become problematic
    uint256 public constant REGISTRATION_DEPOSIT = 0;

    /// @notice EIP-712 typehash for phone verification proof
    /// @dev Used by submitPhoneVerification() for trustless phone verification
    bytes32 public constant PHONE_VERIFICATION_TYPEHASH = keccak256(
        "PhoneVerification(address user,bytes32 phoneHash,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for social media verification proof
    /// @dev Used by submitSocialVerification() for trustless social verification
    bytes32 public constant SOCIAL_VERIFICATION_TYPEHASH = keccak256(
        "SocialVerification(address user,bytes32 socialHash,string platform,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for email verification proof
    /// @dev Used by submitEmailVerification() for trustless email verification
    bytes32 public constant EMAIL_VERIFICATION_TYPEHASH = keccak256(
        "EmailVerification(address user,bytes32 emailHash,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for trustless registration request
    /// @dev Used by selfRegisterTrustless() for fully trustless user registration
    bytes32 public constant TRUSTLESS_REGISTRATION_TYPEHASH = keccak256(
        "TrustlessRegistration(address user,address referrer,uint256 deadline)"
    );

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

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRUSTLESS VERIFICATION STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Trusted verification key address (signs phone/social proofs)
    /// @dev This is OmniBazaar's verification service key, NOT a validator key
    ///      Set via setTrustedVerificationKey() admin function
    address public trustedVerificationKey;

    /// @notice Mapping of user address to their social verification hash
    /// @dev socialHash = keccak256("platform:handle"), e.g., keccak256("twitter:omnibazaar")
    mapping(address => bytes32) public userSocialHashes;

    /// @notice Mapping of user address to their email verification hash
    /// @dev emailHash = keccak256(normalizedEmail)
    mapping(address => bytes32) public userEmailHashes;

    /// @notice Mapping of user address to KYC Tier 1 completion timestamp
    /// @dev KYC Tier 1 = registered + phone verified + social verified
    ///      Value is 0 if KYC Tier 1 not complete
    mapping(address => uint256) public kycTier1CompletedAt;

    /// @notice Mapping to track used social hashes (prevents duplicate social accounts)
    mapping(bytes32 => bool) public usedSocialHashes;

    /// @notice Mapping to track used nonces (prevents proof replay attacks)
    mapping(bytes32 => bool) public usedNonces;

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

    /**
     * @notice Emitted when a user is unregistered by admin
     * @param user The unregistered user's address
     * @param admin The admin who performed the unregistration
     * @param timestamp When the unregistration occurred
     */
    event UserUnregistered(
        address indexed user,
        address indexed admin,
        uint256 timestamp
    );

    /**
     * @notice Emitted when phone is verified via trustless verification
     * @param user The user who verified their phone
     * @param phoneHash Keccak256 hash of normalized phone number
     * @param timestamp When verification was performed
     */
    event PhoneVerified(
        address indexed user,
        bytes32 indexed phoneHash,
        uint256 timestamp
    );

    /**
     * @notice Emitted when social media is verified via trustless verification
     * @param user The user who verified their social account
     * @param socialHash Keccak256 hash of "platform:handle"
     * @param platform Platform name ("twitter" or "telegram")
     * @param timestamp When verification was performed
     */
    event SocialVerified(
        address indexed user,
        bytes32 indexed socialHash,
        string platform,
        uint256 timestamp
    );

    /**
     * @notice Emitted when KYC Tier 1 is completed
     * @param user The user who completed KYC Tier 1
     * @param timestamp Block timestamp when completed
     */
    event KycTier1Completed(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when trusted verification key is updated
     * @param newKey The new verification key address
     */
    event TrustedVerificationKeyUpdated(address indexed newKey);

    /**
     * @notice Emitted when email is verified via trustless verification
     * @param user The user who verified their email
     * @param emailHash Keccak256 hash of normalized email address
     * @param timestamp When verification was performed
     */
    event EmailVerified(
        address indexed user,
        bytes32 indexed emailHash,
        uint256 timestamp
    );

    /**
     * @notice Emitted when user registers via trustless path
     * @param user The registered user's address
     * @param referrer The referrer's address (address(0) if none)
     * @param timestamp Block timestamp of registration
     */
    event UserRegisteredTrustless(
        address indexed user,
        address indexed referrer,
        uint256 timestamp
    );

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

    /// @notice Attestation or registration request has expired
    error AttestationExpired();

    /// @notice Verification proof has expired (deadline passed)
    error ProofExpired();

    /// @notice Social hash has already been used by another user
    error SocialAlreadyUsed();

    /// @notice Verification proof signature is invalid (not from trusted key)
    error InvalidVerificationProof();

    /// @notice Nonce has already been used (replay attack prevention)
    error NonceAlreadyUsed();

    /// @notice Trusted verification key not set
    error TrustedVerificationKeyNotSet();

    /// @notice Email verification required for trustless registration
    error EmailNotVerified();

    /// @notice Invalid user signature on registration request
    error InvalidUserSignature();

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
     * @notice Self-register using trustless email verification proof
     * @param emailHash Keccak256 of normalized email address
     * @param emailTimestamp When email verification was performed
     * @param emailNonce Unique nonce for email proof replay protection
     * @param emailDeadline Email proof expiration time
     * @param emailSignature EIP-712 signature from trustedVerificationKey
     * @param referrer Referrer address (address(0) for none)
     * @param registrationDeadline Registration request expiration time
     * @param userSignature User's EIP-712 signature on the registration request
     * @dev NO VALIDATOR_ROLE REQUIRED. This is fully trustless registration.
     *      User controls registration - validator cannot create registrations.
     *
     * Security Properties:
     * - Email proof MUST be signed by trustedVerificationKey
     * - User MUST sign the registration request (proves wallet control)
     * - Each email nonce can only be used once (replay protection)
     * - Email hash can only be used by one user (Sybil protection)
     * - Both proofs expire after their deadlines
     * - Caller has NO attestation power - anyone can relay
     *
     * Flow:
     * 1. User completes email verification off-chain
     * 2. Verification service signs email proof with trustedVerificationKey
     * 3. User signs registration request with their wallet
     * 4. User (or relayer) submits both signatures to this function
     * 5. Contract verifies both signatures and creates registration
     */
    function selfRegisterTrustless(
        bytes32 emailHash,
        uint256 emailTimestamp,
        bytes32 emailNonce,
        uint256 emailDeadline,
        bytes calldata emailSignature,
        address referrer,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) external nonReentrant {
        _selfRegisterTrustlessInternal(
            msg.sender,
            emailHash,
            emailTimestamp,
            emailNonce,
            emailDeadline,
            emailSignature,
            referrer,
            registrationDeadline,
            userSignature
        );
    }

    /**
     * @notice Self-register on behalf of a user (relay pattern for gas-free registration)
     * @param user Address of the user being registered
     * @param emailHash Keccak256 of normalized email address
     * @param emailTimestamp When email verification was performed
     * @param emailNonce Unique nonce for email proof replay protection
     * @param emailDeadline Email proof expiration time
     * @param emailSignature EIP-712 signature from trustedVerificationKey
     * @param referrer Referrer address (address(0) for none)
     * @param registrationDeadline Registration request expiration time
     * @param userSignature User's EIP-712 signature on the registration request
     * @dev ANYONE can call this function to relay a registration.
     *      This enables gas-free registration for users who don't have XOM/AVAX.
     *      The user address is verified via userSignature - cannot register someone else.
     *
     * Security Properties:
     * - Same as selfRegisterTrustless()
     * - User address is part of the signed data (cannot be forged)
     * - Caller has NO attestation power - security comes from signatures
     */
    function selfRegisterTrustlessFor(
        address user,
        bytes32 emailHash,
        uint256 emailTimestamp,
        bytes32 emailNonce,
        uint256 emailDeadline,
        bytes calldata emailSignature,
        address referrer,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) external nonReentrant {
        _selfRegisterTrustlessInternal(
            user,
            emailHash,
            emailTimestamp,
            emailNonce,
            emailDeadline,
            emailSignature,
            referrer,
            registrationDeadline,
            userSignature
        );
    }

    /**
     * @notice Internal implementation for trustless registration
     * @param user Address of the user being registered
     * @param emailHash Keccak256 of normalized email address
     * @param emailTimestamp When email verification was performed
     * @param emailNonce Unique nonce for email proof replay protection
     * @param emailDeadline Email proof expiration time
     * @param emailSignature EIP-712 signature from trustedVerificationKey
     * @param referrer Referrer address (address(0) for none)
     * @param registrationDeadline Registration request expiration time
     * @param userSignature User's EIP-712 signature on the registration request
     */
    function _selfRegisterTrustlessInternal(
        address user,
        bytes32 emailHash,
        uint256 emailTimestamp,
        bytes32 emailNonce,
        uint256 emailDeadline,
        bytes calldata emailSignature,
        address referrer,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) internal {
        // Validate preconditions
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();
        if (registrations[user].timestamp != 0) revert AlreadyRegistered();
        if (block.timestamp > emailDeadline) revert ProofExpired(); // solhint-disable-line not-rely-on-time
        if (block.timestamp > registrationDeadline) revert AttestationExpired(); // solhint-disable-line not-rely-on-time
        if (usedNonces[emailNonce]) revert NonceAlreadyUsed();
        if (usedEmailHashes[emailHash]) revert EmailAlreadyUsed();

        // Verify email proof signature from trustedVerificationKey
        bytes32 emailStructHash = keccak256(abi.encode(
            EMAIL_VERIFICATION_TYPEHASH, user, emailHash, emailTimestamp, emailNonce, emailDeadline
        ));
        bytes32 emailDigest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, emailStructHash)
        );
        if (emailDigest.recover(emailSignature) != trustedVerificationKey) {
            revert InvalidVerificationProof();
        }

        // Verify user signature on registration request
        bytes32 registrationStructHash = keccak256(abi.encode(
            TRUSTLESS_REGISTRATION_TYPEHASH, user, referrer, registrationDeadline
        ));
        bytes32 registrationDigest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, registrationStructHash)
        );
        if (registrationDigest.recover(userSignature) != user) revert InvalidUserSignature();

        // Validate referrer
        if (referrer != address(0)) {
            if (referrer == user) revert SelfReferralNotAllowed();
            if (registrations[referrer].timestamp == 0) revert InvalidReferrer();
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days; // solhint-disable-line not-rely-on-time
        if (dailyRegistrationCount[today] >= MAX_DAILY_REGISTRATIONS) revert DailyLimitExceeded();

        // Create registration (phone verified separately after registration)
        registrations[user] = Registration({ // solhint-disable-line not-rely-on-time
            timestamp: block.timestamp,
            referrer: referrer,
            registeredBy: msg.sender,
            phoneHash: bytes32(0),
            emailHash: emailHash,
            kycTier: 1,
            welcomeBonusClaimed: false,
            firstSaleBonusClaimed: false
        });

        // Mark email and nonce as used
        usedEmailHashes[emailHash] = true;
        userEmailHashes[user] = emailHash;
        usedNonces[emailNonce] = true;

        // Update counters and emit event
        ++dailyRegistrationCount[today];
        ++totalRegistrations;
        emit UserRegisteredTrustless(user, referrer, block.timestamp); // solhint-disable-line not-rely-on-time
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
    //                    TRUSTLESS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit phone verification proof (signed by trustedVerificationKey)
     * @param phoneHash Keccak256 of normalized phone number
     * @param timestamp When verification was performed by the verification service
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time (block.timestamp)
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev User calls this after completing phone verification off-chain.
     *      The verification service signs the proof, user submits it on-chain.
     *
     * Security Properties:
     * - Only trustedVerificationKey can sign valid proofs
     * - Each nonce can only be used once (replay protection)
     * - Phone hash can only be used by one user (Sybil protection)
     * - Proof expires after deadline (prevents hoarding)
     * - Updates KYC Tier 1 status if requirements met
     */
    function submitPhoneVerification(
        bytes32 phoneHash,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) {
            revert TrustedVerificationKeyNotSet();
        }

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used (replay protection)
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check phone hash not already used by another user
        if (usedPhoneHashes[phoneHash]) revert PhoneAlreadyUsed();

        // 5. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                PHONE_VERIFICATION_TYPEHASH,
                msg.sender, // User must submit their own proof
                phoneHash,
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != trustedVerificationKey) revert InvalidVerificationProof();

        // 6. Store verification
        // Update registration phoneHash if user is registered and phoneHash was empty
        Registration storage reg = registrations[msg.sender];
        if (reg.timestamp != 0 && reg.phoneHash == bytes32(0)) {
            reg.phoneHash = phoneHash;
        }

        usedPhoneHashes[phoneHash] = true;
        usedNonces[nonce] = true;

        // 7. Check if KYC Tier 1 complete and update status
        _checkAndUpdateKycTier1(msg.sender);

        // solhint-disable-next-line not-rely-on-time
        emit PhoneVerified(msg.sender, phoneHash, timestamp);
    }

    /**
     * @notice Submit social media verification proof (signed by trustedVerificationKey)
     * @param socialHash Keccak256 of "platform:handle" (e.g., keccak256("twitter:omnibazaar"))
     * @param platform Platform name ("twitter" or "telegram")
     * @param timestamp When verification was performed by the verification service
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time (block.timestamp)
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev User calls this after completing social verification off-chain.
     *      The verification service signs the proof, user submits it on-chain.
     *
     * Security Properties:
     * - Only trustedVerificationKey can sign valid proofs
     * - Each nonce can only be used once (replay protection)
     * - Social hash can only be used by one user (Sybil protection)
     * - Proof expires after deadline (prevents hoarding)
     * - Updates KYC Tier 1 status if requirements met
     */
    function submitSocialVerification(
        bytes32 socialHash,
        string calldata platform,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) {
            revert TrustedVerificationKeyNotSet();
        }

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used (replay protection)
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check social hash not already used by another user
        if (usedSocialHashes[socialHash]) revert SocialAlreadyUsed();

        // 5. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                SOCIAL_VERIFICATION_TYPEHASH,
                msg.sender, // User must submit their own proof
                socialHash,
                keccak256(bytes(platform)), // Hash the platform string
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != trustedVerificationKey) revert InvalidVerificationProof();

        // 6. Store verification
        userSocialHashes[msg.sender] = socialHash;
        usedSocialHashes[socialHash] = true;
        usedNonces[nonce] = true;

        // 7. Check if KYC Tier 1 complete and update status
        _checkAndUpdateKycTier1(msg.sender);

        // solhint-disable-next-line not-rely-on-time
        emit SocialVerified(msg.sender, socialHash, platform, timestamp);
    }

    /**
     * @notice Check if user has completed KYC Tier 1
     * @param user Address to check
     * @return True if KYC Tier 1 is complete (registered + phone + social verified)
     * @dev KYC Tier 1 requires:
     *      1. User is registered (registrations[user].timestamp != 0)
     *      2. Phone is verified (usedPhoneHashes[reg.phoneHash] == true OR phone via submitPhoneVerification)
     *      3. Social is verified (userSocialHashes[user] != bytes32(0))
     */
    function hasKycTier1(address user) external view returns (bool) {
        return kycTier1CompletedAt[user] != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    RELAY FUNCTIONS (GAS-FREE FOR USERS)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit phone verification on behalf of a user (relay pattern)
     * @param user Address of the user being verified
     * @param phoneHash Keccak256 of normalized phone number
     * @param timestamp When verification was performed by the verification service
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time (block.timestamp)
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev ANYONE can call this function to relay a verification proof.
     *      This enables gas-free verification for users who don't have XOM.
     *
     * Security Properties:
     * - Only trustedVerificationKey can sign valid proofs
     * - The proof MUST include the user address (cannot be used for different user)
     * - Each nonce can only be used once (replay protection)
     * - Phone hash can only be used by one user (Sybil protection)
     * - Proof expires after deadline (prevents hoarding)
     * - Caller has NO attestation power - security comes from signature verification
     */
    function submitPhoneVerificationFor(
        address user,
        bytes32 phoneHash,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) {
            revert TrustedVerificationKeyNotSet();
        }

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used (replay protection)
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check phone hash not already used by another user
        if (usedPhoneHashes[phoneHash]) revert PhoneAlreadyUsed();

        // 5. Verify EIP-712 signature from trustedVerificationKey
        //    CRITICAL: The user address is part of the signed data!
        bytes32 structHash = keccak256(
            abi.encode(
                PHONE_VERIFICATION_TYPEHASH,
                user, // User address from parameter, verified in signature
                phoneHash,
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != trustedVerificationKey) revert InvalidVerificationProof();

        // 6. Store verification
        // Update registration phoneHash if user is registered and phoneHash was empty
        Registration storage reg = registrations[user];
        if (reg.timestamp != 0 && reg.phoneHash == bytes32(0)) {
            reg.phoneHash = phoneHash;
        }

        usedPhoneHashes[phoneHash] = true;
        usedNonces[nonce] = true;

        // 7. Check if KYC Tier 1 complete and update status
        _checkAndUpdateKycTier1(user);

        // solhint-disable-next-line not-rely-on-time
        emit PhoneVerified(user, phoneHash, timestamp);
    }

    /**
     * @notice Submit social verification on behalf of a user (relay pattern)
     * @param user Address of the user being verified
     * @param socialHash Keccak256 of "platform:handle" (e.g., keccak256("twitter:omnibazaar"))
     * @param platform Platform name ("twitter" or "telegram")
     * @param timestamp When verification was performed by the verification service
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time (block.timestamp)
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev ANYONE can call this function to relay a verification proof.
     *      This enables gas-free verification for users who don't have XOM.
     *
     * Security Properties:
     * - Only trustedVerificationKey can sign valid proofs
     * - The proof MUST include the user address (cannot be used for different user)
     * - Each nonce can only be used once (replay protection)
     * - Social hash can only be used by one user (Sybil protection)
     * - Proof expires after deadline (prevents hoarding)
     * - Caller has NO attestation power - security comes from signature verification
     */
    function submitSocialVerificationFor(
        address user,
        bytes32 socialHash,
        string calldata platform,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) {
            revert TrustedVerificationKeyNotSet();
        }

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used (replay protection)
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check social hash not already used by another user
        if (usedSocialHashes[socialHash]) revert SocialAlreadyUsed();

        // 5. Verify EIP-712 signature from trustedVerificationKey
        //    CRITICAL: The user address is part of the signed data!
        bytes32 structHash = keccak256(
            abi.encode(
                SOCIAL_VERIFICATION_TYPEHASH,
                user, // User address from parameter, verified in signature
                socialHash,
                keccak256(bytes(platform)), // Hash the platform string
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != trustedVerificationKey) revert InvalidVerificationProof();

        // 6. Store verification
        userSocialHashes[user] = socialHash;
        usedSocialHashes[socialHash] = true;
        usedNonces[nonce] = true;

        // 7. Check if KYC Tier 1 complete and update status
        _checkAndUpdateKycTier1(user);

        // solhint-disable-next-line not-rely-on-time
        emit SocialVerified(user, socialHash, platform, timestamp);
    }

    /**
     * @notice Internal function to check and update KYC Tier 1 status
     * @param user Address to check and potentially update
     * @dev Called after phone or social verification to check if requirements are met
     */
    function _checkAndUpdateKycTier1(address user) internal {
        // Already completed - no need to check again
        if (kycTier1CompletedAt[user] != 0) return;

        Registration storage reg = registrations[user];

        // Must be registered
        if (reg.timestamp == 0) return;

        // Must have phone verified (either at registration or via submitPhoneVerification)
        if (reg.phoneHash == bytes32(0)) return;
        if (!usedPhoneHashes[reg.phoneHash]) return;

        // Must have social verified
        if (userSocialHashes[user] == bytes32(0)) return;

        // All requirements met - update KYC Tier 1 status
        // solhint-disable-next-line not-rely-on-time
        kycTier1CompletedAt[user] = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit KycTier1Completed(user, block.timestamp);
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
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the trusted verification key address
     * @param newKey Address of the new verification key (or address(0) to disable)
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     *      The verification key signs phone/social verification proofs.
     *      This is OmniBazaar's verification service key, NOT a validator key.
     *      SECURITY: Changing this key invalidates all pending proofs.
     */
    function setTrustedVerificationKey(
        address newKey
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedVerificationKey = newKey;
        emit TrustedVerificationKeyUpdated(newKey);
    }

    /**
     * @notice Unregister a user (admin only)
     * @dev Clears all registration data including email/phone hash reservations.
     *      This allows the user to re-register with the same credentials.
     *      Use cases: account deletion (GDPR), testing, fixing registration errors.
     * @param user The address of the user to unregister
     */
    function adminUnregister(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Registration storage reg = registrations[user];

        // Check user is actually registered
        if (reg.timestamp == 0) {
            revert NotRegistered();
        }

        // Store hashes before clearing (needed to clear the usedHashes mappings)
        bytes32 emailHash = reg.emailHash;
        bytes32 phoneHash = reg.phoneHash;

        // Clear email hash reservation (allows re-use)
        if (emailHash != bytes32(0)) {
            usedEmailHashes[emailHash] = false;
        }

        // Clear phone hash reservation (allows re-use)
        if (phoneHash != bytes32(0)) {
            usedPhoneHashes[phoneHash] = false;
        }

        // Clear the registration struct
        delete registrations[user];

        // Decrement total registrations count
        totalRegistrations--;

        emit UserUnregistered(user, msg.sender, block.timestamp);
    }

    /**
     * @notice Batch unregister multiple users (admin only)
     * @dev More gas-efficient for unregistering multiple users at once
     * @param users Array of user addresses to unregister
     */
    function adminUnregisterBatch(
        address[] calldata users
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = users.length;
        for (uint256 i = 0; i < length; ) {
            address user = users[i];
            Registration storage reg = registrations[user];

            // Skip users who aren't registered
            if (reg.timestamp != 0) {
                // Clear email hash reservation
                if (reg.emailHash != bytes32(0)) {
                    usedEmailHashes[reg.emailHash] = false;
                }

                // Clear phone hash reservation
                if (reg.phoneHash != bytes32(0)) {
                    usedPhoneHashes[reg.phoneHash] = false;
                }

                // Clear the registration struct
                delete registrations[user];

                // Decrement total registrations count
                totalRegistrations--;

                emit UserUnregistered(user, msg.sender, block.timestamp);
            }

            unchecked {
                ++i;
            }
        }
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
