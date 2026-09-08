// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";

/**
 * @title MockRWAPool
 * @notice Mock LP token with getReserves() and token0() for LPZap tests
 * @dev Acts as both an ERC20 LP token and a pool with reserves
 */
contract MockRWAPool is ERC20 {
    /// @notice Token0 address (lower sorted)
    address public token0;

    /// @notice Token1 address (higher sorted)
    address public token1;

    /// @notice Reserve of token0
    uint256 public reserve0;

    /// @notice Reserve of token1
    uint256 public reserve1;

    /// @notice Last timestamp
    uint256 public lastTimestamp;

    /**
     * @notice Deploy with token pair
     * @param token0_ First token address
     * @param token1_ Second token address
     */
    constructor(
        address token0_,
        address token1_
    ) ERC20("Mock LP Token", "mLP") {
        token0 = token0_;
        token1 = token1_;
        lastTimestamp = block.timestamp;
    }

    /**
     * @notice Get reserves (compatible with RWAPool interface)
     * @return r0 Reserve of token0
     * @return r1 Reserve of token1
     * @return ts Last timestamp
     */
    function getReserves()
        external
        view
        returns (uint256 r0, uint256 r1, uint256 ts)
    {
        return (reserve0, reserve1, lastTimestamp);
    }

    /**
     * @notice Set reserves for testing
     * @param r0 Reserve of token0
     * @param r1 Reserve of token1
     */
    function setReserves(uint256 r0, uint256 r1) external {
        reserve0 = r0;
        reserve1 = r1;
        // solhint-disable-next-line not-rely-on-time
        lastTimestamp = block.timestamp;
    }

    /**
     * @notice Mint LP tokens (callable by mock RWAAMM)
     * @param to Recipient
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn LP tokens (callable by mock RWAAMM)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @title MockRWAAMMForZap
 * @notice Extended mock RWAAMM with addLiquidity, removeLiquidity, getPool
 * @dev Used for testing LPZap contract. Simulates constant-product AMM
 *      behavior with configurable exchange rate.
 */
contract MockRWAAMMForZap {
    using SafeERC20 for IERC20;

    /// @notice Exchange rate (output per input, scaled by 1e18)
    uint256 public exchangeRate;

    /// @notice Protocol fee in basis points
    uint256 public constant PROTOCOL_FEE_BPS = 30;

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice LP pool for each token pair
    mapping(bytes32 => address) public pools;

    /**
     * @notice Deploy with exchange rate
     * @param rate Exchange rate (1e18 = 1:1)
     */
    constructor(uint256 rate) {
        exchangeRate = rate;
    }

    /**
     * @notice Set the exchange rate
     * @param rate New rate (1e18 = 1:1)
     */
    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    /**
     * @notice Register a pool for a token pair
     * @param token0 First token
     * @param token1 Second token
     * @param pool LP pool address
     */
    function setPool(
        address token0,
        address token1,
        address pool
    ) external {
        bytes32 key = _pairKey(token0, token1);
        pools[key] = pool;
    }

    /**
     * @notice Get pool address for a token pair
     * @param token0 First token
     * @param token1 Second token
     * @return pool LP pool/token address
     */
    function getPool(
        address token0,
        address token1
    ) external view returns (address pool) {
        return pools[_pairKey(token0, token1)];
    }

    /**
     * @notice Get a quote for a swap
     * @param tokenIn Input token (unused)
     * @param tokenOut Output token (unused)
     * @param amountIn Input amount
     * @return amountOut Output amount after fee
     * @return protocolFee Fee amount
     * @return priceImpact Always 0 in mock
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 protocolFee,
        uint256 priceImpact
    ) {
        tokenIn;
        tokenOut;

        protocolFee =
            (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - protocolFee;
        amountOut = (afterFee * exchangeRate) / 1e18;
        priceImpact = 0;
    }

    /**
     * @notice Execute a swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param amountOutMin Minimum output (unused)
     * @param deadline Deadline (unused)
     * @param onBehalfOf On behalf of (unused)
     * @return result Swap result
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address onBehalfOf
    ) external returns (IRWAAMM.SwapResult memory result) {
        amountOutMin;
        deadline;
        onBehalfOf;

        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        uint256 protocolFee =
            (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - protocolFee;
        uint256 amountOut = (afterFee * exchangeRate) / 1e18;

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        address[] memory route = new address[](2);
        route[0] = tokenIn;
        route[1] = tokenOut;

        result = IRWAAMM.SwapResult({
            amountIn: amountIn,
            amountOut: amountOut,
            protocolFee: protocolFee,
            priceImpact: 0,
            route: route
        });
    }

    /**
     * @notice Add liquidity to a pool
     * @param token0 First token
     * @param token1 Second token
     * @param amount0Desired Amount of token0
     * @param amount1Desired Amount of token1
     * @param amount0Min Min token0 (unused)
     * @param amount1Min Min token1 (unused)
     * @param deadline Deadline (unused)
     * @param onBehalfOf On behalf of (unused)
     * @return amount0 Token0 used
     * @return amount1 Token1 used
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address onBehalfOf
    ) external returns (
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    ) {
        amount0Min;
        amount1Min;
        deadline;
        onBehalfOf;

        // Take both tokens
        IERC20(token0).safeTransferFrom(
            msg.sender, address(this), amount0Desired
        );
        IERC20(token1).safeTransferFrom(
            msg.sender, address(this), amount1Desired
        );

        amount0 = amount0Desired;
        amount1 = amount1Desired;

        // Mint LP tokens: simple formula (sqrt-ish mock)
        // Use the smaller proportional value
        liquidity = (amount0 + amount1) / 2;

        address pool = pools[_pairKey(token0, token1)];
        require(pool != address(0), "MockRWAAMM: no pool");
        MockRWAPool(pool).mint(msg.sender, liquidity);

        // Update reserves
        MockRWAPool(pool).setReserves(
            MockRWAPool(pool).reserve0() + amount0,
            MockRWAPool(pool).reserve1() + amount1
        );
    }

    /**
     * @notice Remove liquidity from a pool
     * @param token0 First token
     * @param token1 Second token
     * @param liquidity LP tokens to burn
     * @param amount0Min Min token0 output (unused)
     * @param amount1Min Min token1 output (unused)
     * @param deadline Deadline (unused)
     * @param onBehalfOf On behalf of (unused)
     * @return amount0 Token0 returned
     * @return amount1 Token1 returned
     */
    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address onBehalfOf
    ) external returns (uint256 amount0, uint256 amount1) {
        amount0Min;
        amount1Min;
        deadline;
        onBehalfOf;

        address pool = pools[_pairKey(token0, token1)];
        require(pool != address(0), "MockRWAAMM: no pool");

        uint256 totalSupply = IERC20(pool).totalSupply();
        require(totalSupply > 0, "MockRWAAMM: no liquidity");

        uint256 r0 = MockRWAPool(pool).reserve0();
        uint256 r1 = MockRWAPool(pool).reserve1();

        // Pro-rata share
        amount0 = (liquidity * r0) / totalSupply;
        amount1 = (liquidity * r1) / totalSupply;

        // Burn LP tokens from caller
        IERC20(pool).transferFrom(msg.sender, address(this), liquidity);
        MockRWAPool(pool).burn(address(this), liquidity);

        // Return underlying tokens
        IERC20(token0).safeTransfer(msg.sender, amount0);
        IERC20(token1).safeTransfer(msg.sender, amount1);

        // Update reserves
        MockRWAPool(pool).setReserves(r0 - amount0, r1 - amount1);
    }

    /**
     * @notice Compute deterministic pair key
     * @param a First token
     * @param b Second token
     * @return key Hash of sorted pair
     */
    function _pairKey(
        address a,
        address b
    ) internal pure returns (bytes32 key) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(t0, t1));
    }
}
