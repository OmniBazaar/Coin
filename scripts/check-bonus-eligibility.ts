/**
 * @file check-bonus-eligibility.ts
 * @description Check bonus eligibility for existing users
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
    console.log('Check Bonus Eligibility');
    console.log('========================================\n');

    // Get contracts
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');
    const rewardManager = OmniRewardManager.attach(REWARD_MANAGER_PROXY);

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(REGISTRATION_ADDRESS);

    // Check contract configuration
    console.log('--- Contract Configuration ---');
    const regContract = await rewardManager.registrationContract();
    console.log('Reward Manager -> Registration:', regContract);
    console.log('Expected Registration:', REGISTRATION_ADDRESS);
    console.log('Match:', regContract.toLowerCase() === REGISTRATION_ADDRESS.toLowerCase());

    const coolingPeriod = await registration.COOLING_PERIOD();
    console.log('Cooling Period:', coolingPeriod.toString(), 'seconds');
    console.log('               =', Number(coolingPeriod) / 3600, 'hours');

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

            // Check cooling period
            const now = Math.floor(Date.now() / 1000);
            const registrationAge = now - Number(reg.timestamp);
            const coolingPeriodPassed = registrationAge >= Number(coolingPeriod);

            console.log('  Registration Age:', Math.floor(registrationAge / 3600), 'hours');
            console.log('  Cooling Period Passed:', coolingPeriodPassed);

            console.log('  KYC Tier:', reg.kycTier.toString());
            console.log('  Welcome Bonus Claimed:', reg.welcomeBonusClaimed);
            console.log('  First Sale Bonus Claimed:', reg.firstSaleBonusClaimed);

            // Check eligibility criteria
            const isEligible = !reg.welcomeBonusClaimed && coolingPeriodPassed && reg.kycTier >= 1;
            console.log('  *** ELIGIBLE FOR WELCOME BONUS:', isEligible ? 'YES ✓' : 'NO ✗');

            if (!isEligible) {
                if (reg.welcomeBonusClaimed) console.log('      Reason: Already claimed');
                else if (!coolingPeriodPassed) console.log('      Reason: Cooling period not passed');
                else if (reg.kycTier < 1) console.log('      Reason: KYC tier too low');
            }
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

    // Get current bonus amount
    const totalRegistrations = await registration.totalRegistrations();
    console.log('\nTotal Registrations:', totalRegistrations.toString());

    try {
        const bonusAmount = await rewardManager.getWelcomeBonusAmount(totalRegistrations);
        console.log('Current Welcome Bonus Amount:', ethers.formatEther(bonusAmount), 'XOM');
    } catch (e) {
        console.log('Could not get bonus amount:', (e as Error).message.slice(0, 100));
    }

    console.log('\n========================================');
    console.log('Eligibility Check Complete');
    console.log('========================================\n');
}

main().catch(console.error);
