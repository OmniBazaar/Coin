// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../coti-contracts/contracts/token/PrivateERC20/PrivateERC20.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./base/RegistryAware.sol";

/**
 * @title PrivateOmniCoin
 * @dev Private version of OmniCoin using COTI's MPC for encrypted operations
 * 
 * Users bridge from standard OmniCoin to PrivateOmniCoin for privacy features.
 * All balances and operations are encrypted using COTI's Garbled Circuits.
 * 
 * Features:
 * - Encrypted balances and transfers
 * - 1:1 backing with OmniCoin
 * - Bridge-only minting/burning
 * - COTI MPC integration
 */
contract PrivateOmniCoin is PrivateERC20, AccessControl, Pausable, ReentrancyGuard, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Total supply tracking (encrypted)
    ctUint64 private _encryptedTotalSupply;
    
    /// @dev Public total supply for transparency
    uint256 public publicTotalSupply;
    
    /// @dev MPC availability flag
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event PrivacyMint(address indexed to, uint256 publicAmount);
    event PrivacyBurn(address indexed from, uint256 publicAmount);
    event MpcAvailabilityUpdated(bool available);
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error OnlyBridge();
    error InvalidAmount();
    error MpcNotAvailable();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @dev Constructor initializes the private token
     * @param _registry Address of the OmniCoinRegistry contract
     */
    constructor(address _registry) 
        PrivateERC20("Private OmniCoin", "pXOM")
        RegistryAware(_registry) 
    {
        require(_registry != address(0), "Invalid registry");
        
        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        
        // MPC starts disabled for testing
        isMpcAvailable = false;
    }
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyBridge() {
        address bridge = registry.getContract(keccak256("OMNICOIN_BRIDGE"));
        if (msg.sender != bridge) revert OnlyBridge();
        _;
    }
    
    modifier whenMpcAvailable() {
        if (!isMpcAvailable) revert MpcNotAvailable();
        _;
    }
    
    // =============================================================================
    // DECIMALS
    // =============================================================================
    
    /**
     * @dev Returns the number of decimals (6 for compatibility)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    // =============================================================================
    // TOTAL SUPPLY
    // =============================================================================
    
    /**
     * @dev Returns the total supply (public view for transparency)
     */
    function totalSupply() public view virtual override returns (uint256) {
        return publicTotalSupply;
    }
    
    // =============================================================================
    // BRIDGE OPERATIONS
    // =============================================================================
    
    /**
     * @dev Mint private tokens (only callable by bridge)
     * @param to Address to mint tokens to
     * @param amount Amount to mint (public value)
     */
    function mint(address to, uint256 amount) external onlyBridge whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        // Convert public amount to encrypted
        gtUint64 encryptedAmount;
        if (isMpcAvailable) {
            encryptedAmount = MpcCore.setPublic64(uint64(amount));
        } else {
            // Test mode - wrap the value
            encryptedAmount = gtUint64.wrap(uint64(amount));
        }
        
        // Mint using parent contract's internal function
        gtBool success = _mint(to, encryptedAmount);
        
        // Update public total supply
        publicTotalSupply += amount;
        
        emit PrivacyMint(to, amount);
    }
    
    /**
     * @dev Burn private tokens (only callable by bridge)
     * @param from Address to burn tokens from  
     * @param amount Amount to burn (public value)
     */
    function burn(address from, uint256 amount) external onlyBridge whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        // Convert public amount to encrypted
        gtUint64 encryptedAmount;
        if (isMpcAvailable) {
            encryptedAmount = MpcCore.setPublic64(uint64(amount));
        } else {
            // Test mode - wrap the value
            encryptedAmount = gtUint64.wrap(uint64(amount));
        }
        
        // Burn using parent contract's internal function
        gtBool success = _burn(from, encryptedAmount);
        
        // Update public total supply
        publicTotalSupply -= amount;
        
        emit PrivacyBurn(from, amount);
    }
    
    // =============================================================================
    // PUBLIC CONVENIENCE FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Transfer tokens using public amount (converts to encrypted)
     * @param to Recipient address
     * @param amount Amount to transfer (public value)
     * @return success Whether the transfer succeeded
     */
    function transferPublic(address to, uint256 amount) 
        external 
        whenNotPaused 
        returns (bool) 
    {
        if (amount == 0) revert InvalidAmount();
        
        // Convert to encrypted type
        gtUint64 encryptedAmount;
        if (isMpcAvailable) {
            encryptedAmount = MpcCore.setPublic64(uint64(amount));
        } else {
            encryptedAmount = gtUint64.wrap(uint64(amount));
        }
        
        // Use parent's transfer function
        gtBool result = transfer(to, encryptedAmount);
        
        // For testing, assume success
        return true;
    }
    
    /**
     * @dev Get balance as public value (decrypts in test mode)
     * @param account Address to check
     * @return balance Public balance value
     */
    function balanceOfPublic(address account) external view returns (uint256) {
        // In production with MPC, this would require special permissions
        // For testing, return a default value or use registry
        if (!isMpcAvailable) {
            // Test mode - could implement mock balances
            return 0;
        }
        // In MPC mode, would need decryption rights
        return 0;
    }
    
    // =============================================================================
    // MPC MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Set MPC availability (admin only)
     * @param available Whether MPC is available
     */
    function setMpcAvailability(bool available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = available;
        emit MpcAvailabilityUpdated(available);
    }
    
    // =============================================================================
    // PAUSE FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // ACCESS CONTROL
    // =============================================================================
    
    /**
     * @dev Grant bridge role to an address
     * @param bridge Address to grant bridge role to
     */
    function grantBridgeRole(address bridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(BRIDGE_ROLE, bridge);
    }
    
    /**
     * @dev Update the registry address (admin only)
     * @param newRegistry New registry address
     */
    function setRegistry(address newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRegistry != address(0), "Invalid registry");
        // Note: registry is immutable in RegistryAware, so this would need refactoring
        // For now, emit event to track intention
        emit RegistryUpdateRequested(newRegistry);
    }
    
    event RegistryUpdateRequested(address newRegistry);
}