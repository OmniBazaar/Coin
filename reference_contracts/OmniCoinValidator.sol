// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinValidator
 * @author OmniCoin Development Team
 * @notice Validator management contract for OmniCoin network
 * @dev Manages validator registration, staking, and rewards
 */
contract OmniCoinValidator is Ownable, ReentrancyGuard, RegistryAware {
    struct Validator {
        address account;              // 20 bytes
        bool isActive;                // 1 byte
        bool usePrivacy;              // 1 byte - packed with isActive
        // 10 bytes padding
        uint256 stake;                // 32 bytes
        uint256 reputation;           // 32 bytes
        uint256 lastRewardTime;       // 32 bytes
        uint256 accumulatedRewards;   // 32 bytes
    }

    struct ValidatorSet {
        address[] validators;
        uint256 totalStake;
        uint256 minStake;
        uint256 maxValidators;
    }

    /// @notice Reward rate per period
    uint256 public rewardRate;
    /// @notice Reward calculation period
    uint256 public rewardPeriod;
    /// @notice Minimum stake required
    uint256 public minStake;
    /// @notice Maximum number of validators
    uint256 public maxValidators;

    /// @notice Mapping of validator addresses to validator data
    mapping(address => Validator) public validators;
    /// @notice Active validator set information
    ValidatorSet public activeSet;

    /**
     * @notice Emitted when a validator is registered
     * @param validator Validator address
     * @param stake Initial stake amount
     */
    event ValidatorRegistered(address indexed validator, uint256 indexed stake);
    
    /**
     * @notice Emitted when a validator is unregistered
     * @param validator Validator address
     */
    event ValidatorUnregistered(address indexed validator);
    
    /**
     * @notice Emitted when a validator stakes tokens
     * @param validator Validator address
     * @param amount Amount staked
     */
    event ValidatorStaked(address indexed validator, uint256 indexed amount);
    
    /**
     * @notice Emitted when a validator unstakes tokens
     * @param validator Validator address
     * @param amount Amount unstaked
     */
    event ValidatorUnstaked(address indexed validator, uint256 indexed amount);
    
    /**
     * @notice Emitted when rewards are claimed
     * @param validator Validator address
     * @param amount Reward amount
     */
    event RewardsClaimed(address indexed validator, uint256 indexed amount);
    
    /**
     * @notice Emitted when reward rate is updated
     * @param oldRate Previous reward rate
     * @param newRate New reward rate
     */
    event RewardRateUpdated(uint256 indexed oldRate, uint256 indexed newRate);
    
    /**
     * @notice Emitted when reward period is updated
     * @param oldPeriod Previous reward period
     * @param newPeriod New reward period
     */
    event RewardPeriodUpdated(uint256 indexed oldPeriod, uint256 indexed newPeriod);
    
    /**
     * @notice Emitted when minimum stake is updated
     * @param oldStake Previous minimum stake
     * @param newStake New minimum stake
     */
    event MinStakeUpdated(uint256 indexed oldStake, uint256 indexed newStake);
    
    /**
     * @notice Emitted when maximum validators is updated
     * @param oldMax Previous maximum validators
     * @param newMax New maximum validators
     */
    event MaxValidatorsUpdated(uint256 indexed oldMax, uint256 indexed newMax);
    
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

    /**
     * @notice Initializes the validator contract
     * @param _registry Address of the registry contract
     * @param initialOwner Address of the initial contract owner
     */
    constructor(address _registry, address initialOwner) 
        Ownable(initialOwner) 
        RegistryAware(_registry) 
    {
        rewardRate = 100; // 1% per period
        rewardPeriod = 1 days;
        minStake = 1_000_000 * 10 ** 6; // 1,000,000 XOM (1 million tokens, 6 decimals)
        maxValidators = 100;

        activeSet.minStake = minStake;
        activeSet.maxValidators = maxValidators;
    }

    /**
     * @notice Registers the caller as a validator
     * @dev Requires the caller to have at least minStake tokens
     * @param usePrivacy Whether to use PrivateOmniCoin for staking
     */
    function registerValidator(bool usePrivacy) external nonReentrant {
        if (validators[msg.sender].isActive) revert AlreadyRegistered();
        
        address tokenContract = _getTokenContract(usePrivacy);
        if (IERC20(tokenContract).balanceOf(msg.sender) < minStake) revert InsufficientBalance();

        validators[msg.sender] = Validator({
            account: msg.sender,
            stake: 0,
            reputation: 0,
            lastRewardTime: block.timestamp, // solhint-disable-line not-rely-on-time
            accumulatedRewards: 0,
            isActive: true,
            usePrivacy: usePrivacy
        });

        emit ValidatorRegistered(msg.sender, 0);
    }

    /**
     * @notice Unregisters the caller as a validator
     * @dev Requires the validator to have no stake remaining
     */
    function unregisterValidator() external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();
        if (validator.stake != 0) revert StillHasStake();

        validator.isActive = false;

        emit ValidatorUnregistered(msg.sender);
    }

    /**
     * @notice Stakes tokens for the validator
     * @param amount The amount of tokens to stake
     * @dev Claims pending rewards before updating stake
     */
    function stake(uint256 amount) external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();
        if (amount == 0) revert InvalidAmount();
        
        address tokenContract = _getTokenContract(validator.usePrivacy);
        if (IERC20(tokenContract).balanceOf(msg.sender) < amount) revert InsufficientBalance();

        // Claim pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        if (pendingRewards > 0) {
            validator.accumulatedRewards += pendingRewards;
        }

        // Update stake
        validator.stake += amount;
        activeSet.totalStake += amount;

        // Update validator set
        if (validator.stake > minStake - 1 && 
            !isInActiveSet(msg.sender) && 
            activeSet.validators.length < maxValidators
        ) {
            activeSet.validators.push(msg.sender);
        }

        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), amount)) 
            revert TransferFailed();

        emit ValidatorStaked(msg.sender, amount);
    }

    /**
     * @notice Unstakes tokens for the validator
     * @param amount The amount of tokens to unstake
     * @dev Claims pending rewards before updating stake
     */
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

        address tokenContract = _getTokenContract(validator.usePrivacy);
        if (!IERC20(tokenContract).transfer(msg.sender, amount)) revert TransferFailed();

        emit ValidatorUnstaked(msg.sender, amount);
    }

    /**
     * @notice Claims accumulated rewards for the validator
     * @dev Transfers all pending and accumulated rewards to the validator
     */
    function claimRewards() external nonReentrant {
        Validator storage validator = validators[msg.sender];
        if (!validator.isActive) revert NotActiveValidator();

        uint256 pendingRewards = calculateRewards(msg.sender);
        uint256 totalRewards = validator.accumulatedRewards + pendingRewards;
        if (totalRewards == 0) revert NoRewardsAvailable();

        validator.accumulatedRewards = 0;
        validator.lastRewardTime = block.timestamp; // solhint-disable-line not-rely-on-time

        address tokenContract = _getTokenContract(validator.usePrivacy);
        if (!IERC20(tokenContract).transfer(msg.sender, totalRewards)) revert RewardTransferFailed();

        emit RewardsClaimed(msg.sender, totalRewards);
    }

    /**
     * @notice Sets the reward rate per period
     * @param _rate The new reward rate (in basis points, 100 = 1%)
     */
    function setRewardRate(uint256 _rate) external onlyOwner {
        emit RewardRateUpdated(rewardRate, _rate);
        rewardRate = _rate;
    }

    /**
     * @notice Sets the reward calculation period
     * @param _period The new reward period in seconds
     */
    function setRewardPeriod(uint256 _period) external onlyOwner {
        emit RewardPeriodUpdated(rewardPeriod, _period);
        rewardPeriod = _period;
    }

    /**
     * @notice Sets the minimum stake required for validators
     * @param _stake The new minimum stake amount
     */
    function setMinStake(uint256 _stake) external onlyOwner {
        emit MinStakeUpdated(minStake, _stake);
        minStake = _stake;
        activeSet.minStake = _stake;
    }

    /**
     * @notice Sets the maximum number of validators
     * @param _max The new maximum number of validators
     */
    function setMaxValidators(uint256 _max) external onlyOwner {
        emit MaxValidatorsUpdated(maxValidators, _max);
        maxValidators = _max;
        activeSet.maxValidators = _max;
    }

    /**
     * @notice Calculates pending rewards for a validator
     * @param validator The validator address
     * @return The amount of pending rewards
     */
    function calculateRewards(address validator) public view returns (uint256) {
        Validator storage v = validators[validator];
        if (!v.isActive || v.stake == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - v.lastRewardTime; // solhint-disable-line not-rely-on-time
        uint256 periods = timeElapsed / rewardPeriod;
        if (periods == 0) {
            return 0;
        }

        uint256 rewardPerPeriod = (v.stake * rewardRate) / 10000;
        return rewardPerPeriod * periods;
    }

    /**
     * @notice Gets validator information
     * @param account The validator address
     * @return validatorAddress The validator's address
     * @return stakeAmount The validator's stake amount
     * @return reputation The validator's reputation score
     * @return lastRewardTime The last time rewards were calculated
     * @return accumulatedRewards The unclaimed reward amount
     * @return isActive Whether the validator is active
     * @return usePrivacy Whether the validator uses PrivateOmniCoin
     */
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
            bool isActive,
            bool usePrivacy
        )
    {
        Validator storage v = validators[account];
        return (
            v.account,
            v.stake,
            v.reputation,
            v.lastRewardTime,
            v.accumulatedRewards,
            v.isActive,
            v.usePrivacy
        );
    }

    /**
     * @notice Gets the active validator set information
     * @return validatorList Array of active validator addresses
     * @return totalStake Total amount staked by all validators
     * @return minimumStake Minimum stake required
     * @return maximumValidators Maximum number of validators allowed
     */
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

    /**
     * @notice Get token contract based on privacy preference
     * @dev Helper to get appropriate token contract
     * @param usePrivacy Whether to use private token
     * @return Token contract address
     */
    function _getTokenContract(bool usePrivacy) internal view returns (address) {
        if (usePrivacy) {
            return _getContract(REGISTRY.PRIVATE_OMNICOIN());
        } else {
            return _getContract(REGISTRY.OMNICOIN());
        }
    }
    
    /**
     * @notice Removes a validator from the active set
     * @param validator The validator address to remove
     */
    function removeFromActiveSet(address validator) internal {
        for (uint256 i = 0; i < activeSet.validators.length; ++i) {
            if (activeSet.validators[i] == validator) {
                activeSet.validators[i] = activeSet.validators[
                    activeSet.validators.length - 1
                ];
                activeSet.validators.pop();
                break;
            }
        }
    }

    /**
     * @notice Checks if a validator is in the active set
     * @param validator The validator address to check
     * @return True if the validator is in the active set
     */
    function isInActiveSet(address validator) internal view returns (bool) {
        for (uint256 i = 0; i < activeSet.validators.length; ++i) {
            if (activeSet.validators[i] == validator) {
                return true;
            }
        }
        return false;
    }
}
