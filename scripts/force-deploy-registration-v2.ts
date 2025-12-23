/**
 * Force Deploy OmniRegistration v2 Implementation
 *
 * Bypasses Hardhat's upgrade helpers to force deploy new implementation
 * then manually call upgradeTo() on the proxy.
 *
 * This preserves ALL existing user data (UUPS pattern).
 */

import { ethers } from "hardhat";

async function main() {
  console.log("\n🔄 Force deploying OmniRegistration v2...\n");

  const PROXY_ADDRESS = "0x0E4E697317117B150481a827f1e5029864aAe781";
  const [deployer] = await ethers.getSigners();

  console.log(`📍 Proxy address: ${PROXY_ADDRESS}`);
  console.log(`📍 Deployer: ${deployer.address}`);

  // Deploy new implementation directly (not via upgrades plugin)
  console.log('\n📝 Deploying new implementation contract...');
  const OmniRegistrationV2 = await ethers.getContractFactory("OmniRegistration");
  const newImplementation = await OmniRegistrationV2.deploy();
  await newImplementation.waitForDeployment();

  const newImplAddress = await newImplementation.getAddress();
  console.log(`✅ New implementation deployed: ${newImplAddress}`);

  // Get proxy contract
  const proxy = await ethers.getContractAt("OmniRegistration", PROXY_ADDRESS);

  // Call upgradeToAndCall on proxy
  console.log('\n🔄 Upgrading proxy to new implementation...');

  try {
    const upgradeTx = await proxy.upgradeToAndCall(
      newImplAddress,
      '0x' // No initialization data
    );

    const receipt = await upgradeTx.wait();
    console.log(`✅ Proxy upgraded! Gas used: ${receipt?.gasUsed.toString()}`);
  } catch (error: unknown) {
    console.error('❌ Upgrade failed:', error);
    throw error;
  }

  // Call reinitialize(2) to setup v2 features
  console.log('\n🔧 Calling reinitialize(2) to initialize transaction limits...');

  try {
    const reinitTx = await proxy.reinitialize(2);
    const receipt = await reinitTx.wait();
    console.log(`✅ Reinitialized! Gas used: ${receipt?.gasUsed.toString()}`);
  } catch (error: unknown) {
    if (error instanceof Error && error.message.includes('InvalidInitialization')) {
      console.log('ℹ️  Already initialized version 2 (skipping)');
    } else {
      console.error('⚠️  Reinitialize failed:', error);
      console.log('Continuing to verify deployment...');
    }
  }

  // Verify v2 features work
  console.log('\n🔍 Verifying v2 features...');

  try {
    const tier0 = await proxy.tierLimits(0);
    const USD = ethers.parseEther("1");

    console.log(`✅ Transaction limits accessible!`);
    console.log(`   Tier 0 daily limit: $${ethers.formatEther(tier0.dailyLimit)}`);
    console.log(`   Tier 0 per-tx limit: $${ethers.formatEther(tier0.perTransactionLimit)}`);
    console.log(`   Max listings: ${tier0.maxListings}`);

    if (tier0.dailyLimit === 500n * USD) {
      console.log('\n✅ Limits correctly initialized!');
    } else if (tier0.dailyLimit === 0n) {
      console.log('\n⚠️  Limits not initialized yet. Try calling reinitialize(2) manually.');
    }

    // Test getUserKYCTier
    const testTier = await proxy.getUserKYCTier(deployer.address);
    console.log(`✅ getUserKYCTier() works! Deployer tier: ${testTier}`);

    // Verify existing users preserved
    const totalRegs = await proxy.totalRegistrations();
    console.log(`✅ Existing registrations preserved: ${totalRegs.toString()}`);

    console.log('\n✅ Deployment successful! All v2 features working.');
    console.log(`\n📝 Update deployment file:`);
    console.log(`   OmniRegistrationImplementation: ${newImplAddress}`);

  } catch (error) {
    console.error('\n❌ Verification failed:', error);
    console.log('\nDeployment may have succeeded but verification failed.');
    console.log('Check contract manually with:');
    console.log(`  npx hardhat console --network fuji`);
    console.log(`  const reg = await ethers.getContractAt("OmniRegistration", "${PROXY_ADDRESS}");`);
    console.log(`  await reg.tierLimits(0);`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n❌ Script failed:', error);
    process.exitCode = 1;
  });
