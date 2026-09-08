// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IMinimalEscrowResolve
 * @author OmniCoin Development Team
 * @notice Minimal interface to MinimalEscrow.resolveDispute for testing
 */
interface IMinimalEscrowResolve {
    /**
     * @notice Resolve a dispute by releasing or refunding escrow
     * @param escrowId Escrow ID to resolve
     * @param releaseFunds True to release to seller, false to refund buyer
     */
    function resolveDispute(uint256 escrowId, bool releaseFunds) external;
}

/**
 * @title MockEscrowArbitrationResolver
 * @author OmniCoin Development Team
 * @notice Test-only stand-in for OmniArbitration that forwards
 *         resolveDispute calls to a MinimalEscrow instance
 * @dev Used to exercise MinimalEscrow's onlyArbitration external
 *      resolution path (where the arbitration fee routes 100% to the
 *      fee vault) without deploying the full OmniArbitration stack.
 */
contract MockEscrowArbitrationResolver {
    /**
     * @notice Forward a dispute resolution to the escrow contract
     * @param escrow MinimalEscrow contract address
     * @param escrowId Escrow ID to resolve
     * @param releaseFunds True to release to seller, false to refund buyer
     */
    function resolve(
        address escrow,
        uint256 escrowId,
        bool releaseFunds
    ) external {
        IMinimalEscrowResolve(escrow).resolveDispute(escrowId, releaseFunds);
    }
}
