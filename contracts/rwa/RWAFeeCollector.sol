// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRWAFeeCollector} from "./interfaces/IRWAFeeCollector.sol";

/**
 * @title RWAFeeCollector
 * @author OmniCoin Development Team
 * @notice Immutable protocol fee collection and distribution for RWA trading
 * @dev This contract is intentionally NON-UPGRADEABLE.
 *
 * Fee Distribution Model:
 * - RWAAMM extracts 0.30% protocol fee per swap
 * - 70% of that fee stays in the pool (LP revenue via AMM curve)
 * - 30% is sent here and split as:
 *   - 2/3 (66.67% of received = 20% of total fee) to Staking Pool
 *   - 1/3 (33.33% of received = 10% of total fee) to Liquidity Pool
 *
 * Key Features:
 * - Epoch-based distribution (every 6 hours)
 * - Multi-token fee accumulation with accounting
 * - Non-XOM token rescue mechanism for admin
 * - Immutable fee splits (legal defensibility)
 *
 * Security Features:
 * - Reentrancy protection
 * - No admin functions for fee changes
 * - Transparent on-chain distribution
 */
contract RWAFeeCollector is IRWAFeeCollector, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS (IMMUTABLE - CANNOT BE CHANGED)
    // ========================================================================

    /// @notice Distribution interval in seconds (6 hours)
    uint256 public constant DISTRIBUTION_INTERVAL = 6 hours;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Fee split: Staking Pool share of received fees
    /// @dev Receives 2/3 of collector balance = 20% of total protocol fee
    uint256 public constant FEE_STAKING_BPS = 2000;

    /// @notice Fee split: Liquidity Pool share of received fees
    /// @dev Receives 1/3 of collector balance = 10% of total protocol fee
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
    /// @notice Liquidity pool address for fee distribution
    address public immutable LIQUIDITY_POOL;

    // solhint-disable-next-line var-name-mixedcase
    /// @notice Admin address for token rescue operations
    address public immutable ADMIN;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Last distribution timestamp
    uint256 public lastDistributionTime;

    /// @notice Accumulated fees per token (cumulative total received)
    mapping(address => uint256) public accumulatedFees;

    /// @notice List of tokens with accumulated fees
    address[] private _feeTokens;

    /// @notice Mapping to check if token is in list
    mapping(address => bool) private _isFeeToken;

    /// @notice Total XOM fees distributed to staking (for transparency)
    uint256 public totalFeesDistributed;

    /// @notice Total XOM fees sent to liquidity pool (for transparency)
    uint256 public totalFeesToLiquidity;

    /// @notice Epoch counter
    uint256 public currentEpoch;

    /* solhint-disable ordering */
    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Distribution record for transparency
     * @dev Stored on-chain for auditability
     */
    struct DistributionRecord {
        /// @notice Distribution epoch number
        uint256 epoch;
        /// @notice Timestamp of distribution
        uint256 timestamp;
        /// @notice Amount sent to staking pool
        uint256 toStaking;
        /// @notice Amount sent to liquidity pool
        uint256 toLiquidity;
        /// @notice Tokens distributed
        address[] tokens;
        /// @notice Amounts of each token distributed
        uint256[] amounts;
    }

    /// @notice Maximum distribution history entries retained on-chain
    /// @dev Older records are available via FeesDistributed events.
    ///      At 6-hour intervals, 1000 entries covers ~250 days.
    uint256 public constant MAX_DISTRIBUTION_HISTORY = 1000;

    /// @notice Distribution history (circular buffer, capped at MAX)
    DistributionRecord[] public distributionHistory;
    /* solhint-enable ordering */

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when fees are received and tracked
    /// @param token Token address
    /// @param amount Fee amount
    /// @param from Sender address
    event FeesCollected(
        address indexed token,
        uint256 indexed amount,
        address indexed from
    );

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when fees are distributed to pools
    /// @param epoch Distribution epoch
    /// @param toStaking Amount sent to staking
    /// @param toLiquidity Amount sent to liquidity pool
    /// @param timestamp Distribution timestamp
    event FeesDistributed(
        uint256 indexed epoch,
        uint256 indexed toStaking,
        uint256 indexed toLiquidity,
        uint256 timestamp
    );
    /* solhint-enable gas-indexed-events */

    /// @notice Emitted when a distribution transfer fails
    /// @param recipient Staking or liquidity pool that rejected transfer
    /// @param amount Amount that failed to transfer
    event DistributionTransferFailed(
        address indexed recipient,
        uint256 indexed amount
    );

    /// @notice Emitted when non-XOM tokens are rescued by admin
    /// @param token Rescued token address
    /// @param amount Amount rescued
    /// @param recipient Recipient address
    event TokensRescued(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when caller is not AMM
    error NotAMM();

    /// @notice Thrown when caller is not admin
    error NotAdmin();

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

    /// @notice Thrown when trying to rescue XOM (use distribute instead)
    error CannotRescueXOM();

    /// @notice Thrown when maximum tracked fee tokens is reached
    error MaxFeeTokensReached();

    /// @notice Maximum number of tracked fee tokens
    uint256 public constant MAX_FEE_TOKENS = 200;

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

    /**
     * @notice Only admin can call
     */
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAdmin();
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
     * @param _liquidityPool Liquidity pool address
     * @param _admin Admin address for token rescue
     */
    constructor(
        address _xomToken,
        address _stakingPool,
        address _ammContract,
        address _liquidityPool,
        address _admin
    ) {
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_ammContract == address(0)) revert ZeroAddress();
        if (_liquidityPool == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        XOM_TOKEN = _xomToken;
        STAKING_POOL = _stakingPool;
        AMM_CONTRACT = _ammContract;
        LIQUIDITY_POOL = _liquidityPool;
        ADMIN = _admin;

        // solhint-disable-next-line not-rely-on-time
        lastDistributionTime = block.timestamp;
    }

    // ========================================================================
    // FEE COLLECTION
    // ========================================================================

    /**
     * @notice Collect fees from AMM swaps via transferFrom
     * @dev Called by AMM contract after each swap. Pulls tokens from AMM.
     * @param token Fee token address
     * @param amount Fee amount
     */
    function collectFees(
        address token,
        uint256 amount
    ) external onlyAMM nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        IERC20(token).safeTransferFrom(
            msg.sender, address(this), amount
        );

        _trackFee(token, amount, msg.sender);
    }

    /**
     * @inheritdoc IRWAFeeCollector
     * @dev Called by RWAAMM after direct safeTransferFrom to this contract.
     *      Updates internal accounting without requiring another transfer.
     *      Only callable by the AMM contract.
     */
    function notifyFeeReceived(
        address token,
        uint256 amount
    ) external override onlyAMM {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        _trackFee(token, amount, msg.sender);
    }

    /**
     * @notice Receive fees directly (for manual deposits)
     * @dev Restricted to admin to prevent accounting pollution.
     *      Without access control, anyone could deposit 1 wei of
     *      arbitrary tokens to grow _feeTokens unboundedly or
     *      front-run distribute() to manipulate amounts.
     * @param token Fee token address
     * @param amount Fee amount
     */
    function receiveFees(
        address token,
        uint256 amount
    ) external onlyAdmin nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        IERC20(token).safeTransferFrom(
            msg.sender, address(this), amount
        );

        _trackFee(token, amount, msg.sender);
    }

    // ========================================================================
    // FEE DISTRIBUTION
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Distribute accumulated XOM fees to staking and liquidity pools
     * @dev Can be called by anyone after the distribution interval.
     *      Splits the XOM balance: 2/3 to staking, 1/3 to liquidity.
     *      This represents the 20%/10% split of the total protocol fee
     *      (the 70% LP portion stays in pools, never reaches this contract).
     */
    function distribute() external nonReentrant {
    /* solhint-enable code-complexity */
        // solhint-disable-next-line not-rely-on-time
        uint256 nextDistribution =
            lastDistributionTime + DISTRIBUTION_INTERVAL;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nextDistribution) {
            revert DistributionNotDue(nextDistribution);
        }

        uint256 xomBalance = IERC20(XOM_TOKEN).balanceOf(address(this));
        if (xomBalance == 0) revert NoFeesToDistribute();

        // Split: staking gets 2/3, liquidity gets 1/3
        uint256 stakingAmount = (xomBalance * FEE_STAKING_BPS)
            / (FEE_STAKING_BPS + FEE_LIQUIDITY_BPS);
        uint256 liquidityAmount = xomBalance - stakingAmount;

        // Distribute to staking pool (try/catch to prevent DoS
        // if staking pool contract reverts).
        // Note: nonReentrant modifier protects against reentrancy;
        // state changes after transfer are safe.
        /* solhint-disable reentrancy */
        bool stakingSuccess;
        if (stakingAmount > 0) {
            // solhint-disable-next-line no-empty-blocks
            try IERC20(XOM_TOKEN).transfer(
                STAKING_POOL, stakingAmount
            ) returns (bool result) {
                stakingSuccess = result;
            } catch {
                stakingSuccess = false;
            }
            if (stakingSuccess) {
                totalFeesDistributed += stakingAmount;
            } else {
                emit DistributionTransferFailed(
                    STAKING_POOL, stakingAmount
                );
            }
        }

        // Distribute to liquidity pool (try/catch to prevent DoS
        // if liquidity pool contract reverts)
        bool liquiditySuccess;
        if (liquidityAmount > 0) {
            // solhint-disable-next-line no-empty-blocks
            try IERC20(XOM_TOKEN).transfer(
                LIQUIDITY_POOL, liquidityAmount
            ) returns (bool result) {
                liquiditySuccess = result;
            } catch {
                liquiditySuccess = false;
            }
            if (liquiditySuccess) {
                totalFeesToLiquidity += liquidityAmount;
            } else {
                emit DistributionTransferFailed(
                    LIQUIDITY_POOL, liquidityAmount
                );
            }
        }

        // Record distribution
        ++currentEpoch;
        // solhint-disable-next-line not-rely-on-time
        lastDistributionTime = block.timestamp;

        address[] memory tokens = new address[](1);
        tokens[0] = XOM_TOKEN;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = xomBalance;

        DistributionRecord memory record = DistributionRecord({
            epoch: currentEpoch,
            // solhint-disable-next-line not-rely-on-time
            timestamp: block.timestamp,
            toStaking: stakingAmount,
            toLiquidity: liquidityAmount,
            tokens: tokens,
            amounts: amounts
        });

        // Circular buffer: overwrite oldest when at capacity
        if (distributionHistory.length < MAX_DISTRIBUTION_HISTORY) {
            distributionHistory.push(record);
        } else {
            uint256 idx = currentEpoch % MAX_DISTRIBUTION_HISTORY;
            distributionHistory[idx] = record;
        }
        /* solhint-enable reentrancy */

        /* solhint-disable not-rely-on-time */
        emit FeesDistributed(
            currentEpoch, stakingAmount,
            liquidityAmount, block.timestamp
        );
        /* solhint-enable not-rely-on-time */
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Rescue non-XOM tokens that are stranded in this contract
     * @dev Only callable by admin. Cannot rescue XOM (use distribute).
     *      This prevents permanent loss of non-XOM fee tokens in this
     *      non-upgradeable contract.
     * @param token Token address to rescue
     * @param recipient Address to receive rescued tokens
     */
    function rescueTokens(
        address token,
        address recipient
    ) external onlyAdmin nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (token == XOM_TOKEN) revert CannotRescueXOM();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(recipient, balance);

        emit TokensRescued(token, balance, recipient);
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
     * @return Accumulated fee amount (cumulative total)
     */
    function getAccumulatedFee(
        address token
    ) external view returns (uint256) {
        return accumulatedFees[token];
    }

    /**
     * @notice Get time until next distribution
     * @return Seconds until next distribution (0 if due)
     */
    function timeUntilNextDistribution()
        external view returns (uint256)
    {
        uint256 nextDistribution =
            lastDistributionTime + DISTRIBUTION_INTERVAL;
        /* solhint-disable-next-line not-rely-on-time, gas-strict-inequalities */
        if (block.timestamp >= nextDistribution) return 0;
        // solhint-disable-next-line not-rely-on-time
        return nextDistribution - block.timestamp;
    }

    /**
     * @notice Get distribution history count
     * @return Number of distribution records
     */
    function getDistributionCount()
        external view returns (uint256)
    {
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
        // solhint-disable-next-line gas-strict-inequalities
        if (index >= distributionHistory.length) {
            revert IndexOutOfBounds(index, distributionHistory.length);
        }
        return distributionHistory[index];
    }

    /**
     * @notice Get total XOM ready for distribution
     * @return Total XOM balance held by this contract
     */
    function getPendingDistribution()
        external view returns (uint256)
    {
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

        toStaking = (xomBalance * FEE_STAKING_BPS)
            / (FEE_STAKING_BPS + FEE_LIQUIDITY_BPS);
        toLiquidity = xomBalance - toStaking;
    }

    /**
     * @notice Check if distribution is currently due
     * @return True if distribution can be triggered
     */
    function isDistributionDue() external view returns (bool) {
        /* solhint-disable-next-line not-rely-on-time, gas-strict-inequalities */
        return block.timestamp >=
            lastDistributionTime + DISTRIBUTION_INTERVAL;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Track fee receipt in internal accounting
     * @dev Updates accumulatedFees and _feeTokens list, emits event
     * @param token Fee token address
     * @param amount Fee amount received
     * @param from Source of the fee
     */
    function _trackFee(
        address token,
        uint256 amount,
        address from
    ) private {
        accumulatedFees[token] += amount;

        if (!_isFeeToken[token]) {
            // solhint-disable-next-line gas-strict-inequalities
            if (_feeTokens.length >= MAX_FEE_TOKENS) {
                revert MaxFeeTokensReached();
            }
            _feeTokens.push(token);
            _isFeeToken[token] = true;
        }

        emit FeesCollected(token, amount, from);
    }
}
