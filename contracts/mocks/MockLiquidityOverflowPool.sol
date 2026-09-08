// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLiquidityOverflowPool
 * @notice Mock for testing ValidatorRewards V3 overflow routing
 * @dev Records distributeOverflow calls for test assertions.
 *      Can be configured to revert for circuit-breaker testing.
 */
contract MockLiquidityOverflowPool {
    using SafeERC20 for IERC20;

    /// @notice XOM token reference
    IERC20 public xomToken;

    /// @notice Total overflow received
    uint256 public totalReceived;

    /// @notice Number of times distributeOverflow was called
    uint256 public callCount;

    /// @notice Last amount received
    uint256 public lastAmount;

    /// @notice If true, distributeOverflow will revert
    bool public shouldRevert;

    /**
     * @notice Deploy with XOM token reference
     * @param xomToken_ Address of the XOM token
     */
    constructor(address xomToken_) {
        xomToken = IERC20(xomToken_);
    }

    /**
     * @notice Configure whether to revert on distributeOverflow
     * @param revert_ True to make calls revert
     */
    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    /**
     * @notice Receive overflow rewards (mirrors ILiquidityOverflowPool)
     * @param amount XOM overflow amount
     */
    function distributeOverflow(uint256 amount) external {
        if (shouldRevert) {
            revert("MockOverflowPool: forced revert");
        }

        // Pull XOM from caller (ValidatorRewards)
        xomToken.safeTransferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        lastAmount = amount;
        ++callCount;
    }
}
