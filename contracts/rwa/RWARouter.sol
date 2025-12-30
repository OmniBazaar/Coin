// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRWAAMM} from "./interfaces/IRWAAMM.sol";
import {IRWAPool} from "./interfaces/IRWAPool.sol";

/**
 * @title RWARouter
 * @author OmniCoin Development Team
 * @notice User-facing router for RWA token swaps
 * @dev Provides convenience functions for interacting with RWA AMM
 *
 * Key Features:
 * - Single-hop and multi-hop swaps
 * - Slippage protection
 * - Deadline enforcement
 * - Liquidity management helpers
 * - Quote functions for UI
 *
 * Security Features:
 * - Reentrancy protection
 * - Deadline validation
 * - Minimum output validation
 * - Path validation
 */
contract RWARouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // IMMUTABLE STATE
    // ========================================================================

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Reference to the core AMM contract
    IRWAAMM public immutable AMM;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice WETH/WAVAX address for native token wrapping
    address public immutable WRAPPED_NATIVE;

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when deadline has passed
    /// @param deadline Expired deadline timestamp
    /// @param currentTime Current block timestamp
    error DeadlineExpired(uint256 deadline, uint256 currentTime);

    /// @notice Thrown when output amount is insufficient
    /// @param amountOut Actual output amount
    /// @param amountOutMin Minimum required output
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);

    /// @notice Thrown when path is invalid
    error InvalidPath();

    /// @notice Thrown when liquidity amounts are insufficient
    /// @param amountA Amount of token A
    /// @param amountB Amount of token B
    error InsufficientLiquidity(uint256 amountA, uint256 amountB);

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when pool does not exist
    /// @param tokenA First token address
    /// @param tokenB Second token address
    error PoolDoesNotExist(address tokenA, address tokenB);

    /// @notice Thrown when native transfer fails
    error NativeTransferFailed();

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when swap is executed
    /// @param sender Transaction sender
    /// @param path Swap path (token addresses)
    /// @param amountIn Input amount
    /// @param amountOut Output amount
    event SwapExecuted(
        address indexed sender,
        address[] path,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when liquidity is added
    /// @param sender Transaction sender
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @param amountA Amount of token A
    /// @param amountB Amount of token B
    /// @param liquidity LP tokens minted
    event LiquidityAdded(
        address indexed sender,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /// @notice Emitted when liquidity is removed
    /// @param sender Transaction sender
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @param amountA Amount of token A received
    /// @param amountB Amount of token B received
    /// @param liquidity LP tokens burned
    event LiquidityRemoved(
        address indexed sender,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Ensures deadline has not passed
     * @param deadline Deadline timestamp
     */
    modifier ensure(uint256 deadline) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploy the router
     * @param _amm Core AMM contract address
     * @param _wrappedNative Wrapped native token address (WAVAX)
     */
    constructor(address _amm, address _wrappedNative) {
        if (_amm == address(0)) revert ZeroAddress();
        if (_wrappedNative == address(0)) revert ZeroAddress();

        AMM = IRWAAMM(_amm);
        WRAPPED_NATIVE = _wrappedNative;
    }

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /**
     * @notice Swap exact input tokens for output tokens
     * @param amountIn Exact input amount
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param path Array of token addresses (swap route)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for each hop
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        if (amountIn == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        // Calculate amounts for each hop
        amounts = getAmountsOut(amountIn, path);

        // Verify minimum output
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount(amounts[amounts.length - 1], amountOutMin);
        }

        // Transfer input tokens from sender to first pool
        address firstPool = _getPool(path[0], path[1]);
        IERC20(path[0]).safeTransferFrom(msg.sender, firstPool, amountIn);

        // Execute swaps along the path
        _swap(amounts, path, to);

        emit SwapExecuted(msg.sender, path, amountIn, amounts[amounts.length - 1]);
    }

    /**
     * @notice Swap tokens for exact output amount
     * @param amountOut Exact output amount desired
     * @param amountInMax Maximum input amount (slippage protection)
     * @param path Array of token addresses (swap route)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for each hop
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        if (amountOut == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        // Calculate required input amounts
        amounts = getAmountsIn(amountOut, path);

        // Verify maximum input
        if (amounts[0] > amountInMax) {
            revert InsufficientOutputAmount(amountInMax, amounts[0]);
        }

        // Transfer input tokens from sender to first pool
        address firstPool = _getPool(path[0], path[1]);
        IERC20(path[0]).safeTransferFrom(msg.sender, firstPool, amounts[0]);

        // Execute swaps along the path
        _swap(amounts, path, to);

        emit SwapExecuted(msg.sender, path, amounts[0], amountOut);
    }

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /**
     * @notice Add liquidity to a pool
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of token A
     * @param amountBDesired Desired amount of token B
     * @param amountAMin Minimum amount of token A (slippage)
     * @param amountBMin Minimum amount of token B (slippage)
     * @param to Recipient of LP tokens
     * @param deadline Transaction deadline
     * @return amountA Actual amount of token A deposited
     * @return amountB Actual amount of token B deposited
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    ) {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();

        // Calculate optimal amounts
        (amountA, amountB) = _calculateLiquidityAmounts(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );

        // Get or create pool
        address pool = _getPool(tokenA, tokenB);

        // Transfer tokens to pool
        IERC20(tokenA).safeTransferFrom(msg.sender, pool, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pool, amountB);

        // Mint LP tokens
        liquidity = IRWAPool(pool).mint(to);

        emit LiquidityAdded(msg.sender, tokenA, tokenB, amountA, amountB, liquidity);
    }

    /**
     * @notice Remove liquidity from a pool
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param liquidity LP tokens to burn
     * @param amountAMin Minimum amount of token A (slippage)
     * @param amountBMin Minimum amount of token B (slippage)
     * @param to Recipient of underlying tokens
     * @param deadline Transaction deadline
     * @return amountA Amount of token A received
     * @return amountB Amount of token B received
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (
        uint256 amountA,
        uint256 amountB
    ) {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert ZeroAmount();

        address pool = _getPool(tokenA, tokenB);

        // Transfer LP tokens to pool
        IERC20(pool).safeTransferFrom(msg.sender, pool, liquidity);

        // Burn LP tokens and receive underlying
        (uint256 amount0, uint256 amount1) = IRWAPool(pool).burn(to);

        // Sort amounts to match token order
        (address token0,) = _sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        // Verify minimum amounts
        if (amountA < amountAMin || amountB < amountBMin) {
            revert InsufficientLiquidity(amountA, amountB);
        }

        emit LiquidityRemoved(msg.sender, tokenA, tokenB, amountA, amountB, liquidity);
    }

    // ========================================================================
    // QUOTE FUNCTIONS
    // ========================================================================

    /**
     * @notice Get output amounts for a given input along path
     * @param amountIn Input amount
     * @param path Array of token addresses
     * @return amounts Array of output amounts for each hop
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            address pool = _getPool(path[i], path[i + 1]);
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(pool, path[i], path[i + 1]);
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /**
     * @notice Get input amounts required for a given output along path
     * @param amountOut Desired output amount
     * @param path Array of token addresses
     * @return amounts Array of input amounts for each hop
     */
    function getAmountsIn(
        uint256 amountOut,
        address[] memory path
    ) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        for (uint256 i = path.length - 1; i > 0; --i) {
            address pool = _getPool(path[i - 1], path[i]);
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(pool, path[i - 1], path[i]);
            amounts[i - 1] = _getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    /**
     * @notice Quote liquidity amounts for adding liquidity
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of token A
     * @param amountBDesired Desired amount of token B
     * @return amountA Optimal amount of token A
     * @return amountB Optimal amount of token B
     */
    function quoteLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB) {
        address pool = AMM.getPool(tokenA, tokenB);

        if (pool == address(0)) {
            // New pool - use desired amounts
            return (amountADesired, amountBDesired);
        }

        (uint256 reserveA, uint256 reserveB) = _getReserves(pool, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        // Calculate optimal amount B for desired amount A
        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);

        if (amountBOptimal <= amountBDesired) {
            return (amountADesired, amountBOptimal);
        } else {
            // Calculate optimal amount A for desired amount B
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            return (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @notice Get pool address for token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pool Pool address (or zero if doesn't exist)
     */
    function getPool(
        address tokenA,
        address tokenB
    ) external view returns (address pool) {
        return AMM.getPool(tokenA, tokenB);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute swaps along a path
     * @param amounts Pre-calculated amounts for each hop
     * @param path Token addresses in the path
     * @param _to Final recipient
     */
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i = 0; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = _sortTokens(input, output);

            uint256 amountOut = amounts[i + 1];

            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            // Determine recipient (next pool or final recipient)
            address to = i < path.length - 2
                ? _getPool(output, path[i + 2])
                : _to;

            IRWAPool(_getPool(input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    /**
     * @notice Calculate optimal liquidity amounts
     * @param tokenA First token
     * @param tokenB Second token
     * @param amountADesired Desired amount A
     * @param amountBDesired Desired amount B
     * @param amountAMin Minimum amount A
     * @param amountBMin Minimum amount B
     * @return amountA Optimal amount A
     * @return amountB Optimal amount B
     */
    function _calculateLiquidityAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        address pool = AMM.getPool(tokenA, tokenB);

        if (pool == address(0)) {
            // New pool - use desired amounts
            return (amountADesired, amountBDesired);
        }

        (uint256 reserveA, uint256 reserveB) = _getReserves(pool, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);

        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) {
                revert InsufficientLiquidity(amountADesired, amountBOptimal);
            }
            return (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            if (amountAOptimal > amountADesired) {
                revert InsufficientLiquidity(amountAOptimal, amountBDesired);
            }
            if (amountAOptimal < amountAMin) {
                revert InsufficientLiquidity(amountAOptimal, amountBDesired);
            }
            return (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @notice Get pool address (reverts if doesn't exist)
     * @param tokenA First token
     * @param tokenB Second token
     * @return pool Pool address
     */
    function _getPool(
        address tokenA,
        address tokenB
    ) internal view returns (address pool) {
        pool = AMM.getPool(tokenA, tokenB);
        if (pool == address(0)) {
            revert PoolDoesNotExist(tokenA, tokenB);
        }
    }

    /**
     * @notice Get reserves for a pool in specified token order
     * @param pool Pool address
     * @param tokenA First token
     * @param tokenB Second token
     * @return reserveA Reserve of token A
     * @return reserveB Reserve of token B
     */
    function _getReserves(
        address pool,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0,) = _sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IRWAPool(pool).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    /**
     * @notice Sort tokens by address
     * @param tokenA First token
     * @param tokenB Second token
     * @return token0 Lower address
     * @return token1 Higher address
     */
    function _sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
    }

    /**
     * @notice Quote amount of tokenB for given amount of tokenA
     * @param amountA Amount of token A
     * @param reserveA Reserve of token A
     * @param reserveB Reserve of token B
     * @return amountB Equivalent amount of token B
     */
    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert ZeroAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity(reserveA, reserveB);
        amountB = (amountA * reserveB) / reserveA;
    }

    /**
     * @notice Calculate output amount for given input
     * @dev Uses constant-product formula with 0.3% fee
     * @param amountIn Input amount
     * @param reserveIn Input token reserve
     * @param reserveOut Output token reserve
     * @return amountOut Output amount
     */
    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) {
            revert InsufficientLiquidity(reserveIn, reserveOut);
        }

        // Apply 0.3% fee (997/1000)
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /**
     * @notice Calculate input amount required for given output
     * @dev Uses constant-product formula with 0.3% fee
     * @param amountOut Desired output amount
     * @param reserveIn Input token reserve
     * @param reserveOut Output token reserve
     * @return amountIn Required input amount
     */
    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) {
            revert InsufficientLiquidity(reserveIn, reserveOut);
        }
        if (amountOut >= reserveOut) {
            revert InsufficientLiquidity(reserveIn, reserveOut);
        }

        // Apply 0.3% fee (1000/997)
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }
}
