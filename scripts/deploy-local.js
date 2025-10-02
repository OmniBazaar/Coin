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
    const escrow = await MinimalEscrow.deploy(omniCoinAddress, deployer.address);
    await escrow.waitForDeployment();
    const escrowAddress = await escrow.getAddress();
    console.log("MinimalEscrow deployed to:", escrowAddress);

    // Deploy MockWarpMessenger for local testing
    console.log("\n=== Deploying MockWarpMessenger ===");
    const MockWarpMessenger = await ethers.getContractFactory("MockWarpMessenger");
    const warpMessenger = await MockWarpMessenger.deploy();
    await warpMessenger.waitForDeployment();
    const warpMessengerAddress = await warpMessenger.getAddress();
    console.log("MockWarpMessenger deployed to:", warpMessengerAddress);

    // Deploy OmniBridge
    console.log("\n=== Deploying OmniBridge ===");
    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    const bridge = await OmniBridge.deploy(
        omniCoinAddress,
        privateOmniCoinAddress,
        warpMessengerAddress
    );
    await bridge.waitForDeployment();
    const bridgeAddress = await bridge.getAddress();
    console.log("OmniBridge deployed to:", bridgeAddress);

    // Deploy OmniCore (upgradeable with UUPS)
    console.log("\n=== Deploying OmniCore (Upgradeable) ===");
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const omniCore = await upgrades.deployProxy(
        OmniCore,
        [omniCoinAddress, escrowAddress],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await omniCore.waitForDeployment();
    const omniCoreAddress = await omniCore.getAddress();
    console.log("OmniCore deployed to:", omniCoreAddress);

    // Deploy OmniGovernance (needs OmniCore address)
    console.log("\n=== Deploying OmniGovernance ===");
    const OmniGovernance = await ethers.getContractFactory("OmniGovernance");
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
            OmniGovernance: governanceAddress,
            MockWarpMessenger: warpMessengerAddress,
            OmniBridge: bridgeAddress,
            OmniCore: omniCoreAddress
        }
    };

    const deploymentsPath = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsPath)) {
        fs.mkdirSync(deploymentsPath, { recursive: true });
    }

    const deploymentFile = path.join(deploymentsPath, "localhost.json");
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\n✅ Deployment addresses saved to:", deploymentFile);

    // Initialize contracts
    console.log("\n=== Initializing Contracts ===");

    // Grant minter role to bridge in both tokens
    const MINTER_ROLE = await omniCoin.MINTER_ROLE();
    await omniCoin.grantRole(MINTER_ROLE, bridgeAddress);
    console.log("✓ Granted MINTER_ROLE to bridge in OmniCoin");

    await privateOmniCoin.grantRole(MINTER_ROLE, bridgeAddress);
    console.log("✓ Granted MINTER_ROLE to bridge in PrivateOmniCoin");

    // Grant burner role to bridge in both tokens
    const BURNER_ROLE = await omniCoin.BURNER_ROLE();
    await omniCoin.grantRole(BURNER_ROLE, bridgeAddress);
    console.log("✓ Granted BURNER_ROLE to bridge in OmniCoin");

    await privateOmniCoin.grantRole(BURNER_ROLE, bridgeAddress);
    console.log("✓ Granted BURNER_ROLE to bridge in PrivateOmniCoin");

    // Mint initial supply to deployer for testing
    const initialSupply = ethers.parseEther("1000000"); // 1M XOM
    await omniCoin.mint(deployer.address, initialSupply);
    console.log("✓ Minted", ethers.formatEther(initialSupply), "XOM to deployer");

    console.log("\n🎉 Local deployment complete!");
    console.log("\nYou can interact with the contracts using:");
    console.log("- OmniCoin:", omniCoinAddress);
    console.log("- PrivateOmniCoin:", privateOmniCoinAddress);
    console.log("- OmniBridge:", bridgeAddress);
    console.log("- MinimalEscrow:", escrowAddress);
    console.log("- OmniGovernance:", governanceAddress);
    console.log("- OmniCore:", omniCoreAddress);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });