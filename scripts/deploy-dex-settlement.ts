import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploys DEXSettlement contract to OmniCoin L1
 *
 * Contract deployed:
 * - DEXSettlement (Trustless on-chain trade settlement with commit-reveal)
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 *
 * Architecture:
 * - Dual signature verification (maker + taker both sign)
 * - Contract verifies order matching logic
 * - ANYONE can submit settlement (no VALIDATOR_ROLE required)
 * - Commit-reveal for MEV protection
 * - Fee split: 70% ODDAO, 20% Staking Pool, 10% Matching Validator
 *
 * Usage:
 * npx hardhat run scripts/deploy-dex-settlement.ts --network omnicoinFuji
 */

interface DeploymentResult {
  DEXSettlement: string;
  deployer: string;
  oddao: string;
  stakingPool: string;
  network: string;
  chainId: string;
  timestamp: string;
}

async function main(): Promise<void> {
  console.log("🚀 Starting DEXSettlement Deployment (Trustless Architecture)\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  // Verify network
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name);
  console.log("Chain ID:", network.chainId.toString());

  // Load existing deployment
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
    throw new Error("No deployment file found. Deploy core contracts first.");
  }

  // Fee recipient addresses
  // In production, these should be proper contract addresses or multisigs.
  // The 10% validator share is routed dynamically per-trade to the
  // matchingValidator address in each order -- no static address needed.
  const oddaoAddress = deployer.address; // Replace with ODDAO multisig
  const stakingPoolAddress = deployer.address; // Replace with staking pool contract

  console.log("Fee Recipients:");
  console.log("  ODDAO (70%):", oddaoAddress);
  console.log("  Staking Pool (20%):", stakingPoolAddress);
  console.log("  Matching Validator (10%): dynamic per-trade\n");

  // ================================================================
  // Deploy DEXSettlement
  // ================================================================
  console.log("=== Deploying DEXSettlement ===");

  const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
  const dexSettlement = await DEXSettlement.deploy(
    oddaoAddress,          // ODDAO (70% of fees)
    stakingPoolAddress     // Staking Pool (20% of fees)
  );
  await dexSettlement.waitForDeployment();

  const dexSettlementAddress = await dexSettlement.getAddress();
  console.log("✓ DEXSettlement deployed to:", dexSettlementAddress);

  // Verify deployment
  const feeRecipients = await dexSettlement.getFeeRecipients();
  console.log("\n✓ Fee Recipients Verified:");
  console.log("  ODDAO (70%):", feeRecipients.oddao);
  console.log("  Staking Pool (20%):", feeRecipients.stakingPool);
  console.log("  Validator (10%): dynamic per-trade (matchingValidator)");

  const stats = await dexSettlement.getTradingStats();
  console.log("\n✓ Initial Trading Limits:");
  console.log("  Max Trade Size:", ethers.formatUnits(stats.dailyLimit, 18), "tokens");
  console.log("  Daily Volume Limit:", ethers.formatUnits(stats.dailyLimit, 18), "tokens");

  // ================================================================
  // Save deployment information
  // ================================================================
  const deploymentResult: DeploymentResult = {
    DEXSettlement: dexSettlementAddress,
    deployer: deployer.address,
    oddao: oddaoAddress,
    stakingPool: stakingPoolAddress,
    network: network.name,
    chainId: network.chainId.toString(),
    timestamp: new Date().toISOString(),
  };

  // Update the existing deployment file
  if (existingDeployment) {
    existingDeployment.contracts.DEXSettlement = dexSettlementAddress;
    existingDeployment.upgradedAt = new Date().toISOString();

    fs.writeFileSync(
      deploymentPath,
      JSON.stringify(existingDeployment, null, 2)
    );
    console.log("\n✓ Updated deployment file:", deploymentPath);
  }

  // Also save standalone DEX deployment result
  const dexDeploymentPath = path.join(__dirname, "../deployments/dex-settlement.json");
  fs.writeFileSync(
    dexDeploymentPath,
    JSON.stringify(deploymentResult, null, 2)
  );
  console.log("✓ Saved DEX deployment result:", dexDeploymentPath);

  console.log("\n=== Deployment Summary ===");
  console.log("DEXSettlement:", dexSettlementAddress);
  console.log("\nFee Distribution:");
  console.log("  70% → ODDAO:", oddaoAddress);
  console.log("  20% → Staking Pool:", stakingPoolAddress);
  console.log("  10% → Matching Validator: dynamic per-trade");
  console.log("\nDeployer:", deployer.address);
  console.log("Network:", network.name, `(Chain ID: ${network.chainId.toString()})`);

  console.log("\n✅ DEXSettlement deployment complete!");
  console.log("\n🔒 Trustless Features Enabled:");
  console.log("  ✓ ANYONE can submit settlements (no VALIDATOR_ROLE on settlement)");
  console.log("  ✓ Dual signature verification (maker + taker both sign EIP-712)");
  console.log("  ✓ Contract verifies order matching logic");
  console.log("  ✓ Commit-reveal MEV protection");
  console.log("  ✓ Fee attribution to matchingValidator (not submitter)");
  console.log("\n📋 Next Steps:");
  console.log("1. Update Validator/src/config/omnicoin-integration.ts with DEXSettlement address");
  console.log("2. Run: ./scripts/sync-contract-addresses.sh fuji");
  console.log("3. Deploy OmniSwapRouter for optimal routing");
  console.log("4. Deploy LiquidityPool contract for fee collection");
  console.log("5. Update fee recipients: dexSettlement.updateFeeRecipients()");
  console.log("6. Create AMM liquidity pools");
  console.log("7. Implement EIP-712 signing in WebApp/Validator");
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:");
    console.error(error);
    process.exit(1);
  });
