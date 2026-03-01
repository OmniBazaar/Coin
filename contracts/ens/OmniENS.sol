// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Name is already taken
error NameTaken(string name);

/// @notice Name does not exist or has expired
error NameNotFound(string name);

/// @notice Caller is not the name owner
error NotNameOwner();

/// @notice Name length is invalid (3-32 chars)
error InvalidNameLength(uint256 length);

/// @notice Name contains invalid characters
error InvalidNameCharacter();

/// @notice Duration is below minimum (30 days)
error DurationTooShort(uint256 provided, uint256 minimum);

/// @notice Duration exceeds maximum (365 days)
error DurationTooLong(uint256 provided, uint256 maximum);

/// @notice Address is zero
error ZeroAddress();

/// @notice Registration fee transfer failed
error FeeTransferFailed();

/// @notice Name has not expired yet (cannot re-register)
error NameNotExpired(string name, uint256 expiresAt);

/// @notice No commitment found for this registration
/// @dev H-01 audit fix: commit-reveal scheme
error NoCommitment();

/// @notice Commitment was made too recently
/// @dev H-01 audit fix: must wait MIN_COMMITMENT_AGE
error CommitmentTooNew();

/// @notice Commitment has expired
/// @dev H-01 audit fix: must register within MAX_COMMITMENT_AGE
error CommitmentExpired();

/// @notice Registration fee is outside allowed bounds
/// @dev L-03 audit fix: fee bounds validation
error FeeOutOfBounds();

/**
 * @title OmniENS
 * @author OmniBazaar Team
 * @notice Trustless username registry for OmniBazaar
 *
 * @dev Lightweight, non-upgradeable contract for mapping human-readable
 *      usernames to wallet addresses. Prevents validator manipulation
 *      of username assignments.
 *
 * Features:
 * - Register username: lock to msg.sender for duration (30-365 days)
 * - Commit-reveal: prevents front-running of name registration
 * - Transfer: current owner can transfer to another address
 * - Renew: extend before or after expiry
 * - Resolve: lookup owner by name
 * - Reverse resolve: lookup name by owner
 * - Auto-expiry: names released after expiry
 * - Registration fee: 10 XOM/year (anti-spam, sent to ODDAO)
 * - Name rules: 3-32 chars, alphanumeric + hyphens, lowercase
 *
 * Security:
 * - Non-upgradeable (immutable once deployed)
 * - Ownable2Step prevents accidental ownership loss (L-02)
 * - ReentrancyGuard on all state changes
 * - Only owner can transfer/renew their names
 * - Commit-reveal scheme prevents front-running (H-01)
 * - Registration fee bounded (L-03)
 * - CEI pattern enforced (L-04)
 * - Constructor zero-address validation (M-02)
 * - Renewal fee based on actual duration after cap (M-01)
 *
 * Audit Fixes (2026-02-28 Round 4):
 * - H-01: Commit-reveal scheme for registration
 * - M-01: Fee overcharge on capped renewal duration
 * - M-02: Constructor zero-address validation
 * - M-03: Reverse record overwrite event
 * - L-01: _nameHash NatSpec corrected
 * - L-02: Ownable2Step for safe ownership transfer
 * - L-03: Registration fee bounds validation
 * - L-04: CEI pattern in register() and renew()
 */
contract OmniENS is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                        TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Registration record
    struct Registration {
        address owner;
        uint256 registeredAt;
        uint256 expiresAt;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Minimum name length
    uint256 public constant MIN_NAME_LENGTH = 3;

    /// @notice Maximum name length
    uint256 public constant MAX_NAME_LENGTH = 32;

    /// @notice Minimum registration duration (30 days)
    uint256 public constant MIN_DURATION = 30 days;

    /// @notice Maximum registration duration (365 days)
    uint256 public constant MAX_DURATION = 365 days;

    /// @notice Minimum time between commit and reveal (1 minute)
    /// @dev H-01 audit fix: prevents same-block front-running
    uint256 public constant MIN_COMMITMENT_AGE = 1 minutes;

    /// @notice Maximum time a commitment remains valid (24 hours)
    /// @dev H-01 audit fix: prevents stale commitments from
    ///      being used long after market conditions change
    uint256 public constant MAX_COMMITMENT_AGE = 24 hours;

    /// @notice Minimum registration fee per year (1 XOM)
    /// @dev L-03 audit fix: prevents fee being set too low
    uint256 public constant MIN_REGISTRATION_FEE = 1 ether;

    /// @notice Maximum registration fee per year (1000 XOM)
    /// @dev L-03 audit fix: prevents excessive fee extraction
    uint256 public constant MAX_REGISTRATION_FEE = 1000 ether;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /* solhint-disable immutable-vars-naming */
    /// @notice XOM token for registration fees
    IERC20 public immutable xomToken;

    /// @notice ODDAO treasury (receives registration fees)
    address public immutable oddaoTreasury;
    /* solhint-enable immutable-vars-naming */

    /// @notice Annual registration fee in XOM (18 decimals)
    uint256 public registrationFeePerYear;

    /// @notice Name to registration mapping (lowercase name hash)
    mapping(bytes32 => Registration) public registrations;

    /// @notice Address to name mapping (reverse lookup)
    mapping(address => bytes32) public reverseRecords;

    /// @notice Name hash to original string (for reverse resolve)
    mapping(bytes32 => string) public nameStrings;

    /// @notice Total registered names (including expired)
    uint256 public totalRegistrations;

    /// @notice Commitment hash to timestamp for commit-reveal
    /// @dev H-01 audit fix: maps keccak256(name, owner, secret)
    ///      to the block.timestamp when commit() was called
    mapping(bytes32 => uint256) public commitments;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a name is registered
    /// @param name Username that was registered
    /// @param owner Address that owns the name
    /// @param expiresAt Timestamp when registration expires
    /// @param fee XOM fee paid for registration
    event NameRegistered(
        string name,
        address indexed owner,
        uint256 indexed expiresAt,
        uint256 indexed fee
    );

    /// @notice Emitted when a name is transferred
    /// @param name Username that was transferred
    /// @param from Previous owner address
    /// @param to New owner address
    event NameTransferred(
        string name,
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when a name is renewed
    /// @param name Username that was renewed
    /// @param owner Address that owns the name
    /// @param newExpiry New expiration timestamp
    event NameRenewed(
        string name,
        address indexed owner,
        uint256 indexed newExpiry
    );

    /// @notice Emitted when registration fee is updated
    /// @param oldFee Previous annual fee
    /// @param newFee New annual fee
    event RegistrationFeeUpdated(
        uint256 indexed oldFee,
        uint256 indexed newFee
    );

    /// @notice Emitted when a commitment is made
    /// @dev H-01 audit fix: commit-reveal scheme
    /// @param commitment Hash of (name, owner, secret)
    /// @param sender Address that made the commitment
    event NameCommitted(
        bytes32 indexed commitment,
        address indexed sender
    );

    /// @notice Emitted when a reverse record is overwritten
    /// @dev M-03 audit fix: alerts when an active reverse record
    ///      is replaced by a new registration
    /// @param owner Address whose reverse record changed
    /// @param oldNameHash Previous name hash
    /// @param newNameHash New name hash
    event ReverseRecordOverwritten(
        address indexed owner,
        bytes32 indexed oldNameHash,
        bytes32 indexed newNameHash
    );

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the ENS registry
     * @dev M-02 audit fix: validates both addresses are non-zero.
     *      L-02 audit fix: uses Ownable2Step for safe ownership
     *      transfer (prevents accidental loss via typo).
     * @param _xomToken XOM token address
     * @param _oddaoTreasury ODDAO treasury address
     */
    constructor(
        address _xomToken,
        address _oddaoTreasury
    ) Ownable(msg.sender) {
        // M-02: Zero-address validation
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_oddaoTreasury == address(0)) revert ZeroAddress();

        xomToken = IERC20(_xomToken);
        oddaoTreasury = _oddaoTreasury;
        registrationFeePerYear = 10 ether; // 10 XOM per year
    }

    // ══════════════════════════════════════════════════════════════════
    //                          COMMIT-REVEAL
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Commit to registering a name (phase 1)
     * @dev H-01 audit fix: Prevents front-running by requiring
     *      a commitment before registration. The commitment hides
     *      the name being registered until the reveal phase.
     *      Caller must wait MIN_COMMITMENT_AGE before calling
     *      register(), and must register within MAX_COMMITMENT_AGE.
     * @param commitment Hash of (name, msg.sender, secret)
     */
    function commit(bytes32 commitment) external {
        // solhint-disable-next-line not-rely-on-time
        commitments[commitment] = block.timestamp;

        emit NameCommitted(commitment, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════
    //                        NAME REGISTRATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Register a username (phase 2 of commit-reveal)
     * @dev H-01 audit fix: Requires a prior commitment via
     *      commit(). The commitment must be at least
     *      MIN_COMMITMENT_AGE old and at most MAX_COMMITMENT_AGE.
     *      L-04 audit fix: Fee transfer moved after all state
     *      changes (CEI pattern).
     * @param name Username to register (3-32 chars, a-z, 0-9, -)
     * @param duration Registration duration in seconds (30-365 days)
     * @param secret The secret used when making the commitment
     */
    function register(
        string calldata name,
        uint256 duration,
        bytes32 secret
    ) external nonReentrant {
        _validateName(name);
        _validateDuration(duration);
        _consumeCommitment(name, secret);

        bytes32 nameHash = _nameHash(name);
        _ensureNameAvailable(name, nameHash);

        // Calculate fee (proportional to duration)
        uint256 fee = (registrationFeePerYear * duration)
            / 365 days;

        // L-04: All state changes BEFORE external interaction
        // solhint-disable-next-line not-rely-on-time
        uint256 expiresAt = block.timestamp + duration;

        registrations[nameHash] = Registration({
            owner: msg.sender,
            registeredAt: block.timestamp, // solhint-disable-line not-rely-on-time
            expiresAt: expiresAt
        });

        // M-03: Emit event if overwriting active reverse record
        _setReverseRecord(msg.sender, nameHash);

        nameStrings[nameHash] = name;
        ++totalRegistrations;

        // L-04: External call AFTER state changes (CEI pattern)
        if (fee > 0) {
            xomToken.safeTransferFrom(
                msg.sender, oddaoTreasury, fee
            );
        }

        emit NameRegistered(
            name, msg.sender, expiresAt, fee
        );
    }

    /**
     * @notice Transfer a name to a new owner
     * @param name Name to transfer
     * @param newOwner New owner address
     */
    function transfer(
        string calldata name,
        address newOwner
    ) external nonReentrant {
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner != msg.sender) revert NotNameOwner();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > reg.expiresAt - 1) {
            revert NameNotFound(name);
        }

        // Clear old reverse record
        if (reverseRecords[msg.sender] == nameHash) {
            delete reverseRecords[msg.sender];
        }

        reg.owner = newOwner;
        reverseRecords[newOwner] = nameHash;

        emit NameTransferred(name, msg.sender, newOwner);
    }

    /**
     * @notice Renew a name registration
     * @dev M-01 audit fix: Fee is calculated on the actual
     *      duration added (after cap), not the requested
     *      duration. This prevents overcharging when the
     *      renewal would exceed MAX_DURATION.
     *      L-04 audit fix: Fee transfer moved after all state
     *      changes (CEI pattern).
     * @param name Name to renew
     * @param additionalDuration Seconds to add
     */
    function renew(
        string calldata name,
        uint256 additionalDuration
    ) external nonReentrant {
        if (additionalDuration < MIN_DURATION) {
            revert DurationTooShort(
                additionalDuration, MIN_DURATION
            );
        }

        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner != msg.sender) revert NotNameOwner();

        // Extend from current expiry or now (whichever is later)
        /* solhint-disable not-rely-on-time */
        uint256 base = block.timestamp > reg.expiresAt
            ? block.timestamp
            : reg.expiresAt;
        uint256 newExpiry = base + additionalDuration;

        // Cap total duration at MAX_DURATION from now
        // M-01: Calculate actual duration BEFORE computing fee
        uint256 maxExpiry = block.timestamp + MAX_DURATION;
        /* solhint-enable not-rely-on-time */
        uint256 actualDuration;
        if (newExpiry > maxExpiry) {
            actualDuration = maxExpiry - base;
            newExpiry = maxExpiry;
        } else {
            actualDuration = additionalDuration;
        }

        // M-01: Fee based on actual duration (after cap)
        uint256 fee = (registrationFeePerYear
            * actualDuration) / 365 days;

        // L-04: State change BEFORE external call (CEI)
        reg.expiresAt = newExpiry;

        // L-04: External call AFTER state changes
        if (fee > 0) {
            xomToken.safeTransferFrom(
                msg.sender, oddaoTreasury, fee
            );
        }

        emit NameRenewed(name, msg.sender, newExpiry);
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update registration fee (owner only)
     * @dev L-03 audit fix: Fee must be within bounds
     *      [MIN_REGISTRATION_FEE, MAX_REGISTRATION_FEE].
     * @param newFeePerYear New annual fee in XOM (18 decimals)
     */
    function setRegistrationFee(
        uint256 newFeePerYear
    ) external onlyOwner {
        if (
            newFeePerYear < MIN_REGISTRATION_FEE
                || newFeePerYear > MAX_REGISTRATION_FEE
        ) {
            revert FeeOutOfBounds();
        }

        uint256 oldFee = registrationFeePerYear;
        registrationFeePerYear = newFeePerYear;
        emit RegistrationFeeUpdated(oldFee, newFeePerYear);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve a name to its owner address
     * @param name Username to look up
     * @return owner Current owner (address(0) if expired/not found)
     */
    function resolve(
        string calldata name
    ) external view returns (address owner) {
        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner == address(0)) return address(0);
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > reg.expiresAt - 1) {
            return address(0);
        }

        return reg.owner;
    }

    /**
     * @notice Reverse resolve: lookup name by address
     * @param addr Address to look up
     * @return name Username (empty string if none)
     */
    function reverseResolve(
        address addr
    ) external view returns (string memory name) {
        bytes32 nameHash = reverseRecords[addr];
        if (nameHash == bytes32(0)) return "";

        Registration storage reg = registrations[nameHash];
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > reg.expiresAt - 1) return "";
        if (reg.owner != addr) return "";

        return nameStrings[nameHash];
    }

    /**
     * @notice Check if a name is available for registration
     * @param name Username to check
     * @return True if available (not registered or expired)
     */
    function isAvailable(
        string calldata name
    ) external view returns (bool) {
        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner == address(0)) return true;
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp > reg.expiresAt - 1;
    }

    /**
     * @notice Get registration details for a name
     * @param name Username to look up
     * @return owner Current owner
     * @return registeredAt Registration timestamp
     * @return expiresAt Expiry timestamp
     */
    function getRegistration(
        string calldata name
    )
        external
        view
        returns (
            address owner,
            uint256 registeredAt,
            uint256 expiresAt
        )
    {
        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];
        return (reg.owner, reg.registeredAt, reg.expiresAt);
    }

    /**
     * @notice Calculate registration fee for a given duration
     * @param duration Duration in seconds
     * @return fee Fee in XOM (18 decimals)
     */
    function calculateFee(
        uint256 duration
    ) external view returns (uint256 fee) {
        return (registrationFeePerYear * duration)
            / 365 days;
    }

    // ══════════════════════════════════════════════════════════════════
    //                    EXTERNAL PURE FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Compute commitment hash for off-chain use
     * @dev Helper function so callers can compute the commitment
     *      hash without needing to replicate the hashing logic.
     *      H-01 audit fix: part of commit-reveal scheme.
     * @param name Username to register
     * @param nameOwner Address that will own the name
     * @param secret Random secret for commitment hiding
     * @return commitment The commitment hash
     */
    function makeCommitment(
        string calldata name,
        address nameOwner,
        bytes32 secret
    ) external pure returns (bytes32 commitment) {
        return keccak256(
            abi.encodePacked(name, nameOwner, secret)
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Set reverse record with overwrite detection
     * @dev M-03 audit fix: Emits ReverseRecordOverwritten when
     *      an existing active reverse record is replaced.
     * @param owner Address whose reverse record to set
     * @param nameHash New name hash to associate
     */
    function _setReverseRecord(
        address owner,
        bytes32 nameHash
    ) internal {
        bytes32 existingRecord = reverseRecords[owner];
        if (existingRecord != bytes32(0)) {
            Registration storage existing =
                registrations[existingRecord];
            if (
                existing.owner == owner
                    // solhint-disable-next-line not-rely-on-time
                    && block.timestamp < existing.expiresAt
            ) {
                emit ReverseRecordOverwritten(
                    owner, existingRecord, nameHash
                );
            }
        }
        reverseRecords[owner] = nameHash;
    }

    /**
     * @notice Verify and consume a commit-reveal commitment
     * @dev H-01 audit fix: Checks commitment age bounds and
     *      deletes the commitment to prevent reuse.
     * @param name The name being registered
     * @param secret The secret used in the commitment
     */
    function _consumeCommitment(
        string calldata name,
        bytes32 secret
    ) internal {
        bytes32 commitment = keccak256(
            abi.encodePacked(name, msg.sender, secret)
        );
        uint256 committedAt = commitments[commitment];
        if (committedAt == 0) revert NoCommitment();

        /* solhint-disable not-rely-on-time */
        if (
            block.timestamp
                < committedAt + MIN_COMMITMENT_AGE
        ) {
            revert CommitmentTooNew();
        }
        if (
            block.timestamp
                > committedAt + MAX_COMMITMENT_AGE
        ) {
            revert CommitmentExpired();
        }
        /* solhint-enable not-rely-on-time */

        delete commitments[commitment];
    }

    /**
     * @notice Ensure a name is available for registration
     * @dev Checks if the name is unregistered or expired.
     *      If expired, clears the old reverse record.
     * @param name Name string (for error messages)
     * @param nameHash Hash of the name
     */
    function _ensureNameAvailable(
        string calldata name,
        bytes32 nameHash
    ) internal {
        Registration storage reg = registrations[nameHash];
        if (reg.owner != address(0)) {
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp < reg.expiresAt) {
                revert NameTaken(name);
            }
            // Expired — clear old reverse record
            if (reverseRecords[reg.owner] == nameHash) {
                delete reverseRecords[reg.owner];
            }
        }
    }

    // ── Internal Pure Functions ──────────────────────────────────

    /**
     * @notice Validate registration duration is within bounds
     * @param duration Duration in seconds
     */
    function _validateDuration(
        uint256 duration
    ) internal pure {
        if (duration < MIN_DURATION) {
            revert DurationTooShort(duration, MIN_DURATION);
        }
        if (duration > MAX_DURATION) {
            revert DurationTooLong(duration, MAX_DURATION);
        }
    }

    /**
     * @notice Validate name format
     * @dev 3-32 chars, a-z, 0-9, hyphens only.
     *      No leading/trailing hyphens. Uppercase characters
     *      are rejected (case-insensitivity is enforced here,
     *      not in _nameHash).
     * @param name Name to validate
     */
    function _validateName(
        string calldata name
    ) internal pure {
        bytes memory b = bytes(name);
        uint256 len = b.length;

        if (len < MIN_NAME_LENGTH || len > MAX_NAME_LENGTH) {
            revert InvalidNameLength(len);
        }

        // No leading/trailing hyphens
        if (b[0] == 0x2D || b[len - 1] == 0x2D) {
            revert InvalidNameCharacter();
        }

        /* solhint-disable gas-strict-inequalities */
        for (uint256 i = 0; i < len; ++i) {
            bytes1 c = b[i];
            // a-z (0x61-0x7A), 0-9 (0x30-0x39), hyphen (0x2D)
            bool valid = (c >= 0x61 && c <= 0x7A)
                || (c >= 0x30 && c <= 0x39)
                || c == 0x2D;
            if (!valid) revert InvalidNameCharacter();
        }
        /* solhint-enable gas-strict-inequalities */
    }

    /**
     * @notice Hash a name for storage key derivation
     * @dev Hashes the raw name bytes. Case-insensitivity is
     *      enforced by _validateName() rejecting uppercase
     *      characters, not by this function. All stored names
     *      are guaranteed lowercase by the validation step.
     *      L-01 audit fix: NatSpec corrected from claiming
     *      case-insensitive hashing.
     * @param name Name to hash (must be lowercase)
     * @return Name hash (keccak256 of raw bytes)
     */
    function _nameHash(
        string calldata name
    ) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }
}
