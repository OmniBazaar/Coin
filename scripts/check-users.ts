import { ethers } from 'hardhat';

const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';

const regABI = [
  'function registrations(address) view returns (uint256 timestamp, address referrer, address registeredBy, bytes32 phoneHash, bytes32 emailHash, uint8 kycTier, bool welcomeBonusClaimed, bool firstSaleBonusClaimed)'
];

async function main() {
  const registration = new ethers.Contract(REGISTRATION_ADDRESS, regABI, ethers.provider);

  const users = [
    { name: 'omnirick', address: '0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83' },
    { name: 'mohsinalikhan', address: '0x46b6AF2444A12542e195ca4F5c1e2fC25897653A' },
    { name: 'TestyTestman', address: '0xb0eC55EcE7D626f89d062738fe6Ab40510bC90D3' }
  ];

  for (const user of users) {
    try {
      const reg = await registration.registrations(user.address);
      console.log(`\n${user.name} (${user.address}):`);
      console.log('  Registered:', reg.timestamp > 0 ? `Yes (${new Date(Number(reg.timestamp) * 1000).toISOString()})` : 'No');
      console.log('  KYC Tier:', reg.kycTier.toString());
      console.log('  Welcome Bonus Claimed:', reg.welcomeBonusClaimed);
      console.log('  First Sale Bonus Claimed:', reg.firstSaleBonusClaimed);
      console.log('  Referrer:', reg.referrer);
    } catch (e) {
      console.log(`\n${user.name}: Error - ${(e as Error).message}`);
    }
  }
}

main().catch(console.error);
