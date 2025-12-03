/**
 * @file verify-registration-upgrade.ts
 * @description Verify OmniRegistration upgrade and check existing registrations
 */

import { ethers, upgrades } from 'hardhat';

async function main(): Promise<void> {
    console.log('========================================');
    console.log('Verifying OmniRegistration Upgrade');
    console.log('========================================\n');

    const proxyAddr = '0x0E4E697317117B150481a827f1e5029864aAe781';

    // Get implementation address
    const impl = await upgrades.erc1967.getImplementationAddress(proxyAddr);
    console.log('Implementation address:', impl);

    // Attach to proxy
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const proxy = OmniRegistration.attach(proxyAddr);

    // Check EIP-712 support
    const domainSep = await proxy.DOMAIN_SEPARATOR();
    console.log('DOMAIN_SEPARATOR:', domainSep);

    if (domainSep === ethers.ZeroHash) {
        console.log('ERROR: DOMAIN_SEPARATOR not set!');
        process.exit(1);
    }

    const typeHash = await proxy.REGISTRATION_ATTESTATION_TYPEHASH();
    console.log('REGISTRATION_ATTESTATION_TYPEHASH:', typeHash);

    const attestationValidity = await proxy.ATTESTATION_VALIDITY();
    console.log('ATTESTATION_VALIDITY:', attestationValidity.toString(), 'seconds');

    // Check existing registrations
    console.log('\n--- Checking existing registrations ---');

    // Convert to proper checksummed addresses
    const existingUsers = [
        '0x59fBfB4C1C1E6f4a6A64f3AC6F066E5c85CDf0b3'.toLowerCase(),
        '0xd6B6D5E3096d4dFB77CA6E0E4D2e18B61f21e5a6'.toLowerCase(),
        '0x52a9Eb5bc3a68A6cef0D47c3f574Cd00daB8B8a4'.toLowerCase(),
    ].map(addr => ethers.getAddress(addr));

    for (const user of existingUsers) {
        const reg = await proxy.registrations(user);
        if (reg.timestamp > 0) {
            console.log(`User ${user}:`);
            console.log(`  - Registered at: ${new Date(Number(reg.timestamp) * 1000).toISOString()}`);
            console.log(`  - Eligible for bonus: ${reg.eligibleForWelcomeBonus}`);
            console.log(`  - Bonus claimed: ${reg.welcomeBonusClaimed}`);
        } else {
            console.log(`User ${user}: NOT REGISTERED`);
        }
    }

    // Check today's registrations
    const todayCount = await proxy.getTodayRegistrationCount();
    console.log(`\nToday's registration count: ${todayCount.toString()}`);

    console.log('\n========================================');
    console.log('Upgrade Verified Successfully!');
    console.log('selfRegister with EIP-712 attestations is now available');
    console.log('========================================\n');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Verification failed:', error);
        process.exit(1);
    });
