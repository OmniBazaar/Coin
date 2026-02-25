// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
 * - Owner cannot drain user-committed rewards
 *
 * Reward Distribution Model:
 * - 30% of rewards claimable immediately
 * - 70% of rewards vest linearly over 90 days (configurable per pool)
 */
contract LiquidityMining is ReentrancyGuard, Ownable2Step, Pausable {
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

    /// @notice Treasury / ODDAO address for fees (receives 70%)
    address public treasury;

    /// @notice Validator fee recipient (receives 20% of fees)
    address public validatorFeeRecipient;

    /// @notice Staking pool fee recipient (receives 10% of fees)
    address public stakingPoolFeeRecipient;

    /// @notice Emergency withdrawal fee in basis points (0.5% = 50 bps)
    uint256 public emergencyWithdrawFeeBps;

    /// @notice Total XOM committed to users (pending immediate + unvested)
    uint256 public totalCommittedRewards;

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

    /// @notice Emitted when treasury address is updated
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when validator fee recipient is updated
    /// @param oldRecipient Previous recipient address
    /// @param newRecipient New recipient address
    event ValidatorFeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Emitted when staking pool fee recipient is updated
    /// @param oldRecipient Previous recipient address
    /// @param newRecipient New recipient address
    event StakingPoolFeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
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

    /// @notice Thrown when withdrawing more than available uncommitted rewards
    error InsufficientRewards();

    // ============ Constructor ============

    /**
     * @notice Initialize liquidity mining contract
     * @param _xom XOM reward token address
     * @param _treasury Treasury / ODDAO address for fees (70%)
     * @param _validatorFeeRecipient Validator fee recipient (20%)
     * @param _stakingPoolFeeRecipient Staking pool fee recipient (10%)
     */
    constructor(
        address _xom,
        address _treasury,
        address _validatorFeeRecipient,
        address _stakingPoolFeeRecipient
    ) Ownable(msg.sender) {
        if (
            _xom == address(0) ||
            _treasury == address(0) ||
            _validatorFeeRecipient == address(0) ||
            _stakingPoolFeeRecipient == address(0)
        ) {
            revert InvalidParameters();
        }
        xom = IERC20(_xom);
        treasury = _treasury;
        validatorFeeRecipient = _validatorFeeRecipient;
        stakingPoolFeeRecipient = _stakingPoolFeeRecipient;
        emergencyWithdrawFeeBps = 50; // 0.5% fee
    }

    // ============ External Functions ============

    /**
     * @notice Add a new staking pool
     * @dev Reverts if MAX_POOLS limit is reached or LP token already exists
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
        // solhint-disable-next-line gas-strict-inequalities
        if (immediateBps > BASIS_POINTS) revert InvalidParameters();
        // solhint-disable-next-line gas-strict-inequalities
        if (pools.length >= MAX_POOLS) revert InvalidParameters();

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
     * @param poolId Pool identifier
     * @param newRewardPerSecond New reward rate
     */
    function setRewardRate(
        uint256 poolId,
        uint256 newRewardPerSecond
    ) external onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

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

        PoolInfo storage pool = pools[poolId];
        if (!pool.active) revert PoolNotActive();

        _updatePool(poolId);

        UserStake storage user = userStakes[poolId][msg.sender];

        // Harvest pending rewards before modifying stake
        if (user.amount > 0) {
            _harvestRewards(poolId, msg.sender);
        }

        // Transfer LP tokens from user (M-01: balance-before/after
        // for fee-on-transfer token compatibility)
        uint256 balBefore = pool.lpToken.balanceOf(address(this));
        pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = pool.lpToken.balanceOf(address(this)) - balBefore;

        // Update user stake with actual received amount
        user.amount += received;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

        // Update pool total
        pool.totalStaked += received;

        emit Staked(msg.sender, poolId, received);
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

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][msg.sender];

        if (user.amount < amount) revert InsufficientStake();

        _updatePool(poolId);

        // Harvest pending rewards before modifying stake
        _harvestRewards(poolId, msg.sender);

        // Update user stake
        user.amount -= amount;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / REWARD_PRECISION;

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
    )
        external
        nonReentrant
        returns (uint256 immediateAmount, uint256 vestedAmount)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        _updatePool(poolId);
        _harvestRewards(poolId, msg.sender);

        UserStake storage user = userStakes[poolId][msg.sender];

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

        xom.safeTransfer(msg.sender, total);
        totalXomDistributed += total;

        emit RewardsClaimed(
            msg.sender, poolId, immediateAmount, vestedAmount
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
        uint256 poolLen = pools.length;
        for (uint256 i = 0; i < poolLen; ) {
            _updatePool(i);
            UserStake storage user = userStakes[i][msg.sender];

            if (
                user.amount > 0 ||
                user.pendingImmediate > 0 ||
                user.vestingTotal > 0
            ) {
                _harvestRewards(i, msg.sender);

                uint256 immediate = user.pendingImmediate;
                user.pendingImmediate = 0;
                totalImmediate += immediate;

                uint256 vested = _calculateVested(user, i);
                user.vestingClaimed += vested;
                totalVested += vested;

                if (immediate + vested > 0) {
                    emit RewardsClaimed(
                        msg.sender, i, immediate, vested
                    );
                }
            }

            unchecked { ++i; }
        }

        uint256 total = totalImmediate + totalVested;
        if (total == 0) revert NothingToClaim();

        // Decrement committed rewards tracker
        totalCommittedRewards -= total;

        xom.safeTransfer(msg.sender, total);
        totalXomDistributed += total;

        return (totalImmediate, totalVested);
    }

    /**
     * @notice Emergency withdraw without rewards (with fee)
     * @dev Forfeits all pending and vesting rewards
     * @param poolId Pool identifier
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        // solhint-disable-next-line gas-strict-inequalities
        if (poolId >= pools.length) revert PoolNotFound();

        PoolInfo storage pool = pools[poolId];
        UserStake storage user = userStakes[poolId][msg.sender];

        uint256 amount = user.amount;
        if (amount == 0) revert InsufficientStake();

        // Calculate forfeited rewards and decrement committed tracker
        uint256 forfeited = user.pendingImmediate +
            user.vestingTotal -
            user.vestingClaimed;
        // solhint-disable-next-line gas-strict-inequalities
        if (forfeited > 0 && totalCommittedRewards >= forfeited) {
            totalCommittedRewards -= forfeited;
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

        // Transfer LP tokens with 70/20/10 fee split (M-02)
        if (fee > 0) {
            uint256 validatorShare = (fee * 2_000) / BASIS_POINTS; // 20%
            uint256 stakingShare = (fee * 1_000) / BASIS_POINTS;   // 10%
            uint256 oddaoShare = fee - validatorShare - stakingShare; // 70%
            pool.lpToken.safeTransfer(treasury, oddaoShare);
            pool.lpToken.safeTransfer(
                validatorFeeRecipient, validatorShare
            );
            pool.lpToken.safeTransfer(
                stakingPoolFeeRecipient, stakingShare
            );
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
     * @notice Withdraw excess XOM not committed to users
     * @dev Only allows withdrawal of XOM above totalCommittedRewards
     * @param amount Amount to withdraw
     */
    function withdrawRewards(uint256 amount) external onlyOwner {
        uint256 balance = xom.balanceOf(address(this));
        uint256 available = balance > totalCommittedRewards
            ? balance - totalCommittedRewards
            : 0;
        if (amount > available) revert InsufficientRewards();
        xom.safeTransfer(treasury, amount);
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
     * @notice Set treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        address oldTreasury = treasury;
        treasury = _treasury;

        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Set validator fee recipient address
     * @param _recipient New validator fee recipient
     */
    function setValidatorFeeRecipient(
        address _recipient
    ) external onlyOwner {
        if (_recipient == address(0)) revert InvalidParameters();
        address old = validatorFeeRecipient;
        validatorFeeRecipient = _recipient;
        emit ValidatorFeeRecipientUpdated(old, _recipient);
    }

    /**
     * @notice Set staking pool fee recipient address
     * @param _recipient New staking pool fee recipient
     */
    function setStakingPoolFeeRecipient(
        address _recipient
    ) external onlyOwner {
        if (_recipient == address(0)) revert InvalidParameters();
        address old = stakingPoolFeeRecipient;
        stakingPoolFeeRecipient = _recipient;
        emit StakingPoolFeeRecipientUpdated(old, _recipient);
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
                // Add to existing vesting (extends proportionally)
                userStakeInfo.vestingTotal += vestingReward;
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
}
