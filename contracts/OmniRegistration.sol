// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

    /// @notice Role for contracts/services authorized to mark bonuses as claimed
    bytes32 public constant BONUS_MARKER_ROLE = keccak256("BONUS_MARKER_ROLE");

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
    // solhint-disable-next-line max-line-length
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
    //                    KYC TIER 2/3/4 STORAGE (Added v2)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice EIP-712 typehash for ID verification proof (KYC Tier 2)
    bytes32 public constant ID_VERIFICATION_TYPEHASH = keccak256(
        "IDVerification(address user,bytes32 idHash,string country,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for address verification proof (KYC Tier 2)
    /// @dev Verifies proof of residence via utility bill, bank statement, or tax document
    // solhint-disable-next-line max-line-length
    bytes32 public constant ADDRESS_VERIFICATION_TYPEHASH = keccak256(
        "AddressVerification(address user,bytes32 addressHash,string country,bytes32 documentType,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for selfie verification proof (KYC Tier 2)
    /// @dev Verifies face match between ID photo and selfie (not liveness detection)
    // solhint-disable-next-line max-line-length
    bytes32 public constant SELFIE_VERIFICATION_TYPEHASH = keccak256(
        "SelfieVerification(address user,bytes32 selfieHash,uint256 similarity,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for video verification proof (KYC Tier 3 - DEPRECATED)
    /// @dev DEPRECATED: Tier 3 now uses accredited investor verification, not video
    ///      Keeping for backwards compatibility during upgrade
    bytes32 public constant VIDEO_VERIFICATION_TYPEHASH = keccak256(
        "VideoVerification(address user,bytes32 sessionHash,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for third-party KYC attestation (KYC Tier 4)
    bytes32 public constant THIRD_PARTY_KYC_TYPEHASH = keccak256(
        "ThirdPartyKYC(address user,address provider,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice User ID hash (keccak256 of normalized ID data) for KYC Tier 2
    mapping(address => bytes32) public userIDHashes;

    /// @notice Used ID hashes (prevent reuse across users)
    mapping(bytes32 => bool) public usedIDHashes;

    /// @notice User country codes (ISO 3166-1 alpha-2)
    mapping(address => string) public userCountries;

    /// @notice User address hash (proof of residence) for KYC Tier 2
    /// @dev Format: keccak256("ADDRESS_LINE:CITY:POSTAL:COUNTRY:DOC_TYPE")
    ///      Privacy-preserving proof of address verification
    mapping(address => bytes32) public userAddressHashes;

    /// @notice Used address hashes (prevent reuse across users)
    mapping(bytes32 => bool) public usedAddressHashes;

    /// @notice Selfie verification status (face match to ID photo)
    /// @dev Simple boolean - proves same person as ID, not anti-spoofing
    mapping(address => bool) public selfieVerified;

    /// @notice KYC Tier 2 completion timestamp
    mapping(address => uint256) public kycTier2CompletedAt;

    /// @notice Video verification session hashes for KYC Tier 3
    mapping(address => bytes32) public videoSessionHashes;

    /// @notice KYC Tier 3 completion timestamp
    mapping(address => uint256) public kycTier3CompletedAt;

    /// @notice Trusted third-party KYC provider addresses
    mapping(address => bool) public trustedKYCProviders;

    /// @notice Provider names for transparency
    mapping(address => string) public kycProviderNames;

    /// @notice KYC Tier 4 completion timestamp
    mapping(address => uint256) public kycTier4CompletedAt;

    /// @notice Which provider verified each user for Tier 4
    mapping(address => address) public userKYCProvider;

    /// @notice Referral count per user (how many users they referred)
    mapping(address => uint256) public referralCounts;

    /// @notice Whether a user has completed their first marketplace sale
    /// @dev Set by TRANSACTION_RECORDER_ROLE when a sale is finalized.
    ///      Used by OmniRewardManager to gate first sale bonus claims.
    mapping(address => bool) public firstSaleCompleted;

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
    //                    KYC TIER 2/3/4 EVENTS (Added v2)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when ID is verified (KYC Tier 2)
     * @param user The user who verified their ID
     * @param idHash Keccak256 hash of normalized ID data
     * @param country ISO 3166-1 alpha-2 country code
     * @param timestamp When verification was performed
     */
    event IDVerified(
        address indexed user,
        bytes32 indexed idHash,
        string country,
        uint256 timestamp
    );

    /**
     * @notice Emitted when KYC Tier 2 is completed
     * @param user The user who completed KYC Tier 2
     * @param timestamp Block timestamp when completed
     */
    event KycTier2Completed(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when video verification is completed (KYC Tier 3)
     * @param user The user who completed video verification
     * @param sessionHash Keccak256 hash of video session ID
     * @param timestamp When verification was performed
     */
    event VideoVerified(
        address indexed user,
        bytes32 indexed sessionHash,
        uint256 timestamp
    );

    /**
     * @notice Emitted when KYC Tier 3 is completed
     * @param user The user who completed KYC Tier 3
     * @param timestamp Block timestamp when completed
     */
    event KycTier3Completed(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when a KYC provider is added
     * @param provider Provider contract address
     * @param name Provider name
     */
    event KYCProviderAdded(address indexed provider, string name);

    /**
     * @notice Emitted when a KYC provider is removed
     * @param provider Provider address that was removed
     */
    event KYCProviderRemoved(address indexed provider);

    /**
     * @notice Emitted when KYC Tier 4 is completed (third-party KYC)
     * @param user The user who completed KYC Tier 4
     * @param provider The KYC provider who verified the user
     * @param timestamp Block timestamp when completed
     */
    event KycTier4Completed(
        address indexed user,
        address indexed provider,
        uint256 timestamp
    );

    /// @notice Emitted when transaction is recorded for volume tracking
    /// @param user User address
    /// @param amount Transaction amount in USD (18 decimals)
    /// @param dailyVolume Updated daily volume
    /// @param monthlyVolume Updated monthly volume
    /// @param annualVolume Updated annual volume
    event TransactionRecorded(
        address indexed user,
        uint256 amount,
        uint256 dailyVolume,
        uint256 monthlyVolume,
        uint256 annualVolume
    );

    /// @notice Emitted when admin updates tier limits
    /// @param tier Tier number (0-4)
    /// @param newLimits New limit configuration
    event TierLimitsUpdated(
        uint8 indexed tier,
        TierLimits newLimits
    );

    /// @notice Emitted when address verification is submitted
    /// @param user User address
    /// @param addressHash Hash of verified address
    /// @param country Country code
    /// @param documentType Type of address document
    /// @param timestamp Verification timestamp
    event AddressVerified(
        address indexed user,
        bytes32 indexed addressHash,
        string country,
        bytes32 documentType,
        uint256 timestamp
    );

    /// @notice Emitted when selfie verification is submitted
    /// @param user User address
    /// @param selfieHash Hash of selfie image
    /// @param similarity Face match similarity score (0-100)
    /// @param timestamp Verification timestamp
    event SelfieVerified(
        address indexed user,
        bytes32 indexed selfieHash,
        uint256 similarity,
        uint256 timestamp
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

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

    /// @notice ID hash has already been used by another user
    error IDAlreadyUsed();

    /// @notice KYC provider is not in the trusted list
    error UntrustedKYCProvider();

    /// @notice KYC provider signature is invalid
    error InvalidKYCProviderSignature();

    /// @notice User must complete previous KYC tier first
    error PreviousTierRequired();

    /// @notice Invalid provider address (zero address)
    error InvalidProvider();

    /// @notice Selfie similarity score below minimum threshold (85%)
    error InsufficientSimilarity();

    /// @notice KYC Tier 1 required before this action
    error KYCTier1Required();

    /// @notice Caller not authorized to record transactions
    error UnauthorizedTransactionRecorder();

    /// @notice Invalid tier number (must be 0-4)
    error InvalidTier();

    /// @notice Tier 2 KYC required before proceeding
    error KYCTier2Required();

    /// @notice Address hash has already been used
    error AddressAlreadyUsed();

    /// @notice ID verification required before this action
    error IDVerificationRequired();

    /// @notice Invalid verifier signature
    error InvalidVerifierSignature();

    /// @notice Address is zero
    error ZeroAddress();

    /// @notice Thrown when batch operation exceeds the maximum allowed size
    error BatchTooLarge();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

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

        // Initialize transaction limits for all tiers
        _initializeTierLimits();
    }

    /**
     * @notice Reinitialize the contract to set DOMAIN_SEPARATOR for upgrades
     * @dev Can only be called once per version number
     * @param version The reinitializer version number
     */
    function reinitialize(uint64 version) public onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(version) {
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

        // Initialize transaction limits (new in v2)
        if (tierLimits[0].dailyLimit == 0) {
            _initializeTierLimits();
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
        if (user == address(0)) revert ZeroAddress(); // L-05: reject zero-address registration
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

        // Increment referrer's referral count if referrer exists
        if (referrer != address(0)) {
            ++referralCounts[referrer];
        }

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
        if (user == address(0)) revert ZeroAddress(); // L-05: reject zero-address registration
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();
        if (registrations[user].timestamp != 0) revert AlreadyRegistered();
        if (block.timestamp > emailDeadline) revert ProofExpired(); // solhint-disable-line not-rely-on-time
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > registrationDeadline) {
            revert AttestationExpired();
        }
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

        // M-02: Trustless registration sets kycTier to 0 (not 1).
        // Users must complete phone + social verification to earn Tier 1.
        // This prevents Sybil attackers from getting KYC Tier 1 with only email.
        registrations[user] = Registration({ // solhint-disable-line not-rely-on-time
            timestamp: block.timestamp,
            referrer: referrer,
            registeredBy: msg.sender,
            phoneHash: bytes32(0),
            emailHash: emailHash,
            kycTier: 0,
            welcomeBonusClaimed: false,
            firstSaleBonusClaimed: false
        });

        // Mark email and nonce as used
        usedEmailHashes[emailHash] = true;
        userEmailHashes[user] = emailHash;
        usedNonces[emailNonce] = true;

        // Update counters
        ++dailyRegistrationCount[today];
        ++totalRegistrations;

        // Increment referrer's referral count if referrer exists
        if (referrer != address(0)) {
            ++referralCounts[referrer];
        }

        // solhint-disable-next-line not-rely-on-time
        emit UserRegisteredTrustless(user, referrer, block.timestamp);
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

            // M-01: Synchronize kycTierXCompletedAt timestamps with attestation upgrades
            // This prevents dual-tracking inconsistencies between Registration.kycTier
            // and the per-tier completion timestamps used by getUserKYCTier().
            // solhint-disable-next-line not-rely-on-time
            if (tier == 2 && kycTier2CompletedAt[user] == 0) {
                kycTier2CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
            } else if (tier == 3 && kycTier3CompletedAt[user] == 0) {
                kycTier3CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
            } else if (tier == 4 && kycTier4CompletedAt[user] == 0) {
                kycTier4CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
            }

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
     * @dev Called after phone or social verification to check if requirements are met.
     *      H-01 fix: Also synchronizes Registration.kycTier so that
     *      canClaimWelcomeBonus() returns correct results for trustless-path users.
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

        // H-01: Synchronize Registration.kycTier for canClaimWelcomeBonus()
        // This ensures trustless-path users who complete KYC Tier 1 via
        // submitPhoneVerification + submitSocialVerification get their
        // Registration.kycTier updated (previously remained at 0).
        if (reg.kycTier < 1) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 1;
            emit KYCUpgraded(user, oldTier, 1);
        }

        // solhint-disable-next-line not-rely-on-time
        emit KycTier1Completed(user, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    KYC TIER 2/3/4 VERIFICATION (Added v2)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit ID verification proof (KYC Tier 2)
     * @param idHash Keccak256 of (ID_TYPE:ID_NUMBER:DOB:COUNTRY)
     * @param country ISO 3166-1 alpha-2 country code (e.g., "US", "GB")
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev Requires KYC Tier 1 to be complete first.
     *      ID hash format: keccak256("PASSPORT:AB123456:1990-01-01:US")
     */
    function submitIDVerification(
        bytes32 idHash,
        string calldata country,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check ID hash not already used
        if (usedIDHashes[idHash]) revert IDAlreadyUsed();

        // 5. Check user has KYC Tier 1
        if (kycTier1CompletedAt[msg.sender] == 0) revert PreviousTierRequired();

        // 6. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                ID_VERIFICATION_TYPEHASH,
                msg.sender,
                idHash,
                keccak256(bytes(country)),
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

        // 7. Store verification
        userIDHashes[msg.sender] = idHash;
        usedIDHashes[idHash] = true;
        userCountries[msg.sender] = country;
        usedNonces[nonce] = true;

        // 8. Check if KYC Tier 2 complete (ID + Address + Selfie all required)
        _checkAndUpdateKycTier2(msg.sender);

        // solhint-disable-next-line not-rely-on-time
        emit IDVerified(msg.sender, idHash, country, timestamp);
    }

    /**
     * @notice Submit ID verification for another user (relay pattern)
     * @param user Address of the user being verified
     * @param idHash Keccak256 of (ID_TYPE:ID_NUMBER:DOB:COUNTRY)
     * @param country ISO 3166-1 alpha-2 country code
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev ANYONE can relay. User address is verified in signature.
     */
    function submitIDVerificationFor(
        address user,
        bytes32 idHash,
        string calldata country,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check ID hash not already used
        if (usedIDHashes[idHash]) revert IDAlreadyUsed();

        // 5. Check user has KYC Tier 1
        if (kycTier1CompletedAt[user] == 0) revert PreviousTierRequired();

        // 6. Verify EIP-712 signature (user address is part of signed data)
        bytes32 structHash = keccak256(
            abi.encode(
                ID_VERIFICATION_TYPEHASH,
                user,
                idHash,
                keccak256(bytes(country)),
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

        // 7. Store verification
        userIDHashes[user] = idHash;
        usedIDHashes[idHash] = true;
        userCountries[user] = country;
        usedNonces[nonce] = true;

        // 8. Check if KYC Tier 2 complete (ID + Address + Selfie all required)
        _checkAndUpdateKycTier2(user);

        // solhint-disable-next-line not-rely-on-time
        emit IDVerified(user, idHash, country, timestamp);
    }

    /**
     * @notice Submit address verification proof (KYC Tier 2 - Required)
     * @param addressHash Keccak256 of (ADDRESS:CITY:POSTAL:COUNTRY:DOC_TYPE)
     * @param country ISO 3166-1 alpha-2 country code
     * @param documentType Type of address document ("utility", "bank", "tax")
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     *
     * @dev Requires KYC Tier 1 complete. Address document must be within 3 months.
     *      Completes Tier 2 when combined with ID verification and selfie.
     */
    function submitAddressVerification(
        bytes32 addressHash,
        string calldata country,
        bytes32 documentType,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check address hash not already used
        if (usedAddressHashes[addressHash]) revert AddressAlreadyUsed();

        // 5. Check user has KYC Tier 1
        if (kycTier1CompletedAt[msg.sender] == 0) revert PreviousTierRequired();

        // 6. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                ADDRESS_VERIFICATION_TYPEHASH,
                msg.sender,
                addressHash,
                keccak256(bytes(country)),
                documentType,
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

        // 7. Store verification
        userAddressHashes[msg.sender] = addressHash;
        usedAddressHashes[addressHash] = true;
        usedNonces[nonce] = true;

        // 8. Check if KYC Tier 2 complete (ID + Address + Selfie all required)
        _checkAndUpdateKycTier2(msg.sender);

        // solhint-disable-next-line not-rely-on-time
        emit AddressVerified(msg.sender, addressHash, country, documentType, timestamp);
    }

    /**
     * @notice Submit selfie verification proof (KYC Tier 2 - Required)
     * @param selfieHash Keccak256 of selfie image data
     * @param similarity Face match similarity score (0-100, must be 85+)
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     *
     * @dev Requires ID verification already submitted. Automated face matching
     *      verifies same person as ID photo (not liveness detection).
     *      Completes Tier 2 when combined with ID and address verification.
     */
    function submitSelfieVerification(
        bytes32 selfieHash,
        uint256 similarity,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check ID verification already submitted
        if (userIDHashes[msg.sender] == bytes32(0)) revert IDVerificationRequired();

        // 5. Verify similarity score meets threshold (85% minimum)
        if (similarity < 85) revert InsufficientSimilarity();

        // 6. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                SELFIE_VERIFICATION_TYPEHASH,
                msg.sender,
                selfieHash,
                similarity,
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

        // 7. Mark selfie verified
        selfieVerified[msg.sender] = true;
        usedNonces[nonce] = true;

        // 8. Check if KYC Tier 2 complete (ID + Address + Selfie all required)
        _checkAndUpdateKycTier2(msg.sender);

        // solhint-disable-next-line not-rely-on-time
        emit SelfieVerified(msg.sender, selfieHash, similarity, timestamp);
    }

    /**
     * @notice Submit video verification proof (KYC Tier 3)
     * @param sessionHash Keccak256 of video session ID
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev Requires KYC Tier 2 to be complete first.
     *      Video session proves liveness and ID match.
     */
    function submitVideoVerification(
        bytes32 sessionHash,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check user has KYC Tier 2
        if (kycTier2CompletedAt[msg.sender] == 0) revert PreviousTierRequired();

        // 5. Verify EIP-712 signature from trustedVerificationKey
        bytes32 structHash = keccak256(
            abi.encode(
                VIDEO_VERIFICATION_TYPEHASH,
                msg.sender,
                sessionHash,
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
        videoSessionHashes[msg.sender] = sessionHash;
        usedNonces[nonce] = true;

        // 7. Mark KYC Tier 3 complete
        // solhint-disable-next-line not-rely-on-time
        kycTier3CompletedAt[msg.sender] = block.timestamp;

        // H-01: Synchronize Registration.kycTier
        Registration storage reg = registrations[msg.sender];
        if (reg.kycTier < 3) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 3;
            emit KYCUpgraded(msg.sender, oldTier, 3);
        }

        // solhint-disable-next-line not-rely-on-time
        emit VideoVerified(msg.sender, sessionHash, timestamp);
        // solhint-disable-next-line not-rely-on-time
        emit KycTier3Completed(msg.sender, block.timestamp);
    }

    /**
     * @notice Submit video verification for another user (relay pattern)
     * @param user Address of the user being verified
     * @param sessionHash Keccak256 of video session ID
     * @param timestamp When verification was performed
     * @param nonce Unique nonce for replay protection
     * @param deadline Proof expiration time
     * @param signature EIP-712 signature from trustedVerificationKey
     * @dev ANYONE can relay. User address is verified in signature.
     */
    function submitVideoVerificationFor(
        address user,
        bytes32 sessionHash,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check trusted verification key is set
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check user has KYC Tier 2
        if (kycTier2CompletedAt[user] == 0) revert PreviousTierRequired();

        // 5. Verify EIP-712 signature (user address is part of signed data)
        bytes32 structHash = keccak256(
            abi.encode(
                VIDEO_VERIFICATION_TYPEHASH,
                user,
                sessionHash,
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
        videoSessionHashes[user] = sessionHash;
        usedNonces[nonce] = true;

        // 7. Mark KYC Tier 3 complete
        // solhint-disable-next-line not-rely-on-time
        kycTier3CompletedAt[user] = block.timestamp;

        // H-01: Synchronize Registration.kycTier
        Registration storage reg = registrations[user];
        if (reg.kycTier < 3) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 3;
            emit KYCUpgraded(user, oldTier, 3);
        }

        // solhint-disable-next-line not-rely-on-time
        emit VideoVerified(user, sessionHash, timestamp);
        // solhint-disable-next-line not-rely-on-time
        emit KycTier3Completed(user, block.timestamp);
    }

    /**
     * @notice Submit third-party KYC completion proof (KYC Tier 4)
     * @param kycProvider Address of trusted KYC provider
     * @param timestamp When KYC was completed
     * @param nonce Replay protection
     * @param deadline Proof expiration
     * @param signature EIP-712 signature from KYC provider
     * @dev KYC provider must be in trustedKYCProviders.
     *      Provider attests user passed their verification.
     */
    function submitThirdPartyKYC(
        address kycProvider,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check provider is trusted
        if (!trustedKYCProviders[kycProvider]) revert UntrustedKYCProvider();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check user has KYC Tier 3
        if (kycTier3CompletedAt[msg.sender] == 0) revert PreviousTierRequired();

        // 5. Verify signature from KYC provider
        bytes32 structHash = keccak256(
            abi.encode(
                THIRD_PARTY_KYC_TYPEHASH,
                msg.sender,
                kycProvider,
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != kycProvider) revert InvalidKYCProviderSignature();

        // 6. Mark complete
        usedNonces[nonce] = true;
        // solhint-disable-next-line not-rely-on-time
        kycTier4CompletedAt[msg.sender] = block.timestamp;
        userKYCProvider[msg.sender] = kycProvider;

        // H-01: Synchronize Registration.kycTier
        Registration storage reg = registrations[msg.sender];
        if (reg.kycTier < 4) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 4;
            emit KYCUpgraded(msg.sender, oldTier, 4);
        }

        // solhint-disable-next-line not-rely-on-time
        emit KycTier4Completed(msg.sender, kycProvider, block.timestamp);
    }

    /**
     * @notice Submit third-party KYC for another user (relay pattern)
     * @param user Address of the user being verified
     * @param kycProvider Address of trusted KYC provider
     * @param timestamp When KYC was completed
     * @param nonce Replay protection
     * @param deadline Proof expiration
     * @param signature EIP-712 signature from KYC provider
     * @dev ANYONE can relay. User address is verified in signature.
     */
    function submitThirdPartyKYCFor(
        address user,
        address kycProvider,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Check provider is trusted
        if (!trustedKYCProviders[kycProvider]) revert UntrustedKYCProvider();

        // 2. Check deadline not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert ProofExpired();

        // 3. Check nonce not already used
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        // 4. Check user has KYC Tier 3
        if (kycTier3CompletedAt[user] == 0) revert PreviousTierRequired();

        // 5. Verify signature from KYC provider (user is part of signed data)
        bytes32 structHash = keccak256(
            abi.encode(
                THIRD_PARTY_KYC_TYPEHASH,
                user,
                kycProvider,
                timestamp,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        if (signer != kycProvider) revert InvalidKYCProviderSignature();

        // 6. Mark complete
        usedNonces[nonce] = true;
        // solhint-disable-next-line not-rely-on-time
        kycTier4CompletedAt[user] = block.timestamp;
        userKYCProvider[user] = kycProvider;

        // H-01: Synchronize Registration.kycTier
        Registration storage reg = registrations[user];
        if (reg.kycTier < 4) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 4;
            emit KYCUpgraded(user, oldTier, 4);
        }

        // solhint-disable-next-line not-rely-on-time
        emit KycTier4Completed(user, kycProvider, block.timestamp);
    }

    /**
     * @notice Check if user has completed KYC Tier 2
     * @param user Address to check
     * @return True if Tier 2 complete (ID verification)
     */
    function hasKycTier2(address user) external view returns (bool) {
        return kycTier2CompletedAt[user] != 0;
    }

    /**
     * @notice Check if user has completed KYC Tier 3
     * @param user Address to check
     * @return True if Tier 3 complete (video verification)
     */
    function hasKycTier3(address user) external view returns (bool) {
        return kycTier3CompletedAt[user] != 0;
    }

    /**
     * @notice Check if user has completed KYC Tier 4
     * @param user Address to check
     * @return True if Tier 4 complete (third-party KYC)
     */
    function hasKycTier4(address user) external view returns (bool) {
        return kycTier4CompletedAt[user] != 0;
    }

    /**
     * @notice Get the number of users referred by a user
     * @param user Address to check
     * @return Number of referrals
     */
    function getReferralCount(address user) external view returns (uint256) {
        return referralCounts[user];
    }

    /**
     * @notice Add trusted KYC provider (admin only)
     * @param provider Provider contract address
     * @param name Provider name for transparency
     */
    function addKYCProvider(
        address provider,
        string calldata name
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidProvider();
        trustedKYCProviders[provider] = true;
        kycProviderNames[provider] = name;
        emit KYCProviderAdded(provider, name);
    }

    /**
     * @notice Remove KYC provider (admin only)
     * @param provider Provider address to remove
     */
    function removeKYCProvider(
        address provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedKYCProviders[provider] = false;
        emit KYCProviderRemoved(provider);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        BONUS CLAIM MARKING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Mark welcome bonus as claimed for a user
     * @param user The user who claimed the bonus
     * @dev Only callable by addresses with BONUS_MARKER_ROLE (e.g., OmniRewardManager)
     */
    function markWelcomeBonusClaimed(address user) external onlyRole(BONUS_MARKER_ROLE) {
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        if (reg.welcomeBonusClaimed) revert BonusAlreadyClaimed();

        reg.welcomeBonusClaimed = true;
        emit WelcomeBonusMarkedClaimed(user, block.timestamp);
    }

    /**
     * @notice Mark first sale bonus as claimed for a user
     * @param user The user who claimed the bonus
     * @dev Only callable by addresses with BONUS_MARKER_ROLE (e.g., OmniRewardManager)
     */
    function markFirstSaleBonusClaimed(address user) external onlyRole(BONUS_MARKER_ROLE) {
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        if (reg.firstSaleBonusClaimed) revert BonusAlreadyClaimed();

        reg.firstSaleBonusClaimed = true;
        // solhint-disable-next-line not-rely-on-time
        emit FirstSaleBonusMarkedClaimed(user, block.timestamp);
    }

    /**
     * @notice Mark a user as having completed their first marketplace sale
     * @dev Only callable by TRANSACTION_RECORDER_ROLE (marketplace/escrow contracts).
     *      This flag gates the first sale bonus in OmniRewardManager, ensuring
     *      that users cannot claim the bonus without actually completing a sale.
     * @param user The seller's address who completed the sale
     */
    function markFirstSaleCompleted(
        address user
    ) external onlyRole(TRANSACTION_RECORDER_ROLE) {
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        firstSaleCompleted[user] = true;
    }

    /**
     * @notice Check if a user has completed their first marketplace sale
     * @param user The user address to check
     * @return True if the user has completed at least one sale
     */
    function hasCompletedFirstSale(address user) external view returns (bool) {
        return firstSaleCompleted[user];
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
        if (newKey == address(0)) revert ZeroAddress();
        trustedVerificationKey = newKey;
        emit TrustedVerificationKeyUpdated(newKey);
    }

    /**
     * @notice Unregister a user (admin only)
     * @dev Clears ALL registration data including email/phone hash reservations,
     *      social/ID/address hash reservations, KYC tier timestamps, provider data,
     *      volume tracking, and referral counts. This ensures the user can
     *      cleanly re-register with the same credentials without ghost state.
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

        // Decrement referrer's referral count if applicable
        if (reg.referrer != address(0) && referralCounts[reg.referrer] > 0) {
            --referralCounts[reg.referrer];
        }

        // Clear email hash reservation (allows re-use)
        if (emailHash != bytes32(0)) {
            usedEmailHashes[emailHash] = false;
        }

        // Clear phone hash reservation (allows re-use)
        if (phoneHash != bytes32(0)) {
            usedPhoneHashes[phoneHash] = false;
        }

        // Clear social hash reservation (allows re-use)
        bytes32 socialHash = userSocialHashes[user];
        if (socialHash != bytes32(0)) {
            usedSocialHashes[socialHash] = false;
            delete userSocialHashes[user];
        }

        // Clear separate email hash mapping
        delete userEmailHashes[user];

        // Clear ID hash reservation (allows re-use of government ID)
        bytes32 idHash = userIDHashes[user];
        if (idHash != bytes32(0)) {
            usedIDHashes[idHash] = false;
            delete userIDHashes[user];
        }

        // Clear address hash reservation (allows re-use of address docs)
        bytes32 addrHash = userAddressHashes[user];
        if (addrHash != bytes32(0)) {
            usedAddressHashes[addrHash] = false;
            delete userAddressHashes[user];
        }

        // Clear selfie and video verification
        delete selfieVerified[user];
        delete videoSessionHashes[user];

        // Clear all KYC tier completion timestamps
        delete kycTier1CompletedAt[user];
        delete kycTier2CompletedAt[user];
        delete kycTier3CompletedAt[user];
        delete kycTier4CompletedAt[user];

        // Clear KYC provider and country data
        delete userKYCProvider[user];
        delete userCountries[user];

        // Clear volume tracking
        delete userVolumes[user];

        // M-01: Clear firstSaleCompleted to prevent stale bonus state
        // on re-registration. Without this, a re-registered user could
        // claim the first sale bonus without completing a new sale.
        delete firstSaleCompleted[user];

        // Clear the registration struct
        delete registrations[user];

        // Decrement total registrations count
        --totalRegistrations;

        // solhint-disable-next-line not-rely-on-time
        emit UserUnregistered(user, msg.sender, block.timestamp);
    }

    /**
     * @notice Batch unregister multiple users (admin only)
     * @dev Performs complete state cleanup for each user, clearing all
     *      registration data, KYC tier timestamps, hash reservations,
     *      volume tracking, and referral counts. Capped at 100 users
     *      per batch to prevent exceeding block gas limits.
     * @param users Array of user addresses to unregister (max 100)
     */
    function adminUnregisterBatch(
        address[] calldata users
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = users.length;
        if (length > 100) revert BatchTooLarge();

        for (uint256 i = 0; i < length; ) {
            address user = users[i];
            Registration storage reg = registrations[user];

            // Skip users who aren't registered
            if (reg.timestamp != 0) {
                // Decrement referrer's referral count
                if (reg.referrer != address(0) && referralCounts[reg.referrer] > 0) {
                    --referralCounts[reg.referrer];
                }

                // Clear email hash reservation
                if (reg.emailHash != bytes32(0)) {
                    usedEmailHashes[reg.emailHash] = false;
                }

                // Clear phone hash reservation
                if (reg.phoneHash != bytes32(0)) {
                    usedPhoneHashes[reg.phoneHash] = false;
                }

                // Clear social hash reservation
                bytes32 socialHash = userSocialHashes[user];
                if (socialHash != bytes32(0)) {
                    usedSocialHashes[socialHash] = false;
                    delete userSocialHashes[user];
                }

                // Clear separate email hash mapping
                delete userEmailHashes[user];

                // Clear ID hash reservation
                bytes32 idHash = userIDHashes[user];
                if (idHash != bytes32(0)) {
                    usedIDHashes[idHash] = false;
                    delete userIDHashes[user];
                }

                // Clear address hash reservation
                bytes32 addrHash = userAddressHashes[user];
                if (addrHash != bytes32(0)) {
                    usedAddressHashes[addrHash] = false;
                    delete userAddressHashes[user];
                }

                // Clear selfie, video, KYC timestamps, provider, country
                delete selfieVerified[user];
                delete videoSessionHashes[user];
                delete kycTier1CompletedAt[user];
                delete kycTier2CompletedAt[user];
                delete kycTier3CompletedAt[user];
                delete kycTier4CompletedAt[user];
                delete userKYCProvider[user];
                delete userCountries[user];
                delete userVolumes[user];

                // M-01: Clear firstSaleCompleted to prevent stale bonus state
                delete firstSaleCompleted[user];

                // Clear the registration struct
                delete registrations[user];

                // L-04: Use prefix decrement for gas efficiency
                --totalRegistrations;

                // solhint-disable-next-line not-rely-on-time
                emit UserUnregistered(user, msg.sender, block.timestamp);
            }

            unchecked {
                ++i;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRANSACTION LIMITS & VOLUME TRACKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice USD unit with 18 decimals (matches XOM token decimals)
    /// @dev All transaction limits denominated in USD with same precision as XOM
    ///      Example: $500 = 500 * USD = 500000000000000000000
    uint256 private constant USD = 10**18;

    /// @notice Transaction limit configuration per KYC tier
    /// @dev Limits prevent fraud and ensure regulatory compliance
    struct TierLimits {
        uint256 dailyLimit;          // Daily transaction limit in USD (18 decimals)
        uint256 monthlyLimit;        // Monthly transaction limit in USD (18 decimals)
        uint256 annualLimit;         // Annual transaction limit in USD (0 = unlimited)
        uint256 perTransactionLimit; // Maximum single transaction in USD
        uint16 maxListings;          // Maximum concurrent marketplace listings (0 = unlimited)
        uint256 maxListingPrice;     // Maximum price per listing in USD (0 = unlimited)
    }

    /// @notice Tier limit configuration (admin configurable)
    /// @dev Mapping: tier number (0-4) => TierLimits struct
    mapping(uint8 => TierLimits) public tierLimits;

    /// @notice User transaction volume tracking for limit enforcement
    /// @dev Volumes reset automatically based on time period
    struct VolumeTracking {
        uint256 dailyVolume;         // Current day's transaction volume in USD
        uint256 monthlyVolume;       // Current month's transaction volume in USD
        uint256 annualVolume;        // Current year's transaction volume in USD
        uint256 lastTransactionDay;  // Day number (timestamp / 86400) for daily reset
        uint256 lastTransactionMonth; // Month number for monthly reset
        uint256 lastTransactionYear;  // Year number for annual reset
    }

    /// @notice Volume tracking per user address
    mapping(address => VolumeTracking) public userVolumes;

    /// @notice Role for contracts authorized to record transactions
    /// @dev Marketplace and DEX contracts need this role to call recordTransaction()
    bytes32 public constant TRANSACTION_RECORDER_ROLE = keccak256("TRANSACTION_RECORDER_ROLE");

    /**
     * @notice Check if transaction is within user's KYC tier limits
     * @param user Address to check
     * @param amount Transaction amount in USD (18 decimals)
     * @return allowed True if transaction is within limits
     * @return reason Error message if not allowed (empty string if allowed)
     *
     * @dev M-03: This is a VIEW function intended for off-chain pre-checks
     *      via eth_call. It does NOT modify state or enforce limits.
     *      Callers should use this to show users their remaining capacity
     *      before submitting transactions. The actual on-chain enforcement
     *      happens in recordTransaction(), which uses custom errors
     *      (TransactionLimitExceeded) instead of string returns.
     *
     *      Return pattern:
     *      - (true, "") = transaction is allowed
     *      - (false, "reason string") = transaction would exceed a limit
     *
     *      The reason strings are human-readable for UX purposes:
     *      - "Transaction exceeds per-transaction limit for your KYC tier"
     *      - "Transaction would exceed daily limit for your KYC tier"
     *      - "Transaction would exceed monthly limit for your KYC tier"
     *      - "Transaction would exceed annual limit for your KYC tier"
     */
    function checkTransactionLimit(
        address user,
        uint256 amount
    ) external view returns (bool allowed, string memory reason) {
        uint8 tier = getUserKYCTier(user);
        TierLimits memory limits = tierLimits[tier];
        VolumeTracking memory volume = userVolumes[user];

        uint256 today = block.timestamp / 86400;
        uint256 thisMonth = block.timestamp / (30 * 86400);
        uint256 thisYear = block.timestamp / (365 * 86400);

        // Check per-transaction limit
        if (limits.perTransactionLimit > 0 && amount > limits.perTransactionLimit) {
            return (false, "Transaction exceeds per-transaction limit for your KYC tier");
        }

        // Check daily limit
        uint256 dailyVol = (volume.lastTransactionDay == today) ? volume.dailyVolume : 0;
        if (limits.dailyLimit > 0 && dailyVol + amount > limits.dailyLimit) {
            return (false, "Transaction would exceed daily limit for your KYC tier");
        }

        // Check monthly limit
        uint256 monthlyVol = (volume.lastTransactionMonth == thisMonth) ? volume.monthlyVolume : 0;
        if (limits.monthlyLimit > 0 && monthlyVol + amount > limits.monthlyLimit) {
            return (false, "Transaction would exceed monthly limit for your KYC tier");
        }

        // Check annual limit
        uint256 annualVol = (volume.lastTransactionYear == thisYear) ? volume.annualVolume : 0;
        if (limits.annualLimit > 0 && annualVol + amount > limits.annualLimit) {
            return (false, "Transaction would exceed annual limit for your KYC tier");
        }

        return (true, "");
    }

    /**
     * @notice Record transaction for volume tracking
     * @param user Address of user making transaction
     * @param amount Transaction amount in USD (18 decimals)
     *
     * @dev Only callable by authorized contracts (marketplace, DEX, etc.)
     *      Updates daily, monthly, and annual volume counters
     *      Automatically resets counters when periods change
     */
    /// @notice Thrown when a transaction exceeds the user's KYC tier limit
    /// @param user User address
    /// @param limitType Which limit was exceeded (daily, monthly, annual, per-transaction)
    error TransactionLimitExceeded(address user, string limitType);

    /**
     * @notice Record transaction for volume tracking and enforce on-chain limits
     * @param user Address of user making transaction
     * @param amount Transaction amount in USD (18 decimals)
     *
     * @dev Only callable by authorized contracts (marketplace, DEX, etc.)
     *      Updates daily, monthly, and annual volume counters.
     *      Automatically resets counters when periods change.
     *      M-04: Now enforces tier limits on-chain (not just advisory).
     */
    function recordTransaction(address user, uint256 amount) external {
        if (!hasRole(TRANSACTION_RECORDER_ROLE, msg.sender)) {
            revert UnauthorizedTransactionRecorder();
        }

        // solhint-disable not-rely-on-time
        uint256 today = block.timestamp / 86400;
        uint256 thisMonth = block.timestamp / (30 * 86400);
        uint256 thisYear = block.timestamp / (365 * 86400);
        // solhint-enable not-rely-on-time

        VolumeTracking storage volume = userVolumes[user];

        // Reset counters if new period
        if (volume.lastTransactionDay != today) {
            volume.dailyVolume = 0;
            volume.lastTransactionDay = today;
        }
        if (volume.lastTransactionMonth != thisMonth) {
            volume.monthlyVolume = 0;
            volume.lastTransactionMonth = thisMonth;
        }
        if (volume.lastTransactionYear != thisYear) {
            volume.annualVolume = 0;
            volume.lastTransactionYear = thisYear;
        }

        // M-04: Enforce tier limits on-chain
        uint8 tier = getUserKYCTier(user);
        TierLimits memory limits = tierLimits[tier];

        if (limits.perTransactionLimit > 0 && amount > limits.perTransactionLimit) {
            revert TransactionLimitExceeded(user, "per-transaction");
        }
        if (limits.dailyLimit > 0 && volume.dailyVolume + amount > limits.dailyLimit) {
            revert TransactionLimitExceeded(user, "daily");
        }
        if (limits.monthlyLimit > 0 && volume.monthlyVolume + amount > limits.monthlyLimit) {
            revert TransactionLimitExceeded(user, "monthly");
        }
        if (limits.annualLimit > 0 && volume.annualVolume + amount > limits.annualLimit) {
            revert TransactionLimitExceeded(user, "annual");
        }

        // Add to volumes
        volume.dailyVolume += amount;
        volume.monthlyVolume += amount;
        volume.annualVolume += amount;

        emit TransactionRecorded(
            user, amount, volume.dailyVolume, volume.monthlyVolume, volume.annualVolume
        );
    }

    /**
     * @notice Get user's current KYC tier
     * @param user Address to check
     * @return tier Current KYC tier (0-4)
     *
     * @dev Checks tier completion timestamps in reverse order (highest first)
     *      Returns highest tier achieved that hasn't expired
     */
    function getUserKYCTier(address user) public view returns (uint8) {
        // Tier 4: Institutional or Enhanced KYC
        if (kycTier4CompletedAt[user] != 0) return 4;

        // Tier 3: Accredited Investor (check expiration)
        if (kycTier3CompletedAt[user] != 0) {
            // TODO: Add expiration check when accreditation system implemented
            return 3;
        }

        // Tier 2: Verified Identity (ID + Address)
        if (kycTier2CompletedAt[user] != 0) return 2;

        // Tier 1: Basic (Email + Phone + Social)
        if (kycTier1CompletedAt[user] != 0) return 1;

        // Tier 0: Anonymous
        return 0;
    }

    /**
     * @notice Admin updates tier limits configuration
     * @param tier Tier number (0-4)
     * @param newLimits New limit configuration for this tier
     *
     * @dev Only callable by admin, allows adjusting limits based on market conditions
     */
    function updateTierLimits(
        uint8 tier,
        TierLimits calldata newLimits
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier > 4) revert InvalidTier();
        tierLimits[tier] = newLimits;
        emit TierLimitsUpdated(tier, newLimits);
    }

    /**
     * @notice Initialize tier limits with default values
     * @dev Called during contract initialization, sets industry-standard limits
     */
    function _initializeTierLimits() internal {
        // Tier 0: Anonymous - Minimal access for browsing
        tierLimits[0] = TierLimits({
            dailyLimit: 500 * USD,           // $500 daily
            monthlyLimit: 5000 * USD,        // $5,000 monthly
            annualLimit: 25000 * USD,        // $25,000 annual
            perTransactionLimit: 100 * USD,  // $100 per transaction
            maxListings: 3,
            maxListingPrice: 100 * USD       // $100 max item price
        });

        // Tier 1: Basic (Email + Phone + Social) - Active marketplace user
        tierLimits[1] = TierLimits({
            dailyLimit: 5000 * USD,          // $5,000 daily
            monthlyLimit: 50000 * USD,       // $50,000 monthly
            annualLimit: 250000 * USD,       // $250,000 annual
            perTransactionLimit: 2000 * USD, // $2,000 per transaction
            maxListings: 25,
            maxListingPrice: 2000 * USD      // $2,000 max item price
        });

        // Tier 2: Verified Identity (ID + Address) - Public RWA access
        tierLimits[2] = TierLimits({
            dailyLimit: 25000 * USD,         // $25,000 daily
            monthlyLimit: 250000 * USD,      // $250,000 monthly
            annualLimit: 0,                   // Unlimited annual
            perTransactionLimit: 25000 * USD, // $25,000 per transaction
            maxListings: 250,
            maxListingPrice: 25000 * USD     // $25,000 max item price
        });

        // Tier 3: Accredited Investor - Private RWA access
        tierLimits[3] = TierLimits({
            dailyLimit: 100000 * USD,        // $100,000 daily
            monthlyLimit: 1000000 * USD,     // $1,000,000 monthly
            annualLimit: 0,                   // Unlimited annual
            perTransactionLimit: 100000 * USD, // $100,000 per transaction
            maxListings: 0,                   // Unlimited listings
            maxListingPrice: 0                // Unlimited item price
        });

        // Tier 4: Institutional/Validator - Full access
        tierLimits[4] = TierLimits({
            dailyLimit: 0,                    // Unlimited daily
            monthlyLimit: 0,                  // Unlimited monthly
            annualLimit: 0,                   // Unlimited annual
            perTransactionLimit: 0,           // Unlimited per transaction
            maxListings: 0,                   // Unlimited listings
            maxListingPrice: 0                // Unlimited item price
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check and update KYC Tier 2 status if all requirements met
     * @param user Address to check
     * @dev Tier 2 requires THREE verifications:
     *      1. ID verification (userIDHashes[user] != 0)
     *      2. Address verification (userAddressHashes[user] != 0)
     *      3. Selfie verification (selfieVerified[user] == true)
     *      Only marks Tier 2 complete when ALL three are present.
     *      H-01 fix: Also synchronizes Registration.kycTier so that
     *      canClaimWelcomeBonus() and other checks reading Registration.kycTier
     *      return correct results for trustless-path users.
     */
    function _checkAndUpdateKycTier2(address user) internal {
        // Must have Tier 1 first
        if (kycTier1CompletedAt[user] == 0) return;

        // Must have all three Tier 2 verifications
        if (userIDHashes[user] == bytes32(0)) return;         // No ID
        if (userAddressHashes[user] == bytes32(0)) return;    // No address
        if (!selfieVerified[user]) return;                     // No selfie

        // All requirements met - mark Tier 2 complete (only if not already complete)
        if (kycTier2CompletedAt[user] == 0) {
            // solhint-disable-next-line not-rely-on-time
            kycTier2CompletedAt[user] = block.timestamp;

            // H-01: Synchronize Registration.kycTier
            Registration storage reg = registrations[user];
            if (reg.kycTier < 2) {
                uint8 oldTier = reg.kycTier;
                reg.kycTier = 2;
                emit KYCUpgraded(user, oldTier, 2);
            }

            // solhint-disable-next-line not-rely-on-time
            emit KycTier2Completed(user, block.timestamp);
        }
    }

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin. Once ossified, the contract can never
     *      be upgraded again. IMPORTANT: The admin role MUST be behind a
     *      TimelockController before calling this function in production.
     *      Accidental ossification permanently prevents bug fixes.
     *
     *      Upgrade Validation Process (M-02):
     *      Before ANY production upgrade, run OpenZeppelin validateUpgrade()
     *      from hardhat-upgrades to verify storage layout compatibility:
     *      require('openzeppelin/hardhat-upgrades').validateUpgrade(V1, V2)
     *      This ensures new state variables consume gap slots correctly and
     *      do not corrupt existing storage. The storage gap is sized at 49
     *      (50 - 1 for _ossified) to provide room for future additions.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Reverts if contract is ossified.
     *      The newImplementation parameter is required by the UUPS interface
     *      but is not used in authorization logic.
     *
     *      L-02: The admin role should be held by a TimelockController before
     *      production deployment. This ensures upgrade proposals have a delay
     *      period (e.g., 7 days) for community review before execution.
     *
     *      Relationship between on-chain KYC and off-chain KYC service (L-04):
     *      On-chain: Registration.kycTier and kycTierXCompletedAt timestamps
     *      track KYC progression. Off-chain: The OmniBazaar verification service
     *      performs actual identity checks (phone, email, social, ID, selfie,
     *      video) and signs EIP-712 proofs that users submit on-chain. The
     *      trustedVerificationKey bridges these two systems.
     * @param newImplementation Address of new implementation
     *        (unused -- required by UUPSUpgradeable interface)
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /**
     * @dev Reserved storage gap for future upgrades.
     *      Ensures that adding new state variables in upgraded versions
     *      does not corrupt existing storage layout. Standard UUPS pattern
     *      used by all other OmniBazaar upgradeable contracts.
     *      Reduced from 50 to 49 to accommodate _ossified.
     */
    uint256[49] private __gap;
}
