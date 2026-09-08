// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRWAPool
 * @author OmniCoin Development Team
 * @notice Interface for individual RWA liquidity pools
 * @dev Each pool handles a single RWA/XOM token pair
 */
interface IRWAPool {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when reserves are synchronized
    /// @param reserve0 New reserve of token0
    /// @param reserve1 New reserve of token1
    event Sync(uint256 indexed reserve0, uint256 indexed reserve1);

    /// @notice Emitted when tokens are minted
    /// @param sender Address that triggered mint
    /// @param amount0 Token0 deposited
    /// @param amount1 Token1 deposited
    event Mint(
        address indexed sender,
        uint256 indexed amount0,
        uint256 indexed amount1
    );

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when a swap is executed on the pool
    /// @param sender Address that triggered the swap (factory)
    /// @param amount0In Token0 input amount
    /// @param amount1In Token1 input amount
    /// @param amount0Out Token0 output amount
    /// @param amount1Out Token1 output amount
    /// @param to Recipient address
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted when tokens are burned
    /// @param sender Address that triggered burn
    /// @param amount0 Token0 withdrawn
    /// @param amount1 Token1 withdrawn
    /// @param to Recipient address
    event Burn(
        address indexed sender,
        uint256 indexed amount0,
        uint256 amount1,
        address indexed to
    );
    /* solhint-enable gas-indexed-events */

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when k value decreases (invariant violation)
    error KValueDecreased();

    /// @notice Thrown when insufficient liquidity minted
    error InsufficientLiquidityMinted();

    /// @notice Thrown when insufficient liquidity burned
    error InsufficientLiquidityBurned();

    /// @notice Thrown when insufficient liquidity in reserves
    /// @param requested Amount requested
    /// @param available Amount available
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Thrown when output amounts are insufficient
    error InsufficientOutputAmount();

    /// @notice Thrown when input amounts are insufficient
    error InsufficientInputAmount();

    /// @notice Thrown when locked for reentrancy
    error Locked();

    /// @notice Thrown when overflow occurs
    error Overflow();

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get token0 address
     * @return Token0 address
     */
    function token0() external view returns (address);

    /**
     * @notice Get token1 address
     * @return Token1 address
     */
    function token1() external view returns (address);

    /**
     * @notice Get current reserves and last update timestamp
     * @return reserve0 Token0 reserve
     * @return reserve1 Token1 reserve
     * @return blockTimestampLast Last update block timestamp
     */
    function getReserves() external view returns (
        uint256 reserve0,
        uint256 reserve1,
        uint32 blockTimestampLast
    );

    /**
     * @notice Get cumulative price for token0
     * @return price0CumulativeLast Cumulative price of token0
     */
    function price0CumulativeLast() external view returns (uint256);

    /**
     * @notice Get cumulative price for token1
     * @return price1CumulativeLast Cumulative price of token1
     */
    function price1CumulativeLast() external view returns (uint256);

    /**
     * @notice Get k value (reserve0 * reserve1)
     * @return kLast Last recorded k value
     */
    function kLast() external view returns (uint256);

    /* solhint-disable func-name-mixedcase */
    /**
     * @notice Get minimum liquidity locked on first mint
     * @return Minimum liquidity amount (1000)
     */
    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    /* solhint-enable func-name-mixedcase */

    /* solhint-disable ordering */
    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /**
     * @notice Initialize pool with token pair
     * @param _token0 First token address
     * @param _token1 Second token address
     */
    function initialize(address _token0, address _token1) external;
    /* solhint-enable ordering */

    /**
     * @notice Mint LP tokens for deposited liquidity
     * @param to Recipient of LP tokens
     * @return liquidity Amount of LP tokens minted
     */
    function mint(address to) external returns (uint256 liquidity);

    /**
     * @notice Burn LP tokens and withdraw liquidity
     * @param to Recipient of withdrawn tokens
     * @return amount0 Token0 withdrawn
     * @return amount1 Token1 withdrawn
     */
    function burn(address to) external returns (
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice Execute swap on the pool
     * @param amount0Out Token0 output amount
     * @param amount1Out Token1 output amount
     * @param to Recipient address
     * @param data Callback data (for flash swaps)
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * @notice Force sync reserves with actual balances
     */
    function sync() external;

    /**
     * @notice Skim excess tokens to recipient
     * @param to Recipient of excess tokens
     */
    function skim(address to) external;
}
