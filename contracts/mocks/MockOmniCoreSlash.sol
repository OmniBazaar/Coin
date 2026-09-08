// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockOmniCoreSlash
 * @author OmniBazaar Team
 * @notice Test double for the minimal OmniCore surface AttestationFraudHandler
 *         depends on (`getStake` / `slash` / `OMNI_COIN`). `slash` reduces the
 *         staked amount and transfers the slashed XOM to the caller, mirroring
 *         OmniCore's production behavior.
 */
contract MockOmniCoreSlash {
    using SafeERC20 for IERC20;

    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    IERC20 public token;
    mapping(address => Stake) public stakes;

    event Slashed(address indexed validator, uint256 amount);

    constructor(address _token) {
        token = IERC20(_token);
    }

    function OMNI_COIN() external view returns (address) {
        return address(token);
    }

    function setStake(address validator, uint256 amount, bool active) external {
        stakes[validator] = Stake({
            amount: amount,
            tier: 1,
            duration: 0,
            lockTime: 0,
            active: active
        });
    }

    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    function slash(address validator, uint256 amount) external {
        Stake storage s = stakes[validator];
        require(s.active, "inactive");
        require(amount <= s.amount, "exceeds");
        s.amount -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Slashed(validator, amount);
    }
}
