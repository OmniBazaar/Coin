// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OmniCoinRegistry} from "../OmniCoinRegistry.sol";
import {OmniCoin} from "../OmniCoin.sol";
import {PrivateOmniCoin} from "../PrivateOmniCoin.sol";
import {OmniCoinConfig} from "../OmniCoinConfig.sol";
import {OmniCoinEscrow} from "../OmniCoinEscrow.sol";
import {UnifiedPaymentSystem} from "../UnifiedPaymentSystem.sol";
import {OmniCoinStaking} from "../OmniCoinStaking.sol";
import {UnifiedArbitrationSystem} from "../UnifiedArbitrationSystem.sol";
import {OmniCoinBridge} from "../OmniCoinBridge.sol";
import {PrivacyFeeManager} from "../PrivacyFeeManager.sol";
import {DEXSettlement} from "../DEXSettlement.sol";
import {UnifiedNFTMarketplace} from "../UnifiedNFTMarketplace.sol";

/**
 * @title DeploymentHelper
 * @author OmniCoin Development Team
 * @notice Helper contract for deploying the complete OmniCoin ecosystem with Registry pattern
 * @dev This replaces the monolithic factory approach with modular deployment.
 *      Each contract is deployed individually and registered in the registry for better
 *      modularity and upgradeability.
 */
contract DeploymentHelper {
    
    /// @notice The registry contract for registering deployed contracts
    /// @dev Immutable to ensure registry consistency across deployments
    OmniCoinRegistry public immutable REGISTRY;
    
    // Events
    /// @notice Emitted when a contract is successfully deployed and registered
    /// @param contractName The name of the deployed contract
    /// @param contractAddress The deployed contract's address
    event ContractDeployed(string contractName, address indexed contractAddress);

    /// @notice Emitted when the full ecosystem deployment is complete
    /// @param timestamp The block timestamp of deployment completion
    event DeploymentComplete(uint256 indexed timestamp);

    // Custom errors
    error InvalidRegistryAddress();
    error UnusedParameterAdmin();
    error UnusedParameterMinimumValidators();
    
    /**
     * @notice Initialize the deployment helper with a registry contract
     * @dev The registry must be deployed first before using this helper
     * @param _registry Address of the OmniCoinRegistry contract
     */
    constructor(address _registry) {
        if (_registry == address(0)) revert InvalidRegistryAddress();
        REGISTRY = OmniCoinRegistry(_registry);
    }
    
    // External functions

    /**
     * @notice Deploy NFT marketplace contracts
     * @dev Creates and initializes the unified NFT marketplace
     * @param admin The admin address (kept for interface compatibility) 
     * @param listingNFT The NFT contract address for marketplace listings
     * @param platformFee The platform fee in basis points
     * @param feeRecipient The address to receive platform fees
     * @return marketplace The deployed NFT marketplace contract address
     */
    function deployNFTMarketplace(
        address admin,
        address listingNFT,
        uint256 platformFee,
        address feeRecipient
    ) external returns (address marketplace) {
        // Note: admin parameter kept for interface compatibility
        if (admin == address(0)) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        address token = REGISTRY.getContract(REGISTRY.OMNICOIN_CORE());
        address escrow = REGISTRY.getContract(REGISTRY.ESCROW());
        address privacyFeeManager = REGISTRY.getContract(REGISTRY.FEE_MANAGER());
        
        marketplace = address(new UnifiedNFTMarketplace());
        
        // Initialize the marketplace
        UnifiedNFTMarketplace(marketplace).initialize(
            token,
            escrow,
            listingNFT,
            privacyFeeManager,
            platformFee,
            feeRecipient
        );
        
        REGISTRY.registerContract(REGISTRY.NFT_MARKETPLACE(), marketplace, "Unified NFT Marketplace V2");
        emit ContractDeployed("UnifiedNFTMarketplace", marketplace);
        
        return marketplace;
    }

    /**
     * @notice Deploy the complete OmniCoin ecosystem in one transaction
     * @dev Convenience function that deploys all contracts in the correct order
     * @param admin The admin address for all deployed contracts
     * @param cotiToken The COTI token address for treasury operations
     * @param minimumValidators Minimum number of validators (kept for compatibility)
     * @param companyTreasury The company treasury address for fees
     * @param developmentFund The development fund address
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

    // Public functions

    /**
     * @notice Deploy the core OmniCoin ecosystem contracts
     * @dev Deploys OmniCoin, PrivateOmniCoin, OmniCoinConfig, and PrivacyFeeManager
     * @param admin The admin address for deployed contracts
     * @param cotiToken The COTI token address for treasury operations
     * @param minimumValidators Minimum number of validators (currently unused but kept for interface compatibility)
     * @return core The deployed OmniCoin contract address
     * @return config The deployed OmniCoinConfig contract address
     * @return privacyFeeManager The deployed PrivacyFeeManager contract address
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
        // Note: minimumValidators parameter kept for interface compatibility
        if (minimumValidators == 0) {
            // This satisfies the unused variable warning while maintaining interface
        }
        // Deploy Config
        config = address(new OmniCoinConfig(address(REGISTRY), admin));
        REGISTRY.registerContract(REGISTRY.OMNICOIN_CONFIG(), config, "Configuration contract");
        emit ContractDeployed("OmniCoinConfig", config);
        
        // Deploy OmniCoin (public token)
        core = address(new OmniCoin(address(REGISTRY)));
        REGISTRY.registerContract(REGISTRY.OMNICOIN(), core, "OmniCoin public token");
        emit ContractDeployed("OmniCoin", core);
        
        // Deploy PrivateOmniCoin
        address privateToken = address(new PrivateOmniCoin(address(REGISTRY)));
        REGISTRY.registerContract(REGISTRY.PRIVATE_OMNICOIN(), privateToken, "PrivateOmniCoin privacy token");
        emit ContractDeployed("PrivateOmniCoin", privateToken);
        
        // Deploy PrivacyFeeManager
        privacyFeeManager = address(new PrivacyFeeManager(
            address(REGISTRY),
            cotiToken, // Using cotiToken as treasury
            admin
        ));
        REGISTRY.registerContract(REGISTRY.FEE_MANAGER(), privacyFeeManager, "Privacy fee manager");
        emit ContractDeployed("PrivacyFeeManager", privacyFeeManager);
        
        return (core, config, privacyFeeManager);
    }
    
    /**
     * @notice Deploy financial ecosystem contracts (escrow, payment, staking)
     * @dev Requires core contracts to be deployed first for proper integration
     * @param admin The admin address for deployed contracts
     * @return escrow The deployed OmniCoinEscrow contract address
     * @return payment The deployed payment system contract address
     * @return staking The deployed OmniCoinStaking contract address
     */
    function deployFinancialContracts(
        address admin
    ) public returns (
        address escrow,
        address payment,
        address staking
    ) {
        address privacyFeeManager = REGISTRY.getContract(REGISTRY.FEE_MANAGER());
        address token = REGISTRY.getContract(REGISTRY.OMNICOIN_CORE());
        address config = REGISTRY.getContract(REGISTRY.OMNICOIN_CONFIG());
        
        // Deploy EscrowV3 with registry integration
        escrow = address(new OmniCoinEscrow(
            address(REGISTRY),
            admin
        ));
        REGISTRY.registerContract(REGISTRY.ESCROW(), escrow, "Escrow contract V3");
        emit ContractDeployed("OmniCoinEscrow", escrow);
        
        // Deploy Unified Payment System
        payment = address(new UnifiedPaymentSystem(
            address(REGISTRY),
            token,
            address(0), // Account contract to be set
            address(0), // Staking contract to be set
            admin,
            privacyFeeManager
        ));
        REGISTRY.registerContract(REGISTRY.PAYMENT(), payment, "Unified Payment System V2");
        emit ContractDeployed("UnifiedPaymentSystem", payment);
        
        // Deploy StakingV2
        staking = address(new OmniCoinStaking(
            config,
            token,
            admin,
            privacyFeeManager
        ));
        REGISTRY.registerContract(REGISTRY.STAKING(), staking, "Staking contract V2");
        emit ContractDeployed("OmniCoinStaking", staking);
        
        return (escrow, payment, staking);
    }
    
    /**
     * @notice Deploy bridge contracts for cross-chain functionality
     * @dev Deploys the main OmniCoin bridge for interoperability
     * @param admin The admin address for the bridge contract
     * @return bridge The deployed OmniCoinBridge contract address
     */
    function deployBridgeContracts(
        address admin
    ) public returns (address bridge) {
        address token = REGISTRY.getContract(REGISTRY.OMNICOIN_CORE());
        address privacyFeeManager = REGISTRY.getContract(REGISTRY.FEE_MANAGER());
        
        bridge = address(new OmniCoinBridge(address(REGISTRY), token, admin, privacyFeeManager));
        REGISTRY.registerContract(REGISTRY.BRIDGE(), bridge, "Bridge contract");
        emit ContractDeployed("OmniCoinBridge", bridge);
        
        return bridge;
    }
    
    /**
     * @notice Deploy governance and arbitration contracts
     * @dev This is a simplified deployment for the arbitration system
     * @param admin The admin address (kept for interface compatibility)
     * @return arbitration The deployed arbitration contract address
     */
    function deployGovernanceContracts(
        address admin
    ) public returns (address arbitration) {
        // Note: admin parameter kept for interface compatibility
        if (admin == address(0)) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        // Note: This is a simplified deployment
        // In production, these contracts would be properly initialized
        
        arbitration = address(new UnifiedArbitrationSystem());
        REGISTRY.registerContract(REGISTRY.ARBITRATION(), arbitration, "Unified Arbitration System");
        emit ContractDeployed("UnifiedArbitrationSystem", arbitration);
        
        return arbitration;
    }
    
    /**
     * @notice Complete deployment by setting up cross-contract references
     * @dev This finalizes the deployment process and emits completion event
     */
    function finalizeDeployment() public {
        // This would set up any remaining cross-contract references
        // that couldn't be done during initial deployment
        
        emit DeploymentComplete(block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Deploy DEX (Decentralized Exchange) contracts
     * @dev Deploys the DEX settlement contract for trading functionality
     * @param admin The admin address (kept for interface compatibility)
     * @param companyTreasury The company treasury address for fees
     * @param developmentFund The development fund address
     * @return dexSettlement The deployed DEXSettlement contract address
     */
    function deployDEXContracts(
        address admin,
        address companyTreasury,
        address developmentFund
    ) public returns (address dexSettlement) {
        // Note: admin parameter kept for interface compatibility
        if (admin == address(0)) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        address privacyFeeManager = REGISTRY.getContract(REGISTRY.FEE_MANAGER());
        
        dexSettlement = address(new DEXSettlement(
            address(REGISTRY),
            companyTreasury,
            developmentFund,
            privacyFeeManager
        ));
        REGISTRY.registerContract(REGISTRY.DEX_SETTLEMENT(), dexSettlement, "DEX Settlement V2");
        emit ContractDeployed("DEXSettlement", dexSettlement);
        
        return dexSettlement;
    }
}