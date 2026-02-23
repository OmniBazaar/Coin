// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IOmniRegistration} from "./interfaces/IOmniRegistration.sol";

/**
 * @title OmniRewardManager
 * @author OmniCoin Development Team
 * @notice Unified manager for all pre-minted reward pools in OmniCoin ecosystem
 * @dev Manages Welcome Bonus, Referral Bonus, First Sale Bonus, and Validator Rewards pools.
 *      All pools are pre-minted at genesis - distribution is by transfer, not minting.
 *      This design eliminates infinite mint attack vectors and provides transparent,
 *      on-chain verifiable pool balances.
 *
 *      Historical Context:
 *      - Original total supply: 25 billion XOM
 *      - Burned in 2019: 8.4 billion XOM
 *      - Effective supply: ~16.6 billion XOM
 *
 *      Pool Allocations (Production):
 *      - Welcome Bonus: 1,383,457,500 XOM
 *      - Referral Bonus: 2,995,000,000 XOM
 *      - First Sale Bonus: 2,000,000,000 XOM
 *      - Validator Rewards: 6,089,000,000 XOM (40-year emission)
 */
contract OmniRewardManager is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    // ============ Type Declarations ============

    /// @notice Types of bonus pools for merkle root management
    enum PoolType {
        WelcomeBonus,
        ReferralBonus,
        FirstSaleBonus,
        ValidatorRewards
    }

    /// @notice State for each reward pool (reduces individual state variables)
    struct PoolState {
        uint256 initial;
        uint256 remaining;
        uint256 distributed;
        bytes32 merkleRoot;
    }

    /// @notice Parameters for referral bonus distribution
    struct ReferralParams {
        address referrer;
        address secondLevelReferrer;
        uint256 primaryAmount;
        uint256 secondaryAmount;
    }

    /// @notice Parameters for validator reward distribution
    struct ValidatorRewardParams {
        address validator;
        uint256 validatorAmount;
        address stakingPool;
        uint256 stakingAmount;
        address oddao;
        uint256 oddaoAmount;
    }

    // ============ Constants ============

    /// @notice Original total supply before 2019 burn (for historical documentation)
    uint256 public constant ORIGINAL_TOTAL_SUPPLY = 25_000_000_000 * 10 ** 18;

    /// @notice Amount burned in 2019 community event (not minted in new contract)
    uint256 public constant HISTORICAL_BURN_2019 = 8_400_000_000 * 10 ** 18;

    /// @notice Effective total supply (actual tokens that will exist)
    uint256 public constant EFFECTIVE_TOTAL_SUPPLY = 16_600_000_000 * 10 ** 18;

    /// @notice Role for distributing user bonuses (welcome, referral, first sale)
    bytes32 public constant BONUS_DISTRIBUTOR_ROLE = keccak256("BONUS_DISTRIBUTOR_ROLE");

    /// @notice Role for distributing validator rewards (called by OmniCore/scheduler)
    bytes32 public constant VALIDATOR_REWARD_ROLE = keccak256("VALIDATOR_REWARD_ROLE");

    /// @notice Role for upgrading the contract implementation
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Role for pausing the contract in emergencies
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Low pool warning threshold (1% of initial allocation)
    uint256 public constant LOW_POOL_THRESHOLD_BPS = 100;

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum welcome bonuses per day (rate limiting for Sybil protection)
    uint256 public constant MAX_DAILY_WELCOME_BONUSES = 1000;

    /// @notice Maximum referral bonuses per day (rate limiting for Sybil protection)
    uint256 public constant MAX_DAILY_REFERRAL_BONUSES = 2000;

    /// @notice Maximum first sale bonuses per day (rate limiting)
    uint256 public constant MAX_DAILY_FIRST_SALE_BONUSES = 500;

    /// @notice EIP-712 typehash for trustless welcome bonus claim
    /// @dev ClaimWelcomeBonus(address user,uint256 nonce,uint256 deadline)
    bytes32 public constant CLAIM_WELCOME_BONUS_TYPEHASH = keccak256(
        "ClaimWelcomeBonus(address user,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for trustless referral bonus claim
    /// @dev ClaimReferralBonus(address user,uint256 nonce,uint256 deadline)
    bytes32 public constant CLAIM_REFERRAL_BONUS_TYPEHASH = keccak256(
        "ClaimReferralBonus(address user,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for trustless first sale bonus claim
    /// @dev ClaimFirstSaleBonus(address user,uint256 nonce,uint256 deadline)
    bytes32 public constant CLAIM_FIRST_SALE_BONUS_TYPEHASH = keccak256(
        "ClaimFirstSaleBonus(address user,uint256 nonce,uint256 deadline)"
    );

    // ============ State Variables ============

    /// @notice Reference to the OmniCoin ERC20 token
    IERC20 public omniCoin;

    /// @notice Welcome bonus pool state
    PoolState public welcomeBonusPool;

    /// @notice Referral bonus pool state
    PoolState public referralBonusPool;

    /// @notice First sale bonus pool state
    PoolState public firstSaleBonusPool;

    /// @notice Validator rewards pool state
    PoolState public validatorRewardsPool;

    /// @notice Tracks whether a user has claimed their welcome bonus
    mapping(address => bool) public welcomeBonusClaimed;

    /// @notice Tracks whether a user has claimed their first sale bonus
    mapping(address => bool) public firstSaleBonusClaimed;

    /// @notice Tracks total referral bonuses claimed by each referrer
    mapping(address => uint256) public referralBonusesEarned;

    /// @notice Current virtual block height for validator reward tracking
    uint256 public currentVirtualBlockHeight;

    /// @notice Reference to OmniRegistration contract for secure bonus claiming
    IOmniRegistration public registrationContract;

    /// @notice Daily welcome bonus count for rate limiting (day => count)
    mapping(uint256 => uint256) public dailyWelcomeBonusCount;

    /// @notice Daily referral bonus count for rate limiting (day => count)
    mapping(uint256 => uint256) public dailyReferralBonusCount;

    /// @notice Daily first sale bonus count for rate limiting (day => count)
    mapping(uint256 => uint256) public dailyFirstSaleBonusCount;

    /// @notice Claim nonces for replay protection (user => nonce)
    mapping(address => uint256) public claimNonces;

    /// @notice ODDAO address for referral fee distribution
    address public oddaoAddress;

    /// @notice Count of legacy users who already claimed the welcome bonus
    /// @dev Added to on-chain welcomeBonusClaimCount when calculating bonus tier.
    ///      Set to the number of legacy users (~3996) who got bonuses in old OmniBazaar.
    ///      Effective claim count = welcomeBonusClaimCount + legacyBonusClaimsCount
    uint256 public legacyBonusClaimsCount;

    /// @notice Count of welcome bonuses claimed on-chain (excluding legacy)
    /// @dev Incremented each time a welcome bonus is claimed. Used for tier calculation.
    ///      This is separate from registration count since not all users claim bonuses.
    uint256 public welcomeBonusClaimCount;

    /// @notice Pending referral bonuses ready to claim (user => amount in wei)
    /// @dev Accumulated when referees claim welcome bonus. User must manually claim.
    ///      This prevents validators from controlling bonus distribution.
    mapping(address => uint256) public pendingReferralBonuses;

    /// @notice Pending registration contract address (M-03 timelock)
    address public pendingRegistrationContract;

    /// @notice Timestamp when pending registration contract can be applied (M-03)
    uint256 public registrationContractTimelockEnd;

    /// @notice Maximum legacy bonus claims count (M-06: prevents overflow/manipulation)
    uint256 public constant MAX_LEGACY_CLAIMS_COUNT = 10_000_000;

    /// @notice Registration contract change timelock delay (M-03: 48 hours)
    uint256 public constant REGISTRATION_TIMELOCK_DELAY = 48 hours;

    /// @notice Daily auto-referral count, separate from manual claims (M-05)
    mapping(uint256 => uint256) public dailyAutoReferralCount;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @dev Reserved storage gap for future upgrades (reduced by 1 for _ossified)
    uint256[30] private __gap;

    // ============ Events ============

    /// @notice Emitted when a user claims their welcome bonus
    /// @param user Address of the bonus recipient
    /// @param amount Amount of XOM transferred
    /// @param remainingPool Remaining balance in welcome bonus pool
    event WelcomeBonusClaimed(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed remainingPool
    );

    /// @notice Emitted when referral bonuses are distributed (two-level)
    /// @param referrer Primary referrer receiving 70% of referral fee
    /// @param secondLevelReferrer Secondary referrer receiving 20% of referral fee
    /// @param totalAmount Combined amount sent to both referrers
    event ReferralBonusClaimed(
        address indexed referrer,
        address indexed secondLevelReferrer,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when a seller claims their first sale bonus
    /// @param seller Address of the bonus recipient
    /// @param amount Amount of XOM transferred
    /// @param remainingPool Remaining balance in first sale bonus pool
    event FirstSaleBonusClaimed(
        address indexed seller,
        uint256 indexed amount,
        uint256 indexed remainingPool
    );

    /// @notice Emitted when validator rewards are distributed (every 2 seconds)
    /// @param virtualBlockHeight Virtual block height for this distribution
    /// @param validator Address of the selected validator
    /// @param totalAmount Combined amount distributed (validator + staking + oddao)
    event ValidatorRewardDistributed(
        uint256 indexed virtualBlockHeight,
        address indexed validator,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when a pool balance drops below warning threshold
    /// @param poolType Type of pool that is running low
    /// @param remainingAmount Current remaining balance
    /// @param threshold Warning threshold that was crossed
    event PoolLowWarning(
        PoolType indexed poolType,
        uint256 indexed remainingAmount,
        uint256 indexed threshold
    );

    /// @notice Emitted when a merkle root is updated for a pool
    /// @param poolType Type of pool whose merkle root was updated
    /// @param oldRoot Previous merkle root
    /// @param newRoot New merkle root
    event MerkleRootUpdated(
        PoolType indexed poolType,
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot
    );

    /// @notice Emitted when the contract is initialized
    /// @param omniCoinAddr Address of the OmniCoin token
    /// @param totalPoolSize Total tokens allocated across all pools
    /// @param adminAddr Address that received admin roles
    event ContractInitialized(
        address indexed omniCoinAddr,
        uint256 indexed totalPoolSize,
        address indexed adminAddr
    );

    /// @notice Emitted when registration contract is set
    /// @param registrationContract Address of the registration contract
    event RegistrationContractSet(address indexed registrationContract);

    /// @notice Emitted when registration contract change is queued (M-03)
    /// @param newContract Address of the proposed new registration contract
    /// @param effectiveTime Timestamp when the change can be applied
    event RegistrationContractChangeQueued(
        address indexed newContract,
        uint256 indexed effectiveTime
    );

    /// @notice Emitted when ODDAO address is set
    /// @param oddaoAddress Address of the ODDAO
    event OddaoAddressSet(address indexed oddaoAddress);

    /// @notice Emitted when permissionless welcome bonus is claimed
    /// @param user User who claimed
    /// @param amount Amount claimed
    /// @param referrer Referrer who will receive bonus (if any)
    event PermissionlessWelcomeBonusClaimed(
        address indexed user,
        uint256 indexed amount,
        address indexed referrer
    );

    /// @notice Emitted when auto-referral bonus is distributed
    /// @param referrer Primary referrer
    /// @param secondLevelReferrer Second level referrer (if any)
    /// @param referrerAmount Amount to primary referrer
    /// @param secondLevelAmount Amount to second level referrer
    event AutoReferralBonusDistributed(
        address indexed referrer,
        address indexed secondLevelReferrer,
        uint256 referrerAmount,
        uint256 secondLevelAmount
    );

    /// @notice Emitted when legacy bonus claims count is updated
    /// @param oldCount Previous count value
    /// @param newCount New count value
    /// @param effectiveRegistrations Effective registration count (on-chain + legacy)
    event LegacyBonusClaimsCountUpdated(
        uint256 indexed oldCount,
        uint256 indexed newCount,
        uint256 effectiveRegistrations
    );

    /// @notice Emitted when trustless welcome bonus is claimed (requires KYC Tier 1)
    /// @param user User who claimed via trustless verification
    /// @param amount Amount claimed
    /// @param referrer Referrer who will receive bonus (if any)
    event TrustlessWelcomeBonusClaimed(
        address indexed user,
        uint256 indexed amount,
        address indexed referrer
    );

    /// @notice Emitted when welcome bonus is claimed via trustless relay
    /// @param user User who received the bonus
    /// @param amount Amount of XOM transferred
    /// @param relayer Address that submitted the transaction (paid gas)
    /// @param referrer Referrer who will receive referral bonus (if any)
    event WelcomeBonusClaimedRelayed(
        address indexed user,
        uint256 indexed amount,
        address relayer,
        address referrer
    );

    /// @notice Emitted when referral bonus is accumulated (not transferred yet)
    /// @param referrer Primary referrer who will receive 70%
    /// @param secondLevelReferrer Secondary referrer who will receive 20%
    /// @param referrerAmount Amount accumulated for primary referrer
    /// @param secondLevelAmount Amount accumulated for second-level referrer
    /// @param referee User whose welcome bonus triggered this accumulation
    event ReferralBonusAccumulated(
        address indexed referrer,
        address indexed secondLevelReferrer,
        uint256 referrerAmount,
        uint256 secondLevelAmount,
        address referee
    );

    /// @notice Emitted when referrer claims their accumulated bonus
    /// @param referrer Address who claimed the bonus
    /// @param amount Amount transferred to referrer
    event ReferralBonusClaimedPermissionless(
        address indexed referrer,
        uint256 indexed amount
    );

    /// @notice Emitted when referral bonus is claimed via relay (gasless)
    /// @param referrer Address who received the bonus
    /// @param amount Amount transferred
    /// @param relayer Address that paid gas and submitted transaction
    event ReferralBonusClaimedRelayed(
        address indexed referrer,
        uint256 indexed amount,
        address relayer
    );

    /// @notice Emitted when admin migrates pending referral bonus from database
    /// @param referrer Address whose pending bonus was set
    /// @param oldAmount Previous pending amount
    /// @param newAmount New pending amount
    event ReferralBonusMigrated(
        address indexed referrer,
        uint256 oldAmount,
        uint256 newAmount
    );

    /// @notice Emitted when first sale bonus is claimed via relay (gasless)
    /// @param seller Address who received the bonus
    /// @param amount Amount transferred
    /// @param relayer Address that paid gas and submitted transaction
    event FirstSaleBonusClaimedRelayed(
        address indexed seller,
        uint256 indexed amount,
        address relayer
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ============ Custom Errors ============

    /// @notice Thrown when pool has insufficient funds for distribution
    error InsufficientPoolBalance(PoolType poolType, uint256 requested, uint256 available);

    /// @notice Thrown when user has already claimed a one-time bonus
    error BonusAlreadyClaimed(address user, PoolType bonusType);

    /// @notice Thrown when merkle proof verification fails
    error InvalidMerkleProof(address user, PoolType poolType);

    /// @notice Thrown when zero address is provided
    error ZeroAddressNotAllowed();

    /// @notice Thrown when zero amount is provided
    error ZeroAmountNotAllowed();

    /// @notice Thrown when invalid pool type is provided for merkle root update
    error InvalidPoolTypeForMerkle();

    /// @notice Thrown when daily bonus rate limit is exceeded
    error DailyBonusLimitExceeded(PoolType poolType, uint256 limit);

    /// @notice Thrown when registration contract is not set
    error RegistrationContractNotSet();

    /// @notice Thrown when user is not registered
    error UserNotRegistered(address user);

    /// @notice Thrown when user tries to claim first sale bonus without completing a sale
    /// @param user The user who has not completed a sale
    error FirstSaleNotCompleted(address user);

    /// @notice Thrown when ODDAO address is not set
    error OddaoAddressNotSet();

    /// @notice Thrown when user has not completed KYC Tier 1 (phone + social verified on-chain)
    error KycTier1Required(address user);

    /// @notice Thrown when claim deadline has expired
    error ClaimDeadlineExpired();

    /// @notice Thrown when claim nonce doesn't match expected
    /// @param user User address
    /// @param provided Provided nonce
    /// @param expected Expected nonce
    error InvalidClaimNonce(address user, uint256 provided, uint256 expected);

    /// @notice Thrown when recovered signer doesn't match user
    /// @param expectedUser Expected user address
    /// @param recoveredSigner Recovered signer from signature
    error InvalidUserSignature(address expectedUser, address recoveredSigner);

    /// @notice Thrown when user tries to claim but has no pending referral bonus
    /// @param user User address
    error NoPendingReferralBonus(address user);

    /// @notice Thrown when contract token balance is insufficient for declared pools (M-02)
    /// @param required Total pool allocation declared
    /// @param actual Actual token balance held by contract
    error InsufficientInitialBalance(uint256 required, uint256 actual);

    /// @notice Thrown when legacy bonus claims count exceeds maximum (M-06)
    /// @param provided The count that was provided
    /// @param maximum The maximum allowed count
    error LegacyClaimsCountTooHigh(uint256 provided, uint256 maximum);

    /// @notice Thrown when registration contract timelock has not elapsed (M-03)
    error RegistrationTimelockActive();

    /// @notice Thrown when no pending registration contract change exists (M-03)
    error NoPendingRegistrationChange();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    // ============ Constructor ============

    /**
     * @notice Disables initializers for the implementation contract
     * @dev Required for UUPS proxy pattern security
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the OmniRewardManager with pool allocations
     * @dev Must be called immediately after proxy deployment. Caller must have
     *      already transferred the total pool amount to this contract.
     * @param _omniCoin Address of the OmniCoin ERC20 token
     * @param _welcomeBonusPool Initial size of welcome bonus pool
     * @param _referralBonusPool Initial size of referral bonus pool
     * @param _firstSaleBonusPool Initial size of first sale bonus pool
     * @param _validatorRewardsPool Initial size of validator rewards pool
     * @param _admin Address to receive all admin roles
     */
    function initialize(
        address _omniCoin,
        uint256 _welcomeBonusPool,
        uint256 _referralBonusPool,
        uint256 _firstSaleBonusPool,
        uint256 _validatorRewardsPool,
        address _admin
    ) external initializer {
        _validateInitParams(_omniCoin, _admin);

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("OmniRewardManager", "1");

        omniCoin = IERC20(_omniCoin);

        // M-02: Verify contract holds enough tokens for all declared pools
        uint256 totalPool = _welcomeBonusPool + _referralBonusPool +
            _firstSaleBonusPool + _validatorRewardsPool;
        uint256 actualBalance = IERC20(_omniCoin).balanceOf(address(this));
        if (actualBalance < totalPool) {
            revert InsufficientInitialBalance(totalPool, actualBalance);
        }

        _initializePool(welcomeBonusPool, _welcomeBonusPool);
        _initializePool(referralBonusPool, _referralBonusPool);
        _initializePool(firstSaleBonusPool, _firstSaleBonusPool);
        _initializePool(validatorRewardsPool, _validatorRewardsPool);

        _setupRoles(_admin);

        emit ContractInitialized(_omniCoin, totalPool, _admin);
    }

    /**
     * @notice Reinitialize the contract for V2 (adds EIP-712 support)
     * @dev Call this after upgrading from V1 to enable trustless relay claims.
     *      This function can only be called once (reinitializer(2)).
     *      Restricted to DEFAULT_ADMIN_ROLE to prevent unauthorized reinitialization.
     *      While reinitializer(2) already prevents repeated calls, the access control
     *      ensures only the admin multisig can trigger the upgrade initialization.
     */
    function reinitializeV2() external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(2) {
        __EIP712_init("OmniRewardManager", "1");
    }

    // ============ External Functions - Bonus Distribution ============

    /**
     * @notice Claim welcome bonus for a user with merkle proof verification
     * @dev Only callable by BONUS_DISTRIBUTOR_ROLE. Each user can only claim once.
     * @param user Address of the user receiving the bonus
     * @param amount Amount of XOM to transfer
     * @param merkleProof Merkle proof verifying user eligibility
     */
    function claimWelcomeBonus(
        address user,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external onlyRole(BONUS_DISTRIBUTOR_ROLE) nonReentrant whenNotPaused {
        _validateClaimParams(user, amount);
        _validateNotClaimed(welcomeBonusClaimed[user], user, PoolType.WelcomeBonus);
        _validatePoolBalance(welcomeBonusPool, PoolType.WelcomeBonus, amount);
        _verifyMerkleProof(
            welcomeBonusPool.merkleRoot, user, amount, merkleProof, PoolType.WelcomeBonus
        );

        welcomeBonusClaimed[user] = true;
        _updatePoolAfterDistribution(welcomeBonusPool, amount);

        omniCoin.safeTransfer(user, amount);

        emit WelcomeBonusClaimed(user, amount, welcomeBonusPool.remaining);
        _checkPoolThreshold(PoolType.WelcomeBonus, welcomeBonusPool);
    }

    /**
     * @notice Claim referral bonus for referrer and optional second-level referrer
     * @dev Only callable by BONUS_DISTRIBUTOR_ROLE. Referrers can earn multiple times.
     * @param params Struct containing referral distribution parameters
     * @param merkleProof Merkle proof verifying referral relationship
     */
    function claimReferralBonus(
        ReferralParams calldata params,
        bytes32[] calldata merkleProof
    ) external onlyRole(BONUS_DISTRIBUTOR_ROLE) nonReentrant whenNotPaused {
        uint256 referrerTotal = params.primaryAmount + params.secondaryAmount;
        _validateReferralParams(params.referrer, referrerTotal);

        // Calculate ODDAO share for full pool accounting
        uint256 oddaoShare;
        if (params.secondaryAmount != 0 && params.secondLevelReferrer != address(0)) {
            oddaoShare = (referrerTotal * 10) / 90;
        } else {
            oddaoShare = (params.primaryAmount * 30) / 70;
        }
        uint256 totalWithOddao = referrerTotal + oddaoShare;

        _validatePoolBalance(referralBonusPool, PoolType.ReferralBonus, totalWithOddao);
        _verifyReferralMerkleProof(params, merkleProof);

        _updatePoolAfterDistribution(referralBonusPool, totalWithOddao);
        _distributeReferralRewards(params);

        emit ReferralBonusClaimed(params.referrer, params.secondLevelReferrer, totalWithOddao);
        _checkPoolThreshold(PoolType.ReferralBonus, referralBonusPool);
    }

    /**
     * @notice Claim first sale bonus for a seller
     * @dev Only callable by BONUS_DISTRIBUTOR_ROLE. Each seller can only claim once.
     * @param seller Address of the seller receiving the bonus
     * @param amount Amount of XOM to transfer
     * @param merkleProof Merkle proof verifying first sale completion
     */
    function claimFirstSaleBonus(
        address seller,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external onlyRole(BONUS_DISTRIBUTOR_ROLE) nonReentrant whenNotPaused {
        _validateClaimParams(seller, amount);
        _validateNotClaimed(firstSaleBonusClaimed[seller], seller, PoolType.FirstSaleBonus);
        _validatePoolBalance(firstSaleBonusPool, PoolType.FirstSaleBonus, amount);
        _verifyMerkleProof(
            firstSaleBonusPool.merkleRoot, seller, amount, merkleProof, PoolType.FirstSaleBonus
        );

        firstSaleBonusClaimed[seller] = true;
        _updatePoolAfterDistribution(firstSaleBonusPool, amount);

        omniCoin.safeTransfer(seller, amount);

        emit FirstSaleBonusClaimed(seller, amount, firstSaleBonusPool.remaining);
        _checkPoolThreshold(PoolType.FirstSaleBonus, firstSaleBonusPool);
    }

    // ============ External Functions - Validator Rewards ============

    /**
     * @notice Distribute validator reward for a virtual block
     * @dev Called every 2 seconds by VirtualRewardScheduler via OmniCore.
     *      Splits reward between validator, staking pool, and ODDAO.
     * @param params Struct containing validator reward distribution parameters
     */
    function distributeValidatorReward(
        ValidatorRewardParams calldata params
    ) external onlyRole(VALIDATOR_REWARD_ROLE) nonReentrant whenNotPaused {
        uint256 totalAmount = params.validatorAmount + params.stakingAmount + params.oddaoAmount;
        _validateValidatorParams(params, totalAmount);
        _validatePoolBalance(validatorRewardsPool, PoolType.ValidatorRewards, totalAmount);

        ++currentVirtualBlockHeight;
        _updatePoolAfterDistribution(validatorRewardsPool, totalAmount);
        _distributeValidatorRewards(params);

        emit ValidatorRewardDistributed(currentVirtualBlockHeight, params.validator, totalAmount);
        _checkPoolThreshold(PoolType.ValidatorRewards, validatorRewardsPool);
    }

    // ============ External Functions - Admin ============

    /**
     * @notice Update merkle root for a bonus pool
     * @dev Only callable by BONUS_DISTRIBUTOR_ROLE
     * @param poolType Type of pool to update
     * @param newRoot New merkle root
     */
    function updateMerkleRoot(
        PoolType poolType,
        bytes32 newRoot
    ) external onlyRole(BONUS_DISTRIBUTOR_ROLE) {
        bytes32 oldRoot = _getMerkleRoot(poolType);
        _setMerkleRoot(poolType, newRoot);
        emit MerkleRootUpdated(poolType, oldRoot, newRoot);
    }

    /**
     * @notice Pause all distribution functions
     * @dev Only callable by PAUSER_ROLE. Use in emergencies.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause distribution functions
     * @dev Only callable by PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Queue a registration contract change (M-03: 48-hour timelock)
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Change takes effect after delay.
     *      If no registration contract is set yet (initial setup), applies immediately.
     * @param _registrationContract Address of the new OmniRegistration contract
     */
    function setRegistrationContract(
        address _registrationContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_registrationContract == address(0)) revert ZeroAddressNotAllowed();

        // First-time setup: apply immediately (no timelock needed)
        if (address(registrationContract) == address(0)) {
            registrationContract = IOmniRegistration(_registrationContract);
            emit RegistrationContractSet(_registrationContract);
            return;
        }

        // M-03: Subsequent changes require 48-hour timelock
        pendingRegistrationContract = _registrationContract;
        // solhint-disable-next-line not-rely-on-time
        registrationContractTimelockEnd = block.timestamp + REGISTRATION_TIMELOCK_DELAY;

        // solhint-disable-next-line not-rely-on-time
        emit RegistrationContractChangeQueued(_registrationContract, registrationContractTimelockEnd);
    }

    /**
     * @notice Apply a queued registration contract change after timelock expires
     * @dev Only callable by DEFAULT_ADMIN_ROLE after the timelock period.
     */
    function applyRegistrationContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingRegistrationContract == address(0)) revert NoPendingRegistrationChange();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < registrationContractTimelockEnd) revert RegistrationTimelockActive();

        registrationContract = IOmniRegistration(pendingRegistrationContract);
        emit RegistrationContractSet(pendingRegistrationContract);

        // Clear pending state
        pendingRegistrationContract = address(0);
        registrationContractTimelockEnd = 0;
    }

    /**
     * @notice Set the ODDAO address for referral fee distribution
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param _oddaoAddress Address of the ODDAO
     */
    function setOddaoAddress(
        address _oddaoAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oddaoAddress == address(0)) revert ZeroAddressNotAllowed();
        oddaoAddress = _oddaoAddress;
        emit OddaoAddressSet(_oddaoAddress);
    }

    /**
     * @notice Set the legacy bonus claims count for bonus tier calculation
     * @dev Only callable by DEFAULT_ADMIN_ROLE. This count is ADDED to
     *      on-chain totalRegistrations when calculating which bonus tier a user falls into.
     *
     *      Use case: Legacy OmniBazaar had ~3,996 users who claimed the welcome bonus.
     *      These users are not on-chain but should be counted for tier calculation.
     *      New users should start at position ~3,997 (Tier 2: 5,000 XOM).
     *
     *      Example: If on-chain totalRegistrations = 10 and legacyClaims = 3,996
     *               Effective position = 10 + 3,996 = 4,006 (tier 2: 5,000 XOM)
     *
     * @param _count The count of legacy users who already claimed bonuses
     */
    function setLegacyBonusClaimsCount(
        uint256 _count
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // M-06: Prevent manipulation by enforcing upper bound
        if (_count > MAX_LEGACY_CLAIMS_COUNT) {
            revert LegacyClaimsCountTooHigh(_count, MAX_LEGACY_CLAIMS_COUNT);
        }

        uint256 oldCount = legacyBonusClaimsCount;
        legacyBonusClaimsCount = _count;

        // Calculate effective registrations for the event
        uint256 effectiveRegs = _count;
        if (address(registrationContract) != address(0)) {
            uint256 totalRegs = registrationContract.totalRegistrations();
            effectiveRegs = totalRegs + _count;
        }

        emit LegacyBonusClaimsCountUpdated(oldCount, _count, effectiveRegs);
    }

    /**
     * @notice Migrate pending referral bonuses from off-chain database (ADMIN ONLY)
     * @dev Used for one-time migration of bonuses tracked in old database system.
     *      Sets pendingReferralBonuses for users who have accumulated bonuses off-chain.
     *      These users can then claim via claimReferralBonusPermissionless().
     *
     *      SECURITY: This function now properly accounts for pool balance changes.
     *      Increasing a pending bonus deducts from referralBonusPool.remaining.
     *      Decreasing a pending bonus credits back to referralBonusPool.remaining.
     *      This prevents the pool accounting bypass where arbitrary pending amounts
     *      could be set without deducting from the pool, then claimed from the
     *      contract's total XOM balance.
     *
     *      ADMIN-ONLY function for migration purposes. Once all legacy bonuses
     *      are migrated, this function should not be needed.
     *
     * @param referrer Address of the referrer
     * @param amount New pending bonus amount (in wei). Must be > 0.
     */
    function setPendingReferralBonus(
        address referrer,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (referrer == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert ZeroAmountNotAllowed();

        uint256 oldPending = pendingReferralBonuses[referrer];

        if (amount > oldPending) {
            // Increasing pending bonus: deduct the increase from pool
            uint256 increase = amount - oldPending;
            _validatePoolBalance(referralBonusPool, PoolType.ReferralBonus, increase);
            _updatePoolAfterDistribution(referralBonusPool, increase);
        } else if (amount < oldPending) {
            // Decreasing pending bonus: credit the decrease back to pool
            uint256 decrease = oldPending - amount;
            referralBonusPool.remaining += decrease;
            referralBonusPool.distributed -= decrease;
        }
        // If amount == oldPending, no pool changes needed

        pendingReferralBonuses[referrer] = amount;

        emit ReferralBonusMigrated(referrer, oldPending, amount);
    }

    // ============ External Functions - Permissionless Claiming ============

    /**
     * @notice Claim welcome bonus directly (permissionless)
     * @dev Users call this directly after completing KYC Tier 1. No role required.
     *      Validates eligibility via OmniRegistration contract.
     *      Automatically triggers referral bonus accumulation for referrer.
     *
     * Security measures:
     * - Must be registered in OmniRegistration contract
     * - KYC Tier 1 required (phone + social media verified on-chain)
     * - Daily rate limit enforced (MAX_DAILY_WELCOME_BONUSES per day)
     * - Bonus amount calculated based on effective claim count
     * - ODDAO address must be set (required for referral distribution)
     */
    function claimWelcomeBonusPermissionless() external nonReentrant whenNotPaused {
        if (address(registrationContract) == address(0)) {
            revert RegistrationContractNotSet();
        }

        // Get registration data from OmniRegistration contract
        IOmniRegistration.Registration memory reg = registrationContract.getRegistration(msg.sender);

        // Verify eligibility
        if (reg.timestamp == 0) revert UserNotRegistered(msg.sender);
        if (reg.welcomeBonusClaimed) {
            revert BonusAlreadyClaimed(msg.sender, PoolType.WelcomeBonus);
        }

        // CRITICAL: Verify KYC Tier 1 completion (phone + social verified)
        // This prevents Sybil attacks where bots register and immediately claim bonuses
        // without completing any identity verification
        if (!registrationContract.hasKycTier1(msg.sender)) {
            revert KycTier1Required(msg.sender);
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyWelcomeBonusCount[today] >= MAX_DAILY_WELCOME_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.WelcomeBonus, MAX_DAILY_WELCOME_BONUSES);
        }
        ++dailyWelcomeBonusCount[today];

        // Calculate bonus based on effective CLAIM count (on-chain claims + legacy claims)
        // Legacy users (~3996) already got their bonus in old OmniBazaar
        // New users start at position ~3997+ (Tier 2: 5,000 XOM)
        // NOTE: We use claim count, NOT registration count (not all users claim bonuses)
        uint256 effectiveClaims = welcomeBonusClaimCount + legacyBonusClaimsCount;
        if (effectiveClaims == 0) effectiveClaims = 1; // Minimum 1 to avoid edge cases
        uint256 bonusAmount = _calculateWelcomeBonus(effectiveClaims);

        // Validate pool balance
        _validatePoolBalance(welcomeBonusPool, PoolType.WelcomeBonus, bonusAmount);

        // Mark as claimed in registration contract
        registrationContract.markWelcomeBonusClaimed(msg.sender);

        // Mark as claimed locally (for backward compatibility)
        welcomeBonusClaimed[msg.sender] = true;

        // Increment claim count BEFORE transfer (for accurate tier calculation)
        ++welcomeBonusClaimCount;

        // Update pool and transfer
        _updatePoolAfterDistribution(welcomeBonusPool, bonusAmount);
        omniCoin.safeTransfer(msg.sender, bonusAmount);

        emit PermissionlessWelcomeBonusClaimed(msg.sender, bonusAmount, reg.referrer);
        emit WelcomeBonusClaimed(msg.sender, bonusAmount, welcomeBonusPool.remaining);
        _checkPoolThreshold(PoolType.WelcomeBonus, welcomeBonusPool);

        // Auto-trigger referral bonus if referrer exists (use effectiveClaims for tier calc)
        if (reg.referrer != address(0)) {
            _distributeAutoReferralBonus(reg.referrer, msg.sender, effectiveClaims);
        }
    }

    /**
     * @notice Claim welcome bonus using trustless on-chain verification
     * @dev Users call this after completing KYC Tier 1 via on-chain verification.
     *      Requires user to have:
     *      1. Registered in OmniRegistration contract
     *      2. Submitted phone verification proof on-chain
     *      3. Submitted social verification proof on-chain
     *      4. Achieved KYC Tier 1 status (hasKycTier1 returns true)
     *
     *      This is the TRUSTLESS version - no validator role required.
     *      User must first submit verification proofs to OmniRegistration contract:
     *      - registration.submitPhoneVerification(phoneHash, timestamp, nonce, deadline, signature)
     *      - registration.submitSocialVerification(socialHash, platform, timestamp, nonce, deadline, signature)
     *
     * Security measures:
     * - Requires hasKycTier1() to return true (on-chain verification)
     * - No trusted roles involved in the verification
     * - Daily rate limit enforced
     * - Bonus amount calculated based on registration number
     */
    function claimWelcomeBonusTrustless() external nonReentrant whenNotPaused {
        if (address(registrationContract) == address(0)) {
            revert RegistrationContractNotSet();
        }

        // Get registration data from OmniRegistration contract
        IOmniRegistration.Registration memory reg = registrationContract.getRegistration(msg.sender);

        // Verify user is registered
        if (reg.timestamp == 0) revert UserNotRegistered(msg.sender);

        // Verify welcome bonus not already claimed
        if (reg.welcomeBonusClaimed) {
            revert BonusAlreadyClaimed(msg.sender, PoolType.WelcomeBonus);
        }

        // CRITICAL: Verify KYC Tier 1 completion via on-chain verification
        // This checks that user has submitted phone AND social verification proofs on-chain
        if (!registrationContract.hasKycTier1(msg.sender)) {
            revert KycTier1Required(msg.sender);
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyWelcomeBonusCount[today] >= MAX_DAILY_WELCOME_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.WelcomeBonus, MAX_DAILY_WELCOME_BONUSES);
        }
        ++dailyWelcomeBonusCount[today];

        // Calculate bonus based on effective CLAIM count (on-chain claims + legacy claims)
        // NOTE: We use claim count, NOT registration count (not all users claim bonuses)
        uint256 effectiveClaims = welcomeBonusClaimCount + legacyBonusClaimsCount;
        if (effectiveClaims == 0) effectiveClaims = 1; // Minimum 1 to avoid edge cases
        uint256 bonusAmount = _calculateWelcomeBonus(effectiveClaims);

        // Validate pool balance
        _validatePoolBalance(welcomeBonusPool, PoolType.WelcomeBonus, bonusAmount);

        // Mark as claimed in registration contract
        registrationContract.markWelcomeBonusClaimed(msg.sender);

        // Mark as claimed locally (for backward compatibility)
        welcomeBonusClaimed[msg.sender] = true;

        // Increment claim count BEFORE transfer (for accurate tier calculation)
        ++welcomeBonusClaimCount;

        // Update pool and transfer
        _updatePoolAfterDistribution(welcomeBonusPool, bonusAmount);
        omniCoin.safeTransfer(msg.sender, bonusAmount);

        emit TrustlessWelcomeBonusClaimed(msg.sender, bonusAmount, reg.referrer);
        emit WelcomeBonusClaimed(msg.sender, bonusAmount, welcomeBonusPool.remaining);
        _checkPoolThreshold(PoolType.WelcomeBonus, welcomeBonusPool);

        // Auto-trigger referral bonus if referrer exists (use effectiveClaims for tier calc)
        if (reg.referrer != address(0)) {
            _distributeAutoReferralBonus(reg.referrer, msg.sender, effectiveClaims);
        }
    }

    /**
     * @notice Claim welcome bonus with user signature (trustless relayable)
     * @dev ANYONE can relay this - NO SPECIAL ROLES REQUIRED.
     *      Security comes from verifying the USER'S signature, not caller's role.
     *      This is the GASLESS version - relayer pays gas, user receives bonus.
     *
     *      The user signs an EIP-712 ClaimWelcomeBonus message with their wallet.
     *      Any relayer can submit the signed message and pay gas.
     *      The contract verifies the USER signed it, then transfers bonus to USER.
     *
     * @param user The address of the user claiming (must match signer)
     * @param nonce User's current claim nonce (for replay protection)
     * @param deadline Claim request expiration timestamp
     * @param signature User's EIP-712 signature
     *
     * Security measures:
     * - USER must sign the claim request (cannot claim without wallet control)
     * - User must be registered in OmniRegistration contract
     * - User must have KYC Tier 1 status (phone + social verified on-chain)
     * - User must not have already claimed
     * - Nonce prevents replay attacks
     * - Deadline prevents stale claims
     * - Daily rate limit enforced
     * - NO ROLE CHECK - Relayer has NO attestation power
     */
    function claimWelcomeBonusRelayed(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (address(registrationContract) == address(0)) {
            revert RegistrationContractNotSet();
        }
        if (user == address(0)) {
            revert ZeroAddressNotAllowed();
        }

        // 1. Check deadline
        if (block.timestamp > deadline) {
            revert ClaimDeadlineExpired();
        }

        // 2. Verify nonce (replay protection)
        if (nonce != claimNonces[user]) {
            revert InvalidClaimNonce(user, nonce, claimNonces[user]);
        }

        // 3. Verify USER's signature (EIP-712)
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_WELCOME_BONUS_TYPEHASH, user, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != user) {
            revert InvalidUserSignature(user, recoveredSigner);
        }

        // 4. Increment nonce BEFORE state changes (replay protection)
        ++claimNonces[user];

        // 5. Get registration data from OmniRegistration contract
        IOmniRegistration.Registration memory reg = registrationContract.getRegistration(user);

        // 6. Verify user is registered
        if (reg.timestamp == 0) revert UserNotRegistered(user);

        // 7. Verify welcome bonus not already claimed
        if (reg.welcomeBonusClaimed) {
            revert BonusAlreadyClaimed(user, PoolType.WelcomeBonus);
        }

        // 8. Verify KYC Tier 1 completion via on-chain verification
        if (!registrationContract.hasKycTier1(user)) {
            revert KycTier1Required(user);
        }

        // 9. Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyWelcomeBonusCount[today] >= MAX_DAILY_WELCOME_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.WelcomeBonus, MAX_DAILY_WELCOME_BONUSES);
        }
        ++dailyWelcomeBonusCount[today];

        // 10. Calculate bonus based on effective CLAIM count (on-chain claims + legacy claims)
        // NOTE: We use claim count, NOT registration count (not all users claim bonuses)
        uint256 effectiveClaims = welcomeBonusClaimCount + legacyBonusClaimsCount;
        if (effectiveClaims == 0) effectiveClaims = 1;
        uint256 bonusAmount = _calculateWelcomeBonus(effectiveClaims);

        // 11. Validate pool balance
        _validatePoolBalance(welcomeBonusPool, PoolType.WelcomeBonus, bonusAmount);

        // 12. Mark as claimed in registration contract
        registrationContract.markWelcomeBonusClaimed(user);

        // 13. Mark as claimed locally (for backward compatibility)
        welcomeBonusClaimed[user] = true;

        // 14. Increment claim count BEFORE transfer (for accurate tier calculation)
        ++welcomeBonusClaimCount;

        // 15. Update pool and transfer TO USER (not msg.sender!)
        _updatePoolAfterDistribution(welcomeBonusPool, bonusAmount);
        omniCoin.safeTransfer(user, bonusAmount);

        // 16. Emit events (include relayer for tracking)
        emit WelcomeBonusClaimedRelayed(user, bonusAmount, msg.sender, reg.referrer);
        emit WelcomeBonusClaimed(user, bonusAmount, welcomeBonusPool.remaining);
        _checkPoolThreshold(PoolType.WelcomeBonus, welcomeBonusPool);

        // 17. Auto-trigger referral bonus if referrer exists (use effectiveClaims for tier calc)
        if (reg.referrer != address(0)) {
            _distributeAutoReferralBonus(reg.referrer, user, effectiveClaims);
        }
    }

    /**
     * @notice Get user's current claim nonce
     * @param user Address to check
     * @return Current nonce for the user
     */
    function getClaimNonce(address user) external view returns (uint256) {
        return claimNonces[user];
    }

    /**
     * @notice Claim accumulated referral bonuses (permissionless)
     * @dev Referrers call this to claim their accumulated bonuses from successful referrals.
     *      No role required - anyone can claim their own pending bonuses.
     *      Bonuses accumulate when referees claim welcome bonuses.
     *
     * Security measures:
     * - Can only claim own pending bonuses (msg.sender)
     * - No validator involvement in distribution decision
     * - Amount verified on-chain in pendingReferralBonuses mapping
     * - Daily rate limit enforced
     */
    function claimReferralBonusPermissionless() external nonReentrant whenNotPaused {
        uint256 pending = pendingReferralBonuses[msg.sender];

        // Check has pending bonus
        if (pending == 0) {
            revert NoPendingReferralBonus(msg.sender);
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyReferralBonusCount[today] >= MAX_DAILY_REFERRAL_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.ReferralBonus, MAX_DAILY_REFERRAL_BONUSES);
        }
        ++dailyReferralBonusCount[today];

        // Clear pending bonus
        pendingReferralBonuses[msg.sender] = 0;

        // Transfer bonus
        omniCoin.safeTransfer(msg.sender, pending);

        emit ReferralBonusClaimedPermissionless(msg.sender, pending);
        emit ReferralBonusClaimed(msg.sender, address(0), pending);
        _checkPoolThreshold(PoolType.ReferralBonus, referralBonusPool);
    }

    /**
     * @notice Claim referral bonus with user signature (trustless relayable)
     * @dev ANYONE can relay this - NO SPECIAL ROLES REQUIRED.
     *      User signs claim request, relayer pays gas.
     *      This is the GASLESS version of claimReferralBonusPermissionless.
     *
     * @param user Address of referrer claiming (must match signer)
     * @param nonce User's current claim nonce
     * @param deadline Claim request expiration
     * @param signature User's EIP-712 signature
     *
     * Security measures:
     * - USER must sign the claim request
     * - Nonce-based replay protection
     * - Time-bounded via deadline
     * - Relayer has NO control over eligibility or amount
     */
    function claimReferralBonusRelayed(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        // 1. Check deadline
        if (block.timestamp > deadline) revert ClaimDeadlineExpired();

        // 2. Verify nonce
        if (nonce != claimNonces[user]) {
            revert InvalidClaimNonce(user, nonce, claimNonces[user]);
        }

        // 3. Verify user signature (EIP-712)
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_REFERRAL_BONUS_TYPEHASH,
            user,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != user) {
            revert InvalidUserSignature(user, recoveredSigner);
        }

        // 4. Check has pending bonus
        uint256 pending = pendingReferralBonuses[user];
        if (pending == 0) {
            revert NoPendingReferralBonus(user);
        }

        // 5. Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyReferralBonusCount[today] >= MAX_DAILY_REFERRAL_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.ReferralBonus, MAX_DAILY_REFERRAL_BONUSES);
        }
        ++dailyReferralBonusCount[today];

        // 6. Increment nonce (replay protection)
        ++claimNonces[user];

        // 7. Clear pending bonus
        pendingReferralBonuses[user] = 0;

        // 8. Transfer bonus to USER
        omniCoin.safeTransfer(user, pending);

        // 9. Emit events
        emit ReferralBonusClaimedRelayed(user, pending, msg.sender);
        emit ReferralBonusClaimed(user, address(0), pending);
        _checkPoolThreshold(PoolType.ReferralBonus, referralBonusPool);
    }

    /**
     * @notice Claim first sale bonus directly (permissionless)
     * @dev Sellers call this after completing their first sale.
     *      Requires that the user has actually completed a sale, as tracked
     *      by OmniRegistration.firstSaleCompleted (set by marketplace/escrow).
     */
    function claimFirstSaleBonusPermissionless() external nonReentrant whenNotPaused {
        if (address(registrationContract) == address(0)) {
            revert RegistrationContractNotSet();
        }

        // Get registration data
        IOmniRegistration.Registration memory reg = registrationContract.getRegistration(msg.sender);

        // Verify eligibility
        if (reg.timestamp == 0) revert UserNotRegistered(msg.sender);
        if (reg.firstSaleBonusClaimed) {
            revert BonusAlreadyClaimed(msg.sender, PoolType.FirstSaleBonus);
        }

        // Verify user has actually completed a first sale
        if (!registrationContract.hasCompletedFirstSale(msg.sender)) {
            revert FirstSaleNotCompleted(msg.sender);
        }

        // Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyFirstSaleBonusCount[today] >= MAX_DAILY_FIRST_SALE_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.FirstSaleBonus, MAX_DAILY_FIRST_SALE_BONUSES);
        }
        ++dailyFirstSaleBonusCount[today];

        // Calculate bonus based on effective registrations (on-chain + legacy claims)
        uint256 totalRegs = registrationContract.totalRegistrations();
        uint256 effectiveRegs = totalRegs + legacyBonusClaimsCount;
        if (effectiveRegs == 0) effectiveRegs = 1; // Minimum 1 to avoid edge cases
        uint256 bonusAmount = _calculateFirstSaleBonus(effectiveRegs);

        // Validate pool balance
        _validatePoolBalance(firstSaleBonusPool, PoolType.FirstSaleBonus, bonusAmount);

        // Mark as claimed
        registrationContract.markFirstSaleBonusClaimed(msg.sender);
        firstSaleBonusClaimed[msg.sender] = true;

        // Update pool and transfer
        _updatePoolAfterDistribution(firstSaleBonusPool, bonusAmount);
        omniCoin.safeTransfer(msg.sender, bonusAmount);

        emit FirstSaleBonusClaimed(msg.sender, bonusAmount, firstSaleBonusPool.remaining);
        _checkPoolThreshold(PoolType.FirstSaleBonus, firstSaleBonusPool);
    }

    /**
     * @notice Claim first sale bonus with user signature (trustless relayable)
     * @dev ANYONE can relay this - NO SPECIAL ROLES REQUIRED.
     *      User signs claim request, relayer pays gas.
     *      This is the GASLESS version of claimFirstSaleBonusPermissionless.
     *
     * @param user Address of seller claiming (must match signer)
     * @param nonce User's current claim nonce
     * @param deadline Claim request expiration
     * @param signature User's EIP-712 signature
     *
     * Security measures:
     * - USER must sign the claim request
     * - Eligibility verified on-chain via OmniRegistration
     * - Nonce-based replay protection
     * - Time-bounded via deadline
     * - Relayer has NO control over eligibility or amount
     */
    function claimFirstSaleBonusRelayed(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        // 1. Check registration contract is set
        if (address(registrationContract) == address(0)) {
            revert RegistrationContractNotSet();
        }

        // 2. Check deadline
        if (block.timestamp > deadline) revert ClaimDeadlineExpired();

        // 3. Verify nonce
        if (nonce != claimNonces[user]) {
            revert InvalidClaimNonce(user, nonce, claimNonces[user]);
        }

        // 4. Verify user signature (EIP-712)
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_FIRST_SALE_BONUS_TYPEHASH,
            user,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != user) {
            revert InvalidUserSignature(user, recoveredSigner);
        }

        // 5. Get registration data
        IOmniRegistration.Registration memory reg = registrationContract.getRegistration(user);

        // 6. Verify eligibility
        if (reg.timestamp == 0) revert UserNotRegistered(user);
        if (reg.firstSaleBonusClaimed) {
            revert BonusAlreadyClaimed(user, PoolType.FirstSaleBonus);
        }

        // 6b. Verify user has actually completed a first sale
        if (!registrationContract.hasCompletedFirstSale(user)) {
            revert FirstSaleNotCompleted(user);
        }

        // 7. Check daily rate limit
        uint256 today = block.timestamp / 1 days;
        if (dailyFirstSaleBonusCount[today] >= MAX_DAILY_FIRST_SALE_BONUSES) {
            revert DailyBonusLimitExceeded(PoolType.FirstSaleBonus, MAX_DAILY_FIRST_SALE_BONUSES);
        }
        ++dailyFirstSaleBonusCount[today];

        // 8. Increment nonce (replay protection)
        ++claimNonces[user];

        // 9. Calculate bonus based on effective registrations
        uint256 totalRegs = registrationContract.totalRegistrations();
        uint256 effectiveRegs = totalRegs + legacyBonusClaimsCount;
        if (effectiveRegs == 0) effectiveRegs = 1;
        uint256 bonusAmount = _calculateFirstSaleBonus(effectiveRegs);

        // 10. Validate pool balance
        _validatePoolBalance(firstSaleBonusPool, PoolType.FirstSaleBonus, bonusAmount);

        // 11. Mark as claimed
        registrationContract.markFirstSaleBonusClaimed(user);
        firstSaleBonusClaimed[user] = true;

        // 12. Update pool and transfer to USER (not msg.sender!)
        _updatePoolAfterDistribution(firstSaleBonusPool, bonusAmount);
        omniCoin.safeTransfer(user, bonusAmount);

        // 13. Emit events
        emit FirstSaleBonusClaimedRelayed(user, bonusAmount, msg.sender);
        emit FirstSaleBonusClaimed(user, bonusAmount, firstSaleBonusPool.remaining);
        _checkPoolThreshold(PoolType.FirstSaleBonus, firstSaleBonusPool);
    }

    // ============ External View Functions ============

    /**
     * @notice Get all pool balances in a single call
     * @return welcomeBonus Remaining welcome bonus pool balance
     * @return referralBonus Remaining referral bonus pool balance
     * @return firstSaleBonus Remaining first sale bonus pool balance
     * @return validatorRewards Remaining validator rewards pool balance
     */
    function getPoolBalances()
        external
        view
        returns (
            uint256 welcomeBonus,
            uint256 referralBonus,
            uint256 firstSaleBonus,
            uint256 validatorRewards
        )
    {
        return (
            welcomeBonusPool.remaining,
            referralBonusPool.remaining,
            firstSaleBonusPool.remaining,
            validatorRewardsPool.remaining
        );
    }

    /**
     * @notice Get total undistributed tokens across all pools
     * @return total Sum of all remaining pool balances
     */
    function getTotalUndistributed() external view returns (uint256 total) {
        return welcomeBonusPool.remaining +
            referralBonusPool.remaining +
            firstSaleBonusPool.remaining +
            validatorRewardsPool.remaining;
    }

    /**
     * @notice Get total tokens distributed across all pools
     * @return total Sum of all distributed tokens
     */
    function getTotalDistributed() external view returns (uint256 total) {
        return welcomeBonusPool.distributed +
            referralBonusPool.distributed +
            firstSaleBonusPool.distributed +
            validatorRewardsPool.distributed;
    }

    /**
     * @notice Check if a user has claimed their welcome bonus
     * @param user Address to check
     * @return claimed True if already claimed
     */
    function hasClaimedWelcomeBonus(address user) external view returns (bool claimed) {
        return welcomeBonusClaimed[user];
    }

    /**
     * @notice Check if a seller has claimed their first sale bonus
     * @param seller Address to check
     * @return claimed True if already claimed
     */
    function hasClaimedFirstSaleBonus(address seller) external view returns (bool claimed) {
        return firstSaleBonusClaimed[seller];
    }

    /**
     * @notice Get total referral bonuses earned by an address
     * @param referrer Address to check
     * @return earned Total XOM earned through referrals
     */
    function getReferralBonusesEarned(address referrer) external view returns (uint256 earned) {
        return referralBonusesEarned[referrer];
    }

    /**
     * @notice Get pending referral bonus ready to claim
     * @dev Returns amount accumulated but not yet claimed by the referrer.
     *      User must call claimReferralBonusPermissionless() to receive these bonuses.
     * @param referrer Address to check
     * @return pending Pending referral bonus amount in wei
     */
    function getPendingReferralBonus(address referrer) external view returns (uint256 pending) {
        return pendingReferralBonuses[referrer];
    }

    /**
     * @notice Get effective claim count after applying legacy claims count
     * @dev Returns the claim count used for bonus tier calculation.
     *      NOTE: This is based on CLAIMS, not registrations (not all users claim bonuses).
     * @return effectiveClaims Effective claim count (on-chain claims + legacy claims)
     */
    function getEffectiveRegistrations() external view returns (uint256 effectiveClaims) {
        uint256 result = welcomeBonusClaimCount + legacyBonusClaimsCount;
        return result > 0 ? result : 1;
    }

    /**
     * @notice Get the expected welcome bonus amount for new users
     * @dev Calculates based on effective CLAIM count (on-chain claims + legacy claims).
     *      NOTE: Tier is based on number of bonuses paid, not user registrations.
     * @return bonusAmount Expected bonus in wei (18 decimals)
     */
    function getExpectedWelcomeBonus() external view returns (uint256 bonusAmount) {
        uint256 effectiveClaims = welcomeBonusClaimCount + legacyBonusClaimsCount;
        if (effectiveClaims == 0) effectiveClaims = 1;
        return _calculateWelcomeBonus(effectiveClaims);
    }

    /**
     * @notice Get the expected referral bonus amount for new referrals
     * @dev Calculates based on effective CLAIM count (on-chain claims + legacy claims).
     *      NOTE: Tier is based on number of bonuses paid, not user registrations.
     * @return bonusAmount Expected bonus in wei (18 decimals)
     */
    function getExpectedReferralBonus() external view returns (uint256 bonusAmount) {
        uint256 effectiveClaims = welcomeBonusClaimCount + legacyBonusClaimsCount;
        if (effectiveClaims == 0) effectiveClaims = 1;
        return _calculateReferralBonus(effectiveClaims);
    }

    /**
     * @notice Get the expected first sale bonus amount for sellers
     * @dev M-04: Uses totalRegistrations + legacyBonusClaimsCount to match actual
     *      claimFirstSaleBonusPermissionless() logic. First sale bonus tiers are
     *      based on total registrations, not welcome bonus claim count.
     * @return bonusAmount Expected bonus in wei (18 decimals)
     */
    function getExpectedFirstSaleBonus() external view returns (uint256 bonusAmount) {
        // M-04: Match claimFirstSaleBonusPermissionless() which uses totalRegistrations
        uint256 effectiveRegs;
        if (address(registrationContract) != address(0)) {
            effectiveRegs = registrationContract.totalRegistrations() + legacyBonusClaimsCount;
        } else {
            effectiveRegs = legacyBonusClaimsCount;
        }
        if (effectiveRegs == 0) effectiveRegs = 1;
        return _calculateFirstSaleBonus(effectiveRegs);
    }

    /**
     * @notice Get detailed statistics for all pools
     * @return initialAmounts Initial allocation for each pool
     * @return remainingAmounts Remaining balance for each pool
     * @return distributedAmounts Total distributed from each pool
     */
    function getPoolStatistics()
        external
        view
        returns (
            uint256[4] memory initialAmounts,
            uint256[4] memory remainingAmounts,
            uint256[4] memory distributedAmounts
        )
    {
        initialAmounts = [
            welcomeBonusPool.initial,
            referralBonusPool.initial,
            firstSaleBonusPool.initial,
            validatorRewardsPool.initial
        ];

        remainingAmounts = [
            welcomeBonusPool.remaining,
            referralBonusPool.remaining,
            firstSaleBonusPool.remaining,
            validatorRewardsPool.remaining
        ];

        distributedAmounts = [
            welcomeBonusPool.distributed,
            referralBonusPool.distributed,
            firstSaleBonusPool.distributed,
            validatorRewardsPool.distributed
        ];
    }

    // ============ Internal Functions (non-view, non-pure first) ============

    /**
     * @notice Initialize a pool state
     * @param pool Pool state storage reference
     * @param amount Initial pool amount
     */
    function _initializePool(PoolState storage pool, uint256 amount) internal {
        pool.initial = amount;
        pool.remaining = amount;
    }

    /**
     * @notice Update pool state after distribution
     * @param pool Pool state to update
     * @param amount Amount distributed
     */
    function _updatePoolAfterDistribution(PoolState storage pool, uint256 amount) internal {
        pool.remaining -= amount;
        pool.distributed += amount;
    }

    /**
     * @notice Check if pool balance is below warning threshold
     * @param poolType Type of pool to check
     * @param pool Pool state to check
     */
    function _checkPoolThreshold(PoolType poolType, PoolState storage pool) internal {
        uint256 threshold = (pool.initial * LOW_POOL_THRESHOLD_BPS) / BASIS_POINTS;
        if (pool.remaining < threshold + 1 && pool.remaining != 0) {
            emit PoolLowWarning(poolType, pool.remaining, threshold);
        }
    }

    /**
     * @notice Set merkle root for a pool type
     * @param poolType Type of pool
     * @param newRoot New merkle root
     */
    function _setMerkleRoot(PoolType poolType, bytes32 newRoot) internal {
        if (poolType == PoolType.WelcomeBonus) {
            welcomeBonusPool.merkleRoot = newRoot;
        } else if (poolType == PoolType.ReferralBonus) {
            referralBonusPool.merkleRoot = newRoot;
        } else if (poolType == PoolType.FirstSaleBonus) {
            firstSaleBonusPool.merkleRoot = newRoot;
        } else {
            revert InvalidPoolTypeForMerkle();
        }
    }

    /**
     * @notice Distribute referral rewards to referrers and ODDAO
     * @dev Enforces the 70/20/10 split by calculating the ODDAO share
     *      on-chain from the total amount. The total pool deduction
     *      (done by the caller) includes the ODDAO share.
     *      Split: primaryAmount (70%) to referrer, secondaryAmount (20%)
     *      to second-level referrer, remainder (10%) to ODDAO.
     *      If no second-level referrer, their 20% goes to ODDAO (total 30%).
     * @param params Referral distribution parameters
     */
    function _distributeReferralRewards(ReferralParams calldata params) internal {
        referralBonusesEarned[params.referrer] += params.primaryAmount;

        if (params.primaryAmount != 0) {
            omniCoin.safeTransfer(params.referrer, params.primaryAmount);
        }

        uint256 oddaoShare;
        if (params.secondaryAmount != 0 && params.secondLevelReferrer != address(0)) {
            referralBonusesEarned[params.secondLevelReferrer] += params.secondaryAmount;
            omniCoin.safeTransfer(params.secondLevelReferrer, params.secondaryAmount);
            // ODDAO gets 10% of total (remainder after 70%+20%)
            uint256 totalAmount = params.primaryAmount + params.secondaryAmount;
            oddaoShare = (totalAmount * 10) / 90;
        } else {
            // No second-level referrer: ODDAO gets 30% of total (10% + unused 20%)
            oddaoShare = (params.primaryAmount * 30) / 70;
        }

        // Send ODDAO share if oddaoAddress is set
        if (oddaoShare != 0 && oddaoAddress != address(0)) {
            omniCoin.safeTransfer(oddaoAddress, oddaoShare);
        }
    }

    /**
     * @notice Distribute validator rewards to recipients
     * @param params Validator reward parameters
     */
    function _distributeValidatorRewards(ValidatorRewardParams calldata params) internal {
        if (params.validatorAmount != 0) {
            omniCoin.safeTransfer(params.validator, params.validatorAmount);
        }

        if (params.stakingAmount != 0) {
            omniCoin.safeTransfer(params.stakingPool, params.stakingAmount);
        }

        if (params.oddaoAmount != 0) {
            omniCoin.safeTransfer(params.oddao, params.oddaoAmount);
        }
    }

    /**
     * @notice Setup initial admin role only
     * @dev Only grants DEFAULT_ADMIN_ROLE. Other roles (BONUS_DISTRIBUTOR_ROLE,
     *      VALIDATOR_REWARD_ROLE, UPGRADER_ROLE, PAUSER_ROLE) must be granted
     *      separately to distinct addresses via grantRole().
     *
     *      SECURITY: admin MUST be a multi-sig wallet (Gnosis Safe 3-of-5 minimum)
     *      with TimelockController for all sensitive operations. Granting all five
     *      roles to a single EOA creates a single point of compromise. The admin
     *      should grant operational roles to separate, purpose-specific addresses:
     *      - BONUS_DISTRIBUTOR_ROLE -> validator service account
     *      - VALIDATOR_REWARD_ROLE  -> OmniCore scheduler contract
     *      - UPGRADER_ROLE          -> timelock-controlled upgrade multisig
     *      - PAUSER_ROLE            -> emergency response multisig
     *
     * @param admin Address to receive admin role (must be a multi-sig wallet)
     */
    function _setupRoles(address admin) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @notice Calculate welcome bonus amount based on registration number
     * @dev Implements decreasing curve as per tokenomics
     * @param registrationNumber Current total registration count
     * @return Bonus amount in wei
     *
     * Bonus Schedule:
     * - Users 1 - 1,000:           10,000 XOM
     * - Users 1,001 - 10,000:       5,000 XOM
     * - Users 10,001 - 100,000:     2,500 XOM
     * - Users 100,001 - 1,000,000:  1,250 XOM
     * - Users 1,000,001+:             625 XOM
     */
    function _calculateWelcomeBonus(uint256 registrationNumber) internal pure returns (uint256) {
        if (registrationNumber <= 1000) {
            return 10000 * 10 ** 18;
        } else if (registrationNumber <= 10000) {
            return 5000 * 10 ** 18;
        } else if (registrationNumber <= 100000) {
            return 2500 * 10 ** 18;
        } else if (registrationNumber <= 1000000) {
            return 1250 * 10 ** 18;
        } else {
            return 625 * 10 ** 18;
        }
    }

    /**
     * @notice Calculate referral bonus amount based on registration number
     * @dev Mirrors welcome bonus tiers with different amounts
     * @param registrationNumber Current total registration count
     * @return Bonus amount in wei
     *
     * Referral Schedule:
     * - Users 1 - 10,000:            2,500 XOM
     * - Users 10,001 - 100,000:      1,250 XOM
     * - Users 100,001 - 1,000,000:     625 XOM
     * - Users 1,000,001+:             312.5 XOM (rounded to 312 XOM)
     */
    function _calculateReferralBonus(uint256 registrationNumber) internal pure returns (uint256) {
        if (registrationNumber <= 10000) {
            return 2500 * 10 ** 18;
        } else if (registrationNumber <= 100000) {
            return 1250 * 10 ** 18;
        } else if (registrationNumber <= 1000000) {
            return 625 * 10 ** 18;
        } else {
            return 312 * 10 ** 18; // 312.5 rounded down
        }
    }

    /**
     * @notice Calculate first sale bonus amount based on registration number
     * @dev Incentivizes early sellers
     * @param registrationNumber Current total registration count
     * @return Bonus amount in wei
     *
     * First Sale Schedule:
     * - Users 1 - 100,000:             500 XOM
     * - Users 100,001 - 1,000,000:     250 XOM
     * - Users 1,000,001 - 10,000,000:  125 XOM
     * - Users 10,000,001+:              62.5 XOM (rounded to 62 XOM)
     */
    function _calculateFirstSaleBonus(uint256 registrationNumber) internal pure returns (uint256) {
        if (registrationNumber <= 100000) {
            return 500 * 10 ** 18;
        } else if (registrationNumber <= 1000000) {
            return 250 * 10 ** 18;
        } else if (registrationNumber <= 10000000) {
            return 125 * 10 ** 18;
        } else {
            return 62 * 10 ** 18; // 62.5 rounded down
        }
    }

    /**
     * @notice Accumulate referral bonus when welcome bonus is claimed (TRUSTLESS)
     * @dev Called internally by welcome bonus claim functions.
     *      DOES NOT transfer - accumulates to pendingReferralBonuses mapping.
     *      Referrer must manually claim via claimReferralBonusPermissionless().
     *      This removes validator control over bonus distribution.
     *
     * @param referrer Primary referrer address
     * @param referee User who claimed welcome bonus (triggers this accumulation)
     * @param registrationNumber Current effective registrations for bonus calculation
     *
     * Accumulation:
     * - 70% accumulated for primary referrer
     * - 20% accumulated for second-level referrer (if exists)
     * - 10% transferred immediately to ODDAO (no accumulation needed)
     */
    function _distributeAutoReferralBonus(
        address referrer,
        address referee,
        uint256 registrationNumber
    ) internal {
        // SECURITY: Revert if ODDAO address not set to prevent stranded funds.
        // The ODDAO share (10%) would be silently skipped if oddaoAddress == address(0),
        // causing those tokens to remain locked in the contract permanently.
        if (oddaoAddress == address(0)) revert OddaoAddressNotSet();

        // M-05: Use SEPARATE daily counter for auto-distribution
        // This prevents auto-distributions from blocking manual referral claims
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        if (dailyAutoReferralCount[today] >= MAX_DAILY_REFERRAL_BONUSES) {
            // Skip referral bonus if daily limit exceeded (don't revert - welcome bonus already claimed)
            return;
        }
        ++dailyAutoReferralCount[today];

        // Calculate total referral bonus
        uint256 referralAmount = _calculateReferralBonus(registrationNumber);

        // Validate pool balance
        if (referralBonusPool.remaining < referralAmount) {
            // Skip if pool exhausted (don't revert)
            return;
        }

        // Get second-level referrer from registration contract
        IOmniRegistration.Registration memory referrerReg = registrationContract.getRegistration(referrer);
        address secondLevelReferrer = referrerReg.referrer;

        // Calculate distribution amounts
        uint256 referrerAmount = (referralAmount * 70) / 100;
        uint256 secondLevelAmount = (secondLevelReferrer != address(0)) ? (referralAmount * 20) / 100 : 0;
        uint256 oddaoAmount = referralAmount - referrerAmount - secondLevelAmount;

        // Update pool accounting
        _updatePoolAfterDistribution(referralBonusPool, referralAmount);

        // ACCUMULATE bonuses (DO NOT transfer yet!)
        pendingReferralBonuses[referrer] += referrerAmount;
        if (secondLevelAmount != 0 && secondLevelReferrer != address(0)) {
            pendingReferralBonuses[secondLevelReferrer] += secondLevelAmount;
        }

        // Track earnings for stats (backward compatibility)
        referralBonusesEarned[referrer] += referrerAmount;
        if (secondLevelAmount != 0 && secondLevelReferrer != address(0)) {
            referralBonusesEarned[secondLevelReferrer] += secondLevelAmount;
        }

        // Transfer ONLY to ODDAO (no user action needed for protocol)
        if (oddaoAmount != 0 && oddaoAddress != address(0)) {
            omniCoin.safeTransfer(oddaoAddress, oddaoAmount);
        }

        // Emit accumulation event (NOT a claim event!)
        emit ReferralBonusAccumulated(referrer, secondLevelReferrer, referrerAmount, secondLevelAmount, referee);
        _checkPoolThreshold(PoolType.ReferralBonus, referralBonusPool);
    }

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by UPGRADER_ROLE (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(UPGRADER_ROLE) {
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
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern. Only UPGRADER_ROLE can upgrade.
     *      Reverts if contract is ossified.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    // ============ Internal View Functions ============

    /**
     * @notice Validate pool has sufficient balance
     * @param pool Pool state to check
     * @param poolType Pool type for error reporting
     * @param amount Amount requested
     */
    function _validatePoolBalance(
        PoolState storage pool,
        PoolType poolType,
        uint256 amount
    ) internal view {
        if (pool.remaining < amount) {
            revert InsufficientPoolBalance(poolType, amount, pool.remaining);
        }
    }

    /**
     * @notice Verify merkle proof for referral claims
     * @param params Referral parameters
     * @param proof Merkle proof
     */
    /**
     * @notice Verify merkle proof for referral claims
     * @dev M-01: When merkleRoot is bytes32(0), the proof array MUST be empty.
     * @param params Referral parameters
     * @param proof Merkle proof
     */
    function _verifyReferralMerkleProof(
        ReferralParams calldata params,
        bytes32[] calldata proof
    ) internal view {
        if (referralBonusPool.merkleRoot == bytes32(0)) {
            // M-01: No root set - require empty proof (role-gated callers only)
            if (proof.length != 0) {
                revert InvalidMerkleProof(params.referrer, PoolType.ReferralBonus);
            }
            return;
        }
        bytes32 leaf = keccak256(abi.encodePacked(
            params.referrer,
            params.secondLevelReferrer,
            params.primaryAmount,
            params.secondaryAmount
        ));
        if (!MerkleProof.verify(proof, referralBonusPool.merkleRoot, leaf)) {
            revert InvalidMerkleProof(params.referrer, PoolType.ReferralBonus);
        }
    }

    /**
     * @notice Get merkle root for a pool type
     * @param poolType Type of pool
     * @return Current merkle root
     */
    function _getMerkleRoot(PoolType poolType) internal view returns (bytes32) {
        if (poolType == PoolType.WelcomeBonus) return welcomeBonusPool.merkleRoot;
        if (poolType == PoolType.ReferralBonus) return referralBonusPool.merkleRoot;
        if (poolType == PoolType.FirstSaleBonus) return firstSaleBonusPool.merkleRoot;
        revert InvalidPoolTypeForMerkle();
    }

    // ============ Internal Pure Functions ============

    /**
     * @notice Validate initialization parameters
     * @param _omniCoin Address of the OmniCoin token
     * @param _admin Address to receive admin roles
     */
    function _validateInitParams(address _omniCoin, address _admin) internal pure {
        if (_omniCoin == address(0)) revert ZeroAddressNotAllowed();
        if (_admin == address(0)) revert ZeroAddressNotAllowed();
    }

    /**
     * @notice Validate basic claim parameters
     * @param recipient Address receiving the bonus
     * @param amount Amount to transfer
     */
    function _validateClaimParams(address recipient, uint256 amount) internal pure {
        if (recipient == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert ZeroAmountNotAllowed();
    }

    /**
     * @notice Validate that bonus has not been claimed
     * @param claimed Whether bonus was already claimed
     * @param user User address for error reporting
     * @param poolType Pool type for error reporting
     */
    function _validateNotClaimed(bool claimed, address user, PoolType poolType) internal pure {
        if (claimed) revert BonusAlreadyClaimed(user, poolType);
    }

    /**
     * @notice Validate referral bonus parameters
     * @param referrer Primary referrer address
     * @param totalAmount Total amount to distribute
     */
    function _validateReferralParams(address referrer, uint256 totalAmount) internal pure {
        if (referrer == address(0)) revert ZeroAddressNotAllowed();
        if (totalAmount == 0) revert ZeroAmountNotAllowed();
    }

    /**
     * @notice Validate validator reward parameters
     * @param params Validator reward parameters
     * @param totalAmount Total amount to distribute
     */
    function _validateValidatorParams(
        ValidatorRewardParams calldata params,
        uint256 totalAmount
    ) internal pure {
        if (params.validator == address(0)) revert ZeroAddressNotAllowed();
        if (params.stakingPool == address(0)) revert ZeroAddressNotAllowed();
        if (params.oddao == address(0)) revert ZeroAddressNotAllowed();
        if (totalAmount == 0) revert ZeroAmountNotAllowed();
    }

    /**
     * @notice Verify merkle proof for simple claims (user + amount)
     * @param merkleRoot Root to verify against
     * @param user User address
     * @param amount Claim amount
     * @param proof Merkle proof
     * @param poolType Pool type for error reporting
     */
    /**
     * @notice Verify merkle proof for simple claims (user + amount)
     * @dev M-01: When merkleRoot is bytes32(0), the proof array MUST be empty.
     *      This allows initial operation before roots are set (role-gated callers only)
     *      while preventing arbitrary amount claims with fabricated proofs.
     *      Once a merkle root is set, proof verification is enforced.
     * @param merkleRoot Root to verify against
     * @param user User address
     * @param amount Claim amount
     * @param proof Merkle proof
     * @param poolType Pool type for error reporting
     */
    function _verifyMerkleProof(
        bytes32 merkleRoot,
        address user,
        uint256 amount,
        bytes32[] calldata proof,
        PoolType poolType
    ) internal pure {
        if (merkleRoot == bytes32(0)) {
            // M-01: No root set - require empty proof (role-gated callers only)
            if (proof.length != 0) revert InvalidMerkleProof(user, poolType);
            return;
        }
        bytes32 leaf = keccak256(abi.encodePacked(user, amount));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert InvalidMerkleProof(user, poolType);
        }
    }
}
