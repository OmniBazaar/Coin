const { execSync } = require('child_process');
const fs = require('fs');

// Get all actual contract files
const contracts = fs.readdirSync('./contracts')
    .filter(f => f.endsWith('.sol') && !f.includes('Test') && !f.includes('Mock'));

console.log(`Found ${contracts.length} contracts to test\n`);

const results = {
    stackTooDeep: [],
    compiled: [],
    otherError: []
};

// Test each contract
for (const contract of contracts) {
    process.stdout.write(`${contract.padEnd(35, '.')} `);
    
    try {
        // Create isolated test
        fs.mkdirSync('./test-isolated', { recursive: true });
        fs.mkdirSync('./test-isolated/base', { recursive: true });
        
        // Copy contract
        fs.copyFileSync(`./contracts/${contract}`, `./test-isolated/${contract}`);
        
        // Copy base dependencies if they exist
        if (fs.existsSync('./contracts/base/RegistryAware.sol')) {
            fs.copyFileSync('./contracts/base/RegistryAware.sol', './test-isolated/base/RegistryAware.sol');
        }
        if (fs.existsSync('./contracts/OmniCoinRegistry.sol')) {
            fs.copyFileSync('./contracts/OmniCoinRegistry.sol', './test-isolated/OmniCoinRegistry.sol');
        }
        
        // Minimal config
        const config = `
require("@nomicfoundation/hardhat-toolbox");
module.exports = {
    solidity: {
        version: "0.8.19",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200
            }
        }
    },
    paths: {
        sources: "./test-isolated",
        cache: "./cache-test",
        artifacts: "./artifacts-test"
    }
};`;
        
        fs.writeFileSync('hardhat.test.config.js', config);
        
        // Try without viaIR first
        let output = execSync('npx hardhat compile --config hardhat.test.config.js 2>&1', {
            encoding: 'utf8',
            stdio: 'pipe',
            maxBuffer: 1024 * 1024 * 10
        });
        
        if (output.includes('Stack too deep')) {
            console.log('❌ STACK TOO DEEP');
            results.stackTooDeep.push(contract);
        } else if (output.includes('Compiled') || output.includes('Nothing to compile')) {
            console.log('✅ OK');
            results.compiled.push(contract);
        } else {
            console.log('⚠️  Other error');
            results.otherError.push(contract);
        }
        
    } catch (error) {
        const errorMsg = error.stdout || error.stderr || error.message || '';
        if (errorMsg.includes('Stack too deep')) {
            console.log('❌ STACK TOO DEEP');
            results.stackTooDeep.push(contract);
        } else {
            console.log('⚠️  Error');
            results.otherError.push(contract);
        }
    } finally {
        // Cleanup
        fs.rmSync('./test-isolated', { recursive: true, force: true });
        fs.rmSync('./cache-test', { recursive: true, force: true });
        fs.rmSync('./artifacts-test', { recursive: true, force: true });
        fs.rmSync('hardhat.test.config.js', { force: true });
    }
}

// Summary
console.log('\n' + '='.repeat(60));
console.log('SUMMARY');
console.log('='.repeat(60));

if (results.stackTooDeep.length > 0) {
    console.log(`\n❌ Stack too deep errors (${results.stackTooDeep.length}):`);
    results.stackTooDeep.forEach(c => console.log(`   - ${c}`));
}

if (results.compiled.length > 0) {
    console.log(`\n✅ Compiled successfully (${results.compiled.length}):`);
    results.compiled.forEach(c => console.log(`   - ${c}`));
}

if (results.otherError.length > 0) {
    console.log(`\n⚠️  Other errors (${results.otherError.length}):`);
    results.otherError.forEach(c => console.log(`   - ${c}`));
}

console.log('\n' + '='.repeat(60));
console.log('RECOMMENDATION:');
console.log('='.repeat(60));

if (results.stackTooDeep.length > 0) {
    console.log('\nFor contracts with stack too deep errors, you need to:');
    console.log('1. Enable viaIR in hardhat.config.js for those specific contracts');
    console.log('2. OR refactor the contract to use fewer local variables');
    console.log('3. OR split large functions into smaller ones');
}