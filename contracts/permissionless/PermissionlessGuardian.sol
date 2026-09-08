// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IEmergencyGuardian } from "../interfaces/IEmergencyGuardian.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title PermissionlessGuardian
 * @author OmniCoin Development Team
 * @notice Lightweight emergency guardian for external-chain deployments
 * @dev AMMPermissionless requires an IEmergencyGuardian that answers
 *      `isGuardian(address)` to authorize 3-of-N pause signatures. The
 *      full EmergencyGuardian on the home chain (88008) is bound to a
 *      timelock and a governance multisig which do not yet exist on
 *      Ethereum, Arbitrum, Base, or Polygon. This contract is the minimal
 *      shim deployed on external chains at launch.
 *
 *      Design:
 *      - Single owner (deployer initially) can add/remove guardians
 *      - Ownership is two-step to prevent fat-finger transfers
 *      - Requires at least 3 guardians to satisfy PAUSE_THRESHOLD checks
 *      - After multisig infrastructure ships on a chain, ownership of this
 *        contract will be transferred to the new multisig, which will then
 *        rotate guardians to its members
 *
 *      This contract is immutable (not UUPS) — the expected upgrade path is
 *      to deploy a fuller on-chain guardian (e.g., a timelocked Safe) later
 *      and transfer AMMPermissionless authority through a new deployment,
 *      not to mutate this contract.
 */
contract PermissionlessGuardian is IEmergencyGuardian, Ownable2Step {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when a zero address is supplied where disallowed
    error ZeroAddress();
    /// @notice Thrown when attempting to add an already-active guardian
    error AlreadyGuardian(address account);
    /// @notice Thrown when attempting to remove an inactive guardian
    error NotGuardian(address account);
    /// @notice Thrown when the guardian set would exceed the maximum size
    error MaxGuardiansExceeded();

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a guardian is added or removed
    event GuardianUpdated(address indexed account, bool indexed active);

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Whether an address is an active guardian
    mapping(address => bool) private _isGuardian;

    /// @notice Current number of active guardians
    uint256 public guardianCount;

    /// @notice Maximum number of guardians (bounds 3-of-N signature-verification gas)
    uint256 public constant MAX_GUARDIANS = 21;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploys the guardian with an initial guardian set
     * @param initialOwner Contract owner who can mutate the guardian set
     * @param initialGuardians Array of guardian addresses to seed (>= 3)
     * @dev At least 3 guardians are required so that AMMPermissionless
     *      PAUSE_THRESHOLD (3-of-N) can be satisfied from day one. Passing
     *      the same address multiple times is rejected (duplicates).
     */
    constructor(
        address initialOwner,
        address[] memory initialGuardians
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        uint256 len = initialGuardians.length;
        if (len < 3) revert NotGuardian(address(0));
        if (len > MAX_GUARDIANS) revert MaxGuardiansExceeded();
        for (uint256 i = 0; i < len; ++i) {
            address g = initialGuardians[i];
            if (g == address(0)) revert ZeroAddress();
            if (_isGuardian[g]) revert AlreadyGuardian(g);
            _isGuardian[g] = true;
            emit GuardianUpdated(g, true);
        }
        guardianCount = len;
    }

    // ========================================================================
    // OWNER OPERATIONS
    // ========================================================================

    /**
     * @notice Add a new guardian
     * @param account Address to grant guardian status
     */
    function addGuardian(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (_isGuardian[account]) revert AlreadyGuardian(account);
        if (guardianCount >= MAX_GUARDIANS) revert MaxGuardiansExceeded();
        _isGuardian[account] = true;
        unchecked { ++guardianCount; }
        emit GuardianUpdated(account, true);
    }

    /**
     * @notice Remove an existing guardian
     * @param account Address to revoke guardian status
     * @dev Reverts if doing so would drop the set below 3 guardians,
     *      preserving AMMPermissionless pause viability.
     */
    function removeGuardian(address account) external onlyOwner {
        if (!_isGuardian[account]) revert NotGuardian(account);
        if (guardianCount <= 3) revert NotGuardian(account);
        _isGuardian[account] = false;
        unchecked { --guardianCount; }
        emit GuardianUpdated(account, false);
    }

    // ========================================================================
    // OWNERSHIP SAFETY
    // ========================================================================

    /**
     * @notice Renouncing ownership would permanently freeze the guardian set.
     * @dev Override to prevent irreversible lockout. Ownership transfer is
     *      still possible via the two-step transferOwnership flow.
     */
    function renounceOwnership() public view override onlyOwner {
        revert("Cannot renounce: guardian set would be permanently frozen");
    }

    // ========================================================================
    // VIEW
    // ========================================================================

    /**
     * @inheritdoc IEmergencyGuardian
     */
    function isGuardian(address account) external view override returns (bool) {
        return _isGuardian[account];
    }
}
