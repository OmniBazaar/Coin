// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniCoinValidator is Ownable, ReentrancyGuard {
    struct Validator {
        address account;
        uint256 stake;
        uint256 reputation;
        uint256 lastRewardTime;
        uint256 accumulatedRewards;
        bool isActive;
    }

    struct ValidatorSet {
        address[] validators;
        uint256 totalStake;
        uint256 minStake;
        uint256 maxValidators;
    }

    // Custom errors
    error InvalidValidator();
    error AlreadyRegistered();
    error InsufficientBalance();
    error TransferFailed();
    error NotActiveValidator();
    error StillHasStake();
    error InsufficientStakeAmount();
    error ValidatorSetFull();
    error NoRewardsAvailable();
    error RewardTransferFailed();
    error InvalidAddress();
    error InvalidAmount();

    IERC20 public token;
    uint256 public rewardRate;
    uint256 public rewardPeriod;
    uint256 public minStake;
    uint256 public maxValidators;

    mapping(address => Validator) public validators;
    ValidatorSet public activeSet;

    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorUnregistered(address indexed validator);
    event ValidatorStaked(address indexed validator, uint256 amount);
    event ValidatorUnstaked(address indexed validator, uint256 amount);
    event RewardsClaimed(address indexed validator, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MinStakeUpdated(uint256 oldStake, uint256 newStake);
    event MaxValidatorsUpdated(uint256 oldMax, uint256 newMax);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
        rewardRate = 100; // 1% per period
        rewardPeriod = 1 days;
        minStake = 1000 * 10 ** 18; // 1000 tokens
        maxValidators = 100;

        activeSet.minStake = minStake;
        activeSet.maxValidators = maxValidators;
    }

    function registerValidator() external nonReentrant {
        if (validators[msg.sender].isActive) revert AlreadyRegistered();
        if (token.balanceOf(msg.sender) < minStake) revert InsufficientBalance();

        validators[msg.sender] = Validator({
            account: msg.sender,
            stake: 0,
            reputation: 0,
            lastRewardTime: block.timestamp,
            accumulatedRewards: 0,
            isActive: true
        });

        emit ValidatorRegistered(msg.sender, 0);
    }

    function unregisterValidator() external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();
        if (validator.stake != 0) revert StillHasStake();

        validator.isActive = false;

        emit ValidatorUnregistered(msg.sender);
    }

    function stake(uint256 amount) external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();
        if (amount == 0) revert InvalidAmount();
        if (token.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        // Claim pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        if (pendingRewards > 0) {
            validator.accumulatedRewards += pendingRewards;
        }

        // Update stake
        validator.stake += amount;
        activeSet.totalStake += amount;

        // Update validator set
        if (validator.stake >= minStake && !isInActiveSet(msg.sender)) {
            if (activeSet.validators.length < maxValidators) {
                activeSet.validators.push(msg.sender);
            }
        }

        if (!token.transferFrom(msg.sender, address(this), amount)) 
            revert TransferFailed();

        emit ValidatorStaked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();
        if (amount == 0) revert InvalidAmount();
        if (amount > validator.stake) revert InsufficientStakeAmount();

        // Claim pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        if (pendingRewards > 0) {
            validator.accumulatedRewards += pendingRewards;
        }

        // Update stake
        validator.stake -= amount;
        activeSet.totalStake -= amount;

        // Update validator set
        if (validator.stake < minStake && isInActiveSet(msg.sender)) {
            removeFromActiveSet(msg.sender);
        }

        if (!token.transfer(msg.sender, amount)) revert TransferFailed();

        emit ValidatorUnstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();

        uint256 pendingRewards = calculateRewards(msg.sender);
        uint256 totalRewards = validator.accumulatedRewards + pendingRewards;
        if (totalRewards == 0) revert NoRewardsAvailable();

        validator.accumulatedRewards = 0;
        validator.lastRewardTime = block.timestamp;

        if (!token.transfer(msg.sender, totalRewards)) revert RewardTransferFailed();

        emit RewardsClaimed(msg.sender, totalRewards);
    }

    function setRewardRate(uint256 _rate) external onlyOwner {
        emit RewardRateUpdated(rewardRate, _rate);
        rewardRate = _rate;
    }

    function setRewardPeriod(uint256 _period) external onlyOwner {
        emit RewardPeriodUpdated(rewardPeriod, _period);
        rewardPeriod = _period;
    }

    function setMinStake(uint256 _stake) external onlyOwner {
        emit MinStakeUpdated(minStake, _stake);
        minStake = _stake;
        activeSet.minStake = _stake;
    }

    function setMaxValidators(uint256 _max) external onlyOwner {
        emit MaxValidatorsUpdated(maxValidators, _max);
        maxValidators = _max;
        activeSet.maxValidators = _max;
    }

    function calculateRewards(address validator) public view returns (uint256) {
        Validator storage v = validators[validator];
        if (!v.isActive || v.stake == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - v.lastRewardTime;
        uint256 periods = timeElapsed / rewardPeriod;
        if (periods == 0) {
            return 0;
        }

        uint256 rewardPerPeriod = (v.stake * rewardRate) / 10000;
        return rewardPerPeriod * periods;
    }

    function isInActiveSet(address validator) public view returns (bool) {
        for (uint256 i = 0; i < activeSet.validators.length; i++) {
            if (activeSet.validators[i] == validator) {
                return true;
            }
        }
        return false;
    }

    function removeFromActiveSet(address validator) internal {
        for (uint256 i = 0; i < activeSet.validators.length; i++) {
            if (activeSet.validators[i] == validator) {
                activeSet.validators[i] = activeSet.validators[
                    activeSet.validators.length - 1
                ];
                activeSet.validators.pop();
                break;
            }
        }
    }

    function getValidator(
        address account
    )
        external
        view
        returns (
            address validatorAddress,
            uint256 stakeAmount,
            uint256 reputation,
            uint256 lastRewardTime,
            uint256 accumulatedRewards,
            bool isActive
        )
    {
        Validator storage v = validators[account];
        return (
            v.account,
            v.stake,
            v.reputation,
            v.lastRewardTime,
            v.accumulatedRewards,
            v.isActive
        );
    }

    function getActiveSet()
        external
        view
        returns (
            address[] memory validatorList,
            uint256 totalStake,
            uint256 minimumStake,
            uint256 maximumValidators
        )
    {
        return (
            activeSet.validators,
            activeSet.totalStake,
            activeSet.minStake,
            activeSet.maxValidators
        );
    }
}
