// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoinMultisig.sol";
import "./OmniCoinPrivacy.sol";
import "./OmniCoinGarbledCircuit.sol";

contract OmniCoinSecurityFactory is Ownable, ReentrancyGuard {
    struct SecurityDeployment {
        address multisig;
        address privacy;
        address garbledCircuit;
        uint256 timestamp;
    }

    mapping(uint256 => SecurityDeployment) public deployments;
    uint256 public deploymentCount;

    event SecurityDeployed(
        uint256 indexed deploymentId,
        address indexed multisig,
        address indexed privacy,
        address garbledCircuit
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deploySecurityComponents(
        address tokenOwner,
        address tokenAddress
    )
        external
        nonReentrant
        returns (
            uint256 deploymentId,
            address multisig,
            address privacy,
            address garbledCircuit
        )
    {
        deploymentId = deploymentCount++;

        // Deploy security components
        OmniCoinMultisig multisigContract = new OmniCoinMultisig(tokenOwner);
        OmniCoinPrivacy privacyContract = new OmniCoinPrivacy(
            tokenAddress,
            tokenOwner
        );
        OmniCoinGarbledCircuit garbledCircuitContract = new OmniCoinGarbledCircuit(
                tokenOwner
            );

        // Store deployment
        deployments[deploymentId] = SecurityDeployment({
            multisig: address(multisigContract),
            privacy: address(privacyContract),
            garbledCircuit: address(garbledCircuitContract),
            timestamp: block.timestamp
        });

        emit SecurityDeployed(
            deploymentId,
            address(multisigContract),
            address(privacyContract),
            address(garbledCircuitContract)
        );

        return (
            deploymentId,
            address(multisigContract),
            address(privacyContract),
            address(garbledCircuitContract)
        );
    }

    function transferOwnership(
        uint256 deploymentId,
        address newOwner
    ) external onlyOwner {
        SecurityDeployment storage deployment = deployments[deploymentId];
        require(deployment.multisig != address(0), "Deployment not found");

        OmniCoinMultisig(deployment.multisig).transferOwnership(newOwner);
        OmniCoinPrivacy(deployment.privacy).transferOwnership(newOwner);
        OmniCoinGarbledCircuit(deployment.garbledCircuit).transferOwnership(
            newOwner
        );
    }

    function getDeployment(
        uint256 _deploymentId
    )
        external
        view
        returns (
            address multisig,
            address privacy,
            address garbledCircuit,
            uint256 timestamp
        )
    {
        SecurityDeployment storage deployment = deployments[_deploymentId];
        return (
            deployment.multisig,
            deployment.privacy,
            deployment.garbledCircuit,
            deployment.timestamp
        );
    }
}
