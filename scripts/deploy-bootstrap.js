const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys Bootstrap.sol to Avalanche Fuji C-Chain
 *
 * Bootstrap.sol is the SINGLE SOURCE OF TRUTH for validator discovery.
 * It's deployed on C-Chain (not OmniCoin L1) so that:
 * - Clients can discover validators without L1 access
 * - Validators self-register by paying gas on C-Chain
 * - Anyone can query active validators
 *
 * Network: fuji-c-chain (Avalanche Fuji C-Chain)
 * Chain ID: 43113
 */
async function main() {
  console.log("🚀 Deploying Bootstrap.sol to Avalanche Fuji C-Chain\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "AVAX\n");

  if (balance === 0n) {
    console.log("❌ Deployer has no AVAX on Fuji C-Chain!");
    console.log("Get test AVAX from: https://core.app/tools/testnet-faucet/");
    process.exit(1);
  }

  // Verify we're on Fuji C-Chain
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name);
  console.log("Chain ID:", network.chainId.toString());

  if (network.chainId !== 43113n) {
    throw new Error("Not connected to Fuji C-Chain (expected chainId 43113)");
  }
  console.log("✓ Connected to Avalanche Fuji C-Chain\n");

  // Load OmniCoin L1 deployment info
  const fujiDeploymentPath = path.join(__dirname, "../deployments/fuji.json");
  if (!fs.existsSync(fujiDeploymentPath)) {
    throw new Error("fuji.json deployment file not found. Deploy to L1 first.");
  }

  const fujiDeployment = JSON.parse(fs.readFileSync(fujiDeploymentPath, "utf8"));
  const omniCoreAddress = fujiDeployment.contracts.OmniCore;
  const omniCoreChainId = fujiDeployment.chainId; // 131313
  const omniCoreRpcUrl = fujiDeployment.rpcUrl;

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

  console.log("✓ Stored OmniCore address:", storedOmniCore);
  console.log("✓ Stored chain ID:", storedChainId.toString());
  console.log("✓ Stored RPC URL:", storedRpcUrl);

  // Check roles
  const DEFAULT_ADMIN_ROLE = await bootstrap.DEFAULT_ADMIN_ROLE();
  const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();

  const hasAdminRole = await bootstrap.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
  const hasBootstrapRole = await bootstrap.hasRole(BOOTSTRAP_ADMIN_ROLE, deployer.address);

  console.log("✓ Deployer has DEFAULT_ADMIN_ROLE:", hasAdminRole);
  console.log("✓ Deployer has BOOTSTRAP_ADMIN_ROLE:", hasBootstrapRole);

  // Save deployment to fuji-c-chain.json
  const deployment = {
    network: "fuji-c-chain",
    chainId: 43113,
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
    contracts: {
      Bootstrap: bootstrapAddress
    },
    omniCoreReference: {
      address: omniCoreAddress,
      chainId: omniCoreChainId,
      rpcUrl: omniCoreRpcUrl
    }
  };

  const deploymentsPath = path.join(__dirname, "../deployments");
  const deploymentFile = path.join(deploymentsPath, "fuji-c-chain.json");
  fs.writeFileSync(deploymentFile, JSON.stringify(deployment, null, 2));
  console.log("\n✅ Deployment saved to:", deploymentFile);

  // Print instructions
  console.log("\n=== Next Steps ===");
  console.log("1. Update C_CHAIN_BOOTSTRAP.fuji.Bootstrap in omnicoin-integration.ts:");
  console.log(`   Bootstrap: '${bootstrapAddress}'`);
  console.log("");
  console.log("2. Run the sync script to update all modules:");
  console.log("   ./scripts/sync-contract-addresses.sh fuji");
  console.log("");
  console.log("3. Ensure validators have AVAX on C-Chain for registration");
  console.log("");
  console.log("4. Restart validators - they will auto-register on Bootstrap.sol");

  console.log("\n🎉 Bootstrap deployment complete!");
  console.log("Bootstrap Address:", bootstrapAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });
