const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

async function generateTypechain() {
  console.log('Generating TypeChain types...');

  // Create typechain-types directory if it doesn't exist
  const typechainDir = path.join(__dirname, '..', 'typechain-types');
  if (!fs.existsSync(typechainDir)) {
    fs.mkdirSync(typechainDir, { recursive: true });
  }

  // Run typechain for all contracts
  const artifacts = [
    './artifacts/contracts/MinimalEscrow.sol/MinimalEscrow.json',
    './artifacts/contracts/OmniBridge.sol/OmniBridge.json',
    './artifacts/contracts/OmniCoin.sol/OmniCoin.json',
    './artifacts/contracts/OmniCore.sol/OmniCore.json',
    './artifacts/contracts/OmniGovernance.sol/OmniGovernance.json',
    './artifacts/contracts/OmniRewardManager.sol/OmniRewardManager.json',
    './artifacts/contracts/PrivateOmniCoin.sol/PrivateOmniCoin.json',
    './artifacts/contracts/interfaces/IOmniCoin.sol/IOmniCoin.json',
    './artifacts/contracts/interfaces/IOmniRewardManager.sol/IOmniRewardManager.json'
  ].join(' ');

  exec(`npx typechain --target ethers-v6 --out-dir typechain-types ${artifacts}`, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error: ${error.message}`);
      return;
    }
    if (stderr) {
      console.error(`Stderr: ${stderr}`);
      return;
    }
    console.log('TypeChain types generated successfully!');
    console.log(stdout);
  });
}

generateTypechain();