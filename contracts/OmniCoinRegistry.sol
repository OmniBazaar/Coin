// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OmniCoinRegistry
 * @author OmniCoin Development Team
 * @notice Central registry for all OmniCoin contract addresses
 * @dev Central registry for all OmniCoin contract addresses
 * 
 * Benefits:
 * - Single source of truth for contract addresses
 * - Cheaper to update than modifying all contracts
 * - Supports versioning and upgrades
 * - Emergency pause functionality
 * - Gas optimization through caching
 */
contract OmniCoinRegistry is AccessControl, Pausable {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct ContractInfo {
        address contractAddress;
        bool isActive;
        uint256 version;
        uint256 deployedAt;
        uint256 updatedAt;
        string description;
    }
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error ContractAlreadyRegistered();
    error ContractNotRegistered();
    error ContractNotActive();
    error InvalidIdentifier();
    error UnauthorizedUpgrade();
    error VersionMismatch();
    error BatchSizeMismatch();
    error InvalidVersion();
    error NoTargetContract();
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Role for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role for updating contract addresses
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    
    // =============================================================================
    // CONTRACT IDENTIFIERS
    // =============================================================================
    
    // Core contracts
    /// @notice Identifier for OmniCoin Core contract
    bytes32 public constant OMNICOIN_CORE = keccak256("OMNICOIN_CORE");
    /// @notice Identifier for OmniCoin token contract
    bytes32 public constant OMNICOIN = keccak256("OMNICOIN");
    /// @notice Identifier for Private OmniCoin contract
    bytes32 public constant PRIVATE_OMNICOIN = keccak256("PRIVATE_OMNICOIN");
    /// @notice Identifier for OmniCoin Bridge contract
    bytes32 public constant OMNICOIN_BRIDGE = keccak256("OMNICOIN_BRIDGE");
    /// @notice Identifier for OmniCoin Config contract
    bytes32 public constant OMNICOIN_CONFIG = keccak256("OMNICOIN_CONFIG");
    /// @notice Identifier for OmniCoin Privacy module
    bytes32 public constant OMNICOIN_PRIVACY = keccak256("OMNICOIN_PRIVACY");
    /// @notice Identifier for OmniCoin Account contract
    bytes32 public constant OMNICOIN_ACCOUNT = keccak256("OMNICOIN_ACCOUNT");
    /// @notice Identifier for Fee Distribution contract
    bytes32 public constant FEE_DISTRIBUTION = keccak256("FEE_DISTRIBUTION");
    
    // Reputation system
    /// @notice Identifier for Reputation Core contract
    bytes32 public constant REPUTATION_CORE = keccak256("REPUTATION_CORE");
    /// @notice Identifier for Identity Verification contract
    bytes32 public constant IDENTITY_VERIFICATION = keccak256("IDENTITY_VERIFICATION");
    /// @notice Identifier for Trust System contract
    bytes32 public constant TRUST_SYSTEM = keccak256("TRUST_SYSTEM");
    /// @notice Identifier for Referral System contract
    bytes32 public constant REFERRAL_SYSTEM = keccak256("REFERRAL_SYSTEM");
    
    // Financial contracts
    /// @notice Identifier for Escrow contract
    bytes32 public constant ESCROW = keccak256("ESCROW");
    /// @notice Identifier for Payment contract
    bytes32 public constant PAYMENT = keccak256("PAYMENT");
    /// @notice Identifier for Staking contract
    bytes32 public constant STAKING = keccak256("STAKING");
    
    // Governance and dispute
    /// @notice Identifier for Governance contract
    bytes32 public constant GOVERNANCE = keccak256("GOVERNANCE");
    /// @notice Identifier for Arbitration contract
    bytes32 public constant ARBITRATION = keccak256("ARBITRATION");
    
    // Bridge
    /// @notice Identifier for Bridge contract
    bytes32 public constant BRIDGE = keccak256("BRIDGE");
    
    // Future expansions
    /// @notice Identifier for DEX contract
    bytes32 public constant DEX = keccak256("DEX");
    /// @notice Identifier for Marketplace contract
    bytes32 public constant MARKETPLACE = keccak256("MARKETPLACE");
    /// @notice Identifier for Validator Manager contract
    bytes32 public constant VALIDATOR_MANAGER = keccak256("VALIDATOR_MANAGER");
    /// @notice Identifier for Gas Relayer contract
    bytes32 public constant GAS_RELAYER = keccak256("GAS_RELAYER");
    /// @notice Identifier for Fee Manager contract
    bytes32 public constant FEE_MANAGER = keccak256("FEE_MANAGER");
    /// @notice Identifier for Treasury contract
    bytes32 public constant TREASURY = keccak256("TREASURY");
    /// @notice Identifier for DEX Settlement contract
    bytes32 public constant DEX_SETTLEMENT = keccak256("DEX_SETTLEMENT");
    /// @notice Identifier for NFT Marketplace contract
    bytes32 public constant NFT_MARKETPLACE = keccak256("NFT_MARKETPLACE");
    /// @notice Identifier for Listing NFT contract
    bytes32 public constant LISTING_NFT = keccak256("LISTING_NFT");
    
    // ERC-1155 Support
    /// @notice Identifier for OmniERC1155 contract (multi-token standard)
    bytes32 public constant OMNI_ERC1155 = keccak256("OMNI_ERC1155");
    /// @notice Identifier for Unified NFT Marketplace (ERC-721 & ERC-1155)
    bytes32 public constant UNIFIED_NFT_MARKETPLACE = keccak256("UNIFIED_NFT_MARKETPLACE");
    /// @notice Identifier for ERC-1155 Bridge contract
    bytes32 public constant ERC1155_BRIDGE = keccak256("ERC1155_BRIDGE");
    /// @notice Identifier for Service Token Examples contract
    bytes32 public constant SERVICE_TOKEN_EXAMPLES = keccak256("SERVICE_TOKEN_EXAMPLES");
    
    // Common treasury identifiers
    /// @notice Identifier for OmniBazaar Treasury
    bytes32 public constant OMNIBAZAAR_TREASURY = keccak256("OMNIBAZAAR_TREASURY");
    /// @notice Identifier for Fee Recipient
    bytes32 public constant FEE_RECIPIENT = keccak256("FEE_RECIPIENT");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Mapping from contract identifier to contract info
    mapping(bytes32 => ContractInfo) public contracts;
    
    /// @notice Array of all registered contract identifiers
    bytes32[] public contractIdentifiers;
    
    /// @notice Mapping to check if identifier exists
    mapping(bytes32 => bool) public identifierExists;
    
    /// @notice Version history: identifier => version => contract info
    mapping(bytes32 => mapping(uint256 => ContractInfo)) public versionHistory;
    
    /// @notice Emergency admin address for critical operations
    address public emergencyAdmin;
    /// @notice Emergency fallback addresses per contract
    mapping(bytes32 => address) public emergencyFallback;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a contract is registered
     * @param identifier The contract identifier
     * @param contractAddress The contract address
     * @param version The contract version
     * @param description The contract description
     */
    event ContractRegistered(
        bytes32 indexed identifier,
        address indexed contractAddress,
        uint256 indexed version,
        string description
    );
    
    /**
     * @notice Emitted when a contract is updated
     * @param identifier The contract identifier
     * @param oldAddress The previous contract address
     * @param newAddress The new contract address
     * @param newVersion The new contract version
     */
    event ContractUpdated(
        bytes32 indexed identifier,
        address indexed oldAddress,
        address indexed newAddress,
        uint256 newVersion
    );
    
    /**
     * @notice Emitted when a contract is deactivated
     * @param identifier The contract identifier
     */
    event ContractDeactivated(bytes32 indexed identifier);
    
    /**
     * @notice Emitted when a contract is reactivated
     * @param identifier The contract identifier
     */
    event ContractReactivated(bytes32 indexed identifier);
    
    /**
     * @notice Emitted when emergency admin is updated
     * @param oldAdmin The previous emergency admin
     * @param newAdmin The new emergency admin
     */
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    
    /**
     * @notice Emitted when emergency fallback is updated
     * @param identifier The contract identifier
     * @param oldFallback The previous fallback address
     * @param newFallback The new fallback address
     */
    event EmergencyFallbackUpdated(
        bytes32 indexed identifier, 
        address indexed oldFallback, 
        address indexed newFallback
    );
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the registry with an admin address
     * @param _admin The initial admin address
     */
    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPDATER_ROLE, _admin);
        
        emergencyAdmin = _admin;
        emergencyFallback[bytes32(0)] = _admin;
    }
    
    // =============================================================================
    // REGISTRATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Register a new contract in the registry
     * @param identifier Unique identifier for the contract
     * @param contractAddress Address of the contract
     * @param description Human-readable description
     */
    function registerContract(
        bytes32 identifier,
        address contractAddress,
        string calldata description
    ) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (identifier == bytes32(0)) revert InvalidIdentifier();
        if (contractAddress == address(0)) revert InvalidAddress();
        if (identifierExists[identifier]) revert ContractAlreadyRegistered();
        
        contracts[identifier] = ContractInfo({
            contractAddress: contractAddress,
            version: 1,
            isActive: true,
            description: description,
            deployedAt: block.timestamp, // solhint-disable-line not-rely-on-time
            updatedAt: block.timestamp // solhint-disable-line not-rely-on-time
        });
        
        contractIdentifiers.push(identifier);
        identifierExists[identifier] = true;
        versionHistory[identifier][1] = contracts[identifier];
        
        emit ContractRegistered(identifier, contractAddress, 1, description);
    }
    
    /**
     * @notice Update an existing contract address
     * @param identifier Contract identifier
     * @param newAddress New contract address
     */
    function updateContract(
        bytes32 identifier,
        address newAddress
    ) external onlyRole(UPDATER_ROLE) whenNotPaused {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        if (newAddress == address(0)) revert InvalidAddress();
        if (!contracts[identifier].isActive) revert ContractNotActive();
        
        ContractInfo storage info = contracts[identifier];
        address oldAddress = info.contractAddress;
        
        info.contractAddress = newAddress;
        ++info.version;
        info.updatedAt = block.timestamp; // solhint-disable-line not-rely-on-time
        
        versionHistory[identifier][info.version] = info;
        
        emit ContractUpdated(identifier, oldAddress, newAddress, info.version);
    }
    
    /**
     * @notice Batch register multiple contracts at once
     * @param identifiers Array of identifiers
     * @param addresses Array of addresses
     * @param descriptions Array of descriptions
     */
    function batchRegister(
        bytes32[] calldata identifiers,
        address[] calldata addresses,
        string[] calldata descriptions
    ) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (identifiers.length != addresses.length || 
            addresses.length != descriptions.length) revert BatchSizeMismatch();
        
        for (uint256 i = 0; i < identifiers.length; ++i) {
            if (!identifierExists[identifiers[i]] && addresses[i] != address(0)) {
                contracts[identifiers[i]] = ContractInfo({
                    contractAddress: addresses[i],
                    version: 1,
                    isActive: true,
                    description: descriptions[i],
                    deployedAt: block.timestamp, // solhint-disable-line not-rely-on-time
                    updatedAt: block.timestamp // solhint-disable-line not-rely-on-time
                });
                
                contractIdentifiers.push(identifiers[i]);
                identifierExists[identifiers[i]] = true;
                versionHistory[identifiers[i]][1] = contracts[identifiers[i]];
                
                emit ContractRegistered(identifiers[i], addresses[i], 1, descriptions[i]);
            }
        }
    }
    
    // =============================================================================
    // DEACTIVATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Deactivate a contract in the registry
     * @param identifier Contract identifier
     */
    function deactivateContract(bytes32 identifier) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        if (!contracts[identifier].isActive) revert ContractNotActive();
        
        contracts[identifier].isActive = false;
        emit ContractDeactivated(identifier);
    }
    
    /**
     * @notice Reactivate a previously deactivated contract
     * @param identifier Contract identifier
     */
    function reactivateContract(bytes32 identifier) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        if (contracts[identifier].isActive) revert ContractNotActive();
        
        contracts[identifier].isActive = true;
        emit ContractReactivated(identifier);
    }
    
    // =============================================================================
    // GETTER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get contract address by identifier
     * @param identifier Contract identifier
     * @return Contract address
     */
    function getContract(bytes32 identifier) external view returns (address) {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        if (!contracts[identifier].isActive) revert ContractNotActive();
        return contracts[identifier].contractAddress;
    }
    
    /**
     * @notice Get detailed contract information
     * @param identifier Contract identifier
     * @return Contract information struct
     */
    function getContractInfo(bytes32 identifier) 
        external 
        view 
        returns (ContractInfo memory) 
    {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        return contracts[identifier];
    }
    
    /**
     * @notice Get multiple contracts at once (gas optimization)
     * @param identifiers Array of identifiers
     * @return addresses Array of addresses
     */
    function getContracts(bytes32[] calldata identifiers) 
        external 
        view 
        returns (address[] memory addresses) 
    {
        addresses = new address[](identifiers.length);
        for (uint256 i = 0; i < identifiers.length; ++i) {
            if (identifierExists[identifiers[i]] && contracts[identifiers[i]].isActive) {
                addresses[i] = contracts[identifiers[i]].contractAddress;
            }
        }
    }
    
    /**
     * @notice Get all registered identifiers
     * @return Array of all identifiers
     */
    function getAllIdentifiers() external view returns (bytes32[] memory) {
        return contractIdentifiers;
    }
    
    /**
     * @notice Get contract at specific version
     * @param identifier Contract identifier
     * @param version Version number
     * @return Contract address at that version
     */
    function getContractAtVersion(bytes32 identifier, uint256 version) 
        external 
        view 
        returns (address) 
    {
        if (!identifierExists[identifier]) revert ContractNotRegistered();
        if (version == 0 || version > contracts[identifier].version) revert InvalidVersion();
        return versionHistory[identifier][version].contractAddress;
    }
    
    /**
     * @notice Check if address is a registered OmniCoin contract
     * @param contractAddress Address to check
     * @return Whether address is registered
     */
    function isOmniCoinContract(address contractAddress) external view returns (bool) {
        for (uint256 i = 0; i < contractIdentifiers.length; ++i) {
            if (contracts[contractIdentifiers[i]].contractAddress == contractAddress && 
                contracts[contractIdentifiers[i]].isActive) {
                return true;
            }
        }
        return false;
    }
    
    // =============================================================================
    // EMERGENCY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update emergency admin
     * @param newAdmin New emergency admin address
     */
    function updateEmergencyAdmin(address newAdmin) external {
        if (msg.sender != emergencyAdmin) revert UnauthorizedUpgrade();
        if (newAdmin == address(0)) revert InvalidAddress();
        
        address oldAdmin = emergencyAdmin;
        emergencyAdmin = newAdmin;
        
        emit EmergencyAdminUpdated(oldAdmin, newAdmin);
    }
    
    /**
     * @notice Update emergency fallback address
     * @param identifier Contract identifier
     * @param newFallback New emergency fallback address
     */
    function updateEmergencyFallback(bytes32 identifier, address newFallback) external onlyRole(ADMIN_ROLE) {
        if (newFallback == address(0)) revert InvalidAddress();
        
        address oldFallback = emergencyFallback[identifier];
        emergencyFallback[identifier] = newFallback;
        
        emit EmergencyFallbackUpdated(identifier, oldFallback, newFallback);
    }
    
    /**
     * @notice Emergency pause the registry
     */
    function emergencyPause() external {
        if (msg.sender != emergencyAdmin) 
            revert UnauthorizedUpgrade();
        _pause();
    }
    
    /**
     * @notice Unpause the registry
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // MIGRATION SUPPORT
    // =============================================================================
    
    /**
     * @notice Export all contract data for migration
     * @return identifiers Array of identifiers
     * @return addresses Array of current addresses
     * @return versions Array of versions
     */
    function exportRegistry() 
        external 
        view 
        returns (
            bytes32[] memory identifiers,
            address[] memory addresses,
            uint256[] memory versions
        ) 
    {
        uint256 length = contractIdentifiers.length;
        identifiers = new bytes32[](length);
        addresses = new address[](length);
        versions = new uint256[](length);
        
        for (uint256 i = 0; i < length; ++i) {
            bytes32 id = contractIdentifiers[i];
            identifiers[i] = id;
            addresses[i] = contracts[id].contractAddress;
            versions[i] = contracts[id].version;
        }
    }
}