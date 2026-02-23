// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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

// ════════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ════════════════════════════════════════════════════════════════════════

/**
 * @title IOmniCoreStaking
 * @author OmniBazaar Team
 * @notice Interface for reading stake data from the OmniCore contract
 * @dev Single source of truth for user stake information.
 *      The StakingRewardPool reads staking positions from this oracle
 *      to compute time-based APR rewards.
 */
interface IOmniCoreStaking {
    /// @notice Minimal stake information returned by OmniCore
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Get stake information for a user
    /// @param user Address of the staker
    /// @return Stake struct with staking details
    function getStake(address user) external view returns (Stake memory);
}

// ════════════════════════════════════════════════════════════════════════
//                          STAKING REWARD POOL
// ════════════════════════════════════════════════════════════════════════

/**
 * @title StakingRewardPool
 * @author OmniBazaar Team
 * @notice Trustless on-chain staking reward pool using time-based
 *         drip pattern
 * @dev Computes rewards entirely on-chain from OmniCore stake data.
 *      No validator involvement in claims -- fully trustless.
 *
 * Reward Calculation:
 * - Reads stake amount, tier, and duration from OmniCore.getStake()
 * - APR determined by staking tier (5-9%) + duration bonus (0-3%)
 * - Rewards accrue per-second:
 *     (amount * effectiveAPR * elapsed) / (365 days * 10000)
 * - Users call claimRewards() directly to collect accrued XOM
 *
 * Pool Funding:
 * - Anyone can call depositToPool() to fund the reward pool
 * - Validators deposit block reward share and fee allocations
 *
 * Safety:
 * - snapshotRewards() freezes accrued rewards before unlock
 * - frozenRewards persist even after stake becomes inactive
 * - lastActiveStake caches stake data for post-unlock claims
 * - setContracts() changes are timelocked (48h delay)
 * - APR values are capped at MAX_TOTAL_APR (12%)
 * - Tier values are independently validated against staked amounts
 * - UUPS upgradeable with AccessControl for admin operations
 *
 * Audit Fixes (2026-02-20):
 * - H-01: emergencyWithdraw blocks XOM withdrawal
 * - H-02: setContracts uses 48h timelock
 * - H-03: APR bounded by MAX_TOTAL_APR (1200 bps)
 * - H-04: lastActiveStake cache prevents post-unlock reward loss
 * - H-05: _authorizeUpgrade uses DEFAULT_ADMIN_ROLE
 * - H-07: _clampTier validates tier vs staked amount
 *
 * Audit Fixes (2026-02-22):
 * - M-01: Partial claims when pool underfunded
 * - M-03: PausableUpgradeable for emergency stops
 * - M-04: APR changes use 24h timelock
 * - M-05: Duration tier range-based (documented design)
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract StakingRewardPool is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // solhint-disable-next-line max-states-count

    // ════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Cached stake data for post-unlock reward calculation
    /// @dev Stored when snapshotRewards() is called so that rewards
    ///      for the last active period can be computed even after
    ///      OmniCore.unlock() sets the stake to inactive.
    struct CachedStake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        uint256 snapshotTime;
    }

    /// @notice Pending contract change proposal (48h timelock)
    /// @dev Created by proposeContracts(), executed via
    ///      executeContracts()
    struct PendingContracts {
        address omniCore;
        address xomToken;
        uint256 executeAfter;
    }

    /// @notice Pending APR change proposal (24h timelock)
    /// @dev Created by proposeAPRChange(), executed via
    ///      executeAPRChange(). Covers both tier APR
    ///      and duration bonus APR changes.
    struct PendingAPRChange {
        uint256 tier;
        uint256 newAPR;
        bool isDurationBonus;
        uint256 executeAfter;
    }

    // ════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Total basis points for percentage calculations
    /// @dev 100% = 10000 basis points
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Seconds per year for APR calculations (365 days)
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Number of staking tiers (0 = unused, 1-5 = active)
    uint256 public constant MAX_TIER = 5;

    /// @notice Number of duration bonus tiers (0-3)
    uint256 public constant MAX_DURATION_TIER = 3;

    /// @notice One month in seconds (30 days)
    uint256 public constant ONE_MONTH = 30 days;

    /// @notice Six months in seconds (180 days)
    uint256 public constant SIX_MONTHS = 180 days;

    /// @notice Two years in seconds (730 days)
    uint256 public constant TWO_YEARS = 730 days;

    /// @notice Maximum combined APR in basis points (12% = 1200 bps)
    /// @dev Per tokenomics: max 9% base (tier 5) + 3% duration = 12%
    uint256 public constant MAX_TOTAL_APR = 1200;

    /// @notice Timelock delay for contract reference changes
    /// @dev 48 hours protects against instant oracle replacement
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    /// @notice Timelock delay for APR changes
    /// @dev 24 hours prevents front-running APR adjustments
    ///      via snapshotRewards() (M-04 fix)
    uint256 public constant APR_TIMELOCK_DELAY = 24 hours;

    // ════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ════════════════════════════════════════════════════════════════════

    /// @notice OmniCore contract for reading stake data
    IOmniCoreStaking public omniCore;

    /// @notice XOM token contract
    IERC20 public xomToken;

    /// @notice Per-user last claim timestamp
    mapping(address => uint256) public lastClaimTime;

    /// @notice Per-user frozen rewards (snapshot before unlock)
    mapping(address => uint256) public frozenRewards;

    /// @notice APR in basis points per staking tier
    /// @dev Index 0 unused (no stake), tiers 1-5 at indices 1-5
    uint256[6] public tierAPR;

    /// @notice Duration bonus APR in basis points
    /// @dev [0]=none, [1]=1mo, [2]=6mo, [3]=2yr
    uint256[4] public durationBonusAPR;

    /// @notice Total XOM deposited into the reward pool
    uint256 public totalDeposited;

    /// @notice Total XOM distributed from the reward pool
    uint256 public totalDistributed;

    /// @notice Per-user cached stake data from last snapshot
    /// @dev Preserves reward calculation after OmniCore.unlock()
    mapping(address => CachedStake) public lastActiveStake;

    /// @notice Pending contract reference change (48h timelock)
    PendingContracts public pendingContracts;

    /// @notice Pending APR change (24h timelock, M-04 fix)
    PendingAPRChange public pendingAPRChange;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Storage gap for future upgrades
    /// @dev Reduced from 36 to 35 to accommodate _ossified.
    uint256[35] private __gap;

    // ════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user claims staking rewards
    /// @param user Address of the claimant
    /// @param amount Amount of XOM claimed
    /// @param timestamp Block timestamp of claim
    event RewardsClaimed(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /// @notice Emitted when rewards are frozen before unlock
    /// @param user Address whose rewards were frozen
    /// @param amount Amount of XOM frozen
    /// @param timestamp Block timestamp of snapshot
    event RewardsSnapshot(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /// @notice Emitted when XOM is deposited to the reward pool
    /// @param depositor Address that deposited
    /// @param amount Amount of XOM deposited
    /// @param newTotalDeposited New total deposited amount
    event PoolDeposit(
        address indexed depositor,
        uint256 indexed amount,
        uint256 indexed newTotalDeposited
    );

    /// @notice Emitted when tier APR is updated
    /// @param tier Tier index that was updated
    /// @param newAPR New APR in basis points
    event TierAPRUpdated(
        uint256 indexed tier,
        uint256 indexed newAPR
    );

    /// @notice Emitted when duration bonus APR is updated
    /// @param tier Duration tier that was updated
    /// @param newAPR New bonus APR in basis points
    event DurationBonusAPRUpdated(
        uint256 indexed tier,
        uint256 indexed newAPR
    );

    /// @notice Emitted when contract references are updated
    /// @param omniCoreAddr New OmniCore address
    /// @param xomTokenAddr New XOM token address
    event ContractsUpdated(
        address indexed omniCoreAddr,
        address indexed xomTokenAddr
    );

    /// @notice Emitted when a contract change is proposed
    /// @param omniCoreAddr Proposed OmniCore address
    /// @param xomTokenAddr Proposed XOM token address
    /// @param executeAfter Earliest execution timestamp
    event ContractsChangeProposed(
        address indexed omniCoreAddr,
        address indexed xomTokenAddr,
        uint256 indexed executeAfter
    );

    /// @notice Emitted when a pending contract change is cancelled
    event ContractsChangeCancelled();

    /// @notice Emitted when tokens are withdrawn in an emergency
    /// @param token Token address withdrawn
    /// @param amount Amount withdrawn
    /// @param recipient Address that received the tokens
    event EmergencyWithdrawal(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when an APR change is proposed (M-04)
    /// @param tier Tier index affected
    /// @param newAPR Proposed new APR in basis points
    /// @param isDurationBonus Whether this is a duration bonus
    /// @param executeAfter Earliest execution timestamp
    event APRChangeProposed(
        uint256 indexed tier,
        uint256 indexed newAPR,
        bool isDurationBonus,
        uint256 executeAfter
    );

    /// @notice Emitted when a pending APR change is cancelled
    event APRChangeCancelled();

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ════════════════════════════════════════════════════════════════════

    /// @notice No rewards available to claim
    error NoRewardsToClaim();

    /// @notice Reward pool has insufficient XOM balance
    error PoolUnderfunded();

    /// @notice Zero address provided where non-zero required
    error ZeroAddress();

    /// @notice Invalid tier index provided
    error InvalidTier();

    /// @notice Invalid amount (zero or overflow)
    error InvalidAmount();

    /// @notice Cannot withdraw XOM reward token via emergency withdraw
    error CannotWithdrawRewardToken();

    /// @notice No pending contract change exists
    error NoPendingChange();

    /// @notice Timelock delay has not elapsed yet
    error TimelockNotElapsed();

    /// @notice APR exceeds the maximum allowed value
    error APRExceedsMaximum();

    /// @notice No pending APR change exists
    error NoPendingAPRChange();

    /// @notice APR timelock has not elapsed
    error APRTimelockNotElapsed();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    // ════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor disables initializers for the implementation
     * @dev Prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the StakingRewardPool contract
     * @dev Sets up APR tiers per OmniBazaar tokenomics.
     *      Grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to deployer.
     * @param omniCoreAddr Address of OmniCore contract
     * @param xomTokenAddr Address of XOM token contract
     */
    function initialize(
        address omniCoreAddr,
        address xomTokenAddr
    ) external initializer {
        if (omniCoreAddr == address(0)) revert ZeroAddress();
        if (xomTokenAddr == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        omniCore = IOmniCoreStaking(omniCoreAddr);
        xomToken = IERC20(xomTokenAddr);

        // Base APR per staking tier (basis points)
        // Tier 0: unused (no stake), Tier 1-5: 5-9%
        tierAPR[1] = 500;   // 5%
        tierAPR[2] = 600;   // 6%
        tierAPR[3] = 700;   // 7%
        tierAPR[4] = 800;   // 8%
        tierAPR[5] = 900;   // 9%

        // Duration bonus APR (basis points)
        // Tier 0: none, Tier 1: +1%, Tier 2: +2%, Tier 3: +3%
        durationBonusAPR[1] = 100;  // +1%
        durationBonusAPR[2] = 200;  // +2%
        durationBonusAPR[3] = 300;  // +3%
    }

    // ════════════════════════════════════════════════════════════════════
    //                         EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim all accrued staking rewards
     * @dev Transfers earned XOM directly to caller.
     *      Reverts if zero rewards. Follows CEI pattern.
     *      If pool is underfunded, pays out available
     *      balance and records remaining as frozen
     *      rewards for future claims (M-01 fix).
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
    {
        uint256 reward = earned(msg.sender);
        if (reward == 0) revert NoRewardsToClaim();

        uint256 poolBalance =
            xomToken.balanceOf(address(this));

        // M-01: Allow partial claims when pool underfunded
        uint256 payout = reward;
        uint256 remainder = 0;
        if (poolBalance < reward) {
            payout = poolBalance;
            remainder = reward - poolBalance;
        }

        // Update state before transfer (CEI pattern)
        // solhint-disable-next-line not-rely-on-time
        lastClaimTime[msg.sender] = block.timestamp;
        frozenRewards[msg.sender] = remainder;
        totalDistributed += payout;

        // Transfer rewards to caller
        if (payout > 0) {
            xomToken.safeTransfer(msg.sender, payout);
        }

        // solhint-disable not-rely-on-time
        emit RewardsClaimed(
            msg.sender, payout, block.timestamp
        );
        // solhint-enable not-rely-on-time
    }

    /**
     * @notice Snapshot and freeze accrued rewards before unlock
     * @dev Should be called BEFORE OmniCore.unlock() to preserve
     *      rewards. Caches stake data into lastActiveStake so
     *      rewards for the last active period can still be computed
     *      even after the stake becomes inactive.
     *      Callable by anyone for any user (intentional design).
     * @param user Address to snapshot rewards for
     */
    function snapshotRewards(
        address user
    ) external whenNotPaused {
        if (user == address(0)) revert ZeroAddress();

        IOmniCoreStaking.Stake memory stakeData =
            omniCore.getStake(user);

        // Only snapshot if stake is still active
        if (!stakeData.active || stakeData.amount == 0) {
            return;
        }

        uint256 accrued = _computeAccrued(user, stakeData);

        if (accrued > 0) {
            frozenRewards[user] += accrued;
            // solhint-disable-next-line not-rely-on-time
            lastClaimTime[user] = block.timestamp;

            // solhint-disable not-rely-on-time
            emit RewardsSnapshot(
                user, accrued, block.timestamp
            );
            // solhint-enable not-rely-on-time
        }

        // Cache stake data for post-unlock calculation (H-04)
        // solhint-disable not-rely-on-time
        lastActiveStake[user] = CachedStake({
            amount: stakeData.amount,
            tier: stakeData.tier,
            duration: stakeData.duration,
            lockTime: stakeData.lockTime,
            snapshotTime: block.timestamp
        });
        // solhint-enable not-rely-on-time
    }

    /**
     * @notice Deposit XOM to fund the reward pool
     * @dev Anyone can deposit. Validators deposit block reward share
     *      and fee allocations to keep the pool funded.
     * @param amount Amount of XOM to deposit
     */
    function depositToPool(
        uint256 amount
    ) external whenNotPaused {
        if (amount == 0) revert InvalidAmount();

        xomToken.safeTransferFrom(
            msg.sender, address(this), amount
        );
        totalDeposited += amount;

        emit PoolDeposit(msg.sender, amount, totalDeposited);
    }

    /**
     * @notice Propose a tier APR change (24h timelock)
     * @dev M-04: APR changes are timelocked to prevent
     *      front-running via snapshotRewards(). Only
     *      ADMIN_ROLE can propose. Replaces any existing
     *      pending APR change.
     * @param tier Tier index (1-5)
     * @param apr New APR in basis points (e.g., 500 = 5%)
     */
    function proposeTierAPR(
        uint256 tier,
        uint256 apr
    ) external onlyRole(ADMIN_ROLE) {
        if (tier == 0 || tier > MAX_TIER) {
            revert InvalidTier();
        }
        if (apr > MAX_TOTAL_APR) {
            revert APRExceedsMaximum();
        }

        // solhint-disable not-rely-on-time
        uint256 execAfter =
            block.timestamp + APR_TIMELOCK_DELAY;
        // solhint-enable not-rely-on-time

        pendingAPRChange = PendingAPRChange({
            tier: tier,
            newAPR: apr,
            isDurationBonus: false,
            executeAfter: execAfter
        });

        emit APRChangeProposed(
            tier, apr, false, execAfter
        );
    }

    /**
     * @notice Propose a duration bonus APR change (24h timelock)
     * @dev M-04: Duration bonus APR changes are timelocked.
     *      Replaces any existing pending APR change.
     * @param tier Duration tier index (0-3)
     * @param apr New bonus APR in basis points
     */
    function proposeDurationBonusAPR(
        uint256 tier,
        uint256 apr
    ) external onlyRole(ADMIN_ROLE) {
        if (tier > MAX_DURATION_TIER) {
            revert InvalidTier();
        }
        if (apr > MAX_TOTAL_APR) {
            revert APRExceedsMaximum();
        }

        // solhint-disable not-rely-on-time
        uint256 execAfter =
            block.timestamp + APR_TIMELOCK_DELAY;
        // solhint-enable not-rely-on-time

        pendingAPRChange = PendingAPRChange({
            tier: tier,
            newAPR: apr,
            isDurationBonus: true,
            executeAfter: execAfter
        });

        emit APRChangeProposed(
            tier, apr, true, execAfter
        );
    }

    /**
     * @notice Execute a pending APR change after timelock
     * @dev Only ADMIN_ROLE can execute. Reverts if timelock
     *      has not elapsed or no pending change exists.
     */
    function executeAPRChange()
        external
        onlyRole(ADMIN_ROLE)
    {
        PendingAPRChange memory pending = pendingAPRChange;
        if (pending.executeAfter == 0) {
            revert NoPendingAPRChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.executeAfter) {
            revert APRTimelockNotElapsed();
        }

        if (pending.isDurationBonus) {
            durationBonusAPR[pending.tier] = pending.newAPR;
            emit DurationBonusAPRUpdated(
                pending.tier, pending.newAPR
            );
        } else {
            tierAPR[pending.tier] = pending.newAPR;
            emit TierAPRUpdated(
                pending.tier, pending.newAPR
            );
        }

        delete pendingAPRChange;
    }

    /**
     * @notice Cancel a pending APR change
     * @dev Only ADMIN_ROLE can cancel.
     */
    function cancelAPRChange()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingAPRChange.executeAfter == 0) {
            revert NoPendingAPRChange();
        }
        delete pendingAPRChange;
        emit APRChangeCancelled();
    }

    /**
     * @notice Propose new contract references (48h timelock)
     * @dev Creates a pending change that can be executed after
     *      TIMELOCK_DELAY (48 hours). Replaces any existing pending
     *      change. Only ADMIN_ROLE can propose. This prevents
     *      instant oracle replacement attacks (H-02).
     * @param omniCoreAddr New OmniCore contract address
     * @param xomTokenAddr New XOM token address
     */
    function proposeContracts(
        address omniCoreAddr,
        address xomTokenAddr
    ) external onlyRole(ADMIN_ROLE) {
        if (omniCoreAddr == address(0)) revert ZeroAddress();
        if (xomTokenAddr == address(0)) revert ZeroAddress();

        // solhint-disable-next-line not-rely-on-time
        uint256 execAfter = block.timestamp + TIMELOCK_DELAY;

        pendingContracts = PendingContracts({
            omniCore: omniCoreAddr,
            xomToken: xomTokenAddr,
            executeAfter: execAfter
        });

        emit ContractsChangeProposed(
            omniCoreAddr, xomTokenAddr, execAfter
        );
    }

    /**
     * @notice Execute a pending contract reference change
     * @dev Can only be called after TIMELOCK_DELAY has elapsed
     *      since the proposal. Only ADMIN_ROLE can execute.
     */
    function executeContracts()
        external
        onlyRole(ADMIN_ROLE)
    {
        PendingContracts memory pending = pendingContracts;
        if (pending.executeAfter == 0) revert NoPendingChange();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.executeAfter) {
            revert TimelockNotElapsed();
        }

        omniCore = IOmniCoreStaking(pending.omniCore);
        xomToken = IERC20(pending.xomToken);

        // Clear the pending change
        delete pendingContracts;

        emit ContractsUpdated(
            pending.omniCore, pending.xomToken
        );
    }

    /**
     * @notice Cancel a pending contract reference change
     * @dev Only ADMIN_ROLE can cancel. Useful if a proposed change
     *      is discovered to be erroneous before execution.
     */
    function cancelContractsChange()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingContracts.executeAfter == 0) {
            revert NoPendingChange();
        }

        delete pendingContracts;

        emit ContractsChangeCancelled();
    }

    /// @notice Pause all pool operations (M-03)
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /// @notice Unpause pool operations (M-03)
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck tokens (not XOM)
     * @dev Only DEFAULT_ADMIN_ROLE can withdraw in emergencies.
     *      Cannot withdraw the XOM reward token to prevent pool
     *      drainage (H-01). Emits EmergencyWithdrawal event.
     * @param token Token address to withdraw (must not be XOM)
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
     * @notice Get the effective APR for a given tier and duration
     * @param tier Staking tier (1-5)
     * @param duration Lock duration in seconds
     * @return Effective APR in basis points
     */
    function getEffectiveAPR(
        uint256 tier,
        uint256 duration
    ) external view returns (uint256) {
        return _getEffectiveAPR(tier, duration);
    }

    /**
     * @notice Get pool balance available for rewards
     * @return Available XOM balance in the pool
     */
    function getPoolBalance() external view returns (uint256) {
        return xomToken.balanceOf(address(this));
    }

    // ════════════════════════════════════════════════════════════════════
    //                         PUBLIC FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate total earned rewards for a user
     * @dev Reads stake data from OmniCore and computes time-based
     *      rewards. Falls back to frozen rewards if OmniCore is
     *      unavailable or stake is inactive.
     * @param user Address to calculate rewards for
     * @return Total earned XOM (frozen + accrued from active stake)
     */
    function earned(address user) public view returns (uint256) {
        uint256 frozen = frozenRewards[user];

        // Wrap OmniCore call in try/catch for resilience (M-02)
        try omniCore.getStake(user) returns (
            IOmniCoreStaking.Stake memory stakeData
        ) {
            // If stake is inactive, only frozen rewards remain
            if (!stakeData.active || stakeData.amount == 0) {
                return frozen;
            }

            // Compute accrued rewards from active stake
            uint256 accrued = _computeAccrued(
                user, stakeData
            );
            return frozen + accrued;
        } catch {
            // OmniCore unavailable: return frozen rewards only
            return frozen;
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //                         INTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Authorize contract upgrade
     * @dev Required by UUPSUpgradeable. Restricted to
     *      DEFAULT_ADMIN_ROLE (the root admin role), not
     *      ADMIN_ROLE, because upgrades are the most privileged
     *      operation (H-05). Reverts if contract is ossified.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    )
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }

    /**
     * @notice Compute accrued rewards for an active stake
     * @dev Uses time elapsed since last claim and effective APR.
     *      Validates declared tier against actual staked amount
     *      using _clampTier() to prevent tier inflation (H-07).
     *      Guards against underflow if lockTime < duration (M-07).
     * @param user Address of the staker
     * @param stakeData Stake data from OmniCore
     * @return Accrued reward amount in XOM (18 decimals)
     */
    function _computeAccrued(
        address user,
        IOmniCoreStaking.Stake memory stakeData
    ) internal view returns (uint256) {
        // Guard against underflow on malformed stake data (M-07)
        if (stakeData.lockTime < stakeData.duration) {
            return 0;
        }

        // Stake start time = lockTime - duration
        uint256 stakeStart =
            stakeData.lockTime - stakeData.duration;

        // Determine the effective start of accrual
        uint256 accrualStart = lastClaimTime[user];
        if (accrualStart < stakeStart) {
            accrualStart = stakeStart;
        }

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < accrualStart + 1) {
            return 0;
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - accrualStart;

        // Clamp tier to prevent reward rate inflation (H-07)
        uint256 validatedTier = _clampTier(
            stakeData.amount, stakeData.tier
        );

        uint256 effectiveAPR = _getEffectiveAPR(
            validatedTier, stakeData.duration
        );

        if (effectiveAPR == 0) {
            return 0;
        }

        // accrued = (amount * effectiveAPR * elapsed)
        //         / (365 days * 10000)
        return (stakeData.amount * effectiveAPR * elapsed)
            / (SECONDS_PER_YEAR * BASIS_POINTS);
    }

    /**
     * @notice Get the effective APR for a tier and duration
     * @dev Combines base tier APR with duration bonus APR.
     *      Tiers beyond MAX_TIER are capped to MAX_TIER APR.
     * @param tier Staking tier (0-5)
     * @param duration Lock duration in seconds
     * @return Combined APR in basis points
     */
    function _getEffectiveAPR(
        uint256 tier,
        uint256 duration
    ) internal view returns (uint256) {
        uint256 baseAPR = tier < MAX_TIER + 1
            ? tierAPR[tier]
            : tierAPR[MAX_TIER];
        uint256 durationTier = _getDurationTier(duration);
        uint256 bonusAPR = durationBonusAPR[durationTier];

        return baseAPR + bonusAPR;
    }

    /**
     * @notice Determine duration tier from lock duration
     * @dev Maps continuous duration to discrete tier using
     *      range-based comparison (M-05: intentional design).
     *      Any duration >= the threshold qualifies for that
     *      tier's bonus, encouraging longer commitments:
     *      - >= TWO_YEARS (730 days): tier 3 (+3%)
     *      - >= SIX_MONTHS (180 days): tier 2 (+2%)
     *      - >= ONE_MONTH (30 days): tier 1 (+1%)
     *      - < ONE_MONTH: tier 0 (no bonus)
     *
     *      OmniCore validates that duration matches one of
     *      the four canonical values (0, 30d, 180d, 730d)
     *      at stake time, so range matching here serves as
     *      a defensive fallback.
     * @param duration Lock duration in seconds
     * @return Duration tier (0-3)
     */
    function _getDurationTier(
        uint256 duration
    ) internal pure returns (uint256) {
        if (duration > TWO_YEARS - 1) return 3;
        if (duration > SIX_MONTHS - 1) return 2;
        if (duration > ONE_MONTH - 1) return 1;
        return 0;
    }

    /**
     * @notice Validate and clamp declared tier against staked amount
     * @dev Returns the minimum of the declared tier and the tier
     *      that the staked amount actually qualifies for. Prevents
     *      users from claiming higher APR than their stake warrants.
     *
     *      Tier thresholds (per OmniBazaar tokenomics):
     *      - Tier 1: 1 - 999,999 XOM
     *      - Tier 2: 1,000,000 - 9,999,999 XOM
     *      - Tier 3: 10,000,000 - 99,999,999 XOM
     *      - Tier 4: 100,000,000 - 999,999,999 XOM
     *      - Tier 5: 1,000,000,000+ XOM
     *
     * @param amount Staked amount in XOM (18 decimals)
     * @param declaredTier Tier declared by OmniCore
     * @return Validated tier (min of declared and computed)
     */
    function _clampTier(
        uint256 amount,
        uint256 declaredTier
    ) internal pure returns (uint256) {
        uint256 computedTier;

        if (amount > 1_000_000_000e18 - 1) {
            computedTier = 5;
        } else if (amount > 100_000_000e18 - 1) {
            computedTier = 4;
        } else if (amount > 10_000_000e18 - 1) {
            computedTier = 3;
        } else if (amount > 1_000_000e18 - 1) {
            computedTier = 2;
        } else if (amount > 1e18 - 1) {
            computedTier = 1;
        } else {
            computedTier = 0;
        }

        // Return the lesser of declared and computed
        return declaredTier < computedTier
            ? declaredTier
            : computedTier;
    }

}
