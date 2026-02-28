/**
 * Upgrade OmniValidatorRewards UUPS Proxy
 *
 * Force-deploys new implementation and upgrades proxy.
 * This is needed because the deployed impl was compiled without PENALTY_ROLE.
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-validator-rewards.ts --network fuji
 */

import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  console.log("\n=== Upgrading OmniValidatorRewards ===\n");

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  // Load deployment config
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const proxyAddress = deployment.contracts.OmniValidatorRewards;
  if (!proxyAddress || proxyAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniValidatorRewards not deployed. Deploy first.");
  }

  console.log(`Proxy address: ${proxyAddress}`);

  const OmniValidatorRewards = await ethers.getContractFactory("OmniValidatorRewards");

  // Force import existing proxy
  console.log("Importing existing proxy...");
  try {
    await upgrades.forceImport(proxyAddress, OmniValidatorRewards, { kind: "uups" });
    console.log("Proxy imported");
  } catch {
    console.log("Proxy already registered");
  }

  const oldImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`Current implementation: ${oldImpl}`);

  // Deploy a fresh implementation manually
  console.log("\nDeploying fresh implementation...");
  const newImplFactory = await ethers.getContractFactory("OmniValidatorRewards");
  const newImplContract = await newImplFactory.deploy();
  await newImplContract.waitForDeployment();
  const newImplAddr = await newImplContract.getAddress();
  console.log(`New implementation deployed at: ${newImplAddr}`);

  // Now upgrade proxy to point to new implementation
  // Use UUPS upgradeAndCall pattern
  const proxyContract = await ethers.getContractAt("OmniValidatorRewards", proxyAddress);

  // UUPS: call upgradeToAndCall on the proxy
  console.log("Upgrading proxy to new implementation...");
  const tx = await proxyContract.upgradeToAndCall(newImplAddr, "0x");
  await tx.wait();
  console.log(`Upgrade tx: ${tx.hash}`);

  const finalImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`Final implementation: ${finalImpl}`);

  // Verify PENALTY_ROLE
  console.log("\nVerifying PENALTY_ROLE...");
  const upgraded = await ethers.getContractAt("OmniValidatorRewards", proxyAddress);
  try {
    const penaltyRole = await upgraded.PENALTY_ROLE();
    console.log(`PENALTY_ROLE: ${penaltyRole}`);
    console.log("SUCCESS: PENALTY_ROLE is now accessible");
  } catch (e: unknown) {
    console.log(`PENALTY_ROLE still fails: ${(e as Error).message?.slice(0, 200)}`);
  }

  // Verify other functions still work
  try {
    const epoch = await upgraded.EPOCH_DURATION();
    console.log(`EPOCH_DURATION: ${epoch}`);
  } catch (e: unknown) {
    console.log(`EPOCH_DURATION failed: ${(e as Error).message?.slice(0, 100)}`);
  }

  // Update deployment file
  deployment.contracts.OmniValidatorRewardsImplementation = newImplAddr;
  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("\nUpdated deployments/fuji.json");

  console.log("\n=== Upgrade Complete ===\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nUpgrade failed:", error);
    process.exitCode = 1;
  });
