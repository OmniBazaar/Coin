/**
 * @file fund-legacy-claim-mainnet.js
 * @description Fund LegacyBalanceClaim with 4,130,000,000 XOM on mainnet (chain 88008).
 *
 * LegacyBalanceClaim uses transfer-based distribution (NOT mint-based).
 * It needs XOM tokens transferred to it so users can claim their legacy balances.
 *
 * After this funding + OmniRewardManager funding (12,467,457,500 XOM),
 * deployer should have 0 XOM remaining.
 *
 * Usage:
 *   npx hardhat run scripts/fund-legacy-claim-mainnet.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Legacy balance pool: 4,130,000,000 XOM */
const LEGACY_FUNDING = ethers.parseEther("4130000000");

async function main() {
    console.log("=== Fund LegacyBalanceClaim (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const omniCoinAddress = deployments.contracts.OmniCoin;
    const legacyClaimAddress = deployments.contracts.LegacyBalanceClaim;

    if (!omniCoinAddress) {
        throw new Error("OmniCoin not found in mainnet.json!");
    }
    if (!legacyClaimAddress) {
        throw new Error("LegacyBalanceClaim not found in mainnet.json!");
    }

    console.log("OmniCoin:", omniCoinAddress);
    console.log("LegacyBalanceClaim:", legacyClaimAddress);
    console.log("Funding amount:", ethers.formatEther(LEGACY_FUNDING), "XOM\n");

    // Verify OmniCoin on-chain
    const omniCoin = await ethers.getContractAt("OmniCoin", omniCoinAddress);
    const symbol = await omniCoin.symbol();
    console.log(`Token: ${symbol}`);

    // Check deployer balance
    const deployerBalance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", ethers.formatEther(deployerBalance), "XOM");

    if (deployerBalance < LEGACY_FUNDING) {
        throw new Error(
            `Insufficient XOM! Need ${ethers.formatEther(LEGACY_FUNDING)}, ` +
            `have ${ethers.formatEther(deployerBalance)}`
        );
    }

    // Check current LegacyBalanceClaim balance
    const legacyBefore = await omniCoin.balanceOf(legacyClaimAddress);
    console.log("LegacyBalanceClaim current balance:", ethers.formatEther(legacyBefore), "XOM\n");

    // --- Transfer XOM to LegacyBalanceClaim ---
    console.log("--- Transferring", ethers.formatEther(LEGACY_FUNDING), "XOM to LegacyBalanceClaim ---");
    const transferTx = await omniCoin.transfer(legacyClaimAddress, LEGACY_FUNDING);
    const receipt = await transferTx.wait();
    console.log("Transfer tx:", receipt.hash);

    // Verify balances
    const legacyAfter = await omniCoin.balanceOf(legacyClaimAddress);
    const deployerAfter = await omniCoin.balanceOf(deployer.address);

    console.log("\nLegacyBalanceClaim balance:", ethers.formatEther(legacyAfter), "XOM");
    console.log("Deployer XOM remaining:", ethers.formatEther(deployerAfter), "XOM");

    if (deployerAfter === 0n) {
        console.log("\nAll 16,600,000,000 XOM fully distributed. Deployer balance is ZERO.");
    }

    // --- Update mainnet.json ---
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `LegacyBalanceClaim funded with ${ethers.formatEther(LEGACY_FUNDING)} XOM. ` +
        `Deployer remaining: ${ethers.formatEther(deployerAfter)} XOM.`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Updated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== LegacyBalanceClaim Funded ===");
    if (deployerAfter === 0n) {
        console.log("ALL FUNDING COMPLETE. Deployer has 0 XOM.");
        console.log("Next: Revoke MINTER_ROLE from deployer on OmniCoin");
    } else {
        console.log("WARNING: Deployer still has", ethers.formatEther(deployerAfter), "XOM");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
