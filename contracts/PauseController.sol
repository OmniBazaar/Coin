// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title PauseController
 * @notice Holds the pause role on money-bearing contracts and separates the cost
 *         of stopping from the cost of restarting.
 *
 *  - Pause: any single guardian. Immediate.
 *  - Unpause: three distinct guardians approve, then anyone executes. Immediate
 *    once the third approval lands.
 *  - Governance (the timelock) can always pause, unpause, and clear approvals.
 *
 * Why not let the guardian contract unpause directly: a single key that both
 * stops and restarts can cycle a contract to mask a live exploit. One key stops,
 * three restart, governance overrides.
 *
 * Guardian membership is read live from the guardian contract, so a signer change
 * is one governance action rather than two.
 *
 * Deliberately dependency-free: no upgradeability, no funds, no token hooks.
 * The only external calls are pause() and unpause() on the target, so the audit
 * surface is this file alone.
 */
interface IPausableTarget {
    function pause() external;
    function unpause() external;
}

interface IGuardianSet {
    function isGuardian(address account) external view returns (bool);
}

contract PauseController {
    /// @notice Distinct guardian approvals required to unpause a target.
    uint256 public constant UNPAUSE_THRESHOLD = 3;

    /// @notice The timelock that administers this controller. Immutable.
    address public immutable TIMELOCK;

    /// @notice The contract whose isGuardian() decides who may pause or approve.
    IGuardianSet public immutable GUARDIANS;

    /// @dev Current approval epoch per target. Bumped on every successful unpause
    ///      and on a governance clear, which invalidates all prior approvals.
    mapping(address => uint256) public approvalEpoch;

    /// @dev target => guardian => epoch in which that guardian approved. Zero
    ///      means no approval in the current epoch.
    mapping(address => mapping(address => uint256)) public approvedAtEpoch;

    /// @dev Count of approvals in the current epoch per target.
    mapping(address => uint256) public approvalCount;

    uint256 private _lock = 1;

    event PausedByGuardian(address indexed target, address indexed guardian);
    event UnpauseApproved(address indexed target, address indexed guardian, uint256 approvals);
    event UnpauseApprovalRevoked(address indexed target, address indexed guardian, uint256 approvals);
    event UnpausedByGuardians(address indexed target, uint256 approvals);
    event ForcedPause(address indexed target, address indexed admin);
    event ForcedUnpause(address indexed target, address indexed admin);
    event ApprovalsCleared(address indexed target, uint256 previousEpoch);

    error NotGuardian(address caller);
    error NotTimelock(address caller);
    error ZeroAddress();
    error Reentrancy();
    error AlreadyApproved();
    error NotApproved();
    error BelowThreshold(uint256 approvals, uint256 required);
    error TargetCallFailed(address target, bytes4 selector);

    modifier onlyGuardian() {
        if (!GUARDIANS.isGuardian(msg.sender)) revert NotGuardian(msg.sender);
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != TIMELOCK) revert NotTimelock(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address timelock, address guardianSet) {
        if (timelock == address(0) || guardianSet == address(0)) revert ZeroAddress();
        TIMELOCK = timelock;
        GUARDIANS = IGuardianSet(guardianSet);
    }

    // ─────────────────────────────────────────────────────────── pause ──

    /// @notice Pause a target immediately. One guardian is enough.
    function pause(address target) external onlyGuardian nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        _call(target, IPausableTarget.pause.selector);
        emit PausedByGuardian(target, msg.sender);
    }

    // ───────────────────────────────────────────────────────── unpause ──

    /// @notice Approve unpausing a target in the current epoch.
    function approveUnpause(address target) external onlyGuardian {
        if (target == address(0)) revert ZeroAddress();
        // Approvals are scoped to the epoch in which they were made. A stored
        // value of zero means "never approved"; the slot is epoch + 1.
        uint256 slot = approvalEpoch[target] + 1;
        if (approvedAtEpoch[target][msg.sender] == slot) revert AlreadyApproved();
        approvedAtEpoch[target][msg.sender] = slot;
        uint256 approvals = approvalCount[target] + 1;
        approvalCount[target] = approvals;
        emit UnpauseApproved(target, msg.sender, approvals);
    }

    /// @notice Withdraw an approval before the threshold executes.
    function revokeUnpause(address target) external onlyGuardian {
        uint256 slot = approvalEpoch[target] + 1;
        if (approvedAtEpoch[target][msg.sender] != slot) revert NotApproved();
        approvedAtEpoch[target][msg.sender] = 0;
        uint256 approvals = approvalCount[target] - 1;
        approvalCount[target] = approvals;
        emit UnpauseApprovalRevoked(target, msg.sender, approvals);
    }

    /// @notice Execute an unpause once three distinct guardians have approved.
    /// @dev Callable by anyone: the approvals are the authority, not the caller.
    function executeUnpause(address target) external nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        uint256 approvals = approvalCount[target];
        if (approvals < UNPAUSE_THRESHOLD) revert BelowThreshold(approvals, UNPAUSE_THRESHOLD);

        // Clear approvals before the external call, so a reverting target cannot
        // replay them and a re-entrant call sees a zero count.
        approvalCount[target] = 0;
        unchecked {
            approvalEpoch[target] += 1;
        }

        _call(target, IPausableTarget.unpause.selector);
        emit UnpausedByGuardians(target, approvals);
    }

    // ──────────────────────────────────────────────── governance override ──

    /// @notice Governance pause. Works even if every guardian is unavailable.
    function forcePause(address target) external onlyTimelock nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        _call(target, IPausableTarget.pause.selector);
        emit ForcedPause(target, msg.sender);
    }

    /// @notice Governance unpause. The always-available restart path.
    function forceUnpause(address target) external onlyTimelock nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        _call(target, IPausableTarget.unpause.selector);
        emit ForcedUnpause(target, msg.sender);
    }

    /// @notice Invalidate every outstanding approval for a target.
    /// @dev Used when a signer is removed, so approvals from that signer cannot
    ///      contribute to a later unpause.
    function clearApprovals(address target) external onlyTimelock {
        uint256 previous = approvalEpoch[target];
        approvalCount[target] = 0;
        unchecked {
            approvalEpoch[target] = previous + 1;
        }
        emit ApprovalsCleared(target, previous);
    }

    // ──────────────────────────────────────────────────────────── views ──

    /// @notice How many approvals are outstanding for a target.
    function approvalsFor(address target) external view returns (uint256) {
        return approvalCount[target];
    }

    /// @notice Whether a guardian has approved in the current epoch.
    function hasApproved(address target, address guardian) external view returns (bool) {
        return approvedAtEpoch[target][guardian] == approvalEpoch[target] + 1;
    }

    // ────────────────────────────────────────────────────────── internal ──

    function _call(address target, bytes4 selector) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = target.call(abi.encodeWithSelector(selector));
        if (!ok) revert TargetCallFailed(target, selector);
    }
}
