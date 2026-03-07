/**
 * @file deploy-swap-router-mainnet.js
 * @description Deploy OmniSwapRouter (immutable, NOT upgradeable) on mainnet (chain 88008).
 *
 * Fee recipient: ODDAO treasury (protocol fees from swaps).
 * Swap fee: 30 bps (0.30%).
 *
 * Usage:
 *   npx hardhat run scripts/deploy-swap-router-mainnet.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Real ODDAO treasury address */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

/** Swap fee: 30 basis points = 0.30% */
const SWAP_FEE_BPS = 30;

async function main() {
    console.log("=== Deploy OmniSwapRouter (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    console.log("Fee Recipient (ODDAO):", ODDAO_TREASURY);
    console.log("Swap Fee:", SWAP_FEE_BPS, "bps (0.30%)\n");

    // --- Deploy OmniSwapRouter ---
    console.log("--- Deploying OmniSwapRouter (Immutable) ---");
    const OmniSwapRouter = await ethers.getContractFactory("OmniSwapRouter");
    const omniSwapRouter = await OmniSwapRouter.deploy(
        ODDAO_TREASURY,   // Fee recipient
        SWAP_FEE_BPS      // Swap fee in basis points
    );
    await omniSwapRouter.waitForDeployment();

    const contractAddress = await omniSwapRouter.getAddress();
    console.log("OmniSwapRouter deployed:", contractAddress);

    // Verify owner
    const owner = await omniSwapRouter.owner();
    console.log("Owner:", owner);
    console.log("Owner is deployer:", owner === deployer.address ? "YES" : "NO");

    // --- Update mainnet.json ---
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    deployments.contracts.OmniSwapRouter = contractAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `OmniSwapRouter deployed: ${contractAddress}. ` +
        `Immutable. Fee: ${SWAP_FEE_BPS} bps (0.30%). ` +
        `Fee recipient: ODDAO treasury (${ODDAO_TREASURY}).`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== OmniSwapRouter Deployed ===");
    console.log("Next: Fund LegacyBalanceClaim with 4,130,000,000 XOM");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
