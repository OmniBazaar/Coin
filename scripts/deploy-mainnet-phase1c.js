/**
 * @file deploy-mainnet-phase1c.js
 * @description Phase 1c: Deploy OmniValidatorManager (contract 8/8)
 *
 * The OmniValidatorManager is NOT UUPS-compatible — it uses a regular constructor.
 * Deploy as a standard contract.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-mainnet-phase1c.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const QUAL_ORACLE = "0x8d7fAf49544308B231182A1cD452F52D8B21E222";

async function main() {
    console.log("=== Phase 1c: OmniValidatorManager ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Deploy OmniValidatorManager (regular contract, not UUPS)
    console.log("--- [8/8] Deploying OmniValidatorManager ---");
    console.log("QualificationOracle:", QUAL_ORACLE);

    const OmniValidatorManager = await ethers.getContractFactory("OmniValidatorManager");
    const validatorMgr = await OmniValidatorManager.deploy(QUAL_ORACLE);
    await validatorMgr.waitForDeployment();
    const validatorMgrAddress = await validatorMgr.getAddress();
    console.log("OmniValidatorManager deployed to:", validatorMgrAddress);

    // Update mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));
    deployments.contracts.OmniValidatorManager = validatorMgrAddress;
    deployments.phase = "Phase 1 — Core Contracts (Complete)";
    deployments.deployedAt = new Date().toISOString();
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Updated mainnet.json\n");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== Phase 1 COMPLETE — All 8 Core Contracts Deployed ===");
    for (const [name, addr] of Object.entries(deployments.contracts)) {
        if (!name.includes("Implementation")) {
            console.log(`  ${name}: ${addr}`);
        }
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
