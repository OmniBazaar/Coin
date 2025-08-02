// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title PrivacyFeeManager
 * @author OmniCoin Development Team
 * @notice Simplified fee manager for dual-token architecture
 * @dev Simplified fee manager for dual-token architecture
 * 
 * Key Changes:
 * - Removed privacy credit system (redundant with pXOM)
 * - Direct fee collection at transaction time
 * - Fees charged in the same token type (XOM or pXOM)
 * - Bridge fees handled by the bridge contract
 */
contract PrivacyFeeManager is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Fee manager role identifier
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @notice Treasury role identifier
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    /// @notice Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    
    // Removed immutable token variables - will use registry
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Treasury address that receives collected fees
    address public treasury;
    
    // Fee structure (in basis points)
    /// @notice Mapping of operation types to fee amounts in basis points
    mapping(bytes32 => uint256) public operationFees;
    
    // Statistics
    /// @notice Total fees collected per operation type
    mapping(bytes32 => uint256) public totalFeesCollected; // operationType => amount
    /// @notice Total fees contributed by each user address
    mapping(address => uint256) public userFeesContributed;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when a fee is collected from a user
    /// @param payer Address that paid the fee
    /// @param operationType Type of operation the fee was collected for
    /// @param amount Amount of fee collected
    /// @param isPrivate Whether the fee was collected in private token
    event FeeCollected(
        address indexed payer,
        bytes32 indexed operationType,
        uint256 indexed amount,
        bool isPrivate
    );
    
    /// @notice Emitted when a fee for an operation type is updated
    /// @param operationType Type of operation being updated
    /// @param oldFee Previous fee in basis points
    /// @param newFee New fee in basis points
    event FeeUpdated(
        bytes32 indexed operationType,
        uint256 indexed oldFee,
        uint256 indexed newFee
    );
    
    /// @notice Emitted when the treasury address is updated
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidOmniCoin();
    error InvalidPrivateOmniCoin();
    error InvalidTreasury();
    error InvalidAdmin();
    error FeeTransferFailed();
    error FeeTooHigh();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the fee manager contract
     * @param _registry Address of the OmniCoinRegistry contract
     * @param _treasury Address to receive collected fees
     * @param _admin Address to be granted admin roles
     */
    constructor(
        address _registry,
        address _treasury,
        address _admin
    ) RegistryAware(_registry) {
        if (_treasury == address(0)) revert InvalidTreasury();
        if (_admin == address(0)) revert InvalidAdmin();
        
        treasury = _treasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        _initializeDefaultFees();
    }
    
    // =============================================================================
    // EXTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Collect fee in public OmniCoin (XOM)
     * @dev Collect fee in public OmniCoin (XOM)
     * @param payer Address paying the fee
     * @param operationType Type of operation
     * @param amount Transaction amount
     * @return feeAmount Amount of fee collected
     */
    function collectPublicFee(
        address payer,
        bytes32 operationType,
        uint256 amount
    ) external onlyRole(FEE_MANAGER_ROLE) whenNotPaused returns (uint256 feeAmount) {
        feeAmount = calculateFee(operationType, amount);
        if (feeAmount == 0) return 0;
        
        // Transfer fee from payer to treasury
        address omniCoin = _getContract(REGISTRY.OMNICOIN());
        if (!IERC20(omniCoin).transferFrom(payer, treasury, feeAmount))
            revert FeeTransferFailed();
        
        // Update statistics
        totalFeesCollected[operationType] = totalFeesCollected[operationType] + feeAmount;
        userFeesContributed[payer] = userFeesContributed[payer] + feeAmount;
        
        emit FeeCollected(payer, operationType, feeAmount, false);
        
        return feeAmount;
    }
    
    /**
     * @dev Collect fee in private OmniCoin (pXOM)
     * @param payer Address paying the fee
     * @param operationType Type of operation
     * @param amount Transaction amount (public value for calculation)
     * @return feeAmount Amount of fee collected
     * @notice Fee is collected in pXOM and stays private
     */
    function collectPrivateFee(
        address payer,
        bytes32 operationType,
        uint256 amount
    ) external onlyRole(FEE_MANAGER_ROLE) whenNotPaused returns (uint256 feeAmount) {
        feeAmount = calculateFee(operationType, amount);
        if (feeAmount == 0) return 0;
        
        // Use PrivateOmniCoin's transferPublic function
        // This maintains privacy while collecting fees
        address privateOmniCoin = _getContract(REGISTRY.PRIVATE_OMNICOIN());
        // Note: This needs to be called by the payer, not the fee manager
        // The actual fee collection should happen in the calling contract
        if (!IERC20(privateOmniCoin).transferFrom(payer, treasury, feeAmount))
            revert FeeTransferFailed();
        
        // Update statistics (aggregated, not linked to specific users)
        totalFeesCollected[operationType] = totalFeesCollected[operationType] + feeAmount;
        
        emit FeeCollected(payer, operationType, feeAmount, true);
        
        return feeAmount;
    }
    
    /**
     * @notice Update fee for an operation type
     * @dev Update fee for an operation type
     * @param operationType Type of operation
     * @param newFeeBasisPoints New fee in basis points
     */
    function updateFee(
        bytes32 operationType,
        uint256 newFeeBasisPoints
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBasisPoints > 1000) revert FeeTooHigh(); // Max 10%
        
        uint256 oldFee = operationFees[operationType];
        operationFees[operationType] = newFeeBasisPoints;
        
        emit FeeUpdated(operationType, oldFee, newFeeBasisPoints);
    }
    
    /**
     * @notice Update treasury address
     * @dev Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(TREASURY_ROLE) {
        if (newTreasury == address(0)) revert InvalidTreasury();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Pause all fee collection operations
     * @dev Only admin can pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume fee collection operations
     * @dev Only admin can unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Get total fees collected for all operations
     * @dev Get total fees collected for all operations
     * @return total Total fees collected
     */
    function getTotalFeesCollected() external view returns (uint256 total) {
        bytes32[8] memory operations = [
            keccak256("TRANSFER"),
            keccak256("ESCROW"),
            keccak256("PAYMENT_STREAM"),
            keccak256("STAKING"),
            keccak256("DEX"),
            keccak256("NFT_LISTING"),
            keccak256("ARBITRATION"),
            keccak256("BRIDGE_CONVERSION")
        ];
        
        for (uint256 i = 0; i < operations.length; ++i) {
            total = total + totalFeesCollected[operations[i]];
        }
    }
    
    /**
     * @notice Check if an address is authorized to collect fees
     * @dev Check if an address is authorized to collect fees
     * @param collector Address to check
     * @return isAuthorized Whether the address can collect fees
     */
    function isAuthorizedCollector(address collector) external view returns (bool isAuthorized) {
        return hasRole(FEE_MANAGER_ROLE, collector);
    }
    
    // =============================================================================
    // PUBLIC FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Calculate fee for an operation
     * @dev Calculate fee for an operation
     * @param operationType Type of operation
     * @param amount Transaction amount
     * @return feeAmount Fee in token units
     */
    function calculateFee(
        bytes32 operationType,
        uint256 amount
    ) public view returns (uint256) {
        uint256 feeBasisPoints = operationFees[operationType];
        if (feeBasisPoints == 0) return 0;
        
        return (amount * feeBasisPoints) / BASIS_POINTS;
    }
    
    // =============================================================================
    // PRIVATE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Initialize default fee values for various operations
     * @dev Called during contract construction to set initial fee structure
     */
    function _initializeDefaultFees() private {
        // Standard operations (basis points)
        operationFees[keccak256("TRANSFER")] = 0; // Free for basic transfers
        operationFees[keccak256("ESCROW")] = 50; // 0.5%
        operationFees[keccak256("PAYMENT_STREAM")] = 30; // 0.3%
        operationFees[keccak256("STAKING")] = 20; // 0.2%
        operationFees[keccak256("DEX")] = 10; // 0.1%
        operationFees[keccak256("NFT_LISTING")] = 100; // 1%
        operationFees[keccak256("ARBITRATION")] = 200; // 2%
        
        // Bridge conversion fee
        operationFees[keccak256("BRIDGE_CONVERSION")] = 100; // 1% for privacy conversion
    }
}