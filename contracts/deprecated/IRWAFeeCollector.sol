// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRWAFeeCollector
 * @author OmniCoin Development Team
 * @notice Interface for the RWA fee collection and distribution contract
 * @custom:deprecated Superseded by UnifiedFeeVault
 * @dev Used by RWAAMM to notify the fee collector of received fees
 */
interface IRWAFeeCollector {
    /**
     * @notice Notify the collector that fees have been received via direct transfer
     * @dev Called by the AMM after transferring fee tokens directly to the collector.
     *      Updates internal accounting (accumulatedFees, _feeTokens) without
     *      requiring a separate transferFrom.
     * @param token Address of the fee token received
     * @param amount Amount of fee tokens received
     */
    function notifyFeeReceived(address token, uint256 amount) external;
}
