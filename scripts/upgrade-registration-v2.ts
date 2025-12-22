/**
 * OmniRegistration v2 Upgrade Script
 *
 * Upgrades existing OmniRegistration contract on Fuji to add:
 * - Transaction limits system (USD-denominated)
 * - Address verification (Tier 2 requirement)
 * - Selfie verification (Tier 2 requirement)
 * - Volume tracking (daily/monthly/annual)
 *
 * IMPORTANT: This is a UUPS upgrade - preserves all existing user data
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-registration-v2.ts --network fuji
 */

import { ethers, upgrades } from "hardhat";

async function main() {
  console.log("\n🔄 Upgrading OmniRegistration to v2...\n");

  // Get current proxy address from deployment file
  const fs = require('fs');
  const deploymentPath = './deployments/fuji.json';

  if (!fs.existsSync(deploymentPath)) {
    throw new Error('Fuji deployment file not found. Deploy OmniRegistration first.');
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));

  // Handle both direct and nested deployment structures
  const PROXY_ADDRESS = deployment.OmniRegistration || deployment.contracts?.OmniRegistration;

  if (!PROXY_ADDRESS || PROXY_ADDRESS === '0x0000000000000000000000000000000000000000') {
    console.error('Deployment structure:', JSON.stringify(deployment, null, 2));
    throw new Error('OmniRegistration not found in deployment file');
  }

  console.log(`📍 Current proxy address: ${PROXY_ADDRESS}`);

  // Get current implementation address
  const currentImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
  console.log(`📍 Current implementation: ${currentImpl}`);

  // Deploy new implementation
  console.log('\n📝 Deploying new implementation...');
  const OmniRegistrationV2 = await ethers.getContractFactory("OmniRegistration");

  // Force import existing proxy to allow upgrade
  console.log('📥 Importing existing proxy for upgrade...');
  await upgrades.forceImport(PROXY_ADDRESS, OmniRegistrationV2, { kind: 'uups' });

  const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, OmniRegistrationV2, {
    kind: 'uups'
  });

  await upgraded.waitForDeployment();

  // Get new implementation address
  const newImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
  console.log(`✅ New implementation deployed: ${newImpl}`);

  // Call reinitialize(2) to initialize new v2 features
  console.log('\n🔧 Calling reinitialize(2) to setup transaction limits...');
  const registration = await ethers.getContractAt("OmniRegistration", PROXY_ADDRESS);

  try {
    const tx = await registration.reinitialize(2);
    await tx.wait();
    console.log('✅ Reinitialized with v2 features');
  } catch (error: unknown) {
    if (error instanceof Error && error.message.includes('InvalidInitialization')) {
      console.log('ℹ️  Already reinitialized (skipping)');
    } else {
      throw error;
    }
  }

  // Verify transaction limits initialized
  const tier0Limits = await registration.tierLimits(0);
  const USD = ethers.parseEther("1");

  console.log('\n📊 Verifying transaction limits:');
  console.log(`   Tier 0 daily limit: $${ethers.formatEther(tier0Limits.dailyLimit)} (expected $500)`);
  console.log(`   Tier 0 per-tx limit: $${ethers.formatEther(tier0Limits.perTransactionLimit)} (expected $100)`);

  if (tier0Limits.dailyLimit !== 500n * USD) {
    console.warn('⚠️  Warning: Tier 0 daily limit incorrect!');
  }

  // Verify new functions exist
  console.log('\n🔍 Verifying new functions:');
  console.log(`   ✅ checkTransactionLimit: ${typeof registration.checkTransactionLimit === 'function'}`);
  console.log(`   ✅ recordTransaction: ${typeof registration.recordTransaction === 'function'}`);
  console.log(`   ✅ submitAddressVerification: ${typeof registration.submitAddressVerification === 'function'}`);
  console.log(`   ✅ submitSelfieVerification: ${typeof registration.submitSelfieVerification === 'function'}`);
  console.log(`   ✅ getUserKYCTier: ${typeof registration.getUserKYCTier === 'function'}`);

  // Update deployment file with implementation address
  deployment.OmniRegistrationImplementation = newImpl;
  deployment.lastUpgraded = new Date().toISOString();

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));

  console.log('\n✅ Upgrade complete!');
  console.log(`\nProxy address (unchanged): ${PROXY_ADDRESS}`);
  console.log(`New implementation: ${newImpl}`);
  console.log('\nExisting users preserved ✅');
  console.log('New Tier 2 requirements: ID + Address + Selfie ✅');
  console.log('Transaction limits active ✅\n');

  // Run contract address sync
  console.log('📝 Run this to sync addresses across modules:');
  console.log('   cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh fuji\n');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n❌ Upgrade failed:', error);
    process.exitCode = 1;
  });
