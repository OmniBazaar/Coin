/**
 * @file force-upgrade-registration.ts
 * @description Force upgrade OmniRegistration with COOLING_PERIOD constant
 */

import { ethers } from 'hardhat';

const REGISTRATION_PROXY = '0x0E4E697317117B150481a827f1e5029864aAe781';

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Force Upgrade OmniRegistration');
    console.log('========================================\n');

    // Get signer
    const [signer] = await ethers.getSigners();
    console.log('Signer:', await signer.getAddress());

    // Get current implementation
    const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
    const currentImplSlot = await ethers.provider.getStorage(REGISTRATION_PROXY, IMPL_SLOT);
    const currentImpl = '0x' + currentImplSlot.slice(-40);
    console.log('Current implementation:', currentImpl);

    // Deploy new implementation directly
    console.log('\n--- Deploying New Implementation ---');
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const newImpl = await OmniRegistration.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();
    console.log('New implementation deployed at:', newImplAddress);

    // Check the new implementation has COOLING_PERIOD
    console.log('\nVerifying new implementation...');
    const newImplCode = await ethers.provider.getCode(newImplAddress);
    console.log('New impl bytecode length:', newImplCode.length);

    const coolingSelector = ethers.id('COOLING_PERIOD()').slice(2, 10);
    const hasCooling = newImplCode.toLowerCase().includes(coolingSelector.toLowerCase());
    console.log('COOLING_PERIOD():', hasCooling ? 'FOUND ✓' : 'NOT FOUND ✗');

    const depositSelector = ethers.id('REGISTRATION_DEPOSIT()').slice(2, 10);
    const hasDeposit = newImplCode.toLowerCase().includes(depositSelector.toLowerCase());
    console.log('REGISTRATION_DEPOSIT():', hasDeposit ? 'FOUND ✓' : 'NOT FOUND ✗');

    // Upgrade the proxy
    console.log('\n--- Upgrading Proxy ---');

    const proxyABI = [
        'function upgradeToAndCall(address newImplementation, bytes calldata data) external payable'
    ];
    const proxy = new ethers.Contract(REGISTRATION_PROXY, proxyABI, signer);

    // Prepare reinitialize call (version 4 - removing cooling period)
    const reinitData = OmniRegistration.interface.encodeFunctionData('reinitialize', [4n]);

    console.log('Calling upgradeToAndCall with reinitialize(4)...');
    const tx = await proxy.upgradeToAndCall(newImplAddress, reinitData);
    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();
    console.log('Confirmed in block:', receipt?.blockNumber);
    console.log('Gas used:', receipt?.gasUsed?.toString());

    // Verify upgrade
    console.log('\n--- Verifying Upgrade ---');

    const registration = OmniRegistration.attach(REGISTRATION_PROXY);

    try {
        const coolingPeriod = await registration.COOLING_PERIOD();
        console.log('COOLING_PERIOD():', coolingPeriod.toString(), 'seconds ✓');
        console.log('               =', Number(coolingPeriod) / 3600, 'hours');
    } catch (e) {
        console.log('COOLING_PERIOD(): ERROR -', (e as Error).message.slice(0, 100));
    }

    try {
        const deposit = await registration.REGISTRATION_DEPOSIT();
        console.log('REGISTRATION_DEPOSIT():', ethers.formatEther(deposit), 'ETH ✓');
    } catch (e) {
        console.log('REGISTRATION_DEPOSIT(): ERROR -', (e as Error).message.slice(0, 100));
    }

    // Check that existing registrations are preserved
    console.log('\n--- Checking Existing Registrations ---');
    const users = [
        { name: 'omnirick', address: '0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83' }
    ];

    for (const user of users) {
        const reg = await registration.getRegistration(user.address);
        console.log(`${user.name}:`, reg.timestamp > 0 ? 'Still registered ✓' : 'NOT REGISTERED ✗');
    }

    console.log('\n========================================');
    console.log('Upgrade Complete');
    console.log('New implementation:', newImplAddress);
    console.log('========================================\n');
}

main().catch(console.error);
