// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OmniCoin} from "./OmniCoin.sol";

/**
 * @title PrivacyFeeManager
 * @author OmniCoin Development Team
 * @notice Manages privacy fees for OmniCoin transactions
 * @dev Manages privacy fees for OmniCoin transactions
 * 
 * Key Features:
 * - Users pay privacy fees in OmniCoins
 * - Contract maintains a COTI reserve for MPC operations
 * - Automatic conversion via DEX when reserves are low
 * - Configurable fee tiers based on operation type
 * 
 * Architecture:
 * - Public transactions: FREE (processed by OmniCoin validators)
 * - Private transactions: Premium fee (requires COTI MPC)
 */
contract PrivacyFeeManager is AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Fee manager role identifier
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @notice Treasury role identifier
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    /// @notice Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    /// @notice Minimum COTI reserve required (1000 COTI)
    uint256 public constant MIN_COTI_RESERVE = 1000 * 10**18;
    
    /// @notice OmniCoin token contract reference
    OmniCoin public immutable OMNI_COIN;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error MustDepositCredits();
    error TransferFromFailed();
    error InsufficientCredits();
    error TransferFailed();
    error UnknownOperationType();
    error NotAuthorized();
    error NoFeeRequired();
    error InsufficientPrivacyCredits();
    error InsufficientCotiReserve();
    error TargetTooLow();
    error InvalidRouter();
    error InvalidToken();
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    /// @notice COTI token address for MPC operations
    address public cotiToken;
    /// @notice DEX router for OmniCoin/COTI swaps
    address public dexRouter;
    
    /// @notice Fee structure (in basis points) by operation type
    mapping(bytes32 => uint256) public privacyFees;
    
    // Reserves
    /// @notice OmniCoin reserve balance
    uint256 public omniCoinReserve;
    /// @notice COTI reserve balance for MPC operations
    uint256 public cotiReserve;
    /// @notice Target COTI reserve level (5000 COTI)
    uint256 public targetCotiReserve = 5000 * 10**18;
    
    // Statistics
    /// @notice Total fees collected in OmniCoin
    uint256 public totalFeesCollected;
    /// @notice Total number of privacy transactions
    uint256 public totalPrivacyTransactions;
    /// @notice Privacy usage count by user
    mapping(address => uint256) public userPrivacyUsage;
    
    // Privacy Credit System
    /// @notice User privacy credit balances
    mapping(address => uint256) public userPrivacyCredits;
    /// @notice Total credits deposited by all users
    uint256 public totalCreditsDeposited;
    /// @notice Total credits used by all users
    uint256 public totalCreditsUsed;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when privacy fee is collected
     * @param user User who paid the fee
     * @param operationType Type of privacy operation
     * @param omniAmount Amount of OmniCoin collected
     * @param timestamp When the fee was collected
     */
    event PrivacyFeeCollected(
        address indexed user,
        bytes32 indexed operationType,
        uint256 indexed omniAmount,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when reserves are rebalanced
     * @param omniSwapped Amount of OmniCoin swapped
     * @param cotiReceived Amount of COTI received
     * @param timestamp When rebalancing occurred
     */
    event ReservesRebalanced(
        uint256 indexed omniSwapped,
        uint256 indexed cotiReceived,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when fee is updated
     * @param operationType Type of operation
     * @param oldFee Previous fee amount
     * @param newFee New fee amount
     */
    event FeeUpdated(
        bytes32 indexed operationType,
        uint256 indexed oldFee,
        uint256 indexed newFee
    );
    
    /**
     * @notice Emitted when COTI is withdrawn
     * @param recipient Recipient address
     * @param amount Amount withdrawn
     * @param reason Reason for withdrawal
     */
    event CotiWithdrawn(
        address indexed recipient,
        uint256 indexed amount,
        string reason
    );
    
    /**
     * @notice Emitted when privacy credits are deposited
     * @param user User who deposited
     * @param amount Amount deposited
     * @param newBalance New credit balance
     */
    event PrivacyCreditsDeposited(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed newBalance
    );
    
    /**
     * @notice Emitted when privacy credits are used
     * @param user User who used credits
     * @param operationType Type of operation
     * @param amount Amount of credits used
     * @param remainingBalance Remaining credit balance
     */
    event PrivacyCreditsUsed(
        address indexed user,
        bytes32 indexed operationType,
        uint256 indexed amount,
        uint256 remainingBalance
    );
    
    /**
     * @notice Emitted when bridge usage is recorded
     * @param user User who used the bridge
     * @param amount Amount bridged
     */
    event BridgeUsageRecorded(address indexed user, uint256 indexed amount);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initializes the PrivacyFeeManager contract
     * @dev Sets up token addresses, router, and grants admin roles
     * @param _omniCoin Address of the OmniCoin token contract
     * @param _cotiToken Address of the COTI token contract  
     * @param _dexRouter Address of the DEX router for token swaps
     * @param _admin Address of the initial admin who receives all roles
     */
    constructor(
        address _omniCoin,
        address _cotiToken,
        address _dexRouter,
        address _admin
    ) {
        if (_omniCoin == address(0)) revert InvalidAddress();
        if (_cotiToken == address(0)) revert InvalidToken();
        if (_dexRouter == address(0)) revert InvalidRouter();
        if (_admin == address(0)) revert InvalidAddress();
        
        OMNI_COIN = OmniCoin(_omniCoin);
        cotiToken = _cotiToken;
        dexRouter = _dexRouter;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        // Initialize default privacy fees
        _initializeDefaultFees();
    }
    
    // =============================================================================
    // PRIVACY CREDITS
    // =============================================================================
    
    /**
     * @dev Deposit privacy credits for future use
     * @param amount Amount of OMNI tokens to deposit as credits
     * @notice Users pre-fund their privacy operations to avoid timing correlation
     */
    function depositPrivacyCredits(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert MustDepositCredits();
        
        // Transfer OMNI tokens from user
        if (!IERC20(address(OMNI_COIN)).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFromFailed();
        }
        
        userPrivacyCredits[msg.sender] += amount;
        totalCreditsDeposited += amount;
        omniCoinReserve += amount;
        
        emit PrivacyCreditsDeposited(
            msg.sender, 
            amount, 
            userPrivacyCredits[msg.sender]
        );
    }
    
    /**
     * @notice Withdraw unused privacy credits
     * @dev Transfers OMNI tokens back to the user from their credit balance
     * @param amount Amount to withdraw
     */
    function withdrawPrivacyCredits(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (userPrivacyCredits[msg.sender] < amount) revert InsufficientCredits();
        
        userPrivacyCredits[msg.sender] -= amount;
        omniCoinReserve -= amount;
        
        // Transfer OMNI back to user
        if (!IERC20(address(OMNI_COIN)).transfer(msg.sender, amount)) {
            revert TransferFailed();
        }
        
        emit PrivacyCreditsDeposited(
            msg.sender, 
            0, 
            userPrivacyCredits[msg.sender]
        );
    }
    
    /**
     * @notice Check user's privacy credit balance
     * @dev Returns the amount of privacy credits a user has deposited
     * @param user User address
     * @return Current credit balance
     */
    function getPrivacyCredits(address user) external view returns (uint256) {
        return userPrivacyCredits[user];
    }
    
    // =============================================================================
    // FEE MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Initialize default privacy fees for different operations
     * @dev Sets up the initial fee structure for various operation types
     */
    function _initializeDefaultFees() private {
        // Transfer operations: 0.1% (10 basis points)
        privacyFees[keccak256("TRANSFER")] = 10;
        
        // Escrow operations: 0.5% (50 basis points)
        privacyFees[keccak256("ESCROW")] = 50;
        
        // Payment stream: 0.3% (30 basis points)
        privacyFees[keccak256("PAYMENT_STREAM")] = 30;
        
        // Staking operations: 0.2% (20 basis points)
        privacyFees[keccak256("STAKING")] = 20;
        
        // DEX operations: 0.1% (10 basis points)
        privacyFees[keccak256("DEX")] = 10;
        
        // Fixed fee operations (not percentage based)
        privacyFees[keccak256("REPUTATION_UPDATE")] = 1 * 10**6; // 1 OMNI
        privacyFees[keccak256("IDENTITY_VERIFICATION")] = 5 * 10**6; // 5 OMNI
    }
    
    /**
     * @notice Calculate privacy fee for a given operation
     * @dev Determines if fee is fixed or percentage-based and calculates accordingly
     * @param operationType Type of operation
     * @param amount Transaction amount (for percentage-based fees)
     * @return feeAmount Fee in OmniCoins
     */
    function calculatePrivacyFee(
        bytes32 operationType,
        uint256 amount
    ) public view returns (uint256 feeAmount) {
        uint256 fee = privacyFees[operationType];
        if (fee == 0) revert UnknownOperationType();
        
        // Check if it's a fixed fee (> BASIS_POINTS means fixed amount)
        if (fee > BASIS_POINTS) {
            return fee;
        }
        
        // Calculate percentage-based fee
        return (amount * fee) / BASIS_POINTS;
    }
    
    /**
     * @dev Collect privacy fee from user's pre-deposited credits
     * @param user User paying the fee
     * @param operationType Type of operation
     * @param amount Transaction amount
     * @return success Whether fee collection succeeded
     * @notice This function now uses pre-deposited credits instead of direct transfers
     */
    function collectPrivacyFee(
        address user,
        bytes32 operationType,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bool success) {
        // Only registered contracts can collect fees
        if (!hasRole(FEE_MANAGER_ROLE, msg.sender) && 
            !OMNI_COIN.hasRole(keccak256("BRIDGE_ROLE"), msg.sender)) {
            revert NotAuthorized();
        }
        
        uint256 feeAmount = calculatePrivacyFee(operationType, amount);
        if (feeAmount == 0) revert NoFeeRequired();
        
        // Deduct from user's privacy credits (no visible transaction)
        if (userPrivacyCredits[user] < feeAmount) revert InsufficientPrivacyCredits();
        userPrivacyCredits[user] -= feeAmount;
        
        // Update statistics
        totalCreditsUsed += feeAmount;
        totalFeesCollected += feeAmount;
        ++totalPrivacyTransactions;
        ++userPrivacyUsage[user];
        
        emit PrivacyCreditsUsed(
            user, 
            operationType, 
            feeAmount, 
            userPrivacyCredits[user]
        );
        
        // Note: No PrivacyFeeCollected event to avoid timing correlation
        
        // Check if we need to rebalance reserves
        if (cotiReserve < MIN_COTI_RESERVE) {
            _rebalanceReserves();
        }
        
        return true;
    }
    
    /**
     * @dev Legacy fee collection with direct transfer (for backward compatibility)
     * @param user User paying the fee
     * @param operationType Type of operation
     * @param amount Transaction amount
     * @return success Whether fee collection succeeded
     * @notice This creates a visible transaction - use depositPrivacyCredits() instead
     */
    function collectPrivacyFeeDirect(
        address user,
        bytes32 operationType,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bool success) {
        // Only registered contracts can collect fees
        if (!hasRole(FEE_MANAGER_ROLE, msg.sender) && 
            !OMNI_COIN.hasRole(keccak256("BRIDGE_ROLE"), msg.sender)) {
            revert NotAuthorized();
        }
        
        uint256 feeAmount = calculatePrivacyFee(operationType, amount);
        if (feeAmount == 0) revert NoFeeRequired();
        
        // Transfer fee from user to this contract (VISIBLE TRANSACTION)
        if (!IERC20(address(OMNI_COIN)).transferFrom(user, address(this), feeAmount)) {
            revert TransferFromFailed();
        }
        
        omniCoinReserve += feeAmount;
        totalFeesCollected += feeAmount;
        ++totalPrivacyTransactions;
        ++userPrivacyUsage[user];
        
        // solhint-disable-next-line not-rely-on-time
        emit PrivacyFeeCollected(user, operationType, feeAmount, block.timestamp);
        
        // Check if we need to rebalance reserves
        if (cotiReserve < MIN_COTI_RESERVE) {
            _rebalanceReserves();
        }
        
        return true;
    }
    
    // =============================================================================
    // RESERVE MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Rebalance reserves by swapping OMNI for COTI
     * @dev Internal function to maintain adequate COTI reserves for MPC operations
     */
    function _rebalanceReserves() private {
        uint256 cotiNeeded = targetCotiReserve - cotiReserve;
        if (cotiNeeded == 0 || omniCoinReserve == 0) return;
        
        // Calculate OMNI to swap (simplified - real implementation would use DEX quotes)
        uint256 omniToSwap = (cotiNeeded * 10) / 1; // Assume 10:1 OMNI:COTI ratio
        if (omniToSwap > omniCoinReserve) {
            omniToSwap = omniCoinReserve;
        }
        
        // In production, this would call DEX router to swap
        // For now, we'll emit an event for manual processing
        // solhint-disable-next-line not-rely-on-time
        emit ReservesRebalanced(omniToSwap, cotiNeeded, block.timestamp);
        
        // Update reserves (in production, after actual swap)
        omniCoinReserve -= omniToSwap;
        cotiReserve += cotiNeeded;
    }
    
    /**
     * @notice Manually rebalance reserves
     */
    function rebalanceReserves() external onlyRole(TREASURY_ROLE) {
        _rebalanceReserves();
    }
    
    /**
     * @notice Record bridge usage for rewards/tracking
     * @param user User who used the bridge
     * @param amount Amount bridged
     */
    function recordBridgeUsage(address user, uint256 amount) external {
        // Only authorized contracts can record usage
        if (msg.sender != address(OMNI_COIN) && 
            !hasRole(FEE_MANAGER_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        // Could track usage for rewards/analytics
        emit BridgeUsageRecorded(user, amount);
    }
    
    /**
     * @notice Withdraw COTI for MPC operations
     * @param amount Amount to withdraw
     * @param recipient Recipient address (usually bridge or MPC operator)
     * @param reason Reason for withdrawal
     */
    function withdrawCotiForOperations(
        uint256 amount,
        address recipient,
        string calldata reason
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (amount > cotiReserve) revert InsufficientCotiReserve();
        if (recipient == address(0)) revert InvalidAddress();
        
        cotiReserve -= amount;
        
        // Transfer COTI (simplified - real implementation would use SafeERC20)
        if (!IERC20(cotiToken).transfer(recipient, amount)) {
            revert TransferFailed();
        }
        
        emit CotiWithdrawn(recipient, amount, reason);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update privacy fee for an operation type
     * @param operationType Type of operation
     * @param newFee New fee (basis points or fixed amount)
     */
    function updatePrivacyFee(
        bytes32 operationType,
        uint256 newFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 oldFee = privacyFees[operationType];
        privacyFees[operationType] = newFee;
        
        emit FeeUpdated(operationType, oldFee, newFee);
    }
    
    /**
     * @notice Update target COTI reserve
     * @param newTarget New target reserve amount
     */
    function updateTargetReserve(uint256 newTarget) external onlyRole(TREASURY_ROLE) {
        if (newTarget < MIN_COTI_RESERVE) revert TargetTooLow();
        targetCotiReserve = newTarget;
    }
    
    /**
     * @notice Update DEX router address
     * @param newRouter New router address
     */
    function updateDexRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidRouter();
        dexRouter = newRouter;
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get user's privacy statistics
     * @param user User address
     * @return usage Number of privacy transactions
     * @return estimatedFeesPaid Estimated fees paid (based on average)
     * @return creditBalance Current privacy credit balance
     */
    function getUserPrivacyStats(address user) external view returns (
        uint256 usage,
        uint256 estimatedFeesPaid,
        uint256 creditBalance
    ) {
        usage = userPrivacyUsage[user];
        if (totalPrivacyTransactions > 0) {
            estimatedFeesPaid = (totalFeesCollected * usage) / totalPrivacyTransactions;
        }
        creditBalance = userPrivacyCredits[user];
    }
    
    /**
     * @notice Get current reserve status
     * @return omniReserve Current OMNI reserve
     * @return cotiReserveAmount Current COTI reserve
     * @return needsRebalance Whether rebalancing is needed
     */
    function getReserveStatus() external view returns (
        uint256 omniReserve,
        uint256 cotiReserveAmount,
        bool needsRebalance
    ) {
        omniReserve = omniCoinReserve;
        cotiReserveAmount = cotiReserve;
        needsRebalance = cotiReserve < MIN_COTI_RESERVE;
    }
    
    /**
     * @notice Get privacy credit system statistics
     * @return totalDeposited Total credits deposited
     * @return totalUsed Total credits used
     * @return totalActive Total active credits in system
     * @return averageBalance Average credit balance per user
     */
    function getCreditSystemStats() external view returns (
        uint256 totalDeposited,
        uint256 totalUsed,
        uint256 totalActive,
        uint256 averageBalance
    ) {
        totalDeposited = totalCreditsDeposited;
        totalUsed = totalCreditsUsed;
        totalActive = totalCreditsDeposited - totalCreditsUsed;
        
        // Calculate average (simplified - in production would track active users)
        if (totalPrivacyTransactions > 0) {
            // Rough estimate based on total transactions
            averageBalance = totalActive / (totalPrivacyTransactions / 10 + 1);
        }
    }
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Pause fee collection in emergency
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume fee collection
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Recover stuck tokens (emergency only)
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverTokens(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidToken();
        if (!IERC20(token).transfer(msg.sender, amount))
            revert TransferFailed();
    }
}