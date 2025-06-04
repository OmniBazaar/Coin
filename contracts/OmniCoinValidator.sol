// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinReputation.sol";
import "./OmniCoinStaking.sol";

/**
 * @title OmniCoinValidator
 * @dev Manages validator selection and rewards based on staking and reputation
 */
contract OmniCoinValidator is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct ValidatorInfo {
        bool isActive;
        uint256 totalStaked;
        uint256 lastRewardTime;
        uint256 totalRewards;
        uint256 performanceScore;
        uint256 uptime;
        uint256 lastHeartbeat;
    }

    struct ValidatorMetrics {
        uint256 blocksProposed;
        uint256 blocksValidated;
        uint256 transactionsProcessed;
        uint256 slashingEvents;
        uint256 lastUpdate;
    }

    // State variables
    mapping(address => ValidatorInfo) public validators;
    mapping(address => ValidatorMetrics) public validatorMetrics;
    address[] public activeValidators;
    
    OmniCoin public omniCoin;
    OmniCoinReputation public reputation;
    OmniCoinStaking public staking;
    
    uint256 public minStakeAmount;
    uint256 public maxValidators;
    uint256 public rewardInterval;
    uint256 public heartbeatInterval;
    uint256 public slashingPenalty;
    uint256 public totalRewardsDistributed;

    // Events
    event ValidatorRegistered(address indexed validator);
    event ValidatorDeregistered(address indexed validator);
    event ValidatorRewarded(address indexed validator, uint256 amount);
    event ValidatorSlashed(address indexed validator, uint256 amount, string reason);
    event HeartbeatReceived(address indexed validator);
    event ValidatorMetricsUpdated(
        address indexed validator,
        uint256 blocksProposed,
        uint256 blocksValidated,
        uint256 transactionsProcessed
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
        address _reputation,
        address _staking,
        uint256 _minStakeAmount,
        uint256 _maxValidators,
        uint256 _rewardInterval,
        uint256 _heartbeatInterval,
        uint256 _slashingPenalty
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        reputation = OmniCoinReputation(_reputation);
        staking = OmniCoinStaking(_staking);
        minStakeAmount = _minStakeAmount;
        maxValidators = _maxValidators;
        rewardInterval = _rewardInterval;
        heartbeatInterval = _heartbeatInterval;
        slashingPenalty = _slashingPenalty;
    }

    /**
     * @dev Register as a validator
     */
    function registerValidator() external nonReentrant {
        require(!validators[msg.sender].isActive, "Already registered");
        require(reputation.qualifiesAsValidator(msg.sender), "Insufficient reputation");
        require(staking.getStakeAmount(msg.sender) >= minStakeAmount, "Insufficient stake");
        require(activeValidators.length < maxValidators, "Max validators reached");

        validators[msg.sender] = ValidatorInfo({
            isActive: true,
            totalStaked: staking.getStakeAmount(msg.sender),
            lastRewardTime: block.timestamp,
            totalRewards: 0,
            performanceScore: 100,
            uptime: 100,
            lastHeartbeat: block.timestamp
        });

        validatorMetrics[msg.sender] = ValidatorMetrics({
            blocksProposed: 0,
            blocksValidated: 0,
            transactionsProcessed: 0,
            slashingEvents: 0,
            lastUpdate: block.timestamp
        });

        activeValidators.push(msg.sender);
        emit ValidatorRegistered(msg.sender);
    }

    /**
     * @dev Deregister as a validator
     */
    function deregisterValidator() external nonReentrant {
        require(validators[msg.sender].isActive, "Not registered");
        
        validators[msg.sender].isActive = false;
        
        // Remove from active validators
        for (uint i = 0; i < activeValidators.length; i++) {
            if (activeValidators[i] == msg.sender) {
                activeValidators[i] = activeValidators[activeValidators.length - 1];
                activeValidators.pop();
                break;
            }
        }
        
        emit ValidatorDeregistered(msg.sender);
    }

    /**
     * @dev Submit validator heartbeat
     */
    function submitHeartbeat() external {
        require(validators[msg.sender].isActive, "Not registered");
        require(
            block.timestamp >= validators[msg.sender].lastHeartbeat + heartbeatInterval,
            "Too early for heartbeat"
        );

        validators[msg.sender].lastHeartbeat = block.timestamp;
        validators[msg.sender].uptime = 100; // Reset uptime on successful heartbeat
        
        emit HeartbeatReceived(msg.sender);
    }

    /**
     * @dev Update validator metrics
     */
    function updateMetrics(
        uint256 _blocksProposed,
        uint256 _blocksValidated,
        uint256 _transactionsProcessed
    ) external {
        require(validators[msg.sender].isActive, "Not registered");
        
        ValidatorMetrics storage metrics = validatorMetrics[msg.sender];
        metrics.blocksProposed += _blocksProposed;
        metrics.blocksValidated += _blocksValidated;
        metrics.transactionsProcessed += _transactionsProcessed;
        metrics.lastUpdate = block.timestamp;
        
        // Update performance score
        uint256 newScore = calculatePerformanceScore(metrics);
        validators[msg.sender].performanceScore = newScore;
        
        emit ValidatorMetricsUpdated(
            msg.sender,
            metrics.blocksProposed,
            metrics.blocksValidated,
            metrics.transactionsProcessed
        );
    }

    /**
     * @dev Calculate validator performance score
     */
    function calculatePerformanceScore(ValidatorMetrics memory metrics) public pure returns (uint256) {
        if (metrics.blocksProposed == 0) return 0;
        
        uint256 validationRate = (metrics.blocksValidated * 100) / metrics.blocksProposed;
        uint256 transactionRate = metrics.transactionsProcessed / metrics.blocksValidated;
        
        return (validationRate * 60 + transactionRate * 40) / 100;
    }

    /**
     * @dev Distribute rewards to validators
     */
    function distributeRewards() external onlyOwner {
        uint256 totalReward = omniCoin.balanceOf(address(this));
        require(totalReward > 0, "No rewards to distribute");
        
        uint256 totalScore = 0;
        for (uint i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            if (validator.isActive) {
                totalScore += validator.performanceScore * validator.uptime;
            }
        }
        
        for (uint i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            if (validator.isActive) {
                uint256 reward = (totalReward * validator.performanceScore * validator.uptime) / totalScore;
                if (reward > 0) {
                    require(omniCoin.transfer(activeValidators[i], reward), "Reward transfer failed");
                    validator.totalRewards += reward;
                    validator.lastRewardTime = block.timestamp;
                    totalRewardsDistributed += reward;
                    
                    emit ValidatorRewarded(activeValidators[i], reward);
                }
            }
        }
    }

    /**
     * @dev Slash a validator for misbehavior
     */
    function slashValidator(address _validator, string calldata _reason) external onlyOwner {
        require(validators[_validator].isActive, "Not an active validator");
        
        uint256 slashAmount = (validators[_validator].totalStaked * slashingPenalty) / 100;
        require(omniCoin.transferFrom(_validator, address(this), slashAmount), "Slashing transfer failed");
        
        validatorMetrics[_validator].slashingEvents++;
        validators[_validator].performanceScore = 0;
        
        emit ValidatorSlashed(_validator, slashAmount, _reason);
    }

    /**
     * @dev Get active validators
     */
    function getActiveValidators() external view returns (address[] memory) {
        return activeValidators;
    }

    /**
     * @dev Get validator info
     */
    function getValidatorInfo(address _validator) external view returns (
        bool isActive,
        uint256 totalStaked,
        uint256 lastRewardTime,
        uint256 totalRewards,
        uint256 performanceScore,
        uint256 uptime,
        uint256 lastHeartbeat
    ) {
        ValidatorInfo storage info = validators[_validator];
        return (
            info.isActive,
            info.totalStaked,
            info.lastRewardTime,
            info.totalRewards,
            info.performanceScore,
            info.uptime,
            info.lastHeartbeat
        );
    }

    /**
     * @dev Get validator metrics
     */
    function getValidatorMetrics(address _validator) external view returns (
        uint256 blocksProposed,
        uint256 blocksValidated,
        uint256 transactionsProcessed,
        uint256 slashingEvents,
        uint256 lastUpdate
    ) {
        ValidatorMetrics storage metrics = validatorMetrics[_validator];
        return (
            metrics.blocksProposed,
            metrics.blocksValidated,
            metrics.transactionsProcessed,
            metrics.slashingEvents,
            metrics.lastUpdate
        );
    }

    /**
     * @dev Update contract parameters
     */
    function updateParameters(
        uint256 _minStakeAmount,
        uint256 _maxValidators,
        uint256 _rewardInterval,
        uint256 _heartbeatInterval,
        uint256 _slashingPenalty
    ) external onlyOwner {
        minStakeAmount = _minStakeAmount;
        maxValidators = _maxValidators;
        rewardInterval = _rewardInterval;
        heartbeatInterval = _heartbeatInterval;
        slashingPenalty = _slashingPenalty;
    }
} 