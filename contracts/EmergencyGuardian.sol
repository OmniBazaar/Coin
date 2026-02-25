// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPausable} from "./interfaces/IPausable.sol";

/**
 * @title EmergencyGuardian
 * @author OmniCoin Development Team
 * @notice Emergency response contract with strictly limited powers
 * @dev Provides two emergency capabilities for protocol safety:
 *
 * 1. **Pause** (1-of-N threshold): Any single guardian can pause any
 *    registered pausable contract immediately. This enables fast
 *    response to exploits or critical bugs.
 *
 * 2. **Cancel** (3-of-5 threshold): Requires 3 guardian signatures to
 *    cancel a queued timelock operation. This prevents execution of
 *    malicious governance proposals (e.g., Beanstalk-style attacks).
 *
 * Deliberately CANNOT:
 * - Upgrade any contract (no upgrade authority)
 * - Unpause contracts (governance must unpause via timelock)
 * - Queue new proposals (no proposer role)
 * - Change its own parameters (timelock manages guardians)
 *
 * Guardian requirements (L2BEAT Stage 1 compliance):
 * - Minimum 8 members
 * - At least 50% external to OmniBazaar team
 * - All members publicly named
 * - Elected/replaced by governance (via timelock)
 *
 * This contract is immutable (not UUPS upgradeable).
 */
contract EmergencyGuardian {
    // Constants
    /// @notice Minimum number of guardian signatures required to cancel an operation
    uint256 public constant CANCEL_THRESHOLD = 3;

    /// @notice Minimum total guardians required for the system to be valid
    uint256 public constant MIN_GUARDIANS = 5;

    // Immutable state
    /// @notice Reference to the OmniTimelockController
    address public immutable TIMELOCK;

    // State variables
    /// @notice Whether an address is an active guardian
    mapping(address => bool) public isGuardian;

    /// @notice Total number of active guardians
    uint256 public guardianCount;

    /// @notice Whether a contract is registered as pausable
    mapping(address => bool) public isPausable;

    /// @notice Count of registered pausable contracts
    uint256 public pausableCount;

    /// @notice Tracks which guardians have signed a cancel request
    /// @dev cancelId => guardian => signed
    mapping(bytes32 => mapping(address => bool)) public cancelSignatures;

    /// @notice Count of signatures for a cancel request
    mapping(bytes32 => uint256) public cancelSignatureCount;

    // Events
    /// @notice Emitted when a guardian pauses a contract
    /// @param target The contract that was paused
    /// @param guardian The guardian who triggered the pause
    /// @param timestamp When the pause occurred
    event EmergencyPause(
        address indexed target,
        address indexed guardian,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a guardian signs a cancel request
    /// @param operationId The timelock operation being cancelled
    /// @param guardian The guardian who signed
    /// @param signatureCount Total signatures collected so far
    event CancelSigned(
        bytes32 indexed operationId,
        address indexed guardian,
        uint256 indexed signatureCount
    );

    /// @notice Emitted when a timelock operation is cancelled
    /// @param operationId The timelock operation that was cancelled
    /// @param signatureCount Number of guardian signatures that authorized it
    event OperationCancelled(
        bytes32 indexed operationId,
        uint256 indexed signatureCount
    );

    /// @notice Emitted when a guardian is added
    /// @param guardian Address of the new guardian
    event GuardianAdded(address indexed guardian);

    /// @notice Emitted when a guardian is removed
    /// @param guardian Address of the removed guardian
    event GuardianRemoved(address indexed guardian);

    /// @notice Emitted when a pausable contract is registered
    /// @param target Address of the registered contract
    event PausableRegistered(address indexed target);

    /// @notice Emitted when a pausable contract is deregistered
    /// @param target Address of the deregistered contract
    event PausableDeregistered(address indexed target);

    // Custom errors
    /// @notice Thrown when caller is not a guardian
    error NotGuardian();
    /// @notice Thrown when caller is not the timelock
    error NotTimelock();
    /// @notice Thrown when the target is not a registered pausable contract
    error NotPausable();
    /// @notice Thrown when the address is zero
    error InvalidAddress();
    /// @notice Thrown when the address is already a guardian
    error AlreadyGuardian();
    /// @notice Thrown when the address is not a guardian
    error NotActiveGuardian();
    /// @notice Thrown when removing would drop below MIN_GUARDIANS
    error BelowMinGuardians();
    /// @notice Thrown when the guardian already signed this cancel request
    error AlreadySigned();
    /// @notice Thrown when the contract is already registered as pausable
    error AlreadyRegistered();
    /// @notice Thrown when the contract is not registered as pausable
    error NotRegistered();
    /// @notice Thrown when the cancel call to the timelock fails
    error CancelFailed();

    // Modifiers
    /**
     * @notice Restrict to active guardians only
     */
    modifier onlyGuardian() {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        _;
    }

    /**
     * @notice Restrict to timelock controller only
     */
    modifier onlyTimelock() {
        if (msg.sender != TIMELOCK) revert NotTimelock();
        _;
    }

    /**
     * @notice Deploy the EmergencyGuardian
     * @dev Initializes with an initial set of guardians. The timelock
     *      address is set immutably and cannot be changed.
     * @param timelock Address of OmniTimelockController
     * @param initialGuardians Array of initial guardian addresses (min 5)
     */
    constructor(address timelock, address[] memory initialGuardians) {
        if (timelock == address(0)) revert InvalidAddress();
        if (initialGuardians.length < MIN_GUARDIANS) {
            revert BelowMinGuardians();
        }

        TIMELOCK = timelock;

        for (uint256 i = 0; i < initialGuardians.length; ++i) {
            address guardian = initialGuardians[i];
            if (guardian == address(0)) revert InvalidAddress();
            if (isGuardian[guardian]) revert AlreadyGuardian();
            isGuardian[guardian] = true;
            emit GuardianAdded(guardian);
        }
        guardianCount = initialGuardians.length;
    }

    // =========================================================================
    // Emergency Actions
    // =========================================================================

    /**
     * @notice Pause a registered pausable contract (1-of-N threshold)
     * @dev Any single guardian can trigger an emergency pause. This is
     *      intentionally low-threshold for fast exploit response. Only
     *      governance (via timelock) can unpause.
     * @param target Address of the pausable contract to pause
     */
    function pauseContract(address target) external onlyGuardian {
        if (!isPausable[target]) revert NotPausable();

        IPausable(target).pause();

        // solhint-disable-next-line not-rely-on-time
        emit EmergencyPause(target, msg.sender, block.timestamp);
    }

    /**
     * @notice Sign a cancel request for a queued timelock operation
     * @dev Each guardian calls this individually. When CANCEL_THRESHOLD
     *      signatures are collected, the timelock operation is automatically
     *      cancelled. This prevents execution of malicious governance
     *      proposals.
     * @param operationId The bytes32 ID of the timelock operation to cancel
     */
    function signCancel(bytes32 operationId) external onlyGuardian {
        if (cancelSignatures[operationId][msg.sender]) {
            revert AlreadySigned();
        }

        cancelSignatures[operationId][msg.sender] = true;
        uint256 newCount = ++cancelSignatureCount[operationId];

        emit CancelSigned(operationId, msg.sender, newCount);

        // Auto-execute cancel when threshold reached
        // solhint-disable-next-line gas-strict-inequalities
        if (newCount >= CANCEL_THRESHOLD) {
            _executeCancel(operationId);
        }
    }

    // =========================================================================
    // Guardian Management (Timelock-only)
    // =========================================================================

    /**
     * @notice Add a new guardian
     * @dev Only callable by the timelock (governance decision)
     * @param guardian Address of the new guardian
     */
    function addGuardian(address guardian) external onlyTimelock {
        if (guardian == address(0)) revert InvalidAddress();
        if (isGuardian[guardian]) revert AlreadyGuardian();

        isGuardian[guardian] = true;
        ++guardianCount;

        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian
     * @dev Only callable by the timelock. Cannot drop below MIN_GUARDIANS.
     * @param guardian Address of the guardian to remove
     */
    function removeGuardian(address guardian) external onlyTimelock {
        if (!isGuardian[guardian]) revert NotActiveGuardian();
        if (guardianCount - 1 < MIN_GUARDIANS) {
            revert BelowMinGuardians();
        }

        isGuardian[guardian] = false;
        --guardianCount;

        emit GuardianRemoved(guardian);
    }

    /**
     * @notice Register a contract as pausable by guardians
     * @dev Only callable by the timelock
     * @param target Address of the pausable contract
     */
    function registerPausable(address target) external onlyTimelock {
        if (target == address(0)) revert InvalidAddress();
        if (isPausable[target]) revert AlreadyRegistered();

        isPausable[target] = true;
        ++pausableCount;

        emit PausableRegistered(target);
    }

    /**
     * @notice Deregister a contract from the pausable list
     * @dev Only callable by the timelock
     * @param target Address of the contract to deregister
     */
    function deregisterPausable(address target) external onlyTimelock {
        if (!isPausable[target]) revert NotRegistered();

        isPausable[target] = false;
        --pausableCount;

        emit PausableDeregistered(target);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @notice Execute the cancel on the timelock controller
     * @dev Called internally when CANCEL_THRESHOLD signatures are collected.
     *      Uses a low-level call to TimelockController.cancel(bytes32).
     * @param operationId The timelock operation to cancel
     */
    function _executeCancel(bytes32 operationId) internal {
        // Call timelock.cancel(operationId)
        // The EmergencyGuardian must have CANCELLER_ROLE on the timelock
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = TIMELOCK.call(
            abi.encodeWithSignature("cancel(bytes32)", operationId)
        );

        if (!success) {
            // Bubble up the revert reason
            if (returndata.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(32, returndata), mload(returndata))
                }
            }
            revert CancelFailed();
        }

        emit OperationCancelled(operationId, cancelSignatureCount[operationId]);
    }
}
