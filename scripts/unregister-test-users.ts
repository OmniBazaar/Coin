/**
 * @file unregister-test-users.ts
 * @description Script to unregister test users from OmniRegistration contract
 */

import { ethers, upgrades } from 'hardhat';

async function main(): Promise<void> {
    console.log('===========================================');
    console.log('Unregistering Test Users');
    console.log('===========================================\n');

    const proxyAddr = '0x0E4E697317117B150481a827f1e5029864aAe781';

    // Check current implementation
    const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddr);
    console.log('Current implementation:', currentImpl);

    const reg = await ethers.getContractAt('OmniRegistration', proxyAddr);

    // Users to unregister (those with onchain_registered=true)
    const users = [
        '0xb0eC55EcE7D626f89d062738fe6Ab40510bC90D3', // TestyTestman
        '0x46b6AF2444A12542e195ca4F5c1e2fC25897653A'  // mohsinalikhan.ca@gmail.com
    ];

    console.log('\n--- Checking status before ---');
    for (const u of users) {
        const isReg = await reg.isRegistered(u);
        console.log(`${u}: ${isReg ? 'REGISTERED' : 'not registered'}`);
    }

    console.log('\n--- Calling adminUnregisterBatch ---');
    try {
        const tx = await reg.adminUnregisterBatch(users);
        console.log('Transaction sent:', tx.hash);
        const receipt = await tx.wait();
        console.log('Transaction confirmed in block:', receipt?.blockNumber);

        console.log('\n--- Checking status after ---');
        for (const u of users) {
            const isReg = await reg.isRegistered(u);
            console.log(`${u}: ${isReg ? 'STILL REGISTERED!' : 'UNREGISTERED'}`);
        }
    } catch (error) {
        console.error('Error:', error);
    }

    console.log('\n===========================================');
    console.log('Complete');
    console.log('===========================================');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
