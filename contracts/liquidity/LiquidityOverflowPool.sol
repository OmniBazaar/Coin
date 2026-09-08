// SPDX-License-Identifier: MIT
// solhint-disable gas-strict-inequalities
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title IRewardSource
 * @author OmniBazaar Team
 * @notice Interface for contracts authorized to push overflow rewards
 * @dev Only OmniValidatorRewards should implement this role
 */
interface IRewardSource {
    /// @notice Check if this contract is a valid reward source
    /// @return True if valid
    function isRewardSource() external view returns (bool);
}

// ══════════════════════════════════════════════════════════════════════
//                           CONTRACT
// ══════════════════════════════════════════════════════════════════════

/**
 * @title LiquidityOverflowPool
 * @author OmniBazaar Team
 * @notice Push-based LP reward distribution from validator reward overflow
 * @dev Receives excess validator rewards and distributes them to LP stakers.
 *
 * Architecture:
 *   ValidatorRewards._distributeRewards()
 *     ├─ Validators: accumulatedRewards[v] += capped amount
 *     └─ Overflow: LiquidityOverflowPool.distributeOverflow(amount)
 *          ├─ xom.safeTransferFrom(ValidatorRewards, this, amount)
 *          ├─ Split by pool weights (basis points, total = 10000)
 *          ├─ Update accRewardPerShare for each pool
 *          └─ 30% immediate / 70% vests 90 days (per user)
 *
 * Key design decisions:
 * - UUPS upgradeable proxy (future-proof)
 * - Multiple LP pools with configurable weight basis points
 * - MasterChef-style accRewardPerShare accounting (proven pattern)
 * - Push-based: ValidatorRewards calls distributeOverflow() each epoch
 * - 30/70 vesting with 90-day period (anti-mercenary-capital)
 * - 1-day minimum stake duration (anti-flash-stake)
 * - Pausable + emergency withdrawal
 *
 * Why not use existing LiquidityMining.sol:
 * - LiquidityMining is NOT upgradeable (direct deploy, no proxy)
 * - Uses static rewardPerSecond that admin must update manually
 * - Has no push-based reward notification mechanism
 * - We need automatic adjustment — overflow IS the reward
 *
 * Security:
 * - Only registered reward sources can push overflow
 * - ReentrancyGuard on all state-modifying functions
 * - CEI pattern throughout
 * - Emergency withdrawal available even when paused
 * - AccessControl for admin operations
 */
contract LiquidityOverflowPool is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                          TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Configuration for each LP staking pool
    struct PoolInfo {
        /// @notice LP token for this pool
        IERC20 lpToken;
        /// @notice Weight in basis points (pool's share of overflow)
        uint256 weightBps;
        /// @notice Accumulated XOM reward per LP share (scaled by PRECISION)
        uint256 accRewardPerShare;
        /// @notice Total LP tokens staked in this pool
        uint256 totalStaked;
        /// @notice Percentage of rewards claimable immediately (bps)
        uint256 immediateBps;
        /// @notice Vesting period in seconds for non-immediate portion
        uint256 vestingPeriod;
        /// @notice Whether pool is accepting new stakes
        bool active;
    }

    /// @notice Per-user stake in a specific pool
    struct UserStake {
        /// @notice Amount of LP tokens staked
        uint256 amount;
        /// @notice Reward debt for MasterChef accounting
        uint256 rewardDebt;
        /// @notice Immediate rewards available to claim
        uint256 pendingImmediate;
        /// @notice Total vesting rewards allocated
        uint256 vestingTotal;
        /// @notice Vesting rewards already claimed
        uint256 vestingClaimed;
        /// @notice Timestamp when latest vesting period started
        uint256 vestingStart;
        /// @notice Timestamp of initial stake (for MIN_STAKE_DURATION)
        uint256 stakeTimestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for managing pools and weights
    bytes32 public constant POOL_MANAGER_ROLE =
        keccak256("POOL_MANAGER_ROLE");

    /// @notice Precision factor for accRewardPerShare (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Default immediate reward percentage (30%)
    uint256 public constant DEFAULT_IMMEDIATE_BPS = 3000;

    /// @notice Default vesting period (90 days)
    uint256 public constant DEFAULT_VESTING_PERIOD = 90 days;

    /// @notice Minimum vesting period (1 day)
    uint256 public constant MIN_VESTING_PERIOD = 1 days;

    /// @notice Minimum stake duration before withdrawal (1 day)
    /// @dev Anti-flash-stake: prevents depositing right before
    ///      overflow distribution and withdrawing immediately after
    uint256 public constant MIN_STAKE_DURATION = 1 days;

    /// @notice Maximum number of pools
    uint256 public constant MAX_POOLS = 20;

    /// @notice Maximum immediate reward percentage (50%)
    /// @dev Prevents admin from bypassing vesting by setting immediateBps
    ///      to 10000 (100%). At most 50% can be immediate; the rest vests.
    uint256 public constant MAX_IMMEDIATE_BPS = 5000;

    /// @notice Emergency withdrawal fee in basis points (0.5%)
    uint256 public constant EMERGENCY_FEE_BPS = 50;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token reference
    IERC20 public xomToken;

    /// @notice All registered pools
    PoolInfo[] public pools;

    /// @notice User stakes: poolId => user => UserStake
    mapping(uint256 => mapping(address => UserStake))
        public userStakes;

    /// @notice Addresses authorized to push overflow rewards
    mapping(address => bool) public rewardSources;

    /// @notice Total overflow XOM received across all time
    uint256 public totalOverflowReceived;

    /// @notice Total XOM distributed to users (immediate + vested)
    uint256 public totalDistributedToUsers;

    /// @notice Sum of all active pool weights (must equal BPS_DENOMINATOR)
    uint256 public totalWeightBps;

    /// @notice Protocol treasury for emergency withdrawal fees
    address public protocolTreasury;

    /// @dev Storage gap for future upgrades (50 - 8 used = 42)
    uint256[42] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when overflow rewards are distributed to pools
    /// @param source Address that pushed the overflow
    /// @param totalAmount Total XOM amount distributed
    /// @param poolCount Number of pools that received rewards
    event OverflowDistributed(
        address indexed source,
        uint256 indexed totalAmount,
        uint256 indexed poolCount
    );

    /// @notice Emitted when a user stakes LP tokens
    /// @param user Address of the staker
    /// @param poolId Pool index
    /// @param amount LP tokens staked
    event Staked(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount
    );

    /// @notice Emitted when a user unstakes LP tokens
    /// @param user Address of the unstaker
    /// @param poolId Pool index
    /// @param amount LP tokens withdrawn
    event Unstaked(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount
    );

    /// @notice Emitted when a user claims rewards
    /// @param user Address of the claimer
    /// @param poolId Pool index
    /// @param immediateAmount Immediate XOM claimed
    /// @param vestedAmount Vested XOM claimed
    event RewardsClaimed(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed immediateAmount,
        uint256 vestedAmount
    );

    /// @notice Emitted when a new pool is added
    /// @param poolId Pool index
    /// @param lpToken LP token address
    /// @param weightBps Pool weight in basis points
    event PoolAdded(
        uint256 indexed poolId,
        address indexed lpToken,
        uint256 indexed weightBps
    );

    /// @notice Emitted when pool weight is updated
    /// @param poolId Pool index
    /// @param oldWeight Previous weight in bps
    /// @param newWeight New weight in bps
    event PoolWeightUpdated(
        uint256 indexed poolId,
        uint256 indexed oldWeight,
        uint256 indexed newWeight
    );

    /// @notice Emitted when a reward source is added or removed
    /// @param source Address of the reward source
    /// @param authorized Whether it is now authorized
    event RewardSourceUpdated(
        address indexed source,
        bool indexed authorized
    );

    /// @notice Emitted when the protocol treasury address is updated
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event ProtocolTreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted on emergency withdrawal
    /// @param user Address of the withdrawer
    /// @param poolId Pool index
    /// @param amount LP tokens returned (after fee)
    /// @param fee Fee retained
    event EmergencyWithdrawal(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed amount,
        uint256 fee
    );

    /// @notice Emitted when pool vesting parameters are updated
    /// @param poolId Pool index
    /// @param immediateBps New immediate reward percentage in bps
    /// @param vestingPeriod New vesting period in seconds
    event VestingParamsUpdated(
        uint256 indexed poolId,
        uint256 indexed immediateBps,
        uint256 indexed vestingPeriod
    );

    /// @notice Emitted when pool active status changes
    /// @param poolId Pool index
    /// @param active New active status
    event PoolStatusUpdated(
        uint256 indexed poolId,
        bool indexed active
    );

    // ══════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Invalid pool ID
    error InvalidPool();

    /// @notice Pool is not active
    error PoolNotActive();

    /// @notice Not an authorized reward source
    error NotRewardSource();

    /// @notice Weights do not sum to BPS_DENOMINATOR
    error WeightsMismatch();

    /// @notice Maximum pool count exceeded
    error TooManyPools();

    /// @notice Stake duration not met (MIN_STAKE_DURATION)
    error StakeTooRecent();

    /// @notice No rewards to claim
    error NoRewardsToClaim();

    /// @notice Insufficient contract balance for transfer
    error InsufficientBalance();

    /// @notice Vesting period too short
    error VestingTooShort();

    /// @notice Weight exceeds BPS_DENOMINATOR
    error WeightTooHigh();

    /// @notice Duplicate LP token across pools
    error DuplicateLpToken();

    /// @notice No active pools have stakers to receive overflow
    error NoActiveStakers();

    /// @notice Immediate percentage exceeds MAX_IMMEDIATE_BPS cap
    error ImmediateBpsTooHigh();

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Implementation constructor — baked-in trusted forwarder.
     * @dev `ERC2771ContextUpgradeable._trustedForwarder` is an
     *      `address private immutable`, set ONLY by this constructor.
     *      To rotate the forwarder later, deploy a fresh IMPL and
     *      UUPS-upgrade. The proxy retains all storage; no
     *      storage-layout slots are added or shifted by inheriting
     *      `ERC2771ContextUpgradeable` (everything it owns is bytecode-
     *      immutable). Pattern matches the LIQ-Q-2 first half landed
     *      2026-05-23 (UnifiedFeeVault + OmniRegistration).
     * @param trustedForwarder_ The canonical OmniForwarder address
     *                          (mainnet: `0xaF8c638b…`). MUST be the
     *                          same forwarder all other contracts in
     *                          the gasless surface trust.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the LiquidityOverflowPool
     * @dev Called once during proxy deployment
     * @param xomTokenAddr Address of the XOM token contract
     * @param treasury Address of the protocol treasury
     */
    function initialize(
        address xomTokenAddr,
        address treasury
    ) external initializer {
        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (treasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_MANAGER_ROLE, msg.sender);

        xomToken = IERC20(xomTokenAddr);
        protocolTreasury = treasury;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       OVERFLOW DISTRIBUTION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Receive and distribute overflow rewards from ValidatorRewards
     * @dev Called by ValidatorRewards._distributeRewards() each epoch.
     *      Splits the overflow across active pools that have stakers,
     *      using liveWeight (sum of weights of eligible pools) as
     *      divisor. Pools with weight but no stakers do not dilute.
     *      Requires prior ERC20 approval.
     *
     *      Gas cost: O(pools.length) — bounded by MAX_POOLS (20).
     *
     * @param amount Total XOM overflow to distribute
     */
    function distributeOverflow(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!rewardSources[msg.sender]) {
            revert NotRewardSource();
        }
        if (amount == 0) revert ZeroAmount();

        // Compute liveWeight: sum of weights only for active pools that
        // have stakers. This prevents pools with weight but no stakers
        // from diluting overflow distribution. Tokens go 100% to pools
        // that actually have stakers, proportional to their weights.
        uint256 poolLen = pools.length;
        uint256 liveWeight = 0;
        for (uint256 i = 0; i < poolLen;) {
            PoolInfo storage pool = pools[i];
            if (pool.active && pool.weightBps > 0 && pool.totalStaked > 0) {
                liveWeight += pool.weightBps;
            }
            unchecked { ++i; }
        }
        if (liveWeight == 0) revert NoActiveStakers();

        // Transfer XOM from reward source to this contract
        xomToken.safeTransferFrom(msg.sender, address(this), amount);

        totalOverflowReceived += amount;

        uint256 distributed = 0;
        uint256 activePoolCount = 0;

        for (uint256 i = 0; i < poolLen;) {
            PoolInfo storage pool = pools[i];
            if (pool.active && pool.weightBps > 0 && pool.totalStaked > 0) {
                uint256 poolShare =
                    (amount * pool.weightBps) / liveWeight;

                // Update accRewardPerShare (MasterChef pattern)
                pool.accRewardPerShare +=
                    (poolShare * PRECISION) / pool.totalStaked;

                distributed += poolShare;
                ++activePoolCount;
            }
            unchecked { ++i; }
        }

        // Rounding dust stays in contract (improves solvency)
        emit OverflowDistributed(
            msg.sender, amount, activePoolCount
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                         USER OPERATIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Stake LP tokens into a pool
     * @dev Harvests pending rewards before updating stake.
     *      Sets stakeTimestamp for MIN_STAKE_DURATION enforcement.
     * @param poolId Index of the pool to stake in
     * @param amount Amount of LP tokens to stake
     */
    function stake(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (poolId >= pools.length) revert InvalidPool();
        if (amount == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId];
        if (!pool.active) revert PoolNotActive();

        // ERC-2771: resolve sender via meta-tx forwarder when present.
        address sender = _msgSender();
        UserStake storage user = userStakes[poolId][sender];

        // Harvest pending rewards if user already has a stake
        if (user.amount > 0) {
            _harvestRewards(poolId, sender);
        }

        // Transfer LP tokens from user
        pool.lpToken.safeTransferFrom(
            sender, address(this), amount
        );

        // Update user stake
        user.amount += amount;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / PRECISION;

        // Reset stake timestamp on every stake to enforce MIN_STAKE_DURATION
        // from the latest deposit. Prevents adding dust to extend an existing
        // stake without resetting the anti-flash-stake timer.
        // solhint-disable-next-line not-rely-on-time
        user.stakeTimestamp = block.timestamp;

        pool.totalStaked += amount;

        emit Staked(sender, poolId, amount);
    }

    /**
     * @notice Unstake LP tokens from a pool
     * @dev Harvests pending rewards before withdrawal.
     *      Enforces MIN_STAKE_DURATION to prevent flash-staking.
     * @param poolId Index of the pool to unstake from
     * @param amount Amount of LP tokens to withdraw
     */
    function unstake(
        uint256 poolId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (poolId >= pools.length) revert InvalidPool();
        if (amount == 0) revert ZeroAmount();

        // ERC-2771: resolve sender via meta-tx forwarder when present.
        address sender = _msgSender();
        UserStake storage user = userStakes[poolId][sender];
        if (user.amount < amount) revert InsufficientBalance();

        // Anti-flash-stake: enforce minimum stake duration
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < user.stakeTimestamp + MIN_STAKE_DURATION) {
            revert StakeTooRecent();
        }

        PoolInfo storage pool = pools[poolId];

        // Harvest pending rewards
        _harvestRewards(poolId, sender);

        // Update user stake
        user.amount -= amount;
        user.rewardDebt =
            (user.amount * pool.accRewardPerShare) / PRECISION;

        // Reset stake timestamp on full withdrawal
        if (user.amount == 0) {
            user.stakeTimestamp = 0;
        }

        pool.totalStaked -= amount;

        // Return LP tokens
        pool.lpToken.safeTransfer(sender, amount);

        emit Unstaked(sender, poolId, amount);
    }

    /**
     * @notice Claim all available rewards from a pool
     * @dev Claims immediate rewards plus any vested portion that
     *      has unlocked since vestingStart.
     * @param poolId Index of the pool to claim from
     */
    function claimRewards(
        uint256 poolId
    ) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool();

        // ERC-2771: resolve sender via meta-tx forwarder when present.
        address sender = _msgSender();

        // Anti-flash-stake: a still-active staker cannot harvest the
        // immediate reward slice until MIN_STAKE_DURATION has elapsed since
        // their last stake — the same lock unstake() enforces. Without this,
        // an attacker could stake heavily right before a distributeOverflow,
        // claim the immediate portion, and exit the same block, diluting
        // honest LPs. A fully-exited user (amount == 0) may still claim any
        // residual rewards.
        UserStake storage user = userStakes[poolId][sender];
        // solhint-disable-next-line not-rely-on-time
        bool lockActive = user.amount > 0
            && block.timestamp < user.stakeTimestamp + MIN_STAKE_DURATION;
        if (lockActive) revert StakeTooRecent();

        _harvestRewards(poolId, sender);

        uint256 immediateAmount = user.pendingImmediate;
        uint256 vestedAmount = _claimableVested(poolId, sender);
        uint256 totalClaim = immediateAmount + vestedAmount;

        if (totalClaim == 0) revert NoRewardsToClaim();

        // Update state before transfer (CEI)
        user.pendingImmediate = 0;
        user.vestingClaimed += vestedAmount;
        totalDistributedToUsers += totalClaim;

        // Transfer XOM rewards
        xomToken.safeTransfer(sender, totalClaim);

        emit RewardsClaimed(
            sender, poolId, immediateAmount, vestedAmount
        );
    }

    /**
     * @notice Emergency withdrawal — forfeit unvested rewards, pay fee
     * @dev Available even when contract is paused. Returns LP tokens
     *      minus a small fee. All pending/vesting rewards are forfeited.
     * @param poolId Index of the pool to emergency withdraw from
     */
    function emergencyWithdraw(
        uint256 poolId
    ) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPool();

        // ERC-2771: resolve sender via meta-tx forwarder when present.
        address sender = _msgSender();
        UserStake storage user = userStakes[poolId][sender];
        uint256 stakedAmount = user.amount;
        if (stakedAmount == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId];

        // Calculate fee
        uint256 fee =
            (stakedAmount * EMERGENCY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 returnAmount = stakedAmount - fee;

        // Clear user state completely
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingImmediate = 0;
        user.vestingTotal = 0;
        user.vestingClaimed = 0;
        user.vestingStart = 0;
        user.stakeTimestamp = 0;

        pool.totalStaked -= stakedAmount;

        // Transfer LP tokens (minus fee) to user
        pool.lpToken.safeTransfer(sender, returnAmount);

        // Send fee to protocol treasury
        if (fee > 0) {
            pool.lpToken.safeTransfer(protocolTreasury, fee);
        }

        emit EmergencyWithdrawal(
            sender, poolId, returnAmount, fee
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Add a new LP staking pool
     * @dev Pool weight must not cause totalWeightBps to exceed
     *      BPS_DENOMINATOR. Use setPoolWeight() to rebalance after adding.
     * @param lpToken Address of the LP token for this pool
     * @param weightBps Weight in basis points (share of overflow)
     */
    function addPool(
        address lpToken,
        uint256 weightBps
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (lpToken == address(0)) revert ZeroAddress();
        if (pools.length >= MAX_POOLS) revert TooManyPools();
        if (totalWeightBps + weightBps > BPS_DENOMINATOR) {
            revert WeightTooHigh();
        }

        // Check for duplicate LP tokens
        uint256 poolLen = pools.length;
        for (uint256 i = 0; i < poolLen;) {
            if (address(pools[i].lpToken) == lpToken) {
                revert DuplicateLpToken();
            }
            unchecked { ++i; }
        }

        pools.push(PoolInfo({
            lpToken: IERC20(lpToken),
            weightBps: weightBps,
            accRewardPerShare: 0,
            totalStaked: 0,
            immediateBps: DEFAULT_IMMEDIATE_BPS,
            vestingPeriod: DEFAULT_VESTING_PERIOD,
            active: true
        }));

        totalWeightBps += weightBps;

        emit PoolAdded(pools.length - 1, lpToken, weightBps);
    }

    /**
     * @notice Update a pool's weight
     * @dev Adjusts totalWeightBps accordingly. Caller must ensure
     *      total of all weights equals BPS_DENOMINATOR before
     *      next overflow distribution for correct accounting.
     * @param poolId Index of the pool
     * @param newWeight New weight in basis points
     */
    function setPoolWeight(
        uint256 poolId,
        uint256 newWeight
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (poolId >= pools.length) revert InvalidPool();

        PoolInfo storage pool = pools[poolId];
        uint256 oldWeight = pool.weightBps;

        // Only adjust totalWeightBps for active pools.
        // Inactive pools' weight is excluded from totalWeightBps
        // (removed in setPoolActive), so modifying it here would
        // corrupt the running total.
        if (pool.active) {
            uint256 newTotal =
                totalWeightBps - oldWeight + newWeight;
            if (newTotal > BPS_DENOMINATOR) revert WeightTooHigh();
            totalWeightBps = newTotal;
        }

        pool.weightBps = newWeight;

        emit PoolWeightUpdated(poolId, oldWeight, newWeight);
    }

    /**
     * @notice Set vesting parameters for a pool
     * @dev Changes apply to future rewards only; existing vesting
     *      schedules are not affected.
     * @param poolId Index of the pool
     * @param immediateBps Immediate reward percentage (0 to MAX_IMMEDIATE_BPS)
     * @param vestingPeriod Vesting duration in seconds
     */
    function setVestingParams(
        uint256 poolId,
        uint256 immediateBps,
        uint256 vestingPeriod
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (poolId >= pools.length) revert InvalidPool();
        if (immediateBps > MAX_IMMEDIATE_BPS) {
            revert ImmediateBpsTooHigh();
        }
        if (
            vestingPeriod > 0
                && vestingPeriod < MIN_VESTING_PERIOD
        ) {
            revert VestingTooShort();
        }

        PoolInfo storage pool = pools[poolId];
        pool.immediateBps = immediateBps;
        pool.vestingPeriod = vestingPeriod;

        emit VestingParamsUpdated(poolId, immediateBps, vestingPeriod);
    }

    /**
     * @notice Set pool active status
     * @dev Inactive pools stop receiving overflow but existing
     *      stakers can still withdraw and claim.
     * @param poolId Index of the pool
     * @param active New active status
     */
    function setPoolActive(
        uint256 poolId,
        bool active
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (poolId >= pools.length) revert InvalidPool();

        PoolInfo storage pool = pools[poolId];
        bool wasActive = pool.active;
        pool.active = active;

        // Auto-adjust totalWeightBps so deactivated pool weight
        // doesn't create permanent overflow leakage.
        if (wasActive && !active) {
            totalWeightBps -= pool.weightBps;
        } else if (!wasActive && active) {
            // Reactivation: verify weight doesn't exceed cap
            if (totalWeightBps + pool.weightBps > BPS_DENOMINATOR) {
                revert WeightTooHigh();
            }
            totalWeightBps += pool.weightBps;
        }

        emit PoolStatusUpdated(poolId, active);
    }

    /**
     * @notice Add or remove a reward source
     * @dev Only authorized sources can call distributeOverflow()
     * @param source Address of the reward source
     * @param authorized Whether to authorize or deauthorize
     */
    function setRewardSource(
        address source,
        bool authorized
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (source == address(0)) revert ZeroAddress();
        rewardSources[source] = authorized;
        emit RewardSourceUpdated(source, authorized);
    }

    /**
     * @notice Update protocol treasury address
     * @param treasury New treasury address
     */
    function setProtocolTreasury(
        address treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) revert ZeroAddress();
        address oldTreasury = protocolTreasury;
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(oldTreasury, treasury);
    }

    /**
     * @notice Pause the contract
     * @dev Blocks staking and overflow distribution.
     *      Claims and emergency withdrawals remain available.
     */
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Get total number of pools
     * @return Number of registered pools
     */
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    /**
     * @notice Get full pool info
     * @param poolId Index of the pool
     * @return Pool configuration and state
     */
    function getPoolInfo(
        uint256 poolId
    ) external view returns (PoolInfo memory) {
        if (poolId >= pools.length) revert InvalidPool();
        return pools[poolId];
    }

    /**
     * @notice Get user's stake info for a pool
     * @param poolId Pool index
     * @param user User address
     * @return User's stake details
     */
    function getUserStake(
        uint256 poolId,
        address user
    ) external view returns (UserStake memory) {
        return userStakes[poolId][user];
    }

    /**
     * @notice Calculate pending rewards for a user in a pool
     * @dev Includes both unharvested and already-harvested pending
     *      immediate rewards plus claimable vested amount.
     * @param poolId Pool index
     * @param user User address
     * @return immediate Claimable immediate rewards
     * @return vested Claimable vested rewards
     * @return vestingRemaining Vesting rewards not yet unlocked
     */
    function pendingRewards(
        uint256 poolId,
        address user
    )
        external
        view
        returns (
            uint256 immediate,
            uint256 vested,
            uint256 vestingRemaining
        )
    {
        if (poolId >= pools.length) return (0, 0, 0);

        PoolInfo storage pool = pools[poolId];
        UserStake storage u = userStakes[poolId][user];

        if (u.amount == 0) {
            return (
                u.pendingImmediate,
                _claimableVested(poolId, user),
                _unvestedAmount(poolId, user)
            );
        }

        // Calculate unharvested rewards
        uint256 accReward =
            (u.amount * pool.accRewardPerShare) / PRECISION;
        uint256 pending = 0;
        if (accReward > u.rewardDebt) {
            pending = accReward - u.rewardDebt;
        }

        // Split into immediate and vesting portions
        uint256 immPortion =
            (pending * pool.immediateBps) / BPS_DENOMINATOR;

        immediate = u.pendingImmediate + immPortion;
        vested = _claimableVested(poolId, user);
        vestingRemaining = _unvestedAmount(poolId, user)
            + (pending - immPortion);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Harvest pending rewards for a user in a pool
     * @dev Updates pendingImmediate and vesting state. Called before
     *      any stake/unstake operation to ensure accurate accounting.
     * @param poolId Pool index
     * @param user User address
     */
    function _harvestRewards(
        uint256 poolId,
        address user
    ) internal {
        PoolInfo storage pool = pools[poolId];
        UserStake storage u = userStakes[poolId][user];

        if (u.amount == 0) return;

        uint256 accReward =
            (u.amount * pool.accRewardPerShare) / PRECISION;
        uint256 pending = 0;
        if (accReward > u.rewardDebt) {
            pending = accReward - u.rewardDebt;
        }

        if (pending > 0) {
            // Split: immediate vs vesting
            uint256 immPortion =
                (pending * pool.immediateBps) / BPS_DENOMINATOR;
            uint256 vestPortion = pending - immPortion;

            u.pendingImmediate += immPortion;

            // Append to existing vesting schedule
            if (vestPortion > 0 && pool.vestingPeriod > 0) {
                // Credit already-vested (but unclaimed) rewards to
                // pendingImmediate so they're not lost when we merge
                // the vesting schedules.
                uint256 existingClaimable =
                    _claimableVested(poolId, user);
                u.pendingImmediate += existingClaimable;

                // Carry forward only the still-unvested portion plus
                // the new vest portion. Reset claimed counter since
                // we moved claimable to pendingImmediate above.
                uint256 existingUnvested =
                    _unvestedAmount(poolId, user);
                uint256 totalNewVest = existingUnvested + vestPortion;
                u.vestingTotal = totalNewVest;
                u.vestingClaimed = 0;

                // Audit fix M-02: Use weighted-average vestingStart so
                // existing unvested rewards keep their original timeline
                // instead of resetting to now (which penalizes active users).
                // solhint-disable-next-line not-rely-on-time
                if (existingUnvested > 0 && totalNewVest > 0) {
                    u.vestingStart = (
                        (existingUnvested * u.vestingStart)
                            + (vestPortion * block.timestamp)
                    ) / totalNewVest;
                } else {
                    // solhint-disable-next-line not-rely-on-time
                    u.vestingStart = block.timestamp;
                }
            } else {
                // No vesting period — treat as immediate
                u.pendingImmediate += vestPortion;
            }
        }

        // Update reward debt
        u.rewardDebt =
            (u.amount * pool.accRewardPerShare) / PRECISION;
    }

    /**
     * @notice Authorize UUPS upgrade
     * @dev Restricted to DEFAULT_ADMIN_ROLE
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-only access is sufficient for upgrade authorization
        // Production should use a multisig for admin role
        (newImplementation);
    }

    /**
     * @notice Calculate claimable vested rewards for a user
     * @param poolId Pool index
     * @param user User address
     * @return Claimable vested XOM amount
     */
    function _claimableVested(
        uint256 poolId,
        address user
    ) internal view returns (uint256) {
        UserStake storage u = userStakes[poolId][user];
        if (u.vestingTotal == 0) return 0;

        PoolInfo storage pool = pools[poolId];
        if (pool.vestingPeriod == 0) return u.vestingTotal - u.vestingClaimed;

        /* solhint-disable not-rely-on-time */
        uint256 elapsed = block.timestamp > u.vestingStart
            ? block.timestamp - u.vestingStart
            : 0;
        /* solhint-enable not-rely-on-time */

        uint256 totalVested;
        if (elapsed >= pool.vestingPeriod) {
            totalVested = u.vestingTotal;
        } else {
            totalVested = (u.vestingTotal * elapsed) / pool.vestingPeriod;
        }

        if (totalVested <= u.vestingClaimed) return 0;
        return totalVested - u.vestingClaimed;
    }

    /**
     * @notice Calculate unvested rewards for a user
     * @param poolId Pool index
     * @param user User address
     * @return Unvested XOM amount
     */
    function _unvestedAmount(
        uint256 poolId,
        address user
    ) internal view returns (uint256) {
        UserStake storage u = userStakes[poolId][user];
        if (u.vestingTotal == 0) return 0;

        uint256 totalVesting = u.vestingTotal - u.vestingClaimed;
        uint256 claimable = _claimableVested(poolId, user);

        if (claimable >= totalVesting) return 0;
        return totalVesting - claimable;
    }

    // ══════════════════════════════════════════════════════════════════
    //              ERC2771Context Overrides (resolve diamond)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve `_msgSender` between `ContextUpgradeable` and
     *         `ERC2771ContextUpgradeable`.
     * @dev When a meta-tx arrives via the trusted forwarder, the
     *      original signer's address is recovered from the suffixed
     *      calldata. Otherwise the raw `msg.sender` is returned. This
     *      is the function every user-facing flow now reads via the
     *      local `sender` variable.
     * @return The effective sender for the current call.
     */
    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve `_msgData` between `ContextUpgradeable` and
     *         `ERC2771ContextUpgradeable`.
     * @dev Strips the ERC-2771 sender suffix when the call originated
     *      at the trusted forwarder; otherwise returns raw `msg.data`.
     * @return The effective calldata for the current call.
     */
    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolve `_contextSuffixLength` between
     *         `ContextUpgradeable` and `ERC2771ContextUpgradeable`.
     * @dev Returns 20 (the address-length suffix appended by an
     *      ERC-2771 forwarder).
     * @return Suffix byte length used to recover the meta-tx sender.
     */
    function _contextSuffixLength()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
