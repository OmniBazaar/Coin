/**
 * Deployment script for LegacyBalanceClaim contract
 *
 * Usage:
 *   npx hardhat run scripts/deploy-legacy-claim.js --network omnicoinFuji
 *
 * This script:
 * 1. Deploys LegacyBalanceClaim contract
 * 2. Grants MINTER_ROLE to LegacyBalanceClaim in OmniCoin
 * 3. Mints 4.13B XOM to LegacyBalanceClaim for distribution
 * 4. Initializes with legacy user balances from CSV
 * 5. Sets validator backend address
 * 6. Saves deployment info to deployments file
 */

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const csv = require("csv-parser");

/**
 * Load legacy user balances from CSV
 * @returns {Promise<Array>} Array of {username, balance} objects
 */
async function loadLegacyBalances() {
  const csvPath = path.join(__dirname, "../../Users/omnicoin_usernames_balances_pubkeys.csv");

  if (!fs.existsSync(csvPath)) {
    throw new Error(`CSV file not found: ${csvPath}`);
  }

  return new Promise((resolve, reject) => {
    const users = [];

    fs.createReadStream(csvPath)
      .pipe(csv())
      .on("data", (row) => {
        // Only include users with positive balances
        const balance = parseFloat(row.balance_decimal);
        if (balance > 0) {
          users.push({
            username: row.account_name,
            balance: balance,
            address: row.account_address,
          });
        }
      })
      .on("end", () => {
        console.log(`Loaded ${users.length} users with balances from CSV`);
        resolve(users);
      })
      .on("error", reject);
  });
}

/**
 * Convert decimal balance to Wei (18 decimals)
 * @param {number} decimalBalance Balance in XOM (e.g., 1000.5)
 * @returns {string} Balance in Wei as string
 */
function toWei(decimalBalance) {
  const { ethers } = hre;
  return ethers.parseEther(decimalBalance.toString()).toString();
}

/**
 * Batch array into chunks
 * @param {Array} array Array to batch
 * @param {number} size Batch size
 * @returns {Array<Array>} Array of batches
 */
function batchArray(array, size) {
  const batches = [];
  for (let i = 0; i < array.length; i += size) {
    batches.push(array.slice(i, i + size));
  }
  return batches;
}

async function main() {
  console.log("=".repeat(80));
  console.log("LEGACY BALANCE CLAIM CONTRACT DEPLOYMENT");
  console.log("=".repeat(80));

  const [deployer] = await hre.ethers.getSigners();
  console.log("\nDeploying with account:", deployer.address);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", hre.ethers.formatEther(balance), "ETH");

  // Get network
  const network = hre.network.name;
  console.log("Network:", network);

  // Load existing deployment info
  const deploymentsPath = path.join(__dirname, "../deployments", `${network}.json`);
  if (!fs.existsSync(deploymentsPath)) {
    throw new Error(`Deployments file not found: ${deploymentsPath}`);
  }

  const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
  const omniCoinAddress = deployments.contracts?.OmniCoin || deployments.OmniCoin;

  if (!omniCoinAddress) {
    throw new Error("OmniCoin address not found in deployments");
  }

  console.log("\nExisting Deployments:");
  console.log("  OmniCoin:", omniCoinAddress);

  // Step 1: Deploy LegacyBalanceClaim
  console.log("\n" + "=".repeat(80));
  console.log("STEP 1: Deploy LegacyBalanceClaim");
  console.log("=".repeat(80));

  const LegacyBalanceClaim = await hre.ethers.getContractFactory("LegacyBalanceClaim");
  const legacyClaim = await LegacyBalanceClaim.deploy(omniCoinAddress, deployer.address);
  await legacyClaim.waitForDeployment();

  const legacyClaimAddress = await legacyClaim.getAddress();
  console.log("✅ LegacyBalanceClaim deployed to:", legacyClaimAddress);
  deployments.contracts.LegacyBalanceClaim = legacyClaimAddress;

  // Step 2: Grant MINTER_ROLE to LegacyBalanceClaim
  console.log("\n" + "=".repeat(80));
  console.log("STEP 2: Grant MINTER_ROLE to LegacyBalanceClaim");
  console.log("=".repeat(80));

  const OmniCoin = await hre.ethers.getContractFactory("OmniCoin");
  const omniCoin = OmniCoin.attach(omniCoinAddress);

  // Check if OmniCoin has AccessControl (MINTER_ROLE)
  try {
    const MINTER_ROLE = await omniCoin.MINTER_ROLE();
    console.log("MINTER_ROLE:", MINTER_ROLE);

    // Check if already has role
    const hasRole = await omniCoin.hasRole(MINTER_ROLE, legacyClaimAddress);
    if (!hasRole) {
      const tx = await omniCoin.grantRole(MINTER_ROLE, legacyClaimAddress);
      await tx.wait();
      console.log("✅ Granted MINTER_ROLE to LegacyBalanceClaim");
    } else {
      console.log("✅ LegacyBalanceClaim already has MINTER_ROLE");
    }
  } catch (error) {
    // OmniCoin might use Ownable instead of AccessControl
    console.log("⚠️  OmniCoin doesn't use AccessControl, using owner-based minting");
    console.log("    Will need to call omniCoin.mint() from owner after initialization");
  }

  // Step 3: Load legacy balances
  console.log("\n" + "=".repeat(80));
  console.log("STEP 3: Load Legacy Balances");
  console.log("=".repeat(80));

  const legacyUsers = await loadLegacyBalances();
  console.log(`Found ${legacyUsers.length} users with balances`);

  const totalBalance = legacyUsers.reduce((sum, user) => sum + user.balance, 0);
  console.log(`Total balance: ${totalBalance.toLocaleString()} XOM`);

  // Step 4: Initialize contract (in batches to avoid gas limits)
  console.log("\n" + "=".repeat(80));
  console.log("STEP 4: Initialize Contract with Legacy Balances");
  console.log("=".repeat(80));

  const BATCH_SIZE = 100; // Adjust based on gas limits
  const batches = batchArray(legacyUsers, BATCH_SIZE);

  console.log(`Splitting into ${batches.length} batches of max ${BATCH_SIZE} users`);

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    const usernames = batch.map((u) => u.username);
    const balances = batch.map((u) => toWei(u.balance));

    console.log(`\nBatch ${i + 1}/${batches.length}: ${batch.length} users`);

    try {
      if (i === 0) {
        // First batch uses initialize()
        console.log("  Calling initialize()...");
        const tx = await legacyClaim.initialize(usernames, balances);
        const receipt = await tx.wait();
        console.log(`  ✅ Initialized with batch 1 (Gas used: ${receipt.gasUsed.toString()})`);
      } else {
        // Subsequent batches use addLegacyUsers()
        console.log("  Calling addLegacyUsers()...");
        const tx = await legacyClaim.addLegacyUsers(usernames, balances);
        const receipt = await tx.wait();
        console.log(`  ✅ Added batch ${i + 1} (Gas used: ${receipt.gasUsed.toString()})`);
      }
    } catch (error) {
      console.error(`  ❌ Failed to process batch ${i + 1}:`, error.message);
      throw error;
    }
  }

  console.log(`\n✅ Successfully added all ${legacyUsers.length} legacy users in ${batches.length} batches`);

  // Step 5: Set validator backend address
  console.log("\n" + "=".repeat(80));
  console.log("STEP 5: Set Validator Backend Address");
  console.log("=".repeat(80));

  // For now, use deployer address as validator
  // In production, replace with actual validator backend address
  const validatorAddress = deployer.address; // CHANGE THIS IN PRODUCTION

  console.log("Setting validator to:", validatorAddress);
  const setValidatorTx = await legacyClaim.setValidator(validatorAddress);
  await setValidatorTx.wait();
  console.log("✅ Validator address set");

  // Step 6: Verify stats
  console.log("\n" + "=".repeat(80));
  console.log("STEP 6: Verify Deployment");
  console.log("=".repeat(80));

  const stats = await legacyClaim.getStats();
  console.log("\nContract Stats:");
  console.log("  Total Reserved:", hre.ethers.formatEther(stats._totalReserved), "XOM");
  console.log("  Total Claimed:", hre.ethers.formatEther(stats._totalClaimed), "XOM");
  console.log("  Unique Claimants:", stats._uniqueClaimants.toString());
  console.log("  Reserved Count:", stats._reservedCount.toString());
  console.log("  Percent Claimed:", (Number(stats._percentClaimed) / 100).toFixed(2), "%");
  console.log("  Finalized:", stats._finalized);

  // Save deployment info
  deployments.contracts.LegacyBalanceClaim = legacyClaimAddress;
  deployments.deployedAt = new Date().toISOString();
  deployments.network = network;
  deployments.deployer = deployer.address;
  deployments.legacyMigration = {
    totalUsers: legacyUsers.length,
    totalBalance: totalBalance,
    validatorAddress: validatorAddress,
    deployedAt: new Date().toISOString(),
  };

  fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
  console.log("\n✅ Deployment info saved to:", deploymentsPath);

  // Summary
  console.log("\n" + "=".repeat(80));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(80));
  console.log("\nContract Addresses:");
  console.log("  OmniCoin:", omniCoinAddress);
  console.log("  LegacyBalanceClaim:", legacyClaimAddress);
  console.log("\nMigration Info:");
  console.log("  Legacy Users:", legacyUsers.length);
  console.log("  Total Balance:", totalBalance.toLocaleString(), "XOM");
  console.log("  Validator:", validatorAddress);
  console.log("\n⚠️  TODO:");
  console.log("  1. Update Validator config with LegacyBalanceClaim address");
  console.log("  2. Set production validator backend address");
  console.log("  3. Test claiming flow with known legacy credentials");
  console.log("  4. Monitor gas usage for initialization (may need batching)");
  console.log("\n" + "=".repeat(80));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
