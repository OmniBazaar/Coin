// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniSwapRouter
 * @author OmniBazaar Team
 * @notice Minimal interface to the deployed OmniSwapRouter used by
 *         `UnifiedFeeVault.settleNftBuy` for atomic payment-token →
 *         receive-token conversion during coin-agnostic NFT settlement.
 * @dev Mirrors the structs/functions in `contracts/dex/OmniSwapRouter.sol`.
 *      The live router enforces `minAmountOut`, takes its own fee (default
 *      0.30%) from `amountIn` before dispatching to adapters, and returns
 *      the amount actually delivered to `recipient`.
 */
interface IOmniSwapRouter {
    /**
     * @notice Parameters for a single OmniSwapRouter swap
     * @param tokenIn Address of the input token the caller is paying with
     * @param tokenOut Address of the token the recipient receives
     * @param amountIn Amount of `tokenIn` the router may pull from msg.sender
     * @param minAmountOut Minimum acceptable amount of `tokenOut`
     * @param path Ordered list of hop tokens (length 2..4, including ends)
     * @param sources Liquidity-source identifiers, one per hop
     *        (`path.length - 1` entries)
     * @param deadline Unix timestamp after which the swap MUST revert
     * @param recipient Address to receive the swapped `tokenOut`
     */
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

    /**
     * @notice Result of an OmniSwapRouter swap
     * @param amountOut Amount of `tokenOut` delivered to `recipient`
     * @param feeAmount Router-side fee taken from `amountIn`
     * @param route Route identifier (`keccak256(path, sources)`) for logs
     */
    struct SwapResult {
        uint256 amountOut;
        uint256 feeAmount;
        bytes32 route;
    }

    /**
     * @notice Execute an atomic multi-hop swap
     * @dev Pulls `params.amountIn` of `params.tokenIn` from the caller
     *      (who MUST have approved the router), dispatches to registered
     *      liquidity adapters along `params.path` / `params.sources`, and
     *      transfers the resulting `amountOut` to `params.recipient`.
     *      Reverts if `amountOut < params.minAmountOut` or the deadline
     *      is exceeded.
     * @param params Swap parameters, see {SwapParams}.
     * @return result Swap result, see {SwapResult}.
     */
    function swap(
        SwapParams calldata params
    ) external returns (SwapResult memory result);
}
