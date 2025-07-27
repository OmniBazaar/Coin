#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Check a specific Solidity file for errors
function checkFile(filePath) {
    try {
        console.log(`Checking ${filePath}...`);
        
        // Try to compile with Hardhat first
        const result = execSync(`npx hardhat compile --force`, {
            encoding: 'utf8',
            stdio: 'pipe'
        });
        
        console.log('✓ No compilation errors found');
        return { success: true, errors: [] };
    } catch (error) {
        const output = error.stdout + error.stderr;
        console.log('✗ Compilation errors found:');
        console.log(output);
        return { success: false, errors: output };
    }
}

// Main function
function main() {
    const file = process.argv[2];
    if (!file) {
        console.log('Usage: node check-solidity-errors.js <file>');
        process.exit(1);
    }
    
    checkFile(file);
}

if (require.main === module) {
    main();
}

module.exports = { checkFile };