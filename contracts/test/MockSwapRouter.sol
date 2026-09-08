// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmniSwapRouter} from "../interfaces/IOmniSwapRouter.sol";
import {MockRWAAMMFull} from "./MockRWAAMM.sol";
import {MockRWAPool} from "./MockRWAPool.sol";

/**
 * @title MockSwapRouter
 * @author OmniBazaar Test Suite
 * @notice `IOmniSwapRouter`-compatible mock that executes a real
 *         constant-product swap against a {MockRWAPool} resolved from a
 *         {MockRWAAMMFull}, for POLManager unit tests.
 * @dev The router pulls `amountIn` of `tokenIn` from the caller (who
 *      must approve it), applies a 30 bp fee, computes the
 *      constant-product output against the pool's live reserves, and
 *      uses {MockRWAPool-swap} to deliver `tokenOut` to `recipient`.
 *
 *      SANDWICH MODE: when `skewBps` is non-zero, the router first
 *      moves the pool's reserves (simulating a front-run trade) so the
 *      honest swap fills at a worse price — letting tests exercise
 *      POLManager's D1 `DeployValueLoss` end-to-end value bound.
 */
contract MockSwapRouter is IOmniSwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Fee in basis points taken from `amountIn` (matches AMM).
    uint256 public constant FEE_BPS = 30;

    /// @notice Basis-points denominator.
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice The AMM used to resolve pools for a token pair.
    MockRWAAMMFull public immutable AMM;

    /// @notice Pre-swap reserve skew, in basis points of the input
    ///         reserve. Zero = honest swap.
    uint256 public skewBps;

    /// @notice A funded account that backs the sandwich front-run.
    address public skewFunder;

    /**
     * @notice Deploy the router bound to a mock AMM.
     * @param amm_ The {MockRWAAMMFull} used to resolve pools.
     */
    constructor(address amm_) {
        AMM = MockRWAAMMFull(amm_);
    }

    /**
     * @notice Configure a sandwich front-run for the next swap.
     * @dev `funder` must hold both tokens and approve this router so the
     *      router can move reserves in/out of the pool before/after the
     *      honest fill.
     * @param newSkewBps Reserve skew in bps; zero disables sandwiching.
     * @param funder Account backing the front-run trade.
     */
    function setSkew(uint256 newSkewBps, address funder) external {
        skewBps = newSkewBps;
        skewFunder = funder;
    }

    /**
     * @notice Execute a single-hop swap against the resolved pool.
     * @dev Pulls `params.amountIn`, optionally front-runs the pool to
     *      simulate a sandwich, performs the constant-product fill, and
     *      delivers `tokenOut` to `params.recipient`.
     * @param params Swap parameters, see {IOmniSwapRouter-SwapParams}.
     * @return result The swap result.
     */
    function swap(
        SwapParams calldata params
    ) external override returns (SwapResult memory result) {
        // solhint-disable-next-line not-rely-on-time
        require(
            params.deadline >= block.timestamp,
            "MockSwapRouter: deadline"
        );

        address poolAddr =
            AMM.getPool(params.tokenIn, params.tokenOut);
        require(poolAddr != address(0), "MockSwapRouter: no pool");
        MockRWAPool pool = MockRWAPool(poolAddr);

        // Pull the input from the caller.
        IERC20(params.tokenIn).safeTransferFrom(
            msg.sender, address(this), params.amountIn
        );

        // Optional sandwich front-run: push `tokenIn` into the pool to
        // skew reserves against the honest fill that follows.
        if (skewBps != 0) {
            _frontRun(pool, params.tokenIn, params.tokenOut);
        }

        uint256 amountOut =
            _quoteAndFill(pool, params.tokenIn, params.tokenOut,
                params.amountIn, params.recipient);

        require(
            amountOut >= params.minAmountOut,
            "MockSwapRouter: minAmountOut"
        );

        result = SwapResult({
            amountOut: amountOut,
            feeAmount: (params.amountIn * FEE_BPS) / BPS_DENOMINATOR,
            route: keccak256(
                abi.encodePacked(params.path, params.sources)
            )
        });
    }

    /**
     * @notice Move pool reserves to simulate an adversarial front-run.
     * @dev The `skewFunder` swaps a `skewBps`-sized slice of the input
     *      reserve into the pool, worsening the price for the honest
     *      fill. The funder keeps whatever output it gets (the
     *      attacker's profit is not modelled — only the price impact).
     * @param pool The pool to skew.
     * @param tokenIn The honest swap's input token.
     * @param tokenOut The honest swap's output token.
     */
    function _frontRun(
        MockRWAPool pool,
        address tokenIn,
        address tokenOut
    ) private {
        (uint256 r0, uint256 r1, ) = pool.getReserves();
        bool inIsToken0 = pool.token0() == tokenIn;
        uint256 reserveIn = inIsToken0 ? r0 : r1;
        uint256 reserveOut = inIsToken0 ? r1 : r0;

        uint256 frontAmount = (reserveIn * skewBps) / BPS_DENOMINATOR;
        if (frontAmount == 0) return;

        // Funder supplies the front-run input into the pool.
        IERC20(tokenIn).safeTransferFrom(
            skewFunder, address(pool), frontAmount
        );
        uint256 frontOut =
            (reserveOut * frontAmount) / (reserveIn + frontAmount);
        if (inIsToken0) {
            pool.swap(0, frontOut, skewFunder);
        } else {
            pool.swap(frontOut, 0, skewFunder);
        }
    }

    /**
     * @notice Quote and execute the honest constant-product fill.
     * @param pool The pool to swap against.
     * @param tokenIn The input token.
     * @param tokenOut The output token.
     * @param amountIn The input amount held by this router.
     * @param recipient The output recipient.
     * @return amountOut The output delivered.
     */
    function _quoteAndFill(
        MockRWAPool pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) private returns (uint256 amountOut) {
        (uint256 r0, uint256 r1, ) = pool.getReserves();
        bool inIsToken0 = pool.token0() == tokenIn;
        uint256 reserveIn = inIsToken0 ? r0 : r1;
        uint256 reserveOut = inIsToken0 ? r1 : r0;

        uint256 fee = (amountIn * FEE_BPS) / BPS_DENOMINATOR;
        uint256 afterFee = amountIn - fee;
        amountOut =
            (reserveOut * afterFee) / (reserveIn + afterFee);

        // Deposit the input into the pool, then pull the output.
        IERC20(tokenIn).safeTransfer(address(pool), amountIn);
        if (inIsToken0) {
            pool.swap(0, amountOut, recipient);
        } else {
            pool.swap(amountOut, 0, recipient);
        }
        // The fee slice stays in the pool (donated to LPs) — harmless
        // for the test; it only raises K.
        tokenOut;
    }
}
