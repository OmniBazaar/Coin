/**
 * Upgrade OmniCore + OmniValidatorRewards to V2/V3 on L1 (chain 88008)
 *
 * This script:
 * 1. Deploys new OmniCore implementation and upgrades the proxy
 *    (OmniCore has no upgrade timelock — immediate)
 * 2. Deploys new OmniValidatorRewards implementation
 * 3. Proposes the OmniValidatorRewards upgrade (48h timelock required)
 * 4. Optionally applies the upgrade after timelock (run with --apply flag)
 * 5. Optionally funds OmniValidatorRewards with XOM (run with --fund flag)
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-omnicore-rewards-v2.js --network omnicoinL1
 *   npx hardhat run scripts/upgrade-omnicore-rewards-v2.js --network omnicoinL1 -- --apply
 *   npx hardhat run scripts/upgrade-omnicore-rewards-v2.js --network omnicoinL1 -- --fund
 *
 * @module upgrade-omnicore-rewards-v2
 */

const { ethers, upgrades } = require('hardhat');

// L1 contract addresses (chain 88008)
const OMNICORE_PROXY = '0xc2468BA2F42b5ea9095B43E68F39c366730B84B4';
const REWARDS_PROXY = '0x4b9DbBD359A7c0A5B0893Be532b634e9cB99543D';
const BOOTSTRAP_ADDR = '0xf47EaE62931F9033d929D06Dcc5baF758af3f78E';
const OMNICOIN_ADDR = '0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B';
const REWARD_MANAGER_PROXY = '0xaE3D9bDf72a7160712cb99f01E937Ee2F5AF339c';

// Validator rewards pool: 6.089 billion XOM
const VALIDATOR_POOL_XOM = ethers.parseEther('6089000000');

async function main() {
  const [deployer] = await ethers.getSigners();
  const applyMode = process.argv.includes('--apply');
  const fundMode = process.argv.includes('--fund');

  console.log('='.repeat(70));
  console.log('OmniCore + OmniValidatorRewards V2 Upgrade Script');
  console.log('='.repeat(70));
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Bootstrap: ${BOOTSTRAP_ADDR}`);
  console.log(`Mode: ${applyMode ? 'APPLY (post-timelock)' : fundMode ? 'FUND' : 'DEPLOY + PROPOSE'}`);
  console.log('');

  if (applyMode) {
    await applyRewardsUpgrade(deployer);
    return;
  }

  if (fundMode) {
    await fundRewardsContract(deployer);
    return;
  }

  // Phase 1: Upgrade OmniCore (no timelock)
  await upgradeOmniCore(deployer);

  // Phase 2: Deploy + propose OmniValidatorRewards upgrade
  await proposeRewardsUpgrade(deployer);

  console.log('\n' + '='.repeat(70));
  console.log('NEXT STEPS:');
  console.log('1. Wait 48 hours for the OmniValidatorRewards timelock to elapse');
  console.log('2. Run this script with --apply flag to finalize the upgrade');
  console.log('3. Run this script with --fund flag to transfer XOM to the rewards contract');
  console.log('4. Update gateway-validator.ts and service-node.ts');
  console.log('5. Rebuild and restart validators');
  console.log('='.repeat(70));
}

/**
 * Upgrade OmniCore proxy to V3 (adds Bootstrap integration)
 * OmniCore has no upgrade timelock — direct upgrade via ADMIN_ROLE.
 */
async function upgradeOmniCore(deployer) {
  console.log('--- Phase 1: Upgrade OmniCore ---');

  // Deploy new implementation
  const OmniCore = await ethers.getContractFactory('OmniCore');
  console.log('Deploying new OmniCore implementation...');

  // Force-import existing proxy so the plugin tracks it
  try {
    await upgrades.forceImport(OMNICORE_PROXY, OmniCore, { kind: 'uups' });
  } catch {
    console.log('(proxy already imported)');
  }

  // Upgrade proxy
  const upgraded = await upgrades.upgradeProxy(
    OMNICORE_PROXY,
    OmniCore,
    { unsafeSkipStorageCheck: true }
  );
  await upgraded.waitForDeployment();

  const newImpl = await upgrades.erc1967.getImplementationAddress(OMNICORE_PROXY);
  console.log(`OmniCore upgraded. New implementation: ${newImpl}`);

  // Call reinitializeV3 to set Bootstrap address
  console.log(`Calling reinitializeV3(${BOOTSTRAP_ADDR})...`);
  const tx = await upgraded.reinitializeV3(BOOTSTRAP_ADDR);
  await tx.wait();
  console.log('reinitializeV3 complete');

  // Verify
  const bootstrapAddr = await upgraded.bootstrapContract();
  console.log(`Verified bootstrapContract: ${bootstrapAddr}`);

  // Test getActiveNodes
  try {
    const nodes = await upgraded.getActiveNodes();
    console.log(`getActiveNodes() returns ${nodes.length} validators: ${nodes.join(', ')}`);
  } catch (err) {
    console.log(`getActiveNodes() call: ${err.message}`);
  }

  console.log('Phase 1 complete.\n');
}

/**
 * Deploy new OmniValidatorRewards implementation and propose upgrade.
 * The contract has a 48h timelock on upgrades.
 */
async function proposeRewardsUpgrade(deployer) {
  console.log('--- Phase 2: Propose OmniValidatorRewards Upgrade ---');

  // Deploy new implementation directly (not through OpenZeppelin plugin
  // because the contract has its own proposeUpgrade/timelock flow)
  const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
  console.log('Deploying new OmniValidatorRewards implementation...');
  const newImpl = await OmniValidatorRewards.deploy();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  console.log(`New implementation deployed at: ${newImplAddr}`);

  // Attach to proxy for admin calls
  const proxy = OmniValidatorRewards.attach(REWARDS_PROXY);

  // Propose upgrade (starts 48h timelock)
  console.log('Proposing upgrade (48h timelock starts now)...');
  const tx = await proxy.proposeUpgrade(newImplAddr);
  const receipt = await tx.wait();
  console.log(`Upgrade proposed in tx: ${receipt.hash}`);

  // Read pending upgrade details
  const pending = await proxy.getPendingUpgrade();
  const effectiveDate = new Date(Number(pending.effectiveTimestamp) * 1000);
  console.log(`Upgrade can be applied after: ${effectiveDate.toUTCString()}`);
  console.log(`New implementation: ${pending.newImplementation}`);

  console.log('Phase 2 complete.\n');
}

/**
 * Apply the OmniValidatorRewards upgrade after 48h timelock.
 * Also calls reinitializeV2 to set Bootstrap address.
 */
async function applyRewardsUpgrade(deployer) {
  console.log('--- Applying OmniValidatorRewards Upgrade (post-timelock) ---');

  const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
  const proxy = OmniValidatorRewards.attach(REWARDS_PROXY);

  // Check pending upgrade
  const pending = await proxy.getPendingUpgrade();
  if (pending.newImplementation === ethers.ZeroAddress) {
    console.log('ERROR: No pending upgrade found. Run deploy phase first.');
    return;
  }

  const now = Math.floor(Date.now() / 1000);
  if (now < Number(pending.effectiveTimestamp)) {
    const remaining = Number(pending.effectiveTimestamp) - now;
    const hours = Math.floor(remaining / 3600);
    const mins = Math.floor((remaining % 3600) / 60);
    console.log(`ERROR: Timelock not elapsed. ${hours}h ${mins}m remaining.`);
    console.log(`Effective after: ${new Date(Number(pending.effectiveTimestamp) * 1000).toUTCString()}`);
    return;
  }

  console.log(`Applying upgrade to implementation: ${pending.newImplementation}`);

  // Encode reinitializeV2 call data
  const reinitData = proxy.interface.encodeFunctionData('reinitializeV2', [BOOTSTRAP_ADDR]);

  // Call upgradeToAndCall on the proxy
  const tx = await proxy.upgradeToAndCall(pending.newImplementation, reinitData);
  const receipt = await tx.wait();
  console.log(`Upgrade applied in tx: ${receipt.hash}`);

  // Verify
  const newImpl = await upgrades.erc1967.getImplementationAddress(REWARDS_PROXY);
  console.log(`New implementation address: ${newImpl}`);

  const bootstrapAddr = await proxy.bootstrapContract();
  console.log(`Verified bootstrapContract: ${bootstrapAddr}`);

  console.log('OmniValidatorRewards upgrade complete.\n');
}

/**
 * Fund OmniValidatorRewards with the validator pool XOM.
 * Transfers from deployer wallet (must hold sufficient XOM).
 */
async function fundRewardsContract(deployer) {
  console.log('--- Funding OmniValidatorRewards ---');

  const omniCoin = await ethers.getContractAt('IERC20', OMNICOIN_ADDR);

  // Check deployer balance
  const balance = await omniCoin.balanceOf(deployer.address);
  console.log(`Deployer XOM balance: ${ethers.formatEther(balance)} XOM`);

  // Check current rewards contract balance
  const rewardsBalance = await omniCoin.balanceOf(REWARDS_PROXY);
  console.log(`Current OmniValidatorRewards balance: ${ethers.formatEther(rewardsBalance)} XOM`);

  if (rewardsBalance >= VALIDATOR_POOL_XOM) {
    console.log('OmniValidatorRewards already sufficiently funded.');
    return;
  }

  const needed = VALIDATOR_POOL_XOM - rewardsBalance;
  console.log(`Need to transfer: ${ethers.formatEther(needed)} XOM`);

  if (balance < needed) {
    console.log(`ERROR: Deployer only has ${ethers.formatEther(balance)} XOM.`);
    console.log(`Need ${ethers.formatEther(needed)} XOM more.`);
    console.log('Consider using OmniRewardManager.distributeValidatorReward()');
    console.log('to transfer from the validator rewards pool.');
    return;
  }

  console.log(`Transferring ${ethers.formatEther(needed)} XOM to OmniValidatorRewards...`);
  const tx = await omniCoin.transfer(REWARDS_PROXY, needed);
  const receipt = await tx.wait();
  console.log(`Transfer complete in tx: ${receipt.hash}`);

  // Verify
  const newBalance = await omniCoin.balanceOf(REWARDS_PROXY);
  console.log(`OmniValidatorRewards new balance: ${ethers.formatEther(newBalance)} XOM`);

  console.log('Funding complete.\n');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Script failed:', error);
    process.exit(1);
  });
