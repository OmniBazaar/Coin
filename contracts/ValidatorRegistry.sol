// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ValidatorRegistry
 * @dev Registry and management system for unified validators
 *
 * Features:
 * - Validator registration and staking
 * - Proof of Participation scoring system
 * - Hardware requirements verification
 * - Slashing for malicious behavior
 * - Automatic validator selection for consensus
 * - Economic incentives and penalties
 */
contract ValidatorRegistry is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Roles
    bytes32 public constant VALIDATOR_MANAGER_ROLE =
        keccak256("VALIDATOR_MANAGER_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // Events
    event ValidatorRegistered(
        address indexed validator,
        uint256 stake,
        string nodeId,
        uint256 timestamp
    );

    event ValidatorStakeIncreased(
        address indexed validator,
        uint256 additionalStake,
        uint256 totalStake
    );

    event ValidatorDeregistered(
        address indexed validator,
        uint256 refundedStake,
        string reason
    );

    event ParticipationScoreUpdated(
        address indexed validator,
        uint256 oldScore,
        uint256 newScore,
        string reason
    );

    event ValidatorSlashed(
        address indexed validator,
        uint256 slashedAmount,
        uint256 remainingStake,
        string reason
    );

    event ValidatorRewardDistributed(
        address indexed validator,
        uint256 amount,
        uint256 participationScore
    );

    event ValidatorStatusChanged(
        address indexed validator,
        ValidatorStatus oldStatus,
        ValidatorStatus newStatus
    );

    // Enums
    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        SUSPENDED,
        JAILED,
        EXITING
    }

    // Structs
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

    struct HardwareSpecs {
        uint256 cpuCores;
        uint256 ramGB;
        uint256 storageGB;
        uint256 networkSpeed; // Mbps
        bool verified;
        uint256 verificationTime;
    }

    struct PerformanceMetrics {
        uint256 blocksProduced;
        uint256 uptime; // Percentage (0-10000, where 10000 = 100%)
        uint256 tradingVolumeFacilitated;
        uint256 chatMessages;
        uint256 ipfsDataStored;
        uint256 lastUpdateTime;
    }

    struct StakingConfig {
        uint256 minimumStake;
        uint256 maximumStake;
        uint256 slashingRate; // Basis points (100 = 1%)
        uint256 rewardRate; // Annual rate in basis points
        uint256 unstakingPeriod; // Seconds
        uint256 participationThreshold; // Minimum score to stay active
    }

    // State variables
    mapping(address => ValidatorInfo) public validators;
    mapping(string => address) public nodeIdToValidator;
    address[] public validatorList;

    IERC20 public immutable stakingToken; // XOM token
    StakingConfig public stakingConfig;

    uint256 public totalStaked;
    uint256 public totalValidators;
    uint256 public activeValidators;
    uint256 public currentEpoch;
    uint256 public epochDuration = 1 hours;
    uint256 public lastEpochTime;

    // Hardware requirements
    uint256 public constant MIN_CPU_CORES = 4;
    uint256 public constant MIN_RAM_GB = 8;
    uint256 public constant MIN_STORAGE_GB = 100;
    uint256 public constant MIN_NETWORK_SPEED = 100; // Mbps

    // Participation scoring constants
    uint256 public constant MAX_PARTICIPATION_SCORE = 100;
    uint256 public constant BLOCK_PRODUCTION_WEIGHT = 30;
    uint256 public constant UPTIME_WEIGHT = 25;
    uint256 public constant TRADING_VOLUME_WEIGHT = 20;
    uint256 public constant CHAT_ACTIVITY_WEIGHT = 15;
    uint256 public constant IPFS_STORAGE_WEIGHT = 10;

    constructor(
        address _stakingToken,
        uint256 _minimumStake,
        uint256 _maximumStake
    ) {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_minimumStake > 0, "Minimum stake must be positive");
        require(
            _maximumStake >= _minimumStake,
            "Maximum stake must be >= minimum"
        );

        stakingToken = IERC20(_stakingToken);

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

        lastEpochTime = block.timestamp;
    }

    /**
     * @dev Register as a validator
     */
    function registerValidator(
        uint256 stakeAmount,
        string calldata nodeId,
        HardwareSpecs calldata hardwareSpecs
    ) external nonReentrant whenNotPaused {
        require(
            stakeAmount >= stakingConfig.minimumStake,
            "Insufficient stake"
        );
        require(
            stakeAmount <= stakingConfig.maximumStake,
            "Stake exceeds maximum"
        );
        require(bytes(nodeId).length > 0, "Node ID required");
        require(
            validators[msg.sender].validatorAddress == address(0),
            "Already registered"
        );
        require(
            nodeIdToValidator[nodeId] == address(0),
            "Node ID already taken"
        );

        // Verify hardware requirements
        require(
            _verifyHardwareSpecs(hardwareSpecs),
            "Hardware requirements not met"
        );

        // Transfer stake
        stakingToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Initialize validator info
        validators[msg.sender] = ValidatorInfo({
            validatorAddress: msg.sender,
            stakedAmount: stakeAmount,
            participationScore: MAX_PARTICIPATION_SCORE, // Start with full score
            status: ValidatorStatus.ACTIVE,
            registrationTime: block.timestamp,
            lastActivityTime: block.timestamp,
            nodeId: nodeId,
            hardwareSpecs: hardwareSpecs,
            performance: PerformanceMetrics({
                blocksProduced: 0,
                uptime: 10000, // 100% uptime initially
                tradingVolumeFacilitated: 0,
                chatMessages: 0,
                ipfsDataStored: 0,
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
        totalValidators++;
        activeValidators++;

        emit ValidatorRegistered(
            msg.sender,
            stakeAmount,
            nodeId,
            block.timestamp
        );
    }

    /**
     * @dev Increase validator stake
     */
    function increaseStake(uint256 additionalStake) external nonReentrant {
        require(
            validators[msg.sender].validatorAddress != address(0),
            "Not a validator"
        );
        require(additionalStake > 0, "Additional stake must be positive");

        uint256 newTotalStake = validators[msg.sender].stakedAmount +
            additionalStake;
        require(
            newTotalStake <= stakingConfig.maximumStake,
            "Stake exceeds maximum"
        );

        // Transfer additional stake
        stakingToken.safeTransferFrom(
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

    /**
     * @dev Request to deregister and unstake
     */
    function requestDeregistration() external {
        require(
            validators[msg.sender].validatorAddress != address(0),
            "Not a validator"
        );
        require(
            validators[msg.sender].status != ValidatorStatus.EXITING,
            "Already exiting"
        );

        validators[msg.sender].status = ValidatorStatus.EXITING;
        validators[msg.sender].exitTime =
            block.timestamp +
            stakingConfig.unstakingPeriod;

        activeValidators--;

        emit ValidatorStatusChanged(
            msg.sender,
            ValidatorStatus.ACTIVE,
            ValidatorStatus.EXITING
        );
    }

    /**
     * @dev Complete deregistration and withdraw stake
     */
    function completeDeregistration() external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        require(validator.validatorAddress != address(0), "Not a validator");
        require(
            validator.status == ValidatorStatus.EXITING,
            "Not in exiting state"
        );
        require(
            block.timestamp >= validator.exitTime,
            "Unstaking period not completed"
        );

        uint256 refundAmount = validator.stakedAmount;

        // Clean up validator data
        delete nodeIdToValidator[validator.nodeId];
        _removeValidatorFromList(msg.sender);
        delete validators[msg.sender];

        totalStaked -= refundAmount;
        totalValidators--;

        // Refund stake
        stakingToken.safeTransfer(msg.sender, refundAmount);

        emit ValidatorDeregistered(msg.sender, refundAmount, "Voluntary exit");
    }

    /**
     * @dev Update validator performance metrics (called by oracles)
     */
    function updatePerformanceMetrics(
        address validatorAddress,
        uint256 blocksProduced,
        uint256 uptime,
        uint256 tradingVolume,
        uint256 chatMessages,
        uint256 ipfsDataStored
    ) external onlyRole(ORACLE_ROLE) {
        ValidatorInfo storage validator = validators[validatorAddress];
        require(
            validator.validatorAddress != address(0),
            "Validator not found"
        );

        // Update performance metrics
        validator.performance.blocksProduced += blocksProduced;
        validator.performance.uptime = uptime;
        validator.performance.tradingVolumeFacilitated += tradingVolume;
        validator.performance.chatMessages += chatMessages;
        validator.performance.ipfsDataStored += ipfsDataStored;
        validator.performance.lastUpdateTime = block.timestamp;
        validator.lastActivityTime = block.timestamp;

        // Calculate new participation score
        uint256 newScore = _calculateParticipationScore(validator.performance);
        uint256 oldScore = validator.participationScore;
        validator.participationScore = newScore;

        // Check if validator should be suspended for low participation
        if (
            newScore < stakingConfig.participationThreshold &&
            validator.status == ValidatorStatus.ACTIVE
        ) {
            validator.status = ValidatorStatus.SUSPENDED;
            activeValidators--;

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

    /**
     * @dev Slash a validator for malicious behavior
     */
    function slashValidator(
        address validatorAddress,
        uint256 slashAmount,
        string calldata reason
    ) external onlyRole(SLASHER_ROLE) {
        ValidatorInfo storage validator = validators[validatorAddress];
        require(
            validator.validatorAddress != address(0),
            "Validator not found"
        );
        require(slashAmount > 0, "Slash amount must be positive");
        require(
            slashAmount <= validator.stakedAmount,
            "Slash amount exceeds stake"
        );

        // Apply slashing
        validator.stakedAmount -= slashAmount;
        validator.slashingHistory += slashAmount;
        validator.status = ValidatorStatus.JAILED;
        totalStaked -= slashAmount;

        if (validator.status == ValidatorStatus.ACTIVE) {
            activeValidators--;
        }

        // Burned tokens (sent to zero address)
        stakingToken.safeTransfer(address(0), slashAmount);

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

    /**
     * @dev Distribute rewards to validators
     */
    function distributeRewards(
        address[] calldata validatorAddresses,
        uint256[] calldata rewardAmounts
    ) external onlyRole(VALIDATOR_MANAGER_ROLE) {
        require(
            validatorAddresses.length == rewardAmounts.length,
            "Arrays length mismatch"
        );

        for (uint256 i = 0; i < validatorAddresses.length; i++) {
            ValidatorInfo storage validator = validators[validatorAddresses[i]];
            if (
                validator.validatorAddress != address(0) && rewardAmounts[i] > 0
            ) {
                validator.totalRewards += rewardAmounts[i];

                // Transfer reward
                stakingToken.safeTransfer(
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

    /**
     * @dev Advance epoch and update validator states
     */
    function advanceEpoch() external {
        require(
            block.timestamp >= lastEpochTime + epochDuration,
            "Epoch not ready"
        );

        currentEpoch++;
        lastEpochTime = block.timestamp;

        // Update validator states based on participation
        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorAddr = validatorList[i];
            ValidatorInfo storage validator = validators[validatorAddr];

            if (validator.validatorAddress != address(0)) {
                // Reactivate suspended validators with improved participation
                if (
                    validator.status == ValidatorStatus.SUSPENDED &&
                    validator.participationScore >=
                    stakingConfig.participationThreshold
                ) {
                    validator.status = ValidatorStatus.ACTIVE;
                    activeValidators++;

                    emit ValidatorStatusChanged(
                        validatorAddr,
                        ValidatorStatus.SUSPENDED,
                        ValidatorStatus.ACTIVE
                    );
                }
            }
        }
    }

    /**
     * @dev Get validator selection for consensus (top performers)
     */
    function getValidatorSelection(
        uint256 count
    ) external view returns (address[] memory) {
        require(count <= activeValidators, "Not enough active validators");

        // Create array of active validators with their scores
        address[] memory activeValidatorAddresses = new address[](
            activeValidators
        );
        uint256[] memory scores = new uint256[](activeValidators);
        uint256 activeIndex = 0;

        for (uint256 i = 0; i < validatorList.length; i++) {
            ValidatorInfo storage validator = validators[validatorList[i]];
            if (validator.status == ValidatorStatus.ACTIVE) {
                activeValidatorAddresses[activeIndex] = validatorList[i];
                scores[activeIndex] = validator.participationScore;
                activeIndex++;
            }
        }

        // Sort by participation score (simple bubble sort for small arrays)
        for (uint256 i = 0; i < activeValidators - 1; i++) {
            for (uint256 j = 0; j < activeValidators - i - 1; j++) {
                if (scores[j] < scores[j + 1]) {
                    // Swap scores
                    uint256 tempScore = scores[j];
                    scores[j] = scores[j + 1];
                    scores[j + 1] = tempScore;

                    // Swap addresses
                    address tempAddr = activeValidatorAddresses[j];
                    activeValidatorAddresses[j] = activeValidatorAddresses[
                        j + 1
                    ];
                    activeValidatorAddresses[j + 1] = tempAddr;
                }
            }
        }

        // Return top performers
        address[] memory selected = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            selected[i] = activeValidatorAddresses[i];
        }

        return selected;
    }

    // Internal functions
    function _verifyHardwareSpecs(
        HardwareSpecs calldata specs
    ) internal pure returns (bool) {
        return
            specs.cpuCores >= MIN_CPU_CORES &&
            specs.ramGB >= MIN_RAM_GB &&
            specs.storageGB >= MIN_STORAGE_GB &&
            specs.networkSpeed >= MIN_NETWORK_SPEED;
    }

    function _calculateParticipationScore(
        PerformanceMetrics memory performance
    ) internal pure returns (uint256) {
        // Calculate weighted score based on different metrics
        uint256 score = 0;

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

        return Math.min(score, MAX_PARTICIPATION_SCORE);
    }

    function _removeValidatorFromList(address validatorAddress) internal {
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorList[i] == validatorAddress) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                break;
            }
        }
    }

    // View functions
    function getValidatorInfo(
        address validatorAddress
    ) external view returns (ValidatorInfo memory) {
        return validators[validatorAddress];
    }

    function getValidatorByNodeId(
        string calldata nodeId
    ) external view returns (address) {
        return nodeIdToValidator[nodeId];
    }

    function getValidatorList() external view returns (address[] memory) {
        return validatorList;
    }

    function getActiveValidators() external view returns (address[] memory) {
        address[] memory active = new address[](activeValidators);
        uint256 index = 0;

        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validators[validatorList[i]].status == ValidatorStatus.ACTIVE) {
                active[index] = validatorList[i];
                index++;
            }
        }

        return active;
    }

    function getStakingConfig() external view returns (StakingConfig memory) {
        return stakingConfig;
    }

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    function getValidatorCount()
        external
        view
        returns (uint256 total, uint256 active)
    {
        return (totalValidators, activeValidators);
    }

    // Admin functions
    function updateStakingConfig(
        StakingConfig calldata newConfig
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingConfig = newConfig;
    }

    function updateEpochDuration(
        uint256 newDuration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDuration >= 1 hours, "Epoch duration too short");
        epochDuration = newDuration;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
