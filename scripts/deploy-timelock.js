/**
 * Deploy TimelockController for OmniBazaar governance
 *
 * Deploys an OpenZeppelin TimelockController with a 72-hour minimum delay.
 * This contract gates all admin actions — role grants, contract upgrades,
 * parameter changes — giving users time to exit before hostile changes.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-timelock.js --network localhost
 *   npx hardhat run scripts/deploy-timelock.js --network omnicoinFuji
 *
 * After deployment:
 *   1. Run transfer-admin-to-timelock.js to migrate admin roles
 *   2. Grant PROPOSER_ROLE to governance contract (when ready)
 *   3. Grant EXECUTOR_ROLE to multisig (when ready)
 *   4. Revoke deployer's PROPOSER/EXECUTOR roles
 */
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying TimelockController with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "native tokens");

  // 72-hour delay (in seconds)
  const MIN_DELAY = 3 * 24 * 60 * 60; // 259200 seconds = 72 hours
  console.log(`Minimum delay: ${MIN_DELAY} seconds (${MIN_DELAY / 3600} hours)`);

  // Initial setup: deployer is both proposer and executor
  // These roles will be transferred to governance/multisig after launch
  const proposers = [deployer.address];
  const executors = [deployer.address];

  // admin = address(0) means the timelock is self-governing
  // Only the timelock itself can grant/revoke roles after deployment
  const admin = ethers.ZeroAddress;

  console.log("\nDeploying TimelockController...");
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockController.deploy(
    MIN_DELAY,
    proposers,
    executors,
    admin
  );
  await timelock.waitForDeployment();

  const timelockAddress = await timelock.getAddress();
  console.log("TimelockController deployed to:", timelockAddress);

  // Verify roles
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
  const TIMELOCK_ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();

  console.log("\nRole verification:");
  console.log("  Deployer has PROPOSER_ROLE:", await timelock.hasRole(PROPOSER_ROLE, deployer.address));
  console.log("  Deployer has EXECUTOR_ROLE:", await timelock.hasRole(EXECUTOR_ROLE, deployer.address));
  console.log("  Timelock self-admin:", await timelock.hasRole(TIMELOCK_ADMIN_ROLE, timelockAddress));
  console.log("  Deployer has ADMIN_ROLE:", await timelock.hasRole(TIMELOCK_ADMIN_ROLE, deployer.address));

  // Log deployment summary
  console.log("\n========================================");
  console.log("  DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("  TimelockController:", timelockAddress);
  console.log("  Minimum Delay:     72 hours");
  console.log("  Admin:             Self-governing (address(0))");
  console.log("  Proposers:         [deployer] (temporary)");
  console.log("  Executors:         [deployer] (temporary)");
  console.log("========================================");
  console.log("\nNext steps:");
  console.log("  1. Run: npx hardhat run scripts/transfer-admin-to-timelock.js --network <network>");
  console.log("  2. After governance contract is deployed, grant PROPOSER_ROLE to it");
  console.log("  3. After multisig is deployed, grant EXECUTOR_ROLE to it");
  console.log("  4. Revoke deployer's PROPOSER and EXECUTOR roles");
  console.log("  5. Update Coin/deployments/<network>.json with TimelockController address");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
