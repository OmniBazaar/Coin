const { execSync } = require('child_process');
const chalk = require('chalk');

/**
 * OmniCoin Test Runner — runs all test files via a single `npx hardhat test`
 * invocation per category to avoid ELOCKED cache conflicts.
 *
 * Usage:
 *   node test/runAllTests.js                          # run all categories
 *   node test/runAllTests.js --category "Core Contracts"
 *   node test/runAllTests.js --category "Privacy" --category "DEX & Settlement"
 *   node test/runAllTests.js --list                   # show categories without running
 */

const testCategories = {
  'Core Contracts': [
    'test/OmniCoin.test.js',
    'test/PrivateOmniCoin.test.js',
    'test/OmniCore.test.js',
    'test/OmniRegistration.test.ts',
    'test/OmniParticipation.test.ts',
    'test/Bootstrap.test.js',
  ],
  'Escrow & Marketplace': [
    'test/MinimalEscrow.test.js',
    'test/MinimalEscrowPrivacy.test.js',
    'test/OmniArbitration.test.js',
    'test/OmniMarketplace.test.js',
  ],
  'Governance': [
    'test/UUPSGovernance.test.js',
  ],
  'Rewards': [
    'test/OmniRewardManager.test.ts',
    'test/OmniValidatorRewards.test.ts',
    'test/StakingRewardPool.test.js',
  ],
  'DEX & Settlement': [
    'test/DEXSettlement.test.ts',
    'test/dex/OmniSwapRouter.test.js',
    'test/dex/OmniFeeRouter.test.js',
    'test/FeeSwapAdapter.test.js',
  ],
  'Fee Infrastructure': [
    'test/UnifiedFeeVault.test.js',
    'test/OmniTreasury.test.js',
    'test/OmniChatFee.test.js',
  ],
  'Cross-Chain': [
    'test/OmniBridge.test.js',
    'test/OmniPrivacyBridge.test.js',
  ],
  'Privacy': [
    'test/PrivateDEXSettlement.test.ts',
    'test/privacy/PrivateDEX.test.js',
    'test/privacy/PrivateUSDC.test.js',
    'test/privacy/PrivateWETH.test.js',
    'test/privacy/PrivateWBTC.test.js',
  ],
  'Liquidity': [
    'test/liquidity/LiquidityBootstrappingPool.test.js',
    'test/liquidity/LiquidityMining.test.js',
    'test/liquidity/OmniBonding.test.js',
  ],
  'NFT': [
    'test/nft/OmniNFTFactory.test.js',
    'test/nft/OmniNFTCollection.test.js',
    'test/nft/OmniFractionalNFT.test.js',
    'test/nft/OmniNFTStaking.test.js',
    'test/nft/OmniNFTLending.test.js',
  ],
  'RWA': [
    'test/rwa/RWAAMM.test.js',
    'test/rwa/RWAPool.test.js',
  ],
  'Account Abstraction': [
    'test/account-abstraction/AccountAbstraction.test.js',
  ],
  'Infrastructure': [
    'test/OmniPriceOracle.test.js',
    'test/UpdateRegistry.test.js',
    'test/OmniENS.test.js',
    'test/predictions/OmniPredictionRouter.test.js',
    'test/reputation/ReputationCredential.test.js',
    'test/yield/OmniYieldFeeCollector.test.js',
    'test/LegacyBalanceClaim.test.js',
  ],
  'Integration': [
    'test/TrustlessIntegration.test.js',
  ],
};

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const showList = args.includes('--list');
const selectedCategories = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--category' && args[i + 1]) {
    selectedCategories.push(args[i + 1]);
    i++;
  }
}

// ---------------------------------------------------------------------------
// --list mode: print categories and exit
// ---------------------------------------------------------------------------
if (showList) {
  console.log(chalk.bold.cyan('Available test categories:\n'));
  for (const [name, files] of Object.entries(testCategories)) {
    console.log(chalk.bold(`  ${name}`), chalk.gray(`(${files.length} files)`));
    files.forEach(f => console.log(chalk.gray(`    ${f}`)));
  }
  const total = Object.values(testCategories).reduce((s, f) => s + f.length, 0);
  console.log(chalk.bold(`\nTotal: ${total} test files in ${Object.keys(testCategories).length} categories`));
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Determine which categories to run
// ---------------------------------------------------------------------------
const categoriesToRun = selectedCategories.length > 0
  ? Object.fromEntries(
      Object.entries(testCategories).filter(([name]) =>
        selectedCategories.some(sel => name.toLowerCase() === sel.toLowerCase())
      )
    )
  : testCategories;

if (Object.keys(categoriesToRun).length === 0) {
  console.error(chalk.red(`No matching categories found for: ${selectedCategories.join(', ')}`));
  console.error(chalk.yellow('Use --list to see available categories'));
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------
let totalCategories = 0;
let passedCategories = 0;
let failedCategories = 0;
const failedCategoryNames = [];
const startTime = Date.now();

console.log(chalk.bold.magenta('OmniCoin Test Suite'));
console.log(chalk.bold.magenta(`${'='.repeat(60)}\n`));

const totalFiles = Object.values(categoriesToRun).reduce((s, f) => s + f.length, 0);
console.log(chalk.bold(`Running ${Object.keys(categoriesToRun).length} categories (${totalFiles} files)\n`));

for (const [category, files] of Object.entries(categoriesToRun)) {
  totalCategories++;
  console.log(chalk.bold.cyan(`\n${'='.repeat(60)}`));
  console.log(chalk.bold.cyan(`[${totalCategories}] ${category} (${files.length} files)`));
  console.log(chalk.bold.cyan(`${'='.repeat(60)}`));

  // Pass ALL files for this category in a single hardhat invocation
  const fileList = files.join(' ');
  const cmd = `npx hardhat test ${fileList}`;

  try {
    const output = execSync(cmd, {
      cwd: process.cwd(),
      stdio: 'pipe',
      encoding: 'utf-8',
      timeout: 600000, // 10 minutes per category
      env: { ...process.env, FORCE_COLOR: '1' },
    });

    // Extract passing/failing counts from mocha output
    const passingMatch = output.match(/(\d+) passing/);
    const failingMatch = output.match(/(\d+) failing/);
    const pendingMatch = output.match(/(\d+) pending/);
    const passing = passingMatch ? passingMatch[1] : '?';
    const failing = failingMatch ? failingMatch[1] : '0';
    const pending = pendingMatch ? pendingMatch[1] : '0';

    if (failingMatch && parseInt(failingMatch[1]) > 0) {
      failedCategories++;
      failedCategoryNames.push(category);
      console.log(chalk.red(`\n  ✗ ${category}: ${passing} passing, ${failing} failing, ${pending} pending`));
      // Print last 40 lines for context on failures
      const lines = output.split('\n');
      console.log(chalk.gray(lines.slice(-40).join('\n')));
    } else {
      passedCategories++;
      console.log(chalk.green(`\n  ✓ ${category}: ${passing} passing, ${pending} pending`));
    }
  } catch (err) {
    failedCategories++;
    failedCategoryNames.push(category);
    const stderr = err.stderr ? err.stderr.toString() : '';
    const stdout = err.stdout ? err.stdout.toString() : '';

    // Extract counts even from failed runs
    const passingMatch = stdout.match(/(\d+) passing/);
    const failingMatch = stdout.match(/(\d+) failing/);
    const passing = passingMatch ? passingMatch[1] : '0';
    const failing = failingMatch ? failingMatch[1] : '?';

    console.log(chalk.red(`\n  ✗ ${category}: ${passing} passing, ${failing} failing`));

    // Print last 50 lines of output for debugging
    const combinedOutput = stdout + '\n' + stderr;
    const lines = combinedOutput.split('\n');
    console.log(chalk.gray(lines.slice(-50).join('\n')));
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
const duration = ((Date.now() - startTime) / 1000).toFixed(1);

console.log(chalk.bold.cyan(`\n${'='.repeat(60)}`));
console.log(chalk.bold.cyan('Test Summary'));
console.log(chalk.bold.cyan(`${'='.repeat(60)}\n`));

console.log(chalk.bold('Categories Run:'), totalCategories);
console.log(chalk.green.bold('Passed:'), passedCategories);
console.log(chalk.red.bold('Failed:'), failedCategories);
console.log(chalk.bold('Duration:'), `${duration}s`);

if (failedCategoryNames.length > 0) {
  console.log(chalk.red.bold('\nFailed Categories:'));
  failedCategoryNames.forEach(name => {
    console.log(chalk.red(`  - ${name}`));
  });
}

// Write results JSON
const fs = require('fs');
fs.writeFileSync('test-results.json', JSON.stringify({
  timestamp: new Date().toISOString(),
  duration: `${duration}s`,
  summary: { total: totalCategories, passed: passedCategories, failed: failedCategories },
  failedCategories: failedCategoryNames,
}, null, 2));
console.log(chalk.gray(`\nResults saved to test-results.json`));

const exitCode = failedCategories > 0 ? 1 : 0;
console.log(chalk.bold(`\nTest suite ${exitCode === 0 ? chalk.green('PASSED') : chalk.red('FAILED')}`));
process.exit(exitCode);
