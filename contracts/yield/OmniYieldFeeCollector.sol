// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniYieldFeeCollector
 * @author OmniCoin Development Team
 * @notice Collects a 5% performance fee on yield earned through OmniBazaar.
 * @dev Users deposit directly into external DeFi protocols (Curve, Convex, Aave,
 *      Pendle, etc.). When they withdraw yield through OmniBazaar's UI, this contract
 *      collects the performance fee atomically.
 *
 * Flow (simple approach — no vault wrapper):
 *   1. User withdraws yield from external protocol (off-chain step).
 *   2. User calls `collectFeeAndForward()` with their yield tokens.
 *   3. Contract deducts `performanceFeeBps` from the yield amount.
 *   4. Fee sent to immutable `feeCollector`.
 *   5. Net yield forwarded to user.
 *
 * Trustless guarantees:
 *   - Performance fee percentage is immutable (set at deploy).
 *   - Fee collector address is immutable (set at deploy).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20.
 *   - Reentrancy guard on every external entry point.
 *
 * Alternative use: Backend can call `recordFee()` to log fee collection that
 * happened through other means (e.g., user-signed tx to protocol that routes
 * yield through this contract).
 */
contract OmniYieldFeeCollector is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Custom Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when yield amount is zero.
    error ZeroAmount();

    /// @notice Thrown when token address is the zero address.
    error InvalidTokenAddress();

    /// @notice Thrown when the fee collector address is the zero address.
    error InvalidFeeCollector();

    /// @notice Thrown when performance fee exceeds safety cap.
    error FeeExceedsCap(uint256 feeBps, uint256 maxBps);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a performance fee is collected.
    /// @param user       Address of the yield earner.
    /// @param token      The yield token.
    /// @param yieldAmount Total yield amount before fee.
    /// @param feeAmount  Fee collected.
    /// @param netAmount  Net yield forwarded to user.
    event FeeCollected(
        address indexed user,
        address indexed token,
        uint256 yieldAmount,
        uint256 feeAmount,
        uint256 netAmount
    );

    // -----------------------------------------------------------------------
    // Immutable State
    // -----------------------------------------------------------------------

    /// @notice Address that receives all collected performance fees.
    address public immutable feeCollector;

    /// @notice Performance fee in basis points (e.g., 500 = 5%).
    uint256 public immutable performanceFeeBps;

    /// @notice Basis-point denominator constant.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum allowed performance fee (10% = 1000 bps).
    uint256 private constant MAX_FEE_BPS = 1000;

    /// @notice Total fees collected per token (for transparency).
    mapping(address => uint256) public totalFeesCollected;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the yield fee collector.
     * @param _feeCollector      Address that receives fees (immutable).
     * @param _performanceFeeBps Performance fee in basis points (immutable, e.g., 500 = 5%).
     */
    constructor(address _feeCollector, uint256 _performanceFeeBps) {
        if (_feeCollector == address(0)) revert InvalidFeeCollector();
        if (_performanceFeeBps == 0 || _performanceFeeBps > MAX_FEE_BPS) {
            revert FeeExceedsCap(_performanceFeeBps, MAX_FEE_BPS);
        }
        feeCollector = _feeCollector;
        performanceFeeBps = _performanceFeeBps;
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Collect performance fee from yield tokens and forward net to user.
     * @dev User must have approved this contract for `yieldAmount` of `token`.
     *      The fee is calculated as: feeAmount = yieldAmount * performanceFeeBps / 10000
     *      Net amount forwarded to user: yieldAmount - feeAmount
     *
     * @param token       ERC20 yield token.
     * @param yieldAmount Total yield amount to process.
     */
    function collectFeeAndForward(
        address token,
        uint256 yieldAmount
    ) external nonReentrant {
        if (yieldAmount == 0) revert ZeroAmount();
        if (token == address(0)) revert InvalidTokenAddress();

        uint256 feeAmount = (yieldAmount * performanceFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = yieldAmount - feeAmount;

        // Pull yield tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), yieldAmount);

        // Send fee to collector
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(feeCollector, feeAmount);
            totalFeesCollected[token] += feeAmount;
        }

        // Forward net yield to user
        if (netAmount > 0) {
            IERC20(token).safeTransfer(msg.sender, netAmount);
        }

        emit FeeCollected(msg.sender, token, yieldAmount, feeAmount, netAmount);
    }

    /**
     * @notice Calculate the fee for a given yield amount (view only).
     * @param yieldAmount The yield amount to calculate fee for.
     * @return feeAmount  The fee that would be collected.
     * @return netAmount  The net amount after fee.
     */
    function calculateFee(uint256 yieldAmount)
        external
        view
        returns (uint256 feeAmount, uint256 netAmount)
    {
        feeAmount = (yieldAmount * performanceFeeBps) / BPS_DENOMINATOR;
        netAmount = yieldAmount - feeAmount;
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Only callable by feeCollector.
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
