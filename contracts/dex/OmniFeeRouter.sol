// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniFeeRouter
 * @author OmniCoin Development Team
 * @notice Trustless fee-collecting wrapper for external DEX swaps on any EVM chain.
 * @dev Deployed per-chain (Polygon, Ethereum, Arbitrum, etc.) to wrap swaps through
 *      external routers (Uniswap, SushiSwap, PancakeSwap) with atomic fee collection.
 *      Follows the same pattern as OmniPredictionRouter.
 *
 * Flow:
 *   1. Pull totalAmount of inputToken from caller.
 *   2. Send feeAmount to immutable feeCollector.
 *   3. Approve netAmount to the external DEX router.
 *   4. Execute the swap via low-level call with caller-supplied calldata.
 *   5. Sweep output tokens back to caller.
 *
 * Trustless guarantees:
 *   - Fee percentage capped by immutable maxFeeBps (set at deploy).
 *   - Fee collector address is immutable (set at deploy).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20 (reverts on failure).
 *   - Reentrancy guard on every external entry point.
 *
 * Gas optimisations:
 *   - Immutable storage for fee collector and cap.
 *   - Custom errors instead of revert strings.
 */
contract OmniFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Custom Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when the requested fee exceeds the on-chain cap.
    error FeeExceedsCap(uint256 feeAmount, uint256 maxAllowed);

    /// @notice Thrown when total amount is zero.
    error ZeroAmount();

    /// @notice Thrown when fee is larger than total amount.
    error FeeExceedsTotal(uint256 feeAmount, uint256 totalAmount);

    /// @notice Thrown when the external router call fails.
    error RouterCallFailed(address router, bytes reason);

    /// @notice Thrown when a token address is the zero address.
    error InvalidTokenAddress();

    /// @notice Thrown when the router address is the zero address.
    error InvalidRouterAddress();

    /// @notice Thrown when the fee collector address is the zero address.
    error InvalidFeeCollector();

    /// @notice Thrown when output tokens received are below the minimum.
    error InsufficientOutputTokens(uint256 received, uint256 minimum);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful fee-collecting swap.
    /// @param user        The trader's address.
    /// @param inputToken  The input token sent by the user.
    /// @param outputToken The output token received by the user.
    /// @param totalAmount Total input amount pulled from user (fee inclusive).
    /// @param feeAmount   Fee collected and sent to feeCollector.
    /// @param netAmount   Amount forwarded to the external DEX router.
    /// @param router      The external DEX router address.
    event SwapExecuted(
        address indexed user,
        address indexed inputToken,
        address indexed outputToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 netAmount,
        address router
    );

    // -----------------------------------------------------------------------
    // Immutable State
    // -----------------------------------------------------------------------

    /// @notice Address that receives all collected fees.
    address public immutable feeCollector;

    /// @notice Maximum fee in basis points (e.g., 100 = 1.00%).
    uint256 public immutable maxFeeBps;

    /// @notice Basis-point denominator constant.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the fee router with a fixed fee collector and cap.
     * @param _feeCollector Address that receives collected fees (immutable).
     * @param _maxFeeBps    Maximum fee in basis points (immutable, e.g., 100 = 1%).
     */
    constructor(address _feeCollector, uint256 _maxFeeBps) {
        if (_feeCollector == address(0)) revert InvalidFeeCollector();
        if (_maxFeeBps == 0 || _maxFeeBps > 500) {
            // Cap cannot exceed 5% as a hard safety bound
            revert FeeExceedsCap(_maxFeeBps, 500);
        }
        feeCollector = _feeCollector;
        maxFeeBps = _maxFeeBps;
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Execute an external DEX swap with atomic fee collection.
     * @dev The caller must have approved this contract for `totalAmount` of `inputToken`.
     *      The `routerCalldata` must encode a swap that sends output tokens to this contract
     *      (not directly to the user), because we sweep them after verifying minimum output.
     *
     * @param inputToken     ERC20 token the user is selling.
     * @param outputToken    ERC20 token the user is buying.
     * @param totalAmount    Total input amount (fee inclusive).
     * @param feeAmount      Fee to collect (validated against maxFeeBps on-chain).
     * @param routerAddress  Address of the external DEX router.
     * @param routerCalldata ABI-encoded swap call for the external router.
     * @param minOutput      Minimum output tokens expected (slippage protection).
     */
    function swapWithFee(
        address inputToken,
        address outputToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address routerAddress,
        bytes calldata routerCalldata,
        uint256 minOutput
    ) external nonReentrant {
        // --- Input validation ---
        if (totalAmount == 0) revert ZeroAmount();
        if (inputToken == address(0)) revert InvalidTokenAddress();
        if (outputToken == address(0)) revert InvalidTokenAddress();
        if (routerAddress == address(0)) revert InvalidRouterAddress();
        if (feeAmount > totalAmount) revert FeeExceedsTotal(feeAmount, totalAmount);

        // --- On-chain fee cap enforcement ---
        uint256 maxAllowed = (totalAmount * maxFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) revert FeeExceedsCap(feeAmount, maxAllowed);

        uint256 netAmount = totalAmount - feeAmount;

        // --- Pull input tokens from user ---
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), totalAmount);

        // --- Send fee to collector ---
        if (feeAmount > 0) {
            IERC20(inputToken).safeTransfer(feeCollector, feeAmount);
        }

        // --- Approve net amount to external router ---
        IERC20(inputToken).forceApprove(routerAddress, netAmount);

        // --- Record output balance before swap ---
        uint256 outputBefore = IERC20(outputToken).balanceOf(address(this));

        // --- Execute external DEX swap ---
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = routerAddress.call(routerCalldata);
        if (!success) revert RouterCallFailed(routerAddress, returnData);

        // --- Reset leftover approval to zero (safety + gas refund) ---
        IERC20(inputToken).forceApprove(routerAddress, 0);

        // --- Sweep output tokens to caller ---
        uint256 outputAfter = IERC20(outputToken).balanceOf(address(this));
        uint256 outputReceived = outputAfter - outputBefore;
        if (outputReceived < minOutput) {
            revert InsufficientOutputTokens(outputReceived, minOutput);
        }
        if (outputReceived > 0) {
            IERC20(outputToken).safeTransfer(msg.sender, outputReceived);
        }

        emit SwapExecuted(
            msg.sender,
            inputToken,
            outputToken,
            totalAmount,
            feeAmount,
            netAmount,
            routerAddress
        );
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Only callable by feeCollector. Cannot be used during a trade
     *      because of the reentrancy guard.
     * @param token ERC20 token to rescue.
     */
    function rescueTokens(address token) external nonReentrant {
        if (msg.sender != feeCollector) revert InvalidFeeCollector();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(feeCollector, balance);
        }
    }
}
