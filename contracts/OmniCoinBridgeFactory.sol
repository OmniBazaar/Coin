// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoinEscrow.sol";
import "./OmniCoinBridge.sol";

contract OmniCoinBridgeFactory is Ownable, ReentrancyGuard {
    struct BridgeDeployment {
        address escrow;
        address bridge;
        uint256 timestamp;
    }

    mapping(uint256 => BridgeDeployment) public deployments;
    uint256 public deploymentCount;

    event BridgeDeployed(
        uint256 indexed deploymentId,
        address indexed escrow,
        address indexed bridge
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deployBridgeComponents(
        address tokenOwner,
        address tokenAddress
    )
        external
        nonReentrant
        returns (uint256 deploymentId, address escrow, address bridge)
    {
        deploymentId = deploymentCount++;

        // Deploy bridge components
        OmniCoinEscrow escrowContract = new OmniCoinEscrow(
            tokenAddress,
            tokenOwner
        );
        OmniCoinBridge bridgeContract = new OmniCoinBridge(
            tokenAddress,
            tokenOwner
        );

        // Store deployment
        deployments[deploymentId] = BridgeDeployment({
            escrow: address(escrowContract),
            bridge: address(bridgeContract),
            timestamp: block.timestamp
        });

        emit BridgeDeployed(
            deploymentId,
            address(escrowContract),
            address(bridgeContract)
        );

        return (deploymentId, address(escrowContract), address(bridgeContract));
    }

    function transferOwnership(
        uint256 deploymentId,
        address newOwner
    ) external onlyOwner {
        BridgeDeployment storage deployment = deployments[deploymentId];
        require(deployment.escrow != address(0), "Deployment not found");

        OmniCoinEscrow(deployment.escrow).transferOwnership(newOwner);
        OmniCoinBridge(deployment.bridge).transferOwnership(newOwner);
    }

    function getDeployment(
        uint256 _deploymentId
    )
        external
        view
        returns (address escrow, address bridge, uint256 timestamp)
    {
        BridgeDeployment storage deployment = deployments[_deploymentId];
        return (deployment.escrow, deployment.bridge, deployment.timestamp);
    }
}
