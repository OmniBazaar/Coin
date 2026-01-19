// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniSwapRouter
 * @author OmniCoin Development Team
 * @notice Optimal routing for token swaps across multiple liquidity sources
 * @dev Routes swaps through internal and external DEX pools for best execution
 *
 * Features:
 * - Multi-source routing (Uniswap V3, Sushiswap, Curve, internal pools)
 * - Single-hop and multi-hop swap paths
 * - Slippage protection
 * - Fee collection (0.30% default)
 * - MEV protection via deadline
 * - Emergency pause capability
 *
 * Architecture:
 * - Aggregates liquidity from multiple sources
 * - Computes optimal routes for best price
 * - Executes swaps atomically
 * - Distributes fees to protocol treasury
 */
contract OmniSwapRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum number of hops in a swap path
    uint256 public constant MAX_HOPS = 3;

    /// @notice Maximum slippage tolerance in basis points (10% = 1000)
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Basis points divisor (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a swap is executed
     * @param user User who initiated the swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param amountOut Amount of output token received
     * @param feeAmount Fee amount collected
     * @param route Route identifier (hash of path + sources)
     */
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        bytes32 route
    );

    /**
     * @notice Emitted when a liquidity source is added
     * @param sourceId Source identifier
     * @param adapter Adapter contract address
     */
    event LiquiditySourceAdded(bytes32 indexed sourceId, address adapter);

    /**
     * @notice Emitted when a liquidity source is removed
     * @param sourceId Source identifier
     */
    event LiquiditySourceRemoved(bytes32 indexed sourceId);

    /**
     * @notice Emitted when swap fee is updated
     * @param oldFee Old fee in basis points
     * @param newFee New fee in basis points
     */
    event SwapFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Emitted when fee recipient is updated
     * @param oldRecipient Old recipient address
     * @param newRecipient New recipient address
     */
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when path has too many hops
    error PathTooLong();

    /// @notice Thrown when path is empty
    error EmptyPath();

    /// @notice Thrown when swap deadline has passed
    error SwapDeadlineExpired();

    /// @notice Thrown when output amount is below minimum
    error InsufficientOutputAmount();

    /// @notice Thrown when input amount is zero
    error ZeroInputAmount();

    /// @notice Thrown when slippage tolerance is too high
    error SlippageTooHigh();

    /// @notice Thrown when liquidity source is not registered
    error InvalidLiquiditySource();

    /// @notice Thrown when fee is too high
    error FeeTooHigh();

    /// @notice Thrown when token address is invalid
    error InvalidTokenAddress();

    /// @notice Thrown when recipient address is invalid
    error InvalidRecipientAddress();

    /// @notice Thrown when token transfer fails
    error TokenTransferFailed();

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Swap parameters
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum acceptable output amount
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param deadline Swap expiration timestamp
     * @param recipient Address to receive output tokens
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
     * @notice Swap result
     * @param amountOut Amount of output token received
     * @param feeAmount Fee amount collected
     * @param route Route identifier
     */
    struct SwapResult {
        uint256 amountOut;
        uint256 feeAmount;
        bytes32 route;
    }

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Swap fee in basis points (30 = 0.30%)
    uint256 public swapFeeBps;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Mapping of source ID to adapter contract
    mapping(bytes32 => address) public liquiditySources;

    /// @notice Total swap volume
    uint256 public totalSwapVolume;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Constructor to initialize the OmniSwapRouter
     * @param _feeRecipient Address to receive swap fees
     * @param _swapFeeBps Initial swap fee in basis points
     */
    constructor(address _feeRecipient, uint256 _swapFeeBps) Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert InvalidRecipientAddress();
        if (_swapFeeBps > 100) revert FeeTooHigh(); // Max 1%

        feeRecipient = _feeRecipient;
        swapFeeBps = _swapFeeBps;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute a token swap with optimal routing
     * @param params Swap parameters
     * @return result Swap result with amounts and route
     * @dev Swaps tokens through the specified path and liquidity sources
     */
    function swap(
        SwapParams calldata params
    ) external nonReentrant whenNotPaused returns (SwapResult memory result) {
        // Validate parameters
        if (params.amountIn == 0) revert ZeroInputAmount();
        if (params.path.length == 0) revert EmptyPath();
        if (params.path.length > MAX_HOPS + 1) revert PathTooLong();
        if (params.sources.length != params.path.length - 1) revert InvalidLiquiditySource();
        if (block.timestamp > params.deadline) revert SwapDeadlineExpired();
        if (params.tokenIn == address(0) || params.tokenOut == address(0)) {
            revert InvalidTokenAddress();
        }
        if (params.recipient == address(0)) revert InvalidRecipientAddress();

        // Verify path consistency
        if (params.path[0] != params.tokenIn ||
            params.path[params.path.length - 1] != params.tokenOut) {
            revert EmptyPath();
        }

        // Transfer input tokens from user
        IERC20(params.tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            params.amountIn
        );

        // Calculate and deduct fee
        uint256 feeAmount = (params.amountIn * swapFeeBps) / BASIS_POINTS_DIVISOR;
        uint256 swapAmount = params.amountIn - feeAmount;

        if (feeAmount > 0) {
            IERC20(params.tokenIn).safeTransfer(feeRecipient, feeAmount);
        }

        // Execute swap through the path
        uint256 amountOut = _executeSwapPath(
            params.path,
            params.sources,
            swapAmount
        );

        // Check slippage protection
        if (amountOut < params.minAmountOut) {
            revert InsufficientOutputAmount();
        }

        // Transfer output tokens to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        // Calculate route identifier
        bytes32 route = keccak256(abi.encodePacked(params.path, params.sources));

        // Update statistics
        totalSwapVolume += params.amountIn;
        totalFeesCollected += feeAmount;

        // Emit event
        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            feeAmount,
            route
        );

        return SwapResult({
            amountOut: amountOut,
            feeAmount: feeAmount,
            route: route
        });
    }

    /**
     * @notice Get quote for a potential swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @return amountOut Estimated output amount (before fees)
     * @return feeAmount Fee amount
     * @dev This is a view function for price estimation
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata path,
        bytes32[] calldata sources
    ) external view returns (uint256 amountOut, uint256 feeAmount) {
        if (amountIn == 0) revert ZeroInputAmount();
        if (path.length == 0) revert EmptyPath();
        if (path.length > MAX_HOPS + 1) revert PathTooLong();

        // Calculate fee
        feeAmount = (amountIn * swapFeeBps) / BASIS_POINTS_DIVISOR;
        uint256 swapAmount = amountIn - feeAmount;

        // Estimate output through path
        amountOut = _estimateSwapPath(path, sources, swapAmount);
    }

    /**
     * @notice Add a new liquidity source adapter
     * @param sourceId Source identifier
     * @param adapter Adapter contract address
     * @dev Can only be called by owner
     */
    function addLiquiditySource(
        bytes32 sourceId,
        address adapter
    ) external onlyOwner {
        if (adapter == address(0)) revert InvalidTokenAddress();

        liquiditySources[sourceId] = adapter;
        emit LiquiditySourceAdded(sourceId, adapter);
    }

    /**
     * @notice Remove a liquidity source adapter
     * @param sourceId Source identifier
     * @dev Can only be called by owner
     */
    function removeLiquiditySource(bytes32 sourceId) external onlyOwner {
        delete liquiditySources[sourceId];
        emit LiquiditySourceRemoved(sourceId);
    }

    /**
     * @notice Update swap fee
     * @param _swapFeeBps New swap fee in basis points
     * @dev Can only be called by owner. Maximum 1%
     */
    function setSwapFee(uint256 _swapFeeBps) external onlyOwner {
        if (_swapFeeBps > 100) revert FeeTooHigh(); // Max 1%

        uint256 oldFee = swapFeeBps;
        swapFeeBps = _swapFeeBps;
        emit SwapFeeUpdated(oldFee, _swapFeeBps);
    }

    /**
     * @notice Update fee recipient
     * @param _feeRecipient New fee recipient address
     * @dev Can only be called by owner
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidRecipientAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @notice Pause all swaps
     * @dev Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause swaps
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue stuck tokens
     * @param token Token address
     * @param amount Amount to rescue
     * @param recipient Recipient address
     * @dev Emergency function to recover stuck tokens
     */
    function rescueTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        if (token == address(0) || recipient == address(0)) {
            revert InvalidTokenAddress();
        }

        IERC20(token).safeTransfer(recipient, amount);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get swap statistics
     * @return volume Total swap volume
     * @return fees Total fees collected
     */
    function getSwapStats() external view returns (uint256 volume, uint256 fees) {
        return (totalSwapVolume, totalFeesCollected);
    }

    /**
     * @notice Check if liquidity source is registered
     * @param sourceId Source identifier
     * @return isRegistered True if source is registered
     */
    function isLiquiditySourceRegistered(
        bytes32 sourceId
    ) external view returns (bool isRegistered) {
        return liquiditySources[sourceId] != address(0);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute swap through a multi-hop path
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param amountIn Input amount
     * @return amountOut Final output amount
     * @dev Executes swaps sequentially through the path
     */
    function _executeSwapPath(
        address[] calldata path,
        bytes32[] calldata sources,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        amountOut = amountIn;

        // Execute each hop in the path
        for (uint256 i = 0; i < path.length - 1; ++i) {
            bytes32 sourceId = sources[i];

            // Get adapter for this liquidity source
            address adapter = liquiditySources[sourceId];
            if (adapter == address(0)) revert InvalidLiquiditySource();

            // Execute swap through adapter
            // NOTE: This is a simplified implementation
            // In production, implement actual adapter calls via ISwapAdapter interface
            // For now, placeholder that returns the input amount
            amountOut = amountIn; // Placeholder - TODO: Implement adapter interface
        }

        return amountOut;
    }

    /**
     * @notice Estimate output amount for a swap path
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param amountIn Input amount
     * @return amountOut Estimated output amount
     * @dev View function for quote estimation
     */
    function _estimateSwapPath(
        address[] calldata path,
        bytes32[] calldata sources,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        amountOut = amountIn;

        // Estimate each hop in the path
        for (uint256 i = 0; i < path.length - 1; ++i) {
            bytes32 sourceId = sources[i];

            // Get adapter for this liquidity source
            address adapter = liquiditySources[sourceId];
            if (adapter == address(0)) revert InvalidLiquiditySource();

            // Get quote from adapter
            // NOTE: This is a simplified implementation
            // In production, implement actual adapter quote calls via ISwapAdapter interface
            // For now, placeholder that returns the input amount
            amountOut = amountIn; // Placeholder - TODO: Implement adapter interface
        }

        return amountOut;
    }
}
