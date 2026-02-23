// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title OmniPredictionRouter
 * @author OmniCoin Development Team
 * @notice Trustless fee-collecting router for prediction market trades.
 * @dev Deployed on Polygon (Polymarket) and Gnosis (Omen). Collects a
 *      capped fee atomically, then forwards the net amount to the target
 *      platform contract. Outcome tokens flow directly to the caller.
 *
 * Trustless guarantees:
 *   - Fee percentage is capped by immutable `MAX_FEE_BPS` (set at deploy).
 *   - Fee collector address is immutable (set at deploy).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20 (reverts on failure).
 *   - Reentrancy guard on every external entry point.
 *
 * Gas optimisations:
 *   - Immutable storage for fee collector and cap.
 *   - Custom errors instead of revert strings.
 *
 * ERC-1155 compatibility:
 *   - Inherits ERC1155Holder so the contract can receive Polymarket CTF
 *     and Omen ConditionalTokens (both ERC-1155).
 *   - Provides `buyWithFeeAndSweepERC1155()` for ERC-1155 outcome token
 *     sweep after trade execution.
 */
contract OmniPredictionRouter is ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Basis-point denominator constant
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum gas reserved for post-call operations (M-03 mitigation).
    uint256 private constant GAS_RESERVE = 50_000;

    // -----------------------------------------------------------------------
    // Immutable State
    // -----------------------------------------------------------------------

    /// @notice Address that receives all collected fees
    address public immutable FEE_COLLECTOR;

    /// @notice Maximum fee in basis points (e.g. 200 = 2.00%)
    uint256 public immutable MAX_FEE_BPS;

    // -----------------------------------------------------------------------
    // Mutable State
    // -----------------------------------------------------------------------

    /// @notice Approved prediction market platforms that can be called
    /// @dev Only addresses in this mapping may be used as platformTarget
    mapping(address => bool) public approvedPlatforms;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful fee-collecting trade
    /// @param user         The trader's address
    /// @param collateral   The collateral token (USDC / WXDAI)
    /// @param totalAmount  Total amount pulled from user (including fee)
    /// @param feeAmount    Fee collected and sent to FEE_COLLECTOR
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

    /// @notice Emitted when a platform's approval status changes
    /// @param platform The platform contract address
    /// @param approved Whether the platform is now approved (true) or revoked (false)
    event PlatformApprovalChanged(
        address indexed platform,
        bool indexed approved
    );

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

    /// @notice Thrown when platform target is invalid (zero address, not approved, self, or collateral)
    error InvalidPlatformTarget();

    /// @notice Thrown when the caller has insufficient outcome tokens after the trade
    error InsufficientOutcomeTokens();

    /// @notice Thrown when the transaction deadline has passed
    error DeadlineExpired();

    /// @notice Thrown when the caller is not the fee collector (admin)
    error InvalidFeeCollector();

    /// @notice Thrown when the outcome token address is invalid (zero address)
    error InvalidOutcomeToken();

    /// @notice Thrown when a fee-on-transfer token delivers less than expected (M-01)
    error FeeOnTransferNotSupported();

    /// @notice Thrown when the platform target has no deployed code (M-04)
    error PlatformNotContract();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the prediction router with a fixed fee collector and cap.
     * @param feeCollector_ Address that receives collected fees (immutable)
     * @param maxFeeBps_    Maximum fee in basis points (immutable, e.g. 200 = 2%)
     */
    constructor(address feeCollector_, uint256 maxFeeBps_) {
        if (feeCollector_ == address(0)) revert InvalidFeeCollector();
        if (maxFeeBps_ == 0 || maxFeeBps_ > 1000) {
            // Cap cannot exceed 10% as a hard safety bound
            revert FeeExceedsCap(maxFeeBps_, 1000);
        }
        FEE_COLLECTOR = feeCollector_;
        MAX_FEE_BPS = maxFeeBps_;
    }

    // -----------------------------------------------------------------------
    // Admin Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Add or remove a platform from the approved platforms list.
     * @dev Only callable by the fee collector (admin). Prevents the zero
     *      address from being approved.
     * @param platform Address of the platform contract to approve or revoke
     * @param approved True to approve, false to revoke
     */
    function setPlatformApproval(
        address platform,
        bool approved
    ) external {
        if (msg.sender != FEE_COLLECTOR) revert InvalidFeeCollector();
        if (platform == address(0)) revert InvalidPlatformTarget();
        approvedPlatforms[platform] = approved;
        emit PlatformApprovalChanged(platform, approved);
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Execute a prediction market trade with atomic fee collection.
     * @dev Flow:
     *      1. Validate deadline has not passed.
     *      2. Validate platformTarget is on the approved platforms list.
     *      3. Pull `totalAmount` of `collateralToken` from caller.
     *      4. Send `feeAmount` to `FEE_COLLECTOR`.
     *      5. Validate fee does not exceed `MAX_FEE_BPS` cap.
     *      6. Approve net amount to `platformTarget`.
     *      7. Call `platformTarget` with `platformData`.
     *
     *      WARNING: This function does NOT sweep outcome tokens. The caller
     *      MUST encode the recipient address in `platformData` so that the
     *      platform sends outcome tokens directly to `msg.sender`. If the
     *      platform sends ERC-20 tokens to this router instead, use
     *      `buyWithFeeAndSweep()`. For ERC-1155 outcome tokens (Polymarket
     *      CTF, Omen ConditionalTokens), use `buyWithFeeAndSweepERC1155()`.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect (calculated off-chain, validated on-chain)
     * @param platformTarget  Address of the platform contract (FPMM, CTFExchange, etc.)
     * @param platformData    ABI-encoded call data for the platform contract
     * @param deadline        Unix timestamp after which the transaction reverts (MEV protection)
     */
    function buyWithFee(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        uint256 deadline
    ) external nonReentrant {
        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        _executeTrade(
            collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

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
     * @notice Execute a trade and sweep ERC-20 outcome tokens back to caller.
     * @dev Same as buyWithFee but additionally transfers any ERC-20 outcome
     *      tokens received by this contract back to msg.sender. Use when the
     *      platform sends ERC-20 tokens to the router instead of directly to
     *      the caller. For ERC-1155 outcome tokens (Polymarket CTF, Omen
     *      ConditionalTokens), use `buyWithFeeAndSweepERC1155()` instead.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param platformData    ABI-encoded call data for the platform contract
     * @param outcomeToken    ERC20 outcome token to sweep to caller after trade
     * @param minOutcome      Minimum outcome tokens expected (slippage protection)
     * @param deadline        Unix timestamp after which the transaction reverts (MEV protection)
     */
    function buyWithFeeAndSweep(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        address outcomeToken,
        uint256 minOutcome,
        uint256 deadline
    ) external nonReentrant {
        if (outcomeToken == address(0)) revert InvalidOutcomeToken();

        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        // --- M-02: Record ERC-20 outcome balance BEFORE trade ---
        uint256 outcomeBefore = IERC20(outcomeToken).balanceOf(
            address(this)
        );

        _executeTrade(
            collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

        // --- M-02: Sweep only the delta (prevents donation attack) ---
        uint256 outcomeReceived =
            IERC20(outcomeToken).balanceOf(address(this)) - outcomeBefore;
        if (outcomeReceived < minOutcome) {
            revert InsufficientOutcomeTokens();
        }
        if (outcomeReceived > 0) {
            IERC20(outcomeToken).safeTransfer(
                msg.sender, outcomeReceived
            );
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
     * @notice Execute a trade and sweep ERC-1155 outcome tokens back to caller.
     * @dev Same as buyWithFeeAndSweep but handles ERC-1155 tokens (Polymarket
     *      CTF, Omen ConditionalTokens). The contract must inherit ERC1155Holder
     *      to receive these tokens. After executing the platform call, only the
     *      delta of ERC-1155 outcome tokens (balance after minus balance before)
     *      is transferred to `msg.sender` (M-02 donation attack mitigation).
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param platformData    ABI-encoded call data for the platform contract
     * @param outcomeToken    ERC-1155 outcome token contract address (CTF)
     * @param outcomeTokenId  ERC-1155 token ID for the specific outcome position
     * @param minOutcome      Minimum outcome tokens expected (slippage protection)
     * @param deadline        Unix timestamp after which the tx reverts (MEV protection)
     */
    function buyWithFeeAndSweepERC1155(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        address outcomeToken,
        uint256 outcomeTokenId,
        uint256 minOutcome,
        uint256 deadline
    ) external nonReentrant {
        if (outcomeToken == address(0)) revert InvalidOutcomeToken();

        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        // --- M-02: Record ERC-1155 outcome balance BEFORE trade ---
        uint256 outcomeBefore = IERC1155(outcomeToken).balanceOf(
            address(this), outcomeTokenId
        );

        _executeTrade(
            collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

        // --- M-02: Sweep only the delta (prevents donation attack) ---
        uint256 outcomeReceived = IERC1155(outcomeToken).balanceOf(
            address(this), outcomeTokenId
        ) - outcomeBefore;
        if (outcomeReceived < minOutcome) {
            revert InsufficientOutcomeTokens();
        }
        if (outcomeReceived > 0) {
            IERC1155(outcomeToken).safeTransferFrom(
                address(this), msg.sender, outcomeTokenId,
                outcomeReceived, ""
            );
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
     * @dev Only callable by FEE_COLLECTOR. Cannot be used during a trade
     *      because of the reentrancy guard.
     * @param token ERC20 token to rescue
     */
    function rescueTokens(address token) external nonReentrant {
        if (msg.sender != FEE_COLLECTOR) revert InvalidFeeCollector();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(FEE_COLLECTOR, balance);
        }
    }

    // -----------------------------------------------------------------------
    // Private Functions (mutating before view per solhint ordering)
    // -----------------------------------------------------------------------

    /**
     * @notice Execute the core trade logic: pull collateral, send fee,
     *         approve platform, and execute the platform call.
     * @dev Called by all buy functions after validation.
     *      M-01: Uses balance-before/after to detect fee-on-transfer tokens.
     *      M-03: Caps gas forwarded to the platform call so post-call
     *            operations (approval reset, sweep, event) cannot be starved.
     * @param collateralToken ERC20 collateral token address
     * @param totalAmount     Total amount pulled from the user
     * @param feeAmount       Fee sent to FEE_COLLECTOR
     * @param netAmount       Amount approved and forwarded to the platform
     * @param platformTarget  Approved platform contract address
     * @param platformData    ABI-encoded call data for the platform
     */
    function _executeTrade(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 netAmount,
        address platformTarget,
        bytes calldata platformData
    ) private {
        // --- M-01: Pull collateral with balance-before/after check ---
        uint256 balBefore = IERC20(collateralToken).balanceOf(address(this));
        IERC20(collateralToken).safeTransferFrom(
            msg.sender, address(this), totalAmount
        );
        uint256 actualReceived =
            IERC20(collateralToken).balanceOf(address(this)) - balBefore;
        if (actualReceived != totalAmount) {
            revert FeeOnTransferNotSupported();
        }

        // --- Send fee to collector ---
        if (feeAmount > 0) {
            IERC20(collateralToken).safeTransfer(FEE_COLLECTOR, feeAmount);
        }

        // --- Approve net amount to platform ---
        IERC20(collateralToken).forceApprove(platformTarget, netAmount);

        // --- M-03: Execute platform trade with gas reserve ---
        uint256 gasForCall = gasleft() - GAS_RESERVE;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = platformTarget.call{
            gas: gasForCall
        }(platformData);
        if (!success) revert PlatformCallFailed(platformTarget, returnData);

        // Reset leftover approval to zero (gas refund + safety)
        IERC20(collateralToken).forceApprove(platformTarget, 0);
    }

    /**
     * @notice Validate that a platform target is safe to call.
     * @dev Checks that the target is non-zero, on the approved list,
     *      not the collateral token, and not this contract.
     * @param platformTarget  Address of the platform contract to validate
     * @param collateralToken Address of the collateral token (must differ from target)
     */
    function _validatePlatformTarget(
        address platformTarget,
        address collateralToken
    ) private view {
        if (platformTarget == address(0)) revert InvalidPlatformTarget();
        if (!approvedPlatforms[platformTarget]) {
            revert InvalidPlatformTarget();
        }
        if (platformTarget == collateralToken) {
            revert InvalidPlatformTarget();
        }
        if (platformTarget == address(this)) {
            revert InvalidPlatformTarget();
        }
        // M-04: Verify target has deployed code
        if (platformTarget.code.length == 0) {
            revert PlatformNotContract();
        }
    }

    /**
     * @notice Validate common trade parameters shared by both buy functions.
     * @dev Checks deadline, zero amounts, zero addresses, platform allowlist,
     *      fee-over-total, and fee cap. Delegates platform target validation
     *      to `_validatePlatformTarget`.
     * @param collateralToken ERC20 collateral token address
     * @param totalAmount     Total amount the user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param deadline        Unix timestamp after which the transaction reverts
     * @return netAmount      The amount remaining after the fee is deducted
     */
    function _validateTradeParams(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        uint256 deadline
    ) private view returns (uint256 netAmount) {
        // --- Deadline check ---
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();

        // --- Input validation ---
        if (totalAmount == 0) revert ZeroAmount();
        if (collateralToken == address(0)) revert InvalidCollateralToken();
        _validatePlatformTarget(platformTarget, collateralToken);
        if (feeAmount > totalAmount) {
            revert FeeExceedsTotal(feeAmount, totalAmount);
        }

        // --- On-chain fee cap enforcement ---
        uint256 maxAllowed = (totalAmount * MAX_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) {
            revert FeeExceedsCap(feeAmount, maxAllowed);
        }

        netAmount = totalAmount - feeAmount;
    }
}
