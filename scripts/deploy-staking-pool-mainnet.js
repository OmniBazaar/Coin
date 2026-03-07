/**
 * @file deploy-staking-pool-mainnet.js
 * @description Deploy StakingRewardPool (UUPS proxy) on mainnet (chain 88008).
 *
 * After deploying, this script:
 *   1. Calls omniCore.setStakingPoolAddress() to register the pool
 *   2. Seeds the pool with 2,542,500 XOM (deployer remainder after all
 *      other allocations from the 16.6B XOM total supply)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-staking-pool-mainnet.js --network mainnet
 *
 * Prerequisites:
 *   - OmniCore redeployed with setStakingPoolAddress() function
 *   - OmniCoin deployed and initialized (16.6B XOM in deployer)
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Seed funding: 2,542,500 XOM — exact deployer remainder after all pool allocations */
const SEED_FUNDING = ethers.parseEther("2542500");

async function main() {
    console.log("=== Deploy StakingRewardPool (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const omniCoreAddress = deployments.contracts.OmniCore;
    const omniCoinAddress = deployments.contracts.OmniCoin;

    if (!omniCoreAddress || !omniCoinAddress) {
        throw new Error("OmniCore or OmniCoin not found in mainnet.json!");
    }

    console.log("OmniCore:", omniCoreAddress);
    console.log("OmniCoin:", omniCoinAddress);

    // Verify on-chain
    const omniCoin = await ethers.getContractAt("OmniCoin", omniCoinAddress);
    const symbol = await omniCoin.symbol();
    console.log(`Token: ${symbol}\n`);

    // --- Deploy StakingRewardPool ---
    console.log("--- Deploying StakingRewardPool (UUPS Proxy) ---");
    const StakingRewardPool = await ethers.getContractFactory("StakingRewardPool");
    const proxy = await upgrades.deployProxy(
        StakingRewardPool,
        [omniCoreAddress, omniCoinAddress],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("StakingRewardPool proxy:", proxyAddress);
    console.log("StakingRewardPool implementation:", implAddress);

    // Verify ADMIN_ROLE
    const stakingPool = await ethers.getContractAt("StakingRewardPool", proxyAddress);
    const ADMIN_ROLE = await stakingPool.ADMIN_ROLE();
    const hasAdmin = await stakingPool.hasRole(ADMIN_ROLE, deployer.address);
    console.log("Deployer has ADMIN_ROLE:", hasAdmin);

    // Verify APR settings
    const tier1 = await stakingPool.tierAPR(1);
    const tier5 = await stakingPool.tierAPR(5);
    console.log(`Tier 1 APR: ${Number(tier1) / 100}%, Tier 5 APR: ${Number(tier5) / 100}%\n`);

    // --- Set StakingRewardPool on OmniCore ---
    console.log("--- Setting StakingRewardPool on OmniCore ---");
    const omniCore = await ethers.getContractAt("OmniCore", omniCoreAddress);
    const setTx = await omniCore.setStakingPoolAddress(proxyAddress);
    await setTx.wait();
    const newStakingPool = await omniCore.stakingPoolAddress();
    console.log("OmniCore.stakingPoolAddress:", newStakingPool);
    console.log("Matches:", newStakingPool === proxyAddress ? "YES" : "NO");

    if (newStakingPool !== proxyAddress) {
        throw new Error("StakingPoolAddress mismatch after setStakingPoolAddress()!");
    }
    console.log("");

    // --- Seed pool with 2,542,500 XOM ---
    console.log("--- Seeding StakingRewardPool with", ethers.formatEther(SEED_FUNDING), "XOM ---");
    const deployerBalance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", ethers.formatEther(deployerBalance), "XOM");

    if (deployerBalance < SEED_FUNDING) {
        console.log("WARNING: Deployer has insufficient XOM for seed funding. Skipping.");
    } else {
        // Approve
        const approveTx = await omniCoin.approve(proxyAddress, SEED_FUNDING);
        await approveTx.wait();
        console.log("Approved", ethers.formatEther(SEED_FUNDING), "XOM");

        // Deposit
        const depositTx = await stakingPool.depositToPool(SEED_FUNDING);
        await depositTx.wait();

        const poolBalance = await stakingPool.getPoolBalance();
        console.log("Pool balance:", ethers.formatEther(poolBalance), "XOM");
        console.log("Total deposited:", ethers.formatEther(await stakingPool.totalDeposited()), "XOM");
    }
    console.log("");

    // --- Update mainnet.json ---
    deployments.contracts.StakingRewardPool = proxyAddress;
    deployments.contracts.StakingRewardPoolImplementation = implAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `StakingRewardPool deployed 2026-03-07: proxy ${proxyAddress}. ` +
        `OmniCore.setStakingPoolAddress() called. ` +
        `Seeded with 2,542,500 XOM (deployer remainder).`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Updated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== StakingRewardPool Deployed & Configured ===");
    console.log("Next: Deploy OmniParticipation, OmniValidatorRewards, OmniRewardManager");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
