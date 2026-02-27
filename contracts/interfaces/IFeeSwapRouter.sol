// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IFeeSwapRouter
 * @author OmniBazaar Team
 * @notice Minimal interface decoupling the UnifiedFeeVault from
 *         the full OmniSwapRouter SwapParams struct.
 * @dev The vault calls this single function to convert any ERC-20
 *      fee token into XOM before bridging to the ODDAO treasury.
 *      The concrete adapter (FeeSwapAdapter) translates this call
 *      into the OmniSwapRouter.swap(SwapParams) format.
 */
interface IFeeSwapRouter {
    /**
     * @notice Swap an exact input amount of one token for another
     * @dev The caller MUST have approved this contract for `amountIn`
     *      of `tokenIn` before calling. The adapter pulls tokens via
     *      safeTransferFrom, executes the swap, and sends output
     *      tokens to `recipient`.
     * @param tokenIn  Address of the input ERC-20 token
     * @param tokenOut Address of the desired output ERC-20 token
     * @param amountIn Exact amount of `tokenIn` to swap
     * @param amountOutMin Minimum acceptable output (slippage guard)
     * @param recipient Address to receive the output tokens
     * @return amountOut Actual amount of `tokenOut` delivered
     */
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external returns (uint256 amountOut);
}
