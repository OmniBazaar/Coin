// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "./interfaces/IFeeSwapRouter.sol";

// ════════════════════════════════════════════════════════════════════
//  Forward-declare the OmniSwapRouter interface we actually call
// ════════════════════════════════════════════════════════════════════

/**
 * @title IOmniSwapRouter
 * @author OmniBazaar Team
 * @notice Subset of OmniSwapRouter used by this adapter
 */
interface IOmniSwapRouter {
    /// @notice Swap parameters (mirrors OmniSwapRouter.SwapParams)
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

    /// @notice Swap result
    struct SwapResult {
        uint256 amountOut;
        uint256 feeAmount;
        bytes32 route;
    }

    /**
     * @notice Execute a token swap
     * @param params Swap parameters
     * @return result Swap result
     */
    function swap(
        SwapParams calldata params
    ) external returns (SwapResult memory result);
}

// ════════════════════════════════════════════════════════════════════
//                        FEE SWAP ADAPTER
// ════════════════════════════════════════════════════════════════════

/**
 * @title FeeSwapAdapter
 * @author OmniBazaar Team
 * @notice Bridges the minimal {IFeeSwapRouter} interface to the full
 *         {OmniSwapRouter.swap(SwapParams)} call.
 * @dev Non-upgradeable. Deployed once per network and pointed at
 *      the live OmniSwapRouter. Uses {Ownable2Step} for safe admin
 *      transfer and disables {renounceOwnership}.
 *
 * Flow:
 *   1. UnifiedFeeVault approves this adapter for `tokenIn`
 *   2. Vault calls swapExactInput(...)
 *   3. Adapter pulls tokenIn via safeTransferFrom
 *   4. Adapter approves OmniSwapRouter via forceApprove
 *   5. Adapter calls router.swap(...) with recipient = caller
 *   6. Router sends tokenOut to the vault (caller)
 *   7. Adapter resets approval to 0 (L-01 audit fix)
 *   8. Adapter verifies actual balance change (H-01 audit fix)
 *
 * Security (Audit Round 4):
 * - H-01: Balance-before/after verification on swap output
 * - M-01: Caller-provided deadline for MEV protection
 * - M-02: Router changes require 24h timelock (propose/apply)
 * - M-03: Token rescue function for stuck tokens
 * - L-01: Residual approval reset after swap
 * - L-02: Zero-value default source rejected
 * - L-03: Minimum swap amount enforced
 * - I-01: OwnershipRenunciationDisabled error for clarity
 * - I-02: ReentrancyGuard on swapExactInput
 */
contract FeeSwapAdapter is
    IFeeSwapRouter,
    Ownable2Step,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ════════════════════════════════════════════════════════════════

    /// @notice Minimum swap amount (0.001 tokens with 18 decimals)
    /// @dev L-03 audit fix: prevents dust swaps that waste gas
    uint256 public constant MIN_SWAP_AMOUNT = 1e15;

    /// @notice Timelock delay for router updates (24 hours)
    /// @dev M-02 audit fix: prevents instant router swaps
    uint256 public constant ROUTER_DELAY = 24 hours;

    // ════════════════════════════════════════════════════════════════
    //                        STATE VARIABLES
    // ════════════════════════════════════════════════════════════════

    /// @notice OmniSwapRouter contract used for actual swaps
    IOmniSwapRouter public router;

    /// @notice Default liquidity source identifier for single-hop
    bytes32 public defaultSource;

    /// @notice Pending router address awaiting timelock
    /// @dev M-02 audit fix: set via proposeRouter()
    address public pendingRouter;

    /// @notice Timestamp when pending router can be applied
    /// @dev M-02 audit fix: must be > 0 and <= block.timestamp
    uint256 public routerChangeTime;

    // ════════════════════════════════════════════════════════════════
    //                            EVENTS
    // ════════════════════════════════════════════════════════════════

    /// @notice Emitted when the router address is updated
    /// @param oldRouter Previous router address
    /// @param newRouter New router address
    event RouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted when a router change is proposed
    /// @param proposedRouter Proposed new router address
    /// @param effectiveTime When the change can be applied
    event RouterProposed(
        address indexed proposedRouter,
        uint256 indexed effectiveTime
    );

    /// @notice Emitted when the default liquidity source is updated
    /// @param oldSource Previous source identifier
    /// @param newSource New source identifier
    event DefaultSourceUpdated(
        bytes32 indexed oldSource,
        bytes32 indexed newSource
    );

    /// @notice Emitted when stuck tokens are rescued
    /// @param token Address of the rescued token
    /// @param to Recipient address
    /// @param amount Amount rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    // ════════════════════════════════════════════════════════════════
    //                         CUSTOM ERRORS
    // ════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when the swap output is below the minimum
    /// @param received Actual output amount
    /// @param minimum Required minimum amount
    error InsufficientOutput(uint256 received, uint256 minimum);

    /// @notice Thrown when renounceOwnership is called
    /// @dev I-01 audit fix: descriptive error name
    error OwnershipRenunciationDisabled();

    /// @notice Thrown when the swap deadline has passed
    /// @dev M-01 audit fix: MEV protection
    error DeadlineExpired();

    /// @notice Thrown when the timelock has not yet elapsed
    /// @dev M-02 audit fix: router timelock
    error TimelockNotExpired();

    /// @notice Thrown when no pending router change exists
    /// @dev M-02 audit fix
    error NoPendingChange();

    /// @notice Thrown when default source is set to zero
    /// @dev L-02 audit fix
    error InvalidSource();

    /// @notice Thrown when swap amount is below minimum
    /// @dev L-03 audit fix
    error AmountTooSmall();

    // ════════════════════════════════════════════════════════════════
    //                         CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the FeeSwapAdapter
     * @param _router OmniSwapRouter contract address
     * @param _defaultSource Default liquidity source ID for swaps
     * @param _owner Initial owner (admin)
     */
    constructor(
        address _router,
        bytes32 _defaultSource,
        address _owner
    ) Ownable(_owner) {
        if (_router == address(0)) revert ZeroAddress();

        router = IOmniSwapRouter(_router);
        defaultSource = _defaultSource;
    }

    // ════════════════════════════════════════════════════════════════
    //                      EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IFeeSwapRouter
     * @dev Pulls tokenIn from msg.sender, approves the router,
     *      executes a single-hop swap via OmniSwapRouter, and
     *      sends tokenOut directly to `recipient`.
     *      H-01: Verifies actual balance change, not router return.
     *      M-01: Enforces caller-provided deadline.
     *      L-01: Resets residual approval after swap.
     *      L-03: Rejects dust amounts below MIN_SWAP_AMOUNT.
     *      I-02: Protected by nonReentrant modifier.
     */
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (recipient == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        // L-03: Minimum swap amount
        if (amountIn < MIN_SWAP_AMOUNT) revert AmountTooSmall();
        // M-01: Deadline check
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();

        // H-01: Record balance before swap
        uint256 balanceBefore =
            IERC20(tokenOut).balanceOf(recipient);

        // 1. Pull input tokens from caller (vault)
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // 2. Approve router to spend our tokens
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // 3. Build single-hop swap path
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        bytes32[] memory sources = new bytes32[](1);
        sources[0] = defaultSource;

        // 4. Execute swap — recipient receives tokenOut directly
        router.swap(
            IOmniSwapRouter.SwapParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: amountOutMin,
                path: path,
                sources: sources,
                deadline: deadline,
                recipient: recipient
            })
        );

        // L-01: Reset residual approval to zero
        IERC20(tokenIn).forceApprove(address(router), 0);

        // H-01: Verify actual balance change
        uint256 balanceAfter =
            IERC20(tokenOut).balanceOf(recipient);
        amountOut = balanceAfter - balanceBefore;

        // 5. Enforce slippage protection on actual output
        if (amountOut < amountOutMin) {
            revert InsufficientOutput(
                amountOut, amountOutMin
            );
        }
    }

    // ════════════════════════════════════════════════════════════════
    //                       ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════

    /**
     * @notice Propose a new OmniSwapRouter address (24h timelock)
     * @dev M-02 audit fix: Router changes cannot be applied
     *      immediately. Call applyRouter() after ROUTER_DELAY
     *      has elapsed.
     * @param _router New router contract address
     */
    function proposeRouter(
        address _router
    ) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();

        // solhint-disable-next-line not-rely-on-time
        uint256 effective = block.timestamp + ROUTER_DELAY;
        pendingRouter = _router;
        routerChangeTime = effective;

        emit RouterProposed(_router, effective);
    }

    /**
     * @notice Apply the pending router change after timelock
     * @dev M-02 audit fix: Reverts if timelock has not elapsed
     *      or no pending change exists.
     */
    function applyRouter() external onlyOwner {
        if (pendingRouter == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < routerChangeTime) {
            revert TimelockNotExpired();
        }

        address oldRouter = address(router);
        router = IOmniSwapRouter(pendingRouter);

        // Clear pending state
        delete pendingRouter;
        delete routerChangeTime;

        emit RouterUpdated(oldRouter, address(router));
    }

    /**
     * @notice Update the default liquidity source identifier
     * @dev L-02 audit fix: Rejects zero-value source to prevent
     *      silent misconfiguration.
     * @param _source New default source ID (must be non-zero)
     */
    function setDefaultSource(
        bytes32 _source
    ) external onlyOwner {
        if (_source == bytes32(0)) revert InvalidSource();

        bytes32 oldSource = defaultSource;
        defaultSource = _source;

        emit DefaultSourceUpdated(oldSource, _source);
    }

    /**
     * @notice Rescue accidentally sent tokens from the adapter
     * @dev M-03 audit fix: Allows owner to recover tokens that
     *      were accidentally sent to this contract. The adapter
     *      should not hold any tokens between transactions.
     * @param token Token address to rescue
     * @param to Recipient address
     * @param amount Amount to rescue
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);

        emit TokensRescued(token, to, amount);
    }

    /**
     * @notice Disabled to prevent accidental loss of admin control
     * @dev Always reverts. Use transferOwnership + acceptOwnership.
     *      I-01 audit fix: Uses descriptive error name.
     */
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }
}
