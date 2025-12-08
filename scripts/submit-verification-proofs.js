/**
 * Submit verification proofs for a user who has already verified
 * but whose proofs were not submitted on-chain.
 *
 * Usage: npx hardhat run scripts/submit-verification-proofs.js --network fuji
 */

const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

// User address to submit proofs for
const USER_ADDRESS = '0xe89d532934D7771976Ae3530292c9a854ef6449D';

// Phone number and Twitter handle from database
const PHONE_NUMBER = '+50769707932';
const TWITTER_HANDLE = '@TitansClubNFT';

async function main() {
    console.log('======================================');
    console.log('Submit Verification Proofs for User');
    console.log('======================================\n');

    // Get addresses
    const deployments = JSON.parse(
        fs.readFileSync(path.join(__dirname, '../deployments/fuji.json'), 'utf8')
    );

    const contracts = deployments.contracts || deployments;
    const omniRegistrationAddress = contracts.OmniRegistration || contracts.OmniRegistrationProxy;
    if (!omniRegistrationAddress) {
        throw new Error('OmniRegistration contract not found in deployments');
    }

    console.log('OmniRegistration Address:', omniRegistrationAddress);
    console.log('User Address:', USER_ADDRESS);

    // Get signer (validator wallet)
    const [signer] = await ethers.getSigners();
    console.log('Signer Address:', signer.address);

    // Get verification private key
    const verificationPrivateKey = process.env.VERIFICATION_PRIVATE_KEY;
    if (!verificationPrivateKey) {
        throw new Error('VERIFICATION_PRIVATE_KEY environment variable not set');
    }

    const verificationWallet = new ethers.Wallet(verificationPrivateKey, ethers.provider);
    console.log('Verification Signer Address:', verificationWallet.address);

    // Get contract
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const contract = OmniRegistration.attach(omniRegistrationAddress);

    // Check current state
    console.log('\n--- Current On-Chain State ---');
    const hasKycTier1 = await contract.hasKycTier1(USER_ADDRESS);
    console.log('hasKycTier1:', hasKycTier1);

    const userSocialHashes = await contract.userSocialHashes(USER_ADDRESS);
    console.log('userSocialHashes:', userSocialHashes);

    const kycTier1CompletedAt = await contract.kycTier1CompletedAt(USER_ADDRESS);
    console.log('kycTier1CompletedAt:', kycTier1CompletedAt.toString());

    // Get trusted verification key
    const trustedKey = await contract.trustedVerificationKey();
    console.log('trustedVerificationKey:', trustedKey);

    if (trustedKey.toLowerCase() !== verificationWallet.address.toLowerCase()) {
        throw new Error(`Verification wallet (${verificationWallet.address}) does not match trusted key (${trustedKey})`);
    }

    console.log('✅ Verification key matches');

    // Create EIP-712 domain
    const domain = {
        name: 'OmniRegistration',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: omniRegistrationAddress
    };

    console.log('\n--- Creating Proofs ---');

    // Generate phone verification proof
    const phoneHash = ethers.keccak256(ethers.toUtf8Bytes(PHONE_NUMBER));
    const phoneTimestamp = Math.floor(Date.now() / 1000);
    const phoneNonce = ethers.hexlify(ethers.randomBytes(32));
    const phoneDeadline = phoneTimestamp + 3600; // 1 hour from now

    console.log('Phone Hash:', phoneHash);
    console.log('Phone Timestamp:', phoneTimestamp);
    console.log('Phone Deadline:', phoneDeadline);

    const phoneTypes = {
        PhoneVerification: [
            { name: 'user', type: 'address' },
            { name: 'phoneHash', type: 'bytes32' },
            { name: 'timestamp', type: 'uint256' },
            { name: 'nonce', type: 'bytes32' },
            { name: 'deadline', type: 'uint256' }
        ]
    };

    const phoneValue = {
        user: USER_ADDRESS,
        phoneHash: phoneHash,
        timestamp: phoneTimestamp,
        nonce: phoneNonce,
        deadline: phoneDeadline
    };

    const phoneSignature = await verificationWallet.signTypedData(domain, phoneTypes, phoneValue);
    console.log('Phone Signature:', phoneSignature.substring(0, 20) + '...');

    // Generate social verification proof
    const socialHash = ethers.keccak256(ethers.toUtf8Bytes(`twitter:${TWITTER_HANDLE.toLowerCase()}`));
    const socialTimestamp = Math.floor(Date.now() / 1000);
    const socialNonce = ethers.hexlify(ethers.randomBytes(32));
    const socialDeadline = socialTimestamp + 3600; // 1 hour from now
    const platform = 'twitter';

    console.log('\nSocial Hash:', socialHash);
    console.log('Social Timestamp:', socialTimestamp);
    console.log('Social Deadline:', socialDeadline);
    console.log('Platform:', platform);

    const socialTypes = {
        SocialVerification: [
            { name: 'user', type: 'address' },
            { name: 'socialHash', type: 'bytes32' },
            { name: 'platform', type: 'string' },
            { name: 'timestamp', type: 'uint256' },
            { name: 'nonce', type: 'bytes32' },
            { name: 'deadline', type: 'uint256' }
        ]
    };

    const socialValue = {
        user: USER_ADDRESS,
        socialHash: socialHash,
        platform: platform,
        timestamp: socialTimestamp,
        nonce: socialNonce,
        deadline: socialDeadline
    };

    const socialSignature = await verificationWallet.signTypedData(domain, socialTypes, socialValue);
    console.log('Social Signature:', socialSignature.substring(0, 20) + '...');

    // Submit phone verification using RELAY function (submitPhoneVerificationFor)
    console.log('\n--- Submitting Phone Verification (Relay Pattern) ---');
    try {
        // Use submitPhoneVerificationFor - allows anyone to relay
        const tx1 = await contract.connect(signer).submitPhoneVerificationFor(
            USER_ADDRESS,
            phoneHash,
            phoneTimestamp,
            phoneNonce,
            phoneDeadline,
            phoneSignature
        );
        console.log('TX Hash:', tx1.hash);
        const receipt1 = await tx1.wait();
        console.log('✅ Phone verification submitted (relayed), block:', receipt1.blockNumber);
    } catch (error) {
        console.log('❌ Phone verification failed:', error.message);
        if (error.message.includes('Phone already')) {
            console.log('  (Phone was already verified on-chain)');
        }
    }

    // Submit social verification using RELAY function (submitSocialVerificationFor)
    console.log('\n--- Submitting Social Verification (Relay Pattern) ---');
    try {
        // Use submitSocialVerificationFor - allows anyone to relay
        const tx2 = await contract.connect(signer).submitSocialVerificationFor(
            USER_ADDRESS,
            socialHash,
            platform,
            socialTimestamp,
            socialNonce,
            socialDeadline,
            socialSignature
        );
        console.log('TX Hash:', tx2.hash);
        const receipt2 = await tx2.wait();
        console.log('✅ Social verification submitted (relayed), block:', receipt2.blockNumber);
    } catch (error) {
        console.log('❌ Social verification failed:', error.message);
        if (error.message.includes('Social') || error.message.includes('already')) {
            console.log('  (Social was already verified on-chain)');
        }
    }

    // Check final state
    console.log('\n--- Final On-Chain State ---');
    const finalHasKycTier1 = await contract.hasKycTier1(USER_ADDRESS);
    console.log('hasKycTier1:', finalHasKycTier1);

    const finalUserSocialHashes = await contract.userSocialHashes(USER_ADDRESS);
    console.log('userSocialHashes:', finalUserSocialHashes);

    const finalKycTier1CompletedAt = await contract.kycTier1CompletedAt(USER_ADDRESS);
    console.log('kycTier1CompletedAt:', finalKycTier1CompletedAt.toString());

    if (finalHasKycTier1) {
        console.log('\n✅ SUCCESS: User now has KYC Tier 1 on-chain!');
    } else {
        console.log('\n⚠️ User still does not have KYC Tier 1.');
        console.log('  Both phone AND social verification must be completed.');
    }

    // Check canClaimWelcomeBonus
    const canClaim = await contract.canClaimWelcomeBonus(USER_ADDRESS);
    console.log('canClaimWelcomeBonus:', canClaim);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
