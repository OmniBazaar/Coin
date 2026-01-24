import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Redeploys LiquidityBootstrappingPool with TestUSDC as counter-asset
 *
 * The original LBP was deployed with OmniCoin as both XOM and counter-asset
 * (a placeholder). This script redeploys with proper XOM/TestUSDC configuration.
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 */

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  [key: string]: unknown;
}

async function main(): Promise<void> {
  console.log("🚀 Redeploying LiquidityBootstrappingPool with TestUSDC\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "native tokens\n");

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("Fuji deployment file not found");
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;

  const omniCoinAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;

  if (!testUsdcAddress || testUsdcAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("TestUSDC not deployed. Run deploy-test-usdc.ts first");
  }

  console.log("OmniCoin (XOM):", omniCoinAddress);
  console.log("TestUSDC:", testUsdcAddress);

  // Treasury address - deployer for testnet
  const treasuryAddress = deployer.address;
  console.log("Treasury:", treasuryAddress);

  // ================================================================
  // Deploy new LiquidityBootstrappingPool with TestUSDC
  // ================================================================
  console.log("\n=== Deploying New LiquidityBootstrappingPool ===");

  const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
  const lbp = await LBP.deploy(
    omniCoinAddress,     // XOM token
    testUsdcAddress,     // Counter-asset (TestUSDC)
    6,                   // TestUSDC has 6 decimals
    treasuryAddress      // Treasury to receive raised funds
  );
  await lbp.waitForDeployment();

  const lbpAddress = await lbp.getAddress();
  console.log("New LBP deployed to:", lbpAddress);

  // ================================================================
  // Configure LBP Parameters
  // ================================================================
  console.log("\n=== Configuring LBP ===");

  // LBP Duration: Start in 1 minute, run for 7 days
  const now = Math.floor(Date.now() / 1000);
  const startTime = now + 60;
  const endTime = startTime + 7 * 24 * 60 * 60;

  // Weight configuration (basis points, 10000 = 100%)
  const startWeightXOM = 9000; // 90% XOM
  const endWeightXOM = 3000;   // 30% XOM

  // Price floor: $0.0005 per XOM (18 decimals)
  const priceFloor = ethers.parseUnits("0.0005", 18);

  // Max purchase: 100,000 TestUSDC (6 decimals)
  const maxPurchaseAmount = ethers.parseUnits("100000", 6);

  console.log("Parameters:");
  console.log(`  Start Time: ${new Date(startTime * 1000).toISOString()}`);
  console.log(`  End Time: ${new Date(endTime * 1000).toISOString()}`);
  console.log(`  Start Weight XOM: ${startWeightXOM / 100}%`);
  console.log(`  End Weight XOM: ${endWeightXOM / 100}%`);
  console.log(`  Price Floor: $${ethers.formatUnits(priceFloor, 18)}`);
  console.log(`  Max Purchase: ${ethers.formatUnits(maxPurchaseAmount, 6)} TestUSDC`);

  const configureTx = await lbp.configure(
    startTime,
    endTime,
    startWeightXOM,
    endWeightXOM,
    priceFloor,
    maxPurchaseAmount
  );
  await configureTx.wait();
  console.log("✓ LBP configured");

  // ================================================================
  // Add Initial Liquidity
  // ================================================================
  console.log("\n=== Adding Initial Liquidity ===");

  const xomAmount = ethers.parseUnits("1000000", 18);   // 1 million XOM
  const usdcAmount = ethers.parseUnits("10000", 6);     // 10,000 TestUSDC

  console.log(`Adding: ${ethers.formatUnits(xomAmount, 18)} XOM + ${ethers.formatUnits(usdcAmount, 6)} TestUSDC`);

  // Get token contracts
  const xom = await ethers.getContractAt("IERC20", omniCoinAddress);
  const testUsdc = await ethers.getContractAt("IERC20", testUsdcAddress);

  // Check balances
  const xomBalance = await xom.balanceOf(deployer.address);
  const usdcBalance = await testUsdc.balanceOf(deployer.address);
  console.log(`Deployer XOM balance: ${ethers.formatUnits(xomBalance, 18)}`);
  console.log(`Deployer TestUSDC balance: ${ethers.formatUnits(usdcBalance, 6)}`);

  if (xomBalance < xomAmount) {
    throw new Error(`Insufficient XOM balance`);
  }
  if (usdcBalance < usdcAmount) {
    throw new Error(`Insufficient TestUSDC balance`);
  }

  // Approve tokens
  console.log("Approving XOM...");
  const approveXomTx = await xom.approve(lbpAddress, xomAmount);
  await approveXomTx.wait();

  console.log("Approving TestUSDC...");
  const approveUsdcTx = await testUsdc.approve(lbpAddress, usdcAmount);
  await approveUsdcTx.wait();

  // Add liquidity
  console.log("Adding liquidity...");
  const addLiquidityTx = await lbp.addLiquidity(xomAmount, usdcAmount);
  await addLiquidityTx.wait();
  console.log("✓ Liquidity added");

  // ================================================================
  // Update Deployment File
  // ================================================================
  console.log("\n=== Updating Deployment File ===");

  deployment.contracts.LiquidityBootstrappingPool = lbpAddress;
  deployment.upgradedAt = new Date().toISOString();

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✓ Updated deployments/fuji.json");

  // ================================================================
  // Verify Final Status
  // ================================================================
  console.log("\n=== Final LBP Status ===");

  console.log("Counter Asset:", await lbp.counterAsset());
  console.log("Counter Asset Decimals:", (await lbp.counterAssetDecimals()).toString());
  console.log("XOM Reserve:", ethers.formatUnits(await lbp.xomReserve(), 18), "XOM");
  console.log("USDC Reserve:", ethers.formatUnits(await lbp.counterAssetReserve(), 6), "TestUSDC");
  console.log("Spot Price:", ethers.formatUnits(await lbp.getSpotPrice(), 18), "per XOM");

  console.log("\n" + "=".repeat(60));
  console.log("🎉 LBP REDEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log("\nNew LBP Address:", lbpAddress);
  console.log("\nNext Steps:");
  console.log("1. Run: ./scripts/sync-contract-addresses.sh fuji");
  console.log("2. Wait for startTime to begin trading");
  console.log("3. Create LBPService in Validator");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Redeployment failed:", error);
    process.exit(1);
  });
