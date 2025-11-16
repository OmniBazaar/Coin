const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys OmniCoin contracts to Fuji Subnet-EVM blockchain
 * Network: omnicoinFuji
 * Chain ID: 131313
 * RPC: http://127.0.0.1:9650/ext/bc/2FYUT2FZenR4bUZUGjVaucXmQgqmDnKmrioLNdPEn7RqPwunMw/rpc
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

    // Skip PrivateOmniCoin (requires COTI MPC precompiles)
    console.log("\n⏭️  Skipping PrivateOmniCoin (requires COTI's MPC precompiles)");

    // Deploy MinimalEscrow
    console.log("\n=== Deploying MinimalEscrow ===");
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    // For Fuji testing, we'll use the deployer as the registry
    // No PrivateOmniCoin, so use zero address for second parameter
    const escrow = await MinimalEscrow.deploy(omniCoinAddress, ethers.ZeroAddress, deployer.address);
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

    // Deploy OmniGovernance (needs OmniCore address)
    console.log("\n=== Deploying OmniGovernance ===");
    const OmniGovernance = await ethers.getContractFactory("OmniGovernance");
    const governance = await OmniGovernance.deploy(omniCoreAddress);
    await governance.waitForDeployment();
    const governanceAddress = await governance.getAddress();
    console.log("OmniGovernance deployed to:", governanceAddress);

    // Deploy LegacyBalanceClaim
    console.log("\n=== Deploying LegacyBalanceClaim ===");
    const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
    const legacyClaim = await LegacyBalanceClaim.deploy(omniCoinAddress);
    await legacyClaim.waitForDeployment();
    const legacyClaimAddress = await legacyClaim.getAddress();
    console.log("LegacyBalanceClaim deployed to:", legacyClaimAddress);

    // Grant MINTER_ROLE to LegacyBalanceClaim
    console.log("Granting MINTER_ROLE to LegacyBalanceClaim...");
    const MINTER_ROLE = await omniCoin.MINTER_ROLE();
    const grantTx = await omniCoin.grantRole(MINTER_ROLE, legacyClaimAddress);
    await grantTx.wait();
    console.log("✓ MINTER_ROLE granted");

    // Deploy QualificationOracle (upgradeable with UUPS proxy)
    console.log("\n=== Deploying QualificationOracle ===");
    const QualificationOracle = await ethers.getContractFactory("QualificationOracle");
    const qualOracle = await upgrades.deployProxy(
        QualificationOracle,
        [deployer.address], // owner (will be verifier)
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await qualOracle.waitForDeployment();
    const qualOracleAddress = await qualOracle.getAddress();
    console.log("QualificationOracle proxy deployed to:", qualOracleAddress);

    const qualOracleImpl = await upgrades.erc1967.getImplementationAddress(qualOracleAddress);
    console.log("QualificationOracle implementation deployed to:", qualOracleImpl);

    // Deploy OmniValidatorManager (upgradeable with UUPS proxy)
    console.log("\n=== Deploying OmniValidatorManager ===");
    const OmniValidatorManager = await ethers.getContractFactory("OmniValidatorManager");
    const validatorMgr = await upgrades.deployProxy(
        OmniValidatorManager,
        [deployer.address, qualOracleAddress], // owner, qualification oracle
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await validatorMgr.waitForDeployment();
    const validatorMgrAddress = await validatorMgr.getAddress();
    console.log("OmniValidatorManager proxy deployed to:", validatorMgrAddress);

    const validatorMgrImpl = await upgrades.erc1967.getImplementationAddress(validatorMgrAddress);
    console.log("OmniValidatorManager implementation deployed to:", validatorMgrImpl);

    // Save deployment addresses
    // Note: blockchainId and subnetId will be updated by sync script or manually
    const deployments = {
        network: "omnicoinFuji",
        chainId: 131313,
        blockchainId: "", // To be filled from actual deployment
        subnetId: "", // To be filled from actual deployment
        rpcUrl: "", // To be filled from actual deployment
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        contracts: {
            OmniCoin: omniCoinAddress,
            MinimalEscrow: escrowAddress,
            OmniCore: omniCoreAddress,
            OmniCoreImplementation: implementationAddress,
            OmniGovernance: governanceAddress,
            LegacyBalanceClaim: legacyClaimAddress,
            QualificationOracle: qualOracleAddress,
            QualificationOracleImplementation: qualOracleImpl,
            OmniValidatorManager: validatorMgrAddress,
            OmniValidatorManagerImplementation: validatorMgrImpl
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
    console.log("OmniCoin:                ", omniCoinAddress);
    console.log("MinimalEscrow:           ", escrowAddress);
    console.log("OmniCore (Proxy):        ", omniCoreAddress);
    console.log("OmniGovernance:          ", governanceAddress);
    console.log("LegacyBalanceClaim:      ", legacyClaimAddress);
    console.log("QualificationOracle:     ", qualOracleAddress);
    console.log("OmniValidatorManager:    ", validatorMgrAddress);

    console.log("\n=== Next Steps ===");
    console.log("1. Update fuji.json with blockchain IDs (run manually)");
    console.log("2. Sync addresses: ./scripts/sync-contract-addresses.sh fuji");
    console.log("3. Add validators 2-5 sequentially using OmniValidatorManager");
    console.log("4. Monitor resource consumption after each validator addition");
    console.log("5. Run integration tests");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });
