// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoinStaking.sol";
import "./OmniCoinValidator.sol";
import "./OmniCoinGovernor.sol";

contract OmniCoinDefiFactory is Ownable, ReentrancyGuard {
    struct DefiDeployment {
        address staking;
        address validator;
        address governor;
        uint256 timestamp;
    }

    mapping(uint256 => DefiDeployment) public deployments;
    uint256 public deploymentCount;

    event DefiDeployed(
        uint256 indexed deploymentId,
        address indexed staking,
        address indexed validator,
        address governor
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deployDefiComponents(
        address tokenOwner,
        address configAddress,
        address tokenAddress
    )
        external
        nonReentrant
        returns (
            uint256 deploymentId,
            address staking,
            address validator,
            address governor
        )
    {
        deploymentId = deploymentCount++;

        // Deploy DeFi components
        OmniCoinStaking stakingContract = new OmniCoinStaking(
            configAddress,
            tokenOwner
        );
        OmniCoinValidator validatorContract = new OmniCoinValidator(
            configAddress,
            tokenOwner
        );
        OmniCoinGovernor governorContract = new OmniCoinGovernor(
            tokenAddress,
            tokenOwner
        );

        // Store deployment
        deployments[deploymentId] = DefiDeployment({
            staking: address(stakingContract),
            validator: address(validatorContract),
            governor: address(governorContract),
            timestamp: block.timestamp
        });

        emit DefiDeployed(
            deploymentId,
            address(stakingContract),
            address(validatorContract),
            address(governorContract)
        );

        return (
            deploymentId,
            address(stakingContract),
            address(validatorContract),
            address(governorContract)
        );
    }

    function transferOwnership(
        uint256 deploymentId,
        address newOwner
    ) external onlyOwner {
        DefiDeployment storage deployment = deployments[deploymentId];
        require(deployment.staking != address(0), "Deployment not found");

        OmniCoinStaking(deployment.staking).transferOwnership(newOwner);
        OmniCoinValidator(deployment.validator).transferOwnership(newOwner);
        OmniCoinGovernor(deployment.governor).transferOwnership(newOwner);
    }

    function getDeployment(
        uint256 _deploymentId
    )
        external
        view
        returns (
            address staking,
            address validator,
            address governor,
            uint256 timestamp
        )
    {
        DefiDeployment storage deployment = deployments[_deploymentId];
        return (
            deployment.staking,
            deployment.validator,
            deployment.governor,
            deployment.timestamp
        );
    }
}
