// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";
import {MockRWAPool} from "./MockRWAPool.sol";

/**
 * @title MockRWAAMMFull
 * @author OmniBazaar Test Suite
 * @notice Full `IRWAAMM`-surface mock backed by real {MockRWAPool}
 *         instances, for POLManager unit tests.
 * @dev Implements the exact `IRWAAMM` functions POLManager calls:
 *      `getPoolId`, `poolExists`, `getPool(bytes32)`,
 *      `getPool(address,address)`, `getPoolAddress`, `addLiquidity`,
 *      `removeLiquidity`, `getQuote`. `addLiquidity` returns the
 *      REALIZED `(amount0, amount1, liquidity)` and supports a
 *      configurable ratio-dust skim so POLManager's realized-principal
 *      accounting can be exercised.
 *
 *      Named `MockRWAAMMFull` to avoid colliding with the pre-existing,
 *      insufficient `contracts/mocks/MockRWAAMM.sol`.
 */
contract MockRWAAMMFull {
    using SafeERC20 for IERC20;

    /// @notice Protocol fee in basis points (matches RWAAMM default).
    uint256 public constant PROTOCOL_FEE_BPS = 30;

    /// @notice Basis-points denominator.
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice poolId => MockRWAPool address.
    mapping(bytes32 => address) public pools;

    /// @notice Basis-points haircut applied to the `token0` side of an
    ///         `addLiquidity` deposit.
    /// @dev Models an adversarially reserve-skewed pool where the
    ///      optimal-ratio match trims the `token0` side hard: only
    ///      `(BPS_DENOMINATOR - addLiquidityHaircutBps)` of the
    ///      supplied `token0` is actually deposited, shrinking the
    ///      redeployed position's tracked principal so POLManager's D1
    ///      end-to-end value assertion (`HarvestValueLoss` /
    ///      `CompoundValueLoss`) trips. The `token0` side is chosen
    ///      because POLManager passes `amount0Min = 0`, so the haircut
    ///      reaches the value check rather than the per-leg
    ///      `amount1Min` guard. Zero = honest behavior.
    uint256 public addLiquidityHaircutBps;

    /// @notice Thrown when a pool does not exist.
    /// @param poolId The missing pool id.
    error PoolNotFound(bytes32 poolId);

    /**
     * @notice Compute the canonical pool id for a token pair.
     * @dev Identical to `RWAAMM.getPoolId` — sorts the pair.
     * @param token0 First token.
     * @param token1 Second token.
     * @return poolId The pool identifier.
     */
    function getPoolId(
        address token0,
        address token1
    ) public pure returns (bytes32 poolId) {
        (address a, address b) = token0 < token1
            ? (token0, token1)
            : (token1, token0);
        poolId = keccak256(abi.encodePacked(a, b));
    }

    /**
     * @notice Create a backing {MockRWAPool} for a pair (test helper).
     * @dev The pool's own token order is fixed at creation as the
     *      argument order — tests pass tokens in the order they want
     *      POLManager to store.
     * @param token0 First token (becomes pool `token0()`).
     * @param token1 Second token (becomes pool `token1()`).
     * @return poolId The pool id.
     * @return poolAddr The deployed pool address.
     */
    function createPool(
        address token0,
        address token1
    ) external returns (bytes32 poolId, address poolAddr) {
        poolId = getPoolId(token0, token1);
        require(pools[poolId] == address(0), "MockRWAAMM: exists");
        MockRWAPool pool = new MockRWAPool(token0, token1);
        poolAddr = address(pool);
        pools[poolId] = poolAddr;
    }

    /**
     * @notice Set the `addLiquidity` deposit haircut (test control).
     * @param bps Haircut in basis points; zero restores honest behavior.
     */
    function setAddLiquidityHaircutBps(uint256 bps) external {
        addLiquidityHaircutBps = bps;
    }

    /**
     * @notice Check whether a pool exists.
     * @param poolId The pool id.
     * @return exists True if a pool is registered.
     */
    function poolExists(
        bytes32 poolId
    ) external view returns (bool exists) {
        exists = pools[poolId] != address(0);
    }

    /**
     * @notice Resolve a pool address by id.
     * @param poolId The pool id.
     * @return pool The pool address (zero if none).
     */
    function getPoolAddress(
        bytes32 poolId
    ) external view returns (address pool) {
        pool = pools[poolId];
    }

    /**
     * @notice Resolve a pool address by token pair.
     * @param token0 First token.
     * @param token1 Second token.
     * @return pool The pool address (zero if none).
     */
    function getPool(
        address token0,
        address token1
    ) external view returns (address pool) {
        pool = pools[getPoolId(token0, token1)];
    }

    /**
     * @notice Read pool info, with `token0`/`token1` in the pool's own
     *         order (matches `RWAAMM.getPool(bytes32)`).
     * @param poolId The pool id.
     * @return info The pool info struct.
     */
    function getPool(
        bytes32 poolId
    ) external view returns (IRWAAMM.PoolInfo memory info) {
        address poolAddr = pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);
        MockRWAPool pool = MockRWAPool(poolAddr);
        (uint256 r0, uint256 r1, ) = pool.getReserves();
        info = IRWAAMM.PoolInfo({
            token0: pool.token0(),
            token1: pool.token1(),
            reserve0: r0,
            reserve1: r1,
            totalLiquidity: pool.totalSupply(),
            lastUpdateTimestamp: block.timestamp,
            status: IRWAAMM.PoolStatus.ACTIVE,
            complianceRequired: false
        });
    }

    /**
     * @notice Spot quote against a pool's current reserves.
     * @param tokenIn Input token.
     * @param tokenOut Output token.
     * @param amountIn Input amount.
     * @return amountOut Output after the protocol fee.
     * @return protocolFee Fee taken from the input.
     * @return priceImpact Always zero in this mock.
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        external
        view
        returns (
            uint256 amountOut,
            uint256 protocolFee,
            uint256 priceImpact
        )
    {
        address poolAddr = pools[getPoolId(tokenIn, tokenOut)];
        if (poolAddr == address(0)) {
            revert PoolNotFound(getPoolId(tokenIn, tokenOut));
        }
        MockRWAPool pool = MockRWAPool(poolAddr);
        (uint256 r0, uint256 r1, ) = pool.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = pool.token0() == tokenIn
            ? (r0, r1)
            : (r1, r0);
        protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - protocolFee;
        amountOut = (reserveOut * afterFee) / (reserveIn + afterFee);
        priceImpact = 0;
    }

    /**
     * @notice Add proportional liquidity to a pool, returning the
     *         REALIZED deposit amounts.
     * @dev `token0`/`token1` are passed in the pool's own order by
     *      POLManager. Pulls the optimal amounts from the caller,
     *      mints LP to `onBehalfOf`, and returns the realized
     *      `(amount0, amount1, liquidity)`.
     * @param token0 First token of the pair (pool order).
     * @param token1 Second token of the pair (pool order).
     * @param amount0Desired Desired token0 input.
     * @param amount1Desired Desired token1 input.
     * @param amount0Min Minimum token0 (unused on the executing branch).
     * @param amount1Min Minimum token1.
     * @param deadline Transaction deadline.
     * @param onBehalfOf LP-token recipient.
     * @return amount0 Realized token0 deposited.
     * @return amount1 Realized token1 deposited.
     * @return liquidity LP tokens minted.
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
    )
        external
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 liquidity
        )
    {
        amount0Min;
        // solhint-disable-next-line not-rely-on-time
        require(deadline >= block.timestamp, "MockRWAAMM: deadline");

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);
        MockRWAPool pool = MockRWAPool(poolAddr);

        (uint256 r0, uint256 r1, ) = pool.getReserves();
        (amount0, amount1) = _optimalAmounts(
            r0, r1, amount0Desired, amount1Desired
        );

        // Adversarial-pool model: trim the token0 side of the deposit
        // by the configured haircut so the redeployed position's
        // tracked principal shrinks (exercises POLManager's D1
        // value-loss assertion). token0 is trimmed (not token1)
        // because POLManager passes `amount0Min = 0`.
        uint256 haircut = addLiquidityHaircutBps;
        if (haircut != 0) {
            amount0 = (amount0 * (BPS_DENOMINATOR - haircut)) /
                BPS_DENOMINATOR;
        }
        require(amount1 >= amount1Min, "MockRWAAMM: amount1Min");

        // Pull the realized amounts from the caller into the pool.
        IERC20(pool.token0()).safeTransferFrom(
            msg.sender, poolAddr, amount0
        );
        IERC20(pool.token1()).safeTransferFrom(
            msg.sender, poolAddr, amount1
        );

        liquidity = pool.mint(onBehalfOf);
    }

    /**
     * @notice Remove proportional liquidity, returning underlying.
     * @param token0 First token (pool order).
     * @param token1 Second token (pool order).
     * @param liquidity LP tokens to burn.
     * @param amount0Min Minimum token0 out.
     * @param amount1Min Minimum token1 out.
     * @param deadline Transaction deadline.
     * @param onBehalfOf Recipient of the underlying tokens.
     * @return amount0 Token0 returned.
     * @return amount1 Token1 returned.
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
        // solhint-disable-next-line not-rely-on-time
        require(deadline >= block.timestamp, "MockRWAAMM: deadline");

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);
        MockRWAPool pool = MockRWAPool(poolAddr);

        // Pull LP tokens from the caller into the pool, then burn.
        IERC20(poolAddr).safeTransferFrom(
            msg.sender, poolAddr, liquidity
        );
        (amount0, amount1) = pool.burn(onBehalfOf);

        require(amount0 >= amount0Min, "MockRWAAMM: amount0Min");
        require(amount1 >= amount1Min, "MockRWAAMM: amount1Min");
    }

    /**
     * @notice Compute the optimal proportional add amounts.
     * @dev For an empty pool both desired amounts are used. Otherwise
     *      the deposit is matched to the live reserve ratio: the side
     *      that would over-supply is trimmed.
     * @param reserve0 Current token0 reserve.
     * @param reserve1 Current token1 reserve.
     * @param amount0Desired Desired token0 input.
     * @param amount1Desired Desired token1 input.
     * @return amount0 Optimal token0 amount.
     * @return amount1 Optimal token1 amount.
     */
    function _optimalAmounts(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (reserve0 == 0 && reserve1 == 0) {
            return (amount0Desired, amount1Desired);
        }
        uint256 amount1Optimal =
            (amount0Desired * reserve1) / reserve0;
        if (amount1Optimal <= amount1Desired) {
            return (amount0Desired, amount1Optimal);
        }
        uint256 amount0Optimal =
            (amount1Desired * reserve0) / reserve1;
        return (amount0Optimal, amount1Desired);
    }
}
