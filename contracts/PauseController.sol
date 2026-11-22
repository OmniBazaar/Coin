// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title PauseController
 * @notice Holds the pause role on money-bearing contracts and separates the cost
 *         of stopping from the cost of restarting.
 *
 *  - Pause: any single guardian. Immediate.
 *  - Unpause: three distinct guardians approve, a short challenge window passes,
 *    then anyone may execute. Still minutes, not days.
 *  - Governance (the timelock) can always pause, unpause, and clear approvals.
 *
 * Why the challenge window: without it, whoever executes can pick the block and
 * front-run a guardian's revoke. The window makes the revoke always win.
 *
 * Why approvals are invalidated on every pause-state transition: an approval
 * collected while the target was running must not be usable to re-open it after
 * a pause, which is exactly when an incident is in progress.
 *
 * Why approvers are re-validated at execution: a guardian removed between
 * approval and execution must not contribute to the threshold.
 *
 * Guardian membership is read live from the guardian contract, so a signer change
 * is one governance action rather than two.
 *
 * Deliberately dependency-free: no upgradeability, no funds, no token hooks.
 * The only external calls are isGuardian() and pause()/unpause() on the target,
 * so the audit surface is this file alone.
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

    /// @notice Wait between the third approval and execution. Any guardian can
    ///         revoke inside this window, so an execution cannot front-run it.
    uint256 public constant UNPAUSE_DELAY = 1 hours;

    /// @notice The timelock that administers this controller. Immutable.
    address public immutable TIMELOCK;

    /// @notice The contract whose isGuardian() decides who may pause or approve.
    IGuardianSet public immutable GUARDIANS;

    /// @dev Current approval epoch per target. Bumped whenever approvals are
    ///      invalidated (pause, force pause, force unpause, clear, execute).
    mapping(address => uint256) public approvalEpoch;

    /// @dev target => guardian => epoch + 1 in which that guardian approved.
    ///      Zero means no approval in the current epoch.
    mapping(address => mapping(address => uint256)) public approvedAtEpoch;

    /// @dev Every address that approved in the current epoch, in order. Bounded
    ///      by the guardian set size because a second approval in the same epoch
    ///      is refused. Cleared when the epoch advances.
    mapping(address => address[]) private _approvers;

    /// @dev target => approver => 1-based index in _approvers, so a revoke can
    ///      remove the entry instead of leaving a duplicate that would count
    ///      twice at execution.
    mapping(address => mapping(address => uint256)) private _approverIndex;

    /// @dev Count of approvals in the current epoch. Drives the challenge timer;
    ///      the authoritative count at execution is recomputed against the live
    ///      guardian set.
    mapping(address => uint256) public approvalCount;

    /// @dev Timestamp at which the threshold was reached, or zero when not met.
    mapping(address => uint256) public unpauseReadyAt;

    uint256 private _lock = 1;

    event PausedByGuardian(address indexed target, address indexed guardian);
    event UnpauseApproved(address indexed target, address indexed guardian, uint256 approvals, uint256 readyAt);
    event UnpauseApprovalRevoked(address indexed target, address indexed guardian, uint256 approvals);
    event UnpausedByGuardians(address indexed target, uint256 approvals);
    event ForcedPause(address indexed target, address indexed admin);
    event ForcedUnpause(address indexed target, address indexed admin);
    event ApprovalsCleared(address indexed target, uint256 previousEpoch);

    error NotGuardian(address caller);
    error NotTimelock(address caller);
    error ZeroAddress();
    error NotAContract(address target);
    error Reentrancy();
    error AlreadyApproved();
    error NotApproved();
    error BelowThreshold(uint256 approvals, uint256 required);
    error NotReady(uint256 readyAt, uint256 nowTimestamp);
    error TargetCallFailed(address target, bytes4 selector);
    error TargetStateMismatch(address target, bool pausedNow);
    error GuardianProbeFailed();

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
        if (timelock.code.length == 0) revert NotAContract(timelock);
        if (guardianSet.code.length == 0) revert NotAContract(guardianSet);
        // Probe the getter so a mis-wired guardian contract fails the deploy
        // rather than silently reverting every guardian call afterwards.
        (bool probed, bytes memory probeData) = guardianSet.staticcall(
            abi.encodeWithSignature("isGuardian(address)", address(0))
        );
        if (!probed || probeData.length < 32) revert GuardianProbeFailed();
        TIMELOCK = timelock;
        GUARDIANS = IGuardianSet(guardianSet);
    }

    // ─────────────────────────────────────────────────────────── pause ──

    /// @notice Pause a target immediately. One guardian is enough.
    /// @dev Invalidates outstanding approvals: they were collected while the
    ///      target was running and must not re-open it now.
    function pause(address target) external onlyGuardian nonReentrant {
        _requireContract(target);
        _resetApprovals(target);
        _call(target, IPausableTarget.pause.selector, true);
        emit PausedByGuardian(target, msg.sender);
    }

    // ───────────────────────────────────────────────────────── unpause ──

    /// @notice Approve unpausing a target in the current epoch.
    function approveUnpause(address target) external onlyGuardian nonReentrant {
        _requireContract(target);
        uint256 slot = approvalEpoch[target] + 1;
        if (approvedAtEpoch[target][msg.sender] == slot) revert AlreadyApproved();

        approvedAtEpoch[target][msg.sender] = slot;
        _approvers[target].push(msg.sender);
        _approverIndex[target][msg.sender] = _approvers[target].length;

        uint256 approvals = approvalCount[target] + 1;
        approvalCount[target] = approvals;

        uint256 readyAt = unpauseReadyAt[target];
        if (readyAt == 0 && approvals >= UNPAUSE_THRESHOLD) {
            // solhint-disable-next-line not-rely-on-time
            readyAt = block.timestamp + UNPAUSE_DELAY;
            unpauseReadyAt[target] = readyAt;
        }
        emit UnpauseApproved(target, msg.sender, approvals, readyAt);
    }

    /// @notice Withdraw an approval before execution.
    function revokeUnpause(address target) external onlyGuardian nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        uint256 slot = approvalEpoch[target] + 1;
        if (approvedAtEpoch[target][msg.sender] != slot) revert NotApproved();

        approvedAtEpoch[target][msg.sender] = 0;
        _removeApprover(target, msg.sender);
        uint256 approvals = approvalCount[target] - 1;
        approvalCount[target] = approvals;
        if (approvals < UNPAUSE_THRESHOLD) unpauseReadyAt[target] = 0;

        emit UnpauseApprovalRevoked(target, msg.sender, approvals);
    }

    /// @notice Execute an unpause once the threshold has held for the challenge window.
    /// @dev Callable by anyone: the approvals are the authority, not the caller.
    ///      Approvers are re-validated against the live guardian set here, so a
    ///      signer removed after approving cannot contribute.
    function executeUnpause(address target) external nonReentrant {
        _requireContract(target);

        uint256 valid = _validApprovalCount(target);
        if (valid < UNPAUSE_THRESHOLD) revert BelowThreshold(valid, UNPAUSE_THRESHOLD);

        uint256 readyAt = unpauseReadyAt[target];
        // solhint-disable-next-line not-rely-on-time
        if (readyAt == 0 || block.timestamp < readyAt) revert NotReady(readyAt, block.timestamp);

        // Consume approvals before the external call. A reverting target unwinds
        // the whole transaction, restoring this state, so a retry keeps them.
        _resetApprovals(target);

        _call(target, IPausableTarget.unpause.selector, false);
        emit UnpausedByGuardians(target, valid);
    }

    // ──────────────────────────────────────────────── governance override ──

    /// @notice Governance pause. Works even if every guardian is unavailable.
    function forcePause(address target) external onlyTimelock nonReentrant {
        _requireContract(target);
        _resetApprovals(target);
        _call(target, IPausableTarget.pause.selector, true);
        emit ForcedPause(target, msg.sender);
    }

    /// @notice Governance unpause.
    /// @dev This is only the restart path if the target accepts the controller
    ///      (or the timelock itself) on unpause. Several targets gate unpause on
    ///      DEFAULT_ADMIN_ROLE while gating pause on a guardian role, so wiring
    ///      must grant the controller the unpause role too, or those targets must
    ///      be upgraded before this path works. Invalidates approvals, so a stale
    ///      count cannot survive a governance restart.
    function forceUnpause(address target) external onlyTimelock nonReentrant {
        _requireContract(target);
        _resetApprovals(target);
        _call(target, IPausableTarget.unpause.selector, false);
        emit ForcedUnpause(target, msg.sender);
    }

    /// @notice Invalidate every outstanding approval for a target.
    function clearApprovals(address target) external onlyTimelock nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        uint256 previous = approvalEpoch[target];
        _resetApprovals(target);
        emit ApprovalsCleared(target, previous);
    }

    // ──────────────────────────────────────────────────────────── views ──

    /// @notice Stored approval count for a target, in the current epoch.
    function approvalsFor(address target) external view returns (uint256) {
        return approvalCount[target];
    }

    /// @notice Approvals that would count if execution were attempted now.
    function validApprovalsFor(address target) external view returns (uint256) {
        return _validApprovalCount(target);
    }

    /// @notice Whether a guardian has approved in the current epoch.
    function hasApproved(address target, address guardian) external view returns (bool) {
        return approvedAtEpoch[target][guardian] == approvalEpoch[target] + 1;
    }

    // ────────────────────────────────────────────────────────── internal ──

    /// @dev Count approvers of the current epoch that are still guardians.
    function _validApprovalCount(address target) private view returns (uint256 valid) {
        uint256 slot = approvalEpoch[target] + 1;
        address[] storage list = _approvers[target];
        for (uint256 i = 0; i < list.length; ++i) {
            address approver = list[i];
            if (approvedAtEpoch[target][approver] == slot && GUARDIANS.isGuardian(approver)) {
                unchecked {
                    ++valid;
                }
            }
        }
    }

    /// @dev Swap-and-pop an approver so a later re-approval cannot leave a
    ///      duplicate that would be counted twice at execution.
    function _removeApprover(address target, address approver) private {
        uint256 index = _approverIndex[target][approver];
        if (index == 0) return;
        address[] storage list = _approvers[target];
        address last = list[list.length - 1];
        list[index - 1] = last;
        _approverIndex[target][last] = index;
        list.pop();
        delete _approverIndex[target][approver];
    }

    /// @dev Clear the current epoch's approvals and advance the epoch so stale
    ///      slots can never match again.
    function _resetApprovals(address target) private {
        delete _approvers[target];
        approvalCount[target] = 0;
        unpauseReadyAt[target] = 0;
        unchecked {
            approvalEpoch[target] += 1;
        }
    }

    function _requireContract(address target) private view {
        if (target == address(0)) revert ZeroAddress();
        if (target.code.length == 0) revert NotAContract(target);
    }

    /// @dev Call the target and, when it exposes a paused() getter, verify the
    ///      state actually changed. A target whose pause() is a silent no-op
    ///      would otherwise be reported as halted.
    function _call(address target, bytes4 selector, bool expectPaused) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = target.call(abi.encodeWithSelector(selector));
        if (!ok) revert TargetCallFailed(target, selector);

        // solhint-disable-next-line avoid-low-level-calls
        (bool hasView, bytes memory data) = target.staticcall(abi.encodeWithSignature("paused()"));
        if (hasView && data.length >= 32) {
            bool pausedNow = abi.decode(data, (bool));
            if (pausedNow != expectPaused) revert TargetStateMismatch(target, pausedNow);
        }
    }
}
