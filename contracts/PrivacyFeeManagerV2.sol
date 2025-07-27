// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";

/**
 * @title PrivacyFeeManagerV2
 * @dev Simplified fee manager for dual-token architecture
 * 
 * Key Changes:
 * - Removed privacy credit system (redundant with pXOM)
 * - Direct fee collection at transaction time
 * - Fees charged in the same token type (XOM or pXOM)
 * - Bridge fees handled by the bridge contract
 */
contract PrivacyFeeManagerV2 is AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    uint256 public constant BASIS_POINTS = 10000;
    
    // =============================================================================
    // IMMUTABLE VARIABLES
    // =============================================================================
    
    OmniCoin public immutable OMNI_COIN;
    PrivateOmniCoin public immutable PRIVATE_OMNI_COIN;
    
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
    // STATE VARIABLES
    // =============================================================================
    address public treasury;
    
    // Fee structure (in basis points)
    mapping(bytes32 => uint256) public operationFees;
    
    // Statistics
    mapping(bytes32 => uint256) public totalFeesCollected; // operationType => amount
    mapping(address => uint256) public userFeesContributed;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event FeeCollected(
        address indexed payer,
        bytes32 indexed operationType,
        uint256 amount,
        bool isPrivate
    );
    
    event FeeUpdated(
        bytes32 indexed operationType,
        uint256 oldFee,
        uint256 newFee
    );
    
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _omniCoin,
        address _privateOmniCoin,
        address _treasury,
        address _admin
    ) {
        if (_omniCoin == address(0)) revert InvalidOmniCoin();
        if (_privateOmniCoin == address(0)) revert InvalidPrivateOmniCoin();
        if (_treasury == address(0)) revert InvalidTreasury();
        if (_admin == address(0)) revert InvalidAdmin();
        
        OMNI_COIN = OmniCoin(_omniCoin);
        PRIVATE_OMNI_COIN = PrivateOmniCoin(_privateOmniCoin);
        treasury = _treasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        _initializeDefaultFees();
    }
    
    // =============================================================================
    // FEE INITIALIZATION
    // =============================================================================
    
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
    
    // =============================================================================
    // FEE CALCULATION
    // =============================================================================
    
    /**
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
    // PUBLIC FEE COLLECTION (XOM)
    // =============================================================================
    
    /**
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
        if (!IERC20(address(OMNI_COIN)).transferFrom(payer, treasury, feeAmount))
            revert FeeTransferFailed();
        
        // Update statistics
        totalFeesCollected[operationType] += feeAmount;
        userFeesContributed[payer] += feeAmount;
        
        emit FeeCollected(payer, operationType, feeAmount, false);
        
        return feeAmount;
    }
    
    // =============================================================================
    // PRIVATE FEE COLLECTION (pXOM)
    // =============================================================================
    
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
        PRIVATE_OMNI_COIN.transferPublic(treasury, feeAmount);
        
        // Update statistics (aggregated, not linked to specific users)
        totalFeesCollected[operationType] += feeAmount;
        
        emit FeeCollected(payer, operationType, feeAmount, true);
        
        return feeAmount;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
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
     * @dev Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(TREASURY_ROLE) {
        if (newTreasury == address(0)) revert InvalidTreasury();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
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
            total += totalFeesCollected[operations[i]];
        }
    }
    
    /**
     * @dev Check if an address is authorized to collect fees
     * @param collector Address to check
     * @return isAuthorized Whether the address can collect fees
     */
    function isAuthorizedCollector(address collector) external view returns (bool) {
        return hasRole(FEE_MANAGER_ROLE, collector);
    }
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}