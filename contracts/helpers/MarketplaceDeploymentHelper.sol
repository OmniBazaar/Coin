// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../OmniCoinRegistry.sol";
import "../OmniNFTMarketplace.sol";
import "../ListingNFT.sol";
import "../ReputationSystem.sol";

/**
 * @title MarketplaceDeploymentHelper
 * @dev Specialized deployment helper for marketplace-related contracts
 * 
 * This helper focuses on deploying and configuring the marketplace ecosystem
 * including NFT marketplace, listing NFTs, and reputation systems
 */
contract MarketplaceDeploymentHelper {
    
    OmniCoinRegistry public immutable registry;
    
    event ContractDeployed(string contractName, address contractAddress);
    event MarketplaceConfigured(address marketplace, uint256 timestamp);
    
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = OmniCoinRegistry(_registry);
    }
    
    /**
     * @dev Deploy NFT marketplace with all dependencies
     */
    function deployMarketplaceEcosystem(
        address admin,
        uint256 platformFee,
        address feeRecipient,
        string memory listingNFTName,
        string memory listingNFTSymbol
    ) external returns (
        address marketplace,
        address listingNFT,
        address reputation
    ) {
        // Deploy ListingNFT contract
        listingNFT = address(new ListingNFT(address(registry), admin));
        registry.registerContract(
            keccak256("LISTING_NFT"),
            listingNFT,
            "Listing NFT contract"
        );
        emit ContractDeployed("ListingNFT", listingNFT);
        
        // Deploy ReputationSystem
        reputation = address(new ReputationSystem(
            address(registry),
            admin
        ));
        registry.registerContract(
            registry.REPUTATION_CORE(),
            reputation,
            "Reputation System V2"
        );
        emit ContractDeployed("ReputationSystemBase", reputation);
        
        // Deploy NFT Marketplace
        marketplace = deployNFTMarketplace(
            admin,
            listingNFT,
            platformFee,
            feeRecipient
        );
        
        // Configure marketplace permissions
        configureMarketplacePermissions(marketplace, listingNFT, admin);
        
        emit MarketplaceConfigured(marketplace, block.timestamp);
        
        return (marketplace, listingNFT, reputation);
    }
    
    /**
     * @dev Deploy just the NFT marketplace
     */
    function deployNFTMarketplace(
        address admin,
        address listingNFT,
        uint256 platformFee,
        address feeRecipient
    ) public returns (address marketplace) {
        address token = registry.getContract(registry.OMNICOIN_CORE());
        address escrow = registry.getContract(registry.ESCROW());
        address privacyFeeManager = registry.getContract(registry.FEE_MANAGER());
        
        marketplace = address(new OmniNFTMarketplace());
        
        // Initialize the upgradeable marketplace
        OmniNFTMarketplace(marketplace).initialize(
            token,
            escrow,
            listingNFT,
            privacyFeeManager,
            platformFee,
            feeRecipient
        );
        
        registry.registerContract(
            registry.NFT_MARKETPLACE(),
            marketplace,
            "NFT Marketplace V2"
        );
        emit ContractDeployed("OmniNFTMarketplace", marketplace);
        
        return marketplace;
    }
    
    /**
     * @dev Configure marketplace permissions and integrations
     */
    function configureMarketplacePermissions(
        address marketplace,
        address listingNFT,
        address admin
    ) public {
        // Set marketplace as approved minter for listing NFTs
        ListingNFT(listingNFT).setApprovedMinter(marketplace, true);
        
        // Additional configuration can be added here
    }
    
    /**
     * @dev Deploy additional marketplace features
     */
    function deployMarketplaceAddons(
        address admin
    ) external returns (
        address auctionExtension,
        address bundleManager,
        address royaltyEngine
    ) {
        // These would be additional contracts for extended marketplace functionality
        // Placeholder for future implementation
        
        return (address(0), address(0), address(0));
    }
    
    /**
     * @dev Verify marketplace deployment
     */
    function verifyMarketplaceDeployment() external view returns (bool) {
        address marketplace = registry.getContract(registry.NFT_MARKETPLACE());
        address reputation = registry.getContract(registry.REPUTATION_CORE());
        address listingNFT = registry.getContract(keccak256("LISTING_NFT"));
        
        return (
            marketplace != address(0) &&
            reputation != address(0) &&
            listingNFT != address(0)
        );
    }
}