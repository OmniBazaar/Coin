// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/* solhint-disable import-path-check */
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/* solhint-enable import-path-check */

/**
 * @title ISwapAdapter
 * @author OmniCoin Development Team
 * @notice Interface that all liquidity source adapters must implement
 * @dev Each DEX integration (Uniswap V3, SushiSwap, Curve, internal pools)
 *      must deploy an adapter contract implementing this interface and register
 *      it via {OmniSwapRouter-addLiquiditySource}.
 */
interface ISwapAdapter {
    /**
     * @notice Execute a token swap through this liquidity source
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens to swap
     * @param recipient Address to receive the output tokens
     * @return amountOut Amount of output tokens received
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    /**
     * @notice Estimate the output amount for a given swap
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens
     * @return amountOut Estimated amount of output tokens
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}

/**
 * @title OmniSwapRouter
 * @author OmniCoin Development Team
 * @notice Optimal routing for token swaps across multiple liquidity sources
 * @dev Routes swaps through internal and external DEX pools for best execution.
 *      Uses {Ownable2Step} for safe two-step ownership transfer and disables
 *      {renounceOwnership} to prevent accidental loss of admin control.
 *
 * Features:
 * - Multi-source routing (Uniswap V3, Sushiswap, Curve, internal pools)
 * - Single-hop and multi-hop swap paths
 * - Slippage protection
 * - Fee collection (0.30% default)
 * - Fee-on-transfer token support via balance-before/after pattern
 * - MEV protection via deadline
 * - Emergency pause capability
 * - Restricted token rescue (feeRecipient only, full balance)
 *
 * Architecture:
 * - Aggregates liquidity from multiple sources via {ISwapAdapter}
 * - Computes optimal routes for best price
 * - Executes swaps atomically
 * - Distributes fees to protocol treasury
 */
contract OmniSwapRouter is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Swap parameters
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum acceptable output amount
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param deadline Swap expiration timestamp
     * @param recipient Address to receive output tokens
     */
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

    /**
     * @notice Swap result
     * @param amountOut Amount of output token received
     * @param feeAmount Fee amount collected
     * @param route Route identifier
     */
    struct SwapResult {
        uint256 amountOut;
        uint256 feeAmount;
        bytes32 route;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum number of hops in a swap path
    uint256 public constant MAX_HOPS = 3;

    /// @notice Basis points divisor (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice Timelock delay for critical admin functions (M-02)
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Swap fee in basis points (30 = 0.30%)
    uint256 public swapFeeBps;

    /// @notice Fee recipient address (receives 100% on-chain)
    /// @dev H-02: The 70/20/10 fee distribution (ODDAO / staking pool / validator)
    ///      is handled off-chain by the fee collector contract or a separate
    ///      OmniFeeDistributor. On-chain, fees are sent to a single address
    ///      for simplicity. This matches the DEXSettlement.sol pattern where
    ///      the validator backend performs the three-way split.
    address public feeRecipient;

    /// @notice Mapping of source ID to adapter contract
    mapping(bytes32 => address) public liquiditySources;

    /// @notice Total swap volume
    uint256 public totalSwapVolume;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

    /// @notice Pending swap fee in basis points
    uint256 public pendingSwapFeeBps;

    /// @notice Pending fee recipient address
    address public pendingFeeRecipient;

    /// @notice Timestamp when pending fee change can be applied
    uint256 public feeTimelockExpiry;

    /// @notice Timestamp when pending recipient change can apply
    uint256 public recipientTimelockExpiry;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a swap is executed
     * @param user User who initiated the swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param amountOut Amount of output token received
     * @param feeAmount Fee amount collected
     * @param route Route identifier (hash of path + sources)
     */
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        bytes32 route
    );

    /**
     * @notice Emitted when a liquidity source is added
     * @param sourceId Source identifier
     * @param adapter Adapter contract address
     */
    event LiquiditySourceAdded(bytes32 indexed sourceId, address indexed adapter);

    /**
     * @notice Emitted when a liquidity source is removed
     * @param sourceId Source identifier
     */
    event LiquiditySourceRemoved(bytes32 indexed sourceId);

    /**
     * @notice Emitted when swap fee is updated
     * @param oldFee Old fee in basis points
     * @param newFee New fee in basis points
     */
    event SwapFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /**
     * @notice Emitted when fee recipient is updated
     * @param oldRecipient Old recipient address
     * @param newRecipient New recipient address
     */
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /**
     * @notice Emitted when accidentally-sent tokens are rescued
     * @param token Token address that was rescued
     * @param amount Amount of tokens rescued
     */
    event TokensRescued(address indexed token, uint256 indexed amount);

    /**
     * @notice Emitted when a fee change is scheduled (M-02)
     * @param newFee Proposed new fee in basis points
     * @param effectiveAt Timestamp when the change can be applied
     */
    event FeeChangeScheduled(
        uint256 indexed newFee,
        uint256 indexed effectiveAt
    );

    /**
     * @notice Emitted when a recipient change is scheduled (M-02)
     * @param newRecipient Proposed new fee recipient
     * @param effectiveAt Timestamp when the change can be applied
     */
    event RecipientChangeScheduled(
        address indexed newRecipient,
        uint256 indexed effectiveAt
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when path has too many hops
    error PathTooLong();

    /// @notice Thrown when path is empty
    error EmptyPath();

    /// @notice Thrown when swap deadline has passed
    error SwapDeadlineExpired();

    /// @notice Thrown when output amount is below minimum
    error InsufficientOutputAmount();

    /// @notice Thrown when input amount is zero
    error ZeroInputAmount();

    /// @notice Thrown when liquidity source is not registered
    error InvalidLiquiditySource();

    /// @notice Thrown when fee is too high
    error FeeTooHigh();

    /// @notice Thrown when token address is invalid
    error InvalidTokenAddress();

    /// @notice Thrown when recipient address is invalid
    error InvalidRecipientAddress();

    /// @notice Thrown when token transfer fails
    error TokenTransferFailed();

    /// @notice Thrown when swap path endpoints do not match tokenIn/tokenOut
    error PathMismatch();

    /// @notice Thrown when a registered adapter address has no deployed code
    error AdapterNotContract();

    /// @notice Thrown when the timelock period has not elapsed (M-02)
    error TimelockNotElapsed();

    /// @notice Thrown when no pending change is scheduled (M-02)
    error NoPendingChange();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Constructor to initialize the OmniSwapRouter
     * @param _feeRecipient Address to receive swap fees
     * @param _swapFeeBps Initial swap fee in basis points
     */
    constructor(address _feeRecipient, uint256 _swapFeeBps) Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert InvalidRecipientAddress();
        if (_swapFeeBps > 100) revert FeeTooHigh(); // Max 1%

        feeRecipient = _feeRecipient;
        swapFeeBps = _swapFeeBps;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute a token swap with optimal routing
     * @param params Swap parameters
     * @return result Swap result with amounts and route
     * @dev Swaps tokens through the specified path and liquidity sources.
     *      Uses balance-before/after pattern for fee-on-transfer token support.
     */
    function swap(
        SwapParams calldata params
    ) external nonReentrant whenNotPaused returns (SwapResult memory result) {
        _validateSwapParams(params);

        // Transfer input tokens (balance-before/after for fee-on-transfer)
        uint256 balanceBefore =
            IERC20(params.tokenIn).balanceOf(address(this));
        IERC20(params.tokenIn).safeTransferFrom(
            msg.sender, address(this), params.amountIn
        );
        uint256 actualReceived =
            IERC20(params.tokenIn).balanceOf(address(this)) - balanceBefore;

        // Calculate and deduct fee based on actual received amount
        uint256 feeAmount =
            (actualReceived * swapFeeBps) / BASIS_POINTS_DIVISOR;
        uint256 swapAmount = actualReceived - feeAmount;

        if (feeAmount > 0) {
            IERC20(params.tokenIn).safeTransfer(feeRecipient, feeAmount);
        }

        // Execute swap through the path
        uint256 amountOut = _executeSwapPath(
            params.path, params.sources, swapAmount
        );

        // Check slippage protection
        if (amountOut < params.minAmountOut) {
            revert InsufficientOutputAmount();
        }

        // Transfer output tokens to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        // Calculate route identifier
        bytes32 route = keccak256(
            abi.encode(params.path, params.sources)
        );

        // Update statistics
        totalSwapVolume += params.amountIn;
        totalFeesCollected += feeAmount;

        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            feeAmount,
            route
        );

        return SwapResult({
            amountOut: amountOut,
            feeAmount: feeAmount,
            route: route
        });
    }

    /**
     * @notice Add a new liquidity source adapter
     * @dev H-03 remediation: validates that the adapter address has deployed
     *      code to prevent registering EOAs or undeployed addresses.
     * @param sourceId Source identifier
     * @param adapter Adapter contract address implementing {ISwapAdapter}
     */
    function addLiquiditySource(
        bytes32 sourceId,
        address adapter
    ) external onlyOwner {
        if (adapter == address(0)) revert InvalidTokenAddress();
        if (adapter.code.length == 0) revert AdapterNotContract();

        liquiditySources[sourceId] = adapter;
        emit LiquiditySourceAdded(sourceId, adapter);
    }

    /**
     * @notice Remove a liquidity source adapter
     * @param sourceId Source identifier
     * @dev Can only be called by owner
     */
    function removeLiquiditySource(bytes32 sourceId) external onlyOwner {
        delete liquiditySources[sourceId];
        emit LiquiditySourceRemoved(sourceId);
    }

    /**
     * @notice Schedule swap fee change with timelock (M-02)
     * @param _swapFeeBps New swap fee in basis points
     * @dev Queues the change with a 48-hour delay. Call
     *      `applySwapFee()` after the delay to apply.
     */
    function scheduleSwapFee(
        uint256 _swapFeeBps
    ) external onlyOwner {
        if (_swapFeeBps > 100) revert FeeTooHigh();

        pendingSwapFeeBps = _swapFeeBps;
        // solhint-disable-next-line not-rely-on-time
        feeTimelockExpiry = block.timestamp + TIMELOCK_DELAY;

        emit FeeChangeScheduled(
            _swapFeeBps,
            feeTimelockExpiry
        );
    }

    /**
     * @notice Apply pending swap fee after timelock (M-02)
     */
    function applySwapFee() external onlyOwner {
        if (feeTimelockExpiry == 0) revert NoPendingChange();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < feeTimelockExpiry) {
            revert TimelockNotElapsed();
        }

        uint256 oldFee = swapFeeBps;
        swapFeeBps = pendingSwapFeeBps;
        feeTimelockExpiry = 0;
        emit SwapFeeUpdated(oldFee, pendingSwapFeeBps);
    }

    /**
     * @notice Schedule fee recipient change with timelock (M-02)
     * @param _feeRecipient New fee recipient address
     * @dev Queues the change with a 48-hour delay. Call
     *      `applyFeeRecipient()` after the delay to apply.
     */
    function scheduleFeeRecipient(
        address _feeRecipient
    ) external onlyOwner {
        if (_feeRecipient == address(0)) {
            revert InvalidRecipientAddress();
        }

        pendingFeeRecipient = _feeRecipient;
        recipientTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit RecipientChangeScheduled(
            _feeRecipient,
            recipientTimelockExpiry
        );
    }

    /**
     * @notice Apply pending fee recipient after timelock (M-02)
     */
    function applyFeeRecipient() external onlyOwner {
        if (recipientTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < recipientTimelockExpiry) {
            revert TimelockNotElapsed();
        }

        address oldRecipient = feeRecipient;
        feeRecipient = pendingFeeRecipient;
        recipientTimelockExpiry = 0;
        emit FeeRecipientUpdated(
            oldRecipient,
            pendingFeeRecipient
        );
    }

    /**
     * @notice Pause all swaps
     * @dev Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause swaps
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue accidentally-sent tokens to the fee recipient
     * @param token Token address to rescue
     * @dev Restricted: only callable by feeRecipient, transfers full balance.
     *      This prevents owner from draining arbitrary amounts to arbitrary
     *      addresses. Only accidentally-sent tokens should ever be present.
     */
    function rescueTokens(address token) external nonReentrant {
        if (msg.sender != feeRecipient) revert InvalidRecipientAddress();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(feeRecipient, balance);
            emit TokensRescued(token, balance);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get quote for a potential swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @return amountOut Estimated output amount (after fees)
     * @return feeAmount Fee amount
     * @dev This is a view function for price estimation
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata path,
        bytes32[] calldata sources
    ) external view returns (uint256 amountOut, uint256 feeAmount) {
        if (amountIn == 0) revert ZeroInputAmount();
        if (path.length == 0) revert EmptyPath();
        if (path.length > MAX_HOPS + 1) revert PathTooLong();
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert InvalidTokenAddress();
        }

        // Calculate fee
        feeAmount = (amountIn * swapFeeBps) / BASIS_POINTS_DIVISOR;
        uint256 swapAmount = amountIn - feeAmount;

        // Estimate output through path
        amountOut = _estimateSwapPath(path, sources, swapAmount);
    }

    /**
     * @notice Get swap statistics
     * @return volume Total swap volume
     * @return fees Total fees collected
     */
    function getSwapStats() external view returns (uint256 volume, uint256 fees) {
        return (totalSwapVolume, totalFeesCollected);
    }

    /**
     * @notice Check if liquidity source is registered
     * @param sourceId Source identifier
     * @return isRegistered True if source is registered
     */
    function isLiquiditySourceRegistered(
        bytes32 sourceId
    ) external view returns (bool isRegistered) {
        return liquiditySources[sourceId] != address(0);
    }

    // ========================================================================
    // PUBLIC FUNCTIONS
    // ========================================================================

    /**
     * @notice Disabled to prevent accidental loss of contract admin control
     * @dev Always reverts. Ownership can only be transferred via two-step
     *      {transferOwnership} + {acceptOwnership} flow.
     */
    function renounceOwnership() public pure override {
        revert InvalidRecipientAddress();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Execute swap through a multi-hop path via registered adapters
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param amountIn Input amount for the first hop
     * @return amountOut Final output amount after all hops
     * @dev Executes swaps sequentially through the path. Each hop calls the
     *      registered {ISwapAdapter} for the corresponding liquidity source.
     *      Tokens must be approved to adapters or held by this contract.
     */
    function _executeSwapPath(
        address[] calldata path,
        bytes32[] calldata sources,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        amountOut = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            address adapter = liquiditySources[sources[i]];
            if (adapter == address(0)) revert InvalidLiquiditySource();

            // Approve the adapter to spend input tokens for this hop
            IERC20(path[i]).forceApprove(adapter, amountOut);

            // Execute swap via the adapter
            amountOut = ISwapAdapter(adapter).executeSwap(
                path[i],
                path[i + 1],
                amountOut,
                address(this)
            );
        }
    }

    /**
     * @notice Validate all swap parameters before execution
     * @param params Swap parameters to validate
     * @dev Delegates to {_validateSwapAddresses} and {_validateSwapPath}
     *      to keep cyclomatic complexity within limits.
     */
    function _validateSwapParams(
        SwapParams calldata params
    ) internal view {
        _validateSwapAddresses(params);
        _validateSwapPath(params);
    }

    /**
     * @notice Validate swap addresses, amounts, and deadline
     * @param params Swap parameters to validate
     * @dev Checks zero amounts, zero addresses, same-token swaps,
     *      and MEV-protection deadline.
     */
    function _validateSwapAddresses(
        SwapParams calldata params
    ) internal view {
        if (params.amountIn == 0) revert ZeroInputAmount();
        if (
            params.tokenIn == address(0) ||
            params.tokenOut == address(0)
        ) {
            revert InvalidTokenAddress();
        }
        if (params.tokenIn == params.tokenOut) {
            revert InvalidTokenAddress();
        }
        if (params.recipient == address(0)) {
            revert InvalidRecipientAddress();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > params.deadline) {
            revert SwapDeadlineExpired();
        }
    }

    /**
     * @notice Estimate output amount for a swap path via registered adapters
     * @param path Token addresses in swap path
     * @param sources Liquidity source identifiers for each hop
     * @param amountIn Input amount for the first hop
     * @return amountOut Estimated output amount after all hops
     * @dev View function that calls each adapter's {getAmountOut} to produce
     *      a cumulative price estimate across the full multi-hop path.
     */
    function _estimateSwapPath(
        address[] calldata path,
        bytes32[] calldata sources,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        amountOut = amountIn;

        for (uint256 i = 0; i < path.length - 1; ++i) {
            address adapter = liquiditySources[sources[i]];
            if (adapter == address(0)) revert InvalidLiquiditySource();

            amountOut = ISwapAdapter(adapter).getAmountOut(
                path[i],
                path[i + 1],
                amountOut
            );
        }
    }

    /**
     * @notice Validate swap path structure and consistency
     * @param params Swap parameters to validate
     * @dev Checks path length, sources count, and path endpoint consistency
     *      with tokenIn/tokenOut.
     */
    function _validateSwapPath(
        SwapParams calldata params
    ) internal pure {
        if (params.path.length == 0) revert EmptyPath();
        if (params.path.length > MAX_HOPS + 1) revert PathTooLong();
        if (params.sources.length != params.path.length - 1) {
            revert InvalidLiquiditySource();
        }
        if (
            params.path[0] != params.tokenIn ||
            params.path[params.path.length - 1] != params.tokenOut
        ) {
            revert PathMismatch();
        }
    }
}
