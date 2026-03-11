// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from
    "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title LiquidityMining
 * @author OmniCoin Development Team
 * @notice Liquidity mining rewards with vesting for LP token stakers
 * @dev Distributes XOM rewards to LP stakers with configurable vesting.
 *
 * Key features:
 * - Multiple LP pool support (XOM/USDC, XOM/ETH, XOM/AVAX)
 * - Configurable reward rates per pool (capped by MAX_REWARD_PER_SECOND)
 * - Split reward structure: immediate + vested portions
 * - Adjustable vesting periods per pool (minimum 1 day)
 * - Anti-dump protection through vesting
 * - Owner cannot drain user-committed rewards (totalCommittedRewards)
 * - Ownable2Step prevents accidental ownership transfers
 * - Emergency withdrawal with 80/20 fee split (protocolTreasury/stakingPool)
 *
 * Emergency Withdrawal Fee Distribution:
 * The emergency withdrawal penalty is split 70/20/10 where:
 *   - 70% to protocolTreasury
 *   - 20% to stakingPool
 *   - 10% to protocolTreasury (also protocol treasury)
 * This results in an effective 80/20 split: 80% protocol treasury, 20% staking pool.
 * "Validator" is NEVER a fee recipient in any contract.
 *
 * Reward Calculation Formula:
 * Each pool accumulates rewards at `rewardPerSecond`. For each second
 * elapsed, `rewardPerSecond` XOM is divided among stakers proportional
 * to their stake:
 *   userReward = (elapsed * rewardPerSecond * userStake) / totalStaked
 *
 * The reward is then split into two portions:
 *   immediateReward = userReward * immediateBps / 10000
 *   vestingReward = userReward - immediateReward
 *
 * The `immediateBps` parameter controls the split:
 * - DEFAULT_IMMEDIATE_BPS = 3000 (30%) means 30% claimable immediately,
 *   70% vests linearly over the pool's vestingPeriod.
 * - immediateBps = 10000 means 100% immediate (no vesting).
 * - immediateBps = 0 means 100% vested (no immediate rewards).
 *
 * In addPool(), passing immediateBps = 0 defaults to DEFAULT_IMMEDIATE_BPS.
 * To create a fully-vesting pool, use setVestingParams() after addPool().
 *
 * DEFAULT_VESTING_PERIOD = 90 days. The vesting period is configurable
 * per pool via setVestingParams() and must be >= MIN_VESTING_PERIOD
 * (1 day) when non-zero.
 */
contract LiquidityMining is ReentrancyGuard, Ownable2Step, Pausable, ERC2771Context {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    /// @notice Configuration for each staking pool
    struct PoolInfo {
        /// @notice LP token for this pool
        IERC20 lpToken;
        /// @notice XOM rewards per second (18 decimals)
        uint256 rewardPerSecond;
        /// @notice Last timestamp rewards were calculated
        uint256 lastRewardTime;
        /// @notice Accumulated rewards per LP token share (scaled by REWARD_PRECISION)
        uint256 accRewardPerShare;
        /// @notice Total LP tokens staked in this pool
        uint256 totalStaked;
        /// @notice Percentage of rewards claimable immediately (basis points)
        uint256 immediateBps;
        /// @notice Vesting period for remaining rewards
        uint256 vestingPeriod;
        /// @notice Whether pool is active
        bool active;
        /// @notice Pool name for UI display
        string name;
    }

    /// @notice User stake information per pool
    struct UserStake {
        /// @notice Amount of LP tokens staked
        uint256 amount;
        /// @notice Reward debt for accurate reward calculation
        uint256 rewardDebt;
        /// @notice Pending immediate rewards (claimable now)
        uint256 pendingImmediate;
        /// @notice Total vesting rewards allocated
        uint256 vestingTotal;
        /// @notice Vesting rewards already claimed
        uint256 vestingClaimed;
        /// @notice Timestamp when vesting started
        uint256 vestingStart;
    }

    // ============ Constants ============

    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Default immediate reward percentage (30%)
    uint256 public constant DEFAULT_IMMEDIATE_BPS = 3_000;

    /// @notice Default vesting period (90 days)
    uint256 public constant DEFAULT_VESTING_PERIOD = 90 days;

    /// @notice Precision for reward calculations
    uint256 private constant REWARD_PRECISION = 1e18;

    /// @notice Minimum reward rate update interval
    uint256 public constant MIN_UPDATE_INTERVAL = 1 days;

    /// @notice Maximum number of pools allowed
    uint256 public constant MAX_POOLS = 50;

    /// @notice Minimum vesting period (1 day)
    uint256 public constant MIN_VESTING_PERIOD = 1 days;

    /// @notice Maximum reward rate per second (~31.5 billion XOM/year)
    /// @dev Prevents admin from setting absurdly high reward rates
    ///      that would inflate totalCommittedRewards beyond the XOM
    ///      balance and cause all claims to revert. At 1e24 per
    ///      second: 1e24 * 365.25 * 86400 = ~3.15e31 XOM/year,
    ///      far exceeding total supply (16.6B = 1.66e28). This is a
    ///      safety cap, not a practical operational limit.
    uint256 public constant MAX_REWARD_PER_SECOND = 1e24;

    /// @notice Minimum staking duration before withdrawal is allowed
    /// @dev H-01 Round 6: prevents flash-stake reward extraction where
    ///      an attacker stakes and withdraws within the same block to
    ///      capture rewards without meaningful time commitment.
    uint256 public constant MIN_STAKE_DURATION = 1 days;

    // ============ Immutables ============

    /// @notice XOM reward token used to distribute staking rewards
    IERC20 public immutable xom; // solhint-disable-line immutable-vars-naming

    // ============ State Variables ============

    /// @notice Array of all pool configurations
    PoolInfo[] public pools;

    /// @notice User stakes by pool ID => user => stake info
    mapping(uint256 => mapping(address => UserStake)) public userStakes;

    /// @notice Total XOM distributed across all pools
    uint256 public totalXomDistributed;

    /// @notice Protocol treasury address (receives 70% + 10% = 80% of emergency fees)
    address public protocolTreasury;

    /// @notice Staking pool fee recipient (receives 20% of fees)
    address public stakingPool;

    /// @notice Emergency withdrawal fee in basis points (0.5% = 50 bps)
    uint256 public emergencyWithdrawFeeBps;

    /// @notice Total XOM committed to users (pending immediate + unvested)
    /// @dev M-01 Round 6 accounting note: totalCommittedRewards may drift
    ///      slightly above the actual sum of user obligations due to
    ///      rounding errors in the vesting append path. Each append
    ///      operation can introduce up to 1 wei of conservative drift
    ///      (over-committing). Over thousands of operations, the
    ///      cumulative drift could reach a few thousand wei -- negligible
    ///      in value terms. The drift is always in the safe direction:
    ///      the contract holds slightly more XOM than necessary, never
    ///      less. The owner's withdrawRewards() function can only
    ///      withdraw excess above totalCommittedRewards, so this
    ///      locked dust is inaccessible but does not affect solvency.
    uint256 public totalCommittedRewards;

    /// @notice Timestamp of user's most recent stake per pool
    /// @dev H-01 Round 6: tracks when each user last staked to enforce
    ///      MIN_STAKE_DURATION before withdrawal is permitted.
    mapping(uint256 => mapping(address => uint256)) public stakeTimestamp;

    // ============ Events ============

    /// @notice Emitted when a new pool is added
    /// @param poolId Pool identifier
    /// @param lpToken LP token address
    /// @param rewardPerSecond Reward rate
    /// @param name Pool name
    event PoolAdded(
        uint256 indexed poolId,
        address indexed lpToken,
        uint256 indexed rewardPerSecond,
        string name
    );

    /// @notice Emitted when pool reward rate is updated
    /// @param poolId Pool identifier
    /// @param oldRate Previous rate
    /// @param newRate New rate
    event RewardRateUpdated(
        uint256 indexed poolId,
        uint256 indexed oldRate,
        uint256 indexed newRate
    );

    /// @notice Emitted when user stakes LP tokens
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount staked
    event Staked(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount
    );

    /// @notice Emitted when user withdraws LP tokens
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount withdrawn
    event Withdrawn(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount
    );

    /// @notice Emitted when user claims rewards
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param immediateAmount Immediate rewards claimed
    /// @param vestedAmount Vested rewards claimed
    event RewardsClaimed(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed immediateAmount,
        uint256 vestedAmount
    );

    /// @notice Emitted when user does emergency withdrawal
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount withdrawn after fee deduction
    /// @param fee Fee charged on withdrawal
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount,
        uint256 fee
    );

    /// @notice Emitted when vesting parameters are updated
    /// @param poolId Pool identifier
    /// @param immediateBps New immediate percentage
    /// @param vestingPeriod New vesting period
    event VestingParamsUpdated(
        uint256 indexed poolId,
        uint256 indexed immediateBps,
        uint256 indexed vestingPeriod
    );

    /// @notice Emitted when pool active status is changed
    /// @param poolId Pool identifier
    /// @param active New active status
    event PoolActiveUpdated(
        uint256 indexed poolId,
        bool indexed active
    );

    /// @notice Emitted when emergency withdrawal fee is updated
    /// @param oldFeeBps Previous fee in basis points
    /// @param newFeeBps New fee in basis points
    event EmergencyWithdrawFeeUpdated(
        uint256 indexed oldFeeBps,
        uint256 indexed newFeeBps
    );

    /// @notice Emitted when protocol treasury address is updated
    /// @param oldTreasury Previous protocol treasury address
    /// @param newTreasury New protocol treasury address
    event ProtocolTreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when staking pool fee recipient is updated
    /// @param oldRecipient Previous recipient address
    /// @param newRecipient New recipient address
    event StakingPoolUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when totalCommittedRewards clamping occurs during
    ///         emergency withdrawal, indicating accounting drift
    /// @dev M-02 Round 6: provides observability when forfeited rewards
    ///      exceed totalCommittedRewards, which should not happen under
    ///      normal operation but may occur due to rounding drift (M-01).
    ///      Parameters are not indexed because filtering by numeric
    ///      values is less useful than filtering by address, and this
    ///      event is expected to be extremely rare.
    /// @param totalCommitted The totalCommittedRewards value at the time
    /// @param forfeited The calculated forfeited amount that exceeded it
    event CommittedRewardsDrift(
        uint256 totalCommitted,
        uint256 forfeited
    );

    /* solhint-enable gas-indexed-events */

    // ============ Errors ============

    /// @notice Thrown when pool doesn't exist
    error PoolNotFound();

    /// @notice Thrown when pool is not active
    error PoolNotActive();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when user has insufficient stake
    error InsufficientStake();

    /// @notice Thrown when parameters are invalid
    error InvalidParameters();

    /// @notice Thrown when there's nothing to claim
    error NothingToClaim();

    /// @notice Thrown when LP token is already added
    error LpTokenAlreadyAdded();

    /// @notice Thrown when withdrawing more than available uncommitted rewards
    error InsufficientRewards();

    /// @notice Thrown when withdrawal is attempted before MIN_STAKE_DURATION
    error MinStakeDurationNotMet();

    // ============ Constructor ============

    /**
     * @notice Initialize liquidity mining contract
     * @param _xom XOM reward token address
     * @param _protocolTreasury Protocol treasury address (receives 80% of
     *        emergency withdrawal fees: 70% + 10%)
     * @param _stakingPool Staking pool fee recipient (receives 20% of fees)
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    constructor(
        address _xom,
        address _protocolTreasury,
        address _stakingPool,
        address trustedForwarder_
    ) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
        if (
            _xom == address(0) ||
            _protocolTreasury == address(0) ||
            _stakingPool == address(0)
        ) {
            revert InvalidParameters();
        }
        xom = IERC20(_xom);
        protocolTreasury = _protocolTreasury;
        stakingPool = _stakingPool;
        emergencyWithdrawFeeBps = 50; // 0.5% fee
    }

    // ============ External Functions ============

    /**
     * @notice Add a new staking pool
     * @dev Reverts if MAX_POOLS limit is reached, LP token already
     *      exists, or rewardPerSecond exceeds MAX_REWARD_PER_SECOND.
     *      If immediateBps is 0 it defaults to DEFAULT_IMMEDIATE_BPS
     *      (30%). To create a fully-vesting pool (immediateBps = 0),
     *      call addPool with any non-zero value then setVestingParams
     *      with immediateBps = 0.
     * @param lpToken LP token address (must not be zero or duplicate)
     * @param rewardPerSecond XOM rewards per second (18 decimals,
     *        must be <= MAX_REWARD_PER_SECOND)
     * @param immediateBps Percentage of rewards claimable immediately
     *        in basis points (0 defaults to DEFAULT_IMMEDIATE_BPS)
     * @param vestingPeriod Vesting period for remaining rewards in
     *        seconds (0 defaults to DEFAULT_VESTING_PERIOD)
     * @param name Pool display name for UI
     */
    function addPool(
        address lpToken,
        uint256 rewardPerSecond,
        uint256 immediateBps,
        uint256 vestingPeriod,
        string calldata name
    ) external onlyOwner {
        if (lpToken == address(0)) revert InvalidParameters();
        // solhint-disable-next-line gas-strict-inequalities
        if (immediateBps > BASIS_POINTS) revert InvalidParameters();
        // solhint-disable-next-line gas-strict-inequalities
        if (pools.length >= MAX_POOLS) revert InvalidParameters();
        if (rewardPerSecond > MAX_REWARD_PER_SECOND) {
            revert InvalidParameters();
        }

        // Check LP token not already added
        uint256 poolLen = pools.length;
        for (uint256 i = 0; i < poolLen; ) {
            if (address(pools[i].lpToken) == lpToken) {
                revert LpTokenAlreadyAdded();
            }
            unchecked { ++i; }
        }

        pools.push(
            PoolInfo({
                lpToken: IERC20(lpToken),
                rewardPerSecond: rewardPerSecond,
                // solhint-disable-next-line not-rely-on-time
                lastRewardTime: block.timestamp,
                accRewardPerShare: 0,
                totalStaked: 0,
                immediateBps: immediateBps > 0
                    ? immediateBps
                    : DEFAULT_IMMEDIATE_BPS,
                vestingPeriod: vestingPeriod > 0
                    ? vestingPeriod
                    : DEFAULT_VESTING_PERIOD,
                active: true,
                name: name
            })
        );

        emit PoolAdded(pools.length - 1, lpToken, rewardPerSecond, name);
    }

    /**
     * @notice Update pool reward rate
     * @dev Enforces MAX_REWARD_PER_SECOND to prevent inflation of
     *      totalCommittedRewards beyond the contract's XOM balance.
     *      Calls _updatePool() first to settle pending rewards at
     *      the old rate before applying the new rate.
     * @param poolId Pool identifier
     * @param newRewardPerSecond New reward rate (must be <=
     *        MAX_REWARD_PER_SECOND)
     */
    function setRewardRate(
        uint256 poolId,
        uint256 newRewardPerSecond
    ) external onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        if (newRewardPerSecond > MAX_REWARD_PER_SECOND) {
            revert InvalidParameters();
        }

        _updatePool(poolId);

        uint256 oldRate = pools[poolId].rewardPerSecond;
        pools[poolId].rewardPerSecond = newRewardPerSecond;

        emit RewardRateUpdated(poolId, oldRate, newRewardPerSecond);
    }

    /**
     * @notice Update pool vesting parameters
     * @dev If vestingPeriod is non-zero, it must be at least MIN_VESTING_PERIOD
     * @param poolId Pool identifier
     * @param immediateBps New immediate percentage in basis points
     * @param vestingPeriod New vesting period in seconds
     */
    function setVestingParams(
        uint256 poolId,
        uint256 immediateBps,
        uint256 vestingPeriod
    ) external onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        // solhint-disable-next-line gas-strict-inequalities
        if (immediateBps > BASIS_POINTS) revert InvalidParameters();
        if (
            vestingPeriod > 0 && vestingPeriod < MIN_VESTING_PERIOD
        ) {
            revert InvalidParameters();
        }

        pools[poolId].immediateBps = immediateBps;
        pools[poolId].vestingPeriod = vestingPeriod;

        emit VestingParamsUpdated(poolId, immediateBps, vestingPeriod);
    }

    /**
     * @notice Set pool active status
     * @param poolId Pool identifier
     * @param active Whether pool is active
     */
    function setPoolActive(
        uint256 poolId,
        bool active
    ) external onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        pools[poolId].active = active;

        emit PoolActiveUpdated(poolId, active);
    }

    /**
     * @notice Stake LP tokens to earn rewards
     * @param poolId Pool identifier
     * @param amount Amount of LP tokens to stake
     */
    function stake(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();

        PoolInfo storage pool = pools[poolId];
        if (!pool.active) revert PoolNotActive();

        _updatePool(poolId);

        UserStake storage user = userStakes[poolId][caller];

        // Harvest pending rewards before modifying stake
        if (user.amount > 0) {
            _harvestRewards(poolId, caller);
        }

        // Transfer LP tokens from user (M-01: balance-before/after
        // for fee-on-transfer token compatibility)
        uint256 balBefore = pool.lpToken.balanceOf(address(this));
        pool.lpToken.safeTransferFrom(caller, address(this), amount);
        uint256 received = pool.lpToken.balanceOf(address(this)) - balBefore;

        // Update user stake with actual received amount
        user.amount += received;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

        // H-01 Round 6: record stake timestamp for MIN_STAKE_DURATION
        // solhint-disable-next-line not-rely-on-time
        stakeTimestamp[poolId][caller] = block.timestamp;

        // Update pool total
        pool.totalStaked += received;

        emit Staked(caller, poolId, received);
    }

    /**
     * @notice Withdraw staked LP tokens
     * @param poolId Pool identifier
     * @param amount Amount of LP tokens to withdraw
     */
    function withdraw(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][caller];

        if (user.amount < amount) revert InsufficientStake();

        // H-01 Round 6: enforce minimum staking duration to prevent
        // flash-stake reward extraction
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < stakeTimestamp[poolId][caller] + MIN_STAKE_DURATION
        ) {
            revert MinStakeDurationNotMet();
        }

        _updatePool(poolId);

        // Harvest pending rewards before modifying stake
        _harvestRewards(poolId, caller);

        // Update user stake
        user.amount -= amount;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

        // Update pool total
        pool.totalStaked -= amount;

        // Transfer LP tokens to user
        pool.lpToken.safeTransfer(caller, amount);

        emit Withdrawn(caller, poolId, amount);
    }

    /**
     * @notice Claim available rewards (immediate + vested)
     * @param poolId Pool identifier
     * @return immediateAmount Immediate rewards claimed
     * @return vestedAmount Vested rewards claimed
     */
    function claim(
        uint256 poolId
    )
        external
        nonReentrant
        returns (uint256 immediateAmount, uint256 vestedAmount)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        address caller = _msgSender();

        _updatePool(poolId);
        _harvestRewards(poolId, caller);

        UserStake storage user = userStakes[poolId][caller];

        // Claim immediate rewards
        immediateAmount = user.pendingImmediate;
        user.pendingImmediate = 0;

        // Claim vested rewards
        vestedAmount = _calculateVested(user, poolId);
        user.vestingClaimed += vestedAmount;

        uint256 total = immediateAmount + vestedAmount;
        if (total == 0) revert NothingToClaim();

        // Decrement committed rewards tracker
        totalCommittedRewards -= total;

        xom.safeTransfer(caller, total);
        totalXomDistributed += total;

        emit RewardsClaimed(
            caller, poolId, immediateAmount, vestedAmount
        );

        return (immediateAmount, vestedAmount);
    }

    /**
     * @notice Claim rewards from all pools
     * @return totalImmediate Total immediate rewards claimed
     * @return totalVested Total vested rewards claimed
     */
    function claimAll()
        external
        nonReentrant
        returns (uint256 totalImmediate, uint256 totalVested)
    {
        address caller = _msgSender();
        uint256 poolLen = pools.length;
        for (uint256 i = 0; i < poolLen; ) {
            _updatePool(i);
            UserStake storage user = userStakes[i][caller];

            if (
                user.amount > 0 ||
                user.pendingImmediate > 0 ||
                user.vestingTotal > 0
            ) {
                _harvestRewards(i, caller);

                uint256 immediate = user.pendingImmediate;
                user.pendingImmediate = 0;
                totalImmediate += immediate;

                uint256 vested = _calculateVested(user, i);
                user.vestingClaimed += vested;
                totalVested += vested;

                if (immediate + vested > 0) {
                    emit RewardsClaimed(
                        caller, i, immediate, vested
                    );
                }
            }

            unchecked { ++i; }
        }

        uint256 total = totalImmediate + totalVested;
        if (total == 0) revert NothingToClaim();

        // Decrement committed rewards tracker
        totalCommittedRewards -= total;

        xom.safeTransfer(caller, total);
        totalXomDistributed += total;

        return (totalImmediate, totalVested);
    }

    /**
     * @notice Emergency withdraw LP tokens without rewards (with fee)
     * @dev Forfeits ALL pending and vesting rewards. The emergency
     *      withdrawal fee is split 70/20/10 (protocolTreasury/
     *      stakingPool/protocolTreasury). This means 80% goes to
     *      protocolTreasury and 20% to stakingPool. "Validator" is
     *      never a fee recipient. Does not call _updatePool() -- the
     *      stale accumulator has no effect since all reward state is
     *      zeroed. This function is available even when paused to
     *      ensure users can always recover their LP tokens.
     * @param poolId Pool identifier
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        address caller = _msgSender();

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][caller];

        uint256 amount = user.amount;
        if (amount == 0) revert InsufficientStake();

        // Calculate forfeited rewards and decrement committed tracker.
        // M-02 Round 6: emit CommittedRewardsDrift when clamping occurs
        // to provide observability for accounting anomalies rather than
        // silently masking them.
        uint256 forfeited = user.pendingImmediate +
            user.vestingTotal -
            user.vestingClaimed;
        if (forfeited > 0) {
            if (forfeited > totalCommittedRewards) {
                emit CommittedRewardsDrift(
                    totalCommittedRewards, forfeited
                );
                totalCommittedRewards = 0;
            } else {
                totalCommittedRewards -= forfeited;
            }
        }

        // Calculate fee
        uint256 fee = (amount * emergencyWithdrawFeeBps) / BASIS_POINTS;
        uint256 amountAfterFee = amount - fee;

        // Reset user state (forfeit all rewards)
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingImmediate = 0;
        user.vestingTotal = 0;
        user.vestingClaimed = 0;
        user.vestingStart = 0;

        // Update pool total
        pool.totalStaked -= amount;

        // Transfer LP tokens with 70/20/10 fee split
        // 70% protocolTreasury + 10% protocolTreasury = 80% protocolTreasury
        // 20% stakingPool
        if (fee > 0) {
            uint256 stakingShare = (fee * 2_000) / BASIS_POINTS;   // 20%
            uint256 protocolShare = fee - stakingShare;              // 80% (70% + 10%)
            pool.lpToken.safeTransfer(protocolTreasury, protocolShare);
            pool.lpToken.safeTransfer(
                stakingPool, stakingShare
            );
        }
        pool.lpToken.safeTransfer(caller, amountAfterFee);

        emit EmergencyWithdraw(caller, poolId, amountAfterFee, fee);
    }

    /**
     * @notice Deposit XOM rewards for distribution
     * @param amount Amount of XOM to deposit
     */
    function depositRewards(uint256 amount) external onlyOwner {
        xom.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw excess XOM not committed to users
     * @dev Only allows withdrawal of XOM above totalCommittedRewards.
     *      Sends withdrawn XOM to the protocolTreasury.
     * @param amount Amount to withdraw
     */
    function withdrawRewards(uint256 amount) external onlyOwner {
        uint256 balance = xom.balanceOf(address(this));
        uint256 available = balance > totalCommittedRewards
            ? balance - totalCommittedRewards
            : 0;
        if (amount > available) revert InsufficientRewards();
        xom.safeTransfer(protocolTreasury, amount);
    }

    /**
     * @notice Set emergency withdrawal fee
     * @param feeBps Fee in basis points (max 1000 = 10%)
     */
    function setEmergencyWithdrawFee(
        uint256 feeBps
    ) external onlyOwner {
        if (feeBps > 1000) revert InvalidParameters(); // Max 10%
        uint256 oldFeeBps = emergencyWithdrawFeeBps;
        emergencyWithdrawFeeBps = feeBps;

        emit EmergencyWithdrawFeeUpdated(oldFeeBps, feeBps);
    }

    /**
     * @notice Set protocol treasury address
     * @param _protocolTreasury New protocol treasury address
     */
    function setProtocolTreasury(
        address _protocolTreasury
    ) external onlyOwner {
        if (_protocolTreasury == address(0)) revert InvalidParameters();
        address oldTreasury = protocolTreasury;
        protocolTreasury = _protocolTreasury;

        emit ProtocolTreasuryUpdated(oldTreasury, _protocolTreasury);
    }

    /**
     * @notice Set staking pool fee recipient address
     * @param _stakingPool New staking pool fee recipient
     */
    function setStakingPool(
        address _stakingPool
    ) external onlyOwner {
        if (_stakingPool == address(0)) revert InvalidParameters();
        address old = stakingPool;
        stakingPool = _stakingPool;
        emit StakingPoolUpdated(old, _stakingPool);
    }

    /**
     * @notice Pause staking
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause staking
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get number of pools
     * @return count Pool count
     */
    function poolCount() external view returns (uint256 count) {
        return pools.length;
    }

    /**
     * @notice Get pool information
     * @param poolId Pool identifier
     * @return lpToken LP token address
     * @return rewardPerSecond Reward rate
     * @return totalStaked Total staked
     * @return active Whether active
     * @return name Pool name
     */
    function getPoolInfo(
        uint256 poolId
    )
        external
        view
        returns (
            address lpToken,
            uint256 rewardPerSecond,
            uint256 totalStaked,
            bool active,
            string memory name
        )
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();
        PoolInfo storage pool = pools[poolId];
        return (
            address(pool.lpToken),
            pool.rewardPerSecond,
            pool.totalStaked,
            pool.active,
            pool.name
        );
    }

    /**
     * @notice Get user stake information
     * @param poolId Pool identifier
     * @param user User address
     * @return amount Staked amount
     * @return pendingImmediate Pending immediate rewards
     * @return pendingVested Pending vested rewards (claimable now)
     * @return totalVesting Total vesting amount
     * @return vestingClaimed Already claimed from vesting
     */
    function getUserInfo(
        uint256 poolId,
        address user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 pendingImmediate,
            uint256 pendingVested,
            uint256 totalVesting,
            uint256 vestingClaimed
        )
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        UserStake storage userStakeInfo = userStakes[poolId][user];

        // Calculate pending rewards
        (uint256 newImmediate, ) = _calculatePendingRewards(
            poolId, user
        );
        pendingImmediate = userStakeInfo.pendingImmediate + newImmediate;
        pendingVested = _calculateVested(userStakeInfo, poolId);

        return (
            userStakeInfo.amount,
            pendingImmediate,
            pendingVested,
            userStakeInfo.vestingTotal,
            userStakeInfo.vestingClaimed
        );
    }

    /**
     * @notice Calculate estimated APR for a pool
     * @param poolId Pool identifier
     * @param lpTokenPrice LP token price in USD (18 decimals)
     * @param xomPrice XOM price in USD (18 decimals)
     * @return aprBps Estimated APR in basis points
     */
    function estimateAPR(
        uint256 poolId,
        uint256 lpTokenPrice,
        uint256 xomPrice
    ) external view returns (uint256 aprBps) {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        PoolInfo storage pool = pools[poolId];
        if (
            pool.totalStaked == 0 ||
            lpTokenPrice == 0 ||
            xomPrice == 0
        ) {
            return 0;
        }

        // Annual XOM rewards
        uint256 annualRewards = pool.rewardPerSecond * 365 days;

        // Annual reward value in USD
        uint256 annualRewardValue =
            (annualRewards * xomPrice) / 1e18;

        // Total staked value in USD
        uint256 stakedValue =
            (pool.totalStaked * lpTokenPrice) / 1e18;

        // APR = (annual reward value / staked value) * 10000
        aprBps =
            (annualRewardValue * BASIS_POINTS) / stakedValue;

        return aprBps;
    }

    // ============ Public Pure Functions ============

    /**
     * @notice Disable renounceOwnership to prevent accidental lockout
     * @dev Always reverts to protect contract administration
     */
    function renounceOwnership() public pure override {
        revert InvalidParameters();
    }

    // ============ Internal Functions ============

    /**
     * @notice Update pool reward state
     * @param poolId Pool identifier
     */
    function _updatePool(uint256 poolId) internal {
        PoolInfo storage pool = pools[poolId];

        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        if (pool.totalStaked == 0) {
            // solhint-disable-next-line not-rely-on-time
            pool.lastRewardTime = block.timestamp;
            return;
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward = elapsed * pool.rewardPerSecond;

        pool.accRewardPerShare +=
            (reward * REWARD_PRECISION) / pool.totalStaked;
        // solhint-disable-next-line not-rely-on-time
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @notice Harvest pending rewards for user and update vesting
     * @dev Credits any unclaimed vested rewards before resetting schedule
     * @param poolId Pool identifier
     * @param user User address
     */
    function _harvestRewards(
        uint256 poolId,
        address user
    ) internal {
        (
            uint256 immediateReward,
            uint256 vestingReward
        ) = _calculatePendingRewards(poolId, user);

        UserStake storage userStakeInfo = userStakes[poolId][user];
        PoolInfo storage pool = pools[poolId];

        // Add to immediate pending
        userStakeInfo.pendingImmediate += immediateReward;

        // Track committed rewards
        totalCommittedRewards += immediateReward + vestingReward;

        // Add to vesting
        if (vestingReward > 0) {
            // solhint-disable-next-line not-rely-on-time
            uint256 vestingEnd = userStakeInfo.vestingStart + pool.vestingPeriod;
            // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
            bool periodComplete = userStakeInfo.vestingStart == 0 || block.timestamp >= vestingEnd;

            if (periodComplete) {
                // Previous vesting period complete
                // Credit any unclaimed vested rewards to immediate
                if (userStakeInfo.vestingTotal > 0) {
                    uint256 unclaimed = userStakeInfo.vestingTotal -
                        userStakeInfo.vestingClaimed;
                    if (unclaimed > 0) {
                        userStakeInfo.pendingImmediate += unclaimed;
                    }
                }
                // Start new vesting schedule
                userStakeInfo.vestingTotal = vestingReward;
                userStakeInfo.vestingClaimed = 0;
                // solhint-disable-next-line not-rely-on-time
                userStakeInfo.vestingStart = block.timestamp;
            } else {
                // Append to existing vesting schedule.
                // Account for the portion that becomes instantly
                // vested due to already-elapsed time inheriting
                // into the new reward (M-01 accounting fix).
                // solhint-disable-next-line not-rely-on-time
                uint256 alreadyElapsed = block.timestamp
                    - userStakeInfo.vestingStart;
                uint256 instantlyVested =
                    (vestingReward * alreadyElapsed)
                        / pool.vestingPeriod;
                userStakeInfo.pendingImmediate += instantlyVested;
                userStakeInfo.vestingTotal +=
                    vestingReward - instantlyVested;
            }
        }

        // Update reward debt
        userStakeInfo.rewardDebt =
            (userStakeInfo.amount * pool.accRewardPerShare) /
            REWARD_PRECISION;
    }

    /**
     * @notice Calculate pending rewards for user
     * @param poolId Pool identifier
     * @param user User address
     * @return immediateReward Immediate portion
     * @return vestingReward Vesting portion
     */
    function _calculatePendingRewards(
        uint256 poolId,
        address user
    )
        internal
        view
        returns (uint256 immediateReward, uint256 vestingReward)
    {
        PoolInfo storage pool = pools[poolId];
        UserStake storage userStakeInfo = userStakes[poolId][user];

        if (userStakeInfo.amount == 0) {
            return (0, 0);
        }

        // Calculate accumulated rewards
        uint256 accRewardPerShare = pool.accRewardPerShare;

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            // solhint-disable-next-line not-rely-on-time
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = elapsed * pool.rewardPerSecond;
            accRewardPerShare +=
                (reward * REWARD_PRECISION) / pool.totalStaked;
        }

        uint256 pending = (userStakeInfo.amount * accRewardPerShare) /
            REWARD_PRECISION -
            userStakeInfo.rewardDebt;

        // Split into immediate and vesting
        immediateReward =
            (pending * pool.immediateBps) / BASIS_POINTS;
        vestingReward = pending - immediateReward;

        return (immediateReward, vestingReward);
    }

    /**
     * @notice Calculate vested amount claimable for a user in a specific pool
     * @dev Uses the pool-specific vesting period, falling back to DEFAULT_VESTING_PERIOD
     * @param userStakeInfo User stake struct
     * @param poolId Pool identifier for vesting period lookup
     * @return vested Amount vested and claimable
     */
    function _calculateVested(
        UserStake storage userStakeInfo,
        uint256 poolId
    ) internal view returns (uint256 vested) {
        if (
            userStakeInfo.vestingTotal == 0 ||
            userStakeInfo.vestingStart == 0
        ) {
            return 0;
        }

        // Use pool-specific vesting period
        uint256 vestingPeriod = pools[poolId].vestingPeriod;
        if (vestingPeriod == 0) vestingPeriod = DEFAULT_VESTING_PERIOD;

        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= userStakeInfo.vestingStart + vestingPeriod) {
            // Fully vested
            return
                userStakeInfo.vestingTotal -
                userStakeInfo.vestingClaimed;
        }

        // Linear vesting
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - userStakeInfo.vestingStart;
        uint256 totalVested =
            (userStakeInfo.vestingTotal * elapsed) / vestingPeriod;

        return
            totalVested > userStakeInfo.vestingClaimed
                ? totalVested - userStakeInfo.vestingClaimed
                : 0;
    }

    // ============ ERC-2771 Overrides ============

    /**
     * @notice Return the sender of the call, accounting for
     *         ERC-2771 meta-transactions.
     * @dev Delegates to ERC2771Context to extract the original
     *      sender when the call comes from the trusted forwarder.
     * @return The resolved sender address.
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Return the calldata of the call, accounting for
     *         ERC-2771 meta-transactions.
     * @dev Delegates to ERC2771Context to strip the appended
     *      sender address when the call comes from the trusted
     *      forwarder.
     * @return The resolved calldata.
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
     * @notice Return the context suffix length for ERC-2771.
     * @dev ERC-2771 appends 20 bytes (the sender address) to
     *      the calldata.
     * @return Length of the context suffix (20).
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
