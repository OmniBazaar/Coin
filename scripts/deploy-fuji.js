const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys OmniCoin contracts to Fuji Subnet-EVM blockchain
 * Network: omnicoinFuji
 * Chain ID: 131313
 * RPC: http://127.0.0.1:44969/ext/bc/wFWtK4stScGVipRgh9em1aqY7TZ94rRBdV95BbGkjQFwh6wCS/rpc
 */
async function main() {
    console.log("🚀 Starting OmniCoin Fuji Subnet Deployment\n");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deployer address:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer balance:", ethers.formatEther(balance), "tokens\n");

    // Verify we're on the right network
    const network = await ethers.provider.getNetwork();
    console.log("Network:", network.name);
    console.log("Chain ID:", network.chainId.toString());

    if (network.chainId !== 131313n) {
        throw new Error("Not connected to OmniCoin Fuji Subnet (expected chainId 131313)");
    }
    console.log("✓ Connected to OmniCoin Fuji Subnet\n");

    // Deploy OmniCoin
    console.log("=== Deploying OmniCoin ===");
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy();
    await omniCoin.waitForDeployment();
    const omniCoinAddress = await omniCoin.getAddress();
    console.log("OmniCoin deployed to:", omniCoinAddress);

    // Initialize OmniCoin (grants roles and mints initial supply)
    console.log("Initializing OmniCoin...");
    const initTx = await omniCoin.initialize();
    await initTx.wait();
    console.log("OmniCoin initialized");

    // Deploy PrivateOmniCoin (pXOM)
    console.log("\n=== Deploying PrivateOmniCoin ===");
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const privateOmniCoin = await PrivateOmniCoin.deploy();
    await privateOmniCoin.waitForDeployment();
    const privateOmniCoinAddress = await privateOmniCoin.getAddress();
    console.log("PrivateOmniCoin deployed to:", privateOmniCoinAddress);

    // Initialize PrivateOmniCoin
    console.log("Initializing PrivateOmniCoin...");
    const initPxomTx = await privateOmniCoin.initialize();
    await initPxomTx.wait();
    console.log("PrivateOmniCoin initialized");

    // Deploy MinimalEscrow
    console.log("\n=== Deploying MinimalEscrow ===");
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    // For Fuji testing, we'll use the deployer as the registry
    const escrow = await MinimalEscrow.deploy(omniCoinAddress, deployer.address);
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

    // Skip OmniBridge deployment for now (requires Avalanche Warp precompile on mainnet)
    console.log("\n⏭️  Skipping OmniBridge (requires Avalanche Warp precompile on Fuji testnet)");

    // Deploy OmniGovernance (needs OmniCore address)
    console.log("\n=== Deploying OmniGovernance ===");
    const OmniGovernance = await ethers.getContractFactory("OmniGovernance");
    const governance = await OmniGovernance.deploy(omniCoreAddress);
    await governance.waitForDeployment();
    const governanceAddress = await governance.getAddress();
    console.log("OmniGovernance deployed to:", governanceAddress);

    // Save deployment addresses
    const deployments = {
        network: "omnicoinFuji",
        chainId: 131313,
        blockchainId: "wFWtK4stScGVipRgh9em1aqY7TZ94rRBdV95BbGkjQFwh6wCS",
        subnetId: "2L5zKkWyff1UoYAhaZ59Pz8LJwXxKMvHW6giJDb1awYaH59CVu",
        rpcUrl: "http://127.0.0.1:44969/ext/bc/wFWtK4stScGVipRgh9em1aqY7TZ94rRBdV95BbGkjQFwh6wCS/rpc",
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

    const deploymentFile = path.join(deploymentsPath, "fuji.json");
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\n✅ Deployment addresses saved to:", deploymentFile);

    // Verification tests
    console.log("\n=== Running Verification Tests ===");

    // Check deployer XOM balance
    const xomBalance = await omniCoin.balanceOf(deployer.address);
    console.log("✓ Deployer XOM balance:", ethers.formatEther(xomBalance));

    // Check total supply
    const totalSupply = await omniCoin.totalSupply();
    console.log("✓ Total XOM supply:", ethers.formatEther(totalSupply));

    // Check OmniCore configuration
    const coreToken = await omniCore.OMNI_COIN();
    console.log("✓ OmniCore token address:", coreToken);
    console.log("✓ Matches OmniCoin:", coreToken === omniCoinAddress);

    console.log("\n🎉 Fuji Subnet deployment complete!");
    console.log("\n=== Deployed Contracts ===");
    console.log("OmniCoin:          ", omniCoinAddress);
    console.log("PrivateOmniCoin:   ", privateOmniCoinAddress);
    console.log("MinimalEscrow:     ", escrowAddress);
    console.log("OmniCore:          ", omniCoreAddress);
    console.log("OmniGovernance:    ", governanceAddress);

    console.log("\n=== Next Steps ===");
    console.log("1. Test contract interactions:");
    console.log("   npx hardhat console --network omnicoinFuji");
    console.log("2. Add additional validators to the subnet");
    console.log("3. Integrate TypeScript services with deployed contracts");
    console.log("4. Update Validator module configuration with these addresses");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });
