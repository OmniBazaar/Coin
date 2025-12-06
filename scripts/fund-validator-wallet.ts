/**
 * Fund Validator Wallet Script
 *
 * Transfers native tokens from the genesis-funded account to the validator wallet.
 * The genesis account (cli-teleporter-deployer) has 600 native tokens allocated.
 *
 * Usage:
 *   npx ts-node scripts/fund-validator-wallet.ts [amount_in_ether]
 *
 * Default amount: 100 native tokens (should be plenty for gas)
 */

import { ethers } from 'ethers';

// Deployer account - omnicoin-control-1 key
// This account has ~9 billion native tokens allocated in genesis
const SOURCE_PRIVATE_KEY = '5145d2bcf3710ae4143b95aab6a7ff5cd954f78ddb9956b28ce86e4c7855e74b';
const SOURCE_ADDRESS = '0xf8C9057d9649daCB06F14A7763233618Cc280663';

// Validator wallet - Hardhat account #0
const VALIDATOR_WALLET = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

// RPC URL for OmniCoin L1 (Fuji)
const RPC_URL = 'http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc';

async function main(): Promise<void> {
  // Parse amount from command line (default: 100 native tokens)
  const amountArg = process.argv[2];
  const amountInEther = amountArg ? parseFloat(amountArg) : 100;

  console.log('='.repeat(60));
  console.log('Fund Validator Wallet');
  console.log('='.repeat(60));
  console.log(`Source:           ${SOURCE_ADDRESS}`);
  console.log(`Destination:      ${VALIDATOR_WALLET}`);
  console.log(`Amount:           ${amountInEther} native tokens`);
  console.log(`RPC URL:          ${RPC_URL}`);
  console.log('='.repeat(60));

  // Connect to the OmniCoin L1
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  // Check connection
  try {
    const network = await provider.getNetwork();
    console.log(`\nConnected to network: chainId=${network.chainId}`);
  } catch (error) {
    console.error('\n❌ Failed to connect to RPC endpoint');
    console.error('   Make sure avalanchego is running with OmniCoin L1');
    console.error('   Error:', error instanceof Error ? error.message : error);
    process.exit(1);
  }

  // Create wallet from source private key
  const sourceWallet = new ethers.Wallet(SOURCE_PRIVATE_KEY, provider);

  // Verify address matches
  if (sourceWallet.address.toLowerCase() !== SOURCE_ADDRESS.toLowerCase()) {
    console.error(`❌ Wallet address mismatch!`);
    console.error(`   Expected: ${SOURCE_ADDRESS}`);
    console.error(`   Got:      ${sourceWallet.address}`);
    process.exit(1);
  }

  // Check source balance
  const sourceBalance = await provider.getBalance(SOURCE_ADDRESS);
  console.log(`\nSource balance:   ${ethers.formatEther(sourceBalance)} native tokens`);

  if (sourceBalance === 0n) {
    console.error('❌ Source account has zero balance!');
    console.error('   Check genesis.json allocation');
    process.exit(1);
  }

  // Check current validator balance
  const validatorBalance = await provider.getBalance(VALIDATOR_WALLET);
  console.log(`Validator balance: ${ethers.formatEther(validatorBalance)} native tokens`);

  // Calculate amount to send
  const amountWei = ethers.parseEther(amountInEther.toString());

  if (amountWei > sourceBalance) {
    console.error(`❌ Insufficient balance in source account!`);
    console.error(`   Requested: ${amountInEther} tokens`);
    console.error(`   Available: ${ethers.formatEther(sourceBalance)} tokens`);
    process.exit(1);
  }

  // Send transaction
  console.log(`\nSending ${amountInEther} native tokens to validator wallet...`);

  try {
    const tx = await sourceWallet.sendTransaction({
      to: VALIDATOR_WALLET,
      value: amountWei,
    });

    console.log(`Transaction hash: ${tx.hash}`);
    console.log('Waiting for confirmation...');

    const receipt = await tx.wait();

    if (receipt && receipt.status === 1) {
      console.log(`\n✅ Transaction confirmed!`);
      console.log(`   Block number: ${receipt.blockNumber}`);
      console.log(`   Gas used:     ${receipt.gasUsed.toString()}`);

      // Check new balances
      const newSourceBalance = await provider.getBalance(SOURCE_ADDRESS);
      const newValidatorBalance = await provider.getBalance(VALIDATOR_WALLET);

      console.log(`\nNew balances:`);
      console.log(`   Source:    ${ethers.formatEther(newSourceBalance)} native tokens`);
      console.log(`   Validator: ${ethers.formatEther(newValidatorBalance)} native tokens`);

      console.log('\n✅ Validator wallet funded successfully!');
      console.log('   Validator can now pay gas fees for OmniCore registration');
    } else {
      console.error('❌ Transaction failed!');
      process.exit(1);
    }
  } catch (error) {
    console.error('\n❌ Transaction failed!');
    console.error('   Error:', error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error('Unhandled error:', error);
  process.exit(1);
});
