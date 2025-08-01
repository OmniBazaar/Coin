// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOmniCoinStaking
 * @author OmniCoin Development Team
 * @notice Interface for OmniCoin staking contract
 * @dev This is a placeholder interface - actual implementation may vary
 */
interface IOmniCoinStaking {
    /**
     * @notice Get total amount staked across all users
     * @return Total staked amount
     */
    function getTotalStaked() external view returns (uint256);
    
    /**
     * @notice Get list of active stakers
     * @return Array of staker addresses
     */
    function getActiveStakers() external view returns (address[] memory);
    
    /**
     * @notice Get stake information for a user
     * @param staker Address of the staker
     * @return amount Staked amount
     * @return tier Staking tier
     * @return commitmentDuration Lock duration
     * @return startTime When stake began
     */
    function getStakeInfo(address staker) 
        external 
        view 
        returns (
            uint256 amount,
            uint256 tier,
            uint256 commitmentDuration,
            uint256 startTime
        );
}