// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniPredictionRouter
 * @author OmniCoin Development Team
 * @notice Trustless fee-collecting router for prediction market trades.
 * @dev Deployed on Polygon (Polymarket) and Gnosis (Omen). Collects a
 *      capped fee atomically, then forwards the net amount to the target
 *      platform contract. Outcome tokens flow directly to the caller.
 *
 * Trustless guarantees:
 *   - Fee percentage is capped by immutable `maxFeeBps` (set at deploy).
 *   - Fee collector address is immutable (set at deploy).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20 (reverts on failure).
 *   - Reentrancy guard on every external entry point.
 *
 * Gas optimisations:
 *   - Immutable storage for fee collector and cap.
 *   - Custom errors instead of revert strings.
 *   - Minimal proxy-friendly (no constructor args in bytecode).
 */
contract OmniPredictionRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Custom Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when the requested fee exceeds the on-chain cap
    error FeeExceedsCap(uint256 feeAmount, uint256 maxAllowed);

    /// @notice Thrown when total amount is zero
    error ZeroAmount();

    /// @notice Thrown when fee is larger than total amount
    error FeeExceedsTotal(uint256 feeAmount, uint256 totalAmount);

    /// @notice Thrown when the platform call fails
    error PlatformCallFailed(address target, bytes reason);

    /// @notice Thrown when collateral token is the zero address
    error InvalidCollateralToken();

    /// @notice Thrown when platform target is the zero address
    error InvalidPlatformTarget();

    /// @notice Thrown when the caller has insufficient outcome tokens after the trade
    error InsufficientOutcomeTokens();

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful fee-collecting trade
    /// @param user         The trader's address
    /// @param collateral   The collateral token (USDC / WXDAI)
    /// @param totalAmount  Total amount pulled from user (including fee)
    /// @param feeAmount    Fee collected and sent to feeCollector
    /// @param netAmount    Amount forwarded to the platform
    /// @param platform     Target platform contract address
    event TradeExecuted(
        address indexed user,
        address indexed collateral,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 netAmount,
        address indexed platform
    );

    // -----------------------------------------------------------------------
    // Immutable State
    // -----------------------------------------------------------------------

    /// @notice Address that receives all collected fees
    address public immutable feeCollector;

    /// @notice Maximum fee in basis points (e.g. 200 = 2.00%)
    uint256 public immutable maxFeeBps;

    /// @notice Basis-point denominator constant
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the prediction router with a fixed fee collector and cap.
     * @param _feeCollector Address that receives collected fees (immutable)
     * @param _maxFeeBps    Maximum fee in basis points (immutable, e.g. 200 = 2%)
     */
    constructor(address _feeCollector, uint256 _maxFeeBps) {
        if (_feeCollector == address(0)) revert InvalidCollateralToken();
        if (_maxFeeBps == 0 || _maxFeeBps > 1000) {
            // Cap cannot exceed 10% as a hard safety bound
            revert FeeExceedsCap(_maxFeeBps, 1000);
        }
        feeCollector = _feeCollector;
        maxFeeBps = _maxFeeBps;
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Execute a prediction market trade with atomic fee collection.
     * @dev Flow:
     *      1. Pull `totalAmount` of `collateralToken` from caller.
     *      2. Send `feeAmount` to `feeCollector`.
     *      3. Validate fee does not exceed `maxFeeBps` cap.
     *      4. Approve net amount to `platformTarget`.
     *      5. Call `platformTarget` with `platformData`.
     *      6. Sweep any outcome tokens back to caller.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect (calculated off-chain, validated on-chain)
     * @param platformTarget  Address of the platform contract (FPMM, CTFExchange, etc.)
     * @param platformData    ABI-encoded call data for the platform contract
     */
    function buyWithFee(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData
    ) external nonReentrant {
        // --- Input validation ---
        if (totalAmount == 0) revert ZeroAmount();
        if (collateralToken == address(0)) revert InvalidCollateralToken();
        if (platformTarget == address(0)) revert InvalidPlatformTarget();
        if (feeAmount > totalAmount) revert FeeExceedsTotal(feeAmount, totalAmount);

        // --- On-chain fee cap enforcement ---
        uint256 maxAllowed = (totalAmount * maxFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) revert FeeExceedsCap(feeAmount, maxAllowed);

        uint256 netAmount = totalAmount - feeAmount;

        // --- Pull collateral from user ---
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), totalAmount);

        // --- Send fee to collector ---
        if (feeAmount > 0) {
            IERC20(collateralToken).safeTransfer(feeCollector, feeAmount);
        }

        // --- Approve net amount to platform ---
        IERC20(collateralToken).forceApprove(platformTarget, netAmount);

        // --- Execute platform trade ---
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = platformTarget.call(platformData);
        if (!success) revert PlatformCallFailed(platformTarget, returnData);

        // Reset leftover approval to zero (gas refund + safety)
        IERC20(collateralToken).forceApprove(platformTarget, 0);

        emit TradeExecuted(
            msg.sender,
            collateralToken,
            totalAmount,
            feeAmount,
            netAmount,
            platformTarget
        );
    }

    /**
     * @notice Execute a trade and sweep a specific outcome token back to caller.
     * @dev Same as buyWithFee but additionally transfers any outcome tokens
     *      received by this contract back to msg.sender. Use when the platform
     *      sends tokens to the router instead of directly to the caller.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param platformData    ABI-encoded call data for the platform contract
     * @param outcomeToken    ERC20 outcome token to sweep to caller after trade
     * @param minOutcome      Minimum outcome tokens expected (slippage protection)
     */
    function buyWithFeeAndSweep(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        address outcomeToken,
        uint256 minOutcome
    ) external nonReentrant {
        // --- Input validation ---
        if (totalAmount == 0) revert ZeroAmount();
        if (collateralToken == address(0)) revert InvalidCollateralToken();
        if (platformTarget == address(0)) revert InvalidPlatformTarget();
        if (feeAmount > totalAmount) revert FeeExceedsTotal(feeAmount, totalAmount);

        // --- On-chain fee cap enforcement ---
        uint256 maxAllowed = (totalAmount * maxFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) revert FeeExceedsCap(feeAmount, maxAllowed);

        uint256 netAmount = totalAmount - feeAmount;

        // --- Pull collateral from user ---
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), totalAmount);

        // --- Send fee to collector ---
        if (feeAmount > 0) {
            IERC20(collateralToken).safeTransfer(feeCollector, feeAmount);
        }

        // --- Approve net amount to platform ---
        IERC20(collateralToken).forceApprove(platformTarget, netAmount);

        // --- Execute platform trade ---
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = platformTarget.call(platformData);
        if (!success) revert PlatformCallFailed(platformTarget, returnData);

        // Reset leftover approval to zero
        IERC20(collateralToken).forceApprove(platformTarget, 0);

        // --- Sweep outcome tokens to caller ---
        uint256 outcomeBalance = IERC20(outcomeToken).balanceOf(address(this));
        if (outcomeBalance < minOutcome) revert InsufficientOutcomeTokens();
        if (outcomeBalance > 0) {
            IERC20(outcomeToken).safeTransfer(msg.sender, outcomeBalance);
        }

        emit TradeExecuted(
            msg.sender,
            collateralToken,
            totalAmount,
            feeAmount,
            netAmount,
            platformTarget
        );
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Only callable by feeCollector. Cannot be used during a trade
     *      because of the reentrancy guard.
     * @param token ERC20 token to rescue
     */
    function rescueTokens(address token) external nonReentrant {
        if (msg.sender != feeCollector) revert InvalidPlatformTarget();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(feeCollector, balance);
        }
    }
}
