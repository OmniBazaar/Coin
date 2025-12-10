import { ethers } from 'hardhat';

const REGISTRATION_PROXY = '0x0E4E697317117B150481a827f1e5029864aAe781';
const EMAIL = 'rickcrites@usa.net';
const OLD_OMNIRICK_ADDRESS = '0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83';

async function main() {
    const [admin] = await ethers.getSigners();
    console.log('Admin:', await admin.getAddress());

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(REGISTRATION_PROXY);

    // Calculate email hash
    const emailHash = ethers.keccak256(ethers.toUtf8Bytes(EMAIL.toLowerCase().trim()));
    console.log('\nEmail:', EMAIL);
    console.log('Email hash:', emailHash);
    console.log('Old omnirick address:', OLD_OMNIRICK_ADDRESS);

    // Check if email is used
    const isUsed = await registration.usedEmailHashes(emailHash);
    console.log('\nEmail hash is used:', isUsed);

    // Check if old address is registered
    const reg = await registration.getRegistration(OLD_OMNIRICK_ADDRESS);
    console.log('\nOld address registration:');
    console.log('  Timestamp:', reg.timestamp.toString());
    console.log('  Email hash:', reg.emailHash);
    console.log('  Matches:', reg.emailHash === emailHash);

    if (reg.timestamp > 0) {
        console.log('\n✓ Old omnirick address IS registered on-chain');
        console.log('  Unregistering to free up email...');
        
        const tx = await registration.adminUnregister(OLD_OMNIRICK_ADDRESS);
        const receipt = await tx.wait();
        console.log('  Unregistered in tx:', receipt?.hash);

        // Verify
        const stillUsed = await registration.usedEmailHashes(emailHash);
        console.log('  Email still used:', stillUsed);
        console.log(stillUsed ? '  ✗ Failed' : '  ✓ Email freed for re-use');
    } else {
        console.log('\n✗ Old address is NOT registered on-chain');
        console.log('   Email may be orphaned in usedEmailHashes');
        console.log('   Need to add admin function to clear orphaned hashes');
    }
}

main().catch(console.error);
