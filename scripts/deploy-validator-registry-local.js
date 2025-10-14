const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploy ValidatorRegistry contract to localhost Hardhat network
 * This is for local development and testing only
 */
async function main() {
    console.log("========================================");
    console.log("ValidatorRegistry Local Deployment");
    console.log("========================================\n");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deployer address:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer balance:", ethers.formatEther(balance), "ETH\n");

    // Deploy ValidatorRegistry
    console.log("Deploying ValidatorRegistry...");
    const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
    const registry = await ValidatorRegistry.deploy();

    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();

    console.log("✅ ValidatorRegistry deployed to:", registryAddress);
    console.log("");

    // Save deployment info
    const deploymentInfo = {
        network: "localhost",
        chainId: 1337,
        address: registryAddress,
        deployer: deployer.address,
        deployedAt: new Date().toISOString()
    };

    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    const deploymentPath = path.join(deploymentsDir, "localhost-validator-registry.json");
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("Deployment info saved to:", deploymentPath);
    console.log("");
    console.log("========================================");
    console.log("Set this environment variable:");
    console.log(`export VALIDATOR_REGISTRY_ADDRESS=${registryAddress}`);
    console.log("========================================");

    return registryAddress;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });
