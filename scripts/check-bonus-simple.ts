/**
 * @file check-bonus-simple.ts
 * @description Simple bonus eligibility check
 */

import { ethers } from 'hardhat';

const REWARD_MANAGER_PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';

const USERS = [
    { name: 'omnirick', address: '0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83' },
    { name: 'mohsinalikhan', address: '0x46b6AF2444A12542e195ca4F5c1e2fC25897653A' },
    { name: 'TestyTestman', address: '0xb0eC55EcE7D626f89d062738fe6Ab40510bC90D3' }
];

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Simple Bonus Eligibility Check');
    console.log('========================================\n');

    // Get contracts
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');
    const rewardManager = OmniRewardManager.attach(REWARD_MANAGER_PROXY);

    // Registration ABI for getRegistration
    const regABI = [
        'function getRegistration(address) view returns (uint256 timestamp, address referrer, address registeredBy, bytes32 phoneHash, bytes32 emailHash, uint8 kycTier, bool welcomeBonusClaimed, bool firstSaleBonusClaimed)',
        'function totalRegistrations() view returns (uint256)'
    ];
    const registration = new ethers.Contract(REGISTRATION_ADDRESS, regABI, ethers.provider);

    // Check contract configuration
    console.log('--- Contract Configuration ---');
    const regContract = await rewardManager.registrationContract();
    console.log('Reward Manager -> Registration:', regContract);
    console.log('Match:', regContract.toLowerCase() === REGISTRATION_ADDRESS.toLowerCase());

    // Check each user
    console.log('\n--- User Eligibility ---\n');

    for (const user of USERS) {
        console.log(`${user.name} (${user.address}):`);

        // Get registration data
        const reg = await registration.getRegistration(user.address);
        console.log('  Registered:', reg.timestamp > 0 ? 'Yes' : 'No');

        if (reg.timestamp > 0) {
            const regDate = new Date(Number(reg.timestamp) * 1000);
            console.log('  Registration Date:', regDate.toISOString());

            // Calculate age
            const now = Math.floor(Date.now() / 1000);
            const ageHours = Math.floor((now - Number(reg.timestamp)) / 3600);
            console.log('  Registration Age:', ageHours, 'hours');

            console.log('  KYC Tier:', reg.kycTier.toString());
            console.log('  Welcome Bonus Claimed:', reg.welcomeBonusClaimed);
            console.log('  First Sale Bonus Claimed:', reg.firstSaleBonusClaimed);

            // Simple eligibility (ignoring cooling period for now)
            const couldClaim = !reg.welcomeBonusClaimed && reg.kycTier >= 1;
            console.log('  Could Claim (ignoring cooling):', couldClaim ? 'YES' : 'NO');
        }
        console.log('');
    }

    // Check bonus pool balance
    console.log('--- Bonus Pool Status ---');
    const welcomePool = await rewardManager.welcomeBonusPool();
    console.log('Welcome Bonus Pool:');
    console.log('  Initial:', ethers.formatEther(welcomePool.initial), 'XOM');
    console.log('  Remaining:', ethers.formatEther(welcomePool.remaining), 'XOM');
    console.log('  Distributed:', ethers.formatEther(welcomePool.distributed), 'XOM');

    // Total registrations
    const totalRegistrations = await registration.totalRegistrations();
    console.log('\nTotal Registrations:', totalRegistrations.toString());

    console.log('\n========================================');
    console.log('Eligibility Check Complete');
    console.log('========================================\n');

    console.log('NOTE: The claimWelcomeBonusPermissionless() function');
    console.log('requires COOLING_PERIOD to be defined in OmniRegistration.');
    console.log('This constant needs to be added to OmniRegistration.');
}

main().catch(console.error);
