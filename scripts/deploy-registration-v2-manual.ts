/**
 * Manual OmniRegistration v2 Deployment
 *
 * Uses prepareUpgrade to deploy new implementation, then manually upgrade proxy
 */

import { ethers, upgrades } from "hardhat";

async function main() {
  console.log("\n🔄 Deploying OmniRegistration v2 (manual upgrade)...\n");

  const PROXY_ADDRESS = "0x0E4E697317117B150481a827f1e5029864aAe781";

  console.log(`📍 Proxy address: ${PROXY_ADDRESS}`);

  // Get current implementation
  const currentImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
  console.log(`📍 Current implementation: ${currentImpl}`);

  // Deploy new implementation
  console.log('\n📝 Deploying new implementation contract...');
  const OmniRegistrationV2 = await ethers.getContractFactory("OmniRegistration");

  const newImplAddress = await upgrades.prepareUpgrade(
    PROXY_ADDRESS,
    OmniRegistrationV2,
    { kind: 'uups' }
  );

  console.log(`✅ New implementation deployed: ${newImplAddress}`);

  if (newImplAddress === currentImpl) {
    console.log('\nℹ️  Implementation unchanged (bytecode identical)');
    console.log('This means v2 features may already be deployed.');
    console.log('\nTesting if v2 features exist...');

    const registration = await ethers.getContractAt("OmniRegistration", PROXY_ADDRESS);

    try {
      const tier0 = await registration.tierLimits(0);
      const USD = ethers.parseEther("1");

      console.log(`\n✅ v2 features ARE deployed!`);
      console.log(`   Tier 0 daily limit: $${ethers.formatEther(tier0.dailyLimit)}`);
      console.log(`   Tier 0 per-tx limit: $${ethers.formatEther(tier0.perTransactionLimit)}`);

      if (tier0.dailyLimit === 500n * USD) {
        console.log('\n✅ Transaction limits correctly initialized!');
      } else {
        console.log('\n⚠️  Limits not initialized. Run reinitialize(2)');
      }

      return;
    } catch (error) {
      console.log('\n❌ v2 features NOT deployed despite same bytecode');
      console.log('This suggests deployment issue. Manual upgrade needed.');
    }
  }

  // If bytecode different, perform upgrade
  console.log('\n🔄 Upgrading proxy to new implementation...');

  const proxy = await ethers.getContractAt("OmniRegistration", PROXY_ADDRESS);
  const [deployer] = await ethers.getSigners();

  // Call upgradeTo on the proxy (UUPS pattern)
  const upgradeTx = await proxy.connect(deployer).upgradeToAndCall(
    newImplAddress,
    '0x' // No data, just upgrade
  );

  await upgradeTx.wait();

  console.log('✅ Proxy upgraded to new implementation');

  // Call reinitialize(2)
  console.log('\n🔧 Calling reinitialize(2)...');

  try {
    const reinitTx = await proxy.reinitialize(2);
    await reinitTx.wait();
    console.log('✅ Reinitialized with v2 features');
  } catch (error: unknown) {
    if (error instanceof Error && error.message.includes('InvalidInitialization')) {
      console.log('ℹ️  Already initialized (skipping)');
    } else {
      console.error('❌ Reinitialize failed:', error);
    }
  }

  // Verify
  const tier0 = await proxy.tierLimits(0);
  console.log(`\n📊 Tier 0 limits:`);
  console.log(`   Daily: $${ethers.formatEther(tier0.dailyLimit)}`);
  console.log(`   Per-tx: $${ethers.formatEther(tier0.perTransactionLimit)}`);

  console.log('\n✅ Deployment complete!\n');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n❌ Deployment failed:', error);
    process.exitCode = 1;
  });
