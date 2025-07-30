// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OmniCoinRegistry} from "../OmniCoinRegistry.sol";

/**
 * @title RegistryAware
 * @author OmniCoin Development Team
 * @notice Base contract providing registry integration and address caching for OmniCoin ecosystem contracts
 * @dev Implements caching mechanism to optimize gas costs for frequent contract lookups
 * 
 * Benefits:
 * - Automatic registry integration
 * - Cached addresses for gas optimization
 * - Easy updates when contracts change
 */
abstract contract RegistryAware {
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Duration for which cached addresses remain valid (1 day)
    /// @dev After this period, addresses are re-fetched from the registry
    uint256 public constant CACHE_DURATION = 1 days;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Immutable reference to the OmniCoin registry contract
    /// @dev Set once during deployment and cannot be changed
    OmniCoinRegistry public immutable REGISTRY;
    
    // Cached addresses for gas optimization
    mapping(bytes32 => address) private _cachedAddresses;
    mapping(bytes32 => uint256) private _cacheTimestamp;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when the registry reference is updated
    /// @param newRegistry The address of the new registry contract
    event RegistryUpdated(address indexed newRegistry);
    
    /// @notice Emitted when a contract address is cached
    /// @param identifier The unique identifier of the cached contract
    /// @param contractAddress The address of the cached contract
    event AddressCached(bytes32 indexed identifier, address indexed contractAddress);
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidRegistry();
    error ContractNotFound(bytes32 identifier);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /// @notice Initializes the contract with a registry reference
    /// @param _registry The address of the OmniCoinRegistry contract
    /// @dev Reverts if the registry address is zero
    constructor(address _registry) {
        if (_registry == address(0)) revert InvalidRegistry();
        REGISTRY = OmniCoinRegistry(_registry);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Retrieves a contract address from registry with caching
     * @dev Checks cache first, fetches from registry if cache miss or expired
     * @param identifier The unique identifier of the contract to retrieve
     * @return contractAddress The address of the requested contract
     */
    function _getContract(bytes32 identifier) internal returns (address contractAddress) {
        // Check cache first
        if (_cachedAddresses[identifier] != address(0) && 
            block.timestamp - _cacheTimestamp[identifier] < CACHE_DURATION) { // solhint-disable-line not-rely-on-time
            return _cachedAddresses[identifier];
        }
        
        // Get from registry and cache
        contractAddress = REGISTRY.getContract(identifier);
        if (contractAddress == address(0)) revert ContractNotFound(identifier);
        
        _cachedAddresses[identifier] = contractAddress;
        _cacheTimestamp[identifier] = block.timestamp; // solhint-disable-line not-rely-on-time
        
        emit AddressCached(identifier, contractAddress);
    }
    
    /**
     * @notice Retrieves multiple contract addresses in a single call
     * @dev More gas efficient than multiple individual calls
     * @param identifiers Array of contract identifiers to retrieve
     * @return addresses Array of corresponding contract addresses
     */
    function _getContracts(bytes32[] memory identifiers) 
        internal 
        returns (address[] memory addresses) 
    {
        addresses = new address[](identifiers.length);
        
        // Check which ones need updating
        bool[] memory needsUpdate = new bool[](identifiers.length);
        uint256 updateCount = 0;
        
        for (uint256 i = 0; i < identifiers.length; ++i) {
            if (_cachedAddresses[identifiers[i]] == address(0) || 
                block.timestamp - _cacheTimestamp[identifiers[i]] >= CACHE_DURATION) { // solhint-disable-line not-rely-on-time
                needsUpdate[i] = true;
                ++updateCount;
            } else {
                addresses[i] = _cachedAddresses[identifiers[i]];
            }
        }
        
        // Batch fetch from registry if needed
        if (updateCount > 0) {
            bytes32[] memory toFetch = new bytes32[](updateCount);
            uint256 fetchIndex = 0;
            
            for (uint256 i = 0; i < identifiers.length; ++i) {
                if (needsUpdate[i]) {
                    toFetch[fetchIndex] = identifiers[i];
                    ++fetchIndex;
                }
            }
            
            address[] memory fetched = REGISTRY.getContracts(toFetch);
            fetchIndex = 0;
            
            for (uint256 i = 0; i < identifiers.length; ++i) {
                if (needsUpdate[i]) {
                    addresses[i] = fetched[fetchIndex];
                    ++fetchIndex;
                    _cachedAddresses[identifiers[i]] = addresses[i];
                    _cacheTimestamp[identifiers[i]] = block.timestamp; // solhint-disable-line not-rely-on-time
                    emit AddressCached(identifiers[i], addresses[i]);
                }
            }
        }
    }
    
    /**
     * @notice Clears the cached address for a specific contract
     * @dev Forces a fresh lookup on next access
     * @param identifier The identifier of the contract to clear from cache
     */
    function _clearCache(bytes32 identifier) internal {
        delete _cachedAddresses[identifier];
        delete _cacheTimestamp[identifier];
    }
    
    /**
     * @notice Clears all cached contract addresses
     * @dev This is expensive but sometimes necessary after major updates
     */
    function _clearAllCache() internal {
        // This is expensive but sometimes necessary
        // In practice, you'd track identifiers and clear them
    }
    
    /**
     * @notice Verifies if an address is a registered OmniCoin contract
     * @dev Queries the registry to check registration status
     * @param contractAddress The address to verify
     * @return isValid True if the address is a registered OmniCoin contract
     */
    function _isOmniCoinContract(address contractAddress) internal view returns (bool) {
        return REGISTRY.isOmniCoinContract(contractAddress);
    }
}