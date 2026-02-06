// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
 * @title IOmniCoreStaking
 * @author OmniBazaar Team
 * @notice Interface for reading stake data from OmniCore contract
 * @dev Single source of truth for user stake information
 */
interface IOmniCoreStaking {
    /// @notice Minimal stake information
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

// ═══════════════════════════════════════════════════════════════════════════════
//                          STAKING REWARD POOL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @title StakingRewardPool
 * @author OmniBazaar Team
 * @notice Trustless on-chain staking reward pool using time-based drip pattern
 * @dev Computes rewards entirely on-chain from OmniCore stake data.
 *      No validator involvement in claims — fully trustless.
 *
 * Reward Calculation:
 * - Reads stake amount, tier, and duration from OmniCore.getStake()
 * - APR determined by staking tier (5-9%) + duration bonus (0-3%)
 * - Rewards accrue per-second: (amount * effectiveAPR * elapsed) / (365 days * 10000)
 * - Users call claimRewards() directly to collect accrued XOM
 *
 * Pool Funding:
 * - Anyone can call depositToPool() to fund the reward pool
 * - Validators deposit block reward share and fee allocations
 *
 * Safety:
 * - snapshotRewards() freezes accrued rewards before unlock
 * - frozenRewards persist even after stake becomes inactive
 * - UUPS upgradeable with AccessControl for admin operations
 *
 * @dev max-states-count disabled: Need multiple states for comprehensive reward tracking
 * @dev ordering disabled: Upgradeable contracts follow specific ordering pattern
 */
// solhint-disable max-states-count, ordering
contract StakingRewardPool is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Total basis points for percentage calculations (100% = 10000)
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

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice OmniCore contract for reading stake data
    IOmniCoreStaking public omniCore;

    /// @notice XOM token contract
    IERC20 public xomToken;

    /// @notice Per-user last claim timestamp
    mapping(address => uint256) public lastClaimTime;

    /// @notice Per-user frozen rewards (snapshot before unlock)
    mapping(address => uint256) public frozenRewards;

    /// @notice APR in basis points per staking tier [0]=unused, [1]-[5]=active
    /// @dev Index 0 is unused (tier 0 has no stake), tiers 1-5 map to indices 1-5
    uint256[6] public tierAPR;

    /// @notice Duration bonus APR in basis points [0]=none, [1]=1mo, [2]=6mo, [3]=2yr
    uint256[4] public durationBonusAPR;

    /// @notice Total XOM deposited into the reward pool
    uint256 public totalDeposited;

    /// @notice Total XOM distributed from the reward pool
    uint256 public totalDistributed;

    /// @notice Storage gap for future upgrades
    uint256[44] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

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
    /// @param omniCore New OmniCore address
    /// @param xomToken New XOM token address
    event ContractsUpdated(
        address indexed omniCore,
        address indexed xomToken
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor that disables initializers for the implementation contract
     * @dev Prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the StakingRewardPool contract
     * @dev Sets up APR tiers per OmniBazaar tokenomics
     * @param omniCoreAddr Address of OmniCore contract
     * @param xomTokenAddr Address of XOM token contract
     */
    function initialize(
        address omniCoreAddr,
        address xomTokenAddr
    ) public initializer {
        if (omniCoreAddr == address(0)) revert ZeroAddress();
        if (xomTokenAddr == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        omniCore = IOmniCoreStaking(omniCoreAddr);
        xomToken = IERC20(xomTokenAddr);

        // Base APR per staking tier (basis points)
        // Tier 0: unused (no stake), Tier 1-5: 5-9%
        tierAPR[0] = 0;
        tierAPR[1] = 500;   // 5%
        tierAPR[2] = 600;   // 6%
        tierAPR[3] = 700;   // 7%
        tierAPR[4] = 800;   // 8%
        tierAPR[5] = 900;   // 9%

        // Duration bonus APR (basis points)
        // Tier 0: none, Tier 1: +1%, Tier 2: +2%, Tier 3: +3%
        durationBonusAPR[0] = 0;
        durationBonusAPR[1] = 100;  // +1%
        durationBonusAPR[2] = 200;  // +2%
        durationBonusAPR[3] = 300;  // +3%
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         REWARD CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate total earned rewards for a user
     * @dev Reads stake data from OmniCore and computes time-based rewards
     * @param user Address to calculate rewards for
     * @return Total earned XOM (frozen + accrued from active stake)
     */
    function earned(address user) public view returns (uint256) {
        uint256 frozen = frozenRewards[user];

        IOmniCoreStaking.Stake memory stakeData = omniCore.getStake(user);

        // If stake is inactive, only frozen rewards remain
        if (!stakeData.active || stakeData.amount == 0) {
            return frozen;
        }

        // Compute accrued rewards from active stake
        uint256 accrued = _computeAccrued(user, stakeData);

        return frozen + accrued;
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

    // ═══════════════════════════════════════════════════════════════════════
    //                         USER ACTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim all accrued staking rewards
     * @dev Transfers earned XOM directly to caller. Reverts if zero or underfunded.
     */
    function claimRewards() external nonReentrant {
        uint256 reward = earned(msg.sender);
        if (reward == 0) revert NoRewardsToClaim();

        uint256 poolBalance = xomToken.balanceOf(address(this));
        if (poolBalance < reward) revert PoolUnderfunded();

        // Update state before transfer (CEI pattern)
        // solhint-disable-next-line not-rely-on-time
        lastClaimTime[msg.sender] = block.timestamp;
        frozenRewards[msg.sender] = 0;
        totalDistributed += reward;

        // Transfer rewards to caller
        xomToken.safeTransfer(msg.sender, reward);

        // solhint-disable-next-line not-rely-on-time
        emit RewardsClaimed(msg.sender, reward, block.timestamp);
    }

    /**
     * @notice Snapshot and freeze accrued rewards before unlock
     * @dev Should be called BEFORE OmniCore.unlock() to preserve rewards.
     *      If stake is already inactive, this is a no-op.
     * @param user Address to snapshot rewards for
     */
    function snapshotRewards(address user) external {
        IOmniCoreStaking.Stake memory stakeData = omniCore.getStake(user);

        // Only snapshot if stake is still active
        if (!stakeData.active || stakeData.amount == 0) {
            return;
        }

        uint256 accrued = _computeAccrued(user, stakeData);

        if (accrued > 0) {
            frozenRewards[user] += accrued;
            // solhint-disable-next-line not-rely-on-time
            lastClaimTime[user] = block.timestamp;

            // solhint-disable-next-line not-rely-on-time
            emit RewardsSnapshot(user, accrued, block.timestamp);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         POOL FUNDING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit XOM to fund the reward pool
     * @dev Anyone can deposit — validators deposit block reward share and fees
     * @param amount Amount of XOM to deposit
     */
    function depositToPool(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        xomToken.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;

        emit PoolDeposit(msg.sender, amount, totalDeposited);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update APR for a staking tier
     * @dev Only ADMIN_ROLE can modify APR rates
     * @param tier Tier index (1-5)
     * @param apr New APR in basis points (e.g., 500 = 5%)
     */
    function setTierAPR(
        uint256 tier,
        uint256 apr
    ) external onlyRole(ADMIN_ROLE) {
        if (tier == 0 || tier > MAX_TIER) revert InvalidTier();
        tierAPR[tier] = apr;
        emit TierAPRUpdated(tier, apr);
    }

    /**
     * @notice Update duration bonus APR
     * @dev Only ADMIN_ROLE can modify bonus rates
     * @param tier Duration tier index (0-3)
     * @param apr New bonus APR in basis points (e.g., 100 = 1%)
     */
    function setDurationBonusAPR(
        uint256 tier,
        uint256 apr
    ) external onlyRole(ADMIN_ROLE) {
        if (tier > MAX_DURATION_TIER) revert InvalidTier();
        durationBonusAPR[tier] = apr;
        emit DurationBonusAPRUpdated(tier, apr);
    }

    /**
     * @notice Update contract references
     * @dev Only ADMIN_ROLE can update contract addresses
     * @param omniCoreAddr New OmniCore contract address
     * @param xomTokenAddr New XOM token address
     */
    function setContracts(
        address omniCoreAddr,
        address xomTokenAddr
    ) external onlyRole(ADMIN_ROLE) {
        if (omniCoreAddr == address(0)) revert ZeroAddress();
        if (xomTokenAddr == address(0)) revert ZeroAddress();

        omniCore = IOmniCoreStaking(omniCoreAddr);
        xomToken = IERC20(xomTokenAddr);

        emit ContractsUpdated(omniCoreAddr, xomTokenAddr);
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @dev Only DEFAULT_ADMIN_ROLE can withdraw in emergencies
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
    //                         INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Compute accrued rewards for an active stake
     * @dev Uses time elapsed since last claim and effective APR
     * @param user Address of the staker
     * @param stakeData Stake data from OmniCore
     * @return Accrued reward amount in XOM (18 decimals)
     */
    function _computeAccrued(
        address user,
        IOmniCoreStaking.Stake memory stakeData
    ) internal view returns (uint256) {
        // Stake start time = lockTime - duration
        uint256 stakeStart = stakeData.lockTime - stakeData.duration;

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
        uint256 effectiveAPR = _getEffectiveAPR(stakeData.tier, stakeData.duration);

        if (effectiveAPR == 0) {
            return 0;
        }

        // accrued = (amount * effectiveAPR * elapsed) / (365 days * 10000)
        return (stakeData.amount * effectiveAPR * elapsed)
            / (SECONDS_PER_YEAR * BASIS_POINTS);
    }

    /**
     * @notice Get the effective APR for a tier and duration combination
     * @param tier Staking tier (0-5)
     * @param duration Lock duration in seconds
     * @return Combined APR in basis points
     */
    function _getEffectiveAPR(
        uint256 tier,
        uint256 duration
    ) internal view returns (uint256) {
        uint256 baseAPR = tier < MAX_TIER + 1 ? tierAPR[tier] : tierAPR[MAX_TIER];
        uint256 durationTier = _getDurationTier(duration);
        uint256 bonusAPR = durationBonusAPR[durationTier];

        return baseAPR + bonusAPR;
    }

    /**
     * @notice Determine duration tier from lock duration in seconds
     * @param duration Lock duration in seconds
     * @return Duration tier (0-3)
     */
    function _getDurationTier(uint256 duration) internal pure returns (uint256) {
        if (duration > TWO_YEARS - 1) return 3;
        if (duration > SIX_MONTHS - 1) return 2;
        if (duration > ONE_MONTH - 1) return 1;
        return 0;
    }

    /**
     * @notice Authorize contract upgrade
     * @dev Required by UUPSUpgradeable, only admin can upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ADMIN_ROLE) {} // solhint-disable-line no-empty-blocks
}
