import { ethers } from 'hardhat';

const REWARD_MANAGER_PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REWARD_MANAGER_IMPL = '0x81De0CD90D3184feEf6f47c2e14F7162Aba48349';

async function main() {
  console.log('Checking OmniRewardManager implementation...\n');

  // Check implementation bytecode
  const implBytecode = await ethers.provider.getCode(REWARD_MANAGER_IMPL);
  console.log('Implementation bytecode length:', implBytecode.length);

  // Check for selectors in implementation
  const selectors = [
    { name: 'registrationContract()', selector: ethers.id('registrationContract()').slice(2, 10) },
    { name: 'oddaoAddress()', selector: ethers.id('oddaoAddress()').slice(2, 10) },
    { name: 'omniCoin()', selector: ethers.id('omniCoin()').slice(2, 10) },
    { name: 'paused()', selector: ethers.id('paused()').slice(2, 10) },
    { name: 'welcomeBonusPool()', selector: ethers.id('welcomeBonusPool()').slice(2, 10) },
    { name: 'claimWelcomeBonusPermissionless()', selector: ethers.id('claimWelcomeBonusPermissionless()').slice(2, 10) },
    { name: 'setRegistrationContract(address)', selector: ethers.id('setRegistrationContract(address)').slice(2, 10) }
  ];

  console.log('\nFunction selectors in implementation:');
  for (const { name, selector } of selectors) {
    const found = implBytecode.toLowerCase().includes(selector.toLowerCase());
    console.log(`${name}: ${selector} - ${found ? 'FOUND' : 'NOT FOUND'}`);
  }

  // Try calling setRegistrationContract through proxy with signer
  console.log('\n\nAttempting to set registration contract...');

  const [signer] = await ethers.getSigners();
  console.log('Signer:', await signer.getAddress());

  const RewardManager = await ethers.getContractFactory('OmniRewardManager');
  const rewardManager = RewardManager.attach(REWARD_MANAGER_PROXY).connect(signer);

  // Check if we can read paused
  try {
    const isPaused = await rewardManager.paused();
    console.log('paused():', isPaused);
  } catch (e) {
    console.log('paused() error:', (e as Error).message.slice(0, 100));
  }

  // Check if signer has admin role
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
  try {
    const hasAdmin = await rewardManager.hasRole(DEFAULT_ADMIN_ROLE, await signer.getAddress());
    console.log('Has admin role:', hasAdmin);
  } catch (e) {
    console.log('hasRole() error:', (e as Error).message.slice(0, 100));
  }

  // Try to call setRegistrationContract
  const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';
  console.log('\nCalling setRegistrationContract with:', REGISTRATION_ADDRESS);

  try {
    const tx = await rewardManager.setRegistrationContract(REGISTRATION_ADDRESS);
    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();
    console.log('Transaction confirmed in block:', receipt.blockNumber);
    console.log('Gas used:', receipt.gasUsed.toString());
  } catch (e) {
    console.log('setRegistrationContract() error:', (e as Error).message.slice(0, 200));
  }
}

main().catch(console.error);
