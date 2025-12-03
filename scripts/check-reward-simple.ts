import { ethers } from 'hardhat';

const REWARD_MANAGER_ADDRESS = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';

async function main() {
  // Use minimal ABI with public state variables as functions
  const rewardManagerABI = [
    'function omniCoin() view returns (address)',
    'function registrationContract() view returns (address)',
    'function paused() view returns (bool)',
    'function welcomeBonusPool() view returns (uint256)',
    'function referralBonusPool() view returns (uint256)',
    'function firstSaleBonusPool() view returns (uint256)',
    'function totalWelcomeBonusesPaid() view returns (uint256)'
  ];

  const rewardManager = new ethers.Contract(REWARD_MANAGER_ADDRESS, rewardManagerABI, ethers.provider);

  console.log('OmniRewardManager State:');
  console.log('========================');

  const omniCoinAddr = await rewardManager.omniCoin();
  console.log('OmniCoin:', omniCoinAddr);

  const regContract = await rewardManager.registrationContract();
  console.log('Registration Contract:', regContract);
  console.log('  Expected:', REGISTRATION_ADDRESS);
  console.log('  Is Set:', regContract !== '0x0000000000000000000000000000000000000000');
  console.log('  Match:', regContract.toLowerCase() === REGISTRATION_ADDRESS.toLowerCase());

  const isPaused = await rewardManager.paused();
  console.log('Paused:', isPaused);

  const welcomePool = await rewardManager.welcomeBonusPool();
  console.log('Welcome Bonus Pool:', ethers.formatEther(welcomePool), 'XOM');

  const referralPool = await rewardManager.referralBonusPool();
  console.log('Referral Bonus Pool:', ethers.formatEther(referralPool), 'XOM');

  const firstSalePool = await rewardManager.firstSaleBonusPool();
  console.log('First Sale Bonus Pool:', ethers.formatEther(firstSalePool), 'XOM');

  const totalWelcomePaid = await rewardManager.totalWelcomeBonusesPaid();
  console.log('Total Welcome Bonuses Paid:', totalWelcomePaid.toString());
}

main().catch(console.error);
