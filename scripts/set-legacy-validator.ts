/**
 * Set Validator Address on LegacyBalanceClaim Contract
 *
 * Authorizes the validator backend to call claim() on behalf of users
 */

import { ethers } from 'hardhat';
import fs from 'fs';
import path from 'path';

async function main(): Promise<void> {
  console.log('Setting validator address on LegacyBalanceClaim contract...\n');

  // Get contract address from deployments
  const network = process.env.HARDHAT_NETWORK || 'fuji';
  const deploymentsPath = path.join(__dirname, '../deployments', `${network}.json`);

  if (!fs.existsSync(deploymentsPath)) {
    throw new Error(`Deployment file not found: ${deploymentsPath}`);
  }

  const deployments = JSON.parse(fs.readFileSync(deploymentsPath, 'utf-8'));
  const contractAddress = deployments.contracts?.LegacyBalanceClaim || deployments.LegacyBalanceClaim;

  if (!contractAddress) {
    throw new Error('LegacyBalanceClaim address not found in deployments');
  }

  console.log(`Contract Address: ${contractAddress}`);
  console.log(`Network: ${network}\n`);

  // Get contract instance
  const LegacyBalanceClaim = await ethers.getContractFactory('LegacyBalanceClaim');
  const contract = LegacyBalanceClaim.attach(contractAddress);

  // Check current validator address
  const currentValidator = await contract.validator();
  console.log(`Current validator address: ${currentValidator}`);

  // Validator backend address (from VALIDATOR_PRIVATE_KEY env var)
  const validatorAddress = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
  console.log(`New validator address: ${validatorAddress}\n`);

  if (currentValidator.toLowerCase() === validatorAddress.toLowerCase()) {
    console.log('✅ Validator address already set correctly!');
    return;
  }

  // Set validator address
  console.log('Setting validator address...');
  const tx = await contract.setValidator(validatorAddress);
  console.log(`Transaction hash: ${tx.hash}`);
  console.log('Waiting for confirmation...');

  const receipt = await tx.wait();
  console.log(`✅ Confirmed in block ${receipt.blockNumber}`);
  console.log(`Gas used: ${receipt.gasUsed.toString()}\n`);

  // Verify
  const newValidator = await contract.validator();
  console.log(`Verified validator address: ${newValidator}`);
  console.log('\n✅ Validator address set successfully!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
