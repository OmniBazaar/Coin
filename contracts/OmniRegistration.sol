// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OmniRegistrationDigestLib} from "./registration/OmniRegistrationDigestLib.sol";
import {
    IBridgeVerifier,
    IOmniAttestationGateway
} from "./registration/OmniRegistrationInterfaces.sol";

/**
 * @notice Minimum surface this contract needs from the live
 *         {OmniRegistrationKYCTiers} proxy: a one-shot sweep that clears
 *         all Tier-2/3/4 per-user state on KYCTiers when Base unregisters
 *         a user, and a Tier-3 reset that clears Persona/AML/Tier-3+ state
 *         when Base downgrades a user on sanctions hit. Implemented on
 *         KYCTiers, gated by `msg.sender == baseRegistration` so only this
 *         contract can invoke them. See {OmniRegistrationKYCTiers.purgeUserState}.
 * @dev    FIX_OMNIREGISTRATION_SPLIT audit H-02 / H-03 remediation. Without
 *         these callbacks, `_unregisterUser` and `resetKycTier3` would clear
 *         only Base's dead local slots, leaving KYCTiers state stranded —
 *         creating both an ID-hash permaban griefing vector and a
 *         sanctions-bypass surface (KYCTiers continues to report the user
 *         as Tier 3 / Tier 4 after the reset).
 */
interface IOmniRegistrationKYCTiersSweep {
    function purgeUserState(address user) external;
    function purgeTier3State(address user) external;
}

/**
 * @notice Minimal view interface into LegacyBalanceClaim so username binding
 *         can honor pre-launch legacy fund-routing reservations. Both
 *         contracts hash `keccak256(bytes(username))` over the same all-
 *         lowercase legacy corpus, so the `usernameHash` domains align.
 */
interface ILegacyBalanceClaim {
    /// @notice True for every legacy fund-routing username reserved on-chain.
    function reserved(bytes32 usernameHash) external view returns (bool);
    /// @notice The address that has claimed a legacy username, or zero.
    function claimedBy(bytes32 usernameHash) external view returns (address);
}

/**
 * @notice Gateway interface — all attestation verification logic moved into
 *         `OmniAttestationGateway` post-2026-05-18 audit. The gateway owns
 *         the dual-path (legacy single-key + Phase 2 M-of-N), the nonce
 *         map, Pausable, and all audit-recommended guards (subject
 *         exclusion, pool-size gate, version whitelist, etc.). The
 *         interface OmniRegistration consumes is hoisted to
 *         `./registration/OmniRegistrationInterfaces.sol` so the
 *         OMNICORE-DECENT library can share the type without forcing the
 *         heavy bridge-package compile graph.
 */

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
 *
 * @dev AUDIT ACCEPTED (Round 6): Off-chain verification (phone, email, social media,
 *      device fingerprinting, IP rate limiting) is enforced by the Validator node
 *      network, not on-chain. On-chain contracts verify EIP-712 signed attestations
 *      from trusted verification keys. This hybrid approach provides Sybil resistance
 *      without storing PII on-chain. The VALIDATOR_ROLE and KYC_ATTESTOR_ROLE
 *      provide the on-chain trust boundary.
 */
contract OmniRegistration is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable
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

    /// @notice Role held by OmniRegistrationKYCTiers proxy so it can call
    ///         {bumpKycTier} when Tier-2/3/4 promotions complete.
    /// @dev Post-split (FIX_OMNIREGISTRATION_SPLIT). Granted via
    ///      `grantRole` after KYCTiers proxy deploys.
    bytes32 public constant KYCTIERS_ROLE = keccak256("KYCTIERS_ROLE");

    /// @dev REMOVED: BONUS_MARKER_ROLE replaced by omniRewardManagerAddress
    ///      (state variable declared in storage gap section below)

    /// @notice Maximum registrations per day (rate limiting)
    uint256 public constant MAX_DAILY_REGISTRATIONS = 10000;

    /// @notice Number of validator attestations required for KYC upgrade
    uint256 public constant KYC_ATTESTATION_THRESHOLD = 3;


    /// @notice Registration deposit amount (0 for now - gas-free registration)
    /// @dev Can be increased if Sybil attacks become problematic
    uint256 public constant REGISTRATION_DEPOSIT = 0;

    /// @notice Minimum sale amount required for first sale bonus eligibility (100 XOM)
    /// @dev SYBIL-H05: Prevents wash trading with trivial amounts to claim first sale bonus
    uint256 public constant MIN_FIRST_SALE_AMOUNT = 100 * 10 ** 18;

    /// @notice Minimum time after registration before first sale qualifies (7 days)
    /// @dev SYBIL-H05: Cooling period prevents rapid sybil account creation + instant first sale
    uint256 public constant MIN_FIRST_SALE_AGE = 7 days;

    /// @notice EIP-712 typehash for phone verification proof
    /// @dev Used by submitPhoneVerification() for trustless phone verification.
    ///      OMNICORE-DECENT: `supersedes` references the canonical digest
    ///      of the prior phone attestation for the same user (or
    ///      `bytes32(0)` for the first attestation). Lets the supersedes-
    ///      chain check structurally reject single-attester equivocation.
    // solhint-disable-next-line max-line-length
    bytes32 public constant PHONE_VERIFICATION_TYPEHASH = keccak256(
        "PhoneVerification(address user,bytes32 phoneHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for social media verification proof
    /// @dev Used by submitSocialVerification() for trustless social verification.
    ///      OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant SOCIAL_VERIFICATION_TYPEHASH = keccak256(
        "SocialVerification(address user,bytes32 socialHash,string platform,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for email verification proof
    /// @dev Used during trustless registration. OMNICORE-DECENT: includes
    ///      `supersedes` (always `bytes32(0)` for the one-shot registration
    ///      path; the chain check trivially succeeds because there is no
    ///      prior canonical) so every attestation envelope has a uniform
    ///      shape.
    // solhint-disable-next-line max-line-length
    bytes32 public constant EMAIL_VERIFICATION_TYPEHASH = keccak256(
        "EmailVerification(address user,bytes32 emailHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for trustless registration request
    /// @dev Used by selfRegisterTrustless() for fully trustless user registration.
    ///      SYBIL-Q-10 (2026-05-23): added `deviceHash` so the same-device
    ///      referral self-deal — where one human installs the wallet twice
    ///      on the same device and refers themselves to harvest the 70%
    ///      referrer slice of the welcome bonus — is rejected at the
    ///      contract layer. The client wallet derives a stable opaque
    ///      `keccak256(platformId || hardwareFingerprint || installSalt)`
    ///      and folds it into the user signature; the contract reads
    ///      `userDeviceHash[referrer]` and reverts `SameDeviceReferral`
    ///      on collision. `bytes32(0)` is accepted for back-compat with
    ///      pre-upgrade registrations whose deviceHash is unknown — the
    ///      check requires a non-zero collision to fire.
    bytes32 public constant TRUSTLESS_REGISTRATION_TYPEHASH = keccak256(
        "TrustlessRegistration(address user,address referrer,bytes32 deviceHash,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for trustless registration that ALSO binds a
    ///         username->address record in the SAME user signature (one action).
    /// @dev `usernameHash` is keccak256(bytes(lowercased username)). Because the
    ///      user signs over it, the username->address binding is user-authored —
    ///      no deployer or validator key has any authority over it. Used by
    ///      {selfRegisterTrustlessForWithName}.
    bytes32 public constant TRUSTLESS_REGISTRATION_WITH_NAME_TYPEHASH = keccak256(
        "TrustlessRegistrationWithName(address user,address referrer,bytes32 deviceHash,bytes32 usernameHash,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for a STANDALONE user-signed username binding,
    ///         used by already-registered users to claim their name on-chain
    ///         (the trustless migration path — see {bindUsernameTrustless}).
    bytes32 public constant BIND_USERNAME_TYPEHASH = keccak256(
        "BindUsername(address user,bytes32 usernameHash,uint256 deadline)"
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
    /// @dev OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant ID_VERIFICATION_TYPEHASH = keccak256(
        "IDVerification(address user,bytes32 idHash,string country,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for address verification proof (KYC Tier 2)
    /// @dev Verifies proof of residence via utility bill, bank statement, or tax document.
    ///      OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant ADDRESS_VERIFICATION_TYPEHASH = keccak256(
        "AddressVerification(address user,bytes32 addressHash,string country,bytes32 documentType,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for selfie verification proof (KYC Tier 2)
    /// @dev Verifies face match between ID photo and selfie (not liveness detection).
    ///      OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant SELFIE_VERIFICATION_TYPEHASH = keccak256(
        "SelfieVerification(address user,bytes32 selfieHash,uint256 similarity,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for Persona identity verification (KYC Tier 3)
    /// @dev Used by submitPersonaVerification() for Persona-based identity verification.
    ///      OMNICORE-DECENT: includes `supersedes` for the chain check
    ///      (Persona retry: failed→passed extends the chain).
    // solhint-disable-next-line max-line-length
    bytes32 public constant PERSONA_VERIFICATION_TYPEHASH = keccak256(
        "PersonaVerification(address user,bytes32 verificationHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for accredited investor self-certification
    /// @dev Used by submitAccreditedInvestorCertification() for SEC 501(a) attestation.
    ///      OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant ACCREDITED_INVESTOR_TYPEHASH = keccak256(
        "AccreditedInvestorCertification(address user,uint8 criteria,bool certified,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for AML/PEP screening clearance
    /// @dev Used by submitAMLClearance() for sanctions screening attestation.
    ///      OMNICORE-DECENT: includes `supersedes` so cleared→not cleared→
    ///      cleared flips chain legitimately and equivocation attempts are
    ///      structurally rejected.
    // solhint-disable-next-line max-line-length
    bytes32 public constant AML_CLEARANCE_TYPEHASH = keccak256(
        "AMLClearance(address user,bool cleared,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for third-party KYC attestation (KYC Tier 4)
    /// @dev OMNICORE-DECENT: includes `supersedes` for the chain check.
    // solhint-disable-next-line max-line-length
    bytes32 public constant THIRD_PARTY_KYC_TYPEHASH = keccak256(
        "ThirdPartyKYC(address user,address provider,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
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
    //               PERSONA / AML / ACCREDITED INVESTOR STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Persona verification hash per user (keccak256 of inquiry ID + result)
    /// @dev Non-zero value indicates Persona identity verification completed
    mapping(address => bytes32) public personaVerificationHashes;

    /// @notice Whether user has self-certified as accredited investor
    mapping(address => bool) public isAccreditedInvestor;

    /// @notice SEC Rule 501(a) criteria bitmask for accredited investor
    /// @dev Bit 0: net worth > $1M, Bit 1: individual income > $200K,
    ///      Bit 2: joint income > $300K, Bit 3: Series 7/65/82 license,
    ///      Bit 4: knowledgeable employee of fund
    mapping(address => uint8) public accreditedInvestorCriteria;

    /// @notice Timestamp when accredited investor certification was submitted
    mapping(address => uint256) public accreditedInvestorCertifiedAt;

    /// @notice Whether user has passed AML/PEP screening
    mapping(address => bool) public amlCleared;

    /// @notice Timestamp when AML clearance was last updated
    mapping(address => uint256) public amlClearedAt;

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

    /// @notice Emitted whenever a non-zero deviceHash is recorded for a user.
    /// @dev SYBIL-Q-10: lets the off-chain Sybil index reconstruct the
    ///      `device → users` mapping without scanning every registration.
    /// @param user       Address whose deviceHash was recorded.
    /// @param deviceHash The recorded hash (always non-zero — zero is silently skipped).
    event DeviceHashRecorded(
        address indexed user,
        bytes32 indexed deviceHash
    );

    /// @notice Emitted when admin resets a user's KYC Tier 3 (e.g., sanctions hit)
    /// @param user The user whose Tier 3 was revoked
    /// @param admin The admin who performed the reset
    /// @param timestamp Block timestamp of reset
    event KycTier3Reset(
        address indexed user,
        address indexed admin,
        uint256 timestamp
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when ossification is requested (starts delay)
    /// @param requestedAt Timestamp when ossification was requested
    event OssificationRequested(uint256 indexed requestedAt);

    /// @notice Emitted when ossification is executed after delay
    /// @param executedAt Timestamp when ossification was executed
    event OssificationExecuted(uint256 indexed executedAt);

    /// @notice Emitted when a pending ossification request is cancelled
    /// @param cancelledBy Admin who cancelled the request
    event OssificationCancelled(address indexed cancelledBy);

    /// @notice Emitted when {setAttestationGateway} (re)points OmniRegistration
    ///         at an attestation gateway. `address(0)` = pipeline disabled.
    /// @param newGateway The new gateway address (or `address(0)` to disable).
    event AttestationGatewaySet(address indexed newGateway);

    /// @notice Emitted when {setKycTiersContract} (re)points this contract at
    ///         a live KYCTiers proxy. `address(0)` clears the binding.
    /// @param newKycTiers Address of the new KYCTiers proxy, or `address(0)`.
    event KycTiersContractSet(address indexed newKycTiers);

    /// @notice Emitted when a user binds their username->address record via a
    ///         user-signed trustless registration.
    /// @param user The address that now owns the username.
    /// @param usernameHash keccak256(bytes(lowercased username)).
    event UsernameBound(address indexed user, bytes32 indexed usernameHash);

    /// @notice Emitted when the admin seeds reserved username hashes.
    /// @param count Number of hashes marked reserved in the call.
    event ReservedUsernamesSeeded(uint256 count);

    /// @notice Emitted when the LegacyBalanceClaim reference is (re)wired.
    /// @param legacyBalanceClaim The new LegacyBalanceClaim address (0 = off).
    event LegacyBalanceClaimSet(address indexed legacyBalanceClaim);

    /// @notice Emitted when the admin releases reserved username hashes.
    /// @param count Number of hashes cleared from the reserved set in the call.
    event ReservedUsernamesReleased(uint256 count);

    /// @notice Emitted when an attestation submission is rejected because
    ///         the submitted payload MATCHES the canonical payload — i.e.,
    ///         two relayers raced and the loser is reporting the same fact.
    /// @dev OMNICORE-DECENT. This is HONEST behavior, not misbehavior.
    ///      The loser should retry with the corrected `supersedes` value
    ///      and the same proof bytes; the validator-side observer pipeline
    ///      handles this automatically.
    /// @param user                    Subject of the attestation.
    /// @param typehash                EIP-712 typehash discriminator.
    /// @param attemptedDigest         Digest of the losing submission.
    /// @param currentCanonicalDigest  Digest that already held the chain head.
    event AttestationRaceLost(
        address indexed user,
        bytes32 indexed typehash,
        bytes32 attemptedDigest,
        bytes32 currentCanonicalDigest
    );

    /// @notice Emitted when an attestation submission is rejected with a
    ///         DIFFERENT payload than the canonical — i.e., the attester
    ///         signed an envelope claiming a different fact under the same
    ///         supersedes parent.
    /// @dev OMNICORE-DECENT. UNAMBIGUOUS equivocation attempt. Validator-
    ///      side `EquivocationWatcher` subscribes to this event, captures
    ///      the rejected proof bytes from the tx input, pairs them with
    ///      the canonical attestation's proof bytes, and submits
    ///      `recordEquivocation` to attribute and increment the per-
    ///      attester misbehavior counter.
    event AttestationEquivocationAttempt(
        address indexed user,
        bytes32 indexed typehash,
        bytes32 attemptedDigest,
        bytes32 attemptedPayloadHash,
        bytes32 currentCanonicalDigest,
        bytes32 currentCanonicalPayloadHash
    );

    /// @notice Emitted by {recordEquivocation} for each attester attributed
    ///         to the equivocation. Drives BOTH the per-epoch reward
    ///         zeroing (off-chain) AND the rolling-30-day eligibility
    ///         exclusion (on-chain via `_requireEligibleAttesters`).
    /// @param attester  Attester whose misbehavior counter was incremented.
    /// @param subject   Subject the conflicting envelopes targeted.
    /// @param typehash  EIP-712 typehash discriminator of the conflicting envelopes.
    /// @param timestamp Block timestamp the attribution was recorded.
    event MisbehaviorRecorded(
        address indexed attester,
        address indexed subject,
        bytes32 indexed typehash,
        uint64 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice User is already registered
    error AlreadyRegistered();

    /// @notice Phone number hash has already been used
    error PhoneAlreadyUsed();

    /// @notice User already has a verified phone number (M-03)
    error PhoneAlreadyVerified();

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

    /// @notice User already has a verified social account (M-02)
    error SocialAlreadyVerified();

    /// @notice Verification proof signature is invalid (not from trusted key)
    error InvalidVerificationProof();

    /// @notice Nonce has already been used (replay attack prevention)
    error NonceAlreadyUsed();

    /// @notice Trusted verification key not set
    error TrustedVerificationKeyNotSet();

    /// @notice Attestation gateway address unset — `setAttestationGateway`
    ///         must be called by DEFAULT_ADMIN_ROLE before any
    ///         registration / KYC submission can succeed. Post-Phase-2-audit
    ///         refactor: the gateway is the single trust surface for all
    ///         attestation verification.
    error AttestationGatewayNotSet();

    /// @notice Audit Pass-2 L-NEW-Biz: `setTrustedVerificationKey` cannot
    ///         be called once `attestationGateway` is wired — the local
    ///         legacy key is dead after Phase 2 cutover.
    error LegacyTrustedKeyRetired();

    /// @notice Audit Pass-2 M-NEW-4: a new gateway being wired into
    ///         OmniRegistration must already have `authorizedConsumers
    ///         [address(this)] = true`, otherwise every subsequent
    ///         `_verifyAttestation` call would revert and brick the
    ///         registration pipeline.
    error GatewayNotConfiguredForConsumer(address consumer);

    /// @notice Email verification required for trustless registration
    error EmailNotVerified();

    /// @notice Invalid user signature on registration request
    error InvalidUserSignature();

    /// @notice User must complete previous KYC tier first
    error PreviousTierRequired();

    /// @notice KYC Tier 1 required before this action
    error KYCTier1Required();

    /// @notice Caller not authorized to record transactions
    error UnauthorizedTransactionRecorder();

    /// @notice Address is zero
    error ZeroAddress();

    /// @notice Thrown when batch operation exceeds the maximum allowed size
    error BatchTooLarge();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when ossification has not been requested
    error OssificationNotRequested();

    /// @notice Thrown when ossification delay has not elapsed
    error OssificationDelayNotMet();

    /// @notice Thrown when ossification has already been requested
    error OssificationAlreadyRequested();

    /// @notice Thrown when first sale doesn't meet minimum requirements
    /// @dev SYBIL-H05: Sale amount too low, account too new, or shared referrer detected
    error FirstSaleRequirementsNotMet();

    /// @notice Referrer has not completed KYC Tier 1 (email + phone + social)
    /// @dev SYBIL-H02: Prevents Tier 0 accounts from acting as referrers
    error ReferrerKycRequired();

    /// @notice New registration's deviceHash collides with referrer's deviceHash
    /// @dev SYBIL-Q-10: Same-device referral self-deal. Reverts when a
    ///      registration's submitted deviceHash equals the referrer's
    ///      recorded `userDeviceHash[referrer]`. Allowed when either
    ///      side is `bytes32(0)` (back-compat).
    error SameDeviceReferral();

    /// @notice `attestKYC` deprecated post-split.
    /// @dev OMNICORE-DECENT 2026-05-24 / FIX_OMNIREGISTRATION_SPLIT.
    error LegacyAttestKYCRetired();

    /// @notice `registerUser` deprecated — use the trustless path
    ///         (`selfRegisterTrustless` / `selfRegisterTrustlessFor`).
    /// @dev Red-team finding: VALIDATOR_ROLE could register arbitrary users
    ///      without any attestation. The trustless path enforces email
    ///      verification via the attestation gateway.
    error LegacyRegisterUserRetired();

    /// @notice Typehash is owned by OmniRegistrationKYCTiers; call it there instead.
    error UnsupportedTypehash(bytes32 typehash);

    /// @notice Caller is not the bound {kycTiersContract}.
    /// @dev Audit L-01 remediation. When `kycTiersContract` is set, the only
    ///      caller allowed through {bumpKycTier} is that exact address; the
    ///      KYCTIERS_ROLE check stays in place as defense-in-depth.
    error CallerNotBoundKYCTiers();

    /// @notice Address argument must be a deployed contract.
    /// @dev Audit M-02 remediation — mirrors OmniCore's GOV-XSYS-15 hardening
    ///      on the three KYCTiers-side setters.
    error RecipientMustBeContract();

    // ─── OMNICORE-DECENT supersedes chain + auto-eligibility errors ────────

    /// @notice Submitted `supersedes` reference doesn't match the canonical
    ///         head for the `(user, typehash)` tuple.
    /// @dev Race condition (`AttestationRaceLost` event fires) OR
    ///      equivocation attempt (`AttestationEquivocationAttempt` event
    ///      fires) — discriminated by the event emitted right before the
    ///      revert. Honest relayer behavior: observe `AttestationRaceLost`
    ///      and retry with the corrected `supersedes` value.
    /// @param expected  Canonical digest currently held by the contract.
    /// @param submitted Value the attester signed for `supersedes`.
    error InvalidSupersedes(bytes32 expected, bytes32 submitted);

    /// @notice {recordEquivocation}'s claimed shared `supersedes` parent
    ///         was never a real canonical digest — caller is trying to
    ///         fabricate evidence against an attester. Rejected.
    /// @param claimedSupersedes The non-zero value the recorder claimed.
    error NotHistoricalCanonical(bytes32 claimedSupersedes);

    /// @notice {recordEquivocation}'s first-attestation case (`sharedSupersedes
    ///         == bytes32(0)`) — but the legitimate first attestation has
    ///         already landed on-chain. Whatever the two envelopes are,
    ///         this is honest racing, not equivocation. NO attribution.
    error FirstAttestationRaceImmune();

    /// @notice {recordEquivocation}'s two envelope payloads are identical —
    ///         not equivocation. Submitter is either confused or testing.
    error PayloadHashesIdentical();

    /// @notice One or both proofs handed to {recordEquivocation} failed the
    ///         direct verifier check. No attribution; could be malformed
    ///         input OR the verifier was swapped between sign and submit.
    error ProofVerificationFailed();

    /// @notice The two committees attached to the conflicting envelopes
    ///         share NO attester. Different committees signing different
    ///         facts is NOT equivocation — only a SINGLE attester signing
    ///         both sides is.
    error NoCommonAttester();

    /// @notice An attestation cannot be accepted because at least one of
    ///         the attesters has reached the `MISBEHAVIOR_EXCLUSION_THRESHOLD`
    ///         inside the trailing `MISBEHAVIOR_EXCLUSION_WINDOW`. The
    ///         attester is auto-excluded; submission must be re-formed
    ///         with a different committee.
    /// @param attester         The first ineligible attester encountered.
    /// @param misbehaviorCount Their current count within the window.
    error AttesterIneligible(address attester, uint256 misbehaviorCount);

    /// @notice {recordEquivocation} called a second time with the same
    ///         evidence pair (same envelopes, same shared parent).
    /// @dev OMNICORE-DECENT post-audit remediation (audit finding F-01 /
    ///      M-2 / F-6 — replay-amplified eligibility exclusion). v4
    ///      design originally accepted replay; the audit showed that a
    ///      single honest equivocation can be amplified into rolling
    ///      exclusion by any griefer for ~$0.005 / 30d. Dedup mapping
    ///      below makes each evidence pair attributable AT MOST ONCE.
    /// @param evidenceKey The canonical key derived from the two digests
    ///        and the supersedes parent.
    error EvidenceAlreadyRecorded(bytes32 evidenceKey);

    /// @notice The supplied username hash is the zero value (invalid input).
    error InvalidUsername();

    /// @notice The username is reserved (brand/system/blocklist) and cannot be bound.
    error UsernameReserved(bytes32 usernameHash);

    /// @notice The username is already bound to another address.
    error UsernameTaken(bytes32 usernameHash);

    /// @notice The user already owns a username (one username per account).
    error UserAlreadyHasUsername(address user);

    /// @notice The target account has not reached KYC Tier 4 (brand-claim gate).
    /// @param business The account that failed the Tier-4 requirement.
    error KycTier4Required(address business);

    /// @notice The username hash is not in the reserved set (brand-claim gate).
    /// @param usernameHash The hash that was expected to be reserved.
    error NotReserved(bytes32 usernameHash);

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
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
     * @param deviceHash SYBIL-Q-10 opaque device fingerprint. Pass
     *        `bytes32(0)` only when the off-chain pipeline cannot derive
     *        one (legacy migration paths). Non-zero values are matched
     *        against the referrer's recorded device hash and registration
     *        reverts `SameDeviceReferral` on collision.
     * @dev Requires VALIDATOR_ROLE. No deposit required.
     *
     * Security measures:
     * - Duplicate phone/email prevention (Sybil protection)
     * - Rate limiting (MAX_DAILY_REGISTRATIONS)
     * - Referrer validation (must be registered user)
     * - Self-dealing prevention (validator cannot be referrer)
     * - SYBIL-Q-10: device-hash referral collision rejected
     * - Additional off-chain protections: device fingerprinting, IP rate limiting, social media verification
     */
    function registerUser(
        address user,
        address referrer,
        bytes32 phoneHash,
        bytes32 emailHash,
        bytes32 deviceHash
    ) external pure {
        revert LegacyRegisterUserRetired();
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
        bytes32 deviceHash,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) external nonReentrant {
        address caller = _msgSender();
        bytes32 registrationStructHash = keccak256(abi.encode(
            TRUSTLESS_REGISTRATION_TYPEHASH,
            caller,
            referrer,
            deviceHash,
            registrationDeadline
        ));
        _selfRegisterTrustlessInternal(
            caller,
            emailHash,
            emailTimestamp,
            emailNonce,
            emailDeadline,
            emailSignature,
            referrer,
            deviceHash,
            registrationDeadline,
            registrationStructHash,
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
        bytes32 deviceHash,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) external nonReentrant {
        bytes32 registrationStructHash = keccak256(abi.encode(
            TRUSTLESS_REGISTRATION_TYPEHASH,
            user,
            referrer,
            deviceHash,
            registrationDeadline
        ));
        _selfRegisterTrustlessInternal(
            user,
            emailHash,
            emailTimestamp,
            emailNonce,
            emailDeadline,
            emailSignature,
            referrer,
            deviceHash,
            registrationDeadline,
            registrationStructHash,
            userSignature
        );
    }

    /**
     * @notice Trustless registration that ALSO binds the user's username->address
     *         record, authorised by a SINGLE user signature (one action).
     * @dev The user signs {TRUSTLESS_REGISTRATION_WITH_NAME_TYPEHASH} over
     *      (user, referrer, deviceHash, usernameHash, deadline). That one
     *      signature both registers the identity and authorises the name binding,
     *      so neither the deployer nor any validator has authority over the
     *      username->address record used for fund-routing resolution. ANYONE may
     *      relay this (gas-free for the user); the binding's authority is the
     *      signature, not the caller.
     *
     *      Anti-squat: the binding reverts if the username is reserved
     *      ({reservedUsername}) or already taken ({usernameOwner}), and a single
     *      account may own only one username ({registeredUsernameHash}). Exact-name
     *      uniqueness + the seeded reserved set are enforced here on-chain;
     *      homoglyph/look-alike blocking is the off-chain skeleton gate at signup
     *      (on-chain skeleton folding would be gas-prohibitive).
     * @param user Address being registered + bound to the username.
     * @param emailHash Keccak256 of normalized email address.
     * @param emailTimestamp When email verification was performed.
     * @param emailNonce Unique nonce for email proof replay protection.
     * @param emailDeadline Email proof expiration time.
     * @param emailSignature Attestation signature (committee or legacy key).
     * @param referrer Referrer address (address(0) for none).
     * @param deviceHash Device fingerprint hash (bytes32(0) if none).
     * @param usernameHash keccak256(bytes(lowercased username)) the user is binding.
     * @param registrationDeadline Registration request expiration time.
     * @param userSignature User's EIP-712 signature over the with-name typehash.
     */
    function selfRegisterTrustlessForWithName(
        address user,
        bytes32 emailHash,
        uint256 emailTimestamp,
        bytes32 emailNonce,
        uint256 emailDeadline,
        bytes calldata emailSignature,
        address referrer,
        bytes32 deviceHash,
        bytes32 usernameHash,
        uint256 registrationDeadline,
        bytes calldata userSignature
    ) external nonReentrant {
        bytes32 registrationStructHash = keccak256(abi.encode(
            TRUSTLESS_REGISTRATION_WITH_NAME_TYPEHASH,
            user,
            referrer,
            deviceHash,
            usernameHash,
            registrationDeadline
        ));
        _selfRegisterTrustlessInternal(
            user,
            emailHash,
            emailTimestamp,
            emailNonce,
            emailDeadline,
            emailSignature,
            referrer,
            deviceHash,
            registrationDeadline,
            registrationStructHash,
            userSignature
        );
        // Bind the name only after identity registration succeeds (same tx, so
        // either both land or both revert). Authorised by the same userSignature.
        _bindUsername(user, usernameHash);
    }

    /**
     * @notice Bind a username hash to a user, enforcing reserved + uniqueness.
     * @dev Authority is the caller's already-verified user signature (the with-name
     *      typehash covers `usernameHash`). One username per account.
     * @param user The owner address.
     * @param usernameHash keccak256(bytes(lowercased username)).
     */
    function _bindUsername(address user, bytes32 usernameHash) internal {
        if (usernameHash == bytes32(0)) revert InvalidUsername();
        if (reservedUsername[usernameHash]) revert UsernameReserved(usernameHash);
        // Honor LegacyBalanceClaim reservations: a legacy fund-routing name may
        // be bound ONLY by the address that already CLAIMED it. An unclaimed
        // reserved legacy name (claimedBy == 0) is blocked entirely, so a
        // squatter cannot hijack a legacy holder's on-chain name before they
        // migrate. Advisory when the reference is unset (address(0)).
        if (
            address(legacyBalanceClaim) != address(0) &&
            legacyBalanceClaim.reserved(usernameHash) &&
            legacyBalanceClaim.claimedBy(usernameHash) != user
        ) {
            revert UsernameReserved(usernameHash);
        }
        if (usernameOwner[usernameHash] != address(0)) revert UsernameTaken(usernameHash);
        if (registeredUsernameHash[user] != bytes32(0)) revert UserAlreadyHasUsername(user);
        usernameOwner[usernameHash] = user;
        registeredUsernameHash[user] = usernameHash;
        emit UsernameBound(user, usernameHash);
    }

    /**
     * @notice Mark username hashes as reserved (brands/system/blocklist/legacy),
     *         blocking anyone from binding them via {selfRegisterTrustlessForWithName}.
     * @dev Admin-gated protocol configuration (DEFAULT_ADMIN_ROLE = deployer during
     *      Pioneer, governance later) — NOT a per-user binding. Idempotent; seeding
     *      an already-reserved hash is a no-op. Legacy holders are reserved
     *      on-chain separately in LegacyBalanceClaim and are enforced directly
     *      by {_bindUsername} once {setLegacyBalanceClaim} is wired — they need
     *      not be duplicated into this local set.
     * @param usernameHashes The keccak256(bytes(name)) values to reserve.
     */
    function seedReservedUsernames(bytes32[] calldata usernameHashes)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 len = usernameHashes.length;
        for (uint256 i = 0; i < len; ++i) {
            reservedUsername[usernameHashes[i]] = true;
        }
        emit ReservedUsernamesSeeded(len);
    }

    /**
     * @notice Wire the LegacyBalanceClaim contract so username binding honors
     *         legacy fund-routing reservations.
     * @dev Admin-gated (DEFAULT_ADMIN_ROLE = deployer during Pioneer, governance
     *      later). Until set, the legacy-reservation gate in {_bindUsername} is
     *      inert (address(0) sentinel). Setting to the live LegacyBalanceClaim
     *      blocks anyone but the claiming address from binding a reserved legacy
     *      name. Idempotent.
     * @param legacyBalanceClaim_ The LegacyBalanceClaim address (0 to disable).
     */
    function setLegacyBalanceClaim(address legacyBalanceClaim_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        legacyBalanceClaim = ILegacyBalanceClaim(legacyBalanceClaim_);
        emit LegacyBalanceClaimSet(legacyBalanceClaim_);
    }

    /**
     * @notice Release reserved username hashes, clearing their reserved flag.
     * @dev Admin-gated (DEFAULT_ADMIN_ROLE = deployer during Pioneer, governance
     *      later). Inverse of {seedReservedUsernames}: makes the names bindable
     *      again via the normal trustless path. Idempotent; releasing a hash that
     *      is not reserved is a no-op. Does NOT unbind any existing owner — it only
     *      clears the reserved flag. Use to retire a reservation seeded in error or
     *      a brand/blocklist entry that no longer needs protection.
     * @param usernameHashes The keccak256(bytes(name)) values to un-reserve.
     */
    function releaseReservedUsername(bytes32[] calldata usernameHashes)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 len = usernameHashes.length;
        for (uint256 i = 0; i < len; ++i) {
            reservedUsername[usernameHashes[i]] = false;
        }
        emit ReservedUsernamesReleased(len);
    }

    /**
     * @notice Bind a reserved username (e.g. a protected brand) to a Tier-4-verified
     *         account, bypassing the reserved check while preserving every other
     *         binding guard.
     * @dev Admin-gated (DEFAULT_ADMIN_ROLE = deployer during Pioneer, governance
     *      later) — the on-chain leg of the brand-claim flow. A business proves bona
     *      fides via Tier-4 KYC + off-chain ownership review, then ODDAO/admin binds
     *      the brand to their account. The reservation is intentionally LEFT IN PLACE
     *      so the brand stays protected against squatters after binding — only this
     *      admin path (gated on Tier 4 + uniqueness) can ever bind it.
     *
     *      Guards retained from {_bindUsername}: non-zero hash, name not already
     *      taken ({UsernameTaken}), account does not already own a name
     *      ({UserAlreadyHasUsername}). Added preconditions: the name must be in the
     *      reserved set ({NotReserved} — this path is strictly for reserved brands;
     *      non-reserved names bind via the normal owner-signed path), and the target
     *      must be a registered account ({NotRegistered}) at Tier 4
     *      ({KycTier4Required}). The
     *      Tier-4 check is a local SLOAD of the canonical
     *      `registrations[business].kycTier` (maintained by KYCTiers via
     *      `bumpKycTier`) — no cross-contract call.
     * @param business The Tier-4-verified account to receive the brand.
     * @param usernameHash keccak256(bytes(lowercased brand name)).
     */
    function bindReservedUsernameFor(address business, bytes32 usernameHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (usernameHash == bytes32(0)) revert InvalidUsername();
        // This is the brand-claim path: the name MUST be reserved. Non-reserved
        // names are bound by their owner through the normal trustless path.
        if (!reservedUsername[usernameHash]) revert NotReserved(usernameHash);
        if (registrations[business].timestamp == 0) revert NotRegistered();
        if (registrations[business].kycTier < 4) revert KycTier4Required(business);
        if (usernameOwner[usernameHash] != address(0)) revert UsernameTaken(usernameHash);
        if (registeredUsernameHash[business] != bytes32(0)) revert UserAlreadyHasUsername(business);
        usernameOwner[usernameHash] = business;
        registeredUsernameHash[business] = usernameHash;
        emit UsernameBound(business, usernameHash);
    }

    /**
     * @notice Resolve a username to its bound owner address (trustless, on-chain).
     * @param username The plaintext (already-lowercased) username.
     * @return owner The bound address, or address(0) if unbound.
     */
    function resolveUsername(string calldata username) external view returns (address owner) {
        return usernameOwner[keccak256(bytes(username))];
    }

    /**
     * @notice Bind a username to an ALREADY-REGISTERED user via a standalone user
     *         signature (the trustless, gasless migration path). New users bind in
     *         one shot via {selfRegisterTrustlessForWithName}; users who registered
     *         before that flow existed use this to claim their name on-chain.
     * @dev Authorised SOLELY by the user's EIP-712 signature over
     *      {BIND_USERNAME_TYPEHASH} — no deployer/validator/admin authority. ANYONE
     *      may relay (gas-free for the user). Replay-safe: a second call reverts in
     *      {_bindUsername} via {UserAlreadyHasUsername}. Anti-squat (reserved +
     *      taken + one-per-account) is enforced in {_bindUsername}.
     * @param user The registered address claiming the name.
     * @param usernameHash keccak256(bytes(lowercased username)).
     * @param deadline Signature expiry (unix seconds).
     * @param userSignature User's EIP-712 signature over the bind typehash.
     */
    function bindUsernameTrustless(
        address user,
        bytes32 usernameHash,
        uint256 deadline,
        bytes calldata userSignature
    ) external nonReentrant {
        if (registrations[user].timestamp == 0) revert NotRegistered();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert AttestationExpired();
        bytes32 structHash = keccak256(abi.encode(
            BIND_USERNAME_TYPEHASH, user, usernameHash, deadline
        ));
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        if (digest.recover(userSignature) != user) revert InvalidUserSignature();
        _bindUsername(user, usernameHash);
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
        bytes32 deviceHash,
        uint256 registrationDeadline,
        bytes32 registrationStructHash,
        bytes calldata userSignature
    ) internal {
        // Validate preconditions
        if (user == address(0)) revert ZeroAddress(); // L-05: reject zero-address registration
        if (registrations[user].timestamp != 0) revert AlreadyRegistered();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > registrationDeadline) {
            revert AttestationExpired();
        }
        if (usedEmailHashes[emailHash]) revert EmailAlreadyUsed();

        // OMNICORE-DECENT: EMAIL_VERIFICATION_TYPEHASH gained `supersedes`
        // for uniform envelope shape. Trustless registration is one-shot
        // per user (the `AlreadyRegistered` check above guarantees this is
        // always the first email attestation for `user`), so the off-chain
        // signer MUST sign with `supersedes = bytes32(0)` and the chain
        // check below is trivially satisfied.
        //
        // Verify email proof via the active attestation path (legacy single-
        // key OR Phase 2 M-of-N committee, gated by attestationGateway).
        // {_verifyAttestation} checks deadline + nonce-reuse + signature
        // recovery internally, then marks the nonce used.
        bytes32 emailStructHash = keccak256(abi.encode(
            EMAIL_VERIFICATION_TYPEHASH, user, emailHash,
            bytes32(0), emailTimestamp, emailNonce, emailDeadline
        ));
        bytes32 emailDigest = _hashTypedDataV4(emailStructHash);
        // Chain check: `currentCanonical[user][EMAIL] == 0` always holds
        // here because `AlreadyRegistered` would have reverted otherwise.
        _enforceSupersedesChain(
            user, EMAIL_VERIFICATION_TYPEHASH, emailDigest, emailHash, bytes32(0)
        );
        _requireEligibleAttesters(emailDigest, emailSignature);
        _verifyAttestation(
            user,
            emailStructHash,
            emailNonce,
            emailDeadline,
            emailSignature
        );
        _recordCanonical(user, EMAIL_VERIFICATION_TYPEHASH, emailDigest, emailHash);

        // Verify user signature on registration request. The struct hash is
        // supplied by the caller so this body serves BOTH the name-less typehash
        // (selfRegisterTrustless / selfRegisterTrustlessFor) and the with-name
        // typehash (selfRegisterTrustlessForWithName) without duplicating the
        // email-verification / referrer / rate-limit / store flow below.
        bytes32 registrationDigest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, registrationStructHash)
        );
        if (registrationDigest.recover(userSignature) != user) revert InvalidUserSignature();

        // Validate referrer
        if (referrer != address(0)) {
            if (referrer == user) revert SelfReferralNotAllowed();
            if (registrations[referrer].timestamp == 0) revert InvalidReferrer();

            // SYBIL-H02: Referrer must have completed KYC Tier 1
            if (kycTier1CompletedAt[referrer] == 0) revert ReferrerKycRequired();

            // SYBIL-Q-10: same-device referral self-deal. Reverts only
            // when both sides carry a non-zero hash (back-compat with
            // pre-upgrade referrers whose deviceHash was never recorded).
            if (
                deviceHash != bytes32(0)
                && userDeviceHash[referrer] == deviceHash
            ) {
                revert SameDeviceReferral();
            }
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

        // Mark email used. Audit Pass-2 H-NEW-2: the redundant
        // `usedNonces[emailNonce] = true` cross-write was removed — the
        // gateway already burned `emailNonce` inside `_verifyAttestation`
        // via `usedNonces` on the gateway. The local `usedNonces` map is
        // retained ONLY for the Tier-4 third-party KYC path
        // (`_verifyKYCProviderAttestation`), which does NOT route through
        // the gateway (it validates a `trustedKYCProviders[provider]`
        // signature instead). Mixing the nonce spaces here is dead code.
        usedEmailHashes[emailHash] = true;
        userEmailHashes[user] = emailHash;

        // SYBIL-Q-10: record device hash so future referrers see it.
        if (deviceHash != bytes32(0)) {
            userDeviceHash[user] = deviceHash;
            emit DeviceHashRecorded(user, deviceHash);
        }

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
     * @notice DEPRECATED: legacy multi-attestor KYC promotion path.
     * @dev OMNICORE-DECENT 2026-05-24 / FIX_OMNIREGISTRATION_SPLIT.
     *      Always reverts {LegacyAttestKYCRetired}. Canonical Tier-2/3/4
     *      promotions now flow through {OmniRegistrationKYCTiers}; Tier-1
     *      promotions flow through {submitPhoneVerificationFor} +
     *      {submitSocialVerificationFor} on this contract.
     */
    function attestKYC(
        address /* user */,
        uint8 /* tier */
    ) external pure {
        // OMNICORE-DECENT 2026-05-24 / SPLIT: legacy multi-attestor path
        // deprecated. Trustless attestation via `submit*Verification*` on
        // OmniRegistration (Tier 1) or `OmniRegistrationKYCTiers` (Tier 2/3/4)
        // is the canonical path. On-chain audit confirmed 0 mainnet calls
        // to `attestKYC` since launch (~430K blocks); deprecation breaks
        // nothing in production.
        revert LegacyAttestKYCRetired();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRUSTLESS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if user has completed KYC Tier 1
     * @param user Address to check
     * @return True if KYC Tier 1 is complete (registered + phone + social verified)
     * @dev KYC Tier 1 requires:
     *      1. User is registered (registrations[user].timestamp != 0)
     *      2. Phone is verified (usedPhoneHashes[reg.phoneHash] == true)
     *      3. Social is verified (userSocialHashes[user] != bytes32(0))
     */
    function hasKycTier1(address user) external view returns (bool) {
        return kycTier1CompletedAt[user] != 0;
    }

    /**
     * @notice Authorised callback for OmniRegistrationKYCTiers to bump
     *         this user's `kycTier` field after a Tier-2/3/4 promotion.
     * @dev Defense in depth: `onlyRole(KYCTIERS_ROLE)` AND, when
     *      `kycTiersContract` is non-zero, also requires
     *      `msg.sender == kycTiersContract` (audit L-01 — singleton binding;
     *      protects against an admin grant of KYCTIERS_ROLE to a second
     *      contract or EOA bypassing all attestation gates).
     *      Idempotent — already-equal or lower-tier values are a no-op so
     *      KYCTiers doesn't need to track local sequencing. Emits {KYCUpgraded}
     *      on actual bump.
     * @param user    Subject whose tier is being promoted.
     * @param newTier New tier value (must be 2, 3, or 4).
     */
    function bumpKycTier(
        address user,
        uint8 newTier
    ) external onlyRole(KYCTIERS_ROLE) {
        // Audit L-01: when bound, only the live KYCTiers proxy can call.
        address bound = kycTiersContract;
        if (bound != address(0) && msg.sender != bound) {
            revert CallerNotBoundKYCTiers();
        }
        if (registrations[user].timestamp == 0) revert NotRegistered();
        if (newTier < 2 || newTier > 4) revert InvalidKYCTier();
        Registration storage reg = registrations[user];
        if (newTier <= reg.kycTier) return;
        uint8 oldTier = reg.kycTier;
        reg.kycTier = newTier;
        emit KYCUpgraded(user, oldTier, newTier);
    }

    /**
     * @notice Bind this contract to the live KYCTiers proxy.
     * @dev Audit H-02 / H-03 / L-01 remediation. Setting `kycTiersContract`
     *      (a) enables cross-contract sweep from {_unregisterUser} and
     *      {resetKycTier3} so KYCTiers state is cleared alongside Base's,
     *      and (b) locks {bumpKycTier} to that exact caller so an
     *      accidentally over-granted `KYCTIERS_ROLE` cannot escalate.
     *
     *      `address(0)` is accepted as a deliberate clear path (e.g., during
     *      cutover staging) — when clear, both behaviours fall back to the
     *      pre-remediation semantics so the contract stays usable.
     *      Otherwise the new contract MUST be a deployed contract
     *      (`code.length > 0`), mirroring the OmniCore GOV-XSYS-15 setter
     *      hardening on the fee-recipient slots.
     * @param newKycTiers The OmniRegistrationKYCTiers proxy address, or `0`
     *        to disable the cross-contract sweep + binding.
     */
    function setKycTiersContract(
        address newKycTiers
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newKycTiers != address(0) && newKycTiers.code.length == 0) {
            revert RecipientMustBeContract();
        }
        kycTiersContract = newKycTiers;
        emit KycTiersContractSet(newKycTiers);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    RELAY FUNCTIONS (GAS-FREE FOR USERS)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Submit phone verification on behalf of a user (relay pattern)
    /// @dev ANYONE can relay. User address is verified in EIP-712 signature.
    ///      Validators call this to pay gas for users.
    /// @param user Address of the user being verified
    /// @param phoneHash Keccak256 of normalized phone number
    /// @param supersedes Prior canonical phone-attestation digest for `user`
    ///        (`bytes32(0)` for the first attestation). OMNICORE-DECENT
    ///        supersedes-chain check rejects mismatches.
    /// @param timestamp When verification was performed
    /// @param nonce Unique nonce for replay protection
    /// @param deadline Proof expiration time
    /// @param signature EIP-712 signature from trustedVerificationKey
    function submitPhoneVerificationFor(
        address user,
        bytes32 phoneHash,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _submitPhoneInternal(user, phoneHash, supersedes, timestamp, nonce, deadline, signature);
    }

    /// @notice Submit social verification on behalf of a user (relay pattern)
    /// @dev ANYONE can relay. User address is verified in EIP-712 signature.
    /// @param user Address of the user being verified
    /// @param socialHash Keccak256 of "platform:handle"
    /// @param platform Platform name ("twitter" or "telegram")
    /// @param supersedes Prior canonical social-attestation digest for `user`
    ///        (`bytes32(0)` for the first attestation).
    /// @param timestamp When verification was performed
    /// @param nonce Unique nonce for replay protection
    /// @param deadline Proof expiration time
    /// @param signature EIP-712 signature from trustedVerificationKey
    function submitSocialVerificationFor(
        address user,
        bytes32 socialHash,
        string calldata platform,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _submitSocialInternal(
            user, socialHash, platform, supersedes, timestamp, nonce, deadline, signature
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //           INTERNAL VERIFICATION IMPLEMENTATIONS (SHARED LOGIC)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Shared phone verification logic for both direct and relay paths
    function _submitPhoneInternal(
        address user,
        bytes32 phoneHash,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (registrations[user].timestamp == 0) revert NotRegistered();
        // M-03: Prevent re-verification if user already has a phone hash
        // (avoids permanently locking the new phoneHash in usedPhoneHashes)
        Registration storage reg = registrations[user];
        if (reg.phoneHash != bytes32(0)) revert PhoneAlreadyVerified();
        if (usedPhoneHashes[phoneHash]) revert PhoneAlreadyUsed();
        bytes32 structHash = keccak256(abi.encode(
            PHONE_VERIFICATION_TYPEHASH, user, phoneHash,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        // OMNICORE-DECENT: chain check first, eligibility second, gateway last.
        _enforceSupersedesChain(user, PHONE_VERIFICATION_TYPEHASH, digest, phoneHash, supersedes);
        _requireEligibleAttesters(digest, signature);
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        _recordCanonical(user, PHONE_VERIFICATION_TYPEHASH, digest, phoneHash);
        reg.phoneHash = phoneHash;
        usedPhoneHashes[phoneHash] = true;
        _checkAndUpdateKycTier1(user);
        // solhint-disable-next-line not-rely-on-time
        emit PhoneVerified(user, phoneHash, timestamp);
    }

    /// @dev Shared social verification logic for both direct and relay paths
    function _submitSocialInternal(
        address user,
        bytes32 socialHash,
        string calldata platform,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (registrations[user].timestamp == 0) revert NotRegistered();
        // M-02: Prevent re-verification if user already has a social hash
        // (avoids permanently locking the old socialHash in usedSocialHashes)
        if (userSocialHashes[user] != bytes32(0)) revert SocialAlreadyVerified();
        if (usedSocialHashes[socialHash]) revert SocialAlreadyUsed();
        bytes32 platformHash = keccak256(bytes(platform));
        bytes32 structHash = keccak256(abi.encode(
            SOCIAL_VERIFICATION_TYPEHASH, user, socialHash, platformHash,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(socialHash, platformHash));
        _enforceSupersedesChain(user, SOCIAL_VERIFICATION_TYPEHASH, digest, payloadHash, supersedes);
        _requireEligibleAttesters(digest, signature);
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        _recordCanonical(user, SOCIAL_VERIFICATION_TYPEHASH, digest, payloadHash);
        userSocialHashes[user] = socialHash;
        usedSocialHashes[socialHash] = true;
        _checkAndUpdateKycTier1(user);
        // solhint-disable-next-line not-rely-on-time
        emit SocialVerified(user, socialHash, platform, timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ATTESTATION VERIFICATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Compute the EIP-712 digest and delegate verification to the
    ///         attestation gateway. The gateway owns the dual-path
    ///         (legacy / M-of-N), the replay-protection nonce map, the
    ///         Pausable circuit-breaker, and all audit-recommended guards.
    /// @dev Pre-cutover (gateway unset), every call reverts with
    ///      `AttestationGatewayNotSet`. Cutover sequence: deploy
    ///      `OmniAttestationGateway` → wire it via {setAttestationGateway}
    ///      → all attestations flow through it.
    /// @param user Subject of the attestation (the address whose tier is
    ///        being promoted). Forwarded so the gateway can enforce audit
    ///        finding C-2: subject ∉ committee.
    /// @param structHash EIP-712 struct hash (unique per verification type).
    /// @param nonce Unique nonce for replay protection.
    /// @param deadline Proof expiration timestamp.
    /// @param proof Legacy: 65-byte single-signer ECDSA. Committee: opaque
    ///        verifier-specific blob (e.g. commitBlock || sigs).
    function _verifyAttestation(
        address user,
        bytes32 structHash,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata proof
    ) internal {
        IOmniAttestationGateway gw = attestationGateway;
        if (address(gw) == address(0)) revert AttestationGatewayNotSet();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        gw.verifyAndConsume(user, digest, nonce, deadline, proof);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   OMNICORE-DECENT — SUPERSEDES CHAIN + AUTO-ELIGIBILITY HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Enforce the supersedes chain for a `(user, typehash)` tuple.
    /// @dev Reverts on mismatch with a CLASSIFYING event emitted right
    ///      before the revert so off-chain observers can distinguish race
    ///      conditions (`AttestationRaceLost`) from equivocation attempts
    ///      (`AttestationEquivocationAttempt`).
    ///
    ///      Called by every `_submit*Internal` function AFTER digest
    ///      construction but BEFORE {_requireEligibleAttesters} + gateway
    ///      `verifyAndConsume`. Ordering matters: chain check first so we
    ///      don't waste a verifier round-trip on obviously wrong-chain
    ///      envelopes; eligibility check second so an excluded attester
    ///      can't even consume the nonce; gateway last.
    ///
    ///      Rejection at this layer means no nonce is consumed — honest
    ///      relayers observe the `AttestationRaceLost` event, re-form the
    ///      envelope against the new `currentCanonical`, and resubmit
    ///      using the original proof bytes.
    /// @param user                 Subject of the attestation.
    /// @param typehash             EIP-712 typehash discriminator.
    /// @param newDigest            Newly-computed envelope digest.
    /// @param newPayloadHash       Payload portion of the envelope — used
    ///                              ONLY for race-vs-equivocation
    ///                              classification, not for the chain check.
    /// @param submittedSupersedes  The supersedes value the attester signed.
    function _enforceSupersedesChain(
        address user,
        bytes32 typehash,
        bytes32 newDigest,
        bytes32 newPayloadHash,
        bytes32 submittedSupersedes
    ) internal {
        OmniRegistrationDigestLib.checkSupersedesChain(
            currentCanonical,
            canonicalPayloadHash,
            user,
            typehash,
            newDigest,
            newPayloadHash,
            submittedSupersedes
        );
    }

    /// @notice Confirm every attester in `proof` passes the auto-eligibility
    ///         check — fewer than `MISBEHAVIOR_EXCLUSION_THRESHOLD` recorded
    ///         events in the trailing `MISBEHAVIOR_EXCLUSION_WINDOW`.
    /// @dev Consumer-level eligibility gate. Lives here (not in
    ///      `RandomCommitteeVerifier`) so the Phase 2 stability window is
    ///      preserved — the verifier is zero-delta in this upgrade.
    ///
    ///      Runs AFTER {_enforceSupersedesChain} (so we don't burn the
    ///      verifier round-trip on rejections) and BEFORE
    ///      `gateway.verifyAndConsume` (so an ineligible attester can't
    ///      consume the nonce even with a valid signature).
    ///
    ///      Derives the attester list by reading
    ///      `attestationGateway.committeeVerifier()` and calling its
    ///      `verify(digest, proof)` directly — view function, no nonce
    ///      consumption, no side effects. If the committee verifier is
    ///      unset, the gateway is still on the legacy single-key path and
    ///      this gate is a no-op (legacy retirement is gated separately
    ///      by the gateway's `disableLegacyPath()` latch).
    /// @param digest Pre-computed EIP-712 digest.
    /// @param proof  Verifier-specific opaque bytes.
    function _requireEligibleAttesters(
        bytes32 digest,
        bytes calldata proof
    ) internal view {
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, proof
        );
    }

    /// @notice Public view wrapping the library-side window counter for off-
    ///         chain consumers (reward calculator, monitoring dashboards).
    function getMisbehaviorCountInWindow(
        address attester,
        uint256 windowSeconds
    ) external view returns (uint256) {
        return OmniRegistrationDigestLib.getMisbehaviorCountInWindow(
            misbehaviorTimestamps, attester, windowSeconds
        );
    }

    /// @notice Advance canonical pointers + mark prior as historical via library.
    function _recordCanonical(
        address user,
        bytes32 typehash,
        bytes32 newDigest,
        bytes32 newPayloadHash
    ) internal {
        OmniRegistrationDigestLib.recordCanonical(
            currentCanonical,
            canonicalPayloadHash,
            wasEverCanonical,
            user,
            typehash,
            newDigest,
            newPayloadHash
        );
    }

    /// @notice Permissionless equivocation attribution.
    /// @dev Anyone submits two signed envelopes that prove a single
    ///      attester signed conflicting claims under the same
    ///      `sharedSupersedes` parent. The contract reconstructs both
    ///      digests, verifies both proofs via direct verifier read, finds
    ///      the common attester(s), and records each one's misbehavior
    ///      timestamp — feeding BOTH the per-epoch reward zeroing (off-
    ///      chain) and the rolling 30-day auto-exclusion (on-chain).
    ///
    ///      FALSE-POSITIVE PROTECTION (in evaluation order):
    ///        1. Reconstruct digests from envelope inputs — prevents
    ///           proof-mismatch attacks where the recorder substitutes a
    ///           proof from an unrelated envelope.
    ///        2. Payloads must differ — otherwise it's the same fact and
    ///           there is no equivocation.
    ///        3. Non-zero `sharedSupersedes` MUST be present in
    ///           `wasEverCanonical` — closes fabrication against a
    ///           never-real parent.
    ///        4. Zero `sharedSupersedes` requires `currentCanonical[subject]
    ///           [typehash] == 0` — first-attestation race immunity: if
    ///           the legitimate first attestation has already landed, any
    ///           competing pair signed with `supersedes=0` is honest
    ///           racing, not equivocation.
    ///        5. Both proofs must validate via the active committee
    ///           verifier.
    ///        6. At least one common attester between the two committees.
    ///
    ///      BOUNTY: NONE in v4. Watchers run gratis (validators have an
    ///      existing economic interest in keeping the network honest).
    ///      Bounty mechanics deferred to v5 if empirically needed.
    ///
    ///      REPLAY: this function is NOT idempotent on purpose. Each call
    ///      appends a timestamp. Replaying the same equivocation evidence
    ///      twice DOES increment twice. Acceptable in v4 because the
    ///      recorder gets no bounty and the exclusion threshold is 3
    ///      events — replaying once only succeeds against an attester who
    ///      ALREADY has at least one real attempt, and isn't economically
    ///      motivated. Nonce dedup can be added in v5 if a pattern emerges.
    /// @param typehash           The EIP-712 typehash both envelopes claim.
    /// @param subject            The subject address both envelopes claim.
    /// @param sharedSupersedes   The supersedes parent both envelopes claim.
    /// @param envelopeA          Encoded envelope inputs for the first signed
    ///                            claim (typehash-specific, decoded inside
    ///                            {_reconstructDigest}).
    /// @param proofA             Verifier proof bytes for envelopeA.
    /// @param envelopeB          Encoded envelope inputs for the second claim.
    /// @param proofB             Verifier proof bytes for envelopeB.
    function recordEquivocation(
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelopeA,
        bytes calldata proofA,
        bytes calldata envelopeB,
        bytes calldata proofB
    ) external nonReentrant {
        // Post-split: this contract owns the phone/social/email typehashes.
        // Tier 2/3/4 typehashes live on OmniRegistrationKYCTiers; calls
        // for those typehashes must go there instead.
        if (typehash != PHONE_VERIFICATION_TYPEHASH
            && typehash != SOCIAL_VERIFICATION_TYPEHASH
            && typehash != EMAIL_VERIFICATION_TYPEHASH) {
            revert UnsupportedTypehash(typehash);
        }
        // Body extracted to {OmniRegistrationDigestLib.recordEquivocation}
        // for code-size relief. NOTE: caller's `nonReentrant` modifier
        // still gates the call site — the library function is `external`
        // (delegate-called) so the consumer's reentrancy guard fully
        // covers it. See `OmniRegistrationDigestLib.recordEquivocation`
        // for the full body + audit-remediation dedup logic.
        OmniRegistrationDigestLib.recordEquivocation(
            currentCanonical,
            wasEverCanonical,
            misbehaviorTimestamps,
            recordedEquivocationEvidence,
            attestationGateway,
            DOMAIN_SEPARATOR,
            typehash,
            subject,
            sharedSupersedes,
            envelopeA,
            proofA,
            envelopeB,
            proofB
        );
    }

    /// @notice Reconstruct an EIP-712 digest + its typehash-specific payload
    ///         hash from the raw envelope inputs.
    /// @dev Per-typehash dispatcher — each branch ABI-decodes the envelope
    ///      back into the original struct fields, re-derives the struct
    ///      hash with the canonical `(supersedes, subject)` pair plumbed
    ///      through, and applies `_hashTypedDataV4` to get the digest.
    ///      Duplicating the encoding per typehash is unavoidable because
    ///      each typehash has different fields; the alternative would be a
    ///      single dispatcher with `if/else` typehash branches that's
    ///      identical in surface but harder to audit per-branch.
    ///
    ///      ENVELOPE LAYOUTS (all `abi.encode`):
    ///        PHONE_VERIFICATION_TYPEHASH:
    ///          (bytes32 phoneHash, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        SOCIAL_VERIFICATION_TYPEHASH:
    ///          (bytes32 socialHash, string platform, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        EMAIL_VERIFICATION_TYPEHASH:
    ///          (bytes32 emailHash, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        ID_VERIFICATION_TYPEHASH:
    ///          (bytes32 idHash, string country, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        ADDRESS_VERIFICATION_TYPEHASH:
    ///          (bytes32 addressHash, string country, bytes32 documentType, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        SELFIE_VERIFICATION_TYPEHASH:
    ///          (bytes32 selfieHash, uint256 similarity, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        PERSONA_VERIFICATION_TYPEHASH:
    ///          (bytes32 verificationHash, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        ACCREDITED_INVESTOR_TYPEHASH:
    ///          (uint8 criteria, bool certified, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        AML_CLEARANCE_TYPEHASH:
    ///          (bool cleared, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///        THIRD_PARTY_KYC_TYPEHASH:
    ///          (address provider, uint256 timestamp, bytes32 nonce, uint256 deadline)
    ///
    ///      The "payload hash" returned alongside the digest is a typehash-
    ///      specific summary of the asserted facts — the value that gets
    ///      stored in {canonicalPayloadHash} on success and compared
    ///      against to discriminate race-vs-equivocation.
    /// @param typehash           Typehash of the envelope being reconstructed.
    /// @param subject            Subject address (plumbed into the struct hash).
    /// @param sharedSupersedes   Supersedes value (plumbed into the struct hash).
    /// @param envelope           Encoded typehash-specific tail of the struct.
    /// @return digest            Reconstructed EIP-712 digest.
    /// @return payloadHash       Typehash-specific payload hash.
    function _reconstructDigest(
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelope
    ) internal view returns (bytes32 digest, bytes32 payloadHash) {
        // Hoisted into {OmniRegistrationDigestLib} for code-size relief —
        // the 10-way dispatcher is ~5 KB of bytecode and would push this
        // contract over the 24576-byte Subnet-EVM deployment limit. The
        // library function is `external pure`, so Solidity compiles this
        // call as a DELEGATECALL to the library address linked at deploy
        // time; the body of the dispatcher lives in the library's
        // bytecode, not this contract's.
        (digest, payloadHash) = OmniRegistrationDigestLib.reconstruct(
            typehash, subject, sharedSupersedes, envelope, DOMAIN_SEPARATOR
        );
    }

    /// @notice EIP-712 v4 digest derivation matching the construction used
    ///         by every submit path (`"\x19\x01" || DOMAIN_SEPARATOR ||
    ///         structHash`). Centralized so {_reconstructDigest} and any
    ///         future caller can't drift from the submit-side encoding.
    /// @param structHash Pre-computed EIP-712 struct hash.
    /// @return Digest matching what `submit*` paths build.
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @notice Check and update KYC Tier 1 status after phone/social verification
    /// @param user Address to check and potentially update
    /// @dev H-01: Also synchronizes Registration.kycTier for canClaimWelcomeBonus()
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

    /**
     * @notice Get the number of users referred by a user
     * @param user Address to check
     * @return Number of referrals
     */
    function getReferralCount(address user) external view returns (uint256) {
        return referralCounts[user];
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
        if (msg.sender != omniRewardManagerAddress) revert Unauthorized();
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
        if (msg.sender != omniRewardManagerAddress) revert Unauthorized();
        Registration storage reg = registrations[user];
        if (reg.timestamp == 0) revert NotRegistered();
        if (reg.firstSaleBonusClaimed) revert BonusAlreadyClaimed();

        reg.firstSaleBonusClaimed = true;
        // solhint-disable-next-line not-rely-on-time
        emit FirstSaleBonusMarkedClaimed(user, block.timestamp);
    }

    /**
     * @notice Mark a user as having completed their first marketplace sale
     * @dev Only callable by authorized recorder contracts (marketplace/escrow).
     *      This flag gates the first sale bonus in OmniRewardManager, ensuring
     *      that users cannot claim the bonus without actually completing a sale.
     *      SYBIL-H05: Validates minimum sale amount, account age, and that
     *      buyer and seller don't share the same referrer (wash trade indicator).
     * @param seller The seller's address who completed the sale
     * @param saleAmount The sale amount in token units (18 decimals)
     * @param buyer The buyer's address in the transaction
     */
    function markFirstSaleCompleted(
        address seller,
        uint256 saleAmount,
        address buyer
    ) external {
        if (!authorizedRecorders[msg.sender]) {
            revert UnauthorizedTransactionRecorder();
        }
        Registration storage reg = registrations[seller];
        if (reg.timestamp == 0) revert NotRegistered();

        // SYBIL-H05: Minimum sale amount (prevents trivial wash trades)
        if (saleAmount < MIN_FIRST_SALE_AMOUNT) {
            revert FirstSaleRequirementsNotMet();
        }

        // SYBIL-H05: Account must be at least MIN_FIRST_SALE_AGE old
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < reg.timestamp + MIN_FIRST_SALE_AGE) {
            revert FirstSaleRequirementsNotMet();
        }

        // SYBIL-H05: Buyer and seller must not share the same referrer
        // (strong indicator of wash trading between sybil accounts)
        if (buyer != address(0)) {
            Registration storage buyerReg = registrations[buyer];
            if (buyerReg.timestamp == 0) {
                revert FirstSaleRequirementsNotMet();
            }
            // Case 1: Both have matching non-zero referrers
            if (
                buyerReg.referrer != address(0) &&
                reg.referrer != address(0) &&
                buyerReg.referrer == reg.referrer
            ) {
                revert FirstSaleRequirementsNotMet();
            }
            // ADV-R8-03: When both parties have no referrer,
            // require buyer to have at least KYC Tier 1 as
            // additional Sybil protection (referrer-based
            // detection is unavailable for zero-referrer pairs)
            if (
                buyerReg.referrer == address(0) &&
                reg.referrer == address(0) &&
                buyerReg.kycTier < 1
            ) {
                revert FirstSaleRequirementsNotMet();
            }
        }

        firstSaleCompleted[seller] = true;
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
        return reg.timestamp != 0 && !reg.welcomeBonusClaimed && kycTier1CompletedAt[user] != 0;
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
     * @notice RETIRED — legacy single-key signer setter. Audit Pass-2
     *         L-NEW-Biz: after the Phase 2 refactor, `_verifyAttestation`
     *         routes every attestation through `attestationGateway`,
     *         which owns its OWN trusted single-key path. The local
     *         `trustedVerificationKey` storage slot is dead code (retained
     *         only for UUPS storage-layout stability) and this setter
     *         always reverts to prevent operator confusion about "which
     *         key is in charge". Use the gateway's
     *         `setTrustedVerificationKey` instead — that is the live key
     *         path during the cutover window, before
     *         `disableLegacyPath()` is permanently engaged.
     */
    function setTrustedVerificationKey(
        address /* newKey */
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revert LegacyTrustedKeyRetired();
    }

    /**
     * @notice Set the Phase 2 attestation gateway. All KYC / AML /
     *         phone / email / social verification proofs route through this
     *         contract for verification + nonce replay protection.
     * @dev Only callable by DEFAULT_ADMIN_ROLE (intended: OmniTimelockController
     *      via OmniGovernance proposal — 7-day timelock). The gateway is the
     *      single trust surface for all verifier swaps (committee → BLS →
     *      ZK) — OmniRegistration never points at a verifier directly.
     *
     *      Audit Pass-2 M-NEW-4: rejects `address(0)` so a routine setter
     *      call cannot brick the attestation pipeline by accident. Use
     *      {clearAttestationGateway} for the explicit emergency-shutoff
     *      path (separate entry point matching the audit M-2 discipline).
     *      Also wiring-checks that the new gateway has `authorizedConsumers
     *      [address(this)] = true` so the gateway-side ACL is in place
     *      BEFORE we redirect attestations into it (gateway-side ACL is
     *      what stops cross-tenant calls; an unwired gateway would revert
     *      every `verifyAndConsume` call from this contract).
     *
     *      All audit-recommended guards live in the gateway:
     *      subject exclusion (C-2), pool-size brick + security gate
     *      (H-4, C-1), Pausable + guardian (H-5), verifier-version
     *      whitelist (M-1), explicit set/clear split (M-2), one-way
     *      `legacyDisabled` latch (Pass-2 H-NEW-3).
     * @param newGateway Address of the new gateway (must be non-zero).
     */
    function setAttestationGateway(
        IOmniAttestationGateway newGateway
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newGateway) == address(0)) revert ZeroAddress();
        if (!newGateway.authorizedConsumers(address(this))) {
            revert GatewayNotConfiguredForConsumer(address(this));
        }
        attestationGateway = newGateway;
        emit AttestationGatewaySet(address(newGateway));
    }

    /**
     * @notice Audit Pass-2 M-NEW-4: explicit emergency-shutoff path for
     *         the attestation gateway. Sets `attestationGateway = 0`,
     *         which makes every submit function revert with
     *         {AttestationGatewayNotSet}. Separate from
     *         {setAttestationGateway} so the zero-write cannot happen by
     *         accident. Caller must be DEFAULT_ADMIN_ROLE.
     * @dev    Recovery path: deploy / re-wire a fresh gateway, then call
     *         {setAttestationGateway} again. Use case: gateway bug
     *         requires de-authorization while a fix is in flight.
     */
    function clearAttestationGateway() external onlyRole(DEFAULT_ADMIN_ROLE) {
        attestationGateway = IOmniAttestationGateway(address(0));
        emit AttestationGatewaySet(address(0));
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
        if (registrations[user].timestamp == 0) revert NotRegistered();
        _unregisterUser(user);
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
            // Skip users who aren't registered
            if (registrations[users[i]].timestamp != 0) {
                _unregisterUser(users[i]);
            }

            unchecked {
                ++i;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRANSACTION LIMITS & VOLUME TRACKING
    // ═══════════════════════════════════════════════════════════════════════

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

    /// @dev REMOVED: TRANSACTION_RECORDER_ROLE replaced by authorizedRecorders
    ///      (state variable declared in storage gap section below)

    /**
     * @notice Get the current KYC tier for `user`.
     * @dev Post-split (FIX_OMNIREGISTRATION_SPLIT): reads the canonical
     *      `kycTier` field on this contract. KYCTiers updates this field
     *      via `bumpKycTier` on every Tier-2/3/4 promotion, so this single
     *      field is the source of truth across the whole system. Returns
     *      0 for unregistered users.
     */
    function getUserKYCTier(address user) public view returns (uint8) {
        return registrations[user].kycTier;
    }

    /**
     * @notice True if `user` has reached KYC Tier 2.
     * @dev Post-split passthrough (audit H-01 remediation). Reads the
     *      canonical `registrations[user].kycTier` field — which KYCTiers
     *      maintains via `bumpKycTier` on every Tier-2/3/4 promotion AND
     *      `resetKycTier3` correctly downgrades to 2 on sanctions reset.
     *      Single source of truth for downstream consumers (OmniParticipation,
     *      ValidatorProvisioner) that retain `IOmniRegistration.hasKycTier{N}`
     *      in their local interfaces. Pre-split this function lived directly
     *      on `OmniRegistration`; post-split it was inadvertently moved to
     *      `OmniRegistrationKYCTiers`, breaking every downstream call.
     */
    function hasKycTier2(address user) external view returns (bool) {
        return registrations[user].kycTier >= 2;
    }

    /// @notice True if `user` has reached KYC Tier 3. See {hasKycTier2} note.
    function hasKycTier3(address user) external view returns (bool) {
        return registrations[user].kycTier >= 3;
    }

    /// @notice True if `user` has reached KYC Tier 4. See {hasKycTier2} note.
    function hasKycTier4(address user) external view returns (bool) {
        return registrations[user].kycTier >= 4;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Internal cleanup for user unregistration
     * @param user Address to unregister
     * @dev Clears ALL registration data: email/phone/social/ID/address hashes,
     *      KYC tier timestamps, provider data, volume tracking, referral counts,
     *      firstSaleCompleted, persona verification, AML clearance, and
     *      accredited investor state. Ensures clean re-registration.
     */
    function _unregisterUser(address user) internal {
        Registration storage reg = registrations[user];
        bytes32 emailHash = reg.emailHash;
        bytes32 phoneHash = reg.phoneHash;

        // Decrement referrer's referral count
        if (reg.referrer != address(0) && referralCounts[reg.referrer] > 0) {
            --referralCounts[reg.referrer];
        }

        // Clear hash reservations (allows re-use)
        if (emailHash != bytes32(0)) usedEmailHashes[emailHash] = false;
        if (phoneHash != bytes32(0)) usedPhoneHashes[phoneHash] = false;

        bytes32 socialHash = userSocialHashes[user];
        if (socialHash != bytes32(0)) {
            usedSocialHashes[socialHash] = false;
            delete userSocialHashes[user];
        }
        delete userEmailHashes[user];

        // Audit H-02: the Tier-2/3/4 per-user state (idHash + addressHash +
        // selfieVerified + Persona + AML + accredited-investor + Tier-2/3/4
        // completion timestamps + userKYCProvider + userCountries) now lives
        // exclusively on `OmniRegistrationKYCTiers`. Cross-contract sweep so
        // that state is cleared too — otherwise `usedIDHashes` permanently
        // burns a passport hash, and `kycTier{2,3,4}CompletedAt` short-
        // circuits future tier promotions. The slots ALSO still exist in
        // this contract's storage layout for UUPS safety (see __gap NatSpec
        // below), but are dead — we do NOT touch them anymore (pre-remediation
        // we cleared them locally; the cross-contract sweep is the canonical
        // path). Gracefully skip if `kycTiersContract` is still unset (allows
        // the original monolithic deploy to keep functioning during cutover).
        address kt = kycTiersContract;
        if (kt != address(0)) {
            IOmniRegistrationKYCTiersSweep(kt).purgeUserState(user);
        }

        // M-03: Clear KYC attestation arrays for tiers 2-4 to prevent
        // attestation progress from persisting across unregister/re-register cycles.
        // delete on a dynamic storage array sets its length to zero. Kept
        // because `kycAttestations` lives on THIS contract (driven by the
        // deprecated `attestKYC` path); KYCTiers does not own this map.
        for (uint8 tier = 2; tier <= 4; ++tier) {
            bytes32 attestationKey = keccak256(abi.encodePacked(user, tier));
            delete kycAttestations[attestationKey];
        }

        // Clear username binding (prevents permanent state corruption).
        bytes32 userUsernameHash = registeredUsernameHash[user];
        if (userUsernameHash != bytes32(0)) {
            delete usernameOwner[userUsernameHash];
            delete registeredUsernameHash[user];
        }

        // Clear device hash.
        delete userDeviceHash[user];

        // Clear Base-owned verification state (Tier-1 + bonuses).
        delete kycTier1CompletedAt[user];
        delete firstSaleCompleted[user];
        delete referralCounts[user];

        delete registrations[user];

        --totalRegistrations;

        // solhint-disable-next-line not-rely-on-time
        emit UserUnregistered(user, msg.sender, block.timestamp);
    }

    /**
     * @notice Admin function to revoke KYC Tier 3 (e.g., user found on sanctions list)
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Resets Persona verification,
     *      AML clearance, and Tier 3 completion. Also resets Tier 4 if present.
     *      Does NOT reset accredited investor status (separate concern).
     * @param user Address of the user whose Tier 3 is being revoked
     */
    function resetKycTier3(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registrations[user].timestamp == 0) revert NotRegistered();

        // Audit H-03: Persona / AML / Tier-3 / Tier-4 / userKYCProvider now
        // live on OmniRegistrationKYCTiers. Without a cross-contract reset
        // the sanctions-flagged user keeps `hasKycTier3` == true on KYCTiers
        // and stays eligible for validator gates, predictions, RWA buy, etc.
        // Cross-call so KYCTiers's local copy is also wiped. Falls back to
        // the local-only reset path if the binding hasn't been set yet
        // (cutover staging) so the function never bricks during deploy.
        address kt = kycTiersContract;
        if (kt != address(0)) {
            IOmniRegistrationKYCTiersSweep(kt).purgeUserState(user);
        }

        // Downgrade Registration.kycTier — single source of truth read by
        // {getUserKYCTier} + {hasKycTier3} + downstream OmniParticipation /
        // ValidatorProvisioner consumers.
        Registration storage reg = registrations[user];
        if (reg.kycTier >= 3) {
            uint8 oldTier = reg.kycTier;
            reg.kycTier = 2;
            emit KYCUpgraded(user, oldTier, 2);
        }

        emit KycTier3Reset(user, _msgSender(), block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Request ossification (starts 48-hour delay)
     * @dev Two-phase ossification prevents accidental or malicious
     *      irreversible lockout. Once confirmed after OSSIFICATION_DELAY,
     *      the contract becomes permanently non-upgradeable.
     *      Only callable by DEFAULT_ADMIN_ROLE.
     */
    function requestOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossificationRequestedAt != 0) {
            revert OssificationAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestedAt = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit OssificationRequested(block.timestamp);
    }

    /// @notice Cancel a pending ossification request
    /// @dev L-04: Allows admin to cancel if they change their mind.
    ///      Resets `ossificationRequestedAt` so a new request can be made later.
    function cancelOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossificationRequestedAt == 0) {
            revert OssificationNotRequested();
        }
        delete ossificationRequestedAt;
        emit OssificationCancelled(_msgSender());
    }

    /**
     * @notice Confirm and execute ossification after delay
     * @dev Requires OSSIFICATION_DELAY (48 hours) to have elapsed
     *      since requestOssification() was called. Once executed,
     *      no further proxy upgrades are possible (irreversible).
     *
     *      Upgrade Validation Process (M-02):
     *      Before ANY production upgrade, run OpenZeppelin
     *      validateUpgrade() from hardhat-upgrades to verify storage
     *      layout compatibility:
     *      require('openzeppelin/hardhat-upgrades')
     *        .validateUpgrade(V1, V2)
     *      This ensures new state variables consume gap slots
     *      correctly and do not corrupt existing storage.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ossificationRequestedAt == 0) {
            revert OssificationNotRequested();
        }
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < ossificationRequestedAt + OSSIFICATION_DELAY
        ) {
            revert OssificationDelayNotMet();
        }
        // L-03: Set _ossified before clearing request for defense in depth
        _ossified = true;
        delete ossificationRequestedAt;
        emit ContractOssified(address(this));
        // solhint-disable-next-line not-rely-on-time
        emit OssificationExecuted(block.timestamp);
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
    //                    ROLE MANAGEMENT (Contract-to-Contract)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the OmniRewardManager contract address
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Replaces the former
     *      BONUS_MARKER_ROLE — only the OmniRewardManager can mark
     *      bonuses as claimed.
     * @param _omniRewardManager Address of the OmniRewardManager contract
     */
    function setOmniRewardManagerAddress(
        address _omniRewardManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        omniRewardManagerAddress = _omniRewardManager;
    }

    /**
     * @notice Authorize or deauthorize a contract as a transaction recorder
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Replaces the former
     *      TRANSACTION_RECORDER_ROLE — used by MinimalEscrow to mark a buyer's
     *      first completed marketplace sale ({markFirstSaleCompleted}) for the
     *      first-sale-bonus anti-Sybil checks.
     * @param recorder Contract address to authorize/deauthorize
     * @param authorized Whether the address is authorized
     */
    function setAuthorizedRecorder(
        address recorder,
        bool authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedRecorders[recorder] = authorized;
    }

    /**
     * @notice Transfer admin authority over VALIDATOR_ROLE and
     *         KYC_ATTESTOR_ROLE to a new admin role
     * @dev One-time call by DEFAULT_ADMIN_ROLE to delegate validator
     *      role management to ValidatorProvisioner. After this call,
     *      only the holder of `newAdminRole` can grant/revoke
     *      VALIDATOR_ROLE and KYC_ATTESTOR_ROLE.
     * @param newAdminRole The role that will admin VALIDATOR_ROLE
     *        and KYC_ATTESTOR_ROLE (e.g., PROVISIONER_ROLE)
     */
    function setValidatorRoleAdmin(
        bytes32 newAdminRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(VALIDATOR_ROLE, newAdminRole);
        _setRoleAdmin(KYC_ATTESTOR_ROLE, newAdminRole);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ERC-2771 CONTEXT OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve diamond inheritance for _msgSender()
     * @dev Delegates to ERC2771ContextUpgradeable so that calls from
     *      the trusted forwarder extract the real sender from calldata.
     * @return The original sender when called via trusted forwarder,
     *         otherwise msg.sender
     */
    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve diamond inheritance for _msgData()
     * @dev Delegates to ERC2771ContextUpgradeable so that calls from
     *      the trusted forwarder strip the appended sender address.
     * @return The original calldata without the appended sender
     */
    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolve diamond inheritance for _contextSuffixLength()
     * @dev Delegates to ERC2771ContextUpgradeable which returns 20
     *      (the length of an address appended by ERC-2771 forwarders).
     * @return The context suffix length (20 bytes for ERC-2771)
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Delay required between requesting and executing ossification
    uint256 public constant OSSIFICATION_DELAY = 48 hours;

    /// @notice Timestamp when ossification was requested (0 = not requested)
    uint256 public ossificationRequestedAt;

    /// @notice Address of OmniRewardManager (only caller for bonus marking)
    /// @dev Replaces BONUS_MARKER_ROLE — only ever held by one contract.
    ///      Set via setOmniRewardManagerAddress().
    address public omniRewardManagerAddress;

    /// @notice Contracts authorized to record transactions
    /// @dev Replaces TRANSACTION_RECORDER_ROLE — only held by specific
    ///      contracts. Mappings do not consume sequential slots.
    ///      Set via setAuthorizedRecorder().
    mapping(address => bool) public authorizedRecorders;

    // ═══════════════════════════════════════════════════════════════════════
    //                    PHASE 2 — TRUSTLESS COMMITTEE ATTESTATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Attestation gateway for KYC/AML/email/phone/social proof
    ///         verification. The gateway owns the dual-path cutover state
    ///         (legacy single-key vs Phase 2 M-of-N committee) + the nonce
    ///         replay map + Pausable + all audit-recommended guards.
    /// @dev Set via {setAttestationGateway} (DEFAULT_ADMIN_ROLE = Timelock).
    ///      Pre-cutover: the OmniRegistration storage slot can be zero;
    ///      submit functions revert with `AttestationGatewayNotSet` until
    ///      a gateway is wired. Cutover sequence: deploy gateway → wire it
    ///      via setAttestationGateway → gateway becomes the single trust
    ///      surface for attestations. Reference impl:
    ///      `Coin/contracts/attestation/OmniAttestationGateway.sol`.
    ///
    ///      Storage-layout note: this slot replaces the earlier
    ///      `IAttestationVerifierBool` pointer (same slot index, same type
    ///      width — address). Field renamed for clarity; slot semantics
    ///      change from "verifier" to "gateway". No UUPS storage break.
    IOmniAttestationGateway public attestationGateway;

    /// @notice Per-user device-fingerprint hash recorded at registration.
    /// @dev SYBIL-Q-10 (2026-05-23): closes the same-device referral
    ///      self-deal where a single human installs the wallet twice on
    ///      the same device and registers as their own referrer to
    ///      harvest the 70% referrer slice of the welcome bonus split.
    ///      The wallet client derives a stable opaque
    ///      `keccak256(platformId || hardwareFingerprint || installSalt)`
    ///      and submits it alongside registration. The contract stores
    ///      it here and rejects any future registration whose `referrer`
    ///      already carries the same non-zero hash.
    ///
    ///      `bytes32(0)` is accepted for back-compat: pre-upgrade
    ///      registrations have no recorded deviceHash, and the same-
    ///      device check requires a non-zero collision before reverting.
    ///      The 2026-05-18 storage gap was 49; SYBIL-Q-10 consumes one
    ///      slot so the gap is now 48 below.
    mapping(address => bytes32) public userDeviceHash;

    // ═══════════════════════════════════════════════════════════════════════
    //         OMNICORE-DECENT — SUPERSEDES CHAIN + AUTO-ELIGIBILITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Latest accepted attestation digest per `(subject, typehash)`.
    /// @dev Supersedes chain head. Every new attestation MUST reference the
    ///      prior canonical digest via its `supersedes` field. The first
    ///      attestation for a `(subject, typehash)` tuple references
    ///      `bytes32(0)`. Single-attester equivocation is structurally
    ///      prevented because only one chain head exists per tuple, so a
    ///      second "first" attestation cannot land.
    mapping(address subject => mapping(bytes32 typehash => bytes32 digest))
        public currentCanonical;

    /// @notice Latest accepted payload hash per `(subject, typehash)`.
    /// @dev Stored alongside `currentCanonical` so the chain-check code can
    ///      distinguish race conditions (same payload, different relayer
    ///      raced and lost) from equivocation attempts (same attester
    ///      signing two different payloads under the same supersedes
    ///      parent). The payload hash is a typehash-specific summary of
    ///      the asserted facts: `phoneHash` for phone, `emailHash` for
    ///      email, `keccak256(abi.encode(cleared))` for AML, etc.
    mapping(address subject => mapping(bytes32 typehash => bytes32 payloadHash))
        public canonicalPayloadHash;

    /// @notice History flag: every digest that has EVER been canonical for
    ///         any `(subject, typehash)` tuple. Used by
    ///         {recordEquivocation} to require that a claimed-shared
    ///         supersedes parent actually existed on-chain at some
    ///         point — closes the fabrication attack where a recorder
    ///         points at a never-real parent. The first-attestation case
    ///         (`sharedSupersedes == 0`) is allowed and gated separately
    ///         by the first-attestation race-immunity check inside
    ///         `recordEquivocation`.
    mapping(bytes32 digest => bool) public wasEverCanonical;

    /// @notice Per-attester append-only list of equivocation-attempt
    ///         timestamps recorded via {recordEquivocation}.
    /// @dev Drives BOTH windows:
    ///       (a) per-epoch reward zeroing — off-chain calculator reads
    ///           `MisbehaviorRecorded` events within the current epoch and
    ///           sets that attester's reward to 0.
    ///       (b) rolling 30-day eligibility exclusion — `_requireEligibleAttesters`
    ///           reads `_misbehaviorCountInWindow` on every submit; if any
    ///           attester has ≥ `MISBEHAVIOR_EXCLUSION_THRESHOLD` events
    ///           in the trailing window, the submit reverts.
    ///
    ///      GROWTH: bounded in practice by the auto-exclusion threshold.
    ///      An attester whose count reaches 3 in 30 days is excluded from
    ///      new committees, so cannot generate more events. Storage cost
    ///      is therefore O(real misbehavior) — far below any dust-storage
    ///      concern.
    mapping(address attester => uint64[]) public misbehaviorTimestamps;

    /// @notice Misbehavior-event count that triggers auto-exclusion from
    ///         committee eligibility (`_requireEligibleAttesters`).
    /// @dev Reaching this threshold inside the trailing
    ///      `MISBEHAVIOR_EXCLUSION_WINDOW` disqualifies the attester from
    ///      any new attestation submission. Reinstatement is automatic
    ///      once events age out — no admin / governance action required.
    uint256 public constant MISBEHAVIOR_EXCLUSION_THRESHOLD = 3;

    /// @notice Rolling window for the exclusion threshold above.
    /// @dev Events older than this age out and no longer count toward
    ///      eligibility. Per the OMNICORE-DECENT design walk-through:
    ///      30 days is long enough that a sustained pattern is reliably
    ///      detected; short enough that an honest validator who got hit
    ///      by a freak false positive (e.g., a malformed bridge proof
    ///      that briefly looked like an equivocation) recovers within
    ///      one billing month rather than being permanently sidelined.
    uint256 public constant MISBEHAVIOR_EXCLUSION_WINDOW = 30 days;

    /// @notice Dedup set for {recordEquivocation} evidence pairs.
    /// @dev OMNICORE-DECENT post-audit remediation. Key = `keccak256(
    ///      typehash || subject || sharedSupersedes || sortedPair(
    ///      digestA, digestB))`. Set after a successful attribution;
    ///      subsequent calls with the same evidence revert
    ///      {EvidenceAlreadyRecorded}. Closes the replay-amplification
    ///      vector flagged by three of the four audit agents (OWASP F-01,
    ///      business-logic M-2, DeFi-patterns F-6).
    mapping(bytes32 evidenceKey => bool recorded)
        public recordedEquivocationEvidence;

    /// @notice Live OmniRegistrationKYCTiers proxy address — the only caller
    ///         authorised to (a) invoke {bumpKycTier} and (b) receive sweep
    ///         callbacks from this contract.
    /// @dev FIX_OMNIREGISTRATION_SPLIT audit H-02 / H-03 / L-01 remediation.
    ///      Set via {setKycTiersContract}; consumes 1 slot from `__gap`.
    ///      Unset (`address(0)`) means the post-split wiring has not been
    ///      finalised yet — `bumpKycTier` falls back to role-only gating, and
    ///      `_unregisterUser` / `resetKycTier3` skip the cross-contract sweep.
    address public kycTiersContract;

    /// @notice usernameHash (keccak256(bytes(lowercased username))) -> owner address.
    /// @dev The authoritative, user-signed username->address binding used for
    ///      trustless fund-routing resolution. Written only by {_bindUsername} under
    ///      a verified user signature. Consumes 1 slot from `__gap`.
    mapping(bytes32 usernameHash => address owner) public usernameOwner;

    /// @notice Reverse record: user address -> its bound usernameHash.
    /// @dev Enforces one username per account (anti-squat). Consumes 1 slot from `__gap`.
    mapping(address user => bytes32 usernameHash) public registeredUsernameHash;

    /// @notice Reserved username hashes (brands/system/blocklist) no user may bind.
    /// @dev Seeded by admin via {seedReservedUsernames}. Consumes 1 slot from `__gap`.
    mapping(bytes32 usernameHash => bool isReserved) public reservedUsername;

    /// @notice Legacy fund-routing reservation source (LegacyBalanceClaim).
    /// @dev Set via {setLegacyBalanceClaim}. Zero address = check disabled
    ///      (advisory until wired). Consumes 1 slot from `__gap`
    ///      (reduced 39 → 38, 2026-07-10 — legacy-reservation binding gate).
    ILegacyBalanceClaim public legacyBalanceClaim;

    /**
     * @dev Reserved storage gap for future upgrades.
     *      Ensures that adding new state variables in upgraded versions
     *      does not corrupt existing storage layout. Standard UUPS pattern
     *      used by all other OmniBazaar upgradeable contracts.
     *      Reduced from 50 to 49 to accommodate _ossified.
     *      Reduced from 49 to 48 to accommodate omniRewardManagerAddress.
     *      Reduced from 48 to 47 to accommodate ossificationRequestedAt.
     *      Reduced from 50 to 49 to accommodate Phase 2 attestation slot
     *      (attestationVerifier — 2026-05-18). Cutover gating uses
     *      `address(attestationVerifier) == address(0)` as sentinel,
     *      no separate flag storage required.
     *      Reduced from 49 to 48 to accommodate SYBIL-Q-10
     *      `userDeviceHash` (2026-05-23 — same-device referral block).
     *      Reduced from 48 to 44 to accommodate OMNICORE-DECENT
     *      supersedes chain + auto-eligibility (`currentCanonical`,
     *      `canonicalPayloadHash`, `wasEverCanonical`,
     *      `misbehaviorTimestamps`) — four new storage slots.
     *      Reduced from 44 to 43 to accommodate OMNICORE-DECENT
     *      post-audit `recordedEquivocationEvidence` dedup mapping.
     *      Reduced from 43 to 42 to accommodate `kycTiersContract`
     *      (split audit H-02/H-03/L-01 remediation, 2026-05-24).
     *      Reduced from 42 to 39 to accommodate the trustless username binding
     *      (`usernameOwner`, `registeredUsernameHash`, `reservedUsername` —
     *      3 new slots, 2026-06-09).
     *      Reduced from 39 to 38 to accommodate `legacyBalanceClaim`
     *      (legacy-reservation binding gate, 2026-07-10).
     *      Pre-mainnet: gap set to 50 for ample future upgrade room.
     *      Reduce gap by N when adding N new state variables.
     *
     *      SPLIT (FIX_OMNIREGISTRATION_SPLIT 2026-05-24): the following
     *      Tier-2/3/4 storage slots remain in this contract's layout for
     *      UUPS storage-safety but are NO LONGER WRITTEN OR READ by any
     *      function on this contract — Tier-2/3/4 attestation logic moved
     *      to OmniRegistrationKYCTiers. DO NOT REUSE these slot positions
     *      in any future upgrade — that would corrupt existing user data:
     *        userIDHashes, usedIDHashes, userCountries, userAddressHashes,
     *        usedAddressHashes, selfieVerified, kycTier2CompletedAt,
     *        videoSessionHashes, kycTier3CompletedAt, trustedKYCProviders,
     *        kycProviderNames, kycTier4CompletedAt, userKYCProvider,
     *        personaVerificationHashes, isAccreditedInvestor,
     *        accreditedInvestorCriteria, accreditedInvestorCertifiedAt,
     *        amlCleared, amlClearedAt.
     */
    uint256[38] private __gap;
}
