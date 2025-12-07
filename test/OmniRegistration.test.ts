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

    describe('Trustless Verification', function () {
        // Additional signers for verification
        let verificationKey: any;

        /**
         * Create EIP-712 phone verification signature
         */
        async function createPhoneVerificationSignature(
            signer: any,
            user: string,
            phoneHashVal: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then((n: any) => n.chainId);

            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: registrationAddress,
            };

            const types = {
                PhoneVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'phoneHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user: user,
                phoneHash: phoneHashVal,
                timestamp: timestamp,
                nonce: nonce,
                deadline: deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Create EIP-712 social verification signature
         */
        async function createSocialVerificationSignature(
            signer: any,
            user: string,
            socialHashVal: string,
            platform: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then((n: any) => n.chainId);

            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: registrationAddress,
            };

            const types = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user: user,
                socialHash: socialHashVal,
                platform: platform,
                timestamp: timestamp,
                nonce: nonce,
                deadline: deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Generate a unique nonce
         */
        function generateNonce(): string {
            return keccak256(toUtf8Bytes(`nonce-${Date.now()}-${Math.random()}`));
        }

        /**
         * Generate social hash for testing
         */
        function socialHash(platform: string, handle: string): string {
            return keccak256(toUtf8Bytes(`${platform}:${handle}`));
        }

        beforeEach(async function () {
            // Get a dedicated verification key (distinct from validators)
            const signers = await ethers.getSigners();
            verificationKey = signers[9]; // Use signer index 9 as verification key

            // Set trusted verification key
            await registration.connect(owner).setTrustedVerificationKey(verificationKey.address);

            // Register user1 first so they can use verification functions
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-7000'),
                emailHash('trustless-user@test.com')
            );
        });

        describe('setTrustedVerificationKey', function () {
            it('should set trusted verification key', async function () {
                const newKey = user2.address;

                const tx = await registration.connect(owner).setTrustedVerificationKey(newKey);

                await expect(tx)
                    .to.emit(registration, 'TrustedVerificationKeyUpdated')
                    .withArgs(newKey);

                expect(await registration.trustedVerificationKey()).to.equal(newKey);
            });

            it('should reject unauthorized caller', async function () {
                await expect(
                    registration.connect(unauthorized).setTrustedVerificationKey(user2.address)
                ).to.be.reverted;
            });
        });

        describe('submitPhoneVerification', function () {
            it('should verify phone with valid signature', async function () {
                // Register a new user without phone verified yet
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash, // No phone hash
                    emailHash('phone-test@test.com')
                );

                const newPhoneHash = phoneHash('+1-555-7001');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600; // 1 hour from now

                const signature = await createPhoneVerificationSignature(
                    verificationKey,
                    user2.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                const tx = await registration.connect(user2).submitPhoneVerification(
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                await expect(tx)
                    .to.emit(registration, 'PhoneVerified')
                    .withArgs(user2.address, newPhoneHash, timestamp);
            });

            it('should reject expired proof', async function () {
                const newPhoneHash = phoneHash('+1-555-7002');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 1; // Expires in 1 second

                const signature = await createPhoneVerificationSignature(
                    verificationKey,
                    user1.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                // Wait for deadline to pass
                await time.increase(2);

                await expect(
                    registration.connect(user1).submitPhoneVerification(
                        newPhoneHash,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(registration, 'ProofExpired');
            });

            it('should reject reused nonce', async function () {
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('nonce-test@test.com')
                );

                const newPhoneHash = phoneHash('+1-555-7003');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature1 = await createPhoneVerificationSignature(
                    verificationKey,
                    user2.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                // First submission succeeds
                await registration.connect(user2).submitPhoneVerification(
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline,
                    signature1
                );

                // Try to reuse nonce with different phone
                const newPhoneHash2 = phoneHash('+1-555-7004');
                const signature2 = await createPhoneVerificationSignature(
                    verificationKey,
                    user1.address,
                    newPhoneHash2,
                    timestamp,
                    nonce, // Same nonce
                    deadline
                );

                await expect(
                    registration.connect(user1).submitPhoneVerification(
                        newPhoneHash2,
                        timestamp,
                        nonce,
                        deadline,
                        signature2
                    )
                ).to.be.revertedWithCustomError(registration, 'NonceAlreadyUsed');
            });

            it('should reject invalid signature', async function () {
                const newPhoneHash = phoneHash('+1-555-7005');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                // Sign with wrong signer (unauthorized instead of verificationKey)
                const signature = await createPhoneVerificationSignature(
                    unauthorized,
                    user1.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                await expect(
                    registration.connect(user1).submitPhoneVerification(
                        newPhoneHash,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(registration, 'InvalidVerificationProof');
            });

            it('should reject if trusted verification key not set', async function () {
                // Deploy fresh contract without verification key
                const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
                const freshRegistration = await upgrades.deployProxy(OmniRegistration, [], {
                    initializer: 'initialize',
                    kind: 'uups',
                });
                await freshRegistration.waitForDeployment();

                const newPhoneHash = phoneHash('+1-555-7006');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createPhoneVerificationSignature(
                    verificationKey,
                    user1.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                await expect(
                    freshRegistration.connect(user1).submitPhoneVerification(
                        newPhoneHash,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(freshRegistration, 'TrustedVerificationKeyNotSet');
            });

            it('should reject phone hash already used', async function () {
                // user1 already has phone verified from beforeEach
                const existingPhoneHash = phoneHash('+1-555-7000'); // Same as user1's phone

                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createPhoneVerificationSignature(
                    verificationKey,
                    user2.address,
                    existingPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                // Register user2 first
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('dup-phone@test.com')
                );

                await expect(
                    registration.connect(user2).submitPhoneVerification(
                        existingPhoneHash,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(registration, 'PhoneAlreadyUsed');
            });
        });

        describe('submitSocialVerification', function () {
            it('should verify social with valid signature', async function () {
                const socialHashVal = socialHash('twitter', 'user1handle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                const tx = await registration.connect(user1).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                await expect(tx)
                    .to.emit(registration, 'SocialVerified')
                    .withArgs(user1.address, socialHashVal, platform, timestamp);

                expect(await registration.userSocialHashes(user1.address)).to.equal(socialHashVal);
            });

            it('should reject expired proof', async function () {
                const socialHashVal = socialHash('twitter', 'expiredhandle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 1;

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                await time.increase(2);

                await expect(
                    registration.connect(user1).submitSocialVerification(
                        socialHashVal,
                        platform,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(registration, 'ProofExpired');
            });

            it('should reject reused nonce', async function () {
                const socialHashVal = socialHash('twitter', 'noncehandle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature1 = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                // First submission
                await registration.connect(user1).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature1
                );

                // Register user2 and try to reuse nonce
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-7010'),
                    emailHash('social-nonce@test.com')
                );

                const socialHashVal2 = socialHash('twitter', 'user2handle');
                const signature2 = await createSocialVerificationSignature(
                    verificationKey,
                    user2.address,
                    socialHashVal2,
                    platform,
                    timestamp,
                    nonce, // Same nonce
                    deadline
                );

                await expect(
                    registration.connect(user2).submitSocialVerification(
                        socialHashVal2,
                        platform,
                        timestamp,
                        nonce,
                        deadline,
                        signature2
                    )
                ).to.be.revertedWithCustomError(registration, 'NonceAlreadyUsed');
            });

            it('should reject invalid signature', async function () {
                const socialHashVal = socialHash('twitter', 'invalidhandle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createSocialVerificationSignature(
                    unauthorized, // Wrong signer
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                await expect(
                    registration.connect(user1).submitSocialVerification(
                        socialHashVal,
                        platform,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(registration, 'InvalidVerificationProof');
            });

            it('should reject social hash already used', async function () {
                const socialHashVal = socialHash('twitter', 'sharedhandle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce1 = generateNonce();
                const deadline = timestamp + 3600;

                // user1 verifies social
                const signature1 = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce1,
                    deadline
                );

                await registration.connect(user1).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce1,
                    deadline,
                    signature1
                );

                // Register user2 and try to use same social hash
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-7011'),
                    emailHash('dup-social@test.com')
                );

                const nonce2 = generateNonce();
                const signature2 = await createSocialVerificationSignature(
                    verificationKey,
                    user2.address,
                    socialHashVal, // Same social hash
                    platform,
                    timestamp,
                    nonce2,
                    deadline
                );

                await expect(
                    registration.connect(user2).submitSocialVerification(
                        socialHashVal,
                        platform,
                        timestamp,
                        nonce2,
                        deadline,
                        signature2
                    )
                ).to.be.revertedWithCustomError(registration, 'SocialAlreadyUsed');
            });

            it('should work with telegram platform', async function () {
                const socialHashVal = socialHash('telegram', 'telegramhandle');
                const platform = 'telegram';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                const tx = await registration.connect(user1).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                await expect(tx)
                    .to.emit(registration, 'SocialVerified')
                    .withArgs(user1.address, socialHashVal, platform, timestamp);
            });
        });

        describe('hasKycTier1', function () {
            it('should return false before verifications', async function () {
                // Register a fresh user
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('kyc-tier1-test@test.com')
                );

                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });

            it('should return false after phone verification only', async function () {
                // Register user with no phone
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('phone-only@test.com')
                );

                // Submit phone verification
                const newPhoneHash = phoneHash('+1-555-7020');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createPhoneVerificationSignature(
                    verificationKey,
                    user2.address,
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline
                );

                await registration.connect(user2).submitPhoneVerification(
                    newPhoneHash,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                // Still false - need social too
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });

            it('should return false after social verification only', async function () {
                // user1 already registered with phone hash, so submit social
                const socialHashVal = socialHash('twitter', 'socialonly');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                // Register user with no phone
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('social-only@test.com')
                );

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user2.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                await registration.connect(user2).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                // Still false - need phone too
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });

            it('should return true after both verifications', async function () {
                // Register user with no phone
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('both-verify@test.com')
                );

                // Submit phone verification
                const newPhoneHash = phoneHash('+1-555-7021');
                const timestamp1 = await time.latest();
                const nonce1 = generateNonce();
                const deadline1 = timestamp1 + 3600;

                const phoneSig = await createPhoneVerificationSignature(
                    verificationKey,
                    user2.address,
                    newPhoneHash,
                    timestamp1,
                    nonce1,
                    deadline1
                );

                await registration.connect(user2).submitPhoneVerification(
                    newPhoneHash,
                    timestamp1,
                    nonce1,
                    deadline1,
                    phoneSig
                );

                // Submit social verification
                const socialHashVal = socialHash('twitter', 'bothverify');
                const platform = 'twitter';
                const timestamp2 = await time.latest();
                const nonce2 = generateNonce();
                const deadline2 = timestamp2 + 3600;

                const socialSig = await createSocialVerificationSignature(
                    verificationKey,
                    user2.address,
                    socialHashVal,
                    platform,
                    timestamp2,
                    nonce2,
                    deadline2
                );

                const tx = await registration.connect(user2).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp2,
                    nonce2,
                    deadline2,
                    socialSig
                );

                // Should emit KycTier1Completed
                await expect(tx)
                    .to.emit(registration, 'KycTier1Completed')
                    .withArgs(user2.address, await time.latest());

                // Now true
                expect(await registration.hasKycTier1(user2.address)).to.be.true;
                expect(await registration.kycTier1CompletedAt(user2.address)).to.be.gt(0);
            });

            it('should complete KYC Tier 1 for user with existing phone from registration', async function () {
                // user1 already registered with phone hash in beforeEach
                // Just need social verification

                const socialHashVal = socialHash('twitter', 'existingphone');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user1.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                const tx = await registration.connect(user1).submitSocialVerification(
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                // Should emit KycTier1Completed since user1 already has phone verified
                await expect(tx)
                    .to.emit(registration, 'KycTier1Completed')
                    .withArgs(user1.address, await time.latest());

                expect(await registration.hasKycTier1(user1.address)).to.be.true;
            });

            it('should return false for unregistered user', async function () {
                // user2 not registered
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });
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
