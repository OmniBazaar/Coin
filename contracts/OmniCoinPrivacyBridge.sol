// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";
import {PrivacyFeeManagerV2} from "./PrivacyFeeManagerV2.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinPrivacyBridge
 * @dev Bridge contract for converting between OmniCoin (public) and PrivateOmniCoin (private)
 * 
 * Features:
 * - Convert OmniCoin to PrivateOmniCoin with small bridge fee (1-2%)
 * - Convert PrivateOmniCoin back to OmniCoin with no fee
 * - Maintains 1:1 backing between tokens
 * - Integrates with PrivacyFeeManager for fee collection
 */
contract OmniCoinPrivacyBridge is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_BRIDGE_FEE = 200; // 2% max
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Public token contract
    OmniCoin public immutable OMNI_COIN;
    
    /// @dev Private token contract  
    PrivateOmniCoin public immutable PRIVATE_OMNI_COIN;
    
    /// @dev Privacy fee manager
    PrivacyFeeManagerV2 public immutable PRIVACY_FEE_MANAGER;
    
    /// @dev Bridge fee in basis points (100 = 1%)
    uint256 public bridgeFee = 100; // 1% default
    
    /// @dev Total fees collected
    uint256 public totalFeesCollected;
    
    /// @dev Conversion statistics
    uint256 public totalConvertedToPrivate;
    uint256 public totalConvertedToPublic;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ConvertedToPrivate(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    
    event ConvertedToPublic(
        address indexed user,
        uint256 amount
    );
    
    event BridgeFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidAmount();
    error InsufficientBalance();
    error InvalidFee();
    error TransferFailed();
    error InvalidRecipient();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @dev Constructor
     * @param _omniCoin Address of OmniCoin contract
     * @param _privateOmniCoin Address of PrivateOmniCoin contract
     * @param _privacyFeeManager Address of PrivacyFeeManager
     * @param _registry Address of registry
     */
    constructor(
        address _omniCoin,
        address _privateOmniCoin,
        address _privacyFeeManager,
        address _registry
    ) RegistryAware(_registry) {
        if (_omniCoin == address(0)) revert InvalidAmount();
        if (_privateOmniCoin == address(0)) revert InvalidAmount();
        if (_privacyFeeManager == address(0)) revert InvalidAmount();
        
        OMNI_COIN = OmniCoin(_omniCoin);
        PRIVATE_OMNI_COIN = PrivateOmniCoin(_privateOmniCoin);
        PRIVACY_FEE_MANAGER = PrivacyFeeManagerV2(_privacyFeeManager);
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }
    
    // =============================================================================
    // MAIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Convert OmniCoin to PrivateOmniCoin
     * @param amount Amount of OmniCoin to convert
     * @return amountOut Amount of PrivateOmniCoin received
     */
    function convertToPrivate(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 amountOut) 
    {
        if (amount == 0) revert InvalidAmount();
        
        // Calculate fee
        uint256 fee = (amount * bridgeFee) / BASIS_POINTS;
        amountOut = amount - fee;
        
        // Transfer OmniCoin from user to bridge
        bool success = OMNI_COIN.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        // Mint PrivateOmniCoin to user
        PRIVATE_OMNI_COIN.mint(msg.sender, amountOut);
        
        // Record fee
        totalFeesCollected += fee;
        totalConvertedToPrivate += amount;
        
        // Fee collection is handled directly in the token transfer
        // No need for separate tracking since fees are now immediate
        
        emit ConvertedToPrivate(msg.sender, amount, amountOut, fee);
    }
    
    /**
     * @dev Convert PrivateOmniCoin back to OmniCoin (no fee)
     * @param amount Amount of PrivateOmniCoin to convert
     */
    function convertToPublic(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        
        // Check bridge has enough OmniCoin
        uint256 bridgeBalance = OMNI_COIN.balanceOf(address(this));
        if (bridgeBalance < amount) revert InsufficientBalance();
        
        // Burn PrivateOmniCoin from user
        PRIVATE_OMNI_COIN.burn(msg.sender, amount);
        
        // Transfer OmniCoin to user
        bool success = OMNI_COIN.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        totalConvertedToPublic += amount;
        
        emit ConvertedToPublic(msg.sender, amount);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update bridge fee
     * @param newFee New fee in basis points
     */
    function setBridgeFee(uint256 newFee) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFee > MAX_BRIDGE_FEE) revert InvalidFee();
        
        uint256 oldFee = bridgeFee;
        bridgeFee = newFee;
        
        emit BridgeFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @dev Withdraw collected fees
     * @param recipient Address to receive fees
     * @param amount Amount to withdraw
     */
    function withdrawFees(address recipient, uint256 amount) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
        nonReentrant 
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount > totalFeesCollected) revert InsufficientBalance();
        
        totalFeesCollected -= amount;
        
        bool success = OMNI_COIN.transfer(recipient, amount);
        if (!success) revert TransferFailed();
        
        emit FeesWithdrawn(recipient, amount);
    }
    
    /**
     * @dev Pause the bridge
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause the bridge
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get bridge statistics
     * @return publicBalance OmniCoin balance held by bridge
     * @return privateSupply Total PrivateOmniCoin supply
     * @return feesCollected Total fees collected
     * @return toPrivate Total converted to private
     * @return toPublic Total converted to public
     */
    function getBridgeStats() external view returns (
        uint256 publicBalance,
        uint256 privateSupply,
        uint256 feesCollected,
        uint256 toPrivate,
        uint256 toPublic
    ) {
        publicBalance = OMNI_COIN.balanceOf(address(this));
        privateSupply = PRIVATE_OMNI_COIN.totalSupply();
        feesCollected = totalFeesCollected;
        toPrivate = totalConvertedToPrivate;
        toPublic = totalConvertedToPublic;
    }
    
    /**
     * @dev Calculate fee for a given amount
     * @param amount Amount to convert
     * @return fee Fee amount
     * @return amountOut Amount after fee
     */
    function calculateConversionFee(uint256 amount) 
        external 
        view 
        returns (uint256 fee, uint256 amountOut) 
    {
        fee = (amount * bridgeFee) / BASIS_POINTS;
        amountOut = amount - fee;
    }
}