// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "./OmniSwapRouter.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";

/**
 * @title RWAAMMAdapter
 * @author OmniBazaar Team
 * @notice Adapter implementing ISwapAdapter for RWAAMM pool routing
 * @dev Bridges OmniSwapRouter to RWAAMM by translating ISwapAdapter
 *      calls into RWAAMM.swap() and RWAAMM.getQuote() calls.
 *
 *      RWAAMM is intentionally non-upgradeable ("maintain legal
 *      defensibility — ODDAO has no control over trading logic after
 *      deployment"). This adapter is a thin wrapper that lets
 *      OmniSwapRouter route trades through RWAAMM pools without
 *      modifying the RWAAMM contract.
 *
 *      After deployment, register with OmniSwapRouter:
 *        OmniSwapRouter.addLiquiditySource("RWAAMM", adapterAddress)
 *
 * Security:
 * - Immutable RWAAMM + router references (cannot be changed post-deploy)
 * - Only OmniSwapRouter can call executeSwap (onlyRouter modifier)
 * - Deadline set to block.timestamp (MEV protection delegated to router)
 * - No admin functions, no upgrade path (matches RWAAMM philosophy)
 * - Balance-before/after pattern for accurate output accounting
 */
contract RWAAMMAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

    /// @notice Immutable reference to the RWAAMM contract
    /// @dev Set once in constructor, cannot be changed
    // solhint-disable-next-line immutable-vars-naming,use-natspec
    IRWAAMM public immutable rwaamm;

    /// @notice Immutable reference to the OmniSwapRouter
    /// @dev Only this address can call executeSwap
    // solhint-disable-next-line immutable-vars-naming,use-natspec
    address public immutable router;

    // ══════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller is not the authorized router
    error OnlyRouter();

    /// @notice Swap produced zero output
    error ZeroOutput();

    // ══════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Restricts access to the OmniSwapRouter
    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the adapter with fixed RWAAMM and router references
     * @param rwaamm_ Address of the deployed RWAAMM contract
     * @param router_ Address of the OmniSwapRouter contract
     */
    constructor(address rwaamm_, address router_) {
        if (rwaamm_ == address(0)) revert ZeroAddress();
        if (router_ == address(0)) revert ZeroAddress();
        rwaamm = IRWAAMM(rwaamm_);
        router = router_;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       ISwapAdapter INTERFACE
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a token swap through RWAAMM
     * @dev Only callable by OmniSwapRouter. Approves RWAAMM to spend
     *      tokenIn, executes swap, then transfers output to recipient.
     *      Uses balance-before/after pattern for accurate output
     *      accounting.
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens to swap
     * @param minAmountOut Minimum acceptable output amount (slippage)
     * @param recipient Address to receive the output tokens
     * @return amountOut Amount of output tokens received
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override onlyRouter returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Transfer tokenIn from caller (OmniSwapRouter) to this adapter
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // Approve RWAAMM to spend tokenIn
        IERC20(tokenIn).forceApprove(address(rwaamm), amountIn);

        // Record balance before swap
        uint256 balBefore =
            IERC20(tokenOut).balanceOf(address(this));

        // Execute swap via RWAAMM.
        // onBehalfOf = `recipient`: this adapter is `msg.sender` to the RWAAMM,
        // so leaving onBehalfOf at address(0) would make the compliance oracle
        // (ERC-3643/1400) verify the ADAPTER instead of the human end user and
        // silently bypass per-user RWA compliance. `recipient` is the actual
        // end user who receives tokenOut, so it is the correct compliance
        // target (mirrors the C-01/C-02 audit fix already applied inside
        // RWAAMM.swap's direct callers).
        /* solhint-disable not-rely-on-time */
        rwaamm.swap(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            block.timestamp,
            recipient
        );
        /* solhint-enable not-rely-on-time */

        // Calculate actual output via balance difference
        uint256 balAfter =
            IERC20(tokenOut).balanceOf(address(this));
        amountOut = balAfter - balBefore;

        if (amountOut == 0) revert ZeroOutput();

        // Transfer output to recipient
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        // Reset approval to 0 (H-01 pattern from OmniSwapRouter)
        IERC20(tokenIn).forceApprove(address(rwaamm), 0);
    }

    /**
     * @notice Estimate the output amount for a given swap
     * @dev Delegates to RWAAMM.getQuote() and returns only amountOut
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens
     * @return amountOut Estimated amount of output tokens
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        (amountOut, , ) = rwaamm.getQuote(
            tokenIn, tokenOut, amountIn
        );
    }
}
