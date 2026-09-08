// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockDEXRouterForFeeRouter
 * @author OmniBazaar Team
 * @notice Mock DEX router for testing OmniFeeRouter swap flows.
 * @dev Simulates an external DEX swap called via low-level `call()`
 *      from OmniFeeRouter. Pulls approved inputToken from the caller
 *      (the fee router), mints outputToken to the caller at a
 *      configurable exchange rate. The output token must have a
 *      public `mint()` function (e.g., MockERC20).
 */
contract MockDEXRouterForFeeRouter {
    using SafeERC20 for IERC20;

    /// @notice Thrown when shouldRevert is true
    error ForcedRevert();

    /// @notice Thrown when output token mint fails
    error MintFailed();

    /// @notice Exchange rate numerator (output = input * rate / 1e18)
    uint256 public exchangeRate;

    /// @notice Whether to revert on next swap call
    bool public shouldRevert;

    /// @notice Number of input tokens to leave unconsumed (partial fill)
    uint256 public leaveUnconsumed;

    /// @notice Total number of swap calls received
    uint256 public swapCallCount;

    /**
     * @notice Deploy the mock DEX router.
     * @param _exchangeRate Rate: output = input * rate / 1e18.
     */
    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    /**
     * @notice Set the exchange rate.
     * @param _rate New rate (output = input * _rate / 1e18).
     */
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /**
     * @notice Toggle whether swaps should revert.
     * @param _shouldRevert Whether to revert.
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @notice Set how many input tokens to leave unconsumed.
     * @param _amount Amount of input tokens to not pull from caller.
     */
    function setLeaveUnconsumed(uint256 _amount) external {
        leaveUnconsumed = _amount;
    }

    /**
     * @notice Simulate a DEX swap: pull input tokens, mint output tokens.
     * @dev Called by OmniFeeRouter via low-level call with encoded calldata.
     *      Pulls inputToken from msg.sender (the fee router), then mints
     *      outputToken to msg.sender at the configured exchange rate.
     * @param inputToken  Token to pull from caller.
     * @param outputToken Token to mint to caller (must be MockERC20).
     * @param amountIn    Amount of input tokens to consume.
     * @return amountOut  Amount of output tokens produced.
     */
    function swap(
        address inputToken,
        address outputToken,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        if (shouldRevert) revert ForcedRevert();
        swapCallCount++;

        // Consume input tokens (optionally leaving some unconsumed)
        uint256 toConsume = amountIn;
        if (leaveUnconsumed > 0 && toConsume > leaveUnconsumed) {
            toConsume = amountIn - leaveUnconsumed;
        }
        IERC20(inputToken).safeTransferFrom(
            msg.sender, address(this), toConsume
        );

        // Calculate and mint output
        amountOut = (toConsume * exchangeRate) / 1e18;
        if (amountOut > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = outputToken.call(
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    msg.sender,
                    amountOut
                )
            );
            if (!success) revert MintFailed();
        }
    }
}
