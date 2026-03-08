/**
 * populate-legacy-mainnet.js
 *
 * Populates the LegacyBalanceClaim contract on mainnet with legacy user balances.
 *
 * Reads the original CSV (Users/omnicoin_usernames_balances_pubkeys.csv) and applies
 * the following transformations:
 *   - Excludes null-account (burned supply)
 *   - Excludes system accounts: exchange, bounty, director1, director2, director3
 *   - Excludes absorbed validators: init6, init11, init15
 *   - Reduces init19 balance to absorb the remaining overshoot
 *   - All zero-balance accounts are skipped
 *
 * After transformation, total claimable = 4,130,000,000.000000 XOM exactly,
 * matching the contract's funded balance and MAX_MIGRATION_SUPPLY.
 *
 * Legacy system uses 5 decimal places (1 XOM = 100,000 raw units).
 * New system uses 18 decimal places (1 XOM = 10^18 Wei).
 * Conversion: 1 legacy raw unit = 10^13 Wei.
 *
 * Usage: npx hardhat run scripts/populate-legacy-mainnet.js --network mainnet
 */
const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

// --- Configuration ---

const LEGACY_CLAIM_ADDRESS = '0x0D6bD1C10EDae3DEC57F426760686130759c84AB';
const DEPLOYER_ADDRESS = '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba';

const CSV_PATH = path.join(__dirname, '../../Users/omnicoin_usernames_balances_pubkeys.csv');

const BATCH_SIZE = 100;

const LEGACY_PRECISION = 100_000n; // 1 XOM = 10^5 raw units
const WEI_FACTOR = 10n ** 13n;     // 1 raw unit = 10^13 Wei

const CONTRACT_SUPPLY_XOM = 4_130_000_000n;
const CONTRACT_SUPPLY_RAW = CONTRACT_SUPPLY_XOM * LEGACY_PRECISION;

/** Accounts to exclude entirely (balance set to zero). */
const EXCLUDE_ACCOUNTS = new Set([
  'null-account',
  'exchange',
  'bounty',
  'director1',
  'director2',
  'director3',
  'init6',
  'init11',
  'init15',
]);

/** Account whose balance is reduced to make totals match exactly. */
const ADJUSTMENT_ACCOUNT = 'init19';

// --- CSV Parsing (no external dependencies) ---

function parseCSV(filePath) {
  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  const header = lines[0].split(',');

  const nameIdx = header.indexOf('account_name');
  const balIdx = header.indexOf('balance');

  if (nameIdx === -1 || balIdx === -1) {
    throw new Error('CSV missing required columns: account_name, balance');
  }

  const accounts = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    const cols = line.split(',');
    const name = cols[nameIdx];
    const rawBalance = BigInt(cols[balIdx]);

    if (rawBalance > 0n) {
      accounts.push({ name, rawBalance });
    }
  }
  return accounts;
}

// --- Main ---

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deployer:', deployer.address);

  if (deployer.address.toLowerCase() !== DEPLOYER_ADDRESS.toLowerCase()) {
    throw new Error(`Wrong deployer! Expected ${DEPLOYER_ADDRESS}, got ${deployer.address}`);
  }

  // 1. Load and filter accounts
  console.log('\n=== Loading CSV ===');
  const allAccounts = parseCSV(CSV_PATH);
  console.log(`Loaded ${allAccounts.length} accounts with positive balances`);

  // 2. Apply exclusions
  const included = allAccounts.filter(a => !EXCLUDE_ACCOUNTS.has(a.name));
  const excluded = allAccounts.filter(a => EXCLUDE_ACCOUNTS.has(a.name));

  console.log(`\nExcluded ${excluded.length} system accounts:`);
  for (const a of excluded) {
    const xom = Number(a.rawBalance) / Number(LEGACY_PRECISION);
    console.log(`  ${a.name.padEnd(15)} ${xom.toLocaleString()} XOM`);
  }
  console.log(`Remaining: ${included.length} accounts`);

  // 3. Compute totals and adjust init19
  let totalRaw = 0n;
  for (const a of included) {
    totalRaw += a.rawBalance;
  }

  const excessRaw = totalRaw - CONTRACT_SUPPLY_RAW;
  console.log(`\nTotal before adjustment: ${totalRaw} raw (${Number(totalRaw / LEGACY_PRECISION).toLocaleString()} XOM)`);
  console.log(`Contract supply:        ${CONTRACT_SUPPLY_RAW} raw (${Number(CONTRACT_SUPPLY_RAW / LEGACY_PRECISION).toLocaleString()} XOM)`);
  console.log(`Excess to absorb:       ${excessRaw} raw (${(Number(excessRaw) / Number(LEGACY_PRECISION)).toFixed(6)} XOM)`);

  if (excessRaw < 0n) {
    throw new Error(`Total is LESS than contract supply by ${-excessRaw} raw — cannot proceed`);
  }

  const adjustAcct = included.find(a => a.name === ADJUSTMENT_ACCOUNT);
  if (!adjustAcct) {
    throw new Error(`Adjustment account "${ADJUSTMENT_ACCOUNT}" not found in included accounts`);
  }

  if (adjustAcct.rawBalance <= excessRaw) {
    throw new Error(`${ADJUSTMENT_ACCOUNT} balance (${adjustAcct.rawBalance}) too small to absorb excess (${excessRaw})`);
  }

  const oldBalance = adjustAcct.rawBalance;
  adjustAcct.rawBalance = adjustAcct.rawBalance - excessRaw;
  console.log(`\n${ADJUSTMENT_ACCOUNT} adjusted:`);
  console.log(`  Old: ${oldBalance} raw (${(Number(oldBalance) / Number(LEGACY_PRECISION)).toFixed(6)} XOM)`);
  console.log(`  New: ${adjustAcct.rawBalance} raw (${(Number(adjustAcct.rawBalance) / Number(LEGACY_PRECISION)).toFixed(6)} XOM)`);

  // 4. Verify final total
  let finalTotal = 0n;
  for (const a of included) {
    finalTotal += a.rawBalance;
  }

  if (finalTotal !== CONTRACT_SUPPLY_RAW) {
    throw new Error(`Final total ${finalTotal} does not match contract supply ${CONTRACT_SUPPLY_RAW}`);
  }

  const finalTotalWei = finalTotal * WEI_FACTOR;
  console.log(`\nFinal total: ${finalTotal} raw = ${finalTotalWei} Wei`);
  console.log(`Expected:    ${CONTRACT_SUPPLY_XOM * 10n ** 18n} Wei`);
  console.log(`Match: ${finalTotalWei === CONTRACT_SUPPLY_XOM * 10n ** 18n}`);
  console.log(`Accounts to load: ${included.length}`);

  // 5. Connect to contract
  const contract = await ethers.getContractAt('LegacyBalanceClaim', LEGACY_CLAIM_ADDRESS);

  const currentReserved = await contract.reservedCount();
  console.log(`\nContract reservedCount: ${currentReserved}`);

  if (currentReserved > 0n) {
    throw new Error('Contract already has data — aborting to prevent duplicates');
  }

  // 6. Prepare batches
  const batches = [];
  for (let i = 0; i < included.length; i += BATCH_SIZE) {
    const batch = included.slice(i, i + BATCH_SIZE);
    batches.push({
      usernames: batch.map(a => a.name),
      balances: batch.map(a => (a.rawBalance * WEI_FACTOR).toString()),
    });
  }

  console.log(`\nPrepared ${batches.length} batches of up to ${BATCH_SIZE} users`);

  // 7. Dry-run totals check
  let batchWeiTotal = 0n;
  for (const batch of batches) {
    for (const bal of batch.balances) {
      batchWeiTotal += BigInt(bal);
    }
  }
  if (batchWeiTotal !== CONTRACT_SUPPLY_XOM * 10n ** 18n) {
    throw new Error(`Batch Wei total ${batchWeiTotal} does not match expected ${CONTRACT_SUPPLY_XOM * 10n ** 18n}`);
  }
  console.log('Dry-run total verified: all batches sum to contract supply exactly.');

  // 8. Execute batches
  console.log('\n=== Executing Transactions ===\n');

  let successCount = 0;

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    const batchTotal = batch.balances.reduce((sum, b) => sum + BigInt(b), 0n);

    console.log(`Batch ${i + 1}/${batches.length}: ${batch.usernames.length} users, ${ethers.formatEther(batchTotal)} XOM`);
    console.log(`  First: ${batch.usernames[0]}, Last: ${batch.usernames[batch.usernames.length - 1]}`);

    let tx;
    if (i === 0) {
      console.log('  Calling initialize()...');
      tx = await contract.initialize(batch.usernames, batch.balances);
    } else {
      console.log('  Calling addLegacyUsers()...');
      tx = await contract.addLegacyUsers(batch.usernames, batch.balances);
    }

    console.log(`  tx: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`  Confirmed block ${receipt.blockNumber}, gas ${receipt.gasUsed}`);
    successCount += batch.usernames.length;
  }

  // 9. Final verification
  console.log('\n=== Final Verification ===');
  const finalReserved = await contract.reservedCount();
  const finalTotalReserved = await contract.totalReserved();
  const finalTotalClaimed = await contract.totalClaimed();

  console.log(`Users reserved:  ${finalReserved}`);
  console.log(`Total reserved:  ${ethers.formatEther(finalTotalReserved)} XOM`);
  console.log(`Total claimed:   ${ethers.formatEther(finalTotalClaimed)} XOM`);
  console.log(`Users loaded:    ${successCount}`);

  // Spot-check a few accounts
  const spotChecks = ['quasar', 'init0', 'init19', 'random'];
  console.log('\nSpot checks:');
  for (const name of spotChecks) {
    try {
      const bal = await contract.getUnclaimedBalance(name);
      console.log(`  ${name.padEnd(12)} ${ethers.formatEther(bal)} XOM`);
    } catch {
      console.log(`  ${name.padEnd(12)} (not found or error)`);
    }
  }

  console.log('\nDone.');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Error:', error);
    process.exit(1);
  });
