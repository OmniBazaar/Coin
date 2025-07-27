const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const contracts = fs.readdirSync('./contracts')
    .filter(f => f.endsWith('.sol'))
    .filter(f => !f.includes('PrivacyFeeManager.sol')); // Skip old version

console.log(`Found ${contracts.length} contracts to test\n`);

for (const contract of contracts) {
    console.log(`Testing: ${contract}`);
    
    // Create temp directory
    fs.mkdirSync('./temp-single', { recursive: true });
    fs.mkdirSync('./temp-single/base', { recursive: true });
    
    // Copy contract and dependencies
    fs.copyFileSync(`./contracts/${contract}`, `./temp-single/${contract}`);
    
    // Copy common dependencies
    const deps = ['OmniCoinRegistry.sol', 'base/RegistryAware.sol', 'PrivacyFeeManagerV2.sol', 'OmniCoin.sol', 'PrivateOmniCoin.sol'];
    deps.forEach(dep => {
        const src = `./contracts/${dep}`;
        const dest = `./temp-single/${dep}`;
        if (fs.existsSync(src) && !fs.existsSync(dest)) {
            fs.copyFileSync(src, dest);
        }
    });
    
    // Create minimal config
    const config = `
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
        sources: "./temp-single",
        cache: "./cache-single",
        artifacts: "./artifacts-single"
    }
};`;
    
    fs.writeFileSync('hardhat.single.config.js', config);
    
    try {
        execSync('npx hardhat compile --config hardhat.single.config.js 2>&1', {
            stdio: 'pipe',
            encoding: 'utf8'
        });
        console.log('  ✅ OK\n');
    } catch (error) {
        if (error.stdout?.includes('Stack too deep')) {
            console.log('  ❌ STACK TOO DEEP!\n');
        } else if (error.stdout?.includes('Error')) {
            console.log('  ❌ Other error\n');
        } else {
            console.log('  ✅ OK\n');
        }
    }
    
    // Cleanup
    fs.rmSync('./temp-single', { recursive: true, force: true });
    fs.rmSync('./cache-single', { recursive: true, force: true });
    fs.rmSync('./artifacts-single', { recursive: true, force: true });
    fs.rmSync('hardhat.single.config.js', { force: true });
}