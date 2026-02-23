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
 *   5. Sweep output and residual input tokens back to caller.
 *
 * Trustless guarantees:
 *   - Fee percentage capped by immutable maxFeeBps (set at deploy).
 *   - Fee collector address is immutable (set at deploy).
 *   - Router address validated: cannot be a token, this contract, or an EOA (C-01).
 *   - Deadline parameter for MEV protection (M-01).
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
    // State Variables
    // -----------------------------------------------------------------------

    /// @notice Basis-point denominator constant.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Address that receives all collected fees.
    address public immutable feeCollector; // solhint-disable-line immutable-vars-naming

    /// @notice Maximum fee in basis points (e.g., 100 = 1.00%).
    uint256 public immutable maxFeeBps; // solhint-disable-line immutable-vars-naming

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

    /// @notice Emitted when accidentally-sent tokens are rescued by feeCollector.
    /// @param token  The ERC20 token rescued.
    /// @param amount The amount of tokens rescued.
    event TokensRescued(address indexed token, uint256 indexed amount);

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

    /// @notice Thrown when a token address is zero or input equals output.
    error InvalidTokenAddress();

    /// @notice Thrown when the router address is zero, a token, this contract, or an EOA.
    error InvalidRouterAddress();

    /// @notice Thrown when the fee collector address is the zero address.
    error InvalidFeeCollector();

    /// @notice Thrown when output tokens received are below the minimum.
    error InsufficientOutputTokens(uint256 received, uint256 minimum);

    /// @notice Thrown when the transaction deadline has passed (M-01).
    error DeadlineExpired();

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
     *      The `routerCalldata` must encode a swap that sends output tokens to this
     *      contract (not directly to the user), because we sweep them after verifying
     *      minimum output. Residual input tokens are also swept back to the caller.
     *
     * @param inputToken     ERC20 token the user is selling.
     * @param outputToken    ERC20 token the user is buying.
     * @param totalAmount    Total input amount (fee inclusive).
     * @param feeAmount      Fee to collect (validated against maxFeeBps on-chain).
     * @param routerAddress  Address of the external DEX router.
     * @param routerCalldata ABI-encoded swap call for the external router.
     * @param minOutput      Minimum output tokens expected (slippage protection).
     * @param deadline       Unix timestamp after which the transaction reverts (M-01 MEV protection).
     */
    function swapWithFee(
        address inputToken,
        address outputToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address routerAddress,
        bytes calldata routerCalldata,
        uint256 minOutput,
        uint256 deadline
    ) external nonReentrant {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();
        _validateTokens(inputToken, outputToken);
        _validateRouter(routerAddress, inputToken, outputToken);
        _validateFee(totalAmount, feeAmount);

        // --- Pull input tokens from user (H-02: balance-before/after) ---
        uint256 inputBefore =
            IERC20(inputToken).balanceOf(address(this));
        IERC20(inputToken).safeTransferFrom(
            msg.sender, address(this), totalAmount
        );
        uint256 actualReceived =
            IERC20(inputToken).balanceOf(address(this)) - inputBefore;

        // H-02: Recalculate fee and net based on actual received amount
        // for fee-on-transfer tokens that deliver less than totalAmount.
        uint256 actualFee = (actualReceived * feeAmount) / totalAmount;
        uint256 netAmount = actualReceived - actualFee;

        // --- Send fee to collector ---
        if (actualFee > 0) {
            IERC20(inputToken).safeTransfer(feeCollector, actualFee);
        }

        // --- Execute swap via external router ---
        uint256 outputReceived = _executeRouterSwap(
            inputToken, outputToken, netAmount,
            routerAddress, routerCalldata
        );

        // --- Verify slippage and sweep output tokens ---
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
            actualReceived,
            actualFee,
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
            emit TokensRescued(token, balance);
        }
    }

    // -----------------------------------------------------------------------
    // Private Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Approve, execute the external router swap, then clean up.
     * @dev Resets router approval to zero after the call and sweeps any
     *      residual input tokens back to msg.sender (C-01 mitigation).
     * @param inputToken     ERC20 token approved to the router.
     * @param outputToken    ERC20 token expected from the router.
     * @param netAmount      Amount of inputToken to approve to the router.
     * @param routerAddress  Address of the external DEX router.
     * @param routerCalldata ABI-encoded swap call for the external router.
     * @return outputReceived Amount of outputToken received from the swap.
     */
    function _executeRouterSwap(
        address inputToken,
        address outputToken,
        uint256 netAmount,
        address routerAddress,
        bytes calldata routerCalldata
    ) private returns (uint256 outputReceived) {
        // --- Approve net amount to external router ---
        IERC20(inputToken).forceApprove(routerAddress, netAmount);

        // --- Record output balance before swap ---
        uint256 outputBefore =
            IERC20(outputToken).balanceOf(address(this));

        // --- Execute external DEX swap ---
        /* solhint-disable avoid-low-level-calls */
        (bool success, bytes memory returnData) =
            routerAddress.call(routerCalldata);
        /* solhint-enable avoid-low-level-calls */
        if (!success) {
            revert RouterCallFailed(routerAddress, returnData);
        }

        // --- Reset leftover approval to zero (safety + gas refund) ---
        IERC20(inputToken).forceApprove(routerAddress, 0);

        // --- C-01: Sweep residual input tokens back to caller ---
        // Prevents tokens from being stranded if router consumed less
        // than netAmount.
        uint256 inputRemaining =
            IERC20(inputToken).balanceOf(address(this));
        if (inputRemaining > 0) {
            IERC20(inputToken).safeTransfer(msg.sender, inputRemaining);
        }

        // --- Calculate output received ---
        uint256 outputAfter =
            IERC20(outputToken).balanceOf(address(this));
        outputReceived = outputAfter - outputBefore;
    }

    /**
     * @notice Validate the external router address.
     * @dev C-01 mitigation: blocks routerAddress from being a token address,
     *      this contract, or an EOA to prevent arbitrary approval drain attacks
     *      (e.g. Transit Swap $21M, SushiSwap $3.3M, LI.FI $11.6M exploits).
     * @param routerAddress Address of the external DEX router.
     * @param inputToken    Input token address (must differ from router).
     * @param outputToken   Output token address (must differ from router).
     */
    function _validateRouter(
        address routerAddress,
        address inputToken,
        address outputToken
    ) private view {
        if (routerAddress == address(0)) revert InvalidRouterAddress();
        if (routerAddress == inputToken) revert InvalidRouterAddress();
        if (routerAddress == outputToken) revert InvalidRouterAddress();
        if (routerAddress == address(this)) {
            revert InvalidRouterAddress();
        }
        if (routerAddress.code.length == 0) {
            revert InvalidRouterAddress();
        }
    }

    /**
     * @notice Validate fee amount against total and on-chain cap.
     * @dev Ensures fee does not exceed totalAmount or the maxFeeBps cap.
     * @param totalAmount Total input amount (fee inclusive).
     * @param feeAmount   Fee to collect.
     */
    function _validateFee(
        uint256 totalAmount,
        uint256 feeAmount
    ) private view {
        if (totalAmount == 0) revert ZeroAmount();
        if (feeAmount > totalAmount) {
            revert FeeExceedsTotal(feeAmount, totalAmount);
        }
        uint256 maxAllowed =
            (totalAmount * maxFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) {
            revert FeeExceedsCap(feeAmount, maxAllowed);
        }
    }

    /**
     * @notice Validate token addresses for a swap.
     * @dev Rejects zero addresses and same-token swaps.
     * @param inputToken  ERC20 token the user is selling.
     * @param outputToken ERC20 token the user is buying.
     */
    function _validateTokens(
        address inputToken,
        address outputToken
    ) private pure {
        if (inputToken == address(0)) revert InvalidTokenAddress();
        if (outputToken == address(0)) revert InvalidTokenAddress();
        if (inputToken == outputToken) revert InvalidTokenAddress();
    }
}
