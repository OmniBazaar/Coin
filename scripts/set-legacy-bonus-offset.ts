/**
 * @file set-legacy-bonus-offset.ts
 * @description Set the legacyBonusClaimsCount on OmniRewardManager
 *
 * This script sets the count of legacy users (~3996) who already claimed the
 * welcome bonus in old OmniBazaar. This count is ADDED to on-chain registrations
 * to determine the bonus tier for new users.
 *
 * With 3996 legacy claims + 10 on-chain = 4006 effective registrations → Tier 2 (5,000 XOM)
 *
 * Usage:
 *   npx hardhat run scripts/set-legacy-bonus-offset.ts --network fuji
 */

import { ethers } from 'hardhat';

const REWARD_MANAGER_PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REGISTRATION_CONTRACT = '0x0E4E697317117B150481a827f1e5029864aAe781';

// Number of legacy users who already claimed the bonus in old OmniBazaar
const LEGACY_BONUS_CLAIMS = 3996;

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Set Legacy Bonus Claims Count');
    console.log('========================================\n');

    const [signer] = await ethers.getSigners();
    console.log('Signer:', await signer.getAddress());

    // Connect to OmniRegistration to get total registrations
    const registrationABI = [
        'function totalRegistrations() view returns (uint256)'
    ];
    const registration = new ethers.Contract(REGISTRATION_CONTRACT, registrationABI, signer);

    // Get current total registrations
    const totalRegs = await registration.totalRegistrations();
    console.log('\nOn-chain Registrations:', totalRegs.toString());
    console.log('Legacy Bonus Claims:', LEGACY_BONUS_CLAIMS);

    // Calculate effective registrations (on-chain + legacy)
    const effectiveCount = BigInt(totalRegs) + BigInt(LEGACY_BONUS_CLAIMS);
    console.log('\nEffective Registrations (on-chain + legacy):', effectiveCount.toString());

    // Connect to OmniRewardManager
    const rewardManagerABI = [
        'function setLegacyBonusClaimsCount(uint256 _count) external',
        'function legacyBonusClaimsCount() view returns (uint256)',
        'function getExpectedWelcomeBonus() view returns (uint256)',
        'function getEffectiveRegistrations() view returns (uint256)'
    ];
    const rewardManager = new ethers.Contract(REWARD_MANAGER_PROXY, rewardManagerABI, signer);

    // Check current count
    const currentCount = await rewardManager.legacyBonusClaimsCount();
    console.log('\nCurrent legacy claims count:', currentCount.toString());

    // Set the new count
    console.log('\n--- Setting Legacy Claims Count ---');
    const tx = await rewardManager.setLegacyBonusClaimsCount(LEGACY_BONUS_CLAIMS);
    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();
    console.log('Confirmed in block:', receipt?.blockNumber);
    console.log('Gas used:', receipt?.gasUsed?.toString());

    // Verify the change
    console.log('\n--- Verifying ---');
    const newCount = await rewardManager.legacyBonusClaimsCount();
    console.log('New legacy claims count:', newCount.toString());

    const effectiveRegs = await rewardManager.getEffectiveRegistrations();
    console.log('Effective registrations:', effectiveRegs.toString());

    const expectedBonus = await rewardManager.getExpectedWelcomeBonus();
    const bonusInXOM = ethers.formatEther(expectedBonus);
    console.log('Expected welcome bonus:', bonusInXOM, 'XOM');

    // Determine tier
    const effectiveNum = Number(effectiveRegs);
    let tier: string;
    if (effectiveNum <= 1000) {
        tier = 'Tier 1 (10,000 XOM)';
    } else if (effectiveNum <= 10000) {
        tier = 'Tier 2 (5,000 XOM)';
    } else if (effectiveNum <= 100000) {
        tier = 'Tier 3 (2,500 XOM)';
    } else if (effectiveNum <= 1000000) {
        tier = 'Tier 4 (1,250 XOM)';
    } else {
        tier = 'Tier 5 (625 XOM)';
    }
    console.log('Current tier:', tier);

    console.log('\n========================================');
    console.log('Legacy Claims Count Set Successfully');
    console.log(`New users will receive ${bonusInXOM} XOM welcome bonus`);
    console.log('========================================\n');
}

main().catch(console.error);
