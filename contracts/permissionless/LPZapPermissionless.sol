// SPDX-License-Identifier: MIT
// solhint-disable gas-strict-inequalities
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAMMPermissionless} from "./interfaces/IAMMPermissionless.sol";

// ══════════════════════════════════════════════════════════════════════
//                           INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title ILiquidityOverflowPoolPermissionless
 * @notice Minimal interface for LiquidityOverflowPoolPermissionless staking
 * @dev Only the functions needed by LPZapPermissionless are included
 */
interface ILiquidityOverflowPoolPermissionless {
    /// @notice Stake LP tokens on behalf of a user
    /// @param poolId Pool index
    /// @param amount LP tokens to stake
    function stake(uint256 poolId, uint256 amount) external;

    /// @notice Unstake LP tokens from a pool
    /// @param poolId Pool index
    /// @param amount LP tokens to unstake
    function unstake(uint256 poolId, uint256 amount) external;

    /// @notice Claim rewards from a pool
    /// @param poolId Pool index
    function claimRewards(uint256 poolId) external;
}

/**
 * @title IAMMPermissionless_Extended
 * @notice Extended AMMPermissionless interface with addLiquidity and
 *         removeLiquidity
 * @dev The core IAMMPermissionless interface doesn't expose these
 *      signatures with the exact return types needed, so we define
 *      them explicitly. Signatures match AMMPermissionless directly
 *      (no `onBehalfOf` parameter, since there is no compliance gating).
 */
interface IAMMPermissionless_Extended {
    /// @notice Add liquidity to a pool
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Remove liquidity from a pool
    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap tokens
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (IAMMPermissionless.SwapResult memory result);

    /// @notice Get swap quote
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 protocolFee,
        uint256 priceImpact
    );

    /// @notice Get pool address for a token pair
    function getPool(
        address token0,
        address token1
    ) external view returns (address pool);
}

// ══════════════════════════════════════════════════════════════════════
//                           CONTRACT
// ══════════════════════════════════════════════════════════════════════

/**
 * @title LPZapPermissionless
 * @author OmniBazaar Team
 * @notice Single-sided USDC zap into XOM/USDC LP tokens (permissionless)
 * @dev Permissionless variant of LPZap used on external chains
 *      (Ethereum, Arbitrum, Base, Polygon) where OmniBazaar compliance
 *      gating does not apply. Immutable, non-upgradeable, trustless.
 *      Identical single-token zap math, dust-return logic, sandwich
 *      protection, and deadline enforcement as LPZap — the only
 *      differences are:
 *        1. Targets AMMPermissionless (no compliance oracle)
 *        2. Does not pass `onBehalfOf` to AMM.swap/addLiquidity/
 *           removeLiquidity
 *        3. No compliance checks — wallet-level OFAC screening is
 *           still enforced upstream
 *
 * User flow (zapIn):
 *   1. User approves USDC to this contract
 *   2. Contract swaps half USDC → XOM via AMMPermissionless
 *   3. Contract adds XOM + remaining USDC as liquidity → LP tokens
 *   4. LP tokens returned to user (user stakes separately)
 *
 * User flow (zapOut):
 *   1. User transfers LP tokens to this contract
 *   2. Contract removes liquidity → XOM + USDC
 *   3. Contract swaps XOM → USDC via AMMPermissionless
 *   4. Contract returns all USDC to user
 *
 * Security:
 * - ReentrancyGuard on all state-modifying functions
 * - Deadline parameter for all operations (MEV protection)
 * - Slippage protection via minLPOut / minUSDCOut parameters
 * - No admin functions, no proxy — fully immutable and trustless
 * - No token balances held between transactions
 * - Approvals set to exact amounts, not infinite
 */
contract LPZapPermissionless is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Basis points denominator for slippage calculations
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ══════════════════════════════════════════════════════════════════
    //                      IMMUTABLE STATE
    // ══════════════════════════════════════════════════════════════════

    /// @notice AMMPermissionless contract for swaps and liquidity operations
    IAMMPermissionless_Extended public immutable amm;

    /// @notice XOM token address
    IERC20 public immutable xom;

    /// @notice USDC token address
    IERC20 public immutable usdc;

    /// @notice LiquidityOverflowPoolPermissionless for LP staking
    ILiquidityOverflowPoolPermissionless public immutable overflowPool;

    /// @notice LP token for XOM/USDC pool (AMMPool is an ERC20)
    IERC20 public immutable lpToken;

    // ══════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user zaps USDC into an LP position
    /// @param user Address of the user
    /// @param usdcAmount Total USDC deposited
    /// @param xomSwapped XOM received from USDC swap
    /// @param lpTokens LP tokens minted and returned to user
    event ZappedIn(
        address indexed user,
        uint256 indexed usdcAmount,
        uint256 indexed xomSwapped,
        uint256 lpTokens
    );

    /// @notice Emitted when a user zaps out of LP position back to USDC
    /// @param user Address of the user
    /// @param lpAmount LP tokens burned
    /// @param usdcReturned Total USDC returned to user
    event ZappedOut(
        address indexed user,
        uint256 indexed lpAmount,
        uint256 indexed usdcReturned
    );

    // ══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Zero address provided to constructor
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Transaction deadline has passed
    error DeadlineExpired();

    /// @notice Output below minimum specified (slippage protection)
    /// @param expected Minimum expected output
    /// @param actual Actual output amount
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @notice No LP pool found for XOM/USDC pair
    error NoPoolFound();

    // ══════════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the LPZapPermissionless contract with immutable refs
     * @dev Verifies all addresses are non-zero and that the AMM pool
     *      for XOM/USDC exists. Sets up initial approvals for gas savings.
     * @param amm_ Address of the AMMPermissionless contract
     * @param xom_ Address of the XOM token (OFT on external chain)
     * @param usdc_ Address of the USDC token
     * @param overflowPool_ Address of LiquidityOverflowPoolPermissionless
     */
    constructor(
        address amm_,
        address xom_,
        address usdc_,
        address overflowPool_
    ) {
        if (amm_ == address(0)) revert ZeroAddress();
        if (xom_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0)) revert ZeroAddress();
        if (overflowPool_ == address(0)) revert ZeroAddress();

        amm = IAMMPermissionless_Extended(amm_);
        xom = IERC20(xom_);
        usdc = IERC20(usdc_);
        overflowPool = ILiquidityOverflowPoolPermissionless(overflowPool_);

        // Verify XOM/USDC pool exists
        address poolAddr = IAMMPermissionless_Extended(amm_).getPool(
            xom_, usdc_
        );
        if (poolAddr == address(0)) revert NoPoolFound();
        lpToken = IERC20(poolAddr);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      ZAP IN (USDC → LP Tokens)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Zap USDC into XOM/USDC LP tokens
     * @dev Takes USDC from user, swaps half to XOM via AMMPermissionless,
     *      adds both tokens as liquidity, and returns the LP tokens to
     *      the user. User stakes LP in LiquidityOverflowPoolPermissionless
     *      separately.
     *
     *      The "half" split is approximate — after the swap, the contract
     *      uses all available XOM and USDC for addLiquidity, which
     *      calculates the optimal ratio. Any dust is returned to the user.
     *
     * @param usdcAmount Total USDC to zap in
     * @param minXOMOut Minimum XOM from the swap step (sandwich protection)
     * @param minLPOut Minimum LP tokens expected (end-to-end slippage)
     * @param deadline Transaction deadline (block.timestamp must be <=)
     * @return lpReceived Actual LP tokens minted and transferred to user
     */
    function zapIn(
        uint256 usdcAmount,
        uint256 minXOMOut,
        uint256 minLPOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 lpReceived) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (usdcAmount == 0) revert ZeroAmount();

        // Transfer USDC from user to this contract
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Swap half USDC → XOM
        uint256 swapAmount = usdcAmount / 2;
        uint256 remainingUSDC = usdcAmount - swapAmount;

        // Approve AMM to spend USDC for the swap
        usdc.forceApprove(address(amm), swapAmount);

        IAMMPermissionless.SwapResult memory swapResult = amm.swap(
            address(usdc),
            address(xom),
            swapAmount,
            minXOMOut, // Audit fix M-01: intermediate sandwich protection
            deadline
        );

        uint256 xomReceived = swapResult.amountOut;

        // Approve AMM to spend XOM + USDC for addLiquidity
        xom.forceApprove(address(amm), xomReceived);
        usdc.forceApprove(address(amm), remainingUSDC);

        // Add liquidity — AMM calculates optimal amounts
        (,, uint256 liquidity) = amm.addLiquidity(
            address(xom),
            address(usdc),
            xomReceived,
            remainingUSDC,
            0, // amount0Min: handled by minLPOut check below
            0, // amount1Min: handled by minLPOut check below
            deadline
        );

        // End-to-end slippage check on LP tokens
        if (liquidity < minLPOut) {
            revert SlippageExceeded(minLPOut, liquidity);
        }

        // Transfer LP tokens to user (user stakes separately)
        lpToken.safeTransfer(msg.sender, liquidity);

        lpReceived = liquidity;

        // Return any dust (XOM or USDC leftover from addLiquidity)
        _returnDust();

        emit ZappedIn(
            msg.sender, usdcAmount, xomReceived, liquidity
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                   ZAP OUT (LP → USDC)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Zap out of an LP position back to USDC
     * @dev User must first unstake LP from LiquidityOverflowPoolPermissionless
     *      and approve this contract to spend the LP tokens.
     *      Contract removes liquidity to get XOM + USDC, swaps XOM → USDC,
     *      and returns all USDC to the user.
     *
     * @param lpAmount Amount of LP tokens to zap out
     * @param minXOMFromLP Minimum XOM from removeLiquidity (sandwich protection)
     * @param minUSDCOut Minimum total USDC expected (end-to-end slippage)
     * @param deadline Transaction deadline
     * @return usdcReturned Total USDC returned to user
     */
    function zapOut(
        uint256 lpAmount,
        uint256 minXOMFromLP,
        uint256 minUSDCOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 usdcReturned) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (lpAmount == 0) revert ZeroAmount();

        // Transfer LP tokens from user
        lpToken.safeTransferFrom(msg.sender, address(this), lpAmount);

        // Approve AMM to burn LP tokens
        lpToken.forceApprove(address(amm), lpAmount);

        // Remove liquidity → get XOM + USDC
        (uint256 xomAmount, uint256 usdcAmount) = amm.removeLiquidity(
            address(xom),
            address(usdc),
            lpAmount,
            minXOMFromLP, // Audit fix M-01: intermediate sandwich protection
            0, // USDC min handled by end-to-end check below
            deadline
        );

        // Swap all XOM → USDC
        uint256 usdcFromSwap = 0;
        if (xomAmount > 0) {
            xom.forceApprove(address(amm), xomAmount);

            IAMMPermissionless.SwapResult memory swapResult = amm.swap(
                address(xom),
                address(usdc),
                xomAmount,
                0, // minAmountOut: handled by minUSDCOut below
                deadline
            );
            usdcFromSwap = swapResult.amountOut;
        }

        usdcReturned = usdcAmount + usdcFromSwap;

        // End-to-end slippage check on total USDC
        if (usdcReturned < minUSDCOut) {
            revert SlippageExceeded(minUSDCOut, usdcReturned);
        }

        // Return all USDC to user
        usdc.safeTransfer(msg.sender, usdcReturned);

        // Return any XOM dust
        _returnDust();

        emit ZappedOut(msg.sender, lpAmount, usdcReturned);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Estimate the LP tokens and token split for a given USDC input
     * @dev Read-only estimation. Actual results may differ due to
     *      price movement between estimation and execution.
     * @param usdcAmount Total USDC to zap in
     * @return xomEstimate Estimated XOM received from swap
     * @return usdcForLP Estimated USDC used for liquidity
     * @return lpEstimate Estimated LP tokens minted (approximate)
     */
    function estimateZapIn(
        uint256 usdcAmount
    ) external view returns (
        uint256 xomEstimate,
        uint256 usdcForLP,
        uint256 lpEstimate
    ) {
        if (usdcAmount == 0) return (0, 0, 0);

        uint256 swapAmount = usdcAmount / 2;
        usdcForLP = usdcAmount - swapAmount;

        // Get quote for USDC → XOM swap
        (uint256 xomOut,,) = amm.getQuote(
            address(usdc), address(xom), swapAmount
        );
        xomEstimate = xomOut;

        // Estimate LP tokens based on pool reserves
        // LP tokens ≈ min(xom/reserveXOM, usdc/reserveUSDC) * totalSupply
        address poolAddr = amm.getPool(address(xom), address(usdc));
        if (poolAddr != address(0)) {
            uint256 totalSupply = IERC20(poolAddr).totalSupply();
            if (totalSupply > 0) {
                // Read reserves from pool
                // AMMPool stores reserves as (token0, token1) where
                // token0 < token1 by address sort
                (uint256 r0, uint256 r1) = _getPoolReserves(poolAddr);

                // Determine which reserve is XOM and which is USDC
                (uint256 rXOM, uint256 rUSDC) = _sortReserves(
                    poolAddr, r0, r1
                );

                if (rXOM > 0 && rUSDC > 0) {
                    uint256 lpFromXOM =
                        (xomOut * totalSupply) / rXOM;
                    uint256 lpFromUSDC =
                        (usdcForLP * totalSupply) / rUSDC;
                    lpEstimate = lpFromXOM < lpFromUSDC
                        ? lpFromXOM
                        : lpFromUSDC;
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Return any leftover XOM, USDC, and LP token dust to caller
     * @dev Called after addLiquidity/removeLiquidity operations where
     *      not all tokens may be consumed due to rounding or ratio changes.
     */
    function _returnDust() internal {
        uint256 xomBal = xom.balanceOf(address(this));
        if (xomBal > 0) {
            xom.safeTransfer(msg.sender, xomBal);
        }

        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal > 0) {
            usdc.safeTransfer(msg.sender, usdcBal);
        }

        uint256 lpBal = lpToken.balanceOf(address(this));
        if (lpBal > 0) {
            lpToken.safeTransfer(msg.sender, lpBal);
        }
    }

    /**
     * @notice Read reserves from an AMMPool contract
     * @dev AMMPool.getReserves() returns (reserve0, reserve1, timestamp)
     * @param poolAddr Address of the AMMPool
     * @return r0 Reserve of token0
     * @return r1 Reserve of token1
     */
    function _getPoolReserves(
        address poolAddr
    ) internal view returns (uint256 r0, uint256 r1) {
        // staticcall to getReserves()
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = poolAddr.staticcall(
            abi.encodeWithSignature("getReserves()")
        );
        if (success && data.length >= 64) {
            (r0, r1,) = abi.decode(data, (uint256, uint256, uint256));
        }
    }

    /**
     * @notice Determine which reserve corresponds to XOM and USDC
     * @dev AMMPool sorts tokens by address. We need to match reserves
     *      to the correct token.
     * @param poolAddr Address of the AMMPool
     * @param r0 Reserve of token0 (from getReserves)
     * @param r1 Reserve of token1 (from getReserves)
     * @return rXOM Reserve of XOM
     * @return rUSDC Reserve of USDC
     */
    function _sortReserves(
        address poolAddr,
        uint256 r0,
        uint256 r1
    ) internal view returns (uint256 rXOM, uint256 rUSDC) {
        // Read token0 from pool
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = poolAddr.staticcall(
            abi.encodeWithSignature("token0()")
        );
        if (success && data.length >= 32) {
            address token0 = abi.decode(data, (address));
            if (token0 == address(xom)) {
                rXOM = r0;
                rUSDC = r1;
            } else {
                rXOM = r1;
                rUSDC = r0;
            }
        }
    }
}
