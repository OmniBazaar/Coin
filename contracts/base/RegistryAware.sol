// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../OmniCoinRegistry.sol";

/**
 * @title RegistryAware
 * @dev Base contract for contracts that need to interact with the registry
 * 
 * Benefits:
 * - Automatic registry integration
 * - Cached addresses for gas optimization
 * - Easy updates when contracts change
 */
abstract contract RegistryAware {
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    OmniCoinRegistry public immutable registry;
    
    // Cached addresses for gas optimization
    mapping(bytes32 => address) private _cachedAddresses;
    mapping(bytes32 => uint256) private _cacheTimestamp;
    
    // Cache duration (1 day default)
    uint256 public constant CACHE_DURATION = 1 days;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event RegistryUpdated(address indexed newRegistry);
    event AddressCached(bytes32 indexed identifier, address indexed contractAddress);
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidRegistry();
    error ContractNotFound(bytes32 identifier);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(address _registry) {
        if (_registry == address(0)) revert InvalidRegistry();
        registry = OmniCoinRegistry(_registry);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get contract address from registry with caching
     * @param identifier Contract identifier
     * @return contractAddress The contract address
     */
    function _getContract(bytes32 identifier) internal returns (address contractAddress) {
        // Check cache first
        if (_cachedAddresses[identifier] != address(0) && 
            block.timestamp - _cacheTimestamp[identifier] < CACHE_DURATION) {
            return _cachedAddresses[identifier];
        }
        
        // Get from registry and cache
        contractAddress = registry.getContract(identifier);
        if (contractAddress == address(0)) revert ContractNotFound(identifier);
        
        _cachedAddresses[identifier] = contractAddress;
        _cacheTimestamp[identifier] = block.timestamp;
        
        emit AddressCached(identifier, contractAddress);
    }
    
    /**
     * @dev Get multiple contracts at once (more gas efficient)
     * @param identifiers Array of contract identifiers
     * @return addresses Array of contract addresses
     */
    function _getContracts(bytes32[] memory identifiers) 
        internal 
        returns (address[] memory addresses) 
    {
        addresses = new address[](identifiers.length);
        
        // Check which ones need updating
        bool[] memory needsUpdate = new bool[](identifiers.length);
        uint256 updateCount = 0;
        
        for (uint256 i = 0; i < identifiers.length; i++) {
            if (_cachedAddresses[identifiers[i]] == address(0) || 
                block.timestamp - _cacheTimestamp[identifiers[i]] >= CACHE_DURATION) {
                needsUpdate[i] = true;
                updateCount++;
            } else {
                addresses[i] = _cachedAddresses[identifiers[i]];
            }
        }
        
        // Batch fetch from registry if needed
        if (updateCount > 0) {
            bytes32[] memory toFetch = new bytes32[](updateCount);
            uint256 fetchIndex = 0;
            
            for (uint256 i = 0; i < identifiers.length; i++) {
                if (needsUpdate[i]) {
                    toFetch[fetchIndex++] = identifiers[i];
                }
            }
            
            address[] memory fetched = registry.getContracts(toFetch);
            fetchIndex = 0;
            
            for (uint256 i = 0; i < identifiers.length; i++) {
                if (needsUpdate[i]) {
                    addresses[i] = fetched[fetchIndex++];
                    _cachedAddresses[identifiers[i]] = addresses[i];
                    _cacheTimestamp[identifiers[i]] = block.timestamp;
                    emit AddressCached(identifiers[i], addresses[i]);
                }
            }
        }
    }
    
    /**
     * @dev Clear cache for a specific contract
     * @param identifier Contract identifier
     */
    function _clearCache(bytes32 identifier) internal {
        delete _cachedAddresses[identifier];
        delete _cacheTimestamp[identifier];
    }
    
    /**
     * @dev Clear entire cache
     */
    function _clearAllCache() internal {
        // This is expensive but sometimes necessary
        // In practice, you'd track identifiers and clear them
    }
    
    /**
     * @dev Check if an address is a valid OmniCoin contract
     * @param contractAddress Address to verify
     * @return isValid Whether the address is registered
     */
    function _isOmniCoinContract(address contractAddress) internal view returns (bool) {
        return registry.isOmniCoinContract(contractAddress);
    }
}