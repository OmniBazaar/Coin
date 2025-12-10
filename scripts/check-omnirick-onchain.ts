import { ethers } from 'hardhat';

const REGISTRATION_PROXY = '0x0E4E697317117B150481a827f1e5029864aAe781';
const FAILED_ADDRESS = '0xD0F9115e4a95b1d57F3fAb95e812F195c8989c8a';

async function main() {
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(REGISTRATION_PROXY);

    console.log('Checking failed registration address:', FAILED_ADDRESS);
    
    const reg = await registration.getRegistration(FAILED_ADDRESS);
    console.log('Timestamp:', reg.timestamp.toString());
    console.log('Email hash:', reg.emailHash);
    
    if (reg.timestamp > 0) {
        console.log('\n✓ Address IS registered on-chain - unregistering...');
        const tx = await registration.adminUnregister(FAILED_ADDRESS);
        const receipt = await tx.wait();
        console.log('Unregistered in tx:', receipt?.hash);
        console.log('✓ Failed registration cleared');
    } else {
        console.log('\n✓ Address is NOT registered on-chain - database only');
        console.log('✓ Safe to proceed with new registration');
    }
}

main().catch(console.error);
