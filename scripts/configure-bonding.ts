import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Configure OmniBonding for Protocol-Owned Liquidity
 *
 * This script configures the OmniBonding contract with:
 * - TestUSDC as a bondable asset (5% discount, 7-day vesting)
 * - XOM tokens deposited for bond distribution
 *
 * Usage:
 *   npx hardhat run scripts/configure-bonding.ts --network omnicoinFuji
 *
 * Environment variables (optional):
 *   DISCOUNT_BPS=500         # 5% discount (default)
 *   VESTING_DAYS=7           # 7 days vesting (default)
 *   DAILY_CAPACITY=100000    # 100K USDC daily capacity (default)
 *   XOM_DEPOSIT=500000       # 500K XOM to deposit (default)
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

const BONDING_ABI = [
  "function addBondAsset(address asset, uint8 decimals, uint256 discountBps, uint256 vestingPeriod, uint256 dailyCapacity) external",
  "function updateBondTerms(address asset, uint256 discountBps, uint256 vestingPeriod, uint256 dailyCapacity) external",
  "function depositXom(uint256 amount) external",
  "function setXomPrice(uint256 newPrice) external",
  "function setBondAssetEnabled(address asset, bool enabled) external",
  "function getBondTerms(address asset) external view returns (bool enabled, uint256 discountBps, uint256 vestingPeriod, uint256 dailyCapacity, uint256 dailyRemaining)",
  "function getBondAssets() external view returns (address[])",
  "function calculateBondOutput(address asset, uint256 amount) external view returns (uint256 xomOut, uint256 effectivePrice)",
  "function xom() external view returns (address)",
  "function treasury() external view returns (address)",
  "function fixedXomPrice() external view returns (uint256)",
  "function totalXomDistributed() external view returns (uint256)",
  "function totalValueReceived() external view returns (uint256)",
];

async function main(): Promise<void> {
  console.log("=".repeat(60));
  console.log("CONFIGURING OMNIBONDING FOR PROTOCOL-OWNED LIQUIDITY");
  console.log("=".repeat(60));

  const [deployer] = await ethers.getSigners();
  console.log("\nDeployer:", deployer.address);

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;

  const xomAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;
  // OmniBonding is at top level of contracts, not inside rwa
  const bondingAddress = deployment.contracts.OmniBonding as string;

  console.log("\nContract Addresses:");
  console.log("  XOM:", xomAddress);
  console.log("  TestUSDC:", testUsdcAddress);
  console.log("  OmniBonding:", bondingAddress);

  if (!bondingAddress || bondingAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("OmniBonding not deployed. Run deploy-rwa.ts first.");
  }

  // Create contract instances
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);
  const bonding = new ethers.Contract(bondingAddress, BONDING_ABI, deployer);

  // Configuration parameters
  const discountBps = parseInt(process.env.DISCOUNT_BPS ?? "500");       // 5% discount
  const vestingDays = parseInt(process.env.VESTING_DAYS ?? "7");         // 7 days
  const vestingPeriod = vestingDays * 24 * 60 * 60;                       // Convert to seconds
  const dailyCapacity = ethers.parseUnits(process.env.DAILY_CAPACITY ?? "100000", 6); // 100K USDC
  const xomDeposit = ethers.parseUnits(process.env.XOM_DEPOSIT ?? "500000", 18);     // 500K XOM

  console.log("\nConfiguration:");
  console.log(`  Discount: ${discountBps / 100}%`);
  console.log(`  Vesting Period: ${vestingDays} days`);
  console.log(`  Daily Capacity: ${ethers.formatUnits(dailyCapacity, 6)} USDC`);
  console.log(`  XOM Deposit: ${ethers.formatUnits(xomDeposit, 18)} XOM`);

  // Verify contract state
  console.log("\n" + "=".repeat(60));
  console.log("VERIFYING CONTRACT STATE");
  console.log("=".repeat(60));

  const xomInBonding = await bonding.xom();
  const treasury = await bonding.treasury();
  const currentXomPrice = await bonding.fixedXomPrice();

  console.log("  XOM Token:", xomInBonding);
  console.log("  Treasury:", treasury);
  console.log("  Fixed XOM Price:", ethers.formatUnits(currentXomPrice, 18), "USD");

  // Check if TestUSDC already configured
  const bondAssets = await bonding.getBondAssets();
  const isUsdcConfigured = bondAssets.some(
    (addr: string) => addr.toLowerCase() === testUsdcAddress.toLowerCase()
  );

  if (isUsdcConfigured) {
    console.log("\n  TestUSDC already configured as bond asset");

    const [enabled, currentDiscount, currentVesting, currentCapacity, remaining] =
      await bonding.getBondTerms(testUsdcAddress);

    console.log("  Current Terms:");
    console.log(`    Enabled: ${enabled}`);
    console.log(`    Discount: ${Number(currentDiscount) / 100}%`);
    console.log(`    Vesting: ${Number(currentVesting) / 86400} days`);
    console.log(`    Daily Capacity: ${ethers.formatUnits(currentCapacity, 6)} USDC`);
    console.log(`    Remaining Today: ${ethers.formatUnits(remaining, 6)} USDC`);

    // Update terms if different
    if (
      Number(currentDiscount) !== discountBps ||
      Number(currentVesting) !== vestingPeriod ||
      currentCapacity !== dailyCapacity
    ) {
      console.log("\n  Updating bond terms...");
      const updateTx = await bonding.updateBondTerms(
        testUsdcAddress,
        discountBps,
        vestingPeriod,
        dailyCapacity
      );
      await updateTx.wait();
      console.log("  Terms updated successfully");
    }
  } else {
    // Add TestUSDC as bond asset
    console.log("\n" + "=".repeat(60));
    console.log("ADDING TESTUSDC AS BONDABLE ASSET");
    console.log("=".repeat(60));

    const usdcDecimals = await testUsdc.decimals();
    console.log(`  TestUSDC Decimals: ${usdcDecimals}`);

    console.log("\n  Adding bond asset...");
    const addAssetTx = await bonding.addBondAsset(
      testUsdcAddress,
      usdcDecimals,
      discountBps,
      vestingPeriod,
      dailyCapacity
    );
    await addAssetTx.wait();
    console.log("  TestUSDC added as bondable asset");
  }

  // Check deployer XOM balance and deposit if needed
  console.log("\n" + "=".repeat(60));
  console.log("DEPOSITING XOM FOR BOND DISTRIBUTION");
  console.log("=".repeat(60));

  const deployerXomBalance = await xom.balanceOf(deployer.address);
  const bondingXomBalance = await xom.balanceOf(bondingAddress);

  console.log("  Deployer XOM Balance:", ethers.formatUnits(deployerXomBalance, 18), "XOM");
  console.log("  Bonding Contract XOM:", ethers.formatUnits(bondingXomBalance, 18), "XOM");

  if (bondingXomBalance < xomDeposit) {
    const needed = xomDeposit - bondingXomBalance;

    if (deployerXomBalance < needed) {
      console.log(`\n  WARNING: Insufficient XOM for full deposit`);
      console.log(`    Need: ${ethers.formatUnits(needed, 18)} XOM`);
      console.log(`    Have: ${ethers.formatUnits(deployerXomBalance, 18)} XOM`);

      if (deployerXomBalance > 0n) {
        console.log("\n  Depositing available XOM...");
        const approveTx = await xom.approve(bondingAddress, deployerXomBalance);
        await approveTx.wait();
        const depositTx = await bonding.depositXom(deployerXomBalance);
        await depositTx.wait();
        console.log(`  Deposited ${ethers.formatUnits(deployerXomBalance, 18)} XOM`);
      }
    } else {
      console.log("\n  Approving and depositing XOM...");
      const approveTx = await xom.approve(bondingAddress, needed);
      await approveTx.wait();
      const depositTx = await bonding.depositXom(needed);
      await depositTx.wait();
      console.log(`  Deposited ${ethers.formatUnits(needed, 18)} XOM`);
    }
  } else {
    console.log("\n  Bonding contract has sufficient XOM");
  }

  // Verify final state
  console.log("\n" + "=".repeat(60));
  console.log("FINAL BONDING STATE");
  console.log("=".repeat(60));

  const finalBondingXom = await xom.balanceOf(bondingAddress);
  const [enabled, finalDiscount, finalVesting, finalCapacity, remaining] =
    await bonding.getBondTerms(testUsdcAddress);

  console.log("\nContract XOM Balance:", ethers.formatUnits(finalBondingXom, 18), "XOM");
  console.log("\nTestUSDC Bond Terms:");
  console.log(`  Enabled: ${enabled}`);
  console.log(`  Discount: ${Number(finalDiscount) / 100}%`);
  console.log(`  Vesting: ${Number(finalVesting) / 86400} days`);
  console.log(`  Daily Capacity: ${ethers.formatUnits(finalCapacity, 6)} USDC`);
  console.log(`  Remaining Today: ${ethers.formatUnits(remaining, 6)} USDC`);

  // Calculate example bond output
  const exampleAmount = ethers.parseUnits("100", 6); // 100 USDC
  const [xomOut, effectivePrice] = await bonding.calculateBondOutput(testUsdcAddress, exampleAmount);

  console.log("\nExample Bond (100 USDC):");
  console.log(`  XOM Output: ${ethers.formatUnits(xomOut, 18)} XOM`);
  console.log(`  Effective Price: $${ethers.formatUnits(effectivePrice, 18)}/XOM`);
  console.log(`  Market Price: $${ethers.formatUnits(currentXomPrice, 18)}/XOM`);
  console.log(`  Discount: ${discountBps / 100}%`);

  console.log("\n" + "=".repeat(60));
  console.log("OMNIBONDING CONFIGURED SUCCESSFULLY");
  console.log("=".repeat(60));
  console.log("\nNext Steps:");
  console.log("1. Build Validator: cd ../Validator && npm run build");
  console.log("2. Restart Validator: sudo systemctl restart omnicoin-validator");
  console.log("3. Test bonding via API: curl http://localhost:3001/api/v1/bonding/status");
  console.log("4. Configure LiquidityMining rewards");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Configuration failed:", error);
    process.exit(1);
  });
