// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RWAFeeCollector
 * @author OmniCoin Development Team
 * @notice Immutable protocol fee collection and distribution for RWA trading
 * @dev This contract is intentionally NON-UPGRADEABLE
 *
 * Fee Distribution (per swap):
 * - 70% → Liquidity Providers (accumulated in pools)
 * - 20% → XOM Staking Pool (sent to staking contract)
 * - 10% → Liquidity Pool (deep liquidity incentive)
 *
 * Key Features:
 * - Epoch-based distribution (every 6 hours)
 * - Multi-token fee accumulation
 * - Automatic conversion to XOM for distribution
 * - Immutable fee splits (legal defensibility)
 *
 * Security Features:
 * - Reentrancy protection
 * - No admin functions for fee changes
 * - Transparent on-chain distribution
 */
contract RWAFeeCollector is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS (IMMUTABLE - CANNOT BE CHANGED)
    // ========================================================================

    /// @notice Distribution interval in seconds (6 hours)
    uint256 public constant DISTRIBUTION_INTERVAL = 6 hours;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Fee split: Liquidity Providers (70%)
    /// @dev LP fees stay in pools, this is for tracking only
    uint256 public constant FEE_LP_BPS = 7000;

    /// @notice Fee split: Staking Pool (20%)
    uint256 public constant FEE_STAKING_BPS = 2000;

    /// @notice Fee split: Liquidity Pool (10%)
    uint256 public constant FEE_LIQUIDITY_BPS = 1000;

    // ========================================================================
    // IMMUTABLE STATE
    // ========================================================================

    // solhint-disable-next-line var-name-mixedcase
    /// @notice XOM token address
    address public immutable XOM_TOKEN;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Staking pool contract address
    address public immutable STAKING_POOL;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice AMM contract address (authorized fee sender)
    address public immutable AMM_CONTRACT;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Liquidity pool address for 10% fee distribution
    address public immutable LIQUIDITY_POOL;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Last distribution timestamp
    uint256 public lastDistributionTime;

    /// @notice Accumulated fees per token
    mapping(address => uint256) public accumulatedFees;

    /// @notice List of tokens with accumulated fees
    address[] private _feeTokens;

    /// @notice Mapping to check if token is in list
    mapping(address => bool) private _isFeeToken;

    /// @notice Total fees distributed (for transparency)
    uint256 public totalFeesDistributed;

    /// @notice Total fees sent to liquidity pool (for transparency)
    uint256 public totalFeesToLiquidity;

    /// @notice Epoch counter
    uint256 public currentEpoch;

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Distribution record for transparency
     */
    struct DistributionRecord {
        uint256 epoch;
        uint256 timestamp;
        uint256 toStaking;
        uint256 toLiquidity;
        address[] tokens;
        uint256[] amounts;
    }

    /// @notice Distribution history
    DistributionRecord[] public distributionHistory;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when fees are collected
    /// @param token Token address
    /// @param amount Fee amount
    /// @param from Sender address
    event FeesCollected(
        address indexed token,
        uint256 amount,
        address indexed from
    );

    /// @notice Emitted when fees are distributed
    /// @param epoch Distribution epoch
    /// @param toStaking Amount sent to staking
    /// @param toLiquidity Amount sent to liquidity pool
    /// @param timestamp Distribution timestamp
    event FeesDistributed(
        uint256 indexed epoch,
        uint256 toStaking,
        uint256 toLiquidity,
        uint256 timestamp
    );

    /// @notice Emitted when tokens are converted to XOM
    /// @param tokenIn Input token
    /// @param amountIn Input amount
    /// @param xomOut XOM received
    event TokensConverted(
        address indexed tokenIn,
        uint256 amountIn,
        uint256 xomOut
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when caller is not AMM
    error NotAMM();

    /// @notice Thrown when zero amount
    error ZeroAmount();

    /// @notice Thrown when distribution not yet due
    /// @param nextDistribution Next distribution timestamp
    error DistributionNotDue(uint256 nextDistribution);

    /// @notice Thrown when no fees to distribute
    error NoFeesToDistribute();

    /// @notice Thrown when token address is zero
    error ZeroAddress();

    /// @notice Thrown when index is out of bounds
    /// @param index Requested index
    /// @param length Array length
    error IndexOutOfBounds(uint256 index, uint256 length);

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Only AMM contract can call
     */
    modifier onlyAMM() {
        if (msg.sender != AMM_CONTRACT) revert NotAMM();
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploy the fee collector
     * @param _xomToken XOM token address
     * @param _stakingPool Staking pool address
     * @param _ammContract AMM contract address
     * @param _liquidityPool Liquidity pool address for 10% fee distribution
     */
    constructor(
        address _xomToken,
        address _stakingPool,
        address _ammContract,
        address _liquidityPool
    ) {
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_ammContract == address(0)) revert ZeroAddress();
        if (_liquidityPool == address(0)) revert ZeroAddress();

        XOM_TOKEN = _xomToken;
        STAKING_POOL = _stakingPool;
        AMM_CONTRACT = _ammContract;
        LIQUIDITY_POOL = _liquidityPool;

        // solhint-disable-next-line not-rely-on-time
        lastDistributionTime = block.timestamp;
    }

    // ========================================================================
    // FEE COLLECTION
    // ========================================================================

    /**
     * @notice Collect fees from AMM swaps
     * @dev Called by AMM contract after each swap
     * @param token Fee token address
     * @param amount Fee amount
     */
    function collectFees(
        address token,
        uint256 amount
    ) external onlyAMM nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        // Transfer fees from AMM
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Track accumulated fees
        accumulatedFees[token] += amount;

        // Add to token list if new
        if (!_isFeeToken[token]) {
            _feeTokens.push(token);
            _isFeeToken[token] = true;
        }

        emit FeesCollected(token, amount, msg.sender);
    }

    /**
     * @notice Receive fees directly (for manual deposits)
     * @param token Fee token address
     * @param amount Fee amount
     */
    function receiveFees(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        // Transfer fees from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Track accumulated fees
        accumulatedFees[token] += amount;

        // Add to token list if new
        if (!_isFeeToken[token]) {
            _feeTokens.push(token);
            _isFeeToken[token] = true;
        }

        emit FeesCollected(token, amount, msg.sender);
    }

    // ========================================================================
    // FEE DISTRIBUTION
    // ========================================================================

    /**
     * @notice Distribute accumulated fees
     * @dev Can be called by anyone after distribution interval
     */
    function distribute() external nonReentrant {
        // Check if distribution is due
        // solhint-disable-next-line not-rely-on-time
        uint256 nextDistribution = lastDistributionTime + DISTRIBUTION_INTERVAL;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nextDistribution) {
            revert DistributionNotDue(nextDistribution);
        }

        // Get XOM balance (after any conversions)
        uint256 xomBalance = IERC20(XOM_TOKEN).balanceOf(address(this));
        if (xomBalance == 0) revert NoFeesToDistribute();

        // Calculate distribution amounts
        // Note: LP fees (70%) stay in pools, we only distribute staking (20%) + liquidity (10%)
        uint256 stakingAmount =
            (xomBalance * FEE_STAKING_BPS) / (FEE_STAKING_BPS + FEE_LIQUIDITY_BPS);
        uint256 liquidityAmount = xomBalance - stakingAmount;

        // Distribute to staking pool
        if (stakingAmount > 0) {
            IERC20(XOM_TOKEN).safeTransfer(STAKING_POOL, stakingAmount);
            totalFeesDistributed += stakingAmount;
        }

        // Send to liquidity pool
        if (liquidityAmount > 0) {
            IERC20(XOM_TOKEN).safeTransfer(LIQUIDITY_POOL, liquidityAmount);
            totalFeesToLiquidity += liquidityAmount;
        }

        // Record distribution
        ++currentEpoch;
        // solhint-disable-next-line not-rely-on-time
        lastDistributionTime = block.timestamp;

        // Create distribution record
        address[] memory tokens = new address[](1);
        tokens[0] = XOM_TOKEN;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = xomBalance;

        distributionHistory.push(DistributionRecord({
            epoch: currentEpoch,
            timestamp: block.timestamp,
            toStaking: stakingAmount,
            toLiquidity: liquidityAmount,
            tokens: tokens,
            amounts: amounts
        }));

        emit FeesDistributed(currentEpoch, stakingAmount, liquidityAmount, block.timestamp);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get all tokens with accumulated fees
     * @return Array of token addresses
     */
    function getFeeTokens() external view returns (address[] memory) {
        return _feeTokens;
    }

    /**
     * @notice Get accumulated fee for specific token
     * @param token Token address
     * @return Accumulated fee amount
     */
    function getAccumulatedFee(address token) external view returns (uint256) {
        return accumulatedFees[token];
    }

    /**
     * @notice Get time until next distribution
     * @return Seconds until next distribution (0 if due)
     */
    function timeUntilNextDistribution() external view returns (uint256) {
        uint256 nextDistribution = lastDistributionTime + DISTRIBUTION_INTERVAL;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= nextDistribution) return 0;
        // solhint-disable-next-line not-rely-on-time
        return nextDistribution - block.timestamp;
    }

    /**
     * @notice Get distribution history count
     * @return Number of distribution records
     */
    function getDistributionCount() external view returns (uint256) {
        return distributionHistory.length;
    }

    /**
     * @notice Get distribution record by index
     * @param index Record index
     * @return record Distribution record
     */
    function getDistributionRecord(
        uint256 index
    ) external view returns (DistributionRecord memory record) {
        if (index >= distributionHistory.length) {
            revert IndexOutOfBounds(index, distributionHistory.length);
        }
        return distributionHistory[index];
    }

    /**
     * @notice Get total XOM ready for distribution
     * @return Total XOM balance
     */
    function getPendingDistribution() external view returns (uint256) {
        return IERC20(XOM_TOKEN).balanceOf(address(this));
    }

    /**
     * @notice Calculate expected distribution amounts
     * @return toStaking Amount that would go to staking
     * @return toLiquidity Amount that would go to liquidity pool
     */
    function getExpectedDistribution() external view returns (
        uint256 toStaking,
        uint256 toLiquidity
    ) {
        uint256 xomBalance = IERC20(XOM_TOKEN).balanceOf(address(this));
        if (xomBalance == 0) return (0, 0);

        toStaking = (xomBalance * FEE_STAKING_BPS) / (FEE_STAKING_BPS + FEE_LIQUIDITY_BPS);
        toLiquidity = xomBalance - toStaking;
    }

    /**
     * @notice Check if distribution is currently due
     * @return True if distribution can be triggered
     */
    function isDistributionDue() external view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp >= lastDistributionTime + DISTRIBUTION_INTERVAL;
    }
}
