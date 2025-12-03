/**
 * @file configure-reward-manager-direct.ts
 * @description Configure OmniRewardManager with OmniRegistration - direct version
 */

import { ethers } from 'hardhat';

const REWARD_MANAGER_PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
const REGISTRATION_ADDRESS = '0x0E4E697317117B150481a827f1e5029864aAe781';

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Configure OmniRewardManager');
    console.log('========================================\n');

    // Get signer
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();
    console.log('Signer:', signerAddress);

    // Get contract instance
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');
    const rewardManager = OmniRewardManager.attach(REWARD_MANAGER_PROXY).connect(signer);

    // Check current state
    console.log('\n--- Current State ---');
    const currentReg = await rewardManager.registrationContract();
    console.log('Current registrationContract:', currentReg);
    const currentOddao = await rewardManager.oddaoAddress();
    console.log('Current oddaoAddress:', currentOddao);

    // Set registration contract if not set
    if (currentReg === ethers.ZeroAddress) {
        console.log('\n--- Setting Registration Contract ---');
        console.log('Setting to:', REGISTRATION_ADDRESS);
        const tx1 = await rewardManager.setRegistrationContract(REGISTRATION_ADDRESS);
        console.log('Transaction hash:', tx1.hash);
        const receipt1 = await tx1.wait();
        console.log('Confirmed in block:', receipt1?.blockNumber);
    } else {
        console.log('\nRegistration contract already set');
    }

    // Set ODDAO address if not set (use signer for testing)
    if (currentOddao === ethers.ZeroAddress) {
        console.log('\n--- Setting ODDAO Address ---');
        console.log('Setting to:', signerAddress);
        const tx2 = await rewardManager.setOddaoAddress(signerAddress);
        console.log('Transaction hash:', tx2.hash);
        const receipt2 = await tx2.wait();
        console.log('Confirmed in block:', receipt2?.blockNumber);
    } else {
        console.log('\nODDAO address already set');
    }

    // Verify final state
    console.log('\n--- Final State ---');
    const finalReg = await rewardManager.registrationContract();
    console.log('registrationContract:', finalReg);
    console.log('  Match:', finalReg.toLowerCase() === REGISTRATION_ADDRESS.toLowerCase());

    const finalOddao = await rewardManager.oddaoAddress();
    console.log('oddaoAddress:', finalOddao);

    console.log('\n========================================');
    console.log('Configuration Complete');
    console.log('========================================\n');
}

main().catch(console.error);
