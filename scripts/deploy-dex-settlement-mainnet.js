/**
 * @file deploy-dex-settlement-mainnet.js
 * @description Deploy DEXSettlement (immutable, NOT upgradeable) on mainnet (chain 88008).
 *
 * Uses real ODDAO treasury and StakingRewardPool addresses.
 * Fee split: 70% ODDAO, 20% StakingPool, 10% Matching Validator (dynamic).
 *
 * Usage:
 *   npx hardhat run scripts/deploy-dex-settlement-mainnet.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Real ODDAO treasury address */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

async function main() {
    console.log("=== Deploy DEXSettlement (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const stakingPoolAddress = deployments.contracts.StakingRewardPool;
    if (!stakingPoolAddress) {
        throw new Error("StakingRewardPool not found in mainnet.json!");
    }

    console.log("ODDAO treasury:", ODDAO_TREASURY);
    console.log("StakingRewardPool:", stakingPoolAddress);
    console.log("Fee split: 70% ODDAO, 20% StakingPool, 10% Validator (dynamic)\n");

    // --- Deploy DEXSettlement ---
    console.log("--- Deploying DEXSettlement (Immutable) ---");
    const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
    const dexSettlement = await DEXSettlement.deploy(
        ODDAO_TREASURY,       // ODDAO (70% of fees)
        stakingPoolAddress    // Staking Pool (20% of fees)
    );
    await dexSettlement.waitForDeployment();

    const contractAddress = await dexSettlement.getAddress();
    console.log("DEXSettlement deployed:", contractAddress);

    // Verify fee recipients
    const feeRecipients = await dexSettlement.getFeeRecipients();
    console.log("\nFee Recipients Verified:");
    console.log("  ODDAO (70%):", feeRecipients.oddao);
    console.log("  Staking Pool (20%):", feeRecipients.stakingPool);
    console.log("  ODDAO matches:", feeRecipients.oddao === ODDAO_TREASURY ? "YES" : "NO");
    console.log("  StakingPool matches:", feeRecipients.stakingPool === stakingPoolAddress ? "YES" : "NO");

    if (feeRecipients.oddao !== ODDAO_TREASURY) {
        throw new Error("ODDAO address mismatch!");
    }
    if (feeRecipients.stakingPool !== stakingPoolAddress) {
        throw new Error("StakingPool address mismatch!");
    }

    // Verify trading stats
    const stats = await dexSettlement.getTradingStats();
    console.log("\nTrading Stats:");
    console.log("  Daily Volume Limit:", ethers.formatEther(stats.dailyLimit), "tokens");

    // --- Update mainnet.json ---
    deployments.contracts.DEXSettlement = contractAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `DEXSettlement deployed: ${contractAddress}. ` +
        `Immutable (not upgradeable). Fee push pattern (direct safeTransfer). ` +
        `ODDAO: ${ODDAO_TREASURY}, StakingPool: ${stakingPoolAddress}.`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== DEXSettlement Deployed ===");
    console.log("Next: Deploy OmniSwapRouter");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
