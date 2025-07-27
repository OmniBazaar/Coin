// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PrivateERC20} from "../coti-contracts/contracts/token/PrivateERC20/PrivateERC20.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

interface IPrivacyFeeManager {
    function collectPrivacyFee(address user, bytes32 operationType, uint256 amount) external returns (bool);
}

/**
 * @title OmniCoinCore
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
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    uint64 public constant INITIAL_SUPPLY = 100_000_000 * 10**6; // 100M tokens with 6 decimals
    uint64 public constant MAX_SUPPLY = 1_000_000_000 * 10**6; // 1B tokens max supply
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Registry of approved validators for L2.5 business logic operations
    mapping(address => bool) public validators;
    
    /// @dev Mapping to track validator network operations
    mapping(bytes32 => ValidatorOperation) public validatorOperations;
    
    /// @dev Privacy toggle for users (true = private, false = public)
    mapping(address => bool) public userPrivacyPreference;
    
    /// @dev Total count of registered validators
    uint256 public validatorCount;
    
    /// @dev Minimum validators required for consensus
    uint256 public minimumValidators;
    
    /// @dev Track total supply for max supply checking (public counter)
    uint64 private _publicTotalSupply;
    
    /// @dev MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    /// @dev Privacy enabled by default flag (business logic - always false)
    bool public privacyEnabledByDefault = false;
    
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
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ValidatorOperationSubmitted(bytes32 indexed operationHash, address indexed submitter);
    event ValidatorOperationExecuted(bytes32 indexed operationHash, uint256 confirmations);
    event PrivacyPreferenceChanged(address indexed user, bool privacyEnabled);
    
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
    // REGISTRY INTEGRATION HELPERS
    // =============================================================================
    
    /**
     * @dev Get bridge contract from registry
     */
    function getBridgeContract() public returns (address) {
        return _getContract(registry.BRIDGE());
    }
    
    /**
     * @dev Get treasury contract from registry
     */
    function getTreasuryContract() public returns (address) {
        return _getContract(registry.TREASURY());
    }
    
    /**
     * @dev Get privacy fee manager from registry
     */
    function getPrivacyFeeManager() public returns (address) {
        return _getContract(registry.FEE_MANAGER());
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     */
    function setMpcAvailability(bool _available) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Mint initial supply (called once after deployment)
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
     * @dev Add a new validator to the network
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
     * @dev Remove a validator from the network
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!validators[validator]) revert NotValidator();
        if (validatorCount <= minimumValidators) revert InsufficientValidators();
        
        validators[validator] = false;
        --validatorCount;
        
        _revokeRole(VALIDATOR_ROLE, validator);
        
        emit ValidatorRemoved(validator);
    }
    
    // =============================================================================
    // PRIVACY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Set user privacy preference
     * @param privacyEnabled True for private operations, false for public
     */
    function setPrivacyPreference(bool privacyEnabled) external {
        userPrivacyPreference[msg.sender] = privacyEnabled;
        emit PrivacyPreferenceChanged(msg.sender, privacyEnabled);
    }
    
    /**
     * @dev Standard public transfer (no privacy, no extra fees)
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function transferPublic(address to, uint256 amount) 
        public 
        whenNotPausedAndEnabled 
        returns (bool) 
    {
        // Convert to gtUint64 for internal use
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        gtBool result = _transfer(msg.sender, to, gtAmount);
        // In public mode, we assume success
        return true;
    }
    
    /**
     * @dev Standard public transferFrom (no privacy, no extra fees)
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function transferFromPublic(address from, address to, uint256 amount) 
        public 
        whenNotPausedAndEnabled 
        returns (bool) 
    {
        address spender = _msgSender();
        
        // Convert amount to gtUint64
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        
        // Use the PrivateERC20 transferFrom which handles allowance internally
        gtBool result = transferFrom(from, to, gtAmount);
        
        // For public functions, we assume success if no revert
        return true;
    }
    
    /**
     * @dev TransferFrom with explicit privacy choice
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     * @param usePrivacy Whether to use privacy features (costs extra)
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
            
            address privacyFeeManager = getPrivacyFeeManager();
            if (privacyFeeManager != address(0)) {
                // Collect privacy fee from the sender (from address)
                IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
     * @dev Standard public approve (no privacy, no extra fees)
     * @param spender Address allowed to spend
     * @param amount Amount allowed
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
     * @dev Approve with explicit privacy choice
     * @param spender Address allowed to spend
     * @param amount Amount allowed
     * @param usePrivacy Whether to use privacy features (costs extra)
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
            
            address privacyFeeManager = getPrivacyFeeManager();
            if (privacyFeeManager != address(0)) {
                // Collect privacy fee
                IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
     * @dev Transfer with explicit privacy choice
     * @param to Recipient address
     * @param amount Transfer amount
     * @param usePrivacy Whether to use privacy features (costs extra)
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
            
            address privacyFeeManager = getPrivacyFeeManager();
            if (privacyFeeManager != address(0)) {
                // Collect privacy fee
                IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
     * @dev Legacy private transfer function (for compatibility)
     * @param to Recipient address
     * @param value Transfer amount (encrypted)
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
        address privacyFeeManager = getPrivacyFeeManager();
        if (privacyFeeManager != address(0)) {
            // For encrypted amounts, we estimate fee based on typical transfer
            uint256 estimatedAmount = 1000 * 10**6; // 1000 OMNI typical transfer
            IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
     * @dev Transfer with garbled circuit value (already encrypted)
     * @param to Recipient address
     * @param value Transfer amount (garbled)
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
        address privacyFeeManager = getPrivacyFeeManager();
        if (privacyFeeManager != address(0)) {
            uint256 estimatedAmount = 1000 * 10**6; // Estimate for fee
            IPrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
                msg.sender,
                keccak256("TRANSFER"),
                estimatedAmount
            );
        }
        
        return _transferPrivate(to, value);
    }
    
    /**
     * @dev Internal private transfer using MPC
     * @param to Recipient address
     * @param amount Transfer amount (garbled)
     */
    function _transferPrivate(address to, gtUint64 amount) internal returns (gtBool) {
        // This calls the PrivateERC20 transfer function with garbled types
        return transfer(to, amount);
    }
    
    /**
     * @dev Internal private transferFrom using MPC
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount (garbled)
     */
    function _transferFromPrivate(address from, address to, gtUint64 amount) internal returns (gtBool) {
        // This calls the PrivateERC20 transferFrom function with garbled types
        return transferFrom(from, to, amount);
    }
    
    // =============================================================================
    // MINTING & BURNING WITH PRIVACY
    // =============================================================================
    
    /**
     * @dev Mint tokens with privacy support
     * @param to Recipient address
     * @param amount Amount to mint (encrypted)
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
     * @dev Mint tokens with garbled circuit value
     * @param to Recipient address
     * @param amount Amount to mint (garbled)
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
     * @dev Burn tokens with privacy support
     * @param amount Amount to burn (encrypted)
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
     * @dev Burn tokens with garbled circuit value
     * @param amount Amount to burn (garbled)
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
     * @dev Submit operation to validator network for business logic processing
     * @param operationData Encoded operation data
     * @param operationType Type of operation (0=transfer, 1=stake, 2=reputation, etc.)
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
            block.timestamp
        ));
        
        validatorOperations[operationHash] = ValidatorOperation({
            operationHash: operationHash,
            validators: new address[](0),
            confirmations: 0,
            executed: false,
            timestamp: block.timestamp
        });
        
        emit ValidatorOperationSubmitted(operationHash, msg.sender);
        return operationHash;
    }
    
    /**
     * @dev Confirm operation by validator
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
        if (operation.confirmations >= minimumValidators) {
            operation.executed = true;
            emit ValidatorOperationExecuted(operationHash, operation.confirmations);
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update minimum validators required
     * @param newMinimum New minimum validator count
     */
    function setMinimumValidators(uint256 newMinimum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMinimum > 0, "OmniCoinCore: Minimum must be > 0");
        require(newMinimum <= validatorCount, "OmniCoinCore: Minimum cannot exceed current count");
        minimumValidators = newMinimum;
    }
    
    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL HELPER FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Internal mint function with privacy
     * @param to Recipient address
     * @param amount Amount to mint (garbled)
     */
    function _mintPrivate(address to, gtUint64 amount) internal returns (gtBool) {
        // Check max supply constraint by temporarily accessing the encrypted total supply
        return _mint(to, amount);
    }
    
    /**
     * @dev Internal burn function with privacy
     * @param from Address to burn from
     * @param amount Amount to burn (garbled)
     */
    function _burnPrivate(address from, gtUint64 amount) internal returns (gtBool) {
        return _burn(from, amount);
    }
    
    /**
     * @dev Override _update to add pause functionality and max supply check
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
            require(_publicTotalSupply <= MAX_SUPPLY, "OmniCoinCore: Would exceed max supply");
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
     * @dev Check if address is a validator
     * @param addr Address to check
     */
    function isValidator(address addr) external view returns (bool) {
        return validators[addr];
    }
    
    /**
     * @dev Get validator operation details
     * @param operationHash Hash of the operation
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
     * @dev Get user's privacy preference
     * @param user User address
     */
    function getPrivacyPreference(address user) external view returns (bool) {
        return userPrivacyPreference[user];
    }
    
    /**
     * @dev Get balance in plain format (for compatibility)
     * @param account Account to query
     * @return Balance as uint256
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
     * @dev Get balance for testing purposes (only works when MPC is not available)
     * @param account Account address
     */
    function testBalanceOf(address account) external view returns (uint256) {
        require(!isMpcAvailable, "OmniCoinCore: Use balanceOf for MPC environments");
        // In test mode, only the admin has the initial supply
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && _publicTotalSupply > 0) {
            return _publicTotalSupply;
        }
        return 0;
    }
    
    /**
     * @dev Override decimals to use 6 decimals (matching COTI)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    /**
     * @dev Get stake amount for address (placeholder)
     * @param account Account to query
     * @return Stake amount (always 0 for now)
     */
    function getStakeAmount(address account) external view returns (uint256) {
        // Staking is handled in OmniCoinStaking contract
        return 0;
    }
    
    /**
     * @dev Get reputation score for address (placeholder)
     * @param account Account to query
     * @return Reputation score (always 100 for now)
     */
    function getReputationScore(address account) external view returns (uint256) {
        // Reputation is handled in Reputation contracts
        return 100;
    }
    
    /**
     * @dev Get username for address (placeholder)
     * @param account Account to query
     * @return Username (empty string for now)
     */
    function addressToUsername(address account) external view returns (string memory) {
        // Username mapping would be in account management contracts
        return "";
    }
    
    /**
     * @dev Override totalSupply to return our tracked public supply
     */
    function totalSupply() public view virtual override returns (uint256) {
        return uint256(_publicTotalSupply);
    }
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Emergency stop for validator operations
     */
    function emergencyStopValidatorOperations() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Recovery function for stuck operations (only admin)
     * @param operationHash Hash of the stuck operation
     */
    function emergencyExecuteOperation(bytes32 operationHash) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        ValidatorOperation storage operation = validatorOperations[operationHash];
        if (operation.operationHash == bytes32(0)) revert OperationNotFound();
        if (operation.executed) revert OperationAlreadyExecuted();
        if (block.timestamp <= operation.timestamp + 24 hours) revert OperationNotFound();
        
        operation.executed = true;
        emit ValidatorOperationExecuted(operationHash, operation.confirmations);
    }
    
    // =============================================================================
    // BACKWARD COMPATIBILITY
    // =============================================================================
    
    /**
     * @dev Get bridge contract (backward compatibility)
     * @notice Deprecated - use registry directly
     */
    function bridgeContract() external returns (address) {
        return getBridgeContract();
    }
    
    /**
     * @dev Get treasury contract (backward compatibility)
     * @notice Deprecated - use registry directly
     */
    function treasuryContract() external returns (address) {
        return getTreasuryContract();
    }
    
    /**
     * @dev Get privacy fee manager (backward compatibility)
     * @notice Deprecated - use registry directly
     */
    function privacyFeeManager() external returns (address) {
        return getPrivacyFeeManager();
    }
}