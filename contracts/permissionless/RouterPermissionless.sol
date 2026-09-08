// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IAMMPermissionless} from "./interfaces/IAMMPermissionless.sol";
import {IAMMPool} from "./interfaces/IAMMPool.sol";

/**
 * @title RouterPermissionless
 * @author OmniCoin Development Team
 * @notice User-facing router for permissionless AMM token swaps
 * @dev Permissionless variant of RWARouter used on external chains
 *      (Ethereum, Arbitrum, Base, Polygon) where OmniBazaar compliance
 *      gating does not apply. Identical swap math, slippage guards,
 *      deadline enforcement, multi-hop routing, and balance-delta
 *      accounting as RWARouter — the only differences are:
 *        1. Targets AMMPermissionless/AMMPool (no compliance oracle)
 *        2. Does not pass `onBehalfOf` to AMM.swap/addLiquidity/
 *           removeLiquidity (no C-01/C-02 compliance flag needed)
 *        3. No compliance checks — wallet-level OFAC screening is
 *           still enforced upstream
 *
 * Key Features:
 * - Single-hop and multi-hop swaps via AMMPermissionless
 * - Slippage protection with balance-delta pattern on all hops
 * - Deadline enforcement (rejects zero and past deadlines)
 * - Liquidity management via AMMPermissionless delegation
 * - Quote functions matching AMMPermissionless fee model
 *
 * Multi-Hop Routing:
 *   For paths longer than 2 tokens (e.g., A -> B -> C), each hop
 *   is executed sequentially through AMM.swap(). The router holds
 *   intermediate tokens between hops. Balance deltas are measured
 *   on ALL hops (including the final hop) to handle fee-on-transfer
 *   tokens correctly and ensure actual received amounts are used
 *   (audit fix H-01/H-02). Intermediate hops verify the router's
 *   balance rather than performing wasteful self-transfers. The
 *   final output is verified against amountOutMin.
 *
 * Security Features:
 * - Reentrancy protection
 * - Deadline validation (zero and past deadlines rejected)
 * - Minimum output validation
 * - Path validation
 * - Balance-delta measurement on all swap hops
 * - All swaps routed through AMMPermissionless (fees, pause)
 */
contract RouterPermissionless is ReentrancyGuard, ERC2771Context {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Protocol fee in basis points (must match AMMPermissionless)
    uint256 private constant PROTOCOL_FEE_BPS = 30;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    // ========================================================================
    // IMMUTABLE STATE
    // ========================================================================

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Reference to the core permissionless AMM contract
    IAMMPermissionless public immutable AMM;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Fixed protocol treasury that receives swept dust (F-02 fix).
    /// @dev Hardcoded at deployment so sweepTokens() cannot be abused to
    ///      redirect in-flight balances to an arbitrary recipient. MEV
    ///      bots cannot front-run sweeps since the destination is fixed.
    address public immutable PROTOCOL_TREASURY;

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
    error InsufficientOutputAmount(
        uint256 amountOut,
        uint256 amountOutMin
    );

    /// @notice Thrown when input amount exceeds maximum
    /// @param amountIn Required input amount
    /// @param amountInMax Maximum allowed input
    error ExcessiveInputAmount(uint256 amountIn, uint256 amountInMax);

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

    /// @notice Thrown when minimum output amount is zero (no slippage protection)
    error ZeroMinimumOutput();

    /// @notice Thrown when pool does not exist
    /// @param tokenA First token address
    /// @param tokenB Second token address
    error PoolDoesNotExist(address tokenA, address tokenB);

    /* solhint-disable ordering */
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when multi-hop swap is executed
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

    /// @notice Emitted when liquidity is added via router
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

    /// @notice Emitted when liquidity is removed via router
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
    /* solhint-enable ordering */

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Ensures deadline has not passed and is not zero
     * @dev Rejects deadline == 0 to prevent accidental submissions
     *      with no deadline protection. Also rejects any deadline
     *      that is already in the past.
     * @param deadline Deadline timestamp (must be > block.timestamp)
     */
    modifier ensure(uint256 deadline) {
        if (deadline == 0) {
            revert DeadlineExpired(0, block.timestamp); // solhint-disable-line not-rely-on-time
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) {
            // solhint-disable-next-line not-rely-on-time
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploy the router
     * @param _amm Core permissionless AMM contract address
     * @param _protocolTreasury Fixed address that receives swept dust
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address
     */
    constructor(
        address _amm,
        address _protocolTreasury,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        if (_amm == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        AMM = IAMMPermissionless(_amm);
        PROTOCOL_TREASURY = _protocolTreasury;
    }

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Swap exact input tokens for output tokens
     * @dev Routes each hop through AMM.swap() to enforce
     *      fee collection and pause controls at every step. Uses
     *      the balance-delta pattern on all hops to correctly handle
     *      fee-on-transfer tokens. Intermediate hops skip the
     *      self-transfer since the router already holds the tokens
     *      from the previous AMM.swap() output. The final output
     *      is verified against amountOutMin after all hops complete.
     *
     *      Audit M-02: Intermediate hops pass `amountOutMin = 0` to
     *      AMM.swap(). Slippage protection is enforced only on the
     *      final output via `amountOutMin`. This is standard Uniswap
     *      V2 router behavior: per-hop minimums would over-constrain
     *      multi-hop swaps and cause unnecessary reverts when the
     *      total path output is acceptable. Users should set tight
     *      `amountOutMin` values to limit total MEV extraction.
     * @param amountIn Exact input amount
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param path Array of token addresses (swap route, min length 2)
     * @param to Recipient address (must not be zero)
     * @param deadline Transaction deadline (must be > 0 and not expired)
     * @return amounts Array of amounts for each hop
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (
        uint256[] memory amounts
    ) {
        if (path.length < 2) revert InvalidPath();
        if (amountIn == 0) revert ZeroAmount();
        if (amountOutMin == 0) revert ZeroMinimumOutput();
        if (to == address(0)) revert ZeroAddress();

        address caller = _msgSender();

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        // Execute each hop through AMMPermissionless. Uses balance-delta
        // on all hops for FOT token correctness.
        for (uint256 i = 0; i < path.length - 1; ++i) {
            address recipient = i < path.length - 2
                ? address(this) : to;

            if (i == 0) {
                // First hop: transfer from user, measure via delta
                uint256 balBefore = IERC20(path[i]).balanceOf(
                    address(this)
                );
                IERC20(path[i]).safeTransferFrom(
                    caller, address(this), amounts[i]
                );
                uint256 actualReceived = IERC20(path[i]).balanceOf(
                    address(this)
                ) - balBefore;
                if (actualReceived < amounts[i]) {
                    amounts[i] = actualReceived;
                }
            }

            IERC20(path[i]).forceApprove(address(AMM), amounts[i]);

            // Audit fix H-02: Measure balance-delta on ALL hops
            // including the last one. The AMM sends output tokens to
            // msg.sender (this router), so we always measure the
            // router's balance change regardless of hop position.
            // This correctly handles fee-on-transfer tokens and
            // prevents using result.amountOut (the calculated, not
            // actual, amount) for the final transfer.
            uint256 outputBalBefore = IERC20(path[i + 1]).balanceOf(
                address(this)
            );

            AMM.swap(
                path[i],
                path[i + 1],
                amounts[i],
                0, // Min checked at end for full path
                deadline
            );

            uint256 actualOutput = IERC20(path[i + 1]).balanceOf(
                address(this)
            ) - outputBalBefore;
            amounts[i + 1] = actualOutput;

            // Transfer to final recipient on last hop
            if (recipient != address(this)) {
                IERC20(path[i + 1]).safeTransfer(
                    recipient, actualOutput
                );
            }
        }

        // Verify minimum output
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount(
                amounts[amounts.length - 1], amountOutMin
            );
        }

        emit SwapExecuted(
            caller,
            path,
            amountIn,
            amounts[amounts.length - 1]
        );
    }
    /* solhint-enable code-complexity */

    /* solhint-disable code-complexity */
    /**
     * @notice Swap tokens for exact output amount
     * @dev Routes through AMM.swap(). For multi-hop, calculates required
     *      inputs then executes forward through AMM at each hop.
     *      Complexity justification: the output verification guard at
     *      the end of this function is a security-critical check added
     *      per audit recommendation M-02.
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
    ) external nonReentrant ensure(deadline) returns (
        uint256[] memory amounts
    ) {
        if (path.length < 2) revert InvalidPath();
        if (amountOut == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        address caller = _msgSender();

        // Calculate required input amounts (reverse)
        amounts = getAmountsIn(amountOut, path);

        // Verify maximum input
        if (amounts[0] > amountInMax) {
            revert ExcessiveInputAmount(amounts[0], amountInMax);
        }

        // Execute forward through AMM (same as swapExact).
        // Audit fix H-01: For intermediate hops (i > 0), verify the
        // router holds sufficient tokens via balance check instead of
        // doing a wasteful self-transfer. This prevents using residual
        // tokens from unrelated operations and provides accurate
        // accounting.
        for (uint256 i = 0; i < path.length - 1; ++i) {
            address recipient = i < path.length - 2
                ? address(this)
                : to;

            if (i == 0) {
                // First hop: transfer from user to router
                IERC20(path[i]).safeTransferFrom(
                    caller, address(this), amounts[i]
                );
            } else {
                // Audit fix H-01: Verify the router actually holds
                // enough tokens from the previous hop's output.
                // Do NOT do a self-transfer; instead check balance.
                uint256 routerBal = IERC20(path[i]).balanceOf(
                    address(this)
                );
                if (routerBal < amounts[i]) {
                    revert InsufficientOutputAmount(
                        routerBal, amounts[i]
                    );
                }
            }

            IERC20(path[i]).forceApprove(address(AMM), amounts[i]);

            // Audit fix H-02: Measure balance-delta on ALL hops
            // (including the last) to use actual received amounts
            // rather than the calculated result.amountOut.
            uint256 outputBalBefore = IERC20(path[i + 1]).balanceOf(
                address(this)
            );

            AMM.swap(
                path[i],
                path[i + 1],
                amounts[i],
                0,
                deadline
            );

            uint256 actualOutput = IERC20(path[i + 1]).balanceOf(
                address(this)
            ) - outputBalBefore;
            amounts[i + 1] = actualOutput;

            if (recipient != address(this)) {
                IERC20(path[i + 1]).safeTransfer(
                    recipient, actualOutput
                );
            }
        }

        // Verify final output meets the user's desired amount.
        // The reverse calculation in getAmountsIn() uses ceiling
        // rounding (+1) so users typically overpay slightly, but
        // multi-hop rounding can compound and produce less output
        // than expected. This check ensures the user is protected.
        if (amounts[amounts.length - 1] < amountOut) {
            revert InsufficientOutputAmount(
                amounts[amounts.length - 1], amountOut
            );
        }

        emit SwapExecuted(caller, path, amounts[0], amountOut);
    }
    /* solhint-enable code-complexity */

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /**
     * @notice Add liquidity to a pool via AMMPermissionless
     * @dev Delegates to AMM.addLiquidity() for pause checks.
     *      Reverts with PoolDoesNotExist if no pool exists for the pair
     *      (unlike AMM which auto-creates pools).
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
        if (tokenA == address(0) || tokenB == address(0)) {
            revert ZeroAddress();
        }
        if (to == address(0)) revert ZeroAddress();

        address caller = _msgSender();

        // Verify pool exists (router does not auto-create pools)
        address pool = AMM.getPool(tokenA, tokenB);
        if (pool == address(0)) {
            revert PoolDoesNotExist(tokenA, tokenB);
        }

        // Transfer tokens from user to this contract, then approve AMM
        IERC20(tokenA).safeTransferFrom(
            caller, address(this), amountADesired
        );
        IERC20(tokenB).safeTransferFrom(
            caller, address(this), amountBDesired
        );
        IERC20(tokenA).forceApprove(address(AMM), amountADesired);
        IERC20(tokenB).forceApprove(address(AMM), amountBDesired);

        // Delegate to AMM
        (amountA, amountB, liquidity) = AMM.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            deadline
        );

        // Transfer LP tokens to recipient (AMM mints to msg.sender
        // which is this contract)
        if (to != address(this)) {
            IERC20(pool).safeTransfer(to, liquidity);
        }

        // Refund unused tokens
        uint256 remainingA = amountADesired - amountA;
        uint256 remainingB = amountBDesired - amountB;
        if (remainingA > 0) {
            IERC20(tokenA).safeTransfer(caller, remainingA);
        }
        if (remainingB > 0) {
            IERC20(tokenB).safeTransfer(caller, remainingB);
        }

        emit LiquidityAdded(
            caller, tokenA, tokenB,
            amountA, amountB, liquidity
        );
    }

    /* solhint-disable code-complexity */
    /**
     * @notice Remove liquidity from a pool via AMMPermissionless
     * @dev Delegates to AMM.removeLiquidity().
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
        if (tokenA == address(0) || tokenB == address(0)) {
            revert ZeroAddress();
        }
        if (to == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert ZeroAmount();

        address caller = _msgSender();

        address pool = AMM.getPool(tokenA, tokenB);
        if (pool == address(0)) {
            revert PoolDoesNotExist(tokenA, tokenB);
        }

        // Transfer LP tokens from user and approve AMM
        IERC20(pool).safeTransferFrom(
            caller, address(this), liquidity
        );
        IERC20(pool).forceApprove(address(AMM), liquidity);

        // Delegate to AMM
        (amountA, amountB) = AMM.removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            deadline
        );

        // Transfer underlying to final recipient (AMM sends to
        // msg.sender which is this contract)
        if (to != address(this)) {
            if (amountA > 0) {
                IERC20(tokenA).safeTransfer(to, amountA);
            }
            if (amountB > 0) {
                IERC20(tokenB).safeTransfer(to, amountB);
            }
        }

        emit LiquidityRemoved(
            caller, tokenA, tokenB,
            amountA, amountB, liquidity
        );
    }
    /* solhint-enable code-complexity */

    // ========================================================================
    // QUOTE FUNCTIONS
    // ========================================================================

    /**
     * @notice Get output amounts for a given input along path
     * @dev Uses the same fee model as AMMPermissionless (upfront fee
     *      deduction) to produce accurate quotes matching actual swap
     *      results.
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
            // Use AMM.getQuote() for accurate fee-adjusted output
            (uint256 amountOut,,) = AMM.getQuote(
                path[i], path[i + 1], amounts[i]
            );
            amounts[i + 1] = amountOut;
        }
    }

    /**
     * @notice Get input amounts required for a given output along path
     * @dev Calculates reverse path using AMMPermissionless fee model.
     *      Output may differ slightly from forward execution due to
     *      rounding in the constant-product formula.
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
            address pool = AMM.getPool(path[i - 1], path[i]);
            if (pool == address(0)) {
                revert PoolDoesNotExist(path[i - 1], path[i]);
            }

            (uint256 reserveIn, uint256 reserveOut) = _getReserves(
                pool, path[i - 1], path[i]
            );

            // Reverse the AMMPermissionless formula:
            // amountOut = reserveOut * amountAfterFee /
            //             (reserveIn + amountAfterFee)
            // Solve for amountIn:
            // amountAfterFee = reserveIn * amountOut /
            //                  (reserveOut - amountOut)
            // amountIn = amountAfterFee * BPS / (BPS - FEE)
            // solhint-disable-next-line gas-strict-inequalities
            if (amounts[i] >= reserveOut) {
                revert InsufficientLiquidity(reserveIn, reserveOut);
            }

            uint256 amountAfterFee = (reserveIn * amounts[i])
                / (reserveOut - amounts[i]) + 1;
            amounts[i - 1] = (amountAfterFee * BPS_DENOMINATOR)
                / (BPS_DENOMINATOR - PROTOCOL_FEE_BPS) + 1;
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
            return (amountADesired, amountBDesired);
        }

        (uint256 reserveA, uint256 reserveB) = _getReserves(
            pool, tokenA, tokenB
        );

        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint256 amountBOptimal = _quote(
            amountADesired, reserveA, reserveB
        );

        // solhint-disable-next-line gas-strict-inequalities
        if (amountBOptimal <= amountBDesired) {
            return (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = _quote(
                amountBDesired, reserveB, reserveA
            );
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
    // DUST RECOVERY
    // ========================================================================

    /// @notice Emitted when residual tokens are swept to the treasury.
    /// @param token Token address swept.
    /// @param to Fixed protocol treasury recipient.
    /// @param amount Amount swept.
    event TokensSwept(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    /**
     * @notice Sweep residual token dust from the router to the protocol
     *         treasury (audit fix M-01 / F-02).
     * @dev Routers can accumulate small dust amounts from rounding in
     *      swap and liquidity operations. This function sends dust to
     *      the immutable PROTOCOL_TREASURY set at deployment. The
     *      recipient is NOT caller-chosen — this prevents MEV bots from
     *      front-running swaps and siphoning any in-flight balances.
     *      Permissionless caller is safe because destination is fixed.
     * @param token ERC-20 token address to sweep.
     */
    function sweepTokens(
        address token
    ) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(PROTOCOL_TREASURY, balance);

        emit TokensSwept(token, PROTOCOL_TREASURY, balance);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

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
        (uint256 reserve0, uint256 reserve1,) =
            IAMMPool(pool).getReserves();
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
     * @notice Quote proportional amount based on reserves
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
        if (reserveA == 0 || reserveB == 0) {
            revert InsufficientLiquidity(reserveA, reserveB);
        }
        amountB = (amountA * reserveB) / reserveA;
    }
}
