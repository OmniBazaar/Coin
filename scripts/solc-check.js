#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function checkSolidityFile(filePath) {
    try {
        // Create a temporary file with all imports resolved
        const contractName = path.basename(filePath);
        
        // Use solcjs to compile and check for errors
        const cmd = `solcjs --base-path . --include-path ./node_modules --include-path ./contracts ${filePath}`;
        
        console.log(`Checking ${filePath}...`);
        const output = execSync(cmd, { 
            encoding: 'utf8',
            cwd: path.join(__dirname, '..'),
            stdio: 'pipe'
        });
        
        console.log('✓ No errors found');
        return { success: true, output };
    } catch (error) {
        console.log('✗ Errors found:');
        console.error(error.stdout || error.stderr || error.message);
        return { success: false, error: error.message };
    }
}

// If called directly from command line
if (require.main === module) {
    const file = process.argv[2];
    if (!file) {
        console.log('Usage: node solc-check.js <contract-file>');
        process.exit(1);
    }
    
    checkSolidityFile(file);
}

module.exports = { checkSolidityFile };