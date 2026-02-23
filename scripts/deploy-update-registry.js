const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys UpdateRegistry.sol to OmniCoin L1 (chain 131313)
 *
 * UpdateRegistry is the on-chain source of truth for ODDAO-approved software releases.
 * Validators and clients query this contract to discover new versions and enforce
 * minimum version requirements.
 *
 * Network: fuji (OmniCoin L1 Subnet-EVM)
 * Chain ID: 131313
 *
 * Usage:
 *   npx hardhat run scripts/deploy-update-registry.js --network fuji
 */
async function main() {
  console.log("Deploying UpdateRegistry.sol to OmniCoin L1\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  if (balance === 0n) {
    console.log("Deployer has no native tokens on OmniCoin L1.");
    process.exit(1);
  }

  // Verify we're on OmniCoin L1
  const network = await ethers.provider.getNetwork();
  console.log("Network chain ID:", network.chainId.toString());

  if (network.chainId !== 131313n) {
    throw new Error("Not connected to OmniCoin L1 (expected chainId 131313)");
  }
  console.log("Connected to OmniCoin L1\n");

  // Configure initial ODDAO signers
  // For testnet, use the deployer as the sole signer with threshold 1
  // For mainnet, this will be replaced with actual ODDAO member addresses
  const initialSigners = [deployer.address];
  const initialThreshold = 1;

  console.log("=== ODDAO Signer Configuration ===");
  console.log("Signers:", initialSigners);
  console.log("Threshold:", initialThreshold);
  console.log("(Testnet: deployer-only. Update for mainnet with actual ODDAO members.)\n");

  // Deploy UpdateRegistry
  console.log("=== Deploying UpdateRegistry ===");
  const UpdateRegistry = await ethers.getContractFactory("UpdateRegistry");
  const registry = await UpdateRegistry.deploy(initialSigners, initialThreshold);

  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log("UpdateRegistry deployed to:", registryAddress);

  // Verify deployment
  console.log("\n=== Verification ===");
  const storedThreshold = await registry.signerThreshold();
  const storedSigners = await registry.getSigners();
  const hasAdminRole = await registry.hasRole(
    await registry.DEFAULT_ADMIN_ROLE(),
    deployer.address
  );
  const hasManagerRole = await registry.hasRole(
    await registry.RELEASE_MANAGER_ROLE(),
    deployer.address
  );

  console.log("Signer threshold:", storedThreshold.toString());
  console.log("Signers:", storedSigners);
  console.log("Deployer has DEFAULT_ADMIN_ROLE:", hasAdminRole);
  console.log("Deployer has RELEASE_MANAGER_ROLE:", hasManagerRole);

  // Update fuji.json deployment file
  const deploymentsPath = path.join(__dirname, "../deployments");
  const deploymentFile = path.join(deploymentsPath, "fuji.json");

  if (fs.existsSync(deploymentFile)) {
    const deployment = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
    deployment.contracts.UpdateRegistry = registryAddress;
    deployment.upgradedAt = new Date().toISOString();
    fs.writeFileSync(deploymentFile, JSON.stringify(deployment, null, 2));
    console.log("\nDeployment saved to:", deploymentFile);
  } else {
    console.log("\nWARNING: fuji.json not found. Manually add UpdateRegistry:", registryAddress);
  }

  // Print instructions
  console.log("\n=== Next Steps ===");
  console.log("1. Run the sync script to update all modules:");
  console.log("   ./scripts/sync-contract-addresses.sh fuji");
  console.log("");
  console.log("2. For mainnet, update signers to actual ODDAO member addresses:");
  console.log("   registry.updateSignerSet([addr1, addr2, ...addr5], 3, signatures)");
  console.log("");
  console.log("3. Restart validators to pick up the new contract address");

  console.log("\nUpdateRegistry deployment complete!");
  console.log("UpdateRegistry Address:", registryAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
