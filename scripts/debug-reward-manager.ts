import { ethers } from 'hardhat';

const REWARD_MANAGER_ADDRESS = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';

async function main() {
  console.log('Debugging OmniRewardManager contract...\n');

  // Try to get the contract at the proxy address
  const RewardManager = await ethers.getContractFactory('OmniRewardManager');
  const rewardManager = RewardManager.attach(REWARD_MANAGER_ADDRESS);

  console.log('Contract attached at:', REWARD_MANAGER_ADDRESS);

  // Try getting the implementation slot for UUPS proxy
  // keccak256("eip1967.proxy.implementation") - 1
  const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

  try {
    const implSlotValue = await ethers.provider.getStorage(REWARD_MANAGER_ADDRESS, IMPL_SLOT);
    const implAddress = '0x' + implSlotValue.slice(-40);
    console.log('Implementation Address:', implAddress);
  } catch (e) {
    console.log('Error getting impl slot:', e);
  }

  // Try calling functions one by one
  console.log('\nTrying individual function calls:');

  try {
    const omniCoinAddr = await rewardManager.omniCoin();
    console.log('omniCoin():', omniCoinAddr);
  } catch (e) {
    console.log('omniCoin() ERROR:', (e as Error).message.slice(0, 100));
  }

  try {
    const paused = await rewardManager.paused();
    console.log('paused():', paused);
  } catch (e) {
    console.log('paused() ERROR:', (e as Error).message.slice(0, 100));
  }

  try {
    const welcomePool = await rewardManager.welcomeBonusPool();
    console.log('welcomeBonusPool():', ethers.formatEther(welcomePool));
  } catch (e) {
    console.log('welcomeBonusPool() ERROR:', (e as Error).message.slice(0, 100));
  }

  try {
    const regContract = await rewardManager.registrationContract();
    console.log('registrationContract():', regContract);
  } catch (e) {
    console.log('registrationContract() ERROR:', (e as Error).message.slice(0, 100));
  }

  try {
    const oddao = await rewardManager.oddaoAddress();
    console.log('oddaoAddress():', oddao);
  } catch (e) {
    console.log('oddaoAddress() ERROR:', (e as Error).message.slice(0, 100));
  }

  // Check if we have admin role
  console.log('\nChecking roles...');
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();
  console.log('Signer address:', signerAddress);

  try {
    const hasAdminRole = await rewardManager.hasRole(DEFAULT_ADMIN_ROLE, signerAddress);
    console.log('Signer has DEFAULT_ADMIN_ROLE:', hasAdminRole);
  } catch (e) {
    console.log('hasRole() ERROR:', (e as Error).message.slice(0, 100));
  }
}

main().catch(console.error);
