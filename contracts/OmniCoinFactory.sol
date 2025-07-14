// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoin.sol";
import "./OmniCoinConfig.sol";
import "./OmniCoinReputation.sol";
import "./OmniCoinStaking.sol";
import "./OmniCoinValidator.sol";
import "./OmniCoinMultisig.sol";
import "./OmniCoinPrivacy.sol";
import "./OmniCoinGarbledCircuit.sol";
import "./OmniCoinGovernor.sol";
import "./OmniCoinEscrow.sol";
import "./OmniCoinBridge.sol";

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

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deployOmniCoin() external nonReentrant returns (uint256) {
        uint256 deploymentId = deploymentCount++;

        // Deploy components
        OmniCoinConfig config = new OmniCoinConfig(msg.sender);
        OmniCoinReputation reputation = new OmniCoinReputation(address(config));
        OmniCoinStaking staking = new OmniCoinStaking(address(config));
        OmniCoinValidator validator = new OmniCoinValidator(address(config));
        OmniCoinMultisig multisig = new OmniCoinMultisig(msg.sender);
        OmniCoinPrivacy privacy = new OmniCoinPrivacy(address(this));
        OmniCoinGarbledCircuit garbledCircuit = new OmniCoinGarbledCircuit(
            msg.sender
        );
        OmniCoinGovernor governor = new OmniCoinGovernor(address(this));
        OmniCoinEscrow escrow = new OmniCoinEscrow(address(this));
        OmniCoinBridge bridge = new OmniCoinBridge(address(this));

        // Deploy main token
        OmniCoin token = new OmniCoin(
            address(config),
            address(reputation),
            address(staking),
            address(validator),
            address(multisig),
            address(privacy),
            address(garbledCircuit),
            address(governor),
            address(escrow),
            address(bridge)
        );

        // Store deployment
        deployments[deploymentId] = Deployment({
            config: address(config),
            reputation: address(reputation),
            staking: address(staking),
            validator: address(validator),
            multisig: address(multisig),
            privacy: address(privacy),
            garbledCircuit: address(garbledCircuit),
            governor: address(governor),
            escrow: address(escrow),
            bridge: address(bridge),
            token: address(token),
            timestamp: block.timestamp
        });

        // Initialize systems
        config.transferOwnership(address(token));
        reputation.transferOwnership(address(token));
        staking.transferOwnership(address(token));
        validator.transferOwnership(address(token));
        multisig.transferOwnership(address(token));
        privacy.transferOwnership(address(token));
        garbledCircuit.transferOwnership(address(token));
        governor.transferOwnership(address(token));
        escrow.transferOwnership(address(token));
        bridge.transferOwnership(address(token));

        // Mint initial supply
        token.mint(msg.sender, 1000000 * 10 ** 6); // 1M tokens

        emit OmniCoinDeployed(
            deploymentId,
            address(token),
            address(config),
            address(reputation),
            address(staking),
            address(validator),
            address(multisig),
            address(privacy),
            address(garbledCircuit),
            address(governor),
            address(escrow),
            address(bridge)
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
