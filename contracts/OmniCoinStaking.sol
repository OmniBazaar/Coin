// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MpcCore, gtUint64, ctUint64, itUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinConfig} from "./OmniCoinConfig.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinStaking
 * @author OmniCoin Development Team
 * @notice Privacy-enabled staking contract for OmniCoin
 * @dev Privacy-enabled staking contract using COTI V2 MPC for encrypted stake amounts
 * 
 * Hybrid Privacy Approach:
 * - Encrypted stake amounts for privacy
 * - Public tier levels for Proof of Participation calculations
 * - Public participation scores for consensus weight
 * - Private reward calculations with public distribution
 */
contract OmniCoinStaking is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivateStake {
        gtUint64 encryptedAmount;       // Private: actual stake amount (encrypted)
        ctUint64 userEncryptedAmount;   // Private: amount encrypted for user viewing
        uint256 tier;                   // Public: staking tier for PoP calculations
        uint256 startTime;              // Public: when stake was created
        uint256 lastRewardTime;         // Public: last reward calculation time
        uint256 commitmentDuration;     // Public: commitment duration in seconds (0 = no commitment)
        gtUint64 encryptedRewards;      // Private: accumulated rewards (encrypted)
        ctUint64 userEncryptedRewards;  // Private: rewards encrypted for user viewing
        bool isActive;                  // Public: whether stake is active
        bool usePrivacy;                // Public: whether using PrivateOmniCoin
    }
    
    struct TierInfo {
        uint256 totalStakers;           // Public: number of stakers in this tier
        uint256 totalTierWeight;        // Public: total weight for PoP calculations
        gtUint64 totalEncryptedAmount;  // Private: total staked in this tier
    }
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidStakeAmount();
    error InvalidPrivacyLevel();
    error NoActiveStake();
    error StakingDisabled();
    error InsufficientStake();
    error StakeAlreadyActive();
    error StakeNotFound();
    error UnstakeTooEarly();
    error InvalidUnstakeAmount();
    error CompoundTooEarly();
    error EmergencyPauseActive();
    error UnauthorizedAccess();
    error InvalidConfiguration();
    error PrivacyNotEnabled();
    error MpcNotAvailable();
    error TransferFailed();
    error InvalidDuration();
    error RewardsTooHigh();
    error InvalidRewardRate();
    error InvalidBasisPoints();
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /* solhint-disable ordering */
    /// @notice Admin role identifier
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Validator role identifier
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    /// @notice Reward distributor role identifier
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    /// @notice Privacy fee configuration - 10x fee for privacy
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    
    // Duration constants
    /// @notice 1 month in seconds
    uint256 public constant ONE_MONTH = 30 days;
    /// @notice 6 months in seconds
    uint256 public constant SIX_MONTHS = 180 days;
    /// @notice 2 years in seconds
    uint256 public constant TWO_YEARS = 730 days;
    
    // Duration bonus rates (in basis points, added to base APY)
    /// @notice 1 month commitment bonus: +1% APY
    uint256 public constant ONE_MONTH_BONUS = 100; // 1%
    /// @notice 6 month commitment bonus: +2% APY
    uint256 public constant SIX_MONTHS_BONUS = 200; // 2%
    /// @notice 2 year commitment bonus: +3% APY
    uint256 public constant TWO_YEARS_BONUS = 300; // 3%
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;
    /* solhint-enable ordering */
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Configuration contract reference (deprecated, use registry)
    OmniCoinConfig public config;
    
    /// @notice User stakes with privacy
    mapping(address => PrivateStake) public stakes;
    
    /// @notice Public participation scores for PoP consensus
    mapping(address => uint256) public participationScores;
    
    /// @notice Public tier information for efficient PoP calculations
    mapping(uint256 => TierInfo) public tierInfo;
    
    /// @notice List of active stakers for enumeration
    address[] public activeStakers;
    /// @notice Mapping from address to index in activeStakers array
    mapping(address => uint256) public stakerIndex;
    
    /// @notice Total number of active stakers
    uint256 public totalStakers;
    
    /// @notice Emergency pause for stake operations
    bool public stakingPaused;
    
    /// @notice MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    /// @notice Privacy fee manager contract address
    address public privacyFeeManager;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a private stake is created
     * @param user The user address
     * @param tier The staking tier
     * @param timestamp When the stake was created
     */
    event PrivateStakeCreated(address indexed user, uint256 indexed tier, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when a private stake is increased
     * @param user The user address
     * @param newTier The new staking tier
     * @param timestamp When the stake was increased
     */
    event PrivateStakeIncreased(address indexed user, uint256 indexed newTier, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when a private stake is decreased
     * @param user The user address
     * @param newTier The new staking tier
     * @param timestamp When the stake was decreased
     */
    event PrivateStakeDecreased(address indexed user, uint256 indexed newTier, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when a private stake is withdrawn
     * @param user The user address
     * @param timestamp When the stake was withdrawn
     */
    event PrivateStakeWithdrawn(address indexed user, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when private rewards are claimed
     * @param user The user address
     * @param timestamp When the rewards were claimed
     */
    event PrivateRewardsClaimed(address indexed user, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when participation score is updated
     * @param user The user address
     * @param oldScore The previous score
     * @param newScore The new score
     */
    event ParticipationScoreUpdated(address indexed user, uint256 indexed oldScore, uint256 indexed newScore);
    
    /**
     * @notice Emitted when tier info is updated
     * @param tier The tier index
     * @param totalStakers Total stakers in tier
     * @param totalWeight Total weight in tier
     */
    event TierInfoUpdated(uint256 indexed tier, uint256 indexed totalStakers, uint256 indexed totalWeight);
    
    /**
     * @notice Emitted when staking pause status changes
     * @param paused Whether staking is paused
     */
    event StakingPausedToggled(bool indexed paused);
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier whenStakingNotPaused() {
        if (stakingPaused) revert StakingDisabled();
        _;
    }
    
    modifier onlyActiveStaker(address user) {
        if (!stakes[user].isActive) revert NoActiveStake();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the staking contract
     * @param _registry Registry contract address
     * @param _config Configuration contract address (deprecated, use registry)
     * @param _admin Admin address
     * @param _privacyFeeManager Privacy fee manager address
     */
    constructor(
        address _registry,
        address _config,
        address _admin,
        address _privacyFeeManager
    ) RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidConfiguration();
        
        // Keep config for backwards compatibility
        if (_config != address(0)) {
            config = OmniCoinConfig(_config);
        }
        privacyFeeManager = _privacyFeeManager;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, _admin);
        
        stakingPaused = false;
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Default to false (Hardhat/testing mode)
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Set MPC availability status
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     * @param _available Whether MPC is available
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Set privacy fee manager address
     * @dev Set privacy fee manager
     * @param _privacyFeeManager The new privacy fee manager address
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyRole(ADMIN_ROLE) {
        if (_privacyFeeManager == address(0)) revert InvalidConfiguration();
        privacyFeeManager = _privacyFeeManager;
    }
    
    // =============================================================================
    // INTERNAL HELPERS FOR REGISTRY
    // =============================================================================
    
    /**
     * @notice Get config contract from registry
     * @dev Helper to get config contract
     * @return Configuration contract instance
     */
    function _getConfig() internal view returns (OmniCoinConfig) {
        if (address(config) != address(0)) {
            return config; // Backwards compatibility
        }
        address configAddr = _getContract(REGISTRY.OMNICOIN_CONFIG());
        return OmniCoinConfig(configAddr);
    }
    
    /**
     * @notice Get token contract based on privacy preference
     * @dev Helper to get appropriate token contract
     * @param usePrivacy Whether to use private token
     * @return Token contract address
     */
    function _getTokenContract(bool usePrivacy) internal returns (address) {
        if (usePrivacy) {
            return _getContract(REGISTRY.PRIVATE_OMNICOIN());
        } else {
            return _getContract(REGISTRY.OMNICOIN());
        }
    }
    
    // =============================================================================
    // STAKING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Stake tokens publicly (default, no privacy fees)
     * @dev Stake tokens publicly (default, no privacy fees)
     * @param amount Amount to stake
     */
    function stake(uint256 amount, uint256 duration) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        if (amount == 0) revert InvalidStakeAmount();
        _validateDuration(duration);
        
        // Transfer tokens using public OmniCoin
        address omniCoin = _getTokenContract(false);
        bool transferResult = IERC20(omniCoin).transferFrom(msg.sender, address(this), amount);
        if (!transferResult) revert TransferFailed();
        
        // Convert to garbled for internal processing
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        _stakeInternal(msg.sender, gtAmount, false, duration);
    }
    
    /**
     * @notice Stake tokens with privacy (premium feature)
     * @dev Stake tokens with privacy (premium feature)
     * @param amount Encrypted amount to stake
     * @param usePrivacy Whether to use privacy features
     */
    function stakeWithPrivacy(itUint64 calldata amount, bool usePrivacy, uint256 duration) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotEnabled();
        if (privacyFeeManager == address(0)) revert InvalidConfiguration();
        _validateDuration(duration);
        
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        
        // Validate amount > 0
        gtBool isPositive = MpcCore.gt(gtAmount, MpcCore.setPublic64(0));
        if (!MpcCore.decrypt(isPositive)) revert InvalidStakeAmount();
        
        // Calculate privacy fee (0.2% of stake amount for staking operations)
        uint256 stakingFeeRate = 20; // 0.2% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(stakingFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 fee = MpcCore.mul(gtAmount, feeRate);
        fee = MpcCore.div(fee, basisPointsGt);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("STAKING"),
            privacyFee
        );
        
        // Transfer tokens using PrivateOmniCoin
        // For privacy staking, we need to decrypt amount temporarily for transfer
        uint64 transferAmount = MpcCore.decrypt(gtAmount);
        address privateToken = _getTokenContract(true);
        bool transferResult = IERC20(privateToken).transferFrom(msg.sender, address(this), transferAmount);
        if (!transferResult) revert TransferFailed();
        
        _stakeInternal(msg.sender, gtAmount, true, duration);
    }
    
    /**
     * @notice Stake tokens with garbled amount (already encrypted)
     * @dev Stake tokens with garbled amount (already encrypted)
     * @param amount Garbled amount to stake
     */
    function stakeGarbled(gtUint64 amount, bool usePrivacy, uint256 duration) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        _validateDuration(duration);
        _stakeInternal(msg.sender, amount, usePrivacy, duration);
    }
    
    /**
     * @notice Internal staking logic
     * @dev Internal staking logic
     * @param user The user address
     * @param gtAmount The garbled amount to stake
     * @param usePrivacy Whether using PrivateOmniCoin
     */
    function _stakeInternal(address user, gtUint64 gtAmount, bool usePrivacy, uint256 duration) internal {
        // Decrypt amount to determine tier (this is the only time we decrypt)
        uint64 plaintextAmount;
        if (isMpcAvailable) {
            plaintextAmount = MpcCore.decrypt(gtAmount);
        } else {
            plaintextAmount = uint64(gtUint64.unwrap(gtAmount));
        }
        
        // Get staking tier based on amount
        uint256 tierIndex = _findStakingTierIndex(uint256(plaintextAmount));
        
        PrivateStake storage userStake = stakes[user];
        
        if (userStake.isActive) {
            // Update existing stake
            _updateExistingStake(user, gtAmount, tierIndex, usePrivacy);
        } else {
            // Create new stake
            _createNewStake(user, gtAmount, tierIndex, usePrivacy, duration);
        }
    }
    
    /**
     * @notice Create new stake entry
     * @dev Create new stake entry
     * @param user The user address
     * @param gtAmount The garbled amount to stake
     * @param tierIndex The staking tier index
     * @param usePrivacy Whether using PrivateOmniCoin
     */
    function _createNewStake(address user, gtUint64 gtAmount, uint256 tierIndex, bool usePrivacy, uint256 duration) internal {
        // Encrypt amount for user viewing
        ctUint64 userEncrypted;
        gtUint64 zeroRewards;
        ctUint64 userZeroRewards;
        
        if (isMpcAvailable) {
            userEncrypted = MpcCore.offBoardToUser(gtAmount, user);
            zeroRewards = MpcCore.setPublic64(0);
            userZeroRewards = MpcCore.offBoardToUser(MpcCore.setPublic64(0), user);
        } else {
            // Fallback
            uint64 amount = uint64(gtUint64.unwrap(gtAmount));
            userEncrypted = ctUint64.wrap(amount);
            zeroRewards = gtUint64.wrap(0);
            userZeroRewards = ctUint64.wrap(0);
        }
        
        stakes[user] = PrivateStake({
            encryptedAmount: gtAmount,
            userEncryptedAmount: userEncrypted,
            tier: tierIndex,
            startTime: block.timestamp,  // solhint-disable-line not-rely-on-time
            lastRewardTime: block.timestamp,  // solhint-disable-line not-rely-on-time
            commitmentDuration: duration,
            encryptedRewards: zeroRewards,
            userEncryptedRewards: userZeroRewards,
            isActive: true,
            usePrivacy: usePrivacy
        });
        
        // Add to active stakers list
        stakerIndex[user] = activeStakers.length;
        activeStakers.push(user);
        ++totalStakers;
        
        // Update tier information
        _updateTierInfo(tierIndex, gtAmount, true, false);
        
        emit PrivateStakeCreated(user, tierIndex, block.timestamp);  // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Update existing stake
     * @dev Update existing stake
     * @param user The user address
     * @param additionalAmount The additional garbled amount to stake
     * @param newTierIndex The new tier index
     * @param usePrivacy Whether using PrivateOmniCoin (must match existing)
     */
    function _updateExistingStake(address user, gtUint64 additionalAmount, uint256 newTierIndex, bool usePrivacy) internal {
        PrivateStake storage userStake = stakes[user];
        
        // Ensure privacy mode matches existing stake
        if (userStake.usePrivacy != usePrivacy) revert InvalidConfiguration();
        
        // Calculate and add pending rewards
        _updateRewards(user);
        
        // Update tier info (remove from old tier, add to new tier)
        uint256 oldTier = userStake.tier;
        if (oldTier != newTierIndex) {
            _updateTierInfo(oldTier, userStake.encryptedAmount, false, true);
        }
        
        // Update encrypted amounts
        if (isMpcAvailable) {
            userStake.encryptedAmount = MpcCore.add(userStake.encryptedAmount, additionalAmount);
            userStake.userEncryptedAmount = MpcCore.offBoardToUser(userStake.encryptedAmount, user);
        } else {
            // Fallback - add amounts directly
            uint64 currentAmount = uint64(gtUint64.unwrap(userStake.encryptedAmount));
            uint64 addAmount = uint64(gtUint64.unwrap(additionalAmount));
            uint64 newAmount = currentAmount + addAmount;
            userStake.encryptedAmount = gtUint64.wrap(newAmount);
            userStake.userEncryptedAmount = ctUint64.wrap(newAmount);
        }
        userStake.tier = newTierIndex;
        userStake.lastRewardTime = block.timestamp;  // solhint-disable-line not-rely-on-time
        
        // Update tier info with new amounts
        _updateTierInfo(newTierIndex, userStake.encryptedAmount, true, oldTier != newTierIndex);
        
        emit PrivateStakeIncreased(user, newTierIndex, block.timestamp);  // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // UNSTAKING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Unstake tokens publicly (default, no privacy fees)
     * @dev Unstake tokens publicly (default, no privacy fees)
     * @param amount Amount to unstake
     */
    function unstake(uint256 amount) 
        external 
        whenNotPaused 
        onlyActiveStaker(msg.sender) 
        nonReentrant 
    {
        if (amount == 0) revert InvalidStakeAmount();
        
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        _unstakeInternal(msg.sender, gtAmount);
    }
    
    /**
     * @notice Unstake tokens with privacy (premium feature)
     * @dev Unstake tokens with privacy (premium feature)
     * @param amount Encrypted amount to unstake
     * @param usePrivacy Whether to use privacy features
     */
    function unstakeWithPrivacy(itUint64 calldata amount, bool usePrivacy) 
        external 
        whenNotPaused 
        onlyActiveStaker(msg.sender) 
        nonReentrant 
    {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotEnabled();
        if (privacyFeeManager == address(0)) revert InvalidConfiguration();
        
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        
        // Validate amount > 0
        gtBool isPositive = MpcCore.gt(gtAmount, MpcCore.setPublic64(0));
        if (!MpcCore.decrypt(isPositive)) revert InvalidStakeAmount();
        
        // Calculate privacy fee for unstaking
        uint256 stakingFeeRate = 20; // 0.2% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(stakingFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 fee = MpcCore.mul(gtAmount, feeRate);
        fee = MpcCore.div(fee, basisPointsGt);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("STAKING"),
            privacyFee
        );
        
        _unstakeInternal(msg.sender, gtAmount);
    }
    
    /**
     * @notice Unstake tokens with garbled amount
     * @dev Unstake tokens with garbled amount
     * @param amount Garbled amount to unstake
     */
    function unstakeGarbled(gtUint64 amount) 
        external 
        whenNotPaused 
        onlyActiveStaker(msg.sender) 
        nonReentrant 
    {
        _unstakeInternal(msg.sender, amount);
    }
    
    /**
     * @notice Internal unstaking logic
     * @dev Internal unstaking logic
     * @param user The user address
     * @param gtAmount The garbled amount to unstake
     */
    function _unstakeInternal(address user, gtUint64 gtAmount) internal {
        PrivateStake storage userStake = stakes[user];
        
        // Verify user has enough staked (using MPC comparison)
        if (isMpcAvailable) {
            gtBool hasEnough = MpcCore.ge(userStake.encryptedAmount, gtAmount);
            if (!MpcCore.decrypt(hasEnough)) revert InsufficientStake();
        } else {
            // Fallback comparison
            uint64 currentStake = uint64(gtUint64.unwrap(userStake.encryptedAmount));
            uint64 requestedAmount = uint64(gtUint64.unwrap(gtAmount));
            if (currentStake < requestedAmount) revert InsufficientStake();
        }
        
        // Calculate and add pending rewards
        _updateRewards(user);
        
        // Get current staking tier for penalty calculation
        uint64 plaintextAmount;
        if (isMpcAvailable) {
            plaintextAmount = MpcCore.decrypt(gtAmount);
        } else {
            plaintextAmount = uint64(gtUint64.unwrap(gtAmount));
        }
        OmniCoinConfig.StakingTier memory stakingTier = _getConfig().getStakingTier(uint256(plaintextAmount));
        
        // Calculate penalty if within lock period
        gtUint64 penalty = _calculatePenalty(user, gtAmount, stakingTier);
        gtUint64 netAmount;
        
        if (isMpcAvailable) {
            netAmount = MpcCore.sub(gtAmount, penalty);
            // Update stake
            userStake.encryptedAmount = MpcCore.sub(userStake.encryptedAmount, gtAmount);
        } else {
            // Fallback calculations
            uint64 penaltyAmount = uint64(gtUint64.unwrap(penalty));
            uint64 requestedAmount = uint64(gtUint64.unwrap(gtAmount));
            uint64 netAmountValue = requestedAmount - penaltyAmount;
            netAmount = gtUint64.wrap(netAmountValue);
            
            // Update stake
            uint64 currentStake = uint64(gtUint64.unwrap(userStake.encryptedAmount));
            userStake.encryptedAmount = gtUint64.wrap(currentStake - requestedAmount);
        }
        
        if (isMpcAvailable) {
            userStake.userEncryptedAmount = MpcCore.offBoardToUser(userStake.encryptedAmount, user);
        } else {
            uint64 currentAmount = uint64(gtUint64.unwrap(userStake.encryptedAmount));
            userStake.userEncryptedAmount = ctUint64.wrap(currentAmount);
        }
        userStake.lastRewardTime = block.timestamp;  // solhint-disable-line not-rely-on-time
        
        // Check if stake becomes zero
        bool isZero;
        uint64 remainingAmount;
        
        if (isMpcAvailable) {
            gtBool isZeroGt = MpcCore.eq(userStake.encryptedAmount, MpcCore.setPublic64(0));
            isZero = MpcCore.decrypt(isZeroGt);
            remainingAmount = MpcCore.decrypt(userStake.encryptedAmount);
        } else {
            remainingAmount = uint64(gtUint64.unwrap(userStake.encryptedAmount));
            isZero = (remainingAmount == 0);
        }
        
        if (isZero) {
            _removeStaker(user);
        } else {
            // Update tier if necessary
            uint256 newTier = _findStakingTierIndex(uint256(remainingAmount));
            if (newTier != userStake.tier) {
                _updateTierInfo(userStake.tier, userStake.encryptedAmount, false, true);
                userStake.tier = newTier;
                _updateTierInfo(newTier, userStake.encryptedAmount, true, false);
            }
        }
        
        // Process token transfers
        _processUnstakeTransfer(user, netAmount, penalty, userStake.usePrivacy);
        
        emit PrivateStakeDecreased(user, userStake.tier, block.timestamp);  // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // REWARD FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Claim accumulated rewards
     * @dev Claim accumulated rewards
     */
    function claimRewards() 
        external 
        whenNotPaused 
        onlyActiveStaker(msg.sender) 
        nonReentrant 
    {
        _updateRewards(msg.sender);
        
        PrivateStake storage userStake = stakes[msg.sender];
        gtUint64 rewards = userStake.encryptedRewards;
        
        // Check if there are rewards to claim
        if (isMpcAvailable) {
            gtBool hasRewards = MpcCore.gt(rewards, MpcCore.setPublic64(0));
            if (!MpcCore.decrypt(hasRewards)) revert InvalidStakeAmount();
            
            // Reset rewards
            userStake.encryptedRewards = MpcCore.setPublic64(0);
            userStake.userEncryptedRewards = MpcCore.offBoardToUser(MpcCore.setPublic64(0), msg.sender);
        } else {
            // Fallback - check rewards
            uint64 rewardAmountCheck = uint64(gtUint64.unwrap(rewards));
            if (rewardAmountCheck == 0) revert InvalidStakeAmount();
            
            // Reset rewards
            userStake.encryptedRewards = gtUint64.wrap(0);
            userStake.userEncryptedRewards = ctUint64.wrap(0);
        }
        
        // Transfer rewards using the same token type as staked
        address tokenContract = _getTokenContract(userStake.usePrivacy);
        uint64 rewardAmount = uint64(gtUint64.unwrap(rewards));
        bool rewardTransferResult = IERC20(tokenContract).transfer(msg.sender, uint256(rewardAmount));
        if (!rewardTransferResult) revert TransferFailed();
        
        emit PrivateRewardsClaimed(msg.sender, block.timestamp);  // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Update rewards for a user (internal)
     * @dev Update rewards for a user (internal)
     * @param user The user address
     */
    function _updateRewards(address user) internal {
        PrivateStake storage userStake = stakes[user];
        if (!userStake.isActive) return;
        
        // Calculate time since last reward update
        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;  // solhint-disable-line not-rely-on-time
        if (timeElapsed == 0) return;
        
        // Get staking configuration by reconstructing the tier from stored data
        // We need to determine the current amount to get proper tier information
        uint64 currentAmount;
        if (isMpcAvailable) {
            currentAmount = MpcCore.decrypt(userStake.encryptedAmount);
        } else {
            currentAmount = uint64(gtUint64.unwrap(userStake.encryptedAmount));
        }
        OmniCoinConfig.StakingTier memory stakingTier = _getConfig().getStakingTier(uint256(currentAmount));
        
        // Calculate base rewards using encrypted amounts with duration bonus
        uint256 effectiveRewardRate = _getEffectiveRewardRate(stakingTier.rewardRate, userStake.commitmentDuration);
        gtUint64 baseReward = _calculateBaseReward(userStake.encryptedAmount, effectiveRewardRate, timeElapsed);
        
        // Apply participation score multiplier if enabled
        if (_getConfig().useParticipationScore()) {
            uint256 participationScore = participationScores[user];
            if (participationScore > 0) {
                if (isMpcAvailable) {
                    gtUint64 multiplier = MpcCore.setPublic64(uint64(participationScore));
                    baseReward = MpcCore.mul(baseReward, multiplier);
                    baseReward = MpcCore.div(baseReward, MpcCore.setPublic64(100)); // Divide by 100 for percentage
                } else {
                    // Fallback calculation
                    uint64 baseRewardAmount = uint64(gtUint64.unwrap(baseReward));
                    baseRewardAmount = (baseRewardAmount * uint64(participationScore)) / 100;
                    baseReward = gtUint64.wrap(baseRewardAmount);
                }
            }
        }
        
        // Add to accumulated rewards
        if (isMpcAvailable) {
            userStake.encryptedRewards = MpcCore.add(userStake.encryptedRewards, baseReward);
            userStake.userEncryptedRewards = MpcCore.offBoardToUser(userStake.encryptedRewards, user);
        } else {
            // Fallback - add rewards directly
            uint64 currentRewards = uint64(gtUint64.unwrap(userStake.encryptedRewards));
            uint64 newRewardAmount = uint64(gtUint64.unwrap(baseReward));
            uint64 totalRewards = currentRewards + newRewardAmount;
            userStake.encryptedRewards = gtUint64.wrap(totalRewards);
            userStake.userEncryptedRewards = ctUint64.wrap(totalRewards);
        }
        userStake.lastRewardTime = block.timestamp;  // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update participation score for PoP calculations
     * @dev Update participation score for PoP calculations
     * @param user User address
     * @param score New participation score (0-100)
     */
    function updateParticipationScore(address user, uint256 score) 
        external 
        onlyRole(VALIDATOR_ROLE) 
    {
        if (score > 100) revert InvalidBasisPoints();
        
        uint256 oldScore = participationScores[user];
        participationScores[user] = score;
        
        emit ParticipationScoreUpdated(user, oldScore, score);
    }
    
    /**
     * @notice Toggle staking pause state
     * @dev Toggle staking pause state
     */
    function toggleStakingPause() external onlyRole(ADMIN_ROLE) {
        stakingPaused = !stakingPaused;
        emit StakingPausedToggled(stakingPaused);
    }
    
    /**
     * @notice Emergency pause all operations
     * @dev Emergency pause all operations
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause all operations
     * @dev Unpause all operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS (PUBLIC DATA FOR PoP)
    // =============================================================================
    
    /**
     * @notice Get public stake information for PoP calculations
     * @dev Get public stake information for PoP calculations
     * @param user User address
     * @return tier Staking tier (public)
     * @return participationScore Participation score (public)
     * @return isActive Whether stake is active (public)
     * @return startTime Stake start time (public)
     */
    function getPublicStakeInfo(address user) 
        external 
        view 
        returns (
            uint256 tier,
            uint256 participationScore,
            bool isActive,
            uint256 startTime
        ) 
    {
        PrivateStake storage userStake = stakes[user];
        return (
            userStake.tier,
            participationScores[user],
            userStake.isActive,
            userStake.startTime
        );
    }
    
    /**
     * @notice Get encrypted stake information for user
     * @dev Get encrypted stake information for user
     * @param user User address
     * @return userEncryptedAmount Encrypted amount visible to user
     * @return userEncryptedRewards Encrypted rewards visible to user
     */
    function getPrivateStakeInfo(address user) 
        external 
        view 
        returns (
            ctUint64 userEncryptedAmount,
            ctUint64 userEncryptedRewards
        ) 
    {
        PrivateStake storage userStake = stakes[user];
        return (
            userStake.userEncryptedAmount,
            userStake.userEncryptedRewards
        );
    }
    
    /**
     * @notice Get tier information for PoP calculations
     * @dev Get tier information for PoP calculations
     * @param tier Tier index
     * @return tierTotalStakers Number of stakers in tier (public)
     * @return tierTotalWeight Total weight for PoP (public)
     */
    function getTierInfo(uint256 tier) 
        external 
        view 
        returns (
            uint256 tierTotalStakers,
            uint256 tierTotalWeight
        ) 
    {
        TierInfo storage info = tierInfo[tier];
        return (
            info.totalStakers,
            info.totalTierWeight
        );
    }
    
    /**
     * @notice Get list of active stakers for PoP enumeration
     * @dev Get list of active stakers for PoP enumeration
     * @return List of active staker addresses
     */
    function getActiveStakers() external view returns (address[] memory) {
        return activeStakers;
    }
    
    // =============================================================================
    // INTERNAL HELPER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Validate staking duration
     * @dev Validates that the duration is one of the allowed values
     * @param duration The commitment duration to validate
     */
    function _validateDuration(uint256 duration) internal pure {
        if (
            duration != 0 &&
            duration != ONE_MONTH &&
            duration != SIX_MONTHS &&
            duration != TWO_YEARS
        ) {
            revert InvalidDuration();
        }
    }
    
    /**
     * @notice Get effective reward rate including duration bonus
     * @dev Calculates the total reward rate by adding base rate and duration bonus
     * @param baseRate The base reward rate from staking tier
     * @param duration The commitment duration
     * @return The effective reward rate including bonus
     */
    function _getEffectiveRewardRate(uint256 baseRate, uint256 duration) internal pure returns (uint256) {
        uint256 bonus = 0;
        
        if (duration == ONE_MONTH) {
            bonus = ONE_MONTH_BONUS;
        } else if (duration == SIX_MONTHS) {
            bonus = SIX_MONTHS_BONUS;
        } else if (duration == TWO_YEARS) {
            bonus = TWO_YEARS_BONUS;
        }
        
        // Add bonus to base rate (both are in percentage points)
        return baseRate + bonus;
    }

    /**
     * @notice Process token transfer for unstaking
     * @dev Helper function to handle token transfers during unstaking
     * @param user The user address
     * @param netAmount The net amount to transfer
     * @param penalty The penalty amount
     * @param usePrivacy Whether using PrivateOmniCoin
     */
    function _processUnstakeTransfer(address user, gtUint64 netAmount, gtUint64 penalty, bool usePrivacy) internal {
        // Get appropriate token contract
        address tokenContract = _getTokenContract(usePrivacy);
        address treasuryAddr = _getContract(REGISTRY.TREASURY());
        
        // Transfer tokens back to user
        uint64 netAmountValue = uint64(gtUint64.unwrap(netAmount));
        bool transferResult = IERC20(tokenContract).transfer(user, uint256(netAmountValue));
        if (!transferResult) revert TransferFailed();
        
        // Transfer penalty to treasury if applicable
        uint64 penaltyAmount = uint64(gtUint64.unwrap(penalty));
        if (penaltyAmount > 0 && treasuryAddr != address(0)) {
            bool penaltyTransferResult = IERC20(tokenContract).transfer(treasuryAddr, uint256(penaltyAmount));
            if (!penaltyTransferResult) revert TransferFailed();
        }
    }
    
    /**
     * @notice Calculate base reward using encrypted arithmetic
     * @dev Calculate base reward using encrypted arithmetic
     * @param encryptedAmount The encrypted stake amount
     * @param rewardRate The reward rate
     * @param timeElapsed Time elapsed since last reward
     * @return The calculated base reward
     */
    function _calculateBaseReward(gtUint64 encryptedAmount, uint256 rewardRate, uint256 timeElapsed) 
        internal 
        returns (gtUint64) 
    {
        if (isMpcAvailable) {
            // Convert reward rate to encrypted value
            gtUint64 rate = MpcCore.setPublic64(uint64(rewardRate));
            gtUint64 time = MpcCore.setPublic64(uint64(timeElapsed));
            gtUint64 yearInSeconds = MpcCore.setPublic64(365 * 24 * 60 * 60);
            gtUint64 hundred = MpcCore.setPublic64(100);
            
            // Calculate: (amount * rate * time) / (365 * 24 * 60 * 60 * 100)
            gtUint64 numerator = MpcCore.mul(encryptedAmount, rate);
            numerator = MpcCore.mul(numerator, time);
            
            gtUint64 denominator = MpcCore.mul(yearInSeconds, hundred);
            
            return MpcCore.div(numerator, denominator);
        } else {
            // Fallback calculation
            uint64 amount = uint64(gtUint64.unwrap(encryptedAmount));
            uint64 reward = (amount * uint64(rewardRate) * uint64(timeElapsed)) / (365 * 24 * 60 * 60 * 100);
            return gtUint64.wrap(reward);
        }
    }
    
    /**
     * @notice Calculate penalty for early unstaking
     * @dev Calculate penalty for early unstaking
     * @param user The user address
     * @param amount The amount being unstaked
     * @param tier The staking tier configuration
     * @return The penalty amount
     */
    function _calculatePenalty(address user, gtUint64 amount, OmniCoinConfig.StakingTier memory tier) 
        internal 
        returns (gtUint64) 
    {
        PrivateStake storage userStake = stakes[user];
        
        // Check if within commitment period or tier lock period
        uint256 effectiveLockPeriod = tier.lockPeriod > userStake.commitmentDuration ? 
            tier.lockPeriod : userStake.commitmentDuration;
            
        if (block.timestamp > userStake.startTime + effectiveLockPeriod - 1) {  // solhint-disable-line not-rely-on-time
            if (isMpcAvailable) {
                return MpcCore.setPublic64(0); // No penalty
            } else {
                return gtUint64.wrap(0);
            }
        }
        
        if (isMpcAvailable) {
            // Calculate penalty: (amount * penaltyRate) / 100
            gtUint64 penaltyRate = MpcCore.setPublic64(uint64(tier.penaltyRate));
            gtUint64 hundred = MpcCore.setPublic64(100);
            
            gtUint64 penalty = MpcCore.mul(amount, penaltyRate);
            return MpcCore.div(penalty, hundred);
        } else {
            // Fallback calculation
            uint64 amountValue = uint64(gtUint64.unwrap(amount));
            uint64 penaltyValue = (amountValue * uint64(tier.penaltyRate)) / 100;
            return gtUint64.wrap(penaltyValue);
        }
    }
    
    /**
     * @notice Update tier information for PoP calculations
     * @dev Update tier information for PoP calculations
     * @param tierIndex The tier index
     * @param amount The stake amount
     * @param isAdding Whether adding to tier
     * @param isRemoving Whether removing from tier
     */
    function _updateTierInfo(uint256 tierIndex, gtUint64 amount, bool isAdding, bool isRemoving) internal {
        TierInfo storage tier = tierInfo[tierIndex];
        
        if (isAdding && !isRemoving) {
            // New staker in this tier
            ++tier.totalStakers;
            if (isMpcAvailable) {
                tier.totalEncryptedAmount = MpcCore.add(tier.totalEncryptedAmount, amount);
            } else {
                uint64 currentTotal = uint64(gtUint64.unwrap(tier.totalEncryptedAmount));
                uint64 addAmount = uint64(gtUint64.unwrap(amount));
                tier.totalEncryptedAmount = gtUint64.wrap(currentTotal + addAmount);
            }
        } else if (!isAdding && isRemoving) {
            // Staker leaving this tier
            if (tier.totalStakers > 0) {
                --tier.totalStakers;
                if (isMpcAvailable) {
                    tier.totalEncryptedAmount = MpcCore.sub(tier.totalEncryptedAmount, amount);
                } else {
                    uint64 currentTotal = uint64(gtUint64.unwrap(tier.totalEncryptedAmount));
                    uint64 subAmount = uint64(gtUint64.unwrap(amount));
                    tier.totalEncryptedAmount = gtUint64.wrap(currentTotal - subAmount);
                }
            }
        } else if (isAdding && isRemoving) {
            // Staker changing tiers (update amount only)
            if (isMpcAvailable) {
                tier.totalEncryptedAmount = MpcCore.add(tier.totalEncryptedAmount, amount);
            } else {
                uint64 currentTotal = uint64(gtUint64.unwrap(tier.totalEncryptedAmount));
                uint64 addAmount = uint64(gtUint64.unwrap(amount));
                tier.totalEncryptedAmount = gtUint64.wrap(currentTotal + addAmount);
            }
        }
        
        // Update tier weight (can be based on tier level and staker count)
        tier.totalTierWeight = tier.totalStakers * (tierIndex + 1); // Simple weight calculation
        
        emit TierInfoUpdated(tierIndex, tier.totalStakers, tier.totalTierWeight);
    }
    
    /**
     * @notice Remove staker from active list
     * @dev Remove staker from active list
     * @param user The user address
     */
    function _removeStaker(address user) internal {
        uint256 index = stakerIndex[user];
        uint256 lastIndex = activeStakers.length - 1;
        
        if (index != lastIndex) {
            address lastStaker = activeStakers[lastIndex];
            activeStakers[index] = lastStaker;
            stakerIndex[lastStaker] = index;
        }
        
        activeStakers.pop();
        delete stakerIndex[user];
        
        // Update stake info
        PrivateStake storage userStake = stakes[user];
        _updateTierInfo(userStake.tier, userStake.encryptedAmount, false, true);
        userStake.isActive = false;
        
        --totalStakers;
        
        emit PrivateStakeWithdrawn(user, block.timestamp);  // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Find staking tier index based on amount
     * @dev Find staking tier index based on amount
     * @param amount The stake amount
     * @return The tier index
     */
    function _findStakingTierIndex(uint256 amount) internal view returns (uint256) {
        try _getConfig().getStakingTier(amount) returns (OmniCoinConfig.StakingTier memory tier) {
            // Find matching tier index
            for (uint256 i = 0; i < 3; ++i) {
                try _getConfig().stakingTiers(i) returns (
                    uint256 minAmount,
                    uint256 maxAmount,
                    uint256,
                    uint256,
                    uint256
                ) {
                    if (minAmount == tier.minAmount && maxAmount == tier.maxAmount) {
                        return i;
                    }
                } catch {
                    break;
                }
            }
        } catch {
            return 0; // Default to tier 0
        }
        
        return 0;
    }
}