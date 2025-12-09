const { ethers } = require('hardhat');

async function main() {
    const proxyAddress = '0x0E4E697317117B150481a827f1e5029864aAe781';
    const verificationKeyAddress = '0xE13a2D66736805Fd57F765E82370C5d7b0FBdE54';
    
    console.log('Setting trustedVerificationKey on OmniRegistration...');
    console.log('Proxy:', proxyAddress);
    console.log('Verification Key:', verificationKeyAddress);
    
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(proxyAddress);
    
    // Check current key
    const currentKey = await registration.trustedVerificationKey();
    console.log('Current trustedVerificationKey:', currentKey);
    
    if (currentKey.toLowerCase() === verificationKeyAddress.toLowerCase()) {
        console.log('Verification key already set correctly');
        return;
    }
    
    // Set the new key
    console.log('Setting new trustedVerificationKey...');
    const tx = await registration.setTrustedVerificationKey(verificationKeyAddress);
    console.log('Transaction:', tx.hash);
    await tx.wait();
    console.log('Transaction confirmed');
    
    // Verify
    const newKey = await registration.trustedVerificationKey();
    console.log('New trustedVerificationKey:', newKey);
    
    if (newKey.toLowerCase() === verificationKeyAddress.toLowerCase()) {
        console.log('✅ Verification key set successfully');
    } else {
        console.log('❌ Verification key mismatch!');
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Error:', error);
        process.exit(1);
    });
