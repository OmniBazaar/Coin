const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys OmniCoin contracts to local hardhat network for development
 */
async function main() {
    console.log("🚀 Starting OmniCoin Local Deployment\n");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deployer address:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer balance:", ethers.formatEther(balance), "ETH\n");

    // Deploy OmniCoin
    console.log("=== Deploying OmniCoin ===");
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy();
    await omniCoin.waitForDeployment();
    const omniCoinAddress = await omniCoin.getAddress();
    console.log("OmniCoin deployed to:", omniCoinAddress);

    // Initialize OmniCoin (grants roles and mints initial supply)
    await omniCoin.initialize();
    console.log("OmniCoin initialized");

    // Deploy PrivateOmniCoin (pXOM)
    console.log("\n=== Deploying PrivateOmniCoin ===");
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const privateOmniCoin = await PrivateOmniCoin.deploy();
    await privateOmniCoin.waitForDeployment();
    const privateOmniCoinAddress = await privateOmniCoin.getAddress();
    console.log("PrivateOmniCoin deployed to:", privateOmniCoinAddress);

    // Initialize PrivateOmniCoin
    await privateOmniCoin.initialize();
    console.log("PrivateOmniCoin initialized");

    // Deploy MinimalEscrow
    console.log("\n=== Deploying MinimalEscrow ===");
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    // For local testing, we'll use the deployer as the registry
    // Args: omniCoin, privateOmniCoin, registry, feeCollector, marketplaceFeeBps (100 = 1%)
    const escrow = await MinimalEscrow.deploy(
      omniCoinAddress, omniCoinAddress, deployer.address,
      deployer.address, 100
    );
    await escrow.waitForDeployment();
    const escrowAddress = await escrow.getAddress();
    console.log("MinimalEscrow deployed to:", escrowAddress);

    // Deploy placeholder addresses for ODDAO and StakingPool
    // In production, these would be proper DAO and staking pool contracts
    const oddaoAddress = deployer.address; // Temporary: use deployer as ODDAO
    const stakingPoolAddress = deployer.address; // Temporary: use deployer as staking pool

    // Deploy OmniCore (upgradeable with UUPS proxy)
    console.log("\n=== Deploying OmniCore (Upgradeable with UUPS Proxy) ===");
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const omniCore = await upgrades.deployProxy(
        OmniCore,
        [
            deployer.address,      // admin
            omniCoinAddress,       // OmniCoin token
            oddaoAddress,          // ODDAO address (70% fees)
            stakingPoolAddress     // Staking pool address (20% fees)
        ],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await omniCore.waitForDeployment();
    const omniCoreAddress = await omniCore.getAddress();
    console.log("OmniCore proxy deployed to:", omniCoreAddress);

    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(omniCoreAddress);
    console.log("OmniCore implementation deployed to:", implementationAddress);

    // Skip OmniBridge deployment for local Hardhat (requires Avalanche Warp precompile)
    // OmniBridge constructor calls WARP_MESSENGER.getBlockchainID() which only works on Avalanche
    console.log("\n⏭️  Skipping OmniBridge (requires Avalanche Warp precompile)");

    // Deploy OmniGovernance (needs OmniCore address)
    console.log("\n=== Deploying OmniGovernance ===");
    const OmniGovernance = await ethers.getContractFactory("OmniGovernanceV1");
    const governance = await OmniGovernance.deploy(omniCoreAddress);
    await governance.waitForDeployment();
    const governanceAddress = await governance.getAddress();
    console.log("OmniGovernance deployed to:", governanceAddress);

    // Save deployment addresses
    const deployments = {
        network: "localhost",
        chainId: 1337,
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        contracts: {
            OmniCoin: omniCoinAddress,
            PrivateOmniCoin: privateOmniCoinAddress,
            MinimalEscrow: escrowAddress,
            OmniCore: omniCoreAddress,
            OmniGovernance: governanceAddress
        }
    };

    const deploymentsPath = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsPath)) {
        fs.mkdirSync(deploymentsPath, { recursive: true });
    }

    const deploymentFile = path.join(deploymentsPath, "localhost.json");
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\n✅ Deployment addresses saved to:", deploymentFile);

    // All initialization complete (OmniCoin.initialize() already granted roles and minted supply)
    console.log("\n=== Deployment Summary ===");
    const xomBalance = await omniCoin.balanceOf(deployer.address);
    console.log("✓ Deployer XOM balance:", ethers.formatEther(xomBalance));

    console.log("\n🎉 Local deployment complete!");
    console.log("\nYou can interact with the contracts using:");
    console.log("- OmniCoin:", omniCoinAddress);
    console.log("- PrivateOmniCoin:", privateOmniCoinAddress);
    console.log("- MinimalEscrow:", escrowAddress);
    console.log("- OmniCore:", omniCoreAddress);
    console.log("- OmniGovernance:", governanceAddress);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });