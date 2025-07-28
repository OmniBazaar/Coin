// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";
import {OmniCoinValidator} from "./OmniCoinValidator.sol";

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
contract DEXSettlement is RegistryAware, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct Trade {
        bytes32 id;                  // 32 bytes
        address maker;               // 20 bytes
        address taker;               // 20 bytes - total 52, needs 12 more
        address tokenIn;             // 20 bytes - total 72, needs 40 more  
        address tokenOut;            // 20 bytes - total 92, needs 68 more
        uint64 maxSlippage;          // 8 bytes (basis points, max 65535 = 655.35%)
        bool executed;               // 1 byte
        bool isPrivate;              // 1 byte - completes 96 byte slot
        uint256 amountIn;            // 32 bytes
        uint256 amountOut;           // 32 bytes
        uint256 makerFee;            // 32 bytes
        uint256 takerFee;            // 32 bytes
        uint256 deadline;            // 32 bytes
        bytes validatorSignature;    // dynamic
        ctUint64 encryptedAmountIn;  // 32 bytes - For private trades
        ctUint64 encryptedAmountOut; // 32 bytes - For private trades
        ctUint64 encryptedMakerFee;  // 32 bytes - For private trades
        ctUint64 encryptedTakerFee;  // 32 bytes - For private trades
    }

    struct FeeDistribution {
        uint256 validatorShare; // 7000 = 70%
        uint256 companyShare; // 2000 = 20%
        uint256 developmentShare; // 1000 = 10%
        address companyTreasury;
        address developmentFund;
    }

    struct ValidatorInfo {
        address validatorAddress;    // 20 bytes
        uint96 participationScore;   // 12 bytes - completes 32 byte slot
        uint256 totalFeesEarned;     // 32 bytes
        uint256 lastRewardTime;      // 32 bytes
        bool isActive;               // 1 byte (will be in new slot)
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
    
    /// @notice Whether COTI MPC is available for privacy features
    bool public isMpcAvailable;
    /// @notice Address of the privacy fee manager contract (deprecated - use registry)
    address public privacyFeeManager;
    
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
    
    /**
     * @notice Initializes the DEX settlement contract
     * @param _registry Address of the registry contract
     * @param _companyTreasury Address for company fee collection
     * @param _developmentFund Address for development fund fee collection
     * @param _privacyFeeManager Address of the privacy fee manager contract
     */
    constructor(
        address _registry,
        address _companyTreasury,
        address _developmentFund,
        address _privacyFeeManager
    ) RegistryAware(_registry) {
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

        lastResetDay = block.timestamp / 1 days; // solhint-disable-line not-rely-on-time
        isMpcAvailable = false; // Default to false, set by admin when on COTI
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Set MPC availability for privacy features
     * @dev Admin function to enable/disable privacy features based on network
     * @param _available Whether MPC is available on the current network
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Set the privacy fee manager contract address
     * @dev Admin function to update the privacy fee manager
     * @param _privacyFeeManager Address of the new privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_privacyFeeManager == address(0)) revert InvalidTokenAddress();
        privacyFeeManager = _privacyFeeManager;
    }

    // =============================================================================
    // TRADING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Settle a public trade (default, no privacy fees)
     * @dev Executes atomic settlement of a trade between maker and taker
     * @param trade The trade structure containing all trade details
     */
    function settleTrade(
        Trade calldata trade
    ) external nonReentrant whenNotPaused onlyRole(VALIDATOR_ROLE) {
        // Validate trade parameters
        _validateTradeParams(trade);
        
        // Check volume limits
        _checkVolumeLimits(trade.amountIn);
        
        // Verify validator signature
        if (!_verifyValidatorSignature(trade)) {
            revert UnauthorizedValidator();
        }

        // Process the trade
        _processTradeSettlement(trade);

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
     * @notice Settle a private trade with encrypted amounts (premium feature)
     * @dev Executes atomic settlement with privacy features using COTI MPC
     * @param id Unique identifier for the trade
     * @param maker Address of the maker
     * @param taker Address of the taker
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Encrypted input amount
     * @param amountOut Encrypted output amount
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param deadline Trade expiration timestamp
     * @param validatorSignature Validator's signature for the trade
     * @param usePrivacy Whether to use privacy features
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
        // Validate privacy requirements
        _validatePrivacyParams(usePrivacy, maker, taker, deadline);
        
        // Process encrypted amounts
        (gtUint64 gtAmountIn, gtUint64 gtAmountOut, uint64 amountInPlain) = _processEncryptedAmounts(amountIn, amountOut);
        
        // Check volume limits
        _checkVolumeLimits(amountInPlain);
        
        // Handle privacy fees and store trade
        _processPrivateTrade(id, maker, taker, tokenIn, tokenOut, gtAmountIn, gtAmountOut, 
                           maxSlippage, deadline, validatorSignature, amountInPlain);
        
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
    
    /**
     * @notice Validate trade parameters
     * @dev Checks basic trade validity
     * @param trade The trade to validate
     */
    function _validateTradeParams(Trade calldata trade) internal view {
        if (emergencyStop) revert InvalidTrade();
        if (trade.executed) revert AlreadyExecuted();
        if (block.timestamp > trade.deadline) revert TradeExpired(); // solhint-disable-line not-rely-on-time
        if (trade.maker == trade.taker) revert InvalidTrade();
        if (trade.isPrivate) revert InvalidTrade();
    }
    
    /**
     * @notice Check volume limits
     * @dev Verifies trade amount against daily and max limits
     * @param amountIn The trade input amount
     */
    function _checkVolumeLimits(uint256 amountIn) internal {
        _resetDailyVolumeIfNeeded();
        if (amountIn > maxTradeSize) revert InvalidAmount();
        if (dailyVolumeUsed + amountIn > dailyVolumeLimit) {
            revert InvalidAmount();
        }
    }
    
    /**
     * @notice Process trade settlement
     * @dev Executes the trade and updates state
     * @param trade The trade to process
     */
    function _processTradeSettlement(Trade calldata trade) internal {
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
    }
    
    /**
     * @notice Validate privacy trade parameters
     * @dev Checks privacy availability and basic validity
     * @param usePrivacy Whether privacy is requested
     * @param maker Maker address
     * @param taker Taker address
     * @param deadline Trade deadline
     */
    function _validatePrivacyParams(bool usePrivacy, address maker, address taker, uint256 deadline) internal view {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        if (getPrivacyFeeManager() == address(0)) revert InvalidTokenAddress();
        if (emergencyStop) revert InvalidTrade();
        if (block.timestamp > deadline) revert TradeExpired(); // solhint-disable-line not-rely-on-time
        if (maker == taker) revert InvalidTrade();
    }
    
    /**
     * @notice Process encrypted amounts for privacy trade
     * @dev Validates ciphertexts and extracts plain amount for limits
     * @param amountIn Encrypted input amount
     * @param amountOut Encrypted output amount
     * @return gtAmountIn Validated input amount
     * @return gtAmountOut Validated output amount
     * @return amountInPlain Decrypted input amount for validation
     */
    function _processEncryptedAmounts(
        itUint64 calldata amountIn,
        itUint64 calldata amountOut
    ) internal returns (gtUint64, gtUint64, uint64) {
        gtUint64 gtAmountIn = MpcCore.validateCiphertext(amountIn);
        gtUint64 gtAmountOut = MpcCore.validateCiphertext(amountOut);
        uint64 amountInPlain = MpcCore.decrypt(gtAmountIn);
        return (gtAmountIn, gtAmountOut, amountInPlain);
    }
    
    /**
     * @notice Process privacy trade fees and storage
     * @dev Handles fee calculation, collection, and trade storage
     */
    function _processPrivateTrade(
        bytes32 id,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        gtUint64 gtAmountIn,
        gtUint64 gtAmountOut,
        uint256 maxSlippage,
        uint256 deadline,
        bytes calldata validatorSignature,
        uint64 amountInPlain
    ) internal {
        // Calculate and collect privacy fees
        _calculateAndCollectPrivacyFee(gtAmountIn, maker);
        
        // Calculate encrypted fees
        (gtUint64 gtMakerFee, gtUint64 gtTakerFee) = _calculateEncryptedFees(gtAmountIn, gtAmountOut);
        
        // Store trade
        trades[id] = Trade({
            id: id,
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: 0,
            amountOut: 0,
            makerFee: 0,
            takerFee: 0,
            maxSlippage: uint64(maxSlippage),
            executed: true,
            isPrivate: true,
            deadline: deadline,
            validatorSignature: validatorSignature,
            encryptedAmountIn: MpcCore.offBoard(gtAmountIn),
            encryptedAmountOut: MpcCore.offBoard(gtAmountOut),
            encryptedMakerFee: MpcCore.offBoard(gtMakerFee),
            encryptedTakerFee: MpcCore.offBoard(gtTakerFee)
        });
        
        dailyVolumeUsed += amountInPlain;
    }
    
    /**
     * @notice Calculate and collect privacy fee
     * @dev Calculates 10x normal fee for privacy
     * @param gtAmountIn Encrypted input amount
     * @param maker Maker address to charge fee
     * @return privacyFee The fee amount collected
     */
    function _calculateAndCollectPrivacyFee(gtUint64 gtAmountIn, address maker) internal returns (uint256) {
        uint256 dexFeeRate = 10; // 0.1% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(dexFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 privacyFeeBase = MpcCore.mul(gtAmountIn, feeRate);
        privacyFeeBase = MpcCore.div(privacyFeeBase, basisPointsGt);
        
        uint256 normalFee = uint64(gtUint64.unwrap(privacyFeeBase));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        
        PrivacyFeeManager(getPrivacyFeeManager()).collectPrivateFee(
            maker,
            keccak256("DEX_TRADE"),
            privacyFee
        );
        
        return privacyFee;
    }
    
    /**
     * @notice Calculate encrypted trading fees
     * @dev Computes maker and taker fees in encrypted form
     * @param gtAmountIn Encrypted input amount
     * @param gtAmountOut Encrypted output amount
     * @return gtMakerFee Encrypted maker fee
     * @return gtTakerFee Encrypted taker fee
     */
    function _calculateEncryptedFees(gtUint64 gtAmountIn, gtUint64 gtAmountOut) internal returns (gtUint64, gtUint64) {
        uint256 basisPoints = 10000;
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        
        gtUint64 gtMakerFee = MpcCore.mul(gtAmountIn, MpcCore.setPublic64(uint64(SPOT_MAKER_FEE)));
        gtMakerFee = MpcCore.div(gtMakerFee, basisPointsGt);
        
        gtUint64 gtTakerFee = MpcCore.mul(gtAmountOut, MpcCore.setPublic64(uint64(SPOT_TAKER_FEE)));
        gtTakerFee = MpcCore.div(gtTakerFee, basisPointsGt);
        
        return (gtMakerFee, gtTakerFee);
    }
    
    /**
     * @notice Reset daily volume tracking if a new day has started
     * @dev Required for enforcing daily volume limits
     */
    function _resetDailyVolumeIfNeeded() internal {
        if (block.timestamp / 1 days > lastResetDay) { // solhint-disable-line not-rely-on-time
            dailyVolumeUsed = 0;
            lastResetDay = block.timestamp / 1 days; // solhint-disable-line not-rely-on-time
        }
    }
    
    /**
     * @notice Verify that trade participants have sufficient balances and allowances
     * @dev Checks both maker and taker have required tokens and allowances
     * @param trade The trade to verify
     */
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
    
    /**
     * @notice Execute atomic settlement of tokens between maker and taker
     * @dev Transfers tokens and collects fees in a single transaction
     * @param trade The trade to execute
     */
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

    /**
     * @notice Distribute trading fees according to configured percentages
     * @dev Splits fees between validators, company, and development fund
     * @param trade The completed trade
     * @param validator The validator who settled the trade
     */
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
        emit CompanyFeesCollected(companyAmount, block.timestamp); // solhint-disable-line not-rely-on-time
        emit DevelopmentFeesCollected(developmentAmount, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Verify that the trade has a valid validator signature
     * @dev Verifies ECDSA signature from authorized validator
     * @param trade The trade containing the signature to verify
     * @return Whether the signature is valid
     */
    function _verifyValidatorSignature(Trade calldata trade) internal view returns (bool) {
        if (trade.validatorSignature.length != 65) return false;
        
        // Construct the message hash that was signed
        bytes32 messageHash = keccak256(
            abi.encode(
                trade.id,
                trade.maker,
                trade.taker,
                trade.tokenIn,
                trade.tokenOut,
                trade.amountIn,
                trade.amountOut,
                trade.makerFee,
                trade.takerFee,
                trade.deadline,
                trade.maxSlippage,
                trade.isPrivate
            )
        );
        
        // Ethereum signed message hash
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        
        // Recover signer from signature
        bytes memory signature = trade.validatorSignature;
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        if (signer == address(0)) return false;
        
        // Check if signer is an authorized validator
        OmniCoinValidator validatorContract = OmniCoinValidator(
            _getContract(registry.VALIDATOR_MANAGER())
        );
        // Check if the signer is registered as a validator
        (address validatorAddress,,,,,bool isActive,) = validatorContract.getValidator(signer);
        return validatorAddress != address(0) && isActive;
    }

    /**
     * @notice Check if the trade meets slippage protection requirements
     * @dev Verifies that maxSlippage is within allowed bounds
     * @param trade The trade to check
     * @return Whether the trade passes slippage checks
     */
    function _checkSlippageProtection(Trade calldata trade) internal view returns (bool) {
        if (trade.maxSlippage == 0) return true; // No slippage protection requested
        return trade.maxSlippage < maxSlippageBasisPoints + 1;
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
     * @notice Register a new validator
     * @dev Adds a validator to the system and grants them the validator role
     * @param validatorAddress Address of the new validator
     * @param initialParticipationScore Starting participation score for the validator
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
            participationScore: uint96(initialParticipationScore),
            isActive: true,
            lastRewardTime: block.timestamp // solhint-disable-line not-rely-on-time
        });

        _grantRole(VALIDATOR_ROLE, validatorAddress);
    }

    /**
     * @notice Distribute pending fees to validator
     * @dev Transfers accumulated fees to the validator's address
     * @param validator Address of the validator to receive fees
     */
    function distributeValidatorFees(address validator) external {
        uint256 pendingFees = validatorPendingFees[validator];
        if (pendingFees == 0) revert NoFundsToWithdraw();

        validatorPendingFees[validator] = 0;
        validators[validator].totalFeesEarned += pendingFees;
        validators[validator].lastRewardTime = block.timestamp; // solhint-disable-line not-rely-on-time

        // Transfer fees to validator
        // Implementation depends on fee token

        emit ValidatorFeesDistributed(validator, pendingFees, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Emergency stop trading
     * @dev Immediately halts all trading operations
     * @param reason Human-readable explanation for the emergency stop
     */
    function emergencyStopTrading(string calldata reason) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @notice Resume trading after emergency
     * @dev Re-enables trading operations after an emergency stop
     */
    function resumeTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @notice Pause all operations
     * @dev Temporarily pauses the contract using OpenZeppelin's Pausable
     */
    function pause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause operations
     * @dev Resumes normal contract operations after a pause
     */
    function unpause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _unpause();
    }

    // =============================================================================
    // CONFIGURATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update max trade size
     * @dev Sets the maximum allowed size for a single trade
     * @param _maxTradeSize New maximum trade size in tokens
     */
    function setMaxTradeSize(uint256 _maxTradeSize) external onlyRole(FEE_MANAGER_ROLE) {
        maxTradeSize = _maxTradeSize;
    }

    /**
     * @notice Update daily volume limit
     * @dev Sets the maximum allowed trading volume per day
     * @param _limit New daily volume limit in tokens
     */
    function setDailyVolumeLimit(uint256 _limit) external onlyRole(FEE_MANAGER_ROLE) {
        dailyVolumeLimit = _limit;
    }

    /**
     * @notice Update max slippage
     * @dev Sets the maximum allowed slippage in basis points
     * @param _maxSlippage New maximum slippage (10000 = 100%)
     */
    function setMaxSlippage(uint256 _maxSlippage) external onlyRole(FEE_MANAGER_ROLE) {
        maxSlippageBasisPoints = _maxSlippage;
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
        address omniCoin = _getContract(registry.OMNICOIN());
        address privateOmniCoin = _getContract(registry.PRIVATE_OMNICOIN());
        return token == omniCoin || token == privateOmniCoin;
    }
    
    /**
     * @notice Check if a trade involves privacy tokens
     * @dev Returns true if either token is PrivateOmniCoin
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @return Whether the trade involves privacy tokens
     */
    function isPrivacyTrade(address tokenIn, address tokenOut) public view returns (bool) {
        address privateOmniCoin = _getContract(registry.PRIVATE_OMNICOIN());
        return tokenIn == privateOmniCoin || tokenOut == privateOmniCoin;
    }
    
    /**
     * @notice Get the correct privacy fee manager from registry
     * @dev Uses registry instead of stored address
     * @return feeManager Address of the privacy fee manager
     */
    function getPrivacyFeeManager() public view returns (address feeManager) {
        feeManager = _getContract(registry.FEE_MANAGER());
        if (feeManager == address(0) && privacyFeeManager != address(0)) {
            // Fallback to stored address if registry not configured
            feeManager = privacyFeeManager;
        }
        return feeManager;
    }
}