// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockRWAPool
 * @author OmniBazaar Test Suite
 * @notice Faithful Uniswap-V2-style constant-product pool for POLManager
 *         unit tests.
 * @dev Replicates `RWAPool`'s `_update` UQ112x112 cumulative-price
 *      accumulator math so POLManager's `_currentCumulativePrices` +
 *      TWAP machinery can be driven by `evm_increaseTime` / `mine`.
 *      The pool is the LP ERC-20 token itself (`token0()`/`token1()`
 *      report the underlying pair). State-changing functions are
 *      permissionless here — the test driver calls them directly via
 *      MockRWAAMM.
 */
contract MockRWAPool is ERC20 {
    using SafeERC20 for IERC20;

    /// @notice Minimum liquidity locked on the first mint.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Dead address that receives the locked minimum liquidity.
    address private constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /// @notice First token of the pair.
    address public token0;

    /// @notice Second token of the pair.
    address public token1;

    /// @notice Reserve of token0.
    uint112 private reserve0;

    /// @notice Reserve of token1.
    uint112 private reserve1;

    /// @notice Timestamp (mod 2^32) of the last reserve update.
    uint32 private blockTimestampLast;

    /// @notice Cumulative token0->token1 price accumulator (UQ112x112).
    uint256 public price0CumulativeLast;

    /// @notice Cumulative token1->token0 price accumulator (UQ112x112).
    uint256 public price1CumulativeLast;

    /// @notice Last recorded product of reserves.
    uint256 public kLast;

    /// @notice Thrown when insufficient liquidity is minted.
    error InsufficientLiquidityMinted();

    /// @notice Thrown when insufficient liquidity is burned.
    error InsufficientLiquidityBurned();

    /// @notice Thrown when a reserve would exceed uint112.
    error Overflow();

    /// @notice Emitted when reserves are synchronized.
    /// @param reserve0 New reserve of token0.
    /// @param reserve1 New reserve of token1.
    event Sync(uint112 reserve0, uint112 reserve1);

    /**
     * @notice Deploy the mock pool with a fixed token pair.
     * @param token0_ First token of the pair.
     * @param token1_ Second token of the pair.
     */
    constructor(
        address token0_,
        address token1_
    ) ERC20("Mock RWA Pool LP", "MOCK-LP") {
        token0 = token0_;
        token1 = token1_;
    }

    /**
     * @notice Read current reserves and the last update timestamp.
     * @return reserve0_ Token0 reserve.
     * @return reserve1_ Token1 reserve.
     * @return blockTimestampLast_ Last update timestamp (mod 2^32).
     */
    function getReserves()
        external
        view
        returns (
            uint256 reserve0_,
            uint256 reserve1_,
            uint32 blockTimestampLast_
        )
    {
        reserve0_ = reserve0;
        reserve1_ = reserve1;
        blockTimestampLast_ = blockTimestampLast;
    }

    /**
     * @notice Total LP supply (alias used by some callers).
     * @return supply The current LP token total supply.
     */
    function totalLiquidity() external view returns (uint256 supply) {
        supply = totalSupply();
    }

    /**
     * @notice Mint LP tokens against tokens already transferred in.
     * @dev Uniswap-V2 mint: first deposit mints `sqrt(a0*a1) - MIN_LIQ`,
     *      subsequent deposits mint proportionally.
     * @param to Recipient of the LP tokens.
     * @return liquidity LP tokens minted.
     */
    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(
                (amount0 * supply) / reserve0,
                (amount1 * supply) / reserve1
            );
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        kLast = uint256(reserve0) * uint256(reserve1);
    }

    /**
     * @notice Burn LP tokens held by this pool and return proportional
     *         reserves.
     * @param to Recipient of the underlying tokens.
     * @return amount0 Token0 returned.
     * @return amount1 Token1 returned.
     */
    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        uint256 supply = totalSupply();

        amount0 = (liquidity * balance0) / supply;
        amount1 = (liquidity * balance1) / supply;
        if (amount0 == 0 || amount1 == 0) {
            revert InsufficientLiquidityBurned();
        }

        _burn(address(this), liquidity);

        uint256 newBalance0 = balance0 - amount0;
        uint256 newBalance1 = balance1 - amount1;
        _update(newBalance0, newBalance1);
        kLast = newBalance0 * newBalance1;

        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);
    }

    /**
     * @notice Execute a constant-product swap against this pool.
     * @dev Output tokens must be transferable from the pool's balance;
     *      the K-invariant is verified after the optimistic transfer.
     * @param amount0Out Token0 to send to `to`.
     * @param amount1Out Token1 to send to `to`.
     * @param to Recipient of the swap output.
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        require(amount0Out < r0 && amount1Out < r1, "MockRWAPool: OUT");

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // K-invariant check (fee-free here — the swap source applies fee
        // by reducing the output amount it requests).
        require(
            balance0 * balance1 >= r0 * r1,
            "MockRWAPool: K"
        );
        _update(balance0, balance1);
    }

    /**
     * @notice Synchronize reserves to the pool's actual token balances.
     */
    function sync() external {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        );
    }

    /**
     * @notice Update reserves and advance the TWAP accumulators.
     * @dev Faithful copy of `RWAPool._update`: accumulates
     *      `(reserveOther << 112) / reserveThis * timeElapsed`.
     * @param balance0 New token0 balance.
     * @param balance1 New token1 balance.
     */
    function _update(uint256 balance0, uint256 balance1) private {
        if (
            balance0 > type(uint112).max ||
            balance1 > type(uint112).max
        ) {
            revert Overflow();
        }

        // solhint-disable-next-line not-rely-on-time
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                price0CumulativeLast +=
                    ((uint256(reserve1) << 112) / reserve0) *
                    timeElapsed;
                price1CumulativeLast +=
                    ((uint256(reserve0) << 112) / reserve1) *
                    timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }
}
