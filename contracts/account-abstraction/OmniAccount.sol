// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAccount, UserOperation} from "./interfaces/IAccount.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniAccount
 * @author OmniCoin Development Team
 * @notice ERC-4337 smart wallet with guardian recovery, session keys, and spending limits
 * @dev Deployed via OmniAccountFactory using CREATE2 for deterministic addresses.
 *      Designed for the OmniCoin L1 chain where gas is free for users.
 *      Features:
 *      - Single-owner ECDSA validation (compatible with passkey signing via adapter)
 *      - Batch execution for complex DeFi operations
 *      - Guardian-based social recovery (wires to RecoveryService)
 *      - Session keys with time-limited permissions
 *      - Daily spending limits per token
 */
contract OmniAccount is IAccount, Initializable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ══════════════════════════════════════════════════════════════
    //                     TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Session key with scoped permissions
    struct SessionKey {
        /// @notice Whether this session key is active
        bool active;
        /// @notice Unix timestamp when session expires
        uint48 validUntil;
        /// @notice Authorized signer address
        address signer;
        /// @notice Allowed target contract (address(0) = any target)
        address allowedTarget;
        /// @notice Maximum native value per call (0 = no native transfers)
        uint256 maxValue;
    }

    /// @notice Daily spending limit for a specific token
    struct SpendingLimit {
        /// @notice Timestamp when current period resets (midnight UTC boundary)
        uint48 resetTime;
        /// @notice Maximum daily spend amount
        uint256 dailyLimit;
        /// @notice Amount spent in current period
        uint256 spentToday;
    }

    /// @notice Pending recovery request
    /// @dev Packed: newOwner (20 bytes) + initiatedAt (6 bytes) = 26 bytes in slot 1
    struct RecoveryRequest {
        /// @notice Proposed new owner
        address newOwner;
        /// @notice Timestamp when recovery was initiated
        uint48 initiatedAt;
        /// @notice Number of guardian approvals received
        uint256 approvalCount;
        /// @notice Mapping of guardian approvals
        mapping(address => bool) approvals;
    }

    // ══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Sentinel value indicating a valid signature (ERC-4337)
    uint256 internal constant SIG_VALIDATION_SUCCEEDED = 0;

    /// @notice Sentinel value indicating an invalid signature (ERC-4337)
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @notice Maximum number of guardians allowed
    uint256 internal constant MAX_GUARDIANS = 7;

    /// @notice Maximum number of active session keys
    uint256 internal constant MAX_SESSION_KEYS = 10;

    /// @notice Recovery threshold: requires ceil(guardians / 2) + 1 approvals
    /// @dev For 3 guardians = 2 approvals, 5 guardians = 3 approvals, 7 guardians = 4 approvals
    uint256 internal constant RECOVERY_DELAY = 2 days;

    /// @notice ERC-20 transfer(address,uint256) selector
    bytes4 internal constant ERC20_TRANSFER = 0xa9059cbb;

    /// @notice ERC-20 approve(address,uint256) selector
    bytes4 internal constant ERC20_APPROVE = 0x095ea7b3;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint; // solhint-disable-line immutable-vars-naming

    /// @notice Account owner (can execute arbitrary calls, change settings)
    address public owner;

    /// @notice Guardian addresses for social recovery
    address[] public guardians;

    /// @notice Whether an address is a guardian
    mapping(address => bool) public isGuardian;

    /// @notice Session keys indexed by signer address
    mapping(address => SessionKey) public sessionKeys;

    /// @notice List of active session key addresses
    address[] public sessionKeyList;

    /// @notice Spending limits per token address (address(0) = native token)
    mapping(address => SpendingLimit) public spendingLimits;

    /// @notice Current pending recovery request (only one active at a time)
    RecoveryRequest public recoveryRequest;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Emitted when the account executes a call
    /// @param target Contract called
    /// @param value Native token value sent
    /// @param data Calldata executed
    event Executed(address indexed target, uint256 indexed value, bytes data);

    /// @notice Emitted when ownership is transferred
    /// @param previousOwner Old owner address
    /// @param newOwner New owner address
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a guardian is added
    /// @param guardian Address of the new guardian
    event GuardianAdded(address indexed guardian);

    /// @notice Emitted when a guardian is removed
    /// @param guardian Address of the removed guardian
    event GuardianRemoved(address indexed guardian);

    /// @notice Emitted when a session key is added
    /// @param signer Session key signer address
    /// @param validUntil Expiration timestamp
    /// @param allowedTarget Scoped target contract
    event SessionKeyAdded(
        address indexed signer,
        uint48 indexed validUntil,
        address indexed allowedTarget
    );

    /// @notice Emitted when a session key is revoked
    /// @param signer Revoked session key address
    event SessionKeyRevoked(address indexed signer);

    /// @notice Emitted when a spending limit is set
    /// @param token Token address (address(0) for native)
    /// @param dailyLimit Maximum daily spend
    event SpendingLimitSet(address indexed token, uint256 indexed dailyLimit);

    /// @notice Emitted when recovery is initiated
    /// @param newOwner Proposed new owner
    /// @param initiatedBy Guardian who started recovery
    event RecoveryInitiated(address indexed newOwner, address indexed initiatedBy);

    /// @notice Emitted when recovery is completed
    /// @param newOwner The new account owner
    event RecoveryCompleted(address indexed newOwner);

    /// @notice Emitted when recovery is cancelled
    event RecoveryCancelled();

    // ══════════════════════════════════════════════════════════════
    //                       CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    /// @notice Caller is not the EntryPoint
    error OnlyEntryPoint();

    /// @notice Caller is not the owner or EntryPoint
    error OnlyOwnerOrEntryPoint();

    /// @notice Caller is not the owner
    error OnlyOwner();

    /// @notice Caller is not a guardian
    error OnlyGuardian();

    /// @notice Call execution failed
    /// @param target The target that reverted
    error ExecutionFailed(address target);

    /// @notice Batch arrays have mismatched lengths
    error BatchLengthMismatch();

    /// @notice Maximum number of guardians reached
    error TooManyGuardians();

    /// @notice Maximum number of session keys reached
    error TooManySessionKeys();

    /// @notice Address is already a guardian
    error AlreadyGuardian();

    /// @notice Address is not a guardian
    error NotGuardian();

    /// @notice Session key has expired
    error SessionKeyExpired();

    /// @notice Session key target not allowed
    error SessionKeyTargetNotAllowed();

    /// @notice Session key value exceeds limit
    error SessionKeyValueExceeded();

    /// @notice Spending limit exceeded for this period
    error SpendingLimitExceeded();

    /// @notice Recovery is already in progress
    error RecoveryAlreadyActive();

    /// @notice No recovery is in progress
    error NoActiveRecovery();

    /// @notice Recovery delay period has not elapsed
    error RecoveryDelayNotMet();

    /// @notice Guardian has already approved this recovery
    error AlreadyApproved();

    /// @notice Invalid address (zero address)
    error InvalidAddress();

    /// @notice Guardian management is frozen during active recovery
    error GuardiansFrozenDuringRecovery();

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Restricts access to the EntryPoint contract only
     */
    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert OnlyEntryPoint();
        _;
    }

    /**
     * @notice Restricts access to the owner or EntryPoint
     */
    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != entryPoint) {
            revert OnlyOwnerOrEntryPoint();
        }
        _;
    }

    /**
     * @notice Restricts access to the owner only
     */
    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != address(this)) {
            revert OnlyOwner();
        }
        _;
    }

    /**
     * @notice Restricts access to registered guardians
     */
    modifier onlyGuardianRole() {
        if (!isGuardian[msg.sender]) revert OnlyGuardian();
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Set the immutable EntryPoint address
     * @param entryPoint_ The ERC-4337 EntryPoint contract
     */
    constructor(address entryPoint_) {
        if (entryPoint_ == address(0)) revert InvalidAddress();
        entryPoint = entryPoint_;
        _disableInitializers();
    }

    /// @notice Allow the account to receive native tokens
    receive() external payable {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Initialize the account with an owner (called by factory)
     * @param owner_ The initial owner of this smart account
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
    }

    // ══════════════════════════════════════════════════════════════
    //                    ERC-4337 VALIDATION
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Validate a UserOperation signature
     * @dev Supports two signing modes:
     *      1. Owner signature (ECDSA recovery matches owner)
     *      2. Session key signature (ECDSA recovery matches active session key)
     * @param userOp The UserOperation to validate
     * @param userOpHash Hash of the UserOperation
     * @param missingAccountFunds Amount to prefund the EntryPoint
     * @return validationData 0 if valid owner sig, packed time range for session keys, 1 if invalid
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256 validationData) {
        // Pay prefund to EntryPoint if needed
        if (missingAccountFunds > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            // Ignore failure — EntryPoint will revert if underfunded
            (success);
        }

        // Recover signer from signature
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        address signer = ethHash.recover(userOp.signature);

        // Check if signer is the owner
        if (signer == owner) {
            return SIG_VALIDATION_SUCCEEDED;
        }

        // Check if signer is an active session key
        SessionKey storage sk = sessionKeys[signer];
        if (sk.active && sk.signer == signer) {
            // Enforce session key target and value constraints on callData
            if (!_validateSessionKeyCallData(userOp.callData, sk)) {
                return SIG_VALIDATION_FAILED;
            }

            // Pack validUntil into validation data (bits 160-207)
            return uint256(sk.validUntil) << 160;
        }

        return SIG_VALIDATION_FAILED;
    }

    // ══════════════════════════════════════════════════════════════
    //                       EXECUTION
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Execute a single call from this account
     * @dev Can only be called by the EntryPoint (via UserOp) or directly by the owner.
     * @param target Contract to call
     * @param value Native token value to send
     * @param data Calldata for the call
     * @return result Return data from the call
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwnerOrEntryPoint nonReentrant returns (bytes memory result) {
        // Enforce spending limits only for EntryPoint calls (session key path).
        // Direct owner calls are unrestricted.
        if (msg.sender == entryPoint) {
            // Check native token spending limit
            if (value > 0) {
                _checkAndUpdateSpendingLimit(address(0), value);
            }
            // Check ERC-20 transfer/approve spending limits
            if (data.length > 3) {
                _checkERC20SpendingLimit(target, data);
            }
        }

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed(target);
        emit Executed(target, value, data);
        return returnData;
    }

    /**
     * @notice Execute a batch of calls from this account
     * @dev Atomic — reverts entirely if any call fails. Useful for approve+swap patterns.
     * @param targets Array of contracts to call
     * @param values Array of native token values
     * @param datas Array of calldatas
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwnerOrEntryPoint nonReentrant {
        uint256 len = targets.length;
        if (len != values.length || len != datas.length) revert BatchLengthMismatch();

        for (uint256 i; i < len; ++i) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert ExecutionFailed(targets[i]);
            emit Executed(targets[i], values[i], datas[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                     OWNER MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Transfer account ownership to a new address
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ══════════════════════════════════════════════════════════════
    //                    GUARDIAN MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Add a guardian for social recovery
     * @param guardian Address of the new guardian
     */
    function addGuardian(address guardian) external onlyOwner {
        if (recoveryRequest.initiatedAt > 0) {
            revert GuardiansFrozenDuringRecovery();
        }
        if (guardian == address(0)) revert InvalidAddress();
        if (isGuardian[guardian]) revert AlreadyGuardian();
        if (guardians.length > MAX_GUARDIANS - 1) revert TooManyGuardians();

        guardians.push(guardian);
        isGuardian[guardian] = true;
        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian
     * @dev C-04: Clears any stale recovery approval for the removed guardian
     *      as defense-in-depth. The primary protection is GuardiansFrozenDuringRecovery
     *      which prevents removal during active recovery, and _clearRecovery() which
     *      clears all approvals when recovery ends.
     * @param guardian Address to remove
     */
    function removeGuardian(address guardian) external onlyOwner {
        if (recoveryRequest.initiatedAt > 0) {
            revert GuardiansFrozenDuringRecovery();
        }
        if (!isGuardian[guardian]) revert NotGuardian();

        isGuardian[guardian] = false;

        // C-04: Clear any stale recovery approval for defense-in-depth
        if (recoveryRequest.approvals[guardian]) {
            recoveryRequest.approvals[guardian] = false;
            if (recoveryRequest.approvalCount > 0) {
                --recoveryRequest.approvalCount;
            }
        }

        // Remove from array by swapping with last element
        uint256 len = guardians.length;
        for (uint256 i; i < len; ++i) {
            if (guardians[i] == guardian) {
                guardians[i] = guardians[len - 1];
                guardians.pop();
                break;
            }
        }
        emit GuardianRemoved(guardian);
    }

    // ══════════════════════════════════════════════════════════════
    //                    SOCIAL RECOVERY
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Initiate account recovery to transfer ownership
     * @dev Any guardian can initiate. Requires threshold approvals + delay period.
     * @param newOwner Proposed new owner address
     */
    function initiateRecovery(address newOwner) external onlyGuardianRole {
        if (newOwner == address(0)) revert InvalidAddress();
        if (recoveryRequest.initiatedAt > 0) revert RecoveryAlreadyActive();

        recoveryRequest.newOwner = newOwner;
        recoveryRequest.approvalCount = 1;
        recoveryRequest.initiatedAt = uint48(block.timestamp); // solhint-disable-line not-rely-on-time
        recoveryRequest.approvals[msg.sender] = true;

        emit RecoveryInitiated(newOwner, msg.sender);
    }

    /**
     * @notice Approve a pending recovery request
     * @dev Each guardian can approve once. Recovery auto-executes when threshold is met.
     */
    function approveRecovery() external onlyGuardianRole {
        if (recoveryRequest.initiatedAt == 0) revert NoActiveRecovery();
        if (recoveryRequest.approvals[msg.sender]) revert AlreadyApproved();

        recoveryRequest.approvals[msg.sender] = true;
        ++recoveryRequest.approvalCount;
    }

    /**
     * @notice Execute recovery after threshold approvals and delay period
     * @dev Anyone can call this once conditions are met.
     */
    function executeRecovery() external {
        if (recoveryRequest.initiatedAt == 0) revert NoActiveRecovery();
        if (recoveryRequest.approvalCount < recoveryThreshold()) {
            revert NoActiveRecovery();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < recoveryRequest.initiatedAt + RECOVERY_DELAY) {
            revert RecoveryDelayNotMet();
        }

        address newOwner = recoveryRequest.newOwner;
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;

        // Clear recovery state
        _clearRecovery();
        emit RecoveryCompleted(newOwner);
    }

    /**
     * @notice Cancel a pending recovery (owner only)
     * @dev Allows the current owner to cancel a malicious recovery attempt.
     */
    function cancelRecovery() external onlyOwner {
        if (recoveryRequest.initiatedAt == 0) revert NoActiveRecovery();
        _clearRecovery();
        emit RecoveryCancelled();
    }

    // ══════════════════════════════════════════════════════════════
    //                      SESSION KEYS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Add a session key with scoped permissions
     * @param signer Session key signer address
     * @param validUntil Expiration timestamp
     * @param allowedTarget Scoped contract (address(0) = any)
     * @param maxValue Maximum native value per call
     */
    function addSessionKey(
        address signer,
        uint48 validUntil,
        address allowedTarget,
        uint256 maxValue
    ) external onlyOwner {
        if (signer == address(0)) revert InvalidAddress();
        if (sessionKeyList.length > MAX_SESSION_KEYS - 1) revert TooManySessionKeys();

        // If replacing, don't increment list
        if (!sessionKeys[signer].active) {
            sessionKeyList.push(signer);
        }

        sessionKeys[signer] = SessionKey({
            signer: signer,
            validUntil: validUntil,
            allowedTarget: allowedTarget,
            maxValue: maxValue,
            active: true
        });

        emit SessionKeyAdded(signer, validUntil, allowedTarget);
    }

    /**
     * @notice Revoke a session key
     * @param signer Session key to revoke
     */
    function revokeSessionKey(address signer) external onlyOwner {
        sessionKeys[signer].active = false;

        // Remove from list
        uint256 len = sessionKeyList.length;
        for (uint256 i; i < len; ++i) {
            if (sessionKeyList[i] == signer) {
                sessionKeyList[i] = sessionKeyList[len - 1];
                sessionKeyList.pop();
                break;
            }
        }

        emit SessionKeyRevoked(signer);
    }

    // ══════════════════════════════════════════════════════════════
    //                     SPENDING LIMITS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Set a daily spending limit for a token
     * @param token Token address (address(0) for native token)
     * @param dailyLimit Maximum amount per day (0 = no limit)
     */
    function setSpendingLimit(address token, uint256 dailyLimit) external onlyOwner {
        spendingLimits[token].dailyLimit = dailyLimit;
        spendingLimits[token].spentToday = 0;
        spendingLimits[token].resetTime = _nextMidnight();
        emit SpendingLimitSet(token, dailyLimit);
    }

    // ══════════════════════════════════════════════════════════════
    //                   EXTERNAL VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Get the number of guardians
     * @return count Number of registered guardians
     */
    function guardianCount() external view returns (uint256 count) {
        return guardians.length;
    }

    /**
     * @notice Get the number of active session keys
     * @return count Number of session keys
     */
    function sessionKeyCount() external view returns (uint256 count) {
        return sessionKeyList.length;
    }

    /**
     * @notice Check remaining spending allowance for a token
     * @param token Token address (address(0) for native)
     * @return remaining Amount that can still be spent today
     */
    function remainingSpendingLimit(address token) external view returns (uint256 remaining) {
        SpendingLimit storage limit = spendingLimits[token];
        if (limit.dailyLimit == 0) return type(uint256).max;

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > limit.resetTime - 1) {
            return limit.dailyLimit;
        }

        if (limit.spentToday > limit.dailyLimit - 1) return 0;
        return limit.dailyLimit - limit.spentToday;
    }

    // ══════════════════════════════════════════════════════════════
    //                    PUBLIC VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Get the required number of approvals for recovery
     * @return threshold Minimum approvals needed
     */
    function recoveryThreshold() public view returns (uint256 threshold) {
        uint256 count = guardians.length;
        if (count == 0) return 0;
        return (count / 2) + 1;
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Check and update daily spending limit for a token
     * @dev Reverts with SpendingLimitExceeded if the spend would exceed the daily limit.
     *      Automatically resets the daily counter when the reset time has passed.
     *      If no limit is set (dailyLimit == 0), the function returns without enforcement.
     * @param token Token address (address(0) for native token)
     * @param amount Amount being spent
     */
    function _checkAndUpdateSpendingLimit(
        address token,
        uint256 amount
    ) internal {
        SpendingLimit storage limit = spendingLimits[token];
        if (limit.dailyLimit == 0) return; // No limit configured

        // Reset counter if new period has started
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > limit.resetTime - 1) {
            limit.spentToday = 0;
            limit.resetTime = _nextMidnight();
        }

        if (limit.spentToday + amount > limit.dailyLimit) {
            revert SpendingLimitExceeded();
        }
        limit.spentToday += amount;
    }

    /**
     * @notice Check ERC-20 transfer/approve calldata against spending limits
     * @dev Decodes the first 4 bytes of data to identify transfer or approve calls,
     *      then extracts the amount and checks against the spending limit for the
     *      target token contract.
     * @param token The target contract address (presumed to be an ERC-20 token)
     * @param data The calldata being sent to the target
     */
    function _checkERC20SpendingLimit(
        address token,
        bytes calldata data
    ) internal {
        bytes4 selector = bytes4(data[:4]);

        // Only enforce for transfer(address,uint256) and approve(address,uint256)
        if (selector == ERC20_TRANSFER || selector == ERC20_APPROVE) {
            if (data.length < 68) return; // 4 + 32 + 32
            (, uint256 amount) = abi.decode(data[4:68], (address, uint256));
            _checkAndUpdateSpendingLimit(token, amount);
        }
    }

    /**
     * @notice Clear the current recovery request
     * @dev Resets all recovery state. Guardian approval mappings are left
     *      stale but harmless since initiatedAt is reset to 0.
     */
    function _clearRecovery() internal {
        // Clear guardian approvals for all current guardians
        uint256 len = guardians.length;
        for (uint256 i; i < len; ++i) {
            recoveryRequest.approvals[guardians[i]] = false;
        }
        recoveryRequest.newOwner = address(0);
        recoveryRequest.approvalCount = 0;
        recoveryRequest.initiatedAt = 0;
    }

    /**
     * @notice Validate that session key callData respects target and value constraints
     * @dev Session keys may only call execute(address,uint256,bytes). executeBatch and
     *      all other selectors are rejected. If allowedTarget is set, the decoded target
     *      must match. If maxValue is set, the decoded value must not exceed it.
     * @param callData The callData from the UserOperation
     * @param sk The session key to validate against
     * @return valid True if the call is permitted under the session key constraints
     */
    function _validateSessionKeyCallData(
        bytes calldata callData,
        SessionKey storage sk
    ) internal view returns (bool valid) {
        // Minimum length: 4 bytes selector + 32 target + 32 value + 32 data offset = 100
        if (callData.length < 100) return false;

        // Session keys may only call execute(address,uint256,bytes)
        bytes4 selector = bytes4(callData[:4]);
        // solhint-disable-next-line max-line-length
        if (selector != bytes4(keccak256("execute(address,uint256,bytes)"))) {
            return false;
        }

        // Decode target and value from callData
        (address target, uint256 value,) = abi.decode(
            callData[4:],
            (address, uint256, bytes)
        );

        // Validate target constraint (address(0) means any target is allowed)
        if (sk.allowedTarget != address(0) && target != sk.allowedTarget) {
            return false;
        }

        // Validate value constraint (maxValue == 0 means no native transfers allowed)
        if (sk.maxValue == 0 && value > 0) return false;
        if (sk.maxValue > 0 && value > sk.maxValue) return false;

        return true;
    }

    /**
     * @notice Calculate the next midnight UTC timestamp
     * @return midnight Unix timestamp of next midnight UTC
     */
    function _nextMidnight() internal view returns (uint48 midnight) {
        // solhint-disable-next-line not-rely-on-time
        return uint48(((block.timestamp / 1 days) + 1) * 1 days);
    }
}
