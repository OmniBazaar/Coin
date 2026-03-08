const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys Bootstrap.sol to OmniCoin L1 (chain 88008)
 *
 * Bootstrap.sol is the SINGLE SOURCE OF TRUTH for validator discovery.
 * Deployed on the OmniCoin L1 for free gas (no AVAX costs for registration/heartbeats).
 *
 * Network: mainnet (OmniCoin L1)
 * Chain ID: 88008
 */
async function main() {
  console.log("Deploying Bootstrap.sol to OmniCoin L1 (chain 88008)\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  if (balance === 0n) {
    console.log("Deployer has no native tokens on L1!");
    process.exit(1);
  }

  // Verify we're on OmniCoin L1
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name);
  console.log("Chain ID:", network.chainId.toString());

  if (network.chainId !== 88008n) {
    throw new Error("Not connected to OmniCoin L1 (expected chainId 88008, got " + network.chainId.toString() + ")");
  }
  console.log("Connected to OmniCoin L1\n");

  // Load mainnet deployment info
  const mainnetDeploymentPath = path.join(__dirname, "../deployments/mainnet.json");
  if (!fs.existsSync(mainnetDeploymentPath)) {
    throw new Error("mainnet.json deployment file not found.");
  }

  const mainnetDeployment = JSON.parse(fs.readFileSync(mainnetDeploymentPath, "utf8"));
  const omniCoreAddress = mainnetDeployment.contracts.OmniCore;
  const omniCoreChainId = mainnetDeployment.chainId; // 88008
  const omniCoreRpcUrl = "https://rpc.omnicoin.net";

  console.log("=== OmniCoin L1 Configuration ===");
  console.log("OmniCore Address:", omniCoreAddress);
  console.log("OmniCore Chain ID:", omniCoreChainId);
  console.log("OmniCore RPC URL:", omniCoreRpcUrl);
  console.log("");

  // Deploy Bootstrap
  console.log("=== Deploying Bootstrap ===");
  const Bootstrap = await ethers.getContractFactory("Bootstrap");
  const bootstrap = await Bootstrap.deploy(
    omniCoreAddress,
    omniCoreChainId,
    omniCoreRpcUrl
  );

  await bootstrap.waitForDeployment();
  const bootstrapAddress = await bootstrap.getAddress();
  console.log("Bootstrap deployed to:", bootstrapAddress);

  // Verify deployment
  console.log("\n=== Verification ===");
  const storedOmniCore = await bootstrap.omniCoreAddress();
  const storedChainId = await bootstrap.omniCoreChainId();
  const storedRpcUrl = await bootstrap.omniCoreRpcUrl();

  console.log("Stored OmniCore address:", storedOmniCore);
  console.log("Stored chain ID:", storedChainId.toString());
  console.log("Stored RPC URL:", storedRpcUrl);

  // Check roles
  const DEFAULT_ADMIN_ROLE = await bootstrap.DEFAULT_ADMIN_ROLE();
  const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();

  const hasAdminRole = await bootstrap.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
  const hasBootstrapRole = await bootstrap.hasRole(BOOTSTRAP_ADMIN_ROLE, deployer.address);

  console.log("Deployer has DEFAULT_ADMIN_ROLE:", hasAdminRole);
  console.log("Deployer has BOOTSTRAP_ADMIN_ROLE:", hasBootstrapRole);

  const totalNodes = await bootstrap.getTotalNodeCount();
  console.log("Total node count:", totalNodes.toString());

  // Update mainnet.json with Bootstrap address
  mainnetDeployment.contracts.Bootstrap = bootstrapAddress;
  mainnetDeployment.notes.push(
    "Bootstrap deployed " + new Date().toISOString().split("T")[0] +
    ": " + bootstrapAddress + ". Node discovery contract on L1 (chain 88008). " +
    "OmniCore ref: " + omniCoreAddress + ", RPC: " + omniCoreRpcUrl
  );
  fs.writeFileSync(mainnetDeploymentPath, JSON.stringify(mainnetDeployment, null, 2));
  console.log("\nDeployment saved to:", mainnetDeploymentPath);

  console.log("\n=== Next Steps ===");
  console.log("1. Update BOOTSTRAP_CONFIG.mainnet in omnicoin-integration.ts:");
  console.log("   Bootstrap: '" + bootstrapAddress + "'");
  console.log("   rpcUrl: 'https://rpc.omnicoin.net'");
  console.log("   chainId: 88008");
  console.log("");
  console.log("2. Run the sync script:");
  console.log("   ./scripts/sync-contract-addresses.sh mainnet");
  console.log("");
  console.log("3. Restart validators - they will auto-register on Bootstrap.sol");

  console.log("\nBootstrap deployment complete!");
  console.log("Bootstrap Address:", bootstrapAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
