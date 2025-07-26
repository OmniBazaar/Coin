// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

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

    // Roles
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

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
        uint256 participationScore;
        bool claimed;
        ctUint64 privateAmount;      // Privacy-enabled reward amount
        ctBool privateClaimed;       // Privacy-enabled claim status
    }

    struct ValidatorInfo {
        address validatorAddress;
        uint256 participationScore;
        uint256 totalRewardsClaimed;
        uint256 lastClaimTime;
        bool isActive;
        ctUint64 privateTotalRewards;    // Privacy-enabled total rewards
        ctUint64 privateStakeAmount;     // Privacy-enabled staking amount
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

    // State variables
    IERC20 public immutable feeToken; // Primary fee token (XOM)
    DistributionRatio public distributionRatio;

    address public companyTreasury;
    address public developmentFund;
    
    // MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;

    mapping(address => ValidatorInfo) public validators;
    mapping(uint256 => Distribution) public distributions;
    mapping(address => mapping(address => uint256))
        public validatorPendingRewards; // validator -> token -> amount
    mapping(address => uint256) public companyPendingWithdrawals; // token -> amount
    mapping(address => uint256) public developmentPendingWithdrawals; // token -> amount
    
    // Privacy-enabled mappings using COTI V2 MPC
    mapping(address => mapping(address => ctUint64)) private validatorPrivateRewards; // validator -> token -> encrypted amount
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
        address _feeToken,
        address _companyTreasury,
        address _developmentFund
    ) {
        require(_feeToken != address(0), "Invalid fee token");
        require(_companyTreasury != address(0), "Invalid company treasury");
        require(_developmentFund != address(0), "Invalid development fund");

        feeToken = IERC20(_feeToken);
        companyTreasury = _companyTreasury;
        developmentFund = _developmentFund;

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
        require(validator != address(0), "Invalid validator address");
        
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
        require(amount > 0, "Amount must be positive");
        require(enabledFeeSources[source], "Fee source not enabled");

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
        require(
            tokens.length == amounts.length && amounts.length == sources.length,
            "Arrays length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
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
        require(
            validatorAddresses.length == participationScores.length,
            "Arrays length mismatch"
        );
        require(validatorAddresses.length > 0, "No validators provided");
        require(
            block.timestamp >= lastDistributionTime + distributionInterval,
            "Distribution too early"
        );

        uint256 totalAmount = feeToken.balanceOf(address(this)) -
            companyPendingWithdrawals[address(feeToken)] -
            developmentPendingWithdrawals[address(feeToken)];

        require(
            totalAmount >= minimumDistributionAmount,
            "Insufficient amount for distribution"
        );

        // Calculate distribution amounts
        uint256 validatorShareAmount = (totalAmount *
            distributionRatio.validatorShare) / 10000;
        uint256 companyShareAmount = (totalAmount *
            distributionRatio.companyShare) / 10000;
        uint256 developmentShareAmount = (totalAmount *
            distributionRatio.developmentShare) / 10000;

        // Create new distribution
        currentDistributionId++;
        Distribution storage newDistribution = distributions[
            currentDistributionId
        ];
        newDistribution.id = currentDistributionId;
        newDistribution.totalAmount = totalAmount;
        newDistribution.validatorShare = validatorShareAmount;
        newDistribution.companyShare = companyShareAmount;
        newDistribution.developmentShare = developmentShareAmount;
        newDistribution.timestamp = block.timestamp;
        newDistribution.validatorCount = validatorAddresses.length;
        newDistribution.completed = false;

        // Calculate individual validator rewards based on participation scores
        uint256 totalParticipationScore = 0;
        for (uint256 i = 0; i < participationScores.length; i++) {
            totalParticipationScore += participationScores[i];
        }

        // Distribute to validators
        for (uint256 i = 0; i < validatorAddresses.length; i++) {
            address validator = validatorAddresses[i];
            uint256 score = participationScores[i];

            // Calculate validator's share based on participation score
            uint256 validatorReward = totalParticipationScore > 0
                ? (validatorShareAmount * score) / totalParticipationScore
                : 0;

            if (validatorReward > 0) {
                // Update validator info (always works)
                validators[validator].validatorAddress = validator;
                validators[validator].participationScore = score;
                validators[validator].isActive = true;

                // Add to public pending rewards (always works)
                validatorPendingRewards[validator][address(feeToken)] += validatorReward;

                // Use MPC for privacy features if available
                if (isMpcAvailable) {
                    // Encrypt validator reward for privacy using COTI V2 MPC
                    gtUint64 gtReward = MpcCore.setPublic64(uint64(validatorReward));
                    ctUint64 encryptedReward = MpcCore.offBoard(gtReward);
                    
                    gtBool gtFalse = MpcCore.setPublic(false);
                    ctBool notClaimed = MpcCore.offBoard(gtFalse);
                    
                    // Initialize private earnings if not set
                    gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
                    ctUint64 ctZero = MpcCore.offBoard(gtZero);
                    
                    gtUint64 gtCurrentEarnings = MpcCore.onBoard(validatorPrivateEarnings[validator]);
                    gtBool isZero = MpcCore.eq(gtCurrentEarnings, gtZero);
                    
                    if (MpcCore.decrypt(isZero)) {
                        validatorPrivateEarnings[validator] = ctZero;
                        validators[validator].privateTotalRewards = ctZero;
                    }

                    // Store distribution info with privacy
                    newDistribution.validatorDistributions[validator] = ValidatorDistribution({
                        amount: validatorReward,
                        participationScore: score,
                        claimed: false,
                        privateAmount: encryptedReward,
                        privateClaimed: notClaimed
                    });
                    
                    // Add to private rewards using MPC operations
                    gtUint64 gtCurrentPrivateRewards = MpcCore.onBoard(validatorPrivateRewards[validator][address(feeToken)]);
                    gtUint64 gtNewPrivateRewards = MpcCore.add(gtCurrentPrivateRewards, gtReward);
                    validatorPrivateRewards[validator][address(feeToken)] = MpcCore.offBoard(gtNewPrivateRewards);

                    // Update total private earnings
                    gtUint64 gtCurrentTotalEarnings = MpcCore.onBoard(validatorPrivateEarnings[validator]);
                    gtUint64 gtNewTotalEarnings = MpcCore.add(gtCurrentTotalEarnings, gtReward);
                    validatorPrivateEarnings[validator] = MpcCore.offBoard(gtNewTotalEarnings);
                    validators[validator].privateTotalRewards = MpcCore.offBoard(gtNewTotalEarnings);

                    // Emit privacy event
                    bytes32 encryptedHash = keccak256(abi.encode(encryptedReward, validator, block.timestamp));
                    emit PrivateValidatorRewardDistributed(validator, encryptedHash, currentDistributionId);

                } else {
                    // MPC not available - store distribution info without privacy features
                    newDistribution.validatorDistributions[validator] = ValidatorDistribution({
                        amount: validatorReward,
                        participationScore: score,
                        claimed: false,
                        privateAmount: ctUint64.wrap(0), // Default encrypted value
                        privateClaimed: ctBool.wrap(0)   // Default encrypted value
                    });
                }
            }
        }

        // Allocate company and development shares
        companyPendingWithdrawals[address(feeToken)] += companyShareAmount;
        developmentPendingWithdrawals[
            address(feeToken)
        ] += developmentShareAmount;

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
        require(pendingAmount > 0, "No pending rewards");

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
            
            require(MpcCore.decrypt(hasRewards), "No private rewards");

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
            require(pendingAmount > 0, "No private rewards (fallback to public)");
            
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
        require(amount > 0, "Amount must be positive");
        require(
            companyPendingWithdrawals[token] >= amount,
            "Insufficient company funds"
        );

        companyPendingWithdrawals[token] -= amount;
        IERC20(token).safeTransfer(companyTreasury, amount);

        emit CompanyFeesWithdrawn(token, amount, companyTreasury);
    }

    /**
     * @dev Withdraw development fees
     */
    function withdrawDevelopmentFees(
        address token,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        require(amount > 0, "Amount must be positive");
        require(
            developmentPendingWithdrawals[token] >= amount,
            "Insufficient development funds"
        );

        developmentPendingWithdrawals[token] -= amount;
        IERC20(token).safeTransfer(developmentFund, amount);

        emit DevelopmentFeesWithdrawn(token, amount, developmentFund);
    }

    /**
     * @dev Update distribution ratios
     */
    function updateDistributionRatios(
        uint256 _validatorShare,
        uint256 _companyShare,
        uint256 _developmentShare
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _validatorShare + _companyShare + _developmentShare == 10000,
            "Ratios must sum to 100%"
        );
        require(
            _validatorShare >= 5000,
            "Validator share must be at least 50%"
        );

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
        require(_distributionInterval >= 1 hours, "Interval too short");
        require(
            _minimumDistributionAmount > 0,
            "Minimum amount must be positive"
        );

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
        require(_companyTreasury != address(0), "Invalid company treasury");
        require(_developmentFund != address(0), "Invalid development fund");

        companyTreasury = _companyTreasury;
        developmentFund = _developmentFund;
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
        require(weight <= 10000, "Weight cannot exceed 100%");
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
        require(
            msg.sender == validator || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access denied: private rewards"
        );
        return validatorPrivateRewards[validator][token];
    }

    /**
     * @dev Get validator's total private earnings (only accessible by validator or admin)
     */
    function getValidatorPrivateEarnings(
        address validator
    ) external view returns (ctUint64) {
        require(
            msg.sender == validator || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access denied: private earnings"
        );
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
        require(index < feeCollections.length, "Index out of bounds");
        return feeCollections[index];
    }

    function canDistribute() external view returns (bool) {
        uint256 totalAmount = feeToken.balanceOf(address(this)) -
            companyPendingWithdrawals[address(feeToken)] -
            developmentPendingWithdrawals[address(feeToken)];

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
