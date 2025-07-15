#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');

class SecurityMonitor {
  constructor() {
    this.testResults = {
      timestamp: new Date().toISOString(),
      tests: [],
      summary: {
        total: 0,
        passed: 0,
        failed: 0
      }
    };
  }

  async runSingleTest(testName, testFunction) {
    console.log(`\n🔍 Running: ${testName}`);
    
    try {
      const startTime = Date.now();
      await testFunction();
      const duration = Date.now() - startTime;
      
      this.testResults.tests.push({
        name: testName,
        status: 'PASSED',
        duration: `${duration}ms`,
        error: null
      });
      
      console.log(`✅ ${testName} - PASSED (${duration}ms)`);
      this.testResults.summary.passed++;
      
    } catch (error) {
      this.testResults.tests.push({
        name: testName,
        status: 'FAILED',
        duration: null,
        error: error.message
      });
      
      console.log(`❌ ${testName} - FAILED`);
      console.log(`   Error: ${error.message}`);
      this.testResults.summary.failed++;
    }
    
    this.testResults.summary.total++;
  }

  async runBasicContractTests() {
    console.log('\n🚀 Starting OmniCoin Security Monitor');
    console.log('=====================================');

    // Test 1: Compilation
    await this.runSingleTest('Contract Compilation', async () => {
      execSync('npx hardhat compile --quiet', { stdio: 'pipe' });
    });

    // Test 2: Basic Deployment
    await this.runSingleTest('Basic Deployment', async () => {
      const output = execSync('echo "y" | npx hardhat test test/simple-test.js --no-compile', { 
        stdio: 'pipe',
        timeout: 15000
      });
      
      if (!output.toString().includes('passing')) {
        throw new Error('Basic deployment test failed');
      }
    });

    // Test 3: Access Control Check
    await this.runSingleTest('Access Control Validation', async () => {
      // This would validate that access control is properly configured
      const output = execSync('echo "y" | npx hardhat run scripts/validate-access-control.js --network hardhat', { 
        stdio: 'pipe',
        timeout: 30000 
      });
      
      if (!output.toString().includes('Access control validated')) {
        throw new Error('Access control validation failed');
      }
    });

    // Test 4: Contract Size Check  
    await this.runSingleTest('Contract Size Validation', async () => {
      const sizeScript = `
        const fs = require('fs');
        const path = require('path');
        
        const factoryPaths = [
          'artifacts/contracts/OmniCoinFactory.sol/OmniCoinFactory.json',
          'artifacts/contracts/OmniCoinCoreFactory.sol/OmniCoinCoreFactory.json',
          'artifacts/contracts/OmniCoinSecurityFactory.sol/OmniCoinSecurityFactory.json',
          'artifacts/contracts/OmniCoinDefiFactory.sol/OmniCoinDefiFactory.json',
          'artifacts/contracts/OmniCoinBridgeFactory.sol/OmniCoinBridgeFactory.json'
        ];
        
        const EIP170_LIMIT = 24576;
        let allWithinLimit = true;
        
        for (const factoryPath of factoryPaths) {
          if (fs.existsSync(factoryPath)) {
            const artifact = JSON.parse(fs.readFileSync(factoryPath));
            const bytecode = artifact.bytecode.replace('0x', '');
            const sizeBytes = bytecode.length / 2;
            
            console.log(\`\${path.basename(factoryPath, '.json')}: \${sizeBytes} bytes\`);
            
            if (sizeBytes > EIP170_LIMIT) {
              allWithinLimit = false;
              console.log(\`❌ Exceeds EIP-170 limit!\`);
            }
          }
        }
        
        if (!allWithinLimit) {
          throw new Error('Some contracts exceed EIP-170 size limit');
        }
        
        console.log('✅ All contracts within EIP-170 size limit');
      `;
      
      fs.writeFileSync('/tmp/size-check.js', sizeScript);
      execSync('cd /mnt/c/Users/rickc/OmniBazaar/Coin && node /tmp/size-check.js', { 
        stdio: 'pipe' 
      });
    });

    this.generateReport();
  }

  generateReport() {
    console.log('\n📊 Security Monitor Report');
    console.log('==========================');
    console.log(`Timestamp: ${this.testResults.timestamp}`);
    console.log(`Total Tests: ${this.testResults.summary.total}`);
    console.log(`Passed: ${this.testResults.summary.passed} ✅`);
    console.log(`Failed: ${this.testResults.summary.failed} ❌`);
    
    if (this.testResults.summary.failed > 0) {
      console.log('\n🚨 Failed Tests:');
      this.testResults.tests
        .filter(test => test.status === 'FAILED')
        .forEach(test => {
          console.log(`   • ${test.name}: ${test.error}`);
        });
    }

    // Save report to file
    const reportPath = 'security-monitor-report.json';
    fs.writeFileSync(reportPath, JSON.stringify(this.testResults, null, 2));
    console.log(`\n📄 Report saved to: ${reportPath}`);

    // Exit with appropriate code
    process.exit(this.testResults.summary.failed > 0 ? 1 : 0);
  }
}

// Run the monitor
const monitor = new SecurityMonitor();
monitor.runBasicContractTests().catch(console.error); 