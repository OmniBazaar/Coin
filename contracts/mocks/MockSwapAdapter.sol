// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ISwapAdapter
 * @notice Duplicate of the interface defined in OmniSwapRouter for mock use
 */
interface ISwapAdapter {
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}

/**
 * @title MockSwapAdapter
 * @author OmniBazaar Development Team
 * @notice Mock ISwapAdapter for testing OmniSwapRouter swap paths
 * @dev Simulates token swaps with a configurable exchange rate.
 *      Pulls tokenIn from the caller via transferFrom and mints
 *      tokenOut to the recipient using the MockERC20 mint function.
 *
 *      Exchange rate is expressed as a multiplier with 18-decimal
 *      precision: outputAmount = inputAmount * exchangeRate / 1e18.
 */
contract MockSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Exchange rate numerator (output = input * rate / 1e18)
    uint256 public exchangeRate;

    /// @notice Whether the next swap call should revert
    bool public shouldRevert;

    /**
     * @notice Deploy the mock swap adapter
     * @param _exchangeRate Rate: output = input * rate / 1e18
     */
    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    /**
     * @notice Set the exchange rate
     * @param _rate New rate (output = input * _rate / 1e18)
     */
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /**
     * @notice Toggle forced revert on next swap
     * @param _shouldRevert Whether to revert
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @inheritdoc ISwapAdapter
     * @dev Pulls tokenIn from msg.sender, mints tokenOut to recipient
     *      at the configured exchange rate. The tokenOut address must
     *      be a MockERC20 with a public mint(address,uint256) function.
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external override returns (uint256 amountOut) {
        require(!shouldRevert, "MockSwapAdapter: forced revert");

        // Pull input tokens from caller (the router)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Calculate output
        amountOut = (amountIn * exchangeRate) / 1e18;

        // Mint output tokens to recipient (must be MockERC20)
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = tokenOut.call(
            abi.encodeWithSignature(
                "mint(address,uint256)",
                recipient,
                amountOut
            )
        );
        require(success, "MockSwapAdapter: mint failed");
    }

    /**
     * @inheritdoc ISwapAdapter
     * @dev Returns estimated output based on exchange rate
     */
    function getAmountOut(
        address, /* tokenIn */
        address, /* tokenOut */
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        amountOut = (amountIn * exchangeRate) / 1e18;
    }
}
