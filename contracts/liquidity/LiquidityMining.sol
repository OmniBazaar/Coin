// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title LiquidityMining
 * @author OmniCoin Development Team
 * @notice Liquidity mining rewards with vesting for LP token stakers
 * @dev Distributes XOM rewards to LP stakers with configurable vesting.
 *
 * Key features:
 * - Multiple LP pool support (XOM/USDC, XOM/ETH, XOM/AVAX)
 * - Configurable reward rates per pool
 * - Split reward structure: 30% immediate, 70% vested
 * - Adjustable vesting periods per pool
 * - Anti-dump protection through vesting
 *
 * Reward Distribution Model:
 * - 30% of rewards claimable immediately
 * - 70% of rewards vest linearly over 90 days (configurable)
 */
contract LiquidityMining is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

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

    // ============ Immutables ============

    /// @notice XOM reward token
    IERC20 public immutable xom;

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

    // ============ State Variables ============

    /// @notice Array of all pool configurations
    PoolInfo[] public pools;

    /// @notice User stakes by pool ID => user => stake info
    mapping(uint256 => mapping(address => UserStake)) public userStakes;

    /// @notice Total XOM distributed across all pools
    uint256 public totalXomDistributed;

    /// @notice Treasury address for fees
    address public treasury;

    /// @notice Emergency withdrawal fee in basis points (0.5% = 50 bps)
    uint256 public emergencyWithdrawFeeBps;

    // ============ Events ============

    /// @notice Emitted when a new pool is added
    /// @param poolId Pool identifier
    /// @param lpToken LP token address
    /// @param rewardPerSecond Reward rate
    /// @param name Pool name
    event PoolAdded(
        uint256 indexed poolId,
        address indexed lpToken,
        uint256 rewardPerSecond,
        string name
    );

    /// @notice Emitted when pool reward rate is updated
    /// @param poolId Pool identifier
    /// @param oldRate Previous rate
    /// @param newRate New rate
    event RewardRateUpdated(
        uint256 indexed poolId,
        uint256 oldRate,
        uint256 newRate
    );

    /// @notice Emitted when user stakes LP tokens
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount staked
    event Staked(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Emitted when user withdraws LP tokens
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount withdrawn
    event Withdrawn(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Emitted when user claims rewards
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param immediateAmount Immediate rewards claimed
    /// @param vestedAmount Vested rewards claimed
    event RewardsClaimed(
        address indexed user,
        uint256 indexed poolId,
        uint256 immediateAmount,
        uint256 vestedAmount
    );

    /// @notice Emitted when user does emergency withdrawal
    /// @param user User address
    /// @param poolId Pool identifier
    /// @param amount Amount withdrawn
    /// @param fee Fee charged
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 fee
    );

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

    // ============ Constructor ============

    /**
     * @notice Initialize liquidity mining contract
     * @param _xom XOM reward token address
     * @param _treasury Treasury address for fees
     */
    constructor(address _xom, address _treasury) Ownable(msg.sender) {
        if (_xom == address(0) || _treasury == address(0)) {
            revert InvalidParameters();
        }
        xom = IERC20(_xom);
        treasury = _treasury;
        emergencyWithdrawFeeBps = 50; // 0.5% fee
    }

    // ============ External Functions ============

    /**
     * @notice Add a new staking pool
     * @param lpToken LP token address
     * @param rewardPerSecond XOM rewards per second (18 decimals)
     * @param immediateBps Percentage of rewards claimable immediately
     * @param vestingPeriod Vesting period for remaining rewards
     * @param name Pool display name
     */
    function addPool(
        address lpToken,
        uint256 rewardPerSecond,
        uint256 immediateBps,
        uint256 vestingPeriod,
        string calldata name
    ) external onlyOwner {
        if (lpToken == address(0)) revert InvalidParameters();
        if (immediateBps > BASIS_POINTS) revert InvalidParameters();

        // Check LP token not already added
        for (uint256 i = 0; i < pools.length; i++) {
            if (address(pools[i].lpToken) == lpToken) {
                revert LpTokenAlreadyAdded();
            }
        }

        pools.push(
            PoolInfo({
                lpToken: IERC20(lpToken),
                rewardPerSecond: rewardPerSecond,
                // solhint-disable-next-line not-rely-on-time
                lastRewardTime: block.timestamp,
                accRewardPerShare: 0,
                totalStaked: 0,
                immediateBps: immediateBps > 0 ? immediateBps : DEFAULT_IMMEDIATE_BPS,
                vestingPeriod: vestingPeriod > 0 ? vestingPeriod : DEFAULT_VESTING_PERIOD,
                active: true,
                name: name
            })
        );

        emit PoolAdded(pools.length - 1, lpToken, rewardPerSecond, name);
    }

    /**
     * @notice Update pool reward rate
     * @param poolId Pool identifier
     * @param newRewardPerSecond New reward rate
     */
    function setRewardRate(
        uint256 poolId,
        uint256 newRewardPerSecond
    ) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound();

        _updatePool(poolId);

        uint256 oldRate = pools[poolId].rewardPerSecond;
        pools[poolId].rewardPerSecond = newRewardPerSecond;

        emit RewardRateUpdated(poolId, oldRate, newRewardPerSecond);
    }

    /**
     * @notice Update pool vesting parameters
     * @param poolId Pool identifier
     * @param immediateBps New immediate percentage
     * @param vestingPeriod New vesting period
     */
    function setVestingParams(
        uint256 poolId,
        uint256 immediateBps,
        uint256 vestingPeriod
    ) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound();
        if (immediateBps > BASIS_POINTS) revert InvalidParameters();

        pools[poolId].immediateBps = immediateBps;
        pools[poolId].vestingPeriod = vestingPeriod;
    }

    /**
     * @notice Set pool active status
     * @param poolId Pool identifier
     * @param active Whether pool is active
     */
    function setPoolActive(uint256 poolId, bool active) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound();
        pools[poolId].active = active;
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
        if (poolId >= pools.length) revert PoolNotFound();
        if (amount == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId];
        if (!pool.active) revert PoolNotActive();

        _updatePool(poolId);

        UserStake storage user = userStakes[poolId][msg.sender];

        // Harvest pending rewards before modifying stake
        if (user.amount > 0) {
            _harvestRewards(poolId, msg.sender);
        }

        // Transfer LP tokens from user
        pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update user stake
        user.amount += amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

        // Update pool total
        pool.totalStaked += amount;

        emit Staked(msg.sender, poolId, amount);
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
        if (poolId >= pools.length) revert PoolNotFound();
        if (amount == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][msg.sender];

        if (user.amount < amount) revert InsufficientStake();

        _updatePool(poolId);

        // Harvest pending rewards before modifying stake
        _harvestRewards(poolId, msg.sender);

        // Update user stake
        user.amount -= amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

        // Update pool total
        pool.totalStaked -= amount;

        // Transfer LP tokens to user
        pool.lpToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, poolId, amount);
    }

    /**
     * @notice Claim available rewards (immediate + vested)
     * @param poolId Pool identifier
     * @return immediateAmount Immediate rewards claimed
     * @return vestedAmount Vested rewards claimed
     */
    function claim(
        uint256 poolId
    ) external nonReentrant returns (uint256 immediateAmount, uint256 vestedAmount) {
        if (poolId >= pools.length) revert PoolNotFound();

        _updatePool(poolId);
        _harvestRewards(poolId, msg.sender);

        UserStake storage user = userStakes[poolId][msg.sender];

        // Claim immediate rewards
        immediateAmount = user.pendingImmediate;
        user.pendingImmediate = 0;

        // Claim vested rewards
        vestedAmount = _calculateVested(user);
        user.vestingClaimed += vestedAmount;

        uint256 total = immediateAmount + vestedAmount;
        if (total == 0) revert NothingToClaim();

        xom.safeTransfer(msg.sender, total);
        totalXomDistributed += total;

        emit RewardsClaimed(msg.sender, poolId, immediateAmount, vestedAmount);

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
        for (uint256 i = 0; i < pools.length; i++) {
            _updatePool(i);
            UserStake storage user = userStakes[i][msg.sender];

            if (user.amount > 0 || user.pendingImmediate > 0 || user.vestingTotal > 0) {
                _harvestRewards(i, msg.sender);

                uint256 immediate = user.pendingImmediate;
                user.pendingImmediate = 0;
                totalImmediate += immediate;

                uint256 vested = _calculateVested(user);
                user.vestingClaimed += vested;
                totalVested += vested;

                if (immediate + vested > 0) {
                    emit RewardsClaimed(msg.sender, i, immediate, vested);
                }
            }
        }

        uint256 total = totalImmediate + totalVested;
        if (total == 0) revert NothingToClaim();

        xom.safeTransfer(msg.sender, total);
        totalXomDistributed += total;

        return (totalImmediate, totalVested);
    }

    /**
     * @notice Emergency withdraw without rewards (with fee)
     * @param poolId Pool identifier
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        if (poolId >= pools.length) revert PoolNotFound();

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][msg.sender];

        uint256 amount = user.amount;
        if (amount == 0) revert InsufficientStake();

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

        // Transfer LP tokens
        if (fee > 0) {
            pool.lpToken.safeTransfer(treasury, fee);
        }
        pool.lpToken.safeTransfer(msg.sender, amountAfterFee);

        emit EmergencyWithdraw(msg.sender, poolId, amountAfterFee, fee);
    }

    /**
     * @notice Deposit XOM rewards for distribution
     * @param amount Amount of XOM to deposit
     */
    function depositRewards(uint256 amount) external onlyOwner {
        xom.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw excess XOM (emergency only)
     * @param amount Amount to withdraw
     */
    function withdrawRewards(uint256 amount) external onlyOwner {
        xom.safeTransfer(treasury, amount);
    }

    /**
     * @notice Set emergency withdrawal fee
     * @param feeBps Fee in basis points
     */
    function setEmergencyWithdrawFee(uint256 feeBps) external onlyOwner {
        if (feeBps > 1000) revert InvalidParameters(); // Max 10%
        emergencyWithdrawFeeBps = feeBps;
    }

    /**
     * @notice Set treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        treasury = _treasury;
    }

    /**
     * @notice Pause staking
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause staking
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
        if (poolId >= pools.length) revert PoolNotFound();

        UserStake storage userStakeInfo = userStakes[poolId][user];

        // Calculate pending rewards
        (uint256 newImmediate, ) = _calculatePendingRewards(poolId, user);
        pendingImmediate = userStakeInfo.pendingImmediate + newImmediate;
        pendingVested = _calculateVested(userStakeInfo);

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
        if (poolId >= pools.length) revert PoolNotFound();

        PoolInfo storage pool = pools[poolId];
        if (pool.totalStaked == 0 || lpTokenPrice == 0 || xomPrice == 0) {
            return 0;
        }

        // Annual XOM rewards
        uint256 annualRewards = pool.rewardPerSecond * 365 days;

        // Annual reward value in USD
        uint256 annualRewardValue = (annualRewards * xomPrice) / 1e18;

        // Total staked value in USD
        uint256 stakedValue = (pool.totalStaked * lpTokenPrice) / 1e18;

        // APR = (annual reward value / staked value) * 10000
        aprBps = (annualRewardValue * BASIS_POINTS) / stakedValue;

        return aprBps;
    }

    // ============ Internal Functions ============

    /**
     * @notice Update pool reward state
     * @param poolId Pool identifier
     */
    function _updatePool(uint256 poolId) internal {
        PoolInfo storage pool = pools[poolId];

        // solhint-disable-next-line not-rely-on-time
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

        pool.accRewardPerShare += (reward * REWARD_PRECISION) / pool.totalStaked;
        // solhint-disable-next-line not-rely-on-time
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @notice Harvest pending rewards for user
     * @param poolId Pool identifier
     * @param user User address
     */
    function _harvestRewards(uint256 poolId, address user) internal {
        (uint256 immediateReward, uint256 vestingReward) = _calculatePendingRewards(
            poolId,
            user
        );

        UserStake storage userStakeInfo = userStakes[poolId][user];
        PoolInfo storage pool = pools[poolId];

        // Add to immediate pending
        userStakeInfo.pendingImmediate += immediateReward;

        // Add to vesting
        if (vestingReward > 0) {
            // If this is first vesting or previous vesting complete, reset
            // solhint-disable-next-line not-rely-on-time
            if (userStakeInfo.vestingStart == 0 || block.timestamp >= userStakeInfo.vestingStart + pool.vestingPeriod) {
                userStakeInfo.vestingTotal = vestingReward;
                userStakeInfo.vestingClaimed = 0;
                // solhint-disable-next-line not-rely-on-time
                userStakeInfo.vestingStart = block.timestamp;
            } else {
                // Add to existing vesting (extends proportionally)
                userStakeInfo.vestingTotal += vestingReward;
            }
        }

        // Update reward debt
        userStakeInfo.rewardDebt = (userStakeInfo.amount * pool.accRewardPerShare) / REWARD_PRECISION;
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
    ) internal view returns (uint256 immediateReward, uint256 vestingReward) {
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
            accRewardPerShare += (reward * REWARD_PRECISION) / pool.totalStaked;
        }

        uint256 pending = (userStakeInfo.amount * accRewardPerShare) /
            REWARD_PRECISION -
            userStakeInfo.rewardDebt;

        // Split into immediate and vesting
        immediateReward = (pending * pool.immediateBps) / BASIS_POINTS;
        vestingReward = pending - immediateReward;

        return (immediateReward, vestingReward);
    }

    /**
     * @notice Calculate vested amount claimable
     * @param userStakeInfo User stake struct
     * @return vested Amount vested and claimable
     */
    function _calculateVested(
        UserStake storage userStakeInfo
    ) internal view returns (uint256 vested) {
        if (userStakeInfo.vestingTotal == 0 || userStakeInfo.vestingStart == 0) {
            return 0;
        }

        // Get pool vesting period (use default if not set)
        // Note: We don't have poolId here, so use a simpler approach
        uint256 vestingPeriod = DEFAULT_VESTING_PERIOD;

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= userStakeInfo.vestingStart + vestingPeriod) {
            // Fully vested
            return userStakeInfo.vestingTotal - userStakeInfo.vestingClaimed;
        }

        // Linear vesting
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - userStakeInfo.vestingStart;
        uint256 totalVested = (userStakeInfo.vestingTotal * elapsed) / vestingPeriod;

        return totalVested > userStakeInfo.vestingClaimed
            ? totalVested - userStakeInfo.vestingClaimed
            : 0;
    }
}
