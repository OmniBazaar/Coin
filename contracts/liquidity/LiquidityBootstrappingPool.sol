// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title LiquidityBootstrappingPool
 * @author OmniCoin Development Team
 * @notice Weighted pool with time-based weight shifting for fair token distribution
 * @dev Implements Balancer-style weighted AMM with dynamic weight changes.
 *      Used for initial XOM distribution with minimal counter-asset capital.
 *
 * Key features:
 * - Time-based weight shifting from high XOM ratio to balanced
 * - Fair price discovery through auction-like mechanism
 * - Discourages front-running and whale manipulation
 * - Minimal initial capital requirements ($5K-$25K seed)
 *
 * Weight Progression Example:
 * - Start: 90% XOM / 10% USDC (need $10K USDC for $100K XOM)
 * - End:   30% XOM / 70% USDC (natural accumulation through swaps)
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

    /// @notice Precision for fixed-point math
    uint256 private constant PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice XOM token contract address
    IERC20 public immutable xom;

    /// @notice Counter-asset token (USDC) contract address
    IERC20 public immutable counterAsset;

    /// @notice Counter-asset decimals (for normalization)
    uint8 public immutable counterAssetDecimals;

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

    // ============ Events ============

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
        uint256 indexed spotPrice,
        uint256 timestamp
    );

    /// @notice Emitted when liquidity is added by owner
    /// @param xomAmount Amount of XOM added
    /// @param counterAssetAmount Amount of counter-asset added
    event LiquidityAdded(uint256 xomAmount, uint256 counterAssetAmount);

    /// @notice Emitted when LBP parameters are updated
    /// @param startTime New start time
    /// @param endTime New end time
    /// @param startWeightXOM New starting XOM weight
    /// @param endWeightXOM New ending XOM weight
    event ParametersUpdated(
        uint256 startTime,
        uint256 endTime,
        uint256 startWeightXOM,
        uint256 endWeightXOM
    );

    /// @notice Emitted when LBP is finalized
    /// @param totalRaised Total counter-asset raised
    /// @param totalDistributed Total XOM distributed
    /// @param remainingXom Remaining XOM returned to treasury
    event LBPFinalized(
        uint256 totalRaised,
        uint256 totalDistributed,
        uint256 remainingXom
    );

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

    // ============ Constructor ============

    /**
     * @notice Initialize the LBP contract
     * @param _xom XOM token address
     * @param _counterAsset Counter-asset (USDC) token address
     * @param _counterAssetDecimals Decimals of counter-asset (typically 6 for USDC)
     * @param _treasury Address to receive raised funds
     */
    constructor(
        address _xom,
        address _counterAsset,
        uint8 _counterAssetDecimals,
        address _treasury
    ) Ownable(msg.sender) {
        if (_xom == address(0) || _counterAsset == address(0) || _treasury == address(0)) {
            revert InvalidParameters();
        }

        xom = IERC20(_xom);
        counterAsset = IERC20(_counterAsset);
        counterAssetDecimals = _counterAssetDecimals;
        treasury = _treasury;
    }

    // ============ External Functions ============

    /**
     * @notice Configure LBP parameters before start
     * @dev Can only be called before LBP starts
     * @param _startTime Unix timestamp when LBP starts
     * @param _endTime Unix timestamp when LBP ends
     * @param _startWeightXOM Starting XOM weight in basis points
     * @param _endWeightXOM Ending XOM weight in basis points
     * @param _priceFloor Minimum XOM price in counter-asset (18 decimals)
     * @param _maxPurchaseAmount Maximum single purchase amount (0 for no limit)
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
        if (startTime != 0 && block.timestamp >= startTime) revert LBPAlreadyStarted();
        if (_startTime >= _endTime) revert InvalidParameters();
        if (_startWeightXOM > MAX_XOM_WEIGHT || _startWeightXOM < MIN_XOM_WEIGHT) {
            revert InvalidWeights();
        }
        if (_endWeightXOM > MAX_XOM_WEIGHT || _endWeightXOM < MIN_XOM_WEIGHT) {
            revert InvalidWeights();
        }
        if (_startWeightXOM <= _endWeightXOM) revert InvalidWeights();

        startTime = _startTime;
        endTime = _endTime;
        startWeightXOM = _startWeightXOM;
        endWeightXOM = _endWeightXOM;
        priceFloor = _priceFloor;
        maxPurchaseAmount = _maxPurchaseAmount;

        emit ParametersUpdated(_startTime, _endTime, _startWeightXOM, _endWeightXOM);
    }

    /**
     * @notice Add initial liquidity to the pool
     * @dev Can only be called by owner before LBP ends
     * @param xomAmount Amount of XOM to add
     * @param counterAssetAmount Amount of counter-asset to add
     */
    function addLiquidity(
        uint256 xomAmount,
        uint256 counterAssetAmount
    ) external onlyOwner nonReentrant {
        if (finalized) revert AlreadyFinalized();

        if (xomAmount > 0) {
            xom.safeTransferFrom(msg.sender, address(this), xomAmount);
            xomReserve += xomAmount;
        }

        if (counterAssetAmount > 0) {
            counterAsset.safeTransferFrom(msg.sender, address(this), counterAssetAmount);
            counterAssetReserve += counterAssetAmount;
        }

        emit LiquidityAdded(xomAmount, counterAssetAmount);
    }

    /**
     * @notice Swap counter-asset for XOM tokens
     * @dev Main swap function for LBP participants
     * @param counterAssetIn Amount of counter-asset to swap
     * @param minXomOut Minimum XOM to receive (slippage protection)
     * @return xomOut Amount of XOM tokens received
     */
    function swap(
        uint256 counterAssetIn,
        uint256 minXomOut
    ) external nonReentrant whenNotPaused returns (uint256 xomOut) {
        if (!isActive()) revert LBPNotActive();
        if (maxPurchaseAmount > 0 && counterAssetIn > maxPurchaseAmount) {
            revert ExceedsMaxPurchase();
        }

        // Get current weights
        (uint256 weightXOM, uint256 weightCounterAsset) = getCurrentWeights();

        // Calculate output using weighted constant product formula
        xomOut = _calculateSwapOutput(
            counterAssetReserve,
            weightCounterAsset,
            xomReserve,
            weightXOM,
            counterAssetIn
        );

        // Slippage check
        if (xomOut < minXomOut) revert SlippageExceeded();

        // Price floor check
        uint256 currentPrice = getSpotPrice();
        if (currentPrice < priceFloor) revert PriceBelowFloor();

        // Execute swap
        counterAsset.safeTransferFrom(msg.sender, address(this), counterAssetIn);
        xom.safeTransfer(msg.sender, xomOut);

        // Update reserves
        counterAssetReserve += counterAssetIn;
        xomReserve -= xomOut;

        // Update totals
        totalRaised += counterAssetIn;
        totalDistributed += xomOut;

        // solhint-disable-next-line not-rely-on-time
        emit Swap(msg.sender, counterAssetIn, xomOut, currentPrice, block.timestamp);

        return xomOut;
    }

    /**
     * @notice Finalize LBP and transfer funds to treasury
     * @dev Can only be called after LBP ends
     */
    function finalize() external onlyOwner nonReentrant {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < endTime) revert LBPNotEnded();
        if (finalized) revert AlreadyFinalized();

        finalized = true;

        // Transfer raised funds to treasury
        uint256 raisedAmount = counterAssetReserve;
        if (raisedAmount > 0) {
            counterAsset.safeTransfer(treasury, raisedAmount);
            counterAssetReserve = 0;
        }

        // Return remaining XOM to treasury
        uint256 remainingXom = xomReserve;
        if (remainingXom > 0) {
            xom.safeTransfer(treasury, remainingXom);
            xomReserve = 0;
        }

        emit LBPFinalized(totalRaised, totalDistributed, remainingXom);
    }

    /**
     * @notice Pause the LBP (emergency only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the LBP
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        treasury = _treasury;
    }

    // ============ View Functions ============

    /**
     * @notice Get current pool weights based on time progression
     * @return weightXOM Current XOM weight in basis points
     * @return weightCounterAsset Current counter-asset weight in basis points
     */
    function getCurrentWeights()
        public
        view
        returns (uint256 weightXOM, uint256 weightCounterAsset)
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp <= startTime) {
            return (startWeightXOM, BASIS_POINTS - startWeightXOM);
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= endTime) {
            return (endWeightXOM, BASIS_POINTS - endWeightXOM);
        }

        // Linear interpolation
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - startTime;
        uint256 duration = endTime - startTime;
        uint256 weightChange = ((startWeightXOM - endWeightXOM) * elapsed) / duration;

        weightXOM = startWeightXOM - weightChange;
        weightCounterAsset = BASIS_POINTS - weightXOM;
    }

    /**
     * @notice Get current spot price of XOM in counter-asset terms
     * @dev Price = (counterAssetReserve / weightCounterAsset) / (xomReserve / weightXOM)
     * @return price Price in counter-asset per XOM (18 decimals)
     */
    function getSpotPrice() public view returns (uint256 price) {
        if (xomReserve == 0) return 0;

        (uint256 weightXOM, uint256 weightCounterAsset) = getCurrentWeights();

        // Normalize counter-asset to 18 decimals
        uint256 normalizedCounterAsset = counterAssetReserve *
            (10 ** (18 - counterAssetDecimals));

        // Price = (counterAssetReserve / weightCounterAsset) / (xomReserve / weightXOM)
        // Simplified: (counterAssetReserve * weightXOM) / (xomReserve * weightCounterAsset)
        price =
            (normalizedCounterAsset * weightXOM * PRECISION) /
            (xomReserve * weightCounterAsset);
    }

    /**
     * @notice Calculate expected output for a given input
     * @param counterAssetIn Amount of counter-asset to swap
     * @return xomOut Expected XOM output
     */
    function getExpectedOutput(
        uint256 counterAssetIn
    ) external view returns (uint256 xomOut) {
        (uint256 weightXOM, uint256 weightCounterAsset) = getCurrentWeights();
        return
            _calculateSwapOutput(
                counterAssetReserve,
                weightCounterAsset,
                xomReserve,
                weightXOM,
                counterAssetIn
            );
    }

    /**
     * @notice Check if LBP is currently active
     * @return active True if LBP is within active time window
     */
    function isActive() public view returns (bool active) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp >= startTime &&
            block.timestamp <= endTime &&
            !finalized &&
            startTime != 0;
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

    // ============ Internal Functions ============

    /**
     * @notice Calculate swap output using Balancer weighted math
     * @dev Uses simplified weighted constant product formula with fee
     * @param balanceIn Input token balance (counter-asset)
     * @param weightIn Input token weight
     * @param balanceOut Output token balance (XOM)
     * @param weightOut Output token weight
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
        // Apply swap fee
        uint256 amountInAfterFee = (amountIn * (BASIS_POINTS - SWAP_FEE_BPS)) /
            BASIS_POINTS;

        // Balancer weighted math (simplified approximation):
        // amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountIn))^(weightIn/weightOut))
        //
        // For simplicity, we use a first-order approximation that works well for typical swap sizes:
        // amountOut ≈ balanceOut * amountIn * weightOut / (balanceIn * weightIn + amountIn * weightOut)

        uint256 numerator = balanceOut * amountInAfterFee * weightOut;
        uint256 denominator = balanceIn * weightIn + amountInAfterFee * weightOut;

        amountOut = numerator / denominator;
    }
}
