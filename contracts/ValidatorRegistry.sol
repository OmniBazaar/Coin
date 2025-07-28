// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title ValidatorRegistry
 * @author OmniBazaar Team
 * @notice Registry and management system for unified validators with proof of participation
 * @dev Implements validator registration, staking, scoring, and slashing mechanisms
 *
 * Features:
 * - Validator registration and staking
 * - Proof of Participation scoring system
 * - Hardware requirements verification
 * - Slashing for malicious behavior
 * - Automatic validator selection for consensus
 * - Economic incentives and penalties
 */
contract ValidatorRegistry is ReentrancyGuard, Pausable, AccessControl, RegistryAware {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Enums
    /// @notice Validator lifecycle states
    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        SUSPENDED,
        JAILED,
        EXITING
    }

    // Structs
    /// @notice Complete information about a validator
    struct ValidatorInfo {
        address validatorAddress;
        uint256 stakedAmount;
        uint256 participationScore;
        ValidatorStatus status;
        uint256 registrationTime;
        uint256 lastActivityTime;
        string nodeId;
        HardwareSpecs hardwareSpecs;
        PerformanceMetrics performance;
        uint256 totalRewards;
        uint256 slashingHistory;
        uint256 exitTime;
    }

    /// @notice Hardware specifications for validator nodes
    struct HardwareSpecs {
        uint256 cpuCores;
        uint256 ramGB;
        uint256 storageGB;
        uint256 networkSpeed; // Mbps
        bool verified;
        uint256 verificationTime;
    }

    /// @notice Performance metrics tracked for each validator
    struct PerformanceMetrics {
        uint256 blocksProduced;
        uint256 uptime; // Percentage (0-10000, where 10000 = 100%)
        uint256 tradingVolumeFacilitated;
        uint256 chatMessages;
        uint256 ipfsDataStored;
        uint256 lastUpdateTime;
    }

    /// @notice Configuration parameters for staking mechanism
    struct StakingConfig {
        uint256 minimumStake;
        uint256 maximumStake;
        uint256 slashingRate; // Basis points (100 = 1%)
        uint256 rewardRate; // Annual rate in basis points
        uint256 unstakingPeriod; // Seconds
        uint256 participationThreshold; // Minimum score to stay active
    }

    // State variables - Constants
    /// @notice Role for validator management operations
    bytes32 public constant VALIDATOR_MANAGER_ROLE =
        keccak256("VALIDATOR_MANAGER_ROLE");
    /// @notice Role for slashing operations
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    /// @notice Role for oracle data submission
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // Hardware requirements
    /// @notice Minimum required CPU cores
    uint256 public constant MIN_CPU_CORES = 4;
    /// @notice Minimum required RAM in GB
    uint256 public constant MIN_RAM_GB = 8;
    /// @notice Minimum required storage in GB
    uint256 public constant MIN_STORAGE_GB = 100;
    /// @notice Minimum required network speed in Mbps
    uint256 public constant MIN_NETWORK_SPEED = 100;

    // Participation scoring constants
    /// @notice Maximum possible participation score
    uint256 public constant MAX_PARTICIPATION_SCORE = 100;
    /// @notice Weight for block production in participation score
    uint256 public constant BLOCK_PRODUCTION_WEIGHT = 30;
    /// @notice Weight for uptime in participation score
    uint256 public constant UPTIME_WEIGHT = 25;
    /// @notice Weight for trading volume in participation score
    uint256 public constant TRADING_VOLUME_WEIGHT = 20;
    /// @notice Weight for chat activity in participation score
    uint256 public constant CHAT_ACTIVITY_WEIGHT = 15;
    /// @notice Weight for IPFS storage in participation score
    uint256 public constant IPFS_STORAGE_WEIGHT = 10;

    // State variables - Immutables removed - will use registry

    // State variables - Storage
    /// @notice Mapping from validator address to their information
    mapping(address => ValidatorInfo) public validators;
    /// @notice Mapping from node ID to validator address
    mapping(string => address) public nodeIdToValidator;
    /// @notice List of all validator addresses
    address[] public validatorList;

    /// @notice Current staking configuration parameters
    StakingConfig public stakingConfig;

    /// @notice Total amount of tokens staked across all validators
    uint256 public totalStaked;
    /// @notice Total number of registered validators
    uint256 public totalValidators;
    /// @notice Number of currently active validators
    uint256 public activeValidators;
    /// @notice Current epoch number
    uint256 public currentEpoch;
    /// @notice Duration of each epoch in seconds
    uint256 public epochDuration = 1 hours;
    /// @notice Timestamp of the last epoch transition
    uint256 public lastEpochTime;

    // Events
    /// @notice Emitted when a new validator registers
    /// @param validator Address of the registered validator
    /// @param stake Initial stake amount
    /// @param nodeId Unique node identifier
    /// @param timestamp Registration timestamp
    event ValidatorRegistered(
        address indexed validator,
        uint256 indexed stake,
        string indexed nodeId,
        uint256 timestamp
    );

    /// @notice Emitted when a validator increases their stake
    /// @param validator Address of the validator
    /// @param additionalStake Amount of stake added
    /// @param totalStake New total stake amount
    event ValidatorStakeIncreased(
        address indexed validator,
        uint256 indexed additionalStake,
        uint256 indexed totalStake
    );

    /// @notice Emitted when a validator deregisters
    /// @param validator Address of the deregistered validator
    /// @param refundedStake Amount of stake refunded
    /// @param reason Deregistration reason
    event ValidatorDeregistered(
        address indexed validator,
        uint256 indexed refundedStake,
        string indexed reason
    );

    /// @notice Emitted when a validator's participation score changes
    /// @param validator Address of the validator
    /// @param oldScore Previous participation score
    /// @param newScore Updated participation score
    /// @param reason Reason for the update
    event ParticipationScoreUpdated(
        address indexed validator,
        uint256 indexed oldScore,
        uint256 indexed newScore,
        string reason
    );

    /// @notice Emitted when a validator is slashed
    /// @param validator Address of the slashed validator
    /// @param slashedAmount Amount slashed from stake
    /// @param remainingStake Remaining stake after slashing
    /// @param reason Slashing reason
    event ValidatorSlashed(
        address indexed validator,
        uint256 indexed slashedAmount,
        uint256 indexed remainingStake,
        string indexed reason
    );

    /// @notice Emitted when rewards are distributed to a validator
    /// @param validator Address of the validator
    /// @param amount Reward amount
    /// @param participationScore Validator's participation score at time of reward
    event ValidatorRewardDistributed(
        address indexed validator,
        uint256 indexed amount,
        uint256 indexed participationScore
    );

    /// @notice Emitted when a validator's status changes
    /// @param validator Address of the validator
    /// @param oldStatus Previous status
    /// @param newStatus New status
    event ValidatorStatusChanged(
        address indexed validator,
        ValidatorStatus indexed oldStatus,
        ValidatorStatus indexed newStatus
    );

    // Custom errors
    error InvalidStakingToken();
    error MinimumStakeMustBePositive();
    error MaximumStakeTooLow();
    error InsufficientStake();
    error StakeExceedsMaximum();
    error NodeIdRequired();
    error AlreadyRegistered();
    error NodeIdAlreadyTaken();
    error HardwareRequirementsNotMet();
    error NotAValidator();
    error AdditionalStakeMustBePositive();
    error AlreadyExiting();
    error NotInExitingState();
    error UnstakingPeriodNotCompleted();
    error ValidatorNotFound();
    error SlashAmountMustBePositive();
    error SlashAmountExceedsStake();
    error ArraysLengthMismatch();
    error EpochNotReady();
    error NotEnoughActiveValidators();
    error EpochDurationTooShort();

    /// @notice Initialize the ValidatorRegistry contract
    /// @param _registry Address of the OmniCoinRegistry contract
    /// @param _minimumStake Minimum stake amount required to become a validator
    /// @param _maximumStake Maximum stake amount allowed per validator
    constructor(
        address _registry,
        uint256 _minimumStake,
        uint256 _maximumStake
    ) RegistryAware(_registry) {
        if (_minimumStake == 0) revert MinimumStakeMustBePositive();
        if (_maximumStake < _minimumStake) revert MaximumStakeTooLow();

        stakingConfig = StakingConfig({
            minimumStake: _minimumStake,
            maximumStake: _maximumStake,
            slashingRate: 500, // 5% slashing rate
            rewardRate: 1200, // 12% annual reward rate
            unstakingPeriod: 7 days,
            participationThreshold: 70 // 70% minimum participation score
        });

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_MANAGER_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);

        /* solhint-disable-next-line not-rely-on-time */
        lastEpochTime = block.timestamp;
    }

    /// @notice Register as a validator with initial stake
    /// @param stakeAmount Amount of tokens to stake
    /// @param nodeId Unique identifier for the validator node
    /// @param hardwareSpecs Hardware specifications of the validator node
    function registerValidator(
        uint256 stakeAmount,
        string calldata nodeId,
        HardwareSpecs calldata hardwareSpecs
    ) external nonReentrant whenNotPaused {
        if (stakeAmount < stakingConfig.minimumStake) revert InsufficientStake();
        if (stakeAmount > stakingConfig.maximumStake) revert StakeExceedsMaximum();
        if (bytes(nodeId).length == 0) revert NodeIdRequired();
        if (validators[msg.sender].validatorAddress != address(0)) revert AlreadyRegistered();
        if (nodeIdToValidator[nodeId] != address(0)) revert NodeIdAlreadyTaken();

        // Verify hardware requirements
        if (!_verifyHardwareSpecs(hardwareSpecs)) revert HardwareRequirementsNotMet();

        // Transfer stake (using OmniCoin by default for validators)
        address stakingToken = _getContract(registry.OMNICOIN());
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Initialize validator info
        validators[msg.sender] = ValidatorInfo({
            validatorAddress: msg.sender,
            stakedAmount: stakeAmount,
            participationScore: MAX_PARTICIPATION_SCORE, // Start with full score
            status: ValidatorStatus.ACTIVE,
            /* solhint-disable-next-line not-rely-on-time */
            registrationTime: block.timestamp,
            /* solhint-disable-next-line not-rely-on-time */
            lastActivityTime: block.timestamp,
            nodeId: nodeId,
            hardwareSpecs: hardwareSpecs,
            performance: PerformanceMetrics({
                blocksProduced: 0,
                uptime: 10000, // 100% uptime initially
                tradingVolumeFacilitated: 0,
                chatMessages: 0,
                ipfsDataStored: 0,
                /* solhint-disable-next-line not-rely-on-time */
                lastUpdateTime: block.timestamp
            }),
            totalRewards: 0,
            slashingHistory: 0,
            exitTime: 0
        });

        // Update mappings and counters
        nodeIdToValidator[nodeId] = msg.sender;
        validatorList.push(msg.sender);
        totalStaked += stakeAmount;
        ++totalValidators;
        ++activeValidators;

        emit ValidatorRegistered(
            msg.sender,
            stakeAmount,
            nodeId,
            /* solhint-disable-next-line not-rely-on-time */
            block.timestamp
        );
    }

    /// @notice Increase validator stake
    /// @param additionalStake Amount of additional tokens to stake
    function increaseStake(uint256 additionalStake) external nonReentrant {
        if (validators[msg.sender].validatorAddress == address(0)) revert NotAValidator();
        if (additionalStake == 0) revert AdditionalStakeMustBePositive();

        uint256 newTotalStake = validators[msg.sender].stakedAmount +
            additionalStake;
        if (newTotalStake > stakingConfig.maximumStake) revert StakeExceedsMaximum();

        // Transfer additional stake
        address stakingToken = _getContract(registry.OMNICOIN());
        IERC20(stakingToken).safeTransferFrom(
            msg.sender,
            address(this),
            additionalStake
        );

        // Update stake
        validators[msg.sender].stakedAmount = newTotalStake;
        totalStaked += additionalStake;

        emit ValidatorStakeIncreased(
            msg.sender,
            additionalStake,
            newTotalStake
        );
    }

    /// @notice Request to deregister and unstake
    function requestDeregistration() external {
        if (validators[msg.sender].validatorAddress == address(0)) revert NotAValidator();
        if (validators[msg.sender].status == ValidatorStatus.EXITING) revert AlreadyExiting();

        validators[msg.sender].status = ValidatorStatus.EXITING;
        validators[msg.sender].exitTime =
            /* solhint-disable-next-line not-rely-on-time */
            block.timestamp +
            stakingConfig.unstakingPeriod;

        --activeValidators;

        emit ValidatorStatusChanged(
            msg.sender,
            ValidatorStatus.ACTIVE,
            ValidatorStatus.EXITING
        );
    }

    /// @notice Complete deregistration and withdraw stake
    function completeDeregistration() external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        if (validator.validatorAddress == address(0)) revert NotAValidator();
        if (validator.status != ValidatorStatus.EXITING) revert NotInExitingState();
        /* solhint-disable-next-line not-rely-on-time */
        if (block.timestamp < validator.exitTime) revert UnstakingPeriodNotCompleted();

        uint256 refundAmount = validator.stakedAmount;

        // Clean up validator data
        delete nodeIdToValidator[validator.nodeId];
        _removeValidatorFromList(msg.sender);
        delete validators[msg.sender];

        totalStaked -= refundAmount;
        --totalValidators;

        // Refund stake
        address stakingToken = _getContract(registry.OMNICOIN());
        IERC20(stakingToken).safeTransfer(msg.sender, refundAmount);

        emit ValidatorDeregistered(msg.sender, refundAmount, "Voluntary exit");
    }

    /// @notice Update validator performance metrics (called by oracles)
    /// @param validatorAddress Address of the validator to update
    /// @param blocksProduced Number of blocks produced
    /// @param uptime Uptime percentage (0-10000)
    /// @param tradingVolume Trading volume facilitated
    /// @param chatMessages Number of chat messages handled
    /// @param ipfsDataStored Amount of IPFS data stored
    function updatePerformanceMetrics(
        address validatorAddress,
        uint256 blocksProduced,
        uint256 uptime,
        uint256 tradingVolume,
        uint256 chatMessages,
        uint256 ipfsDataStored
    ) external onlyRole(ORACLE_ROLE) {
        ValidatorInfo storage validator = validators[validatorAddress];
        if (validator.validatorAddress == address(0)) revert ValidatorNotFound();

        // Update performance metrics
        validator.performance.blocksProduced += blocksProduced;
        validator.performance.uptime = uptime;
        validator.performance.tradingVolumeFacilitated += tradingVolume;
        validator.performance.chatMessages += chatMessages;
        validator.performance.ipfsDataStored += ipfsDataStored;
        /* solhint-disable-next-line not-rely-on-time */
        validator.performance.lastUpdateTime = block.timestamp;
        /* solhint-disable-next-line not-rely-on-time */
        validator.lastActivityTime = block.timestamp;

        // Calculate new participation score
        uint256 newScore = _calculateParticipationScore(validator.performance);
        uint256 oldScore = validator.participationScore;
        validator.participationScore = newScore;

        // Check if validator should be suspended for low participation
        /* solhint-disable-next-line not-rely-on-time */
        if (
            newScore < stakingConfig.participationThreshold &&
            validator.status == ValidatorStatus.ACTIVE
        ) {
            validator.status = ValidatorStatus.SUSPENDED;
            --activeValidators;

            emit ValidatorStatusChanged(
                validatorAddress,
                ValidatorStatus.ACTIVE,
                ValidatorStatus.SUSPENDED
            );
        }

        emit ParticipationScoreUpdated(
            validatorAddress,
            oldScore,
            newScore,
            "Performance update"
        );
    }

    /// @notice Slash a validator for malicious behavior
    /// @param validatorAddress Address of the validator to slash
    /// @param slashAmount Amount to slash from validator's stake
    /// @param reason Reason for slashing
    function slashValidator(
        address validatorAddress,
        uint256 slashAmount,
        string calldata reason
    ) external onlyRole(SLASHER_ROLE) {
        ValidatorInfo storage validator = validators[validatorAddress];
        if (validator.validatorAddress == address(0)) revert ValidatorNotFound();
        if (slashAmount == 0) revert SlashAmountMustBePositive();
        if (slashAmount > validator.stakedAmount) revert SlashAmountExceedsStake();

        // Apply slashing
        validator.stakedAmount -= slashAmount;
        validator.slashingHistory += slashAmount;
        validator.status = ValidatorStatus.JAILED;
        totalStaked -= slashAmount;

        if (validator.status == ValidatorStatus.ACTIVE) {
            --activeValidators;
        }

        // Burned tokens (sent to zero address)
        address stakingToken = _getContract(registry.OMNICOIN());
        IERC20(stakingToken).safeTransfer(address(0), slashAmount);

        emit ValidatorSlashed(
            validatorAddress,
            slashAmount,
            validator.stakedAmount,
            reason
        );
        emit ValidatorStatusChanged(
            validatorAddress,
            ValidatorStatus.ACTIVE,
            ValidatorStatus.JAILED
        );
    }

    /// @notice Distribute rewards to validators
    /// @param validatorAddresses Array of validator addresses
    /// @param rewardAmounts Array of reward amounts corresponding to each validator
    function distributeRewards(
        address[] calldata validatorAddresses,
        uint256[] calldata rewardAmounts
    ) external onlyRole(VALIDATOR_MANAGER_ROLE) {
        if (validatorAddresses.length != rewardAmounts.length) revert ArraysLengthMismatch();

        for (uint256 i = 0; i < validatorAddresses.length; ++i) {
            ValidatorInfo storage validator = validators[validatorAddresses[i]];
            if (
                validator.validatorAddress != address(0) && rewardAmounts[i] > 0
            ) {
                validator.totalRewards += rewardAmounts[i];

                // Transfer reward
                address stakingToken = _getContract(registry.OMNICOIN());
                IERC20(stakingToken).safeTransfer(
                    validatorAddresses[i],
                    rewardAmounts[i]
                );

                emit ValidatorRewardDistributed(
                    validatorAddresses[i],
                    rewardAmounts[i],
                    validator.participationScore
                );
            }
        }
    }

    /// @notice Advance epoch and update validator states
    function advanceEpoch() external {
        /* solhint-disable-next-line not-rely-on-time */
        if (block.timestamp < lastEpochTime + epochDuration) revert EpochNotReady();

        ++currentEpoch;
        /* solhint-disable-next-line not-rely-on-time */
        lastEpochTime = block.timestamp;

        // Update validator states based on participation
        for (uint256 i = 0; i < validatorList.length; ++i) {
            address validatorAddr = validatorList[i];
            ValidatorInfo storage validator = validators[validatorAddr];

            if (validator.validatorAddress != address(0)) {
                // Reactivate suspended validators with improved participation
                if (
                    validator.status == ValidatorStatus.SUSPENDED &&
                    validator.participationScore >
                    stakingConfig.participationThreshold - 1
                ) {
                    validator.status = ValidatorStatus.ACTIVE;
                    ++activeValidators;

                    emit ValidatorStatusChanged(
                        validatorAddr,
                        ValidatorStatus.SUSPENDED,
                        ValidatorStatus.ACTIVE
                    );
                }
            }
        }
    }

    /// @notice Get validator selection for consensus (top performers)
    /// @param count Number of validators to select
    /// @return selected Array of selected validator addresses
    function getValidatorSelection(
        uint256 count
    ) external view returns (address[] memory selected) {
        if (count > activeValidators) revert NotEnoughActiveValidators();

        // Get active validators and their scores
        (address[] memory activeValidatorAddresses, uint256[] memory scores) = _getActiveValidatorsWithScores();

        // Sort validators by score
        _sortValidatorsByScore(activeValidatorAddresses, scores);

        // Return top performers
        selected = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            selected[i] = activeValidatorAddresses[i];
        }
    }

    // Internal functions
    /// @notice Remove a validator from the validator list
    /// @param validatorAddress Address of the validator to remove
    function _removeValidatorFromList(address validatorAddress) internal {
        for (uint256 i = 0; i < validatorList.length; ++i) {
            if (validatorList[i] == validatorAddress) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                break;
            }
        }
    }

    /// @notice Get active validators and their scores
    /// @return activeValidatorAddresses Array of active validator addresses
    /// @return scores Array of participation scores
    function _getActiveValidatorsWithScores() internal view returns (
        address[] memory activeValidatorAddresses,
        uint256[] memory scores
    ) {
        activeValidatorAddresses = new address[](activeValidators);
        scores = new uint256[](activeValidators);
        uint256 activeIndex = 0;

        for (uint256 i = 0; i < validatorList.length; ++i) {
            ValidatorInfo storage validator = validators[validatorList[i]];
            if (validator.status == ValidatorStatus.ACTIVE) {
                activeValidatorAddresses[activeIndex] = validatorList[i];
                scores[activeIndex] = validator.participationScore;
                ++activeIndex;
            }
        }
    }

    /// @notice Sort validators by participation score (descending)
    /// @param addresses Array of validator addresses to sort
    /// @param scores Array of participation scores to sort
    function _sortValidatorsByScore(
        address[] memory addresses,
        uint256[] memory scores
    ) internal pure {
        uint256 length = addresses.length;
        for (uint256 i = 0; i < length - 1; ++i) {
            for (uint256 j = 0; j < length - i - 1; ++j) {
                if (scores[j] < scores[j + 1]) {
                    // Swap scores
                    uint256 tempScore = scores[j];
                    scores[j] = scores[j + 1];
                    scores[j + 1] = tempScore;

                    // Swap addresses
                    address tempAddr = addresses[j];
                    addresses[j] = addresses[j + 1];
                    addresses[j + 1] = tempAddr;
                }
            }
        }
    }

    // Internal functions
    /// @notice Verify hardware specifications meet minimum requirements
    /// @param specs Hardware specifications to verify
    /// @return valid True if specifications meet requirements
    function _verifyHardwareSpecs(
        HardwareSpecs calldata specs
    ) internal pure returns (bool valid) {
        valid = specs.cpuCores > MIN_CPU_CORES - 1 &&
            specs.ramGB > MIN_RAM_GB - 1 &&
            specs.storageGB > MIN_STORAGE_GB - 1 &&
            specs.networkSpeed > MIN_NETWORK_SPEED - 1;
    }

    /// @notice Calculate participation score from performance metrics
    /// @param performance Performance metrics to evaluate
    /// @return score Calculated participation score
    function _calculateParticipationScore(
        PerformanceMetrics memory performance
    ) internal pure returns (uint256 score) {
        // Calculate weighted score based on different metrics

        // Block production score (0-30 points)
        uint256 blockScore = Math.min(
            performance.blocksProduced * 2,
            BLOCK_PRODUCTION_WEIGHT
        );
        score += blockScore;

        // Uptime score (0-25 points)
        uint256 uptimeScore = (performance.uptime * UPTIME_WEIGHT) / 10000;
        score += uptimeScore;

        // Trading volume score (0-20 points)
        uint256 tradingScore = Math.min(
            performance.tradingVolumeFacilitated / 10000,
            TRADING_VOLUME_WEIGHT
        );
        score += tradingScore;

        // Chat activity score (0-15 points)
        uint256 chatScore = Math.min(
            performance.chatMessages / 100,
            CHAT_ACTIVITY_WEIGHT
        );
        score += chatScore;

        // IPFS storage score (0-10 points)
        uint256 storageScore = Math.min(
            performance.ipfsDataStored / 1000,
            IPFS_STORAGE_WEIGHT
        );
        score += storageScore;

        score = Math.min(score, MAX_PARTICIPATION_SCORE);
    }

    // View functions
    /// @notice Get complete information for a validator
    /// @param validatorAddress Address of the validator
    /// @return ValidatorInfo struct with all validator details
    function getValidatorInfo(
        address validatorAddress
    ) external view returns (ValidatorInfo memory) {
        return validators[validatorAddress];
    }

    /// @notice Get validator address by node ID
    /// @param nodeId Node identifier to look up
    /// @return validatorAddress Address of the validator
    function getValidatorByNodeId(
        string calldata nodeId
    ) external view returns (address validatorAddress) {
        validatorAddress = nodeIdToValidator[nodeId];
    }

    /// @notice Get list of all validator addresses
    /// @return Array of validator addresses
    function getValidatorList() external view returns (address[] memory) {
        return validatorList;
    }

    /// @notice Get list of active validator addresses
    /// @return active Array of active validator addresses
    function getActiveValidators() external view returns (address[] memory active) {
        active = new address[](activeValidators);
        uint256 index = 0;

        for (uint256 i = 0; i < validatorList.length; ++i) {
            if (validators[validatorList[i]].status == ValidatorStatus.ACTIVE) {
                active[index] = validatorList[i];
                ++index;
            }
        }

    }

    /// @notice Get current staking configuration
    /// @return Current staking configuration parameters
    function getStakingConfig() external view returns (StakingConfig memory) {
        return stakingConfig;
    }

    /// @notice Get total amount staked across all validators
    /// @return Total staked amount
    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    /// @notice Get validator count statistics
    /// @return total Total number of validators
    /// @return active Number of active validators
    function getValidatorCount()
        external
        view
        returns (uint256 total, uint256 active)
    {
        return (totalValidators, activeValidators);
    }

    // Admin functions
    /// @notice Update staking configuration parameters
    /// @param newConfig New staking configuration
    function updateStakingConfig(
        StakingConfig calldata newConfig
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingConfig = newConfig;
    }

    /// @notice Update epoch duration
    /// @param newDuration New epoch duration in seconds
    function updateEpochDuration(
        uint256 newDuration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDuration < 1 hours) revert EpochDurationTooShort();
        epochDuration = newDuration;
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
