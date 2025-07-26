// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./OmniCoinCore.sol";

/**
 * @title PrivacyFeeManager
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
    
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_COTI_RESERVE = 1000 * 10**18; // 1000 COTI minimum
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    OmniCoinCore public immutable omniCoin;
    address public cotiToken;
    address public dexRouter;
    
    // Fee structure (in basis points)
    mapping(bytes32 => uint256) public privacyFees;
    
    // Reserves
    uint256 public omniCoinReserve;
    uint256 public cotiReserve;
    uint256 public targetCotiReserve = 5000 * 10**18; // 5000 COTI target
    
    // Statistics
    uint256 public totalFeesCollected;
    uint256 public totalPrivacyTransactions;
    mapping(address => uint256) public userPrivacyUsage;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event PrivacyFeeCollected(
        address indexed user,
        bytes32 indexed operationType,
        uint256 omniAmount,
        uint256 timestamp
    );
    
    event ReservesRebalanced(
        uint256 omniSwapped,
        uint256 cotiReceived,
        uint256 timestamp
    );
    
    event FeeUpdated(
        bytes32 indexed operationType,
        uint256 oldFee,
        uint256 newFee
    );
    
    event CotiWithdrawn(
        address indexed recipient,
        uint256 amount,
        string reason
    );
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _omniCoin,
        address _cotiToken,
        address _dexRouter,
        address _admin
    ) {
        require(_omniCoin != address(0), "Invalid OmniCoin address");
        require(_cotiToken != address(0), "Invalid COTI address");
        require(_dexRouter != address(0), "Invalid DEX router");
        require(_admin != address(0), "Invalid admin address");
        
        omniCoin = OmniCoinCore(_omniCoin);
        cotiToken = _cotiToken;
        dexRouter = _dexRouter;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        // Initialize default privacy fees
        _initializeDefaultFees();
    }
    
    // =============================================================================
    // FEE MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Initialize default privacy fees for different operations
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
     * @dev Calculate privacy fee for a given operation
     * @param operationType Type of operation
     * @param amount Transaction amount (for percentage-based fees)
     * @return feeAmount Fee in OmniCoins
     */
    function calculatePrivacyFee(
        bytes32 operationType,
        uint256 amount
    ) public view returns (uint256 feeAmount) {
        uint256 fee = privacyFees[operationType];
        require(fee > 0, "Unknown operation type");
        
        // Check if it's a fixed fee (> BASIS_POINTS means fixed amount)
        if (fee > BASIS_POINTS) {
            return fee;
        }
        
        // Calculate percentage-based fee
        return (amount * fee) / BASIS_POINTS;
    }
    
    /**
     * @dev Collect privacy fee from user
     * @param user User paying the fee
     * @param operationType Type of operation
     * @param amount Transaction amount
     * @return success Whether fee collection succeeded
     */
    function collectPrivacyFee(
        address user,
        bytes32 operationType,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bool success) {
        // Only registered contracts can collect fees
        require(
            hasRole(FEE_MANAGER_ROLE, msg.sender) || 
            omniCoin.hasRole(omniCoin.BRIDGE_ROLE(), msg.sender),
            "Unauthorized fee collector"
        );
        
        uint256 feeAmount = calculatePrivacyFee(operationType, amount);
        require(feeAmount > 0, "No fee required");
        
        // Transfer fee from user to this contract
        // Note: User must approve this contract first
        require(
            IERC20(address(omniCoin)).transferFrom(user, address(this), feeAmount),
            "Fee transfer failed"
        );
        
        omniCoinReserve += feeAmount;
        totalFeesCollected += feeAmount;
        totalPrivacyTransactions++;
        userPrivacyUsage[user]++;
        
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
     * @dev Rebalance reserves by swapping OMNI for COTI
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
        emit ReservesRebalanced(omniToSwap, cotiNeeded, block.timestamp);
        
        // Update reserves (in production, after actual swap)
        omniCoinReserve -= omniToSwap;
        cotiReserve += cotiNeeded;
    }
    
    /**
     * @dev Manually rebalance reserves
     */
    function rebalanceReserves() external onlyRole(TREASURY_ROLE) {
        _rebalanceReserves();
    }
    
    /**
     * @dev Withdraw COTI for MPC operations
     * @param amount Amount to withdraw
     * @param recipient Recipient address (usually bridge or MPC operator)
     * @param reason Reason for withdrawal
     */
    function withdrawCotiForOperations(
        uint256 amount,
        address recipient,
        string calldata reason
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        require(amount <= cotiReserve, "Insufficient COTI reserve");
        require(recipient != address(0), "Invalid recipient");
        
        cotiReserve -= amount;
        
        // Transfer COTI (simplified - real implementation would use SafeERC20)
        require(
            IERC20(cotiToken).transfer(recipient, amount),
            "COTI transfer failed"
        );
        
        emit CotiWithdrawn(recipient, amount, reason);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update privacy fee for an operation type
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
     * @dev Update target COTI reserve
     * @param newTarget New target reserve amount
     */
    function updateTargetReserve(uint256 newTarget) external onlyRole(TREASURY_ROLE) {
        require(newTarget >= MIN_COTI_RESERVE, "Target too low");
        targetCotiReserve = newTarget;
    }
    
    /**
     * @dev Update DEX router address
     * @param newRouter New router address
     */
    function updateDexRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRouter != address(0), "Invalid router");
        dexRouter = newRouter;
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get user's privacy statistics
     * @param user User address
     * @return usage Number of privacy transactions
     * @return estimatedFeesPaid Estimated fees paid (based on average)
     */
    function getUserPrivacyStats(address user) external view returns (
        uint256 usage,
        uint256 estimatedFeesPaid
    ) {
        usage = userPrivacyUsage[user];
        if (totalPrivacyTransactions > 0) {
            estimatedFeesPaid = (totalFeesCollected * usage) / totalPrivacyTransactions;
        }
    }
    
    /**
     * @dev Get current reserve status
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
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Pause fee collection in emergency
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Resume fee collection
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Recover stuck tokens (emergency only)
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverTokens(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");
        require(
            IERC20(token).transfer(msg.sender, amount),
            "Recovery failed"
        );
    }
}