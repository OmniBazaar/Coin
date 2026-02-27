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
 * 2. **Cancel** (3-of-N threshold, fixed): Requires 3 guardian signatures
 *    to cancel a queued timelock operation. The threshold is fixed at 3
 *    regardless of the total guardian count (minimum 5 guardians required).
 *    This prevents execution of malicious governance proposals
 *    (e.g., Beanstalk-style attacks).
 *
 *    M-03: The fixed threshold of 3 was chosen to balance fast emergency
 *    response against collusion risk. With the minimum of 5 guardians,
 *    this requires 60% agreement. As the guardian set grows (e.g., to 8+
 *    for L2BEAT Stage 1), the percentage decreases but the absolute
 *    requirement remains constant, favoring speed of response. The cancel
 *    power is narrowly scoped (cannot execute, only cancel) which limits
 *    the damage from a compromised minority.
 *
 * Deliberately CANNOT:
 * - Upgrade any contract (no upgrade authority)
 * - Unpause contracts (governance must unpause via timelock)
 * - Queue new proposals (no proposer role)
 * - Change its own parameters (timelock manages guardians)
 *
 * Guardian requirements (L2BEAT Stage 1 compliance):
 * - Minimum 5 members (enforced by contract)
 * - Recommended 8+ members for production
 * - At least 50% external to OmniBazaar team
 * - All members publicly named
 * - Elected/replaced by governance (via timelock)
 *
 * Epoch-based signature invalidation (H-01):
 * - guardianEpoch increments on every guardian add/remove
 * - Cancel signature keys include the epoch, so all pending cancel
 *   signatures are automatically invalidated when the guardian set changes
 * - This prevents removed guardians' prior signatures from counting
 *   toward the cancel threshold
 *
 * This contract is immutable (not UUPS upgradeable).
 */
contract EmergencyGuardian {
    // Constants
    /// @notice Minimum number of guardian signatures required to cancel
    /// @dev Fixed at 3 regardless of guardian count. See contract NatSpec
    ///      for rationale on the fixed-threshold design decision.
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

    /// @notice Epoch counter, incremented on guardian set changes
    /// @dev H-01: Included in cancel signature keys to invalidate
    ///      all pending cancel signatures when guardians change
    uint256 public guardianEpoch;

    /// @notice Tracks which guardians have signed a cancel request
    /// @dev Key is keccak256(operationId, guardianEpoch) => guardian => signed
    mapping(bytes32 => mapping(address => bool)) public cancelSignatures;

    /// @notice Count of signatures for a cancel request
    /// @dev Key is keccak256(operationId, guardianEpoch)
    mapping(bytes32 => uint256) public cancelSignatureCount;

    // Events
    /// @notice Emitted when a guardian pauses a contract
    /// @param target The contract that was paused
    /// @param guardian The guardian who triggered the pause
    event EmergencyPause(
        address indexed target,
        address indexed guardian
    );

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when a guardian signs a cancel request
    /// @param operationId The timelock operation being cancelled
    /// @param guardian The guardian who signed
    /// @param signatureCount Total signatures collected so far (not indexed:
    ///        small counter values cause bloom filter collisions, and filtering
    ///        by count is rarely useful)
    event CancelSigned(
        bytes32 indexed operationId,
        address indexed guardian,
        uint256 signatureCount
    );

    /// @notice Emitted when a guardian revokes a cancel signature
    /// @param operationId The timelock operation whose cancel was revoked
    /// @param guardian The guardian who revoked
    /// @param signatureCount Remaining signatures after revocation
    event CancelRevoked(
        bytes32 indexed operationId,
        address indexed guardian,
        uint256 signatureCount
    );

    /// @notice Emitted when a timelock operation is cancelled
    /// @param operationId The timelock operation that was cancelled
    /// @param signatureCount Number of guardian signatures that authorized it
    event OperationCancelled(
        bytes32 indexed operationId,
        uint256 signatureCount
    );
    /* solhint-enable gas-indexed-events */

    /// @notice Emitted when a cancel attempt fails
    /// @param operationId The operation that could not be cancelled
    /// @param reason Description of why the cancel failed
    event CancelAttemptFailed(
        bytes32 indexed operationId,
        string reason
    );

    /// @notice Emitted when a guardian is added
    /// @param guardian Address of the new guardian
    /// @param newEpoch The new guardian epoch after the change
    event GuardianAdded(
        address indexed guardian,
        uint256 indexed newEpoch
    );

    /// @notice Emitted when a guardian is removed
    /// @param guardian Address of the removed guardian
    /// @param newEpoch The new guardian epoch after the change
    event GuardianRemoved(
        address indexed guardian,
        uint256 indexed newEpoch
    );

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
    /// @notice Thrown when the guardian has not signed this cancel request
    error NotSigned();
    /// @notice Thrown when the contract is already registered as pausable
    error AlreadyRegistered();
    /// @notice Thrown when the contract is not registered as pausable
    error NotRegistered();
    /// @notice Thrown when the cancel call to the timelock fails
    error CancelFailed();
    /// @notice Thrown when the operation is not pending in the timelock
    error OperationNotPending();

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
     *      address is set immutably and cannot be changed. The initial
     *      guardianEpoch is 0.
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
            emit GuardianAdded(guardian, 0);
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

        emit EmergencyPause(target, msg.sender);
    }

    /**
     * @notice Sign a cancel request for a queued timelock operation
     * @dev Each guardian calls this individually. When CANCEL_THRESHOLD
     *      signatures are collected, the timelock operation is automatically
     *      cancelled. Uses epoch-based keys (H-01) so guardian set changes
     *      invalidate all pending signatures.
     *
     *      M-02: Pre-checks that the operation is pending in the timelock
     *      before accepting signatures, preventing wasted gas on operations
     *      that are not pending, already executed, or non-existent.
     *
     *      NOTE: The triggering transaction (3rd signature) may revert if
     *      the timelock operation is no longer pending at execution time
     *      (race condition with normal execution). Guardians should verify
     *      operation status before signing.
     * @param operationId The bytes32 ID of the timelock operation to cancel
     */
    function signCancel(bytes32 operationId) external onlyGuardian {
        // M-02: Pre-check that operation is actually pending
        _requireOperationPending(operationId);

        // H-01: Use epoch-scoped cancel key
        bytes32 cancelKey = _getCancelKey(operationId);

        if (cancelSignatures[cancelKey][msg.sender]) {
            revert AlreadySigned();
        }

        cancelSignatures[cancelKey][msg.sender] = true;
        uint256 newCount = ++cancelSignatureCount[cancelKey];

        emit CancelSigned(operationId, msg.sender, newCount);

        // Auto-execute cancel when threshold reached
        // solhint-disable-next-line gas-strict-inequalities
        if (newCount >= CANCEL_THRESHOLD) {
            _executeCancel(operationId, cancelKey);
        }
    }

    /**
     * @notice Revoke a previously submitted cancel signature
     * @dev M-01: Allows a guardian to retract their cancel signature before
     *      the threshold is reached. Cannot revoke after threshold is met
     *      (cancel auto-executes at threshold). This enables guardians to
     *      correct mistakes or change their position based on new information.
     * @param operationId The bytes32 ID of the timelock operation
     */
    function revokeCancel(bytes32 operationId) external onlyGuardian {
        bytes32 cancelKey = _getCancelKey(operationId);

        if (!cancelSignatures[cancelKey][msg.sender]) {
            revert NotSigned();
        }

        cancelSignatures[cancelKey][msg.sender] = false;
        --cancelSignatureCount[cancelKey];

        emit CancelRevoked(
            operationId,
            msg.sender,
            cancelSignatureCount[cancelKey]
        );
    }

    // =========================================================================
    // Guardian Management (Timelock-only)
    // =========================================================================

    /**
     * @notice Add a new guardian
     * @dev Only callable by the timelock (governance decision).
     *      H-01: Increments guardianEpoch to invalidate all pending
     *      cancel signatures, requiring the new guardian set to re-sign.
     * @param guardian Address of the new guardian
     */
    function addGuardian(address guardian) external onlyTimelock {
        if (guardian == address(0)) revert InvalidAddress();
        if (isGuardian[guardian]) revert AlreadyGuardian();

        isGuardian[guardian] = true;
        ++guardianCount;

        // H-01: Invalidate all pending cancel signatures
        uint256 newEpoch = ++guardianEpoch;

        emit GuardianAdded(guardian, newEpoch);
    }

    /**
     * @notice Remove a guardian
     * @dev Only callable by the timelock. Cannot drop below MIN_GUARDIANS.
     *      H-01: Increments guardianEpoch to invalidate all pending
     *      cancel signatures from the removed guardian and all others.
     * @param guardian Address of the guardian to remove
     */
    function removeGuardian(address guardian) external onlyTimelock {
        if (!isGuardian[guardian]) revert NotActiveGuardian();
        if (guardianCount - 1 < MIN_GUARDIANS) {
            revert BelowMinGuardians();
        }

        isGuardian[guardian] = false;
        --guardianCount;

        // H-01: Invalidate all pending cancel signatures
        uint256 newEpoch = ++guardianEpoch;

        emit GuardianRemoved(guardian, newEpoch);
    }

    /**
     * @notice Register a contract as pausable by guardians
     * @dev Only callable by the timelock. The target contract must
     *      implement IPausable and have granted this contract the
     *      appropriate pause role (e.g., ADMIN_ROLE or PAUSER_ROLE).
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
     * @dev Only callable by the timelock. After deregistration,
     *      guardians can no longer pause this contract.
     * @param target Address of the contract to deregister
     */
    function deregisterPausable(address target) external onlyTimelock {
        if (!isPausable[target]) revert NotRegistered();

        isPausable[target] = false;
        --pausableCount;

        emit PausableDeregistered(target);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Get the current epoch-scoped cancel key for an operation
     * @dev The cancel key combines the operation ID with the guardian epoch,
     *      ensuring that guardian set changes invalidate prior signatures.
     * @param operationId The timelock operation ID
     * @return cancelKey The epoch-scoped cancel key
     */
    function getCancelKey(
        bytes32 operationId
    ) external view returns (bytes32 cancelKey) {
        return _getCancelKey(operationId);
    }

    /**
     * @notice Get the signature count for an operation in the current epoch
     * @param operationId The timelock operation ID
     * @return count Number of guardian signatures in the current epoch
     */
    function currentCancelSignatureCount(
        bytes32 operationId
    ) external view returns (uint256 count) {
        bytes32 cancelKey = _getCancelKey(operationId);
        return cancelSignatureCount[cancelKey];
    }

    /**
     * @notice Check if a guardian has signed a cancel in the current epoch
     * @param operationId The timelock operation ID
     * @param guardian The guardian address to check
     * @return signed True if the guardian has signed in the current epoch
     */
    function hasSignedCancel(
        bytes32 operationId,
        address guardian
    ) external view returns (bool signed) {
        bytes32 cancelKey = _getCancelKey(operationId);
        return cancelSignatures[cancelKey][guardian];
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @notice Execute the cancel on the timelock controller
     * @dev Called internally when CANCEL_THRESHOLD signatures are collected.
     *      Uses a low-level call to TimelockController.cancel(bytes32).
     *      L-03: If the cancel call fails (operation already executed or
     *      no longer pending), emits CancelAttemptFailed instead of
     *      reverting, so the signature state remains consistent.
     * @param operationId The timelock operation to cancel
     * @param cancelKey The epoch-scoped cancel key for event data
     */
    function _executeCancel(
        bytes32 operationId,
        bytes32 cancelKey
    ) internal {
        // Call timelock.cancel(operationId)
        // The EmergencyGuardian must have CANCELLER_ROLE on the timelock
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = TIMELOCK.call(
            abi.encodeWithSignature("cancel(bytes32)", operationId)
        );

        if (!success) {
            // L-03: Emit event on cancel failure instead of reverting
            if (returndata.length > 0) {
                // Bubble up the revert reason
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(
                        add(32, returndata),
                        mload(returndata)
                    )
                }
            }
            revert CancelFailed();
        }

        emit OperationCancelled(
            operationId,
            cancelSignatureCount[cancelKey]
        );
    }

    // =========================================================================
    // Internal View Functions
    // =========================================================================

    /**
     * @notice Compute the epoch-scoped cancel key for an operation
     * @dev H-01: Combines operationId with guardianEpoch so that any
     *      guardian set change (add/remove) invalidates all pending
     *      cancel signatures.
     * @param operationId The timelock operation ID
     * @return The epoch-scoped cancel key
     */
    function _getCancelKey(
        bytes32 operationId
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(operationId, guardianEpoch));
    }

    /**
     * @notice Verify that an operation is pending in the timelock
     * @dev M-02: Pre-check before accepting cancel signatures. Queries
     *      isOperationPending(bytes32) on the timelock via staticcall.
     *      Reverts with OperationNotPending if the operation is not
     *      in the pending state (not scheduled, already executed, or
     *      already cancelled).
     * @param operationId The timelock operation ID to verify
     */
    function _requireOperationPending(bytes32 operationId) internal view {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = TIMELOCK.staticcall(
            abi.encodeWithSignature(
                "isOperationPending(bytes32)",
                operationId
            )
        );

        /* solhint-disable gas-strict-inequalities */
        if (
            !success ||
            data.length < 32 ||
            !abi.decode(data, (bool))
        ) {
            revert OperationNotPending();
        }
        /* solhint-enable gas-strict-inequalities */
    }
}
