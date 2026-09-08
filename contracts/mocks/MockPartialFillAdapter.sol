// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ISwapAdapterPartial
 * @notice Local copy of the ISwapAdapter interface from OmniSwapRouter
 */
interface ISwapAdapterPartial {
    /// @notice Execute a token swap
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Estimate the output for a swap
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}

/**
 * @title MockPartialFillAdapter
 * @author OmniCoin Development Team
 * @notice Mock ISwapAdapter that simulates a CLOB partial fill: it pulls the
 *         FULL requested `amountIn` from the router, consumes only a
 *         configured fraction of it, and refunds the unconsumed remainder back
 *         to the router (msg.sender). This reproduces the CLOBAdapter residual
 *         behavior that RT-CC-01 fixes on the router side.
 */
contract MockPartialFillAdapter is ISwapAdapterPartial {
    using SafeERC20 for IERC20;

    /// @notice Fraction of the input actually consumed, in basis points
    uint256 public fillBps;

    /// @notice Exchange rate (output = consumed * rate / 1e18)
    uint256 public exchangeRate;

    /**
     * @notice Deploy the partial-fill mock
     * @param _fillBps Fraction consumed (10000 = full fill)
     * @param _exchangeRate Output per consumed input (1e18 = 1:1)
     */
    constructor(uint256 _fillBps, uint256 _exchangeRate) {
        fillBps = _fillBps;
        exchangeRate = _exchangeRate;
    }

    /**
     * @notice Set the consumed fraction (basis points)
     * @param _fillBps New fraction (10000 = full fill)
     */
    function setFillBps(uint256 _fillBps) external {
        fillBps = _fillBps;
    }

    /**
     * @inheritdoc ISwapAdapterPartial
     * @dev Pulls the full amountIn, mints output for `amountIn * fillBps`,
     *      and refunds the unconsumed input back to msg.sender.
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256, /* minAmountOut */
        address recipient
    ) external override returns (uint256 amountOut) {
        // Pull the full requested input, like CLOBAdapter does.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 consumed = (amountIn * fillBps) / 10_000;
        amountOut = (consumed * exchangeRate) / 1e18;

        // Refund the unconsumed input back to the router.
        uint256 residual = amountIn - consumed;
        if (residual > 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, residual);
        }

        // Mint output (tokenOut must expose a public mint).
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = tokenOut.call(
            abi.encodeWithSignature("mint(address,uint256)", recipient, amountOut)
        );
        require(success, "PartialFillAdapter: mint failed");
    }

    /**
     * @inheritdoc ISwapAdapterPartial
     */
    function getAmountOut(
        address, /* tokenIn */
        address, /* tokenOut */
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        uint256 consumed = (amountIn * fillBps) / 10_000;
        amountOut = (consumed * exchangeRate) / 1e18;
    }
}
