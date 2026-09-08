// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStakingRewardPool} from "../interfaces/IStakingRewardPool.sol";

/**
 * @title MockStakingRewardPoolSnapshot
 * @author OmniBazaar Team
 * @notice Happy-path implementation of {IStakingRewardPool} for OmniCore
 *         H-02 test coverage. Records every `snapshotRewards` call by
 *         emitting `Snapshotted(address user)` so tests can assert the
 *         try-block executed.
 */
contract MockStakingRewardPoolSnapshot is IStakingRewardPool {
    /// @notice Emitted on every successful `snapshotRewards` call.
    /// @param user Address whose rewards were snapshotted.
    event Snapshotted(address indexed user);

    /// @inheritdoc IStakingRewardPool
    function snapshotRewards(address user) external override {
        emit Snapshotted(user);
    }
}

/**
 * @title MockStakingRewardPoolReverting
 * @author OmniBazaar Team
 * @notice Adversarial implementation of {IStakingRewardPool} that always
 *         reverts. OmniCore's `unlock` MUST swallow the revert via try/catch
 *         and still deliver principal back to the staker. Tests assert that
 *         the staker's balance increases by the staked amount even though
 *         `snapshotRewards` failed.
 */
contract MockStakingRewardPoolReverting is IStakingRewardPool {
    /// @notice Thrown by `snapshotRewards` so OmniCore must catch it.
    error SnapshotIntentionallyReverted();

    /// @inheritdoc IStakingRewardPool
    function snapshotRewards(address) external pure override {
        revert SnapshotIntentionallyReverted();
    }
}
