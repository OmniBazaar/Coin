// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../OmniCoinRegistry.sol";
import "../OmniCoin.sol";
import "../PrivateOmniCoin.sol";
import "../OmniCoinConfig.sol";
import "../OmniCoinEscrow.sol";
import "../OmniCoinPayment.sol";
import "../OmniCoinStaking.sol";
import "../OmniCoinArbitration.sol";
import "../OmniCoinBridge.sol";
import "../OmniCoinPrivacyBridge.sol";
import "../PrivacyFeeManager.sol";
import "../DEXSettlement.sol";
import "../OmniNFTMarketplace.sol";

/**
 * @title DeploymentHelper
 * @dev Helper contract for deploying OmniCoin ecosystem with Registry pattern
 * 
 * This replaces the monolithic factory approach with modular deployment
 * Each contract is deployed individually and registered in the registry
 */
contract DeploymentHelper {
    
    OmniCoinRegistry public immutable registry;
    
    event ContractDeployed(string contractName, address contractAddress);
    event DeploymentComplete(uint256 timestamp);
    
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = OmniCoinRegistry(_registry);
    }
    
    /**
     * @dev Deploy core contracts
     */
    function deployCoreContracts(
        address admin,
        address cotiToken,
        uint256 minimumValidators
    ) public returns (
        address core,
        address config,
        address privacyFeeManager
    ) {
        // Deploy Config
        config = address(new OmniCoinConfig(address(registry), admin));
        registry.registerContract(registry.OMNICOIN_CONFIG(), config, "Configuration contract");
        emit ContractDeployed("OmniCoinConfig", config);
        
        // Deploy OmniCoin (public token)
        core = address(new OmniCoin(address(registry)));
        registry.registerContract(registry.OMNICOIN(), core, "OmniCoin public token");
        emit ContractDeployed("OmniCoin", core);
        
        // Deploy PrivateOmniCoin
        address privateToken = address(new PrivateOmniCoin(address(registry)));
        registry.registerContract(registry.PRIVATE_OMNICOIN(), privateToken, "PrivateOmniCoin privacy token");
        emit ContractDeployed("PrivateOmniCoin", privateToken);
        
        // Deploy PrivacyFeeManager
        privacyFeeManager = address(new PrivacyFeeManager(
            address(registry),
            cotiToken, // Using cotiToken as treasury
            admin
        ));
        registry.registerContract(registry.FEE_MANAGER(), privacyFeeManager, "Privacy fee manager");
        emit ContractDeployed("PrivacyFeeManager", privacyFeeManager);
        
        return (core, config, privacyFeeManager);
    }
    
    /**
     * @dev Deploy financial contracts
     */
    function deployFinancialContracts(
        address admin
    ) public returns (
        address escrow,
        address payment,
        address staking
    ) {
        address privacyFeeManager = registry.getContract(registry.FEE_MANAGER());
        address token = registry.getContract(registry.OMNICOIN_CORE());
        address config = registry.getContract(registry.OMNICOIN_CONFIG());
        
        // Deploy EscrowV3 with registry integration
        escrow = address(new OmniCoinEscrow(
            address(registry),
            admin
        ));
        registry.registerContract(registry.ESCROW(), escrow, "Escrow contract V3");
        emit ContractDeployed("OmniCoinEscrow", escrow);
        
        // Deploy PaymentV2  
        payment = address(new OmniCoinPayment(
            address(registry),
            token,
            address(0), // Account contract to be set
            address(0), // Staking contract to be set
            admin,
            privacyFeeManager
        ));
        registry.registerContract(registry.PAYMENT(), payment, "Payment contract V2");
        emit ContractDeployed("OmniCoinPayment", payment);
        
        // Deploy StakingV2
        staking = address(new OmniCoinStaking(
            config,
            token,
            admin,
            privacyFeeManager
        ));
        registry.registerContract(registry.STAKING(), staking, "Staking contract V2");
        emit ContractDeployed("OmniCoinStaking", staking);
        
        return (escrow, payment, staking);
    }
    
    /**
     * @dev Deploy bridge contracts
     */
    function deployBridgeContracts(
        address admin
    ) public returns (address bridge) {
        address token = registry.getContract(registry.OMNICOIN_CORE());
        address privacyFeeManager = registry.getContract(registry.FEE_MANAGER());
        
        bridge = address(new OmniCoinBridge(address(registry), token, admin, privacyFeeManager));
        registry.registerContract(registry.BRIDGE(), bridge, "Bridge contract");
        emit ContractDeployed("OmniCoinBridge", bridge);
        
        return bridge;
    }
    
    /**
     * @dev Deploy governance contracts
     */
    function deployGovernanceContracts(
        address admin
    ) public returns (address arbitration) {
        // Note: This is a simplified deployment
        // In production, these contracts would be properly initialized
        
        arbitration = address(new OmniCoinArbitration());
        registry.registerContract(registry.ARBITRATION(), arbitration, "Arbitration contract");
        emit ContractDeployed("OmniCoinArbitration", arbitration);
        
        return arbitration;
    }
    
    /**
     * @dev Complete deployment by setting up cross-contract references
     */
    function finalizeDeployment() public {
        // This would set up any remaining cross-contract references
        // that couldn't be done during initial deployment
        
        emit DeploymentComplete(block.timestamp);
    }
    
    /**
     * @dev Deploy DEX contracts
     */
    function deployDEXContracts(
        address admin,
        address companyTreasury,
        address developmentFund
    ) public returns (address dexSettlement) {
        address privacyFeeManager = registry.getContract(registry.FEE_MANAGER());
        
        dexSettlement = address(new DEXSettlement(
            address(registry),
            companyTreasury,
            developmentFund,
            privacyFeeManager
        ));
        registry.registerContract(registry.DEX_SETTLEMENT(), dexSettlement, "DEX Settlement V2");
        emit ContractDeployed("DEXSettlement", dexSettlement);
        
        return dexSettlement;
    }
    
    /**
     * @dev Deploy NFT marketplace contracts
     */
    function deployNFTMarketplace(
        address admin,
        address listingNFT,
        uint256 platformFee,
        address feeRecipient
    ) external returns (address marketplace) {
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
        
        registry.registerContract(registry.NFT_MARKETPLACE(), marketplace, "NFT Marketplace V2");
        emit ContractDeployed("OmniNFTMarketplace", marketplace);
        
        return marketplace;
    }
    
    /**
     * @dev Deploy a full ecosystem (convenience function)
     */
    function deployFullEcosystem(
        address admin,
        address cotiToken,
        uint256 minimumValidators,
        address companyTreasury,
        address developmentFund
    ) external {
        // Deploy in stages
        deployCoreContracts(admin, cotiToken, minimumValidators);
        deployFinancialContracts(admin);
        deployBridgeContracts(admin);
        deployGovernanceContracts(admin);
        deployDEXContracts(admin, companyTreasury, developmentFund);
        finalizeDeployment();
    }
}