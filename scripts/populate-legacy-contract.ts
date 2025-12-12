/**
 * Populate Legacy Balance Claim Contract
 *
 * Loads all legacy users from CSV and populates the LegacyBalanceClaim contract
 * Processes in batches to avoid gas limit issues
 */

import { ethers } from 'hardhat';
import fs from 'fs';
import path from 'path';
import csv from 'csv-parser';

interface LegacyUser {
  accountId: string;
  username: string;
  xomAddress: string;
  balance: number;
  balanceDecimal: number;
  balanceType: string;
}

const BATCH_SIZE = 100; // Process 100 users per transaction
const CSV_PATH = path.join(__dirname, '../../Users/omnicoin_usernames_balances_pubkeys.csv');

/**
 * Load legacy users from CSV file
 */
async function loadLegacyUsers(): Promise<LegacyUser[]> {
  return new Promise((resolve, reject) => {
    const users: LegacyUser[] = [];

    fs.createReadStream(CSV_PATH)
      .pipe(csv())
      .on('data', (row) => {
        // Skip system accounts and zero balances
        if (row.account_name && row.balance_decimal && parseFloat(row.balance_decimal) > 0) {
          users.push({
            accountId: row.account_id,
            username: row.account_name,
            xomAddress: row.account_address,
            balance: parseFloat(row.balance),
            balanceDecimal: parseFloat(row.balance_decimal),
            balanceType: row.balance_type
          });
        }
      })
      .on('end', () => {
        console.log(`✅ Loaded ${users.length} users with positive balances from CSV`);
        resolve(users);
      })
      .on('error', reject);
  });
}

/**
 * Populate the LegacyBalanceClaim contract with user data
 */
async function main(): Promise<void> {
  console.log('Starting Legacy Balance Claim contract population...\n');

  // Get contract address from deployments
  const network = process.env.HARDHAT_NETWORK || 'fuji';
  const deploymentsPath = path.join(__dirname, '../deployments', `${network}.json`);

  if (!fs.existsSync(deploymentsPath)) {
    throw new Error(`Deployment file not found: ${deploymentsPath}`);
  }

  const deployments = JSON.parse(fs.readFileSync(deploymentsPath, 'utf-8'));
  const contractAddress = deployments.contracts?.LegacyBalanceClaim || deployments.LegacyBalanceClaim;

  if (!contractAddress) {
    throw new Error('LegacyBalanceClaim address not found in deployments');
  }

  console.log(`Contract Address: ${contractAddress}`);
  console.log(`Network: ${network}\n`);

  // Get contract instance
  const LegacyBalanceClaim = await ethers.getContractFactory('LegacyBalanceClaim');
  const contract = LegacyBalanceClaim.attach(contractAddress);

  // Check if already initialized
  const reservedCount = await contract.reservedCount();
  console.log(`Current reserved count: ${reservedCount}`);

  if (reservedCount > 0) {
    console.log('⚠️  Contract already has data. Checking if we need to add more users...\n');
  }

  // Load users from CSV
  const users = await loadLegacyUsers();
  console.log(`Total users to process: ${users.length}\n`);

  // Process in batches
  const batches: Array<{ usernames: string[]; balances: string[] }> = [];

  for (let i = 0; i < users.length; i += BATCH_SIZE) {
    const batch = users.slice(i, i + BATCH_SIZE);

    batches.push({
      usernames: batch.map(u => u.username),
      balances: batch.map(u => ethers.parseEther(u.balanceDecimal.toString()).toString())
    });
  }

  console.log(`Processing ${batches.length} batches of up to ${BATCH_SIZE} users each\n`);

  // Execute batches
  let successCount = 0;
  let failCount = 0;

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];

    console.log(`\n📦 Batch ${i + 1}/${batches.length} (${batch.usernames.length} users):`);
    console.log(`   First user: ${batch.usernames[0]}`);
    console.log(`   Last user: ${batch.usernames[batch.usernames.length - 1]}`);

    try {
      // Calculate total XOM in this batch
      const batchTotal = batch.balances.reduce((sum, bal) => sum + BigInt(bal), 0n);
      const batchTotalXOM = parseFloat(ethers.formatEther(batchTotal));

      console.log(`   Total XOM in batch: ${batchTotalXOM.toLocaleString()}`);

      // Use initialize() for first batch if contract is empty, otherwise use addLegacyUsers()
      let tx;
      if (reservedCount === 0n && i === 0) {
        console.log('   Calling initialize()...');
        tx = await contract.initialize(batch.usernames, batch.balances);
      } else {
        console.log('   Calling addLegacyUsers()...');
        tx = await contract.addLegacyUsers(batch.usernames, batch.balances);
      }

      console.log(`   Transaction hash: ${tx.hash}`);
      console.log('   Waiting for confirmation...');

      const receipt = await tx.wait();

      console.log(`   ✅ Confirmed in block ${receipt.blockNumber}`);
      console.log(`   Gas used: ${receipt.gasUsed.toString()}`);

      successCount += batch.usernames.length;
    } catch (error) {
      console.error(`   ❌ Batch ${i + 1} failed:`, error instanceof Error ? error.message : error);
      failCount += batch.usernames.length;

      // Continue with next batch despite failure
      continue;
    }
  }

  // Final statistics
  console.log('\n' + '='.repeat(60));
  console.log('POPULATION COMPLETE');
  console.log('='.repeat(60));

  const finalReservedCount = await contract.reservedCount();
  const finalTotalReserved = await contract.totalReserved();
  const finalTotalClaimed = await contract.totalClaimed();

  console.log(`\n📊 Final Statistics:`);
  console.log(`   Users reserved: ${finalReservedCount}`);
  console.log(`   Total reserved: ${ethers.formatEther(finalTotalReserved)} XOM`);
  console.log(`   Total claimed: ${ethers.formatEther(finalTotalClaimed)} XOM`);
  console.log(`   Total unclaimed: ${ethers.formatEther(finalTotalReserved - finalTotalClaimed)} XOM`);
  console.log(`\n   ✅ Success: ${successCount} users`);
  if (failCount > 0) {
    console.log(`   ❌ Failed: ${failCount} users`);
  }
  console.log('');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
