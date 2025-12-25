/**
 * Deploy OmniParticipation Contract
 *
 * Deploys the trustless participation scoring system.
 * Requires OmniRegistration and OmniCore to be already deployed.
 */

import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  console.log("\n=== Deploying OmniParticipation ===\n");

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance: ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} AVAX\n`);

  // Load deployment config
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const registrationAddress = deployment.contracts.OmniRegistration;
  const omniCoreAddress = deployment.contracts.OmniCore;

  if (!registrationAddress || registrationAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniRegistration not deployed. Deploy it first.");
  }

  if (!omniCoreAddress || omniCoreAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniCore not deployed. Deploy it first.");
  }

  console.log(`OmniRegistration: ${registrationAddress}`);
  console.log(`OmniCore: ${omniCoreAddress}`);

  // Check if already deployed
  if (deployment.contracts.OmniParticipation && deployment.contracts.OmniParticipation !== "0x0000000000000000000000000000000000000000") {
    console.log(`\nOmniParticipation already deployed at: ${deployment.contracts.OmniParticipation}`);
    console.log("Use --force to redeploy");

    // Verify contract is accessible
    try {
      const existing = await ethers.getContractAt("OmniParticipation", deployment.contracts.OmniParticipation);
      const minScore = await existing.MIN_VALIDATOR_SCORE();
      console.log(`Verified - MIN_VALIDATOR_SCORE: ${minScore}`);
      return;
    } catch (error) {
      console.log("Contract not accessible, proceeding with deployment...");
    }
  }

  // Deploy OmniParticipation
  console.log("\nDeploying OmniParticipation (UUPS Proxy)...");

  const OmniParticipation = await ethers.getContractFactory("OmniParticipation");

  const participation = await upgrades.deployProxy(
    OmniParticipation,
    [registrationAddress, omniCoreAddress],
    {
      kind: "uups",
      initializer: "initialize",
    }
  );

  await participation.waitForDeployment();

  const proxyAddress = await participation.getAddress();
  const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log(`\nProxy deployed: ${proxyAddress}`);
  console.log(`Implementation: ${implAddress}`);

  // Verify deployment
  console.log("\nVerifying deployment...");

  const minValidatorScore = await participation.MIN_VALIDATOR_SCORE();
  const minListingNodeScore = await participation.MIN_LISTING_NODE_SCORE();

  console.log(`MIN_VALIDATOR_SCORE: ${minValidatorScore}`);
  console.log(`MIN_LISTING_NODE_SCORE: ${minListingNodeScore}`);

  // Update deployment file
  deployment.contracts.OmniParticipation = proxyAddress;
  deployment.contracts.OmniParticipationImplementation = implAddress;

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("\nUpdated deployments/fuji.json");

  // Sync to other modules
  console.log("\nRemember to sync contract addresses:");
  console.log("  ./scripts/sync-contract-addresses.sh fuji");

  console.log("\n=== OmniParticipation Deployment Complete ===\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nDeployment failed:", error);
    process.exitCode = 1;
  });
