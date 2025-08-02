// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoin
 * @author OmniCoin Development Team
 * @notice Standard ERC20 token for public transactions on COTI V2
 * @dev Main public token - users bridge to PrivateOmniCoin for privacy features
 * 
 * Features:
 * - Standard ERC20 with configurable decimals (default: 6)
 * - Role-based access control
 * - Pausable for emergency stops
 * - Burnable for supply management
 * - Registry integration for cross-contract communication
 */
contract OmniCoin is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ReentrancyGuard, RegistryAware {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct ValidatorOperation {
        address initiator;    // 20 bytes
        bool executed;        // 1 byte
        // 11 bytes padding
        uint256 amount;       // 32 bytes
        uint256 timestamp;    // 32 bytes - Time tracking required for validator operations
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for minting new tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Role for pausing token transfers
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Role for validator operations
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    /// @notice Role for bridge operations
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    /// @notice Decimals used by the token (configurable: 6, 12, or 18)
    uint8 public constant DECIMALS = 18;
    
    /// @notice Initial circulating supply (~4.1 billion tokens)
    /// @dev Already distributed: block subsidy (1.34B) + dev subsidy (2.52B) + welcome (0.02B) +
    ///      referral (0.005B) + faucet/burned (0.26B)
    uint256 public constant INITIAL_SUPPLY = 4_132_353_934 * 10**DECIMALS;
    
    /// @notice Maximum token supply (25 billion total)
    /// @dev ~12.5 billion remaining to be minted over 40 years via block rewards and bonuses
    uint256 public constant MAX_SUPPLY = 25_000_000_000 * 10**DECIMALS;
    
    /// @notice Maximum supply cap (immutable)
    uint256 public immutable MAX_SUPPLY_CAP;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Registry of approved validators
    mapping(address => bool) public validators;
    
    /// @notice Validator operation tracking
    mapping(bytes32 => ValidatorOperation) public validatorOperations;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a validator is added
     * @param validator Address of the new validator
     */
    event ValidatorAdded(address indexed validator);
    /**
     * @notice Emitted when a validator is removed
     * @param validator Address of the removed validator
     */
    event ValidatorRemoved(address indexed validator);
    
    /**
     * @notice Emitted when a validator operation is initiated
     * @param operationId Unique operation identifier
     * @param initiator Address that initiated the operation
     * @param amount Amount involved in the operation
     */
    event ValidatorOperationInitiated(bytes32 indexed operationId, address indexed initiator, uint256 indexed amount);
    
    /**
     * @notice Emitted when a validator operation is executed
     * @param operationId Unique operation identifier
     */
    event ValidatorOperationExecuted(bytes32 indexed operationId);
    
    /**
     * @notice Emitted when tokens are transferred to bridge
     * @param from Address sending tokens
     * @param bridge Bridge contract address
     * @param amount Amount transferred
     */
    event BridgeTransferInitiated(address indexed from, address indexed bridge, uint256 indexed amount);
    
    /**
     * @notice Emitted when registry update is requested
     * @param newRegistry Address of the requested new registry
     */
    event RegistryUpdateRequested(address indexed newRegistry);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    /// @notice Thrown when minting would exceed max supply cap
    error ExceedsMaxSupply();
    /// @notice Thrown when validator address is invalid
    error InvalidValidator();
    /// @notice Thrown when amount parameter is invalid
    error InvalidAmount();
    /// @notice Thrown when validator operation is not found
    error OperationNotFound();
    /// @notice Thrown when validator operation has already been executed
    error OperationAlreadyExecuted();
    /// @notice Thrown when caller is not an authorized validator
    error UnauthorizedValidator();
    /// @notice Thrown when address parameter is zero address
    error ZeroAddress();
    /// @notice Thrown when bridge transfer operation fails
    error BridgeTransferFailed();
    /// @notice Thrown when account has insufficient balance for operation
    error InsufficientBalance();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the OmniCoin token with initial supply
     * @param _registry Address of the OmniCoinRegistry contract
     */
    constructor(address _registry) 
        ERC20("OmniCoin", "XOM") 
        RegistryAware(_registry) 
    {
        if (_registry == address(0)) revert InvalidRegistry();
        
        MAX_SUPPLY_CAP = MAX_SUPPLY;
        
        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        
        // Mint initial supply to deployer
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    // =============================================================================
    // MINTING & BURNING
    // =============================================================================
    
    /**
     * @notice Mint new tokens
     * @dev Restricted to MINTER_ROLE, checks max supply cap
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY_CAP) revert ExceedsMaxSupply();
        _mint(to, amount);
    }
    
    
    // =============================================================================
    // VALIDATOR MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Add a new validator
     * @dev Restricted to DEFAULT_ADMIN_ROLE
     * @param validator Address to add as validator
     */
    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidValidator();
        validators[validator] = true;
        emit ValidatorAdded(validator);
    }
    
    /**
     * @notice Remove an existing validator
     * @dev Restricted to DEFAULT_ADMIN_ROLE
     * @param validator Address to remove from validators
     */
    function removeValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validators[validator] = false;
        emit ValidatorRemoved(validator);
    }
    
    
    // =============================================================================
    // VALIDATOR OPERATIONS
    // =============================================================================
    
    /**
     * @notice Initiate a validator operation
     * @dev Restricted to validators, stores operation for later execution
     * @param operationId Unique operation identifier
     * @param amount Amount involved in the operation
     */
    function initiateValidatorOperation(
        bytes32 operationId, 
        uint256 amount
    ) external {
        if (!isValidator(msg.sender)) revert UnauthorizedValidator();
        if (validatorOperations[operationId].executed) revert OperationAlreadyExecuted();
        
        validatorOperations[operationId] = ValidatorOperation({
            initiator: msg.sender,
            amount: amount,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            executed: false
        });
        
        emit ValidatorOperationInitiated(operationId, msg.sender, amount);
    }
    
    /**
     * @notice Execute a validator operation
     * @dev Restricted to validators, marks operation as executed
     * @param operationId Operation identifier to execute
     */
    function executeValidatorOperation(bytes32 operationId) external {
        if (!isValidator(msg.sender)) revert UnauthorizedValidator();
        ValidatorOperation storage op = validatorOperations[operationId];
        if (op.initiator == address(0)) revert OperationNotFound();
        if (op.executed) revert OperationAlreadyExecuted();
        
        op.executed = true;
        emit ValidatorOperationExecuted(operationId);
    }
    
    // =============================================================================
    // BRIDGE OPERATIONS
    // =============================================================================
    
    /**
     * @notice Initiate transfer to bridge for conversion to PrivateOmniCoin
     * @dev Transfers tokens to bridge contract from caller's balance
     * @param amount Amount to transfer to bridge
     */
    function transferToBridge(uint256 amount) external nonReentrant whenNotPaused {
        address bridge = REGISTRY.getContract(keccak256("OMNICOIN_BRIDGE"));
        if (bridge == address(0)) revert ZeroAddress();
        
        _transfer(msg.sender, bridge, amount);
        emit BridgeTransferInitiated(msg.sender, bridge, amount);
    }
    
    // =============================================================================
    // PAUSE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Pause the contract
     * @dev Pauses all token transfers, restricted to PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     * @dev Resumes token transfers, restricted to PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Update the registry address (admin only)
     * @dev Emits RegistryUpdateRequested event for tracking
     * @param newRegistry New registry address
     */
    function setRegistry(address newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRegistry == address(0)) revert InvalidRegistry();
        // Note: registry is immutable in RegistryAware, so this would need refactoring
        // For now, emit event to track intention
        emit RegistryUpdateRequested(newRegistry);
    }
    
    // =============================================================================
    // PUBLIC FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Burn tokens from a specific address
     * @dev Restricted to BRIDGE_ROLE for bridge operations
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
    
    /**
     * @notice Get the number of decimal places for the token
     * @dev Returns DECIMALS constant for easy configuration
     * @return decimals Number of decimal places (configurable: 6, 12, or 18)
     */
    function decimals() public view virtual override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @notice Check if an address is a validator
     * @dev Checks both the validators mapping and VALIDATOR_ROLE
     * @param account Address to check
     * @return bool True if the address is a validator
     */
    function isValidator(address account) public view returns (bool) {
        return validators[account] || hasRole(VALIDATOR_ROLE, account);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Internal token transfer logic
     * @dev Override required by Solidity for multiple inheritance
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param value Amount of tokens to transfer
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}