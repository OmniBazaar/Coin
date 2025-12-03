import { ethers } from 'hardhat';

const REWARD_MANAGER_ADDRESS = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';
const OMNICOIN_ADDRESS = '0x117defc430E143529a9067A7866A9e7Eb532203C';

const rewardABI = [
  'function registrationContract() view returns (address)',
  'function omniCoin() view returns (address)',
  'function getWelcomeBonusAmount(uint256 userCount) view returns (uint256)',
  'function totalRegisteredUsers() view returns (uint256)',
  'function bonusFundBalance() view returns (uint256)',
  'function paused() view returns (bool)',
  'function checkWelcomeBonusEligibility(address user) view returns (bool eligible, string memory reason)'
];

async function main() {
  const rewardManager = new ethers.Contract(REWARD_MANAGER_ADDRESS, rewardABI, ethers.provider);

  console.log('OmniRewardManager Configuration:');
  console.log('================================');
  console.log('Contract Address:', REWARD_MANAGER_ADDRESS);

  try {
    const registrationAddr = await rewardManager.registrationContract();
    console.log('Registration Contract:', registrationAddr);
    console.log('  Expected:', REGISTRATION_ADDRESS);
    console.log('  Match:', registrationAddr.toLowerCase() === REGISTRATION_ADDRESS.toLowerCase());
  } catch (e) {
    console.log('Registration Contract: Error -', (e as Error).message);
  }

  try {
    const omniCoinAddr = await rewardManager.omniCoin();
    console.log('OmniCoin Contract:', omniCoinAddr);
    console.log('  Expected:', OMNICOIN_ADDRESS);
    console.log('  Match:', omniCoinAddr.toLowerCase() === OMNICOIN_ADDRESS.toLowerCase());
  } catch (e) {
    console.log('OmniCoin Contract: Error -', (e as Error).message);
  }

  try {
    const totalUsers = await rewardManager.totalRegisteredUsers();
    console.log('Total Registered Users:', totalUsers.toString());

    const bonusAmount = await rewardManager.getWelcomeBonusAmount(totalUsers);
    console.log('Current Welcome Bonus Amount:', ethers.formatEther(bonusAmount), 'XOM');
  } catch (e) {
    console.log('Total Users/Bonus: Error -', (e as Error).message);
  }

  try {
    const fundBalance = await rewardManager.bonusFundBalance();
    console.log('Bonus Fund Balance:', ethers.formatEther(fundBalance), 'XOM');
  } catch (e) {
    console.log('Bonus Fund Balance: Error -', (e as Error).message);
  }

  try {
    const paused = await rewardManager.paused();
    console.log('Contract Paused:', paused);
  } catch (e) {
    console.log('Paused Status: Error -', (e as Error).message);
  }

  // Check eligibility for existing users
  console.log('\nUser Welcome Bonus Eligibility:');
  console.log('==============================');

  const users = [
    { name: 'omnirick', address: '0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83' },
    { name: 'mohsinalikhan', address: '0x46b6AF2444A12542e195ca4F5c1e2fC25897653A' },
    { name: 'TestyTestman', address: '0xb0eC55EcE7D626f89d062738fe6Ab40510bC90D3' }
  ];

  for (const user of users) {
    try {
      const [eligible, reason] = await rewardManager.checkWelcomeBonusEligibility(user.address);
      console.log(`${user.name}: ${eligible ? 'ELIGIBLE' : 'NOT ELIGIBLE'} - ${reason}`);
    } catch (e) {
      console.log(`${user.name}: Error - ${(e as Error).message}`);
    }
  }
}

main().catch(console.error);
