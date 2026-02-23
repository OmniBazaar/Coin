// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from
    "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OmniNFTStaking
 * @author OmniBazaar Development Team
 * @notice Collection-based NFT staking with ERC-20 rewards and rarity
 *         multipliers.
 * @dev Creators or the protocol fund reward pools for specific collections.
 *      Stakers earn rewards proportional to their rarity multiplier and
 *      streak bonus. No mandatory lock-up -- users can unstake at any time
 *      but lose their streak.
 *
 *      Streak bonuses:
 *        1.0x  (0-6 days)
 *        1.1x  (7-29 days)
 *        1.25x (30-89 days)
 *        1.5x  (90+ days)
 *
 *      Security notes:
 *        - Reward transfer failures never trap staked NFTs (H-01).
 *        - Pool endTime is enforced in both staking and reward accrual
 *          (H-02).
 *        - Pool creators can withdraw unused rewards after endTime (H-03).
 *        - Fee-on-transfer tokens are handled via balance-before/after
 *          accounting (H-04).
 *        - lastClaimAt only advances when rewards are actually paid (H-05).
 */
contract OmniNFTStaking is ERC721Holder, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Structs ──────────────────────────────────────────────────────────

    /// @notice Staking pool configuration.
    struct Pool {
        address creator;
        address collection;
        address rewardToken;
        uint256 totalReward;
        uint256 rewardPerDay;
        uint256 remainingReward;
        uint64 startTime;
        uint64 endTime;
        uint32 totalStaked;
        bool active;
        bool rarityEnabled;
    }

    /// @notice Individual NFT stake.
    /// @dev Fields packed: staker (20 bytes) + stakedAt (8) + lastClaimAt
    ///      (8) fit in two slots alongside the uint256 fields.
    // solhint-disable-next-line gas-struct-packing
    struct Stake {
        address staker;
        uint64 stakedAt;
        uint64 lastClaimAt;
        uint256 tokenId;
        uint256 rarityMultiplier;
        uint256 accumulatedReward;
        bool active;
    }

    // ── Constants ────────────────────────────────────────────────────────

    /// @notice Multiplier precision: 10000 = 1.0x.
    uint256 public constant MULTIPLIER_PRECISION = 10000;

    /// @notice Minimum multiplier: 0.1x.
    uint256 public constant MIN_MULTIPLIER = 1000;

    /// @notice Maximum multiplier: 5.0x.
    uint256 public constant MAX_MULTIPLIER = 50000;

    /// @notice Streak bonus threshold: 7 days.
    uint256 public constant STREAK_TIER1 = 7 days;

    /// @notice Streak bonus threshold: 30 days.
    uint256 public constant STREAK_TIER2 = 30 days;

    /// @notice Streak bonus threshold: 90 days.
    uint256 public constant STREAK_TIER3 = 90 days;

    /// @notice Streak bonus multiplier for 0-6 days (1.0x).
    uint256 public constant STREAK_BONUS_0 = 10000;

    /// @notice Streak bonus multiplier for 7-29 days (1.1x).
    uint256 public constant STREAK_BONUS_1 = 11000;

    /// @notice Streak bonus multiplier for 30-89 days (1.25x).
    uint256 public constant STREAK_BONUS_2 = 12500;

    /// @notice Streak bonus multiplier for 90+ days (1.5x).
    uint256 public constant STREAK_BONUS_3 = 15000;

    // ── Storage ──────────────────────────────────────────────────────────

    /// @notice Next pool ID.
    uint256 public nextPoolId;

    /// @notice Pool by ID.
    mapping(uint256 => Pool) public pools;

    /// @notice Stakes: poolId => tokenId => Stake.
    mapping(uint256 => mapping(uint256 => Stake)) public stakes;

    /// @notice Total weighted stakes per pool (for reward distribution).
    mapping(uint256 => uint256) public totalWeightedStakes;

    // ── Events ───────────────────────────────────────────────────────────

    /// @notice Emitted when a staking pool is created.
    /// @param poolId Pool identifier.
    /// @param creator Pool creator address.
    /// @param collection NFT collection.
    /// @param rewardToken Token used for rewards.
    /// @param totalReward Total reward funded.
    /// @param rewardPerDay Daily reward rate.
    event PoolCreated(
        uint256 indexed poolId,
        address indexed creator,
        address indexed collection,
        address rewardToken,
        uint256 totalReward,
        uint256 rewardPerDay
    );

    /// @notice Emitted when an NFT is staked.
    /// @param poolId Pool receiving the stake.
    /// @param staker Staker address.
    /// @param tokenId NFT token ID.
    event Staked(
        uint256 indexed poolId,
        address indexed staker,
        uint256 indexed tokenId
    );

    /// @notice Emitted when an NFT is unstaked.
    /// @param poolId Pool the NFT was in.
    /// @param staker Staker address.
    /// @param tokenId NFT token ID.
    /// @param reward Reward claimed on unstake.
    event Unstaked(
        uint256 indexed poolId,
        address indexed staker,
        uint256 indexed tokenId,
        uint256 reward
    );

    /// @notice Emitted when rewards are claimed without unstaking.
    /// @param poolId Pool for the claim.
    /// @param staker Staker address.
    /// @param tokenId NFT token ID.
    /// @param reward Amount claimed.
    event RewardsClaimed(
        uint256 indexed poolId,
        address indexed staker,
        uint256 indexed tokenId,
        uint256 reward
    );

    /// @notice Emitted when a staker emergency-withdraws without rewards.
    /// @param poolId Pool the NFT was in.
    /// @param staker Staker address.
    /// @param tokenId NFT token ID.
    event EmergencyWithdraw(
        uint256 indexed poolId,
        address indexed staker,
        uint256 indexed tokenId
    );

    /// @notice Emitted when a pool creator withdraws remaining rewards.
    /// @param poolId Pool identifier.
    /// @param creator Creator address.
    /// @param amount Amount withdrawn.
    event RemainingRewardsWithdrawn(
        uint256 indexed poolId,
        address indexed creator,
        uint256 indexed amount
    );

    /// @notice Emitted when a pool is paused.
    /// @param poolId Pool that was paused.
    event PoolPaused(uint256 indexed poolId);

    /// @notice Emitted when a pool is resumed.
    /// @param poolId Pool that was resumed.
    event PoolResumed(uint256 indexed poolId);

    /// @notice Emitted when a rarity multiplier is changed.
    /// @param poolId Pool identifier.
    /// @param tokenId NFT token ID.
    /// @param oldMultiplier Previous multiplier.
    /// @param newMultiplier New multiplier.
    event RarityMultiplierSet(
        uint256 indexed poolId,
        uint256 indexed tokenId,
        uint256 indexed oldMultiplier,
        uint256 newMultiplier
    );

    /// @notice Emitted when a reward transfer fails during unstake.
    /// @param poolId Pool identifier.
    /// @param staker Staker address.
    /// @param amount Amount that failed to transfer.
    event RewardTransferFailed(
        uint256 indexed poolId,
        address indexed staker,
        uint256 indexed amount
    );

    // ── Custom errors ────────────────────────────────────────────────────

    /// @dev Pool does not exist.
    error PoolNotFound();

    /// @dev Pool is not active (paused or deactivated).
    error PoolNotActive();

    /// @dev Pool has expired (past endTime).
    error PoolExpired();

    /// @dev Stake not found or not owned by caller.
    error StakeNotFound();

    /// @dev NFT is already staked in this pool.
    error AlreadyStaked();

    /// @dev Caller is not the staker.
    error NotStaker();

    /// @dev Reward per day is zero.
    error ZeroRewardRate();

    /// @dev Duration is zero.
    error ZeroDuration();

    /// @dev Total reward is zero.
    error ZeroTotalReward();

    /// @dev Multiplier out of range (1000-50000 = 0.1x-5.0x).
    error InvalidMultiplier();

    /// @dev Caller is not the pool creator.
    error NotPoolCreator();

    /// @dev Pool has not ended yet.
    error PoolStillActive();

    /// @dev Supplied amount is zero.
    error ZeroAmount();

    /// @dev Remaining reward is less than pending -- pool under-funded.
    error InsufficientRewards();

    /// @dev Address is the zero address.
    error ZeroAddress();

    /// @dev Total reward insufficient to cover full pool duration.
    error InsufficientTotalReward();

    // ── Constructor ──────────────────────────────────────────────────────

    /**
     * @notice Deploy the staking contract.
     */
    constructor() Ownable(msg.sender) {}

    // ── External functions ───────────────────────────────────────────────

    /**
     * @notice Create a staking pool. Creator deposits total rewards.
     * @dev Uses balance-before/after pattern to handle fee-on-transfer
     *      tokens (H-04). The actual received amount is stored as both
     *      totalReward and remainingReward.
     * @param collection NFT collection eligible for this pool.
     * @param rewardToken ERC-20 reward token (e.g. XOM).
     * @param totalReward Total reward tokens to distribute.
     * @param rewardPerDay Daily reward rate.
     * @param durationDays Pool duration in days.
     * @param rarityEnabled Whether rarity multipliers are used.
     * @return poolId The new pool identifier.
     */
    function createPool(
        address collection,
        address rewardToken,
        uint256 totalReward,
        uint256 rewardPerDay,
        uint16 durationDays,
        bool rarityEnabled
    ) external nonReentrant returns (uint256 poolId) {
        // M-03: Validate non-zero addresses
        if (collection == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();

        if (totalReward == 0) revert ZeroTotalReward();
        if (rewardPerDay == 0) revert ZeroRewardRate();
        if (durationDays == 0) revert ZeroDuration();

        // M-04: Ensure totalReward covers at least one full duration
        // at the configured rewardPerDay rate
        uint256 minRequired = rewardPerDay * uint256(durationDays);
        if (totalReward < minRequired) {
            revert InsufficientTotalReward();
        }

        poolId = nextPoolId;
        ++nextPoolId;

        uint64 endTime = uint64(
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + (uint256(durationDays) * 1 days)
        );

        pools[poolId] = Pool({
            creator: msg.sender,
            collection: collection,
            rewardToken: rewardToken,
            totalReward: totalReward,
            rewardPerDay: rewardPerDay,
            remainingReward: totalReward,
            // solhint-disable-next-line not-rely-on-time
            startTime: uint64(block.timestamp),
            endTime: endTime,
            totalStaked: 0,
            active: true,
            rarityEnabled: rarityEnabled
        });

        // H-04: Use balance-before/after to handle fee-on-transfer tokens
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(
            msg.sender,
            address(this),
            totalReward
        );
        uint256 received = IERC20(rewardToken).balanceOf(address(this))
            - balBefore;

        // Update accounting to reflect actual received amount
        pools[poolId].totalReward = received;
        pools[poolId].remainingReward = received;

        emit PoolCreated(
            poolId,
            msg.sender,
            collection,
            rewardToken,
            received,
            rewardPerDay
        );
    }

    /**
     * @notice Stake an NFT into a pool.
     * @dev Reverts if pool is expired (H-02) or paused.
     * @param poolId Pool to stake in.
     * @param tokenId NFT token ID.
     */
    function stake(
        uint256 poolId,
        uint256 tokenId
    ) external nonReentrant {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        if (!pool.active) revert PoolNotActive();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= pool.endTime) revert PoolExpired();
        if (stakes[poolId][tokenId].active) revert AlreadyStaked();

        uint256 multiplier = MULTIPLIER_PRECISION;

        stakes[poolId][tokenId] = Stake({
            staker: msg.sender,
            // solhint-disable-next-line not-rely-on-time
            stakedAt: uint64(block.timestamp),
            // solhint-disable-next-line not-rely-on-time
            lastClaimAt: uint64(block.timestamp),
            tokenId: tokenId,
            rarityMultiplier: multiplier,
            accumulatedReward: 0,
            active: true
        });

        ++pool.totalStaked;
        totalWeightedStakes[poolId] += multiplier;

        // Transfer NFT to contract
        IERC721(pool.collection).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        emit Staked(poolId, msg.sender, tokenId);
    }

    /**
     * @notice Unstake an NFT and attempt to claim pending rewards.
     * @dev H-01: Reward transfer failure does NOT trap the NFT. If the
     *      reward token transfer fails, the NFT is still returned and
     *      the unclaimed rewards remain in the pool for future retrieval
     *      by the creator after endTime. An EmergencyWithdraw or
     *      RewardTransferFailed event is emitted accordingly.
     * @param poolId Pool the NFT is staked in.
     * @param tokenId NFT token ID.
     */
    function unstake(
        uint256 poolId,
        uint256 tokenId
    ) external nonReentrant {
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) revert StakeNotFound();
        if (s.staker != msg.sender) revert NotStaker();

        Pool storage pool = pools[poolId];

        uint256 pending = _calculatePending(poolId, tokenId);

        // Effects first (CEI pattern)
        s.active = false;
        --pool.totalStaked;
        totalWeightedStakes[poolId] -= s.rarityMultiplier;

        // Attempt reward transfer -- failure must NOT block NFT return
        uint256 paid;
        // solhint-disable-next-line gas-strict-inequalities
        if (pending > 0 && pending <= pool.remainingReward) {
            pool.remainingReward -= pending;
            s.accumulatedReward += pending;

            // H-01: Wrap reward transfer in try/catch so NFT is always
            // returned even if the reward token reverts (e.g. paused
            // USDC, blocklisted address).
            // solhint-disable-next-line no-empty-blocks
            try IERC20(pool.rewardToken).transfer(
                msg.sender, pending
            ) returns (bool success) {
                if (success) {
                    paid = pending;
                } else {
                    // Transfer returned false -- restore remaining
                    pool.remainingReward += pending;
                    s.accumulatedReward -= pending;
                    emit RewardTransferFailed(
                        poolId, msg.sender, pending
                    );
                }
            } catch {
                // Revert in transfer -- restore remaining
                pool.remainingReward += pending;
                s.accumulatedReward -= pending;
                emit RewardTransferFailed(
                    poolId, msg.sender, pending
                );
            }
        }

        // NFT is ALWAYS returned regardless of reward transfer outcome
        IERC721(pool.collection).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit Unstaked(poolId, msg.sender, tokenId, paid);
    }

    /**
     * @notice Claim pending rewards without unstaking.
     * @dev H-05: lastClaimAt only advances when rewards are actually
     *      paid. If remainingReward is insufficient, the call reverts
     *      with InsufficientRewards instead of silently dropping them.
     * @param poolId Pool the NFT is staked in.
     * @param tokenId NFT token ID.
     */
    function claimRewards(
        uint256 poolId,
        uint256 tokenId
    ) external nonReentrant {
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) revert StakeNotFound();
        if (s.staker != msg.sender) revert NotStaker();

        Pool storage pool = pools[poolId];

        uint256 pending = _calculatePending(poolId, tokenId);
        if (pending == 0) return;

        // H-05: Revert if pool cannot cover the pending reward rather
        // than silently advancing the timestamp and losing rewards.
        if (pending > pool.remainingReward) {
            revert InsufficientRewards();
        }

        // H-05: Only advance lastClaimAt AFTER confirming payout.
        // solhint-disable-next-line not-rely-on-time
        s.lastClaimAt = uint64(block.timestamp);
        s.accumulatedReward += pending;
        pool.remainingReward -= pending;

        IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);

        emit RewardsClaimed(poolId, msg.sender, tokenId, pending);
    }

    /**
     * @notice Emergency withdraw: return the NFT without any reward
     *         transfer. Use when reward token is paused/blocklisted.
     * @dev H-01 mitigation: provides a guaranteed exit path for stakers
     *      whose reward token transfer would revert.
     * @param poolId Pool the NFT is staked in.
     * @param tokenId NFT token ID.
     */
    function emergencyWithdraw(
        uint256 poolId,
        uint256 tokenId
    ) external nonReentrant {
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) revert StakeNotFound();
        if (s.staker != msg.sender) revert NotStaker();

        Pool storage pool = pools[poolId];

        // Effects
        s.active = false;
        --pool.totalStaked;
        totalWeightedStakes[poolId] -= s.rarityMultiplier;

        // Return NFT -- no reward transfer attempted
        IERC721(pool.collection).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit EmergencyWithdraw(poolId, msg.sender, tokenId);
    }

    /**
     * @notice Withdraw remaining (undistributed) reward tokens after a
     *         pool has ended.
     * @dev H-03 fix: allows the pool creator to reclaim unused rewards
     *      once the pool's endTime has passed.
     * @param poolId Pool to withdraw from.
     */
    function withdrawRemainingRewards(
        uint256 poolId
    ) external nonReentrant {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        if (pool.creator != msg.sender) revert NotPoolCreator();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pool.endTime) revert PoolStillActive();

        uint256 amount = pool.remainingReward;
        if (amount == 0) revert ZeroAmount();

        pool.remainingReward = 0;

        IERC20(pool.rewardToken).safeTransfer(msg.sender, amount);

        emit RemainingRewardsWithdrawn(poolId, msg.sender, amount);
    }

    /**
     * @notice Set rarity multiplier for a staked NFT (owner only).
     * @dev Claims pending rewards before changing the multiplier.
     *      Uses nonReentrant to prevent reentrancy through reward
     *      token callbacks.
     * @param poolId Pool ID.
     * @param tokenId NFT token ID.
     * @param multiplier Multiplier in MULTIPLIER_PRECISION units
     *        (10000 = 1.0x).
     */
    function setRarityMultiplier(
        uint256 poolId,
        uint256 tokenId,
        uint256 multiplier
    ) external onlyOwner nonReentrant {
        if (multiplier < MIN_MULTIPLIER || multiplier > MAX_MULTIPLIER)
        {
            revert InvalidMultiplier();
        }
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) revert StakeNotFound();

        Pool storage pool = pools[poolId];

        // Claim pending before changing multiplier
        uint256 pending = _calculatePending(poolId, tokenId);

        // Effects first (CEI pattern)
        uint256 oldMultiplier = s.rarityMultiplier;
        // solhint-disable-next-line not-rely-on-time
        s.lastClaimAt = uint64(block.timestamp);
        totalWeightedStakes[poolId] = totalWeightedStakes[poolId]
            - oldMultiplier + multiplier;
        s.rarityMultiplier = multiplier;

        // Interaction: transfer pending rewards
        // solhint-disable-next-line gas-strict-inequalities
        if (pending > 0 && pending <= pool.remainingReward) {
            s.accumulatedReward += pending;
            pool.remainingReward -= pending;
            IERC20(pool.rewardToken).safeTransfer(s.staker, pending);
        }

        emit RarityMultiplierSet(
            poolId, tokenId, oldMultiplier, multiplier
        );
    }

    /**
     * @notice Pause a pool, preventing new stakes. Existing stakers
     *         can still claim rewards and unstake.
     * @param poolId Pool to pause.
     */
    function pausePool(uint256 poolId) external onlyOwner {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        pool.active = false;
        emit PoolPaused(poolId);
    }

    /**
     * @notice Resume a paused pool, allowing new stakes.
     * @param poolId Pool to resume.
     */
    function resumePool(uint256 poolId) external onlyOwner {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        pool.active = true;
        emit PoolResumed(poolId);
    }

    // ── View functions ───────────────────────────────────────────────────

    /**
     * @notice Calculate pending rewards for a staked NFT.
     * @param poolId Pool ID.
     * @param tokenId NFT token ID.
     * @return pending Pending reward amount.
     */
    function pendingRewards(
        uint256 poolId,
        uint256 tokenId
    ) external view returns (uint256 pending) {
        return _calculatePending(poolId, tokenId);
    }

    /**
     * @notice Get the streak bonus multiplier for a stake.
     * @param poolId Pool ID.
     * @param tokenId NFT token ID.
     * @return bonus Streak bonus in MULTIPLIER_PRECISION units.
     */
    function getStreakBonus(
        uint256 poolId,
        uint256 tokenId
    ) external view returns (uint256 bonus) {
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) return STREAK_BONUS_0;
        return _streakBonus(s.stakedAt);
    }

    /**
     * @notice Get full pool details.
     * @param poolId Pool to query.
     * @return creator Pool creator.
     * @return collection NFT collection.
     * @return rewardToken Reward token address.
     * @return totalReward Total rewards.
     * @return remainingReward Remaining rewards.
     * @return totalStaked Number of NFTs staked.
     * @return active Whether the pool is active.
     */
    function getPool(uint256 poolId)
        external
        view
        returns (
            address creator,
            address collection,
            address rewardToken,
            uint256 totalReward,
            uint256 remainingReward,
            uint32 totalStaked,
            bool active
        )
    {
        Pool storage p = pools[poolId];
        return (
            p.creator,
            p.collection,
            p.rewardToken,
            p.totalReward,
            p.remainingReward,
            p.totalStaked,
            p.active
        );
    }

    /**
     * @notice Get stake details.
     * @param poolId Pool ID.
     * @param tokenId Token ID.
     * @return staker Staker address.
     * @return stakedAt When the NFT was staked.
     * @return rarityMultiplier Rarity multiplier.
     * @return accumulatedReward Total rewards claimed so far.
     * @return active Whether the stake is active.
     */
    function getStake(uint256 poolId, uint256 tokenId)
        external
        view
        returns (
            address staker,
            uint64 stakedAt,
            uint256 rarityMultiplier,
            uint256 accumulatedReward,
            bool active
        )
    {
        Stake storage s = stakes[poolId][tokenId];
        return (
            s.staker,
            s.stakedAt,
            s.rarityMultiplier,
            s.accumulatedReward,
            s.active
        );
    }

    // ── Internal functions ───────────────────────────────────────────────

    /**
     * @notice Calculate pending rewards for a stake.
     * @dev H-02: Caps the effective timestamp to pool.endTime so rewards
     *      do not accrue past the intended pool duration. Also returns 0
     *      if lastClaimAt is already at or past the effective end.
     *      M-01: Streak bonus is segmented across tier boundaries so that
     *      each sub-period uses the correct streak multiplier. This
     *      prevents retroactive application of higher tiers to earlier
     *      reward periods.
     * @param poolId Pool ID.
     * @param tokenId Token ID.
     * @return pending Amount of pending rewards.
     */
    function _calculatePending(
        uint256 poolId,
        uint256 tokenId
    ) internal view returns (uint256 pending) {
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) return 0;

        Pool storage pool = pools[poolId];
        uint256 totalWeight = totalWeightedStakes[poolId];
        if (totalWeight == 0) return 0;

        // H-02: Cap effective time to pool.endTime so rewards stop
        // accruing once the pool expires.
        // solhint-disable-next-line not-rely-on-time
        uint256 nowTs = block.timestamp;
        uint256 effectiveNow = nowTs < pool.endTime
            ? nowTs
            : pool.endTime;

        // solhint-disable-next-line gas-strict-inequalities
        if (effectiveNow <= s.lastClaimAt) return 0;

        // M-01: Segment reward calculation across streak tier boundaries
        // to prevent retroactive application of higher bonuses.
        pending = _segmentedReward(
            pool.rewardPerDay,
            s.rarityMultiplier,
            totalWeight,
            s.stakedAt,
            s.lastClaimAt,
            effectiveNow
        );

        if (pending > pool.remainingReward) {
            pending = pool.remainingReward;
        }
    }

    /**
     * @notice Get streak bonus multiplier based on time staked.
     * @param stakedAt Timestamp when NFT was staked.
     * @return bonus Multiplier in MULTIPLIER_PRECISION units.
     */
    function _streakBonus(
        uint64 stakedAt
    ) internal view returns (uint256 bonus) {
        // solhint-disable-next-line not-rely-on-time
        uint256 duration = block.timestamp - stakedAt;
        // solhint-disable-next-line gas-strict-inequalities
        if (duration >= STREAK_TIER3) return STREAK_BONUS_3;
        // solhint-disable-next-line gas-strict-inequalities
        if (duration >= STREAK_TIER2) return STREAK_BONUS_2;
        // solhint-disable-next-line gas-strict-inequalities
        if (duration >= STREAK_TIER1) return STREAK_BONUS_1;
        return STREAK_BONUS_0;
    }

    /**
     * @notice Calculate rewards segmented by streak tier boundaries.
     * @dev Splits the reward period [lastClaim, effectiveNow] at each
     *      streak tier boundary so that each sub-period uses the correct
     *      multiplier. This prevents a higher tier (e.g. 1.5x at 90 days)
     *      from being applied retroactively to the entire claim period.
     * @param rewardPerDay Daily reward rate for the pool.
     * @param rarityMul Rarity multiplier for this stake.
     * @param totalWeight Total weighted stakes in pool.
     * @param stakedAt Timestamp when the NFT was staked.
     * @param lastClaim Timestamp of last reward claim.
     * @param effectiveEnd Effective end timestamp (capped to pool.endTime).
     * @return total Total rewards across all segments.
     */
    function _segmentedReward(
        uint256 rewardPerDay,
        uint256 rarityMul,
        uint256 totalWeight,
        uint64 stakedAt,
        uint64 lastClaim,
        uint256 effectiveEnd
    ) internal pure returns (uint256 total) {
        // Streak tier boundary timestamps relative to stakedAt
        uint256 tier1Start = uint256(stakedAt) + STREAK_TIER1;
        uint256 tier2Start = uint256(stakedAt) + STREAK_TIER2;
        uint256 tier3Start = uint256(stakedAt) + STREAK_TIER3;

        // Boundary points within [lastClaim, effectiveEnd]
        uint256 from = uint256(lastClaim);

        // Segment 0: [from, min(tier1Start, effectiveEnd)] at 1.0x
        if (from < tier1Start && from < effectiveEnd) {
            uint256 segEnd = tier1Start < effectiveEnd
                ? tier1Start : effectiveEnd;
            total += _rewardForSegment(
                rewardPerDay, segEnd - from,
                rarityMul, totalWeight, STREAK_BONUS_0
            );
            from = segEnd;
        }

        // Segment 1: [from, min(tier2Start, effectiveEnd)] at 1.1x
        if (from < tier2Start && from < effectiveEnd) {
            uint256 segEnd = tier2Start < effectiveEnd
                ? tier2Start : effectiveEnd;
            total += _rewardForSegment(
                rewardPerDay, segEnd - from,
                rarityMul, totalWeight, STREAK_BONUS_1
            );
            from = segEnd;
        }

        // Segment 2: [from, min(tier3Start, effectiveEnd)] at 1.25x
        if (from < tier3Start && from < effectiveEnd) {
            uint256 segEnd = tier3Start < effectiveEnd
                ? tier3Start : effectiveEnd;
            total += _rewardForSegment(
                rewardPerDay, segEnd - from,
                rarityMul, totalWeight, STREAK_BONUS_2
            );
            from = segEnd;
        }

        // Segment 3: [from, effectiveEnd] at 1.5x
        if (from < effectiveEnd) {
            total += _rewardForSegment(
                rewardPerDay, effectiveEnd - from,
                rarityMul, totalWeight, STREAK_BONUS_3
            );
        }
    }

    /**
     * @notice Calculate reward for a single time segment.
     * @param rewardPerDay Daily reward rate.
     * @param elapsed Duration of this segment in seconds.
     * @param rarityMul Rarity multiplier.
     * @param totalWeight Total weighted stakes.
     * @param streakMul Streak bonus multiplier for this segment.
     * @return reward Reward amount for this segment.
     */
    function _rewardForSegment(
        uint256 rewardPerDay,
        uint256 elapsed,
        uint256 rarityMul,
        uint256 totalWeight,
        uint256 streakMul
    ) internal pure returns (uint256 reward) {
        reward = (rewardPerDay * elapsed * rarityMul * streakMul)
            / (1 days * totalWeight * MULTIPLIER_PRECISION);
    }
}
