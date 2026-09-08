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
import {OmniRegistrationDigestLib} from "./OmniRegistrationDigestLib.sol";
import {
    IBridgeVerifier,
    IOmniAttestationGateway
} from "./OmniRegistrationInterfaces.sol";

/**
 * @notice The minimum surface this contract needs from the live
 *         `OmniRegistration` (Base) proxy after the OmniRegistration split
 *         (FIX_OMNIREGISTRATION_SPLIT). KYCTiers reads
 *         registration + Tier-1 state from Base and writes back exactly
 *         one thing — `bumpKycTier` — on every Tier-2/3/4 promotion.
 */
interface IOmniRegistrationBase {
    /// @notice True iff `user` is registered on Base (`registrations[user].timestamp != 0`).
    function isRegistered(address user) external view returns (bool);

    /// @notice Tier-1 completion timestamp on Base. Used by KYCTiers to gate
    ///         Tier-2 promotions (Tier 2 requires Tier 1).
    function kycTier1CompletedAt(address user) external view returns (uint256);

    /// @notice Authorised callback: KYCTiers bumps `registrations[user].kycTier`
    ///         on Base when a Tier-2/3/4 promotion completes. Only callable
    ///         by addresses with `KYCTIERS_ROLE` on Base.
    function bumpKycTier(address user, uint8 newTier) external;
}

/**
 * @title OmniRegistrationKYCTiers
 * @author OmniBazaar Team
 * @notice Tier-2/3/4 attestation surface, split out from `OmniRegistration` so
 *         the latter fits under the 24576-byte Subnet-EVM deployment limit
 *         after the OMNICORE-DECENT supersedes-chain + auto-eligibility +
 *         `recordEquivocation` additions. Hosts: ID / address / selfie /
 *         persona / AML / accredited-investor / third-party-KYC attestation
 *         submits, plus the OMNICORE-DECENT supersedes-chain machinery for
 *         the 7 typehashes it owns and a `recordEquivocation` that only
 *         accepts those 7 typehashes.
 *
 * @dev    Architecture (FIX_OMNIREGISTRATION_SPLIT):
 *           - Base (existing `OmniRegistration` proxy at `0x2B05cbA7…`)
 *             owns registration + Tier-1 (phone, social, email) + bonus
 *             marking + transaction-volume tracking + the canonical
 *             `registrations[user].kycTier` field.
 *           - This contract (new UUPS proxy) owns Tier-2/3/4 attestation
 *             submits + the per-user Tier-2/3/4 timestamps + the
 *             OMNICORE-DECENT chain state for its 7 typehashes.
 *           - KYCTiers receives `KYCTIERS_ROLE` on Base and calls
 *             `baseRegistration.bumpKycTier(user, N)` on every promotion
 *             so Base's canonical `kycTier` field stays in lock-step.
 *
 *         This contract is UUPS-upgradeable independently of Base.
 *         Storage layout: standard OZ ordering (inherited slots, then
 *         declared slots), with a `__gap` at the tail.
 */
contract OmniRegistrationKYCTiers is
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

    /// @notice EIP-712 typehash for ID verification proof (KYC Tier 2).
    // solhint-disable-next-line max-line-length
    bytes32 public constant ID_VERIFICATION_TYPEHASH = keccak256(
        "IDVerification(address user,bytes32 idHash,string country,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for address verification proof (KYC Tier 2).
    // solhint-disable-next-line max-line-length
    bytes32 public constant ADDRESS_VERIFICATION_TYPEHASH = keccak256(
        "AddressVerification(address user,bytes32 addressHash,string country,bytes32 documentType,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for selfie verification proof (KYC Tier 2).
    // solhint-disable-next-line max-line-length
    bytes32 public constant SELFIE_VERIFICATION_TYPEHASH = keccak256(
        "SelfieVerification(address user,bytes32 selfieHash,uint256 similarity,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for Persona identity verification (KYC Tier 3).
    // solhint-disable-next-line max-line-length
    bytes32 public constant PERSONA_VERIFICATION_TYPEHASH = keccak256(
        "PersonaVerification(address user,bytes32 verificationHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for accredited investor self-certification.
    // solhint-disable-next-line max-line-length
    bytes32 public constant ACCREDITED_INVESTOR_TYPEHASH = keccak256(
        "AccreditedInvestorCertification(address user,uint8 criteria,bool certified,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for AML/PEP screening clearance.
    // solhint-disable-next-line max-line-length
    bytes32 public constant AML_CLEARANCE_TYPEHASH = keccak256(
        "AMLClearance(address user,bool cleared,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 typehash for third-party KYC attestation (KYC Tier 4).
    // solhint-disable-next-line max-line-length
    bytes32 public constant THIRD_PARTY_KYC_TYPEHASH = keccak256(
        "ThirdPartyKYC(address user,address provider,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    /// @notice Selfie minimum similarity threshold (face-match score, 0-100).
    uint256 public constant MIN_SELFIE_SIMILARITY = 85;

    /// @notice OMNICORE-DECENT misbehavior exclusion threshold.
    uint256 public constant MISBEHAVIOR_EXCLUSION_THRESHOLD = 3;
    /// @notice OMNICORE-DECENT misbehavior exclusion window.
    uint256 public constant MISBEHAVIOR_EXCLUSION_WINDOW = 30 days;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice EIP-712 domain separator.
    /// @dev Set on `initialize`; rotated only by reinitializer.
    // solhint-disable-next-line var-name-mixedcase
    bytes32 public DOMAIN_SEPARATOR;

    /// @notice Reference to the Base registration contract.
    IOmniRegistrationBase public baseRegistration;

    /// @notice Attestation gateway (committee verifier + nonce burner).
    IOmniAttestationGateway public attestationGateway;

    // ─── Tier-2 storage (ID + Address + Selfie) ───────────────────────────

    mapping(address => bytes32) public userIDHashes;
    mapping(bytes32 => bool) public usedIDHashes;
    mapping(address => string) public userCountries;
    mapping(address => bytes32) public userAddressHashes;
    mapping(bytes32 => bool) public usedAddressHashes;
    mapping(address => bool) public selfieVerified;
    mapping(address => uint256) public kycTier2CompletedAt;

    // ─── Tier-3 storage (Persona + AML) ────────────────────────────────────

    mapping(address => bytes32) public personaVerificationHashes;
    mapping(address => uint256) public kycTier3CompletedAt;
    mapping(address => bool) public amlCleared;
    mapping(address => uint256) public amlClearedAt;

    // ─── Accredited-investor storage (optional, gates on Tier-3 Persona) ──

    mapping(address => bool) public isAccreditedInvestor;
    mapping(address => uint8) public accreditedInvestorCriteria;
    mapping(address => uint256) public accreditedInvestorCertifiedAt;

    // ─── Tier-4 storage (third-party KYC) ──────────────────────────────────

    mapping(address => bool) public trustedKYCProviders;
    mapping(address => string) public kycProviderNames;
    mapping(address => address) public userKYCProvider;
    mapping(address => uint256) public kycTier4CompletedAt;

    /// @notice Used nonces (legacy global replay protection for Tier-4
    ///         provider attestations). Retained for UUPS storage-layout
    ///         compatibility; superseded by `kycProviderNonce` (RT-05).
    mapping(bytes32 => bool) public usedNonces;

    // ─── OMNICORE-DECENT storage (this contract's own copy) ────────────────

    /// @notice Per-(subject, typehash) canonical digest. KYCTiers owns the
    ///         chain state for its 7 typehashes; Base owns the chain state
    ///         for its 3 typehashes. Independent chains, no cross-contract
    ///         coordination required.
    mapping(address subject => mapping(bytes32 typehash => bytes32 digest))
        public currentCanonical;
    mapping(address subject => mapping(bytes32 typehash => bytes32 payloadHash))
        public canonicalPayloadHash;
    mapping(bytes32 digest => bool) public wasEverCanonical;
    mapping(address attester => uint64[]) public misbehaviorTimestamps;
    mapping(bytes32 evidenceKey => bool recorded)
        public recordedEquivocationEvidence;

    /// @notice One-way ossification latch. Set true to permanently disable
    ///         {_authorizeUpgrade}; cannot be reset. Audit I-09 placement:
    ///         relocated adjacent to other storage so future maintainers
    ///         see all storage in one block + `__gap` accurately reflects
    ///         remaining slots.
    bool private _ossified;

    /// @notice Address authorised to invoke the sweep callbacks
    ///         ({purgeUserState} / {purgeTier3State}). Decoupled from
    ///         {baseRegistration} so a Base proxy swap cannot orphan or
    ///         silently transfer the sweep authority (RT-04 remediation).
    address public sweepAuthority;

    /// @notice Next nonce a trusted KYC provider must sign for a Tier-4
    ///         attestation. Contract-issued, monotonic, per-provider
    ///         (RT-05 remediation) — replaces the free-form global
    ///         `usedNonces` nonce for Tier-4 submits.
    mapping(address => bytes32) public kycProviderNonce;

    /// @notice Storage gap for future upgrades.
    /// @dev Reduced 40 → 38 in this revision to accommodate the
    ///      relocated `_ossified` slot plus `sweepAuthority` (packs with
    ///      `_ossified`) and `kycProviderNonce`. Post-deploy, every
    ///      state-var addition consumes one gap slot.
    uint256[38] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event IDVerified(
        address indexed user, bytes32 indexed idHash,
        string country, uint256 timestamp
    );
    event AddressVerified(
        address indexed user, bytes32 indexed addressHash,
        string country, bytes32 documentType, uint256 timestamp
    );
    event SelfieVerified(
        address indexed user, bytes32 indexed selfieHash,
        uint256 similarity, uint256 timestamp
    );
    event PersonaVerified(
        address indexed user, bytes32 indexed verificationHash, uint256 timestamp
    );
    event AMLCleared(address indexed user, bool cleared, uint256 timestamp);
    event KycTier2Completed(address indexed user, uint256 timestamp);
    event KycTier3Completed(address indexed user, uint256 timestamp);
    event KycTier4Completed(
        address indexed user, address indexed provider, uint256 timestamp
    );
    event AccreditedInvestorCertified(
        address indexed user, uint8 criteria, bool isAccredited, uint256 timestamp
    );
    event KYCProviderAdded(address indexed provider, string name);
    event KYCProviderRemoved(address indexed provider);
    event AttestationGatewaySet(address indexed newGateway);
    event BaseRegistrationSet(address indexed newBase);
    event SweepAuthoritySet(address indexed newAuthority);

    // OMNICORE-DECENT classifier + attribution events (mirror of the
    // library's declarations for ABI exposure on this consumer).
    event AttestationRaceLost(
        address indexed user, bytes32 indexed typehash,
        bytes32 attemptedDigest, bytes32 currentCanonicalDigest
    );
    event AttestationEquivocationAttempt(
        address indexed user, bytes32 indexed typehash,
        bytes32 attemptedDigest, bytes32 attemptedPayloadHash,
        bytes32 currentCanonicalDigest, bytes32 currentCanonicalPayloadHash
    );
    event MisbehaviorRecorded(
        address indexed attester, address indexed subject,
        bytes32 indexed typehash, uint64 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error NotRegistered();
    error AttestationGatewayNotSet();
    error BaseRegistrationNotSet();
    error PreviousTierRequired();
    error IDAlreadyUsed();
    error AddressAlreadyUsed();
    error IDVerificationRequired();
    error InsufficientSimilarity();
    error UntrustedKYCProvider();
    error InvalidKYCProviderSignature();
    error InvalidProvider();
    error ProofExpired();
    error NonceAlreadyUsed();
    error InvalidProviderNonce();
    error UnsupportedTypehash(bytes32 typehash);
    error ContractIsOssified();

    // Mirror of OMNICORE-DECENT errors emitted by the library.
    error InvalidSupersedes(bytes32 expected, bytes32 submitted);
    error NotHistoricalCanonical(bytes32 claimedSupersedes);
    error FirstAttestationRaceImmune();
    error PayloadHashesIdentical();
    error ProofVerificationFailed();
    error NoCommonAttester();
    error AttesterIneligible(address attester, uint256 misbehaviorCount);
    error EvidenceAlreadyRecorded(bytes32 evidenceKey);

    /// @notice Only the bound Base proxy can invoke sweep callbacks.
    /// @dev Audit H-02 / H-03 remediation.
    error CallerNotBaseRegistration();

    /// @notice Address argument must be a deployed contract.
    /// @dev Audit M-02 remediation — mirrors OmniCore's GOV-XSYS-15 setter.
    error RecipientMustBeContract();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract.
     * @param admin             Address granted `DEFAULT_ADMIN_ROLE`.
     * @param baseRegistration_ Live `OmniRegistration` proxy address.
     * @param attestationGateway_ Live `OmniAttestationGateway` proxy address.
     */
    function initialize(
        address admin,
        address baseRegistration_,
        address attestationGateway_
    ) public initializer {
        if (admin == address(0)
            || baseRegistration_ == address(0)
            || attestationGateway_ == address(0)) {
            revert ZeroAddress();
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            ),
            keccak256(bytes("OmniRegistrationKYCTiers")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
        baseRegistration = IOmniRegistrationBase(baseRegistration_);
        attestationGateway = IOmniAttestationGateway(attestationGateway_);
        sweepAuthority = baseRegistration_;
        emit BaseRegistrationSet(baseRegistration_);
        emit AttestationGatewaySet(attestationGateway_);
        emit SweepAuthoritySet(baseRegistration_);
    }

    /// @notice Authorize contract upgrades (UUPSUpgradeable hook).
    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    /**
     * @notice Permanently disable future upgrades by setting the ossification
     *         latch. Irreversible — once called, {_authorizeUpgrade} reverts
     *         forever.
     * @dev Audit M-02 remediation: `_ossified` was declared but never
     *      settable, making the ossification guard non-functional.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  ATTESTATION-GATEWAY + BASE ADMIN SETTERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the attestation gateway. Mirrors Base's hardened setter
     *         (audit M-02 remediation): rejects EOAs, allows explicit
     *         clearing via {clearAttestationGateway}.
     * @param newGateway Address of the new gateway. MUST be a deployed
     *        contract; for emergency shutoff use {clearAttestationGateway}.
     */
    function setAttestationGateway(
        address newGateway
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGateway == address(0)) revert ZeroAddress();
        if (newGateway.code.length == 0) revert RecipientMustBeContract();
        attestationGateway = IOmniAttestationGateway(newGateway);
        emit AttestationGatewaySet(newGateway);
    }

    /**
     * @notice Explicit emergency-shutoff entry point for the attestation
     *         pipeline. Mirrors Base's {clearAttestationGateway}.
     * @dev Audit M-02 remediation. Separating clear from set keeps the
     *      "did the operator mean to disable, or did they typo a zero?"
     *      question unambiguous.
     */
    function clearAttestationGateway() external onlyRole(DEFAULT_ADMIN_ROLE) {
        attestationGateway = IOmniAttestationGateway(address(0));
        emit AttestationGatewaySet(address(0));
    }

    /// @dev When rotating the Base proxy, call {setBaseRegistration} AND
    ///      {setSweepAuthority} in sequence — they are intentionally
    ///      independent (RT-04), so a Base swap alone leaves the sweep
    ///      authority on the prior address until the second call.
    function setBaseRegistration(
        address newBase
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBase == address(0)) revert ZeroAddress();
        if (newBase.code.length == 0) revert RecipientMustBeContract();
        baseRegistration = IOmniRegistrationBase(newBase);
        emit BaseRegistrationSet(newBase);
    }

    /**
     * @notice Set the address authorised to invoke the sweep callbacks
     *         ({purgeUserState} / {purgeTier3State}).
     * @dev RT-04 remediation. Kept independent of {setBaseRegistration} so
     *      rotating the Base proxy (for `bumpKycTier` callbacks) does not
     *      orphan or silently hand over the purge authority. Mirrors the
     *      hardened {setBaseRegistration} checks (rejects EOAs).
     * @param newAuthority Address of the new sweep authority.
     */
    function setSweepAuthority(
        address newAuthority
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAuthority == address(0)) revert ZeroAddress();
        if (newAuthority.code.length == 0) revert RecipientMustBeContract();
        sweepAuthority = newAuthority;
        emit SweepAuthoritySet(newAuthority);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  KYC TIER 2 — ID + ADDRESS + SELFIE
    // ═══════════════════════════════════════════════════════════════════════

    function submitIDVerificationFor(
        address user,
        bytes32 idHash,
        string calldata country,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        if (usedIDHashes[idHash]) revert IDAlreadyUsed();
        if (baseRegistration.kycTier1CompletedAt(user) == 0) {
            revert PreviousTierRequired();
        }
        bytes32 countryHash = keccak256(bytes(country));
        bytes32 structHash = keccak256(abi.encode(
            ID_VERIFICATION_TYPEHASH, user, idHash, countryHash,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(idHash, countryHash));
        _processGate(user, ID_VERIFICATION_TYPEHASH, digest, payloadHash, supersedes);
        _recordCanonical(user, ID_VERIFICATION_TYPEHASH, digest, payloadHash);
        userIDHashes[user] = idHash;
        usedIDHashes[idHash] = true;
        userCountries[user] = country;
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        _checkAndUpdateKycTier2(user);
        emit IDVerified(user, idHash, country, timestamp);
    }

    function submitAddressVerificationFor(
        address user,
        bytes32 addressHash,
        string calldata country,
        bytes32 documentType,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        if (usedAddressHashes[addressHash]) revert AddressAlreadyUsed();
        if (baseRegistration.kycTier1CompletedAt(user) == 0) {
            revert PreviousTierRequired();
        }
        bytes32 countryHash = keccak256(bytes(country));
        bytes32 structHash = keccak256(abi.encode(
            ADDRESS_VERIFICATION_TYPEHASH, user, addressHash, countryHash,
            documentType, supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(addressHash, countryHash, documentType));
        _processGate(user, ADDRESS_VERIFICATION_TYPEHASH, digest, payloadHash, supersedes);
        _recordCanonical(user, ADDRESS_VERIFICATION_TYPEHASH, digest, payloadHash);
        userAddressHashes[user] = addressHash;
        usedAddressHashes[addressHash] = true;
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        _checkAndUpdateKycTier2(user);
        emit AddressVerified(user, addressHash, country, documentType, timestamp);
    }

    function submitSelfieVerificationFor(
        address user,
        bytes32 selfieHash,
        uint256 similarity,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        if (userIDHashes[user] == bytes32(0)) revert IDVerificationRequired();
        if (similarity < MIN_SELFIE_SIMILARITY) revert InsufficientSimilarity();
        bytes32 structHash = keccak256(abi.encode(
            SELFIE_VERIFICATION_TYPEHASH, user, selfieHash, similarity,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(selfieHash, similarity));
        _processGate(user, SELFIE_VERIFICATION_TYPEHASH, digest, payloadHash, supersedes);
        _recordCanonical(user, SELFIE_VERIFICATION_TYPEHASH, digest, payloadHash);
        selfieVerified[user] = true;
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        _checkAndUpdateKycTier2(user);
        emit SelfieVerified(user, selfieHash, similarity, timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  KYC TIER 3 — PERSONA + AML
    // ═══════════════════════════════════════════════════════════════════════

    function submitPersonaVerificationFor(
        address user,
        bytes32 verificationHash,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        if (kycTier2CompletedAt[user] == 0) revert PreviousTierRequired();
        bytes32 structHash = keccak256(abi.encode(
            PERSONA_VERIFICATION_TYPEHASH, user, verificationHash,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        _processGate(
            user, PERSONA_VERIFICATION_TYPEHASH, digest, verificationHash, supersedes
        );
        _recordCanonical(user, PERSONA_VERIFICATION_TYPEHASH, digest, verificationHash);
        personaVerificationHashes[user] = verificationHash;
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        emit PersonaVerified(user, verificationHash, timestamp);
        _checkAndUpdateKycTier3(user);
    }

    function submitAMLClearance(
        address user,
        bool cleared,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        bytes32 structHash = keccak256(abi.encode(
            AML_CLEARANCE_TYPEHASH, user, cleared,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(cleared));
        _processGate(user, AML_CLEARANCE_TYPEHASH, digest, payloadHash, supersedes);
        _recordCanonical(user, AML_CLEARANCE_TYPEHASH, digest, payloadHash);
        amlCleared[user] = cleared;
        amlClearedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
        if (!cleared && kycTier3CompletedAt[user] != 0) {
            kycTier3CompletedAt[user] = 0;
            baseRegistration.bumpKycTier(user, 2);
        }
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        emit AMLCleared(user, cleared, timestamp);
        if (cleared) _checkAndUpdateKycTier3(user);
    }

    function submitAccreditedInvestorCertificationFor(
        address user,
        uint8 criteria,
        bool certified,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // Audit M-01 remediation: every other Tier-2/3/4 submit guards on
        // `_ensureRegistered` first. Don't rely on the transitive Persona
        // gate alone — make this an explicit invariant so future refactors
        // of {submitPersonaVerificationFor} can't accidentally open a
        // bypass on this path.
        _ensureRegistered(user);
        if (personaVerificationHashes[user] == bytes32(0)) revert PreviousTierRequired();
        bytes32 structHash = keccak256(abi.encode(
            ACCREDITED_INVESTOR_TYPEHASH, user, criteria, certified,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = keccak256(abi.encode(criteria, certified));
        _processGate(
            user, ACCREDITED_INVESTOR_TYPEHASH, digest, payloadHash, supersedes
        );
        _recordCanonical(user, ACCREDITED_INVESTOR_TYPEHASH, digest, payloadHash);
        isAccreditedInvestor[user] = certified;
        accreditedInvestorCriteria[user] = criteria;
        accreditedInvestorCertifiedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
        OmniRegistrationDigestLib.requireEligibleAttesters(
            misbehaviorTimestamps, attestationGateway, digest, signature
        );
        _verifyAttestation(user, structHash, nonce, deadline, signature);
        emit AccreditedInvestorCertified(user, criteria, certified, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  KYC TIER 4 — THIRD-PARTY KYC PROVIDER
    // ═══════════════════════════════════════════════════════════════════════

    function submitThirdPartyKYCFor(
        address user,
        address kycProvider,
        bytes32 supersedes,
        uint256 timestamp,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _ensureRegistered(user);
        if (kycTier3CompletedAt[user] == 0) revert PreviousTierRequired();
        bytes32 structHash = keccak256(abi.encode(
            THIRD_PARTY_KYC_TYPEHASH, user, kycProvider,
            supersedes, timestamp, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 payloadHash = bytes32(uint256(uint160(kycProvider)));
        // Eligibility gate intentionally SKIPPED — Tier-4 uses the trusted-
        // provider signature path, not the committee verifier. Misbehavior
        // is handled out of band via {removeKYCProvider}.
        OmniRegistrationDigestLib.checkSupersedesChain(
            currentCanonical, canonicalPayloadHash,
            user, THIRD_PARTY_KYC_TYPEHASH, digest, payloadHash, supersedes
        );
        _verifyKYCProviderAttestation(kycProvider, structHash, nonce, deadline, signature);
        _recordCanonical(user, THIRD_PARTY_KYC_TYPEHASH, digest, payloadHash);
        kycTier4CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
        userKYCProvider[user] = kycProvider;
        baseRegistration.bumpKycTier(user, 4);
        emit KycTier4Completed(user, kycProvider, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    function addKYCProvider(
        address provider,
        string calldata name
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidProvider();
        trustedKYCProviders[provider] = true;
        kycProviderNames[provider] = name;
        emit KYCProviderAdded(provider, name);
    }

    function removeKYCProvider(
        address provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedKYCProviders[provider] = false;
        // Audit L-05 remediation: clear the stored name so off-chain
        // consumers reading `kycProviderNames[provider]` no longer see a
        // valid-looking name for a provider whose `trustedKYCProviders`
        // flag is false. Cosmetic on-chain, but the previous behaviour
        // left stale display data that misleads UI lookups.
        delete kycProviderNames[provider];
        emit KYCProviderRemoved(provider);
    }

    /**
     * @notice Issue / reset the next expected nonce for a trusted KYC
     *         provider (RT-05 remediation).
     * @dev Contract-issued nonce recovery: if a provider's off-chain nonce
     *      counter desynchronizes from on-chain state, the admin can reset
     *      the expectation directly. The next successful {submitThirdPartyKYCFor}
     *      for `provider` must sign exactly this value.
     * @param provider The trusted KYC provider to update.
     * @param nonce The next nonce the provider must sign.
     */
    function setKycProviderNonce(
        address provider,
        bytes32 nonce
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidProvider();
        kycProviderNonce[provider] = nonce;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          CROSS-CONTRACT SWEEP CALLBACKS (Base → KYCTiers)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Clear ALL per-user Tier-2/3/4 state for `user`.
     * @dev Audit H-02 remediation. Invoked exclusively by the bound
     *      `baseRegistration` proxy from its `_unregisterUser` path
     *      (admin unregister / GDPR sweep / batch cleanup). Restoring the
     *      pre-split invariant that all per-user attestation state vanishes
     *      atomically on unregister. Without this callback, KYCTiers would
     *      strand `usedIDHashes` / `usedAddressHashes` (permaban that user's
     *      passport hash for the lifetime of the contract) AND keep
     *      `kycTier{2,3,4}CompletedAt` non-zero — which causes
     *      `_checkAndUpdateKycTier{2,3}` to short-circuit on re-register and
     *      never call back into `bumpKycTier`, leaving Base permanently
     *      stuck on Tier 1 while KYCTiers still reports the old tiers.
     *
     *      `usedIDHashes` and `usedAddressHashes` are cleared per the legacy
     *      Sybil-protection contract — re-registered user is expected to be
     *      able to re-attest the same passport hash (admin unregister is
     *      typically reversal of a deletion or sanctions cleanup, not a
     *      blacklist).
     *
     *      Idempotent: zero-value writes succeed silently so callers don't
     *      need to track which fields are populated.
     * @param user Subject whose state is being purged.
     */
    function purgeUserState(address user) external {
        if (msg.sender != sweepAuthority) {
            revert CallerNotBaseRegistration();
        }
        bytes32 idHash = userIDHashes[user];
        if (idHash != bytes32(0)) {
            usedIDHashes[idHash] = false;
            delete userIDHashes[user];
        }
        bytes32 addrHash = userAddressHashes[user];
        if (addrHash != bytes32(0)) {
            usedAddressHashes[addrHash] = false;
            delete userAddressHashes[user];
        }
        delete userCountries[user];
        delete selfieVerified[user];
        delete kycTier2CompletedAt[user];
        delete personaVerificationHashes[user];
        delete kycTier3CompletedAt[user];
        delete amlCleared[user];
        delete amlClearedAt[user];
        delete isAccreditedInvestor[user];
        delete accreditedInvestorCriteria[user];
        delete accreditedInvestorCertifiedAt[user];
        delete userKYCProvider[user];
        delete kycTier4CompletedAt[user];
    }

    /**
     * @notice Clear Tier-3+ state for `user` (Persona, AML, Tier 3/4
     *         completion timestamps, userKYCProvider).
     * @dev Audit H-03 remediation. Invoked exclusively by the bound
     *      `baseRegistration` proxy from `resetKycTier3` when an admin
     *      sanctions-resets a user. Leaves Tier-2 state in place — caller
     *      semantics match Base's `resetKycTier3`. Without this callback
     *      `hasKycTier3` on KYCTiers stays true, sanctioned users continue
     *      to pass downstream Tier-3 gates, and {submitThirdPartyKYCFor}
     *      can still be invoked because `kycTier3CompletedAt[user] != 0`.
     * @param user Subject whose Tier-3+ state is being cleared.
     */
    function purgeTier3State(address user) external {
        if (msg.sender != sweepAuthority) {
            revert CallerNotBaseRegistration();
        }
        delete personaVerificationHashes[user];
        delete kycTier3CompletedAt[user];
        delete amlCleared[user];
        delete amlClearedAt[user];
        // Tier-4 depends on Tier-3 by construction (see
        // `submitThirdPartyKYCFor` gate), so it must also be cleared.
        delete kycTier4CompletedAt[user];
        delete userKYCProvider[user];
    }

    /**
     * @notice Clear Tier-2-specific state for `user` without touching
     *         Sybil-protection hashes (usedIDHashes / usedAddressHashes).
     * @dev Audit RT-02 remediation. Unlike {purgeUserState} which clears
     *      everything including Sybil-protection hashes, this function
     *      resets only the Tier-2 completion flags so the user can re-attest
     *      without losing their passport-hash slots. Callable by admin for
     *      targeted Tier-2 resets (e.g. re-verification campaigns).
     * @param user Subject whose Tier-2 completion state is being cleared.
     */
    function purgeTier2State(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete selfieVerified[user];
        delete kycTier2CompletedAt[user];
        baseRegistration.bumpKycTier(user, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  OMNICORE-DECENT — recordEquivocation
    // ═══════════════════════════════════════════════════════════════════════

    function recordEquivocation(
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelopeA,
        bytes calldata proofA,
        bytes calldata envelopeB,
        bytes calldata proofB
    ) external nonReentrant {
        // Restrict to typehashes this contract owns — Base owns the rest.
        if (typehash != ID_VERIFICATION_TYPEHASH
            && typehash != ADDRESS_VERIFICATION_TYPEHASH
            && typehash != SELFIE_VERIFICATION_TYPEHASH
            && typehash != PERSONA_VERIFICATION_TYPEHASH
            && typehash != ACCREDITED_INVESTOR_TYPEHASH
            && typehash != AML_CLEARANCE_TYPEHASH
            && typehash != THIRD_PARTY_KYC_TYPEHASH) {
            revert UnsupportedTypehash(typehash);
        }
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

    /// @notice Public view wrapping the library-side window counter.
    function getMisbehaviorCountInWindow(
        address attester,
        uint256 windowSeconds
    ) external view returns (uint256) {
        return OmniRegistrationDigestLib.getMisbehaviorCountInWindow(
            misbehaviorTimestamps, attester, windowSeconds
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function hasKycTier2(address user) external view returns (bool) {
        return kycTier2CompletedAt[user] != 0;
    }

    function hasKycTier3(address user) external view returns (bool) {
        return kycTier3CompletedAt[user] != 0;
    }

    function hasKycTier4(address user) external view returns (bool) {
        return kycTier4CompletedAt[user] != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _ensureRegistered(address user) internal view {
        if (address(baseRegistration) == address(0)) revert BaseRegistrationNotSet();
        if (!baseRegistration.isRegistered(user)) revert NotRegistered();
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _processGate(
        address user,
        bytes32 typehash,
        bytes32 digest,
        bytes32 payloadHash,
        bytes32 supersedes
    ) internal {
        OmniRegistrationDigestLib.checkSupersedesChain(
            currentCanonical, canonicalPayloadHash,
            user, typehash, digest, payloadHash, supersedes
        );
    }

    function _recordCanonical(
        address user, bytes32 typehash,
        bytes32 newDigest, bytes32 newPayloadHash
    ) internal {
        OmniRegistrationDigestLib.recordCanonical(
            currentCanonical, canonicalPayloadHash, wasEverCanonical,
            user, typehash, newDigest, newPayloadHash
        );
    }

    function _verifyAttestation(
        address user,
        bytes32 structHash,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata proof
    ) internal {
        IOmniAttestationGateway gw = attestationGateway;
        if (address(gw) == address(0)) revert AttestationGatewayNotSet();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        gw.verifyAndConsume(user, digest, nonce, deadline, proof);
    }

    function _verifyKYCProviderAttestation(
        address provider,
        bytes32 structHash,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (!trustedKYCProviders[provider]) revert UntrustedKYCProvider();
        if (block.timestamp > deadline) revert ProofExpired(); // solhint-disable-line not-rely-on-time
        if (nonce != kycProviderNonce[provider]) revert InvalidProviderNonce();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (digest.recover(signature) != provider) {
            revert InvalidKYCProviderSignature();
        }
        kycProviderNonce[provider] = bytes32(uint256(nonce) + 1);
    }

    function _checkAndUpdateKycTier2(address user) internal {
        if (kycTier2CompletedAt[user] != 0) return;
        if (userIDHashes[user] == bytes32(0)) return;
        if (userAddressHashes[user] == bytes32(0)) return;
        if (!selfieVerified[user]) return;
        kycTier2CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
        baseRegistration.bumpKycTier(user, 2);
        emit KycTier2Completed(user, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    function _checkAndUpdateKycTier3(address user) internal {
        if (kycTier3CompletedAt[user] != 0) return;
        if (personaVerificationHashes[user] == bytes32(0)) return;
        if (!amlCleared[user]) return;
        kycTier3CompletedAt[user] = block.timestamp; // solhint-disable-line not-rely-on-time
        baseRegistration.bumpKycTier(user, 3);
        emit KycTier3Completed(user, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  ERC2771 + AccessControl glue
    // ═══════════════════════════════════════════════════════════════════════

    function _msgSender()
        internal view override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal view override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal view override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
