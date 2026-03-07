/**
 * @file deploy-reward-manager-mainnet.js
 * @description Deploy OmniRewardManager (UUPS proxy) on mainnet (chain 88008)
 *              and fund it with 12,467,457,500 XOM.
 *
 * The contract's initialize() checks balanceOf(address(this)) >= totalPool
 * (M-02 audit fix), so tokens must be present BEFORE initialization.
 *
 * Strategy: Deploy proxy WITHOUT initialization, fund it, then call
 * initialize() manually.
 *
 * Pool allocation:
 *   Welcome Bonus:     1,383,457,500 XOM
 *   Referral Bonus:    2,995,000,000 XOM
 *   First Sale Bonus:  2,000,000,000 XOM
 *   Validator Rewards: 6,089,000,000 XOM
 *   TOTAL:            12,467,457,500 XOM
 *
 * Usage:
 *   npx hardhat run scripts/deploy-reward-manager-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Production pool sizes */
const POOLS = {
    welcomeBonus:     ethers.parseEther("1383457500"),
    referralBonus:    ethers.parseEther("2995000000"),
    firstSaleBonus:   ethers.parseEther("2000000000"),
    validatorRewards: ethers.parseEther("6089000000"),
};

async function main() {
    console.log("=== Deploy OmniRewardManager (Mainnet) ===\n");

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
    if (!omniCoinAddress) {
        throw new Error("OmniCoin not found in mainnet.json!");
    }
    console.log("OmniCoin:", omniCoinAddress);

    // Verify OmniCoin on-chain
    const omniCoin = await ethers.getContractAt("OmniCoin", omniCoinAddress);
    const symbol = await omniCoin.symbol();
    console.log(`Token: ${symbol}`);

    // Calculate totals
    const totalPoolSize = POOLS.welcomeBonus + POOLS.referralBonus +
                          POOLS.firstSaleBonus + POOLS.validatorRewards;

    console.log("\nPool Allocation (PRODUCTION):");
    console.log("  Welcome Bonus:     ", ethers.formatEther(POOLS.welcomeBonus), "XOM");
    console.log("  Referral Bonus:    ", ethers.formatEther(POOLS.referralBonus), "XOM");
    console.log("  First Sale Bonus:  ", ethers.formatEther(POOLS.firstSaleBonus), "XOM");
    console.log("  Validator Rewards: ", ethers.formatEther(POOLS.validatorRewards), "XOM");
    console.log("  TOTAL:             ", ethers.formatEther(totalPoolSize), "XOM");

    // Check deployer balance
    const deployerBalance = await omniCoin.balanceOf(deployer.address);
    console.log("\nDeployer XOM balance:", ethers.formatEther(deployerBalance), "XOM");

    if (deployerBalance < totalPoolSize) {
        throw new Error(
            `Insufficient XOM! Need ${ethers.formatEther(totalPoolSize)}, ` +
            `have ${ethers.formatEther(deployerBalance)}`
        );
    }

    // --- Step 1: Deploy proxy WITHOUT initialization ---
    // The contract's initialize() checks token balance (M-02 audit fix),
    // so we must fund the proxy before calling initialize().
    console.log("\n--- Step 1: Deploy OmniRewardManager proxy (uninitialized) ---");
    const OmniRewardManager = await ethers.getContractFactory("OmniRewardManager");
    const proxy = await upgrades.deployProxy(
        OmniRewardManager,
        [],
        {
            initializer: false,
            kind: "uups"
        }
    );
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("OmniRewardManager proxy (uninitialized):", proxyAddress);
    console.log("OmniRewardManager implementation:", implAddress);

    // --- Step 2: Fund the proxy with 12,467,457,500 XOM ---
    console.log("\n--- Step 2: Funding proxy with", ethers.formatEther(totalPoolSize), "XOM ---");
    const transferTx = await omniCoin.transfer(proxyAddress, totalPoolSize);
    const receipt = await transferTx.wait();
    console.log("Transfer tx:", receipt.hash);

    const proxyBalance = await omniCoin.balanceOf(proxyAddress);
    console.log("Proxy XOM balance:", ethers.formatEther(proxyBalance), "XOM");

    // --- Step 3: Call initialize() now that tokens are present ---
    console.log("\n--- Step 3: Calling initialize() ---");
    const rewardManager = await ethers.getContractAt("OmniRewardManager", proxyAddress);
    const initTx = await rewardManager.initialize(
        omniCoinAddress,
        POOLS.welcomeBonus,
        POOLS.referralBonus,
        POOLS.firstSaleBonus,
        POOLS.validatorRewards,
        deployer.address    // admin
    );
    await initTx.wait();
    console.log("initialize() called successfully");

    // Verify pool balances
    const [welcomeRemaining, referralRemaining, firstSaleRemaining, validatorRemaining] =
        await rewardManager.getPoolBalances();

    console.log("\nVerified Pool Balances:");
    console.log("  Welcome Bonus:     ", ethers.formatEther(welcomeRemaining), "XOM");
    console.log("  Referral Bonus:    ", ethers.formatEther(referralRemaining), "XOM");
    console.log("  First Sale Bonus:  ", ethers.formatEther(firstSaleRemaining), "XOM");
    console.log("  Validator Rewards: ", ethers.formatEther(validatorRemaining), "XOM");

    // Check deployer balance after
    const deployerAfter = await omniCoin.balanceOf(deployer.address);
    console.log("\nDeployer XOM remaining:", ethers.formatEther(deployerAfter), "XOM");

    // --- Update mainnet.json ---
    deployments.contracts.OmniRewardManager = proxyAddress;
    deployments.contracts.OmniRewardManagerImplementation = implAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `OmniRewardManager deployed: proxy ${proxyAddress}. ` +
        `Funded with ${ethers.formatEther(totalPoolSize)} XOM ` +
        `(Welcome: ${ethers.formatEther(POOLS.welcomeBonus)}, ` +
        `Referral: ${ethers.formatEther(POOLS.referralBonus)}, ` +
        `FirstSale: ${ethers.formatEther(POOLS.firstSaleBonus)}, ` +
        `Validator: ${ethers.formatEther(POOLS.validatorRewards)}).`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("Updated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== OmniRewardManager Deployed & Funded ===");
    console.log("Next: Deploy DEXSettlement, OmniSwapRouter, fund LegacyBalanceClaim");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
