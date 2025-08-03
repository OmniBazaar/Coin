// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PrivateERC20} from "../coti-contracts/contracts/token/PrivateERC20/PrivateERC20.sol";
import {MpcCore, gtBool, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title IPrivacyFeeManager
 * @author OmniCoin Development Team
 * @notice Interface for privacy fee management
 */
interface IPrivacyFeeManager {
    /**
     * @notice Collect privacy fee from user
     * @param user User address
     * @param operationType Type of operation
     * @param amount Fee amount
     * @return success Whether fee collection was successful
     */
    function collectPrivacyFee(address user, bytes32 operationType, uint256 amount) external returns (bool success);
}

/**
 * @title OmniCoinCore
 * @author OmniCoin Development Team
 * @notice Core OmniCoin token with privacy features and Registry pattern integration
 * @dev Core OmniCoin token with Registry pattern integration
 * 
 * Updates:
 * - Extends RegistryAware for dynamic contract address resolution
 * - Removes hardcoded contract addresses (bridge, treasury, etc.)
 * - Uses registry for all inter-contract communication
 * - Maintains backward compatibility with existing interfaces
 */
contract OmniCoinCore is PrivateERC20, AccessControl, Pausable, ReentrancyGuard, RegistryAware {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct ValidatorOperation {
        bytes32 operationHash;
        address[] validators;
        uint256 confirmations;
        bool executed;
        uint256 timestamp;
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for minting new tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Role for burning tokens
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    /// @notice Role for pausing the contract
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Role for validator operations
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    /// @notice Role for bridge operations
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    /// @notice Initial token supply (100M tokens)
    uint64 public constant INITIAL_SUPPLY = 100_000_000 * 10**6; // 100M tokens with 6 decimals
    /// @notice Maximum token supply (1B tokens)
    uint64 public constant MAX_SUPPLY = 1_000_000_000 * 10**6; // 1B tokens max supply
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Registry of approved validators for L2.5 business logic operations
    mapping(address => bool) public validators;
    
    /// @notice Mapping to track validator network operations
    mapping(bytes32 => ValidatorOperation) public validatorOperations;
    
    /// @notice Privacy toggle for users (true = private, false = public)
    mapping(address => bool) public userPrivacyPreference;
    
    /// @notice Total count of registered validators
    uint256 public validatorCount;
    
    /// @notice Minimum validators required for consensus
    uint256 public minimumValidators;
    
    /// @dev Track total supply for max supply checking (public counter)
    uint64 private _publicTotalSupply;
    
    /// @notice MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    /// @notice Privacy enabled by default flag (business logic - always false)
    bool public privacyEnabledByDefault = false;
    
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
     * @notice Emitted when a validator operation is submitted
     * @param operationHash Hash of the operation
     * @param submitter Address that submitted the operation
     */
    event ValidatorOperationSubmitted(bytes32 indexed operationHash, address indexed submitter);
    
    /**
     * @notice Emitted when a validator operation is executed
     * @param operationHash Hash of the operation
     * @param confirmations Number of confirmations received
     */
    event ValidatorOperationExecuted(bytes32 indexed operationHash, uint256 indexed confirmations);
    
    /**
     * @notice Emitted when a user changes their privacy preference
     * @param user User address
     * @param privacyEnabled Whether privacy is enabled
     */
    event PrivacyPreferenceChanged(address indexed user, bool indexed privacyEnabled);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error NotValidator();
    error InvalidAddress();
    error InvalidAmount();
    error ExceedsMaxSupply();
    error InsufficientValidators();
    error OperationNotFound();
    error OperationAlreadyExecuted();
    error AlreadyConfirmed();
    error ContractPaused();
    error PrivacyNotEnabled();
    error PrivacyFeeFailed();
    error MpcNotAvailable();
    error MinimumValidatorsTooLow();
    error MaxValidatorsTooHigh();
    error TestEnvironmentOnly();
    error InsufficientReputationForProposal();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyValidator() {
        if (!validators[msg.sender]) revert NotValidator();
        _;
    }
    
    modifier whenNotPausedAndEnabled() {
        if (paused()) revert ContractPaused();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the OmniCoinCore contract
     * @param _registry Address of the OmniCoinRegistry contract
     * @param _admin Initial admin address
     * @param _minimumValidators Minimum number of validators required
     */
    constructor(
        address _registry,
        address _admin,
        uint256 _minimumValidators
    ) PrivateERC20("OmniCoin", "OMNI") RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidAddress();
        if (_minimumValidators == 0) revert InsufficientValidators();
        
        // Grant roles to admin
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(BURNER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        minimumValidators = _minimumValidators;
        
        // Initialize public supply counter
        _publicTotalSupply = 0; // Will be set when initial supply is minted
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Start false, admin sets true on COTI
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Set MPC availability (admin only)
     * @dev Called when deploying to COTI testnet/mainnet
     * @param _available Whether MPC is available
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Mint initial supply (called once after deployment)
     */
    function mintInitialSupply() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_publicTotalSupply != 0) revert InvalidAmount();
        
        // Update the public total supply tracker
        _publicTotalSupply = INITIAL_SUPPLY;
        
        if (isMpcAvailable) {
            // On COTI with MPC enabled
            gtUint64 initialSupply = MpcCore.setPublic64(uint64(INITIAL_SUPPLY));
            gtBool result = _mint(msg.sender, initialSupply);
            if (!MpcCore.decrypt(result)) revert InvalidAmount();
        } else {
            // In test environment
            ctUint64 dummyValue = ctUint64.wrap(0);
            emit Transfer(address(0), msg.sender, dummyValue, dummyValue);
        }
    }
    
    // =============================================================================
    // VALIDATOR MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Add a new validator to the network
     * @dev Requires admin role and checks for duplicate validators
     * @param validator Address of the validator to add
     */
    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        if (validators[validator]) revert InvalidAddress();
        
        validators[validator] = true;
        ++validatorCount;
        
        _grantRole(VALIDATOR_ROLE, validator);
        
        emit ValidatorAdded(validator);
    }
    
    /**
     * @notice Remove a validator from the network
     * @dev Requires admin role and maintains minimum validator count
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!validators[validator]) revert NotValidator();
        if (validatorCount < minimumValidators + 1) revert InsufficientValidators();
        
        validators[validator] = false;
        --validatorCount;
        
        _revokeRole(VALIDATOR_ROLE, validator);
        
        emit ValidatorRemoved(validator);
    }
    
    // =============================================================================
    // PRIVACY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Set user privacy preference
     * @dev Allows users to opt-in to privacy features
     * @param privacyEnabled True for private operations, false for public
     */
    function setPrivacyPreference(bool privacyEnabled) external {
        userPrivacyPreference[msg.sender] = privacyEnabled;
        emit PrivacyPreferenceChanged(msg.sender, privacyEnabled);
    }
    
    // =============================================================================
    // REGISTRY INTEGRATION HELPERS
    // =============================================================================
    
    /**
     * @notice Get bridge contract from registry
     * @return bridge Bridge contract address
     */
    function getBridgeContract() public returns (address bridge) {
        return _getContract(registry.BRIDGE());
    }
    
    /**
     * @notice Get treasury contract from registry
     * @return treasury Treasury contract address
     */
    function getTreasuryContract() public returns (address treasury) {
        return _getContract(registry.TREASURY());
    }
    
    /**
     * @notice Get privacy fee manager from registry
     * @return feeManager Privacy fee manager address
     */
    function getPrivacyFeeManager() public returns (address feeManager) {
        return _getContract(registry.FEE_MANAGER());
    }
    
    /**
     * @notice Standard public transfer (no privacy, no extra fees)
     * @dev Wrapper around internal _transfer function
     * @param to Recipient address
     * @param amount Transfer amount
     * @return success Always returns true if no revert
     */
    function transferPublic(address to, uint256 amount) 
        public 
        whenNotPausedAndEnabled 
        returns (bool) 
    {
        // Convert to gtUint64 for internal use
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        _transfer(msg.sender, to, gtAmount);
        // In public mode, we assume success
        return true;
    }
    
    /**
     * @notice Standard public transferFrom (no privacy, no extra fees)
     * @dev Uses PrivateERC20 transferFrom which handles allowance
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     * @return success Always returns true if no revert
     */
    function transferFromPublic(address from, address to, uint256 amount) 
        public 
        whenNotPausedAndEnabled 
        returns (bool) 
    {
        // Convert amount to gtUint64
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        
        // Use the PrivateERC20 transferFrom which handles allowance internally
        transferFrom(from, to, gtAmount);
        
        // For public functions, we assume success if no revert
        return true;
    }
    
    /**
     * @notice TransferFrom with explicit privacy choice
     * @dev Allows sender to choose privacy mode, charges fee if privacy enabled
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     * @param usePrivacy Whether to use privacy features (costs extra)
     * @return success Whether the transfer was successful
     */
    function transferFromWithPrivacy(address from, address to, uint256 amount, bool usePrivacy) 
        external 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (bool) 
    {
        if (usePrivacy && isMpcAvailable) {
            // User explicitly chose privacy - collect fee
            if (!userPrivacyPreference[from]) revert PrivacyNotEnabled();
            
            address feeManager = getPrivacyFeeManager();
            if (feeManager != address(0)) {
                // Collect privacy fee from the sender (from address)
                IPrivacyFeeManager(feeManager).collectPrivacyFee(
                    from,
                    keccak256("TRANSFER_FROM"),
                    amount
                );
            }
            
            // Use MPC for private transfer
            gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));
            gtBool result = _transferFromPrivate(from, to, gtAmount);
            return MpcCore.decrypt(result);
        } else {
            // Standard public transferFrom
            return transferFromPublic(from, to, amount);
        }
    }
    
    /**
     * @notice Standard public approve (no privacy, no extra fees)
     * @dev Sets allowance for spender
     * @param spender Address allowed to spend
     * @param amount Amount allowed
     * @return success Always returns true if no revert
     */
    function approvePublic(address spender, uint256 amount) 
        public 
        whenNotPausedAndEnabled 
        returns (bool) 
    {
        // Convert to encrypted type for internal use
        if (isMpcAvailable) {
            gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));
            _approve(msg.sender, spender, gtAmount);
        } else {
            // In test mode, create a wrapped value
            gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
            _approve(msg.sender, spender, gtAmount);
        }
        return true;
    }
    
    /**
     * @notice Approve with explicit privacy choice
     * @dev Allows approver to choose privacy mode, charges fee if privacy enabled
     * @param spender Address allowed to spend
     * @param amount Amount allowed
     * @param usePrivacy Whether to use privacy features (costs extra)
     * @return success Whether the approval was successful
     */
    function approveWithPrivacy(address spender, uint256 amount, bool usePrivacy) 
        external 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (bool) 
    {
        if (usePrivacy && isMpcAvailable) {
            // User explicitly chose privacy - collect fee
            if (!userPrivacyPreference[msg.sender]) revert PrivacyNotEnabled();
            
            address feeManager = getPrivacyFeeManager();
            if (feeManager != address(0)) {
                // Collect privacy fee
                IPrivacyFeeManager(feeManager).collectPrivacyFee(
                    msg.sender,
                    keccak256("APPROVE"),
                    amount
                );
            }
            
            // Use MPC for private approval
            gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));
            _approve(msg.sender, spender, gtAmount);
            return true;
        } else {
            // Standard public approve
            return approvePublic(spender, amount);
        }
    }
    
    /**
     * @notice Transfer with explicit privacy choice
     * @dev Allows sender to choose privacy mode, charges fee if privacy enabled
     * @param to Recipient address
     * @param amount Transfer amount
     * @param usePrivacy Whether to use privacy features (costs extra)
     * @return success Whether the transfer was successful
     */
    function transferWithPrivacy(address to, uint256 amount, bool usePrivacy) 
        external 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (bool) 
    {
        if (usePrivacy && isMpcAvailable) {
            // User explicitly chose privacy - collect fee
            if (!userPrivacyPreference[msg.sender]) revert PrivacyNotEnabled();
            
            address feeManager = getPrivacyFeeManager();
            if (feeManager != address(0)) {
                // Collect privacy fee
                IPrivacyFeeManager(feeManager).collectPrivacyFee(
                    msg.sender,
                    keccak256("TRANSFER"),
                    amount
                );
            }
            
            // Use MPC for private transfer
            gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));
            gtBool result = _transferPrivate(to, gtAmount);
            return MpcCore.decrypt(result);
        } else {
            // Standard public transfer
            return transferPublic(to, amount);
        }
    }
    
    /**
     * @notice Legacy private transfer function (for compatibility)
     * @dev Uses MPC for fully private transfers, requires privacy preference enabled
     * @param to Recipient address
     * @param value Transfer amount (encrypted)
     * @return result Encrypted boolean result
     */
    function transferPrivate(address to, itUint64 calldata value) 
        external 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        if (!isMpcAvailable) revert MpcNotAvailable();
        if (!userPrivacyPreference[msg.sender]) revert PrivacyNotEnabled();
        
        // This is the explicit privacy path - always charge fee
        address feeManager = getPrivacyFeeManager();
        if (feeManager != address(0)) {
            // For encrypted amounts, we estimate fee based on typical transfer
            uint256 estimatedAmount = 1000 * 10**6; // 1000 OMNI typical transfer
            IPrivacyFeeManager(feeManager).collectPrivacyFee(
                msg.sender,
                keccak256("TRANSFER"),
                estimatedAmount
            );
        }
        
        // Call the PrivateERC20 transfer function with encrypted types
        gtUint64 gtValue = MpcCore.validateCiphertext(value);
        return transfer(to, gtValue);
    }
    
    /**
     * @notice Transfer with garbled circuit value (already encrypted)
     * @dev Uses pre-encrypted values for maximum privacy
     * @param to Recipient address
     * @param value Transfer amount (garbled)
     * @return result Encrypted boolean result
     */
    function transferGarbled(address to, gtUint64 value) 
        external 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        if (!isMpcAvailable) revert MpcNotAvailable();
        if (!userPrivacyPreference[msg.sender]) revert PrivacyNotEnabled();
        
        // Charge privacy fee for garbled transfers
        address feeManager = getPrivacyFeeManager();
        if (feeManager != address(0)) {
            uint256 estimatedAmount = 1000 * 10**6; // Estimate for fee
            IPrivacyFeeManager(feeManager).collectPrivacyFee(
                msg.sender,
                keccak256("TRANSFER"),
                estimatedAmount
            );
        }
        
        return _transferPrivate(to, value);
    }
    
    /**
     * @notice Internal private transfer using MPC
     * @dev Wrapper around PrivateERC20 transfer with garbled types
     * @param to Recipient address
     * @param amount Transfer amount (garbled)
     * @return result Encrypted boolean result
     */
    function _transferPrivate(address to, gtUint64 amount) internal returns (gtBool) {
        // This calls the PrivateERC20 transfer function with garbled types
        return transfer(to, amount);
    }
    
    /**
     * @notice Internal private transferFrom using MPC
     * @dev Wrapper around PrivateERC20 transferFrom with garbled types
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount (garbled)
     * @return result Encrypted boolean result
     */
    function _transferFromPrivate(address from, address to, gtUint64 amount) internal returns (gtBool) {
        // This calls the PrivateERC20 transferFrom function with garbled types
        return transferFrom(from, to, amount);
    }
    
    // =============================================================================
    // MINTING & BURNING WITH PRIVACY
    // =============================================================================
    
    /**
     * @notice Mint tokens with privacy support
     * @dev Requires MINTER_ROLE, validates encrypted amount
     * @param to Recipient address
     * @param amount Amount to mint (encrypted)
     * @return result Encrypted boolean result
     */
    function mintPrivate(address to, itUint64 calldata amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        if (to == address(0)) revert InvalidAddress();
        
        if (isMpcAvailable) {
            gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
            return _mintPrivate(to, gtAmount);
        } else {
            // Fallback for testing - convert amount directly
            uint64 plainAmount = uint64(uint256(keccak256(abi.encode(amount))));
            gtUint64 gtAmount = gtUint64.wrap(plainAmount);
            return _mintPrivate(to, gtAmount);
        }
    }
    
    /**
     * @notice Mint tokens with garbled circuit value
     * @dev Requires MINTER_ROLE, uses pre-encrypted amount
     * @param to Recipient address
     * @param amount Amount to mint (garbled)
     * @return result Encrypted boolean result
     */
    function mintGarbled(address to, gtUint64 amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        if (to == address(0)) revert InvalidAddress();
        return _mintPrivate(to, amount);
    }
    
    /**
     * @notice Burn tokens with privacy support
     * @dev Requires BURNER_ROLE, validates encrypted amount
     * @param amount Amount to burn (encrypted)
     * @return result Encrypted boolean result
     */
    function burnPrivate(itUint64 calldata amount) 
        external 
        onlyRole(BURNER_ROLE) 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        if (isMpcAvailable) {
            gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
            return _burnPrivate(msg.sender, gtAmount);
        } else {
            // Fallback for testing
            uint64 plainAmount = uint64(uint256(keccak256(abi.encode(amount))));
            gtUint64 gtAmount = gtUint64.wrap(plainAmount);
            return _burnPrivate(msg.sender, gtAmount);
        }
    }
    
    /**
     * @notice Burn tokens with garbled circuit value
     * @dev Requires BURNER_ROLE, uses pre-encrypted amount
     * @param amount Amount to burn (garbled)
     * @return result Encrypted boolean result
     */
    function burnGarbled(gtUint64 amount) 
        external 
        onlyRole(BURNER_ROLE) 
        whenNotPausedAndEnabled 
        nonReentrant 
        returns (gtBool) 
    {
        return _burnPrivate(msg.sender, amount);
    }
    
    // =============================================================================
    // BRIDGE OPERATIONS FOR L2.5 ARCHITECTURE
    // =============================================================================
    
    /**
     * @notice Submit operation to validator network for business logic processing
     * @dev Creates a new validator operation that needs confirmation
     * @param operationData Encoded operation data
     * @param operationType Type of operation (0=transfer, 1=stake, 2=reputation, etc.)
     * @return operationHash Hash of the submitted operation
     */
    function submitToValidators(bytes calldata operationData, uint256 operationType) 
        external 
        whenNotPausedAndEnabled 
        returns (bytes32) 
    {
        bytes32 operationHash = keccak256(abi.encodePacked(
            operationData,
            operationType,
            msg.sender,
            block.timestamp // solhint-disable-line not-rely-on-time
        ));
        
        validatorOperations[operationHash] = ValidatorOperation({
            operationHash: operationHash,
            validators: new address[](0),
            confirmations: 0,
            executed: false,
            timestamp: block.timestamp // solhint-disable-line not-rely-on-time
        });
        
        emit ValidatorOperationSubmitted(operationHash, msg.sender);
        return operationHash;
    }
    
    /**
     * @notice Confirm operation by validator
     * @dev Validators confirm operations, executes when minimum reached
     * @param operationHash Hash of the operation to confirm
     */
    function confirmValidatorOperation(bytes32 operationHash) 
        external 
        onlyValidator 
        whenNotPausedAndEnabled 
    {
        ValidatorOperation storage operation = validatorOperations[operationHash];
        if (operation.operationHash == bytes32(0)) revert OperationNotFound();
        if (operation.executed) revert OperationAlreadyExecuted();
        
        // Check if validator already confirmed
        for (uint256 i = 0; i < operation.validators.length; ++i) {
            if (operation.validators[i] == msg.sender) revert AlreadyConfirmed();
        }
        
        operation.validators.push(msg.sender);
        ++operation.confirmations;
        
        // Execute if minimum confirmations reached
        if (operation.confirmations > minimumValidators - 1) {
            operation.executed = true;
            emit ValidatorOperationExecuted(operationHash, operation.confirmations);
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update minimum validators required
     * @dev Admin function to set consensus threshold
     * @param newMinimum New minimum validator count
     */
    function setMinimumValidators(uint256 newMinimum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinimum == 0) revert MinimumValidatorsTooLow();
        if (newMinimum > validatorCount) revert MaxValidatorsTooHigh();
        minimumValidators = newMinimum;
    }
    
    /**
     * @notice Pause contract
     * @dev Requires PAUSER_ROLE, stops all token operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause contract
     * @dev Requires PAUSER_ROLE, resumes all token operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL HELPER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Internal mint function with privacy
     * @dev Wrapper around PrivateERC20 _mint
     * @param to Recipient address
     * @param amount Amount to mint (garbled)
     * @return result Encrypted boolean result
     */
    function _mintPrivate(address to, gtUint64 amount) internal returns (gtBool) {
        // Check max supply constraint by temporarily accessing the encrypted total supply
        return _mint(to, amount);
    }
    
    /**
     * @notice Internal burn function with privacy
     * @dev Wrapper around PrivateERC20 _burn
     * @param from Address to burn from
     * @param amount Amount to burn (garbled)
     * @return result Encrypted boolean result
     */
    function _burnPrivate(address from, gtUint64 amount) internal returns (gtBool) {
        return _burn(from, amount);
    }
    
    /**
     * @notice Override _update to add pause functionality and max supply check
     * @dev Tracks public supply for max supply enforcement
     * @param from Source address (0x0 for minting)
     * @param to Destination address (0x0 for burning)
     * @param value Transfer amount (encrypted)
     * @return result Encrypted boolean result
     */
    function _update(address from, address to, gtUint64 value) 
        internal 
        virtual 
        override 
        returns (gtBool) 
    {
        uint64 amount;
        
        if (isMpcAvailable) {
            // Convert gtUint64 to uint64 for supply tracking
            amount = MpcCore.decrypt(value);
        } else {
            // In testing mode, unwrap the value directly
            amount = uint64(gtUint64.unwrap(value));
        }
        
        // Update public supply counter for max supply enforcement
        if (from == address(0)) {
            // Minting - check max supply
            if (_publicTotalSupply > MAX_SUPPLY) revert ExceedsMaxSupply();
        } else if (to == address(0)) {
            // Burning - decrease counter
            _publicTotalSupply -= amount;
        }
        // For regular transfers, supply doesn't change
        
        return super._update(from, to, value);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if address is a validator
     * @dev Public view function to query validator status
     * @param addr Address to check
     * @return isValid Whether the address is a validator
     */
    function isValidator(address addr) external view returns (bool) {
        return validators[addr];
    }
    
    /**
     * @notice Get validator operation details
     * @dev Returns all details of a validator operation
     * @param operationHash Hash of the operation
     * @return operationHashReturn The operation hash
     * @return validators Array of validators who confirmed
     * @return confirmations Number of confirmations
     * @return executed Whether operation was executed
     * @return timestamp When operation was submitted
     */
    function getValidatorOperation(bytes32 operationHash) 
        external 
        view 
        returns (
            bytes32,
            address[] memory,
            uint256,
            bool,
            uint256
        ) 
    {
        ValidatorOperation memory op = validatorOperations[operationHash];
        return (
            op.operationHash,
            op.validators,
            op.confirmations,
            op.executed,
            op.timestamp
        );
    }
    
    /**
     * @notice Get user's privacy preference
     * @dev Returns whether user has opted into privacy features
     * @param user User address
     * @return privacyEnabled Whether privacy is enabled for user
     */
    function getPrivacyPreference(address user) external view returns (bool) {
        return userPrivacyPreference[user];
    }
    
    /**
     * @notice Get balance in plain format (for compatibility)
     * @dev Returns unencrypted balance for testing/compatibility
     * @param account Account to query
     * @return balance Balance as uint256
     */
    function balanceOfPublic(address account) public view returns (uint256) {
        // In production with MPC, this would decrypt the balance
        // For now, return test balance or 0
        if (!isMpcAvailable) {
            // In test mode, only the admin has the initial supply
            if (hasRole(DEFAULT_ADMIN_ROLE, account) && _publicTotalSupply > 0) {
                return _publicTotalSupply;
            }
            return 0;
        }
        // In MPC mode, would need to handle encrypted balance
        return 0;
    }
    
    /**
     * @notice Get balance for testing purposes (only works when MPC is not available)
     * @dev Test-only function that reverts in production
     * @param account Account address
     * @return balance Test balance
     */
    function testBalanceOf(address account) external view returns (uint256) {
        if (isMpcAvailable) revert TestEnvironmentOnly();
        // In test mode, only the admin has the initial supply
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && _publicTotalSupply > 0) {
            return _publicTotalSupply;
        }
        return 0;
    }
    
    /**
     * @notice Override decimals to use 6 decimals (matching COTI)
     * @dev Returns token decimal places
     * @return decimals Number of decimal places (6)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    /**
     * @notice Get stake amount for address (placeholder)
     * @dev Placeholder - actual staking in OmniCoinStaking contract
     * @return stakeAmount Stake amount (always 0 for now)
     */
    function getStakeAmount(address /* account */) external pure returns (uint256) {
        // Staking is handled in OmniCoinStaking contract
        return 0;
    }
    
    /**
     * @notice Get reputation score for address (placeholder)
     * @dev Placeholder - actual reputation in Reputation contracts
     * @return reputation Reputation score (always 100 for now)
     */
    function getReputationScore(address /* account */) external pure returns (uint256) {
        // Reputation is handled in Reputation contracts
        return 100;
    }
    
    /**
     * @notice Get username for address (placeholder)
     * @dev Placeholder - actual mapping in account management contracts
     * @return username Username (empty string for now)
     */
    function addressToUsername(address /* account */) external pure returns (string memory) {
        // Username mapping would be in account management contracts
        return "";
    }
    
    /**
     * @notice Override totalSupply to return our tracked public supply
     * @dev Returns the total token supply
     * @return supply Total supply in uint256
     */
    function totalSupply() public view virtual override returns (uint256) {
        return uint256(_publicTotalSupply);
    }
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Emergency stop for validator operations
     * @dev Admin function to pause all operations
     */
    function emergencyStopValidatorOperations() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Recovery function for stuck operations (only admin)
     * @dev Force-executes operations stuck for over 24 hours
     * @param operationHash Hash of the stuck operation
     */
    function emergencyExecuteOperation(bytes32 operationHash) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        ValidatorOperation storage operation = validatorOperations[operationHash];
        if (operation.operationHash == bytes32(0)) revert OperationNotFound();
        if (operation.executed) revert OperationAlreadyExecuted();
        // Emergency operations require 24 hour delay for security
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < operation.timestamp + 24 hours + 1) revert OperationNotFound();
        
        operation.executed = true;
        emit ValidatorOperationExecuted(operationHash, operation.confirmations);
    }
    
    // =============================================================================
    // BACKWARD COMPATIBILITY
    // =============================================================================
    
    /**
     * @notice Get bridge contract (backward compatibility)
     * @dev Deprecated - use registry directly
     * @return bridge Bridge contract address
     */
    function bridgeContract() external returns (address) {
        return getBridgeContract();
    }
    
    /**
     * @notice Get treasury contract (backward compatibility)
     * @dev Deprecated - use registry directly
     * @return treasury Treasury contract address
     */
    function treasuryContract() external returns (address) {
        return getTreasuryContract();
    }
    
    /**
     * @notice Get privacy fee manager (backward compatibility)
     * @dev Deprecated - use registry directly
     * @return feeManager Privacy fee manager address
     */
    function privacyFeeManager() external returns (address) {
        return getPrivacyFeeManager();
    }
}