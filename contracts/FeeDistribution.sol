// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MpcCore, gtUint64, ctUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title FeeDistribution
 * @dev Automated fee distribution system for unified validators
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
contract FeeDistribution is ReentrancyGuard, Pausable, AccessControl {
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
        address validatorAddress;
        uint256 participationScore;
        uint256 totalEarned;
        uint256 pendingRewards;
        bool isActive;
        uint256 lastUpdateTime;
        ctUint64 privateRewardBalance; // For privacy mode
        uint256 totalRewardsClaimed;
        uint256 lastClaimTime;
        ctUint64 privateTotalRewards;
        ctUint64 privateStakeAmount;
        mapping(address => uint256) tokenBalances;
    }

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    
    // Roles
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // Custom Errors
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

    // Events
    event FeesCollected(
        address indexed source,
        address indexed token,
        uint256 amount,
        FeeSource feeSource,
        uint256 timestamp
    );

    event FeesDistributed(
        uint256 indexed distributionId,
        uint256 totalAmount,
        uint256 validatorShare,
        uint256 companyShare,
        uint256 developmentShare,
        uint256 timestamp
    );

    event ValidatorRewardClaimed(
        address indexed validator,
        address indexed token,
        uint256 amount,
        uint256 distributionId
    );

    event CompanyFeesWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    event DevelopmentFeesWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    event DistributionRatiosUpdated(
        uint256 validatorShare,
        uint256 companyShare,
        uint256 developmentShare
    );

    event PrivateValidatorRewardDistributed(
        address indexed validator,
        bytes32 encryptedAmountHash,
        uint256 distributionId
    );

    event PrivateRewardsClaimed(
        address indexed validator,
        bytes32 encryptedAmountHash,
        address indexed token
    );


    // State variables
    IERC20 public immutable FEE_TOKEN; // Primary fee token (XOM)
    DistributionRatio public distributionRatio;
    TreasuryAddresses public treasuryAddresses;
    
    // MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;

    mapping(address => ValidatorInfo) public validators;
    mapping(uint256 => Distribution) public distributions;
    mapping(address => mapping(address => uint256))
        public validatorPendingRewards; // validator -> token -> amount
    mapping(address => uint256) public companyPendingWithdrawals; // token -> amount
    mapping(address => uint256) public developmentPendingWithdrawals; // token -> amount
    
    // Privacy-enabled mappings using COTI V2 MPC
    // validator -> token -> encrypted amount
    mapping(address => mapping(address => ctUint64)) private validatorPrivateRewards;
    mapping(address => ctUint64) private validatorPrivateEarnings; // validator -> total encrypted earnings

    FeeCollection[] public feeCollections;
    mapping(FeeSource => uint256) public feeSourceTotals;
    mapping(address => uint256) public tokenTotals; // token -> total collected

    uint256 public currentDistributionId;
    uint256 public distributionInterval = 6 hours; // Default distribution every 6 hours
    uint256 public lastDistributionTime;
    uint256 public minimumDistributionAmount = 1000 * 10 ** 18; // 1000 XOM minimum

    RevenueMetrics public revenueMetrics;

    // Fee source configurations
    mapping(FeeSource => bool) public enabledFeeSources;
    mapping(FeeSource => uint256) public feeSourceWeights; // For weighted distribution

    constructor(
        address feeToken_,
        address companyTreasury_,
        address developmentFund_
    ) {
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

        lastDistributionTime = block.timestamp;
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Default to false (Hardhat/testing mode)
    }

    /**
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }

    /**
     * @dev Initialize validator for private rewards (called when validator is first registered)
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
     * @dev Collect fees from various sources
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
                timestamp: block.timestamp,
                collector: msg.sender
            })
        );

        // Update totals
        feeSourceTotals[source] += amount;
        tokenTotals[token] += amount;
        revenueMetrics.totalFeesCollected += amount;

        emit FeesCollected(msg.sender, token, amount, source, block.timestamp);
    }

    /**
     * @dev Batch collect fees from multiple sources
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
                        timestamp: block.timestamp,
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
                    block.timestamp
                );
            }
        }
    }

    /**
     * @dev Distribute fees to validators, company, and development fund
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
     * @dev Validate distribution inputs
     */
    function _validateDistributionInputs(
        address[] calldata validatorAddresses,
        uint256[] calldata participationScores
    ) internal view {
        if (validatorAddresses.length != participationScores.length)
            revert InvalidAmount();
        if (validatorAddresses.length == 0) revert InvalidAmount();
        if (block.timestamp < lastDistributionTime + distributionInterval)
            revert InvalidDistribution();
    }
    
    /**
     * @dev Calculate distributable amount
     */
    function _calculateDistributableAmount() internal view returns (uint256) {
        return FEE_TOKEN.balanceOf(address(this)) -
            companyPendingWithdrawals[address(FEE_TOKEN)] -
            developmentPendingWithdrawals[address(FEE_TOKEN)];
    }
    
    /**
     * @dev Calculate distribution shares
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
     * @dev Create new distribution record
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
        newDistribution.timestamp = block.timestamp;
        newDistribution.validatorCount = validatorCount;
        newDistribution.completed = false;
        return newDistribution;
    }
    
    /**
     * @dev Calculate total participation score
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
     * @dev Distribute rewards to validators
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
     * @dev Process individual validator reward
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
                participationScore: score,
                claimed: false,
                privateAmount: ctUint64.wrap(0),
                privateClaimed: ctBool.wrap(0)
            });
        }
    }
    
    /**
     * @dev Process private validator reward with MPC
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
            participationScore: score,
            claimed: false,
            privateAmount: encryptedReward,
            privateClaimed: notClaimed
        });
        
        // Update private rewards
        _updatePrivateRewards(validator, gtReward);
        
        // Emit privacy event
        bytes32 encryptedHash = keccak256(abi.encode(encryptedReward, validator, block.timestamp));
        emit PrivateValidatorRewardDistributed(validator, encryptedHash, currentDistributionId);
    }
    
    /**
     * @dev Initialize private earnings if needed
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
     * @dev Update private rewards using MPC
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
     * @dev Finalize distribution and update metrics
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
        revenueMetrics.distributionCount++;
        revenueMetrics.lastDistributionTime = block.timestamp;
        
        newDistribution.completed = true;
        lastDistributionTime = block.timestamp;
        
        emit FeesDistributed(
            currentDistributionId,
            totalAmount,
            validatorShareAmount,
            companyShareAmount,
            developmentShareAmount,
            block.timestamp
        );
    }

    /**
     * @dev Claim validator rewards (public version)
     */
    function claimValidatorRewards(address token) external nonReentrant {
        uint256 pendingAmount = validatorPendingRewards[msg.sender][token];
        if (pendingAmount == 0) revert NoFeesPending();

        // Reset pending rewards
        validatorPendingRewards[msg.sender][token] = 0;

        // Update validator info
        validators[msg.sender].totalRewardsClaimed += pendingAmount;
        validators[msg.sender].lastClaimTime = block.timestamp;

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
     * @dev Claim validator rewards with privacy (encrypted amounts)
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
            validators[msg.sender].lastClaimTime = block.timestamp;

            // Transfer rewards (amount is only known to validator)
            IERC20(token).safeTransfer(msg.sender, decryptedAmount);

            // Emit privacy-preserving event with hash
            bytes32 encryptedHash = keccak256(abi.encode(privatePendingAmount, msg.sender, block.timestamp));
            emit PrivateRewardsClaimed(msg.sender, encryptedHash, token);

        } else {
            // MPC not available (e.g., in Hardhat testing) - fallback to public rewards
            uint256 pendingAmount = validatorPendingRewards[msg.sender][token];
            if (pendingAmount == 0) revert NoFeesPending();
            
            // Reset pending rewards
            validatorPendingRewards[msg.sender][token] = 0;
            
            // Update validator info
            validators[msg.sender].totalRewardsClaimed += pendingAmount;
            validators[msg.sender].lastClaimTime = block.timestamp;
            
            // Transfer rewards
            IERC20(token).safeTransfer(msg.sender, pendingAmount);
            
            // Emit regular event
            emit ValidatorRewardClaimed(msg.sender, token, pendingAmount, currentDistributionId);
        }
    }

    /**
     * @dev Withdraw company fees
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
     * @dev Withdraw development fees
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
     * @dev Update distribution ratios
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
     * @dev Update distribution parameters
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
     * @dev Update treasury addresses
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
     * @dev Enable/disable fee sources
     */
    function setFeeSourceEnabled(
        FeeSource source,
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabledFeeSources[source] = enabled;
    }

    /**
     * @dev Set fee source weights
     */
    function setFeeSourceWeight(
        FeeSource source,
        uint256 weight
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (weight > 10000) revert InvalidFeeConfiguration();
        feeSourceWeights[source] = weight;
    }

    // Internal functions
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

    // View functions
    function getValidatorInfo(
        address validator
    ) external view returns (ValidatorInfo memory) {
        return validators[validator];
    }

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

    function getValidatorPendingRewards(
        address validator,
        address token
    ) external view returns (uint256) {
        return validatorPendingRewards[validator][token];
    }

    /**
     * @dev Get validator's private pending rewards (only accessible by validator or admin)
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
     * @dev Get validator's total private earnings (only accessible by validator or admin)
     */
    function getValidatorPrivateEarnings(
        address validator
    ) external view returns (ctUint64) {
        if (msg.sender != validator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
            revert NotAuthorized();
        return validatorPrivateEarnings[validator];
    }

    function getCompanyPendingWithdrawals(
        address token
    ) external view returns (uint256) {
        return companyPendingWithdrawals[token];
    }

    function getDevelopmentPendingWithdrawals(
        address token
    ) external view returns (uint256) {
        return developmentPendingWithdrawals[token];
    }

    function getRevenueMetrics() external view returns (RevenueMetrics memory) {
        return revenueMetrics;
    }

    function getFeeSourceTotal(
        FeeSource source
    ) external view returns (uint256) {
        return feeSourceTotals[source];
    }

    function getTokenTotal(address token) external view returns (uint256) {
        return tokenTotals[token];
    }

    function getDistributionRatio()
        external
        view
        returns (DistributionRatio memory)
    {
        return distributionRatio;
    }

    function getFeeCollectionCount() external view returns (uint256) {
        return feeCollections.length;
    }

    function getFeeCollection(
        uint256 index
    ) external view returns (FeeCollection memory) {
        if (index >= feeCollections.length) revert InvalidAmount();
        return feeCollections[index];
    }

    function canDistribute() external view returns (bool) {
        uint256 totalAmount = FEE_TOKEN.balanceOf(address(this)) -
            companyPendingWithdrawals[address(FEE_TOKEN)] -
            developmentPendingWithdrawals[address(FEE_TOKEN)];

        return
            totalAmount >= minimumDistributionAmount &&
            block.timestamp >= lastDistributionTime + distributionInterval;
    }

    function getNextDistributionTime() external view returns (uint256) {
        return lastDistributionTime + distributionInterval;
    }

    // Pause functions
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Get contract version for privacy upgrade tracking
     */
    function getVersion() external pure returns (string memory) {
        return "FeeDistribution v2.0.0 - COTI V2 Privacy Integration";
    }
}
