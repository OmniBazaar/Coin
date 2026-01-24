import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Configure LiquidityMining for LP Reward Distribution
 *
 * This script configures the LiquidityMining contract with:
 * - XOM/USDC LP pool for staking rewards
 * - Initial XOM rewards deposited for distribution
 *
 * Usage:
 *   npx hardhat run scripts/configure-mining.ts --network omnicoinFuji
 *
 * Environment variables (optional):
 *   REWARD_PER_DAY=10000       # XOM rewards per day (default: 10K)
 *   IMMEDIATE_BPS=3000         # 30% immediate rewards (default)
 *   VESTING_DAYS=90            # 90 days vesting (default)
 *   XOM_DEPOSIT=100000         # 100K XOM to deposit (default)
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
  "function symbol() external view returns (string)",
];

const MINING_ABI = [
  "function addPool(address lpToken, uint256 rewardPerSecond, uint256 immediateBps, uint256 vestingPeriod, string calldata name) external",
  "function setRewardRate(uint256 poolId, uint256 newRewardPerSecond) external",
  "function setVestingParams(uint256 poolId, uint256 immediateBps, uint256 vestingPeriod) external",
  "function depositRewards(uint256 amount) external",
  "function poolCount() external view returns (uint256)",
  "function getPoolInfo(uint256 poolId) external view returns (address lpToken, uint256 rewardPerSecond, uint256 totalStaked, bool active, string memory name)",
  "function xom() external view returns (address)",
  "function treasury() external view returns (address)",
  "function totalXomDistributed() external view returns (uint256)",
  "function estimateAPR(uint256 poolId, uint256 lpTokenPrice, uint256 xomPrice) external view returns (uint256)",
];

const RWAAMM_ABI = [
  "function getPool(address token0, address token1) external view returns (address)",
];

async function main(): Promise<void> {
  console.log("=".repeat(60));
  console.log("CONFIGURING LIQUIDITY MINING FOR LP REWARDS");
  console.log("=".repeat(60));

  const [deployer] = await ethers.getSigners();
  console.log("\nDeployer:", deployer.address);

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;

  const xomAddress = deployment.contracts.OmniCoin as string;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;
  // LiquidityMining is at top level of contracts, not inside rwa
  const miningAddress = deployment.contracts.LiquidityMining as string;
  // RWAAMM is inside rwa
  const rwaAmmAddress = (deployment.contracts.rwa as Record<string, string>)?.RWAAMM as string;

  console.log("\nContract Addresses:");
  console.log("  XOM:", xomAddress);
  console.log("  TestUSDC:", testUsdcAddress);
  console.log("  LiquidityMining:", miningAddress);
  console.log("  RWAAMM:", rwaAmmAddress);

  if (!miningAddress || miningAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("LiquidityMining not deployed. Run deploy-rwa.ts first.");
  }

  // Create contract instances
  const xom = new ethers.Contract(xomAddress, ERC20_ABI, deployer);
  const mining = new ethers.Contract(miningAddress, MINING_ABI, deployer);
  const rwaamm = new ethers.Contract(rwaAmmAddress, RWAAMM_ABI, deployer);

  // Configuration parameters
  const rewardPerDay = ethers.parseUnits(process.env.REWARD_PER_DAY ?? "10000", 18);   // 10K XOM/day
  const rewardPerSecond = rewardPerDay / BigInt(86400);                                  // Convert to per-second
  const immediateBps = parseInt(process.env.IMMEDIATE_BPS ?? "3000");                   // 30% immediate
  const vestingDays = parseInt(process.env.VESTING_DAYS ?? "90");                       // 90 days
  const vestingPeriod = vestingDays * 24 * 60 * 60;                                      // Convert to seconds
  const xomDeposit = ethers.parseUnits(process.env.XOM_DEPOSIT ?? "100000", 18);        // 100K XOM

  console.log("\nConfiguration:");
  console.log(`  Rewards/Day: ${ethers.formatUnits(rewardPerDay, 18)} XOM`);
  console.log(`  Rewards/Second: ${ethers.formatUnits(rewardPerSecond, 18)} XOM`);
  console.log(`  Immediate Rewards: ${immediateBps / 100}%`);
  console.log(`  Vesting Period: ${vestingDays} days`);
  console.log(`  XOM Deposit: ${ethers.formatUnits(xomDeposit, 18)} XOM`);

  // Verify contract state
  console.log("\n" + "=".repeat(60));
  console.log("VERIFYING CONTRACT STATE");
  console.log("=".repeat(60));

  const xomInMining = await mining.xom();
  const treasury = await mining.treasury();
  const poolCount = await mining.poolCount();

  console.log("  XOM Token:", xomInMining);
  console.log("  Treasury:", treasury);
  console.log("  Current Pool Count:", poolCount.toString());

  // Get XOM/USDC LP token address from RWAAMM
  console.log("\n" + "=".repeat(60));
  console.log("FINDING XOM/USDC LP TOKEN");
  console.log("=".repeat(60));

  const lpTokenAddress = await rwaamm.getPool(xomAddress, testUsdcAddress);

  if (lpTokenAddress === "0x0000000000000000000000000000000000000000") {
    console.log("\n  WARNING: No XOM/USDC pool exists yet");
    console.log("  Run seed-amm-pool.ts first to create the pool");
    console.log("  Then re-run this script to add the LP pool");
    console.log("=".repeat(60));
    return;
  }

  console.log("  LP Token Address:", lpTokenAddress);

  // Check if pool already exists
  let poolExists = false;
  let existingPoolId = 0;

  for (let i = 0; i < Number(poolCount); i++) {
    const [lpToken, , , active, name] = await mining.getPoolInfo(i);
    console.log(`  Pool ${i}: ${name} (${lpToken})`);
    if (lpToken.toLowerCase() === lpTokenAddress.toLowerCase()) {
      poolExists = true;
      existingPoolId = i;
      console.log(`    Already configured as pool ${i}`);
    }
  }

  if (poolExists) {
    console.log("\n  XOM/USDC pool already configured");

    // Update parameters if different
    const [, currentRewardRate, totalStaked, active] = await mining.getPoolInfo(existingPoolId);

    console.log("  Current Settings:");
    console.log(`    Reward Rate: ${ethers.formatUnits(currentRewardRate, 18)} XOM/second`);
    console.log(`    Total Staked: ${ethers.formatUnits(totalStaked, 18)} LP`);
    console.log(`    Active: ${active}`);

    if (currentRewardRate !== rewardPerSecond) {
      console.log("\n  Updating reward rate...");
      const updateTx = await mining.setRewardRate(existingPoolId, rewardPerSecond);
      await updateTx.wait();
      console.log("  Reward rate updated");
    }
  } else {
    // Add XOM/USDC pool
    console.log("\n" + "=".repeat(60));
    console.log("ADDING XOM/USDC LP POOL");
    console.log("=".repeat(60));

    console.log("\n  Adding pool...");
    const addPoolTx = await mining.addPool(
      lpTokenAddress,
      rewardPerSecond,
      immediateBps,
      vestingPeriod,
      "XOM/USDC LP"
    );
    await addPoolTx.wait();
    console.log("  Pool added successfully");
  }

  // Deposit XOM rewards
  console.log("\n" + "=".repeat(60));
  console.log("DEPOSITING XOM REWARDS");
  console.log("=".repeat(60));

  const deployerXomBalance = await xom.balanceOf(deployer.address);
  const miningXomBalance = await xom.balanceOf(miningAddress);

  console.log("  Deployer XOM Balance:", ethers.formatUnits(deployerXomBalance, 18), "XOM");
  console.log("  Mining Contract XOM:", ethers.formatUnits(miningXomBalance, 18), "XOM");

  if (miningXomBalance < xomDeposit) {
    const needed = xomDeposit - miningXomBalance;

    if (deployerXomBalance < needed) {
      console.log(`\n  WARNING: Insufficient XOM for full deposit`);
      console.log(`    Need: ${ethers.formatUnits(needed, 18)} XOM`);
      console.log(`    Have: ${ethers.formatUnits(deployerXomBalance, 18)} XOM`);

      if (deployerXomBalance > 0n) {
        console.log("\n  Depositing available XOM...");
        const approveTx = await xom.approve(miningAddress, deployerXomBalance);
        await approveTx.wait();
        const depositTx = await mining.depositRewards(deployerXomBalance);
        await depositTx.wait();
        console.log(`  Deposited ${ethers.formatUnits(deployerXomBalance, 18)} XOM`);
      }
    } else {
      console.log("\n  Approving and depositing XOM...");
      const approveTx = await xom.approve(miningAddress, needed);
      await approveTx.wait();
      const depositTx = await mining.depositRewards(needed);
      await depositTx.wait();
      console.log(`  Deposited ${ethers.formatUnits(needed, 18)} XOM`);
    }
  } else {
    console.log("\n  Mining contract has sufficient XOM");
  }

  // Verify final state
  console.log("\n" + "=".repeat(60));
  console.log("FINAL MINING STATE");
  console.log("=".repeat(60));

  const finalPoolCount = await mining.poolCount();
  const finalMiningXom = await xom.balanceOf(miningAddress);
  const totalDistributed = await mining.totalXomDistributed();

  console.log("\nContract XOM Balance:", ethers.formatUnits(finalMiningXom, 18), "XOM");
  console.log("Total XOM Distributed:", ethers.formatUnits(totalDistributed, 18), "XOM");
  console.log("\nConfigured Pools:", finalPoolCount.toString());

  for (let i = 0; i < Number(finalPoolCount); i++) {
    const [lpToken, rewardRate, totalStaked, active, name] = await mining.getPoolInfo(i);
    const dailyRewards = BigInt(rewardRate) * 86400n;

    console.log(`\n  Pool ${i}: ${name}`);
    console.log(`    LP Token: ${lpToken}`);
    console.log(`    Reward Rate: ${ethers.formatUnits(dailyRewards, 18)} XOM/day`);
    console.log(`    Total Staked: ${ethers.formatUnits(totalStaked, 18)} LP`);
    console.log(`    Active: ${active}`);

    // Estimate APR (using placeholder prices)
    const xomPrice = ethers.parseUnits("0.005", 18);  // $0.005/XOM
    const lpPrice = ethers.parseUnits("0.01", 18);    // $0.01/LP (placeholder)
    try {
      const aprBps = await mining.estimateAPR(i, lpPrice, xomPrice);
      console.log(`    Est. APR: ${Number(aprBps) / 100}%`);
    } catch {
      console.log(`    Est. APR: N/A (no stake)`);
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("LIQUIDITY MINING CONFIGURED SUCCESSFULLY");
  console.log("=".repeat(60));
  console.log("\nNext Steps:");
  console.log("1. Build Validator: cd ../Validator && npm run build");
  console.log("2. Restart Validator: sudo systemctl restart omnicoin-validator");
  console.log("3. Test mining via API: curl http://localhost:3001/api/v1/mining/status");
  console.log("4. Users can now stake LP tokens to earn XOM rewards");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Configuration failed:", error);
    process.exit(1);
  });
