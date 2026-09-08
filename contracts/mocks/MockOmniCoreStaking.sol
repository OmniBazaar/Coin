// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniCoreStaking
 * @notice Duplicated interface for the mock (avoids import path issues)
 */
interface IOmniCoreStaking {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    function getStake(address user) external view returns (Stake memory);
}

/**
 * @title MockOmniCoreStaking
 * @author OmniBazaar Team
 * @notice Mock implementation of IOmniCoreStaking for testing
 *         StakingRewardPool in isolation.
 * @dev Allows test scripts to set arbitrary stake data per address.
 *      Also supports a "revert mode" to simulate OmniCore being
 *      unavailable (for try/catch fallback tests).
 */
contract MockOmniCoreStaking is IOmniCoreStaking {
    /// @notice Per-user stake data set by tests
    mapping(address => Stake) private _stakes;

    /// @notice When true, getStake() always reverts
    bool public shouldRevert;

    /**
     * @notice Set stake data for a user
     * @param user Address of the staker
     * @param amount Staked amount (18 decimals)
     * @param tier Staking tier (1-5)
     * @param duration Lock duration in seconds
     * @param lockTime Timestamp when lock expires
     * @param active Whether the stake is active
     */
    function setStake(
        address user,
        uint256 amount,
        uint256 tier,
        uint256 duration,
        uint256 lockTime,
        bool active
    ) external {
        _stakes[user] = Stake({
            amount: amount,
            tier: tier,
            duration: duration,
            lockTime: lockTime,
            active: active
        });
    }

    /**
     * @notice Toggle revert mode for simulating OmniCore unavailability
     * @param _shouldRevert True to make getStake() revert
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @notice Get stake information for a user
     * @param user Address of the staker
     * @return Stake struct with staking details
     */
    function getStake(
        address user
    ) external view override returns (Stake memory) {
        require(!shouldRevert, "MockOmniCoreStaking: reverted");
        return _stakes[user];
    }
}
