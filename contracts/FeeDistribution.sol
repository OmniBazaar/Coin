// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MpcCore, gtBool, gtUint64, ctBool, ctUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";

/**
 * @title FeeDistribution
 * @author OmniCoin Development Team
 * @notice Automated fee distribution system for unified validators
 * @dev Implements a transparent fee distribution mechanism with privacy options
 *
 * Distribution model:
 * - 70% to validators (based on participation scores)
 * - 20% to company treasury
 * - 10% to development fund
 *
 * Features:
 * - Automatic periodic distribution
 * - Participation-based validator rewards
 * - Revenue tracking and analytics
 * - Multiple fee source support
 * - Transparent distribution history
 */
contract FeeDistribution is RegistryAware, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Enums
    enum FeeSource {
        TRADING,
        PERPETUAL_FUTURES,
        AUTO_CONVERSION,
        MARKETPLACE,
        CHAT_PREMIUM,
        IPFS_STORAGE,
        BLOCK_REWARDS,
        BRIDGING,
        STAKING_REWARDS
    }

    // Structs
    struct DistributionRatio {
        uint256 validatorShare; // 7000 = 70%
        uint256 companyShare; // 2000 = 20%
        uint256 developmentShare; // 1000 = 10%
    }

    struct FeeCollection {
        address token;
        uint256 amount;
        FeeSource source;
        uint256 timestamp;
        address collector;
    }

    struct Distribution {
        uint256 id;
        uint256 totalAmount;
        uint256 validatorShare;
        uint256 companyShare;
        uint256 developmentShare;
        uint256 timestamp;
        uint256 validatorCount;
        bool completed;
        mapping(address => ValidatorDistribution) validatorDistributions;
    }

    struct ValidatorDistribution {
        uint256 amount;
        bool claimed;
        uint256 claimTime;
        uint256 participationScore;
        ctUint64 privateAmount;
        ctBool privateClaimed;
    }
    
    struct RevenueMetrics {
        uint256 totalFeesCollected;
        uint256 totalDistributed;
        uint256 totalValidatorRewards;
        uint256 totalCompanyRevenue;
        uint256 totalDevelopmentFunding;
        uint256 distributionCount;
        uint256 lastDistributionTime;
    }
    
    struct TreasuryAddresses {
        address companyTreasury;
        address developmentFund;
    }

    struct ValidatorInfo {
        address validatorAddress;     // 20 bytes
        bool isActive;                // 1 byte
        ctUint64 privateRewardBalance; // 32 bytes (packed)
        ctUint64 privateTotalRewards;  // 32 bytes
        ctUint64 privateStakeAmount;   // 32 bytes
        uint256 participationScore;    // 32 bytes
        uint256 totalEarned;          // 32 bytes
        uint256 pendingRewards;       // 32 bytes
        uint256 lastUpdateTime;       // 32 bytes
        uint256 totalRewardsClaimed;  // 32 bytes
        uint256 lastClaimTime;        // 32 bytes
        mapping(address => uint256) tokenBalances;
    }

    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Role for fee collectors
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    /// @notice Role for distribution managers
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    /// @notice Role for treasury management
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDistribution();
    error NoFeesPending();
    error NotAuthorized();
    error AlreadyClaimed();
    error DistributionNotComplete();
    error InvalidToken();
    error NoFundsToWithdraw();
    error InvalidFeeConfiguration();
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when fees are collected
     * @param source Address that collected the fees
     * @param token Token address of collected fees
     * @param amount Amount collected
     * @param feeSource Source category of the fees
     * @param timestamp Time of collection
     */
    event FeesCollected(
        address indexed source,
        address indexed token,
        uint256 amount,
        FeeSource feeSource,
        uint256 timestamp
    );

    /**
     * @notice Emitted when fees are distributed
     * @param distributionId Unique distribution identifier
     * @param totalAmount Total amount distributed
     * @param validatorShare Amount allocated to validators
     * @param companyShare Amount allocated to company
     * @param developmentShare Amount allocated to development
     * @param timestamp Time of distribution
     */
    event FeesDistributed(
        uint256 indexed distributionId,
        uint256 indexed totalAmount,
        uint256 indexed validatorShare,
        uint256 companyShare,
        uint256 developmentShare,
        uint256 timestamp
    );

    /**
     * @notice Emitted when validator claims rewards
     * @param validator Address of the validator
     * @param token Token address of the reward
     * @param amount Amount claimed
     * @param distributionId Associated distribution ID
     */
    event ValidatorRewardClaimed(
        address indexed validator,
        address indexed token,
        uint256 indexed amount,
        uint256 distributionId
    );

    /**
     * @notice Emitted when company withdraws fees
     * @param token Token address withdrawn
     * @param amount Amount withdrawn
     * @param recipient Recipient address
     */
    event CompanyFeesWithdrawn(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /**
     * @notice Emitted when development fund withdraws fees
     * @param token Token address withdrawn
     * @param amount Amount withdrawn
     * @param recipient Recipient address
     */
    event DevelopmentFeesWithdrawn(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /**
     * @notice Emitted when distribution ratios are updated
     * @param validatorShare New validator share percentage
     * @param companyShare New company share percentage
     * @param developmentShare New development share percentage
     */
    event DistributionRatiosUpdated(
        uint256 indexed validatorShare,
        uint256 indexed companyShare,
        uint256 indexed developmentShare
    );

    /**
     * @notice Emitted when private rewards are distributed
     * @param validator Address of the validator
     * @param encryptedAmountHash Hash of encrypted amount
     * @param distributionId Associated distribution ID
     */
    event PrivateValidatorRewardDistributed(
        address indexed validator,
        bytes32 encryptedAmountHash,
        uint256 indexed distributionId
    );

    /**
     * @notice Emitted when private rewards are claimed
     * @param validator Address of the validator
     * @param encryptedAmountHash Hash of encrypted amount
     * @param token Token address of the reward
     */
    event PrivateRewardsClaimed(
        address indexed validator,
        bytes32 encryptedAmountHash,
        address indexed token
    );


    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Primary fee token (XOM)
    IERC20 public immutable FEE_TOKEN;
    
    /// @notice Distribution ratio configuration
    DistributionRatio public distributionRatio;
    
    /// @notice Treasury addresses for fee recipients
    TreasuryAddresses public treasuryAddresses;
    
    /// @notice MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;

    /// @notice Validator information mapping
    mapping(address => ValidatorInfo) public validators;
    
    /// @notice Distribution records by ID
    mapping(uint256 => Distribution) public distributions;
    
    /// @notice Pending rewards per validator per token
    mapping(address => mapping(address => uint256))
        public validatorPendingRewards;
    
    /// @notice Company pending withdrawals by token
    mapping(address => uint256) public companyPendingWithdrawals;
    
    /// @notice Development fund pending withdrawals by token
    mapping(address => uint256) public developmentPendingWithdrawals;
    
    /// @notice Privacy-enabled validator rewards (validator -> token -> encrypted amount)
    mapping(address => mapping(address => ctUint64)) private validatorPrivateRewards;
    
    /// @notice Privacy-enabled validator earnings (validator -> total encrypted earnings)
    mapping(address => ctUint64) private validatorPrivateEarnings;

    /// @notice Array of all fee collections
    FeeCollection[] public feeCollections;
    
    /// @notice Total fees by source type
    mapping(FeeSource => uint256) public feeSourceTotals;
    
    /// @notice Total fees collected by token
    mapping(address => uint256) public tokenTotals;

    /// @notice Current distribution ID counter
    uint256 public currentDistributionId;
    
    /// @notice Time interval between distributions (default 6 hours)
    uint256 public distributionInterval = 6 hours;
    
    /// @notice Timestamp of last distribution
    uint256 public lastDistributionTime;
    
    /// @notice Minimum amount required for distribution (default 1000 XOM)
    uint256 public minimumDistributionAmount = 1000 * 10 ** 18;

    /// @notice Comprehensive revenue metrics
    RevenueMetrics public revenueMetrics;

    /// @notice Enabled fee sources configuration
    mapping(FeeSource => bool) public enabledFeeSources;
    
    /// @notice Weighted distribution for fee sources
    mapping(FeeSource => uint256) public feeSourceWeights;

    /**
     * @notice Initialize the fee distribution contract
     * @param registry_ Address of the registry contract
     * @param feeToken_ Address of the primary fee token (XOM)
     * @param companyTreasury_ Address to receive company fees
     * @param developmentFund_ Address to receive development fees
     */
    constructor(
        address registry_,
        address feeToken_,
        address companyTreasury_,
        address developmentFund_
    ) RegistryAware(registry_) {
        if (feeToken_ == address(0)) revert InvalidToken();
        if (companyTreasury_ == address(0)) revert InvalidAddress();
        if (developmentFund_ == address(0)) revert InvalidAddress();

        FEE_TOKEN = IERC20(feeToken_);
        treasuryAddresses = TreasuryAddresses({
            companyTreasury: companyTreasury_,
            developmentFund: developmentFund_
        });

        // Initialize distribution ratios (70/20/10)
        distributionRatio = DistributionRatio({
            validatorShare: 7000,
            companyShare: 2000,
            developmentShare: 1000
        });

        // Enable all fee sources by default
        _initializeFeeSources();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COLLECTOR_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);

        lastDistributionTime = block.timestamp; // solhint-disable-line not-rely-on-time
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Default to false (Hardhat/testing mode)
    }

    /**
     * @notice Set MPC availability for privacy features
     * @dev Admin only, called when deploying to COTI testnet/mainnet
     * @param _available Whether MPC is available
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }

    /**
     * @notice Initialize validator for private rewards
     * @dev Called when validator is first registered
     * @param validator Address of the validator to initialize
     */
    function initializeValidatorPrivateRewards(address validator) external onlyRole(DISTRIBUTOR_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        
        // Initialize basic validator info (always works)
        validators[validator].validatorAddress = validator;
        validators[validator].isActive = true;
        
        // Initialize private earnings if MPC is available
        if (isMpcAvailable) {
            gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
            ctUint64 ctZero = MpcCore.offBoard(gtZero);
            
            validatorPrivateEarnings[validator] = ctZero;
            validators[validator].privateTotalRewards = ctZero;
            validators[validator].privateStakeAmount = ctZero;
        }
    }

    /**
     * @notice Collect fees from various sources
     * @dev Transfers fees to the contract and records the collection
     * @param token Address of the token being collected
     * @param amount Amount of fees to collect
     * @param source Source category of the fees
     */
    function collectFees(
        address token,
        uint256 amount,
        FeeSource source
    ) external onlyRole(COLLECTOR_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (!enabledFeeSources[source]) revert InvalidToken();

        // Transfer fees to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Record fee collection
        feeCollections.push(
            FeeCollection({
                token: token,
                amount: amount,
                source: source,
                timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
                collector: msg.sender
            })
        );

        // Update totals
        feeSourceTotals[source] += amount;
        tokenTotals[token] += amount;
        revenueMetrics.totalFeesCollected += amount;

        emit FeesCollected(msg.sender, token, amount, source, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Batch collect fees from multiple sources
     * @dev Transfers multiple fee collections in a single transaction
     * @param tokens Array of token addresses
     * @param amounts Array of amounts to collect
     * @param sources Array of fee sources
     */
    function batchCollectFees(
        address[] calldata tokens,
        uint256[] calldata amounts,
        FeeSource[] calldata sources
    ) external onlyRole(COLLECTOR_ROLE) {
        if (tokens.length != amounts.length || amounts.length != sources.length)
            revert InvalidAmount();

        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amounts[i] > 0 && enabledFeeSources[sources[i]]) {
                // Transfer fees
                IERC20(tokens[i]).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amounts[i]
                );

                // Record collection
                feeCollections.push(
                    FeeCollection({
                        token: tokens[i],
                        amount: amounts[i],
                        source: sources[i],
                        timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
                        collector: msg.sender
                    })
                );

                // Update totals
                feeSourceTotals[sources[i]] += amounts[i];
                tokenTotals[tokens[i]] += amounts[i];
                revenueMetrics.totalFeesCollected += amounts[i];

                emit FeesCollected(
                    msg.sender,
                    tokens[i],
                    amounts[i],
                    sources[i],
                    block.timestamp // solhint-disable-line not-rely-on-time
                );
            }
        }
    }

    /**
     * @notice Distribute fees to validators, company, and development fund
     * @dev Executes distribution based on participation scores
     * @param validatorAddresses Array of validator addresses
     * @param participationScores Array of participation scores corresponding to validators
     */
    function distributeFees(
        address[] calldata validatorAddresses,
        uint256[] calldata participationScores
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        _validateDistributionInputs(validatorAddresses, participationScores);
        
        uint256 totalAmount = _calculateDistributableAmount();
        if (totalAmount < minimumDistributionAmount)
            revert InvalidAmount();

        // Calculate distribution shares
        (uint256 validatorShareAmount, uint256 companyShareAmount, uint256 developmentShareAmount) = 
            _calculateDistributionShares(totalAmount);

        // Create new distribution
        Distribution storage newDistribution = _createNewDistribution(
            totalAmount,
            validatorShareAmount,
            companyShareAmount,
            developmentShareAmount,
            validatorAddresses.length
        );

        // Calculate total participation score
        uint256 totalParticipationScore = _calculateTotalParticipationScore(participationScores);

        // Distribute to validators
        _distributeToValidators(
            newDistribution,
            validatorAddresses,
            participationScores,
            validatorShareAmount,
            totalParticipationScore
        );

        // Allocate company and development shares
        companyPendingWithdrawals[address(FEE_TOKEN)] += companyShareAmount;
        developmentPendingWithdrawals[
            address(FEE_TOKEN)
        ] += developmentShareAmount;

        // Update metrics and finalize
        _finalizeDistribution(
            newDistribution,
            totalAmount,
            validatorShareAmount,
            companyShareAmount,
            developmentShareAmount
        );
    }
    
    /**
     * @notice Validate distribution inputs
     * @dev Checks array lengths and distribution timing
     * @param validatorAddresses Array of validator addresses
     * @param participationScores Array of participation scores
     */
    function _validateDistributionInputs(
        address[] calldata validatorAddresses,
        uint256[] calldata participationScores
    ) internal view {
        if (validatorAddresses.length != participationScores.length)
            revert InvalidAmount();
        if (validatorAddresses.length == 0) revert InvalidAmount();
        if (block.timestamp < lastDistributionTime + distributionInterval) // solhint-disable-line not-rely-on-time
            revert InvalidDistribution();
    }
    
    /**
     * @notice Calculate distributable amount
     * @dev Returns available balance minus pending withdrawals
     * @return Total amount available for distribution
     */
    function _calculateDistributableAmount() internal view returns (uint256) {
        return FEE_TOKEN.balanceOf(address(this)) -
            companyPendingWithdrawals[address(FEE_TOKEN)] -
            developmentPendingWithdrawals[address(FEE_TOKEN)];
    }
    
    /**
     * @notice Calculate distribution shares
     * @dev Splits total amount according to configured ratios
     * @param totalAmount Total amount to distribute
     * @return validatorShare Amount for validators
     * @return companyShare Amount for company
     * @return developmentShare Amount for development
     */
    function _calculateDistributionShares(uint256 totalAmount) 
        internal 
        view 
        returns (uint256 validatorShare, uint256 companyShare, uint256 developmentShare) 
    {
        validatorShare = (totalAmount * distributionRatio.validatorShare) / BASIS_POINTS;
        companyShare = (totalAmount * distributionRatio.companyShare) / BASIS_POINTS;
        developmentShare = (totalAmount * distributionRatio.developmentShare) / BASIS_POINTS;
    }
    
    /**
     * @notice Create new distribution record
     * @dev Initializes a new distribution with provided parameters
     * @param totalAmount Total amount being distributed
     * @param validatorShareAmount Amount allocated to validators
     * @param companyShareAmount Amount allocated to company
     * @param developmentShareAmount Amount allocated to development
     * @param validatorCount Number of validators in this distribution
     * @return newDistribution The created distribution storage reference
     */
    function _createNewDistribution(
        uint256 totalAmount,
        uint256 validatorShareAmount,
        uint256 companyShareAmount,
        uint256 developmentShareAmount,
        uint256 validatorCount
    ) internal returns (Distribution storage) {
        ++currentDistributionId;
        Distribution storage newDistribution = distributions[currentDistributionId];
        newDistribution.id = currentDistributionId;
        newDistribution.totalAmount = totalAmount;
        newDistribution.validatorShare = validatorShareAmount;
        newDistribution.companyShare = companyShareAmount;
        newDistribution.developmentShare = developmentShareAmount;
        newDistribution.timestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        newDistribution.validatorCount = validatorCount;
        newDistribution.completed = false;
        return newDistribution;
    }
    
    /**
     * @notice Calculate total participation score
     * @dev Sums all participation scores for proportional distribution
     * @param scores Array of individual participation scores
     * @return total Sum of all participation scores
     */
    function _calculateTotalParticipationScore(uint256[] calldata scores) 
        internal 
        pure 
        returns (uint256 total) 
    {
        for (uint256 i = 0; i < scores.length; ++i) {
            total += scores[i];
        }
    }
    
    /**
     * @notice Distribute rewards to validators
     * @dev Allocates rewards proportionally based on participation scores
     * @param newDistribution The distribution being processed
     * @param validatorAddresses Array of validator addresses
     * @param participationScores Array of participation scores
     * @param validatorShareAmount Total amount allocated to validators
     * @param totalParticipationScore Sum of all participation scores
     */
    function _distributeToValidators(
        Distribution storage newDistribution,
        address[] calldata validatorAddresses,
        uint256[] calldata participationScores,
        uint256 validatorShareAmount,
        uint256 totalParticipationScore
    ) internal {
        for (uint256 i = 0; i < validatorAddresses.length; ++i) {
            address validator = validatorAddresses[i];
            uint256 score = participationScores[i];
            
            uint256 validatorReward = totalParticipationScore > 0
                ? (validatorShareAmount * score) / totalParticipationScore
                : 0;
                
            if (validatorReward > 0) {
                _processValidatorReward(
                    newDistribution,
                    validator,
                    score,
                    validatorReward
                );
            }
        }
    }
    
    /**
     * @notice Process individual validator reward
     * @dev Records validator's reward allocation in the distribution
     * @param newDistribution The distribution being processed
     * @param validator Address of the validator
     * @param score Validator's participation score
     * @param validatorReward Amount of reward for this validator
     */
    function _processValidatorReward(
        Distribution storage newDistribution,
        address validator,
        uint256 score,
        uint256 validatorReward
    ) internal {
        // Update validator info
        validators[validator].validatorAddress = validator;
        validators[validator].participationScore = score;
        validators[validator].isActive = true;
        
        // Add to public pending rewards
        validatorPendingRewards[validator][address(FEE_TOKEN)] += validatorReward;
        
        if (isMpcAvailable) {
            _processPrivateValidatorReward(
                newDistribution,
                validator,
                score,
                validatorReward
            );
        } else {
            // MPC not available - store distribution info without privacy features
            newDistribution.validatorDistributions[validator] = ValidatorDistribution({
                amount: validatorReward,
                claimed: false,
                claimTime: 0,
                participationScore: score,
                privateAmount: ctUint64.wrap(0), // solhint-disable-line
                privateClaimed: ctBool.wrap(0) // solhint-disable-line
            });
        }
    }
    
    /**
     * @notice Process private validator reward with MPC
     * @dev Encrypts reward amounts and stores them privately
     * @param newDistribution The distribution being processed
     * @param validator Address of the validator
     * @param score Validator's participation score
     * @param validatorReward Amount of reward for this validator
     */
    function _processPrivateValidatorReward(
        Distribution storage newDistribution,
        address validator,
        uint256 score,
        uint256 validatorReward
    ) internal {
        gtUint64 gtReward = MpcCore.setPublic64(uint64(validatorReward));
        ctUint64 encryptedReward = MpcCore.offBoard(gtReward);
        
        gtBool gtFalse = MpcCore.setPublic(false);
        ctBool notClaimed = MpcCore.offBoard(gtFalse);
        
        // Initialize private earnings if needed
        _initializePrivateEarnings(validator);
        
        // Store distribution info
        newDistribution.validatorDistributions[validator] = ValidatorDistribution({
            amount: validatorReward,
            claimed: false,
            claimTime: 0,
            participationScore: score,
            privateAmount: encryptedReward,
            privateClaimed: notClaimed
        });
        
        // Update private rewards
        _updatePrivateRewards(validator, gtReward);
        
        // Emit privacy event
        bytes32 encryptedHash = keccak256(abi.encode(encryptedReward, validator, block.timestamp)); // solhint-disable-line not-rely-on-time
        emit PrivateValidatorRewardDistributed(validator, encryptedHash, currentDistributionId);
    }
    
    /**
     * @notice Initialize private earnings if needed
     * @dev Sets up initial encrypted zero values for new validators
     * @param validator Address of the validator to initialize
     */
    function _initializePrivateEarnings(address validator) internal {
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        ctUint64 ctZero = MpcCore.offBoard(gtZero);
        
        gtUint64 gtCurrentEarnings = MpcCore.onBoard(validatorPrivateEarnings[validator]);
        gtBool isZero = MpcCore.eq(gtCurrentEarnings, gtZero);
        
        if (MpcCore.decrypt(isZero)) {
            validatorPrivateEarnings[validator] = ctZero;
            validators[validator].privateTotalRewards = ctZero;
        }
    }
    
    /**
     * @notice Update private rewards using MPC
     * @dev Adds new rewards to existing encrypted balances
     * @param validator Address of the validator
     * @param gtReward Encrypted reward amount to add
     */
    function _updatePrivateRewards(address validator, gtUint64 gtReward) internal {
        // Update token-specific private rewards
        gtUint64 gtCurrentPrivateRewards = MpcCore.onBoard(
            validatorPrivateRewards[validator][address(FEE_TOKEN)]
        );
        gtUint64 gtNewPrivateRewards = MpcCore.add(gtCurrentPrivateRewards, gtReward);
        validatorPrivateRewards[validator][address(FEE_TOKEN)] = MpcCore.offBoard(gtNewPrivateRewards);
        
        // Update total private earnings
        gtUint64 gtCurrentTotalEarnings = MpcCore.onBoard(validatorPrivateEarnings[validator]);
        gtUint64 gtNewTotalEarnings = MpcCore.add(gtCurrentTotalEarnings, gtReward);
        validatorPrivateEarnings[validator] = MpcCore.offBoard(gtNewTotalEarnings);
        validators[validator].privateTotalRewards = MpcCore.offBoard(gtNewTotalEarnings);
    }
    
    /**
     * @notice Finalize distribution and update metrics
     * @dev Updates all tracking metrics and marks distribution as complete
     * @param newDistribution The distribution being finalized
     * @param totalAmount Total amount distributed
     * @param validatorShareAmount Amount distributed to validators
     * @param companyShareAmount Amount allocated to company
     * @param developmentShareAmount Amount allocated to development
     */
    function _finalizeDistribution(
        Distribution storage newDistribution,
        uint256 totalAmount,
        uint256 validatorShareAmount,
        uint256 companyShareAmount,
        uint256 developmentShareAmount
    ) internal {
        // Update metrics
        revenueMetrics.totalDistributed += totalAmount;
        revenueMetrics.totalValidatorRewards += validatorShareAmount;
        revenueMetrics.totalCompanyRevenue += companyShareAmount;
        revenueMetrics.totalDevelopmentFunding += developmentShareAmount;
        ++revenueMetrics.distributionCount;
        revenueMetrics.lastDistributionTime = block.timestamp; // solhint-disable-line not-rely-on-time
        
        newDistribution.completed = true;
        lastDistributionTime = block.timestamp; // solhint-disable-line not-rely-on-time
        
        emit FeesDistributed(
            currentDistributionId,
            totalAmount,
            validatorShareAmount,
            companyShareAmount,
            developmentShareAmount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Claim validator rewards (public version)
     * @dev Transfers accumulated rewards to the validator
     * @param token Token address to claim rewards for
     */
    function claimValidatorRewards(address token) external nonReentrant {
        uint256 pendingAmount = validatorPendingRewards[msg.sender][token];
        if (pendingAmount == 0) revert NoFeesPending();

        // Reset pending rewards
        validatorPendingRewards[msg.sender][token] = 0;

        // Update validator info
        validators[msg.sender].totalRewardsClaimed += pendingAmount;
        validators[msg.sender].lastClaimTime = block.timestamp; // solhint-disable-line not-rely-on-time

        // Transfer rewards
        IERC20(token).safeTransfer(msg.sender, pendingAmount);

        emit ValidatorRewardClaimed(
            msg.sender,
            token,
            pendingAmount,
            currentDistributionId
        );
    }

    /**
     * @notice Claim validator rewards with privacy (encrypted amounts)
     * @dev Transfers rewards while keeping amounts encrypted until claim
     * @param token Token address to claim rewards for
     */
    function claimPrivateValidatorRewards(address token) external nonReentrant {
        if (isMpcAvailable) {
            ctUint64 privatePendingAmount = validatorPrivateRewards[msg.sender][token];
            
            // Check if there are rewards to claim using COTI V2 MPC
            gtUint64 gtPendingAmount = MpcCore.onBoard(privatePendingAmount);
            gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
            gtBool hasRewards = MpcCore.gt(gtPendingAmount, gtZero);
            
            if (!MpcCore.decrypt(hasRewards)) revert NoFeesPending();

            // Decrypt amount for transfer (only revealed to validator)
            uint64 decryptedAmount = MpcCore.decrypt(gtPendingAmount);
        
            // Reset private pending rewards to zero
            ctUint64 ctZero = MpcCore.offBoard(gtZero);
            validatorPrivateRewards[msg.sender][token] = ctZero;

            // Update validator info with encrypted totals
            validators[msg.sender].totalRewardsClaimed += decryptedAmount;
            validators[msg.sender].lastClaimTime = block.timestamp; // solhint-disable-line not-rely-on-time

            // Transfer rewards (amount is only known to validator)
            IERC20(token).safeTransfer(msg.sender, decryptedAmount);

            // Emit privacy-preserving event with hash
            bytes32 encryptedHash = keccak256(abi.encode(privatePendingAmount, msg.sender, block.timestamp)); // solhint-disable-line not-rely-on-time
            emit PrivateRewardsClaimed(msg.sender, encryptedHash, token);

        } else {
            // MPC not available (e.g., in Hardhat testing) - fallback to public rewards
            uint256 pendingAmount = validatorPendingRewards[msg.sender][token];
            if (pendingAmount == 0) revert NoFeesPending();
            
            // Reset pending rewards
            validatorPendingRewards[msg.sender][token] = 0;
            
            // Update validator info
            validators[msg.sender].totalRewardsClaimed += pendingAmount;
            validators[msg.sender].lastClaimTime = block.timestamp; // solhint-disable-line not-rely-on-time
            
            // Transfer rewards
            IERC20(token).safeTransfer(msg.sender, pendingAmount);
            
            // Emit regular event
            emit ValidatorRewardClaimed(msg.sender, token, pendingAmount, currentDistributionId);
        }
    }

    /**
     * @notice Withdraw company fees
     * @dev Transfers accumulated company share to treasury
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawCompanyFees(
        address token,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (companyPendingWithdrawals[token] < amount)
            revert NoFundsToWithdraw();

        companyPendingWithdrawals[token] -= amount;
        IERC20(token).safeTransfer(treasuryAddresses.companyTreasury, amount);

        emit CompanyFeesWithdrawn(token, amount, treasuryAddresses.companyTreasury);
    }

    /**
     * @notice Withdraw development fees
     * @dev Transfers accumulated development share to fund
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawDevelopmentFees(
        address token,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (developmentPendingWithdrawals[token] < amount)
            revert NoFundsToWithdraw();

        developmentPendingWithdrawals[token] -= amount;
        IERC20(token).safeTransfer(treasuryAddresses.developmentFund, amount);

        emit DevelopmentFeesWithdrawn(token, amount, treasuryAddresses.developmentFund);
    }

    /**
     * @notice Update distribution ratios
     * @dev Adjusts the percentage split between validators, company, and development
     * @param _validatorShare New validator share (in basis points)
     * @param _companyShare New company share (in basis points)
     * @param _developmentShare New development share (in basis points)
     */
    function updateDistributionRatios(
        uint256 _validatorShare,
        uint256 _companyShare,
        uint256 _developmentShare
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_validatorShare + _companyShare + _developmentShare != 10000)
            revert InvalidFeeConfiguration();
        if (_validatorShare < 5000)
            revert InvalidFeeConfiguration();

        distributionRatio = DistributionRatio({
            validatorShare: _validatorShare,
            companyShare: _companyShare,
            developmentShare: _developmentShare
        });

        emit DistributionRatiosUpdated(
            _validatorShare,
            _companyShare,
            _developmentShare
        );
    }

    /**
     * @notice Update distribution parameters
     * @dev Adjusts timing and minimum amounts for distributions
     * @param _distributionInterval New interval between distributions
     * @param _minimumDistributionAmount New minimum amount required to distribute
     */
    function updateDistributionParameters(
        uint256 _distributionInterval,
        uint256 _minimumDistributionAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_distributionInterval < 1 hours) revert InvalidDistribution();
        if (_minimumDistributionAmount == 0)
            revert InvalidAmount();

        distributionInterval = _distributionInterval;
        minimumDistributionAmount = _minimumDistributionAmount;
    }

    /**
     * @notice Update treasury addresses
     * @dev Changes the recipient addresses for company and development fees
     * @param _companyTreasury New company treasury address
     * @param _developmentFund New development fund address
     */
    function updateTreasuryAddresses(
        address _companyTreasury,
        address _developmentFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_companyTreasury == address(0)) revert InvalidAddress();
        if (_developmentFund == address(0)) revert InvalidAddress();

        treasuryAddresses = TreasuryAddresses({
            companyTreasury: _companyTreasury,
            developmentFund: _developmentFund
        });
    }

    /**
     * @notice Enable/disable fee sources
     * @dev Controls which fee sources are accepted for collection
     * @param source The fee source to configure
     * @param enabled Whether the source should be enabled
     */
    function setFeeSourceEnabled(
        FeeSource source,
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabledFeeSources[source] = enabled;
    }

    /**
     * @notice Set fee source weights
     * @dev Adjusts the relative importance of different fee sources
     * @param source The fee source to configure
     * @param weight The weight value (max 10000)
     */
    function setFeeSourceWeight(
        FeeSource source,
        uint256 weight
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (weight > 10000) revert InvalidFeeConfiguration();
        feeSourceWeights[source] = weight;
    }

    /**
     * @notice Initialize fee sources
     * @dev Sets up default fee sources and their weights
     */
    function _initializeFeeSources() internal {
        // Enable all fee sources
        enabledFeeSources[FeeSource.TRADING] = true;
        enabledFeeSources[FeeSource.PERPETUAL_FUTURES] = true;
        enabledFeeSources[FeeSource.AUTO_CONVERSION] = true;
        enabledFeeSources[FeeSource.MARKETPLACE] = true;
        enabledFeeSources[FeeSource.CHAT_PREMIUM] = true;
        enabledFeeSources[FeeSource.IPFS_STORAGE] = true;
        enabledFeeSources[FeeSource.BLOCK_REWARDS] = true;
        enabledFeeSources[FeeSource.BRIDGING] = true;
        enabledFeeSources[FeeSource.STAKING_REWARDS] = true;

        // Set equal weights initially
        feeSourceWeights[FeeSource.TRADING] = 3000; // 30%
        feeSourceWeights[FeeSource.PERPETUAL_FUTURES] = 2000; // 20%
        feeSourceWeights[FeeSource.AUTO_CONVERSION] = 1500; // 15%
        feeSourceWeights[FeeSource.MARKETPLACE] = 1000; // 10%
        feeSourceWeights[FeeSource.CHAT_PREMIUM] = 500; // 5%
        feeSourceWeights[FeeSource.IPFS_STORAGE] = 500; // 5%
        feeSourceWeights[FeeSource.BLOCK_REWARDS] = 1000; // 10%
        feeSourceWeights[FeeSource.BRIDGING] = 300; // 3%
        feeSourceWeights[FeeSource.STAKING_REWARDS] = 200; // 2%
    }

    /**
     * @notice Get validator information
     * @dev Returns detailed info about a validator's rewards and status
     * @param validator Address of the validator
     * @return validatorAddress The validator's address
     * @return isActive Whether the validator is active
     * @return participationScore The validator's participation score
     * @return totalEarned Total rewards earned by the validator
     * @return pendingRewards Unclaimed rewards
     * @return lastUpdateTime Last time validator info was updated
     * @return totalRewardsClaimed Total rewards claimed to date
     * @return lastClaimTime Last time rewards were claimed
     */
    function getValidatorInfo(
        address validator
    ) external view returns (
        address validatorAddress,
        bool isActive,
        uint256 participationScore,
        uint256 totalEarned,
        uint256 pendingRewards,
        uint256 lastUpdateTime,
        uint256 totalRewardsClaimed,
        uint256 lastClaimTime
    ) {
        ValidatorInfo storage info = validators[validator];
        return (
            info.validatorAddress,
            info.isActive,
            info.participationScore,
            info.totalEarned,
            info.pendingRewards,
            info.lastUpdateTime,
            info.totalRewardsClaimed,
            info.lastClaimTime
        );
    }

    /**
     * @notice Get distribution information
     * @dev Returns details about a specific distribution
     * @param distributionId The ID of the distribution
     * @return id Distribution ID
     * @return totalAmount Total amount distributed
     * @return validatorShare Amount allocated to validators
     * @return companyShare Amount allocated to company
     * @return developmentShare Amount allocated to development
     * @return timestamp When the distribution occurred
     * @return validatorCount Number of validators in the distribution
     * @return completed Whether the distribution is complete
     */
    function getDistribution(
        uint256 distributionId
    )
        external
        view
        returns (
            uint256 id,
            uint256 totalAmount,
            uint256 validatorShare,
            uint256 companyShare,
            uint256 developmentShare,
            uint256 timestamp,
            uint256 validatorCount,
            bool completed
        )
    {
        Distribution storage dist = distributions[distributionId];
        return (
            dist.id,
            dist.totalAmount,
            dist.validatorShare,
            dist.companyShare,
            dist.developmentShare,
            dist.timestamp,
            dist.validatorCount,
            dist.completed
        );
    }

    /**
     * @notice Get validator's distribution details
     * @dev Returns specific validator's info for a distribution
     * @param distributionId The ID of the distribution
     * @param validator Address of the validator
     * @return amount Amount allocated to the validator
     * @return participationScore Validator's participation score
     * @return claimed Whether the validator has claimed
     */
    function getValidatorDistribution(
        uint256 distributionId,
        address validator
    )
        external
        view
        returns (uint256 amount, uint256 participationScore, bool claimed)
    {
        ValidatorDistribution storage valDist = distributions[distributionId]
            .validatorDistributions[validator];
        return (valDist.amount, valDist.participationScore, valDist.claimed);
    }

    /**
     * @notice Get validator's pending rewards
     * @dev Returns unclaimed rewards for a specific token
     * @param validator Address of the validator
     * @param token Token address
     * @return Pending reward amount
     */
    function getValidatorPendingRewards(
        address validator,
        address token
    ) external view returns (uint256) {
        return validatorPendingRewards[validator][token];
    }

    /**
     * @notice Get validator's private pending rewards
     * @dev Only accessible by validator or admin, returns encrypted amount
     * @param validator Address of the validator
     * @param token Token address
     * @return Encrypted pending reward amount
     */
    function getValidatorPrivatePendingRewards(
        address validator,
        address token
    ) external view returns (ctUint64) {
        if (msg.sender != validator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
            revert NotAuthorized();
        return validatorPrivateRewards[validator][token];
    }

    /**
     * @notice Get validator's total private earnings
     * @dev Only accessible by validator or admin, returns encrypted total
     * @param validator Address of the validator
     * @return Encrypted total earnings
     */
    function getValidatorPrivateEarnings(
        address validator
    ) external view returns (ctUint64) {
        if (msg.sender != validator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
            revert NotAuthorized();
        return validatorPrivateEarnings[validator];
    }

    /**
     * @notice Get company's pending withdrawals
     * @dev Returns accumulated company fees ready for withdrawal
     * @param token Token address
     * @return Pending withdrawal amount
     */
    function getCompanyPendingWithdrawals(
        address token
    ) external view returns (uint256) {
        return companyPendingWithdrawals[token];
    }

    /**
     * @notice Get development fund's pending withdrawals
     * @dev Returns accumulated development fees ready for withdrawal
     * @param token Token address
     * @return Pending withdrawal amount
     */
    function getDevelopmentPendingWithdrawals(
        address token
    ) external view returns (uint256) {
        return developmentPendingWithdrawals[token];
    }

    /**
     * @notice Get revenue metrics
     * @dev Returns comprehensive revenue tracking data
     * @return Revenue metrics struct with all tracking data
     */
    function getRevenueMetrics() external view returns (RevenueMetrics memory) {
        return revenueMetrics;
    }

    /**
     * @notice Get total fees from a specific source
     * @dev Returns cumulative fees collected from the source
     * @param source The fee source to query
     * @return Total fees collected from this source
     */
    function getFeeSourceTotal(
        FeeSource source
    ) external view returns (uint256) {
        return feeSourceTotals[source];
    }

    /**
     * @notice Get total fees for a specific token
     * @dev Returns cumulative fees collected in this token
     * @param token Token address to query
     * @return Total fees collected in this token
     */
    function getTokenTotal(address token) external view returns (uint256) {
        return tokenTotals[token];
    }

    /**
     * @notice Get current distribution ratios
     * @dev Returns the percentage split configuration
     * @return Distribution ratio struct with validator, company, and development shares
     */
    function getDistributionRatio()
        external
        view
        returns (DistributionRatio memory)
    {
        return distributionRatio;
    }

    /**
     * @notice Get total number of fee collections
     * @dev Returns the length of the fee collections array
     * @return Number of fee collections recorded
     */
    function getFeeCollectionCount() external view returns (uint256) {
        return feeCollections.length;
    }

    /**
     * @notice Get specific fee collection details
     * @dev Returns fee collection data at the given index
     * @param index Index in the fee collections array
     * @return Fee collection struct with all details
     */
    function getFeeCollection(
        uint256 index
    ) external view returns (FeeCollection memory) {
        if (index >= feeCollections.length) revert InvalidAmount();
        return feeCollections[index];
    }

    /**
     * @notice Check if distribution can be executed
     * @dev Verifies minimum amount and time interval requirements
     * @return Whether distribution conditions are met
     */
    function canDistribute() external view returns (bool) {
        uint256 totalAmount = FEE_TOKEN.balanceOf(address(this)) -
            companyPendingWithdrawals[address(FEE_TOKEN)] -
            developmentPendingWithdrawals[address(FEE_TOKEN)];

        return
            totalAmount >= minimumDistributionAmount &&
            block.timestamp >= lastDistributionTime + distributionInterval; // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Get next distribution time
     * @dev Calculates when the next distribution will be allowed
     * @return Timestamp of next allowed distribution
     */
    function getNextDistributionTime() external view returns (uint256) {
        return lastDistributionTime + distributionInterval;
    }

    /**
     * @notice Pause contract operations
     * @dev Emergency pause function for admin
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     * @dev Resume normal operations after pause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Get contract version
     * @dev Returns version string for tracking upgrades
     * @return Version string
     */
    function getVersion() external pure returns (string memory) {
        return "FeeDistribution v2.0.0 - COTI V2 Privacy Integration";
    }
    
    // =============================================================================
    // DUAL-TOKEN SUPPORT
    // =============================================================================
    
    /**
     * @notice Check if a token is part of the OmniCoin dual-token system
     * @dev Returns true for OmniCoin or PrivateOmniCoin addresses
     * @param token The token address to check
     * @return isOmniToken Whether the token is OmniCoin or PrivateOmniCoin
     */
    function isOmniCoinToken(address token) public view returns (bool isOmniToken) {
        address omniCoin = _getContract(REGISTRY.OMNICOIN());
        address privateOmniCoin = _getContract(REGISTRY.PRIVATE_OMNICOIN());
        return token == omniCoin || token == privateOmniCoin;
    }
    
    /**
     * @notice Collect fees from dual-token system
     * @dev Handles both OmniCoin and PrivateOmniCoin fee collection
     * @param amount Amount of fees to collect
     * @param source Source category of the fees
     * @param usePrivateToken Whether to collect in PrivateOmniCoin
     */
    function collectDualTokenFees(
        uint256 amount,
        FeeSource source,
        bool usePrivateToken
    ) external onlyRole(COLLECTOR_ROLE) {
        address token;
        if (usePrivateToken) {
            token = _getContract(REGISTRY.PRIVATE_OMNICOIN());
            if (token == address(0)) revert InvalidToken();
        } else {
            token = _getContract(REGISTRY.OMNICOIN());
            if (token == address(0)) {
                // Fallback to FEE_TOKEN if registry not configured
                token = address(FEE_TOKEN);
            }
        }
        
        // Collect fees logic
        if (amount == 0) revert InvalidAmount();
        if (!enabledFeeSources[source]) revert InvalidToken();

        // Transfer fees to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Track collected fees
        tokenTotals[token] += amount;
        feeSourceTotals[source] += amount;

        // Add to fee collections array
        feeCollections.push(FeeCollection({
            token: token,
            amount: amount,
            source: source,
            collector: msg.sender,
            timestamp: block.timestamp
        }));

        // Update revenue metrics
        revenueMetrics.totalFeesCollected += amount;

        emit FeesCollected(msg.sender, token, amount, source, block.timestamp);
    }
    
    /**
     * @notice Get the primary fee token from registry
     * @dev Uses registry if available, otherwise returns FEE_TOKEN
     * @return token Address of the primary fee token
     */
    function getPrimaryFeeToken() public view returns (address token) {
        token = _getContract(REGISTRY.OMNICOIN());
        if (token == address(0)) {
            token = address(FEE_TOKEN);
        }
        return token;
    }
}
