// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/* solhint-disable import-path-check */
import {IERC20} from
    "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from
    "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from
    "@openzeppelin/contracts/utils/Pausable.sol";
import {ISwapAdapter} from "../dex/OmniSwapRouter.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";
/* solhint-enable import-path-check */

/**
 * @title ValidatorLiquidityBridge
 * @author OmniBazaar Team
 * @notice Liquidity reserve adapter that bridges on-chain swaps with
 *         off-chain order book depth during the LP bootstrapping phase.
 *
 * @dev Authorized liquidity providers (typically the deployer) deposit
 *      tokens into the bridge. The bridge implements {ISwapAdapter} so
 *      OmniSwapRouter can route swaps through it when the on-chain
 *      RWAAMM pool lacks sufficient depth.
 *
 *      **Pricing modes:**
 *      - `FIXED_RATE` — admin-set exchange rate per (tokenIn, tokenOut)
 *        direction.  Ideal for bootstrapping when the RWAAMM pool is
 *        shallow or non-existent.
 *      - `RWAAMM_ORACLE` — delegates to RWAAMM.getQuote() for pricing,
 *        with an oracle deviation check against the stored fixed rate.
 *        Use once the on-chain pool has grown deep enough.
 *
 *      **Integration:**
 *      After deployment, register with OmniSwapRouter:
 *        `OmniSwapRouter.addLiquiditySource("BRIDGE", bridgeAddress)`
 *      The router queries getAmountOut() from all adapters and picks
 *      the best rate.  During bootstrapping, the bridge often wins for
 *      large swaps because it has no price-impact curve — just flat
 *      pricing from the reserve.
 *
 *      **Security:**
 *      - Immutable RWAAMM + router references
 *      - Only router can call {executeSwap}; anyone can call {swap}
 *      - Daily volume limit (normalized) + per-user caps + per-swap
 *        min/max prevent griefing and single-tx draining
 *      - MAX_RATE ceiling prevents absurd rate misconfiguration
 *      - Oracle deviation check prevents RWAAMM price manipulation
 *      - Supported-token whitelist prevents unauthorized pair routing
 *      - Balance-before/after pattern on deposits
 *      - Approval-reset pattern after RWAAMM interactions
 *      - No upgrade path (immutable adapter, matches RWAAMM philosophy)
 */
contract ValidatorLiquidityBridge is
    ISwapAdapter,
    ReentrancyGuard,
    AccessControl,
    Pausable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════
    //                           ENUMS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pricing strategy for computing amountOut
    enum PricingMode {
        /// @dev Use admin-set directRate per pair direction
        FIXED_RATE,
        /// @dev Delegate to RWAAMM.getQuote() for market pricing
        RWAAMM_ORACLE
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Role for authorized liquidity providers who can
    ///         deposit / withdraw reserves and adjust swap limits
    bytes32 public constant BRIDGE_MANAGER_ROLE =
        keccak256("BRIDGE_MANAGER_ROLE");

    /// @notice Precision scalar for fixed-rate calculations
    /// @dev `amountOut = amountIn * directRate / RATE_PRECISION`
    uint256 public constant RATE_PRECISION = 1e18;

    /// @notice Maximum allowed daily volume limit (10 billion tokens)
    /// @dev Prevents accidental misconfiguration
    uint256 public constant MAX_DAILY_VOLUME = 10_000_000_000e18;

    /// @notice Maximum allowed rate for any pair direction
    /// @dev Prevents accidental or malicious rate misconfiguration.
    ///      Accommodates extreme decimal differences (e.g. 18-dec →
    ///      0-dec tokens at high prices).
    uint256 public constant MAX_RATE = 1e40;

    /// @notice Basis points denominator (100% = 10,000 bps)
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Seconds per day for volume reset
    uint256 private constant _SECONDS_PER_DAY = 86_400;

    // ═══════════════════════════════════════════════════════════════════
    //                         IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Reference to the deployed RWAAMM contract for oracle
    ///         pricing and getQuote() delegation
    // solhint-disable-next-line immutable-vars-naming,use-natspec
    IRWAAMM public immutable rwaamm;

    /// @notice OmniSwapRouter address — only this address may call
    ///         {executeSwap}
    // solhint-disable-next-line immutable-vars-naming,use-natspec
    address public immutable router;

    // ═══════════════════════════════════════════════════════════════════
    //                       MUTABLE STATE
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Current pricing mode
    PricingMode public pricingMode;

    /// @notice Per-direction exchange rate for FIXED_RATE mode.
    ///         `amountOut = amountIn * directRate[tIn][tOut] / 1e18`
    /// @dev The rate encodes decimal differences between tokens.
    ///      Example for XOM (18 dec) → USDC (6 dec) at $0.004:
    ///        1e18 XOM-wei should yield 4000 USDC-wei
    ///        => directRate = 4000
    ///      Example for USDC (6 dec) → XOM (18 dec) at $0.004:
    ///        1e6 USDC-wei should yield 250e18 XOM-wei
    ///        => directRate = 250e30
    mapping(address tokenIn => mapping(address tokenOut => uint256))
        public directRate;

    /// @notice Total reserve balance tracked per token
    mapping(address token => uint256 amount) public reserves;

    /// @notice Whether a token is whitelisted for bridge swaps
    mapping(address token => bool) public supportedTokens;

    /// @notice Maximum input amount for a single swap
    uint256 public maxSwapSize;

    /// @notice Minimum input amount for a single swap (dust guard)
    /// @dev Set to 0 to disable. Prevents volume-limit griefing via
    ///      many small swaps at negligible cost.
    uint256 public minSwapSize;

    /// @notice Maximum aggregate swap volume per calendar day
    /// @dev Tracked in normalized units (see {volumeNormalizer}).
    uint256 public dailyVolumeLimit;

    /// @notice Accumulated swap volume within the current day
    /// @dev Stored in normalized units.
    uint256 public dailyVolumeUsed;

    /// @notice The calendar day (block.timestamp / 86400) when
    ///         {dailyVolumeUsed} was last reset
    uint256 public lastVolumeResetDay;

    /// @notice Maximum aggregate swap volume per user per calendar day
    /// @dev Tracked in normalized units. Set to 0 to disable.
    ///      Prevents a single user from exhausting the daily limit.
    uint256 public perUserDailyVolumeLimit;

    /// @notice Per-user accumulated swap volume for the current day
    /// @dev Stored in normalized units.
    mapping(address user => uint256 used)
        public userDailyVolumeUsed;

    /// @notice Per-user calendar day when volume was last reset
    mapping(address user => uint256 day)
        public userLastVolumeResetDay;

    /// @notice Volume normalizer per token for cross-decimal tracking
    /// @dev Converts raw `amountIn` to 18-decimal-equivalent units.
    ///      For 18-decimal tokens: set to 1 (or leave 0 = default 1).
    ///      For 6-decimal tokens:  set to 1e12.
    ///      Normalized = amountIn * normalizer.
    ///      Daily volume limits are therefore expressed in 18-decimal
    ///      units regardless of which token is being swapped.
    mapping(address token => uint256) public volumeNormalizer;

    /// @notice Maximum deviation (basis points) between RWAAMM oracle
    ///         quote and the stored fixed rate
    /// @dev Only enforced in RWAAMM_ORACLE pricing mode. If 0,
    ///      deviation checking is disabled. Recommended: 500 (5%).
    uint256 public maxOracleDeviationBps;

    // ═══════════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a liquidity provider deposits tokens
    /// @param provider Address that deposited
    /// @param token Token deposited
    /// @param amount Amount credited to reserves
    event Deposited(
        address indexed provider,
        address indexed token,
        uint256 indexed amount
    );

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when a liquidity provider withdraws tokens
    /// @param provider Address that initiated the withdrawal
    /// @param token Token withdrawn
    /// @param amount Amount removed from reserves
    /// @param to Destination address
    event Withdrawn(
        address indexed provider,
        address indexed token,
        uint256 amount,
        address to
    );
    /* solhint-enable gas-indexed-events */

    /// @notice Emitted when a swap executes through the bridge
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @param amountOut Output amount
    /// @param recipient Swap output recipient
    /// @param viaRouter True if called via executeSwap (router),
    ///        false if called via public swap()
    event BridgeSwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient,
        bool viaRouter
    );

    /// @notice Emitted when a token's whitelist status changes
    /// @param token Token address
    /// @param supported New whitelist status
    event TokenSupportUpdated(
        address indexed token,
        bool indexed supported
    );

    /// @notice Emitted when a fixed exchange rate is updated
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param oldRate Previous rate
    /// @param newRate New rate
    event RateUpdated(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 indexed oldRate,
        uint256 newRate
    );

    /// @notice Emitted when the pricing mode changes
    /// @param oldMode Previous pricing mode
    /// @param newMode New pricing mode
    event PricingModeUpdated(
        PricingMode oldMode,
        PricingMode newMode
    );

    /// @notice Emitted when max swap size changes
    /// @param oldSize Previous cap
    /// @param newSize New cap
    event MaxSwapSizeUpdated(
        uint256 indexed oldSize,
        uint256 indexed newSize
    );

    /// @notice Emitted when min swap size changes
    /// @param oldSize Previous floor
    /// @param newSize New floor
    event MinSwapSizeUpdated(
        uint256 indexed oldSize,
        uint256 indexed newSize
    );

    /// @notice Emitted when daily volume limit changes
    /// @param oldLimit Previous limit
    /// @param newLimit New limit
    event DailyVolumeLimitUpdated(
        uint256 indexed oldLimit,
        uint256 indexed newLimit
    );

    /// @notice Emitted when per-user daily volume limit changes
    /// @param oldLimit Previous limit
    /// @param newLimit New limit
    event PerUserDailyVolumeLimitUpdated(
        uint256 indexed oldLimit,
        uint256 indexed newLimit
    );

    /// @notice Emitted when a token's volume normalizer changes
    /// @param token Token address
    /// @param normalizer New normalizer value
    event VolumeNormalizerUpdated(
        address indexed token,
        uint256 indexed normalizer
    );

    /// @notice Emitted when oracle deviation limit changes
    /// @param oldBps Previous deviation in basis points
    /// @param newBps New deviation in basis points
    event MaxOracleDeviationBpsUpdated(
        uint256 indexed oldBps,
        uint256 indexed newBps
    );

    // ═══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Caller is not the authorized router
    error OnlyRouter();

    /// @notice Token is not on the supported whitelist
    /// @param token The unsupported token address
    error UnsupportedToken(address token);

    /// @notice Reserve is too low to fulfill the swap
    /// @param token The token with insufficient reserves
    /// @param requested Amount requested
    /// @param available Amount available
    error InsufficientReserves(
        address token,
        uint256 requested,
        uint256 available
    );

    /// @notice Single swap exceeds maxSwapSize
    /// @param amount Attempted amount
    /// @param maxAllowed Current cap
    error SwapTooLarge(uint256 amount, uint256 maxAllowed);

    /// @notice Single swap is below minSwapSize
    /// @param amount Attempted amount
    /// @param minRequired Current floor
    error SwapTooSmall(uint256 amount, uint256 minRequired);

    /// @notice Aggregate daily volume would exceed limit
    /// @param projected Projected total after this swap
    /// @param limit Current daily limit
    error DailyVolumeLimitExceeded(
        uint256 projected,
        uint256 limit
    );

    /// @notice Per-user daily volume would exceed limit
    /// @param user The user address
    /// @param projected Projected total after this swap
    /// @param limit Current per-user daily limit
    error UserDailyVolumeLimitExceeded(
        address user,
        uint256 projected,
        uint256 limit
    );

    /// @notice A zero amount was provided where non-zero is required
    error ZeroAmount();

    /// @notice A zero address was provided where non-zero is required
    error ZeroAddress();

    /// @notice The computed output amount is zero
    error ZeroOutput();

    /// @notice The swap deadline has expired
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error DeadlineExpired(uint256 deadline, uint256 current);

    /// @notice Slippage tolerance exceeded
    /// @param expected Minimum expected output
    /// @param actual Actual computed output
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @notice Daily volume limit exceeds maximum allowed
    /// @param provided The value provided
    /// @param maximum The maximum allowed
    error VolumeLimitTooHigh(uint256 provided, uint256 maximum);

    /// @notice No exchange rate configured for this pair direction
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    error NoRateConfigured(address tokenIn, address tokenOut);

    /// @notice tokenIn and tokenOut must be different addresses
    error SameToken();

    /// @notice Actual tokens received differ from expected amount
    /// @param expected Expected amount
    /// @param received Actual amount received
    error TransferAmountMismatch(
        uint256 expected,
        uint256 received
    );

    /// @notice Rate exceeds the maximum allowed ceiling
    /// @param provided The rate provided
    /// @param maximum The maximum allowed
    error RateTooHigh(uint256 provided, uint256 maximum);

    /// @notice Thrown when enabling RWAAMM_ORACLE pricing while the oracle
    ///         deviation cap is unset (which would disable the manipulation
    ///         guard and expose reserves to a flash-priced drain).
    error OracleDeviationNotSet();

    // ═══════════════════════════════════════════════════════════════════
    //                         MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Restricts a function to the OmniSwapRouter
    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the bridge with fixed infrastructure references
     * @param rwaamm_ RWAAMM contract for oracle pricing
     * @param router_ OmniSwapRouter that may call executeSwap
     * @param admin_ Initial DEFAULT_ADMIN_ROLE + BRIDGE_MANAGER_ROLE
     * @param maxSwapSize_ Per-swap input cap (in tokenIn smallest
     *        units). Use 0 for no limit during testing.
     * @param dailyVolumeLimit_ Aggregate daily input cap. Use 0 for
     *        no limit during testing.
     */
    constructor(
        address rwaamm_,
        address router_,
        address admin_,
        uint256 maxSwapSize_,
        uint256 dailyVolumeLimit_
    ) {
        if (rwaamm_ == address(0)) revert ZeroAddress();
        if (router_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (dailyVolumeLimit_ > MAX_DAILY_VOLUME) {
            revert VolumeLimitTooHigh(
                dailyVolumeLimit_, MAX_DAILY_VOLUME
            );
        }

        rwaamm = IRWAAMM(rwaamm_);
        router = router_;
        maxSwapSize = maxSwapSize_;
        dailyVolumeLimit = dailyVolumeLimit_;
        pricingMode = PricingMode.FIXED_RATE;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(BRIDGE_MANAGER_ROLE, admin_);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    ISwapAdapter — ROUTER ONLY
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a swap called by OmniSwapRouter
     * @dev Tokens are transferred from the router to this contract.
     *      Output tokens are sent from reserves to the recipient.
     *      The router handles end-to-end slippage protection so
     *      this function does not enforce minAmountOut.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount (transferred from router)
     * @param recipient Address to receive output tokens
     * @return amountOut Amount of output tokens sent
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /* minAmountOut */,
        address recipient
    )
        external
        override
        onlyRouter
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        amountOut = _executeSwapInternal(
            tokenIn, tokenOut, amountIn, recipient, true
        );
    }

    /**
     * @notice Swap tokens directly through the bridge (no router)
     * @dev Transfers tokenIn from msg.sender, sends tokenOut from
     *      reserves to msg.sender. Enforces slippage + deadline.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param minAmountOut Minimum acceptable output (slippage guard)
     * @param deadline Transaction deadline (block.timestamp)
     * @return amountOut Amount of output tokens received
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        /* solhint-disable not-rely-on-time */
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        /* solhint-enable not-rely-on-time */

        amountOut = _executeSwapInternal(
            tokenIn, tokenOut, amountIn, msg.sender, false
        );

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(minAmountOut, amountOut);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens into the bridge reserve
     * @dev Uses balance-before/after pattern to handle fee-on-transfer
     *      tokens correctly. Only callable by BRIDGE_MANAGER_ROLE.
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function deposit(
        address token,
        uint256 amount
    ) external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant {
        if (!supportedTokens[token]) revert UnsupportedToken(token);
        if (amount == 0) revert ZeroAmount();

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            msg.sender, address(this), amount
        );
        uint256 received =
            IERC20(token).balanceOf(address(this)) - balBefore;

        reserves[token] += received;

        emit Deposited(msg.sender, token, received);
    }

    /**
     * @notice Withdraw tokens from the bridge reserve
     * @dev Only callable by BRIDGE_MANAGER_ROLE. Reserves must be
     *      sufficient.
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param to Destination address
     */
    function withdraw(
        address token,
        uint256 amount,
        address to
    ) external onlyRole(BRIDGE_MANAGER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (reserves[token] < amount) {
            revert InsufficientReserves(
                token, amount, reserves[token]
            );
        }

        reserves[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(msg.sender, token, amount, to);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    ADMIN — TOKEN SUPPORT
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Add or remove a token from the supported whitelist
     * @param token Token address
     * @param supported Whether the token is supported
     */
    function setSupportedToken(
        address token,
        bool supported
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        supportedTokens[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    ADMIN — PRICING
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Set the exchange rate for a specific pair direction
     * @dev Rate encodes decimal differences between tokens.
     *
     *      Formula: `amountOut = amountIn * rate / RATE_PRECISION`
     *
     *      Example — XOM (18 dec) to USDC (6 dec) at $0.004:
     *        1e18 XOM → 4000 USDC-wei
     *        rate = 4000
     *
     *      Example — USDC (6 dec) to XOM (18 dec) at $0.004:
     *        1e6 USDC → 250e18 XOM-wei
     *        rate = 250e30
     *
     *      **WARNING:** Rate changes take effect instantly and may be
     *      front-run. Use {safeSetRate} to atomically pause during
     *      the update.
     *
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param rate New rate (scaled by RATE_PRECISION). Must be ≤
     *        MAX_RATE.
     */
    function setRate(
        address tokenIn,
        address tokenOut,
        uint256 rate
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (rate > MAX_RATE) revert RateTooHigh(rate, MAX_RATE);

        uint256 oldRate = directRate[tokenIn][tokenOut];
        directRate[tokenIn][tokenOut] = rate;

        emit RateUpdated(tokenIn, tokenOut, oldRate, rate);
    }

    /**
     * @notice Set rate (alias for setRate with same front-running risk)
     * @dev Identical to setRate. The pause-then-unpause pattern was
     *      removed because _unpause() can revert if another tx
     *      unpaused the contract between the pause and unpause calls,
     *      permanently freezing the contract. Use setRate directly.
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param rate New rate (scaled by RATE_PRECISION)
     */
    function safeSetRate(
        address tokenIn,
        address tokenOut,
        uint256 rate
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert ZeroAddress();
        }
        if (rate > MAX_RATE) revert RateTooHigh(rate, MAX_RATE);

        uint256 oldRate = directRate[tokenIn][tokenOut];
        directRate[tokenIn][tokenOut] = rate;

        emit RateUpdated(tokenIn, tokenOut, oldRate, rate);
    }

    /**
     * @notice Switch between FIXED_RATE and RWAAMM_ORACLE pricing
     * @param mode New pricing mode
     */
    function setPricingMode(
        PricingMode mode
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        // Fail-closed: RWAAMM_ORACLE mode prices off an instantaneous
        // RWAAMM.getQuote() spot, so it MUST have a deviation cap configured
        // first. Without it, _isWithinOracleDeviation short-circuits to true
        // and an attacker can flash-move the AMM reserves to drain the bridge.
        if (mode == PricingMode.RWAAMM_ORACLE && maxOracleDeviationBps == 0) {
            revert OracleDeviationNotSet();
        }
        PricingMode oldMode = pricingMode;
        pricingMode = mode;
        emit PricingModeUpdated(oldMode, mode);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    ADMIN — LIMITS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Update the per-swap size cap
     * @dev Set to 0 to disable the per-swap limit.
     * @param newSize New maximum input per swap
     */
    function setMaxSwapSize(
        uint256 newSize
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        uint256 oldSize = maxSwapSize;
        maxSwapSize = newSize;
        emit MaxSwapSizeUpdated(oldSize, newSize);
    }

    /**
     * @notice Update the per-swap minimum size (dust guard)
     * @dev Set to 0 to disable the minimum. Prevents volume-limit
     *      griefing where many dust swaps exhaust the daily cap.
     * @param newSize New minimum input per swap
     */
    function setMinSwapSize(
        uint256 newSize
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        uint256 oldSize = minSwapSize;
        minSwapSize = newSize;
        emit MinSwapSizeUpdated(oldSize, newSize);
    }

    /**
     * @notice Update the daily aggregate volume limit
     * @dev Set to 0 to disable the daily limit. The limit is
     *      expressed in normalized units (18-decimal equivalent).
     * @param newLimit New daily limit
     */
    function setDailyVolumeLimit(
        uint256 newLimit
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (newLimit > MAX_DAILY_VOLUME) {
            revert VolumeLimitTooHigh(newLimit, MAX_DAILY_VOLUME);
        }
        uint256 oldLimit = dailyVolumeLimit;
        dailyVolumeLimit = newLimit;
        emit DailyVolumeLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Update the per-user daily volume limit
     * @dev Set to 0 to disable per-user tracking. The limit is
     *      expressed in normalized units (18-decimal equivalent).
     *      Prevents a single user from exhausting the global daily
     *      volume limit.
     * @param newLimit New per-user daily limit
     */
    function setPerUserDailyVolumeLimit(
        uint256 newLimit
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (newLimit > MAX_DAILY_VOLUME) {
            revert VolumeLimitTooHigh(newLimit, MAX_DAILY_VOLUME);
        }
        uint256 oldLimit = perUserDailyVolumeLimit;
        perUserDailyVolumeLimit = newLimit;
        emit PerUserDailyVolumeLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Set the volume normalizer for a token
     * @dev Converts raw amountIn to 18-decimal-equivalent units
     *      for fair cross-token volume accounting.
     *
     *      - For 18-decimal tokens (XOM): set to 1 (or leave as 0)
     *      - For 6-decimal tokens (USDC):  set to 1e12
     *      - Formula: normalizedVolume = amountIn * normalizer
     *      - If normalizer is 0 or 1, no scaling is applied.
     *
     * @param token Token address
     * @param normalizer Scaling multiplier
     */
    function setVolumeNormalizer(
        address token,
        uint256 normalizer
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        volumeNormalizer[token] = normalizer;
        emit VolumeNormalizerUpdated(token, normalizer);
    }

    /**
     * @notice Set the maximum oracle deviation in basis points
     * @dev Only enforced in RWAAMM_ORACLE mode. When the RWAAMM
     *      getQuote() result deviates from the stored fixed rate
     *      by more than this threshold, the output is treated as 0
     *      (swap blocked). Set to 0 to disable deviation checking.
     *      Recommended: 500 bps (5%).
     * @param newBps New maximum deviation in basis points
     */
    function setMaxOracleDeviationBps(
        uint256 newBps
    ) external onlyRole(BRIDGE_MANAGER_ROLE) {
        if (newBps > MAX_BPS) {
            revert VolumeLimitTooHigh(newBps, MAX_BPS);
        }
        uint256 oldBps = maxOracleDeviationBps;
        maxOracleDeviationBps = newBps;
        emit MaxOracleDeviationBpsUpdated(oldBps, newBps);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    ADMIN — PAUSE / EMERGENCY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pause all swap activity
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume swap activity
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency token recovery (admin only)
     * @dev Bypasses reserve tracking — use only in emergencies.
     *      After transfer, reconciles reserves with actual balance
     *      to prevent desynchronization from fee-on-transfer tokens,
     *      rounding, or partial-recovery scenarios.
     * @param token Token to recover
     * @param amount Amount to recover
     * @param to Destination address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);

        // Reconcile reserves with actual balance after transfer
        reserves[token] = IERC20(token).balanceOf(address(this));

        emit Withdrawn(msg.sender, token, amount, to);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   EXTERNAL VIEW
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Estimate output for a given swap without executing
     * @dev Returns 0 if the pair is unsupported, reserves are
     *      insufficient, or the swap exceeds size/volume limits.
     *      This lets the router skip the bridge gracefully.
     *
     *      Known limitation: per-user daily volume limits are NOT
     *      checked here because getAmountOut is a view function
     *      called by the router without knowing the end user.
     *      Per-user limits are enforced at execution time in
     *      _executeSwapInternal via _enforceVolumeLimits.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @return amountOut Estimated output amount
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        if (
            !supportedTokens[tokenIn]
                || !supportedTokens[tokenOut]
                || tokenIn == tokenOut
                || !_isValidSwapSize(amountIn)
        ) return 0;
        if (!_hasVolumeCapacity(tokenIn, amountIn)) return 0;

        amountOut = _computeAmountOut(tokenIn, tokenOut, amountIn);
        if (reserves[tokenOut] < amountOut) return 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Get the current day number used for volume tracking
     * @return day The calendar day (block.timestamp / 86400)
     */
    function currentDay() external view returns (uint256 day) {
        /* solhint-disable-next-line not-rely-on-time */
        day = block.timestamp / _SECONDS_PER_DAY;
    }

    /**
     * @notice Get the remaining global daily volume capacity
     * @dev Returns in normalized units (18-decimal equivalent).
     *      To convert back to raw token units, divide by the
     *      token's volumeNormalizer.
     * @return remaining Normalized volume tokens that can still
     *         be swapped today. Returns type(uint256).max if no
     *         limit is set.
     */
    function remainingDailyVolume()
        external
        view
        returns (uint256 remaining)
    {
        if (dailyVolumeLimit == 0) return type(uint256).max;

        /* solhint-disable-next-line not-rely-on-time */
        uint256 today = block.timestamp / _SECONDS_PER_DAY;
        if (today > lastVolumeResetDay) return dailyVolumeLimit;

        // solhint-disable-next-line gas-strict-inequalities
        if (dailyVolumeUsed >= dailyVolumeLimit) return 0;
        remaining = dailyVolumeLimit - dailyVolumeUsed;
    }

    /**
     * @notice Get the remaining per-user daily volume capacity
     * @dev Returns in normalized units. Returns type(uint256).max
     *      if per-user tracking is disabled.
     * @param user The user address to check
     * @return remaining Normalized volume this user can still swap
     */
    function remainingUserDailyVolume(
        address user
    ) external view returns (uint256 remaining) {
        if (perUserDailyVolumeLimit == 0) return type(uint256).max;

        /* solhint-disable-next-line not-rely-on-time */
        uint256 today = block.timestamp / _SECONDS_PER_DAY;
        uint256 used = (today > userLastVolumeResetDay[user])
            ? 0
            : userDailyVolumeUsed[user];

        // solhint-disable-next-line gas-strict-inequalities
        if (used >= perUserDailyVolumeLimit) return 0;
        remaining = perUserDailyVolumeLimit - used;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Core swap logic shared by executeSwap and swap
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param recipient Output recipient
     * @param viaRouter True when called from executeSwap (router
     *        already transferred tokenIn to this contract)
     * @return amountOut Computed and transferred output amount
     */
    function _executeSwapInternal(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        bool viaRouter
    ) internal returns (uint256 amountOut) {
        _validateSwapParams(tokenIn, tokenOut, amountIn, recipient);
        _enforceVolumeLimits(tokenIn, amountIn, recipient);

        // ── Compute output ──────────────────────────────────────────
        amountOut = _computeAmountOut(tokenIn, tokenOut, amountIn);
        if (amountOut == 0) revert ZeroOutput();

        if (reserves[tokenOut] < amountOut) {
            revert InsufficientReserves(
                tokenOut, amountOut, reserves[tokenOut]
            );
        }

        // ── Pull tokenIn (reverts on fee-on-transfer mismatch) ─────
        uint256 received = _pullTokenVerified(tokenIn, amountIn);

        // ── Effects ───────────────────────────────────────────────
        reserves[tokenIn] += received;
        reserves[tokenOut] -= amountOut;

        // ── Send tokenOut from reserves ───────────────────────────
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit BridgeSwapExecuted(
            tokenIn, tokenOut, amountIn, amountOut,
            recipient, viaRouter
        );
    }

    /**
     * @notice Pull tokens from msg.sender with balance verification
     * @dev Reverts with {TransferAmountMismatch} if the received
     *      amount differs from `amountIn` (fee-on-transfer token).
     * @param token Token to pull
     * @param amountIn Expected amount
     * @return received Actual tokens received (always == amountIn)
     */
    function _pullTokenVerified(
        address token,
        uint256 amountIn
    ) internal returns (uint256 received) {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            msg.sender, address(this), amountIn
        );
        received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received != amountIn) {
            revert TransferAmountMismatch(amountIn, received);
        }
    }

    /**
     * @notice Enforce daily volume limits and reset if new day
     * @dev Tracks volume in normalized units. Both global and
     *      per-user limits are checked.
     * @param tokenIn Input token (for normalization)
     * @param amountIn Raw input amount
     * @param user User address for per-user tracking
     */
    function _enforceVolumeLimits(
        address tokenIn,
        uint256 amountIn,
        address user
    ) internal {
        _resetDailyVolumeIfNeeded();
        uint256 normalized = _normalizeVolume(tokenIn, amountIn);

        // ── Global daily volume ─────────────────────────────────
        if (dailyVolumeLimit > 0) {
            uint256 projected = dailyVolumeUsed + normalized;
            if (projected > dailyVolumeLimit) {
                revert DailyVolumeLimitExceeded(
                    projected, dailyVolumeLimit
                );
            }
            dailyVolumeUsed = projected;
        }

        // ── Per-user daily volume ───────────────────────────────
        if (perUserDailyVolumeLimit > 0) {
            _resetUserVolumeIfNeeded(user);
            uint256 userProjected =
                userDailyVolumeUsed[user] + normalized;
            if (userProjected > perUserDailyVolumeLimit) {
                revert UserDailyVolumeLimitExceeded(
                    user, userProjected, perUserDailyVolumeLimit
                );
            }
            userDailyVolumeUsed[user] = userProjected;
        }
    }

    /**
     * @notice Reset dailyVolumeUsed if a new calendar day has begun
     */
    function _resetDailyVolumeIfNeeded() internal {
        /* solhint-disable-next-line not-rely-on-time */
        uint256 today = block.timestamp / _SECONDS_PER_DAY;
        if (today > lastVolumeResetDay) {
            dailyVolumeUsed = 0;
            lastVolumeResetDay = today;
        }
    }

    /**
     * @notice Reset per-user volume if a new calendar day has begun
     * @param user User address to reset
     */
    function _resetUserVolumeIfNeeded(address user) internal {
        /* solhint-disable-next-line not-rely-on-time */
        uint256 today = block.timestamp / _SECONDS_PER_DAY;
        if (today > userLastVolumeResetDay[user]) {
            userDailyVolumeUsed[user] = 0;
            userLastVolumeResetDay[user] = today;
        }
    }

    // ── Internal view ───────────────────────────────────────────────

    /**
     * @notice Normalize a raw token amount to 18-decimal equivalent
     * @dev If no normalizer is set (0 or 1), returns amount as-is.
     * @param token Token address
     * @param amount Raw token amount
     * @return normalized Normalized amount in 18-decimal units
     */
    function _normalizeVolume(
        address token,
        uint256 amount
    ) internal view returns (uint256 normalized) {
        uint256 norm = volumeNormalizer[token];
        if (norm < 2) return amount;
        normalized = amount * norm;
    }

    /**
     * @notice Check whether amountIn passes min/max size constraints
     * @param amountIn Input amount to validate
     * @return valid True if the amount is within allowed bounds
     */
    function _isValidSwapSize(
        uint256 amountIn
    ) internal view returns (bool valid) {
        if (amountIn == 0) return false;
        if (minSwapSize > 0 && amountIn < minSwapSize) return false;
        if (maxSwapSize > 0 && amountIn > maxSwapSize) return false;
        valid = true;
    }

    /**
     * @notice Check whether `amountIn` fits within daily volume limit
     * @param tokenIn Input token (for normalization)
     * @param amountIn Raw input amount to check
     * @return fits True if there is room (or no limit is configured)
     */
    function _hasVolumeCapacity(
        address tokenIn,
        uint256 amountIn
    ) internal view returns (bool fits) {
        if (dailyVolumeLimit == 0) return true;
        /* solhint-disable-next-line not-rely-on-time */
        uint256 today = block.timestamp / _SECONDS_PER_DAY;
        uint256 used = (today > lastVolumeResetDay)
            ? 0
            : dailyVolumeUsed;
        uint256 normalized = _normalizeVolume(tokenIn, amountIn);
        // solhint-disable-next-line gas-strict-inequalities
        fits = (used + normalized <= dailyVolumeLimit);
    }

    /**
     * @notice Validate swap parameters
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param recipient Output recipient
     */
    function _validateSwapParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) internal view {
        if (tokenIn == tokenOut) revert SameToken();
        if (
            !supportedTokens[tokenIn]
                || !supportedTokens[tokenOut]
        ) {
            revert UnsupportedToken(
                !supportedTokens[tokenIn] ? tokenIn : tokenOut
            );
        }
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _validateSwapSize(amountIn);
    }

    /**
     * @notice Validate that amountIn is within min/max swap size
     * @param amountIn Input amount to validate
     */
    function _validateSwapSize(uint256 amountIn) internal view {
        if (minSwapSize > 0 && amountIn < minSwapSize) {
            revert SwapTooSmall(amountIn, minSwapSize);
        }
        if (maxSwapSize > 0 && amountIn > maxSwapSize) {
            revert SwapTooLarge(amountIn, maxSwapSize);
        }
    }

    /**
     * @notice Compute the output amount using the active pricing mode
     * @dev In RWAAMM_ORACLE mode, the call is wrapped in try/catch
     *      so a reverting RWAAMM gracefully returns 0 (allows the
     *      router to skip this adapter). An oracle deviation check
     *      compares the quote against the stored fixed rate.
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @return amountOut Computed output amount
     */
    function _computeAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        if (pricingMode == PricingMode.FIXED_RATE) {
            uint256 rate = directRate[tokenIn][tokenOut];
            if (rate == 0) return 0;
            amountOut = (amountIn * rate) / RATE_PRECISION;
        } else {
            // RWAAMM_ORACLE mode — delegate with try/catch
            try rwaamm.getQuote(tokenIn, tokenOut, amountIn)
                returns (uint256 out, uint256, uint256)
            {
                amountOut = out;
            } catch {
                return 0;
            }
            // Validate oracle deviation against stored fixed rate
            if (!_isWithinOracleDeviation(
                tokenIn, tokenOut, amountIn, amountOut
            )) {
                return 0;
            }
        }
    }

    /**
     * @notice Check that the oracle output is within acceptable
     *         deviation from the stored fixed rate
     * @dev Returns true if deviation check is disabled (bps == 0),
     *      if no reference fixed rate exists, or if the deviation
     *      is within bounds.
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount (for computing fixed-rate ref)
     * @param oracleOut Oracle-quoted output amount
     * @return withinBounds True if the quote is acceptable
     */
    function _isWithinOracleDeviation(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 oracleOut
    ) internal view returns (bool withinBounds) {
        if (maxOracleDeviationBps == 0) return true;

        uint256 rate = directRate[tokenIn][tokenOut];
        if (rate == 0) return false;

        uint256 fixedOut = (amountIn * rate) / RATE_PRECISION;
        if (fixedOut == 0) return true;

        uint256 diff = oracleOut > fixedOut
            ? oracleOut - fixedOut
            : fixedOut - oracleOut;

        // solhint-disable-next-line gas-strict-inequalities
        withinBounds = (diff * MAX_BPS <= fixedOut * maxOracleDeviationBps);
    }
}
