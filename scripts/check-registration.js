const { ethers } = require('hardhat');

async function main() {
    const proxyAddress = '0x0E4E697317117B150481a827f1e5029864aAe781';
    
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(proxyAddress);
    
    console.log('Checking OmniRegistration at:', proxyAddress);
    console.log('');
    
    // Check if selfRegister exists (in LOCAL compiled interface)
    try {
        const fragment = registration.interface.getFunction('selfRegister');
        console.log('❌ selfRegister STILL EXISTS in LOCAL interface');
    } catch (e) {
        console.log('✅ selfRegister REMOVED from LOCAL interface');
    }
    
    // Check if selfRegisterTrustless exists
    try {
        const fragment = registration.interface.getFunction('selfRegisterTrustless');
        console.log('✅ selfRegisterTrustless EXISTS in LOCAL interface');
    } catch (e) {
        console.log('❌ selfRegisterTrustless NOT FOUND in LOCAL interface');
    }
    
    // Try calling selfRegister on-chain to see if it reverts
    console.log('\n--- On-Chain Verification ---');
    try {
        // This will fail if selfRegister doesn't exist on-chain
        const code = await ethers.provider.getCode(proxyAddress);
        console.log('Contract bytecode length:', code.length);
        
        // Try to encode a call to selfRegister
        const iface = new ethers.Interface([
            'function selfRegister(address referrer, bytes32 emailHash, bytes32 phoneHash, uint256 deadline, bytes calldata validatorSignature)'
        ]);
        const calldata = iface.encodeFunctionData('selfRegister', [
            ethers.ZeroAddress,
            ethers.ZeroHash,
            ethers.ZeroHash,
            0,
            '0x'
        ]);
        
        // Try static call - if function doesn't exist, it will revert with different error
        const result = await ethers.provider.call({
            to: proxyAddress,
            data: calldata
        });
        console.log('❌ selfRegister EXISTS on-chain (call returned)');
    } catch (e) {
        if (e.message.includes('function selector was not recognized')) {
            console.log('✅ selfRegister REMOVED on-chain (function not recognized)');
        } else {
            console.log('selfRegister call error:', e.message.slice(0, 150));
        }
    }
    
    // Check EMAIL_VERIFICATION_TYPEHASH
    try {
        const typehash = await registration.EMAIL_VERIFICATION_TYPEHASH();
        console.log('✅ EMAIL_VERIFICATION_TYPEHASH:', typehash.slice(0, 20) + '...');
    } catch (e) {
        console.log('❌ EMAIL_VERIFICATION_TYPEHASH error:', e.message.slice(0, 100));
    }
    
    // Check trustedVerificationKey
    try {
        const key = await registration.trustedVerificationKey();
        console.log('trustedVerificationKey:', key === ethers.ZeroAddress ? '(NOT SET)' : key);
    } catch (e) {
        console.log('trustedVerificationKey error:', e.message.slice(0, 100));
    }
}

main().catch(console.error);
