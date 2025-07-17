#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');

class SimpleSecurityMonitor {
  constructor() {
    this.results = {
      timestamp: new Date().toISOString(),
      checks: [],
      status: 'UNKNOWN'
    };
  }

  runCheck(name, checkFunction) {
    console.log(`\n🔍 ${name}...`);
    
    try {
      const startTime = Date.now();
      checkFunction();
      const duration = Date.now() - startTime;
      
      this.results.checks.push({
        name,
        status: 'PASS',
        duration: `${duration}ms`,
        message: 'OK'
      });
      
      console.log(`✅ ${name} - PASSED (${duration}ms)`);
      
    } catch (error) {
      this.results.checks.push({
        name,
        status: 'FAIL',
        duration: null,
        message: error.message
      });
      
      console.log(`❌ ${name} - FAILED: ${error.message}`);
    }
  }

  run() {
    console.log('\n🛡️  OmniCoin Security Monitor (Simple)');
    console.log('======================================');

    // Check 1: Compilation
    this.runCheck('Contract Compilation', () => {
      execSync('npx hardhat compile --quiet', { stdio: 'pipe', timeout: 30000 });
    });

    // Check 2: Factory Contract Sizes
    this.runCheck('Factory Contract Size Limits', () => {
      const factories = [
        'OmniCoinFactory',
        'OmniCoinCoreFactory',
        'OmniCoinSecurityFactory', 
        'OmniCoinDefiFactory',
        'OmniCoinBridgeFactory'
      ];
      
      const EIP170_LIMIT = 24576;
      let violations = [];
      
      for (const factory of factories) {
        const artifactPath = `artifacts/contracts/${factory}.sol/${factory}.json`;
        
        if (fs.existsSync(artifactPath)) {
          const artifact = JSON.parse(fs.readFileSync(artifactPath));
          const bytecode = artifact.bytecode.replace('0x', '');
          const sizeBytes = bytecode.length / 2;
          
          console.log(`   ${factory}: ${sizeBytes} bytes`);
          
          if (sizeBytes > EIP170_LIMIT) {
            violations.push(`${factory} (${sizeBytes} bytes)`);
          }
        }
      }
      
      if (violations.length > 0) {
        throw new Error(`Contracts exceed EIP-170 limit: ${violations.join(', ')}`);
      }
    });

    // Check 3: Critical Files Exist
    this.runCheck('Critical Contract Files', () => {
      const criticalFiles = [
        'contracts/OmniCoin.sol',
        'contracts/OmniCoinFactory.sol',
        'contracts/OmniCoinCoreFactory.sol',
        'contracts/OmniCoinSecurityFactory.sol',
        'contracts/OmniCoinDefiFactory.sol',
        'contracts/OmniCoinBridgeFactory.sol'
      ];
      
      for (const file of criticalFiles) {
        if (!fs.existsSync(file)) {
          throw new Error(`Missing critical file: ${file}`);
        }
      }
    });

    // Check 4: Package Dependencies
    this.runCheck('Security Dependencies', () => {
      const packageJson = JSON.parse(fs.readFileSync('package.json'));
      
      const requiredDeps = [
        '@openzeppelin/contracts',
        '@nomicfoundation/hardhat-toolbox',
        'hardhat'
      ];
      
      for (const dep of requiredDeps) {
        if (!packageJson.dependencies?.[dep] && !packageJson.devDependencies?.[dep]) {
          throw new Error(`Missing required dependency: ${dep}`);
        }
      }
    });

    // Check 5: Hardhat Configuration
    this.runCheck('Hardhat Security Configuration', () => {
      if (!fs.existsSync('hardhat.config.js')) {
        throw new Error('Missing hardhat.config.js');
      }
      
      const config = fs.readFileSync('hardhat.config.js', 'utf8');
      
      if (!config.includes('viaIR: true')) {
        throw new Error('viaIR optimization not enabled (required for large contracts)');
      }
      
      if (!config.includes('optimizer')) {
        throw new Error('Solidity optimizer not configured');
      }
    });

    this.generateReport();
  }

  generateReport() {
    const passed = this.results.checks.filter(c => c.status === 'PASS').length;
    const failed = this.results.checks.filter(c => c.status === 'FAIL').length;
    
    this.results.status = failed === 0 ? 'SECURE' : 'ISSUES_FOUND';
    
    console.log('\n📊 Security Monitor Summary');
    console.log('============================');
    console.log(`Timestamp: ${this.results.timestamp}`);
    console.log(`Checks: ${this.results.checks.length}`);
    console.log(`Passed: ${passed} ✅`);
    console.log(`Failed: ${failed} ${failed > 0 ? '❌' : ''}`);
    console.log(`Status: ${this.results.status}`);
    
    if (failed > 0) {
      console.log('\n🚨 Issues Found:');
      this.results.checks
        .filter(c => c.status === 'FAIL')
        .forEach(check => {
          console.log(`   • ${check.name}: ${check.message}`);
        });
      
      console.log('\n⚠️  Action required before deployment!');
    } else {
      console.log('\n🎉 All security checks passed!');
      console.log('✅ Ready for deployment');
    }

    // Save detailed report
    fs.writeFileSync('security-monitor-report.json', JSON.stringify(this.results, null, 2));
    console.log('\n📄 Detailed report: security-monitor-report.json');
    
    return this.results.status === 'SECURE';
  }
}

// Run the monitor
if (require.main === module) {
  const monitor = new SimpleSecurityMonitor();
  const success = monitor.run();
  process.exit(success ? 0 : 1);
}

module.exports = SimpleSecurityMonitor; 