// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OmniCoinRegistry
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
    // ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    
    // =============================================================================
    // CONTRACT IDENTIFIERS
    // =============================================================================
    
    // Core contracts
    bytes32 public constant OMNICOIN_CORE = keccak256("OMNICOIN_CORE");
    bytes32 public constant OMNICOIN_CONFIG = keccak256("OMNICOIN_CONFIG");
    bytes32 public constant FEE_DISTRIBUTION = keccak256("FEE_DISTRIBUTION");
    
    // Reputation system
    bytes32 public constant REPUTATION_CORE = keccak256("REPUTATION_CORE");
    bytes32 public constant IDENTITY_VERIFICATION = keccak256("IDENTITY_VERIFICATION");
    bytes32 public constant TRUST_SYSTEM = keccak256("TRUST_SYSTEM");
    bytes32 public constant REFERRAL_SYSTEM = keccak256("REFERRAL_SYSTEM");
    
    // Financial contracts
    bytes32 public constant ESCROW = keccak256("ESCROW");
    bytes32 public constant PAYMENT = keccak256("PAYMENT");
    bytes32 public constant STAKING = keccak256("STAKING");
    
    // Governance and dispute
    bytes32 public constant GOVERNANCE = keccak256("GOVERNANCE");
    bytes32 public constant ARBITRATION = keccak256("ARBITRATION");
    
    // Bridge
    bytes32 public constant BRIDGE = keccak256("BRIDGE");
    
    // Future expansions
    bytes32 public constant DEX = keccak256("DEX");
    bytes32 public constant MARKETPLACE = keccak256("MARKETPLACE");
    bytes32 public constant VALIDATOR_MANAGER = keccak256("VALIDATOR_MANAGER");
    bytes32 public constant GAS_RELAYER = keccak256("GAS_RELAYER");
    bytes32 public constant FEE_MANAGER = keccak256("FEE_MANAGER");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct ContractInfo {
        address contractAddress;
        uint256 version;
        bool isActive;
        string description;
        uint256 deployedAt;
        uint256 updatedAt;
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Mapping from contract identifier to contract info
    mapping(bytes32 => ContractInfo) public contracts;
    
    /// @dev Array of all registered contract identifiers
    bytes32[] public contractIdentifiers;
    
    /// @dev Mapping to check if identifier exists
    mapping(bytes32 => bool) public identifierExists;
    
    /// @dev Version history: identifier => version => address
    mapping(bytes32 => mapping(uint256 => address)) public versionHistory;
    
    /// @dev Emergency contacts
    address public emergencyAdmin;
    address public emergencyFallback;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ContractRegistered(
        bytes32 indexed identifier,
        address indexed contractAddress,
        uint256 version,
        string description
    );
    
    event ContractUpdated(
        bytes32 indexed identifier,
        address indexed oldAddress,
        address indexed newAddress,
        uint256 newVersion
    );
    
    event ContractDeactivated(bytes32 indexed identifier);
    event ContractReactivated(bytes32 indexed identifier);
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event EmergencyFallbackUpdated(address indexed oldFallback, address indexed newFallback);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(address _admin) {
        require(_admin != address(0), "Registry: Invalid admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPDATER_ROLE, _admin);
        
        emergencyAdmin = _admin;
        emergencyFallback = _admin;
    }
    
    // =============================================================================
    // REGISTRATION FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Register a new contract
     * @param identifier Unique identifier for the contract
     * @param contractAddress Address of the contract
     * @param description Human-readable description
     */
    function registerContract(
        bytes32 identifier,
        address contractAddress,
        string calldata description
    ) external onlyRole(ADMIN_ROLE) whenNotPaused {
        require(identifier != bytes32(0), "Registry: Invalid identifier");
        require(contractAddress != address(0), "Registry: Invalid address");
        require(!identifierExists[identifier], "Registry: Already registered");
        
        contracts[identifier] = ContractInfo({
            contractAddress: contractAddress,
            version: 1,
            isActive: true,
            description: description,
            deployedAt: block.timestamp,
            updatedAt: block.timestamp
        });
        
        contractIdentifiers.push(identifier);
        identifierExists[identifier] = true;
        versionHistory[identifier][1] = contractAddress;
        
        emit ContractRegistered(identifier, contractAddress, 1, description);
    }
    
    /**
     * @dev Update an existing contract address
     * @param identifier Contract identifier
     * @param newAddress New contract address
     */
    function updateContract(
        bytes32 identifier,
        address newAddress
    ) external onlyRole(UPDATER_ROLE) whenNotPaused {
        require(identifierExists[identifier], "Registry: Not registered");
        require(newAddress != address(0), "Registry: Invalid address");
        require(contracts[identifier].isActive, "Registry: Contract inactive");
        
        ContractInfo storage info = contracts[identifier];
        address oldAddress = info.contractAddress;
        
        info.contractAddress = newAddress;
        info.version++;
        info.updatedAt = block.timestamp;
        
        versionHistory[identifier][info.version] = newAddress;
        
        emit ContractUpdated(identifier, oldAddress, newAddress, info.version);
    }
    
    /**
     * @dev Batch register contracts
     * @param identifiers Array of identifiers
     * @param addresses Array of addresses
     * @param descriptions Array of descriptions
     */
    function batchRegister(
        bytes32[] calldata identifiers,
        address[] calldata addresses,
        string[] calldata descriptions
    ) external onlyRole(ADMIN_ROLE) whenNotPaused {
        require(
            identifiers.length == addresses.length && 
            addresses.length == descriptions.length,
            "Registry: Length mismatch"
        );
        
        for (uint256 i = 0; i < identifiers.length; i++) {
            if (!identifierExists[identifiers[i]] && addresses[i] != address(0)) {
                contracts[identifiers[i]] = ContractInfo({
                    contractAddress: addresses[i],
                    version: 1,
                    isActive: true,
                    description: descriptions[i],
                    deployedAt: block.timestamp,
                    updatedAt: block.timestamp
                });
                
                contractIdentifiers.push(identifiers[i]);
                identifierExists[identifiers[i]] = true;
                versionHistory[identifiers[i]][1] = addresses[i];
                
                emit ContractRegistered(identifiers[i], addresses[i], 1, descriptions[i]);
            }
        }
    }
    
    // =============================================================================
    // DEACTIVATION FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Deactivate a contract
     * @param identifier Contract identifier
     */
    function deactivateContract(bytes32 identifier) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(identifierExists[identifier], "Registry: Not registered");
        require(contracts[identifier].isActive, "Registry: Already inactive");
        
        contracts[identifier].isActive = false;
        emit ContractDeactivated(identifier);
    }
    
    /**
     * @dev Reactivate a contract
     * @param identifier Contract identifier
     */
    function reactivateContract(bytes32 identifier) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(identifierExists[identifier], "Registry: Not registered");
        require(!contracts[identifier].isActive, "Registry: Already active");
        
        contracts[identifier].isActive = true;
        emit ContractReactivated(identifier);
    }
    
    // =============================================================================
    // GETTER FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get contract address by identifier
     * @param identifier Contract identifier
     * @return Contract address
     */
    function getContract(bytes32 identifier) external view returns (address) {
        require(identifierExists[identifier], "Registry: Not registered");
        require(contracts[identifier].isActive, "Registry: Contract inactive");
        return contracts[identifier].contractAddress;
    }
    
    /**
     * @dev Get contract info
     * @param identifier Contract identifier
     * @return Contract information
     */
    function getContractInfo(bytes32 identifier) 
        external 
        view 
        returns (ContractInfo memory) 
    {
        require(identifierExists[identifier], "Registry: Not registered");
        return contracts[identifier];
    }
    
    /**
     * @dev Get multiple contracts at once (gas optimization)
     * @param identifiers Array of identifiers
     * @return addresses Array of addresses
     */
    function getContracts(bytes32[] calldata identifiers) 
        external 
        view 
        returns (address[] memory addresses) 
    {
        addresses = new address[](identifiers.length);
        for (uint256 i = 0; i < identifiers.length; i++) {
            if (identifierExists[identifiers[i]] && contracts[identifiers[i]].isActive) {
                addresses[i] = contracts[identifiers[i]].contractAddress;
            }
        }
    }
    
    /**
     * @dev Get all registered identifiers
     * @return Array of all identifiers
     */
    function getAllIdentifiers() external view returns (bytes32[] memory) {
        return contractIdentifiers;
    }
    
    /**
     * @dev Get contract at specific version
     * @param identifier Contract identifier
     * @param version Version number
     * @return Contract address at that version
     */
    function getContractAtVersion(bytes32 identifier, uint256 version) 
        external 
        view 
        returns (address) 
    {
        require(identifierExists[identifier], "Registry: Not registered");
        require(version > 0 && version <= contracts[identifier].version, "Registry: Invalid version");
        return versionHistory[identifier][version];
    }
    
    /**
     * @dev Check if address is a registered OmniCoin contract
     * @param contractAddress Address to check
     * @return bool Whether address is registered
     */
    function isOmniCoinContract(address contractAddress) external view returns (bool) {
        for (uint256 i = 0; i < contractIdentifiers.length; i++) {
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
     * @dev Update emergency admin
     * @param newAdmin New emergency admin address
     */
    function updateEmergencyAdmin(address newAdmin) external {
        require(msg.sender == emergencyAdmin, "Registry: Not emergency admin");
        require(newAdmin != address(0), "Registry: Invalid admin");
        
        address oldAdmin = emergencyAdmin;
        emergencyAdmin = newAdmin;
        
        emit EmergencyAdminUpdated(oldAdmin, newAdmin);
    }
    
    /**
     * @dev Update emergency fallback
     * @param newFallback New emergency fallback address
     */
    function updateEmergencyFallback(address newFallback) external onlyRole(ADMIN_ROLE) {
        require(newFallback != address(0), "Registry: Invalid fallback");
        
        address oldFallback = emergencyFallback;
        emergencyFallback = newFallback;
        
        emit EmergencyFallbackUpdated(oldFallback, newFallback);
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external {
        require(
            msg.sender == emergencyAdmin || msg.sender == emergencyFallback,
            "Registry: Not authorized"
        );
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // MIGRATION SUPPORT
    // =============================================================================
    
    /**
     * @dev Export all contract data for migration
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
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = contractIdentifiers[i];
            identifiers[i] = id;
            addresses[i] = contracts[id].contractAddress;
            versions[i] = contracts[id].version;
        }
    }
}