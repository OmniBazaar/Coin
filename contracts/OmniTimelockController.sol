// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title OmniTimelockController
 * @author OmniCoin Development Team
 * @notice Two-tier timelock controller for OmniBazaar governance
 * @dev Extends OpenZeppelin TimelockController with a dual-delay system:
 *
 * Delay Tiers:
 * - ROUTINE (48 hours): Parameter changes, service registry updates,
 *   fee adjustments, scoring weight changes. These operations are
 *   lower-risk and benefit from faster execution while still allowing
 *   community observation.
 * - CRITICAL (7 days): Contract upgrades (UUPS upgradeTo/upgradeToAndCall),
 *   role management (grantRole/revokeRole/renounceRole), pause/unpause,
 *   delay changes (updateDelay), and critical selector management
 *   (addCriticalSelector/removeCriticalSelector). These operations have
 *   the highest potential impact and require extended community review.
 *
 * The contract identifies critical operations by checking function selectors
 * in scheduled calldata. If any call in a batch targets a critical selector,
 * the entire batch uses the 7-day delay.
 *
 * Relationship with OmniGovernance:
 * - OmniGovernance creates proposals and, upon successful vote, calls
 *   scheduleBatch() on this timelock via the PROPOSER_ROLE.
 * - OmniGovernance classifies proposals as ROUTINE or CRITICAL, but this
 *   timelock independently validates the delay requirement based on
 *   function selectors, providing defense-in-depth.
 * - After the timelock delay expires, anyone can call executeBatch()
 *   (EXECUTOR_ROLE is granted to address(0) for open execution).
 * - EmergencyGuardian holds CANCELLER_ROLE and can cancel queued
 *   operations with a 3-of-N guardian threshold.
 *
 * Role architecture:
 * - PROPOSER_ROLE: OmniGovernance (and initial multisig during Phase 1)
 * - EXECUTOR_ROLE: address(0) = anyone can execute after delay
 * - CANCELLER_ROLE: EmergencyGuardian
 * - TIMELOCK_ADMIN_ROLE: self (changes go through timelock itself)
 *
 * This contract is immutable (not UUPS). Upgrades to timelock parameters
 * are executed through the timelock itself via updateDelay().
 */
contract OmniTimelockController is TimelockController {
    // Constants
    /// @notice Delay for routine operations (parameter changes, fee adjustments)
    uint256 public constant ROUTINE_DELAY = 48 hours;

    /// @notice Delay for critical operations (upgrades, role changes, ossification)
    uint256 public constant CRITICAL_DELAY = 7 days;

    // Critical function selectors (4-byte signatures)
    /// @notice UUPS upgrade selector: upgradeTo(address)
    bytes4 public constant SEL_UPGRADE_TO = 0x3659cfe6;

    /// @notice UUPS upgrade selector: upgradeToAndCall(address,bytes)
    bytes4 public constant SEL_UPGRADE_TO_AND_CALL = 0x4f1ef286;

    /// @notice AccessControl selector: grantRole(bytes32,address)
    bytes4 public constant SEL_GRANT_ROLE = 0x2f2ff15d;

    /// @notice AccessControl selector: revokeRole(bytes32,address)
    bytes4 public constant SEL_REVOKE_ROLE = 0xd547741f;

    /// @notice AccessControl selector: renounceRole(bytes32,address)
    bytes4 public constant SEL_RENOUNCE_ROLE = 0x36568abe;

    /// @notice Pausable selector: pause()
    bytes4 public constant SEL_PAUSE = 0x8456cb59;

    /// @notice Pausable selector: unpause()
    bytes4 public constant SEL_UNPAUSE = 0x3f4ba83a;

    /// @notice TimelockController selector: updateDelay(uint256)
    /// @dev M-01: Classified as critical to prevent 48h delay reduction
    bytes4 public constant SEL_UPDATE_DELAY = 0x64d62353;

    /// @notice Self selector: addCriticalSelector(bytes4)
    /// @dev M-02: Classified as critical to prevent 48h selector changes
    bytes4 public constant SEL_ADD_CRITICAL = 0xb634ebcf;

    /// @notice Self selector: removeCriticalSelector(bytes4)
    /// @dev M-02: Classified as critical to prevent 48h selector changes
    bytes4 public constant SEL_REMOVE_CRITICAL = 0x199e6fef;

    // State
    /// @notice Registry of additional critical selectors (admin-extensible)
    mapping(bytes4 => bool) private _criticalSelectors;

    /// @notice Count of registered critical selectors
    uint256 public criticalSelectorCount;

    // Events
    /// @notice Emitted when a critical selector is added or removed
    /// @param selector The 4-byte function selector
    /// @param isCritical Whether the selector is now classified as critical
    event CriticalSelectorUpdated(
        bytes4 indexed selector,
        bool indexed isCritical
    );

    // Custom errors
    /// @notice Thrown when delay is below the required minimum for the operation
    error DelayBelowCriticalMinimum(uint256 provided, uint256 required);

    /// @notice Thrown when caller is not the timelock itself
    error OnlySelfCall();

    /**
     * @notice Deploy the two-tier timelock controller
     * @dev Sets ROUTINE_DELAY as the base minimum. Critical operations
     *      enforce CRITICAL_DELAY via schedule/scheduleBatch overrides.
     *      Registers hardcoded critical selectors on deployment.
     * @param proposers Initial addresses with PROPOSER_ROLE
     * @param executors Initial addresses with EXECUTOR_ROLE (address(0) = anyone)
     * @param admin Initial admin address (should renounce after setup)
     */
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address admin
    )
        TimelockController(ROUTINE_DELAY, proposers, executors, admin)
    {
        // Register hardcoded critical selectors
        _criticalSelectors[SEL_UPGRADE_TO] = true;
        _criticalSelectors[SEL_UPGRADE_TO_AND_CALL] = true;
        _criticalSelectors[SEL_GRANT_ROLE] = true;
        _criticalSelectors[SEL_REVOKE_ROLE] = true;
        _criticalSelectors[SEL_RENOUNCE_ROLE] = true;
        _criticalSelectors[SEL_PAUSE] = true;
        _criticalSelectors[SEL_UNPAUSE] = true;
        // M-01: updateDelay must require 7-day delay
        _criticalSelectors[SEL_UPDATE_DELAY] = true;
        // M-02: Selector management must require 7-day delay
        _criticalSelectors[SEL_ADD_CRITICAL] = true;
        _criticalSelectors[SEL_REMOVE_CRITICAL] = true;
        criticalSelectorCount = 10;
    }

    // =========================================================================
    // External Functions (Critical Selector Management)
    // =========================================================================

    /**
     * @notice Register a new critical function selector
     * @dev M-03 fix: Only callable through the timelock itself via a
     *      scheduled operation (self-administration pattern matching
     *      updateDelay()). This function is itself classified as critical
     *      (M-02), requiring 7-day delay for selector changes.
     *      Adding a critical selector means future calls to functions with
     *      that selector will require CRITICAL_DELAY instead of ROUTINE_DELAY.
     * @param selector The 4-byte function selector to classify as critical
     */
    function addCriticalSelector(bytes4 selector) external {
        if (msg.sender != address(this)) revert OnlySelfCall();
        if (!_criticalSelectors[selector]) {
            _criticalSelectors[selector] = true;
            ++criticalSelectorCount;
            emit CriticalSelectorUpdated(selector, true);
        }
    }

    /**
     * @notice Remove a critical function selector
     * @dev M-03 fix: Only callable through the timelock itself via a
     *      scheduled operation. This function is itself classified as
     *      critical (M-02), requiring 7-day delay for selector changes.
     *      Hardcoded selectors (upgrade, role management, pause) can be
     *      removed but this is strongly discouraged.
     * @param selector The 4-byte function selector to declassify
     */
    function removeCriticalSelector(bytes4 selector) external {
        if (msg.sender != address(this)) revert OnlySelfCall();
        if (_criticalSelectors[selector]) {
            _criticalSelectors[selector] = false;
            --criticalSelectorCount;
            emit CriticalSelectorUpdated(selector, false);
        }
    }

    /**
     * @notice Check if a function selector is classified as critical
     * @param selector The 4-byte function selector to check
     * @return isCritical True if the selector requires CRITICAL_DELAY
     */
    function isCriticalSelector(
        bytes4 selector
    ) external view returns (bool isCritical) {
        return _criticalSelectors[selector];
    }

    /**
     * @notice Get the required delay for a given calldata payload
     * @dev Returns CRITICAL_DELAY if the selector is critical, otherwise
     *      the base minimum delay (ROUTINE_DELAY).
     * @param data Encoded function call to analyze
     * @return delay The minimum required delay in seconds
     */
    function getRequiredDelay(
        bytes calldata data
    ) external view returns (uint256 delay) {
        if (_isCriticalCall(data)) {
            return CRITICAL_DELAY;
        }
        return getMinDelay();
    }

    /**
     * @notice Get the required delay for a batch of calldata payloads
     * @dev Returns CRITICAL_DELAY if any payload is critical
     * @param payloads Array of encoded function calls to analyze
     * @return delay The minimum required delay in seconds
     */
    function getBatchRequiredDelay(
        bytes[] calldata payloads
    ) external view returns (uint256 delay) {
        if (_batchContainsCritical(payloads)) {
            return CRITICAL_DELAY;
        }
        return getMinDelay();
    }

    /**
     * @notice Batch-check whether multiple selectors are critical
     * @dev L-04: Allows frontends and monitoring systems to verify the
     *      complete critical selector set without replaying all events.
     * @param selectors Array of 4-byte function selectors to check
     * @return results Array of booleans (true = critical)
     */
    function areCriticalSelectors(
        bytes4[] calldata selectors
    ) external view returns (bool[] memory results) {
        results = new bool[](selectors.length);
        for (uint256 i = 0; i < selectors.length; ++i) {
            results[i] = _criticalSelectors[selectors[i]];
        }
    }

    // =========================================================================
    // Public Function Overrides (Two-Tier Schedule)
    // =========================================================================

    /**
     * @notice Schedule a single-call operation with two-tier delay enforcement
     * @dev If the call targets a critical selector, the delay must be at least
     *      CRITICAL_DELAY (7 days). Otherwise, ROUTINE_DELAY (48h) is the
     *      minimum (enforced by parent TimelockController._schedule).
     * @param target Contract to call
     * @param value ETH value to send
     * @param data Encoded function call (selector + arguments)
     * @param predecessor Dependency on another operation (0x0 = none)
     * @param salt Unique identifier for this operation
     * @param delay Requested delay in seconds
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        if (_isCriticalCall(data) && delay < CRITICAL_DELAY) {
            revert DelayBelowCriticalMinimum(delay, CRITICAL_DELAY);
        }
        super.schedule(target, value, data, predecessor, salt, delay);
    }

    /**
     * @notice Schedule a batch operation with two-tier delay enforcement
     * @dev If ANY call in the batch targets a critical selector, the delay
     *      for the entire batch must be at least CRITICAL_DELAY (7 days).
     * @param targets Array of contracts to call
     * @param values Array of ETH values to send
     * @param payloads Array of encoded function calls
     * @param predecessor Dependency on another operation (0x0 = none)
     * @param salt Unique identifier for this operation
     * @param delay Requested delay in seconds
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        if (_batchContainsCritical(payloads) && delay < CRITICAL_DELAY) {
            revert DelayBelowCriticalMinimum(delay, CRITICAL_DELAY);
        }
        super.scheduleBatch(
            targets, values, payloads, predecessor, salt, delay
        );
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @notice Check if a single calldata payload targets a critical selector
     * @dev Extracts the first 4 bytes (function selector) and checks the
     *      critical selector registry. Returns false for empty calldata
     *      (plain ETH transfers are not critical).
     * @param data Encoded function call
     * @return True if the call targets a critical function
     */
    function _isCriticalCall(
        bytes calldata data
    ) internal view returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector = bytes4(data[:4]);
        return _criticalSelectors[selector];
    }

    /**
     * @notice Check if any payload in a batch targets a critical selector
     * @dev Iterates through all payloads and returns true on first match.
     *      A batch is as critical as its most critical operation.
     * @param payloads Array of encoded function calls
     * @return True if any call in the batch targets a critical function
     */
    function _batchContainsCritical(
        bytes[] calldata payloads
    ) internal view returns (bool) {
        for (uint256 i = 0; i < payloads.length; ++i) {
            // solhint-disable-next-line gas-strict-inequalities
            if (payloads[i].length >= 4) {
                bytes4 selector = bytes4(payloads[i][:4]);
                if (_criticalSelectors[selector]) return true;
            }
        }
        return false;
    }
}
