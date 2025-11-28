// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

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
    ReentrancyGuardUpgradeable
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

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;

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

        omniCoin = IERC20(_omniCoin);

        _initializePool(welcomeBonusPool, _welcomeBonusPool);
        _initializePool(referralBonusPool, _referralBonusPool);
        _initializePool(firstSaleBonusPool, _firstSaleBonusPool);
        _initializePool(validatorRewardsPool, _validatorRewardsPool);

        _setupRoles(_admin);

        uint256 totalPool = _welcomeBonusPool + _referralBonusPool +
            _firstSaleBonusPool + _validatorRewardsPool;
        emit ContractInitialized(_omniCoin, totalPool, _admin);
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
        uint256 totalAmount = params.primaryAmount + params.secondaryAmount;
        _validateReferralParams(params.referrer, totalAmount);
        _validatePoolBalance(referralBonusPool, PoolType.ReferralBonus, totalAmount);
        _verifyReferralMerkleProof(params, merkleProof);

        _updatePoolAfterDistribution(referralBonusPool, totalAmount);
        _distributeReferralRewards(params);

        emit ReferralBonusClaimed(params.referrer, params.secondLevelReferrer, totalAmount);
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
     * @notice Distribute referral rewards to referrers
     * @param params Referral distribution parameters
     */
    function _distributeReferralRewards(ReferralParams calldata params) internal {
        referralBonusesEarned[params.referrer] += params.primaryAmount;

        if (params.primaryAmount != 0) {
            omniCoin.safeTransfer(params.referrer, params.primaryAmount);
        }

        if (params.secondaryAmount != 0 && params.secondLevelReferrer != address(0)) {
            referralBonusesEarned[params.secondLevelReferrer] += params.secondaryAmount;
            omniCoin.safeTransfer(params.secondLevelReferrer, params.secondaryAmount);
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
     * @notice Setup all admin roles
     * @param admin Address to receive roles
     */
    function _setupRoles(address admin) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BONUS_DISTRIBUTOR_ROLE, admin);
        _grantRole(VALIDATOR_REWARD_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern. Only UPGRADER_ROLE can upgrade.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        // Additional upgrade validation can be added here
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
    function _verifyReferralMerkleProof(
        ReferralParams calldata params,
        bytes32[] calldata proof
    ) internal view {
        if (referralBonusPool.merkleRoot != bytes32(0)) {
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
    function _verifyMerkleProof(
        bytes32 merkleRoot,
        address user,
        uint256 amount,
        bytes32[] calldata proof,
        PoolType poolType
    ) internal pure {
        if (merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(user, amount));
            if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
                revert InvalidMerkleProof(user, poolType);
            }
        }
    }
}
