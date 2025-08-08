const { exec } = require('child_process');
const chalk = require('chalk');

// Test categories for simplified architecture
const testCategories = {
  'Core Contracts': [
    'test/OmniCoin.test.js',
    'test/PrivateOmniCoin.test.js',
    'test/OmniCore.test.js'
  ],
  'Business Logic': [
    'test/MinimalEscrow.test.js',
    'test/OmniGovernance.test.js'
  ],
  'Cross-Chain': [
    'test/OmniBridge.test.js'
  ]
};

// Test results
let totalTests = 0;
let passedTests = 0;
let failedTests = 0;
let skippedTests = 0;
const failedTestFiles = [];

// Function to run a single test file
function runTest(testFile) {
  return new Promise((resolve) => {
    console.log(chalk.blue(`\nRunning ${testFile}...`));
    
    exec(`npx hardhat test ${testFile}`, (error, stdout, stderr) => {
      totalTests++;
      
      if (error) {
        failedTests++;
        failedTestFiles.push(testFile);
        console.log(chalk.red(`✗ ${testFile} FAILED`));
        console.log(chalk.red(stderr));
        resolve({ status: 'failed', file: testFile, error: stderr });
      } else {
        // Check if tests were skipped (common for privacy tests in hardhat)
        if (stdout.includes('0 passing') && stdout.includes('pending')) {
          skippedTests++;
          console.log(chalk.yellow(`⚠ ${testFile} SKIPPED (MPC not available in Hardhat)`));
          resolve({ status: 'skipped', file: testFile });
        } else {
          passedTests++;
          console.log(chalk.green(`✓ ${testFile} PASSED`));
          resolve({ status: 'passed', file: testFile });
        }
      }
    });
  });
}

// Function to run all tests in a category
async function runCategory(categoryName, testFiles) {
  console.log(chalk.bold.cyan(`\n${'='.repeat(60)}`));
  console.log(chalk.bold.cyan(`Running ${categoryName} Tests`));
  console.log(chalk.bold.cyan(`${'='.repeat(60)}`));
  
  const results = [];
  for (const testFile of testFiles) {
    const result = await runTest(testFile);
    results.push(result);
  }
  
  return results;
}

// Main test runner
async function runAllTests() {
  console.log(chalk.bold.magenta('OmniCoin Simplified Architecture Test Suite'));
  console.log(chalk.bold.magenta(`${'='.repeat(60)}\n`));
  
  const startTime = Date.now();
  const allResults = {};
  
  // Run tests by category
  for (const [category, files] of Object.entries(testCategories)) {
    const results = await runCategory(category, files);
    allResults[category] = results;
  }
  
  const endTime = Date.now();
  const duration = ((endTime - startTime) / 1000).toFixed(2);
  
  // Print summary
  console.log(chalk.bold.cyan(`\n${'='.repeat(60)}`));
  console.log(chalk.bold.cyan('Test Summary'));
  console.log(chalk.bold.cyan(`${'='.repeat(60)}\n`));
  
  console.log(chalk.bold('Total Tests Run:'), totalTests);
  console.log(chalk.green.bold('Passed:'), passedTests);
  console.log(chalk.red.bold('Failed:'), failedTests);
  console.log(chalk.yellow.bold('Skipped:'), skippedTests);
  console.log(chalk.bold('Duration:'), `${duration}s`);
  
  // List failed tests
  if (failedTestFiles.length > 0) {
    console.log(chalk.red.bold('\nFailed Tests:'));
    failedTestFiles.forEach(file => {
      console.log(chalk.red(`  - ${file}`));
    });
  }
  
  // Category breakdown
  console.log(chalk.bold('\nCategory Breakdown:'));
  for (const [category, results] of Object.entries(allResults)) {
    const categoryPassed = results.filter(r => r.status === 'passed').length;
    const categoryFailed = results.filter(r => r.status === 'failed').length;
    const categorySkipped = results.filter(r => r.status === 'skipped').length;
    
    console.log(chalk.bold(`\n${category}:`));
    console.log(`  Passed: ${categoryPassed}`);
    console.log(`  Failed: ${categoryFailed}`);
    console.log(`  Skipped: ${categorySkipped}`);
  }
  
  // Exit code
  const exitCode = failedTests > 0 ? 1 : 0;
  console.log(chalk.bold(`\nTest suite ${exitCode === 0 ? chalk.green('PASSED') : chalk.red('FAILED')}`));
  
  // Write results to file
  const fs = require('fs');
  const resultsFile = 'test-results.json';
  const resultsData = {
    timestamp: new Date().toISOString(),
    duration: `${duration}s`,
    summary: {
      total: totalTests,
      passed: passedTests,
      failed: failedTests,
      skipped: skippedTests
    },
    categories: allResults,
    failedFiles: failedTestFiles
  };
  
  fs.writeFileSync(resultsFile, JSON.stringify(resultsData, null, 2));
  console.log(chalk.gray(`\nDetailed results saved to ${resultsFile}`));
  
  process.exit(exitCode);
}

// Error handling
process.on('unhandledRejection', (err) => {
  console.error(chalk.red('Unhandled rejection:'), err);
  process.exit(1);
});

// Run tests
runAllTests().catch(err => {
  console.error(chalk.red('Test runner error:'), err);
  process.exit(1);
});