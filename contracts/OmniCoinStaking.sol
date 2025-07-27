// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MpcCore, gtUint64, ctUint64, itUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinConfig} from "./OmniCoinConfig.sol";
import {OmniCoinCore} from "./OmniCoinCore.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinStaking
 * @dev Privacy-enabled staking contract using COTI V2 MPC for encrypted stake amounts
 * 
 * Hybrid Privacy Approach:
 * - Encrypted stake amounts for privacy
 * - Public tier levels for Proof of Participation calculations
 * - Public participation scores for consensus weight
 * - Private reward calculations with public distribution
 */
contract OmniCoinStaking is AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivateStake {
        gtUint64 encryptedAmount;       // Private: actual stake amount (encrypted)
        ctUint64 userEncryptedAmount;   // Private: amount encrypted for user viewing
        uint256 tier;                   // Public: staking tier for PoP calculations
        uint256 startTime;              // Public: when stake was created
        uint256 lastRewardTime;         // Public: last reward calculation time
        gtUint64 encryptedRewards;      // Private: accumulated rewards (encrypted)
        ctUint64 userEncryptedRewards;  // Private: rewards encrypted for user viewing
        bool isActive;                  // Public: whether stake is active
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
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    OmniCoinConfig public config;
    OmniCoinCore public token;
    
    /// @dev User stakes with privacy
    mapping(address => PrivateStake) public stakes;
    
    /// @dev Public participation scores for PoP consensus
    mapping(address => uint256) public participationScores;
    
    /// @dev Public tier information for efficient PoP calculations
    mapping(uint256 => TierInfo) public tierInfo;
    
    /// @dev List of active stakers for enumeration
    address[] public activeStakers;
    mapping(address => uint256) public stakerIndex;
    
    /// @dev Total number of active stakers
    uint256 public totalStakers;
    
    /// @dev Emergency pause for stake operations
    bool public stakingPaused;
    
    /// @dev MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    /// @dev Privacy fee configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    address public privacyFeeManager;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event PrivateStakeCreated(address indexed user, uint256 tier, uint256 timestamp);
    event PrivateStakeIncreased(address indexed user, uint256 newTier, uint256 timestamp);
    event PrivateStakeDecreased(address indexed user, uint256 newTier, uint256 timestamp);
    event PrivateStakeWithdrawn(address indexed user, uint256 timestamp);
    event PrivateRewardsClaimed(address indexed user, uint256 timestamp);
    event ParticipationScoreUpdated(address indexed user, uint256 oldScore, uint256 newScore);
    event TierInfoUpdated(uint256 indexed tier, uint256 totalStakers, uint256 totalWeight);
    event StakingPausedToggled(bool paused);
    
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
    
    constructor(
        address _config,
        address _token,
        address _admin,
        address _privacyFeeManager
    ) {
        if (_config == address(0)) revert InvalidConfiguration();
        if (_token == address(0)) revert InvalidConfiguration();
        if (_admin == address(0)) revert InvalidConfiguration();
        
        config = OmniCoinConfig(_config);
        token = OmniCoinCore(_token);
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
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyRole(ADMIN_ROLE) {
        if (_privacyFeeManager == address(0)) revert InvalidConfiguration();
        privacyFeeManager = _privacyFeeManager;
    }
    
    // =============================================================================
    // STAKING FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Stake tokens publicly (default, no privacy fees)
     * @param amount Amount to stake
     */
    function stake(uint256 amount) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        if (amount == 0) revert InvalidStakeAmount();
        
        // Transfer tokens using public method
        bool transferResult = token.transferFromPublic(msg.sender, address(this), amount);
        if (!transferResult) revert TransferFailed();
        
        // Convert to garbled for internal processing
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        _stakeInternal(msg.sender, gtAmount);
    }
    
    /**
     * @dev Stake tokens with privacy (premium feature)
     * @param amount Encrypted amount to stake
     * @param usePrivacy Whether to use privacy features
     */
    function stakeWithPrivacy(itUint64 calldata amount, bool usePrivacy) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotEnabled();
        if (privacyFeeManager == address(0)) revert InvalidConfiguration();
        
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
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("STAKING"),
            privacyFee
        );
        
        // Transfer tokens using private method
        gtBool transferResult = token.transferFrom(msg.sender, address(this), gtAmount);
        if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
        
        _stakeInternal(msg.sender, gtAmount);
    }
    
    /**
     * @dev Stake tokens with garbled amount (already encrypted)
     * @param amount Garbled amount to stake
     */
    function stakeGarbled(gtUint64 amount) 
        external 
        whenNotPaused 
        whenStakingNotPaused 
        nonReentrant 
    {
        _stakeInternal(msg.sender, amount);
    }
    
    /**
     * @dev Internal staking logic
     */
    function _stakeInternal(address user, gtUint64 gtAmount) internal {
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
            _updateExistingStake(user, gtAmount, tierIndex);
        } else {
            // Create new stake
            _createNewStake(user, gtAmount, tierIndex);
        }
    }
    
    /**
     * @dev Create new stake entry
     */
    function _createNewStake(address user, gtUint64 gtAmount, uint256 tierIndex) internal {
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
            startTime: block.timestamp,
            lastRewardTime: block.timestamp,
            encryptedRewards: zeroRewards,
            userEncryptedRewards: userZeroRewards,
            isActive: true
        });
        
        // Add to active stakers list
        stakerIndex[user] = activeStakers.length;
        activeStakers.push(user);
        totalStakers++;
        
        // Update tier information
        _updateTierInfo(tierIndex, gtAmount, true, false);
        
        emit PrivateStakeCreated(user, tierIndex, block.timestamp);
    }
    
    /**
     * @dev Update existing stake
     */
    function _updateExistingStake(address user, gtUint64 additionalAmount, uint256 newTierIndex) internal {
        PrivateStake storage userStake = stakes[user];
        
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
        userStake.lastRewardTime = block.timestamp;
        
        // Update tier info with new amounts
        _updateTierInfo(newTierIndex, userStake.encryptedAmount, true, oldTier != newTierIndex);
        
        emit PrivateStakeIncreased(user, newTierIndex, block.timestamp);
    }
    
    // =============================================================================
    // UNSTAKING FUNCTIONS
    // =============================================================================
    
    /**
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
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("STAKING"),
            privacyFee
        );
        
        _unstakeInternal(msg.sender, gtAmount);
    }
    
    /**
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
     * @dev Internal unstaking logic
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
        OmniCoinConfig.StakingTier memory stakingTier = config.getStakingTier(uint256(plaintextAmount));
        
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
        userStake.lastRewardTime = block.timestamp;
        
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
        
        // Transfer tokens back to user
        if (isMpcAvailable) {
            gtBool transferResult = token.transferGarbled(user, netAmount);
            if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
        } else {
            // For public unstaking, use public transfer
            uint64 netAmountValue = uint64(gtUint64.unwrap(netAmount));
            bool transferResult = token.transferPublic(user, uint256(netAmountValue));
            if (!transferResult) revert TransferFailed();
        }
        
        // Transfer penalty to treasury if applicable
        if (isMpcAvailable) {
            gtBool hasPenalty = MpcCore.gt(penalty, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasPenalty)) {
                gtBool penaltyTransferResult = token.transferGarbled(token.treasuryContract(), penalty);
                if (!MpcCore.decrypt(penaltyTransferResult)) revert TransferFailed();
            }
        } else {
            // Fallback - check penalty amount
            uint64 penaltyAmount = uint64(gtUint64.unwrap(penalty));
            if (penaltyAmount > 0) {
                bool penaltyTransferResult = token.transferPublic(token.treasuryContract(), uint256(penaltyAmount));
                if (!penaltyTransferResult) revert TransferFailed();
            }
        }
        
        emit PrivateStakeDecreased(user, userStake.tier, block.timestamp);
    }
    
    // =============================================================================
    // REWARD FUNCTIONS
    // =============================================================================
    
    /**
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
            uint64 rewardAmount = uint64(gtUint64.unwrap(rewards));
            if (rewardAmount == 0) revert InvalidStakeAmount();
            
            // Reset rewards
            userStake.encryptedRewards = gtUint64.wrap(0);
            userStake.userEncryptedRewards = ctUint64.wrap(0);
        }
        
        // Transfer rewards
        if (isMpcAvailable) {
            gtBool rewardTransferResult = token.transferGarbled(msg.sender, rewards);
            if (!MpcCore.decrypt(rewardTransferResult)) revert TransferFailed();
        } else {
            // For public rewards, use public transfer
            uint64 rewardAmount = uint64(gtUint64.unwrap(rewards));
            bool rewardTransferResult = token.transferPublic(msg.sender, uint256(rewardAmount));
            if (!rewardTransferResult) revert TransferFailed();
        }
        
        emit PrivateRewardsClaimed(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Update rewards for a user (internal)
     */
    function _updateRewards(address user) internal {
        PrivateStake storage userStake = stakes[user];
        if (!userStake.isActive) return;
        
        // Calculate time since last reward update
        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;
        if (timeElapsed == 0) return;
        
        // Get staking configuration by reconstructing the tier from stored data
        // We need to determine the current amount to get proper tier information
        uint64 currentAmount;
        if (isMpcAvailable) {
            currentAmount = MpcCore.decrypt(userStake.encryptedAmount);
        } else {
            currentAmount = uint64(gtUint64.unwrap(userStake.encryptedAmount));
        }
        OmniCoinConfig.StakingTier memory stakingTier = config.getStakingTier(uint256(currentAmount));
        
        // Calculate base rewards using encrypted amounts
        gtUint64 baseReward = _calculateBaseReward(userStake.encryptedAmount, stakingTier.rewardRate, timeElapsed);
        
        // Apply participation score multiplier if enabled
        if (config.useParticipationScore()) {
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
        userStake.lastRewardTime = block.timestamp;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
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
     * @dev Toggle staking pause state
     */
    function toggleStakingPause() external onlyRole(ADMIN_ROLE) {
        stakingPaused = !stakingPaused;
        emit StakingPausedToggled(stakingPaused);
    }
    
    /**
     * @dev Emergency pause all operations
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause all operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS (PUBLIC DATA FOR PoP)
    // =============================================================================
    
    /**
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
     * @dev Calculate base reward using encrypted arithmetic
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
     * @dev Calculate penalty for early unstaking
     */
    function _calculatePenalty(address user, gtUint64 amount, OmniCoinConfig.StakingTier memory tier) 
        internal 
        returns (gtUint64) 
    {
        PrivateStake storage userStake = stakes[user];
        
        // Check if within lock period
        if (block.timestamp >= userStake.startTime + tier.lockPeriod) {
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
     * @dev Update tier information for PoP calculations
     */
    function _updateTierInfo(uint256 tierIndex, gtUint64 amount, bool isAdding, bool isRemoving) internal {
        TierInfo storage tier = tierInfo[tierIndex];
        
        if (isAdding && !isRemoving) {
            // New staker in this tier
            tier.totalStakers++;
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
                tier.totalStakers--;
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
     * @dev Remove staker from active list
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
        
        totalStakers--;
        
        emit PrivateStakeWithdrawn(user, block.timestamp);
    }
    
    /**
     * @dev Find staking tier index based on amount
     */
    function _findStakingTierIndex(uint256 amount) internal view returns (uint256) {
        try config.getStakingTier(amount) returns (OmniCoinConfig.StakingTier memory tier) {
            // Find matching tier index
            for (uint256 i = 0; i < 3; i++) {
                try config.stakingTiers(i) returns (
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