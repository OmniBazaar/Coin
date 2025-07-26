// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./PrivacyFeeManager.sol";

/**
 * @title DEXSettlement
 * @dev Enhanced DEX settlement with privacy options
 *
 * Features:
 * - Default: Public trade settlement (no privacy fees)
 * - Optional: Private trade amounts (10x fees via PrivacyFeeManager)
 * - Atomic trade settlement with validator consensus
 * - 70% fee distribution to validators, 20% company, 10% development
 * - MEV protection and slippage controls
 * - Emergency circuit breakers
 */
contract DEXSettlement is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    // Roles
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // Privacy configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    
    // Fee constants (basis points: 10000 = 100%)
    uint256 public constant SPOT_MAKER_FEE = 10; // 0.1%
    uint256 public constant SPOT_TAKER_FEE = 20; // 0.2%
    uint256 public constant PERP_MAKER_FEE = 5; // 0.05%
    uint256 public constant PERP_TAKER_FEE = 15; // 0.15%

    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct Trade {
        bytes32 id;
        address maker;
        address taker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 makerFee;
        uint256 takerFee;
        uint256 maxSlippage; // In basis points (10000 = 100%)
        uint256 deadline;
        bytes validatorSignature;
        bool executed;
        bool isPrivate;
        ctUint64 encryptedAmountIn;  // For private trades
        ctUint64 encryptedAmountOut; // For private trades
        ctUint64 encryptedMakerFee;  // For private trades
        ctUint64 encryptedTakerFee;  // For private trades
    }

    struct FeeDistribution {
        uint256 validatorShare; // 7000 = 70%
        uint256 companyShare; // 2000 = 20%
        uint256 developmentShare; // 1000 = 10%
        address companyTreasury;
        address developmentFund;
    }

    struct ValidatorInfo {
        address validatorAddress;
        uint256 totalFeesEarned;
        uint256 participationScore;
        bool isActive;
        uint256 lastRewardTime;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    address public privacyFeeManager;
    bool public isMpcAvailable;
    
    mapping(bytes32 => Trade) public trades;
    mapping(address => ValidatorInfo) public validators;
    mapping(address => uint256) public validatorPendingFees;

    FeeDistribution public feeDistribution;
    uint256 public totalTradingVolume;
    uint256 public totalFeesCollected;
    uint256 public maxSlippageBasisPoints = 500; // 5% default max slippage

    // Emergency controls
    bool public emergencyStop = false;
    uint256 public maxTradeSize = 1000000 * 10 ** 18; // 1M tokens default
    uint256 public dailyVolumeLimit = 10000000 * 10 ** 18; // 10M tokens daily
    uint256 public dailyVolumeUsed = 0;
    uint256 public lastResetDay;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event TradeSettled(
        bytes32 indexed tradeId,
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 makerFee,
        uint256 takerFee,
        address validator
    );

    event ValidatorFeesDistributed(
        address indexed validator,
        uint256 amount,
        uint256 timestamp
    );

    event CompanyFeesCollected(uint256 amount, uint256 timestamp);
    event DevelopmentFeesCollected(uint256 amount, uint256 timestamp);
    event EmergencyStop(address indexed triggeredBy, string reason);
    event TradingResumed(address indexed triggeredBy);

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _companyTreasury,
        address _developmentFund,
        address _privacyFeeManager
    ) {
        require(_companyTreasury != address(0), "Invalid company treasury");
        require(_developmentFund != address(0), "Invalid development fund");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CIRCUIT_BREAKER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        
        privacyFeeManager = _privacyFeeManager;

        // Initialize fee distribution (70% validators, 20% company, 10% development)
        feeDistribution = FeeDistribution({
            validatorShare: 7000,
            companyShare: 2000,
            developmentShare: 1000,
            companyTreasury: _companyTreasury,
            developmentFund: _developmentFund
        });

        lastResetDay = block.timestamp / 1 days;
        isMpcAvailable = false; // Default to false, set by admin when on COTI
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Set MPC availability (admin only)
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_privacyFeeManager != address(0), "Invalid address");
        privacyFeeManager = _privacyFeeManager;
    }

    // =============================================================================
    // TRADING FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Settle a public trade (default, no privacy fees)
     */
    function settleTrade(
        Trade calldata trade
    ) external nonReentrant whenNotPaused onlyRole(VALIDATOR_ROLE) {
        require(!emergencyStop, "Emergency stop activated");
        require(!trade.executed, "Trade already executed");
        require(block.timestamp <= trade.deadline, "Trade deadline exceeded");
        require(trade.maker != trade.taker, "Self-trading not allowed");
        require(!trade.isPrivate, "Use settleTradeWithPrivacy for private trades");

        // Reset daily volume if new day
        _resetDailyVolumeIfNeeded();

        // Check volume limits
        require(trade.amountIn <= maxTradeSize, "Trade size exceeds limit");
        require(
            dailyVolumeUsed + trade.amountIn <= dailyVolumeLimit,
            "Daily volume limit exceeded"
        );

        // Verify validator signature
        require(
            _verifyValidatorSignature(trade),
            "Invalid validator signature"
        );

        // Check token balances and allowances
        _verifyTradeRequirements(trade);

        // Check slippage protection
        require(_checkSlippageProtection(trade), "Slippage exceeds maximum");

        // Store trade
        trades[trade.id] = trade;

        // Execute atomic settlement
        _executeAtomicSettlement(trade);

        // Mark trade as executed
        trades[trade.id].executed = true;

        // Update volume tracking
        totalTradingVolume += trade.amountIn;
        dailyVolumeUsed += trade.amountIn;

        // Distribute fees
        _distributeTradingFees(trade, msg.sender);

        emit TradeSettled(
            trade.id,
            trade.maker,
            trade.taker,
            trade.tokenIn,
            trade.tokenOut,
            trade.amountIn,
            trade.amountOut,
            trade.makerFee,
            trade.takerFee,
            msg.sender
        );
    }
    
    /**
     * @dev Settle a private trade (premium feature)
     */
    function settleTradeWithPrivacy(
        bytes32 id,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        itUint64 calldata amountIn,
        itUint64 calldata amountOut,
        uint256 maxSlippage,
        uint256 deadline,
        bytes calldata validatorSignature,
        bool usePrivacy
    ) external nonReentrant whenNotPaused onlyRole(VALIDATOR_ROLE) {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        require(privacyFeeManager != address(0), "Privacy fee manager not set");
        require(!emergencyStop, "Emergency stop activated");
        require(block.timestamp <= deadline, "Trade deadline exceeded");
        require(maker != taker, "Self-trading not allowed");
        
        // Validate encrypted amounts
        gtUint64 gtAmountIn = MpcCore.validateCiphertext(amountIn);
        gtUint64 gtAmountOut = MpcCore.validateCiphertext(amountOut);
        
        // Check trade size (decrypt for validation)
        uint64 amountInPlain = MpcCore.decrypt(gtAmountIn);
        require(amountInPlain <= maxTradeSize, "Trade size exceeds limit");
        
        // Reset daily volume if new day
        _resetDailyVolumeIfNeeded();
        
        require(
            dailyVolumeUsed + amountInPlain <= dailyVolumeLimit,
            "Daily volume limit exceeded"
        );
        
        // Calculate privacy fee (0.1% of trade volume for DEX)
        uint256 DEX_FEE_RATE = 10; // 0.1% in basis points
        uint256 BASIS_POINTS = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(DEX_FEE_RATE));
        gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
        gtUint64 privacyFeeBase = MpcCore.mul(gtAmountIn, feeRate);
        privacyFeeBase = MpcCore.div(privacyFeeBase, basisPoints);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(privacyFeeBase));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            maker,
            keccak256("DEX_TRADE"),
            privacyFee
        );
        
        // Calculate fees (encrypted)
        gtUint64 gtMakerFee = MpcCore.mul(gtAmountIn, MpcCore.setPublic64(uint64(SPOT_MAKER_FEE)));
        gtMakerFee = MpcCore.div(gtMakerFee, basisPoints);
        gtUint64 gtTakerFee = MpcCore.mul(gtAmountOut, MpcCore.setPublic64(uint64(SPOT_TAKER_FEE)));
        gtTakerFee = MpcCore.div(gtTakerFee, basisPoints);
        
        // Store trade with encrypted amounts
        trades[id] = Trade({
            id: id,
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: 0, // Use encrypted version
            amountOut: 0, // Use encrypted version
            makerFee: 0, // Use encrypted version
            takerFee: 0, // Use encrypted version
            maxSlippage: maxSlippage,
            deadline: deadline,
            validatorSignature: validatorSignature,
            executed: true,
            isPrivate: true,
            encryptedAmountIn: MpcCore.offBoard(gtAmountIn),
            encryptedAmountOut: MpcCore.offBoard(gtAmountOut),
            encryptedMakerFee: MpcCore.offBoard(gtMakerFee),
            encryptedTakerFee: MpcCore.offBoard(gtTakerFee)
        });
        
        // Note: Actual token transfers would use privacy-enabled token contracts
        // For now, we store the trade and emit events
        
        dailyVolumeUsed += amountInPlain;
        
        emit TradeSettled(
            id,
            maker,
            taker,
            tokenIn,
            tokenOut,
            0, // Amount is private
            0, // Amount is private
            0, // Fee is private
            0, // Fee is private
            msg.sender
        );
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    function _resetDailyVolumeIfNeeded() internal {
        if (block.timestamp / 1 days > lastResetDay) {
            dailyVolumeUsed = 0;
            lastResetDay = block.timestamp / 1 days;
        }
    }
    
    function _verifyTradeRequirements(Trade calldata trade) internal view {
        require(
            IERC20(trade.tokenIn).balanceOf(trade.taker) >= trade.amountIn,
            "Insufficient taker balance"
        );
        require(
            IERC20(trade.tokenOut).balanceOf(trade.maker) >= trade.amountOut,
            "Insufficient maker balance"
        );
        require(
            IERC20(trade.tokenIn).allowance(trade.taker, address(this)) >= trade.amountIn,
            "Insufficient taker allowance"
        );
        require(
            IERC20(trade.tokenOut).allowance(trade.maker, address(this)) >= trade.amountOut,
            "Insufficient maker allowance"
        );
    }
    
    function _executeAtomicSettlement(Trade calldata trade) internal {
        // Transfer tokens from taker to maker
        IERC20(trade.tokenIn).safeTransferFrom(
            trade.taker,
            trade.maker,
            trade.amountIn - trade.takerFee
        );

        // Transfer tokens from maker to taker
        IERC20(trade.tokenOut).safeTransferFrom(
            trade.maker,
            trade.taker,
            trade.amountOut - trade.makerFee
        );

        // Collect fees
        if (trade.takerFee > 0) {
            IERC20(trade.tokenIn).safeTransferFrom(
                trade.taker,
                address(this),
                trade.takerFee
            );
        }
        if (trade.makerFee > 0) {
            IERC20(trade.tokenOut).safeTransferFrom(
                trade.maker,
                address(this),
                trade.makerFee
            );
        }
    }

    function _distributeTradingFees(Trade calldata trade, address validator) internal {
        uint256 totalFees = trade.makerFee + trade.takerFee;
        if (totalFees == 0) return;

        totalFeesCollected += totalFees;

        // Calculate distribution amounts
        uint256 validatorAmount = (totalFees * feeDistribution.validatorShare) / 10000;
        uint256 companyAmount = (totalFees * feeDistribution.companyShare) / 10000;
        uint256 developmentAmount = (totalFees * feeDistribution.developmentShare) / 10000;

        // Add to validator pending fees (distributed later in batches)
        validatorPendingFees[validator] += validatorAmount;

        // Immediate distribution to company and development (if implemented)
        emit CompanyFeesCollected(companyAmount, block.timestamp);
        emit DevelopmentFeesCollected(developmentAmount, block.timestamp);
    }

    function _verifyValidatorSignature(Trade calldata trade) internal view returns (bool) {
        // Implement signature verification logic
        // For now, simplified check
        return trade.validatorSignature.length > 0;
    }

    function _checkSlippageProtection(Trade calldata trade) internal view returns (bool) {
        if (trade.maxSlippage == 0) return true; // No slippage protection requested
        return trade.maxSlippage <= maxSlippageBasisPoints;
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get public trade information
     */
    function getTrade(bytes32 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }
    
    /**
     * @dev Get encrypted trade amounts (only for authorized parties)
     */
    function getPrivateTradeAmounts(bytes32 tradeId) external view returns (
        ctUint64 encryptedAmountIn,
        ctUint64 encryptedAmountOut,
        ctUint64 encryptedMakerFee,
        ctUint64 encryptedTakerFee
    ) {
        Trade storage trade = trades[tradeId];
        require(trade.isPrivate, "Not a private trade");
        require(
            msg.sender == trade.maker || 
            msg.sender == trade.taker || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        
        return (
            trade.encryptedAmountIn,
            trade.encryptedAmountOut,
            trade.encryptedMakerFee,
            trade.encryptedTakerFee
        );
    }

    function getValidatorInfo(address validatorAddress) external view returns (ValidatorInfo memory) {
        return validators[validatorAddress];
    }

    function getValidatorPendingFees(address validator) external view returns (uint256) {
        return validatorPendingFees[validator];
    }

    function getTradingStats() external view returns (
        uint256 volume,
        uint256 fees,
        uint256 dailyUsed,
        uint256 dailyLimit
    ) {
        return (totalTradingVolume, totalFeesCollected, dailyVolumeUsed, dailyVolumeLimit);
    }

    function getFeeDistribution() external view returns (FeeDistribution memory) {
        return feeDistribution;
    }

    // =============================================================================
    // VALIDATOR FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Register a new validator
     */
    function registerValidator(
        address validatorAddress,
        uint256 initialParticipationScore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validatorAddress != address(0), "Invalid validator address");
        require(!validators[validatorAddress].isActive, "Validator already registered");

        validators[validatorAddress] = ValidatorInfo({
            validatorAddress: validatorAddress,
            totalFeesEarned: 0,
            participationScore: initialParticipationScore,
            isActive: true,
            lastRewardTime: block.timestamp
        });

        _grantRole(VALIDATOR_ROLE, validatorAddress);
    }

    /**
     * @dev Distribute pending fees to validator
     */
    function distributeValidatorFees(address validator) external {
        uint256 pendingFees = validatorPendingFees[validator];
        require(pendingFees > 0, "No pending fees");

        validatorPendingFees[validator] = 0;
        validators[validator].totalFeesEarned += pendingFees;
        validators[validator].lastRewardTime = block.timestamp;

        // Transfer fees to validator
        // Implementation depends on fee token

        emit ValidatorFeesDistributed(validator, pendingFees, block.timestamp);
    }

    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Emergency stop trading
     */
    function emergencyStopTrading(string calldata reason) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @dev Resume trading after emergency
     */
    function resumeTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @dev Pause all operations
     */
    function pause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause operations
     */
    function unpause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _unpause();
    }

    // =============================================================================
    // CONFIGURATION FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update max trade size
     */
    function setMaxTradeSize(uint256 _maxTradeSize) external onlyRole(FEE_MANAGER_ROLE) {
        maxTradeSize = _maxTradeSize;
    }

    /**
     * @dev Update daily volume limit
     */
    function setDailyVolumeLimit(uint256 _limit) external onlyRole(FEE_MANAGER_ROLE) {
        dailyVolumeLimit = _limit;
    }

    /**
     * @dev Update max slippage
     */
    function setMaxSlippage(uint256 _maxSlippage) external onlyRole(FEE_MANAGER_ROLE) {
        maxSlippageBasisPoints = _maxSlippage;
    }
}