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
 * @author OmniCoin Development Team
 * @notice Bridge for converting between public and private OmniCoin
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
    
    /// @notice Pauser role identifier
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Fee manager role identifier
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    /// @notice Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    /// @notice Maximum bridge fee (2%)
    uint256 public constant MAX_BRIDGE_FEE = 200;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Public token contract
    OmniCoin public immutable OMNI_COIN;
    
    /// @notice Private token contract  
    PrivateOmniCoin public immutable PRIVATE_OMNI_COIN;
    
    /// @notice Privacy fee manager
    PrivacyFeeManagerV2 public immutable PRIVACY_FEE_MANAGER;
    
    /// @notice Bridge fee in basis points (100 = 1%)
    uint256 public bridgeFee = 100; // 1% default
    
    /// @notice Total fees collected
    uint256 public totalFeesCollected;
    
    /// @notice Total amount converted to private tokens
    uint256 public totalConvertedToPrivate;
    /// @notice Total amount converted to public tokens
    uint256 public totalConvertedToPublic;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when tokens are converted to private
     * @param user User address
     * @param amountIn Amount of public tokens input
     * @param amountOut Amount of private tokens output
     * @param fee Fee charged
     */
    event ConvertedToPrivate(
        address indexed user,
        uint256 indexed amountIn,
        uint256 indexed amountOut,
        uint256 fee
    );
    
    /**
     * @notice Emitted when tokens are converted to public
     * @param user User address
     * @param amount Amount converted
     */
    event ConvertedToPublic(
        address indexed user,
        uint256 indexed amount
    );
    
    /**
     * @notice Emitted when bridge fee is updated
     * @param oldFee Previous fee
     * @param newFee New fee
     */
    event BridgeFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);
    
    /**
     * @notice Emitted when fees are withdrawn
     * @param recipient Recipient address
     * @param amount Amount withdrawn
     */
    event FeesWithdrawn(address indexed recipient, uint256 indexed amount);
    
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
     * @notice Initialize the privacy bridge
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
     * @notice Convert OmniCoin to PrivateOmniCoin
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
     * @notice Convert PrivateOmniCoin back to OmniCoin (no fee)
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
        
        // Update state before transfer
        totalConvertedToPublic += amount;
        
        // Transfer OmniCoin to user
        bool success = OMNI_COIN.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit ConvertedToPublic(msg.sender, amount);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update bridge fee
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
     * @notice Withdraw collected fees
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
     * @notice Pause the bridge
     * @dev Pause the bridge
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the bridge
     * @dev Unpause the bridge
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get bridge statistics
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
     * @notice Calculate fee for a given amount
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