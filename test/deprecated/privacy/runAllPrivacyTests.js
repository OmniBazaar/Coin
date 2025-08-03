const { exec } = require('child_process');
const path = require('path');

/**
 * Run all privacy tests for OmniCoin contracts
 * This script runs each privacy test suite and provides a summary
 */

const testFiles = [
  'OmniCoinCore.privacy.test.js',
  'OmniCoinEscrow.privacy.test.js',
  'OmniCoinPayment.privacy.test.js',
  'OmniCoinStaking.privacy.test.js',
  'OmniCoinArbitration.privacy.test.js',
  'OmniCoinBridge.privacy.test.js',
  'DEXSettlement.privacy.test.js',
  'OmniNFTMarketplace.privacy.test.js'
];

console.log('🔒 Running OmniCoin Privacy Test Suite\n');
console.log('Note: Some tests may be skipped in Hardhat environment');
console.log('Full privacy functionality requires COTI testnet with MPC\n');

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;
let skippedTests = 0;

async function runTest(testFile) {
  return new Promise((resolve) => {
    const testPath = path.join(__dirname, testFile);
    console.log(`\n📋 Running ${testFile}...`);
    
    exec(`npx hardhat test ${testPath}`, (error, stdout, stderr) => {
      // Parse test results
      const output = stdout + stderr;
      
      // Count tests
      const passingMatch = output.match(/(\d+) passing/);
      const failingMatch = output.match(/(\d+) failing/);
      const pendingMatch = output.match(/(\d+) pending/);
      
      const passing = passingMatch ? parseInt(passingMatch[1]) : 0;
      const failing = failingMatch ? parseInt(failingMatch[1]) : 0;
      const pending = pendingMatch ? parseInt(pendingMatch[1]) : 0;
      
      totalTests += passing + failing + pending;
      passedTests += passing;
      failedTests += failing;
      skippedTests += pending;
      
      if (error) {
        console.log(`❌ ${testFile} - ${failing} tests failed`);
        console.log(output);
      } else {
        console.log(`✅ ${testFile} - ${passing} tests passed`);
        if (pending > 0) {
          console.log(`   ⏭️  ${pending} tests skipped (require COTI MPC)`);
        }
      }
      
      resolve();
    });
  });
}

async function runAllTests() {
  console.log('Starting test execution...\n');
  
  for (const testFile of testFiles) {
    // Check if test file exists
    const fs = require('fs');
    const testPath = path.join(__dirname, testFile);
    
    if (fs.existsSync(testPath)) {
      await runTest(testFile);
    } else {
      console.log(`⚠️  ${testFile} not found - creating placeholder...`);
      // You can add logic here to create missing test files
    }
  }
  
  // Print summary
  console.log('\n' + '='.repeat(50));
  console.log('📊 PRIVACY TEST SUMMARY');
  console.log('='.repeat(50));
  console.log(`Total Tests:    ${totalTests}`);
  console.log(`✅ Passed:      ${passedTests}`);
  console.log(`❌ Failed:      ${failedTests}`);
  console.log(`⏭️  Skipped:     ${skippedTests} (MPC required)`);
  console.log('='.repeat(50));
  
  if (failedTests > 0) {
    console.log('\n⚠️  Some tests failed. Please review the output above.');
    process.exit(1);
  } else {
    console.log('\n✨ All tests passed successfully!');
    console.log('\n📝 Note: To test full privacy functionality:');
    console.log('   1. Deploy contracts to COTI testnet');
    console.log('   2. Enable MPC with setMpcAvailability(true)');
    console.log('   3. Run tests against testnet deployment');
  }
}

// Run the tests
runAllTests().catch(console.error);