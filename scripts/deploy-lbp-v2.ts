import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy a new LBP with Option C parameters:
 * - 10,000,000 XOM
 * - 20,000 USDC
 * - Starting price: ~$0.018/XOM
 * - Ending price (no buys): ~$0.003/XOM
 *
 * This creates a proper Dutch auction where price starts HIGH and decreases.
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
];

const LBP_ABI = [
  "function configure(uint256 _startTime, uint256 _endTime, uint256 _startWeightXOM, uint256 _endWeightXOM, uint256 _priceFloor, uint256 _maxPurchaseAmount) external",
  "function addLiquidity(uint256 xomAmount, uint256 counterAssetAmount) external",
  "function startTime() external view returns (uint256)",
  "function endTime() external view returns (uint256)",
  "function xomReserve() external view returns (uint256)",
  "function counterAssetReserve() external view returns (uint256)",
  "function getSpotPrice() external view returns (uint256)",
  "function finalized() external view returns (bool)",
  "function owner() external view returns (address)",
];

async function main(): Promise<void> {
  console.log("=" .repeat(60));
  console.log("🚀 DEPLOYING NEW LBP WITH OPTION C PARAMETERS");
  console.log("=" .repeat(60));

  const [deployer] = await ethers.getSigners();
  console.log("\nDeployer:", deployer.address);

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;

  const xomAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;
  const oldLbpAddress = deployment.contracts.LiquidityBootstrappingPool as string;

  console.log("\nExisting Contracts:");
  console.log("  XOM:", xomAddress);
  console.log("  TestUSDC:", testUsdcAddress);
  console.log("  Old LBP:", oldLbpAddress);

  // Check old LBP status
  const oldLbp = new ethers.Contract(oldLbpAddress, LBP_ABI, deployer);
  const oldXomReserve = await oldLbp.xomReserve();
  const oldUsdcReserve = await oldLbp.counterAssetReserve();
  console.log("\nOld LBP Status:");
  console.log("  XOM Reserve:", ethers.formatUnits(oldXomReserve, 18), "XOM");
  console.log("  USDC Reserve:", ethers.formatUnits(oldUsdcReserve, 6), "USDC");
  console.log("  (Old LBP funds are locked until endTime - will be recovered via finalize())");

  // Create token instances
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);

  // Check deployer balances
  const xomBalance = await xom.balanceOf(deployer.address);
  const usdcBalance = await testUsdc.balanceOf(deployer.address);
  console.log("\nDeployer Balances:");
  console.log("  XOM:", ethers.formatUnits(xomBalance, 18), "XOM");
  console.log("  TestUSDC:", ethers.formatUnits(usdcBalance, 6), "USDC");

  // Option C parameters
  const XOM_AMOUNT = ethers.parseUnits("10000000", 18);    // 10 million XOM
  const USDC_AMOUNT = ethers.parseUnits("20000", 6);       // 20,000 USDC

  // Check sufficient balances
  if (xomBalance < XOM_AMOUNT) {
    throw new Error(`Insufficient XOM. Have: ${ethers.formatUnits(xomBalance, 18)}, Need: 10,000,000`);
  }
  if (usdcBalance < USDC_AMOUNT) {
    throw new Error(`Insufficient USDC. Have: ${ethers.formatUnits(usdcBalance, 6)}, Need: 20,000`);
  }

  // Deploy new LBP
  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYING NEW LBP CONTRACT");
  console.log("=".repeat(60));

  const LBPFactory = await ethers.getContractFactory("LiquidityBootstrappingPool");
  const newLbp = await LBPFactory.deploy(
    xomAddress,           // XOM token
    testUsdcAddress,      // Counter asset (TestUSDC)
    6,                    // USDC decimals
    deployer.address      // Treasury (deployer for now)
  );
  await newLbp.waitForDeployment();
  const newLbpAddress = await newLbp.getAddress();
  console.log("✓ New LBP deployed at:", newLbpAddress);

  // Configure LBP parameters
  console.log("\n" + "=".repeat(60));
  console.log("CONFIGURING LBP PARAMETERS");
  console.log("=".repeat(60));

  const now = Math.floor(Date.now() / 1000);
  const startTime = now + 120;                    // Start in 2 minutes
  const endTime = startTime + 7 * 24 * 60 * 60;   // 7 days duration

  // Weight configuration (basis points, 10000 = 100%)
  const startWeightXOM = 9000;  // 90% XOM at start (HIGH price)
  const endWeightXOM = 3000;    // 30% XOM at end (lower price)

  // Price floor: $0.001 per XOM (protect against price going too low)
  const priceFloor = ethers.parseUnits("0.001", 18);

  // Max purchase: 50,000 USDC per transaction (anti-whale)
  const maxPurchaseAmount = ethers.parseUnits("50000", 6);

  console.log("Parameters:");
  console.log(`  Start Time: ${new Date(startTime * 1000).toISOString()}`);
  console.log(`  End Time: ${new Date(endTime * 1000).toISOString()}`);
  console.log(`  Duration: 7 days`);
  console.log(`  Start Weights: ${startWeightXOM/100}% XOM / ${(10000-startWeightXOM)/100}% USDC`);
  console.log(`  End Weights: ${endWeightXOM/100}% XOM / ${(10000-endWeightXOM)/100}% USDC`);
  console.log(`  Price Floor: $${ethers.formatUnits(priceFloor, 18)}`);
  console.log(`  Max Purchase: ${ethers.formatUnits(maxPurchaseAmount, 6)} USDC`);

  const configureTx = await newLbp.configure(
    startTime,
    endTime,
    startWeightXOM,
    endWeightXOM,
    priceFloor,
    maxPurchaseAmount
  );
  await configureTx.wait();
  console.log("✓ LBP configured");

  // Add liquidity
  console.log("\n" + "=".repeat(60));
  console.log("ADDING LIQUIDITY");
  console.log("=".repeat(60));

  console.log(`Adding: ${ethers.formatUnits(XOM_AMOUNT, 18)} XOM + ${ethers.formatUnits(USDC_AMOUNT, 6)} USDC`);

  // Approve tokens
  console.log("Approving XOM...");
  const approveXomTx = await xom.approve(newLbpAddress, XOM_AMOUNT);
  await approveXomTx.wait();

  console.log("Approving USDC...");
  const approveUsdcTx = await testUsdc.approve(newLbpAddress, USDC_AMOUNT);
  await approveUsdcTx.wait();

  // Add liquidity
  console.log("Adding liquidity to LBP...");
  const addLiqTx = await newLbp.addLiquidity(XOM_AMOUNT, USDC_AMOUNT);
  await addLiqTx.wait();
  console.log("✓ Liquidity added");

  // Verify final state
  console.log("\n" + "=".repeat(60));
  console.log("FINAL LBP STATUS");
  console.log("=".repeat(60));

  const finalXomReserve = await newLbp.xomReserve();
  const finalUsdcReserve = await newLbp.counterAssetReserve();
  const spotPrice = await newLbp.getSpotPrice();

  console.log(`XOM Reserve: ${ethers.formatUnits(finalXomReserve, 18)} XOM`);
  console.log(`USDC Reserve: ${ethers.formatUnits(finalUsdcReserve, 6)} USDC`);
  console.log(`Starting Spot Price: $${ethers.formatUnits(spotPrice, 18)} per XOM`);

  // Calculate expected end price (if no trades)
  // Price = (USDC / USDC_weight) / (XOM / XOM_weight)
  // At end: (20000 / 0.70) / (10000000 / 0.30) = 28571 / 33333333 = 0.000857
  const expectedEndPrice = (20000 / 0.70) / (10000000 / 0.30);
  console.log(`Expected End Price (no trades): $${expectedEndPrice.toFixed(6)} per XOM`);

  // Calculate price at target ($0.005)
  console.log(`\nPrice Comparison:`);
  console.log(`  Starting Price: $${ethers.formatUnits(spotPrice, 18)} (${(Number(ethers.formatUnits(spotPrice, 18)) / 0.005 * 100).toFixed(0)}% of target)`);
  console.log(`  Target Price: $0.005`);
  console.log(`  End Price (no trades): $${expectedEndPrice.toFixed(6)} (${(expectedEndPrice / 0.005 * 100).toFixed(0)}% of target)`);

  // Update deployment file
  console.log("\n" + "=".repeat(60));
  console.log("UPDATING DEPLOYMENT FILE");
  console.log("=".repeat(60));

  // Keep old LBP address for reference
  deployment.contracts.LiquidityBootstrappingPoolV1 = oldLbpAddress;
  deployment.contracts.LiquidityBootstrappingPool = newLbpAddress;
  deployment.deployedAt = new Date().toISOString();

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✓ Updated fuji.json with new LBP address");

  console.log("\n" + "=".repeat(60));
  console.log("🎉 LBP V2 DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log(`\nNew LBP Address: ${newLbpAddress}`);
  console.log(`Old LBP Address: ${oldLbpAddress} (funds locked, finalize after endTime)`);
  console.log(`\nLBP will be active from:`);
  console.log(`  Start: ${new Date(startTime * 1000).toISOString()}`);
  console.log(`  End: ${new Date(endTime * 1000).toISOString()}`);
  console.log("\nNext Steps:");
  console.log("1. Wait ~2 minutes for LBP to start");
  console.log("2. Test swapping USDC → XOM on the Exchange page");
  console.log("3. Price should start at ~$0.018 and decrease over 7 days");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
