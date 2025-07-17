// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoin.sol";
import "./OmniCoinConfig.sol";
import "./OmniCoinReputation.sol";

contract OmniCoinCoreFactory is Ownable, ReentrancyGuard {
    struct CoreDeployment {
        address config;
        address reputation;
        address token;
        uint256 timestamp;
    }

    mapping(uint256 => CoreDeployment) public deployments;
    uint256 public deploymentCount;

    event CoreDeployed(
        uint256 indexed deploymentId,
        address indexed config,
        address indexed reputation,
        address token
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deployCoreComponents(
        address tokenOwner,
        address[8] calldata components // [staking, validator, multisig, privacy, garbledCircuit, governor, escrow, bridge]
    )
        external
        nonReentrant
        returns (
            uint256 deploymentId,
            address config,
            address reputation,
            address token
        )
    {
        deploymentId = deploymentCount++;

        // Deploy core components
        config = address(new OmniCoinConfig(tokenOwner));
        reputation = address(new OmniCoinReputation(config, tokenOwner));

        // Deploy main token
        token = address(
            new OmniCoin(
                tokenOwner,
                config,
                reputation,
                components[0], // staking
                components[1], // validator
                components[2], // multisig
                components[3], // privacy
                components[4], // garbledCircuit
                components[5], // governor
                components[6], // escrow
                components[7] // bridge
            )
        );

        // Store deployment
        deployments[deploymentId] = CoreDeployment({
            config: config,
            reputation: reputation,
            token: token,
            timestamp: block.timestamp
        });

        // Transfer ownership to token contract
        OmniCoinConfig(config).transferOwnership(token);
        OmniCoinReputation(reputation).transferOwnership(token);

        // Mint initial supply
        OmniCoin(token).mint(tokenOwner, 1000000 * 10 ** 6); // 1M tokens

        emit CoreDeployed(deploymentId, config, reputation, token);

        return (deploymentId, config, reputation, token);
    }

    function getDeployment(
        uint256 _deploymentId
    )
        external
        view
        returns (
            address config,
            address reputation,
            address token,
            uint256 timestamp
        )
    {
        CoreDeployment storage deployment = deployments[_deploymentId];
        return (
            deployment.config,
            deployment.reputation,
            deployment.token,
            deployment.timestamp
        );
    }
}
