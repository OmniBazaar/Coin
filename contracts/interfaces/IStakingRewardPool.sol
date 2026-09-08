// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStakingRewardPool
 * @author OmniCoin Development Team
 * @notice Minimum surface OmniCore needs from the off-chain reward pool to
 *         snapshot a staker's accrued rewards immediately before the
 *         principal is returned.
 * @dev Introduced by OMNICORE-DECENT (FIX_OMNICORE_DECENTRALIZATION).
 *      OmniCore.unlock() wraps the call in a try/catch — a pool reversion
 *      MUST NOT block principal withdrawal. Concrete implementation lives
 *      in the validator-side StakingRewardPool service; the on-chain
 *      contract only depends on this slim interface so the staking-reward
 *      pool is free to upgrade independently of OmniCore.
 */
interface IStakingRewardPool {
    /**
     * @notice Capture `user`'s accrued (unclaimed) reward balance so the
     *         off-chain reward distributor can pay it out independently of
     *         the principal unstake transaction.
     * @dev OmniCore.unlock() calls this BEFORE clearing the on-chain stake
     *      slot. Implementations MUST be reentrancy-safe (called inside the
     *      `nonReentrant` modifier on `unlock`) and MUST tolerate being
     *      called more than once for the same user (idempotent capture or
     *      monotonic-non-decreasing snapshot are both acceptable).
     * @param user Address whose reward balance is being snapshotted.
     */
    function snapshotRewards(address user) external;
}
