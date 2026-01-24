import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploys TestUSDC to OmniCoin L1 for DEX liquidity testing
 *
 * TestUSDC is a mintable test stablecoin with 6 decimals (like real USDC)
 * that anyone can mint for testing purposes.
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 */

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  [key: string]: unknown;
}

async function main(): Promise<void> {
  console.log("🚀 Starting TestUSDC Deployment\n");

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
  let existingDeployment: DeploymentFile | null = null;

  if (fs.existsSync(deploymentPath)) {
    existingDeployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;
    console.log("✓ Loaded existing Fuji deployment\n");
  } else {
    throw new Error("Fuji deployment file not found. Deploy core contracts first.");
  }

  // Check if TestUSDC already deployed
  if (existingDeployment.contracts.TestUSDC) {
    console.log("⚠️  TestUSDC already deployed at:", existingDeployment.contracts.TestUSDC);
    console.log("   To redeploy, remove TestUSDC from fuji.json first\n");
    return;
  }

  // Deploy TestUSDC
  console.log("=== Deploying TestUSDC ===");

  const TestUSDC = await ethers.getContractFactory("TestUSDC");
  const testUsdc = await TestUSDC.deploy();
  await testUsdc.waitForDeployment();

  const testUsdcAddress = await testUsdc.getAddress();
  console.log("TestUSDC deployed to:", testUsdcAddress);

  // Verify deployment
  const name = await testUsdc.name();
  const symbol = await testUsdc.symbol();
  const decimals = await testUsdc.decimals();
  const totalSupply = await testUsdc.totalSupply();
  const deployerBalance = await testUsdc.balanceOf(deployer.address);

  console.log("\nToken Details:");
  console.log(`  Name: ${name}`);
  console.log(`  Symbol: ${symbol}`);
  console.log(`  Decimals: ${decimals}`);
  console.log(`  Total Supply: ${ethers.formatUnits(totalSupply, decimals)} ${symbol}`);
  console.log(`  Deployer Balance: ${ethers.formatUnits(deployerBalance, decimals)} ${symbol}`);

  // Update deployment file
  existingDeployment.contracts.TestUSDC = testUsdcAddress;
  existingDeployment.upgradedAt = new Date().toISOString();

  fs.writeFileSync(deploymentPath, JSON.stringify(existingDeployment, null, 2));
  console.log("\n✓ Updated deployments/fuji.json");

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("🎉 TESTUSDC DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log("\nDeployed Contract:");
  console.log(`  TestUSDC: ${testUsdcAddress}`);
  console.log("\nNext Steps:");
  console.log("1. Run: ./scripts/sync-contract-addresses.sh fuji");
  console.log("2. Fund LBP with TestUSDC for XOM/TestUSDC pair");
  console.log("3. Create AMM pool with XOM/TestUSDC liquidity");
  console.log("4. Users can call faucet() to get 10,000 TestUSDC");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
