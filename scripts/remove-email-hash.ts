import { ethers } from 'hardhat';

const REGISTRATION_PROXY = '0x0E4E697317117B150481a827f1e5029864aAe781';
const EMAIL = 'rickcrites@usa.net';

async function main() {
    const [admin] = await ethers.getSigners();
    console.log('Admin:', await admin.getAddress());

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(REGISTRATION_PROXY);

    // Calculate email hash
    const emailHash = ethers.keccak256(ethers.toUtf8Bytes(EMAIL.toLowerCase().trim()));
    console.log('Email:', EMAIL);
    console.log('Email hash:', emailHash);

    // Check if it's used
    const isUsed = await registration.usedEmailHashes(emailHash);
    console.log('Currently used:', isUsed);

    if (isUsed) {
        console.log('\nRemoving email hash from usedEmailHashes...');
        const tx = await registration.removeUsedEmailHash(emailHash);
        const receipt = await tx.wait();
        console.log('Removed in tx:', receipt?.hash);

        const stillUsed = await registration.usedEmailHashes(emailHash);
        console.log('Still used:', stillUsed);
        console.log(stillUsed ? '✗ Failed to remove' : '✓ Successfully removed');
    } else {
        console.log('Email hash is not marked as used');
    }
}

main().catch(console.error);
