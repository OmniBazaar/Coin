// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @title IOmniParticipation
 * @author OmniBazaar Team
 * @notice Interface for OmniParticipation contract
 * @dev Queries participation scores for reward weighting
 */
interface IOmniParticipation {
    /// @notice Get user's total participation score
    /// @param user Address to check
    /// @return Total score (0-100)
    function getTotalScore(address user) external view returns (uint256);

    /// @notice Check if user can be a validator
    /// @param user Address to check
    /// @return True if qualified
    function canBeValidator(address user) external view returns (bool);
}

/**
 * @title IOmniCore
 * @author OmniBazaar Team
 * @notice Interface for OmniCore contract
 * @dev Queries staking and validator status
 */
interface IOmniCore {
    /// @notice Stake information structure
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Get user's stake information
    /// @param user Address to check
    /// @return Stake struct with staking details
    function getStake(address user) external view returns (Stake memory);

    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if validator
    function isValidator(address validator) external view returns (bool);

    /// @notice Get all active nodes
    /// @return Array of active node addresses
    function getActiveNodes() external view returns (address[] memory);
}

/**
 * @title OmniValidatorRewards
 * @author OmniBazaar Team
 * @notice Trustless validator reward distribution for OmniBazaar
 * @dev Time-based epoch distribution with participation weighting
 *
 * Weight Calculation:
 * - 40% participation score (from OmniParticipation)
 * - 30% staking amount (from OmniCore)
 * - 30% activity (heartbeat + transaction processing)
 *
 * Reward Distribution:
 * - Epoch every 2 seconds (tied to block time)
 * - Rewards accumulate in contract
 * - Validators claim via claimValidatorRewards()
 *
 * Block Reward Schedule:
 * - Initial: 15.602 XOM per block
 * - Reduction: 1% every 6,311,520 blocks
 * - Target: 6.089 billion XOM over 40 years
 */
contract OmniValidatorRewards is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for recording transaction processing
    bytes32 public constant BLOCKCHAIN_ROLE = keccak256("BLOCKCHAIN_ROLE");

    /// @notice Epoch duration in seconds (2 second blocks)
    uint256 public constant EPOCH_DURATION = 2;

    /// @notice Heartbeat timeout for active status (20 seconds = 10 epochs)
    uint256 public constant HEARTBEAT_TIMEOUT = 20;

    /// @notice Initial block reward (15.602 XOM with 18 decimals)
    uint256 public constant INITIAL_BLOCK_REWARD = 15602000000000000000;

    /// @notice Blocks per reduction period (6,311,520 blocks)
    uint256 public constant BLOCKS_PER_REDUCTION = 6311520;

    /// @notice Reward reduction factor (99% = keep 99%, reduce by 1%)
    uint256 public constant REDUCTION_FACTOR = 99;

    /// @notice Reduction factor denominator
    uint256 public constant REDUCTION_DENOMINATOR = 100;

    /// @notice Maximum reductions before zero reward (~40 years)
    uint256 public constant MAX_REDUCTIONS = 100;

    /// @notice Weight for participation score (40%)
    uint256 public constant PARTICIPATION_WEIGHT = 40;

    /// @notice Weight for staking amount (30%)
    uint256 public constant STAKING_WEIGHT = 30;

    /// @notice Weight for activity (30%)
    uint256 public constant ACTIVITY_WEIGHT = 30;

    /// @notice Activity sub-weight for heartbeat (60%)
    uint256 public constant HEARTBEAT_SUBWEIGHT = 60;

    /// @notice Activity sub-weight for transaction processing (40%)
    uint256 public constant TX_PROCESSING_SUBWEIGHT = 40;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice XOM token contract
    IERC20 public xomToken;

    /// @notice OmniParticipation contract reference
    IOmniParticipation public participation;

    /// @notice OmniCore contract reference
    IOmniCore public omniCore;

    /// @notice Genesis block timestamp
    uint256 public genesisTimestamp;

    /// @notice Last processed epoch
    uint256 public lastProcessedEpoch;

    /// @notice Total blocks produced (for reduction calculation)
    uint256 public totalBlocksProduced;

    /// @notice Accumulated rewards per validator
    mapping(address => uint256) public accumulatedRewards;

    /// @notice Total rewards claimed per validator
    mapping(address => uint256) public totalClaimed;

    /// @notice Last heartbeat timestamp per validator
    mapping(address => uint256) public lastHeartbeat;

    /// @notice Transactions processed per validator per epoch
    mapping(address => mapping(uint256 => uint256)) public transactionsProcessed;

    /// @notice Total transactions in an epoch
    mapping(uint256 => uint256) public epochTotalTransactions;

    /// @notice Active validators count at epoch end
    mapping(uint256 => uint256) public epochActiveValidators;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when epoch is processed
    event EpochProcessed(
        uint256 indexed epoch,
        uint256 totalReward,
        uint256 activeValidators
    );

    /// @notice Emitted when validator claims rewards
    event RewardsClaimed(
        address indexed validator,
        uint256 amount,
        uint256 totalClaimed
    );

    /// @notice Emitted when validator submits heartbeat
    event ValidatorHeartbeat(
        address indexed validator,
        uint256 timestamp
    );

    /// @notice Emitted when transaction processing is recorded
    event TransactionProcessed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 count
    );

    /// @notice Emitted when contracts are updated
    event ContractsUpdated(
        address xomToken,
        address participation,
        address omniCore
    );

    /// @notice Emitted when reward is distributed to validator
    event RewardDistributed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 amount,
        uint256 weight
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Caller is not a validator
    error NotValidator();

    /// @notice No rewards to claim
    error NoRewardsToClaim();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Epoch already processed
    error EpochAlreadyProcessed();

    /// @notice Future epoch cannot be processed
    error FutureEpoch();

    /// @notice Insufficient contract balance
    error InsufficientBalance();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param xomTokenAddr Address of XOM token contract
     * @param participationAddr Address of OmniParticipation contract
     * @param omniCoreAddr Address of OmniCore contract
     */
    function initialize(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BLOCKCHAIN_ROLE, msg.sender);

        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) revert ZeroAddress();
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        xomToken = IERC20(xomTokenAddr);
        participation = IOmniParticipation(participationAddr);
        omniCore = IOmniCore(omniCoreAddr);

        // solhint-disable-next-line not-rely-on-time
        genesisTimestamp = block.timestamp;
        lastProcessedEpoch = 0;
        totalBlocksProduced = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         HEARTBEAT SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit validator heartbeat
     * @dev Should be called every ~10 epochs (20 seconds)
     */
    function submitHeartbeat() external {
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();

        // solhint-disable-next-line not-rely-on-time
        lastHeartbeat[msg.sender] = block.timestamp;

        // solhint-disable-next-line not-rely-on-time
        emit ValidatorHeartbeat(msg.sender, block.timestamp);
    }

    /**
     * @notice Check if validator is currently active
     * @param validator Address to check
     * @return True if heartbeat within timeout
     */
    function isValidatorActive(address validator) public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - lastHeartbeat[validator]) <= HEARTBEAT_TIMEOUT;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    TRANSACTION PROCESSING TRACKING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Record transaction processing by validator
     * @param validator Address of processing validator
     * @dev Called by blockchain role when validator processes transaction
     */
    function recordTransactionProcessing(
        address validator
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (!omniCore.isValidator(validator)) revert NotValidator();

        uint256 currentEpoch = getCurrentEpoch();
        ++transactionsProcessed[validator][currentEpoch];
        ++epochTotalTransactions[currentEpoch];

        emit TransactionProcessed(validator, currentEpoch, 1);
    }

    /**
     * @notice Record multiple transaction processing
     * @param validator Address of processing validator
     * @param count Number of transactions processed
     */
    function recordMultipleTransactions(
        address validator,
        uint256 count
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (!omniCore.isValidator(validator)) revert NotValidator();

        uint256 currentEpoch = getCurrentEpoch();
        transactionsProcessed[validator][currentEpoch] += count;
        epochTotalTransactions[currentEpoch] += count;

        emit TransactionProcessed(validator, currentEpoch, count);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         EPOCH PROCESSING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Process epoch and distribute rewards
     * @param epoch Epoch number to process
     * @dev Can be called by anyone, processes rewards for all active validators
     */
    function processEpoch(uint256 epoch) external nonReentrant {
        uint256 currentEpoch = getCurrentEpoch();
        if (epoch > currentEpoch) revert FutureEpoch();
        if (epoch <= lastProcessedEpoch) revert EpochAlreadyProcessed();

        // Get epoch reward
        uint256 epochReward = calculateBlockReward();

        // Get active nodes (validators)
        address[] memory validators = omniCore.getActiveNodes();

        // Count active validators with heartbeat
        uint256 activeCount = 0;
        for (uint256 i = 0; i < validators.length;) {
            if (isValidatorActive(validators[i])) {
                ++activeCount;
            }
            unchecked { ++i; }
        }

        if (activeCount == 0) {
            // No active validators, skip epoch
            lastProcessedEpoch = epoch;
            ++totalBlocksProduced;
            return;
        }

        // Calculate and store weights
        uint256[] memory weights = new uint256[](validators.length);
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < validators.length;) {
            if (isValidatorActive(validators[i])) {
                weights[i] = _calculateValidatorWeight(validators[i], epoch);
                totalWeight += weights[i];
            }
            unchecked { ++i; }
        }

        // Distribute rewards proportionally
        if (totalWeight > 0) {
            for (uint256 i = 0; i < validators.length;) {
                if (weights[i] > 0) {
                    uint256 validatorReward = (epochReward * weights[i]) / totalWeight;
                    accumulatedRewards[validators[i]] += validatorReward;

                    emit RewardDistributed(validators[i], epoch, validatorReward, weights[i]);
                }
                unchecked { ++i; }
            }
        }

        // Update state
        lastProcessedEpoch = epoch;
        ++totalBlocksProduced;
        epochActiveValidators[epoch] = activeCount;

        emit EpochProcessed(epoch, epochReward, activeCount);
    }

    /**
     * @notice Process multiple epochs at once
     * @param count Number of epochs to process
     * @dev Gas-optimized batch processing
     */
    function processMultipleEpochs(uint256 count) external nonReentrant {
        uint256 currentEpoch = getCurrentEpoch();
        uint256 processed = 0;

        for (uint256 i = 0; i < count && lastProcessedEpoch < currentEpoch;) {
            uint256 nextEpoch = lastProcessedEpoch + 1;

            // Get epoch reward
            uint256 epochReward = calculateBlockReward();

            // Get active nodes (validators)
            address[] memory validators = omniCore.getActiveNodes();

            // Count active validators with heartbeat
            uint256 activeCount = 0;
            for (uint256 j = 0; j < validators.length;) {
                if (isValidatorActive(validators[j])) {
                    ++activeCount;
                }
                unchecked { ++j; }
            }

            if (activeCount > 0) {
                // Calculate weights
                uint256 totalWeight = 0;
                uint256[] memory weights = new uint256[](validators.length);

                for (uint256 j = 0; j < validators.length;) {
                    if (isValidatorActive(validators[j])) {
                        weights[j] = _calculateValidatorWeight(validators[j], nextEpoch);
                        totalWeight += weights[j];
                    }
                    unchecked { ++j; }
                }

                // Distribute rewards
                if (totalWeight > 0) {
                    for (uint256 j = 0; j < validators.length;) {
                        if (weights[j] > 0) {
                            uint256 validatorReward = (epochReward * weights[j]) / totalWeight;
                            accumulatedRewards[validators[j]] += validatorReward;
                        }
                        unchecked { ++j; }
                    }
                }

                epochActiveValidators[nextEpoch] = activeCount;
            }

            lastProcessedEpoch = nextEpoch;
            ++totalBlocksProduced;
            ++processed;

            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         REWARD CLAIMING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim accumulated validator rewards
     * @dev Transfers all accumulated XOM to caller
     */
    function claimRewards() external nonReentrant {
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();

        uint256 amount = accumulatedRewards[msg.sender];
        if (amount == 0) revert NoRewardsToClaim();

        // Check contract balance
        uint256 balance = xomToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Update state before transfer
        accumulatedRewards[msg.sender] = 0;
        totalClaimed[msg.sender] += amount;

        // Transfer rewards
        xomToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount, totalClaimed[msg.sender]);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         WEIGHT CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate validator weight for reward distribution
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Total weight (0-100 scale, multiplied by 100 for precision)
     *
     * @dev Weight formula:
     *      40% participation score (from OmniParticipation)
     *      30% staking amount (normalized to max stake)
     *      30% activity (60% heartbeat + 40% tx processing)
     */
    function _calculateValidatorWeight(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // 1. Participation score (40% weight, 0-100 points)
        uint256 participationScore = participation.getTotalScore(validator);
        uint256 participationComponent = (participationScore * PARTICIPATION_WEIGHT) / 100;

        // 2. Staking score (30% weight)
        uint256 stakingComponent = _calculateStakingComponent(validator);

        // 3. Activity score (30% weight)
        uint256 activityComponent = _calculateActivityComponent(validator, epoch);

        // Total weight (0-100 scale, but multiplied by 100 for precision)
        return participationComponent + stakingComponent + activityComponent;
    }

    /**
     * @notice Calculate staking component of weight
     * @param validator Validator address
     * @return Staking component (0-30 points)
     */
    function _calculateStakingComponent(address validator) internal view returns (uint256) {
        IOmniCore.Stake memory stake = omniCore.getStake(validator);

        if (!stake.active || stake.amount == 0) {
            return 0;
        }

        // Normalize staking amount to 0-100 scale
        // Use logarithmic scale for fairness:
        // 1M XOM = 20%, 10M = 40%, 100M = 60%, 1B = 80%, 10B+ = 100%
        uint256 stakingScore;
        if (stake.amount >= 10_000_000_000 ether) {
            stakingScore = 100;
        } else if (stake.amount >= 1_000_000_000 ether) {
            stakingScore = 80;
        } else if (stake.amount >= 100_000_000 ether) {
            stakingScore = 60;
        } else if (stake.amount >= 10_000_000 ether) {
            stakingScore = 40;
        } else if (stake.amount >= 1_000_000 ether) {
            stakingScore = 20;
        } else {
            // Linear scale for amounts below 1M
            stakingScore = (stake.amount * 20) / 1_000_000 ether;
        }

        return (stakingScore * STAKING_WEIGHT) / 100;
    }

    /**
     * @notice Calculate activity component of weight
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Activity component (0-30 points)
     *
     * @dev Activity = 60% heartbeat + 40% transaction processing
     */
    function _calculateActivityComponent(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // Heartbeat component (60% of activity weight)
        uint256 heartbeatScore = isValidatorActive(validator) ? 100 : 0;
        uint256 heartbeatComponent = (heartbeatScore * HEARTBEAT_SUBWEIGHT) / 100;

        // Transaction processing component (40% of activity weight)
        uint256 txScore = 0;
        uint256 totalTx = epochTotalTransactions[epoch];
        if (totalTx > 0) {
            uint256 validatorTx = transactionsProcessed[validator][epoch];
            txScore = (validatorTx * 100) / totalTx;
            if (txScore > 100) txScore = 100; // Cap at 100%
        }
        uint256 txComponent = (txScore * TX_PROCESSING_SUBWEIGHT) / 100;

        // Combined activity score
        uint256 activityScore = heartbeatComponent + txComponent;

        return (activityScore * ACTIVITY_WEIGHT) / 100;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         REWARD CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate current block reward
     * @return Block reward in XOM (18 decimals)
     *
     * @dev Reward decreases by 1% every 6,311,520 blocks
     *      Initial: 15.602 XOM
     *      After 100 reductions: ~5.6 XOM
     */
    function calculateBlockReward() public view returns (uint256) {
        uint256 reductions = totalBlocksProduced / BLOCKS_PER_REDUCTION;

        if (reductions >= MAX_REDUCTIONS) {
            return 0; // Rewards exhausted
        }

        uint256 reward = INITIAL_BLOCK_REWARD;

        // Apply compound reduction
        for (uint256 i = 0; i < reductions;) {
            reward = (reward * REDUCTION_FACTOR) / REDUCTION_DENOMINATOR;
            unchecked { ++i; }
        }

        return reward;
    }

    /**
     * @notice Get current epoch number
     * @return Current epoch based on timestamp
     */
    function getCurrentEpoch() public view returns (uint256) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < genesisTimestamp) {
            return 0;
        }
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - genesisTimestamp) / EPOCH_DURATION;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get validator's pending rewards
     * @param validator Validator address
     * @return Amount of unclaimed rewards
     */
    function getPendingRewards(address validator) external view returns (uint256) {
        return accumulatedRewards[validator];
    }

    /**
     * @notice Get validator's total claimed rewards
     * @param validator Validator address
     * @return Total amount claimed
     */
    function getTotalClaimed(address validator) external view returns (uint256) {
        return totalClaimed[validator];
    }

    /**
     * @notice Get validator's current weight
     * @param validator Validator address
     * @return Current weight for reward distribution
     */
    function getValidatorWeight(address validator) external view returns (uint256) {
        return _calculateValidatorWeight(validator, getCurrentEpoch());
    }

    /**
     * @notice Get epochs pending processing
     * @return Number of unprocessed epochs
     */
    function getPendingEpochs() external view returns (uint256) {
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch <= lastProcessedEpoch) {
            return 0;
        }
        return currentEpoch - lastProcessedEpoch;
    }

    /**
     * @notice Get contract's XOM balance
     * @return Balance available for rewards
     */
    function getRewardBalance() external view returns (uint256) {
        return xomToken.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update contract references
     * @param xomTokenAddr New XOM token address
     * @param participationAddr New OmniParticipation address
     * @param omniCoreAddr New OmniCore address
     */
    function setContracts(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) revert ZeroAddress();
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        xomToken = IERC20(xomTokenAddr);
        participation = IOmniParticipation(participationAddr);
        omniCore = IOmniCore(omniCoreAddr);

        emit ContractsUpdated(xomTokenAddr, participationAddr, omniCoreAddr);
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(recipient, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
