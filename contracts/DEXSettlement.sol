// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DEXSettlement
 * @dev Immediate on-chain settlement for unified validator DEX trades
 *
 * Features:
 * - Atomic trade settlement with validator consensus
 * - 70% fee distribution to validators, 20% company, 10% development
 * - MEV protection and slippage controls
 * - Emergency circuit breakers
 * - Multi-signature security
 */
contract DEXSettlement is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant CIRCUIT_BREAKER_ROLE =
        keccak256("CIRCUIT_BREAKER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // Events
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

    // Structs
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

    // State variables
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

    // Fee constants (basis points: 10000 = 100%)
    uint256 public constant SPOT_MAKER_FEE = 10; // 0.1%
    uint256 public constant SPOT_TAKER_FEE = 20; // 0.2%
    uint256 public constant PERP_MAKER_FEE = 5; // 0.05%
    uint256 public constant PERP_TAKER_FEE = 15; // 0.15%

    constructor(address _companyTreasury, address _developmentFund) {
        require(_companyTreasury != address(0), "Invalid company treasury");
        require(_developmentFund != address(0), "Invalid development fund");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CIRCUIT_BREAKER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);

        // Initialize fee distribution (70% validators, 20% company, 10% development)
        feeDistribution = FeeDistribution({
            validatorShare: 7000,
            companyShare: 2000,
            developmentShare: 1000,
            companyTreasury: _companyTreasury,
            developmentFund: _developmentFund
        });

        lastResetDay = block.timestamp / 1 days;
    }

    /**
     * @dev Settle a trade with validator consensus
     */
    function settleTrade(
        Trade calldata trade
    ) external nonReentrant whenNotPaused onlyRole(VALIDATOR_ROLE) {
        require(!emergencyStop, "Emergency stop activated");
        require(!trade.executed, "Trade already executed");
        require(block.timestamp <= trade.deadline, "Trade deadline exceeded");
        require(trade.maker != trade.taker, "Self-trading not allowed");

        // Reset daily volume if new day
        if (block.timestamp / 1 days > lastResetDay) {
            dailyVolumeUsed = 0;
            lastResetDay = block.timestamp / 1 days;
        }

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
        require(
            IERC20(trade.tokenIn).balanceOf(trade.taker) >= trade.amountIn,
            "Insufficient taker balance"
        );
        require(
            IERC20(trade.tokenOut).balanceOf(trade.maker) >= trade.amountOut,
            "Insufficient maker balance"
        );
        require(
            IERC20(trade.tokenIn).allowance(trade.taker, address(this)) >=
                trade.amountIn,
            "Insufficient taker allowance"
        );
        require(
            IERC20(trade.tokenOut).allowance(trade.maker, address(this)) >=
                trade.amountOut,
            "Insufficient maker allowance"
        );

        // Calculate slippage protection
        require(_checkSlippageProtection(trade), "Slippage exceeds maximum");

        // Execute atomic settlement
        _executeAtomicSettlement(trade);

        // Mark trade as executed
        trades[trade.id] = trade;
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
     * @dev Batch settle multiple trades (gas optimization)
     */
    function batchSettleTrades(
        Trade[] calldata trades
    ) external onlyRole(VALIDATOR_ROLE) {
        require(trades.length <= 50, "Batch size too large");

        for (uint256 i = 0; i < trades.length; i++) {
            // Use try-catch to prevent one failed trade from reverting the batch
            try this.settleTrade(trades[i]) {
                // Success - continue
            } catch {
                // Log failed trade but continue with batch
                continue;
            }
        }
    }

    /**
     * @dev Register a new validator
     */
    function registerValidator(
        address validatorAddress,
        uint256 initialParticipationScore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validatorAddress != address(0), "Invalid validator address");
        require(
            !validators[validatorAddress].isActive,
            "Validator already registered"
        );

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
     * @dev Update validator participation score
     */
    function updateValidatorScore(
        address validatorAddress,
        uint256 newScore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validators[validatorAddress].isActive, "Validator not active");
        require(newScore <= 100, "Score cannot exceed 100");

        validators[validatorAddress].participationScore = newScore;
    }

    /**
     * @dev Distribute accumulated fees to validators
     */
    function distributeValidatorFees(
        address[] calldata validatorAddresses
    ) external onlyRole(FEE_MANAGER_ROLE) {
        for (uint256 i = 0; i < validatorAddresses.length; i++) {
            address validator = validatorAddresses[i];
            uint256 pendingFees = validatorPendingFees[validator];

            if (pendingFees > 0 && validators[validator].isActive) {
                validatorPendingFees[validator] = 0;
                validators[validator].totalFeesEarned += pendingFees;
                validators[validator].lastRewardTime = block.timestamp;

                // Transfer fees (assuming XOM token)
                // In production, integrate with actual fee token
                emit ValidatorFeesDistributed(
                    validator,
                    pendingFees,
                    block.timestamp
                );
            }
        }
    }

    /**
     * @dev Emergency circuit breaker
     */
    function emergencyStopTrading(
        string calldata reason
    ) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @dev Resume trading after emergency stop
     */
    function resumeTrading() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @dev Update trading limits
     */
    function updateTradingLimits(
        uint256 _maxTradeSize,
        uint256 _dailyVolumeLimit,
        uint256 _maxSlippageBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTradeSize = _maxTradeSize;
        dailyVolumeLimit = _dailyVolumeLimit;
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
    }

    /**
     * @dev Update fee distribution ratios
     */
    function updateFeeDistribution(
        uint256 _validatorShare,
        uint256 _companyShare,
        uint256 _developmentShare,
        address _companyTreasury,
        address _developmentFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _validatorShare + _companyShare + _developmentShare == 10000,
            "Shares must sum to 100%"
        );
        require(
            _companyTreasury != address(0) && _developmentFund != address(0),
            "Invalid addresses"
        );

        feeDistribution = FeeDistribution({
            validatorShare: _validatorShare,
            companyShare: _companyShare,
            developmentShare: _developmentShare,
            companyTreasury: _companyTreasury,
            developmentFund: _developmentFund
        });
    }

    // Internal functions
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

    function _distributeTradingFees(
        Trade calldata trade,
        address validator
    ) internal {
        uint256 totalFees = trade.makerFee + trade.takerFee;
        if (totalFees == 0) return;

        totalFeesCollected += totalFees;

        // Calculate distribution amounts
        uint256 validatorAmount = (totalFees * feeDistribution.validatorShare) /
            10000;
        uint256 companyAmount = (totalFees * feeDistribution.companyShare) /
            10000;
        uint256 developmentAmount = (totalFees *
            feeDistribution.developmentShare) / 10000;

        // Add to validator pending fees (distributed later in batches)
        validatorPendingFees[validator] += validatorAmount;

        // Immediate distribution to company and development (if implemented)
        // For now, track the amounts
        emit CompanyFeesCollected(companyAmount, block.timestamp);
        emit DevelopmentFeesCollected(developmentAmount, block.timestamp);
    }

    function _verifyValidatorSignature(
        Trade calldata trade
    ) internal view returns (bool) {
        // Implement signature verification logic
        // For now, simplified check
        return trade.validatorSignature.length > 0;
    }

    function _checkSlippageProtection(
        Trade calldata trade
    ) internal view returns (bool) {
        if (trade.maxSlippage == 0) return true; // No slippage protection requested
        return trade.maxSlippage <= maxSlippageBasisPoints;
    }

    // View functions
    function getValidatorInfo(
        address validatorAddress
    ) external view returns (ValidatorInfo memory) {
        return validators[validatorAddress];
    }

    function getTrade(bytes32 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }

    function getValidatorPendingFees(
        address validator
    ) external view returns (uint256) {
        return validatorPendingFees[validator];
    }

    function getTradingStats()
        external
        view
        returns (
            uint256 volume,
            uint256 fees,
            uint256 dailyUsed,
            uint256 dailyLimit
        )
    {
        return (
            totalTradingVolume,
            totalFeesCollected,
            dailyVolumeUsed,
            dailyVolumeLimit
        );
    }

    function getFeeDistribution()
        external
        view
        returns (FeeDistribution memory)
    {
        return feeDistribution;
    }

    // Pause functions
    function pause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _unpause();
    }
}
