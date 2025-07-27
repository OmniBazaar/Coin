// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./base/RegistryAware.sol";

/**
 * @title OmniCoin
 * @dev Standard ERC20 token for public transactions on COTI V2
 * 
 * This is the main public token. For privacy features, users bridge to PrivateOmniCoin.
 * 
 * Features:
 * - Standard ERC20 with 6 decimals
 * - Role-based access control
 * - Pausable for emergency stops
 * - Burnable for supply management
 * - Registry integration for cross-contract communication
 */
contract OmniCoin is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ReentrancyGuard, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**6; // 100M tokens
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**6; // 1B tokens max
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Maximum supply cap
    uint256 public immutable maxSupply;
    
    /// @dev Registry of approved validators
    mapping(address => bool) public validators;
    
    /// @dev Validator operation tracking
    mapping(bytes32 => ValidatorOperation) public validatorOperations;
    
    struct ValidatorOperation {
        address initiator;
        uint256 amount;
        uint256 timestamp;
        bool executed;
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ValidatorOperationInitiated(bytes32 indexed operationId, address indexed initiator, uint256 amount);
    event ValidatorOperationExecuted(bytes32 indexed operationId);
    event BridgeTransferInitiated(address indexed from, address indexed bridge, uint256 amount);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @dev Constructor initializes the token with initial supply
     * @param _registry Address of the OmniCoinRegistry contract
     */
    constructor(address _registry) 
        ERC20("OmniCoin", "XOM") 
        RegistryAware(_registry) 
    {
        require(_registry != address(0), "Invalid registry");
        
        maxSupply = MAX_SUPPLY;
        
        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        
        // Mint initial supply to deployer
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    // =============================================================================
    // DECIMALS
    // =============================================================================
    
    /**
     * @dev Returns the number of decimals (6 for COTI compatibility)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    // =============================================================================
    // MINTING & BURNING
    // =============================================================================
    
    /**
     * @dev Mint new tokens (restricted to MINTER_ROLE)
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        _mint(to, amount);
    }
    
    /**
     * @dev Burn tokens from a specific address (restricted to bridge)
     * @param from Address to burn tokens from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) 
        public 
        override 
        onlyRole(BRIDGE_ROLE) 
    {
        _burn(from, amount);
    }
    
    // =============================================================================
    // VALIDATOR MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Add a validator
     * @param validator Address to add as validator
     */
    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validator != address(0), "Invalid validator");
        validators[validator] = true;
        emit ValidatorAdded(validator);
    }
    
    /**
     * @dev Remove a validator
     * @param validator Address to remove from validators
     */
    function removeValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validators[validator] = false;
        emit ValidatorRemoved(validator);
    }
    
    /**
     * @dev Check if an address is a validator
     * @param account Address to check
     * @return bool True if the address is a validator
     */
    function isValidator(address account) public view returns (bool) {
        return validators[account] || hasRole(VALIDATOR_ROLE, account);
    }
    
    // =============================================================================
    // VALIDATOR OPERATIONS
    // =============================================================================
    
    /**
     * @dev Initiate a validator operation
     * @param operationId Unique operation identifier
     * @param amount Amount involved in the operation
     */
    function initiateValidatorOperation(
        bytes32 operationId, 
        uint256 amount
    ) external {
        require(isValidator(msg.sender), "Not a validator");
        require(!validatorOperations[operationId].executed, "Already executed");
        
        validatorOperations[operationId] = ValidatorOperation({
            initiator: msg.sender,
            amount: amount,
            timestamp: block.timestamp,
            executed: false
        });
        
        emit ValidatorOperationInitiated(operationId, msg.sender, amount);
    }
    
    /**
     * @dev Execute a validator operation
     * @param operationId Operation identifier to execute
     */
    function executeValidatorOperation(bytes32 operationId) external {
        require(isValidator(msg.sender), "Not a validator");
        ValidatorOperation storage op = validatorOperations[operationId];
        require(op.initiator != address(0), "Operation not found");
        require(!op.executed, "Already executed");
        
        op.executed = true;
        emit ValidatorOperationExecuted(operationId);
    }
    
    // =============================================================================
    // BRIDGE OPERATIONS
    // =============================================================================
    
    /**
     * @dev Initiate transfer to bridge for conversion to PrivateOmniCoin
     * @param amount Amount to transfer to bridge
     */
    function transferToBridge(uint256 amount) external nonReentrant whenNotPaused {
        address bridge = registry.getContract(keccak256("OMNICOIN_BRIDGE"));
        require(bridge != address(0), "Bridge not set");
        
        _transfer(msg.sender, bridge, amount);
        emit BridgeTransferInitiated(msg.sender, bridge, amount);
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
    // OVERRIDES
    // =============================================================================
    
    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
    
    // =============================================================================
    // REGISTRY UPDATES
    // =============================================================================
    
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