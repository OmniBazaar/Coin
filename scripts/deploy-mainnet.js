/**
 * @file deploy-mainnet.js
 * @description Phase 1: Core contract deployment to OmniCoin L1 Mainnet (chain 88008)
 *
 * Deploys:
 *   1. OmniCoin (XOM token) — initialize() mints 16.6B XOM to deployer
 *   2. PrivateOmniCoin (pXOM) — deployed but NOT initialized (requires COTI MPC)
 *   3. MinimalEscrow — marketplace escrow
 *   4. OmniCore (UUPS proxy) — validator registry, staking, rewards
 *   5. OmniGovernance V1 — governance proposals
 *   6. LegacyBalanceClaim — legacy V1 user balance claims (transfer-based, NOT mint-based)
 *   7. QualificationOracle (UUPS proxy) — validator qualification
 *   8. OmniValidatorManager (UUPS proxy) — validator management
 *
 * Usage:
 *   npx hardhat run scripts/deploy-mainnet.js --network mainnet
 *
 * Prerequisites:
 *   - MAINNET_DEPLOYER_PRIVATE_KEY set in .env (with 0x prefix)
 *   - Deployer has native tokens for gas on the L1
 *   - All 5 avalanchego validators healthy
 *
 * Post-Deployment (separate steps):
 *   - Deploy Phase 2-7 contracts (Registration, Staking, DEX, Governance V2, RWA, Participation)
 *   - Fund LegacyBalanceClaim with 4.13B XOM
 *   - Fund OmniRewardManager pools with 12.47B XOM
 *   - Revoke MINTER_ROLE from deployer
 *   - Sync addresses: ./scripts/sync-contract-addresses.sh mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("=== OmniCoin Mainnet L1 Deployment — Phase 1: Core Contracts ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer address:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance:", ethers.formatEther(balance), "tokens");

    // Verify correct network
    const network = await ethers.provider.getNetwork();
    console.log("Network chain ID:", network.chainId.toString());

    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected chain 88008, got ${network.chainId}. Use --network mainnet`);
    }
    console.log("Connected to OmniCoin L1 Mainnet (chain 88008)\n");

    const deployed = {};
    let txCount = 0;

    // ===== 1. Deploy OmniCoin =====
    console.log("--- [1/8] Deploying OmniCoin ---");
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy();
    await omniCoin.waitForDeployment();
    deployed.OmniCoin = await omniCoin.getAddress();
    console.log("OmniCoin deployed to:", deployed.OmniCoin);
    txCount++;

    // Initialize OmniCoin — mints 16.6B XOM to deployer
    console.log("Initializing OmniCoin (minting 16.6B XOM to deployer)...");
    const initTx = await omniCoin.initialize();
    await initTx.wait();
    txCount++;

    const totalSupply = await omniCoin.totalSupply();
    console.log("Total supply:", ethers.formatEther(totalSupply), "XOM");
    const deployerXOM = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", ethers.formatEther(deployerXOM), "XOM\n");

    // ===== 2. Deploy PrivateOmniCoin =====
    console.log("--- [2/8] Deploying PrivateOmniCoin ---");
    console.log("(Not initialized — requires COTI MPC precompiles)");
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const privateOmniCoin = await PrivateOmniCoin.deploy();
    await privateOmniCoin.waitForDeployment();
    deployed.PrivateOmniCoin = await privateOmniCoin.getAddress();
    console.log("PrivateOmniCoin deployed to:", deployed.PrivateOmniCoin, "\n");
    txCount++;

    // ===== 3. Deploy MinimalEscrow =====
    console.log("--- [3/8] Deploying MinimalEscrow ---");
    // For Pioneer Phase: deployer is temporary registry and fee collector
    // Will be updated to proper ODDAO/governance addresses later
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    const escrow = await MinimalEscrow.deploy(
        deployed.OmniCoin,         // omniCoin
        deployed.PrivateOmniCoin,  // privateOmniCoin
        deployer.address,          // registry (temporary: deployer)
        deployer.address,          // feeCollector (temporary: deployer)
        100                        // marketplaceFeeBps (100 = 1%)
    );
    await escrow.waitForDeployment();
    deployed.MinimalEscrow = await escrow.getAddress();
    console.log("MinimalEscrow deployed to:", deployed.MinimalEscrow, "\n");
    txCount++;

    // ===== 4. Deploy OmniCore (UUPS Proxy) =====
    console.log("--- [4/8] Deploying OmniCore (UUPS Proxy) ---");
    // For Pioneer Phase: deployer is temporary ODDAO and staking pool
    const oddaoAddress = deployer.address;
    const stakingPoolAddress = deployer.address;

    const OmniCore = await ethers.getContractFactory("OmniCore");
    const omniCore = await upgrades.deployProxy(
        OmniCore,
        [
            deployer.address,   // admin
            deployed.OmniCoin,  // OmniCoin token
            oddaoAddress,       // ODDAO address (70% fees) — temporary
            stakingPoolAddress  // Staking pool (20% fees) — temporary
        ],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await omniCore.waitForDeployment();
    deployed.OmniCore = await omniCore.getAddress();
    deployed.OmniCoreImplementation = await upgrades.erc1967.getImplementationAddress(deployed.OmniCore);
    console.log("OmniCore proxy:", deployed.OmniCore);
    console.log("OmniCore implementation:", deployed.OmniCoreImplementation, "\n");
    txCount += 3; // proxy deploy + impl deploy + init tx

    // ===== 5. Deploy OmniGovernance V1 =====
    console.log("--- [5/8] Deploying OmniGovernance ---");
    const OmniGovernance = await ethers.getContractFactory("OmniGovernanceV1");
    const governance = await OmniGovernance.deploy(deployed.OmniCore);
    await governance.waitForDeployment();
    deployed.OmniGovernance = await governance.getAddress();
    console.log("OmniGovernance deployed to:", deployed.OmniGovernance, "\n");
    txCount++;

    // ===== 6. Deploy LegacyBalanceClaim =====
    console.log("--- [6/8] Deploying LegacyBalanceClaim ---");
    console.log("(Transfer-based — NO MINTER_ROLE grant. Trustless architecture.)");
    const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
    const legacyClaim = await LegacyBalanceClaim.deploy(deployed.OmniCoin, deployer.address);
    await legacyClaim.waitForDeployment();
    deployed.LegacyBalanceClaim = await legacyClaim.getAddress();
    console.log("LegacyBalanceClaim deployed to:", deployed.LegacyBalanceClaim);
    console.log("NOTE: Fund with 4.13B XOM AFTER all contracts deployed.\n");
    txCount++;

    // ===== 7. Deploy QualificationOracle (UUPS Proxy) =====
    console.log("--- [7/8] Deploying QualificationOracle (UUPS Proxy) ---");
    const QualificationOracle = await ethers.getContractFactory("QualificationOracle");
    const qualOracle = await upgrades.deployProxy(
        QualificationOracle,
        [deployer.address],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await qualOracle.waitForDeployment();
    deployed.QualificationOracle = await qualOracle.getAddress();
    deployed.QualificationOracleImplementation = await upgrades.erc1967.getImplementationAddress(deployed.QualificationOracle);
    console.log("QualificationOracle proxy:", deployed.QualificationOracle);
    console.log("QualificationOracle implementation:", deployed.QualificationOracleImplementation, "\n");
    txCount += 3;

    // NOTE: OmniValidatorManager is DEPRECATED — Avalanche's built-in PoA
    // ValidatorManager precompile at 0x0FEEDC0DE handles validator management.
    // Do NOT deploy OmniValidatorManager.

    // ===== Save deployment addresses =====
    const deployments = {
        network: "mainnet",
        chainId: 88008,
        subnetId: "wyq5GmNJdVnRbhEynLqgyo2wW35UX4EPpaeWHtUpLhN4NvZmN",
        blockchainId: "2tNbY8HXgSa3qwgSkhh6XS5F7UCPPu6fP3Gv7jjeeMgNoC3ioA",
        rpcUrl: "http://65.108.205.116:9650/ext/bc/2tNbY8HXgSa3qwgSkhh6XS5F7UCPPu6fP3Gv7jjeeMgNoC3ioA/rpc",
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        phase: "Phase 1 — Core Contracts",
        contracts: {
            OmniCoin: deployed.OmniCoin,
            PrivateOmniCoin: deployed.PrivateOmniCoin,
            MinimalEscrow: deployed.MinimalEscrow,
            OmniCore: deployed.OmniCore,
            OmniCoreImplementation: deployed.OmniCoreImplementation,
            OmniGovernance: deployed.OmniGovernance,
            LegacyBalanceClaim: deployed.LegacyBalanceClaim,
            QualificationOracle: deployed.QualificationOracle,
            QualificationOracleImplementation: deployed.QualificationOracleImplementation,
            // OmniValidatorManager: DEPRECATED — using Avalanche precompile
        }
    };

    const deploymentsPath = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsPath)) {
        fs.mkdirSync(deploymentsPath, { recursive: true });
    }
    const deploymentFile = path.join(deploymentsPath, "mainnet.json");
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Deployment addresses saved to:", deploymentFile);

    // ===== Verification =====
    console.log("\n=== Verification ===");
    const xomBalance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", ethers.formatEther(xomBalance), "XOM");

    const supply = await omniCoin.totalSupply();
    console.log("Total XOM supply:", ethers.formatEther(supply), "XOM");

    const coreToken = await omniCore.OMNI_COIN();
    console.log("OmniCore references OmniCoin:", coreToken === deployed.OmniCoin ? "YES" : "NO");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block number:", blockNum);
    console.log("Total transactions:", txCount);

    // ===== Summary =====
    console.log("\n=== Phase 1 Deployment Complete ===");
    console.log("OmniCoin:              ", deployed.OmniCoin);
    console.log("PrivateOmniCoin:       ", deployed.PrivateOmniCoin, "(not initialized)");
    console.log("MinimalEscrow:         ", deployed.MinimalEscrow);
    console.log("OmniCore (Proxy):      ", deployed.OmniCore);
    console.log("OmniGovernance:        ", deployed.OmniGovernance);
    console.log("LegacyBalanceClaim:    ", deployed.LegacyBalanceClaim);
    console.log("QualificationOracle:   ", deployed.QualificationOracle);
    console.log("OmniValidatorManager:  ", deployed.OmniValidatorManager);

    console.log("\n=== Next Steps ===");
    console.log("Phase 2: npx hardhat run scripts/deploy-registration.ts --network mainnet");
    console.log("Phase 3: npx hardhat run scripts/deploy-staking-pool.js --network mainnet");
    console.log("Phase 3: npx hardhat run scripts/deploy-validator-rewards.ts --network mainnet");
    console.log("Phase 3: npx hardhat run scripts/deploy-reward-manager.ts --network mainnet");
    console.log("Phase 4: npx hardhat run scripts/deploy-dex-settlement.ts --network mainnet");
    console.log("Phase 4: npx hardhat run scripts/deploy-omni-swap-router.ts --network mainnet");
    console.log("Phase 5: npx hardhat run scripts/deploy-governance-system.ts --network mainnet");
    console.log("Phase 7: npx hardhat run scripts/deploy-participation.ts --network mainnet");
    console.log("\nAfter all phases:");
    console.log("  1. Fund LegacyBalanceClaim with 4,130,000,000 XOM");
    console.log("  2. Fund OmniRewardManager pools with 12,467,457,500 XOM");
    console.log("  3. Revoke MINTER_ROLE from deployer");
    console.log("  4. ./scripts/sync-contract-addresses.sh mainnet");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment FAILED:", error);
        process.exit(1);
    });
