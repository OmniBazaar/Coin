// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockOmniCoreForAttestation
 * @notice Test-only stub exposing `getStake(address)` in the exact shape
 *         the `RandomCommitteeVerifier` expects. Lets tests set the (amount,
 *         active) tuple per address without exercising the full OmniCore
 *         staking flow.
 */
contract MockOmniCoreForAttestation {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    mapping(address user => Stake stake) private _stakes;

    /// @notice Test helper: set the stake row for a user.
    function setStake(address user, uint256 amount, bool active) external {
        _stakes[user] = Stake({
            amount: amount,
            tier: 0,
            duration: 0,
            lockTime: 0,
            active: active
        });
    }

    function getStake(address user) external view returns (Stake memory) {
        return _stakes[user];
    }
}
