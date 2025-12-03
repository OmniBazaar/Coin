/**
 * @file force-upgrade-reward-manager.ts
 * @description Force upgrade OmniRewardManager by deploying new implementation directly
 */

import { ethers } from 'hardhat';

const REWARD_MANAGER_PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Force Upgrade OmniRewardManager');
    console.log('========================================\n');

    // Get signer
    const [signer] = await ethers.getSigners();
    console.log('Signer:', await signer.getAddress());

    // Deploy new implementation directly
    console.log('\n--- Deploying New Implementation ---');
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');
    const newImpl = await OmniRewardManager.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();
    console.log('New implementation deployed at:', newImplAddress);

    // Check the new implementation has the functions we need
    console.log('\nVerifying new implementation...');
    const newImplCode = await ethers.provider.getCode(newImplAddress);
    console.log('New impl bytecode length:', newImplCode.length);

    // Check for function selectors
    const selectors = [
        { name: 'registrationContract()', selector: ethers.id('registrationContract()').slice(2, 10) },
        { name: 'setRegistrationContract(address)', selector: ethers.id('setRegistrationContract(address)').slice(2, 10) },
        { name: 'claimWelcomeBonusPermissionless()', selector: ethers.id('claimWelcomeBonusPermissionless()').slice(2, 10) }
    ];

    for (const { name, selector } of selectors) {
        const found = newImplCode.toLowerCase().includes(selector.toLowerCase());
        console.log(`${name}: ${found ? 'FOUND ✓' : 'NOT FOUND ✗'}`);
    }

    // Upgrade the proxy
    console.log('\n--- Upgrading Proxy ---');

    // Use UUPS upgrade interface
    const proxyABI = [
        'function upgradeToAndCall(address newImplementation, bytes calldata data) external payable'
    ];
    const proxy = new ethers.Contract(REWARD_MANAGER_PROXY, proxyABI, signer);

    // Empty bytes for no call
    const emptyCall = '0x';

    console.log('Calling upgradeToAndCall...');
    const tx = await proxy.upgradeToAndCall(newImplAddress, emptyCall);
    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();
    console.log('Confirmed in block:', receipt?.blockNumber);
    console.log('Gas used:', receipt?.gasUsed?.toString());

    // Verify upgrade
    console.log('\n--- Verifying Upgrade ---');

    const rewardManager = OmniRewardManager.attach(REWARD_MANAGER_PROXY);

    try {
        const regContract = await rewardManager.registrationContract();
        console.log('registrationContract():', regContract, '✓');
    } catch (e) {
        console.log('registrationContract(): ERROR -', (e as Error).message.slice(0, 100));
    }

    try {
        const oddao = await rewardManager.oddaoAddress();
        console.log('oddaoAddress():', oddao, '✓');
    } catch (e) {
        console.log('oddaoAddress(): ERROR -', (e as Error).message.slice(0, 100));
    }

    console.log('\n========================================');
    console.log('Upgrade Complete');
    console.log('New implementation:', newImplAddress);
    console.log('========================================\n');
}

main().catch(console.error);
