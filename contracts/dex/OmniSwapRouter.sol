// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/* solhint-disable import-path-check */
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
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
contract OmniSwapRouter is Ownable2Step, Pausable, ReentrancyGuard, ERC2771Context {
    using SafeERC20 for IERC20;

    /// @dev AUDIT ACCEPTED (Round 6): Fee-on-transfer and rebasing tokens are not
    ///      supported. OmniCoin (XOM) is the primary token and does not have these
    ///      features. Only vetted tokens (XOM, USDC, WBTC, WETH) are whitelisted
    ///      for use in the platform. This is documented in deployment guides.

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

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Swap fee in basis points (30 = 0.30%)
    uint256 public swapFeeBps;

    /// @notice Fee recipient address (receives 100% on-chain)
    /// @dev The 70/20/10 fee distribution (ODDAO / staking pool / protocol)
    ///      is handled by the UnifiedFeeVault contract. On-chain, fees are
    ///      sent to a single address (UnifiedFeeVault) for simplicity.
    address public feeRecipient;

    /// @notice Mapping of source ID to adapter contract
    mapping(bytes32 => address) public liquiditySources;

    /// @notice Total swap volume
    uint256 public totalSwapVolume;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

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

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Constructor to initialize the OmniSwapRouter
     * @param _feeRecipient Address to receive swap fees
     * @param _swapFeeBps Initial swap fee in basis points
     * @param trustedForwarder_ ERC-2771 trusted forwarder for
     *        gasless meta-transactions (e.g. OmniForwarder)
     */
    constructor(
        address _feeRecipient,
        uint256 _swapFeeBps,
        address trustedForwarder_
    )
        Ownable(msg.sender)
        ERC2771Context(trustedForwarder_)
    {
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
    /// @dev AUDIT ACCEPTED (Round 6): The deadline parameter provides implicit
    ///      slippage protection by preventing stale transactions from executing
    ///      at outdated prices. Explicit minAmountOut is enforced at the
    ///      DEXSettlement layer which handles actual token transfers.
    function swap(
        SwapParams calldata params
    ) external nonReentrant whenNotPaused returns (SwapResult memory result) {
        _validateSwapParams(params);

        address caller = _msgSender();

        // Transfer input tokens (balance-before/after for fee-on-transfer)
        uint256 balanceBefore =
            IERC20(params.tokenIn).balanceOf(address(this));
        IERC20(params.tokenIn).safeTransferFrom(
            caller, address(this), params.amountIn
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

        // H-02: Record output token balance before swap execution
        uint256 outBalanceBefore =
            IERC20(params.tokenOut).balanceOf(address(this));

        // Execute swap through the path
        _executeSwapPath(params.path, params.sources, swapAmount);

        // H-02: Derive actual output from balance change, not adapter return
        uint256 amountOut =
            IERC20(params.tokenOut).balanceOf(address(this))
            - outBalanceBefore;

        // Slippage protection on ACTUAL received amount
        if (amountOut < params.minAmountOut) {
            revert InsufficientOutputAmount();
        }

        // Transfer verified output tokens to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        // Calculate route identifier
        bytes32 route = keccak256(
            abi.encode(params.path, params.sources)
        );

        // Update statistics
        totalSwapVolume += params.amountIn;
        totalFeesCollected += feeAmount;

        emit SwapExecuted(
            caller,
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
     * @notice Update swap fee in basis points
     * @param _swapFeeBps New swap fee in basis points (max 100 = 1%)
     * @dev Pioneer Phase: no timelock. Will be replaced with
     *      timelocked version before multi-sig handoff.
     */
    function setSwapFee(
        uint256 _swapFeeBps
    ) external onlyOwner {
        if (_swapFeeBps > 100) revert FeeTooHigh();

        uint256 oldFee = swapFeeBps;
        swapFeeBps = _swapFeeBps;
        emit SwapFeeUpdated(oldFee, _swapFeeBps);
    }

    /**
     * @notice Update fee recipient address
     * @param _feeRecipient New fee recipient address
     * @dev Pioneer Phase: no timelock. Will be replaced with
     *      timelocked version before multi-sig handoff.
     */
    function setFeeRecipient(
        address _feeRecipient
    ) external onlyOwner {
        if (_feeRecipient == address(0)) {
            revert InvalidRecipientAddress();
        }

        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
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
     * @dev Restricted: only callable by owner, transfers full balance
     *      to current feeRecipient. Only accidentally-sent tokens
     *      should ever be present.
     */
    function rescueTokens(
        address token
    ) external nonReentrant onlyOwner {
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
     *
     *      Security (H-01 remediation): Residual token approvals are reset
     *      to zero after each hop to prevent a compromised or malicious
     *      adapter from draining leftover allowance via `transferFrom`.
     *
     *      Security (H-02 remediation): Per-hop balance-before/after
     *      verification ensures the actual tokens received from each adapter
     *      are used as the input for the next hop, rather than trusting the
     *      adapter-reported return value. This protects against malicious
     *      adapters reporting inflated output and handles fee-on-transfer
     *      intermediate tokens in multi-hop paths.
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

            // H-02: Record balance of output token before the hop
            uint256 hopBalanceBefore =
                IERC20(path[i + 1]).balanceOf(address(this));

            // Execute swap via the adapter
            ISwapAdapter(adapter).executeSwap(
                path[i],
                path[i + 1],
                amountOut,
                address(this)
            );

            // H-01: Reset residual approval to zero after each hop
            IERC20(path[i]).forceApprove(adapter, 0);

            // H-02: Use actual received amount, not adapter-reported value
            amountOut =
                IERC20(path[i + 1]).balanceOf(address(this))
                - hopBalanceBefore;
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

    // ========================================================================
    // ERC2771Context OVERRIDES
    // (resolve Context vs ERC2771Context diamond)
    // ========================================================================

    /**
     * @notice Resolve _msgSender between Context (via
     *         Ownable/Pausable) and ERC2771Context
     * @dev ERC2771Context overrides _msgSender() to extract
     *      the original signer from trusted-forwarder calldata.
     * @return sender The original transaction signer
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address sender)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context (via
     *         Ownable/Pausable) and ERC2771Context
     * @return The original calldata (stripped of appended
     *         sender when forwarded)
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between Context
     *         and ERC2771Context
     * @return Length of the context suffix (20 bytes when
     *         called via trusted forwarder, 0 otherwise)
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
