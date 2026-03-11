// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IOmniSwapRouter (local copy for mock)
 * @author OmniBazaar Team
 * @notice Mirrors the interface declared inside FeeSwapAdapter.sol
 */
interface IOmniSwapRouter {
    /// @notice Swap parameters
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address[] path;
        bytes32[] sources;
        uint256 deadline;
        address recipient;
    }

    /// @notice Swap result
    struct SwapResult {
        uint256 amountOut;
        uint256 feeAmount;
        bytes32 route;
    }

    /// @notice Execute a token swap
    function swap(
        SwapParams calldata params
    ) external returns (SwapResult memory result);
}

/**
 * @title MockOmniSwapRouter
 * @author OmniBazaar Team
 * @notice Mock IOmniSwapRouter for testing FeeSwapAdapter
 * @dev Simulates token swaps with a configurable exchange rate.
 *      Pulls tokenIn from caller (the adapter), mints tokenOut to
 *      the recipient specified in SwapParams using ERC20Mock.mint().
 */
contract MockOmniSwapRouter is IOmniSwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Thrown when shouldRevert is true
    error ForcedRevert();

    /// @notice Thrown when output token mint fails
    error MintFailed();

    /// @notice Exchange rate numerator (output = input * rate / 1e18)
    uint256 public exchangeRate;

    /// @notice Fee amount to report in SwapResult
    uint256 public feeAmount;

    /// @notice Whether to revert on next swap call
    bool public shouldRevert;

    /// @notice Whether to skip minting (simulate zero output)
    bool public skipMint;

    /// @notice Last swap params received (for verification)
    SwapParams public lastSwapParams;

    /// @notice Total number of swap calls
    uint256 public swapCallCount;

    /**
     * @notice Deploy the mock swap router
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
     * @notice Set the fee amount reported in SwapResult
     * @param _feeAmount Fee amount to report
     */
    function setFeeAmount(uint256 _feeAmount) external {
        feeAmount = _feeAmount;
    }

    /**
     * @notice Toggle whether swaps should revert
     * @param _shouldRevert Whether to revert
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @notice Toggle whether to skip minting output tokens
     * @param _skipMint Whether to skip mint
     */
    function setSkipMint(bool _skipMint) external {
        skipMint = _skipMint;
    }

    /**
     * @inheritdoc IOmniSwapRouter
     * @dev Pulls tokenIn from caller, mints tokenOut to recipient
     *      at the configured exchange rate.
     */
    function swap(
        SwapParams calldata params
    ) external override returns (SwapResult memory result) {
        if (shouldRevert) revert ForcedRevert();

        swapCallCount++;

        // Pull input tokens from caller (the adapter)
        IERC20(params.tokenIn).safeTransferFrom(
            msg.sender, address(this), params.amountIn
        );

        // Calculate output using exchange rate
        uint256 amountOut = (params.amountIn * exchangeRate) / 1e18;

        if (!skipMint && amountOut > 0) {
            // Mint output tokens to recipient (the adapter)
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = params.tokenOut.call(
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    params.recipient,
                    amountOut
                )
            );
            if (!success) revert MintFailed();
        }

        result.amountOut = amountOut;
        result.feeAmount = feeAmount;
        result.route = keccak256("mock-route");
    }
}
