/**
 * configure-mainnet-contracts.js
 *
 * Post-deployment configuration for mainnet contracts.
 * Sets up cross-contract references, roles, and verification keys.
 *
 * Usage: npx hardhat run scripts/configure-mainnet-contracts.js --network mainnet
 */
const { ethers } = require('hardhat');

// Mainnet addresses (from Coin/deployments/mainnet.json)
const ADDRESSES = {
  OmniCoin: '0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B',
  OmniRewardManager: '0xaE3D9bDf72a7160712cb99f01E937Ee2F5AF339c',
  OmniRegistration: '0x7C3C3081128A71817d6450467cD143549Bfc0405',
  OmniCore: '0xc2468BA2F42b5ea9095B43E68F39c366730B84B4',
  LegacyBalanceClaim: '0x0D6bD1C10EDae3DEC57F426760686130759c84AB',
  ODDAO: '0x664B6347a69A22b35348D42E4640CA92e1609378',
  StakingRewardPool: '0x1cc9FF243A3e76A6c122aa708bB3Fd375a97c7d6',
  Deployer: '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba',
  VerificationKey: '0xE13a2D66736805Fd57F765E82370C5d7b0FBdE54',
};

const LEGACY_BONUS_CLAIMS_COUNT = 3996;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deployer:', deployer.address);

  if (deployer.address.toLowerCase() !== ADDRESSES.Deployer.toLowerCase()) {
    throw new Error(`Wrong deployer! Expected ${ADDRESSES.Deployer}, got ${deployer.address}`);
  }

  let txCount = 0;

  // ========== 1. OmniRewardManager Configuration ==========
  console.log('\n=== Configuring OmniRewardManager ===');

  const rm = await ethers.getContractAt('OmniRewardManager', ADDRESSES.OmniRewardManager);

  // 1a. setRegistrationContract
  const currentRegContract = await rm.registrationContract();
  if (currentRegContract === ethers.ZeroAddress) {
    console.log('Setting registrationContract to OmniRegistration...');
    const tx = await rm.setRegistrationContract(ADDRESSES.OmniRegistration);
    console.log('  tx:', tx.hash);
    await tx.wait();
    console.log('  Confirmed. registrationContract:', await rm.registrationContract());
    txCount++;
  } else {
    console.log('registrationContract already set:', currentRegContract);
  }

  // 1b. setOddaoAddress
  const currentOddao = await rm.oddaoAddress();
  if (currentOddao === ethers.ZeroAddress) {
    console.log('Setting oddaoAddress to ODDAO...');
    const tx = await rm.setOddaoAddress(ADDRESSES.ODDAO);
    console.log('  tx:', tx.hash);
    await tx.wait();
    console.log('  Confirmed. oddaoAddress:', await rm.oddaoAddress());
    txCount++;
  } else {
    console.log('oddaoAddress already set:', currentOddao);
  }

  // 1c. setLegacyBonusClaimsCount
  const currentCount = await rm.welcomeBonusClaimCount();
  if (currentCount === 0n) {
    console.log(`Setting legacyBonusClaimsCount to ${LEGACY_BONUS_CLAIMS_COUNT}...`);
    try {
      const tx = await rm.setLegacyBonusClaimsCount(LEGACY_BONUS_CLAIMS_COUNT);
      console.log('  tx:', tx.hash);
      await tx.wait();
      console.log('  Confirmed.');
      txCount++;
    } catch (e) {
      console.log('  Note: setLegacyBonusClaimsCount may not exist in deployed version:', e.message.substring(0, 100));
    }
  } else {
    console.log('welcomeBonusClaimCount already set:', currentCount.toString());
  }

  // 1d. Grant BONUS_DISTRIBUTOR_ROLE to deployer (Pioneer Phase)
  const BONUS_ROLE = await rm.BONUS_DISTRIBUTOR_ROLE();
  const hasBonusRole = await rm.hasRole(BONUS_ROLE, ADDRESSES.Deployer);
  if (!hasBonusRole) {
    console.log('Granting BONUS_DISTRIBUTOR_ROLE to deployer...');
    const tx = await rm.grantRole(BONUS_ROLE, ADDRESSES.Deployer);
    console.log('  tx:', tx.hash);
    await tx.wait();
    console.log('  Confirmed.');
    txCount++;
  } else {
    console.log('Deployer already has BONUS_DISTRIBUTOR_ROLE');
  }

  // ========== 2. OmniRegistration Configuration ==========
  console.log('\n=== Configuring OmniRegistration ===');

  const reg = await ethers.getContractAt('OmniRegistration', ADDRESSES.OmniRegistration);

  // 2a. setTrustedVerificationKey
  const currentVKey = await reg.trustedVerificationKey();
  if (currentVKey === ethers.ZeroAddress) {
    console.log('Setting trustedVerificationKey...');
    const tx = await reg.setTrustedVerificationKey(ADDRESSES.VerificationKey);
    console.log('  tx:', tx.hash);
    await tx.wait();
    const newKey = await reg.trustedVerificationKey();
    console.log('  Confirmed. trustedVerificationKey:', newKey);
    if (newKey.toLowerCase() !== ADDRESSES.VerificationKey.toLowerCase()) {
      throw new Error('Verification key mismatch after setting!');
    }
    txCount++;
  } else {
    console.log('trustedVerificationKey already set:', currentVKey);
  }

  // ========== 3. OmniCore Gateway Registration ==========
  console.log('\n=== Configuring OmniCore ===');

  const core = await ethers.getContractAt('OmniCore', ADDRESSES.OmniCore);

  // 3a. Register deployer as validator (Pioneer Phase — deployer runs the gateway)
  const isValidator = await core.isValidator(ADDRESSES.Deployer);
  if (!isValidator) {
    console.log('Registering deployer as validator in OmniCore...');
    const tx = await core.setValidator(ADDRESSES.Deployer, true);
    console.log('  tx:', tx.hash);
    await tx.wait();
    const nowValidator = await core.isValidator(ADDRESSES.Deployer);
    console.log('  Confirmed. deployer isValidator:', nowValidator);
    txCount++;
  } else {
    console.log('Deployer already registered as validator');
  }

  // ========== Summary ==========
  console.log('\n=== Configuration Summary ===');
  console.log(`Transactions executed: ${txCount}`);
  console.log('\nOmniRewardManager:');
  console.log('  registrationContract:', await rm.registrationContract());
  console.log('  oddaoAddress:', await rm.oddaoAddress());
  console.log('  BONUS_DISTRIBUTOR_ROLE granted:', await rm.hasRole(BONUS_ROLE, ADDRESSES.Deployer));

  console.log('\nOmniRegistration:');
  console.log('  trustedVerificationKey:', await reg.trustedVerificationKey());
  console.log('  totalRegistrations:', (await reg.totalRegistrations()).toString());

  console.log('\nOmniCore:');
  console.log('  deployer isValidator:', await core.isValidator(ADDRESSES.Deployer));
  console.log('  oddaoAddress:', await core.oddaoAddress());
  console.log('  stakingPoolAddress:', await core.stakingPoolAddress());

  console.log('\nPool balances (OmniRewardManager):');
  const balances = await rm.getPoolBalances();
  const names = ['Welcome', 'Referral', 'FirstSale'];
  for (let i = 0; i < 3; i++) {
    console.log(`  ${names[i]}: ${ethers.formatEther(balances[i])} XOM`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Error:', error);
    process.exit(1);
  });
