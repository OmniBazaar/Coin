// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from
    "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OmniNFTStaking
 * @author OmniBazaar Development Team
 * @notice Collection-based NFT staking with XOM rewards and rarity multipliers.
 * @dev Creators or the protocol fund reward pools for specific collections.
 *      Stakers earn rewards proportional to their rarity multiplier and streak bonus.
 *      No mandatory lock-up — users can unstake at any time but lose their streak.
 *      Streak bonuses: 1.0x (0-6d), 1.1x (7-29d), 1.25x (30-89d), 1.5x (90d+).
 */
contract OmniNFTStaking is ERC721Holder, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Pool does not exist.
    error PoolNotFound();
    /// @dev Pool is not active.
    error PoolNotActive();
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

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice Multiplier precision: 10000 = 1.0x.
    uint256 public constant MULTIPLIER_PRECISION = 10000;
    /// @notice Minimum multiplier: 0.1x.
    uint256 public constant MIN_MULTIPLIER = 1000;
    /// @notice Maximum multiplier: 5.0x.
    uint256 public constant MAX_MULTIPLIER = 50000;

    /// @notice Streak bonus thresholds (in seconds).
    uint256 public constant STREAK_TIER1 = 7 days;
    /// @notice Second streak tier: 30 days.
    uint256 public constant STREAK_TIER2 = 30 days;
    /// @notice Third streak tier: 90 days.
    uint256 public constant STREAK_TIER3 = 90 days;

    /// @notice Streak bonus multipliers (in MULTIPLIER_PRECISION units).
    uint256 public constant STREAK_BONUS_0 = 10000;
    /// @notice 1.1x bonus for 7+ days.
    uint256 public constant STREAK_BONUS_1 = 11000;
    /// @notice 1.25x bonus for 30+ days.
    uint256 public constant STREAK_BONUS_2 = 12500;
    /// @notice 1.5x bonus for 90+ days.
    uint256 public constant STREAK_BONUS_3 = 15000;

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
    struct Stake {
        address staker;
        uint256 tokenId;
        uint64 stakedAt;
        uint64 lastClaimAt;
        uint256 rarityMultiplier;
        uint256 accumulatedReward;
        bool active;
    }

    // ── Storage ──────────────────────────────────────────────────────────
    /// @notice Next pool ID.
    uint256 public nextPoolId;
    /// @notice Pool by ID.
    mapping(uint256 => Pool) public pools;
    /// @notice Stakes: poolId => tokenId => Stake.
    mapping(uint256 => mapping(uint256 => Stake)) public stakes;
    /// @notice Total weighted stakes per pool (for reward distribution).
    mapping(uint256 => uint256) public totalWeightedStakes;

    // ── Constructor ──────────────────────────────────────────────────────
    /**
     * @notice Deploy the staking contract.
     */
    constructor() Ownable(msg.sender) {}

    // ── External functions ───────────────────────────────────────────────

    /**
     * @notice Create a staking pool. Creator deposits total rewards.
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
        if (totalReward == 0) revert ZeroTotalReward();
        if (rewardPerDay == 0) revert ZeroRewardRate();
        if (durationDays == 0) revert ZeroDuration();

        poolId = nextPoolId++;

        uint64 endTime = uint64(
            block.timestamp + (uint256(durationDays) * 1 days)
        );

        pools[poolId] = Pool({
            creator: msg.sender,
            collection: collection,
            rewardToken: rewardToken,
            totalReward: totalReward,
            rewardPerDay: rewardPerDay,
            remainingReward: totalReward,
            startTime: uint64(block.timestamp),
            endTime: endTime,
            totalStaked: 0,
            active: true,
            rarityEnabled: rarityEnabled
        });

        // Transfer rewards from creator to contract
        IERC20(rewardToken).safeTransferFrom(
            msg.sender,
            address(this),
            totalReward
        );

        emit PoolCreated(
            poolId,
            msg.sender,
            collection,
            rewardToken,
            totalReward,
            rewardPerDay
        );
    }

    /**
     * @notice Stake an NFT into a pool.
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
        if (stakes[poolId][tokenId].active) revert AlreadyStaked();

        uint256 multiplier = MULTIPLIER_PRECISION;

        stakes[poolId][tokenId] = Stake({
            staker: msg.sender,
            tokenId: tokenId,
            stakedAt: uint64(block.timestamp),
            lastClaimAt: uint64(block.timestamp),
            rarityMultiplier: multiplier,
            accumulatedReward: 0,
            active: true
        });

        pool.totalStaked += 1;
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
     * @notice Unstake an NFT and claim pending rewards.
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

        s.active = false;
        s.accumulatedReward += pending;
        pool.totalStaked -= 1;
        totalWeightedStakes[poolId] -= s.rarityMultiplier;

        if (pending > 0 && pending <= pool.remainingReward) {
            pool.remainingReward -= pending;
            IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);
        }

        // Return NFT
        IERC721(pool.collection).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit Unstaked(poolId, msg.sender, tokenId, pending);
    }

    /**
     * @notice Claim pending rewards without unstaking.
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

        s.lastClaimAt = uint64(block.timestamp);
        s.accumulatedReward += pending;

        if (pending <= pool.remainingReward) {
            pool.remainingReward -= pending;
            IERC20(pool.rewardToken).safeTransfer(msg.sender, pending);
        }

        emit RewardsClaimed(poolId, msg.sender, tokenId, pending);
    }

    /**
     * @notice Set rarity multiplier for a staked NFT (owner or oracle only).
     * @param poolId Pool ID.
     * @param tokenId NFT token ID.
     * @param multiplier Multiplier in MULTIPLIER_PRECISION units (10000 = 1.0x).
     */
    function setRarityMultiplier(
        uint256 poolId,
        uint256 tokenId,
        uint256 multiplier
    ) external onlyOwner {
        if (multiplier < MIN_MULTIPLIER || multiplier > MAX_MULTIPLIER) {
            revert InvalidMultiplier();
        }
        Stake storage s = stakes[poolId][tokenId];
        if (!s.active) revert StakeNotFound();

        // Claim pending before changing multiplier
        uint256 pending = _calculatePending(poolId, tokenId);
        s.lastClaimAt = uint64(block.timestamp);
        s.accumulatedReward += pending;

        Pool storage pool = pools[poolId];
        if (pending > 0 && pending <= pool.remainingReward) {
            pool.remainingReward -= pending;
            IERC20(pool.rewardToken).safeTransfer(s.staker, pending);
        }

        // Update weighted stakes
        totalWeightedStakes[poolId] =
            totalWeightedStakes[poolId] - s.rarityMultiplier + multiplier;
        s.rarityMultiplier = multiplier;
    }

    /**
     * @notice Pause a pool (owner only).
     * @param poolId Pool to pause.
     */
    function pausePool(uint256 poolId) external onlyOwner {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        pool.active = false;
    }

    /**
     * @notice Resume a paused pool (owner only).
     * @param poolId Pool to resume.
     */
    function resumePool(uint256 poolId) external onlyOwner {
        Pool storage pool = pools[poolId];
        if (pool.creator == address(0)) revert PoolNotFound();
        pool.active = true;
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
     * @dev Calculate pending rewards for a stake.
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

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - s.lastClaimAt;
        if (elapsed == 0) return 0;

        uint256 streakMul = _streakBonus(s.stakedAt);

        // reward = (rewardPerDay / 86400) * elapsed *
        //          (rarityMultiplier / totalWeight) *
        //          (streakBonus / MULTIPLIER_PRECISION)
        pending = (pool.rewardPerDay * elapsed * s.rarityMultiplier *
            streakMul) /
            (1 days * totalWeight * MULTIPLIER_PRECISION);

        if (pending > pool.remainingReward) {
            pending = pool.remainingReward;
        }
    }

    /**
     * @dev Get streak bonus multiplier based on time staked.
     * @param stakedAt Timestamp when NFT was staked.
     * @return bonus Multiplier in MULTIPLIER_PRECISION units.
     */
    function _streakBonus(
        uint64 stakedAt
    ) internal view returns (uint256 bonus) {
        // solhint-disable-next-line not-rely-on-time
        uint256 duration = block.timestamp - stakedAt;
        if (duration >= STREAK_TIER3) return STREAK_BONUS_3;
        if (duration >= STREAK_TIER2) return STREAK_BONUS_2;
        if (duration >= STREAK_TIER1) return STREAK_BONUS_1;
        return STREAK_BONUS_0;
    }
}
