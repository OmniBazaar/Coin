// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";

/**
 * @title MockRWAAMM
 * @notice Mock RWAAMM for testing RWAAMMAdapter
 * @dev Simulates swap behavior with a configurable exchange rate.
 *      Takes tokenIn, sends back tokenOut at the configured rate.
 */
contract MockRWAAMM {
    using SafeERC20 for IERC20;

    /// @notice Exchange rate numerator (output per 1 input, scaled by 1e18)
    uint256 public exchangeRate;

    /// @notice Protocol fee in basis points
    uint256 public constant PROTOCOL_FEE_BPS = 30;

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Last swap caller
    address public lastCaller;

    /// @notice Last onBehalfOf value
    address public lastOnBehalfOf;

    /**
     * @notice Deploy with exchange rate
     * @param rate Exchange rate (1e18 = 1:1)
     */
    constructor(uint256 rate) {
        exchangeRate = rate;
    }

    /**
     * @notice Set the exchange rate
     * @param rate New rate (1e18 = 1:1)
     */
    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    /**
     * @notice Get a quote for a swap
     * @param tokenIn Input token (unused in mock)
     * @param tokenOut Output token (unused in mock)
     * @param amountIn Input amount
     * @return amountOut Output amount after fee
     * @return protocolFee Fee amount
     * @return priceImpact Always 0 in mock
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 protocolFee,
        uint256 priceImpact
    ) {
        // Silence unused variable warnings
        tokenIn;
        tokenOut;

        protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - protocolFee;
        amountOut = (afterFee * exchangeRate) / 1e18;
        priceImpact = 0;
    }

    /**
     * @notice Execute a swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param amountOutMin Minimum output (unused in mock)
     * @param deadline Deadline (unused in mock)
     * @param onBehalfOf On behalf of address
     * @return result Swap result
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address onBehalfOf
    ) external returns (IRWAAMM.SwapResult memory result) {
        // Silence unused variable warnings
        amountOutMin;
        deadline;

        lastCaller = msg.sender;
        lastOnBehalfOf = onBehalfOf;

        // Take tokenIn from caller
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // Calculate output
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - protocolFee;
        uint256 amountOut = (afterFee * exchangeRate) / 1e18;

        // Send tokenOut to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        // Build result
        address[] memory route = new address[](2);
        route[0] = tokenIn;
        route[1] = tokenOut;

        result = IRWAAMM.SwapResult({
            amountIn: amountIn,
            amountOut: amountOut,
            protocolFee: protocolFee,
            priceImpact: 0,
            route: route
        });
    }
}
