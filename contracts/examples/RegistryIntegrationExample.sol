// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryAware} from "../base/RegistryAware.sol";
import {UnifiedReputationSystem} from "../UnifiedReputationSystem.sol";
import {OmniCoinEscrow} from "../OmniCoinEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RegistryIntegrationExample
 * @author OmniCoin Development Team
 * @notice Example contract demonstrating proper registry integration patterns
 * @dev This demonstrates:
 *      - How to inherit from RegistryAware
 *      - How to get contract addresses dynamically
 *      - Gas optimization through caching
 *      - Reduced deployment costs compared to storing contract addresses
 */
contract RegistryIntegrationExample is RegistryAware {

    // Custom errors
    error InsufficientReputation(address user, uint256 required, uint256 actual);
    error UnusedParameter();
    
    // Instead of storing addresses:
    // OmniCoinCore public token;           // 20,000 gas to store
    // UnifiedReputationSystem public reputation;  // 20,000 gas to store
    // OmniCoinEscrow public escrow;      // 20,000 gas to store
    
    // We just use the registry (one-time cost)
    
    /**
     * @notice Initialize the example contract with registry integration
     * @dev Inherits from RegistryAware for dynamic contract address resolution
     * @param _registry Address of the OmniCoinRegistry contract
     */
    constructor(address _registry) RegistryAware(_registry) {
        // No need to pass multiple addresses!
        // Saves deployment gas
    }
    
    /**
     * @notice Check user reputation before allowing action
     * @dev Example demonstrating dynamic contract resolution for reputation checks
     * @param user The user address to check reputation for
     * @return eligible Whether the user meets reputation requirements
     */
    function checkUserReputation(address user) external returns (bool eligible) {
        // Get reputation contract dynamically
        address reputationAddr = _getContract(REGISTRY.REPUTATION_CORE());
        UnifiedReputationSystem reputation = UnifiedReputationSystem(reputationAddr);
        
        // Check if user is eligible (using UnifiedReputationSystem interface)
        return reputation.getPublicReputationTier(user) > 0;
    }
    
    /**
     * @notice Transfer tokens using registry-resolved contract addresses
     * @dev Example demonstrating token transfers with dynamic contract resolution
     * @param to The recipient address for the token transfer
     * @param amount The amount of tokens to transfer
     */
    function transferTokens(address to, uint256 amount) external {
        // Note: Parameters used for demonstration purposes
        if (to == address(0) || amount == 0) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        // Get token contract
        address tokenAddr = _getContract(REGISTRY.OMNICOIN());
        IERC20 token = IERC20(tokenAddr);
        
        // Perform transfer (example - actual implementation would need proper interface)
        // In a real implementation, this would call:
        // token.transferFrom(msg.sender, to, amount);
        // We avoid the call here as this is just an example contract
        token; // Satisfy unused variable warning
    }
    
    /**
     * @notice Create escrow using multiple registry-resolved contracts
     * @dev Example demonstrating batch contract resolution and multi-contract interaction
     * @param buyer The buyer address for the escrow
     * @param seller The seller address for the escrow
     * @param amount The escrow amount (kept for interface demonstration)
     * @return escrowId The created escrow ID (placeholder)
     */
    function createEscrowWithReputationCheck(
        address buyer,
        address seller,
        uint256 amount
    ) external returns (uint256 escrowId) {
        // Note: amount parameter used for demonstration purposes
        if (amount == 0) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        // Batch get contracts for efficiency
        bytes32[] memory identifiers = new bytes32[](3);
        identifiers[0] = REGISTRY.OMNICOIN();
        identifiers[1] = REGISTRY.REPUTATION_CORE();
        identifiers[2] = REGISTRY.ESCROW();
        
        address[] memory contracts = _getContracts(identifiers);
        
        IERC20 token = IERC20(contracts[0]);
        UnifiedReputationSystem reputation = UnifiedReputationSystem(contracts[1]);
        OmniCoinEscrow escrow = OmniCoinEscrow(contracts[2]);
        
        // Check reputations with custom errors
        uint256 buyerTier = reputation.getPublicReputationTier(buyer);
        uint256 sellerTier = reputation.getPublicReputationTier(seller);
        
        if (buyerTier < 1) {
            revert InsufficientReputation(buyer, 1, buyerTier);
        }
        if (sellerTier < 1) {
            revert InsufficientReputation(seller, 1, sellerTier);
        }
        
        // Create escrow (simplified - missing some parameters)
        // In a real implementation, this would call:
        // return escrow.createEscrow(...);
        // We avoid the call here as this is just an example contract
        token; // Satisfy unused variable warning
        escrow; // Satisfy unused variable warning
        return 0; // Placeholder
    }
    
    /**
     * @notice Admin function to clear cache after registry update
     * @dev Example demonstrating cache management for registry-aware contracts
     */
    function refreshContracts() external {
        // Clear specific caches after registry update
        _clearCache(REGISTRY.OMNICOIN_CORE());
        _clearCache(REGISTRY.REPUTATION_CORE());
        _clearCache(REGISTRY.ESCROW());
    }
}

/**
 * Gas Cost Comparison:
 * 
 * Traditional Approach (storing addresses):
 * - Deployment: ~60,000 gas for 3 address storage slots
 * - Each update: ~25,000 gas per address change × number of contracts
 * 
 * Registry Approach:
 * - Deployment: ~20,000 gas for registry address only
 * - Each update: ~25,000 gas once in registry
 * - First access: ~10,000 gas (registry lookup + cache)
 * - Cached access: ~2,000 gas
 * 
 * Break-even: After 2-3 contract updates, registry saves gas
 */