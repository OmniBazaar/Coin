/**
 * Deploy OmniValidatorRewards Contract
 *
 * Deploys the validator reward distribution system.
 * Requires OmniCoin, OmniParticipation, and OmniCore to be already deployed.
 */

import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  console.log("\n=== Deploying OmniValidatorRewards ===\n");

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance: ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} AVAX\n`);

  // Load deployment config
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const xomTokenAddress = deployment.contracts.OmniCoin;
  const participationAddress = deployment.contracts.OmniParticipation;
  const omniCoreAddress = deployment.contracts.OmniCore;

  if (!xomTokenAddress || xomTokenAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniCoin not deployed. Deploy it first.");
  }

  if (!participationAddress || participationAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniParticipation not deployed. Deploy it first.");
  }

  if (!omniCoreAddress || omniCoreAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniCore not deployed. Deploy it first.");
  }

  console.log(`OmniCoin: ${xomTokenAddress}`);
  console.log(`OmniParticipation: ${participationAddress}`);
  console.log(`OmniCore: ${omniCoreAddress}`);

  // Check if already deployed
  if (deployment.contracts.OmniValidatorRewards && deployment.contracts.OmniValidatorRewards !== "0x0000000000000000000000000000000000000000") {
    console.log(`\nOmniValidatorRewards already deployed at: ${deployment.contracts.OmniValidatorRewards}`);
    console.log("Use --force to redeploy");

    // Verify contract is accessible
    try {
      const existing = await ethers.getContractAt("OmniValidatorRewards", deployment.contracts.OmniValidatorRewards);
      const baseReward = await existing.BASE_BLOCK_REWARD();
      console.log(`Verified - BASE_BLOCK_REWARD: ${ethers.formatEther(baseReward)} XOM`);
      return;
    } catch (error) {
      console.log("Contract not accessible, proceeding with deployment...");
    }
  }

  // Deploy OmniValidatorRewards
  console.log("\nDeploying OmniValidatorRewards (UUPS Proxy)...");

  const OmniValidatorRewards = await ethers.getContractFactory("OmniValidatorRewards");

  const rewards = await upgrades.deployProxy(
    OmniValidatorRewards,
    [xomTokenAddress, participationAddress, omniCoreAddress],
    {
      kind: "uups",
      initializer: "initialize",
    }
  );

  await rewards.waitForDeployment();

  const proxyAddress = await rewards.getAddress();
  const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log(`\nProxy deployed: ${proxyAddress}`);
  console.log(`Implementation: ${implAddress}`);

  // Verify deployment
  console.log("\nVerifying deployment...");

  const baseReward = await rewards.BASE_BLOCK_REWARD();
  const reductionInterval = await rewards.REDUCTION_INTERVAL();
  const reductionPercent = await rewards.REDUCTION_PERCENT();

  console.log(`BASE_BLOCK_REWARD: ${ethers.formatEther(baseReward)} XOM`);
  console.log(`REDUCTION_INTERVAL: ${reductionInterval} blocks`);
  console.log(`REDUCTION_PERCENT: ${reductionPercent}%`);

  // Update deployment file
  deployment.contracts.OmniValidatorRewards = proxyAddress;
  deployment.contracts.OmniValidatorRewardsImplementation = implAddress;

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("\nUpdated deployments/fuji.json");

  // Note about funding
  console.log("\n=== IMPORTANT: Fund the Contract ===");
  console.log(`The reward contract needs XOM tokens to distribute rewards.`);
  console.log(`Transfer XOM tokens to: ${proxyAddress}`);
  console.log(`Recommended: At least 1,000,000 XOM for initial rewards pool\n`);

  // Sync to other modules
  console.log("Remember to sync contract addresses:");
  console.log("  ./scripts/sync-contract-addresses.sh fuji");

  console.log("\n=== OmniValidatorRewards Deployment Complete ===\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nDeployment failed:", error);
    process.exitCode = 1;
  });
