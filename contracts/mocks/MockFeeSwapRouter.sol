// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "../interfaces/IFeeSwapRouter.sol";

/**
 * @title MockFeeSwapRouter
 * @author OmniBazaar Team
 * @notice Mock IFeeSwapRouter for testing UnifiedFeeVault swap flows
 * @dev Simulates token swaps with a configurable exchange rate.
 *      Pulls tokenIn from caller, mints tokenOut to recipient using
 *      the configured rate. The "output" token must have a public
 *      mint() function (e.g., MockERC20).
 */
contract MockFeeSwapRouter is IFeeSwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Exchange rate numerator (output = input * rate / 1e18)
    uint256 public exchangeRate;

    /// @notice Whether to revert on next swap call
    bool public shouldRevert;

    /// @notice Output token to mint (must be MockERC20 with mint())
    address public outputToken;

    /**
     * @notice Deploy the mock swap router
     * @param _exchangeRate Rate: output = input * rate / 1e18
     * @param _outputToken MockERC20 address to mint on swaps
     */
    constructor(uint256 _exchangeRate, address _outputToken) {
        exchangeRate = _exchangeRate;
        outputToken = _outputToken;
    }

    /**
     * @notice Set the exchange rate
     * @param _rate New rate (output = input * _rate / 1e18)
     */
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /**
     * @notice Toggle whether swaps should revert
     * @param _shouldRevert Whether to revert
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @inheritdoc IFeeSwapRouter
     * @dev Pulls tokenIn, mints outputToken to recipient at the
     *      configured exchange rate.
     */
    function swapExactInput(
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        uint256, /* amountOutMin */
        address recipient
    ) external override returns (uint256 amountOut) {
        require(!shouldRevert, "MockFeeSwapRouter: forced revert");

        // Pull input tokens from caller
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // Calculate output using exchange rate
        amountOut = (amountIn * exchangeRate) / 1e18;

        // Mint output tokens to recipient
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = outputToken.call(
            abi.encodeWithSignature(
                "mint(address,uint256)",
                recipient,
                amountOut
            )
        );
        require(success, "MockFeeSwapRouter: mint failed");
    }
}
