// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "./interfaces/IFeeSwapRouter.sol";

// ════════════════════════════════════════════════════════════════════
//  Forward-declare the OmniSwapRouter interface we actually call
// ════════════════════════════════════════════════════════════════════

/**
 * @title IOmniSwapRouter
 * @author OmniBazaar Team
 * @notice Subset of OmniSwapRouter used by this adapter
 */
interface IOmniSwapRouter {
    /// @notice Swap parameters (mirrors OmniSwapRouter.SwapParams)
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

    /**
     * @notice Execute a token swap
     * @param params Swap parameters
     * @return result Swap result
     */
    function swap(
        SwapParams calldata params
    ) external returns (SwapResult memory result);
}

// ════════════════════════════════════════════════════════════════════
//                        FEE SWAP ADAPTER
// ════════════════════════════════════════════════════════════════════

/**
 * @title FeeSwapAdapter
 * @author OmniBazaar Team
 * @notice Bridges the minimal {IFeeSwapRouter} interface to the full
 *         {OmniSwapRouter.swap(SwapParams)} call.
 * @dev Non-upgradeable. Deployed once per network and pointed at
 *      the live OmniSwapRouter. Uses {Ownable2Step} for safe admin
 *      transfer and disables {renounceOwnership}.
 *
 * Flow:
 *   1. UnifiedFeeVault approves this adapter for `tokenIn`
 *   2. Vault calls swapExactInput(...)
 *   3. Adapter pulls tokenIn via safeTransferFrom
 *   4. Adapter approves OmniSwapRouter via forceApprove
 *   5. Adapter calls router.swap(...) with recipient = caller
 *   6. Router sends tokenOut to the vault (caller)
 */
contract FeeSwapAdapter is IFeeSwapRouter, Ownable2Step {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════
    //                        STATE VARIABLES
    // ════════════════════════════════════════════════════════════════

    /// @notice OmniSwapRouter contract used for actual swaps
    IOmniSwapRouter public router;

    /// @notice Default liquidity source identifier for single-hop swaps
    bytes32 public defaultSource;

    // ════════════════════════════════════════════════════════════════
    //                            EVENTS
    // ════════════════════════════════════════════════════════════════

    /// @notice Emitted when the router address is updated
    /// @param oldRouter Previous router address
    /// @param newRouter New router address
    event RouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted when the default liquidity source is updated
    /// @param oldSource Previous source identifier
    /// @param newSource New source identifier
    event DefaultSourceUpdated(
        bytes32 indexed oldSource,
        bytes32 indexed newSource
    );

    // ════════════════════════════════════════════════════════════════
    //                         CUSTOM ERRORS
    // ════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when the swap output is below the minimum
    /// @param received Actual output amount
    /// @param minimum Required minimum amount
    error InsufficientOutput(uint256 received, uint256 minimum);

    // ════════════════════════════════════════════════════════════════
    //                         CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the FeeSwapAdapter
     * @param _router OmniSwapRouter contract address
     * @param _defaultSource Default liquidity source ID for swaps
     * @param _owner Initial owner (admin)
     */
    constructor(
        address _router,
        bytes32 _defaultSource,
        address _owner
    ) Ownable(_owner) {
        if (_router == address(0)) revert ZeroAddress();

        router = IOmniSwapRouter(_router);
        defaultSource = _defaultSource;
    }

    // ════════════════════════════════════════════════════════════════
    //                      EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IFeeSwapRouter
     * @dev Pulls tokenIn from msg.sender, approves the router,
     *      executes a single-hop swap via OmniSwapRouter, and
     *      sends tokenOut directly to `recipient`.
     */
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external override returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (recipient == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();

        // 1. Pull input tokens from caller (vault)
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // 2. Approve router to spend our tokens
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // 3. Build single-hop swap path
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        bytes32[] memory sources = new bytes32[](1);
        sources[0] = defaultSource;

        // 4. Execute swap — recipient receives tokenOut directly
        IOmniSwapRouter.SwapResult memory result = router.swap(
            IOmniSwapRouter.SwapParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: amountOutMin,
                path: path,
                sources: sources,
                deadline: block.timestamp, // solhint-disable-line not-rely-on-time
                recipient: recipient
            })
        );

        amountOut = result.amountOut;

        // 5. Enforce slippage protection
        if (amountOut < amountOutMin) {
            revert InsufficientOutput(amountOut, amountOutMin);
        }
    }

    // ════════════════════════════════════════════════════════════════
    //                       ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════

    /**
     * @notice Update the OmniSwapRouter address
     * @param _router New router contract address
     */
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();

        address oldRouter = address(router);
        router = IOmniSwapRouter(_router);

        emit RouterUpdated(oldRouter, _router);
    }

    /**
     * @notice Update the default liquidity source identifier
     * @param _source New default source ID
     */
    function setDefaultSource(bytes32 _source) external onlyOwner {
        bytes32 oldSource = defaultSource;
        defaultSource = _source;

        emit DefaultSourceUpdated(oldSource, _source);
    }

    /**
     * @notice Disabled to prevent accidental loss of admin control
     * @dev Always reverts. Use transferOwnership + acceptOwnership.
     */
    function renounceOwnership() public pure override {
        revert ZeroAddress();
    }
}
