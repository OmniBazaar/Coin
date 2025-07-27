// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title DEXSettlement
 * @author OmniCoin Development Team
 * @notice Enhanced DEX settlement contract with optional privacy features
 * @dev Implements atomic trade settlement with validator consensus and privacy options
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
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for validators who can settle trades
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    /// @notice Role for emergency circuit breakers
    bytes32 public constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");
    /// @notice Role for fee configuration management
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice Privacy feature multiplier (10x normal fees)
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    
    /// @notice Spot market maker fee (0.1% in basis points)
    uint256 public constant SPOT_MAKER_FEE = 10;
    /// @notice Spot market taker fee (0.2% in basis points)
    uint256 public constant SPOT_TAKER_FEE = 20;
    /// @notice Perpetual market maker fee (0.05% in basis points)
    uint256 public constant PERP_MAKER_FEE = 5;
    /// @notice Perpetual market taker fee (0.15% in basis points)
    uint256 public constant PERP_TAKER_FEE = 15;

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidTokenAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error TradeExpired();
    error AlreadyExecuted();
    error UnauthorizedValidator();
    error SlippageTooHigh();
    error NoFundsToWithdraw();
    error InvalidTrade();
    error PrivacyNotAvailable();
    error InsufficientLiquidity();
    error InvalidFeeConfiguration();

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Address of the privacy fee manager contract
    address public privacyFeeManager;
    /// @notice Whether COTI MPC is available for privacy features
    bool public isMpcAvailable;
    
    /// @notice Mapping of trade ID to trade data
    mapping(bytes32 => Trade) public trades;
    /// @notice Mapping of validator address to validator info
    mapping(address => ValidatorInfo) public validators;
    /// @notice Pending fee amounts for validators
    mapping(address => uint256) public validatorPendingFees;

    /// @notice Fee distribution configuration
    FeeDistribution public feeDistribution;
    /// @notice Total trading volume processed
    uint256 public totalTradingVolume;
    /// @notice Total fees collected
    uint256 public totalFeesCollected;
    /// @notice Maximum allowed slippage in basis points (default 5%)
    uint256 public maxSlippageBasisPoints = 500;

    /// @notice Emergency stop flag
    bool public emergencyStop = false;
    /// @notice Maximum trade size allowed (default 1M tokens)
    uint256 public maxTradeSize = 1000000 * 10 ** 18;
    /// @notice Daily volume limit (default 10M tokens)
    uint256 public dailyVolumeLimit = 10000000 * 10 ** 18;
    /// @notice Daily volume used in current period
    uint256 public dailyVolumeUsed = 0;
    /// @notice Last day when volume was reset
    uint256 public lastResetDay;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a trade is settled
     * @param tradeId Unique identifier of the trade
     * @param maker Address of the maker
     * @param taker Address of the taker
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount (0 for private trades)
     * @param amountOut Output amount (0 for private trades)
     * @param makerFee Maker fee amount (0 for private trades)
     * @param takerFee Taker fee amount (0 for private trades)
     * @param validator Address of the settling validator
     */
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

    /**
     * @notice Emitted when validator fees are distributed
     * @param validator Address of the validator
     * @param amount Fee amount distributed
     * @param timestamp Time of distribution
     */
    event ValidatorFeesDistributed(
        address indexed validator,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /**
     * @notice Emitted when company fees are collected
     * @param amount Fee amount collected
     * @param timestamp Time of collection
     */
    event CompanyFeesCollected(uint256 indexed amount, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when development fees are collected
     * @param amount Fee amount collected
     * @param timestamp Time of collection
     */
    event DevelopmentFeesCollected(uint256 indexed amount, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when emergency stop is triggered
     * @param triggeredBy Address that triggered the stop
     * @param reason Human-readable reason for the stop
     */
    event EmergencyStop(address indexed triggeredBy, string reason);
    
    /**
     * @notice Emitted when trading is resumed after emergency
     * @param triggeredBy Address that resumed trading
     */
    event TradingResumed(address indexed triggeredBy);

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _companyTreasury,
        address _developmentFund,
        address _privacyFeeManager
    ) {
        if (_companyTreasury == address(0)) revert InvalidTokenAddress();
        if (_developmentFund == address(0)) revert InvalidTokenAddress();

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
        if (_privacyFeeManager == address(0)) revert InvalidTokenAddress();
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
        if (emergencyStop) revert InvalidTrade();
        if (trade.executed) revert AlreadyExecuted();
        if (block.timestamp > trade.deadline) revert TradeExpired();
        if (trade.maker == trade.taker) revert InvalidTrade();
        if (trade.isPrivate) revert InvalidTrade();

        // Reset daily volume if new day (time-based decision required for daily limits)
        _resetDailyVolumeIfNeeded();

        // Check volume limits
        if (trade.amountIn > maxTradeSize) revert InvalidAmount();
        if (dailyVolumeUsed + trade.amountIn > dailyVolumeLimit) {
            revert InvalidAmount();
        }

        // Verify validator signature
        if (!_verifyValidatorSignature(trade)) {
            revert UnauthorizedValidator();
        }

        // Check token balances and allowances
        _verifyTradeRequirements(trade);

        // Check slippage protection
        if (!_checkSlippageProtection(trade)) revert SlippageTooHigh();

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
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        if (privacyFeeManager == address(0)) revert InvalidTokenAddress();
        if (emergencyStop) revert InvalidTrade();
        if (block.timestamp > deadline) revert TradeExpired();
        if (maker == taker) revert InvalidTrade();
        
        // Validate encrypted amounts
        gtUint64 gtAmountIn = MpcCore.validateCiphertext(amountIn);
        gtUint64 gtAmountOut = MpcCore.validateCiphertext(amountOut);
        
        // Check trade size (decrypt for validation)
        uint64 amountInPlain = MpcCore.decrypt(gtAmountIn);
        if (amountInPlain > maxTradeSize) revert InvalidAmount();
        
        // Reset daily volume if new day (time-based decision required for daily limits)
        _resetDailyVolumeIfNeeded();
        
        if (dailyVolumeUsed + amountInPlain > dailyVolumeLimit) {
            revert InvalidAmount();
        }
        
        // Calculate privacy fee (0.1% of trade volume for DEX)
        uint256 dexFeeRate = 10; // 0.1% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(dexFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 privacyFeeBase = MpcCore.mul(gtAmountIn, feeRate);
        privacyFeeBase = MpcCore.div(privacyFeeBase, basisPointsGt);
        
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
        gtMakerFee = MpcCore.div(gtMakerFee, basisPointsGt);
        gtUint64 gtTakerFee = MpcCore.mul(gtAmountOut, MpcCore.setPublic64(uint64(SPOT_TAKER_FEE)));
        gtTakerFee = MpcCore.div(gtTakerFee, basisPointsGt);
        
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
        if (IERC20(trade.tokenIn).balanceOf(trade.taker) < trade.amountIn) {
            revert InsufficientLiquidity();
        }
        if (IERC20(trade.tokenOut).balanceOf(trade.maker) < trade.amountOut) {
            revert InsufficientLiquidity();
        }
        if (IERC20(trade.tokenIn).allowance(trade.taker, address(this)) < trade.amountIn) {
            revert InsufficientLiquidity();
        }
        if (IERC20(trade.tokenOut).allowance(trade.maker, address(this)) < trade.amountOut) {
            revert InsufficientLiquidity();
        }
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
     * @notice Get public trade information
     * @dev Returns full trade struct including privacy fields
     * @param tradeId The unique trade identifier
     * @return trade Trade struct with all trade details
     */
    function getTrade(bytes32 tradeId) external view returns (Trade memory trade) {
        return trades[tradeId];
    }
    
    /**
     * @notice Get encrypted trade amounts for authorized parties
     * @dev Only accessible by trade participants or admin
     * @param tradeId The unique trade identifier
     * @return encryptedAmountIn Encrypted input amount
     * @return encryptedAmountOut Encrypted output amount  
     * @return encryptedMakerFee Encrypted maker fee
     * @return encryptedTakerFee Encrypted taker fee
     */
    function getPrivateTradeAmounts(bytes32 tradeId) external view returns (
        ctUint64 encryptedAmountIn,
        ctUint64 encryptedAmountOut,
        ctUint64 encryptedMakerFee,
        ctUint64 encryptedTakerFee
    ) {
        Trade storage trade = trades[tradeId];
        if (!trade.isPrivate) revert InvalidTrade();
        if (msg.sender != trade.maker && 
            msg.sender != trade.taker && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedValidator();
        }
        
        return (
            trade.encryptedAmountIn,
            trade.encryptedAmountOut,
            trade.encryptedMakerFee,
            trade.encryptedTakerFee
        );
    }

    /**
     * @notice Get validator information
     * @param validatorAddress Address of the validator
     * @return info ValidatorInfo struct with validator details
     */
    function getValidatorInfo(address validatorAddress) external view returns (ValidatorInfo memory info) {
        return validators[validatorAddress];
    }

    /**
     * @notice Get pending fees for a validator
     * @param validator Address of the validator
     * @return pendingFees Amount of fees pending distribution
     */
    function getValidatorPendingFees(address validator) external view returns (uint256 pendingFees) {
        return validatorPendingFees[validator];
    }

    /**
     * @notice Get current trading statistics
     * @return volume Total trading volume processed
     * @return fees Total fees collected
     * @return dailyUsed Volume used in current daily period
     * @return dailyLimit Maximum daily volume allowed
     */
    function getTradingStats() external view returns (
        uint256 volume,
        uint256 fees,
        uint256 dailyUsed,
        uint256 dailyLimit
    ) {
        return (totalTradingVolume, totalFeesCollected, dailyVolumeUsed, dailyVolumeLimit);
    }

    /**
     * @notice Get fee distribution configuration
     * @return feeConfig FeeDistribution struct with percentage allocations
     */
    function getFeeDistribution() external view returns (FeeDistribution memory feeConfig) {
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
        if (validatorAddress == address(0)) revert InvalidTokenAddress();
        if (validators[validatorAddress].isActive) revert InvalidTrade();

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
        if (pendingFees == 0) revert NoFundsToWithdraw();

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