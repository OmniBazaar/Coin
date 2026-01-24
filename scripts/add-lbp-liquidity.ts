import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Add additional liquidity to the LBP
 *
 * Usage:
 *   npx hardhat run scripts/add-lbp-liquidity.ts --network omnicoinFuji
 *
 * Set amounts via environment variables:
 *   XOM_AMOUNT=100000000 USDC_AMOUNT=0 npx hardhat run scripts/add-lbp-liquidity.ts --network omnicoinFuji
 *
 * Defaults to adding 100 million XOM (no additional USDC)
 */

// Amount in whole tokens (not wei)
const DEFAULT_XOM_AMOUNT = process.env.XOM_AMOUNT ?? "100000000";  // 100 million XOM
const DEFAULT_USDC_AMOUNT = process.env.USDC_AMOUNT ?? "0";        // No additional USDC

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  [key: string]: unknown;
}

const LBP_ABI = [
  "function addLiquidity(uint256 xomAmount, uint256 counterAssetAmount) external",
  "function xomReserve() external view returns (uint256)",
  "function counterAssetReserve() external view returns (uint256)",
  "function getStatus() external view returns (uint256, uint256, bool, uint256, uint256, uint256)",
  "function getSpotPrice() external view returns (uint256)",
  "function finalized() external view returns (bool)",
  "function owner() external view returns (address)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)",
];

async function main(): Promise<void> {
  const xomAmount = DEFAULT_XOM_AMOUNT;
  const usdcAmount = DEFAULT_USDC_AMOUNT;

  console.log("🚀 Adding Liquidity to LBP\n");

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

  console.log("LBP Address:", lbpAddress);
  console.log("XOM Address:", xomAddress);
  console.log("TestUSDC Address:", testUsdcAddress);

  // Create contract instances
  const lbp = new ethers.Contract(lbpAddress, LBP_ABI, deployer);
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);

  // Check owner
  const owner = await lbp.owner();
  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(`Not the LBP owner. Owner: ${owner}, Deployer: ${deployer.address}`);
  }

  // Check if finalized
  const finalized = await lbp.finalized();
  if (finalized) {
    throw new Error("LBP has already been finalized. Cannot add liquidity.");
  }

  // Check current reserves
  const currentXomReserve = await lbp.xomReserve();
  const currentUsdcReserve = await lbp.counterAssetReserve();
  console.log("\nCurrent LBP Reserves:");
  console.log(`  XOM: ${ethers.formatUnits(currentXomReserve, 18)} XOM`);
  console.log(`  TestUSDC: ${ethers.formatUnits(currentUsdcReserve, 6)} TestUSDC`);

  // Check deployer balances
  const xomBalance = await xom.balanceOf(deployer.address);
  const usdcBalance = await testUsdc.balanceOf(deployer.address);
  console.log("\nDeployer Balances:");
  console.log(`  XOM: ${ethers.formatUnits(xomBalance, 18)} XOM`);
  console.log(`  TestUSDC: ${ethers.formatUnits(usdcBalance, 6)} TestUSDC`);

  // Parse amounts
  const xomAmountWei = ethers.parseUnits(xomAmount, 18);
  const usdcAmountWei = ethers.parseUnits(usdcAmount, 6);

  console.log("\nAdding:");
  console.log(`  XOM: ${xomAmount} XOM`);
  console.log(`  TestUSDC: ${usdcAmount} TestUSDC`);

  // Check sufficient balances
  if (xomBalance < xomAmountWei) {
    throw new Error(`Insufficient XOM balance. Have: ${ethers.formatUnits(xomBalance, 18)}, Need: ${xomAmount}`);
  }
  if (usdcBalance < usdcAmountWei) {
    throw new Error(`Insufficient TestUSDC balance. Have: ${ethers.formatUnits(usdcBalance, 6)}, Need: ${usdcAmount}`);
  }

  // Approve tokens if needed
  if (xomAmountWei > 0n) {
    console.log("\nApproving XOM...");
    const approveXomTx = await xom.approve(lbpAddress, xomAmountWei);
    await approveXomTx.wait();
    console.log("✓ XOM approved");
  }

  if (usdcAmountWei > 0n) {
    console.log("Approving TestUSDC...");
    const approveUsdcTx = await testUsdc.approve(lbpAddress, usdcAmountWei);
    await approveUsdcTx.wait();
    console.log("✓ TestUSDC approved");
  }

  // Add liquidity
  console.log("\nAdding liquidity...");
  const addLiquidityTx = await lbp.addLiquidity(xomAmountWei, usdcAmountWei);
  const receipt = await addLiquidityTx.wait();
  console.log("✓ Liquidity added in block:", receipt?.blockNumber);
  console.log("  Transaction hash:", addLiquidityTx.hash);

  // Display final status
  console.log("\n=== LBP Status After Adding Liquidity ===");

  const newXomReserve = await lbp.xomReserve();
  const newUsdcReserve = await lbp.counterAssetReserve();
  const spotPrice = await lbp.getSpotPrice();

  console.log(`XOM Reserve: ${ethers.formatUnits(newXomReserve, 18)} XOM`);
  console.log(`TestUSDC Reserve: ${ethers.formatUnits(newUsdcReserve, 6)} TestUSDC`);
  console.log(`Current Spot Price: $${ethers.formatUnits(spotPrice, 18)} per XOM`);

  // Calculate approximate pool value
  const xomValueUsd = Number(ethers.formatUnits(newXomReserve, 18)) * 0.005; // At $0.005/XOM
  const usdcValueUsd = Number(ethers.formatUnits(newUsdcReserve, 6));
  console.log(`\nApproximate Pool Value (at $0.005/XOM):`);
  console.log(`  XOM value: $${xomValueUsd.toLocaleString()}`);
  console.log(`  USDC value: $${usdcValueUsd.toLocaleString()}`);
  console.log(`  Total: $${(xomValueUsd + usdcValueUsd).toLocaleString()}`);

  console.log("\n✅ Successfully added liquidity to LBP");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Add liquidity failed:", error);
    process.exit(1);
  });
