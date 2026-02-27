// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

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
    function getTotalScore(
        address user
    ) external view returns (uint256);

    /// @notice Check if user can be a validator
    /// @param user Address to check
    /// @return True if qualified
    function canBeValidator(
        address user
    ) external view returns (bool);
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
    function getStake(
        address user
    ) external view returns (Stake memory);

    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if validator
    function isValidator(
        address validator
    ) external view returns (bool);

    /// @notice Get all active nodes
    /// @return Array of active node addresses
    function getActiveNodes()
        external
        view
        returns (address[] memory);
}

/**
 * @title OmniValidatorRewards
 * @author OmniBazaar Team
 * @notice Trustless validator reward distribution for OmniBazaar
 * @dev Time-based epoch distribution with participation weighting.
 *
 * Weight Calculation:
 * - 40% participation score (from OmniParticipation)
 * - 30% staking amount (from OmniCore)
 * - 30% activity (heartbeat + transaction processing)
 *
 * Relationship Between Block Rewards and Validator Rewards:
 *   Block rewards are the primary funding source for this contract.
 *   The MintController mints XOM per block at the emission schedule
 *   rate. A portion of each block reward is allocated to validator
 *   rewards and deposited into this contract. Validators earn
 *   rewards proportional to their weighted participation score.
 *   The per-epoch reward is calculated using the same emission
 *   schedule as block rewards (15.602 XOM initial, 1% reduction
 *   per 6,311,520 epochs).
 *
 * Reward Distribution:
 * - Epoch every 2 seconds (tied to block time)
 * - Rewards accumulate in contract
 * - Validators claim via claimRewards()
 *
 * Block Reward Schedule:
 * - Initial: 15.602 XOM per block
 * - Reduction: 1% every 6,311,520 blocks
 * - Target: 6.089 billion XOM over 40 years
 *
 * Security:
 * - Pausable by admin for emergency scenarios
 * - Sequential epoch enforcement prevents reward destruction
 * - Retired validators can still claim earned rewards
 * - 48h timelock on contract reference updates
 * - 48h timelock on UUPS upgrades (H-01 audit fix Round 3)
 * - Flash-stake protection via lock expiry check
 * - Validator iteration capped at 200 per epoch
 * - Transaction recording capped at 1000 per call
 * - Epoch processing restricted to BLOCKCHAIN_ROLE (M-07)
 * - Batch processing capped at 50 epochs (M-03)
 * - External calls wrapped in try/catch (M-01 Round 3)
 * - Total outstanding rewards tracked for solvency (M-02 R3)
 * - Ossification mechanism for permanent upgrade lockdown
 *
 * Planned Ossification Timeline (M-04 audit recommendation):
 *   After initial deployment and a minimum 6-month tuning period
 *   on mainnet, the admin (via governance vote) should call
 *   ossify() to permanently freeze the contract. Once ossified:
 *   - No further UUPS upgrades are possible
 *   - Reward parameters become immutable
 *   - Only epoch processing, heartbeats, and claims continue
 *   - Admin retains pause/unpause and contract reference updates
 *   Post-ossification risk rating drops from 7/10 to 3/10.
 *
 * Audit Fixes (2026-02-22):
 * - M-02: Reward reduction based on epoch number (time-based)
 * - M-03: Batch processing capped at MAX_BATCH_EPOCHS (50)
 * - M-04: Staking score uses linear interpolation
 * - M-05: Graduated heartbeat scoring (not binary)
 * - M-07: processEpoch restricted to BLOCKCHAIN_ROLE
 *
 * Audit Fixes (2026-02-26 Round 3):
 * - H-01: Upgrade timelock (propose/apply with 48h delay)
 * - M-01: External calls wrapped in try/catch
 * - M-02: totalOutstandingRewards accumulator for solvency
 * - M-03: MAX_BATCH_EPOCHS documented (50 = 100s catch-up)
 * - M-04: Ossification timeline documented
 *
 * Gateway Role Bonus (2026-02-27):
 * - roleMultiplier mapping: basis-point multiplier per validator
 *   (10000 = 1.0x, 15000 = 1.5x). Separate from penalty
 *   rewardMultiplier (0-100 scale) which cannot represent >1.0x.
 * - Gateway validators earn 1.5x to offset AVAX staking costs
 *   and avalanchego infrastructure overhead.
 * - Anti-gaming: bonus only applied when _heartbeatScore > 0
 *   (active heartbeat within 20s). Offline = no bonus.
 * - Max cap: 20000 bps (2.0x) to prevent abuse.
 * - Access: ROLE_MANAGER_ROLE (granted to deployer + validators).
 */
contract OmniValidatorRewards is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                          TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Pending contract references awaiting timelock
    /// @dev Set via proposeContracts(), applied via applyContracts()
    struct PendingContractsUpdate {
        address xomToken;
        address participation;
        address omniCore;
        uint256 effectiveTimestamp;
    }

    /// @notice Pending upgrade awaiting timelock
    /// @dev Set via proposeUpgrade(), checked in _authorizeUpgrade()
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveTimestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for recording transaction processing
    bytes32 public constant BLOCKCHAIN_ROLE =
        keccak256("BLOCKCHAIN_ROLE");

    /// @notice Role for applying reward penalties
    bytes32 public constant PENALTY_ROLE =
        keccak256("PENALTY_ROLE");

    /// @notice Role for managing gateway/service-node role multipliers
    bytes32 public constant ROLE_MANAGER_ROLE =
        keccak256("ROLE_MANAGER_ROLE");

    /// @notice Epoch duration in seconds (2 second blocks)
    uint256 public constant EPOCH_DURATION = 2;

    /// @notice Heartbeat timeout for active status (20s = 10 epochs)
    uint256 public constant HEARTBEAT_TIMEOUT = 20;

    /// @notice Initial block reward (15.602 XOM with 18 decimals)
    uint256 public constant INITIAL_BLOCK_REWARD =
        15_602_000_000_000_000_000;

    /// @notice Blocks per reduction period (6,311,520 blocks)
    uint256 public constant BLOCKS_PER_REDUCTION = 6_311_520;

    /// @notice Reward reduction factor (99% = keep 99%, reduce 1%)
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

    /// @notice Maximum transactions recordable in a single call
    uint256 public constant MAX_TX_BATCH = 1000;

    /// @notice Maximum validators processed per epoch
    /// @dev Prevents gas DoS when validator set grows large
    uint256 public constant MAX_VALIDATORS_PER_EPOCH = 200;

    /// @notice Maximum epochs processable in a single batch
    /// @dev Limits state drift when processing historical epochs
    ///      with current validator/heartbeat state (M-03 fix).
    ///      50 epochs = 100 seconds of catch-up per batch.
    ///      At 200 validators max per epoch, worst-case gas is
    ///      50 * 200 = 10,000 weight calculations per batch,
    ///      well within Avalanche block gas limits.
    uint256 public constant MAX_BATCH_EPOCHS = 50;

    /// @notice Timelock delay for contract reference updates
    /// @dev 48 hours in seconds
    uint256 public constant CONTRACT_UPDATE_DELAY = 48 hours;

    /// @notice Timelock delay for UUPS upgrades
    /// @dev H-01 Round 3 audit fix: 48 hours to allow monitoring
    ///      and intervention before an upgrade takes effect.
    ///      MUST be used with a multisig wallet for production.
    uint256 public constant UPGRADE_DELAY = 48 hours;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

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

    /// @notice Total blocks produced (for monitoring only)
    /// @dev Not used in reward calculation (epoch-based instead).
    ///      Kept for off-chain monitoring and transparency.
    uint256 public totalBlocksProduced;

    /// @notice Accumulated rewards per validator
    mapping(address => uint256) public accumulatedRewards;

    /// @notice Total rewards claimed per validator
    mapping(address => uint256) public totalClaimed;

    /// @notice Last heartbeat timestamp per validator
    mapping(address => uint256) public lastHeartbeat;

    /// @notice Transactions processed per validator per epoch
    mapping(address => mapping(uint256 => uint256))
        public transactionsProcessed;

    /// @notice Total transactions in an epoch
    mapping(uint256 => uint256) public epochTotalTransactions;

    /// @notice Active validators count at epoch end
    mapping(uint256 => uint256) public epochActiveValidators;

    /// @notice Pending contract reference update with timelock
    PendingContractsUpdate public pendingContracts;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Total outstanding (unclaimed) rewards across all validators
    /// @dev M-02 Round 3 audit fix: tracks total allocated but unclaimed
    ///      rewards. Enables solvency check: balance >= totalOutstanding.
    uint256 public totalOutstandingRewards;

    /// @notice Pending upgrade awaiting timelock
    /// @dev H-01 Round 3 audit fix: UUPS upgrades require proposal +
    ///      48h delay before execution
    PendingUpgrade public pendingUpgrade;

    /// @notice Reward multiplier per validator (0-100 percentage)
    /// @dev Defaults to 0 which is treated as 100% (full rewards).
    ///      Set via setRewardMultiplier() by PENALTY_ROLE.
    ///      0 = default (100%), 1-100 = explicit multiplier.
    mapping(address => uint256) public rewardMultiplier;

    /// @notice Role-based reward multiplier in basis points
    /// @dev Gateway validators earn 1.5x (15000 bps) vs service
    ///      nodes at 1.0x (10000 bps). Set via setRoleMultiplier()
    ///      by ROLE_MANAGER_ROLE. Unset (0) defaults to 10000 (1.0x).
    ///      Only applied when validator has an active heartbeat,
    ///      preventing offline nodes from claiming the bonus.
    mapping(address => uint256) public roleMultiplier;

    /// @dev Storage gap for future upgrades.
    ///      Slots used: 16 explicit + mappings (7 slot headers).
    ///      Gap = 34 to leave headroom.
    uint256[34] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when epoch is processed
    /// @param epoch The epoch number that was processed
    /// @param totalReward Total XOM reward distributed
    /// @param activeValidators Count of active validators
    event EpochProcessed(
        uint256 indexed epoch,
        uint256 indexed totalReward,
        uint256 indexed activeValidators
    );

    /// @notice Emitted when validator claims rewards
    /// @param validator Address of the claiming validator
    /// @param amount Amount of XOM claimed
    /// @param claimedTotal Cumulative total claimed by validator
    event RewardsClaimed(
        address indexed validator,
        uint256 indexed amount,
        uint256 indexed claimedTotal
    );

    /// @notice Emitted when validator submits heartbeat
    /// @param validator Address of the validator
    /// @param timestamp Block timestamp of the heartbeat
    event ValidatorHeartbeat(
        address indexed validator,
        uint256 indexed timestamp
    );

    /// @notice Emitted when transaction processing is recorded
    /// @param validator Address of the processing validator
    /// @param epoch Epoch in which transactions were recorded
    /// @param count Number of transactions recorded
    event TransactionProcessed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 indexed count
    );

    /// @notice Emitted when contract references are updated
    /// @param xomTokenAddr New XOM token address
    /// @param participationAddr New OmniParticipation address
    /// @param omniCoreAddr New OmniCore address
    event ContractsUpdated(
        address indexed xomTokenAddr,
        address indexed participationAddr,
        address indexed omniCoreAddr
    );

    /// @notice Emitted when reward is distributed to validator
    /// @param validator Address receiving the reward
    /// @param epoch Epoch for which reward was distributed
    /// @param amount Amount of XOM distributed
    /// @param weight Validator's weight used for calculation
    event RewardDistributed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 indexed amount,
        uint256 weight
    );

    /// @notice Emitted when reward distribution fails for a validator
    /// @dev M-01 Round 3 audit fix: emitted when external call to
    ///      OmniParticipation or OmniCore fails during weight calc.
    /// @param validator Address that failed
    /// @param epoch Epoch being processed
    /// @param reason Encoded revert reason (may be empty)
    event RewardDistributionFailed(
        address indexed validator,
        uint256 indexed epoch,
        bytes reason
    );

    /// @notice Emitted when emergency withdrawal occurs
    /// @param token Address of the withdrawn token
    /// @param amount Amount withdrawn
    /// @param recipient Address receiving the tokens
    event EmergencyWithdrawal(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a contract update is proposed
    /// @param xomTokenAddr Proposed XOM token address
    /// @param participationAddr Proposed participation address
    /// @param omniCoreAddr Proposed OmniCore address
    /// @param effectiveTimestamp When the update can be applied
    event ContractsUpdateProposed(
        address indexed xomTokenAddr,
        address indexed participationAddr,
        address indexed omniCoreAddr,
        uint256 effectiveTimestamp
    );

    /// @notice Emitted when a pending contract update is cancelled
    event ContractsUpdateCancelled();

    /// @notice Emitted when validator set exceeds cap
    /// @param totalValidators Total active validators found
    /// @param processedCount Number actually processed
    event ValidatorSetCapped(
        uint256 indexed totalValidators,
        uint256 indexed processedCount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when a UUPS upgrade is proposed
    /// @param newImplementation Proposed implementation address
    /// @param effectiveTimestamp When the upgrade can be executed
    event UpgradeProposed(
        address indexed newImplementation,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a pending upgrade is cancelled
    event UpgradeCancelled();

    /// @notice Emitted when a validator's reward multiplier is changed
    /// @param validator Address of the penalized/restored validator
    /// @param oldMultiplier Previous multiplier value
    /// @param newMultiplier New multiplier value (0-100)
    /// @param reason Human-readable reason for the change
    event RewardMultiplierChanged(
        address indexed validator,
        uint256 indexed oldMultiplier,
        uint256 indexed newMultiplier,
        string reason
    );

    /// @notice Emitted when a validator's role multiplier is changed
    /// @param validator Address of the validator
    /// @param multiplierBps New multiplier in basis points
    event RoleMultiplierUpdated(
        address indexed validator,
        uint256 indexed multiplierBps
    );

    // ══════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Caller is not a validator
    error NotValidator();

    /// @notice No rewards to claim
    error NoRewardsToClaim();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Epoch must be processed sequentially
    error EpochNotSequential();

    /// @notice Future epoch cannot be processed
    error FutureEpoch();

    /// @notice Insufficient contract balance
    error InsufficientBalance();

    /// @notice Thrown when trying to withdraw reward tokens
    error CannotWithdrawRewardToken();

    /// @notice Thrown when batch size exceeds maximum
    error BatchTooLarge();

    /// @notice Thrown when timelock has not elapsed
    error TimelockNotElapsed();

    /// @notice Thrown when no pending update exists
    error NoPendingUpdate();

    /// @notice Thrown when staking lock has expired
    error StakeLockExpired();

    /// @notice Thrown when validator set exceeds cap
    error TooManyValidators();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when upgrade target has no deployed code
    error InvalidImplementation();

    /// @notice Thrown when upgrade was not proposed or does not match
    /// @param proposed The proposed implementation address
    /// @param attempted The attempted implementation address
    error UpgradeNotProposed(
        address proposed,
        address attempted
    );

    /// @notice Thrown when reward multiplier exceeds 100
    error MultiplierTooHigh();

    /// @notice Thrown when role multiplier exceeds 20000 bps (2.0x)
    error RoleMultiplierTooHigh();

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during proxy deployment. Sets up roles,
     *      external contract references, and genesis timestamp.
     * @param xomTokenAddr Address of XOM token contract
     * @param participationAddr Address of OmniParticipation
     * @param omniCoreAddr Address of OmniCore contract
     */
    function initialize(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BLOCKCHAIN_ROLE, msg.sender);
        _grantRole(ROLE_MANAGER_ROLE, msg.sender);

        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) {
            revert ZeroAddress();
        }
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        xomToken = IERC20(xomTokenAddr);
        participation =
            IOmniParticipation(participationAddr);
        omniCore = IOmniCore(omniCoreAddr);

        // solhint-disable-next-line not-rely-on-time
        genesisTimestamp = block.timestamp;
        lastProcessedEpoch = 0;
        totalBlocksProduced = 0;
        totalOutstandingRewards = 0;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       EXTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit validator heartbeat
     * @dev Should be called every ~10 epochs (20 seconds).
     *      Only active validators may submit heartbeats.
     */
    function submitHeartbeat() external whenNotPaused {
        if (!omniCore.isValidator(msg.sender)) {
            revert NotValidator();
        }

        // solhint-disable-next-line not-rely-on-time
        lastHeartbeat[msg.sender] = block.timestamp;

        /* solhint-disable not-rely-on-time */
        emit ValidatorHeartbeat(
            msg.sender, block.timestamp
        );
        /* solhint-enable not-rely-on-time */
    }

    /**
     * @notice Record transaction processing by validator
     * @dev Called by BLOCKCHAIN_ROLE when validator processes
     *      a transaction.
     * @param validator Address of processing validator
     */
    function recordTransactionProcessing(
        address validator
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (!omniCore.isValidator(validator)) {
            revert NotValidator();
        }

        uint256 currentEpoch = getCurrentEpoch();
        ++transactionsProcessed[validator][currentEpoch];
        ++epochTotalTransactions[currentEpoch];

        emit TransactionProcessed(
            validator, currentEpoch, 1
        );
    }

    /**
     * @notice Record multiple transaction processing
     * @dev Capped at MAX_TX_BATCH (1000) per call to prevent
     *      unbounded gas consumption.
     * @param validator Address of processing validator
     * @param count Number of transactions processed
     */
    function recordMultipleTransactions(
        address validator,
        uint256 count
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (count == 0 || count > MAX_TX_BATCH) {
            revert BatchTooLarge();
        }
        if (!omniCore.isValidator(validator)) {
            revert NotValidator();
        }

        uint256 currentEpoch = getCurrentEpoch();
        transactionsProcessed[validator][currentEpoch] += count;
        epochTotalTransactions[currentEpoch] += count;

        emit TransactionProcessed(
            validator, currentEpoch, count
        );
    }

    /**
     * @notice Process epoch and distribute rewards
     * @dev Epochs MUST be processed sequentially to prevent
     *      reward destruction via epoch skipping.
     *      Only BLOCKCHAIN_ROLE can call (M-07 fix).
     * @param epoch Epoch number to process
     */
    function processEpoch(
        uint256 epoch
    )
        external
        onlyRole(BLOCKCHAIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 currentEpoch = getCurrentEpoch();
        if (epoch != lastProcessedEpoch + 1) {
            revert EpochNotSequential();
        }
        if (epoch > currentEpoch) revert FutureEpoch();

        // M-02: Use epoch-based reward to prevent emission
        // desynchronization when epochs are processed late
        uint256 epochReward =
            calculateBlockRewardForEpoch(epoch);

        // Get active nodes (validators)
        address[] memory validators =
            omniCore.getActiveNodes();

        // Count and distribute in single pass
        (
            uint256 activeCount,
            uint256[] memory weights,
            uint256 totalWeight
        ) = _computeEpochWeights(validators, epoch);

        if (activeCount == 0) {
            // No active validators, skip distribution
            lastProcessedEpoch = epoch;
            ++totalBlocksProduced;
            return;
        }

        // Distribute rewards proportionally
        _distributeRewards(
            validators,
            weights,
            totalWeight,
            epochReward,
            epoch
        );

        // Update state
        lastProcessedEpoch = epoch;
        ++totalBlocksProduced;
        epochActiveValidators[epoch] = activeCount;

        emit EpochProcessed(
            epoch, epochReward, activeCount
        );
    }

    /**
     * @notice Process multiple epochs at once
     * @dev Gas-optimized batch processing. Epochs are
     *      processed sequentially starting from
     *      lastProcessedEpoch + 1. Validator list is
     *      cached outside the loop (H-03 fix).
     *      Restricted to BLOCKCHAIN_ROLE to prevent
     *      front-running (M-07 fix).
     *      Capped at MAX_BATCH_EPOCHS (50 = 100 seconds
     *      of catch-up) to limit gas and reduce stale-state
     *      drift when processing historical epochs with
     *      current state (M-03 fix).
     * @param count Number of epochs to process
     */
    function processMultipleEpochs(
        uint256 count
    )
        external
        onlyRole(BLOCKCHAIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        // M-03: Cap batch size to limit state drift
        if (count > MAX_BATCH_EPOCHS) {
            revert BatchTooLarge();
        }

        uint256 currentEpoch = getCurrentEpoch();
        uint256 nextEpoch;

        // H-03: Cache validator list outside loop
        address[] memory validators =
            omniCore.getActiveNodes();

        if (validators.length > MAX_VALIDATORS_PER_EPOCH) {
            emit ValidatorSetCapped(
                validators.length,
                MAX_VALIDATORS_PER_EPOCH
            );
        }

        for (uint256 i = 0; i < count;) {
            nextEpoch = lastProcessedEpoch + 1;
            if (nextEpoch > currentEpoch) break;

            // M-02: Use epoch-based reward calculation
            uint256 epochReward =
                calculateBlockRewardForEpoch(nextEpoch);

            (
                uint256 activeCount,
                uint256[] memory weights,
                uint256 totalWeight
            ) = _computeEpochWeights(
                validators, nextEpoch
            );

            if (activeCount > 0) {
                _distributeRewards(
                    validators,
                    weights,
                    totalWeight,
                    epochReward,
                    nextEpoch
                );
                epochActiveValidators[nextEpoch] =
                    activeCount;
            }

            lastProcessedEpoch = nextEpoch;
            ++totalBlocksProduced;

            emit EpochProcessed(
                nextEpoch, epochReward, activeCount
            );

            unchecked { ++i; }
        }
    }

    /**
     * @notice Claim accumulated validator rewards
     * @dev Transfers all accumulated XOM to caller.
     *      No active-validator check: rewards earned during
     *      active period are claimable after deactivation
     *      (H-04 fix).
     *      Updates totalOutstandingRewards for solvency
     *      tracking (M-02 Round 3 fix).
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
    {
        uint256 amount = accumulatedRewards[msg.sender];
        if (amount == 0) revert NoRewardsToClaim();

        // Check contract balance
        uint256 balance = xomToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Update state before transfer (CEI pattern)
        accumulatedRewards[msg.sender] = 0;
        totalClaimed[msg.sender] += amount;
        totalOutstandingRewards -= amount;

        // Transfer rewards
        xomToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(
            msg.sender, amount, totalClaimed[msg.sender]
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Propose new contract references (48h timelock)
     * @dev Changes are not applied immediately. After the
     *      timelock elapses, call applyContracts() to finalize.
     * @param xomTokenAddr New XOM token address
     * @param participationAddr New OmniParticipation address
     * @param omniCoreAddr New OmniCore address
     */
    function proposeContracts(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) {
            revert ZeroAddress();
        }
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        /* solhint-disable not-rely-on-time */
        uint256 effective = block.timestamp
            + CONTRACT_UPDATE_DELAY;
        /* solhint-enable not-rely-on-time */

        pendingContracts = PendingContractsUpdate({
            xomToken: xomTokenAddr,
            participation: participationAddr,
            omniCore: omniCoreAddr,
            effectiveTimestamp: effective
        });

        emit ContractsUpdateProposed(
            xomTokenAddr,
            participationAddr,
            omniCoreAddr,
            effective
        );
    }

    /**
     * @notice Apply pending contract references after timelock
     * @dev Reverts if timelock has not elapsed or no pending
     *      update exists.
     */
    function applyContracts()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingContractsUpdate memory pending =
            pendingContracts;

        if (pending.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.effectiveTimestamp) {
            revert TimelockNotElapsed();
        }

        xomToken = IERC20(pending.xomToken);
        participation =
            IOmniParticipation(pending.participation);
        omniCore = IOmniCore(pending.omniCore);

        // Clear pending state
        delete pendingContracts;

        emit ContractsUpdated(
            pending.xomToken,
            pending.participation,
            pending.omniCore
        );
    }

    /**
     * @notice Cancel a pending contract reference update
     * @dev Can be called at any time before applyContracts().
     */
    function cancelContractsUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingContracts.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        delete pendingContracts;
        emit ContractsUpdateCancelled();
    }

    /**
     * @notice Propose a UUPS upgrade (48h timelock)
     * @dev H-01 Round 3 audit fix: upgrades cannot be executed
     *      immediately. The admin must propose the new
     *      implementation, wait UPGRADE_DELAY (48h), then
     *      call upgradeToAndCall(). The _authorizeUpgrade()
     *      function verifies that the proposed implementation
     *      matches and the timelock has elapsed.
     *      MUST be combined with a multisig wallet for production.
     * @param newImplementation Address of proposed implementation
     */
    function proposeUpgrade(
        address newImplementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }
        if (newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }

        /* solhint-disable not-rely-on-time */
        uint256 effective = block.timestamp + UPGRADE_DELAY;
        /* solhint-enable not-rely-on-time */

        pendingUpgrade = PendingUpgrade({
            newImplementation: newImplementation,
            effectiveTimestamp: effective
        });

        emit UpgradeProposed(newImplementation, effective);
    }

    /**
     * @notice Cancel a pending upgrade proposal
     * @dev Can be called at any time before the upgrade is executed.
     */
    function cancelUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingUpgrade.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        delete pendingUpgrade;
        emit UpgradeCancelled();
    }

    /**
     * @notice Emergency withdraw stuck tokens (non-XOM only)
     * @dev Cannot withdraw XOM to prevent draining validator
     *      rewards. SECURITY: Admin MUST be a multi-sig
     *      wallet with timelock.
     * @param token Token address to withdraw (must NOT be XOM)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (token == address(xomToken)) {
            revert CannotWithdrawRewardToken();
        }
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(token, amount, recipient);
    }

    /**
     * @notice Set reward multiplier for a validator
     * @dev Called by PENALTY_ROLE to penalize or restore validators.
     *      A multiplier of 0 is treated as 100% (default/full rewards).
     *      Values 1-100 set the explicit reward percentage.
     *      Setting to 1 effectively zeroes rewards (1% of normal).
     * @param validator Address of the validator
     * @param multiplier Reward percentage (0=default/100%, 1-100)
     * @param reason Human-readable reason for the change
     */
    function setRewardMultiplier(
        address validator,
        uint256 multiplier,
        string calldata reason
    ) external onlyRole(PENALTY_ROLE) {
        if (multiplier > 100) revert MultiplierTooHigh();

        uint256 oldMultiplier = rewardMultiplier[validator];
        rewardMultiplier[validator] = multiplier;

        emit RewardMultiplierChanged(
            validator,
            oldMultiplier,
            multiplier,
            reason
        );
    }

    /**
     * @notice Set role-based reward multiplier for a validator
     * @dev Gateway validators should be set to 15000 (1.5x) to
     *      compensate for higher operational costs (AVAX staking,
     *      avalanchego infrastructure). Service nodes default to
     *      10000 (1.0x). The bonus only applies when the validator
     *      has an active heartbeat (heartbeat score > 0), preventing
     *      offline nodes from earning the gateway premium.
     *      Maximum 20000 (2.0x) to prevent abuse.
     * @param validator Address of the validator
     * @param multiplierBps Multiplier in basis points (10000 = 1.0x)
     */
    function setRoleMultiplier(
        address validator,
        uint256 multiplierBps
    ) external onlyRole(ROLE_MANAGER_ROLE) {
        if (multiplierBps > 20000) {
            revert RoleMultiplierTooHigh();
        }

        roleMultiplier[validator] = multiplierBps;

        emit RoleMultiplierUpdated(validator, multiplierBps);
    }

    /**
     * @notice Pause all operations
     * @dev Only DEFAULT_ADMIN_ROLE can pause. Blocks epoch
     *      processing, heartbeats, claims, and recording.
     */
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Unpause operations
     * @dev Only DEFAULT_ADMIN_ROLE can unpause. Resumes
     *      normal contract operation after emergency.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    /**
     * @notice Permanently remove upgrade capability
     * @dev One-way, irreversible. Can only be called by admin
     *      (through timelock). Once ossified, the contract can
     *      never be upgraded again.
     *
     *      Planned Timeline (M-04 audit recommendation):
     *        - Deploy to mainnet
     *        - 6-month minimum tuning period
     *        - Governance vote to approve ossification
     *        - Admin calls ossify()
     *        - Post-ossification: only epoch processing,
     *          heartbeats, claims, and pause/unpause continue
     */
    function ossify()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _ossified = true;
        // Clear any pending upgrade
        delete pendingUpgrade;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ══════════════════════════════════════════════════════════════════
    //                      EXTERNAL VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Get validator's pending rewards
     * @param validator Validator address
     * @return Amount of unclaimed rewards
     */
    function getPendingRewards(
        address validator
    ) external view returns (uint256) {
        return accumulatedRewards[validator];
    }

    /**
     * @notice Get validator's total claimed rewards
     * @param validator Validator address
     * @return Total amount claimed
     */
    function getTotalClaimed(
        address validator
    ) external view returns (uint256) {
        return totalClaimed[validator];
    }

    /**
     * @notice Get validator's current weight
     * @param validator Validator address
     * @return Current weight for reward distribution
     */
    function getValidatorWeight(
        address validator
    ) external view returns (uint256) {
        return _calculateValidatorWeight(
            validator, getCurrentEpoch()
        );
    }

    /**
     * @notice Get epochs pending processing
     * @return Number of unprocessed epochs
     */
    function getPendingEpochs()
        external
        view
        returns (uint256)
    {
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch < lastProcessedEpoch + 1) {
            return 0;
        }
        return currentEpoch - lastProcessedEpoch;
    }

    /**
     * @notice Get contract's XOM balance
     * @return Balance available for rewards
     */
    function getRewardBalance()
        external
        view
        returns (uint256)
    {
        return xomToken.balanceOf(address(this));
    }

    /**
     * @notice Check if the contract is solvent
     * @dev M-02 Round 3 audit fix: compares actual token balance
     *      against total outstanding (unclaimed) rewards.
     * @return True if balance covers all outstanding obligations
     */
    function isSolvent() external view returns (bool) {
        // solhint-disable-next-line gas-strict-inequalities
        return xomToken.balanceOf(address(this))
            >= totalOutstandingRewards;
    }

    /**
     * @notice Get effective weight for a validator
     * @dev Returns the base weight scaled by both the penalty
     *      multiplier (rewardMultiplier) and the role bonus
     *      multiplier (roleMultiplier). Mirrors the logic in
     *      _computeEpochWeights() for external visibility.
     * @param validator Address of the validator
     * @return Effective weight after penalty and role application
     */
    function getEffectiveWeight(
        address validator
    ) external view returns (uint256) {
        uint256 weight = _calculateValidatorWeight(
            validator, getCurrentEpoch()
        );
        // Apply penalty multiplier
        uint256 mult = rewardMultiplier[validator];
        if (mult != 0) {
            weight = (weight * mult) / 100;
        }
        // Apply role bonus (heartbeat-gated)
        uint256 roleMul = roleMultiplier[validator];
        if (
            roleMul > 10000
                && _heartbeatScore(validator) > 0
        ) {
            weight = (weight * roleMul) / 10000;
        }
        return weight;
    }

    /**
     * @notice Get the reward multiplier for a validator
     * @dev Returns 0 if no explicit multiplier set (treated as 100%).
     * @param validator Address to check
     * @return Multiplier value (0=default/100%, 1-100=explicit)
     */
    function getRewardMultiplier(
        address validator
    ) external view returns (uint256) {
        return rewardMultiplier[validator];
    }

    /**
     * @notice Get the role multiplier for a validator
     * @dev Returns 10000 (1.0x) if no explicit value is set.
     *      Gateway validators are expected to have 15000 (1.5x).
     * @param validator Address to check
     * @return Multiplier in basis points (10000 = 1.0x default)
     */
    function getRoleMultiplier(
        address validator
    ) external view returns (uint256) {
        uint256 m = roleMultiplier[validator];
        return m == 0 ? 10000 : m;
    }

    /**
     * @notice Get the pending upgrade details
     * @return newImplementation Proposed address (zero if none)
     * @return effectiveTimestamp When upgrade can execute
     */
    function getPendingUpgrade()
        external
        view
        returns (
            address newImplementation,
            uint256 effectiveTimestamp
        )
    {
        newImplementation =
            pendingUpgrade.newImplementation;
        effectiveTimestamp =
            pendingUpgrade.effectiveTimestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       PUBLIC VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Check if validator is currently active
     * @param validator Address to check
     * @return True if heartbeat within timeout
     */
    function isValidatorActive(
        address validator
    ) public view returns (bool) {
        if (lastHeartbeat[validator] == 0) return false;
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - lastHeartbeat[validator])
            < HEARTBEAT_TIMEOUT + 1;
    }

    /**
     * @notice Calculate current block reward based on next epoch
     * @return Block reward in XOM (18 decimals)
     * @dev Convenience wrapper using lastProcessedEpoch + 1
     */
    function calculateBlockReward()
        public
        view
        returns (uint256)
    {
        return calculateBlockRewardForEpoch(
            lastProcessedEpoch + 1
        );
    }

    /**
     * @notice Get current epoch number
     * @return Current epoch based on timestamp
     */
    function getCurrentEpoch()
        public
        view
        returns (uint256)
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < genesisTimestamp) {
            return 0;
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - genesisTimestamp;
        return elapsed / EPOCH_DURATION;
    }

    /**
     * @notice Calculate block reward for a given epoch
     * @param epoch The epoch number to calculate reward for
     * @return Block reward in XOM (18 decimals)
     *
     * @dev Reward decreases by 1% every 6,311,520 epochs.
     *      Uses epoch number (time-based) rather than
     *      totalBlocksProduced to prevent emission schedule
     *      desynchronization when epochs are processed late
     *      (M-02 fix from Round 1).
     *
     *      Emission Schedule Examples:
     *        Epoch 0: 15.602 XOM (initial)
     *        Epoch 6,311,520: 15.446 XOM (1 reduction)
     *        Epoch 12,623,040: 15.291 XOM (2 reductions)
     *        Epoch ~315M (~year 20): ~9.46 XOM
     *        Epoch ~625M (~year 40): ~5.79 XOM
     *        Epoch 631,152,000+: 0 XOM (exhausted)
     */
    function calculateBlockRewardForEpoch(
        uint256 epoch
    ) public pure returns (uint256) {
        uint256 reductions =
            epoch / BLOCKS_PER_REDUCTION;

        if (reductions > MAX_REDUCTIONS - 1) {
            return 0; // Rewards exhausted
        }

        uint256 reward = INITIAL_BLOCK_REWARD;

        // Apply compound reduction
        for (uint256 i = 0; i < reductions;) {
            reward =
                (reward * REDUCTION_FACTOR)
                / REDUCTION_DENOMINATOR;
            unchecked { ++i; }
        }

        return reward;
    }

    // ══════════════════════════════════════════════════════════════════
    //                      INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @dev H-01 Round 3 audit fix: verifies that the upgrade
     *      was proposed via proposeUpgrade() and the 48h timelock
     *      has elapsed. Reverts if contract is ossified or if the
     *      implementation address does not match the proposal.
     *      MUST be combined with a multisig wallet for production.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();

        PendingUpgrade memory pending = pendingUpgrade;

        // Verify proposal exists and matches
        if (
            pending.newImplementation != newImplementation
        ) {
            revert UpgradeNotProposed(
                pending.newImplementation,
                newImplementation
            );
        }

        // Verify timelock elapsed
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.effectiveTimestamp) {
            revert TimelockNotElapsed();
        }

        // Clear pending upgrade
        delete pendingUpgrade;
    }

    /**
     * @notice Compute active validator weights for an epoch
     * @dev Iterates at most MAX_VALIDATORS_PER_EPOCH
     *      validators to prevent gas DoS (H-03 fix).
     *      External calls to OmniParticipation and OmniCore
     *      are wrapped in try/catch per validator, so one
     *      failing validator does not block the entire epoch
     *      (M-01 Round 3 fix).
     * @param validators Array of validator addresses
     * @param epoch Epoch to compute weights for
     * @return activeCount Number of active validators
     * @return weights Per-validator weight array
     * @return totalWeight Sum of all weights
     */
    function _computeEpochWeights(
        address[] memory validators,
        uint256 epoch
    )
        internal
        view
        returns (
            uint256 activeCount,
            uint256[] memory weights,
            uint256 totalWeight
        )
    {
        uint256 count = validators.length;
        uint256 cap = count > MAX_VALIDATORS_PER_EPOCH
            ? MAX_VALIDATORS_PER_EPOCH
            : count;

        weights = new uint256[](count);

        for (uint256 i = 0; i < cap;) {
            if (isValidatorActive(validators[i])) {
                uint256 baseWeight =
                    _calculateValidatorWeight(
                        validators[i], epoch
                    );
                // Apply reward multiplier (penalty)
                uint256 mult =
                    rewardMultiplier[validators[i]];
                if (mult != 0) {
                    // Explicit multiplier set (1-100%)
                    baseWeight =
                        (baseWeight * mult) / 100;
                }
                // else mult == 0 → default = 100%

                // Apply role multiplier (gateway bonus)
                // Only applies when heartbeat is active
                uint256 roleMul =
                    roleMultiplier[validators[i]];
                if (
                    roleMul > 10000
                        && _heartbeatScore(validators[i])
                            > 0
                ) {
                    baseWeight =
                        (baseWeight * roleMul) / 10000;
                }
                // else no role bonus (unset or 1.0x)
                weights[i] = baseWeight;
                totalWeight += weights[i];
                ++activeCount;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculate validator weight for distribution
     * @dev Weight formula:
     *      40% participation score (OmniParticipation)
     *      30% staking amount (OmniCore)
     *      30% activity (60% heartbeat + 40% tx processing)
     *
     *      M-01 Round 3 fix: external calls wrapped in
     *      try/catch. If OmniParticipation or OmniCore
     *      revert, the affected component defaults to 0
     *      rather than blocking the entire epoch.
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Total weight (0-100 scale)
     */
    function _calculateValidatorWeight(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // 1. Participation score (40% weight, 0-100 points)
        // M-01 R3: try/catch for external call resilience
        uint256 pScore;
        try participation.getTotalScore(validator)
            returns (uint256 s)
        {
            pScore = s;
        } catch {
            pScore = 0; // Fail-safe: no participation bonus
        }
        uint256 pComponent =
            (pScore * PARTICIPATION_WEIGHT) / 100;

        // 2. Staking score (30% weight)
        uint256 sComponent =
            _calculateStakingComponent(validator);

        // 3. Activity score (30% weight)
        uint256 aComponent =
            _calculateActivityComponent(validator, epoch);

        return pComponent + sComponent + aComponent;
    }

    /**
     * @notice Calculate staking component of weight
     * @dev Returns 0 if stake lock has expired to prevent
     *      flash-stake weight inflation (H-01 Round 1 fix).
     *      External call to omniCore.getStake() is wrapped in
     *      try/catch (M-01 Round 3 fix).
     * @param validator Validator address
     * @return Staking component (0-30 points)
     */
    function _calculateStakingComponent(
        address validator
    ) internal view returns (uint256) {
        // M-01 R3: try/catch for external call resilience
        IOmniCore.Stake memory stake;
        try omniCore.getStake(validator) returns (
            IOmniCore.Stake memory s
        ) {
            stake = s;
        } catch {
            return 0; // Fail-safe: no staking bonus
        }

        if (!stake.active || stake.amount == 0) {
            return 0;
        }

        // H-01 R1: Reject expired locks to prevent
        // flash-staking with zero duration commitment
        // solhint-disable-next-line not-rely-on-time
        if (stake.lockTime < block.timestamp + 1) {
            return 0;
        }

        // Normalize staking amount to 0-100 scale
        // Logarithmic scale for fairness
        uint256 stakingScore = _stakingTierScore(
            stake.amount
        );

        return (stakingScore * STAKING_WEIGHT) / 100;
    }

    /**
     * @notice Calculate activity component of weight
     * @dev Activity = 60% heartbeat + 40% tx processing.
     *      Heartbeat uses graduated scoring based on
     *      recency of last heartbeat rather than binary
     *      active/inactive (M-05 Round 1 fix). A validator
     *      who sent a heartbeat 1s ago scores higher than
     *      one whose heartbeat is 18s old.
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Activity component (0-30 points)
     */
    function _calculateActivityComponent(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // M-05: Graduated heartbeat scoring
        uint256 hScore = _heartbeatScore(validator);
        uint256 hComponent =
            (hScore * HEARTBEAT_SUBWEIGHT) / 100;

        // Transaction processing component (40%)
        uint256 txScore = _txProcessingScore(
            validator, epoch
        );
        uint256 txComponent =
            (txScore * TX_PROCESSING_SUBWEIGHT) / 100;

        // Combined activity score
        uint256 activityScore = hComponent + txComponent;

        return (activityScore * ACTIVITY_WEIGHT) / 100;
    }

    /**
     * @notice Distribute epoch rewards to validators
     * @dev Updates totalOutstandingRewards for solvency
     *      tracking (M-02 Round 3 fix). Emits per-validator
     *      RewardDistributed events.
     * @param validators Array of validator addresses
     * @param weights Per-validator weight array
     * @param totalWeight Sum of all weights
     * @param epochReward Total reward for this epoch
     * @param epoch Epoch number (for event emission)
     */
    function _distributeRewards(
        address[] memory validators,
        uint256[] memory weights,
        uint256 totalWeight,
        uint256 epochReward,
        uint256 epoch
    ) internal {
        if (totalWeight == 0) return;

        for (uint256 i = 0; i < validators.length;) {
            if (weights[i] > 0) {
                uint256 validatorReward =
                    (epochReward * weights[i]) / totalWeight;
                accumulatedRewards[validators[i]] +=
                    validatorReward;
                // M-02 R3: Track outstanding obligations
                totalOutstandingRewards += validatorReward;

                emit RewardDistributed(
                    validators[i],
                    epoch,
                    validatorReward,
                    weights[i]
                );
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculate graduated heartbeat score
     * @dev M-05 Round 1: Replaces binary 100/0 with graduated
     *      scoring. Heartbeat within 5s = 100, within
     *      10s = 75, within 15s = 50, within 20s = 25,
     *      older = 0. This rewards validators with
     *      consistent uptime over those that merely
     *      submit the minimum heartbeats.
     * @param validator Validator address
     * @return score Graduated score 0-100 based on
     *         heartbeat recency
     */
    function _heartbeatScore(
        address validator
    ) internal view returns (uint256 score) {
        uint256 lastHb = lastHeartbeat[validator];
        if (lastHb == 0) return 0;

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - lastHb;

        if (elapsed < 6) {
            score = 100;   // Very fresh heartbeat
        } else if (elapsed < 11) {
            score = 75;    // Recent heartbeat
        } else if (elapsed < 16) {
            score = 50;    // Getting stale
        } else if (elapsed < HEARTBEAT_TIMEOUT + 1) {
            score = 25;    // Nearly expired
        }
        // else score = 0 (expired / no heartbeat)
    }

    /**
     * @notice Calculate transaction processing score
     * @param validator Validator address
     * @param epoch Epoch to check
     * @return score Normalized score (0-100)
     */
    function _txProcessingScore(
        address validator,
        uint256 epoch
    ) internal view returns (uint256 score) {
        uint256 totalTx = epochTotalTransactions[epoch];
        if (totalTx > 0) {
            uint256 valTx =
                transactionsProcessed[validator][epoch];
            score = (valTx * 100) / totalTx;
            // Cap at 100%
            if (score > 100) score = 100;
        }
    }

    /**
     * @notice Map staking amount to a 0-100 score
     * @dev Uses linear interpolation within tiers to prevent
     *      cliff effects at boundaries (M-04 Round 1 fix):
     *      - 0 to 1M XOM: linear 0-20
     *      - 1M to 10M XOM: linear 20-40
     *      - 10M to 100M XOM: linear 40-60
     *      - 100M to 1B XOM: linear 60-80
     *      - 1B to 10B XOM: linear 80-100
     *      - 10B+ XOM: 100 (cap)
     * @param amount Staked XOM amount (18 decimals)
     * @return score Normalized score (0-100)
     */
    function _stakingTierScore(
        uint256 amount
    ) internal pure returns (uint256 score) {
        if (amount > 10_000_000_000 ether - 1) {
            score = 100;
        } else if (amount > 1_000_000_000 ether - 1) {
            // Linear interpolation: 80-100 over 1B-10B
            uint256 excess =
                amount - 1_000_000_000 ether;
            uint256 range = 9_000_000_000 ether;
            score = 80 + (excess * 20) / range;
        } else if (amount > 100_000_000 ether - 1) {
            // Linear interpolation: 60-80 over 100M-1B
            uint256 excess =
                amount - 100_000_000 ether;
            uint256 range = 900_000_000 ether;
            score = 60 + (excess * 20) / range;
        } else if (amount > 10_000_000 ether - 1) {
            // Linear interpolation: 40-60 over 10M-100M
            uint256 excess =
                amount - 10_000_000 ether;
            uint256 range = 90_000_000 ether;
            score = 40 + (excess * 20) / range;
        } else if (amount > 1_000_000 ether - 1) {
            // Linear interpolation: 20-40 over 1M-10M
            uint256 excess =
                amount - 1_000_000 ether;
            uint256 range = 9_000_000 ether;
            score = 20 + (excess * 20) / range;
        } else {
            // Linear scale for amounts below 1M: 0-20
            score = (amount * 20) / 1_000_000 ether;
        }
    }
}
