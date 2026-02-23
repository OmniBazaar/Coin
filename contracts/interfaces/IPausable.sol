// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPausable
 * @author OmniCoin Development Team
 * @notice Interface for contracts that can be paused by the EmergencyGuardian
 * @dev All OmniBazaar contracts that inherit PausableUpgradeable or Pausable
 *      and expose a public pause() function conform to this interface.
 */
interface IPausable {
    /**
     * @notice Pause the contract
     * @dev Caller must have the appropriate role (ADMIN_ROLE or DEFAULT_ADMIN_ROLE)
     */
    function pause() external;
}
