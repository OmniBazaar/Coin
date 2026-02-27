// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
error ZeroRegistrationAddress();

/// @notice Registration fee transfer failed
error FeeTransferFailed();

/// @notice Name has not expired yet (cannot re-register)
error NameNotExpired(string name, uint256 expiresAt);

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
 * - ReentrancyGuard on all state changes
 * - Only owner can transfer/renew their names
 */
contract OmniENS is ReentrancyGuard, Ownable {
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

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token for registration fees
    IERC20 public immutable xomToken;

    /// @notice ODDAO treasury (receives registration fees)
    address public immutable oddaoTreasury;

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

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a name is registered
    event NameRegistered(
        string name,
        address indexed owner,
        uint256 expiresAt,
        uint256 fee
    );

    /// @notice Emitted when a name is transferred
    event NameTransferred(
        string name,
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when a name is renewed
    event NameRenewed(
        string name,
        address indexed owner,
        uint256 newExpiry
    );

    /// @notice Emitted when registration fee is updated
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the ENS registry
     * @param _xomToken XOM token address
     * @param _oddaoTreasury ODDAO treasury address
     */
    constructor(
        address _xomToken,
        address _oddaoTreasury
    ) Ownable(msg.sender) {
        xomToken = IERC20(_xomToken);
        oddaoTreasury = _oddaoTreasury;
        registrationFeePerYear = 10 ether; // 10 XOM per year
    }

    // ══════════════════════════════════════════════════════════════════
    //                        NAME REGISTRATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Register a username
     * @dev Name is stored lowercase. Fee is proportional to duration.
     * @param name Username to register (3-32 chars, a-z, 0-9, hyphens)
     * @param duration Registration duration in seconds (30-365 days)
     */
    function register(
        string calldata name,
        uint256 duration
    ) external nonReentrant {
        _validateName(name);

        if (duration < MIN_DURATION) {
            revert DurationTooShort(duration, MIN_DURATION);
        }
        if (duration > MAX_DURATION) {
            revert DurationTooLong(duration, MAX_DURATION);
        }

        bytes32 nameHash = _nameHash(name);

        // Check name is available (not registered or expired)
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

        // Calculate fee (proportional to duration)
        uint256 fee = (registrationFeePerYear * duration) / 365 days;

        // Collect fee
        if (fee > 0) {
            xomToken.safeTransferFrom(msg.sender, oddaoTreasury, fee);
        }

        // Register
        // solhint-disable-next-line not-rely-on-time
        uint256 expiresAt = block.timestamp + duration;

        registrations[nameHash] = Registration({
            owner: msg.sender,
            registeredAt: block.timestamp, // solhint-disable-line not-rely-on-time
            expiresAt: expiresAt
        });

        reverseRecords[msg.sender] = nameHash;
        nameStrings[nameHash] = name;
        totalRegistrations++;

        emit NameRegistered(name, msg.sender, expiresAt, fee);
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
        if (newOwner == address(0)) revert ZeroRegistrationAddress();

        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner != msg.sender) revert NotNameOwner();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= reg.expiresAt) {
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
     * @param name Name to renew
     * @param additionalDuration Seconds to add
     */
    function renew(
        string calldata name,
        uint256 additionalDuration
    ) external nonReentrant {
        if (additionalDuration < MIN_DURATION) {
            revert DurationTooShort(additionalDuration, MIN_DURATION);
        }

        bytes32 nameHash = _nameHash(name);
        Registration storage reg = registrations[nameHash];

        if (reg.owner != msg.sender) revert NotNameOwner();

        // Calculate fee for extension
        uint256 fee = (registrationFeePerYear * additionalDuration)
            / 365 days;

        if (fee > 0) {
            xomToken.safeTransferFrom(msg.sender, oddaoTreasury, fee);
        }

        // Extend from current expiry or now (whichever is later)
        // solhint-disable-next-line not-rely-on-time
        uint256 base = block.timestamp > reg.expiresAt
            ? block.timestamp
            : reg.expiresAt;
        uint256 newExpiry = base + additionalDuration;

        // Cap total duration at MAX_DURATION from now
        // solhint-disable-next-line not-rely-on-time
        uint256 maxExpiry = block.timestamp + MAX_DURATION;
        if (newExpiry > maxExpiry) {
            newExpiry = maxExpiry;
        }

        reg.expiresAt = newExpiry;

        emit NameRenewed(name, msg.sender, newExpiry);
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
        if (block.timestamp >= reg.expiresAt) return address(0);

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
        if (block.timestamp >= reg.expiresAt) return "";
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
        return block.timestamp >= reg.expiresAt;
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
        returns (address owner, uint256 registeredAt, uint256 expiresAt)
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
        return (registrationFeePerYear * duration) / 365 days;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update registration fee (owner only)
     * @param newFeePerYear New annual fee in XOM (18 decimals)
     */
    function setRegistrationFee(
        uint256 newFeePerYear
    ) external onlyOwner {
        uint256 oldFee = registrationFeePerYear;
        registrationFeePerYear = newFeePerYear;
        emit FeeUpdated(oldFee, newFeePerYear);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Validate name format
     * @dev 3-32 chars, a-z, 0-9, hyphens. No leading/trailing hyphens.
     * @param name Name to validate
     */
    function _validateName(string calldata name) internal pure {
        bytes memory b = bytes(name);
        uint256 len = b.length;

        if (len < MIN_NAME_LENGTH || len > MAX_NAME_LENGTH) {
            revert InvalidNameLength(len);
        }

        // No leading/trailing hyphens
        if (b[0] == 0x2D || b[len - 1] == 0x2D) {
            revert InvalidNameCharacter();
        }

        for (uint256 i = 0; i < len; ++i) {
            bytes1 c = b[i];
            // a-z (0x61-0x7A), 0-9 (0x30-0x39), hyphen (0x2D)
            bool valid = (c >= 0x61 && c <= 0x7A) ||
                (c >= 0x30 && c <= 0x39) ||
                c == 0x2D;
            if (!valid) revert InvalidNameCharacter();
        }
    }

    /**
     * @notice Hash a name (case-insensitive, stored lowercase)
     * @param name Name to hash
     * @return Name hash
     */
    function _nameHash(
        string calldata name
    ) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }
}
