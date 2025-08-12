const fs = require('fs');
const path = require('path');

// Current contracts (6 remaining - OmniMarketplace removed)
const currentContracts = [
  'MinimalEscrow',
  'OmniBridge', 
  'OmniCoin',
  'OmniCore',
  'OmniGovernance',
  'PrivateOmniCoin'
];

// Scan test directory for all test files
const testDir = './test';
const testFiles = [];

function scanDirectory(dir) {
  const files = fs.readdirSync(dir);
  files.forEach(file => {
    const fullPath = path.join(dir, file);
    const stat = fs.statSync(fullPath);
    
    if (stat.isDirectory() && !file.includes('deprecated')) {
      scanDirectory(fullPath);
    } else if (file.endsWith('.test.js') || file.endsWith('.test.ts')) {
      testFiles.push(fullPath);
    }
  });
}

scanDirectory(testDir);

// Analyze each test file
const results = {
  current: [],      // Tests for current contracts
  deprecated: [],   // Tests for deprecated contracts
  unknown: []      // Can't determine
};

testFiles.forEach(testFile => {
  try {
    const content = fs.readFileSync(testFile, 'utf8');
    
    // Look for contract references
    const contractMatches = content.match(/getContractFactory\(["'](\w+)["']\)/g) || [];
    const importMatches = content.match(/artifacts\/contracts\/(\w+)\.sol/g) || [];
    const describeMatches = content.match(/describe\(["'](\w+)/g) || [];
    
    // Extract contract names
    const referencedContracts = new Set();
    
    contractMatches.forEach(match => {
      const name = match.match(/getContractFactory\(["'](\w+)["']\)/)[1];
      referencedContracts.add(name);
    });
    
    importMatches.forEach(match => {
      const name = match.match(/artifacts\/contracts\/(\w+)\.sol/)[1];
      referencedContracts.add(name);
    });
    
    describeMatches.forEach(match => {
      const name = match.match(/describe\(["'](\w+)/)[1];
      // Only add if it looks like a contract name
      if (name.includes('Omni') || name.includes('Private')) {
        referencedContracts.add(name.split(' ')[0]);
      }
    });
    
    // Categorize
    let isCurrent = false;
    let isDeprecated = false;
    
    referencedContracts.forEach(contract => {
      if (currentContracts.includes(contract)) {
        isCurrent = true;
      } else if (contract.includes('Omni') || contract.includes('Private')) {
        isDeprecated = true;
      }
    });
    
    if (isCurrent && !isDeprecated) {
      results.current.push({ file: testFile, contracts: Array.from(referencedContracts) });
    } else if (isDeprecated && !isCurrent) {
      results.deprecated.push({ file: testFile, contracts: Array.from(referencedContracts) });
    } else {
      results.unknown.push({ file: testFile, contracts: Array.from(referencedContracts) });
    }
    
  } catch (error) {
    console.error(`Error analyzing ${testFile}:`, error.message);
  }
});

// Output results
console.log('\n=== TEST ANALYSIS RESULTS ===\n');

console.log(`Tests for CURRENT contracts (${results.current.length}):`);
results.current.forEach(item => {
  console.log(`  ${item.file}`);
  console.log(`    Contracts: ${item.contracts.join(', ')}`);
});

console.log(`\nTests for DEPRECATED contracts (${results.deprecated.length}):`);
results.deprecated.forEach(item => {
  console.log(`  ${item.file}`);
  console.log(`    Contracts: ${item.contracts.join(', ')}`);
});

console.log(`\nUNKNOWN/Mixed tests (${results.unknown.length}):`);
results.unknown.forEach(item => {
  console.log(`  ${item.file}`);
  console.log(`    Contracts: ${item.contracts.join(', ')}`);
});

console.log('\n=== SUMMARY ===');
console.log(`Total test files: ${testFiles.length}`);
console.log(`Current contract tests: ${results.current.length}`);
console.log(`Deprecated contract tests: ${results.deprecated.length}`);
console.log(`Unknown/Mixed: ${results.unknown.length}`);

// Check which current contracts are missing tests
console.log('\n=== MISSING TESTS ===');
const testedContracts = new Set();
results.current.forEach(item => {
  item.contracts.forEach(c => testedContracts.add(c));
});

currentContracts.forEach(contract => {
  if (!testedContracts.has(contract)) {
    console.log(`  ${contract} - NO TESTS FOUND`);
  }
});