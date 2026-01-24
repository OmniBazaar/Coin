import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Seed XOM/USDC AMM Pool with Initial Liquidity
 *
 * This script creates a permanent trading pool for XOM/USDC on RWAAMM.
 * Run this AFTER the LBP ends to provide ongoing liquidity.
 *
 * Default configuration:
 * - 1,000,000 XOM
 * - 5,000 USDC
 * - Starting price: ~$0.005/XOM (matches target price)
 *
 * Usage:
 *   npx hardhat run scripts/seed-amm-pool.ts --network omnicoinFuji
 *
 * Environment variables (optional):
 *   XOM_AMOUNT=1000000     # XOM to add (default: 1M)
 *   USDC_AMOUNT=5000       # USDC to add (default: 5K)
 */

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  deployer?: string;
  network?: string;
  chainId?: number;
  deployedAt?: string;
  [key: string]: unknown;
}

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

const RWAAMM_ABI = [
  "function createPool(address token0, address token1) external returns (bytes32 poolId, address poolAddress)",
  "function addLiquidity(address token0, address token1, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external returns (uint256 amount0, uint256 amount1, uint256 liquidity)",
  "function getPool(address token0, address token1) external view returns (address)",
  "function getPoolId(address token0, address token1) external pure returns (bytes32)",
];

const POOL_ABI = [
  "function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
  "function totalSupply() external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
];

async function main(): Promise<void> {
  console.log("=".repeat(60));
  console.log("SEEDING XOM/USDC AMM POOL");
  console.log("=".repeat(60));

  const [deployer] = await ethers.getSigners();
  console.log("\nDeployer:", deployer.address);

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;

  const xomAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;
  const rwaAmmAddress = (deployment.contracts.rwa as Record<string, string>)?.RWAAMM as string;

  console.log("\nContract Addresses:");
  console.log("  XOM:", xomAddress);
  console.log("  TestUSDC:", testUsdcAddress);
  console.log("  RWAAMM:", rwaAmmAddress);

  if (!rwaAmmAddress || rwaAmmAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("RWAAMM not deployed. Run deploy-rwa.ts first.");
  }

  // Create contract instances
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);
  const rwaamm = new ethers.Contract(rwaAmmAddress, RWAAMM_ABI, deployer);

  // Configuration - can be overridden with environment variables
  const xomAmount = ethers.parseUnits(process.env.XOM_AMOUNT ?? "1000000", 18);   // 1M XOM default
  const usdcAmount = ethers.parseUnits(process.env.USDC_AMOUNT ?? "5000", 6);      // 5K USDC default

  console.log("\nPool Configuration:");
  console.log("  XOM Amount:", ethers.formatUnits(xomAmount, 18), "XOM");
  console.log("  USDC Amount:", ethers.formatUnits(usdcAmount, 6), "USDC");
  console.log("  Starting Price:", (Number(usdcAmount) / 1e6) / (Number(xomAmount) / 1e18), "USDC/XOM");

  // Check balances
  const xomBalance = await xom.balanceOf(deployer.address);
  const usdcBalance = await testUsdc.balanceOf(deployer.address);

  console.log("\nDeployer Balances:");
  console.log("  XOM:", ethers.formatUnits(xomBalance, 18), "XOM");
  console.log("  USDC:", ethers.formatUnits(usdcBalance, 6), "USDC");

  if (xomBalance < xomAmount) {
    throw new Error(`Insufficient XOM. Have: ${ethers.formatUnits(xomBalance, 18)}, Need: ${ethers.formatUnits(xomAmount, 18)}`);
  }
  if (usdcBalance < usdcAmount) {
    throw new Error(`Insufficient USDC. Have: ${ethers.formatUnits(usdcBalance, 6)}, Need: ${ethers.formatUnits(usdcAmount, 6)}`);
  }

  // Check if pool already exists
  console.log("\n" + "=".repeat(60));
  console.log("CHECKING EXISTING POOL");
  console.log("=".repeat(60));

  const existingPool = await rwaamm.getPool(xomAddress, testUsdcAddress);
  if (existingPool !== "0x0000000000000000000000000000000000000000") {
    console.log("Pool already exists at:", existingPool);

    // Get existing reserves
    const pool = new ethers.Contract(existingPool, POOL_ABI, deployer);
    const [reserve0, reserve1] = await pool.getReserves();
    const token0 = await pool.token0();

    const isXomToken0 = token0.toLowerCase() === xomAddress.toLowerCase();
    const [xomReserve, usdcReserve] = isXomToken0
      ? [reserve0, reserve1]
      : [reserve1, reserve0];

    console.log("Current Reserves:");
    console.log("  XOM:", ethers.formatUnits(xomReserve, 18), "XOM");
    console.log("  USDC:", ethers.formatUnits(usdcReserve, 6), "USDC");

    if (xomReserve > 0n) {
      const currentPrice = Number(usdcReserve) / 1e6 / (Number(xomReserve) / 1e18);
      console.log("  Current Price:", currentPrice.toFixed(6), "USDC/XOM");
    }

    console.log("\nAdding additional liquidity...");
  } else {
    console.log("No existing pool found. Will create new pool.");
  }

  // Approve tokens for RWAAMM
  console.log("\n" + "=".repeat(60));
  console.log("APPROVING TOKENS");
  console.log("=".repeat(60));

  console.log("Approving XOM...");
  const approveXomTx = await xom.approve(rwaAmmAddress, xomAmount);
  await approveXomTx.wait();
  console.log("  XOM approved");

  console.log("Approving USDC...");
  const approveUsdcTx = await testUsdc.approve(rwaAmmAddress, usdcAmount);
  await approveUsdcTx.wait();
  console.log("  USDC approved");

  // Add liquidity (will create pool if needed)
  console.log("\n" + "=".repeat(60));
  console.log("ADDING LIQUIDITY");
  console.log("=".repeat(60));

  const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

  console.log("Calling addLiquidity...");
  const addLiqTx = await rwaamm.addLiquidity(
    xomAddress,
    testUsdcAddress,
    xomAmount,
    usdcAmount,
    0n, // amount0Min - no slippage protection for seeding
    0n, // amount1Min
    deadline
  );

  const receipt = await addLiqTx.wait();
  console.log("Transaction confirmed:", receipt?.hash);

  // Verify final state
  console.log("\n" + "=".repeat(60));
  console.log("FINAL POOL STATE");
  console.log("=".repeat(60));

  const poolAddress = await rwaamm.getPool(xomAddress, testUsdcAddress);
  console.log("Pool Address:", poolAddress);

  const pool = new ethers.Contract(poolAddress, POOL_ABI, deployer);
  const [finalReserve0, finalReserve1] = await pool.getReserves();
  const token0 = await pool.token0();
  const totalSupply = await pool.totalSupply();
  const deployerLP = await pool.balanceOf(deployer.address);

  const isXomToken0 = token0.toLowerCase() === xomAddress.toLowerCase();
  const [xomReserve, usdcReserve] = isXomToken0
    ? [finalReserve0, finalReserve1]
    : [finalReserve1, finalReserve0];

  const price = Number(usdcReserve) / 1e6 / (Number(xomReserve) / 1e18);

  console.log("\nReserves:");
  console.log("  XOM:", ethers.formatUnits(xomReserve, 18), "XOM");
  console.log("  USDC:", ethers.formatUnits(usdcReserve, 6), "USDC");
  console.log("  Price:", price.toFixed(6), "USDC/XOM");

  console.log("\nLP Tokens:");
  console.log("  Total Supply:", ethers.formatUnits(totalSupply, 18), "LP");
  console.log("  Deployer LP:", ethers.formatUnits(deployerLP, 18), "LP");

  console.log("\n" + "=".repeat(60));
  console.log("AMM POOL SEEDED SUCCESSFULLY");
  console.log("=".repeat(60));
  console.log("\nPool Details:");
  console.log(`  Pool Address: ${poolAddress}`);
  console.log(`  XOM/USDC Price: $${price.toFixed(6)}`);
  console.log(`  Total Liquidity: $${(Number(usdcReserve) / 1e6 * 2).toFixed(2)} TVL`);
  console.log("\nNext Steps:");
  console.log("1. Configure OmniBonding for protocol-owned liquidity");
  console.log("2. Configure LiquidityMining for LP rewards");
  console.log("3. Test swap functionality via ExchangePage");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Seeding failed:", error);
    process.exit(1);
  });
