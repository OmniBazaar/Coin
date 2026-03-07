/**
 * @file deploy-validator-rewards-mainnet.js
 * @description Deploy OmniValidatorRewards (UUPS proxy) on mainnet (chain 88008).
 *
 * Requires OmniCoin, OmniParticipation, and OmniCore to be already deployed.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-validator-rewards-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("=== Deploy OmniValidatorRewards (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const xomTokenAddress = deployments.contracts.OmniCoin;
    const participationAddress = deployments.contracts.OmniParticipation;
    const omniCoreAddress = deployments.contracts.OmniCore;

    if (!xomTokenAddress) {
        throw new Error("OmniCoin not found in mainnet.json!");
    }
    if (!participationAddress) {
        throw new Error("OmniParticipation not found in mainnet.json!");
    }
    if (!omniCoreAddress) {
        throw new Error("OmniCore not found in mainnet.json!");
    }

    console.log("OmniCoin:", xomTokenAddress);
    console.log("OmniParticipation:", participationAddress);
    console.log("OmniCore:", omniCoreAddress);

    // Verify contracts exist on-chain
    for (const [name, addr] of [["OmniCoin", xomTokenAddress], ["OmniParticipation", participationAddress], ["OmniCore", omniCoreAddress]]) {
        const code = await ethers.provider.getCode(addr);
        if (code === "0x") {
            throw new Error(`${name} not found on-chain at ${addr}!`);
        }
    }
    console.log("All dependencies verified on-chain\n");

    // --- Deploy OmniValidatorRewards ---
    console.log("--- Deploying OmniValidatorRewards (UUPS Proxy) ---");
    const OmniValidatorRewards = await ethers.getContractFactory("OmniValidatorRewards");
    const proxy = await upgrades.deployProxy(
        OmniValidatorRewards,
        [xomTokenAddress, participationAddress, omniCoreAddress],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("OmniValidatorRewards proxy:", proxyAddress);
    console.log("OmniValidatorRewards implementation:", implAddress);

    // Verify deployment
    const rewards = await ethers.getContractAt("OmniValidatorRewards", proxyAddress);
    const baseReward = await rewards.INITIAL_BLOCK_REWARD();
    const reductionInterval = await rewards.REDUCTION_INTERVAL();
    console.log("BASE_BLOCK_REWARD:", ethers.formatEther(baseReward), "XOM");
    console.log("REDUCTION_INTERVAL:", Number(reductionInterval), "blocks");

    // --- Update mainnet.json ---
    deployments.contracts.OmniValidatorRewards = proxyAddress;
    deployments.contracts.OmniValidatorRewardsImplementation = implAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `OmniValidatorRewards deployed: proxy ${proxyAddress}. ` +
        `Block rewards: ${ethers.formatEther(baseReward)} XOM/block, 1% reduction every ${Number(reductionInterval)} blocks.`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== OmniValidatorRewards Deployed ===");
    console.log("Next: Deploy OmniRewardManager + fund with 12,467,457,500 XOM");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
