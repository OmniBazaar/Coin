// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";

/**
 * @title OmniCoinStaking
 * @dev Handles staking features for OmniCoin
 */
contract OmniCoinStaking is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 rewardRate;
        uint256 lastRewardTime;
        bool isActive;
    }

    struct StakingTier {
        uint256 minAmount;
        uint256 maxAmount;
        uint256 rewardRate;
        uint256 lockPeriod;
    }

    // State variables
    mapping(address => Stake) public stakes;
    mapping(address => uint256) public totalStaked;
    mapping(address => uint256) public totalRewards;
    StakingTier[] public stakingTiers;
    
    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    uint256 public totalStakedAmount;
    uint256 public totalRewardsDistributed;
    uint256 public minStakeAmount;
    uint256 public maxStakeAmount;

    // Events
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 lockPeriod,
        uint256 rewardRate
    );
    event Unstaked(
        address indexed user,
        uint256 amount,
        uint256 rewards
    );
    event RewardsClaimed(
        address indexed user,
        uint256 amount
    );
    event StakingTierAdded(
        uint256 minAmount,
        uint256 maxAmount,
        uint256 rewardRate,
        uint256 lockPeriod
    );
    event StakingTierUpdated(
        uint256 tierIndex,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 rewardRate,
        uint256 lockPeriod
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _omniCoin,
        address _omniCoinAccount,
        uint256 _minStakeAmount,
        uint256 _maxStakeAmount
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        minStakeAmount = _minStakeAmount;
        maxStakeAmount = _maxStakeAmount;
    }

    /**
     * @dev Add a new staking tier
     */
    function addStakingTier(
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _rewardRate,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(_minAmount < _maxAmount, "Invalid tier range");
        require(_rewardRate > 0, "Invalid reward rate");
        require(_lockPeriod > 0, "Invalid lock period");

        stakingTiers.push(StakingTier({
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod
        }));

        emit StakingTierAdded(_minAmount, _maxAmount, _rewardRate, _lockPeriod);
    }

    /**
     * @dev Update an existing staking tier
     */
    function updateStakingTier(
        uint256 _tierIndex,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _rewardRate,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(_tierIndex < stakingTiers.length, "Invalid tier index");
        require(_minAmount < _maxAmount, "Invalid tier range");
        require(_rewardRate > 0, "Invalid reward rate");
        require(_lockPeriod > 0, "Invalid lock period");

        stakingTiers[_tierIndex] = StakingTier({
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod
        });

        emit StakingTierUpdated(_tierIndex, _minAmount, _maxAmount, _rewardRate, _lockPeriod);
    }

    /**
     * @dev Stake tokens
     */
    function stake(uint256 _amount) external nonReentrant {
        require(_amount >= minStakeAmount, "Amount below minimum");
        require(_amount <= maxStakeAmount, "Amount above maximum");
        require(stakes[msg.sender].amount == 0, "Already staked");

        StakingTier memory tier = getStakingTier(_amount);
        require(tier.minAmount > 0, "No suitable tier found");

        require(
            omniCoin.transferFrom(msg.sender, address(this), _amount),
            "Stake transfer failed"
        );

        stakes[msg.sender] = Stake({
            amount: _amount,
            startTime: block.timestamp,
            lockPeriod: tier.lockPeriod,
            rewardRate: tier.rewardRate,
            lastRewardTime: block.timestamp,
            isActive: true
        });

        totalStaked[msg.sender] = _amount;
        totalStakedAmount += _amount;

        emit Staked(msg.sender, _amount, tier.lockPeriod, tier.rewardRate);
    }

    /**
     * @dev Unstake tokens
     */
    function unstake() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.isActive, "No active stake");
        require(
            block.timestamp >= userStake.startTime + userStake.lockPeriod,
            "Lock period not elapsed"
        );

        uint256 rewards = calculateRewards(msg.sender);
        uint256 totalAmount = userStake.amount + rewards;

        require(
            omniCoin.transfer(msg.sender, totalAmount),
            "Unstake transfer failed"
        );

        totalStaked[msg.sender] = 0;
        totalRewards[msg.sender] += rewards;
        totalStakedAmount -= userStake.amount;
        totalRewardsDistributed += rewards;
        userStake.isActive = false;

        emit Unstaked(msg.sender, userStake.amount, rewards);
    }

    /**
     * @dev Claim rewards
     */
    function claimRewards() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.isActive, "No active stake");

        uint256 rewards = calculateRewards(msg.sender);
        require(rewards > 0, "No rewards to claim");

        require(
            omniCoin.transfer(msg.sender, rewards),
            "Reward transfer failed"
        );

        userStake.lastRewardTime = block.timestamp;
        totalRewards[msg.sender] += rewards;
        totalRewardsDistributed += rewards;

        emit RewardsClaimed(msg.sender, rewards);
    }

    /**
     * @dev Calculate rewards for a user
     */
    function calculateRewards(address _user) public view returns (uint256) {
        Stake storage userStake = stakes[_user];
        if (!userStake.isActive) return 0;

        uint256 timeStaked = block.timestamp - userStake.lastRewardTime;
        return (userStake.amount * userStake.rewardRate * timeStaked) / (365 days * 100);
    }

    /**
     * @dev Get staking tier for an amount
     */
    function getStakingTier(uint256 _amount) public view returns (StakingTier memory) {
        for (uint256 i = 0; i < stakingTiers.length; i++) {
            if (_amount >= stakingTiers[i].minAmount && _amount <= stakingTiers[i].maxAmount) {
                return stakingTiers[i];
            }
        }
        return StakingTier(0, 0, 0, 0);
    }

    /**
     * @dev Get user's staking information
     */
    function getUserStake(address _user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 lockPeriod,
        uint256 rewardRate,
        uint256 lastRewardTime,
        bool isActive,
        uint256 pendingRewards
    ) {
        Stake storage userStake = stakes[_user];
        return (
            userStake.amount,
            userStake.startTime,
            userStake.lockPeriod,
            userStake.rewardRate,
            userStake.lastRewardTime,
            userStake.isActive,
            calculateRewards(_user)
        );
    }

    /**
     * @dev Get total staking statistics
     */
    function getStakingStats() external view returns (
        uint256 totalStaked,
        uint256 totalRewards,
        uint256 stakingTiersCount
    ) {
        return (
            totalStakedAmount,
            totalRewardsDistributed,
            stakingTiers.length
        );
    }
} 