/**
 * @file OmniRegistration.test.ts
 * @description Comprehensive tests for OmniRegistration contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - User registration (no deposit required)
 * - Phone/email uniqueness (Sybil protection)
 * - Referrer validation
 * - Daily rate limiting
 * - KYC attestation (multi-validator)
 * - Bonus claim marking
 * - Access control
 * - Self-registration with EIP-712 attestation
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, toUtf8Bytes, ZeroAddress } = require('ethers');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniRegistration', function () {
    // Contract instance
    let registration: any;

    // Signers
    let owner: any;
    let validator1: any;
    let validator2: any;
    let validator3: any;
    let validator4: any;
    let user1: any;
    let user2: any;
    let referrer: any;
    let unauthorized: any;

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
    const KYC_ATTESTOR_ROLE = keccak256(toUtf8Bytes('KYC_ATTESTOR_ROLE'));

    // Constants from contract
    const MAX_DAILY_REGISTRATIONS = 10000;
    const KYC_ATTESTATION_THRESHOLD = 3;
    const ATTESTATION_VALIDITY = 60 * 60; // 1 hour in seconds

    /**
     * Generate phone hash for testing
     */
    function phoneHash(phone: string): string {
        return keccak256(toUtf8Bytes(phone));
    }

    /**
     * Generate email hash for testing
     */
    function emailHash(email: string): string {
        return keccak256(toUtf8Bytes(email));
    }

    beforeEach(async function () {
        // Get signers
        [owner, validator1, validator2, validator3, validator4, user1, user2, referrer, unauthorized] =
            await ethers.getSigners();

        // Deploy OmniRegistration as proxy
        const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
        registration = await upgrades.deployProxy(OmniRegistration, [], {
            initializer: 'initialize',
            kind: 'uups',
        });
        await registration.waitForDeployment();

        // Grant roles
        await registration.grantRole(VALIDATOR_ROLE, validator1.address);
        await registration.grantRole(VALIDATOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator1.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator3.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator4.address);

        // Register referrer first (so they can be used as referrer)
        await registration.connect(validator1).registerUser(
            referrer.address,
            ZeroAddress, // No referrer for the first user
            phoneHash('+1-555-0000'),
            emailHash('referrer@test.com')
        );
    });

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            expect(await registration.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should have correct constants', async function () {
            expect(await registration.MAX_DAILY_REGISTRATIONS()).to.equal(MAX_DAILY_REGISTRATIONS);
            expect(await registration.KYC_ATTESTATION_THRESHOLD()).to.equal(KYC_ATTESTATION_THRESHOLD);
            expect(await registration.ATTESTATION_VALIDITY()).to.equal(ATTESTATION_VALIDITY);
        });

        it('should track total registrations', async function () {
            // One registration from beforeEach (referrer)
            expect(await registration.totalRegistrations()).to.equal(1);
        });
    });

    describe('User Registration', function () {
        it('should register user with valid data', async function () {
            const tx = await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                phoneHash('+1-555-1111'),
                emailHash('user1@test.com'),
            );

            await expect(tx)
                .to.emit(registration, 'UserRegistered')
                .withArgs(user1.address, referrer.address, validator1.address, await time.latest());

            expect(await registration.isRegistered(user1.address)).to.be.true;
            expect(await registration.totalRegistrations()).to.equal(2);
        });

        it('should register user without referrer', async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-2222'),
                emailHash('user2@test.com'),
            );

            const reg = await registration.getRegistration(user1.address);
            expect(reg.referrer).to.equal(ZeroAddress);
        });

        it('should set KYC tier 1 on registration', async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-3333'),
                emailHash('user3@test.com'),
            );

            const reg = await registration.getRegistration(user1.address);
            expect(reg.kycTier).to.equal(1);
        });

        it('should reject duplicate registration', async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-4444'),
                emailHash('user4@test.com'),
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    ZeroAddress,
                    phoneHash('+1-555-5555'),
                    emailHash('user5@test.com'),
                    )
            ).to.be.revertedWithCustomError(registration, 'AlreadyRegistered');
        });

        it('should reject duplicate phone hash', async function () {
            const phone = phoneHash('+1-555-6666');

            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phone,
                emailHash('user6@test.com'),
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phone, // Same phone
                    emailHash('user7@test.com'),
                    )
            ).to.be.revertedWithCustomError(registration, 'PhoneAlreadyUsed');
        });

        it('should reject duplicate email hash', async function () {
            const email = emailHash('duplicate@test.com');

            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-7777'),
                email,
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-8888'),
                    email, // Same email
                    )
            ).to.be.revertedWithCustomError(registration, 'EmailAlreadyUsed');
        });

        it('should reject self-referral', async function () {
            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    user1.address, // Self-referral
                    phoneHash('+1-555-1010'),
                    emailHash('user10@test.com'),
                    )
            ).to.be.revertedWithCustomError(registration, 'SelfReferralNotAllowed');
        });

        it('should reject unregistered referrer', async function () {
            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    user2.address, // user2 is not registered
                    phoneHash('+1-555-1111'),
                    emailHash('user11@test.com'),
                    )
            ).to.be.revertedWithCustomError(registration, 'InvalidReferrer');
        });

        it('should reject validator as referrer', async function () {
            // validator1 is processing the registration
            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    validator1.address, // validator1 trying to be referrer
                    phoneHash('+1-555-1212'),
                    emailHash('user12@test.com'),
                    )
            ).to.be.revertedWithCustomError(registration, 'ValidatorCannotBeReferrer');
        });

        it('should reject unauthorized caller', async function () {
            await expect(
                registration.connect(unauthorized).registerUser(
                    user1.address,
                    ZeroAddress,
                    phoneHash('+1-555-1313'),
                    emailHash('user13@test.com'),
                    )
            ).to.be.reverted;
        });
    });

    describe('KYC Attestation', function () {
        beforeEach(async function () {
            // Register user1 first
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-2000'),
                emailHash('kyc-user@test.com'),
            );
        });

        it('should record attestation', async function () {
            // validator2 attests (validator1 registered, so can't attest)
            await registration.connect(validator2).attestKYC(user1.address, 2);

            expect(await registration.getKYCAttestationCount(user1.address, 2)).to.equal(1);
        });

        it('should upgrade KYC after threshold attestations', async function () {
            // Need 3 attestations
            await registration.connect(validator2).attestKYC(user1.address, 2);
            await registration.connect(validator3).attestKYC(user1.address, 2);
            await registration.connect(validator4).attestKYC(user1.address, 2);

            const reg = await registration.getRegistration(user1.address);
            expect(reg.kycTier).to.equal(2);
        });

        it('should emit KYCUpgraded event', async function () {
            await registration.connect(validator2).attestKYC(user1.address, 2);
            await registration.connect(validator3).attestKYC(user1.address, 2);

            await expect(registration.connect(validator4).attestKYC(user1.address, 2))
                .to.emit(registration, 'KYCUpgraded')
                .withArgs(user1.address, 1, 2);
        });

        it('should reject attestor who registered the user', async function () {
            // validator1 registered user1, so can't attest
            await expect(
                registration.connect(validator1).attestKYC(user1.address, 2)
            ).to.be.revertedWithCustomError(registration, 'ValidatorCannotBeReferrer');
        });

        it('should reject duplicate attestation', async function () {
            await registration.connect(validator2).attestKYC(user1.address, 2);

            await expect(
                registration.connect(validator2).attestKYC(user1.address, 2)
            ).to.be.revertedWithCustomError(registration, 'AlreadyAttested');
        });

        it('should reject invalid KYC tier', async function () {
            await expect(
                registration.connect(validator2).attestKYC(user1.address, 0)
            ).to.be.revertedWithCustomError(registration, 'InvalidKYCTier');

            await expect(
                registration.connect(validator2).attestKYC(user1.address, 5)
            ).to.be.revertedWithCustomError(registration, 'InvalidKYCTier');
        });

        it('should reject downgrade attestation', async function () {
            // Upgrade to tier 2
            await registration.connect(validator2).attestKYC(user1.address, 2);
            await registration.connect(validator3).attestKYC(user1.address, 2);
            await registration.connect(validator4).attestKYC(user1.address, 2);

            // Try to attest tier 2 again
            await expect(
                registration.connect(validator2).attestKYC(user1.address, 2)
            ).to.be.revertedWithCustomError(registration, 'InvalidKYCTier');
        });
    });

    describe('Bonus Eligibility', function () {
        beforeEach(async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                phoneHash('+1-555-4000'),
                emailHash('bonus-user@test.com')
            );
        });

        it('should allow bonus claim immediately after registration', async function () {
            // Registered user with KYC tier 1 can claim welcome bonus immediately
            expect(await registration.canClaimWelcomeBonus(user1.address)).to.be.true;
        });

        it('should not allow bonus claim for unregistered user', async function () {
            expect(await registration.canClaimWelcomeBonus(user2.address)).to.be.false;
        });

        it('should return correct referrer', async function () {
            expect(await registration.getReferrer(user1.address)).to.equal(referrer.address);
        });
    });

    describe('Self-Registration with EIP-712 Attestation', function () {
        /**
         * Helper to create EIP-712 attestation signature
         */
        async function createAttestation(
            signer: any,
            user: string,
            emailHashVal: string,
            phoneHashVal: string,
            referrerAddr: string,
            deadline: number
        ): Promise<string> {
            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then((n: any) => n.chainId);

            // EIP-712 domain
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: registrationAddress,
            };

            // EIP-712 types
            const types = {
                RegistrationAttestation: [
                    { name: 'user', type: 'address' },
                    { name: 'emailHash', type: 'bytes32' },
                    { name: 'phoneHash', type: 'bytes32' },
                    { name: 'referrer', type: 'address' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            // EIP-712 value
            const value = {
                user: user,
                emailHash: emailHashVal,
                phoneHash: phoneHashVal,
                referrer: referrerAddr,
                deadline: deadline,
            };

            // Sign EIP-712 typed data
            return await signer.signTypedData(domain, types, value);
        }

        it('should self-register with valid attestation', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('self-register@test.com');
            const phoneHashVal = phoneHash('+1-555-5000');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                referrer.address,
                deadline
            );

            const tx = await registration.connect(user1).selfRegister(
                referrer.address,
                emailHashVal,
                phoneHashVal,
                deadline,
                signature
            );

            await expect(tx)
                .to.emit(registration, 'UserRegistered')
                .withArgs(user1.address, referrer.address, validator1.address, await time.latest());

            expect(await registration.isRegistered(user1.address)).to.be.true;
            expect(await registration.getReferrer(user1.address)).to.equal(referrer.address);
        });

        it('should self-register without referrer', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('no-referrer@test.com');
            const phoneHashVal = phoneHash('+1-555-5001');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                ZeroAddress,
                deadline
            );

            await registration.connect(user1).selfRegister(
                ZeroAddress,
                emailHashVal,
                phoneHashVal,
                deadline,
                signature
            );

            expect(await registration.isRegistered(user1.address)).to.be.true;
            expect(await registration.getReferrer(user1.address)).to.equal(ZeroAddress);
        });

        it('should reject expired attestation', async function () {
            // Create attestation that expires in 1 second
            const deadline = (await time.latest()) + 1;
            const emailHashVal = emailHash('expired@test.com');
            const phoneHashVal = phoneHash('+1-555-5002');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                ZeroAddress,
                deadline
            );

            // Wait for attestation to expire
            await time.increase(2);

            await expect(
                registration.connect(user1).selfRegister(
                    ZeroAddress,
                    emailHashVal,
                    phoneHashVal,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'AttestationExpired');
        });

        it('should reject replay of used attestation', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('replay@test.com');
            const phoneHashVal = phoneHash('+1-555-5003');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                ZeroAddress,
                deadline
            );

            // First registration succeeds
            await registration.connect(user1).selfRegister(
                ZeroAddress,
                emailHashVal,
                phoneHashVal,
                deadline,
                signature
            );

            // Create new user for replay attempt
            const emailHashVal2 = emailHash('replay2@test.com');
            const phoneHashVal2 = phoneHash('+1-555-5004');

            // Try to use same signature for user2 (should fail)
            // Note: The signature is bound to user1.address, so it won't work for user2
            await expect(
                registration.connect(user2).selfRegister(
                    ZeroAddress,
                    emailHashVal2,
                    phoneHashVal2,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'InvalidAttestation');
        });

        it('should reject invalid signature', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('invalid-sig@test.com');
            const phoneHashVal = phoneHash('+1-555-5005');

            // Create attestation from validator1 but for user2
            const signature = await createAttestation(
                validator1,
                user2.address, // Wrong user
                emailHashVal,
                phoneHashVal,
                ZeroAddress,
                deadline
            );

            // user1 tries to use it (should fail)
            await expect(
                registration.connect(user1).selfRegister(
                    ZeroAddress,
                    emailHashVal,
                    phoneHashVal,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'InvalidAttestation');
        });

        it('should reject signature from non-validator', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('non-validator@test.com');
            const phoneHashVal = phoneHash('+1-555-5006');

            // Create attestation from unauthorized signer
            const signature = await createAttestation(
                unauthorized,
                user1.address,
                emailHashVal,
                phoneHashVal,
                ZeroAddress,
                deadline
            );

            await expect(
                registration.connect(user1).selfRegister(
                    ZeroAddress,
                    emailHashVal,
                    phoneHashVal,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'InvalidAttestation');
        });

        it('should reject duplicate email hash', async function () {
            // First registration
            const deadline1 = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('duplicate@test.com');
            const phoneHashVal1 = phoneHash('+1-555-5007');

            const signature1 = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal1,
                ZeroAddress,
                deadline1
            );

            await registration.connect(user1).selfRegister(
                ZeroAddress,
                emailHashVal,
                phoneHashVal1,
                deadline1,
                signature1
            );

            // Second registration with same email
            const deadline2 = (await time.latest()) + ATTESTATION_VALIDITY;
            const phoneHashVal2 = phoneHash('+1-555-5008');

            const signature2 = await createAttestation(
                validator1,
                user2.address,
                emailHashVal, // Same email
                phoneHashVal2,
                ZeroAddress,
                deadline2
            );

            await expect(
                registration.connect(user2).selfRegister(
                    ZeroAddress,
                    emailHashVal,
                    phoneHashVal2,
                    deadline2,
                    signature2
                )
            ).to.be.revertedWithCustomError(registration, 'EmailAlreadyUsed');
        });

        it('should reject duplicate phone hash', async function () {
            // First registration
            const deadline1 = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal1 = emailHash('phone-dup1@test.com');
            const phoneHashVal = phoneHash('+1-555-5009');

            const signature1 = await createAttestation(
                validator1,
                user1.address,
                emailHashVal1,
                phoneHashVal,
                ZeroAddress,
                deadline1
            );

            await registration.connect(user1).selfRegister(
                ZeroAddress,
                emailHashVal1,
                phoneHashVal,
                deadline1,
                signature1
            );

            // Second registration with same phone
            const deadline2 = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal2 = emailHash('phone-dup2@test.com');

            const signature2 = await createAttestation(
                validator1,
                user2.address,
                emailHashVal2,
                phoneHashVal, // Same phone
                ZeroAddress,
                deadline2
            );

            await expect(
                registration.connect(user2).selfRegister(
                    ZeroAddress,
                    emailHashVal2,
                    phoneHashVal,
                    deadline2,
                    signature2
                )
            ).to.be.revertedWithCustomError(registration, 'PhoneAlreadyUsed');
        });

        it('should reject self-referral', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('self-ref@test.com');
            const phoneHashVal = phoneHash('+1-555-5010');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                user1.address, // Self-referral
                deadline
            );

            await expect(
                registration.connect(user1).selfRegister(
                    user1.address,
                    emailHashVal,
                    phoneHashVal,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'SelfReferralNotAllowed');
        });

        it('should reject unregistered referrer', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('bad-ref@test.com');
            const phoneHashVal = phoneHash('+1-555-5011');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                user2.address, // user2 not registered
                deadline
            );

            await expect(
                registration.connect(user1).selfRegister(
                    user2.address,
                    emailHashVal,
                    phoneHashVal,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'InvalidReferrer');
        });

        it('should reject already registered user', async function () {
            // First registration
            const deadline1 = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal1 = emailHash('first@test.com');
            const phoneHashVal1 = phoneHash('+1-555-5012');

            const signature1 = await createAttestation(
                validator1,
                user1.address,
                emailHashVal1,
                phoneHashVal1,
                ZeroAddress,
                deadline1
            );

            await registration.connect(user1).selfRegister(
                ZeroAddress,
                emailHashVal1,
                phoneHashVal1,
                deadline1,
                signature1
            );

            // Try to register again
            const deadline2 = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal2 = emailHash('second@test.com');
            const phoneHashVal2 = phoneHash('+1-555-5013');

            const signature2 = await createAttestation(
                validator1,
                user1.address,
                emailHashVal2,
                phoneHashVal2,
                ZeroAddress,
                deadline2
            );

            await expect(
                registration.connect(user1).selfRegister(
                    ZeroAddress,
                    emailHashVal2,
                    phoneHashVal2,
                    deadline2,
                    signature2
                )
            ).to.be.revertedWithCustomError(registration, 'AlreadyRegistered');
        });

        it('should set correct registration data', async function () {
            const deadline = (await time.latest()) + ATTESTATION_VALIDITY;
            const emailHashVal = emailHash('complete@test.com');
            const phoneHashVal = phoneHash('+1-555-5014');

            const signature = await createAttestation(
                validator1,
                user1.address,
                emailHashVal,
                phoneHashVal,
                referrer.address,
                deadline
            );

            await registration.connect(user1).selfRegister(
                referrer.address,
                emailHashVal,
                phoneHashVal,
                deadline,
                signature
            );

            const reg = await registration.getRegistration(user1.address);
            expect(reg.referrer).to.equal(referrer.address);
            expect(reg.registeredBy).to.equal(validator1.address);
            expect(reg.emailHash).to.equal(emailHashVal);
            expect(reg.phoneHash).to.equal(phoneHashVal);
            expect(reg.kycTier).to.equal(1);
            expect(reg.welcomeBonusClaimed).to.be.false;
            expect(reg.firstSaleBonusClaimed).to.be.false;
        });
    });

    describe('Admin Unregistration', function () {
        beforeEach(async function () {
            // Register user1
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                phoneHash('+1-555-6000'),
                emailHash('unregister-user@test.com')
            );
        });

        it('should unregister user and clear hashes', async function () {
            const emailHashVal = emailHash('unregister-user@test.com');
            const phoneHashVal = phoneHash('+1-555-6000');

            // Verify user is registered
            expect(await registration.isRegistered(user1.address)).to.be.true;

            // Admin unregisters user
            const tx = await registration.connect(owner).adminUnregister(user1.address);

            await expect(tx)
                .to.emit(registration, 'UserUnregistered')
                .withArgs(user1.address, owner.address, await time.latest());

            // Verify user is no longer registered
            expect(await registration.isRegistered(user1.address)).to.be.false;

            // Verify email and phone hashes are cleared (can re-register with same)
            await registration.connect(validator1).registerUser(
                user2.address,
                referrer.address,
                phoneHashVal, // Same phone - should work now
                emailHashVal  // Same email - should work now
            );

            expect(await registration.isRegistered(user2.address)).to.be.true;
        });

        it('should decrement total registrations', async function () {
            const countBefore = await registration.totalRegistrations();

            await registration.connect(owner).adminUnregister(user1.address);

            expect(await registration.totalRegistrations()).to.equal(countBefore - 1n);
        });

        it('should reject unregistration of non-registered user', async function () {
            await expect(
                registration.connect(owner).adminUnregister(user2.address)
            ).to.be.revertedWithCustomError(registration, 'NotRegistered');
        });

        it('should reject unauthorized caller', async function () {
            await expect(
                registration.connect(unauthorized).adminUnregister(user1.address)
            ).to.be.reverted;
        });

        it('should batch unregister multiple users', async function () {
            // Register user2
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-6001'),
                emailHash('unregister-user2@test.com')
            );

            const countBefore = await registration.totalRegistrations();

            // Batch unregister both users
            await registration.connect(owner).adminUnregisterBatch([user1.address, user2.address]);

            expect(await registration.isRegistered(user1.address)).to.be.false;
            expect(await registration.isRegistered(user2.address)).to.be.false;
            expect(await registration.totalRegistrations()).to.equal(countBefore - 2n);
        });

        it('should skip already unregistered users in batch', async function () {
            // Register user2
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-6002'),
                emailHash('unregister-user3@test.com')
            );

            // Unregister user1 first
            await registration.connect(owner).adminUnregister(user1.address);

            // Batch should still work (skips user1)
            await registration.connect(owner).adminUnregisterBatch([user1.address, user2.address]);

            expect(await registration.isRegistered(user2.address)).to.be.false;
        });
    });
});
