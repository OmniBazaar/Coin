// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRWAAMM
 * @author OmniCoin Development Team
 * @notice Interface for the immutable RWA AMM core contract
 * @dev Defines the essential functions for RWA trading
 */
interface IRWAAMM {
    // ========================================================================
    // ENUMS
    // ========================================================================

    /// @notice Pool status for monitoring
    enum PoolStatus {
        ACTIVE,
        PAUSED,
        DEPRECATED
    }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Pool information structure
     * @dev Contains all pool metadata and reserves
     */
    struct PoolInfo {
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLiquidity;
        uint256 lastUpdateTimestamp;
        PoolStatus status;
        bool complianceRequired;
    }

    /**
     * @notice Swap result information
     * @dev Returned after successful swap execution
     */
    struct SwapResult {
        uint256 amountIn;
        uint256 amountOut;
        uint256 protocolFee;
        uint256 priceImpact;
        address[] route;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a swap is executed
    /// @param sender Address initiating the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input amount
    /// @param amountOut Output amount
    /// @param protocolFee Fee collected
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 protocolFee
    );

    /// @notice Emitted when liquidity is added
    /// @param provider Address providing liquidity
    /// @param poolId Pool identifier
    /// @param amount0 Token0 amount
    /// @param amount1 Token1 amount
    /// @param liquidity LP tokens minted
    event LiquidityAdded(
        address indexed provider,
        bytes32 indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    /// @notice Emitted when liquidity is removed
    /// @param provider Address removing liquidity
    /// @param poolId Pool identifier
    /// @param amount0 Token0 amount
    /// @param amount1 Token1 amount
    /// @param liquidity LP tokens burned
    event LiquidityRemoved(
        address indexed provider,
        bytes32 indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    /// @notice Emitted when a new pool is created
    /// @param poolId Pool identifier
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param creator Pool creator address
    event PoolCreated(
        bytes32 indexed poolId,
        address indexed token0,
        address indexed token1,
        address creator
    );

    /// @notice Emitted when emergency pause is activated
    /// @param poolId Pool identifier (bytes32(0) for all)
    /// @param pauser Address that triggered pause
    /// @param reason Pause reason
    event EmergencyPaused(
        bytes32 indexed poolId,
        address indexed pauser,
        string reason
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when slippage tolerance is exceeded
    /// @param expected Expected minimum output
    /// @param actual Actual output amount
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @notice Thrown when pool does not exist
    /// @param poolId The pool identifier
    error PoolNotFound(bytes32 poolId);

    /// @notice Thrown when pool is paused
    /// @param poolId The pool identifier
    error PoolPaused(bytes32 poolId);

    /// @notice Thrown when compliance check fails
    /// @param user User address
    /// @param token Token address
    /// @param reason Failure reason
    error ComplianceCheckFailed(address user, address token, string reason);

    /// @notice Thrown when insufficient liquidity
    /// @param required Required amount
    /// @param available Available amount
    error InsufficientLiquidity(uint256 required, uint256 available);

    /// @notice Thrown when zero amount provided
    error ZeroAmount();

    /// @notice Thrown when deadline has passed
    /// @param deadline The deadline timestamp
    /// @param current Current timestamp
    error DeadlineExpired(uint256 deadline, uint256 current);

    /// @notice Thrown when caller lacks required signatures
    /// @param required Required signatures
    /// @param provided Provided signatures
    error InsufficientSignatures(uint256 required, uint256 provided);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get protocol fee in basis points
     * @return Fee in basis points (30 = 0.30%)
     */
    function protocolFeeBps() external pure returns (uint256);

    /**
     * @notice Get pool information
     * @param poolId Pool identifier
     * @return info Pool information struct
     */
    function getPool(bytes32 poolId) external view returns (PoolInfo memory info);

    /**
     * @notice Calculate pool ID from token pair
     * @param token0 First token address
     * @param token1 Second token address
     * @return poolId The pool identifier
     */
    function getPoolId(address token0, address token1) external pure returns (bytes32 poolId);

    /**
     * @notice Get pool address from token pair
     * @param token0 First token address
     * @param token1 Second token address
     * @return pool The pool contract address (zero if not exists)
     */
    function getPool(address token0, address token1) external view returns (address pool);

    /**
     * @notice Get quote for swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @return amountOut Expected output amount
     * @return protocolFee Protocol fee amount
     * @return priceImpact Price impact in basis points
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 protocolFee,
        uint256 priceImpact
    );

    /**
     * @notice Check if pool exists
     * @param poolId Pool identifier
     * @return exists True if pool exists
     */
    function poolExists(bytes32 poolId) external view returns (bool exists);

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute token swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param deadline Transaction deadline
     * @return result Swap result information
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (SwapResult memory result);

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /**
     * @notice Add liquidity to pool
     * @param token0 First token address
     * @param token1 Second token address
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0
     * @param amount1Min Minimum amount of token1
     * @param deadline Transaction deadline
     * @return amount0 Actual token0 deposited
     * @return amount1 Actual token1 deposited
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    /**
     * @notice Remove liquidity from pool
     * @param token0 First token address
     * @param token1 Second token address
     * @param liquidity LP tokens to burn
     * @param amount0Min Minimum token0 to receive
     * @param amount1Min Minimum token1 to receive
     * @param deadline Transaction deadline
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );

    // ========================================================================
    // EMERGENCY FUNCTIONS
    // ========================================================================

    /**
     * @notice Emergency pause (requires multi-sig)
     * @param poolId Pool to pause (bytes32(0) for all)
     * @param reason Reason for pause
     * @param signatures Multi-sig signatures
     */
    function emergencyPause(
        bytes32 poolId,
        string calldata reason,
        bytes[] calldata signatures
    ) external;

    /**
     * @notice Emergency unpause (requires multi-sig)
     * @param poolId Pool to unpause (bytes32(0) for all)
     * @param signatures Multi-sig signatures
     */
    function emergencyUnpause(
        bytes32 poolId,
        bytes[] calldata signatures
    ) external;
}
