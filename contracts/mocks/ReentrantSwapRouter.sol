// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "../interfaces/IFeeSwapRouter.sol";

/**
 * @title IOmniSwapRouterForReentrant (local copy)
 * @author OmniBazaar Team
 * @notice Mirrors the IOmniSwapRouter interface from FeeSwapAdapter
 */
interface IOmniSwapRouterForReentrant {
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
 * @title ReentrantSwapRouter
 * @author OmniBazaar Team
 * @notice Malicious IOmniSwapRouter that attempts reentrancy
 * @dev During swap(), calls back into the adapter's swapExactInput
 *      to test reentrancy protection.
 */
contract ReentrantSwapRouter is IOmniSwapRouterForReentrant {
    using SafeERC20 for IERC20;

    /// @notice The adapter contract to re-enter
    IFeeSwapRouter public adapter;

    /// @notice Token addresses for the re-entrant call
    address public reenterTokenIn;

    /// @notice Token addresses for the re-entrant call
    address public reenterTokenOut;

    /// @notice Whether reentrancy has been attempted
    bool public reentrancyAttempted;

    /**
     * @notice Configure the reentrancy attack parameters
     * @param _adapter Adapter to call back into
     * @param _tokenIn Input token for the re-entrant swap
     * @param _tokenOut Output token for the re-entrant swap
     */
    function configure(
        address _adapter,
        address _tokenIn,
        address _tokenOut
    ) external {
        adapter = IFeeSwapRouter(_adapter);
        reenterTokenIn = _tokenIn;
        reenterTokenOut = _tokenOut;
    }

    /**
     * @inheritdoc IOmniSwapRouterForReentrant
     * @dev Attempts reentrancy into the adapter's swapExactInput
     */
    function swap(
        SwapParams calldata params
    ) external override returns (SwapResult memory result) {
        // Pull input tokens as a normal router would
        IERC20(params.tokenIn).safeTransferFrom(
            msg.sender, address(this), params.amountIn
        );

        // Attempt reentrancy
        reentrancyAttempted = true;
        // solhint-disable-next-line not-rely-on-time
        adapter.swapExactInput(
            reenterTokenIn,
            reenterTokenOut,
            params.amountIn,
            0,
            msg.sender,
            block.timestamp + 3600
        );

        result.amountOut = 0;
        result.feeAmount = 0;
        result.route = bytes32(0);
    }
}
