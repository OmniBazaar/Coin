import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Configures LiquidityBootstrappingPool and seeds initial liquidity
 *
 * LBP Parameters:
 * - Duration: 7 days
 * - Starting weights: 90% XOM / 10% TestUSDC
 * - Ending weights: 30% XOM / 70% TestUSDC
 * - Initial liquidity: 1,000,000 XOM + 10,000 TestUSDC
 * - This gives initial price of ~$0.001 per XOM, ending at ~$0.023 per XOM
 *
 * Network: omnicoinFuji (Chain ID: 131313)
 */

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  [key: string]: unknown;
}

const LBP_ABI = [
  "function configure(uint256 _startTime, uint256 _endTime, uint256 _startWeightXOM, uint256 _endWeightXOM, uint256 _priceFloor, uint256 _maxPurchaseAmount) external",
  "function addLiquidity(uint256 xomAmount, uint256 counterAssetAmount) external",
  "function startTime() external view returns (uint256)",
  "function endTime() external view returns (uint256)",
  "function startWeightXOM() external view returns (uint256)",
  "function endWeightXOM() external view returns (uint256)",
  "function xomReserve() external view returns (uint256)",
  "function counterAssetReserve() external view returns (uint256)",
  "function getStatus() external view returns (uint256, uint256, bool, uint256, uint256, uint256)",
  "function getSpotPrice() external view returns (uint256)",
  "function treasury() external view returns (address)",
  "function owner() external view returns (address)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function main(): Promise<void> {
  console.log("🚀 Starting LBP Configuration\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("Fuji deployment file not found");
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;
  const lbpAddress = deployment.contracts.LiquidityBootstrappingPool as string;
  const xomAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;

  if (!lbpAddress || lbpAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("LBP not deployed. Run deploy-liquidity-infrastructure.ts first");
  }
  if (!testUsdcAddress || testUsdcAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("TestUSDC not deployed. Run deploy-test-usdc.ts first");
  }

  console.log("LBP Address:", lbpAddress);
  console.log("XOM Address:", xomAddress);
  console.log("TestUSDC Address:", testUsdcAddress);

  // Create contract instances
  const lbp = new ethers.Contract(lbpAddress, LBP_ABI, deployer);
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);

  // Check current state
  const currentStartTime = await lbp.startTime();
  console.log("\nCurrent LBP State:");
  console.log("  Start Time:", currentStartTime.toString());

  // Check balances
  const xomBalance = await xom.balanceOf(deployer.address);
  const usdcBalance = await testUsdc.balanceOf(deployer.address);
  console.log("\nDeployer Balances:");
  console.log("  XOM:", ethers.formatUnits(xomBalance, 18), "XOM");
  console.log("  TestUSDC:", ethers.formatUnits(usdcBalance, 6), "TestUSDC");

  // ================================================================
  // Configure LBP Parameters
  // ================================================================

  if (currentStartTime.toString() === "0") {
    console.log("\n=== Configuring LBP ===");

    // LBP Duration: Start now, end in 7 days
    const now = Math.floor(Date.now() / 1000);
    const startTime = now + 60; // Start in 1 minute
    const endTime = startTime + 7 * 24 * 60 * 60; // End in 7 days

    // Weight configuration (basis points, 10000 = 100%)
    const startWeightXOM = 9000; // 90% XOM
    const endWeightXOM = 3000;   // 30% XOM

    // Price floor: $0.0005 per XOM (18 decimals)
    const priceFloor = ethers.parseUnits("0.0005", 18);

    // Max purchase: 100,000 TestUSDC
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
  } else {
    console.log("\n⚠️  LBP already configured, skipping configuration");
    console.log("  Current Start Time:", new Date(Number(currentStartTime) * 1000).toISOString());
  }

  // ================================================================
  // Add Initial Liquidity
  // ================================================================

  const currentXomReserve = await lbp.xomReserve();
  const currentUsdcReserve = await lbp.counterAssetReserve();

  if (currentXomReserve.toString() === "0") {
    console.log("\n=== Adding Initial Liquidity ===");

    // Initial liquidity amounts
    const xomAmount = ethers.parseUnits("1000000", 18);    // 1 million XOM
    const usdcAmount = ethers.parseUnits("10000", 6);       // 10,000 TestUSDC

    console.log(`Adding: ${ethers.formatUnits(xomAmount, 18)} XOM + ${ethers.formatUnits(usdcAmount, 6)} TestUSDC`);

    // Check balances are sufficient
    if (xomBalance < xomAmount) {
      throw new Error(`Insufficient XOM balance. Have: ${ethers.formatUnits(xomBalance, 18)}, Need: ${ethers.formatUnits(xomAmount, 18)}`);
    }
    if (usdcBalance < usdcAmount) {
      throw new Error(`Insufficient TestUSDC balance. Have: ${ethers.formatUnits(usdcBalance, 6)}, Need: ${ethers.formatUnits(usdcAmount, 6)}`);
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
  } else {
    console.log("\n⚠️  LBP already has liquidity");
    console.log("  XOM Reserve:", ethers.formatUnits(currentXomReserve, 18), "XOM");
    console.log("  USDC Reserve:", ethers.formatUnits(currentUsdcReserve, 6), "TestUSDC");
  }

  // ================================================================
  // Display Final Status
  // ================================================================

  console.log("\n=== LBP Final Status ===");

  const [
    finalStartTime,
    finalEndTime,
    isActive,
    totalRaised,
    totalDistributed,
    currentPrice
  ] = await lbp.getStatus();

  const finalXomReserve = await lbp.xomReserve();
  const finalUsdcReserve = await lbp.counterAssetReserve();

  console.log(`Start Time: ${new Date(Number(finalStartTime) * 1000).toISOString()}`);
  console.log(`End Time: ${new Date(Number(finalEndTime) * 1000).toISOString()}`);
  console.log(`Is Active: ${isActive}`);
  console.log(`XOM Reserve: ${ethers.formatUnits(finalXomReserve, 18)} XOM`);
  console.log(`TestUSDC Reserve: ${ethers.formatUnits(finalUsdcReserve, 6)} TestUSDC`);
  console.log(`Current Price: $${ethers.formatUnits(currentPrice, 18)} per XOM`);
  console.log(`Total Raised: ${ethers.formatUnits(totalRaised, 6)} TestUSDC`);
  console.log(`Total Distributed: ${ethers.formatUnits(totalDistributed, 18)} XOM`);

  console.log("\n" + "=".repeat(60));
  console.log("🎉 LBP CONFIGURATION COMPLETE");
  console.log("=".repeat(60));
  console.log("\nNext Steps:");
  console.log("1. Wait for startTime to begin trading");
  console.log("2. Users can swap TestUSDC for XOM via swap()");
  console.log("3. Create LBPService in Validator to wrap contract calls");
  console.log("4. Connect ExchangePage to LBPService");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Configuration failed:", error);
    process.exit(1);
  });
