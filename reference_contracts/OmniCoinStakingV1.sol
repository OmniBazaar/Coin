// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./OmniCoinConfig.sol";

contract OmniCoinStaking is Ownable, ReentrancyGuard {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 startTime;
        uint256 lastRewardTime;
        uint256 accumulatedRewards;
    }

    OmniCoinConfig public config;
    IERC20 public token;

    mapping(address => Stake) public stakes;
    mapping(address => uint256) public participationScores;

    event Staked(address indexed user, uint256 amount, uint256 tier);
    event Unstaked(address indexed user, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 amount);
    event ParticipationScoreUpdated(
        address indexed user,
        uint256 oldScore,
        uint256 newScore
    );

    constructor(address _config, address initialOwner) Ownable(initialOwner) {
        config = OmniCoinConfig(_config);
        token = IERC20(msg.sender);
    }

    function stake(
        address user,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(amount > 0, "OmniCoinStaking: invalid amount");

        // Get staking tier
        OmniCoinConfig.StakingTier memory stakingTier = config.getStakingTier(
            amount
        );

        // Update existing stake if any
        Stake storage userStake = stakes[user];
        uint256 tierIndex = _findStakingTierIndex(amount);

        if (userStake.amount > 0) {
            // Claim existing rewards
            uint256 rewards = calculateRewards(user);
            userStake.accumulatedRewards += rewards;
            userStake.lastRewardTime = block.timestamp;

            // Update stake
            userStake.amount += amount;
            userStake.tier = tierIndex;
        } else {
            // Create new stake
            userStake.amount = amount;
            userStake.tier = tierIndex;
            userStake.startTime = block.timestamp;
            userStake.lastRewardTime = block.timestamp;
        }

        emit Staked(user, amount, tierIndex);
    }

    function unstake(
        address user,
        uint256 amount
    ) external onlyOwner nonReentrant {
        Stake storage userStake = stakes[user];
        require(
            userStake.amount >= amount,
            "OmniCoinStaking: insufficient stake"
        );

        // Calculate rewards
        uint256 rewards = calculateRewards(user);
        userStake.accumulatedRewards += rewards;

        // Get staking tier
        OmniCoinConfig.StakingTier memory stakingTier = config.getStakingTier(
            userStake.amount
        );

        // Calculate penalty if applicable
        uint256 penalty = 0;
        if (block.timestamp < userStake.startTime + stakingTier.lockPeriod) {
            penalty = (amount * stakingTier.penaltyRate) / 100;
        }

        // Update stake
        userStake.amount -= amount;
        userStake.lastRewardTime = block.timestamp;

        // Transfer tokens
        if (penalty > 0) {
            require(
                token.transfer(owner(), penalty),
                "OmniCoinStaking: penalty transfer failed"
            );
            amount -= penalty;
        }
        require(
            token.transfer(user, amount),
            "OmniCoinStaking: stake transfer failed"
        );

        emit Unstaked(user, amount, penalty);
    }

    function claimRewards(address user) external onlyOwner nonReentrant {
        Stake storage userStake = stakes[user];
        require(userStake.amount > 0, "OmniCoinStaking: no active stake");

        uint256 rewards = calculateRewards(user);
        userStake.accumulatedRewards += rewards;
        userStake.lastRewardTime = block.timestamp;

        require(
            token.transfer(user, rewards),
            "OmniCoinStaking: reward transfer failed"
        );

        emit RewardsClaimed(user, rewards);
    }

    function updateParticipationScore(
        address user,
        uint256 score
    ) external onlyOwner {
        uint256 oldScore = participationScores[user];
        participationScores[user] = score;

        emit ParticipationScoreUpdated(user, oldScore, score);
    }

    function calculateRewards(address user) public view returns (uint256) {
        Stake storage userStake = stakes[user];
        if (userStake.amount == 0) return 0;

        OmniCoinConfig.StakingTier memory stakingTier = config.getStakingTier(
            userStake.amount
        );

        uint256 timeStaked = block.timestamp - userStake.lastRewardTime;
        uint256 rewards = (userStake.amount *
            stakingTier.rewardRate *
            timeStaked) / (365 days * 100);

        if (config.useParticipationScore()) {
            rewards = (rewards * participationScores[user]) / 100;
        }

        return rewards;
    }

    function getStake(
        address user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 tier,
            uint256 startTime,
            uint256 lastRewardTime,
            uint256 accumulatedRewards
        )
    {
        Stake storage userStake = stakes[user];
        return (
            userStake.amount,
            userStake.tier,
            userStake.startTime,
            userStake.lastRewardTime,
            userStake.accumulatedRewards
        );
    }

    function _findStakingTierIndex(
        uint256 amount
    ) internal view returns (uint256) {
        // Try to find the matching tier by calling getStakingTier
        // If it succeeds, we search for the index
        try config.getStakingTier(amount) returns (
            OmniCoinConfig.StakingTier memory tier
        ) {
            // Find the index by comparing with stored tiers
            for (uint256 i = 0; i < 3; i++) {
                // Assuming max 3 tiers based on constructor
                OmniCoinConfig.StakingTier memory currentTier;
                try config.stakingTiers(i) returns (
                    uint256 minAmount,
                    uint256 maxAmount,
                    uint256 rewardRate,
                    uint256 lockPeriod,
                    uint256 penaltyRate
                ) {
                    if (
                        minAmount == tier.minAmount &&
                        maxAmount == tier.maxAmount
                    ) {
                        return i;
                    }
                } catch {
                    break;
                }
            }
        } catch {
            // Default to tier 0 if no match found
            return 0;
        }

        return 0; // Default tier
    }
}
