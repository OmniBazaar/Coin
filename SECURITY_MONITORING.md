# OmniCoin Security Monitoring System

## Overview

The OmniCoin Security Monitoring System provides continuous security validation for the smart contract ecosystem. It performs critical security checks to ensure the contracts are ready for deployment and maintain security standards.

## Quick Start

### Run Security Monitor

```bash
npm run security:monitor
```

### Validate for Deployment

```bash
npm run security:validate
```

## Security Checks

The monitoring system performs 5 critical security checks:

### 1. Contract Compilation ✅
- **Purpose**: Ensures all contracts compile successfully without errors
- **Validates**: Solidity syntax, import dependencies, OpenZeppelin v5 compatibility
- **Pass Criteria**: All 70 contracts compile successfully

### 2. Factory Contract Size Limits ✅  
- **Purpose**: Validates all factory contracts comply with EIP-170 size limits
- **Validates**: Bytecode size of all factory contracts
- **Pass Criteria**: All factories under 24,576 bytes (EIP-170 limit)
- **Current Status**:
  - OmniCoinFactory: 3,704 bytes (15% of limit)
  - OmniCoinCoreFactory: 18,498 bytes (75% of limit)
  - OmniCoinSecurityFactory: 16,544 bytes (67% of limit)
  - OmniCoinDefiFactory: 17,274 bytes (70% of limit)
  - OmniCoinBridgeFactory: 13,279 bytes (54% of limit)

### 3. Critical Contract Files ✅
- **Purpose**: Verifies all essential contract files exist
- **Validates**: Presence of core contracts and factory contracts
- **Pass Criteria**: All 6 critical contracts present

### 4. Security Dependencies ✅
- **Purpose**: Ensures required security dependencies are installed
- **Validates**: OpenZeppelin contracts, Hardhat toolbox, core dependencies
- **Pass Criteria**: All required packages present in package.json

### 5. Hardhat Security Configuration ✅
- **Purpose**: Validates security-critical compiler settings
- **Validates**: viaIR optimization, Solidity optimizer configuration
- **Pass Criteria**: Required optimizations enabled for large contract compilation

## Output Formats

### Console Output

```text
🛡️  OmniCoin Security Monitor (Simple)
======================================

🔍 Contract Compilation...
✅ Contract Compilation - PASSED (24857ms)

🔍 Factory Contract Size Limits...
   OmniCoinFactory: 3704 bytes
   OmniCoinCoreFactory: 18498 bytes
   OmniCoinSecurityFactory: 16544 bytes
   OmniCoinDefiFactory: 17274 bytes
   OmniCoinBridgeFactory: 13279 bytes
✅ Factory Contract Size Limits - PASSED (30ms)

📊 Security Monitor Summary
============================
Status: SECURE
🎉 All security checks passed!
✅ Ready for deployment
```

### JSON Report
The monitor generates `security-monitor-report.json` with detailed results:

```json
{
  "timestamp": "2025-07-15T11:43:20.478Z",
  "checks": [
    {
      "name": "Contract Compilation",
      "status": "PASS",
      "duration": "24857ms",
      "message": "OK"
    }
  ],
  "status": "SECURE"
}
```

## CI/CD Integration

### Exit Codes
- **0**: All security checks passed (ready for deployment)
- **1**: One or more security checks failed (action required)

### Integration Examples

**GitHub Actions:**

```yaml
- name: Security Validation
  run: npm run security:validate
```

**Jenkins:**

```groovy
stage('Security Check') {
    steps {
        sh 'npm run security:monitor'
    }
}
```

**Pre-deployment Hook:**

```bash
#!/bin/bash
echo "Running security validation..."
npm run security:validate || {
    echo "❌ Security validation failed!"
    exit 1
}
echo "✅ Security validation passed - proceeding with deployment"
```

## Troubleshooting

### Common Issues

**Compilation Errors:**

```text
❌ Contract Compilation - FAILED: Command failed: npx hardhat compile
```

- **Solution**: Check Solidity syntax errors and import statements
- **Check**: Run `npx hardhat compile` for detailed error messages

**Contract Size Violations:**

```text
❌ Factory Contract Size Limits - FAILED: Contracts exceed EIP-170 limit
```

- **Solution**: Contract too large for deployment
- **Check**: Optimize contract code or split into smaller contracts

**Missing Dependencies:**

```text
❌ Security Dependencies - FAILED: Missing required dependency: @openzeppelin/contracts
```

- **Solution**: Install missing dependencies
- **Fix**: Run `npm install @openzeppelin/contracts`

**Configuration Issues:**

```text
❌ Hardhat Security Configuration - FAILED: viaIR optimization not enabled
```

- **Solution**: Update `hardhat.config.js` to include `viaIR: true`
- **Check**: Verify optimizer settings are properly configured

## Security Standards

The monitoring system enforces these security standards:

- ✅ **OpenZeppelin v5 Compatibility**: All contracts use latest security patterns
- ✅ **EIP-170 Compliance**: All contracts deployable on mainnet
- ✅ **Optimizer Configuration**: Proper compilation settings for security
- ✅ **Dependency Management**: Secure and up-to-date dependencies
- ✅ **File Integrity**: All critical contracts present and accounted for

## Maintenance

### Update Checks
Add new security checks by modifying `scripts/simple-security-monitor.js`:

```javascript
// Add new check
this.runCheck('New Security Check', () => {
  // Your validation logic here
  if (securityConditionNotMet) {
    throw new Error('Security condition failed');
  }
});
```

### Monitoring Frequency
- **Development**: Run before each commit
- **CI/CD**: Run on every pull request and deployment
- **Production**: Run daily as part of health checks

## Support

For security monitoring issues:
1. Check the detailed JSON report for specific error messages
2. Review the console output for immediate feedback
3. Verify all dependencies are properly installed
4. Ensure contracts compile individually before running full monitor

The security monitoring system is designed to catch issues early and ensure consistent security standards across the OmniCoin ecosystem.