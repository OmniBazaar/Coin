const fs = require('fs');
const path = require('path');

// Get all contract files
const contractsDir = path.join(__dirname, '..', 'contracts');
const testsDir = path.join(__dirname, '..', 'test');

const contracts = fs.readdirSync(contractsDir)
    .filter(f => f.endsWith('.sol') && !f.startsWith('I')) // Exclude interfaces
    .map(f => f.replace('.sol', ''));

const tests = fs.readdirSync(testsDir)
    .filter(f => f.endsWith('.js'))
    .join(' ');

console.log('=== Contracts without tests ===');
const missingTests = [];

contracts.forEach(contract => {
    if (!tests.includes(contract)) {
        missingTests.push(contract);
        console.log(`- ${contract}`);
    }
});

console.log(`\nTotal contracts: ${contracts.length}`);
console.log(`Contracts without tests: ${missingTests.length}`);
console.log(`Test coverage: ${((contracts.length - missingTests.length) / contracts.length * 100).toFixed(1)}%`);