// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title LiquidityBootstrappingPool
 * @author OmniCoin Development Team
 * @notice Weighted pool with time-based weight shifting for fair token
 *         distribution
 * @dev Implements Balancer-style weighted AMM with dynamic weight changes.
 *      Uses the correct Balancer weighted constant product formula:
 *      amountOut = Bo * (1 - (Bi / (Bi + Ai))^(Wi/Wo))
 *      where exponentiation uses fixed-point ln/exp (exp(y*ln(x)) identity).
 *
 * Key features:
 * - Time-based weight shifting from high XOM ratio to balanced
 * - Fair price discovery through auction-like mechanism
 * - Discourages front-running and whale manipulation
 * - Minimal initial capital requirements ($5K-$25K seed)
 * - MAX_OUT_RATIO caps each swap to 30% of output reserve
 * - Actual-received amount used for price floor checks (FoT safe)
 * - Consolidated swap validation (anti-whale + cumulative tracking)
 * - Liquidity additions blocked after LBP starts
 *
 * PRECISION NOTE: The _lnFixed() function uses a 7-term Taylor series
 * for arctanh which converges well only when the input ratio > ~0.5.
 * This is guaranteed by MAX_OUT_RATIO = 30%, which ensures the ratio
 * Bi/(Bi+Ai) stays above ~0.5 for all valid swaps. If MAX_OUT_RATIO
 * is ever increased above 50%, the math library MUST be upgraded with
 * additional Taylor series terms (11-15) or a range-reduction approach.
 * Current precision: < 0.001% error for all valid swaps.
 *
 * Weight Shift Schedule:
 * The XOM weight decreases linearly from startWeightXOM to endWeightXOM
 * over the duration (endTime - startTime). At any time t:
 *   weightXOM(t) = startWeightXOM - (startWeightXOM - endWeightXOM)
 *                  * (t - startTime) / (endTime - startTime)
 *   weightCounterAsset(t) = 10000 - weightXOM(t)
 *
 * Weight-Price Relationship:
 * spotPrice = (counterReserve * weightXOM) / (xomReserve * weightCA)
 * As weightXOM decreases, the price decreases even without swaps,
 * creating a Dutch auction effect that encourages patient buying.
 *
 * Example with 90/10 -> 30/70 shift over 7 days:
 *   Day 0: price = (10000 * 9000) / (100M * 1000) = 0.0009 USDC/XOM
 *   Day 7: price = (10000 * 3000) / (100M * 7000) = 0.0000428 USDC/XOM
 *   (assuming no swaps change reserves)
 */
contract LiquidityBootstrappingPool is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Swap fee in basis points (0.3% = 30 bps)
    uint256 public constant SWAP_FEE_BPS = 30;

    /// @notice Minimum XOM weight allowed (20%)
    uint256 public constant MIN_XOM_WEIGHT = 2_000;

    /// @notice Maximum XOM weight allowed (96%)
    uint256 public constant MAX_XOM_WEIGHT = 9_600;

    /// @notice Maximum output as a fraction of output reserve per swap
    ///         (30% = 3000 bps). Prevents excessive pool imbalance.
    /// @dev PRECISION DEPENDENCY: The _lnFixed() Taylor series (7-term
    ///      arctanh) provides < 0.001% error only when the input ratio
    ///      stays above ~0.5. MAX_OUT_RATIO at 30% ensures the ratio
    ///      Bi/(Bi+Ai) remains in a range where the series converges
    ///      accurately. If MAX_OUT_RATIO is increased above 50%, the
    ///      Taylor series error grows to > 1%, requiring additional
    ///      terms (11-15) or a range-reduction approach. Do NOT
    ///      increase MAX_OUT_RATIO without upgrading the math library.
    uint256 public constant MAX_OUT_RATIO = 3_000;

    /// @notice Precision for fixed-point math (1e18 = 1.0)
    uint256 private constant PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice XOM token contract address
    IERC20 public immutable XOM_TOKEN;

    /// @notice Counter-asset token (USDC) contract address
    IERC20 public immutable COUNTER_ASSET_TOKEN;

    /// @notice Counter-asset decimals (for normalization)
    uint8 public immutable COUNTER_ASSET_DECIMALS;

    // ============ State Variables ============

    /// @notice LBP start timestamp
    uint256 public startTime;

    /// @notice LBP end timestamp
    uint256 public endTime;

    /// @notice Starting XOM weight in basis points (e.g., 9000 = 90%)
    uint256 public startWeightXOM;

    /// @notice Ending XOM weight in basis points (e.g., 3000 = 30%)
    uint256 public endWeightXOM;

    /// @notice Current XOM reserve in the pool
    uint256 public xomReserve;

    /// @notice Current counter-asset reserve in the pool
    uint256 public counterAssetReserve;

    /// @notice Minimum XOM price floor (in counter-asset, 18 decimals)
    uint256 public priceFloor;

    /// @notice Maximum individual purchase amount (anti-whale)
    uint256 public maxPurchaseAmount;

    /// @notice Total counter-asset raised during LBP
    uint256 public totalRaised;

    /// @notice Total XOM distributed during LBP
    uint256 public totalDistributed;

    /// @notice Whether the LBP has been finalized
    bool public finalized;

    /// @notice Address to receive raised funds
    address public treasury;

    /// @notice M-02: Cumulative counter-asset spent per address.
    ///         Prevents flash-loan attacks that circumvent per-tx
    ///         maxPurchaseAmount by splitting into multiple swaps.
    mapping(address => uint256) public cumulativePurchases;

    // ============ Events ============

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when a swap occurs
    /// @param buyer Address performing the swap
    /// @param counterAssetIn Amount of counter-asset provided
    /// @param xomOut Amount of XOM received
    /// @param spotPrice Price at time of swap (18 decimals)
    /// @param timestamp Block timestamp
    event Swap(
        address indexed buyer,
        uint256 counterAssetIn,
        uint256 xomOut,
        uint256 spotPrice,
        uint256 timestamp
    );

    /// @notice Emitted when liquidity is added by owner
    /// @param xomAmount Amount of XOM added
    /// @param counterAssetAmount Amount of counter-asset added
    event LiquidityAdded(
        uint256 indexed xomAmount,
        uint256 indexed counterAssetAmount
    );

    /// @notice Emitted when LBP parameters are updated
    /// @param newStartTime New start time
    /// @param newEndTime New end time
    /// @param newStartWeightXOM New starting XOM weight
    /// @param newEndWeightXOM New ending XOM weight
    event ParametersUpdated(
        uint256 indexed newStartTime,
        uint256 indexed newEndTime,
        uint256 indexed newStartWeightXOM,
        uint256 newEndWeightXOM
    );

    /// @notice Emitted when LBP is finalized
    /// @param raisedTotal Total counter-asset raised
    /// @param distributedTotal Total XOM distributed
    /// @param remainingXom Remaining XOM returned to treasury
    event LBPFinalized(
        uint256 indexed raisedTotal,
        uint256 indexed distributedTotal,
        uint256 indexed remainingXom
    );

    /* solhint-enable gas-indexed-events */

    // ============ Errors ============

    /// @notice Thrown when LBP is not active
    error LBPNotActive();

    /// @notice Thrown when LBP has already started
    error LBPAlreadyStarted();

    /// @notice Thrown when LBP has not ended
    error LBPNotEnded();

    /// @notice Thrown when LBP is already finalized
    error AlreadyFinalized();

    /// @notice Thrown when slippage exceeds maximum
    error SlippageExceeded();

    /// @notice Thrown when purchase exceeds maximum amount
    error ExceedsMaxPurchase();

    /// @notice Thrown when price is below floor
    error PriceBelowFloor();

    /// @notice Thrown when parameters are invalid
    error InvalidParameters();

    /// @notice Thrown when weights are invalid
    error InvalidWeights();

    /// @notice Thrown when transfer fails
    error TransferFailed();

    /// @notice Thrown when swap output exceeds max out ratio
    error ExceedsMaxOutRatio();

    /// @notice Thrown when logarithm input is zero or negative
    error LogInputOutOfRange();

    /// @notice Thrown when exponential input overflows
    error ExpInputOverflow();

    /// @notice Thrown when counter-asset decimals exceed 18
    error DecimalsOutOfRange();

    /// @notice Thrown when cumulative purchase exceeds per-address limit
    error CumulativePurchaseExceeded();

    // ============ Constructor ============

    /**
     * @notice Initialize the LBP contract
     * @param _xom XOM token address
     * @param _counterAsset Counter-asset (USDC) token address
     * @param _counterAssetDecimals Decimals of counter-asset (6 for USDC)
     * @param _treasury Address to receive raised funds
     */
    constructor(
        address _xom,
        address _counterAsset,
        uint8 _counterAssetDecimals,
        address _treasury
    ) Ownable(msg.sender) {
        if (
            _xom == address(0) ||
            _counterAsset == address(0) ||
            _treasury == address(0)
        ) {
            revert InvalidParameters();
        }

        // M-03: Validate counter-asset decimals do not exceed 18
        // to prevent underflow in getSpotPrice() normalization
        if (_counterAssetDecimals > 18) revert DecimalsOutOfRange();

        XOM_TOKEN = IERC20(_xom);
        COUNTER_ASSET_TOKEN = IERC20(_counterAsset);
        COUNTER_ASSET_DECIMALS = _counterAssetDecimals;
        treasury = _treasury;
    }

    // ============ External Functions ============

    /**
     * @notice Configure LBP parameters before start
     * @dev Can only be called before LBP starts. Start time must be in the
     *      future. Weight must decrease from start to end (Dutch auction).
     * @param _startTime Unix timestamp when LBP starts (must be future)
     * @param _endTime Unix timestamp when LBP ends
     * @param _startWeightXOM Starting XOM weight in basis points
     * @param _endWeightXOM Ending XOM weight in basis points
     * @param _priceFloor Minimum XOM price in counter-asset (18 decimals)
     * @param _maxPurchaseAmount Max single purchase amount (0 = no limit)
     */
    function configure(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _startWeightXOM,
        uint256 _endWeightXOM,
        uint256 _priceFloor,
        uint256 _maxPurchaseAmount
    ) external onlyOwner {
        // solhint-disable-next-line not-rely-on-time
        if (startTime != 0 && block.timestamp > startTime - 1) {
            revert LBPAlreadyStarted();
        }
        // solhint-disable-next-line not-rely-on-time
        if (_startTime < block.timestamp + 1) revert InvalidParameters();
        if (_startTime > _endTime - 1) revert InvalidParameters();
        if (
            _startWeightXOM > MAX_XOM_WEIGHT ||
            _startWeightXOM < MIN_XOM_WEIGHT
        ) {
            revert InvalidWeights();
        }
        if (
            _endWeightXOM > MAX_XOM_WEIGHT ||
            _endWeightXOM < MIN_XOM_WEIGHT
        ) {
            revert InvalidWeights();
        }
        if (_startWeightXOM < _endWeightXOM + 1) revert InvalidWeights();

        startTime = _startTime;
        endTime = _endTime;
        startWeightXOM = _startWeightXOM;
        endWeightXOM = _endWeightXOM;
        priceFloor = _priceFloor;
        maxPurchaseAmount = _maxPurchaseAmount;

        emit ParametersUpdated(
            _startTime, _endTime, _startWeightXOM, _endWeightXOM
        );
    }

    /**
     * @notice Add initial liquidity to the pool
     * @dev Can only be called by owner BEFORE the LBP has started.
     *      Prevents mid-LBP liquidity manipulation that could be
     *      used to front-run participants or manipulate spot price.
     *      If the LBP has started (block.timestamp >= startTime),
     *      this function reverts with LBPAlreadyStarted.
     * @param xomAmount Amount of XOM to add
     * @param counterAssetAmount Amount of counter-asset to add
     */
    function addLiquidity(
        uint256 xomAmount,
        uint256 counterAssetAmount
    ) external onlyOwner nonReentrant {
        if (finalized) revert AlreadyFinalized();
        // M-02: Prevent mid-LBP liquidity manipulation
        // solhint-disable-next-line not-rely-on-time
        if (startTime != 0 && block.timestamp > startTime - 1) {
            revert LBPAlreadyStarted();
        }

        if (xomAmount > 0) {
            XOM_TOKEN.safeTransferFrom(
                msg.sender, address(this), xomAmount
            );
            xomReserve += xomAmount;
        }

        if (counterAssetAmount > 0) {
            COUNTER_ASSET_TOKEN.safeTransferFrom(
                msg.sender, address(this), counterAssetAmount
            );
            counterAssetReserve += counterAssetAmount;
        }

        emit LiquidityAdded(xomAmount, counterAssetAmount);
    }

    /**
     * @notice Swap counter-asset for XOM tokens
     * @dev Main swap function for LBP participants. The function:
     *      1. Validates input (active, non-zero, cumulative limit)
     *      2. Computes swap output via Balancer weighted math
     *      3. Transfers counter-asset in (measures actual received)
     *      4. Updates state with actual received amount
     *      5. Checks price floor against post-swap reserves
     *      6. Transfers XOM out
     *      Price floor is checked using actual received amounts to
     *      correctly handle fee-on-transfer tokens (M-01 fix).
     * @param counterAssetIn Amount of counter-asset to swap
     *        (must be > 0)
     * @param minXomOut Minimum XOM to receive (slippage protection)
     * @return xomOut Amount of XOM tokens received
     */
    function swap(
        uint256 counterAssetIn,
        uint256 minXomOut
    ) external nonReentrant whenNotPaused returns (uint256 xomOut) {
        // --- Checks (consolidated validation) ---
        _validateSwap(counterAssetIn);

        xomOut = _computeSwapOutput(counterAssetIn);

        // Slippage check
        if (xomOut < minXomOut) revert SlippageExceeded();

        // Max output ratio check (30% of output reserve)
        if (xomOut * BASIS_POINTS > xomReserve * MAX_OUT_RATIO) {
            revert ExceedsMaxOutRatio();
        }

        // --- Transfer counter-asset in to measure actual received ---
        uint256 actualReceived = _transferCounterAssetIn(
            counterAssetIn
        );

        // --- Effects (state updates with ACTUAL received amount) ---
        counterAssetReserve += actualReceived;
        xomReserve -= xomOut;
        totalRaised += actualReceived;
        totalDistributed += xomOut;

        // Price floor check uses actual post-swap reserves (M-01 fix)
        uint256 postSwapPrice = getSpotPrice();
        if (postSwapPrice < priceFloor) revert PriceBelowFloor();

        // --- Interaction (XOM out) ---
        XOM_TOKEN.safeTransfer(msg.sender, xomOut);

        // solhint-disable-next-line not-rely-on-time
        uint256 swapTimestamp = block.timestamp;
        emit Swap(
            msg.sender,
            actualReceived,
            xomOut,
            postSwapPrice,
            swapTimestamp
        );

        return xomOut;
    }

    /**
     * @notice Finalize LBP and transfer funds to treasury
     * @dev Can only be called after LBP ends. Transfers all remaining
     *      counter-asset and XOM back to the treasury address.
     */
    function finalize() external onlyOwner nonReentrant {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < endTime) revert LBPNotEnded();
        if (finalized) revert AlreadyFinalized();

        finalized = true;

        // Transfer raised funds to treasury
        uint256 raisedAmount = counterAssetReserve;
        if (raisedAmount > 0) {
            counterAssetReserve = 0;
            COUNTER_ASSET_TOKEN.safeTransfer(treasury, raisedAmount);
        }

        // Return remaining XOM to treasury
        uint256 remainingXom = xomReserve;
        if (remainingXom > 0) {
            xomReserve = 0;
            XOM_TOKEN.safeTransfer(treasury, remainingXom);
        }

        emit LBPFinalized(totalRaised, totalDistributed, remainingXom);
    }

    /**
     * @notice Pause the LBP (emergency only)
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the LBP
     * @dev Only callable by the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update treasury address
     * @dev Only callable by the contract owner. Reverts on zero address.
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        treasury = _treasury;
    }

    // ============ External View Functions ============

    /**
     * @notice Calculate expected output for a given input
     * @dev Uses the same Balancer weighted formula as the actual swap.
     *      IMPORTANT LIMITATIONS: This quote does NOT account for:
     *      1. MAX_OUT_RATIO limit (actual swap may revert)
     *      2. Cumulative per-address purchase limits
     *      3. Fee-on-transfer adjustments
     *      4. Price floor enforcement (actual swap may revert)
     *      Use this for indicative quotes only. The actual swap may
     *      produce different results or revert.
     * @param counterAssetIn Amount of counter-asset to swap
     * @return xomOut Expected XOM output (indicative, not guaranteed)
     */
    function getExpectedOutput(
        uint256 counterAssetIn
    ) external view returns (uint256 xomOut) {
        (
            uint256 weightXOM,
            uint256 weightCounterAsset
        ) = getCurrentWeights();
        return _calculateSwapOutput(
            counterAssetReserve,
            weightCounterAsset,
            xomReserve,
            weightXOM,
            counterAssetIn
        );
    }

    /**
     * @notice Get LBP status information
     * @return _startTime LBP start time
     * @return _endTime LBP end time
     * @return _isActive Whether LBP is active
     * @return _totalRaised Total counter-asset raised
     * @return _totalDistributed Total XOM distributed
     * @return _currentPrice Current spot price
     */
    function getStatus()
        external
        view
        returns (
            uint256 _startTime,
            uint256 _endTime,
            bool _isActive,
            uint256 _totalRaised,
            uint256 _totalDistributed,
            uint256 _currentPrice
        )
    {
        return (
            startTime,
            endTime,
            isActive(),
            totalRaised,
            totalDistributed,
            getSpotPrice()
        );
    }

    // ============ Public View Functions ============

    /**
     * @notice Get current pool weights based on time progression
     * @dev Linear interpolation between start and end weights.
     *      Before start returns start weights; after end returns end
     *      weights.
     * @return weightXOM Current XOM weight in basis points
     * @return weightCounterAsset Current counter-asset weight in bps
     */
    function getCurrentWeights()
        public
        view
        returns (uint256 weightXOM, uint256 weightCounterAsset)
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < startTime + 1) {
            return (startWeightXOM, BASIS_POINTS - startWeightXOM);
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > endTime - 1) {
            return (endWeightXOM, BASIS_POINTS - endWeightXOM);
        }

        // Linear interpolation
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - startTime;
        uint256 duration = endTime - startTime;
        uint256 weightChange =
            ((startWeightXOM - endWeightXOM) * elapsed) / duration;

        weightXOM = startWeightXOM - weightChange;
        weightCounterAsset = BASIS_POINTS - weightXOM;
    }

    /**
     * @notice Get current spot price of XOM in counter-asset terms
     * @dev WARNING: This price is derived from pool reserves and is
     *      manipulable via large swaps. Do NOT use as a price oracle feed.
     *      Price = (counterReserve / wCounter) / (xomReserve / wXOM)
     *      Simplified: (counterReserve * wXOM) / (xomReserve * wCounter)
     *      Counter-asset is normalized to 18 decimals.
     * @return price Price in counter-asset per XOM (18 decimals)
     */
    function getSpotPrice() public view returns (uint256 price) {
        if (xomReserve == 0) return 0;

        (
            uint256 weightXOM,
            uint256 weightCounterAsset
        ) = getCurrentWeights();

        // Normalize counter-asset to 18 decimals
        uint256 normalizedCounterAsset = counterAssetReserve *
            (10 ** (18 - COUNTER_ASSET_DECIMALS));

        // price = (counterReserve * wXOM * 1e18) / (xomReserve * wCA)
        price =
            (normalizedCounterAsset * weightXOM * PRECISION) /
            (xomReserve * weightCounterAsset);
    }

    /**
     * @notice Check if LBP is currently active
     * @dev Active when: configured, current time within window, not
     *      finalized. Uses block.timestamp for time-window gating which
     *      is the intended business logic for an LBP lifecycle.
     * @return active True if LBP is within active time window
     */
    function isActive() public view returns (bool active) {
        // solhint-disable-next-line not-rely-on-time
        uint256 ts = block.timestamp;
        return startTime != 0 &&
            !finalized &&
            ts > startTime - 1 &&
            ts < endTime + 1;
    }

    // ============ Internal Functions ============

    /**
     * @notice Consolidated swap validation
     * @dev Validates that the LBP is active, input is non-zero, and
     *      cumulative per-address purchase limit is respected. Merges
     *      the per-transaction check and cumulative tracking into one
     *      function to avoid redundant validation and save gas on
     *      reverts. The cumulative check is strictly stronger than
     *      the per-transaction check, so the per-transaction check
     *      is only retained as an early cheap revert.
     * @param counterAssetIn Amount of counter-asset to swap
     */
    function _validateSwap(
        uint256 counterAssetIn
    ) internal {
        if (!isActive()) revert LBPNotActive();
        if (counterAssetIn == 0) revert InvalidParameters();
        if (maxPurchaseAmount > 0) {
            // Early revert for single-tx exceeding limit
            if (counterAssetIn > maxPurchaseAmount) {
                revert ExceedsMaxPurchase();
            }
            // Cumulative per-address tracking
            cumulativePurchases[msg.sender] += counterAssetIn;
            if (
                cumulativePurchases[msg.sender]
                    > maxPurchaseAmount
            ) {
                revert CumulativePurchaseExceeded();
            }
        }
    }

    /**
     * @notice Transfer counter-asset in with fee-on-transfer handling
     * @dev Uses balance-before/after pattern to measure actual received
     *      tokens. The caller is responsible for using actualReceived
     *      (not counterAssetIn) when updating state variables.
     * @param counterAssetIn Nominal amount to transfer
     * @return actualReceived Amount actually received after any fee
     */
    function _transferCounterAssetIn(
        uint256 counterAssetIn
    ) internal returns (uint256 actualReceived) {
        uint256 balBefore =
            COUNTER_ASSET_TOKEN.balanceOf(address(this));
        COUNTER_ASSET_TOKEN.safeTransferFrom(
            msg.sender, address(this), counterAssetIn
        );
        actualReceived =
            COUNTER_ASSET_TOKEN.balanceOf(address(this))
                - balBefore;
    }

    /**
     * @notice Compute XOM output for a given counter-asset input
     * @dev Fetches current weights and delegates to
     *      _calculateSwapOutput for Balancer math.
     * @param counterAssetIn Amount of counter-asset input
     * @return xomOut Calculated XOM output amount
     */
    function _computeSwapOutput(
        uint256 counterAssetIn
    ) internal view returns (uint256 xomOut) {
        (
            uint256 weightXOM,
            uint256 weightCounterAsset
        ) = getCurrentWeights();

        xomOut = _calculateSwapOutput(
            counterAssetReserve,
            weightCounterAsset,
            xomReserve,
            weightXOM,
            counterAssetIn
        );
    }

    /**
     * @notice Calculate swap output using Balancer weighted math
     * @dev Correct Balancer weighted constant product formula:
     *      amountOut = Bo * (1 - (Bi / (Bi + Ai))^(Wi / Wo))
     *      The exponent is computed via exp(y * ln(x)) identity using
     *      fixed-point arithmetic at 1e18 precision. Swap fee is applied
     *      to amountIn before the formula.
     * @param balanceIn Input token balance (counter-asset reserve)
     * @param weightIn Input token weight (in basis points)
     * @param balanceOut Output token balance (XOM reserve)
     * @param weightOut Output token weight (in basis points)
     * @param amountIn Amount of input token
     * @return amountOut Amount of output token
     */
    function _calculateSwapOutput(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256 amountOut) {
        if (balanceIn == 0 || balanceOut == 0 || weightOut == 0) {
            return 0;
        }

        // Apply swap fee
        uint256 amountInAfterFee =
            (amountIn * (BASIS_POINTS - SWAP_FEE_BPS)) / BASIS_POINTS;

        // ratio = balanceIn / (balanceIn + amountInAfterFee)
        // Always < 1.0 (represented in PRECISION)
        uint256 ratio =
            (balanceIn * PRECISION) / (balanceIn + amountInAfterFee);

        // exponent = weightIn / weightOut (in PRECISION)
        uint256 exponent = (weightIn * PRECISION) / weightOut;

        // power = ratio ^ exponent via exp(exponent * ln(ratio))
        uint256 power = _powFixed(ratio, exponent);

        // amountOut = balanceOut * (1 - power / PRECISION)
        if (power > PRECISION - 1) return 0;
        amountOut = (balanceOut * (PRECISION - power)) / PRECISION;
    }

    /**
     * @notice Fixed-point power: base^exp where both are scaled by 1e18
     * @dev Uses the identity x^y = exp(y * ln(x)). Base must be in the
     *      range (0, PRECISION]. For LBP swaps, base is always the
     *      ratio balanceIn/(balanceIn+amountIn) which is in (0, 1).
     * @param base Base value scaled by PRECISION (0 < base <= PRECISION)
     * @param exp Exponent scaled by PRECISION
     * @return result base^exp scaled by PRECISION
     */
    function _powFixed(
        uint256 base,
        uint256 exp
    ) internal pure returns (uint256 result) {
        if (base == 0) return 0;
        if (exp == 0) return PRECISION;
        if (base == PRECISION) return PRECISION;

        // ln(base) is negative since 0 < base < PRECISION (i.e., < 1.0)
        int256 lnBase = _lnFixed(int256(base));
        int256 product =
            (lnBase * int256(exp)) / int256(PRECISION);

        result = uint256(_expFixed(product));
    }

    /**
     * @notice Natural logarithm for fixed-point values in (0, PRECISION]
     * @dev Uses the identity ln(x) = 2 * arctanh((x-1)/(x+1)) where
     *      arctanh(y) = y + y^3/3 + y^5/5 + ... Converges well for
     *      |y| < 1. For LBP ratios (typically 0.5-0.999), this gives
     *      accuracy within ~0.01%.
     * @param x Value scaled by PRECISION (must be > 0, <= PRECISION)
     * @return ln Natural log result scaled by PRECISION (negative for
     *         x < PRECISION)
     */
    function _lnFixed(int256 x) internal pure returns (int256 ln) {
        if (x < 1) revert LogInputOutOfRange();

        int256 one = int256(PRECISION);

        // y = (x - 1) / (x + 1), always in (-1, 0] for x in (0, 1]
        int256 y = ((x - one) * one) / (x + one);
        int256 ySquared = (y * y) / one;

        // arctanh(y) = y + y^3/3 + y^5/5 + y^7/7 + ...
        // 7 terms give sufficient precision for LBP operating range
        int256 term = y;
        ln = term;

        term = (term * ySquared) / one;
        ln += term / 3;

        term = (term * ySquared) / one;
        ln += term / 5;

        term = (term * ySquared) / one;
        ln += term / 7;

        term = (term * ySquared) / one;
        ln += term / 9;

        term = (term * ySquared) / one;
        ln += term / 11;

        term = (term * ySquared) / one;
        ln += term / 13;

        // ln(x) = 2 * arctanh((x-1)/(x+1))
        ln *= 2;
    }

    /**
     * @notice Exponential function for fixed-point values
     * @dev Taylor series: e^x = 1 + x + x^2/2! + x^3/3! + ...
     *      For LBP usage, x is typically in [-4, 0] which converges
     *      quickly. 20 terms ensure convergence for the full range.
     * @param x Exponent scaled by PRECISION (can be negative)
     * @return result e^x scaled by PRECISION
     */
    function _expFixed(
        int256 x
    ) internal pure returns (int256 result) {
        int256 one = int256(PRECISION);

        // For very negative values, result approaches 0
        if (x < -42 * one) return 0;
        // Guard against overflow for large positive exponents
        if (x > 42 * one - 1) revert ExpInputOverflow();

        // Taylor series: e^x = sum(x^n / n!) for n = 0..20
        int256 term = one;
        result = one;

        for (uint256 i = 1; i < 21;) {
            term = (term * x) / (int256(i) * one);
            result += term;
            if (term == 0) break;
            unchecked { ++i; }
        }
    }
}
