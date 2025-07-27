const chokidar = require('chokidar');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

// Output file for errors
const ERROR_FILE = path.join(__dirname, '..', 'compilation-errors.log');

// Watch for changes in contracts directory
const watcher = chokidar.watch('contracts/**/*.sol', {
    persistent: true,
    ignoreInitial: true
});

console.log('Watching for Solidity file changes...');

watcher.on('change', (filePath) => {
    console.log(`File changed: ${filePath}`);
    
    exec('npx hardhat compile', (error, stdout, stderr) => {
        const output = stdout + stderr;
        
        if (error) {
            console.log('Compilation failed');
            fs.writeFileSync(ERROR_FILE, output);
        } else {
            console.log('Compilation successful');
            fs.writeFileSync(ERROR_FILE, '');
        }
    });
});

watcher.on('error', error => console.error('Watcher error:', error));