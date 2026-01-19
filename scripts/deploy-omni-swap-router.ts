import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploys OmniSwapRouter contract to OmniCoin L1
 *
 * Contract deployed:
 * - OmniSwapRouter (Optimal routing for token swaps)
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 *
 * Usage:
 * npx hardhat run scripts/deploy-omni-swap-router.ts --network omnicoinFuji
 */

interface DeploymentResult {
  OmniSwapRouter: string;
  deployer: string;
  feeRecipient: string;
  swapFeeBps: number;
  network: string;
  chainId: string;
  timestamp: string;
}

async function main(): Promise<void> {
  console.log("🚀 Starting OmniSwapRouter Deployment\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  // Verify network
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name);
  console.log("Chain ID:", network.chainId.toString());

  // Load existing deployment to get treasury address
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  interface DeploymentFile {
    contracts: Record<string, string | Record<string, string>>;
    deployer?: string;
    [key: string]: unknown;
  }
  let existingDeployment: DeploymentFile | null = null;

  if (fs.existsSync(deploymentPath)) {
    existingDeployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;
    console.log("✓ Loaded existing Fuji deployment\n");
  } else {
    // Try localhost deployment
    const localhostPath = path.join(__dirname, "../deployments/localhost.json");
    if (fs.existsSync(localhostPath)) {
      existingDeployment = JSON.parse(fs.readFileSync(localhostPath, "utf-8")) as DeploymentFile;
      console.log("✓ Loaded localhost deployment\n");
    }
  }

  if (!existingDeployment) {
    throw new Error("No deployment file found. Deploy core contracts first.");
  }

  // Fee recipient - use deployer for testnet
  // In production, this should be the protocol treasury (multisig)
  const feeRecipient = deployer.address; // TODO: Replace with treasury multisig in production

  // Swap fee: 30 basis points = 0.30%
  const swapFeeBps = 30;

  console.log("Fee Recipient:", feeRecipient);
  console.log("Swap Fee:", swapFeeBps, "bps (0.30%)\n");

  // ================================================================
  // Deploy OmniSwapRouter
  // ================================================================
  console.log("=== Deploying OmniSwapRouter ===");

  const OmniSwapRouter = await ethers.getContractFactory("OmniSwapRouter");
  const omniSwapRouter = await OmniSwapRouter.deploy(
    feeRecipient,    // Fee recipient address
    swapFeeBps       // Swap fee in basis points
  );
  await omniSwapRouter.waitForDeployment();

  const omniSwapRouterAddress = await omniSwapRouter.getAddress();
  console.log("✓ OmniSwapRouter deployed to:", omniSwapRouterAddress);

  // ================================================================
  // Register default liquidity sources
  // ================================================================
  console.log("\n=== Registering Default Liquidity Sources ===");

  // Internal AMM pool
  const internalPoolId = ethers.keccak256(ethers.toUtf8Bytes("INTERNAL_AMM"));
  console.log("Internal AMM Pool ID:", internalPoolId);
  // TODO: Deploy and register internal AMM adapter

  // Uniswap V3 (if available on this chain)
  const uniswapV3Id = ethers.keccak256(ethers.toUtf8Bytes("UNISWAP_V3"));
  console.log("Uniswap V3 ID:", uniswapV3Id);
  // TODO: Deploy and register Uniswap V3 adapter if applicable

  console.log("✓ Liquidity source IDs generated (adapters to be registered separately)");

  // ================================================================
  // Save deployment information
  // ================================================================
  const deploymentResult: DeploymentResult = {
    OmniSwapRouter: omniSwapRouterAddress,
    deployer: deployer.address,
    feeRecipient,
    swapFeeBps,
    network: network.name,
    chainId: network.chainId.toString(),
    timestamp: new Date().toISOString(),
  };

  // Update the existing deployment file
  if (existingDeployment) {
    existingDeployment.contracts.OmniSwapRouter = omniSwapRouterAddress;
    existingDeployment.upgradedAt = new Date().toISOString();

    fs.writeFileSync(
      deploymentPath,
      JSON.stringify(existingDeployment, null, 2)
    );
    console.log("\n✓ Updated deployment file:", deploymentPath);
  }

  // Also save standalone router deployment result
  const routerDeploymentPath = path.join(__dirname, "../deployments/omni-swap-router.json");
  fs.writeFileSync(
    routerDeploymentPath,
    JSON.stringify(deploymentResult, null, 2)
  );
  console.log("✓ Saved router deployment result:", routerDeploymentPath);

  console.log("\n=== Deployment Summary ===");
  console.log("OmniSwapRouter:", omniSwapRouterAddress);
  console.log("Fee Recipient:", feeRecipient);
  console.log("Swap Fee:", swapFeeBps, "bps (0.30%)");
  console.log("Deployer:", deployer.address);
  console.log("Network:", network.name, `(Chain ID: ${network.chainId.toString()})`);

  console.log("\n✅ OmniSwapRouter deployment complete!");
  console.log("\n📋 Next Steps:");
  console.log("1. Deploy liquidity source adapters (Internal AMM, Uniswap V3, etc.)");
  console.log("2. Register adapters: omniSwapRouter.addLiquiditySource(sourceId, adapter)");
  console.log("3. Update Validator/src/config/omnicoin-integration.ts with OmniSwapRouter address");
  console.log("4. Run: ./scripts/sync-contract-addresses.sh fuji");
  console.log("5. Create AMM liquidity pools for initial trading pairs");
  console.log("6. Test swaps through the router");
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:");
    console.error(error);
    process.exit(1);
  });
