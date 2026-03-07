/**
 * @file deploy-mainnet-phase1b.js
 * @description Phase 1b: Deploy remaining core contracts (6-8) after Phase 1a succeeded.
 *
 * Phase 1a deployed:
 *   OmniCoin:          0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B
 *   PrivateOmniCoin:   0x6a6aBEd6D0A01E6d693266bF92651d4e2db68F17
 *   MinimalEscrow:     0x9338B9eF1291b0266D28E520797eD57020A84D3B
 *   OmniCore (Proxy):  0xfF92309d8C06B4A09F1EacECB280E5e011D5ba1e
 *   OmniGovernance:    0xe71CB04287A3Bd82cd901EA4B344fC6EA5054d25
 *
 * This script deploys:
 *   6. LegacyBalanceClaim (needs validators[] and requiredSignatures)
 *   7. QualificationOracle (UUPS proxy)
 *   8. OmniValidatorManager (UUPS proxy)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-mainnet-phase1b.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Addresses from Phase 1a deployment
const PHASE1A = {
    OmniCoin: "0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B",
    PrivateOmniCoin: "0x6a6aBEd6D0A01E6d693266bF92651d4e2db68F17",
    MinimalEscrow: "0x9338B9eF1291b0266D28E520797eD57020A84D3B",
    OmniCore: "0xfF92309d8C06B4A09F1EacECB280E5e011D5ba1e",
    OmniCoreImplementation: "0xb53d71B81B1eCdED5a36f4c2d181E88e9019973B",
    OmniGovernance: "0xe71CB04287A3Bd82cd901EA4B344fC6EA5054d25"
};

async function main() {
    console.log("=== OmniCoin Mainnet L1 — Phase 1b: Remaining Core Contracts ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }
    console.log("Chain ID: 88008\n");

    // Verify Phase 1a contracts exist
    const omniCoinCode = await ethers.provider.getCode(PHASE1A.OmniCoin);
    if (omniCoinCode === "0x") {
        throw new Error("OmniCoin not found at expected address! Phase 1a may not have been deployed.");
    }
    console.log("Phase 1a contracts verified on-chain.\n");

    const deployed = { ...PHASE1A };

    // ===== 6. Deploy LegacyBalanceClaim =====
    console.log("--- [6/8] Deploying LegacyBalanceClaim ---");
    console.log("(Transfer-based — NO MINTER_ROLE. Trustless architecture.)");

    // Constructor: (address _omniCoin, address initialOwner, address[] _validators, uint256 _requiredSignatures)
    // For Pioneer Phase: deployer is the sole validator for claim approval
    // This will be updated to real validators via governance later
    const claimValidators = [deployer.address];
    const requiredSignatures = 1;

    const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
    const legacyClaim = await LegacyBalanceClaim.deploy(
        PHASE1A.OmniCoin,      // _omniCoin
        deployer.address,       // initialOwner
        claimValidators,        // _validators (deployer only for Pioneer Phase)
        requiredSignatures      // _requiredSignatures
    );
    await legacyClaim.waitForDeployment();
    deployed.LegacyBalanceClaim = await legacyClaim.getAddress();
    console.log("LegacyBalanceClaim deployed to:", deployed.LegacyBalanceClaim);
    console.log("  Validators:", claimValidators);
    console.log("  Required signatures:", requiredSignatures);
    console.log("  NOTE: Fund with 4.13B XOM after all Phase 1 contracts deployed.\n");

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
    console.log("QualificationOracle impl:", deployed.QualificationOracleImplementation, "\n");

    // ===== 8. Deploy OmniValidatorManager (UUPS Proxy) =====
    console.log("--- [8/8] Deploying OmniValidatorManager (UUPS Proxy) ---");
    const OmniValidatorManager = await ethers.getContractFactory("OmniValidatorManager");
    const validatorMgr = await upgrades.deployProxy(
        OmniValidatorManager,
        [deployed.QualificationOracle],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await validatorMgr.waitForDeployment();
    deployed.OmniValidatorManager = await validatorMgr.getAddress();
    deployed.OmniValidatorManagerImplementation = await upgrades.erc1967.getImplementationAddress(deployed.OmniValidatorManager);
    console.log("OmniValidatorManager proxy:", deployed.OmniValidatorManager);
    console.log("OmniValidatorManager impl:", deployed.OmniValidatorManagerImplementation, "\n");

    // ===== Save complete deployment =====
    const deployments = {
        network: "mainnet",
        chainId: 88008,
        subnetId: "wyq5GmNJdVnRbhEynLqgyo2wW35UX4EPpaeWHtUpLhN4NvZmN",
        blockchainId: "2tNbY8HXgSa3qwgSkhh6XS5F7UCPPu6fP3Gv7jjeeMgNoC3ioA",
        rpcUrl: "http://65.108.205.116:9650/ext/bc/2tNbY8HXgSa3qwgSkhh6XS5F7UCPPu6fP3Gv7jjeeMgNoC3ioA/rpc",
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        phase: "Phase 1 — Core Contracts (Complete)",
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
            OmniValidatorManager: deployed.OmniValidatorManager,
            OmniValidatorManagerImplementation: deployed.OmniValidatorManagerImplementation
        }
    };

    const deploymentsPath = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsPath)) {
        fs.mkdirSync(deploymentsPath, { recursive: true });
    }
    const deploymentFile = path.join(deploymentsPath, "mainnet.json");
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Complete deployment saved to:", deploymentFile);

    // ===== Verification =====
    console.log("\n=== Verification ===");
    const omniCoin = await ethers.getContractAt("OmniCoin", deployed.OmniCoin);
    const xomBalance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM:", ethers.formatEther(xomBalance), "XOM");
    console.log("Total supply:", ethers.formatEther(await omniCoin.totalSupply()), "XOM");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    // ===== Summary =====
    console.log("\n=== Phase 1 Complete — All 8 Contracts Deployed ===");
    for (const [name, addr] of Object.entries(deployed)) {
        if (!name.includes("Implementation")) {
            console.log(`  ${name}: ${addr}`);
        }
    }

    console.log("\n=== Next: Phase 2+ ===");
    console.log("  npx hardhat run scripts/deploy-registration.ts --network mainnet");
    console.log("  npx hardhat run scripts/deploy-staking-pool.js --network mainnet");
    console.log("  npx hardhat run scripts/deploy-reward-manager.ts --network mainnet");
    console.log("  npx hardhat run scripts/deploy-dex-settlement.ts --network mainnet");
    console.log("  npx hardhat run scripts/deploy-governance-system.ts --network mainnet");
    console.log("  npx hardhat run scripts/deploy-participation.ts --network mainnet");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment FAILED:", error);
        process.exit(1);
    });
