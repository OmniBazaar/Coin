import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploys Liquidity Infrastructure contracts to OmniCoin L1
 *
 * Contracts deployed:
 * - LiquidityBootstrappingPool (LBP for initial token distribution)
 * - OmniBonding (Protocol Owned Liquidity via bonds)
 * - LiquidityMining (LP staking rewards with vesting)
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 */

interface DeploymentResult {
  LiquidityBootstrappingPool: string;
  OmniBonding: string;
  LiquidityMining: string;
  deployer: string;
  network: string;
  chainId: string;
  timestamp: string;
}

async function main(): Promise<void> {
  console.log("🚀 Starting Liquidity Infrastructure Deployment\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  // Verify network
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name);
  console.log("Chain ID:", network.chainId.toString());

  // Load existing deployment to get OmniCoin address
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  interface DeploymentFile {
    contracts: Record<string, string | Record<string, string>>;
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

  const omniCoinAddress = existingDeployment.contracts.OmniCoin as string;
  if (!omniCoinAddress || omniCoinAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniCoin address not found in deployment. Deploy core contracts first.");
  }
  console.log("Using OmniCoin at:", omniCoinAddress);

  // Treasury address - use deployer for now, should be multisig in production
  const treasuryAddress = deployer.address;
  console.log("Treasury address:", treasuryAddress);

  // USDC address - use OmniCoin as counter-asset for testnet
  // In production, this would be bridged USDC
  const counterAssetAddress = omniCoinAddress; // Placeholder for testnet
  const counterAssetDecimals = 18; // XOM has 18 decimals
  console.log("Counter-asset (for LBP):", counterAssetAddress, "\n");

  const deploymentResult: Partial<DeploymentResult> = {
    deployer: deployer.address,
    network: network.name,
    chainId: network.chainId.toString(),
    timestamp: new Date().toISOString(),
  };

  // ================================================================
  // Deploy LiquidityBootstrappingPool
  // ================================================================
  console.log("=== Deploying LiquidityBootstrappingPool ===");

  const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
  const lbp = await LBP.deploy(
    omniCoinAddress,           // XOM token
    counterAssetAddress,       // Counter-asset (USDC in production)
    counterAssetDecimals,      // Counter-asset decimals
    treasuryAddress            // Treasury to receive raised funds
  );
  await lbp.waitForDeployment();
  const lbpAddress = await lbp.getAddress();
  console.log("LiquidityBootstrappingPool deployed to:", lbpAddress);
  deploymentResult.LiquidityBootstrappingPool = lbpAddress;

  // ================================================================
  // Deploy OmniBonding
  // ================================================================
  console.log("\n=== Deploying OmniBonding ===");

  // Initial XOM price: $0.005 = 5e15 wei (18 decimals)
  const initialXomPrice = ethers.parseUnits("0.005", 18);

  const OmniBonding = await ethers.getContractFactory("OmniBonding");
  const bonding = await OmniBonding.deploy(
    omniCoinAddress,           // XOM token
    treasuryAddress,           // Treasury to receive bonded assets
    initialXomPrice            // Initial XOM price for bond calculations
  );
  await bonding.waitForDeployment();
  const bondingAddress = await bonding.getAddress();
  console.log("OmniBonding deployed to:", bondingAddress);
  deploymentResult.OmniBonding = bondingAddress;

  // ================================================================
  // Deploy LiquidityMining
  // ================================================================
  console.log("\n=== Deploying LiquidityMining ===");

  const LiquidityMining = await ethers.getContractFactory("LiquidityMining");
  const mining = await LiquidityMining.deploy(
    omniCoinAddress,           // XOM reward token
    treasuryAddress            // Treasury for fees
  );
  await mining.waitForDeployment();
  const miningAddress = await mining.getAddress();
  console.log("LiquidityMining deployed to:", miningAddress);
  deploymentResult.LiquidityMining = miningAddress;

  // ================================================================
  // Save Deployment Results
  // ================================================================
  console.log("\n=== Saving Deployment Results ===");

  // Update existing deployment file - add to contracts object
  existingDeployment.contracts.LiquidityBootstrappingPool = lbpAddress;
  existingDeployment.contracts.OmniBonding = bondingAddress;
  existingDeployment.contracts.LiquidityMining = miningAddress;

  // Update timestamp
  existingDeployment.upgradedAt = new Date().toISOString();

  // Ensure deployments directory exists
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  // Write to fuji.json
  fs.writeFileSync(
    path.join(deploymentsDir, "fuji.json"),
    JSON.stringify(existingDeployment, null, 2)
  );
  console.log("✓ Updated deployments/fuji.json");

  // ================================================================
  // Summary
  // ================================================================
  console.log("\n" + "=".repeat(60));
  console.log("🎉 LIQUIDITY INFRASTRUCTURE DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log("\nDeployed Contracts:");
  console.log(`  LiquidityBootstrappingPool: ${lbpAddress}`);
  console.log(`  OmniBonding:                ${bondingAddress}`);
  console.log(`  LiquidityMining:            ${miningAddress}`);
  console.log("\nUsing:");
  console.log(`  OmniCoin:                   ${omniCoinAddress}`);
  console.log(`  Treasury:                   ${treasuryAddress}`);
  console.log("\n" + "=".repeat(60));
  console.log("\nNext Steps:");
  console.log("1. Run: ./scripts/sync-contract-addresses.sh fuji");
  console.log("2. Configure LBP parameters with lbp.configure(...)");
  console.log("3. Add bond assets with bonding.addBondAsset(...)");
  console.log("4. Add mining pools with mining.addPool(...)");
  console.log("5. Fund contracts with XOM for distribution");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
