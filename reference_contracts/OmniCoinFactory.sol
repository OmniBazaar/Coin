// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../OmniCoinCoreFactory.sol";
import "../OmniCoinSecurityFactory.sol";
import "../OmniCoinDefiFactory.sol";
import "../OmniCoinBridgeFactory.sol";

/**
 * @title OmniCoinFactory
 * @dev Master coordinator factory that orchestrates deployment across specialized factories
 * This approach resolves the EIP-170 contract size limit by splitting deployment logic
 */
contract OmniCoinFactory is Ownable, ReentrancyGuard {
    struct Deployment {
        address config;
        address reputation;
        address staking;
        address validator;
        address multisig;
        address privacy;
        address garbledCircuit;
        address governor;
        address escrow;
        address bridge;
        address token;
        uint256 timestamp;
    }

    // Factory contracts
    OmniCoinCoreFactory public coreFactory;
    OmniCoinSecurityFactory public securityFactory;
    OmniCoinDefiFactory public defiFactory;
    OmniCoinBridgeFactory public bridgeFactory;

    mapping(uint256 => Deployment) public deployments;
    uint256 public deploymentCount;

    event OmniCoinDeployed(
        uint256 indexed deploymentId,
        address indexed token,
        address config,
        address reputation,
        address staking,
        address validator,
        address multisig,
        address privacy,
        address garbledCircuit,
        address governor,
        address escrow,
        address bridge
    );

    event FactoriesInitialized(
        address coreFactory,
        address securityFactory,
        address defiFactory,
        address bridgeFactory
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @dev Initialize specialized factory contracts
     * Must be called before deployments can begin
     */
    function initializeFactories(
        address _coreFactory,
        address _securityFactory,
        address _defiFactory,
        address _bridgeFactory
    ) external onlyOwner {
        require(
            address(coreFactory) == address(0),
            "Factories already initialized"
        );

        coreFactory = OmniCoinCoreFactory(_coreFactory);
        securityFactory = OmniCoinSecurityFactory(_securityFactory);
        defiFactory = OmniCoinDefiFactory(_defiFactory);
        bridgeFactory = OmniCoinBridgeFactory(_bridgeFactory);

        emit FactoriesInitialized(
            _coreFactory,
            _securityFactory,
            _defiFactory,
            _bridgeFactory
        );
    }

    /**
     * @dev Deploy complete OmniCoin ecosystem using specialized factories
     */
    function deployOmniCoin() external nonReentrant returns (uint256) {
        require(
            address(coreFactory) != address(0),
            "Factories not initialized"
        );

        uint256 deploymentId = deploymentCount++;

        // Step 1: Deploy security components first (privacy needs token address)
        (, address multisig, address privacy, address garbledCircuit) = securityFactory
            .deploySecurityComponents(
                msg.sender,
                address(0) // Will be updated after token deployment
            );

        // Step 2: Deploy DeFi components
        (, address staking, address validator, address governor) = defiFactory
            .deployDefiComponents(
                msg.sender,
                address(0), // Will be updated after config deployment
                address(0) // Will be updated after token deployment
            );

        // Step 3: Deploy bridge components
        (, address escrow, address bridge) = bridgeFactory
            .deployBridgeComponents(
                msg.sender,
                address(0), // Will be updated after token deployment
                address(0)  // Privacy fee manager will be set later
            );

        // Step 4: Deploy core components (includes token)
        address[8] memory components = [
            staking,
            validator,
            multisig,
            privacy,
            garbledCircuit,
            governor,
            escrow,
            bridge
        ];
        (, address config, address reputation, address token) = coreFactory
            .deployCoreComponents(msg.sender, components);

        // Step 5: Store deployment
        deployments[deploymentId] = Deployment({
            config: config,
            reputation: reputation,
            staking: staking,
            validator: validator,
            multisig: multisig,
            privacy: privacy,
            garbledCircuit: garbledCircuit,
            governor: governor,
            escrow: escrow,
            bridge: bridge,
            token: token,
            timestamp: block.timestamp
        });

        // Step 6: Transfer ownership to token contract
        securityFactory.transferOwnership(0, token);
        defiFactory.transferOwnership(0, token);
        bridgeFactory.transferOwnership(0, token);

        emit OmniCoinDeployed(
            deploymentId,
            token,
            config,
            reputation,
            staking,
            validator,
            multisig,
            privacy,
            garbledCircuit,
            governor,
            escrow,
            bridge
        );

        return deploymentId;
    }

    function getDeployment(
        uint256 _deploymentId
    )
        external
        view
        returns (
            address config,
            address reputation,
            address staking,
            address validator,
            address multisig,
            address privacy,
            address garbledCircuit,
            address governor,
            address escrow,
            address bridge,
            address token,
            uint256 timestamp
        )
    {
        Deployment storage deployment = deployments[_deploymentId];
        return (
            deployment.config,
            deployment.reputation,
            deployment.staking,
            deployment.validator,
            deployment.multisig,
            deployment.privacy,
            deployment.garbledCircuit,
            deployment.governor,
            deployment.escrow,
            deployment.bridge,
            deployment.token,
            deployment.timestamp
        );
    }
}
