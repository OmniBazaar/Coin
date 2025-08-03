const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

console.log('Finding contracts with "stack too deep" errors...\n');

// Get all Solidity files
const contracts = fs.readdirSync('./contracts')
    .filter(f => f.endsWith('.sol') && !f.includes('Test'));

const problematicContracts = [];

// Test each contract individually
for (const contract of contracts) {
    process.stdout.write(`Testing ${contract.padEnd(30, '.')} `);
    
    // Create a simple test file that imports the contract
    const testContent = `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../contracts/${contract}";
`;
    
    fs.mkdirSync('./test-compile', { recursive: true });
    fs.writeFileSync('./test-compile/test.sol', testContent);
    
    try {
        // Try to compile with solc directly
        const result = execSync(
            `npx solc --optimize --via-ir --base-path . --include-path ./node_modules --include-path ./contracts ./test-compile/test.sol`,
            { encoding: 'utf8', stdio: 'pipe' }
        );
        
        if (result.includes('Stack too deep')) {
            console.log('❌ STACK TOO DEEP');
            problematicContracts.push(contract);
        } else {
            console.log('✅ OK');
        }
    } catch (error) {
        if (error.stdout && error.stdout.includes('Stack too deep')) {
            console.log('❌ STACK TOO DEEP');
            problematicContracts.push(contract);
        } else if (error.stderr && error.stderr.includes('DeclarationError')) {
            console.log('⚠️  Other Error');
        } else {
            console.log('✅ OK');
        }
    }
    
    // Cleanup
    fs.rmSync('./test-compile', { recursive: true, force: true });
}

console.log('\n' + '='.repeat(60));
console.log('Summary:');
console.log('='.repeat(60));

if (problematicContracts.length > 0) {
    console.log('\nContracts with "stack too deep" errors:');
    problematicContracts.forEach(c => console.log(`  - ${c}`));
} else {
    console.log('\nNo contracts found with "stack too deep" errors!');
    console.log('The error might be in the combination of contracts.');
}

// Run solhint on all contracts
console.log('\n\nRunning Solhint linter...\n');
try {
    execSync('npx solhint contracts/**/*.sol', { stdio: 'inherit' });
} catch (error) {
    // Solhint exits with error code if there are warnings
}