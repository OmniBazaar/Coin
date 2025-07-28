// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/RegistryAware.sol";
import "../OmniCoin.sol";
import "../PrivateOmniCoin.sol";
import "../OmniCoinReputationCore.sol";
import "../OmniCoinEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RegistryIntegrationExample
 * @dev Example showing how contracts use the registry
 * 
 * This demonstrates:
 * - How to inherit from RegistryAware
 * - How to get contract addresses dynamically
 * - Gas optimization through caching
 * - Reduced deployment costs
 */
contract RegistryIntegrationExample is RegistryAware {
    
    // Instead of storing addresses:
    // OmniCoinCore public token;           // 20,000 gas to store
    // OmniCoinReputationCore public reputation;  // 20,000 gas to store
    // OmniCoinEscrow public escrow;      // 20,000 gas to store
    
    // We just use the registry (one-time cost)
    
    constructor(address _registry) RegistryAware(_registry) {
        // No need to pass multiple addresses!
        // Saves deployment gas
    }
    
    /**
     * @dev Example: Check user reputation before allowing action
     */
    function checkUserReputation(address user) external returns (bool) {
        // Get reputation contract dynamically
        address reputationAddr = _getContract(registry.REPUTATION_CORE());
        OmniCoinReputationCore reputation = OmniCoinReputationCore(reputationAddr);
        
        // Check if user is eligible
        return reputation.isEligibleValidator(user);
    }
    
    /**
     * @dev Example: Transfer tokens using registry
     */
    function transferTokens(address to, uint256 amount) external {
        // Get token contract
        address tokenAddr = _getContract(registry.OMNICOIN());
        // OmniCoinCore is deprecated - use standard ERC20 interface
        IERC20 token = IERC20(tokenAddr);
        
        // Perform transfer (example - actual implementation would need proper interface)
        // token.transferFrom(msg.sender, to, amount);
    }
    
    /**
     * @dev Example: Create escrow using multiple contracts
     */
    function createEscrowWithReputationCheck(
        address buyer,
        address seller,
        uint256 amount
    ) external returns (uint256) {
        // Batch get contracts for efficiency
        bytes32[] memory identifiers = new bytes32[](3);
        identifiers[0] = registry.OMNICOIN();
        identifiers[1] = registry.REPUTATION_CORE();
        identifiers[2] = registry.ESCROW();
        
        address[] memory contracts = _getContracts(identifiers);
        
        IERC20 token = IERC20(contracts[0]);
        OmniCoinReputationCore reputation = OmniCoinReputationCore(contracts[1]);
        OmniCoinEscrow escrow = OmniCoinEscrow(contracts[2]);
        
        // Check reputations
        require(
            reputation.getPublicReputationTier(buyer) >= 1,
            "Buyer reputation too low"
        );
        require(
            reputation.getPublicReputationTier(seller) >= 1,
            "Seller reputation too low"
        );
        
        // Create escrow (simplified - missing some parameters)
        // return escrow.createEscrow(...);
        return 0; // Placeholder
    }
    
    /**
     * @dev Example: Admin function to clear cache after registry update
     */
    function refreshContracts() external {
        // Clear specific caches after registry update
        _clearCache(registry.OMNICOIN_CORE());
        _clearCache(registry.REPUTATION_CORE());
        _clearCache(registry.ESCROW());
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