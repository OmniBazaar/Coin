// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title UpdateRegistry
 * @author OmniBazaar Development Team
 * @notice On-chain registry for ODDAO-approved software releases.
 *         Validators and client applications query this contract to discover
 *         approved software versions and enforce minimum version requirements.
 * @dev This contract is deployed on OmniCoin L1 (chain 131313). It serves as the
 *      single source of truth for software update authentication. Releases require
 *      multi-sig approval from ODDAO members (M-of-N threshold).
 *
 *      Architecture:
 *      - ODDAO members sign release manifests off-chain
 *      - Any RELEASE_MANAGER submits the manifest + signatures to this contract
 *      - Contract verifies M-of-N valid signatures before accepting a release
 *      - Validators poll this contract (or subscribe to events) for updates
 *      - Minimum version enforcement prevents outdated nodes from operating
 *
 *      Component identifiers (string keys):
 *      - "validator"        = Gateway validator (TypeScript + avalanchego)
 *      - "service-node"     = Service node (TypeScript only)
 *      - "wallet-extension" = Browser extension wallet
 *      - "mobile-app"       = iOS/Android mobile application
 *      - "webapp"           = React web application bundle
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract UpdateRegistry is AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============================================================
    //                    TYPE DECLARATIONS
    // ============================================================

    /**
     * @notice Release information stored on-chain for each published version
     * @dev Struct layout optimized for storage packing:
     *      Slot 1: publishedAt (32 bytes)
     *      Slot 2: binaryHash (32 bytes)
     *      Slot 3: publishedBy (20) + revoked (1) = 21 bytes
     *      Remaining: string pointers (32 bytes each)
     * @param version Semantic version string (e.g., "1.2.0")
     * @param binaryHash SHA-256 hash of the release artifact
     * @param minimumVersion Minimum version nodes must run after this release
     * @param publishedAt Block timestamp when the release was published
     * @param publishedBy Address that submitted the release transaction
     * @param revoked Whether this release has been revoked
     * @param revokeReason Reason for revocation (empty if not revoked)
     * @param changelogCID IPFS CID of the changelog document (optional)
     */
    struct ReleaseInfo {
        // Slot 1
        uint256 publishedAt;
        // Slot 2
        bytes32 binaryHash;
        // Slot 3: packed (21 bytes)
        address publishedBy;
        bool revoked;
        // String pointers
        string version;
        string minimumVersion;
        string revokeReason;
        string changelogCID;
    }

    // ============================================================
    //                    CONSTANTS
    // ============================================================

    /// @notice Role for addresses allowed to submit releases (with valid signatures)
    bytes32 public constant RELEASE_MANAGER_ROLE = keccak256("RELEASE_MANAGER_ROLE");

    /// @notice Maximum number of ODDAO signers allowed
    uint256 public constant MAX_SIGNERS = 20;

    /// @notice Maximum version string length (prevents storage abuse)
    uint256 public constant MAX_VERSION_LENGTH = 32;

    /// @notice Maximum changelog CID length
    uint256 public constant MAX_CID_LENGTH = 128;

    /// @notice Maximum revoke reason length
    uint256 public constant MAX_REASON_LENGTH = 256;

    // ============================================================
    //                    STATE VARIABLES
    // ============================================================

    /// @notice Ordered list of authorized ODDAO signer addresses
    address[] public signers;

    /// @notice Number of signatures required to approve a release
    uint256 public signerThreshold;

    /// @notice Quick lookup for signer membership
    mapping(address => bool) public isSigner;

    /// @notice Release details: component => version hash => ReleaseInfo
    mapping(bytes32 => mapping(bytes32 => ReleaseInfo)) public releases;

    /// @notice Latest version string per component: component hash => version string
    mapping(bytes32 => string) public latestVersion;

    /// @notice Minimum required version per component: component hash => version string
    mapping(bytes32 => string) public minimumVersion;

    /// @notice Total releases published per component (for enumeration)
    mapping(bytes32 => uint256) public releaseCount;

    /// @notice Monotonically increasing nonce included in all signed messages (M-01 replay protection)
    uint256 public operationNonce;

    /// @notice Version history per component (ordered): component hash => index => version hash
    mapping(bytes32 => mapping(uint256 => bytes32)) public versionHistory;

    /// @notice Index of the current latestVersion in versionHistory (M-02 prevents regression)
    mapping(bytes32 => uint256) public latestReleaseIndex;

    // ============================================================
    //                    EVENTS
    // ============================================================

    /**
     * @notice Emitted when a new release is published
     * @param component Component identifier (e.g., "validator")
     * @param version Semantic version string
     * @param binaryHash SHA-256 hash of the release artifact
     * @param minimumVersion New minimum version requirement
     */
    event ReleasePublished(
        string indexed component,
        string version,
        bytes32 indexed binaryHash,
        string minimumVersion
    );

    /**
     * @notice Emitted when a release is revoked
     * @param component Component identifier
     * @param version Version that was revoked
     * @param reason Reason for revocation
     */
    event ReleaseRevoked(
        string indexed component,
        string version,
        string reason
    );

    /**
     * @notice Emitted when the minimum version is updated directly
     * @param component Component identifier
     * @param version New minimum version
     */
    event MinimumVersionUpdated(
        string indexed component,
        string version
    );

    /**
     * @notice Emitted when the ODDAO signer set is changed
     * @param newSignerCount Number of signers in the new set
     * @param newThreshold New signature threshold
     */
    event SignerSetUpdated(
        uint256 indexed newSignerCount,
        uint256 indexed newThreshold
    );

    // ============================================================
    //                    CUSTOM ERRORS
    // ============================================================

    /// @notice Not enough valid signatures provided
    error InsufficientSignatures(uint256 required, uint256 provided);

    /// @notice Recovered signer is not in the authorized set
    error InvalidSignature(address recovered);

    /// @notice Version already published for this component
    error DuplicateVersion(string component, string version);

    /// @notice Version not found for this component
    error VersionNotFound(string component, string version);

    /// @notice Version already revoked
    error VersionAlreadyRevoked(string component, string version);

    /// @notice Invalid threshold for the given signer count
    error InvalidThreshold(uint256 threshold, uint256 signerCount);

    /// @notice Empty version string provided
    error EmptyVersion();

    /// @notice Empty binary hash provided
    error EmptyBinaryHash();

    /// @notice Empty component string provided
    error EmptyComponent();

    /// @notice String exceeds maximum allowed length
    error StringTooLong(uint256 length, uint256 maxLength);

    /// @notice Duplicate signer in the provided set
    error DuplicateSigner(address signer);

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Signature includes a stale nonce (replay protection)
    /// @param expected The current nonce that signatures must include
    /// @param provided The nonce included in the signatures
    error StaleNonce(uint256 expected, uint256 provided);

    // ============================================================
    //                    CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initializes the UpdateRegistry with ODDAO signers
     * @dev Grants DEFAULT_ADMIN_ROLE and RELEASE_MANAGER_ROLE to the deployer.
     *      Sets the initial signer set and threshold for multi-sig verification.
     * @param _signers Array of ODDAO signer addresses (must not contain duplicates or zero)
     * @param _threshold Number of signatures required (must be > 0 and <= signers.length)
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address[] memory _signers, uint256 _threshold) {
        _validateSignerSet(_signers, _threshold);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELEASE_MANAGER_ROLE, msg.sender);

        for (uint256 i = 0; i < _signers.length; ++i) {
            signers.push(_signers[i]);
            isSigner[_signers[i]] = true;
        }
        signerThreshold = _threshold;

        emit SignerSetUpdated(_signers.length, _threshold);
    }

    // ============================================================
    //                    RELEASE MANAGEMENT
    // ============================================================

    /**
     * @notice Publish a new software release with ODDAO multi-sig approval
     * @dev The caller must have RELEASE_MANAGER_ROLE. Signatures are verified
     *      against the authorized signer set. The signed message includes chain ID,
     *      contract address, and operationNonce to prevent replay attacks.
     *
     *      Signers sign: keccak256(abi.encode(
     *          "PUBLISH_RELEASE", component, version, binaryHash, minVersion,
     *          nonce, block.chainid, address(this)
     *      ))
     *
     *      M-02: latestVersion is only updated when the new release's index
     *      exceeds the current latest index, preventing regression if an older
     *      version is published after a newer one.
     *
     * @param component Component identifier (e.g., "validator")
     * @param version Semantic version string (e.g., "1.2.0")
     * @param binaryHash SHA-256 hash of the release artifact
     * @param minVersion Minimum version nodes must run after this release
     * @param changelogCID IPFS CID of the changelog (empty string if none)
     * @param nonce Must match current operationNonce (replay protection)
     * @param signatures Array of ECDSA signatures from ODDAO members
     */
    function publishRelease(
        string calldata component,
        string calldata version,
        bytes32 binaryHash,
        string calldata minVersion,
        string calldata changelogCID,
        uint256 nonce,
        bytes[] calldata signatures
    ) external onlyRole(RELEASE_MANAGER_ROLE) {
        _validateReleaseInputs(component, version, binaryHash, minVersion, changelogCID);

        bytes32 componentHash = keccak256(bytes(component));
        bytes32 versionHash = keccak256(bytes(version));

        // Check for duplicate version
        if (releases[componentHash][versionHash].publishedAt != 0) {
            revert DuplicateVersion(component, version);
        }

        // Verify ODDAO signatures (includes nonce check)
        _verifySignatures(component, version, binaryHash, minVersion, nonce, signatures);

        // Consume the nonce (M-01: prevents replay of this exact signature set)
        ++operationNonce;

        // Store the release
        releases[componentHash][versionHash] = ReleaseInfo({
            publishedAt: block.timestamp, // solhint-disable-line not-rely-on-time
            binaryHash: binaryHash,
            publishedBy: msg.sender,
            revoked: false,
            version: version,
            minimumVersion: minVersion,
            revokeReason: "",
            changelogCID: changelogCID
        });

        // Record in version history
        uint256 idx = releaseCount[componentHash];
        versionHistory[componentHash][idx] = versionHash;
        releaseCount[componentHash] = idx + 1;

        // M-02: Only update latestVersion if this release is newer (higher index)
        // than the current latest. Prevents regression when publishing an older
        // version after a newer one. >= needed so the first release (idx=0) is captured.
        // solhint-disable-next-line gas-strict-inequalities
        if (idx >= latestReleaseIndex[componentHash]) {
            latestVersion[componentHash] = version;
            latestReleaseIndex[componentHash] = idx;
        }

        // Update minimum version if provided
        if (bytes(minVersion).length > 0) {
            minimumVersion[componentHash] = minVersion;
        }

        emit ReleasePublished(component, version, binaryHash, minVersion);
    }

    /**
     * @notice Revoke a previously published release
     * @dev Requires ODDAO multi-sig approval (same threshold as publishing).
     *      Revoked versions trigger mandatory update warnings on nodes running them.
     *      Includes operationNonce in the signed message to prevent replay (M-01).
     * @param component Component identifier
     * @param version Version to revoke
     * @param reason Reason for revocation (e.g., "CVE-2026-XXXX")
     * @param nonce Must match current operationNonce (replay protection)
     * @param signatures Array of ECDSA signatures from ODDAO members
     */
    function revokeRelease(
        string calldata component,
        string calldata version,
        string calldata reason,
        uint256 nonce,
        bytes[] calldata signatures
    ) external onlyRole(RELEASE_MANAGER_ROLE) {
        if (bytes(component).length == 0) revert EmptyComponent();
        if (bytes(version).length == 0) revert EmptyVersion();
        if (bytes(reason).length > MAX_REASON_LENGTH) {
            revert StringTooLong(bytes(reason).length, MAX_REASON_LENGTH);
        }
        if (nonce != operationNonce) {
            revert StaleNonce(operationNonce, nonce);
        }

        bytes32 componentHash = keccak256(bytes(component));
        bytes32 versionHash = keccak256(bytes(version));

        ReleaseInfo storage release = releases[componentHash][versionHash];
        if (release.publishedAt == 0) revert VersionNotFound(component, version);
        if (release.revoked) revert VersionAlreadyRevoked(component, version);

        // For revocation, signers sign: keccak256(abi.encode(
        //     "REVOKE", component, version, reason, nonce, block.chainid, address(this)
        // ))
        bytes32 messageHash = keccak256(
            abi.encode(
                "REVOKE", component, version, reason, nonce, block.chainid, address(this)
            )
        );
        _verifyMessageSignatures(messageHash, signatures);

        // Consume the nonce
        ++operationNonce;

        release.revoked = true;
        release.revokeReason = reason;

        emit ReleaseRevoked(component, version, reason);
    }

    /**
     * @notice Set minimum version directly (admin override)
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Use for emergency version enforcement
     *      without publishing a new release. Requires ODDAO multi-sig.
     *      Includes operationNonce in the signed message to prevent replay (M-01).
     * @param component Component identifier
     * @param version New minimum version requirement
     * @param nonce Must match current operationNonce (replay protection)
     * @param signatures Array of ECDSA signatures from ODDAO members
     */
    function setMinimumVersion(
        string calldata component,
        string calldata version,
        uint256 nonce,
        bytes[] calldata signatures
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(component).length == 0) revert EmptyComponent();
        if (bytes(version).length == 0) revert EmptyVersion();
        if (bytes(version).length > MAX_VERSION_LENGTH) {
            revert StringTooLong(bytes(version).length, MAX_VERSION_LENGTH);
        }
        if (nonce != operationNonce) {
            revert StaleNonce(operationNonce, nonce);
        }

        // Signers sign: keccak256(abi.encode(
        //     "MIN_VERSION", component, version, nonce, block.chainid, address(this)
        // ))
        bytes32 messageHash = keccak256(
            abi.encode(
                "MIN_VERSION", component, version, nonce, block.chainid, address(this)
            )
        );
        _verifyMessageSignatures(messageHash, signatures);

        // Consume the nonce
        ++operationNonce;

        bytes32 componentHash = keccak256(bytes(component));
        minimumVersion[componentHash] = version;

        emit MinimumVersionUpdated(component, version);
    }

    // ============================================================
    //                    SIGNER MANAGEMENT
    // ============================================================

    /**
     * @notice Update the ODDAO signer set and threshold
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Requires signatures from the
     *      CURRENT signer set (using current threshold + 1 for higher security).
     *      This prevents a single compromised admin from replacing all signers.
     *      Includes operationNonce in the signed message to prevent replay (M-01).
     * @param newSigners New array of signer addresses
     * @param newThreshold New signature threshold
     * @param nonce Must match current operationNonce (replay protection)
     * @param signatures Signatures from current signers authorizing this change
     */
    function updateSignerSet(
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce,
        bytes[] calldata signatures
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateSignerSet(newSigners, newThreshold);

        if (nonce != operationNonce) {
            revert StaleNonce(operationNonce, nonce);
        }

        // Require threshold+1 sigs if possible, otherwise all signers (higher bar for rotation)
        uint256 requiredSigs = signers.length > signerThreshold
            ? signerThreshold + 1
            : signers.length;

        // Signers sign: keccak256(abi.encode(
        //     "UPDATE_SIGNERS", keccak256(abi.encode(newSigners)), newThreshold,
        //     nonce, block.chainid, address(this)
        // ))
        bytes32 messageHash = keccak256(
            abi.encode(
                "UPDATE_SIGNERS",
                keccak256(abi.encode(newSigners)),
                newThreshold,
                nonce,
                block.chainid,
                address(this)
            )
        );

        // Verify with elevated threshold
        _verifyMessageSignaturesWithThreshold(messageHash, signatures, requiredSigs);

        // Consume the nonce
        ++operationNonce;

        // Clear old signer set
        for (uint256 i = 0; i < signers.length; ++i) {
            isSigner[signers[i]] = false;
        }
        delete signers;

        // Set new signer set
        for (uint256 i = 0; i < newSigners.length; ++i) {
            signers.push(newSigners[i]);
            isSigner[newSigners[i]] = true;
        }
        signerThreshold = newThreshold;

        emit SignerSetUpdated(newSigners.length, newThreshold);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get the latest release for a component
     * @param component Component identifier (e.g., "validator")
     * @return info Complete release information
     */
    function getLatestRelease(
        string calldata component
    ) external view returns (ReleaseInfo memory info) {
        bytes32 componentHash = keccak256(bytes(component));
        string memory latest = latestVersion[componentHash];
        if (bytes(latest).length == 0) revert VersionNotFound(component, "");
        bytes32 versionHash = keccak256(bytes(latest));
        return releases[componentHash][versionHash];
    }

    /**
     * @notice Get release info for a specific version
     * @param component Component identifier
     * @param version Version string to look up
     * @return info Complete release information
     */
    function getRelease(
        string calldata component,
        string calldata version
    ) external view returns (ReleaseInfo memory info) {
        bytes32 componentHash = keccak256(bytes(component));
        bytes32 versionHash = keccak256(bytes(version));
        if (releases[componentHash][versionHash].publishedAt == 0) {
            revert VersionNotFound(component, version);
        }
        return releases[componentHash][versionHash];
    }

    /**
     * @notice Get the minimum required version for a component
     * @param component Component identifier
     * @return version Minimum version string (empty if none set)
     */
    function getMinimumVersion(
        string calldata component
    ) external view returns (string memory version) {
        bytes32 componentHash = keccak256(bytes(component));
        return minimumVersion[componentHash];
    }

    /**
     * @notice Get the latest version string for a component
     * @param component Component identifier
     * @return version Latest version string (empty if no releases)
     */
    function getLatestVersion(
        string calldata component
    ) external view returns (string memory version) {
        bytes32 componentHash = keccak256(bytes(component));
        return latestVersion[componentHash];
    }

    /**
     * @notice Check whether a specific version has been revoked
     * @param component Component identifier
     * @param version Version to check
     * @return revoked True if the version exists and is revoked
     */
    function isVersionRevoked(
        string calldata component,
        string calldata version
    ) external view returns (bool revoked) {
        bytes32 componentHash = keccak256(bytes(component));
        bytes32 versionHash = keccak256(bytes(version));
        ReleaseInfo storage release = releases[componentHash][versionHash];
        if (release.publishedAt == 0) return false;
        return release.revoked;
    }

    /**
     * @notice Get the full list of authorized signers
     * @return signerList Array of signer addresses
     */
    function getSigners() external view returns (address[] memory signerList) {
        return signers;
    }

    /**
     * @notice Get the current signature threshold
     * @return threshold Number of required signatures
     */
    function getSignerThreshold() external view returns (uint256 threshold) {
        return signerThreshold;
    }

    /**
     * @notice Get the total number of releases for a component
     * @param component Component identifier
     * @return count Total number of releases published
     */
    function getReleaseCount(
        string calldata component
    ) external view returns (uint256 count) {
        bytes32 componentHash = keccak256(bytes(component));
        return releaseCount[componentHash];
    }

    /**
     * @notice Get a release by index in the version history
     * @param component Component identifier
     * @param index Zero-based index in the version history
     * @return info Release information at that index
     */
    function getReleaseByIndex(
        string calldata component,
        uint256 index
    ) external view returns (ReleaseInfo memory info) {
        bytes32 componentHash = keccak256(bytes(component));
        if (releaseCount[componentHash] == 0 || index > releaseCount[componentHash] - 1) {
            revert VersionNotFound(component, "index out of range");
        }
        bytes32 versionHash = versionHistory[componentHash][index];
        return releases[componentHash][versionHash];
    }

    /**
     * @notice Verify a release exists and is not revoked
     * @param component Component identifier
     * @param version Version to verify
     * @return valid True if release exists and is not revoked
     */
    function verifyRelease(
        string calldata component,
        string calldata version
    ) external view returns (bool valid) {
        bytes32 componentHash = keccak256(bytes(component));
        bytes32 versionHash = keccak256(bytes(version));
        ReleaseInfo storage release = releases[componentHash][versionHash];
        return release.publishedAt != 0 && !release.revoked;
    }

    /**
     * @notice Compute the message hash that signers must sign for a release
     * @dev Useful for off-chain signing tools to construct the correct message.
     *      Includes the nonce parameter for replay protection (M-01).
     * @param component Component identifier
     * @param version Version string
     * @param binaryHash SHA-256 hash of the binary
     * @param minVersion Minimum version string
     * @param nonce Operation nonce (should be current operationNonce)
     * @return hash The keccak256 hash to be signed
     */
    function computeReleaseHash(
        string calldata component,
        string calldata version,
        bytes32 binaryHash,
        string calldata minVersion,
        uint256 nonce
    ) external view returns (bytes32 hash) {
        return keccak256(
            abi.encode(
                "PUBLISH_RELEASE",
                component,
                version,
                binaryHash,
                minVersion,
                nonce,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Compute the message hash that signers must sign for a signer set update
     * @dev Useful for off-chain signing tools to construct the correct message.
     *      The hash includes keccak256 of the packed new signer addresses.
     *      Includes nonce for replay protection (M-01).
     * @param newSigners New array of signer addresses
     * @param newThreshold New signature threshold
     * @param nonce Operation nonce (should be current operationNonce)
     * @return hash The keccak256 hash to be signed
     */
    function computeSignerUpdateHash(
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce
    ) external view returns (bytes32 hash) {
        return keccak256(
            abi.encode(
                "UPDATE_SIGNERS",
                keccak256(abi.encode(newSigners)),
                newThreshold,
                nonce,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Get the current operation nonce
     * @dev Useful for off-chain signing tools to include the correct nonce
     * @return nonce The current operation nonce
     */
    function getOperationNonce() external view returns (uint256 nonce) {
        return operationNonce;
    }

    // ============================================================
    //                    INTERNAL VIEW HELPERS
    // ============================================================

    /**
     * @notice Verify ODDAO signatures for a release publication
     * @dev Includes operationNonce in the signed message to prevent replay
     * @param component Component identifier
     * @param version Version string
     * @param binaryHash Binary SHA-256 hash
     * @param minVersion Minimum version
     * @param nonce Expected operation nonce (must match current operationNonce)
     * @param signatures Array of ECDSA signatures
     */
    function _verifySignatures(
        string calldata component,
        string calldata version,
        bytes32 binaryHash,
        string calldata minVersion,
        uint256 nonce,
        bytes[] calldata signatures
    ) internal view {
        if (nonce != operationNonce) {
            revert StaleNonce(operationNonce, nonce);
        }
        bytes32 messageHash = keccak256(
            abi.encode(
                "PUBLISH_RELEASE",
                component,
                version,
                binaryHash,
                minVersion,
                nonce,
                block.chainid,
                address(this)
            )
        );
        _verifyMessageSignatures(messageHash, signatures);
    }

    /**
     * @notice Verify signatures against a pre-computed message hash
     * @dev Uses the default signerThreshold
     * @param messageHash The hash that was signed
     * @param signatures Array of ECDSA signatures
     */
    function _verifyMessageSignatures(
        bytes32 messageHash,
        bytes[] calldata signatures
    ) internal view {
        _verifyMessageSignaturesWithThreshold(messageHash, signatures, signerThreshold);
    }

    /**
     * @notice Verify signatures with a specific threshold
     * @dev Each signature must recover to a unique authorized signer.
     *      Duplicate signers are rejected (prevents one key from being used N times).
     * @param messageHash The hash that was signed
     * @param signatures Array of ECDSA signatures
     * @param threshold Required number of valid signatures
     */
    function _verifyMessageSignaturesWithThreshold(
        bytes32 messageHash,
        bytes[] calldata signatures,
        uint256 threshold
    ) internal view {
        if (signatures.length < threshold) {
            revert InsufficientSignatures(threshold, signatures.length);
        }

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        uint256 validCount = 0;

        // Track which signers have been seen (prevent duplicate signatures)
        // Using a bitmap for gas efficiency (supports up to 256 signers, well above MAX_SIGNERS)
        uint256 seenBitmap = 0;

        for (uint256 i = 0; i < signatures.length && validCount < threshold; ++i) {
            address recovered = ethSignedHash.recover(signatures[i]);

            if (!isSigner[recovered]) {
                revert InvalidSignature(recovered);
            }

            // Find signer index for bitmap
            uint256 signerIdx = _getSignerIndex(recovered);
            uint256 bit = 1 << signerIdx;

            // Skip if this signer already used
            if ((seenBitmap & bit) != 0) continue;
            seenBitmap |= bit;

            ++validCount;
        }

        if (validCount < threshold) {
            revert InsufficientSignatures(threshold, validCount);
        }
    }

    /**
     * @notice Get the index of a signer in the signers array
     * @param signer Address to find
     * @return idx Index in the signers array
     */
    function _getSignerIndex(address signer) internal view returns (uint256 idx) {
        for (uint256 i = 0; i < signers.length; ++i) {
            if (signers[i] == signer) return i;
        }
        // Should not reach here if isSigner check passed
        revert InvalidSignature(signer);
    }

    // ============================================================
    //                    INTERNAL PURE HELPERS
    // ============================================================

    /**
     * @notice Validate release input parameters
     * @param component Component identifier
     * @param version Semantic version string
     * @param binaryHash SHA-256 hash of the binary
     * @param minVersion Minimum version string
     * @param changelogCID IPFS CID of the changelog
     */
    function _validateReleaseInputs(
        string calldata component,
        string calldata version,
        bytes32 binaryHash,
        string calldata minVersion,
        string calldata changelogCID
    ) internal pure {
        if (bytes(component).length == 0) revert EmptyComponent();
        if (bytes(version).length == 0) revert EmptyVersion();
        if (binaryHash == bytes32(0)) revert EmptyBinaryHash();
        if (bytes(version).length > MAX_VERSION_LENGTH) {
            revert StringTooLong(bytes(version).length, MAX_VERSION_LENGTH);
        }
        if (bytes(minVersion).length > MAX_VERSION_LENGTH) {
            revert StringTooLong(bytes(minVersion).length, MAX_VERSION_LENGTH);
        }
        if (bytes(changelogCID).length > MAX_CID_LENGTH) {
            revert StringTooLong(bytes(changelogCID).length, MAX_CID_LENGTH);
        }
    }

    /**
     * @notice Validate a signer set and threshold
     * @param _signers Array of signer addresses to validate
     * @param _threshold Signature threshold to validate
     */
    function _validateSignerSet(
        address[] memory _signers,
        uint256 _threshold
    ) internal pure {
        if (_signers.length == 0 || _signers.length > MAX_SIGNERS) {
            revert InvalidThreshold(_threshold, _signers.length);
        }
        if (_threshold == 0 || _threshold > _signers.length) {
            revert InvalidThreshold(_threshold, _signers.length);
        }

        // Check for zero addresses and duplicates
        for (uint256 i = 0; i < _signers.length; ++i) {
            if (_signers[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < _signers.length; ++j) {
                if (_signers[i] == _signers[j]) revert DuplicateSigner(_signers[i]);
            }
        }
    }
}
