/**
 * @file deploy-omnicore-mainnet.js
 * @description Redeploy OmniCore (UUPS proxy) with correct ODDAO address.
 *
 * The initial Phase 1 deployment used deployer.address as placeholder for
 * both oddaoAddress and stakingPoolAddress. This script deploys a fresh
 * OmniCore proxy with the real ODDAO treasury address. StakingRewardPool
 * address is set to deployer temporarily, then updated via
 * setStakingPoolAddress() after StakingRewardPool deploys.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-omnicore-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

const OMNI_COIN = "0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B";
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

async function main() {
    console.log("=== Redeploy OmniCore with Correct Addresses ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }
    console.log("Chain ID: 88008\n");

    // Verify OmniCoin exists on-chain
    const omniCoinCode = await ethers.provider.getCode(OMNI_COIN);
    if (omniCoinCode === "0x") {
        throw new Error("OmniCoin not found at expected address!");
    }
    console.log("OmniCoin verified at:", OMNI_COIN);

    // Verify ODDAO treasury is a valid address (not a contract requirement, just sanity)
    console.log("ODDAO treasury:", ODDAO_TREASURY);
    console.log("StakingPool: deployer (temporary — update after StakingRewardPool deploys)\n");

    // Deploy new OmniCore proxy
    console.log("--- Deploying OmniCore (UUPS Proxy) ---");
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const omniCore = await upgrades.deployProxy(
        OmniCore,
        [
            deployer.address,    // admin
            OMNI_COIN,           // OmniCoin token
            ODDAO_TREASURY,      // ODDAO address (70% fees) — REAL
            deployer.address     // Staking pool — temporary, update later
        ],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await omniCore.waitForDeployment();

    const proxyAddress = await omniCore.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("OmniCore proxy:", proxyAddress);
    console.log("OmniCore implementation:", implAddress);

    // Verify initialization
    const oddao = await omniCore.oddaoAddress();
    const stakingPool = await omniCore.stakingPoolAddress();
    const token = await omniCore.OMNI_COIN();
    console.log("\nVerification:");
    console.log("  oddaoAddress:", oddao);
    console.log("  stakingPoolAddress:", stakingPool, "(temporary — deployer)");
    console.log("  OMNI_COIN:", token);
    console.log("  ODDAO matches:", oddao === ODDAO_TREASURY ? "YES" : "NO");
    console.log("  Token matches:", token === OMNI_COIN ? "YES" : "NO");

    if (oddao !== ODDAO_TREASURY) {
        throw new Error("ODDAO address mismatch!");
    }

    // Update mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    // Record old address
    const oldOmniCore = deployments.contracts.OmniCore;
    const oldOmniCoreImpl = deployments.contracts.OmniCoreImplementation;

    deployments.contracts.OmniCore = proxyAddress;
    deployments.contracts.OmniCoreImplementation = implAddress;
    deployments.deployedAt = new Date().toISOString();

    // Add note about redeploy
    deployments.notes.push(
        `OmniCore redeployed 2026-03-07: Old proxy ${oldOmniCore} replaced with ${proxyAddress}. ` +
        `Now uses real ODDAO treasury (${ODDAO_TREASURY}). StakingPool still temporary (deployer), ` +
        `will be set via setStakingPoolAddress() after StakingRewardPool deploys.`
    );

    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== OmniCore Redeployed Successfully ===");
    console.log("Next step: Deploy StakingRewardPool, then call:");
    console.log(`  omniCore.setStakingPoolAddress(<StakingRewardPool proxy>)`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
