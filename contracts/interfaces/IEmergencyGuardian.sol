// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IEmergencyGuardian
 * @author OmniCoin Development Team
 * @notice Minimal interface for querying guardian membership
 * @dev Used by RWAAMM to delegate emergency signer verification
 *      to the EmergencyGuardian contract, enabling guardian rotation
 *      via timelock governance without redeploying the AMM.
 */
interface IEmergencyGuardian {
    /**
     * @notice Check whether an address is an active guardian
     * @param account The address to query
     * @return True if the account is currently a guardian
     */
    function isGuardian(address account) external view returns (bool);
}
